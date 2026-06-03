# 国讯芯微 R005 + 白泽系统 Qwen3.5-2B 部署指南

> **目标硬件**：国讯芯微 NSPIC-R005 具身智能控制器  
> **目标系统**：NECRO 白泽具身智能操作系统（基于 Linux）  
> **部署模型**：Qwen3.5-2B-Instruct（20亿参数，Apache 2.0 开源）  
> **适用对象**：零基础，需一键部署 + 对话验证  
> **下游目标**：具身智能体（感知 → 推理 → 控制闭环）

---

## 目录

1. [硬件与系统认知](#一硬件与系统认知)
2. [三种部署方案对比](#二三种部署方案对比)
3. [方案 A：Ollama 一键部署（最简单）](#三方案-aollama-一键部署最简单推荐)
4. [方案 B：llama.cpp 高性能部署（端侧标准）](#四方案-bllamacpp-高性能部署端侧标准)
5. [方案 C：Transformers 原生部署（最灵活）](#五方案-ctransformers-原生部署最灵活)
6. [对话验证：三种方案的通用测试方法](#六对话验证三种方案的通用测试方法)
7. [具身智能体集成思路](#七具身智能体集成思路)
8. [常见问题排查](#八常见问题排查)

---

## 一、硬件与系统认知

### 1.1 国讯芯微 R005 是什么？

国讯芯微（NIIC）NSPIC 系列是**专为具身智能设计的 ARM 架构控制器**：

| 特性 | 说明 |
|------|------|
| **CPU** | ARM 架构多核处理器（推测为 ARMv8 或 ARMv9） |
| **内存** | LPDDR（推测 4~8GB，足够运行 2B 模型） |
| **AI 加速** | 内置 NPU/AI 加速器（支持 int8 推理） |
| **接口** | EtherCAT、CAN/CANFD、USB、GMSL 摄像头等 |
| **定位** | 机器人"大小脑一体化"控制器 |

### 1.2 白泽系统是什么？

**NECRO 白泽**是国讯芯微自研的具身智能操作系统：

- **内核**：囚牛硬实时操作系统（100% 自主代码，工信部认证）
- **兼容性**：兼容 Linux 主流生态（Python、ROS2、Docker 等）
- **实时性**：微秒级系统抖动，纳秒级中断响应
- **AI 支持**：内置大小脑协同架构，GPU/NPU 负责"大脑"推理，CPU 负责"小脑"控制

**对你来说最重要的**：白泽系统能跑 Linux 程序，能装 Python，能跑大模型。

### 1.3 Qwen3.5-2B 在 R005 上能跑吗？

**完全可以。**

| 指标 | Qwen3.5-2B | R005 能力 | 结论 |
|------|-----------|----------|------|
| 参数量 | 20亿 | 同系列 R006 可跑 13B | 绰绰有余 |
| FP16 内存占用 | ~4GB | 推测 ≥4GB | 刚好或需量化 |
| 4-bit 量化后 | ~1.2GB | 轻松容纳 | 推荐方案 |
| 推理速度（CPU） | - | ARM 多核 | 可用（1~5 t/s） |

> **t/s** = tokens/second，每秒生成多少个汉字。1 t/s ≈ 1 秒 1 个字，5 t/s ≈ 1 秒 5 个字。

---

## 二、三种部署方案对比

| 对比维度 | 方案 A：Ollama | 方案 B：llama.cpp | 方案 C：Transformers |
|---------|--------------|-------------------|---------------------|
| **部署难度** | 一条命令 | 需编译（10分钟） | pip 安装即可 |
| **推理速度** | 中 | **最快**（C++） | 最慢（Python） |
| **内存占用** | 中 | **最低**（GGUF量化） | 最高 |
| **是否需联网** | 首次需要 | 不需要 | 首次需要 |
| **是否需编译** | 否 | 是 | 否 |
| **API 接口** | 有 | 有（OpenAI兼容） | 需自己写 |
| **多模态支持** | 部分 | 有（llama-mtmd-cli） | 完整 |
| **推荐度** | ⭐⭐⭐ 懒人首选 | ⭐⭐⭐⭐⭐ **端侧标准** | ⭐⭐⭐ 快速验证 |

**选择建议**：
- **零基础、想最快看到效果** → 方案 A（Ollama）
- **追求性能、后续要接机器人控制** → 方案 B（llama.cpp）
- **要改代码、做研究** → 方案 C（Transformers）

---

## 三、方案 A：Ollama 一键部署（最简单，推荐）

> Ollama 是一个"大模型的 Docker"，内置了各种模型的下载、管理和推理，一条命令就能跑。

### Step 1：安装 Ollama

在白泽系统的终端中运行：

```bash
# 一键安装脚本（ARM 版本会自动检测）
curl -fsSL https://ollama.com/install.sh | sh

# 验证安装
ollama --version
# 应输出版本号，如：ollama version 0.4.x
```

> 如果 `curl` 命令卡住，先检查网络：
> ```bash
> ping hf-mirror.com
> ```

### Step 2：拉取 Qwen3.5-2B 模型

```bash
# 拉取模型（约 1.5GB，首次需联网）
ollama pull qwen3.5:2b

# 等待下载完成...
# 输出类似：pulling manifest... pulling xxx... success
```

> 如果拉取慢或失败，配置镜像加速：
> ```bash
> # 设置环境变量后重试
> export OLLAMA_HOST=0.0.0.0:11434
> # 或使用国内镜像站
> ```

### Step 3：运行对话测试

```bash
# 交互式对话
ollama run qwen3.5:2b

# 你会看到 >>> 提示符，直接输入问题
>>> 你好，请介绍一下自己
>>> 什么是具身智能？
>>> 如何用 Python 写一个冒泡排序？

# 退出对话
/bye
```

### Step 4：启动 API 服务（供后续程序调用）

```bash
# 后台启动 API 服务
ollama serve &

# 测试 API
curl http://localhost:11434/api/generate -d '{
  "model": "qwen3.5:2b",
  "prompt": "你好",
  "stream": false
}'

# 应返回 JSON 格式的模型回答
```

**一键部署脚本**（保存为 `deploy_ollama.sh`）：

```bash
#!/bin/bash
set -e

echo "===== Ollama 一键部署 Qwen3.5-2B ====="

# 安装 Ollama（如果没装）
if ! command -v ollama &> /dev/null; then
    echo "[1/4] 安装 Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo "[1/4] Ollama 已安装"
fi

# 拉取模型
echo "[2/4] 拉取 Qwen3.5-2B..."
ollama pull qwen3.5:2b

# 测试
echo "[3/4] 运行测试..."
echo "你好，请简短介绍自己" | ollama run qwen3.5:2b

# 启动 API
echo "[4/4] 启动 API 服务..."
ollama serve &

echo "===== 部署完成 ====="
echo "API 地址: http://localhost:11434"
echo "交互式对话: ollama run qwen3.5:2b"
```

---

## 四、方案 B：llama.cpp 高性能部署（端侧标准）

> llama.cpp 是用 C++ 编写的大模型推理引擎，专为端侧优化。在 ARM 设备上比 Python 快 3~10 倍。

### 设计思路

```
Qwen3.5-2B (原始 HuggingFace 格式)
    ↓
下载预转换的 GGUF 量化模型（Q4_K_M，约 1.2GB）
    ↓
llama.cpp 编译（ARM 版本）
    ↓
启动 llama-server（提供 OpenAI 兼容 API）
    ↓
HTTP 请求对话 / Python 程序调用
```

### Step 1：安装编译依赖

```bash
sudo apt update
sudo apt install -y build-essential git cmake curl
```

### Step 2：编译 llama.cpp（ARM 优化版）

```bash
# 创建工作目录
mkdir -p ~/ai-tools && cd ~/ai-tools

# 克隆仓库
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp

# ARM 编译（启用 NEON 加速）
mkdir -p build && cd build
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DGGML_OPENMP=ON

# 编译（使用所有 CPU 核心）
make -j$(nproc)

# 编译完成后，二进制在 build/bin/ 目录
ls bin/
# 应看到：llama-cli  llama-server  llama-gguf-split  等
```

> 编译时间：5~15 分钟（取决于 CPU 性能）

### Step 3：下载 Qwen3.5-2B GGUF 模型

```bash
# 创建模型目录
mkdir -p ~/ai-models
cd ~/ai-models

# 方法 1：用 hf 命令下载（推荐）
hf download modelscope/unsloth/Qwen3.5-2B-GGUF --local-dir ./Qwen3.5-2B-GGUF

# 方法 2：如果 hf 命令不可用，用 wget 直接下载单个文件
# Q4_K_M 量化（平衡速度和精度，约 1.2GB）
wget https://hf-mirror.com/modelscope/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B.Q4_K_M.gguf

# Q5_K_M 量化（精度更高，约 1.5GB）
# wget https://hf-mirror.com/modelscope/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B.Q5_K_M.gguf
```

### Step 4：启动推理服务

```bash
cd ~/ai-tools/llama.cpp

# 启动 llama-server（OpenAI 兼容 API）
./build/bin/llama-server \
    -m ~/ai-models/Qwen3.5-2B.Q4_K_M.gguf \
    --host 0.0.0.0 \
    --port 8080 \
    --ctx-size 4096 \
    --threads $(nproc)

# 输出应显示：
# load: model loaded successfully
# srv  http server listening on http://0.0.0.0:8080
```

### Step 5：对话验证

**方式 1：命令行直接对话**

```bash
# 另开一个终端
cd ~/ai-tools/llama.cpp

./build/bin/llama-cli \
    -m ~/ai-models/Qwen3.5-2B.Q4_K_M.gguf \
    --threads $(nproc) \
    -p "你好，请介绍一下自己"
```

**方式 2：HTTP API 调用**

```bash
# 测试 API
curl http://localhost:8080/completion -d '{
  "prompt": "你好，请介绍一下自己",
  "n_predict": 128,
  "temperature": 0.7
}'
```

**方式 3：OpenAI 兼容格式**

```bash
curl http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d '{
  "model": "qwen3.5-2b",
  "messages": [{"role": "user", "content": "你好"}],
  "temperature": 0.7
}'
```

### 一键部署脚本

```bash
#!/bin/bash
set -e

echo "===== llama.cpp 一键部署 Qwen3.5-2B ====="

MODEL_DIR="$HOME/ai-models"
TOOLS_DIR="$HOME/ai-tools"
MODEL_FILE="$MODEL_DIR/Qwen3.5-2B.Q4_K_M.gguf"

# Step 1: 安装依赖
echo "[1/5] 安装编译依赖..."
sudo apt update
sudo apt install -y build-essential git cmake curl

# Step 2: 编译 llama.cpp
echo "[2/5] 编译 llama.cpp（ARM 优化版）..."
mkdir -p "$TOOLS_DIR"
cd "$TOOLS_DIR"

if [ ! -d "llama.cpp" ]; then
    git clone https://github.com/ggerganov/llama.cpp.git
fi

cd llama.cpp
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DGGML_OPENMP=ON
make -j$(nproc)

echo "编译完成！"

# Step 3: 下载模型
echo "[3/5] 下载 Qwen3.5-2B GGUF 模型..."
mkdir -p "$MODEL_DIR"
cd "$MODEL_DIR"

if [ ! -f "$MODEL_FILE" ]; then
    # 尝试用 hf 命令
    if command -v hf &> /dev/null; then
        hf download modelscope/unsloth/Qwen3.5-2B-GGUF --local-dir ./Qwen3.5-2B-GGUF
        cp Qwen3.5-2B-GGUF/Qwen3.5-2B.Q4_K_M.gguf .
    else
        # 备用：wget 直接下载
        wget -O Qwen3.5-2B.Q4_K_M.gguf \
            "https://hf-mirror.com/modelscope/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B.Q4_K_M.gguf"
    fi
else
    echo "模型已存在"
fi

# Step 4: 启动服务
echo "[4/5] 启动 llama-server..."
cd "$TOOLS_DIR/llama.cpp"
./build/bin/llama-server \
    -m "$MODEL_FILE" \
    --host 0.0.0.0 \
    --port 8080 \
    --ctx-size 4096 \
    --threads $(nproc) &

echo "[5/5] 等待服务启动..."
sleep 3

# Step 5: 测试
echo "测试对话..."
curl -s http://localhost:8080/completion -d '{
  "prompt": "你好，请简短介绍自己",
  "n_predict": 100,
  "temperature": 0.7
}' | head -c 500

echo ""
echo "===== 部署完成 ====="
echo "API: http://localhost:8080"
echo "OpenAI兼容: http://localhost:8080/v1/chat/completions"
```

---

## 五、方案 C：Transformers 原生部署（最灵活）

> 直接用 HuggingFace 的 transformers 库加载模型，适合需要深度定制和调试的场景。

### Step 1：安装 Python 依赖

```bash
# 创建虚拟环境（推荐）
python3 -m venv ~/venvs/qwen35
source ~/venvs/qwen35/bin/activate

# 安装依赖
pip install torch --index-url https://download.pytorch.org/whl/cpu
pip install transformers accelerate sentencepiece
```

### Step 2：下载模型

```bash
# 设置镜像站
export HF_ENDPOINT=https://hf-mirror.com

# 用 Python 下载
python3 -c "
from transformers import AutoModelForCausalLM, AutoTokenizer

model_name = 'Qwen/Qwen3.5-2B-Instruct'

print('下载模型...')
tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained(
    model_name,
    trust_remote_code=True,
    torch_dtype='auto',
    device_map='auto'
)
print('下载完成！')
"
```

> 模型会自动缓存到 `~/.cache/huggingface/`（约 4GB）

### Step 3：运行推理

```python
#!/usr/bin/env python3
"""Qwen3.5-2B 对话测试脚本"""

from transformers import AutoModelForCausalLM, AutoTokenizer

# 加载模型
model_name = "Qwen/Qwen3.5-2B-Instruct"
tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained(
    model_name,
    trust_remote_code=True,
    torch_dtype="auto",
    device_map="auto"
)

# 对话循环
messages = []
print("===== Qwen3.5-2B 对话测试 =====")
print("输入 'quit' 退出\n")

while True:
    user_input = input("你: ")
    if user_input.lower() in ["quit", "exit", "退出"]:
        break

    messages.append({"role": "user", "content": user_input})

    # 生成回答
    text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = tokenizer([text], return_tensors="pt").to(model.device)

    outputs = model.generate(
        **inputs,
        max_new_tokens=512,
        temperature=0.7,
        top_p=0.9
    )

    response = tokenizer.batch_decode(outputs[:, inputs.input_ids.shape[1]:], skip_special_tokens=True)[0]
    print(f"AI: {response}\n")
    messages.append({"role": "assistant", "content": response})

print("对话结束！")
```

---

## 六、对话验证：三种方案的通用测试方法

无论用哪种方案，部署完成后用以下方法验证模型是否正常工作：

### 测试 1：基础对话

```
输入：你好，请简短介绍自己
期望：模型输出一段自我介绍（中文）
```

### 测试 2：代码能力

```
输入：用 Python 写一个冒泡排序
期望：输出正确的 Python 代码
```

### 测试 3：逻辑推理

```
输入：如果所有的猫都会爬树，Tom 是一只猫，Tom 会爬树吗？
期望：正确回答"会"
```

### 测试 4：具身智能相关

```
输入：什么是具身智能？它与普通人工智能有什么区别？
期望：输出具身智能的定义和核心区别
```

### 性能评估

记录以下指标：

| 指标 | 良好标准 | 测量方法 |
|------|---------|---------|
| 首次加载时间 | < 30 秒 | 从启动到能对话的时间 |
| 生成速度 | > 3 t/s（每秒3个字） | 对话时观察 |
| 内存占用 | < 2GB | `free -h` 查看 |

---

## 七、具身智能体集成思路

部署 Qwen3.5-2B 只是第一步。要构建具身智能体，需要把大模型与 R005 的控制能力连接起来：

```
传感器（摄像头/雷达/力传感器）
    ↓
感知模块（物体检测、姿态估计）
    ↓
Qwen3.5-2B 推理（决策规划、自然语言理解）
    ↓
运动控制（EtherCAT/CAN 总线 → 电机/关节）
    ↓
执行器（机械臂/轮子/灵巧手）
```

### 集成方式

**方式 1：HTTP API 调用（推荐）**

```python
import requests

def robot_brain(prompt):
    """调用本地部署的 Qwen3.5-2B 做决策"""
    response = requests.post("http://localhost:8080/v1/chat/completions", json={
        "model": "qwen3.5-2b",
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.7
    })
    return response.json()["choices"][0]["message"]["content"]

# 示例：让机器人决策
decision = robot_brain(""
    "传感器数据：前方30厘米有障碍物，左侧有空位。"
    "任务目标：前进到目标点。"
    "请给出下一步动作指令（前进/左转/右转/停止）。"
"")
print(decision)  # 输出：建议左转避开障碍物
```

**方式 2：本地 Python 库调用**

```python
from transformers import AutoModelForCausalLM, AutoTokenizer

class EmbodiedAgent:
    def __init__(self):
        self.tokenizer = AutoTokenizer.from_pretrained("Qwen/Qwen3.5-2B-Instruct", trust_remote_code=True)
        self.model = AutoModelForCausalLM.from_pretrained("Qwen/Qwen3.5-2B-Instruct", trust_remote_code=True)

    def perceive_and_act(self, sensor_data, task):
        prompt = f"传感器数据：{sensor_data}\n任务：{task}\n请给出动作指令："
        response = self.generate(prompt)
        return self.parse_action(response)

    def generate(self, prompt):
        # ... 推理逻辑 ...
        pass

    def parse_action(self, response):
        # 解析模型输出为控制指令
        pass
```

---

## 八、常见问题排查

### 问题 1：`ollama: command not found`

```bash
# 检查安装路径
which ollama
# 如果没输出，手动添加 PATH
export PATH=$PATH:/usr/local/bin

# 或重新安装
curl -fsSL https://ollama.com/install.sh | sh
```

### 问题 2：`Illegal instruction (core dumped)`

**原因**：llama.cpp 编译时启用了本机不支持的指令集。

**解决**：
```bash
# 重新编译，禁用本机优化，使用通用 ARM 指令集
cmake .. -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF
make -j$(nproc)
```

### 问题 3：模型下载失败 / 网络不通

```bash
# 检查镜像站
export HF_ENDPOINT=https://hf-mirror.com
curl -I https://hf-mirror.com

# 如果网络不通，检查白泽系统的网络配置
ping www.baidu.com

# 或用 wget 直接下载 GGUF 文件（不依赖 huggingface_hub）
wget https://hf-mirror.com/xxx/xxx.gguf
```

### 问题 4：内存不足（OOM）

```bash
# 查看内存
free -h

# 解决方案：
# 1. 换更小的量化模型（Q4_K_M → Q3_K_M）
# 2. 减小 ctx-size（--ctx-size 2048）
# 3. 关闭其他程序
```

### 问题 5：推理速度太慢

```bash
# 检查 CPU 核心数
nproc
# 确保 --threads 参数等于核心数

# 检查是否启用了 NEON 加速（ARM 版 SSE）
cat /proc/cpuinfo | grep neon
# 应该有输出
```

---

**文档结束。建议先尝试方案 A（Ollama），5 分钟内就能看到效果；确认模型能跑后再切到方案 B（llama.cpp）获得最佳性能。**
