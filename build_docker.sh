#!/bin/bash
# ============================================================
# RoboAgent R005 Docker 一键构建脚本
# 
# 功能：
#   1. 检测 Docker 环境（安装/配置）
#   2. 下载模型（如果本地没有）
#   3. 构建 Docker 镜像（多阶段，ARM64 优化）
#   4. 启动容器并验证
# 
# 用法：
#   chmod +x build_docker.sh
#   bash build_docker.sh [选项]
# 
# 选项：
#   --model-path PATH    指定本地模型路径（避免重复下载）
#   --hf-mirror URL      指定 HuggingFace 镜像站
#   --quant Q4_K_M       量化级别（Q3_K_M/Q4_K_M/Q5_K_M）
#   --no-cache           Docker 构建不使用缓存
# ============================================================

set -e

# ==================== 配置 ====================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="roboagent"
IMAGE_TAG="r005"
MODEL_NAME="Qwen2.5-VL-3B-Instruct"
QUANT="Q4_K_M"                    # 默认量化级别
HF_MIRROR="https://hf-mirror.com"
MODEL_DIR="${SCRIPT_DIR}/models"
LOGS_DIR="${SCRIPT_DIR}/logs"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"; }

# ==================== 解析参数 ====================
LOCAL_MODEL_PATH=""
DOCKER_NO_CACHE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --model-path)
            LOCAL_MODEL_PATH="$2"
            shift 2
            ;;
        --hf-mirror)
            HF_MIRROR="$2"
            shift 2
            ;;
        --quant)
            QUANT="$2"
            shift 2
            ;;
        --no-cache)
            DOCKER_NO_CACHE="--no-cache"
            shift
            ;;
        -h|--help)
            echo "用法: bash build_docker.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --model-path PATH   指定本地 .gguf 模型路径"
            echo "  --hf-mirror URL     HuggingFace 镜像站 (默认: https://hf-mirror.com)"
            echo "  --quant Q4_K_M      量化级别 (Q3_K_M/Q4_K_M/Q5_K_M)"
            echo "  --no-cache          Docker 构建不使用缓存"
            echo "  -h, --help          显示帮助"
            exit 0
            ;;
        *)
            log_err "未知参数: $1"
            exit 1
            ;;
    esac
done

MODEL_FILE="${MODEL_NAME}-${QUANT}.gguf"
HF_REPO="unsloth/${MODEL_NAME}-GGUF"

# ==================== Phase 1: Docker 环境检测 ====================
log_info "========================================"
log_info "  RoboAgent R005 Docker 构建"
log_info "  模型: ${MODEL_NAME} (${QUANT})"
log_info "========================================"

log_info "Phase 1/5: Docker 环境检测"

if ! command -v docker &> /dev/null; then
    log_warn "Docker 未安装，尝试安装..."
    
    # 检测系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian)
                log_info "安装 Docker (apt)..."
                apt-get update -qq
                apt-get install -y -qq ca-certificates curl gnupg
                install -m 0755 -d /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
                apt-get update -qq
                apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
                ;;
            *)
                log_err "不支持的系统: $ID，请手动安装 Docker"
                exit 1
                ;;
        esac
    fi
    
    # 启动 Docker 服务
    systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
    
    log_ok "Docker 安装完成"
else
    DOCKER_VERSION=$(docker --version)
    log_ok "Docker 已安装: $DOCKER_VERSION"
fi

# 检查 Docker 是否运行
if ! docker info > /dev/null 2>&1; then
    log_err "Docker 服务未运行！尝试启动..."
    systemctl start docker 2>/dev/null || service docker start 2>/dev/null
    sleep 2
    if ! docker info > /dev/null 2>&1; then
        log_err "无法启动 Docker 服务，请检查权限或手动启动"
        exit 1
    fi
fi
log_ok "Docker 服务运行正常"

# 检查架构
ARCH=$(docker info --format '{{.Architecture}}' 2>/dev/null || uname -m)
log_info "Docker 架构: $ARCH"
if [[ "$ARCH" != *"arm64"* && "$ARCH" != *"aarch64"* ]]; then
    log_warn "当前不是 ARM64 架构，构建的镜像可能无法在 R005 上运行"
fi

# ==================== Phase 2: 准备模型文件 ====================
log_info "Phase 2/5: 准备模型文件"

mkdir -p "$MODEL_DIR"

if [ -n "$LOCAL_MODEL_PATH" ] && [ -f "$LOCAL_MODEL_PATH" ]; then
    log_info "使用本地模型: $LOCAL_MODEL_PATH"
    cp "$LOCAL_MODEL_PATH" "${MODEL_DIR}/${MODEL_FILE}"
elif [ -f "${MODEL_DIR}/${MODEL_FILE}" ]; then
    log_ok "模型文件已存在: ${MODEL_DIR}/${MODEL_FILE} ($(du -sh "${MODEL_DIR}/${MODEL_FILE}" | cut -f1))"
else
    log_info "下载模型: ${MODEL_FILE}"
    log_info "来源: ${HF_MIRROR}/${HF_REPO}"
    
    cd "$MODEL_DIR"
    
    # 尝试多种下载方式
    DOWNLOAD_SUCCESS=false
    
    # 方法 1: hf 命令
    if command -v hf &> /dev/null; then
        log_info "尝试 hf download..."
        if hf download "$HF_REPO" "$MODEL_FILE" --local-dir . 2>/dev/null; then
            DOWNLOAD_SUCCESS=true
        fi
    fi
    
    # 方法 2: wget 直链
    if [ "$DOWNLOAD_SUCCESS" = false ]; then
        DOWNLOAD_URL="${HF_MIRROR}/${HF_REPO}/resolve/main/${MODEL_FILE}"
        log_info "尝试 wget 直链下载..."
        if wget --progress=bar:force "$DOWNLOAD_URL" -O "$MODEL_FILE" 2>&1; then
            DOWNLOAD_SUCCESS=true
        fi
    fi
    
    # 方法 3: curl
    if [ "$DOWNLOAD_SUCCESS" = false ]; then
        log_info "尝试 curl 下载..."
        if curl -L -o "$MODEL_FILE" "${HF_MIRROR}/${HF_REPO}/resolve/main/${MODEL_FILE}" --progress-bar; then
            DOWNLOAD_SUCCESS=true
        fi
    fi
    
    if [ "$DOWNLOAD_SUCCESS" = false ]; then
        log_err "模型下载失败！请手动下载后放到 ${MODEL_DIR}/"
        log_err "下载地址: ${HF_MIRROR}/${HF_REPO}"
        exit 1
    fi
    
    log_ok "模型下载完成: $(du -sh "${MODEL_DIR}/${MODEL_FILE}" | cut -f1)"
fi

# 回到脚本目录
cd "$SCRIPT_DIR"

# ==================== Phase 3: 构建 Docker 镜像 ====================
log_info "Phase 3/5: 构建 Docker 镜像 (多阶段构建)"
log_info "这可能需要 15~30 分钟，请耐心等待..."

# 确保 Dockerfile 存在
if [ ! -f "Dockerfile.roboagent" ]; then
    log_err "Dockerfile.roboagent 不存在！"
    exit 1
fi

docker build \
    $DOCKER_NO_CACHE \
    --build-arg MODEL_FILE="$MODEL_FILE" \
    -t "${PROJECT_NAME}:${IMAGE_TAG}" \
    -f Dockerfile.roboagent \
    . 2>&1 | tee "${LOGS_DIR}/docker-build.log"

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_err "Docker 镜像构建失败！查看日志: ${LOGS_DIR}/docker-build.log"
    exit 1
fi

# 查看镜像信息
IMAGE_SIZE=$(docker images "${PROJECT_NAME}:${IMAGE_TAG}" --format "{{.Size}}")
log_ok "镜像构建成功！"
log_info "镜像: ${PROJECT_NAME}:${IMAGE_TAG}"
log_info "大小: ${IMAGE_SIZE}"

# ==================== Phase 4: 启动容器 ====================
log_info "Phase 4/5: 启动容器"

# 确保日志目录存在
mkdir -p "$LOGS_DIR"

# 停止旧容器（如果存在）
if docker ps -a --format "{{.Names}}" | grep -q "roboagent-server"; then
    log_info "停止旧容器..."
    docker stop roboagent-server 2>/dev/null || true
    docker rm roboagent-server 2>/dev/null || true
fi

# 使用 docker compose 或 docker run
if command -v docker-compose &> /dev/null || docker compose version &> /dev/null 2>&1; then
    log_info "使用 Docker Compose 启动..."
    docker compose up -d 2>&1 | tee "${LOGS_DIR}/docker-run.log"
else
    log_info "使用 docker run 启动..."
    docker run -d \
        --name roboagent-server \
        --restart unless-stopped \
        -p 8080:8080 \
        -v "${MODEL_DIR}:/app/models:ro" \
        -v "${LOGS_DIR}:/app/logs" \
        --memory=4g \
        --memory-reservation=1g \
        "${PROJECT_NAME}:${IMAGE_TAG}" \
        -m /app/models/${MODEL_FILE} \
        --host 0.0.0.0 \
        --port 8080 \
        --ctx-size 4096 \
        --threads 4 \
        --batch-size 512 \
        --verbose 2>&1 | tee "${LOGS_DIR}/docker-run.log"
fi

log_ok "容器已启动"

# ==================== Phase 5: 验证 ====================
log_info "Phase 5/5: 验证服务"

log_info "等待模型加载（约 30~60 秒）..."
for i in {1..30}; do
    sleep 2
    if curl -s http://localhost:8080/health > /dev/null 2>&1; then
        log_ok "服务已就绪！"
        break
    fi
    echo -n "."
    
    # 检查容器状态
    if ! docker ps --format "{{.Names}}" | grep -q "roboagent-server"; then
        log_err "容器意外退出！"
        docker logs roboagent-server --tail 50
        exit 1
    fi
done

# 测试对话
echo ""
log_info "测试对话..."
curl -s http://localhost:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "qwen2.5-vl",
        "messages": [{"role": "user", "content": "你好，请简短介绍自己"}],
        "temperature": 0.7,
        "max_tokens": 128
    }' | python3 -m json.tool 2>/dev/null | head -20 || \
    log_warn "Python json 格式化失败，但请求可能已发送"

# ==================== 完成总结 ====================
echo ""
log_ok "========================================"
log_ok "  Docker 部署完成！"
log_ok "========================================"
echo ""
log_info "容器:     roboagent-server"
log_info "镜像:     ${PROJECT_NAME}:${IMAGE_TAG}"
log_info "API 地址: http://localhost:8080"
log_info "模型:     ${MODEL_FILE}"
echo ""
log_info "常用命令:"
log_info "  查看日志:   docker logs -f roboagent-server"
log_info "  停止服务:   docker stop roboagent-server"
log_info "  重启服务:   docker restart roboagent-server"
log_info "  进入容器:   docker exec -it roboagent-server bash"
log_info "  查看状态:   docker ps"
log_info "  资源监控:   docker stats roboagent-server"
echo ""
log_info "从 Python 调用:"
log_info '  requests.post("http://localhost:8080/v1/chat/completions", ...)'
echo ""
