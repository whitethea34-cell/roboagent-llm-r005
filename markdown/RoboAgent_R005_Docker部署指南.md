# 国讯芯微 R005 + RoboAgent Docker 部署指南

> **硬件**：国讯芯微 NSPIC-R005 + 白泽操作系统  
> **部署方式**：Docker 容器化部署  
> **模型**：Qwen2.5-VL-3B-Instruct GGUF（视觉语言基础模型）  
> **推理引擎**：llama.cpp（C++，ARM NEON 加速）  
> **目标**：一键构建 Docker 镜像并启动服务，环境完全隔离

---

## Docker 部署 vs 裸机部署对比

| 维度 | Docker 部署（本次） | 裸机部署（之前方案） |
|------|-------------------|-------------------|
| **环境隔离** | ✅ 完全隔离，不影响系统 | 依赖装在系统里 |
| **一键性** | ✅ `docker compose up -d` 一键启停 | 编译 + 配置 + 启动 |
| **镜像体积** | 约 200MB（不含模型） | 编译产物约 50MB |
| **模型存储** | 主机挂载卷（推荐）或镜像内置 | 直接放文件系统 |
| **卸载** | `docker compose down` 完全清除 | 需手动删文件 |
| **适用场景** | **快速部署、环境隔离、团队分发** | 性能极致优化 |
| **R005 支持** | ✅ 白泽系统兼容 Docker | ✅ 直接编译 |

**结论**：
- **追求快速、干净、可复现** → Docker 部署
- **追求极致性能、内存紧张** → 裸机部署
- **两者可以共存**：先用 Docker 快速验证，后续切裸机优化

---

## 目录

1. [前置条件](#一前置条件)
2. [快速开始（最快路径）](#二快速开始最快路径)
3. [两种部署模式](#三两种部署模式)
4. [从零开始完整步骤](#四从零开始完整步骤)
5. [Docker 常用命令速查](#五docker-常用命令速查)
6. [具身智能集成（Python 调用）](#六具身智能集成python-调用)
7. [性能优化](#七性能优化)
8. [裸机部署 vs Docker 的切换](#八裸机部署-vs-docker-的切换)
9. [常见问题](#九常见问题)

---

## 一、前置条件

### 1.1 R005 硬件要求

| 资源 | 最低要求 | 推荐 |
|------|---------|------|
| CPU | ARM64 (aarch64) | 4 核以上 |
| 内存 | 4GB | 8GB |
| 存储 | 8GB 可用 | 20GB+（模型文件占 2GB） |
| 网络 | 可选（首次下载需要） | 联网方便下模型 |

### 1.2 白泽系统要求

白泽系统基于 Linux，兼容 Docker：

```bash
# 确认 Docker 是否已预装
docker --version
# 期望输出: Docker version 24.x.x 或更高

# 确认架构
uname -m
# 期望输出: aarch64
```

如果 Docker 未安装，`build_docker.sh` 脚本会自动安装（需要 root 权限）。

### 1.3 你需要准备的文件

从资料包复制以下文件到 R005 的同一目录：

```
roboagent-docker/
├── Dockerfile.roboagent     # Docker 镜像定义
├── docker-compose.yml       # 容器编排配置
├── build_docker.sh          # 一键构建脚本
└── (可选) models/           # 本地模型目录
    └── Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf
```

---

## 二、快速开始（最快路径）

如果你已经有一个 `.gguf` 模型文件：

```bash
# Step 1: 创建项目目录
mkdir -p ~/roboagent-docker && cd ~/roboagent-docker

# Step 2: 复制资料包文件进来
# （通过 SCP/U盘/直接下载）

# Step 3: 如果已有模型，放到 models/ 目录
mkdir -p models
cp /path/to/your/Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf models/

# Step 4: 一键构建 + 运行
chmod +x build_docker.sh
bash build_docker.sh

# Step 5: 测试
bash -c 'curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"qwen2.5-vl\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}]}"'
```

**完成！** 整个过程大约 20~40 分钟（取决于编译和下载速度）。

---

## 三、两种部署模式

### 模式 A：模型挂载卷（推荐，镜像体积小）

```
主机文件系统                  Docker 容器
┌──────────────┐           ┌──────────────────┐
│ models/      │ ──挂载──→ │ /app/models/     │
│  └── *.gguf  │  (只读)   │                  │
│              │           │ llama-server     │
│ logs/        │ ──挂载──→ │ /app/logs/       │
│              │           │                  │
└──────────────┘           └──────────────────┘
        ↑                        ↑
   你管理模型文件          容器内推理服务
   换模型只需替换文件      重启容器即生效
```

**优势**：
- Docker 镜像仅 ~200MB（llama.cpp 二进制 + Ubuntu 基础）
- 换模型不重新构建镜像
- 模型和数据持久化在主机

**docker-compose.yml 中的配置**：
```yaml
volumes:
  - ./models:/app/models:ro     # 模型挂载（只读）
  - ./logs:/app/logs            # 日志持久化
```

### 模式 B：模型打包进镜像（离线部署）

```
Docker 镜像
┌──────────────────────────────┐
│ Ubuntu 22.04 ARM64           │
│ ├─ llama-server              │
│ ├─ libgomp1                  │
│ └─ model.gguf  ← 模型打包进镜像 │
│                              │
│ 镜像大小: ~2.2GB             │
└──────────────────────────────┘
```

**优势**：
- 完全离线，不需要运行时下载模型
- 整个应用一个镜像文件，U 盘复制即可部署

**劣势**：
- 镜像体积大（+2GB 模型）
- 换模型需重新构建镜像

**构建方式**：
```bash
# 修改 Dockerfile 中的 COPY 指令
# 或直接用 build_docker.sh（它会自动处理）
```

---

## 四、从零开始完整步骤

### Step 1: 文件传输

从 Windows/WSL 把文件传到 R005：

```powershell
# Windows PowerShell
scp Dockerfile.roboagent docker-compose.yml build_docker.sh admin@r005-ip:~/roboagent-docker/
```

或 U 盘：
```bash
# R005 上
mkdir -p ~/roboagent-docker
cp /media/usb/Dockerfile.roboagent ~/roboagent-docker/
cp /media/usb/docker-compose.yml ~/roboagent-docker/
cp /media/usb/build_docker.sh ~/roboagent-docker/
```

### Step 2: 运行构建脚本

```bash
cd ~/roboagent-docker
chmod +x build_docker.sh

# 基本用法（自动下载模型）
bash build_docker.sh

# 或指定已有模型（跳过下载）
bash build_docker.sh --model-path /mnt/e/models/Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf

# 或选择其他量化级别
bash build_docker.sh --quant Q3_K_M   # 更小更快，精度略低
bash build_docker.sh --quant Q5_K_M   # 更大更准，速度略慢
```

构建过程输出：
```
[INFO] ========================================
[INFO]   RoboAgent R005 Docker 构建
[INFO]   模型: Qwen2.5-VL-3B-Instruct (Q4_K_M)
[INFO] ========================================
[INFO] Phase 1/5: Docker 环境检测
[OK] Docker 已安装: Docker version 24.0.7
[INFO] Phase 2/5: 准备模型文件
[OK] 模型文件已存在: models/Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf (1.9G)
[INFO] Phase 3/5: 构建 Docker 镜像 (多阶段构建)
...（编译输出，约 15~20 分钟）...
[OK] 镜像构建成功！
[INFO] 镜像: roboagent:r005
[INFO] 大小: 215MB
[INFO] Phase 4/5: 启动容器
[OK] 容器已启动
[INFO] Phase 5/5: 验证服务
[OK] 服务已就绪！
========================================
  Docker 部署完成！
========================================
```

### Step 3: 验证服务

```bash
# 查看容器状态
docker ps
# 应看到 roboagent-server 状态为 Up

# 查看日志（实时）
docker logs -f roboagent-server

# 文本对话测试
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-vl",
    "messages": [{"role": "user", "content": "你好，请介绍自己"}],
    "temperature": 0.7,
    "max_tokens": 128
  }'

# 应返回 JSON 格式的回答
```

---

## 五、Docker 常用命令速查

### 服务管理

| 命令 | 作用 |
|------|------|
| `docker compose up -d` | 后台启动服务 |
| `docker compose down` | 停止并删除容器 |
| `docker compose restart` | 重启服务 |
| `docker compose ps` | 查看容器状态 |
| `docker compose logs -f` | 实时查看日志 |

### 容器操作

| 命令 | 作用 |
|------|------|
| `docker ps` | 查看运行中的容器 |
| `docker stop roboagent-server` | 停止容器 |
| `docker start roboagent-server` | 启动容器 |
| `docker restart roboagent-server` | 重启容器 |
| `docker rm roboagent-server` | 删除容器 |
| `docker exec -it roboagent-server bash` | 进入容器内部 |

### 镜像管理

| 命令 | 作用 |
|------|------|
| `docker images` | 查看本地镜像 |
| `docker rmi roboagent:r005` | 删除镜像 |
| `docker save roboagent:r005 > roboagent.tar` | 导出镜像到文件 |
| `docker load < roboagent.tar` | 从文件导入镜像 |

### 监控

| 命令 | 作用 |
|------|------|
| `docker stats roboagent-server` | 查看容器资源占用 |
| `docker logs --tail 100 roboagent-server` | 查看最近 100 行日志 |
| `docker top roboagent-server` | 查看容器内进程 |

### 资源占用参考

```bash
docker stats roboagent-server --no-stream
# 输出示例：
# CONTAINER           CPU %    MEM USAGE / LIMIT     NET I/O
# roboagent-server    15.2%    2.1GiB / 3.906GiB    1.2kB / 3.4kB
```

---

## 六、具身智能集成（Python 调用）

Docker 部署后，API 地址与裸机部署完全相同：

```python
import requests
import base64
import cv2

API_URL = "http://localhost:8080/v1/chat/completions"

class EmbodiedAgent:
    def __init__(self, api_url=API_URL):
        self.api_url = api_url

    def plan_task(self, scene_description, task_goal):
        """任务规划（纯文本）"""
        payload = {
            "model": "qwen2.5-vl",
            "messages": [
                {"role": "system", "content": "你是机器人任务规划助手。"},
                {"role": "user", "content": f"场景: {scene_description}\n任务: {task_goal}\n请给出步骤。"}
            ],
            "temperature": 0.5,
            "max_tokens": 256
        }
        resp = requests.post(self.api_url, json=payload, timeout=60)
        return resp.json()["choices"][0]["message"]["content"]

    def vision_reason(self, image_b64, question):
        """视觉推理"""
        payload = {
            "model": "qwen2.5-vl",
            "messages": [{
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
                    {"type": "text", "text": question}
                ]
            }],
            "temperature": 0.7,
            "max_tokens": 512
        }
        resp = requests.post(self.api_url, json=payload, timeout=120)
        return resp.json()["choices"][0]["message"]["content"]


# ============ 使用 ============
agent = EmbodiedAgent()

# 纯文本规划
plan = agent.plan_task("厨房，桌上有苹果和刀", "把苹果切块")
print(plan)

# 视觉推理
# with open("scene.jpg", "rb") as f:
#     img_b64 = base64.b64encode(f.read()).decode()
# result = agent.vision_reason(img_b64, "描述场景并给出任务建议")
# print(result)
```

**Docker 部署与裸机部署的 Python 调用代码完全相同**，只是 llama-server 跑在容器里。

---

## 七、性能优化

### 7.1 调整线程数

R005 的 CPU 核心数不同，需要在 `docker-compose.yml` 中调整：

```yaml
command: >
  -m /app/models/Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf
  --host 0.0.0.0
  --port 8080
  --ctx-size 4096
  --threads 4        # ← 改为你的 CPU 核心数
  --batch-size 512
```

查看核心数：
```bash
nproc
# 或
cat /proc/cpuinfo | grep processor | wc -l
```

### 7.2 内存限制

R005 内存紧张时，在 `docker-compose.yml` 中收紧限制：

```yaml
deploy:
  resources:
    limits:
      memory: 3G       # 限制最大 3GB
    reservations:
      memory: 1G       # 预留 1GB
```

或运行时调整：
```bash
docker update --memory=3g --memory-swap=3g roboagent-server
```

### 7.3 使用更小的模型

如果内存不够，换用 Q3_K_M 量化：

```bash
# 1. 下载更小模型
bash build_docker.sh --quant Q3_K_M

# 2. 或修改 docker-compose.yml 中的模型文件名
```

### 7.4 镜像导出（离线分发）

构建完成后，导出为 tar 文件，可以在离线 R005 上直接加载：

```bash
# 导出镜像（约 200MB，不含模型）
docker save roboagent:r005 > roboagent-r005-image.tar

# 复制到目标 R005
scp roboagent-r005-image.tar admin@target-r005:~/roboagent/

# 在目标 R005 上加载
docker load < roboagent-r005-image.tar

# 同时复制模型文件
scp models/*.gguf admin@target-r005:~/roboagent/models/

# 启动
cd ~/roboagent
docker compose up -d
```

---

## 八、裸机部署 vs Docker 的切换

### 从 Docker 切到裸机（追求性能）

```bash
# 1. 停止 Docker 容器
cd ~/roboagent-docker
docker compose down

# 2. 运行之前的裸机部署脚本
bash ~/deploy_roboagent_r005.sh

# 3. 验证
bash ~/ai-r005/test_chat.sh
```

### 从裸机切到 Docker（追求便利）

```bash
# 1. 停止裸机服务
pkill llama-server  # 或 bash ~/ai-r005/stop_server.sh

# 2. 启动 Docker 容器
cd ~/roboagent-docker
docker compose up -d

# 3. 验证
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-vl","messages":[{"role":"user","content":"你好"}]}'
```

**两者 API 完全兼容**，你的 Python 控制代码不需要任何修改。

---

## 九、常见问题

### Q1: 白泽系统上 Docker 命令报错 `permission denied`

```bash
# 将当前用户加入 docker 组
sudo usermod -aG docker $USER
# 重新登录或执行
newgrp docker
# 验证
docker ps
```

### Q2: 容器启动后马上退出

```bash
# 查看日志
docker logs roboagent-server

# 常见原因：
# 1. 模型文件不存在 → 检查 models/ 目录
# 2. 内存不足 → docker-compose.yml 里调小 --ctx-size
# 3. 端口冲突 → lsof -i :8080 查看谁占用了 8080
```

### Q3: 镜像构建卡在 "Sending build context to Docker daemon"

**原因**：build 上下文太大（包含了 models/ 目录的 2GB 模型文件）。

**解决**：
```bash
# 创建 .dockerignore 排除大文件
echo "models/" > .dockerignore
echo "*.gguf" >> .dockerignore
echo "logs/" >> .dockerignore

# 重新构建
bash build_docker.sh
```

### Q4: ARM64 镜像在 x86 电脑上构建失败

**原因**：Dockerfile 用了 `arm64v8/ubuntu`，x86 无法直接运行 ARM 镜像。

**解决**：
```bash
# 开启 Docker 的 binfmt_misc（QEMU 模拟）
docker run --privileged --rm tonistiigi/binfmt --install all

# 或直接在 R005 上构建（推荐）
```

### Q5: 如何更新 llama.cpp 版本？

```bash
# 1. 停止容器
docker compose down

# 2. 重新构建（--no-cache 强制重新编译）
bash build_docker.sh --no-cache

# 3. 启动
docker compose up -d
```

### Q6: 如何同时运行多个模型？

```yaml
# docker-compose.yml 中添加多个服务
services:
  roboagent-q4:
    image: roboagent:r005
    container_name: roboagent-q4
    ports:
      - "8080:8080"
    volumes:
      - ./models/q4.gguf:/app/model.gguf:ro

  roboagent-q3:
    image: roboagent:r005
    container_name: roboagent-q3
    ports:
      - "8081:8080"    # 不同端口
    volumes:
      - ./models/q3.gguf:/app/model.gguf:ro
```

### Q7: Docker 容器里的时间和时区不对

```yaml
# docker-compose.yml 中添加
environment:
  - TZ=Asia/Shanghai
volumes:
  - /etc/localtime:/etc/localtime:ro
```

---

## 文件清单

| 文件 | 用途 |
|------|------|
| `Dockerfile.roboagent` | Docker 镜像定义（多阶段构建） |
| `docker-compose.yml` | 容器编排配置 |
| `build_docker.sh` | 一键构建 + 启动脚本 |

---

**文档结束。把这三个文件和模型放到 R005 的同一目录，运行 `bash build_docker.sh`，20 分钟后你就有了一个容器化的具身智能推理服务。**
