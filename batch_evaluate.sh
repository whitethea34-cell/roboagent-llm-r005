#!/bin/bash
# ============================================================
# ERIQ 批量评测脚本
# 功能：按顺序评测多个模型，自动切换 conda 环境，生成评分
# 用法：
#   chmod +x batch_evaluate.sh
#   bash batch_evaluate.sh
# ============================================================

set -e

PROJECT_ROOT="/mnt/e/Projects/eriq-eval"
RESULTS_DIR="$PROJECT_ROOT/results"
CONFIGS_DIR="$PROJECT_ROOT/configs"
EVAL_SCRIPT="$PROJECT_ROOT/eval_code/eval_hf.py"

# ============================================================
# 【用户配置区】在此定义要评测的模型
# 格式：(配置文件路径  conda环境名)
# ============================================================
MODELS=(
    "$CONFIGS_DIR/qwen2.5-vl-3b.yaml   eriq-qwen"
    "$CONFIGS_DIR/qwen2.5-vl-7b.yaml   eriq-qwen"
    # "$CONFIGS_DIR/internvl2.5-8b.yaml  eriq-internvl"
    # "$CONFIGS_DIR/qwen3-vl-8b.yaml      eriq-qwen"
)

# 是否先跑调试模式（10条验证）
DEBUG_FIRST=true

# 调试时最少需要几条有效预测才算通过
DEBUG_MIN_VALID=5

# ============================================================
# 脚本主体（通常无需修改下方内容）
# ============================================================

echo "=========================================="
echo "  ERIQ 批量评测流水线"
echo "  项目目录: $PROJECT_ROOT"
echo "  计划评测: ${#MODELS[@]} 个模型"
echo "=========================================="

# 检查项目目录
if [ ! -d "$PROJECT_ROOT" ]; then
    echo "[错误] 项目目录不存在: $PROJECT_ROOT"
    echo "      请先运行环境初始化脚本 setup_eriq_project.sh"
    exit 1
fi

# 确保结果目录存在
mkdir -p "$RESULTS_DIR"

# 检查 eval_hf.py 是否存在
if [ ! -f "$EVAL_SCRIPT" ]; then
    echo "[错误] 评测脚本不存在: $EVAL_SCRIPT"
    echo "      请从 ERIQ GitHub 仓库下载 eval_code/"
    exit 1
fi

# 逐模型评测
for i in "${!MODELS[@]}"; do
    # 解析配置
    line="${MODELS[$i]}"
    config_file=$(echo "$line" | awk '{print $1}')
    env_name=$(echo "$line" | awk '{print $2}')
    
    # 检查配置文件
    if [ ! -f "$config_file" ]; then
        echo ""
        echo "[跳过] 配置文件不存在: $config_file"
        continue
    fi
    
    model_name=$(basename "$config_file" .yaml)
    
    echo ""
    echo "=========================================="
    echo "[$((i+1))/${#MODELS[@]}] 评测模型: $model_name"
    echo "    配置文件: $config_file"
    echo "    Conda 环境: $env_name"
    echo "=========================================="
    
    # 检查 conda 环境是否存在
    if ! conda env list | grep -q "^${env_name} "; then
        echo "[错误] Conda 环境 '$env_name' 不存在！"
        echo "      请先创建环境: conda create -n $env_name --clone eriq -y"
        continue
    fi
    
    # 激活环境
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate "$env_name"
    
    current_env=$(conda info --envs | grep '^\*' | awk '{print $1}')
    echo "[环境] 当前激活: $current_env"
    
    # 打印环境关键包版本
    echo "[环境] Python: $(python --version 2>&1)"
    python -c "import transformers; print(f'[环境] transformers: {transformers.__version__}')" 2>/dev/null || echo "[环境] transformers: 未安装"
    python -c "import torch; print(f'[环境] torch: {torch.__version__}, CUDA: {torch.cuda.is_available()}')" 2>/dev/null || echo "[环境] torch: 未安装"
    
    # 调试模式（首次验证）
    if [ "$DEBUG_FIRST" = true ]; then
        echo ""
        echo "[调试] 运行 10 条样本验证 prompt 和输出格式..."
        
        python "$PROJECT_ROOT/scripts/run_from_config.py" \
            --config "$config_file" \
            --limit 10 \
            --output "$RESULTS_DIR/${model_name}_debug.json"
        
        # 检查有效预测数量
        valid_count=$(python -c "
import json, sys
try:
    with open('$RESULTS_DIR/${model_name}_debug.json') as f:
        data = json.load(f)
    valid = [d for d in data if d['prediction'] in ['A','B','C','D','E','F','Yes','No']]
    print(len(valid))
except:
    print(0)
" 2>/dev/null)
        
        echo "[调试] 有效预测: $valid_count / 10"
        
        if [ "$valid_count" -lt "$DEBUG_MIN_VALID" ]; then
            echo ""
            echo "[警告] 有效预测过少 ($valid_count < $DEBUG_MIN_VALID)！"
            echo "      可能原因："
            echo "      1. system_prompt 约束不够强，模型输出长句子"
            echo "      2. 答案提取正则不匹配该模型的输出格式"
            echo "      3. chat_template 未正确应用"
            echo ""
            read -p "按回车继续（风险自负），或 Ctrl+C 中断..."
        else
            echo "[调试] 验证通过！"
        fi
    fi
    
    # 正式推理（全量）
    echo ""
    echo "[推理] 开始全量推理（6052 条，预计 30~120 分钟）..."
    
    python "$PROJECT_ROOT/scripts/run_from_config.py" \
        --config "$config_file" \
        --output "$RESULTS_DIR/${model_name}_predictions.json"
    
    echo "[推理] 完成！"
    
    # 评分
    echo ""
    echo "[评分] 运行官方 eval_hf.py ..."
    
    python "$EVAL_SCRIPT" \
        "$RESULTS_DIR/${model_name}_predictions.json" \
        > "$RESULTS_DIR/${model_name}_score.txt" 2>&1
    
    # 提取总分显示
    total_score=$(grep "Weighted average accuracy" "$RESULTS_DIR/${model_name}_score.txt" | awk '{print $NF}' || echo "N/A")
    echo "[评分] 完成！加权平均得分: $total_score"
    echo "[评分] 详细结果: $RESULTS_DIR/${model_name}_score.txt"
    
    # 可选：清理显存（防止连续运行多个模型时显存碎片）
    python -c "import torch; torch.cuda.empty_cache()" 2>/dev/null || true
    
    echo ""
    echo "[$((i+1))/${#MODELS[@]}] $model_name 评测完成"
done

echo ""
echo "=========================================="
echo "  所有模型评测完成！"
echo "=========================================="
echo ""
echo "结果文件列表:"
ls -lh "$RESULTS_DIR"/*_predictions.json 2>/dev/null || echo "  (无预测结果文件)"
echo ""
echo "评分文件列表:"
ls -lh "$RESULTS_DIR"/*_score.txt 2>/dev/null || echo "  (无评分文件)"
echo ""
echo "下一步：生成对比报告"
echo "  python scripts/extract_scores.py"
echo "  python scripts/compare_with_paper.py"
echo ""
echo "=========================================="
