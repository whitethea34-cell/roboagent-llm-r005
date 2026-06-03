#!/bin/bash
# ============================================================
# ERIQ 项目一键初始化脚本 (WSL2 + RTX 4090)
# 功能：
#   1. 创建标准项目目录结构
#   2. 配置 conda 环境（如果不存在则创建）
#   3. 安装 PyTorch + 核心依赖（使用镜像站）
#   4. 配置 HuggingFace 国内镜像
#   5. 下载 ERIQ 评测代码
# 使用方法：
#   chmod +x setup_eriq_project.sh
#   bash setup_eriq_project.sh
# ============================================================

set -e  # 遇到错误立即退出

echo "=========================================="
echo "  ERIQ 项目一键初始化"
echo "=========================================="

# 颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_ROOT="/mnt/e/Projects/eriq-eval"
CONDA_ENV_NAME="eriq"
PYTHON_VERSION="3.10"

echo ""
echo "项目将创建在: $PROJECT_ROOT"
echo "Conda 环境: $CONDA_ENV_NAME (Python $PYTHON_VERSION)"
echo ""
read -p "按回车继续，或按 Ctrl+C 取消..."
echo ""

# ==================== Step 1: 检查 conda ====================
echo "[1/6] 检查 Miniconda/Anaconda..."

if ! command -v conda &> /dev/null; then
    echo -e "${RED}未检测到 conda！${NC}"
    echo "正在为你下载并安装 Miniconda..."
    
    cd ~
    if [ ! -f "Miniconda3-latest-Linux-x86_64.sh" ]; then
        wget https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/Miniconda3-latest-Linux-x86_64.sh
    fi
    
    bash Miniconda3-latest-Linux-x86_64.sh -b -p "$HOME/miniconda3"
    
    # 初始化
    "$HOME/miniconda3/bin/conda" init bash
    
    echo -e "${YELLOW}Miniconda 安装完成！请关闭并重新打开终端，然后重新运行此脚本。${NC}"
    exit 0
else
    echo -e "${GREEN}Conda 已安装: $(conda --version)${NC}"
fi

# ==================== Step 2: 创建/激活环境 ====================
echo ""
echo "[2/6] 配置 Conda 环境 '$CONDA_ENV_NAME'..."

if conda env list | grep -q "^${CONDA_ENV_NAME} "; then
    echo -e "${GREEN}环境 '$CONDA_ENV_NAME' 已存在${NC}"
else
    echo "创建新环境 '$CONDA_ENV_NAME' (Python $PYTHON_VERSION)..."
    conda create -n "$CONDA_ENV_NAME" python="$PYTHON_VERSION" -y
    echo -e "${GREEN}环境创建完成${NC}"
fi

# 激活环境（在脚本中需要使用 source）
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV_NAME"

echo -e "${GREEN}当前环境: $(conda info --envs | grep '^\*' | awk '{print $1}')${NC}"

# ==================== Step 3: 配置镜像源 ====================
echo ""
echo "[3/6] 配置国内镜像源..."

# Conda 清华镜像
conda config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/free/ 2>/dev/null || true
conda config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main/ 2>/dev/null || true
conda config --set show_channel_urls yes 2>/dev/null || true

# PyPI 阿里镜像（写入 pip 配置）
mkdir -p "$HOME/.config/pip"
cat > "$HOME/.config/pip/pip.conf" << 'EOF'
[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
trusted-host = mirrors.aliyun.com

[install]
use-pep517 = true
EOF

echo -e "${GREEN}镜像源配置完成${NC}"

# HuggingFace 镜像和缓存路径
if ! grep -q "HF_ENDPOINT" "$HOME/.bashrc" 2>/dev/null; then
    echo 'export HF_ENDPOINT=https://hf-mirror.com' >> "$HOME/.bashrc"
    echo -e "${GREEN}已添加 HF_ENDPOINT 到 ~/.bashrc${NC}"
fi
export HF_ENDPOINT=https://hf-mirror.com

# 默认把 HuggingFace 缓存放到家目录（如果用户想用 E 盘，运行 setup_e_drive.sh 时会覆盖）
if ! grep -q "HF_HOME" "$HOME/.bashrc" 2>/dev/null; then
    echo 'export HF_HOME=/mnt/e/HuggingFace/Cache' >> "$HOME/.bashrc"
    echo -e "${GREEN}已添加 HF_HOME 到 ~/.bashrc (缓存将存到 E 盘)${NC}"
fi
export HF_HOME=/mnt/e/HuggingFace/Cache
mkdir -p "$HF_HOME"

# ==================== Step 4: 安装 PyTorch ====================
echo ""
echo "[4/6] 安装 PyTorch (CUDA 12.1 版本)..."

pip install --upgrade pip

# 检测 CUDA 版本并选择对应 PyTorch
if command -v nvidia-smi &> /dev/null; then
    CUDA_VERSION=$(nvidia-smi | grep "CUDA Version:" | sed 's/.*CUDA Version: //' | awk '{print $1}')
    echo "检测到 GPU 支持的最高 CUDA 版本: $CUDA_VERSION"
    
    if [[ "$CUDA_VERSION" == 12.* ]]; then
        PYTORCH_URL="https://download.pytorch.org/whl/cu121"
        echo "安装 PyTorch for CUDA 12.1..."
    else
        PYTORCH_URL="https://download.pytorch.org/whl/cu118"
        echo "安装 PyTorch for CUDA 11.8..."
    fi
else
    echo -e "${YELLOW}警告: 未检测到 nvidia-smi，将安装 CPU 版 PyTorch${NC}"
    PYTORCH_URL="https://download.pytorch.org/whl/cpu"
fi

pip install torch torchvision torchaudio --index-url "$PYTORCH_URL"

echo -e "${GREEN}PyTorch 安装完成${NC}"

# ==================== Step 5: 安装核心依赖 ====================
echo ""
echo "[5/6] 安装核心依赖库..."

pip install transformers accelerate sentencepiece \
    pillow opencv-python tabulate huggingface-hub tqdm pyyaml

echo -e "${GREEN}依赖库安装完成${NC}"

# ==================== Step 6: 创建项目目录 ====================
echo ""
echo "[6/6] 创建项目目录结构..."

mkdir -p "$PROJECT_ROOT"/{models,data,results,eval_code,scripts}

# 下载 ERIQ 评测代码
echo "下载 ERIQ 评测代码..."
if [ ! -f "$PROJECT_ROOT/eval_code/eval_hf.py" ]; then
    git clone --depth 1 https://github.com/GenieReasoner/ERIQ.git /tmp/eriq-repo 2>/dev/null || {
        echo -e "${YELLOW}git clone 失败，尝试用 wget 下载...${NC}"
        wget -q https://raw.githubusercontent.com/GenieReasoner/ERIQ/main/eval_code/eval_hf.py -O "$PROJECT_ROOT/eval_code/eval_hf.py" || true
        wget -q https://raw.githubusercontent.com/GenieReasoner/ERIQ/main/subtasks.yaml -O "$PROJECT_ROOT/subtasks.yaml" || true
    }
    
    if [ -d "/tmp/eriq-repo" ]; then
        cp /tmp/eriq-repo/eval_code/* "$PROJECT_ROOT/eval_code/"
        cp /tmp/eriq-repo/subtasks.yaml "$PROJECT_ROOT/"
        rm -rf /tmp/eriq-repo
    fi
fi

echo -e "${GREEN}目录结构创建完成${NC}"

# ==================== 完成总结 ====================
echo ""
echo "=========================================="
echo "  初始化完成！"
echo "=========================================="
echo ""
echo "项目目录: $PROJECT_ROOT"
echo ""
echo "目录结构:"
tree -L 2 "$PROJECT_ROOT" 2>/dev/null || find "$PROJECT_ROOT" -maxdepth 2 -print | sed 's|^\t||'

echo ""
echo "下一步操作:"
echo ""
echo "  1. 激活环境:"
echo "     conda activate eriq"
echo ""
echo "  2. 下载 ERIQ 数据集 (约 4GB):"
echo "     cd $PROJECT_ROOT/data"
echo "     hf download KineMind/ERIQ --local-dir ."
echo ""
echo "  3. 验证 GPU:"
echo "     python -c \"import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))\""
echo ""
echo "  4. 运行推理（需先准备推理脚本）:"
echo "     python scripts/run_inference_qwen.py"
echo ""
echo "  5. 评测打分:"
echo "     python eval_code/eval_hf.py results/xxx_predictions.json"
echo ""
echo "=========================================="

# 最后验证
conda activate eriq
python -c "
import torch
print('PyTorch:', torch.__version__)
print('CUDA available:', torch.cuda.is_available())
if torch.cuda.is_available():
    print('GPU:', torch.cuda.get_device_name(0))
    print('VRAM:', f'{torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB')
"
