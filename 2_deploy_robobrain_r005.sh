#!/bin/bash
# ============================================================
# RoboBrain 国讯芯微 R005 一键部署脚本
# 
# RoboBrain 是 BAAI 智源研究院专为具身智能设计的视觉语言模型(VLM)
# 能力: 看图理解 + 任务规划 + 动作推理
#
# 由于 RoboBrain2.5-4B 暂无现成 GGUF，本脚本提供两个选项:
# 
#   选项A: RoboBrain2.0-7B-GGUF (推荐, 速度快, llama.cpp)
#     模型: modelscope/bartowski/BAAI_RoboBrain2.0-7B-GGUF
#     大小: Q4_K_M = 4.68GB / Q3_K_M = 3.81GB
#     速度: 快 (C++ 推理)
#     适用: R005 内存 6GB+
#
#   选项B: RoboBrain2.5-4B transformers (功能最新, PyTorch CPU)
#     模型: BAAI/RoboBrain2.5-4B (HuggingFace)
#     大小: 4-bit量化后约 2.5GB
#     速度: 较慢 (Python 推理)
#     适用: R005 内存 4GB+
#
#   选项C: 自行转换 RoboBrain2.5-4B 到 GGUF
#     在 x86 电脑上转换后放到 R005 (性能最佳)
#
# 用法: 
#   bash 2_deploy_robobrain_r005.sh --option A  # 推荐
#   bash 2_deploy_robobrain_r005.sh --option B
#   bash 2_deploy_robobrain_r005.sh --option A --quant Q3_K_M
# ============================================================

set -e

# ==================== 配置区 ====================
INSTALL_DIR="${HOME}/ai-r005-robobrain"
MODEL_DIR="${INSTALL_DIR}/models"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
LOGS_DIR="${INSTALL_DIR}/logs"
LOG_FILE="${INSTALL_DIR}/deploy.log"

DEPLOY_OPTION="${2:-A}"                 # 默认选项A
QUANT="${4:-Q4_K_M}"                    # 默认Q4_K_M
API_PORT="8080"
HF_MIRROR="https://hf-mirror.com"
MS_MIRROR="https://www.modelscope.cn"

# 选项A: 2.0-7B GGUF
RB20_REPO="modelscope/bartowski/BAAI_RoboBrain2.0-7B-GGUF"
RB20_FILE="BAAI_RoboBrain2.0-7B-${QUANT}.gguf"

# 选项B: 2.5-4B transformers
RB25_REPO="BAAI/RoboBrain2.5-4B"
RB25_DIR="${MODEL_DIR}/RoboBrain2.5-4B"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"   | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"  | tee -a "$LOG_FILE"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"    | tee -a "$LOG_FILE"; }
log_step() { echo -e "\n${CYAN}========================================${NC}"; echo -e "${CYAN}  $1${NC}" | tee -a "$LOG_FILE"; echo -e "${CYAN}========================================${NC}"; }

mkdir -p "$INSTALL_DIR" "$MODEL_DIR" "$LOGS_DIR"
touch "$LOG_FILE"

# ==================== 参数解析 ====================
while [[ $# -gt 0 ]]; do
    case $1 in
        --option) DEPLOY_OPTION="$2"; shift 2;;
        --quant)  QUANT="$2"; RB20_FILE="BAAI_RoboBrain2.0-7B-${QUANT}.gguf"; shift 2;;
        *) shift;;
    esac
done

# ==================== Phase 0: 硬件探测 ====================
log_step "RoboBrain R005 部署启动 (选项 ${DEPLOY_OPTION})"
log_info "时间: $(date)"

ARCH=$(uname -m)
CPU_COUNT=$(nproc)
TOTAL_MEM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
log_info "架构: $ARCH | CPU: $CPU_COUNT 核 | 内存: ${TOTAL_MEM_GB}GB"

# 根据内存推荐选项
if [ "$DEPLOY_OPTION" = "A" ]; then
    if [ "$TOTAL_MEM_GB" -lt 5 ]; then
        if [ "$QUANT" != "Q3_K_M" ]; then
            log_warn "内存 ${TOTAL_MEM_GB}GB < 5GB，自动切换 Q3_K_M (3.81GB)"
            QUANT="Q3_K_M"; RB20_FILE="BAAI_RoboBrain2.0-7B-${QUANT}.gguf"
        fi
    fi
    if [ "$TOTAL_MEM_GB" -lt 4 ]; then
        log_warn "内存 ${TOTAL_MEM_GB}GB 可能不足以运行 7B 模型，建议使用选项 B (2.5-4B)"
    fi
elif [ "$DEPLOY_OPTION" = "B" ]; then
    if [ "$TOTAL_MEM_GB" -lt 3 ]; then
        log_warn "内存 ${TOTAL_MEM_GB}GB < 3GB，选项B也可能运行困难"
    fi
fi

log_ok "硬件探测完成"

# ==================== 选项A: RoboBrain2.0-7B GGUF ====================
deploy_option_a() {
    log_step "选项A: 部署 RoboBrain2.0-7B-GGUF (${QUANT})"
    
    # ---- Phase A1: 依赖 ----
    log_info "安装依赖..."
    apt-get update -qq
    apt-get install -y -qq build-essential cmake git curl wget python3 python3-pip libgomp1 ca-certificates
    
    if ! grep -q "HF_ENDPOINT" ~/.bashrc 2>/dev/null; then
        echo "export HF_ENDPOINT=$HF_MIRROR" >> ~/.bashrc
    fi
    export HF_ENDPOINT="$HF_MIRROR"
    pip3 install -q --upgrade modelscope huggingface-hub
    
    # ---- Phase A2: 编译 llama.cpp ----
    log_info "编译 llama.cpp..."
    if [ -d "$LLAMA_DIR/.git" ]; then
        cd "$LLAMA_DIR" && git pull --ff-only
    else
        git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
    fi
    cd "$LLAMA_DIR"
    rm -rf build && mkdir build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DGGML_OPENMP=ON \
             -DLLAMA_BUILD_SERVER=ON -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF \
             -DGGML_CUDA=OFF -DGGML_VULKAN=OFF 2>&1 | tee -a "$LOG_FILE"
    make -j"$CPU_COUNT" 2>&1 | tee -a "$LOG_FILE"
    log_ok "编译完成"
    
    # ---- Phase A3: 下载模型 ----
    log_info "下载 RoboBrain2.0-7B ${QUANT}..."
    cd "$MODEL_DIR"
    
    if [ -f "$RB20_FILE" ]; then
        log_ok "模型已存在: $RB20_FILE ($(du -sh "$RB20_FILE" | cut -f1))"
    else
        DOWNLOAD_URL="https://www.modelscope.cn/models/bartowski/BAAI_RoboBrain2.0-7B-GGUF/repo?FilePath=${RB20_FILE}"
        log_info "下载: $DOWNLOAD_URL"
        
        # 优先使用魔搭 modelscope CLI 下载
        if command -v modelscope &> /dev/null && modelscope download --model bartowski/BAAI_RoboBrain2.0-7B-GGUF --local_dir . "$RB20_FILE" 2>/dev/null; then
            log_ok "modelscope download 成功"
        # 备用：wget 魔搭直链
        elif wget --progress=bar:force "$DOWNLOAD_URL" -O "$RB20_FILE" 2>&1; then
            log_ok "wget 下载成功"
        else
            log_err "模型下载失败！"
            log_info "请手动下载: https://www.modelscope.cn/models/bartowski/BAAI_RoboBrain2.0-7B-GGUF"
            exit 1
        fi
    fi
    
    # ---- Phase A4: 创建脚本 ----
    log_info "创建配置文件..."
    
    cat > "${INSTALL_DIR}/start_server.sh" << EOF
#!/bin/bash
INSTALL_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
cd "\${INSTALL_DIR}/llama.cpp"
./build/bin/llama-server \\
    -m "\${INSTALL_DIR}/models/${RB20_FILE}" \\
    --host 0.0.0.0 --port ${API_PORT} \\
    --ctx-size 8192 --threads ${CPU_COUNT} --batch-size 512 \\
    --verbose
EOF
    chmod +x "${INSTALL_DIR}/start_server.sh"
    
    # 视觉对话测试
    cat > "${INSTALL_DIR}/test_vision.sh" << 'EOF'
#!/bin/bash
API="http://localhost:8080/v1/chat/completions"
echo "===== RoboBrain2.0-7B 视觉+规划测试 ====="

echo "[测试1] 文本任务规划"
curl -s "$API" -H "Content-Type: application/json" -d '{
  "model": "robobrain2.0",
  "messages": [{"role": "system", "content": "你是机器人任务规划助手。"}, {"role": "user", "content": "场景：厨房有苹果和盘子。任务：把苹果切块装盘。给出步骤。"}],
  "temperature": 0.5, "max_tokens": 256
}' | python3 -c "import sys,json; d=json.load(sys.stdin); print('AI:', d['choices'][0]['message']['content'])" 2>/dev/null || echo "服务未就绪"
EOF
    chmod +x "${INSTALL_DIR}/test_vision.sh"

    # 交互式对话脚本
    cat > "${INSTALL_DIR}/chat.py" << 'PYEOF'
#!/usr/bin/env python3
"""RoboBrain 交互式对话客户端（支持文本+视觉）"""
import requests
import base64
import os

API = "http://localhost:8080/v1/chat/completions"
MODEL = "robobrain2.0"
history = []

print("===== RoboBrain 交互对话 =====")
print("命令: /image <图片路径>  传入图片")
print("      /clear             清空上下文")
print("      quit               退出\n")

while True:
    user = input("你 > ")
    if user.lower() in ["quit", "exit", "退出"]:
        break

    if user.startswith("/clear"):
        history = []
        print("[上下文已清空]\n")
        continue

    if user.startswith("/image "):
        img_path = user[7:].strip()
        if not os.path.exists(img_path):
            print(f"[错误] 图片不存在: {img_path}\n")
            continue
        with open(img_path, "rb") as f:
            img_b64 = base64.b64encode(f.read()).decode()
        question = input("  问题 > ")
        history.append({"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{img_b64}"}},
            {"type": "text", "text": question}
        ]})
    else:
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
        if len(history) > 20:
            history = history[-20:]
    except Exception as e:
        print(f"[错误] {e}\n")

print("对话结束")
PYEOF
    chmod +x "${INSTALL_DIR}/chat.py"

    # 视觉推理 Python 客户端
    cat > "${INSTALL_DIR}/vision_client.py" << 'EOF'
#!/usr/bin/env python3
"""RoboBrain 视觉推理 + 任务规划客户端"""
import requests
import base64

API = "http://localhost:8080/v1/chat/completions"

class RoboBrainClient:
    def __init__(self, api_url=API):
        self.api_url = api_url
    
    def plan(self, scene, goal):
        """多模态任务规划"""
        payload = {
            "model": "robobrain2.0",
            "messages": [
                {"role": "system", "content": "你是具身智能机器人助手，擅长任务规划。"},
                {"role": "user", "content": f"场景: {scene}\n任务: {goal}\n请给出详细动作步骤:"}
            ],
            "temperature": 0.5, "max_tokens": 512
        }
        resp = requests.post(self.api_url, json=payload, timeout=120)
        return resp.json()["choices"][0]["message"]["content"]
    
    def vision_reason(self, image_path, question):
        """视觉推理（需要 llama.cpp 支持 VLM）"""
        with open(image_path, "rb") as f:
            img_b64 = base64.b64encode(f.read()).decode()
        payload = {
            "model": "robobrain2.0",
            "messages": [{"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{img_b64}"}},
                {"type": "text", "text": question}
            ]}],
            "temperature": 0.7, "max_tokens": 512
        }
        resp = requests.post(self.api_url, json=payload, timeout=120)
        return resp.json()["choices"][0]["message"]["content"]

# 示例
if __name__ == "__main__":
    client = RoboBrainClient()
    print("任务规划:")
    print(client.plan("客厅，沙发前有杯子", "把杯子放到桌子上"))
EOF
    chmod +x "${INSTALL_DIR}/vision_client.py"
    
    # ---- Phase A5: 启动 ----
    log_info "启动 llama-server..."
    cd "$LLAMA_DIR"
    ./build/bin/llama-server \
        -m "$MODEL_DIR/$RB20_FILE" \
        --host 0.0.0.0 --port "$API_PORT" \
        --ctx-size 8192 --threads "$CPU_COUNT" \
        --batch-size 512 \
        > "${LOGS_DIR}/server.log" 2>&1 &
    
    SERVER_PID=$!
    log_info "PID: $SERVER_PID"
    
    for i in {1..45}; do
        sleep 2
        if curl -s http://localhost:${API_PORT}/health > /dev/null 2>&1; then
            log_ok "服务就绪！"
            break
        fi
        if ! kill -0 $SERVER_PID 2>/dev/null; then
            log_err "服务启动失败！"
            tail -n 50 "${LOGS_DIR}/server.log"
            exit 1
        fi
        echo -n "."
    done
    
    bash "${INSTALL_DIR}/test_vision.sh" 2>&1 | head -30
    
    # ---- 完成 ----
    cat << SUMMARY

${GREEN}========================================${NC}
${GREEN}  RoboBrain2.0-7B 部署成功！${NC}
${GREEN}========================================${NC}

${CYAN}【模型信息】${NC}
  名称:   RoboBrain2.0-7B-GGUF (${QUANT})
  来源:   BAAI/RoboBrain2.0-7B (bartowski量化)
  大小:   $(du -sh "${MODEL_DIR}/${RB20_FILE}" | cut -f1)
  能力:   视觉理解 + 任务规划 + 动作推理

${CYAN}【服务信息】${NC}
  API:    http://localhost:${API_PORT}
  日志:   ${LOGS_DIR}/server.log

${CYAN}【快捷命令】${NC}
  启动:   bash ${INSTALL_DIR}/start_server.sh
  测试:   bash ${INSTALL_DIR}/test_vision.sh
  客户端: python3 ${INSTALL_DIR}/vision_client.py

${CYAN}【Python 集成】${NC}
  from vision_client import RoboBrainClient
  client = RoboBrainClient()
  print(client.plan("场景描述", "任务目标"))

${GREEN}========================================${NC}

SUMMARY
}

# ==================== 选项B: RoboBrain2.5-4B transformers ====================
deploy_option_b() {
    log_step "选项B: 部署 RoboBrain2.5-4B (transformers + CPU)"
    
    # ---- Phase B1: 依赖 ----
    log_info "安装 Python 依赖..."
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip python3-venv libgomp1 git curl
    
    if ! grep -q "HF_ENDPOINT" ~/.bashrc 2>/dev/null; then
        echo "export HF_ENDPOINT=$HF_MIRROR" >> ~/.bashrc
    fi
    export HF_ENDPOINT="$HF_MIRROR"
    
    # 创建虚拟环境
    python3 -m venv "${INSTALL_DIR}/venv"
    source "${INSTALL_DIR}/venv/bin/activate"
    
    # 安装 PyTorch CPU + transformers (ARM64)
    log_info "安装 PyTorch CPU (ARM64)..."
    pip install -q torch torchvision --index-url https://download.pytorch.org/whl/cpu
    
    log_info "安装 transformers + accelerate..."
    pip install -q transformers accelerate sentencepiece Pillow
    
    # 尝试安装 bitsandbytes (4-bit 量化支持)
    log_info "尝试安装 bitsandbytes..."
    pip install -q bitsandbytes || log_warn "bitsandbytes 安装失败，将使用 8-bit 量化"
    
    # ---- Phase B2: 下载模型 ----
    log_info "下载 RoboBrain2.5-4B 模型..."
    log_info "这将下载约 7~8GB 原始权重，耗时较长..."
    
    mkdir -p "$RB25_DIR"
    
    python3 << 'PYEOF'
import os
import sys

os.environ['HF_ENDPOINT'] = os.environ.get('HF_ENDPOINT', 'https://hf-mirror.com')

from transformers import AutoModelForVision2Seq, AutoProcessor

repo = "BAAI/RoboBrain2.5-4B"
save_dir = os.path.expanduser("~/ai-r005-robobrain/models/RoboBrain2.5-4B")

print(f"正在下载 {repo}...")
print("这可能需要 30~60 分钟，取决于网速...")

processor = AutoProcessor.from_pretrained(repo, trust_remote_code=True)
processor.save_pretrained(save_dir)
print("Processor 下载完成")

# 使用 4-bit 量化加载后保存
print("下载并量化模型 (4-bit)...")
try:
    from transformers import BitsAndBytesConfig
    quant_config = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_compute_dtype="float16")
    model = AutoModelForVision2Seq.from_pretrained(
        repo, trust_remote_code=True,
        quantization_config=quant_config,
        device_map="cpu",
        low_cpu_mem_usage=True
    )
except Exception as e:
    print(f"4-bit 量化失败 ({e})，尝试 8-bit...")
    model = AutoModelForVision2Seq.from_pretrained(
        repo, trust_remote_code=True,
        load_in_8bit=True,
        device_map="cpu",
        low_cpu_mem_usage=True
    )

# 注意：量化后的模型直接存在 save_dir，但 4-bit 不适合序列化保存
# 我们用原始方式保存配置文件
print("保存模型配置...")
model.config.save_pretrained(save_dir)
print(f"模型下载完成！保存在 {save_dir}")
PYEOF
    
    # ---- Phase B3: 创建启动脚本 ----
    log_info "创建推理服务..."
    
    cat > "${INSTALL_DIR}/run_server.py" << 'PYEOF'
#!/usr/bin/env python3
"""RoboBrain2.5-4B Flask API 服务 (CPU推理)"""
import os
import sys
import base64
from io import BytesIO
from flask import Flask, request, jsonify

# 激活虚拟环境
venv_site = os.path.expanduser("~/ai-r005-robobrain/venv/lib/python3.10/site-packages")
if os.path.exists(venv_site) and venv_site not in sys.path:
    sys.path.insert(0, venv_site)

from transformers import AutoModelForVision2Seq, AutoProcessor
from PIL import Image
import torch

app = Flask(__name__)

MODEL_DIR = os.path.expanduser("~/ai-r005-robobrain/models/RoboBrain2.5-4B")
processor = None
model = None

def load_model():
    """加载模型"""
    global processor, model
    print("正在加载 RoboBrain2.5-4B...")
    processor = AutoProcessor.from_pretrained(MODEL_DIR, trust_remote_code=True)
    model = AutoModelForVision2Seq.from_pretrained(
        MODEL_DIR, trust_remote_code=True,
        torch_dtype=torch.float16,
        device_map="cpu",
        low_cpu_mem_usage=True
    )
    print("模型加载完成！")

@app.route("/v1/chat/completions", methods=["POST"])
def chat():
    """OpenAI 兼容 API"""
    data = request.json
    messages = data.get("messages", [])
    temperature = data.get("temperature", 0.7)
    max_tokens = data.get("max_tokens", 512)
    
    # 处理消息
    text_input = ""
    image_input = None
    
    for msg in messages:
        content = msg.get("content", "")
        if isinstance(content, list):
            # 多模态输入
            for part in content:
                if part.get("type") == "text":
                    text_input += part.get("text", "")
                elif part.get("type") == "image_url":
                    img_url = part["image_url"]["url"]
                    if img_url.startswith("data:image"):
                        img_b64 = img_url.split(",")[1]
                        image_input = Image.open(BytesIO(base64.b64decode(img_b64)))
        else:
            text_input += content + "\n"
    
    # 构建对话
    if image_input:
        msgs = [{"role": "user", "content": [{"type": "image", "image": image_input}, {"type": "text", "text": text_input}]}]
    else:
        msgs = [{"role": "user", "content": text_input}]
    
    # 推理
    text = processor.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
    inputs = processor(text=[text], images=[image_input] if image_input else None, return_tensors="pt")
    
    with torch.no_grad():
        outputs = model.generate(**inputs, max_new_tokens=max_tokens, do_sample=True, temperature=temperature)
    
    response = processor.batch_decode(outputs[:, inputs.input_ids.shape[1]:], skip_special_tokens=True)[0]
    
    return jsonify({
        "choices": [{"message": {"role": "assistant", "content": response}}]
    })

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})

if __name__ == "__main__":
    load_model()
    app.run(host="0.0.0.0", port=8080, threaded=True)
PYEOF
    chmod +x "${INSTALL_DIR}/run_server.py"
    
    # 安装 Flask
    pip install -q flask 2>/dev/null || true
    
    # 启动脚本
    cat > "${INSTALL_DIR}/start_server.sh" << EOF
#!/bin/bash
cd "${INSTALL_DIR}"
source venv/bin/activate
python3 run_server.py
EOF
    chmod +x "${INSTALL_DIR}/start_server.sh"
    
    # ---- Phase B4: 启动 ----
    log_info "启动服务..."
    source "${INSTALL_DIR}/venv/bin/activate"
    python3 "${INSTALL_DIR}/run_server.py" > "${LOGS_DIR}/server.log" 2>&1 &
    
    SERVER_PID=$!
    log_info "PID: $SERVER_PID"
    
    for i in {1..60}; do
        sleep 5
        if curl -s http://localhost:${API_PORT}/health > /dev/null 2>&1; then
            log_ok "服务就绪！"
            break
        fi
        if ! kill -0 $SERVER_PID 2>/dev/null; then
            log_err "服务启动失败！"
            tail -n 50 "${LOGS_DIR}/server.log"
            exit 1
        fi
        echo -n "."
    done
    
    # ---- 完成 ----
    cat << SUMMARY

${GREEN}========================================${NC}
${GREEN}  RoboBrain2.5-4B 部署成功！${NC}
${GREEN}========================================${NC}

${CYAN}【模型信息】${NC}
  名称:   RoboBrain2.5-4B (transformers CPU)
  来源:   BAAI/RoboBrain2.5-4B
  能力:   视觉理解 + 任务规划 + 动作推理 (最新版)

${CYAN}【服务信息】${NC}
  API:    http://localhost:${API_PORT}
  日志:   ${LOGS_DIR}/server.log

${CYAN}【注意】${NC}
  此方案使用 PyTorch CPU 推理，速度较慢（约 0.5~2 t/s）
  如需更快推理，建议转换 GGUF 格式（见选项C说明）

${CYAN}【快捷命令】${NC}
  启动:   bash ${INSTALL_DIR}/start_server.sh

${GREEN}========================================${NC}

SUMMARY
}

# ==================== 选项C: 转换说明 ====================
show_option_c() {
    cat << 'EOF'

========================================
  选项C: RoboBrain2.5-4B → GGUF 转换
========================================

由于 RoboBrain2.5-4B 暂无官方 GGUF 版本，你可以自行转换：

【在 x86 Linux/Windows 电脑上执行】

1. 安装依赖:
   pip install transformers torch gguf

2. 下载模型:
   export HF_ENDPOINT=https://hf-mirror.com
   huggingface-cli download BAAI/RoboBrain2.5-4B --local-dir ./RoboBrain2.5-4B

3. 使用 llama.cpp 转换:
   python llama.cpp/convert_hf_to_gguf.py \
       --src ./RoboBrain2.5-4B \
       --dst ./RoboBrain2.5-4B-Q4_K_M.gguf \
       --outtype q4_k_m

4. 复制到 R005:
   scp RoboBrain2.5-4B-Q4_K_M.gguf admin@r005:~/ai-r005-robobrain/models/

5. 在 R005 上用 llama.cpp 加载（同选项A方式）

【注意事项】
- RoboBrain2.5-4B 基于 qwen2vl 架构，转换需确保 llama.cpp 版本 >= b4000
- 视觉编码器需要额外处理（可能需转换 mmproj 文件）
- 如转换失败，建议先用选项A (2.0-7B-GGUF)

========================================

EOF
}

# ==================== 主入口 ====================
case "$DEPLOY_OPTION" in
    A|a) deploy_option_a ;;
    B|b) deploy_option_b ;;
    C|c) show_option_c ;;
    *)
        log_err "未知选项: $DEPLOY_OPTION"
        log_info "用法: bash $0 --option [A|B|C] [--quant Q4_K_M|Q3_K_M|Q5_K_M]"
        log_info "  A: RoboBrain2.0-7B-GGUF (推荐, 速度快)"
        log_info "  B: RoboBrain2.5-4B transformers (功能最新, 较慢)"
        log_info "  C: 显示转换说明"
        exit 1
        ;;
esac

log_info "全部完成！日志: $LOG_FILE"
