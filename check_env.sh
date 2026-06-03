#!/bin/bash
# ============================================================
# ERIQ 环境一键检查脚本
# 用途：在 WSL2 + RTX 4090 环境中快速验证所有依赖是否正常
# 使用方法：
#   1. 保存为 check_env.sh
#   2. chmod +x check_env.sh
#   3. bash check_env.sh
# ============================================================

echo "=========================================="
echo "  ERIQ 评测环境检查脚本"
echo "  时间: $(date)"
echo "=========================================="
echo ""

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
FAIL=0
WARN=0

check_pass() {
    echo -e "${GREEN}  [PASS]${NC} $1"
    ((PASS++))
}

check_fail() {
    echo -e "${RED}  [FAIL]${NC} $1"
    ((FAIL++))
}

check_warn() {
    echo -e "${YELLOW}  [WARN]${NC} $1"
    ((WARN++))
}

# ==================== [1] WSL2 基础环境 ====================
echo "[1/8] WSL2 基础环境检查"

if grep -q "microsoft" /proc/version 2>/dev/null; then
    check_pass "当前在 WSL2 环境中"
else
    check_warn "似乎不在 WSL2 中（可能是原生 Linux 或其他环境）"
fi

UBUNTU_VERSION=$(lsb_release -d 2>/dev/null | awk -F$'\t' '{print $2}')
if [ -n "$UBUNTU_VERSION" ]; then
    check_pass "Linux 发行版: $UBUNTU_VERSION"
else
    check_warn "无法检测发行版版本"
fi
echo ""

# ==================== [2] Conda 环境 ====================
echo "[2/8] Conda 环境检查"

if command -v conda &> /dev/null; then
    CONDA_VERSION=$(conda --version 2>/dev/null)
    check_pass "Conda 已安装: $CONDA_VERSION"
else
    check_fail "Conda 未安装！请按手册安装 Miniconda"
    echo "      修复: wget https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/Miniconda3-latest-Linux-x86_64.sh"
fi

# 检查当前是否激活了 eriq 环境
if [ "$CONDA_DEFAULT_ENV" == "eriq" ]; then
    check_pass "当前已激活 eriq 环境"
else
    check_warn "当前环境是 '$CONDA_DEFAULT_ENV'，建议运行: conda activate eriq"
fi

# 检查 eriq 环境是否存在
if conda env list 2>/dev/null | grep -q "eriq"; then
    check_pass "eriq 环境已创建"
else
    check_fail "eriq 环境不存在！请运行: conda create -n eriq python=3.10 -y"
fi
echo ""

# ==================== [3] GPU 与 CUDA ====================
echo "[3/8] GPU 与 CUDA 检查"

if command -v nvidia-smi &> /dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)
    if [ -n "$GPU_INFO" ]; then
        check_pass "GPU 识别正常: $GPU_INFO"
        
        # 显存检查
        GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ')
        if [ "$GPU_MEM" -gt 20000 ] 2>/dev/null; then
            check_pass "显存充足: ${GPU_MEM}MiB (>= 20GB，符合 4090 特征)"
        else
            check_warn "显存 ${GPU_MEM}MiB，可能不是 4090 或未正确识别"
        fi
    else
        check_fail "nvidia-smi 存在但无法识别 GPU！请重启 WSL2: wsl --shutdown"
    fi
else
    check_fail "nvidia-smi 未找到！请在 Windows 安装 NVIDIA 驱动"
fi

if command -v nvcc &> /dev/null; then
    CUDA_VERSION=$(nvcc --version 2>/dev/null | grep "release" | sed 's/.*release //' | sed 's/,.*//')
    check_pass "CUDA Toolkit 已安装: $CUDA_VERSION"
else
    check_warn "nvcc 未找到（CUDA Toolkit 可能未安装）"
    echo "      注意: WSL2 中 PyTorch 可通过 wheel 包自带 CUDA runtime，不装 nvcc 也能跑"
fi
echo ""

# ==================== [4] Python 与 PyTorch ====================
echo "[4/8] Python 与 PyTorch 检查"

PYTHON_PATH=$(which python 2>/dev/null)
if [ -n "$PYTHON_PATH" ]; then
    PYTHON_VERSION=$(python --version 2>&1)
    check_pass "Python: $PYTHON_VERSION ($PYTHON_PATH)"
else
    check_fail "Python 未找到！"
fi

# PyTorch 检查
PYTORCH_INFO=$(python -c "
import torch
print(f'{torch.__version__}|{torch.cuda.is_available()}|{torch.version.cuda if torch.cuda.is_available() else \"N/A\"}|{torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"N/A\"}')
" 2>/dev/null)

if [ -n "$PYTORCH_INFO" ]; then
    PT_VERSION=$(echo "$PYTORCH_INFO" | cut -d'|' -f1)
    PT_CUDA_AVAIL=$(echo "$PYTORCH_INFO" | cut -d'|' -f2)
    PT_CUDA_VER=$(echo "$PYTORCH_INFO" | cut -d'|' -f3)
    PT_GPU_NAME=$(echo "$PYTORCH_INFO" | cut -d'|' -f4)
    
    check_pass "PyTorch 已安装: $PT_VERSION"
    
    if [ "$PT_CUDA_AVAIL" == "True" ]; then
        check_pass "PyTorch CUDA 可用"
        check_pass "PyTorch 编译时 CUDA 版本: $PT_CUDA_VER"
        check_pass "PyTorch 识别 GPU: $PT_GPU_NAME"
        
        # 显存检查
        PT_MEM=$(python -c "import torch; print(int(torch.cuda.get_device_properties(0).total_memory / 1024**3))" 2>/dev/null)
        if [ -n "$PT_MEM" ]; then
            check_pass "PyTorch 识别显存: ${PT_MEM}GB"
        fi
    else
        check_fail "PyTorch CUDA 不可用！模型将使用 CPU 推理，速度极慢"
        echo "      修复: 重新安装 CUDA 版 PyTorch:"
        echo "      pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121"
    fi
else
    check_fail "PyTorch 未安装！"
    echo "      修复: conda activate eriq && pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121"
fi
echo ""

# ==================== [5] 关键依赖库 ====================
echo "[5/8] 关键依赖库检查"

LIBS=("transformers" "accelerate" "PIL" "tabulate" "yaml")
for lib in "${LIBS[@]}"; do
    RESULT=$(python -c "import $lib; print('OK')" 2>/dev/null)
    if [ "$RESULT" == "OK" ]; then
        check_pass "Python 库 $lib 已安装"
    else
        check_warn "Python 库 $lib 未安装（某些模型可能不需要）"
    fi
done

# 检查 huggingface_hub 和 hf 命令
HF_OK=$(python -c "import huggingface_hub; print('OK')" 2>/dev/null)
if [ "$HF_OK" == "OK" ]; then
    check_pass "huggingface_hub 已安装"
else
    check_warn "huggingface_hub 未安装（新版 transformers 通常已自带）"
fi

# 检查新版 hf CLI
if command -v hf &> /dev/null; then
    check_pass "hf 命令行工具已安装"
else
    check_warn "hf 命令未找到！数据集下载需要用 'hf download'"
    echo "      修复: pip install --upgrade huggingface-hub"
fi
echo ""

# ==================== [6] HuggingFace 镜像配置 ====================
echo "[6/8] HuggingFace 配置检查"

if [ -n "$HF_ENDPOINT" ]; then
    check_pass "HF_ENDPOINT 已设置: $HF_ENDPOINT"
    if echo "$HF_ENDPOINT" | grep -q "mirror"; then
        check_pass "已配置国内镜像站"
    fi
else
    check_warn "HF_ENDPOINT 未设置！国内可能无法下载模型"
    echo "      修复: echo 'export HF_ENDPOINT=https://hf-mirror.com' >> ~/.bashrc && source ~/.bashrc"
fi

if [ -n "$HF_HOME" ]; then
    check_pass "HF_HOME 已设置: $HF_HOME (HuggingFace 缓存目录)"
    if [ -d "$HF_HOME" ]; then
        CACHE_SIZE=$(du -sh "$HF_HOME" 2>/dev/null | cut -f1)
        check_pass "缓存目录存在，当前占用: $CACHE_SIZE"
    fi
else
    check_warn "HF_HOME 未设置！模型权重将缓存到默认路径 ~/.cache/huggingface/"
    echo "      建议: echo 'export HF_HOME=/mnt/e/HuggingFace/Cache' >> ~/.bashrc"
fi
echo ""

# ==================== [7] ERIQ 项目文件 ====================
echo "[7/8] ERIQ 项目文件检查"

PROJECT_DIR="/mnt/e/Projects/eriq-eval"

if [ -d "$PROJECT_DIR" ]; then
    check_pass "项目目录存在: $PROJECT_DIR"
else
    check_fail "项目目录不存在！请按手册创建目录结构"
fi

# 检查数据文件
if [ -d "$PROJECT_DIR/data" ]; then
    JSON_COUNT=$(ls "$PROJECT_DIR/data"/QA_*.json 2>/dev/null | wc -l)
    if [ "$JSON_COUNT" -eq 15 ]; then
        check_pass "ERIQ 数据 JSON 文件完整: 15/15"
    else
        check_warn "ERIQ JSON 文件: $JSON_COUNT/15，可能未完全下载"
    fi
    
    if [ -d "$PROJECT_DIR/data/images" ]; then
        IMG_COUNT=$(ls "$PROJECT_DIR/data/images"/*.jpg 2>/dev/null | wc -l)
        if [ "$IMG_COUNT" -gt 0 ]; then
            check_pass "图片目录存在，图片数量: $IMG_COUNT"
        else
            check_warn "图片目录为空，需要下载数据集"
        fi
    else
        check_warn "图片目录不存在"
    fi
else
    check_warn "data 目录不存在"
fi

# 检查评测脚本
if [ -f "$PROJECT_DIR/eval_code/eval_hf.py" ]; then
    check_pass "官方评测脚本 eval_hf.py 已就绪"
else
    check_warn "eval_hf.py 未找到"
fi
echo ""

# ==================== [8] 磁盘空间 ====================
echo "[8/8] 磁盘空间检查"

# 检查 WSL2 根分区
ROOT_USAGE=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
if [ -n "$ROOT_USAGE" ]; then
    if [ "$ROOT_USAGE" -lt 80 ]; then
        check_pass "根分区使用率: ${ROOT_USAGE}% (< 80%，空间充足)"
    elif [ "$ROOT_USAGE" -lt 95 ]; then
        check_warn "根分区使用率: ${ROOT_USAGE}% (建议清理空间)"
    else
        check_fail "根分区使用率: ${ROOT_USAGE}% (空间严重不足！)"
    fi
fi

# 检查家目录所在分区
HOME_USAGE=$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
if [ -n "$HOME_USAGE" ] && [ "$HOME" != "/" ]; then
    if [ "$HOME_USAGE" -lt 80 ]; then
        check_pass "家目录使用率: ${HOME_USAGE}%"
    else
        check_warn "家目录使用率: ${HOME_USAGE}%"
    fi
fi
echo ""

# ==================== 总结 ====================
echo "=========================================="
echo "  检查完成"
echo "  通过: $PASS  警告: $WARN  失败: $FAIL"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo -e "${RED}存在 $FAIL 项失败，请先修复后再运行评测！${NC}"
    echo "查看上方 [FAIL] 标记的条目，按照修复建议操作。"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}有 $WARN 项警告，评测可能可以运行但建议优化。${NC}"
    exit 0
else
    echo ""
    echo -e "${GREEN}所有检查全部通过！环境准备就绪，可以开始 ERIQ 评测。${NC}"
    echo ""
    echo "下一步建议:"
    echo "  1. 确保在 eriq 环境中: conda activate eriq"
    echo "  2. 进入项目目录: cd /mnt/e/Projects/eriq-eval"
    echo "  3. 运行推理脚本: python scripts/run_inference_qwen.py"
    exit 0
fi
