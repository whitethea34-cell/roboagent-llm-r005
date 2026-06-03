#!/bin/bash
# ============================================================
# ERIQ 项目 E盘一键初始化脚本
# 用途：在 /mnt/e/Projects/eriq-eval/ 快速创建项目结构
# 适用：已完成 conda + PyTorch 环境搭建，想把项目放E盘的用户
# ============================================================

set -e

PROJECT_ROOT="/mnt/e/Projects/eriq-eval"
RESULTS_DIR="$PROJECT_ROOT/results"
CONFIGS_DIR="$PROJECT_ROOT/configs"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"

echo "=========================================="
echo "  ERIQ 项目 E盘初始化"
echo "=========================================="

# 颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ==================== 检查 E 盘挂载 ====================
echo ""
echo "[1/6] 检查 E 盘挂载..."

if [ ! -d "/mnt/e" ]; then
    echo -e "${RED}错误: E 盘未挂载到 WSL2！${NC}"
    echo "      WSL2 中 E 盘路径应为 /mnt/e/"
    echo "      请确认 Windows 文件资源管理器中能看到 E 盘。"
    exit 1
fi

if [ ! -w "/mnt/e" ]; then
    echo -e "${YELLOW}警告: 似乎没有 E 盘写入权限${NC}"
    echo "      尝试: sudo mkdir -p /mnt/e/Projects"
fi

echo -e "${GREEN}E 盘已挂载${NC}"

# 检查 E 盘剩余空间
echo ""
echo "[2/6] 检查 E 盘空间..."
AVAILABLE=$(df -h /mnt/e 2>/dev/null | awk 'NR==2 {print $4}')
USAGE_PCT=$(df -h /mnt/e 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')

if [ -n "$AVAILABLE" ]; then
    echo "E 盘可用空间: $AVAILABLE"
    if [ "$USAGE_PCT" -gt 95 ] 2>/dev/null; then
        echo -e "${RED}警告: E 盘使用率超过 95%，可能空间不足！${NC}"
        read -p "按回车继续，或 Ctrl+C 取消..."
    fi
else
    echo -e "${YELLOW}无法读取 E 盘空间信息${NC}"
fi

# ==================== 配置 HuggingFace 缓存路径 ====================
echo ""
echo "[3/6] 配置 HuggingFace 缓存路径（模型权重存到 E 盘，避免 C 盘混乱）..."

mkdir -p /mnt/e/HuggingFace/Cache

if ! grep -q "HF_HOME" ~/.bashrc 2>/dev/null; then
    echo 'export HF_HOME=/mnt/e/HuggingFace/Cache' >> ~/.bashrc
    echo -e "${GREEN}已添加 HF_HOME 到 ~/.bashrc${NC}"
else
    echo -e "${YELLOW}HF_HOME 已存在，跳过${NC}"
fi

if ! grep -q "HF_ENDPOINT" ~/.bashrc 2>/dev/null; then
    echo 'export HF_ENDPOINT=https://hf-mirror.com' >> ~/.bashrc
    echo -e "${GREEN}已添加 HF_ENDPOINT 到 ~/.bashrc${NC}"
else
    echo -e "${YELLOW}HF_ENDPOINT 已存在，跳过${NC}"
fi

# 让当前 shell 也生效
export HF_HOME=/mnt/e/HuggingFace/Cache
export HF_ENDPOINT=https://hf-mirror.com

echo "HF_HOME: $HF_HOME (所有 HuggingFace 缓存将存到这里)"
echo "HF_ENDPOINT: $HF_ENDPOINT (镜像站)"

# ==================== 创建目录结构 ====================
echo ""
echo "[4/6] 创建项目目录结构..."

mkdir -p "$PROJECT_ROOT"/{models,data,results,eval_code,scripts,configs}

echo -e "${GREEN}目录结构创建完成:${NC}"
tree -L 1 "$PROJECT_ROOT" 2>/dev/null || find "$PROJECT_ROOT" -maxdepth 1 -type d | sort

# ==================== 复制脚本和配置 ====================
echo ""
echo "[5/6] 检查是否已下载配套脚本..."

# 检查当前目录是否有输出包文件
SCRIPT_SOURCE=""
if [ -f "run_from_config.py" ]; then
    SCRIPT_SOURCE="."
elif [ -f "/mnt/agents/output/run_from_config.py" ]; then
    SCRIPT_SOURCE="/mnt/agents/output"
fi

if [ -n "$SCRIPT_SOURCE" ]; then
    echo "发现配套脚本，复制到项目目录..."
    cp "$SCRIPT_SOURCE/run_from_config.py" "$SCRIPTS_DIR/" 2>/dev/null || true
    cp "$SCRIPT_SOURCE/run_inference_universal.py" "$SCRIPTS_DIR/" 2>/dev/null || true
    cp "$SCRIPT_SOURCE/batch_evaluate.sh" "$SCRIPTS_DIR/" 2>/dev/null || true
    cp "$SCRIPT_SOURCE/extract_scores.py" "$SCRIPTS_DIR/" 2>/dev/null || true
    cp "$SCRIPT_SOURCE/compare_with_paper.py" "$SCRIPTS_DIR/" 2>/dev/null || true
    cp "$SCRIPT_SOURCE/check_env.sh" "$PROJECT_ROOT/" 2>/dev/null || true
    cp "$SCRIPT_SOURCE/setup_eriq_project.sh" "$PROJECT_ROOT/" 2>/dev/null || true
    cp "$SCRIPT_SOURCE"/*.yaml "$CONFIGS_DIR/" 2>/dev/null || true
    echo -e "${GREEN}脚本和配置已复制${NC}"
else
    echo -e "${YELLOW}未找到配套脚本文件，你需要手动复制到以下目录:${NC}"
    echo "  推理脚本 -> $SCRIPTS_DIR/"
    echo "  模型配置 -> $CONFIGS_DIR/"
    echo "  评测脚本 -> $PROJECT_ROOT/eval_code/"
fi

# ==================== 下载 ERIQ 评测代码 ====================
echo ""
echo "[6/6] 下载 ERIQ 官方评测代码..."

if [ ! -f "$PROJECT_ROOT/eval_code/eval_hf.py" ]; then
    echo "从 GitHub 克隆评测代码..."
    if git clone --depth 1 https://github.com/GenieReasoner/ERIQ.git /tmp/eriq-repo 2>/dev/null; then
        cp /tmp/eriq-repo/eval_code/* "$PROJECT_ROOT/eval_code/"
        cp /tmp/eriq-repo/subtasks.yaml "$PROJECT_ROOT/"
        rm -rf /tmp/eriq-repo
        echo -e "${GREEN}评测代码下载完成${NC}"
    else
        echo -e "${YELLOW}git clone 失败，尝试 wget 下载单个文件...${NC}"
        wget -q "https://raw.githubusercontent.com/GenieReasoner/ERIQ/main/eval_code/eval_hf.py" -O "$PROJECT_ROOT/eval_code/eval_hf.py" 2>/dev/null || true
        wget -q "https://raw.githubusercontent.com/GenieReasoner/ERIQ/main/subtasks.yaml" -O "$PROJECT_ROOT/subtasks.yaml" 2>/dev/null || true
        wget -q "https://raw.githubusercontent.com/GenieReasoner/ERIQ/main/eval_code/example.json" -O "$PROJECT_ROOT/eval_code/example.json" 2>/dev/null || true
    fi
else
    echo -e "${GREEN}评测代码已存在${NC}"
fi

# ==================== 完成 ====================
echo ""
echo "=========================================="
echo "  E盘项目初始化完成！"
echo "=========================================="
echo ""
echo "项目根目录: $PROJECT_ROOT"
echo ""

# 显示目录树
echo "当前目录结构:"
tree -L 2 "$PROJECT_ROOT" 2>/dev/null || find "$PROJECT_ROOT" -maxdepth 2 | sort | sed 's|^/mnt/e/Projects/eriq-eval/|. |'

echo ""
echo "下一步操作:"
echo ""
echo "  1. 进入项目目录:"
echo "     cd $PROJECT_ROOT"
echo ""
echo "  2. 下载 ERIQ 数据集 (约 4GB):"
echo "     cd $PROJECT_ROOT/data"
echo "     hf download --repo-type dataset KineMind/ERIQ --local-dir ."
echo ""
echo "  3. 检查环境:"
echo "     bash $PROJECT_ROOT/check_env.sh"
echo ""
echo "  4. 运行推理（示例）:"
echo "     cd $PROJECT_ROOT"
echo "     python scripts/run_from_config.py --config configs/qwen2.5-vl-3b.yaml --limit 10"
echo ""
echo "  5. Windows 侧直接访问项目文件:"
echo "     资源管理器地址栏输入: E:\\Projects\\eriq-eval"
echo ""
echo "=========================================="
echo ""
echo "缓存路径说明:"
echo "  - HF_HOME=/mnt/e/HuggingFace/Cache (所有 HuggingFace 下载的缓存都在 E 盘)"
echo "  - HF_ENDPOINT=https://hf-mirror.com (国内镜像站)"
echo ""
echo "性能提示:"
echo "  - 数据集在 E 盘，推理时跨系统读取有约 10~20% I/O 损耗"
echo "  - 如需极致性能，可将 data/ 通过软链接放到 WSL 内部 ext4:"
echo "      mkdir -p ~/Datasets/ERIQ && ln -s ~/Datasets/ERIQ $PROJECT_ROOT/data"
echo "  - 模型权重缓存到 E 盘，不占 C 盘空间"
echo ""
echo "=========================================="
