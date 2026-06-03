#!/usr/bin/env python3
"""
ERIQ 通用评测推理脚本 (Universal Inference Script)
支持模型: Qwen2.5-VL, Qwen3-VL, InternVL2.5-8B
作者: 零基础适配版
用法: 
    python run_inference_universal.py --model qwen2.5-vl-7b --limit 100
    python run_inference_universal.py --model internvl2.5-8b --data-dir /path/to/data
"""

import os
import sys
import json
import glob
import re
import argparse
from tqdm import tqdm
from PIL import Image

# ===================== 模型注册表 =====================
MODEL_REGISTRY = {
    "qwen2.5-vl-3b": {
        "hf_id": "Qwen/Qwen2.5-VL-3B-Instruct",
        "cls": "Qwen2_5_VLForConditionalGeneration",
        "processor": "AutoProcessor",
        "trust_remote_code": True,
        "torch_dtype": "bfloat16",
        "sample_paper_score": 58.64,
    },
    "qwen2.5-vl-7b": {
        "hf_id": "Qwen/Qwen2.5-VL-7B-Instruct",
        "cls": "Qwen2_5_VLForConditionalGeneration",
        "processor": "AutoProcessor",
        "trust_remote_code": True,
        "torch_dtype": "bfloat16",
        "sample_paper_score": 66.69,
    },
    "qwen3-vl-8b": {
        "hf_id": "Qwen/Qwen3-VL-8B",
        "cls": "Qwen3VLForConditionalGeneration",
        "processor": "AutoProcessor",
        "trust_remote_code": True,
        "torch_dtype": "bfloat16",
        "sample_paper_score": 75.53,
    },
    "internvl2.5-8b": {
        "hf_id": "OpenGVLab/InternVL2_5-8B",
        "cls": "AutoModel",
        "processor": "AutoTokenizer",
        "trust_remote_code": True,
        "torch_dtype": "bfloat16",
        "sample_paper_score": 66.72,
    },
}


def parse_args():
    parser = argparse.ArgumentParser(description="ERIQ Benchmark Inference")
    parser.add_argument(
        "--model",
        type=str,
        default="qwen2.5-vl-7b",
        choices=list(MODEL_REGISTRY.keys()),
        help="要测试的模型名称",
    )
    parser.add_argument(
        "--local-path",
        type=str,
        default=None,
        help="本地模型路径（覆盖HF下载）",
    )
    parser.add_argument(
        "--data-dir",
        type=str,
        default="/mnt/e/Projects/eriq-eval/data",
        help="ERIQ 数据集目录",
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="输出文件路径（默认自动命名）",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="仅测试前N条（用于调试）",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=1,
        help="批处理大小（4090建议保持1）",
    )
    parser.add_argument(
        "--device",
        type=str,
        default="cuda:0",
        help="计算设备",
    )
    parser.add_argument(
        "--max-new-tokens",
        type=int,
        default=32,
        help="生成最大token数",
    )
    parser.add_argument(
        "--quantization",
        type=str,
        default=None,
        choices=[None, "8bit", "4bit"],
        help="量化模式（显存不足时启用）",
    )
    return parser.parse_args()


def expand_path(path):
    return os.path.expanduser(path)


def extract_answer(text, is_yes_no=False):
    """从模型原始输出中提取标准答案"""
    text = text.strip()
    
    if is_yes_no:
        match = re.search(r'^(yes|no)[\W\s_]*', text, re.IGNORECASE)
        if match:
            return match.group(1).capitalize()
        if re.search(r'\byes\b', text, re.IGNORECASE):
            return "Yes"
        if re.search(r'\bno\b', text, re.IGNORECASE):
            return "No"
        return text
    else:
        match = re.search(r'^([A-F])[\.\.\)\s]', text, re.IGNORECASE)
        if match:
            return match.group(1).upper()
        match = re.search(r'(?:answer|答案)[\s:\\u662f]+([A-F])', text, re.IGNORECASE)
        if match:
            return match.group(1).upper()
        match = re.search(r'([A-F])', text.upper())
        if match:
            return match.group(1)
        return text


# ===================== 模型加载器 =====================

def load_model_qwen25vl(cfg, model_id, device, quantization):
    """加载 Qwen2.5-VL 系列模型"""
    from transformers import Qwen2_5_VLForConditionalGeneration, AutoProcessor
    
    extra = {}
    if quantization == "8bit":
        from transformers import BitsAndBytesConfig
        extra["quantization_config"] = BitsAndBytesConfig(load_in_8bit=True)
        extra["device_map"] = "auto"
    elif quantization == "4bit":
        from transformers import BitsAndBytesConfig
        extra["quantization_config"] = BitsAndBytesConfig(load_in_4bit=True)
        extra["device_map"] = "auto"
    else:
        extra["device_map"] = "auto"
    
    dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
    
    model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
        model_id,
        torch_dtype=dtype,
        trust_remote_code=True,
        **extra,
    ).eval()
    
    processor = AutoProcessor.from_pretrained(model_id, trust_remote_code=True)
    return model, processor


def load_model_qwen3vl(cfg, model_id, device, quantization):
    """加载 Qwen3-VL 系列模型"""
    try:
        from transformers import Qwen3VLForConditionalGeneration, AutoProcessor
    except ImportError:
        print("错误: 当前 transformers 版本不支持 Qwen3-VL，请升级:")
        print("  pip install --upgrade transformers -i https://mirrors.aliyun.com/pypi/simple/")
        sys.exit(1)
    
    extra = {}
    if quantization == "8bit":
        from transformers import BitsAndBytesConfig
        extra["quantization_config"] = BitsAndBytesConfig(load_in_8bit=True)
        extra["device_map"] = "auto"
    else:
        extra["device_map"] = "auto"
    
    dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
    
    model = Qwen3VLForConditionalGeneration.from_pretrained(
        model_id,
        torch_dtype=dtype,
        trust_remote_code=True,
        **extra,
    ).eval()
    
    processor = AutoProcessor.from_pretrained(model_id, trust_remote_code=True)
    return model, processor


def load_model_internvl25(cfg, model_id, device, quantization):
    """加载 InternVL2.5 系列模型"""
    from transformers import AutoModel, AutoTokenizer
    import torch
    
    extra = {}
    if quantization == "8bit":
        from transformers import BitsAndBytesConfig
        extra["quantization_config"] = BitsAndBytesConfig(load_in_8bit=True)
    
    dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
    
    model = AutoModel.from_pretrained(
        model_id,
        torch_dtype=dtype,
        low_cpu_mem_usage=True,
        trust_remote_code=True,
        device_map="auto",
        **extra,
    ).eval()
    
    tokenizer = AutoTokenizer.from_pretrained(model_id, trust_remote_code=True, use_fast=False)
    return model, tokenizer


# ===================== 推理核心 =====================

def infer_qwen25vl(model, processor, item, device, max_new_tokens):
    """Qwen2.5-VL 单条推理"""
    image_paths = item.get("image", [])
    images = []
    for img_path in image_paths:
        if not os.path.isabs(img_path):
            img_path = os.path.join(DATA_DIR, img_path)
        if os.path.exists(img_path):
            images.append(Image.open(img_path).convert("RGB"))
    
    question = item["conversations"][0]["value"]
    content = []
    for _ in images:
        content.append({"type": "image"})
    content.append({"type": "text", "text": question.replace("<image>", "").strip()})
    
    messages = [
        {"role": "system", "content": "You are a helpful assistant. Answer with only the choice letter (A/B/C/D/E/F) or Yes/No."},
        {"role": "user", "content": content}
    ]
    
    text_input = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = processor(
        text=[text_input],
        images=images if images else None,
        return_tensors="pt",
        padding=True
    ).to(model.device)
    
    with torch.no_grad():
        generated_ids = model.generate(
            **inputs,
            max_new_tokens=max_new_tokens,
            do_sample=False,
        )
    
    generated_ids_trimmed = [
        out_ids[len(in_ids):] for in_ids, out_ids in zip(inputs.input_ids, generated_ids)
    ]
    output_text = processor.batch_decode(
        generated_ids_trimmed,
        skip_special_tokens=True,
        clean_up_tokenization_spaces=False
    )[0]
    
    return output_text


def infer_internvl25(model, tokenizer, item, device, max_new_tokens):
    """InternVL2.5 单条推理"""
    image_paths = item.get("image", [])
    images = []
    for img_path in image_paths:
        if not os.path.isabs(img_path):
            img_path = os.path.join(DATA_DIR, img_path)
        if os.path.exists(img_path):
            images.append(Image.open(img_path).convert("RGB"))
    
    question = item["conversations"][0]["value"].replace("<image>", "").strip()
    
    # InternVL 使用 <image> 占位符格式
    num_images = len(images)
    image_placeholder = "<image>\n" * num_images
    
    prompt = f"{image_placeholder}{question}\nAnswer with only the choice letter or Yes/No."
    
    # InternVL 的像素限制
    pixel_values = None
    if images and hasattr(tokenizer, "image_processor"):
        pixel_values = tokenizer.image_processor(images, return_tensors="pt").pixel_values
    elif images:
        # 备用方案：手动处理
        from torchvision import transforms
        transform = transforms.Compose([
            transforms.Resize((448, 448)),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
        ])
        pixel_values = torch.stack([transform(img) for img in images]).unsqueeze(0)
    
    if pixel_values is not None:
        pixel_values = pixel_values.to(model.device)
    
    # 构建输入
    generation_config = dict(
        max_new_tokens=max_new_tokens,
        do_sample=False,
    )
    
    # InternVL 使用 model.chat 或直接 generate
    # 注意：不同版本的 InternVL API 略有差异，这里使用通用方式
    if hasattr(model, "chat"):
        response, _ = model.chat(
            tokenizer,
            pixel_values,
            prompt,
            generation_config,
            history=None,
            return_history=True
        )
        return response
    else:
        # 通用 generate 方式
        inputs = tokenizer(prompt, return_tensors="pt", padding=True)
        if pixel_values is not None:
            inputs["pixel_values"] = pixel_values
        inputs = {k: v.to(model.device) for k, v in inputs.items()}
        
        with torch.no_grad():
            outputs = model.generate(**inputs, max_new_tokens=max_new_tokens, do_sample=False)
        
        output_text = tokenizer.decode(outputs[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True)
        return output_text


# ===================== 主程序 =====================

def main():
    args = parse_args()
    
    global DATA_DIR
    DATA_DIR = expand_path(args.data_dir)
    
    model_key = args.model
    cfg = MODEL_REGISTRY[model_key]
    
    # 确定模型加载路径
    model_id = args.local_path if args.local_path else cfg["hf_id"]
    
    # 自动确定输出路径
    if args.output is None:
        os.makedirs(expand_path("/mnt/e/Projects/eriq-eval/results"), exist_ok=True)
        args.output = f"/mnt/e/Projects/eriq-eval/results/{model_key}_predictions.json"
    OUTPUT_PATH = expand_path(args.output)
    
    print("=" * 50)
    print("ERIQ 通用推理脚本")
    print(f"模型: {model_key} ({cfg['hf_id']})")
    print(f"论文参考得分: {cfg.get('sample_paper_score', 'N/A')}%")
    print(f"数据目录: {DATA_DIR}")
    print(f"输出路径: {OUTPUT_PATH}")
    if args.limit:
        print(f"调试模式: 仅测试前 {args.limit} 条")
    if args.quantization:
        print(f"量化模式: {args.quantization}")
    print("=" * 50)
    print()
    
    # 环境检查
    import torch
    print(f"PyTorch: {torch.__version__}")
    print(f"CUDA 可用: {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"GPU: {torch.cuda.get_device_name(0)}")
        print(f"显存: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB")
    print()
    
    # 加载模型
    print("正在加载模型...")
    
    if "qwen2.5" in model_key:
        model, processor = load_model_qwen25vl(cfg, model_id, args.device, args.quantization)
        infer_fn = infer_qwen25vl
    elif "qwen3" in model_key:
        model, processor = load_model_qwen3vl(cfg, model_id, args.device, args.quantization)
        infer_fn = infer_qwen25vl  # Qwen3-VL API 与 Qwen2.5-VL 兼容
    elif "internvl" in model_key:
        model, processor = load_model_internvl25(cfg, model_id, args.device, args.quantization)
        infer_fn = infer_internvl25
    else:
        print(f"不支持的模型: {model_key}")
        sys.exit(1)
    
    print("模型加载完成！")
    if torch.cuda.is_available():
        print(f"显存占用: {torch.cuda.memory_allocated() / 1024**3:.2f} GB")
    print()
    
    # 加载数据
    json_files = sorted(glob.glob(os.path.join(DATA_DIR, "QA_*.json")))
    if not json_files:
        print(f"错误: 在 {DATA_DIR} 中未找到 QA_*.json 文件！")
        print("请确认 ERIQ 数据集已正确下载。")
        sys.exit(1)
    
    print(f"发现 {len(json_files)} 个评测文件")
    
    all_predictions = []
    total_items = 0
    
    for json_file in json_files:
        subset_name = os.path.basename(json_file).replace(".json", "")
        print(f"\n处理: {subset_name}")
        
        with open(json_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        if args.limit:
            data = data[:args.limit]
            print(f"  [调试] 仅处理前 {args.limit} 条")
        
        for item in tqdm(data, desc=subset_name):
            try:
                output_text = infer_fn(model, processor, item, args.device, args.max_new_tokens)
                
                gt_answer = item["conversations"][1]["value"]
                is_yes_no = gt_answer.strip().lower() in ["yes", "no"]
                prediction = extract_answer(output_text, is_yes_no)
                
                all_predictions.append({
                    "id": item["id"],
                    "image": item.get("image", []),
                    "conversations": item["conversations"],
                    "prediction": prediction,
                    "gt_answer": gt_answer,
                    "raw_output": output_text,
                })
                total_items += 1
                
            except Exception as e:
                print(f"\n  错误 {item.get('id', 'unknown')}: {e}")
                import traceback
                traceback.print_exc()
                
                all_predictions.append({
                    "id": item.get("id", f"{subset_name}:unknown"),
                    "image": item.get("image", []),
                    "conversations": item.get("conversations", []),
                    "prediction": "",
                    "gt_answer": item["conversations"][1]["value"] if item.get("conversations") else "",
                    "raw_output": f"ERROR: {e}",
                })
    
    # 保存结果
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, 'w', encoding='utf-8') as f:
        json.dump(all_predictions, f, ensure_ascii=False, indent=2)
    
    print(f"\n{'='*50}")
    print(f"推理完成！共处理 {total_items} 条题目")
    print(f"结果保存至: {OUTPUT_PATH}")
    if torch.cuda.is_available():
        print(f"显存峰值: {torch.cuda.max_memory_allocated() / 1024**3:.2f} GB")
    print()
    print("下一步运行评分:")
    print(f"  python eval_code/eval_hf.py {OUTPUT_PATH}")
    print("="*50)


if __name__ == "__main__":
    main()
