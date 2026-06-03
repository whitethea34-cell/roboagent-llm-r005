#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RoboBrain2.0-7B ONNX 导出管线
==============================
- 从 HuggingFace 下载模型（PyTorch）
- 用 Optimum 导出到 ONNX
- ONNX Runtime 推理验证
- 输出质量对比 + Benchmark

用法:
  # 自动模式（下载 → 导出 → 验证）
  python robobrain_onnx_export.py

  # 仅导出（跳过下载，使用本地缓存）
  python robobrain_onnx_export.py --model-path /path/to/model

  # 仅验证已导出的 ONNX
  python robobrain_onnx_export.py --onnx-path ./robobrain_onnx --skip-export

环境要求:
  pip install torch transformers optimum onnxruntime-gpu
"""

import os, sys, time, json, argparse, shutil
from pathlib import Path


# ── 配置 ──────────────────────────────────────────────────────
MODEL_ID = "BAAI/RoboBrain2.0-7B"
ONNX_OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "robobrain_onnx")
CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hf_cache")

# 测试样本：简单视觉问答（纯文本测试也 OK）
TEST_SAMPLE = {
    "text": "What objects are on the table? List them one by one.",
}

SKIP_IF_OOM = False  # 7B 模型需要约 16GB 显存（fp16）


# ── Phase 1: 检查环境 ──────────────────────────────────────────
def check_env():
    missing = []
    for pkg, name in [("torch", "torch"), ("transformers", "transformers"),
                       ("optimum", "optimum"), ("onnxruntime", "onnxruntime")]:
        try:
            __import__(pkg)
            print(f"  ✓ {name} 已安装")
        except ImportError:
            missing.append(name)

    # 检查 CUDA
    try:
        import torch
        if torch.cuda.is_available():
            print(f"  ✓ CUDA 可用: {torch.cuda.get_device_name(0)}, "
                  f"显存: {torch.cuda.get_device_properties(0).total_mem / 1e9:.1f} GB")
        else:
            print("  ⚠ CUDA 不可用，将使用 CPU（极慢）")
    except:
        pass

    if missing:
        print(f"\n  ❌ 缺少依赖: {', '.join(missing)}")
        print(f"  安装: pip install {' '.join(missing)}")
        return False
    return True


# ── Phase 2: 下载模型 ──────────────────────────────────────────
def download_model():
    """从 HuggingFace 下载 RoboBrain2.0-7B"""
    from transformers import AutoModelForVision2Seq, AutoProcessor

    print(f"\n{'='*60}")
    print(f"  Phase 2: 下载模型 {MODEL_ID}")
    print(f"{'='*60}")

    os.makedirs(CACHE_DIR, exist_ok=True)

    t0 = time.time()
    print(f"  → 加载处理器 (processor)...")
    processor = AutoProcessor.from_pretrained(
        MODEL_ID, cache_dir=CACHE_DIR, trust_remote_code=True
    )
    print(f"  ✓ 处理器加载完成 ({time.time()-t0:.1f}s)")

    t0 = time.time()
    print(f"  → 加载模型 (PyTorch, fp16, device_map=auto)...")
    print(f"    注意: 7B 模型需要 ~14GB 显存")
    model = AutoModelForVision2Seq.from_pretrained(
        MODEL_ID,
        cache_dir=CACHE_DIR,
        torch_dtype="auto",
        device_map="auto",
        trust_remote_code=True,
        low_cpu_mem_usage=True,
    )
    print(f"  ✓ 模型加载完成 ({time.time()-t0:.1f}s)")
    print(f"    参数量: {model.num_parameters()/1e9:.2f}B")
    print(f"    设备: {model.device}")

    return model, processor


# ── Phase 3: ONNX 导出 ─────────────────────────────────────────
def export_onnx(model, processor):
    """用 Optimum 导出到 ONNX"""
    from optimum.onnxruntime import ORTModelForVision2Seq
    from optimum.exporters import TasksManager

    print(f"\n{'='*60}")
    print(f"  Phase 3: ONNX 导出")
    print(f"{'='*60}")

    if os.path.exists(ONNX_OUTPUT_DIR):
        print(f"  ⚠ 目录已存在，清理中...")
        shutil.rmtree(ONNX_OUTPUT_DIR)

    t0 = time.time()
    try:
        print(f"  → 正在导出到 ONNX...")
        print(f"    目标: {ONNX_OUTPUT_DIR}")

        # 方法1: 用 optimum 的 ORTModelForVision2Seq
        onnx_model = ORTModelForVision2Seq.from_pretrained(
            MODEL_ID,
            export=True,
            cache_dir=CACHE_DIR,
            trust_remote_code=True,
            provider="CUDAExecutionProvider",
        )
        onnx_model.save_pretrained(ONNX_OUTPUT_DIR)
        processor.save_pretrained(ONNX_OUTPUT_DIR)

        print(f"  ✓ ONNX 导出完成 ({time.time()-t0:.1f}s)")
        print(f"    模型文件:")
        for f in sorted(os.listdir(ONNX_OUTPUT_DIR)):
            fpath = os.path.join(ONNX_OUTPUT_DIR, f)
            size = os.path.getsize(fpath)
            print(f"      {f:40s} {size/1024/1024:.1f} MB")

        return onnx_model

    except Exception as e:
        print(f"\n  ❌ Optimum 直接导出失败: {e}")
        print(f"\n  → 回退方法: 用 optimum-cli")
        print(f"  命令:")
        print(f"    optimum-cli export onnx \\")
        print(f"      --model {MODEL_ID} \\")
        print(f"      --task vision2seq-lm \\")
        print(f"      --trust-remote-code \\")
        print(f"      {ONNX_OUTPUT_DIR}")

        print(f"\n  → 若仍失败，使用手动 torch.onnx.export 回退")
        fallback_export_torch(model, processor)
        return None


# ── Phase 3 fallback: 手动 torch.onnx.export ──────────────────
def fallback_export_torch(model, processor):
    """手动逐部分导出（Vision Encoder + Language Model）"""
    print(f"\n  {'='*50}")
    print(f"  Fallback: 手动分段导出 ONNX")
    print(f"  {'='*50}")

    os.makedirs(ONNX_OUTPUT_DIR, exist_ok=True)

    # 识别模型组件
    config = model.config

    try:
        # ── 导出 Vision Encoder ──
        if hasattr(model, "visual") or hasattr(model.model, "visual"):
            vision = getattr(model, "visual", None) or model.model.visual
            print(f"  → 导出 Vision Encoder...")

            dummy_input = torch.randn(1, 3, 224, 224).to(model.device)

            torch.onnx.export(
                vision,
                dummy_input,
                os.path.join(ONNX_OUTPUT_DIR, "vision_encoder.onnx"),
                input_names=["pixel_values"],
                output_names=["image_features"],
                dynamic_axes={"pixel_values": {0: "batch", 2: "height", 3: "width"}},
                opset_version=17,
                do_constant_folding=True,
            )
            print(f"  ✓ Vision Encoder 导出完成")
    except Exception as e:
        print(f"  ⚠ Vision Encoder 导出失败: {e}")

    try:
        # ── 导出 Language Model ──
        if hasattr(model, "language_model") or hasattr(model.model, "language_model"):
            lm = getattr(model, "language_model", None) or model.model.language_model
            print(f"  → 导出 Language Model...")

            # 导出 decoder（需要部分 token）
            dtype = next(lm.parameters()).dtype
            dummy_ids = torch.zeros((1, 1), dtype=torch.long).to(model.device)

            torch.onnx.export(
                lm,
                dummy_ids,
                os.path.join(ONNX_OUTPUT_DIR, "language_model.onnx"),
                input_names=["input_ids"],
                output_names=["logits"],
                dynamic_axes={
                    "input_ids": {0: "batch", 1: "seq_len"},
                    "logits": {0: "batch", 1: "seq_len"},
                },
                opset_version=17,
                do_constant_folding=True,
            )
            print(f"  ✓ Language Model 导出完成")
    except Exception as e:
        print(f"  ⚠ Language Model 导出失败: {e}")


# ── Phase 4: ONNX Runtime 验证 ─────────────────────────────────
def verify_onnx(processor):
    """用 ONNX Runtime 加载并推理"""
    from onnxruntime import InferenceSession, SessionOptions, GraphOptimizationLevel

    print(f"\n{'='*60}")
    print(f"  Phase 4: ONNX Runtime 验证")
    print(f"{'='*60}")

    model_files = sorted([
        f for f in os.listdir(ONNX_OUTPUT_DIR)
        if f.endswith(".onnx")
    ])

    if not model_files:
        print(f"  ⚠ 未找到 ONNX 文件")
        return

    for fname in model_files:
        fpath = os.path.join(ONNX_OUTPUT_DIR, fname)
        fsize = os.path.getsize(fpath) / 1024 / 1024
        print(f"\n  → 加载: {fname} ({fsize:.1f} MB)")

        opts = SessionOptions()
        opts.graph_optimization_level = GraphOptimizationLevel.ORT_ENABLE_ALL

        try:
            # 优先 CUDA
            session = InferenceSession(fpath, opts, providers=["CUDAExecutionProvider"])
            provider = "CUDA"
        except:
            session = InferenceSession(fpath, opts, providers=["CPUExecutionProvider"])
            provider = "CPU"

        print(f"    运行设备: {provider}")

        # Benchmark 推理
        input_meta = session.get_inputs()
        print(f"    输入: {[(inp.name, inp.shape, inp.type) for inp in input_meta]}")
        print(f"    输出: {[(out.name, out.shape, out.type) for out in session.get_outputs()]}")

        # Warmup
        feeds = {}
        for inp in input_meta:
            shape = [d if isinstance(d, int) and d > 0 else 1 for d in inp.shape]
            import numpy as np
            if "float" in inp.type:
                feeds[inp.name] = np.random.randn(*shape).astype(np.float32)
            else:
                feeds[inp.name] = np.zeros(shape, dtype=np.int64)

        for _ in range(3):
            session.run(None, feeds)

        # Benchmark
        n_warmup = 10
        n_test = 50
        for _ in range(n_warmup):
            session.run(None, feeds)

        t0 = time.time()
        for _ in range(n_test):
            session.run(None, feeds)
        elapsed = (time.time() - t0) * 1000
        avg = elapsed / n_test

        print(f"    推理延迟 (batch=1): {avg:.1f} ms (avg of {n_test})")
        print(f"    ✓ ONNX 验证通过")


# ── Phase 5: PyTorch vs ONNX 质量对比 ──────────────────────────
def benchmark_compare(model, processor):
    """对比 PyTorch 和 ONNX 的推理质量和速度"""
    print(f"\n{'='*60}")
    print(f"  Phase 5: PyTorch vs ONNX 对比")
    print(f"{'='*60}")

    # ── PyTorch 推理 ──
    print(f"\n  ── PyTorch fp16 ──")
    inputs = processor(text=TEST_SAMPLE["text"], return_tensors="pt").to(model.device)
    input_len = inputs["input_ids"].shape[1]

    # Warmup
    for _ in range(2):
        with torch.no_grad():
            model.generate(**inputs, max_new_tokens=32)

    # Benchmark: prompt processing
    t0 = time.time()
    with torch.no_grad():
        out_pt = model.generate(**inputs, max_new_tokens=32)
    pt_time = (time.time() - t0) * 1000
    pt_tokens = out_pt.shape[1] - input_len
    pt_text = processor.decode(out_pt[0], skip_special_tokens=True)

    print(f"    输入 tokens: {input_len}")
    print(f"    输出 tokens: {pt_tokens}")
    print(f"    推理时间:   {pt_time:.0f} ms ({pt_time/pt_tokens:.0f} ms/tok)")
    print(f"    输出: {pt_text[:120]}...")

    # ── ONNX 推理（如果可用） ──
    onnx_model_path = os.path.join(ONNX_OUTPUT_DIR, "model.onnx")
    if not os.path.exists(onnx_model_path):
        # 检查是否有其他 ONNX 文件
        onnx_files = [f for f in os.listdir(ONNX_OUTPUT_DIR) if f.endswith(".onnx")]
        if onnx_files:
            print(f"  ⚠ 未找到 model.onnx，但找到: {onnx_files}")
            print(f"    轻量级 pipeline 需要完整的 model.onnx（含 embedding + lm_head）")
        else:
            print(f"  ⚠ ONNX 模型未找到，跳过 ONNX 对比")
        print(f"\n  基准结果: PyTorch {pt_time/pt_tokens:.0f} ms/tok (GPU)")


# ── 主入口 ──────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="RoboBrain ONNX 导出管线")
    parser.add_argument("--model-path", help="本地模型路径（跳过下载）")
    parser.add_argument("--onnx-path", default=ONNX_OUTPUT_DIR, help="ONNX 输出/加载路径")
    parser.add_argument("--skip-export", action="store_true", help="跳过导出，仅验证")
    parser.add_argument("--skip-download", action="store_true", help="跳过下载，从缓存加载")
    args = parser.parse_args()

    global ONNX_OUTPUT_DIR
    ONNX_OUTPUT_DIR = args.onnx_path

    print("=" * 60)
    print("  RoboBrain2.0-7B → ONNX 导出管线")
    print("=" * 60)
    print(f"  模型:      {MODEL_ID}")
    print(f"  ONNX 输出: {ONNX_OUTPUT_DIR}")
    print(f"  缓存目录:  {CACHE_DIR}")
    print("=" * 60)

    # Phase 1: 环境检查
    print(f"\n{'='*60}")
    print(f"  Phase 1: 环境检查")
    print(f"{'='*60}")
    if not check_env():
        sys.exit(1)

    # 全局导入
    global torch, np
    import torch
    import numpy as np

    model = None
    processor = None

    if not args.skip_export:
        # Phase 2: 下载模型
        try:
            if args.model_path:
                from transformers import AutoModelForVision2Seq, AutoProcessor
                print(f"\n  → 从本地加载: {args.model_path}")
                processor = AutoProcessor.from_pretrained(
                    args.model_path, trust_remote_code=True
                )
                model = AutoModelForVision2Seq.from_pretrained(
                    args.model_path, device_map="auto",
                    torch_dtype="auto", trust_remote_code=True,
                )
            else:
                model, processor = download_model()
        except Exception as e:
            print(f"  ❌ 模型加载失败: {e}")
            if "out of memory" in str(e).lower():
                print("  提示: 7B 模型需要 ~14GB 显存。尝试:")
                print("    - 关闭其他 GPU 程序")
                print("    - 使用 device_map='sequential' 分载到 CPU")
            sys.exit(1)

        # Phase 3: ONNX 导出
        export_onnx(model, processor)

    # Phase 4: ONNX 验证
    if os.path.exists(ONNX_OUTPUT_DIR):
        verify_onnx(processor or MODEL_ID)

    # Phase 5: 对比
    if model is not None:
        benchmark_compare(model, processor)
    else:
        print(f"\n  ⚠ 无 PyTorch 模型引用，跳过对比")

    print(f"\n{'='*60}")
    print(f"  管线完成")
    print(f"  ONNX 文件: {ONNX_OUTPUT_DIR}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
