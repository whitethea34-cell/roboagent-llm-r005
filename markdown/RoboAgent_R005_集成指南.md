# 国讯芯微 R005 + RoboAgent 具身智能集成指南

> **硬件**：国讯芯微 NSPIC-R005 + 白泽操作系统  
> **部署模型**：Qwen2.5-VL-3B-Instruct（视觉语言基础模型）  
> **部署方式**：llama.cpp + GGUF 量化（CPU/NEON 推理）  
> **目标**：从"能跑模型"到"能控制机器人"的完整路径  
> **前置**：已成功运行 `deploy_roboagent_r005.sh` 并完成对话测试

---

## 目录

1. [你部署的是什么？与 RoboAgent 的关系](#一你部署的是什么与-roboagent-的关系)
2. [为什么不能直接加载 RoboAgent 原始权重？](#二为什么不能直接加载-roboagent-原始权重)
3. [从"对话"到"控制机器人"的架构](#三从对话到控制机器人的架构)
4. [具身智能闭环代码示例](#四具身智能闭环代码示例)
5. [R005 性能预期与优化](#五r005-性能预期与优化)
6. [从当前部署迁移到 RoboAgent 微调权重](#六从当前部署迁移到-roboagent-微调权重)
7. [常见问题](#七常见问题)

---

## 一、你部署的是什么？与 RoboAgent 的关系

### 当前部署的模型

```
模型名称：Qwen2.5-VL-3B-Instruct
类型：    视觉语言模型（Vision-Language Model, VLM）
能力：    看图 + 理解文字 + 回答问题
格式：    GGUF 量化（Q4_K_M，约 1.9GB）
推理引擎：llama.cpp（C++，ARM NEON 加速）
API：     OpenAI 兼容 REST API（http://localhost:8080）
```

### RoboAgent 是什么？

```
论文：    RoboAgent: Chaining Basic Capabilities for Embodied Task Planning (CVPR 2026)
基础模型：Qwen2.5-VL-3B-Instruct（和你部署的一样）
微调数据：ALFRED 数据集（室内家庭任务仿真）
权重：    woyut/RoboAgent_CVPR26（HuggingFace）
能力：    看图 → 理解任务 → 输出动作计划（如：GoTo fridge, Open fridge, PickUp apple）
```

**关系总结**：你部署的是 Qwen3.5-2B 多模态VLM（支持文本/图像/视频理解），RoboAgent 是在这个毛坯房上装修后的"精装房"（微调权重）。毛坯房能住（能看图说话），但精装房更懂家务（能做任务规划）。

---

## 二、为什么不能直接加载 RoboAgent 原始权重？

### 2.1 格式问题

| 项目 | RoboAgent 原始权重 | R005 能用的格式 |
|------|-------------------|---------------|
| 文件格式 | Safetensors（.safetensors） | GGUF（.gguf） |
| 加载方式 | transformers + PyTorch | llama.cpp |
| 依赖 | Python 3.12, CUDA 12.4, flash-attention | 不需要 CUDA |
| 架构 | x86 GPU 服务器 | ARM 嵌入式 |

**核心矛盾**：
- RoboAgent 原始代码要求 `pip install torch==2.6.0 --index-url https://download.pytorch.org/whl/cu124`
- R005 没有 NVIDIA GPU，装不了 CUDA 版 PyTorch
- R005 是 ARM 架构，flash-attention 的预编译 wheel 只有 x86 版本

### 2.2 当前现实路径

**Phase 1（现在）**：用 llama.cpp 跑 Qwen2.5-VL-3B 基础模型  
→ 能看图、能对话、能做简单规划  
→ **足够验证你的控制链路是否通畅**

**Phase 2（后续）**：把 RoboAgent 微调权重转换为 GGUF 格式  
→ 需要社区支持或自行转换（有一定技术门槛）  
→ 转换后在当前 llama.cpp 服务上直接替换模型文件即可

---

## 三、从"对话"到"控制机器人"的架构

### 3.1 具身智能闭环

```
┌─────────────────┐
│  摄像头/传感器   │  ← R005 GMSL/EtherCAT 接口接摄像头
└────────┬────────┘
         │ 图像帧
         ▼
┌─────────────────┐
│  图像预处理      │  ← 裁剪/缩放/编码为 base64
│  (Python/OpenCV) │
└────────┬────────┘
         │ HTTP POST
         ▼
┌─────────────────────────────┐
│   llama-server (localhost:8080) │  ← 你部署的服务
│   Qwen2.5-VL-3B GGUF          │
│   输入: 图片 + "任务: ..."     │
│   输出: "1.GoTo(apple)         │
│          2.PickUp(apple)       │
│          3.GoTo(table)        │
│          4.PutDown(apple)"     │
└────────┬────────────────────┘
         │ HTTP 返回文本
         ▼
┌─────────────────┐
│  动作解析器      │  ← Python 正则/字符串解析
│  (Python)        │    从模型输出提取结构化动作
└────────┬────────┘
         │ 结构化指令
         ▼
┌─────────────────┐
│  运动控制器      │  ← R005 小脑部分
│  (白泽系统)      │    EtherCAT/CAN 下发
└────────┬────────┘
         │ 电机指令
         ▼
┌─────────────────┐
│   执行器         │  ← 机械臂/轮子/灵巧手
│  (关节/轮子)     │
└─────────────────┘
```

### 3.2 你的 Python 代码位置

在 R005 上，你写的控制代码是一个 Python 脚本，它：
1. **读取摄像头**（OpenCV 或 R005 SDK）
2. **调用 llama-server**（HTTP 请求，走 localhost:8080）
3. **解析动作**（字符串处理，提取动作指令）
4. **下发控制**（通过白泽系统的控制接口或 ROS2）

---

## 四、具身智能闭环代码示例

### 4.1 完整的感知-推理-控制脚本

创建 `~/robot_control_loop.py`：

```python
#!/usr/bin/env python3
"""
R005 具身智能闭环控制示例
功能：摄像头取图 → 调用 llama-server 推理 → 解析动作 → 打印控制指令

实际部署时，把 print 替换为真实的电机控制代码
"""

import requests
import base64
import cv2
import json
import re
import time

# ============ 配置 ============
API_URL = "http://localhost:8080/v1/chat/completions"
MODEL_NAME = "qwen2.5-vl"
CAMERA_ID = 0  # R005 上摄像头的设备号

# ============ 模块 1: 视觉感知 ============

def capture_image(camera_id=0, save_path=None):
    """
    从摄像头捕获一帧图像
    
    R005 实际部署时，替换为：
    - GMSL 摄像头驱动
    - 或 ROS2 图像订阅 (/camera/image_raw)
    """
    cap = cv2.VideoCapture(camera_id)
    if not cap.isOpened():
        print("[ERR] 摄像头无法打开")
        return None
    
    ret, frame = cap.read()
    cap.release()
    
    if not ret:
        return None
    
    if save_path:
        cv2.imwrite(save_path, frame)
    
    return frame


def encode_image_to_base64(frame):
    """将 OpenCV 图像帧编码为 base64"""
    _, buffer = cv2.imencode('.jpg', frame)
    return base64.b64encode(buffer).decode('utf-8')


# ============ 模块 2: 大模型推理 ============

def call_llm_vision(image_b64, instruction):
    """
    调用本地 llama-server 进行视觉推理
    
    输入: image_b64 (base64), instruction (文字指令)
    输出: 模型的文字回答
    """
    payload = {
        "model": MODEL_NAME,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}
                    },
                    {
                        "type": "text",
                        "text": instruction
                    }
                ]
            }
        ],
        "temperature": 0.5,   # 任务规划用较低温度，输出更确定
        "max_tokens": 512
    }
    
    try:
        resp = requests.post(API_URL, json=payload, timeout=120)
        result = resp.json()
        return result["choices"][0]["message"]["content"]
    except Exception as e:
        return f"[ERROR] LLM 调用失败: {e}"


def call_llm_text(prompt):
    """
    纯文本推理（不需要图片时）
    """
    payload = {
        "model": MODEL_NAME,
        "messages": [
            {"role": "system", "content": "You are a robot task planner."},
            {"role": "user", "content": prompt}
        ],
        "temperature": 0.5,
        "max_tokens": 512
    }
    
    try:
        resp = requests.post(API_URL, json=payload, timeout=60)
        result = resp.json()
        return result["choices"][0]["message"]["content"]
    except Exception as e:
        return f"[ERROR] LLM 调用失败: {e}"


# ============ 模块 3: 动作解析 ============

def parse_actions(llm_output):
    """
    从模型输出中提取结构化动作
    
    期望模型输出格式：
        1. GoTo(apple)
        2. PickUp(apple)
        3. GoTo(table)
        4. PutDown(apple)
    
    解析为 Python 列表：
        [("GoTo", "apple"), ("PickUp", "apple"), ...]
    """
    actions = []
    
    # 匹配 "数字. 动作(对象)" 格式
    pattern = r'(?:\d+\.?\s*)?(\w+)\s*\(\s*([^)]+)\s*\)'
    matches = re.findall(pattern, llm_output)
    
    for action, target in matches:
        actions.append({
            "action": action.strip(),
            "target": target.strip()
        })
    
    # 如果没匹配到结构化格式，整段文本作为 "RawPlan"
    if not actions:
        actions.append({"action": "RawPlan", "target": llm_output.strip()})
    
    return actions


# ============ 模块 4: 运动控制（占位符） ============

def execute_action(action_dict):
    """
    执行单个动作
    
    R005 实际部署时，替换为真实的控制代码：
    - 调用白泽系统的运动控制 API
    - 或通过 EtherCAT 发送 PDO 数据
    - 或通过 ROS2 Action 发送目标
    """
    action = action_dict["action"]
    target = action_dict["target"]
    
    # 占位：打印到终端
    print(f"  [CONTROL] >>> {action}({target})")
    
    # TODO: 替换为真实控制代码
    # example (伪代码):
    # if action == "GoTo":
    #     nav.send_goal(target)
    # elif action == "PickUp":
    #     arm.gripper_close()
    #     ...
    
    time.sleep(0.5)  # 模拟执行时间


# ============ 主循环 ============

def main_loop():
    """具身智能主循环"""
    print("=" * 60)
    print("  R005 具身智能闭环控制")
    print("  API: " + API_URL)
    print("=" * 60)
    
    # 任务目标（可从语音/上位机接收）
    task_goal = "把桌子上的苹果拿到冰箱里"
    
    # Step 1: 取图
    print("\n[1/4] 捕获场景图像...")
    frame = capture_image(CAMERA_ID, save_path="/tmp/scene.jpg")
    if frame is None:
        print("[ERR] 图像捕获失败，退出")
        return
    print("  图像已保存: /tmp/scene.jpg")
    
    # Step 2: 视觉推理（理解场景 + 任务规划）
    print("\n[2/4] 视觉推理 + 任务规划...")
    img_b64 = encode_image_to_base64(frame)
    
    instruction = f"""
你是一个家用机器人助手。当前任务是: {task_goal}

请分析图片中的场景，并给出完成任务的详细步骤。
每步格式: 动作(对象)，例如:
- GoTo(table)
- PickUp(apple)
- GoTo(fridge)
- Open(fridge)
- PutDown(apple)
- Close(fridge)

只输出动作列表，不要解释。
"""
    
    llm_response = call_llm_vision(img_b64, instruction)
    print(f"  模型输出:\n{llm_response}")
    
    # Step 3: 解析动作
    print("\n[3/4] 解析结构化动作...")
    actions = parse_actions(llm_response)
    for i, act in enumerate(actions, 1):
        print(f"  步骤 {i}: {act['action']}({act['target']})")
    
    # Step 4: 执行控制
    print("\n[4/4] 下发控制指令...")
    for act in actions:
        execute_action(act)
    
    print("\n任务完成！")


if __name__ == "__main__":
    main_loop()
```

### 4.2 运行测试

```bash
# 1. 确保 llama-server 在运行
ps aux | grep llama-server
# 如果没运行，启动它：
# bash ~/ai-r005/start_server.sh

# 2. 运行控制脚本
python3 ~/robot_control_loop.py

# 输出示例：
# [1/4] 捕获场景图像...
# [2/4] 视觉推理 + 任务规划...
#   模型输出:
#   1. GoTo(table)
#   2. PickUp(apple)
#   3. GoTo(fridge)
#   4. Open(fridge)
#   5. PutDown(apple)
#   6. Close(fridge)
# [3/4] 解析结构化动作...
#   步骤 1: GoTo(table)
# [4/4] 下发控制指令...
#   [CONTROL] >>> GoTo(table)
#   [CONTROL] >>> PickUp(apple)
#   ...
```

---

## 五、R005 性能预期与优化

### 5.1 性能基准

在 R005（ARM 多核，无 GPU）上纯 CPU 推理 Qwen2.5-VL-3B Q4_K_M：

| 操作 | 预期时间 | 说明 |
|------|---------|------|
| 模型加载 | 30~60 秒 | 从磁盘读 1.9GB 到内存 |
| 视觉编码 | 5~15 秒 | 图片转视觉 token |
| 生成 100 tokens | 30~60 秒 | 纯 CPU，约 1.5~3 t/s |
| 纯文本 100 tokens | 20~40 秒 | 比视觉快，无需编码图片 |

**结论**：R005 能跑，但不够快。适合：**低频决策**（几秒规划一次），不适合实时视频流处理。

### 5.2 优化建议

**优化 1：降低图片分辨率**

```python
# 传给模型前，把图片缩小到 448x448 或更低
frame = cv2.resize(frame, (448, 448))
```

视觉 token 数量与图片面积成正比，缩小一半 = 速度提升 4 倍。

**优化 2：减少生成长度**

```python
# 只让模型输出动作列表，不要长篇解释
"max_tokens": 128  # 而不是 512
```

**优化 3：使用文本缓存避免重复视觉编码**

如果摄像头视角不变，先做一次视觉推理获取场景描述，后续对话只用纯文本：

```python
# 第一步：看图获取场景描述
scene_desc = call_llm_vision(img_b64, "描述这个场景里的所有物体")

# 后续：纯文本问答（快很多）
for task in tasks:
    plan = call_llm_text(f"场景: {scene_desc}\n任务: {task}")
```

**优化 4：量化到 Q3_K_M（如果内存紧张）**

```bash
# 下载更小模型
wget https://hf-mirror.com/unsloth/Qwen2.5-VL-3B-Instruct-GGUF/resolve/main/Qwen2.5-VL-3B-Instruct-Q3_K_M.gguf
# 替换 start_server.sh 里的 MODEL_FILE
```

**优化 5：使用 R005 NPU（如果可用）**

如果 R005 有专用 NPU 且驱动支持，编译 llama.cpp 时添加 NPU 后端：

```bash
# 需要查看白泽系统提供的 NPU SDK
cmake .. -DGGML_<NPU_BACKEND>=ON
```

---

## 六、从当前部署迁移到 RoboAgent 微调权重

### 6.1 迁移路径

```
Phase 1（当前）: llama.cpp + Qwen2.5-VL-3B-Instruct GGUF
    ↓ 你的控制代码已跑通，验证链路 OK
Phase 2（可选）: 加载 RoboAgent 微调权重
    ↓ 任务规划能力更强（ALFRED 微调）
Phase 3（最终）: 接入真实传感器 + 执行器
    ↓ 完整具身智能体
```

### 6.2 转换 RoboAgent 权重到 GGUF（技术路径）

当前 RoboAgent 权重（`woyut/RoboAgent_CVPR26`）是 safetensors 格式，需要转换为 GGUF 才能被 llama.cpp 加载。

**方法 A：等待社区转换（推荐，零基础友好）**

关注 HuggingFace 上的 `woyut/RoboAgent_CVPR26` 页面，如果作者或社区发布了 GGUF 版本，直接下载替换即可：

```bash
# 假设未来有 GGUF 版本
wget https://hf-mirror.com/woyut/RoboAgent_CVPR26-GGUF/resolve/main/RoboAgent-Q4_K_M.gguf
# 替换 start_server.sh 里的 MODEL_FILE
```

**方法 B：自行转换（需要技术能力）**

```bash
# 1. 安装转换工具
pip install transformers gguf

# 2. 下载 RoboAgent 原始权重
python -c "
from transformers import AutoModelForCausalLM
model = AutoModelForCausalLM.from_pretrained('woyut/RoboAgent_CVPR26', trust_remote_code=True)
model.save_pretrained('./roboagent_raw')
"

# 3. 使用 llama.cpp 的 convert_hf_to_gguf.py 转换
python llama.cpp/convert_hf_to_gguf.py \
    --src ./roboagent_raw \
    --dst ./RoboAgent-Q4_K_M.gguf \
    --outtype q4_k_m

# 4. 替换模型
mv RoboAgent-Q4_K_M.gguf ~/ai-r005/models/
# 修改 start_server.sh 指向新模型
```

> **注意**：转换 VLM（视觉语言模型）比多模态VLM 复杂，需要同时转换视觉编码器部分。建议等社区出官方 GGUF 版本。

### 6.3 当前可以先用 Qwen2.5-VL-3B 做什么？

即使没加载 RoboAgent 微调权重，当前部署已经可以：

| 能力 | 示例 prompt | 用途 |
|------|------------|------|
| 场景理解 | "描述图片里的场景" | 感知模块 |
| 任务规划 | "如何把苹果放到盘子里？" | 规划模块 |
| 物体识别 | "图片里有什么水果？" | 视觉检测 |
| 简单推理 | "桌子上有一杯水，我让它变凉应该怎么做？" | 常识推理 |

这些能力通过精心设计的 prompt，已经可以驱动简单的具身任务。

---

## 七、常见问题

### Q1: llama-server 启动后占用多少内存？

```bash
# 查看
ps aux | grep llama-server
# VSZ 列显示虚拟内存，RSS 列显示实际物理内存

# Qwen2.5-VL-3B Q4_K_M 通常占用 2~3GB RAM
# 如果加上视觉编码，峰值可能到 3.5GB
```

### Q2: 视觉推理报错 "clip/vision 相关"

llama.cpp 对视觉模型的支持还在完善中。如果报错：
- 确认下载的是 **带 vision 标签** 的 GGUF（文件名通常含 `vl` 或 `vision`）
- 检查 llama.cpp 版本是否 >= b4000（视觉支持较新）
- 如果视觉确实跑不通，先用 **多模态任务规划**（把场景描述作为文本输入）

### Q3: R005 上没有摄像头，怎么测试？

```bash
# 用本地图片测试
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-vl",
    "messages": [
      {"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/4AAQ..."}},
        {"type": "text", "text": "描述这个场景"}
      ]}
    ]
  }'

# 或用 test_vision.py 脚本
python3 ~/ai-r005/test_vision.py /path/to/any.jpg
```

### Q4: 能不能不用 llama.cpp，直接用 transformers 加载 RoboAgent？

理论上可以，但 R005 上会非常慢：

```python
# 需要安装大量依赖
pip install torch transformers accelerate sentencepiece qwen-vl-utils

# 加载模型（约 6GB 内存）
from transformers import AutoModelForVision2Seq, AutoProcessor
model = AutoModelForVision2Seq.from_pretrained(
    "woyut/RoboAgent_CVPR26",
    trust_remote_code=True,
    torch_dtype="auto",
    device_map="auto"
)
# R005 纯 CPU 推理 4B VLM 约 0.5~1 t/s，几乎不可用
```

**结论**：R005 上 llama.cpp 是唯一现实的选择。

### Q5: 后续如何接入 ROS2？

白泽系统兼容 ROS2。典型的接入方式：

```python
# ROS2 节点订阅摄像头话题，调用 llama-server，发布动作话题
import rclpy
from sensor_msgs.msg import Image
from std_msgs.msg import String

class RoboAgentNode(rclpy.node.Node):
    def __init__(self):
        super().__init__('roboagent_node')
        self.sub = self.create_subscription(Image, '/camera/image_raw', self.on_image, 10)
        self.pub = self.create_publisher(String, '/robot/actions', 10)
    
    def on_image(self, msg):
        img_b64 = encode_ros_image(msg)
        plan = call_llm_vision(img_b64, "规划下一步动作")
        actions = parse_actions(plan)
        self.pub.publish(String(data=json.dumps(actions)))
```

---

**文档结束。你的 R005 现在有了一个可以工作的视觉语言推理引擎，下一步就是把 `robot_control_loop.py` 里的 `execute_action()` 函数替换为真实的电机控制代码。**
