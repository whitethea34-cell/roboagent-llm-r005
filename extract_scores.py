#!/usr/bin/env python3
"""
ERIQ 评分提取与多模型对比报告生成
功能：从官方 eval_hf.py 的输出文本中提取分数，生成对比表格

用法：
    python extract_scores.py
    # 自动读取 results/ 目录下所有 *_score.txt 文件

输出：
    - 终端对比表格
    - results/comparison.json （结构化数据）
    - results/comparison.md （Markdown 报告）
"""

import os
import re
import json
import glob
from typing import Dict, Any

RESULTS_DIR = os.path.expanduser("/mnt/e/Projects/eriq-eval/results")


def parse_score_file(filepath: str) -> Dict[str, Any]:
    """
    解析 eval_hf.py 的输出文本，提取各子任务分数
    
    eval_hf.py 的输出格式示例：
    +--------------------------+-----------------+------------+------------------+
    | Test Subset              | Total Samples   | Correct    | Accuracy         |
    +==========================+=================+============+==================+
    | QA_ACTION_UNDERSTANDING  | 482             | 342        | 0.7095 (70.95%)  |
    ...
    | Total / Weighted Average | 6052            | N/A        | 0.6869 (68.69%)  |
    +--------------------------+-----------------+------------+------------------+
    """
    scores = {'_subsets': {}}
    
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # 提取加权平均分（总分）
    # 匹配：Weighted average accuracy: 0.6869 (68.69%)
    weighted_match = re.search(
        r'Weighted\s+average\s+accuracy:\s+([0-9.]+)\s+\(([0-9.]+)%\)',
        content
    )
    if weighted_match:
        scores['_total_float'] = float(weighted_match.group(1))
        scores['_total_pct'] = float(weighted_match.group(2))
    else:
        # 备用匹配格式
        alt_match = re.search(r'Weighted\s+average\s+accuracy:\s+([0-9.]+)', content)
        if alt_match:
            scores['_total_float'] = float(alt_match.group(1))
            scores['_total_pct'] = scores['_total_float'] * 100
    
    # 提取各子任务分数
    # 匹配行：| QA_XXX | 482 | 342 | 0.7095 (70.95%) |
    pattern = re.compile(
        r'\|\s*(QA_\w+)\s*\|\s*(\d+)\s*\|\s*(\S+)\s*\|\s*([0-9.]+)\s*\(([0-9.]+)%\)\s*\|'
    )
    
    for match in pattern.finditer(content):
        subset = match.group(1)
        total = int(match.group(2))
        correct_str = match.group(3)
        accuracy = float(match.group(4))
        accuracy_pct = float(match.group(5))
        
        # correct 字段可能是 "N/A"（总分行）
        correct = None
        if correct_str.isdigit():
            correct = int(correct_str)
        
        scores['_subsets'][subset] = {
            'total': total,
            'correct': correct,
            'accuracy': accuracy,
            'accuracy_pct': accuracy_pct
        }
    
    return scores


def generate_comparison_table(all_scores: Dict[str, Dict]) -> str:
    """生成 Markdown 格式的对比表格"""
    models = sorted(all_scores.keys())
    
    # 收集所有子任务名
    subsets = set()
    for scores in all_scores.values():
        subsets.update(scores.get('_subsets', {}).keys())
    subsets = sorted(subsets)
    
    lines = []
    lines.append("# ERIQ 多模型对比评测报告")
    lines.append("")
    lines.append(f"> 生成时间: {__import__('datetime').datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("")
    
    # 总览表格
    lines.append("## 总体得分对比")
    lines.append("")
    lines.append("| 模型 | 加权平均准确率 | 与论文差异 |")
    lines.append("|------|--------------|-----------|")
    
    # 论文 baseline 映射（可根据实际情况扩展）
    paper_baselines = {
        'qwen2.5-vl-3b': 58.64,
        'qwen2.5-vl-7b': 66.69,
        'qwen3-vl-8b': 75.53,
        'internvl2.5-8b': 66.72,
    }
    
    for model in models:
        total = all_scores[model].get('_total_pct', 0)
        paper = paper_baselines.get(model)
        if paper is not None:
            diff = total - paper
            diff_str = f"{diff:+.2f}%"
            status = "✅" if abs(diff) <= 2 else ("⚠️" if abs(diff) <= 5 else "❌")
        else:
            diff_str = "N/A"
            status = ""
        
        lines.append(f"| {model} | **{total:.2f}%** | {diff_str} {status} |")
    
    lines.append("")
    
    # 子任务详细对比
    lines.append("## 各子任务详细对比")
    lines.append("")
    
    # 表头
    header = "| 子任务 | " + " | ".join(models) + " |"
    lines.append(header)
    
    separator = "|--------|" + "|".join(["--------"] * len(models)) + "|"
    lines.append(separator)
    
    # 数据行
    for subset in subsets:
        row = f"| {subset} |"
        for model in models:
            sub = all_scores[model].get('_subsets', {}).get(subset, {})
            if sub:
                row += f" {sub['accuracy_pct']:.2f}% |"
            else:
                row += " N/A |"
        lines.append(row)
    
    # 总分行
    total_row = "| **TOTAL** |"
    for model in models:
        total = all_scores[model].get('_total_pct', 0)
        total_row += f" **{total:.2f}%** |"
    lines.append(total_row)
    
    lines.append("")
    lines.append("---")
    lines.append("*由 extract_scores.py 自动生成*")
    
    return "\n".join(lines)


def main():
    # 查找所有评分文件
    score_files = sorted(glob.glob(os.path.join(RESULTS_DIR, "*_score.txt")))
    
    if not score_files:
        print("[错误] 未找到评分文件！")
        print("      请确保已运行官方评分脚本：")
        print("      python eval_code/eval_hf.py results/xxx_predictions.json > results/xxx_score.txt")
        return
    
    print(f"[信息] 发现 {len(score_files)} 个评分文件")
    
    # 解析所有评分
    all_scores = {}
    for sf in score_files:
        model_name = os.path.basename(sf).replace("_score.txt", "")
        print(f"[解析] {model_name} ...")
        all_scores[model_name] = parse_score_file(sf)
    
    # 提取所有子任务名
    subsets = set()
    for scores in all_scores.values():
        subsets.update(scores.get('_subsets', {}).keys())
    subsets = sorted(subsets)
    
    models = sorted(all_scores.keys())
    
    # 打印终端对比表格
    print("\n" + "="*100)
    print("ERIQ 多模型对比评分报告")
    print("="*100)
    
    # 打印表头
    header = f"{'Subtask':<35}"
    for model in models:
        # 截断过长的模型名
        display_name = model[:18]
        header += f" | {display_name:>18}"
    print(header)
    print("-" * len(header))
    
    # 打印各子任务行
    for subset in subsets:
        line = f"{subset:<35}"
        for model in models:
            sub = all_scores[model].get('_subsets', {}).get(subset, {})
            if sub:
                line += f" | {sub['accuracy_pct']:>8.2f}% ({sub['correct']:>3}/{sub['total']:>3})"
            else:
                line += f" | {'N/A':>18}"
        print(line)
    
    # 打印总分行
    print("-" * len(header))
    total_line = f"{'TOTAL (Weighted Avg)':<35}"
    for model in models:
        t = all_scores[model].get('_total_pct', 0)
        total_line += f" | {t:>8.2f}%"
    print(total_line)
    
    print("="*100)
    
    # 保存 JSON
    json_path = os.path.join(RESULTS_DIR, "comparison.json")
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(all_scores, f, indent=2, ensure_ascii=False)
    print(f"\n[保存] 结构化数据: {json_path}")
    
    # 保存 Markdown
    md_content = generate_comparison_table(all_scores)
    md_path = os.path.join(RESULTS_DIR, "comparison.md")
    with open(md_path, 'w', encoding='utf-8') as f:
        f.write(md_content)
    print(f"[保存] Markdown 报告: {md_path}")
    
    # 打印模型总数和子任务数
    print(f"\n[统计] 模型数: {len(models)}, 子任务数: {len(subsets)}")
    print("\n下一步：与论文 Baseline 对比")
    print("  python scripts/compare_with_paper.py")


if __name__ == '__main__':
    main()
