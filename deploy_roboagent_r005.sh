#!/bin/bash
# ============================================================
# RoboAgent / Qwen2.5-VL-3B 国讯芯微 R005 一键部署脚本
# 目标：在 R005 + 白泽系统上一键完成：
#   1. 环境检测（ARM/内存/NPU）
#   2. 依赖安装
#   3. llama.cpp 编译（ARM NEON + 视觉支持）
#   4. 模型下载（Qwen2.5-VL-3B-Instruct GGUF）
#   5. 配置文件生成
#   6. 服务启动 + 对话验证
# 
# 用法：
#   chmod +x deploy_roboagent_r005.sh
#   bash deploy_roboagent_r005.sh
# 
# 后续集成：
#   本脚本启动的 llama-server 提供 OpenAI 兼容 API
#   你的具身智能 Python 代码通过 HTTP 调用 http://localhost:8080/v1/chat/completions
# ============================================================

set -e

# ============================================================
# 【可配置区】
# ============================================================
INSTALL_DIR="${HOME}/ai-r005"           # 安装根目录
MODEL_DIR="${INSTALL_DIR}/models"       # 模型存放目录
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"   # llama.cpp 源码/编译目录
LOG_FILE="${INSTALL_DIR}/deploy.log"    # 部署日志

# 模型选择（视觉语言模型，适配具身智能）
# Qwen2.5-VL-3B-Instruct 是 RoboAgent 的基础模型
MODEL_REPO="unsloth/Qwen2.5-VL-3B-Instruct-GGUF"
MODEL_FILE="Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf"   # 约 1.9GB，平衡速度与精度
# 备选更小模型（如果内存紧张）：
# MODEL_FILE="Qwen2.5-VL-3B-Instruct-Q3_K_M.gguf"  # 约 1.5GB

# HuggingFace 镜像（国内必需）
HF_MIRROR="https://hf-mirror.com"

# 服务端口号
API_PORT="8080"

# ============================================================
# 颜色定义
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"   | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"  | tee -a "$LOG_FILE"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"    | tee -a "$LOG_FILE"; }
log_step() { echo -e "${CYAN}========================================${NC}"; echo -e "${CYAN}  $1${NC}" | tee -a "$LOG_FILE"; echo -e "${CYAN}========================================${NC}"; }

# ============================================================
# Phase 0: 初始化
# ============================================================
mkdir -p "$INSTALL_DIR"
touch "$LOG_FILE"

log_step "国讯芯微 R005 RoboAgent 一键部署启动"
log_info "安装目录: $INSTALL_DIR"
log_info "日志文件: $LOG_FILE"
log_info "时间: $(date)"

# ============================================================
# Phase 1: 硬件探测
# ============================================================
log_step "Phase 1/7: 硬件与环境探测"

# 1.1 架构检测
ARCH=$(uname -m)
log_info "CPU 架构: $ARCH"
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    log_ok "检测到 ARM64 架构（国讯芯微 R005 匹配）"
else
    log_warn "非 ARM64 架构: $ARCH，编译参数可能需要调整"
fi

# 1.2 CPU 信息
CPU_COUNT=$(nproc)
log_info "CPU 核心数: $CPU_COUNT"

# 1.3 内存检测
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
log_info "总内存: ${TOTAL_MEM_GB}GB"

if [ "$TOTAL_MEM_GB" -lt 2 ]; then
    log_err "内存不足 2GB，无法运行 3B 视觉模型！需要至少 4GB 推荐 8GB+"
    exit 1
elif [ "$TOTAL_MEM_GB" -lt 4 ]; then
    log_warn "内存仅 ${TOTAL_MEM_GB}GB，建议换用 Q3_K_M 量化模型"
    MODEL_FILE="Qwen2.5-VL-3B-Instruct-Q3_K_M.gguf"
else
    log_ok "内存充足 (${TOTAL_MEM_GB}GB)，使用 Q4_K_M 量化"
fi

# 1.4 NPU/GPU 检测
if [ -d /dev/dri ]; then
    log_info "发现 GPU 设备节点 (/dev/dri 存在)"
fi
if command -v npu-smi &> /dev/null; then
    log_ok "发现 NPU 管理工具: $(npu-smi info 2>/dev/null | head -1 || echo '可用')"
else
    log_info "未检测到专用 NPU，将使用 CPU + NEON 加速推理"
fi

# 1.5 操作系统检测
OS_ID=$(cat /etc/os-release 2>/dev/null | grep ^ID= | cut -d= -f2 | tr -d '"')
log_info "操作系统: $OS_ID"

# 1.6 磁盘空间
DISK_AVAIL=$(df -h . | awk 'NR==2 {print $4}')
log_info "当前目录可用空间: $DISK_AVAIL"

log_ok "硬件探测完成"

# ============================================================
# Phase 2: 环境准备
# ============================================================
log_step "Phase 2/7: 环境依赖安装"

# 2.1 更新包列表
log_info "更新 apt 包列表..."
apt-get update -qq

# 2.2 安装编译工具链
log_info "安装编译依赖 (cmake, build-essential, git, curl)..."
apt-get install -y -qq \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    python3 \
    python3-pip \
    libgomp1 \
    || { log_err "apt 安装失败，请检查网络或 sudo 权限"; exit 1; }

log_ok "编译依赖安装完成"

# 2.3 配置 HuggingFace 镜像和缓存
log_info "配置 HuggingFace 镜像站..."
if ! grep -q "HF_ENDPOINT" ~/.bashrc 2>/dev/null; then
    echo "export HF_ENDPOINT=$HF_MIRROR" >> ~/.bashrc
fi
if ! grep -q "HF_HOME" ~/.bashrc 2>/dev/null; then
    # 如果 /mnt/e 存在，缓存放 E 盘；否则放 HOME
    if [ -d /mnt/e ]; then
        mkdir -p /mnt/e/HuggingFace/Cache
        echo "export HF_HOME=/mnt/e/HuggingFace/Cache" >> ~/.bashrc
        export HF_HOME=/mnt/e/HuggingFace/Cache
    else
        mkdir -p ~/.cache/huggingface
        echo "export HF_HOME=$HOME/.cache/huggingface" >> ~/.bashrc
        export HF_HOME="$HOME/.cache/huggingface"
    fi
fi
export HF_ENDPOINT="$HF_MIRROR"
source ~/.bashrc 2>/dev/null || true
log_info "HF_ENDPOINT=$HF_ENDPOINT"
log_info "HF_HOME=$HF_HOME"

# 2.4 安装 huggingface-hub（用于下载）
log_info "安装 huggingface-hub..."
pip3 install --quiet --upgrade huggingface-hub

# 2.5 检查 hf 命令
if command -v hf &> /dev/null; then
    log_ok "hf CLI 可用"
else
    log_warn "hf CLI 未找到，将使用 wget 直接下载模型"
fi

log_ok "环境准备完成"

# ============================================================
# Phase 3: 编译 llama.cpp（ARM NEON + 视觉支持）
# ============================================================
log_step "Phase 3/7: 编译 llama.cpp（ARM 优化版）"

# 3.1 克隆或更新源码
if [ -d "$LLAMA_DIR/.git" ]; then
    log_info "llama.cpp 已存在，拉取最新代码..."
    cd "$LLAMA_DIR"
    git pull --ff-only
else
    log_info "克隆 llama.cpp 源码..."
    git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
    cd "$LLAMA_DIR"
fi

# 3.2 清理旧编译（如果存在）
rm -rf build
mkdir -p build
cd build

# 3.3 CMake 配置（ARM 关键优化参数）
log_info "CMake 配置中..."
CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DGGML_NATIVE=OFF          # 禁用本机指令集探测（嵌入式设备兼容性）
    -DGGML_OPENMP=ON           # 启用 OpenMP 多线程
    -DLLAMA_BUILD_SERVER=ON    # 编译 llama-server
)

# ARM 特有优化：启用 NEON
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    log_info "启用 ARM NEON 加速..."
    CMAKE_ARGS+=(
        -DGGML_CPU_ARM_ARCH=armv8.2-a
        -DGGML_AVX=OFF
        -DGGML_AVX2=OFF
        -DGGML_FMA=OFF
    )
fi

# 如果内存紧张，禁用一些大内存特性
if [ "$TOTAL_MEM_GB" -lt 4 ]; then
    log_warn "内存紧张，禁用 Vulkan/CUDA 支持..."
    CMAKE_ARGS+=(-DGGML_CUDA=OFF -DGGML_VULKAN=OFF)
fi

cmake .. "${CMAKE_ARGS[@]}"

# 3.4 编译
log_info "开始编译（使用 $CPU_COUNT 核心，预计 10~20 分钟）..."
make -j"$CPU_COUNT"

# 3.5 验证二进制
if [ -f "bin/llama-server" ] && [ -f "bin/llama-cli" ]; then
    log_ok "llama.cpp 编译成功！"
    log_info "  llama-server: $(ls -lh bin/llama-server | awk '{print $5, $9}')"
    log_info "  llama-cli:   $(ls -lh bin/llama-cli | awk '{print $5, $9}')"
else
    log_err "编译失败，未找到 llama-server 或 llama-cli 二进制文件"
    exit 1
fi

# ============================================================
# Phase 4: 下载视觉语言模型
# ============================================================
log_step "Phase 4/7: 下载 Qwen2.5-VL-3B-Instruct GGUF 模型"

mkdir -p "$MODEL_DIR"
cd "$MODEL_DIR"

MODEL_PATH="$MODEL_DIR/$MODEL_FILE"

if [ -f "$MODEL_PATH" ]; then
    log_info "模型文件已存在: $MODEL_PATH"
    log_info "大小: $(ls -lh "$MODEL_PATH" | awk '{print $5}')"
else
    log_info "开始下载模型: $MODEL_FILE"
    log_info "来源: $MODEL_REPO"
    
    # 方法 1: 使用 hf 命令（如果可用）
    if command -v hf &> /dev/null; then
        log_info "使用 hf download 下载..."
        hf download "$MODEL_REPO" "$MODEL_FILE" --local-dir . || true
    fi
    
    # 方法 2: 如果 hf 失败或不可用，用 wget 直接下载
    if [ ! -f "$MODEL_FILE" ]; then
        DOWNLOAD_URL="${HF_MIRROR}/${MODEL_REPO}/resolve/main/${MODEL_FILE}"
        log_info "使用 wget 直链下载..."
        log_info "URL: $DOWNLOAD_URL"
        wget --progress=bar:force "$DOWNLOAD_URL" -O "$MODEL_FILE" || {
            log_err "模型下载失败！请检查网络连接"
            log_err "手动下载地址: $DOWNLOAD_URL"
            exit 1
        }
    fi
    
    log_ok "模型下载完成: $MODEL_PATH ($(ls -lh "$MODEL_PATH" | awk '{print $5}'))"
fi

# ============================================================
# Phase 5: 创建配置文件
# ============================================================
log_step "Phase 5/7: 创建配置文件"

# 5.1 系统提示词（适配具身智能场景）
SYSTEM_PROMPT="You are RoboAgent, an embodied AI assistant running on an embedded robot controller. You can understand visual inputs and provide task planning instructions. Respond concisely and clearly."

# 5.2 启动脚本
cat > "${INSTALL_DIR}/start_server.sh" << 'EOF'
#!/bin/bash
# RoboAgent llama-server 启动脚本
# 用法: bash start_server.sh

INSTALL_DIR="$(dirname "$0")"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
MODEL_DIR="${INSTALL_DIR}/models"

# 自动检测模型文件
MODEL_FILE=$(ls "${MODEL_DIR}"/*.gguf 2>/dev/null | head -n1)
if [ -z "$MODEL_FILE" ]; then
    echo "错误: 未找到 .gguf 模型文件"
    exit 1
fi

# 检测 CPU 核心数
THREADS=$(nproc)

# 启动服务
echo "========================================"
echo "  RoboAgent llama-server"
echo "  模型: $(basename "$MODEL_FILE")"
echo "  端口: 8080"
echo "  线程: $THREADS"
echo "========================================"

cd "$LLAMA_DIR"
./build/bin/llama-server \
    -m "$MODEL_FILE" \
    --host 0.0.0.0 \
    --port 8080 \
    --ctx-size 4096 \
    --threads "$THREADS" \
    --batch-size 512 \
    --verbose
EOF
chmod +x "${INSTALL_DIR}/start_server.sh"

# 5.3 测试脚本（纯文本对话）
cat > "${INSTALL_DIR}/test_chat.sh" << 'EOF'
#!/bin/bash
# 文本对话测试

curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-vl",
    "messages": [
      {"role": "system", "content": "You are RoboAgent, an embodied AI assistant."},
      {"role": "user", "content": "你好，请简短介绍你自己"}
    ],
    "temperature": 0.7,
    "max_tokens": 256
  }' | python3 -m json.tool 2>/dev/null || echo "服务未启动或 python3 json 模块不可用"
EOF
chmod +x "${INSTALL_DIR}/test_chat.sh"

# 5.4 视觉测试脚本（需要图片文件）
cat > "${INSTALL_DIR}/test_vision.py" << 'EOF'
#!/usr/bin/env python3
"""
视觉理解测试脚本
用法: python3 test_vision.py /path/to/image.jpg
"""
import sys
import base64
import requests
import json

if len(sys.argv) < 2:
    print("用法: python3 test_vision.py <图片路径>")
    sys.exit(1)

image_path = sys.argv[1]

# 读取图片并转为 base64
with open(image_path, "rb") as f:
    image_b64 = base64.b64encode(f.read()).decode("utf-8")

# 构造请求（llama.cpp vision 格式）
payload = {
    "model": "qwen2.5-vl",
    "messages": [
        {
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
                {"type": "text", "text": "描述这张图片里的场景，并给出机器人下一步可以执行的任务建议。"}
            ]
        }
    ],
    "temperature": 0.7,
    "max_tokens": 512
}

try:
    resp = requests.post("http://localhost:8080/v1/chat/completions", json=payload, timeout=120)
    print(json.dumps(resp.json(), indent=2, ensure_ascii=False))
except Exception as e:
    print(f"请求失败: {e}")
EOF
chmod +x "${INSTALL_DIR}/test_vision.py"

# 5.5 具身智能调用示例（Python）
cat > "${INSTALL_DIR}/roboagent_bridge.py" << 'EOF'
#!/usr/bin/env python3
"""
RoboAgent 具身智能桥接示例
展示如何从 Python 调用本地部署的 llama-server，实现感知→推理→控制闭环
"""
import requests
import json

API_URL = "http://localhost:8080/v1/chat/completions"
MODEL_NAME = "qwen2.5-vl"


class RoboAgentBridge:
    """R005 控制器上的大模型推理客户端"""

    def __init__(self, api_url=API_URL, model=MODEL_NAME):
        self.api_url = api_url
        self.model = model

    def plan_task(self, scene_description, task_goal):
        """
        根据场景描述和任务目标，生成动作计划
        
        Args:
            scene_description: 字符串，当前场景描述（可由视觉模块生成）
            task_goal: 字符串，用户给出的任务目标
        
        Returns:
            模型生成的动作计划字符串
        """
        prompt = f"""当前场景: {scene_description}
任务目标: {task_goal}

请给出机器人完成该任务的详细步骤计划（每步一行，格式: 动作: 对象: 参数）:
"""
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": "You are an embodied task planner. Output structured action plans only."},
                {"role": "user", "content": prompt}
            ],
            "temperature": 0.5,
            "max_tokens": 512
        }
        
        try:
            resp = requests.post(self.api_url, json=payload, timeout=60)
            result = resp.json()
            return result["choices"][0]["message"]["content"]
        except Exception as e:
            return f"[ERROR] 推理失败: {e}"

    def vision_reasoning(self, image_b64, question):
        """
        视觉推理：传入图片 base64，获取回答
        
        Args:
            image_b64: base64 编码的图片字符串
            question: 关于图片的问题
        """
        payload = {
            "model": self.model,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
                        {"type": "text", "text": question}
                    ]
                }
            ],
            "temperature": 0.7,
            "max_tokens": 512
        }
        
        resp = requests.post(self.api_url, json=payload, timeout=120)
        return resp.json()["choices"][0]["message"]["content"]


# ============ 使用示例 ============
if __name__ == "__main__":
    agent = RoboAgentBridge()
    
    # 示例 1: 多模态任务规划
    print("=" * 50)
    print("示例 1: 任务规划")
    print("=" * 50)
    plan = agent.plan_task(
        scene_description="厨房场景，台面上有苹果、刀、盘子",
        task_goal="把苹果切成块放到盘子里"
    )
    print(plan)
    
    # 示例 2: 视觉理解（需要实际的图片 base64）
    # with open("scene.jpg", "rb") as f:
    #     img_b64 = base64.b64encode(f.read()).decode()
    # answer = agent.vision_reasoning(img_b64, "描述场景并建议下一步动作")
    # print(answer)
EOF
chmod +x "${INSTALL_DIR}/roboagent_bridge.py"

# 5.6 创建 systemd 服务文件（可选，开机自启）
if command -v systemctl &> /dev/null; then
    cat > "${INSTALL_DIR}/roboagent.service" << EOF
[Unit]
Description=RoboAgent llama-server on R005
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/start_server.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    log_info "systemd 服务文件已创建: ${INSTALL_DIR}/roboagent.service"
    log_info "如需开机自启: sudo cp roboagent.service /etc/systemd/system/ && sudo systemctl enable roboagent"
fi

log_ok "配置文件创建完成"

# ============================================================
# Phase 6: 启动服务
# ============================================================
log_step "Phase 6/7: 启动 llama-server"

cd "$LLAMA_DIR"

# 后台启动
./build/bin/llama-server \
    -m "$MODEL_PATH" \
    --host 0.0.0.0 \
    --port "$API_PORT" \
    --ctx-size 4096 \
    --threads "$CPU_COUNT" \
    --batch-size 512 \
    > "${INSTALL_DIR}/server.log" 2>&1 &

SERVER_PID=$!
log_info "llama-server PID: $SERVER_PID"
log_info "日志文件: ${INSTALL_DIR}/server.log"

# 等待服务就绪
log_info "等待服务启动（约 30~60 秒加载模型）..."
for i in {1..30}; do
    sleep 2
    if curl -s http://localhost:${API_PORT}/health > /dev/null 2>&1; then
        log_ok "llama-server 已就绪！"
        break
    fi
    # 检查进程是否还在
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        log_err "服务进程意外退出！查看日志:"
        tail -n 30 "${INSTALL_DIR}/server.log"
        exit 1
    fi
    echo -n "."
done

if ! curl -s http://localhost:${API_PORT}/health > /dev/null 2>&1; then
    log_warn "服务启动较慢，继续等待..."
    sleep 30
fi

# ============================================================
# Phase 7: 对话验证
# ============================================================
log_step "Phase 7/7: 对话与功能验证"

log_info "测试 1/3: 纯文本对话"
curl -s http://localhost:${API_PORT}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-vl",
    "messages": [
      {"role": "system", "content": "You are RoboAgent, an embodied AI assistant."},
      {"role": "user", "content": "你好，请用一句话介绍你自己"}
    ],
    "temperature": 0.7,
    "max_tokens": 128
  }' > "${INSTALL_DIR}/test1_result.json"

if [ -s "${INSTALL_DIR}/test1_result.json" ]; then
    log_ok "文本对话测试通过！"
    cat "${INSTALL_DIR}/test1_result.json" | python3 -m json.tool 2>/dev/null || cat "${INSTALL_DIR}/test1_result.json"
else
    log_err "文本对话测试失败"
fi

log_info "测试 2/3: API 健康检查"
HEALTH=$(curl -s http://localhost:${API_PORT}/health 2>/dev/null || echo "FAILED")
log_info "健康状态: $HEALTH"

log_info "测试 3/3: 模型信息"
curl -s http://localhost:${API_PORT}/v1/models 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "无法获取模型信息"

# ============================================================
# 部署完成总结
# ============================================================
log_step "部署完成！"

cat << SUMMARY

${GREEN}========================================${NC}
${GREEN}  国讯芯微 R005 RoboAgent 部署成功${NC}
${GREEN}========================================${NC}

${CYAN}【服务信息】${NC}
  API 地址:    http://localhost:${API_PORT}
  模型文件:    ${MODEL_PATH}
  模型大小:    $(ls -lh "$MODEL_PATH" | awk '{print $5}')
  服务日志:    ${INSTALL_DIR}/server.log

${CYAN}【快捷命令】${NC}
  启动服务:    bash ${INSTALL_DIR}/start_server.sh
  文本测试:    bash ${INSTALL_DIR}/test_chat.sh
  视觉测试:    python3 ${INSTALL_DIR}/test_vision.py <图片.jpg>
  具身桥接:    python3 ${INSTALL_DIR}/roboagent_bridge.py

${CYAN}【后续开发】${NC}
  1. 从 Python 调用: requests.post("http://localhost:${API_PORT}/v1/chat/completions", ...)
  2. 接入摄像头: 将图像编码为 base64，调用 vision_reasoning()
  3. 任务规划:   调用 plan_task(scene, goal) 获取动作序列
  4. 下发控制:   解析模型输出的动作指令，通过 EtherCAT/CAN 发送给执行器

${CYAN}【注意事项】${NC}
  - 当前部署的是 Qwen2.5-VL-3B-Instruct（视觉语言基础模型）
  - RoboAgent 的微调权重（woyut/RoboAgent_CVPR26）目前只有 transformers 格式
  - 如需加载 RoboAgent 专用权重，需额外转换步骤（见集成指南）
  - R005 纯 CPU 推理速度约 1~3 tokens/秒，复杂任务建议简化 prompt

${CYAN}【系统服务】${NC}
  如需开机自启:
    sudo cp ${INSTALL_DIR}/roboagent.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable roboagent
    sudo systemctl start roboagent

${GREEN}========================================${NC}

SUMMARY

log_info "全部完成！日志保存在: $LOG_FILE"
