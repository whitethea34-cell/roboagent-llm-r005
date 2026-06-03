#!/usr/bin/env python3
"""
ERIQ 配置驱动的通用推理脚本
支持通过 YAML 配置文件切换不同模型，无需修改代码

用法:
    # 使用配置文件运行（推荐）
    python run_from_config.py --config ../configs/qwen2.5-vl-7b.yaml
    python run_from_config.py --config ../configs/internvl2.5-8b.yaml --limit 100

    # 指定数据目录和输出路径
    python run_from_config.py --config configs/qwen2.5-vl-3b.yaml \
        --data-dir ~/eriq/data --output ~/eriq/results/my_run.json
"""

import argparse
import yaml
import json
import os
import sys
import glob
import re
import importlib
from typing import List, Dict, Any, Optional
from tqdm import tqdm
from PIL import Image
import torch


def load_config(path: str) -> Dict[str, Any]:
    """加载 YAML 配置文件"""
    with open(path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f)


def dynamic_import(class_path: str):
    """
    动态导入 transformers 中的类
    例如 'transformers.AutoModel' 或 'AutoProcessor'
    """
    if '.' not in class_path:
        # 默认从 transformers 导入
        module = importlib.import_module('transformers')
        return getattr(module, class_path)
    else:
        module_path, class_name = class_path.rsplit('.', 1)
        module = importlib.import_module(module_path)
        return getattr(module, class_name)


def extract_answer(text: str, is_yes_no: bool = False) -> str:
    """
    从模型原始输出中提取标准答案
    - 多选题：提取 A-F 字母
    - 判断题：提取 Yes/No
    """
    text = text.strip()

    if is_yes_no:
        # 判断题：匹配开头的 Yes/No（忽略大小写和标点）
        match = re.search(r'^(yes|no)[\W\s_]*', text, re.IGNORECASE)
        if match:
            return match.group(1).capitalize()
        # 在全文搜索
        if re.search(r'\byes\b', text, re.IGNORECASE):
            return "Yes"
        if re.search(r'\bno\b', text, re.IGNORECASE):
            return "No"
        return text
    else:
        # 多选题：优先匹配 "X." 或 "X)" 开头的格式
        match = re.search(r'^([A-F])[\.\.\)\s]', text, re.IGNORECASE)
        if match:
            return match.group(1).upper()
        # 匹配 "答案是 X" 格式
        match = re.search(r'(?:answer|答案)[\s:\\u662f]+([A-F])', text, re.IGNORECASE)
        if match:
            return match.group(1).upper()
        # 在全文找第一个 A-F 字母（兜底）
        match = re.search(r'([A-F])', text.upper())
        if match:
            return match.group(1)
        return text


def build_messages_for_model(cfg: Dict, question_text: str, has_images: bool = True) -> List[Dict]:
    """
    根据不同模型构造 messages 格式
    这是模型切换时最常改动的部分
    """
    system = cfg['inference']['system_prompt']
    model_name = cfg['model_name'].lower()

    # 清理问题文本中的 <image> 占位符（不同模型有不同处理方式）
    cleaned_question = question_text.replace("<image>", "").strip()

    if 'qwen' in model_name:
        # Qwen 格式：content 是 list，包含 image/text dict
        content = []
        if has_images:
            # Qwen 的 processor 会自动将 <image> 占位符与传入的图片对应
            content.append({"type": "image"})
        content.append({"type": "text", "text": cleaned_question})

        return [
            {"role": "system", "content": system},
            {"role": "user", "content": content}
        ]

    elif 'internvl' in model_name:
        # InternVL 格式：使用 <image> 占位符拼接在文本中
        prompt = f"<image>\n{cleaned_question}\nAnswer with only the choice letter or Yes/No."
        return [
            {"role": "user", "content": prompt}
            # 注意：InternVL 的 system prompt 通常通过 generation_config 或外部传入
        ]

    else:
        # 通用格式：纯文本拼接（最保守，兼容性最好）
        prompt = f"{cleaned_question}\nAnswer with only the choice letter or Yes/No."
        return [
            {"role": "system", "content": system},
            {"role": "user", "content": prompt}
        ]


def load_model_and_processor(cfg: Dict):
    """根据配置动态加载模型和处理器"""
    loader_cfg = cfg['loader']
    model_id = cfg.get('local_path') or cfg['model_id']

    print(f"[加载] 模型: {model_id}")
    print(f"[加载] 使用模型类: {loader_cfg['class']}")
    print(f"[加载] 使用处理器类: {loader_cfg['processor_class']}")

    # 动态导入类
    ModelClass = dynamic_import(loader_cfg['class'])
    ProcessorClass = dynamic_import(loader_cfg['processor_class'])

    # 构造加载参数
    load_kwargs = {
        "trust_remote_code": loader_cfg.get('trust_remote_code', False),
    }

    if loader_cfg.get('device_map'):
        load_kwargs['device_map'] = loader_cfg['device_map']

    # 数据类型
    dtype_str = loader_cfg.get('torch_dtype', 'float32')
    if dtype_str == 'bfloat16':
        load_kwargs['torch_dtype'] = torch.bfloat16
    elif dtype_str == 'float16':
        load_kwargs['torch_dtype'] = torch.float16

    # 量化配置
    if loader_cfg.get('quantization') == '8bit':
        from transformers import BitsAndBytesConfig
        load_kwargs['quantization_config'] = BitsAndBytesConfig(load_in_8bit=True)
        load_kwargs['device_map'] = 'auto'
    elif loader_cfg.get('quantization') == '4bit':
        from transformers import BitsAndBytesConfig
        load_kwargs['quantization_config'] = BitsAndBytesConfig(load_in_4bit=True)
        load_kwargs['device_map'] = 'auto'

    model = ModelClass.from_pretrained(model_id, **load_kwargs)
    model.eval()

    processor = ProcessorClass.from_pretrained(
        model_id,
        trust_remote_code=loader_cfg.get('trust_remote_code', False)
    )

    return model, processor


def infer_with_model(cfg: Dict, model, processor, messages: List[Dict], images: List[Image.Image], max_new_tokens: int) -> str:
    """
    模型特化推理逻辑
    新增模型时，主要在这里添加分支
    """
    model_name = cfg['model_name'].lower()
    device = next(model.parameters()).device

    if 'qwen' in model_name:
        # Qwen 系列推理逻辑 (Qwen2.5-VL, Qwen3-VL)
        text = processor.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True
        )

        inputs = processor(
            text=[text],
            images=images if images else None,
            return_tensors="pt",
            padding=True
        )

        # 将输入移动到模型所在设备
        inputs = {k: v.to(device) if isinstance(v, torch.Tensor) else v for k, v in inputs.items()}

        with torch.no_grad():
            outputs = model.generate(
                **inputs,
                max_new_tokens=max_new_tokens,
                do_sample=False,
            )

        # 只取新生成的 token
        generated_ids = [
            out_ids[len(in_ids):] for in_ids, out_ids in zip(inputs['input_ids'], outputs)
        ]

        output_text = processor.batch_decode(
            generated_ids,
            skip_special_tokens=True,
            clean_up_tokenization_spaces=False
        )[0]

        return output_text

    elif 'internvl' in model_name:
        # InternVL 系列推理逻辑
        if hasattr(model, 'chat'):
            # InternVL 原生 chat 接口
            pixel_values = None
            if images and hasattr(processor, 'image_processor'):
                pixel_values = processor.image_processor(images, return_tensors="pt").pixel_values
            elif images:
                # 备用方案：手动处理图片
                from torchvision import transforms
                transform = transforms.Compose([
                    transforms.Resize((448, 448)),
                    transforms.ToTensor(),
                    transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
                ])
                pixel_values = torch.stack([transform(img) for img in images]).unsqueeze(0).to(device)

            question_text = messages[0]["content"] if messages else ""
            generation_config = dict(
                max_new_tokens=max_new_tokens,
                do_sample=False,
            )

            response, _ = model.chat(
                processor,
                pixel_values,
                question_text,
                generation_config,
                history=None,
                return_history=True
            )
            return response
        else:
            # 通用 fallback（用于不支持 chat 接口的变体）
            prompt = messages[0]["content"] if messages else ""
            inputs = processor(prompt, return_tensors="pt", padding=True)
            if images and hasattr(processor, 'image_processor'):
                pixel_values = processor.image_processor(images, return_tensors="pt").pixel_values
                inputs["pixel_values"] = pixel_values.to(device)
            inputs = {k: v.to(device) if isinstance(v, torch.Tensor) else v for k, v in inputs.items()}

            with torch.no_grad():
                outputs = model.generate(**inputs, max_new_tokens=max_new_tokens, do_sample=False)

            output_text = processor.decode(outputs[0][inputs['input_ids'].shape[1]:], skip_special_tokens=True)
            return output_text

    else:
        # 通用推理（最保守方式，适用于大多数 HF 模型）
        prompt = messages[-1]["content"] if messages else ""

        if images and hasattr(processor, 'image_processor'):
            inputs = processor(
                text=prompt,
                images=images,
                return_tensors="pt",
                padding=True
            )
        else:
            inputs = processor(prompt, return_tensors="pt", padding=True)

        inputs = {k: v.to(device) if isinstance(v, torch.Tensor) else v for k, v in inputs.items()}

        with torch.no_grad():
            outputs = model.generate(**inputs, max_new_tokens=max_new_tokens, do_sample=False)

        output_text = processor.decode(outputs[0][inputs['input_ids'].shape[1]:], skip_special_tokens=True)
        return output_text


def run_inference(cfg: Dict, data_dir: str, output_path: str, limit: Optional[int] = None):
    """主推理循环"""
    model, processor = load_model_and_processor(cfg)

    print("[推理] 模型加载完成！")
    if torch.cuda.is_available():
        mem_gb = torch.cuda.memory_allocated() / 1024**3
        print(f"[推理] 显存占用: {mem_gb:.2f} GB")

    # 收集数据
    json_files = sorted(glob.glob(os.path.join(data_dir, "QA_*.json")))
    if not json_files:
        print(f"[错误] 在 {data_dir} 中未找到 QA_*.json 文件！")
        sys.exit(1)

    print(f"[推理] 发现 {len(json_files)} 个评测文件")

    all_predictions = []
    total_items = 0

    for json_file in json_files:
        subset = os.path.basename(json_file).replace(".json", "")
        print(f"\n[推理] 处理子任务: {subset}")

        with open(json_file, 'r', encoding='utf-8') as f:
            data = json.load(f)

        if limit:
            data = data[:limit]
            print(f"  [调试] 仅处理前 {limit} 条")

        for idx, item in enumerate(tqdm(data, desc=subset)):
            try:
                # 1. 加载图片
                images = []
                for img_path in item.get("image", []):
                    if not os.path.isabs(img_path):
                        img_path = os.path.join(data_dir, img_path)
                    if os.path.exists(img_path):
                        images.append(Image.open(img_path).convert("RGB"))

                # 2. 读取问题
                question = item["conversations"][0]["value"]

                # 3. 构建 prompt
                messages = build_messages_for_model(cfg, question, bool(images))

                # 4. 模型推理
                output_text = infer_with_model(
                    cfg, model, processor, messages, images,
                    cfg['inference']['max_new_tokens']
                )

                # 5. 提取答案
                gt = item["conversations"][1]["value"]
                is_yn = gt.strip().lower() in ["yes", "no"]
                pred = extract_answer(output_text, is_yn)

                all_predictions.append({
                    "id": item["id"],
                    "image": item.get("image", []),
                    "conversations": item["conversations"],
                    "prediction": pred,
                    "gt_answer": gt,
                    "raw_output": output_text,
                })
                total_items += 1

                # 调试打印前 3 条
                if limit and idx < 3:
                    print(f"  [调试] {item['id']}: raw='{output_text[:50]}...' -> pred='{pred}' gt='{gt}'")

            except Exception as e:
                print(f"\n  [错误] {item.get('id', 'unknown')}: {e}")
                import traceback
                traceback.print_exc()

                all_predictions.append({
                    "id": item.get("id", f"{subset}:unknown"),
                    "image": item.get("image", []),
                    "conversations": item.get("conversations", []),
                    "prediction": "",
                    "gt_answer": item["conversations"][1]["value"] if item.get("conversations") else "",
                    "raw_output": f"ERROR: {e}",
                })

    # 保存结果
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(all_predictions, f, ensure_ascii=False, indent=2)

    print(f"\n{'='*50}")
    print(f"[完成] 共处理 {total_items} 条题目")
    print(f"[完成] 结果保存至: {output_path}")
    if torch.cuda.is_available():
        peak_mem = torch.cuda.max_memory_allocated() / 1024**3
        print(f"[完成] 显存峰值: {peak_mem:.2f} GB")
    print(f"[完成] 评分命令:")
    print(f"       python eval_code/eval_hf.py {output_path}")
    print("="*50)


def main():
    parser = argparse.ArgumentParser(description="ERIQ 配置驱动的通用推理脚本")
    parser.add_argument(
        '--config',
        required=True,
        help='模型配置文件路径 (.yaml)，例如 configs/qwen2.5-vl-7b.yaml'
    )
    parser.add_argument(
        '--data-dir',
        default='/mnt/e/Projects/eriq-eval/data',
        help='ERIQ 数据集目录 (默认: /mnt/e/Projects/eriq-eval/data)'
    )
    parser.add_argument(
        '--output',
        default=None,
        help='输出文件路径（默认自动根据配置名命名）'
    )
    parser.add_argument(
        '--limit',
        type=int,
        default=None,
        help='仅测试前 N 条（用于快速调试）'
    )
    args = parser.parse_args()

    # 加载配置
    config_path = os.path.expanduser(args.config)
    if not os.path.exists(config_path):
        print(f"[错误] 配置文件不存在: {config_path}")
        sys.exit(1)

    cfg = load_config(config_path)

    # 路径处理
    data_dir = os.path.expanduser(args.data_dir)

    if args.output is None:
        model_key = os.path.basename(config_path).replace('.yaml', '')
        args.output = f'/mnt/e/Projects/eriq-eval/results/{model_key}_predictions.json'

    output_path = os.path.expanduser(args.output)

    # 打印启动信息
    print("="*50)
    print(f"模型: {cfg['model_name']}")
    print(f"配置: {config_path}")
    print(f"数据: {data_dir}")
    print(f"输出: {output_path}")
    if args.limit:
        print(f"调试模式: 仅处理前 {args.limit} 条")
    print("="*50)

    # 环境检查
    print(f"\n[环境] PyTorch: {torch.__version__}")
    print(f"[环境] CUDA 可用: {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"[环境] GPU: {torch.cuda.get_device_name(0)}")
        print(f"[环境] 显存: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB")

    # 运行推理
    run_inference(cfg, data_dir, output_path, args.limit)


if __name__ == '__main__':
    main()
