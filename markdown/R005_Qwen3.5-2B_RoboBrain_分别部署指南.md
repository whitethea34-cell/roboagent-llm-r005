# 国讯芯微 R005 分别部署指南：Qwen3.5-2B + RoboBrain

> **分别编写** — 两个模型各有独立的部署脚本、Dockerfile、文档  
> **Qwen3.5-2B**：多模态VLM，对话/代码/推理/图像理解/视频理解，llama.cpp + GGUF，速度优先  
> **RoboBrain**：视觉语言模型 (VLM)，看图理解 + 具身任务规划  

---

## 一、两个模型的区别

| 维度 | Qwen3.5-2B | RoboBrain |
|------|-----------|-----------|
| **模型类型** | 多模态VLM | 视觉语言模型 (VLM) |
| **参数量** | 2.35B | 7B (2.0) / 4B (2.5) |
| **核心能力** | 对话、代码、推理、长文本 | 看图理解、任务规划、动作推理 |
| **GGUF 可用性** | ✅ 有现成 GGUF | 2.0-7B ✅ / 2.5-4B ❌ |
| **推荐场景** | 自然语言交互、代码生成 | 具身智能、视觉任务规划 |
| **内存需求** | 1.5GB (Q4_K_M) | 3.8GB (Q3_K_M) / 5GB (Q4_K_M) |
| **部署方式** | llama.cpp (C++) | llama.cpp (2.0-7B) / transformers (2.5-4B) |
| **你的目标** | 对话输入输出测试 | 后续具身智能体开发 |

**设计思路**：
- **Qwen3.5-2B** 做"语言大脑"：轻量快速，处理对话和代码
- **RoboBrain** 做"视觉大脑"：看图理解，规划机器人动作
- 两者可以**同时运行**（不同端口），形成互补

---

## 二、文件清单

### Qwen3.5-2B 专用文件

| 文件 | 用途 |
|------|------|
| **`1_deploy_qwen35_2b_r005.sh`** | **裸机一键部署脚本** |
| **`qwen35.Dockerfile`** | Docker 镜像定义 |
| **`docker-compose.qwen35.yaml`** | Docker Compose 配置 |

### RoboBrain 专用文件

| 文件 | 用途 |
|------|------|
| **`2_deploy_robobrain_r005.sh`** | **裸机一键部署脚本**（三选项） |
| **`robobrain.Dockerfile`** | Docker 镜像定义 |
| **`docker-compose.robobrain.yaml`** | Docker Compose 配置 |

### 本指南
| 文件 | 用途 |
|------|------|
| **`R005_Qwen3.5-2B_RoboBrain_分别部署指南.md`** | 本文件 |

---

## 三、Qwen3.5-2B 部署

### 3.1 模型信息

```
模型名称: Qwen3.5-2B-Instruct
参数量:   2.35B
来源:     https://www.modelscope.cn/models/Qwen/Qwen3.5-2B
GGUF:     Qwen/Qwen3.5-2B-GGUF (魔搭镜像站) (HuggingFace)
量化:     Q4_K_M (约 1.2GB) / Q5_K_M (约 1.5GB)
上下文:   256K tokens
语言:     201 种
特色:     Thinking/Non-thinking 双模式
```

### 3.2 裸机部署

```bash
# Step 1: 传到 R005
scp 1_deploy_qwen35_2b_r005.sh admin@r005:~/deploy/
ssh admin@r005 "cd ~/deploy && chmod +x 1_deploy_qwen35_2b_r005.sh"

# Step 2: 运行部署
ssh admin@r005 "cd ~/deploy && bash 1_deploy_qwen35_2b_r005.sh"

# 可选: 使用更高量化精度
ssh admin@r005 "cd ~/deploy && bash 1_deploy_qwen35_2b_r005.sh --quant Q5_K_M"

# 可选: 启用 thinking 模式
ssh admin@r005 "cd ~/deploy && bash 1_deploy_qwen35_2b_r005.sh --thinking"
```

### 3.3 Docker 部署

```bash
# Step 1: 准备文件
mkdir qwen35-docker
cp qwen35.Dockerfile docker-compose.qwen35.yaml qwen35-docker/

# Step 2: 下载模型
mkdir -p qwen35-docker/models
cd qwen35-docker/models
wget https://hf-mirror.com/modelscope/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B.Q4_K_M.gguf
cd ..

# Step 3: 构建并启动
docker compose -f docker-compose.qwen35.yaml up -d

# Step 4: 验证
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.5-2b","messages":[{"role":"user","content":"你好"}]}'
```

### 3.4 部署后使用

```bash
# 交互式对话
python3 ~/ai-r005-qwen35/chat.py

# API 调用测试
bash ~/ai-r005-qwen35/test_chat.sh

# Python 编程调用
python3 ~/ai-r005-qwen35/api_client.py
```

### 3.5 Thinking 模式说明

Qwen3.5-2B 支持 "Thinking" 模式（深度推理）：

| 模式 | 启动参数 | 适用场景 |
|------|---------|---------|
| **Non-thinking** (默认) | 不需要参数 | 简单对话、快速回答 |
| **Thinking** | `--thinking` | 复杂推理、数学、代码 |

启用 thinking 后，模型会先内部思考再回答，输出质量更高但速度更慢。

---

## 四、RoboBrain 部署

### 4.1 模型信息

```
模型名称: RoboBrain (BAAI 智源研究院)
版本:     2.0-7B / 2.5-4B
来源:     https://huggingface.co/BAAI/RoboBrain2.5-4B
能力:     视觉理解 + 任务规划 + 动作推理
训练数据: 具身智能任务（室内操作、物品交互）
架构:     qwen2vl (视觉语言)
特色:     专为机器人设计，输出结构化动作序列
```

### 4.2 三个部署选项

脚本 `2_deploy_robobrain_r005.sh` 提供三个选项：

| 选项 | 模型 | 方式 | 速度 | 内存 | 推荐度 |
|------|------|------|------|------|--------|
| **A** | RoboBrain2.0-7B-GGUF | llama.cpp (C++) | 快 (3~5 t/s) | 3.8~4.7GB | ⭐⭐⭐⭐⭐ 首选 |
| **B** | RoboBrain2.5-4B | transformers (PyTorch) | 慢 (0.5~2 t/s) | 2.5~4GB | ⭐⭐⭐ 功能最新 |
| **C** | 自行转换2.5-4B→GGUF | 需x86电脑转换 | 转换后同A | 同A | ⭐⭐ 性能最佳 |

**选项选择指南**：

```
你的 R005 内存多少？
  ├── < 4GB → 选项B (2.5-4B transformers, 更小)
  ├── 4~6GB → 选项A + Q3_K_M (速度快)
  └── 6GB+  → 选项A + Q4_K_M (推荐, 速度快精度高)

你追功能还是速度？
  ├── 速度优先 → 选项A (C++推理)
  ├── 最新模型 → 选项B (2.5-4B是最新版)
  └── 性能极致 → 选项C (自己转GGUF)
```

### 4.3 裸机部署（选项A - 推荐）

```bash
# Step 1: 传到 R005
scp 2_deploy_robobrain_r005.sh admin@r005:~/deploy/
ssh admin@r005 "cd ~/deploy && chmod +x 2_deploy_robobrain_r005.sh"

# Step 2: 运行选项A
ssh admin@r005 "cd ~/deploy && bash 2_deploy_robobrain_r005.sh --option A"

# 如果内存紧张，用 Q3_K_M
ssh admin@r005 "cd ~/deploy && bash 2_deploy_robobrain_r005.sh --option A --quant Q3_K_M"
```

### 4.4 裸机部署（选项B - 2.5-4B最新版）

```bash
ssh admin@r005 "cd ~/deploy && bash 2_deploy_robobrain_r005.sh --option B"
```

**注意**：选项B需要下载 7~8GB 原始权重，耗时较长（30~60分钟）。

### 4.5 Docker 部署

```bash
# 选项A: RoboBrain2.0-7B
mkdir robobrain-docker
cp robobrain.Dockerfile docker-compose.robobrain.yaml robobrain-docker/

# 下载模型 (Q3_K_M 内存更友好)
mkdir -p robobrain-docker/models
cd robobrain-docker/models
wget https://hf-mirror.com/modelscope/bartowski/BAAI_RoboBrain2.0-7B-GGUF/resolve/main/BAAI_RoboBrain2.0-7B-Q3_K_M.gguf
cd ..

# 构建启动 (修改 docker-compose.yml 中的 MODEL_FILE 为 Q3_K_M)
docker compose -f docker-compose.robobrain.yaml up -d
```

### 4.6 部署后使用

```bash
# 文本任务规划
python3 ~/ai-r005-robobrain/vision_client.py

# 视觉推理（需要图片）
python3 ~/ai-r005-robobrain/vision_client.py /path/to/scene.jpg

# API 测试
bash ~/ai-r005-robobrain/test_vision.sh
```

---

## 五、两个模型同时运行

Qwen3.5-2B 和 RoboBrain 可以共存，各占不同端口：

```
服务            端口      用途
Qwen3.5-2B      :8080    语言对话、代码、推理
RoboBrain       :8081    视觉理解、任务规划
```

启动方法：

```bash
# Qwen3.5-2B (端口 8080)
bash ~/ai-r005-qwen35/start_server.sh

# RoboBrain (修改端口为 8081)
sed -i 's/--port 8080/--port 8081/' ~/ai-r005-robobrain/start_server.sh
bash ~/ai-r005-robobrain/start_server.sh
```

Python 调用区分：

```python
from api_client import QwenClient          # Qwen3.5-2B
from vision_client import RoboBrainClient  # RoboBrain

qwen = QwenClient("http://localhost:8080/v1/chat/completions")
brain = RoboBrainClient("http://localhost:8081/v1/chat/completions")

# 语言任务 → Qwen3.5-2B
code = qwen.generate_code("控制机械臂的Python类")

# 视觉规划 → RoboBrain
plan = brain.plan("厨房, 桌上有苹果和盘子", "把苹果切块装盘")
```

---

## 六、从部署到具身智能体

### 6.1 单模型架构

**只用 Qwen3.5-2B（文本输入）**：
```
传感器文本描述 → Qwen3.5-2B → 动作计划 → 控制器 → 执行器
```

**只用 RoboBrain（图片输入）**：
```
摄像头 → RoboBrain → 动作计划 → 控制器 → 执行器
```

### 6.2 双模型协作架构（推荐）

```
摄像头
  ↓
RoboBrain (视觉理解) → "场景中有苹果、桌子、盘子"
  ↓
Qwen3.5-2B (语言推理) → "任务：把苹果装盘"
  ↓
综合动作计划 → "1.GoTo(table) 2.PickUp(apple) 3.PutDown(apple)"
  ↓
控制器 → EtherCAT/CAN → 机械臂
```

### 6.3 对接 RoboAgent CVPR26 项目

你的目标项目：https://github.com/woyut/RoboAgent_CVPR26

RoboAgent 使用 RoboBrain 作为基础模型，流程：

```
RoboBrain 感知场景
  → 提取关键信息 (物体、位置、关系)
  → 任务分解 (高层任务 → 子任务序列)
  → 动作生成 (GoTo, PickUp, PutDown 等)
  → 控制器执行
  → 反馈闭环 (执行结果 → 重新感知)
```

你的部署可以直接替换 RoboAgent 中的模型调用部分：

```python
# RoboAgent 原始代码 (用 Transformers)
from transformers import AutoModelForVision2Seq
model = AutoModelForVision2Seq.from_pretrained("BAAI/RoboBrain2.5-4B")

# 替换为你的部署 (用 HTTP API)
import requests
API = "http://localhost:8080/v1/chat/completions"

def infer(image_b64, prompt):
    resp = requests.post(API, json={
        "model": "robobrain",
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
            {"type": "text", "text": prompt}
        ]}],
        "temperature": 0.5,
        "max_tokens": 512
    }, timeout=120)
    return resp.json()["choices"][0]["message"]["content"]
```

---

## 七、性能对比

在 R005 (ARM CPU) 上：

| 模型 | 量化 | 内存占用 | 推理速度 | 首次加载 |
|------|------|---------|---------|---------|
| Qwen3.5-2B | Q4_K_M | ~1.5GB | 3~8 t/s | 15s |
| Qwen3.5-2B | Q5_K_M | ~1.8GB | 2~5 t/s | 20s |
| RoboBrain2.0-7B | Q3_K_M | ~3.8GB | 1~3 t/s | 30s |
| RoboBrain2.0-7B | Q4_K_M | ~4.7GB | 1~2 t/s | 40s |
| RoboBrain2.5-4B | 4-bit | ~3GB | 0.5~1 t/s | 60s |

> t/s = tokens/second，每秒生成的 token 数（约等于汉字数）

---

## 八、常见问题

### Q1: Qwen3.5-2B 和 RoboBrain 有什么本质区别？

Qwen3.5-2B 是**通用 LLM**，擅长对话和代码，但**看不到图片**。  
RoboBrain 是**具身智能 VLM**，能**看图理解场景**，输出**结构化动作计划**。

你的场景：
- **如果机器人需要"看"环境 → 用 RoboBrain**
- **如果只是语音对话/代码生成 → 用 Qwen3.5-2B**
- **两者结合 → RoboBrain 看图，Qwen3.5-2B 辅助推理**

### Q2: 为什么 RoboBrain2.5-4B 没有现成 GGUF？

2.5-4B 是 BAAI 最新版本，社区还在转换中。三个解决路径：
1. 先用 2.0-7B-GGUF（选项A，已有现成文件）
2. 用 transformers CPU 跑 2.5-4B（选项B，功能完整但慢）
3. 自己在 x86 电脑上转 GGUF（选项C）

### Q3: R005 内存不够怎么办？

| 内存 | 推荐方案 |
|------|---------|
| 2GB | 只能跑 Qwen3.5-2B Q3_K_M |
| 4GB | Qwen3.5-2B + RoboBrain2.0-7B Q3_K_M |
| 6GB | Qwen3.5-2B + RoboBrain2.0-7B Q4_K_M |
| 8GB+ | 两个模型同时运行 + 有余量 |

### Q4: 两个模型可以切换吗？

可以。两者是独立的：
```bash
# 停 Qwen3.5-2B，启动 RoboBrain
pkill -f "llama-server.*qwen35"  # 停
bash ~/ai-r005-robobrain/start_server.sh  # 启

# 或修改端口同时运行
# Qwen3.5-2B 用 8080，RoboBrain 用 8081
```

---

## 文件总览

```
部署资料包/
├── 1_deploy_qwen35_2b_r005.sh          ← Qwen3.5-2B 裸机部署
├── 2_deploy_robobrain_r005.sh          ← RoboBrain 裸机部署 (3选项)
├── qwen35.Dockerfile                ← Qwen3.5-2B Docker
├── robobrain.Dockerfile                ← RoboBrain Docker
├── docker-compose.qwen35.yaml        ← Qwen3.5-2B Compose
├── docker-compose.robobrain.yaml        ← RoboBrain Compose
└── R005_Qwen3.5-2B_RoboBrain_分别部署指南.md  ← 本文件
```

---

**结束。根据你的需求选择部署方案，两个模型可独立运行也可协同工作。**
