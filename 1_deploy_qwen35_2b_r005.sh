#!/bin/bash
# ============================================================
# Qwen3.5-2B-Instruct 国讯芯微 R005 一键部署脚本
# 
# 模型: Qwen3.5-2B (多模态VLM，2.35B 参数，支持文本/图像/视频)
# 来源: https://www.modelscope.cn/models/Qwen/Qwen3.5-2B
# GGUF: modelscope/unsloth/Qwen3.5-2B-GGUF (HuggingFace)
# 能力: 对话/代码/推理/长文本 (256K 上下文，201 种语言)
# 
# 硬件要求: ARM64 CPU, 2GB+ 内存
# 量化: Q4_K_M (约 1.2GB) / Q5_K_M (约 1.5GB)
# 
# 用法: bash 1_deploy_qwen35_2b_r005.sh [--quant Q4_K_M|Q5_K_M|Q3_K_M]
# ============================================================

set -e

# ==================== 配置区 ====================
INSTALL_DIR="${HOME}/ai-r005-qwen35"
MODEL_DIR="${INSTALL_DIR}/models"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
LOGS_DIR="${INSTALL_DIR}/logs"
LOG_FILE="${INSTALL_DIR}/deploy.log"

MODEL_NAME="Qwen3.5-2B"
QUANT="${2:-Q4_K_M}"                    # 默认 Q4_K_M
GGUF_REPO="modelscope/unsloth/Qwen3.5-2B-GGUF"
MODEL_FILE="${MODEL_NAME}.${QUANT}.gguf"

HF_MIRROR="https://hf-mirror.com"
API_PORT="8080"

# Qwen3.5-2B 默认禁用 thinking，如需启用使用 --chat-template-kwargs
ENABLE_THINKING="false"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"   | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"  | tee -a "$LOG_FILE"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"    | tee -a "$LOG_FILE"; }
log_step() { echo -e "\n${CYAN}========================================${NC}"; echo -e "${CYAN}  $1${NC}" | tee -a "$LOG_FILE"; echo -e "${CYAN}========================================${NC}"; }

mkdir -p "$INSTALL_DIR" "$MODEL_DIR" "$LOGS_DIR"
touch "$LOG_FILE"

# ==================== Phase 0: 参数解析 ====================
while [[ $# -gt 0 ]]; do
    case $1 in
        --quant) QUANT="$2"; MODEL_FILE="${MODEL_NAME}.${QUANT}.gguf"; shift 2;;
        --thinking) ENABLE_THINKING="true"; shift;;
        *) shift;;
    esac
done

# ==================== Phase 1: 硬件探测 ====================
log_step "Phase 1/6: 硬件探测"
ARCH=$(uname -m)
CPU_COUNT=$(nproc)
TOTAL_MEM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
log_info "架构: $ARCH | CPU: $CPU_COUNT 核 | 内存: ${TOTAL_MEM_GB}GB"

if [ "$TOTAL_MEM_GB" -lt 2 ]; then
    log_err "内存不足 2GB，无法运行 Qwen3.5-2B！"
    exit 1
fi

# 根据内存推荐量化级别
if [ "$TOTAL_MEM_GB" -lt 4 ]; then
    if [ "$QUANT" != "Q3_K_M" ]; then
        log_warn "内存仅 ${TOTAL_MEM_GB}GB，自动切换为 Q3_K_M"
        QUANT="Q3_K_M"; MODEL_FILE="${MODEL_NAME}.${QUANT}.gguf"
    fi
fi
log_info "使用量化: $QUANT"
log_ok "硬件探测完成"

# ==================== Phase 2: 依赖安装 ====================
log_step "Phase 2/6: 安装依赖"

apt-get update -qq
apt-get install -y -qq build-essential cmake git curl wget python3 python3-pip libgomp1 ca-certificates

# HuggingFace 镜像配置
if ! grep -q "HF_ENDPOINT" ~/.bashrc 2>/dev/null; then
    echo "export HF_ENDPOINT=$HF_MIRROR" >> ~/.bashrc
    echo "export HF_HOME=${HOME}/.cache/huggingface" >> ~/.bashrc
fi
export HF_ENDPOINT="$HF_MIRROR"
source ~/.bashrc 2>/dev/null || true

pip3 install -q --upgrade modelscope huggingface-hub

log_ok "依赖安装完成"

# ==================== Phase 3: 编译 llama.cpp ====================
log_step "Phase 3/6: 编译 llama.cpp (ARM NEON 优化)"

if [ -d "$LLAMA_DIR/.git" ]; then
    cd "$LLAMA_DIR" && git pull --ff-only
else
    git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
fi

cd "$LLAMA_DIR"
rm -rf build && mkdir build && cd build

cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=ON \
    -DLLAMA_BUILD_SERVER=ON \
    -DGGML_AVX=OFF \
    -DGGML_AVX2=OFF \
    -DGGML_FMA=OFF \
    -DGGML_CUDA=OFF \
    -DGGML_VULKAN=OFF \
    2>&1 | tee -a "$LOG_FILE"

make -j"$CPU_COUNT" 2>&1 | tee -a "$LOG_FILE"

if [ ! -f "bin/llama-server" ]; then
    log_err "编译失败！查看日志: $LOG_FILE"
    exit 1
fi
log_ok "编译完成"

# ==================== Phase 4: 下载模型 ====================
log_step "Phase 4/6: 下载 Qwen3.5-2B ${QUANT} 模型"

cd "$MODEL_DIR"

if [ -f "$MODEL_FILE" ]; then
    log_ok "模型已存在: $MODEL_FILE ($(du -sh "$MODEL_FILE" | cut -f1))"
else
    log_info "下载: $GGUF_REPO → $MODEL_FILE"
    DOWNLOAD_URL="https://www.modelscope.cn/models/Qwen/Qwen3.5-2B-GGUF/repo?FilePath=${MODEL_FILE}"
    
    # 优先使用魔搭 modelscope CLI 下载
    if command -v modelscope &> /dev/null && modelscope download --model Qwen/Qwen3.5-2B-GGUF --local_dir . "$MODEL_FILE" 2>/dev/null; then
        log_ok "modelscope download 成功"
    # 备用：wget 魔搭直链
    elif wget --progress=bar:force "$DOWNLOAD_URL" -O "$MODEL_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "wget 下载成功"
    else
        log_err "模型下载失败！"
        log_info "请手动下载: https://www.modelscope.cn/models/Qwen/Qwen3.5-2B-GGUF"
        exit 1
    fi

    if [ ! -f "$MODEL_FILE" ]; then
        log_err "模型下载失败！"
        log_info "手动下载: ${HF_MIRROR}/${GGUF_REPO}"
        exit 1
    fi
    log_ok "模型下载完成: $(du -sh "$MODEL_FILE" | cut -f1)"
fi

# ==================== Phase 5: 创建配置文件 ====================
log_step "Phase 5/6: 创建启动脚本和配置文件"

# 启动脚本
cat > "${INSTALL_DIR}/start_server.sh" << EOF
#!/bin/bash
INSTALL_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
cd "\${INSTALL_DIR}/llama.cpp"
./build/bin/llama-server \\
    -m "\${INSTALL_DIR}/models/${MODEL_FILE}" \\
    --host 0.0.0.0 \\
    --port ${API_PORT} \\
    --ctx-size 8192 \\
    --threads ${CPU_COUNT} \\
    --batch-size 512 \\
    --chat-template-kwargs '{"enable_thinking":${ENABLE_THINKING}}' \\
    --verbose
EOF
chmod +x "${INSTALL_DIR}/start_server.sh"

# 对话测试脚本
cat > "${INSTALL_DIR}/test_chat.sh" << 'EOF'
#!/bin/bash
API="http://localhost:8080/v1/chat/completions"
echo "===== Qwen3.5-2B 对话测试 ====="

echo "[测试1] 自我介绍"
curl -s "$API" -H "Content-Type: application/json" -d '{
  "model": "qwen3.5-2b",
  "messages": [{"role": "user", "content": "你好，请用一句话介绍自己"}],
  "temperature": 0.7, "max_tokens": 128
}' | python3 -c "import sys,json; d=json.load(sys.stdin); print('AI:', d['choices'][0]['message']['content'])" 2>/dev/null || echo "需等模型加载"

echo ""
echo "[测试2] 代码能力"
curl -s "$API" -H "Content-Type: application/json" -d '{
  "model": "qwen3.5-2b",
  "messages": [{"role": "user", "content": "写一个Python函数判断回文数"}],
  "temperature": 0.3, "max_tokens": 256
}' | python3 -c "import sys,json; d=json.load(sys.stdin); print('AI:', d['choices'][0]['message']['content'])" 2>/dev/null || true

echo ""
echo "[测试3] 任务规划"
curl -s "$API" -H "Content-Type: application/json" -d '{
  "model": "qwen3.5-2b",
  "messages": [{"role": "system", "content": "你是机器人任务规划助手。"}, {"role": "user", "content": "场景：厨房有苹果和刀。任务：切块装盘。给出步骤。"}],
  "temperature": 0.5, "max_tokens": 256
}' | python3 -c "import sys,json; d=json.load(sys.stdin); print('AI:', d['choices'][0]['message']['content'])" 2>/dev/null || true
EOF
chmod +x "${INSTALL_DIR}/test_chat.sh"

# 交互式对话脚本
cat > "${INSTALL_DIR}/chat.py" << 'EOF'
#!/usr/bin/env python3
"""Qwen3.5-2B 交互式对话客户端"""
import requests
import json

API = "http://localhost:8080/v1/chat/completions"
MODEL = "qwen3.5-2b"
history = []

print("===== Qwen3.5-2B 交互对话 =====")
print("输入 'quit' 退出\n")

while True:
    user = input("你 > ")
    if user.lower() in ["quit", "exit", "退出"]:
        break
    
    history.append({"role": "user", "content": user})
    
    try:
        resp = requests.post(API, json={
            "model": MODEL,
            "messages": history,
            "temperature": 0.7,
            "max_tokens": 512,
            "stream": False
        }, timeout=120)
        reply = resp.json()["choices"][0]["message"]["content"]
        print(f"AI > {reply}\n")
        history.append({"role": "assistant", "content": reply})
        # 保持上下文不超限
        if len(history) > 20:
            history = history[-20:]
    except Exception as e:
        print(f"[错误] {e}")

print("对话结束")
EOF
chmod +x "${INSTALL_DIR}/chat.py"

# Python API 调用示例
cat > "${INSTALL_DIR}/api_client.py" << 'EOF'
#!/usr/bin/env python3
"""Qwen3.5-2B Python API 客户端（供具身智能集成）"""
import requests
import json

class QwenClient:
    def __init__(self, api_url="http://localhost:8080/v1/chat/completions"):
        self.api_url = api_url
        self.history = []
    
    def chat(self, message, temperature=0.7, max_tokens=512):
        """单次对话"""
        self.history.append({"role": "user", "content": message})
        resp = requests.post(self.api_url, json={
            "model": "qwen3.5-2b",
            "messages": self.history,
            "temperature": temperature,
            "max_tokens": max_tokens
        }, timeout=120)
        reply = resp.json()["choices"][0]["message"]["content"]
        self.history.append({"role": "assistant", "content": reply})
        return reply
    
    def plan_task(self, scene, goal):
        """任务规划（具身智能）"""
        prompt = f"场景: {scene}\n任务: {goal}\n请给出分步动作计划（每步: 动作 对象）:"
        return self.chat(prompt, temperature=0.5, max_tokens=256)
    
    def generate_code(self, description):
        """代码生成"""
        return self.chat(f"请写Python代码: {description}", temperature=0.3, max_tokens=512)
    
    def clear_history(self):
        self.history = []

# ============ 使用示例 ============
if __name__ == "__main__":
    client = QwenClient()
    
    # 示例1: 对话
    print("示例1 - 对话:")
    print(client.chat("用一句话解释深度学习"))
    
    # 示例2: 任务规划
    print("\n示例2 - 任务规划:")
    print(client.plan_task("厨房, 桌上有苹果和盘子", "把苹果放盘里"))
    
    # 示例3: 代码
    print("\n示例3 - 代码:")
    print(client.generate_code("快速排序"))
EOF
chmod +x "${INSTALL_DIR}/api_client.py"

log_ok "配置文件创建完成"

# ==================== Phase 6: 启动 + 验证 ====================
log_step "Phase 6/6: 启动服务并验证"

cd "$LLAMA_DIR"
./build/bin/llama-server \
    -m "$MODEL_DIR/$MODEL_FILE" \
    --host 0.0.0.0 \
    --port "$API_PORT" \
    --ctx-size 8192 \
    --threads "$CPU_COUNT" \
    --batch-size 512 \
    --chat-template-kwargs "{\"enable_thinking\":${ENABLE_THINKING}}" \
    > "${LOGS_DIR}/server.log" 2>&1 &

SERVER_PID=$!
log_info "服务 PID: $SERVER_PID"

# 等待就绪
log_info "等待模型加载..."
for i in {1..45}; do
    sleep 2
    if curl -s http://localhost:${API_PORT}/health > /dev/null 2>&1; then
        log_ok "服务已就绪！"
        break
    fi
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        log_err "服务启动失败！"
        tail -n 50 "${LOGS_DIR}/server.log"
        exit 1
    fi
    echo -n "."
done

# 对话验证
echo ""
log_info "运行对话测试..."
bash "${INSTALL_DIR}/test_chat.sh" 2>&1 | head -50

# ==================== 完成总结 ====================
cat << SUMMARY

${GREEN}========================================${NC}
${GREEN}  Qwen3.5-2B 部署成功！${NC}
${GREEN}========================================${NC}

${CYAN}【模型信息】${NC}
  名称:   Qwen3.5-2B-Instruct
  量化:   ${QUANT}
  大小:   $(du -sh "${MODEL_DIR}/${MODEL_FILE}" | cut -f1)
  能力:   对话/代码/推理/长文本(256K)/201语言

${CYAN}【服务信息】${NC}
  API:    http://localhost:${API_PORT}
  日志:   ${LOGS_DIR}/server.log

${CYAN}【快捷命令】${NC}
  启动:    bash ${INSTALL_DIR}/start_server.sh
  测试:    bash ${INSTALL_DIR}/test_chat.sh
  对话:    python3 ${INSTALL_DIR}/chat.py
  客户端:  python3 ${INSTALL_DIR}/api_client.py

${CYAN}【从 Python 调用】${NC}
  from api_client import QwenClient
  client = QwenClient()
  print(client.chat("你好"))
  print(client.plan_task("场景", "任务"))

${CYAN}【对话 curl 示例】${NC}
  curl http://localhost:${API_PORT}/v1/chat/completions \\
    -H "Content-Type: application/json" \\
    -d '{"model":"qwen3.5-2b","messages":[{"role":"user","content":"你好"}]}'

${GREEN}========================================${NC}

SUMMARY
