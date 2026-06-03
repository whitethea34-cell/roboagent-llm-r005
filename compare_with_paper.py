#!/usr/bin/env python3
"""
ERIQ 论文 Baseline 对比脚本
将本次评测结果与 ERIQ 论文中的官方 Baseline 进行对比

用法：
    python compare_with_paper.py
    # 自动读取 results/comparison.json

输出：
    - 终端对比表格（论文得分 vs 本次得分 vs 差异）
    - 兼容性判定（是否在合理误差范围内）
"""

import os
import json
from typing import Dict, Optional

# ============================================================
# ERIQ 论文中的官方 Baseline 得分
# 来源: https://arxiv.org/abs/2512.24125
# 注意：论文使用特定版本的 transformers + 私有推理代码，
#       开源复现有 ±2% 误差属于正常范围
# ============================================================
PAPER_BASELINES: Dict[str, float] = {
    # 开源模型
    "Qwen2.5-VL-3B": 58.64,
    "Qwen2.5-VL-7B": 66.69,
    "InternVL-3.5-8B": 66.72,
    "RoboBrain2.0-7B": 67.38,
    "Cosmos-Reason1-7B": 67.99,
    "Qwen3-VL-8B": 75.53,
    # 闭源 API 模型（仅供参考）
    "Claude-Sonnet-4": 65.66,
    "GPT-4o-mini": 77.61,
    "Gemini-2.5-pro": 80.55,
    # SOTA
    "GenieReasoner-3B": 82.72,
}

# 模型名称的模糊匹配映射
# 键: 配置文件/结果文件名中可能出现的名称
# 值: PAPER_BASELINES 中的标准名称
NAME_ALIASES = {
    # Qwen 系列
    "qwen2.5-vl-3b": "Qwen2.5-VL-3B",
    "qwen2.5-vl-7b": "Qwen2.5-VL-7B",
    "qwen3-vl-8b": "Qwen3-VL-8B",
    "qwen3vl8b": "Qwen3-VL-8B",
    # InternVL 系列
    "internvl2.5-8b": "InternVL-3.5-8B",
    "internvl-3.5-8b": "InternVL-3.5-8B",
    "internvl35-8b": "InternVL-3.5-8B",
    # 其他
    "robobrain2.0-7b": "RoboBrain2.0-7B",
    "cosmos-reason1-7b": "Cosmos-Reason1-7B",
}

# 可接受的误差阈值
TOLERANCE_OK = 2.0      # ±2% 内为正常
TOLERANCE_WARN = 5.0    # ±5% 内为警告，超过为严重偏差


def normalize_name(name: str) -> str:
    """将文件名/配置名转换为标准格式用于匹配"""
    return name.lower().replace('_', '').replace('-', '').replace('.', '')


def find_paper_baseline(result_name: str) -> Optional[tuple]:
    """
    根据结果文件名查找对应的论文 baseline
    返回 (标准名称, 分数) 或 None
    """
    norm = normalize_name(result_name)
    
    # 先查精确别名
    for alias, standard in NAME_ALIASES.items():
        if alias in norm or norm in alias:
            return standard, PAPER_BASELINES[standard]
    
    # 再模糊匹配 baseline 名称
    for standard, score in PAPER_BASELINES.items():
        norm_standard = normalize_name(standard)
        if norm_standard in norm or norm in norm_standard:
            return standard, score
    
    return None


def get_result_score(result_name: str, comparison_data: dict) -> Optional[float]:
    """从 comparison.json 中提取模型的总分"""
    if result_name in comparison_data:
        return comparison_data[result_name].get('_total_pct')
    
    # 尝试模糊匹配
    for key in comparison_data.keys():
        if normalize_name(key) == normalize_name(result_name):
            return comparison_data[key].get('_total_pct')
    
    return None


def main():
    comp_path = os.path.expanduser("/mnt/e/Projects/eriq-eval/results/comparison.json")
    
    # 读取本次评测数据
    your_results = {}
    if os.path.exists(comp_path):
        with open(comp_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        for model_name, scores in data.items():
            total = scores.get('_total_pct')
            if total is not None:
                your_results[model_name] = total
    else:
        print(f"[信息] 未找到 {comp_path}")
        print("      请先运行: python scripts/extract_scores.py")
        print("")
    
    # 打印对比表格
    print("="*80)
    print("ERIQ 论文 Baseline 与 本次评测对比")
    print("="*80)
    print(f"{'模型':<25} {'论文得分':>10} {'本次得分':>10} {'差异':>10} {'状态':>6}")
    print("-"*80)
    
    # 先打印有本次结果的模型
    matched_models = set()
    
    for result_name, your_score in sorted(your_results.items()):
        baseline_info = find_paper_baseline(result_name)
        
        if baseline_info:
            standard_name, paper_score = baseline_info
            matched_models.add(standard_name)
            
            diff = your_score - paper_score
            
            if abs(diff) <= TOLERANCE_OK:
                status = "✅ 正常"
                status_code = "OK"
            elif abs(diff) <= TOLERANCE_WARN:
                status = "⚠️ 偏差"
                status_code = "WARN"
            else:
                status = "❌ 异常"
                status_code = "ERROR"
            
            print(f"{standard_name:<25} {paper_score:>9.2f}% {your_score:>9.2f}% {diff:>+9.2f}% {status:>6}")
        else:
            # 本次有结果但论文无 baseline
            print(f"{result_name:<25} {'--':>9} {your_score:>9.2f}% {'--':>9} {'(新)':>6}")
    
    # 再打印论文有但本次没有的模型（提醒用户还可以测哪些）
    print("-"*80)
    missing = [m for m in PAPER_BASELINES.keys() if m not in matched_models]
    if missing:
        print("\n论文中有但本次未评测的模型（推荐补测）：")
        for m in missing:
            print(f"  - {m} (论文得分: {PAPER_BASELINES[m]:.2f}%)")
    
    print("="*80)
    
    # 统计信息
    if your_results:
        print(f"\n[统计] 本次评测模型数: {len(your_results)}")
        print(f"[统计] 与论文匹配: {len(matched_models)} / {len(your_results)}")
        
        # 计算平均差异（仅限匹配上的）
        diffs = []
        for result_name, your_score in your_results.items():
            baseline_info = find_paper_baseline(result_name)
            if baseline_info:
                _, paper_score = baseline_info
                diffs.append(abs(your_score - paper_score))
        
        if diffs:
            avg_diff = sum(diffs) / len(diffs)
            print(f"[统计] 平均绝对差异: {avg_diff:.2f}%")
            
            if avg_diff <= TOLERANCE_OK:
                print(f"\n✅ 整体复现质量优秀！平均差异在 {TOLERANCE_OK}% 内。")
            elif avg_diff <= TOLERANCE_WARN:
                print(f"\n⚠️ 整体复现可接受，但平均差异超过 {TOLERANCE_OK}%，建议检查 prompt 设置。")
            else:
                print(f"\n❌ 整体复现偏差较大，强烈建议排查：")
                print("   1. system_prompt 是否足够强约束？")
                print("   2. 答案提取正则是否匹配模型输出格式？")
                print("   3. chat_template 是否正确应用？")
                print("   4. 模型是否使用了正确的精度（bf16/fp16）？")
    
    # 保存对比数据
    output_path = os.path.expanduser("/mnt/e/Projects/eriq-eval/results/paper_comparison.json")
    comparison_output = {
        "your_results": your_results,
        "paper_baselines": PAPER_BASELINES,
        "tolerance_ok": TOLERANCE_OK,
        "tolerance_warn": TOLERANCE_WARN,
    }
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(comparison_output, f, indent=2, ensure_ascii=False)
    print(f"\n[保存] 对比数据: {output_path}")


if __name__ == '__main__':
    main()
