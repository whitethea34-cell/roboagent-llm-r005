# RoboAgent 框架 R005 适配说明

> **目标**: 复用 RoboAgent_CVPR26-main 的 Python 框架，接入 R005 上的 llama-server
> **核心思路**: 不改 RoboAgent 框架逻辑，只替换 VLM 推理的底层实现

---

## 一、为什么可以复用

RoboAgent 框架 (agent.py) 和 VLM 推理之间只有**一个接口函数**:

```python
# 文件: agents/qwen.py
def inference(processor, model, image_paths, prompt, ...):
    # 内部调用 HuggingFace transformers
    inputs = processor(text=..., images=...)
    output_ids = model.generate(**inputs, ...)
    return processor.decode(output_ids)
```

`agent.py` 的 7 种基础能力全部通过这个函数调用 VLM。只要替换这个函数的实现（改为 HTTP 调用 llama-server），整个框架就能在 R005 上跑。

---

## 二、需要修改的文件（只有 1 个）

### 修改 agents/agent.py 的 `__init__` (第 10~13 行)

```python
# === 原始代码 (依赖 HuggingFace + CUDA) ===
class Agent(object):
    def __init__(self, vlm_model_path, env_name="alfworld"):
        self.vlm = Qwen2_5_VLForConditionalGeneration.from_pretrained(
            vlm_model_path, torch_dtype=torch.bfloat16, device_map="auto"
        )
        self.vlm_processer = AutoProcessor.from_pretrained(vlm_model_path)

# === 替换为 (使用 HTTP 适配器) ===
class Agent(object):
    def __init__(self, vlm_model_path, env_name="alfworld"):
        from qwen_adapter import QwenAdapter
        self.adapter = QwenAdapter(server_url="http://localhost:8080/v1/chat/completions")
        # 保留 vlm_processer 引用以兼容后续代码
        self.vlm_processer = self.adapter
```

### 修改 agents/agent.py 的 import (第 4 行)

```python
# === 原始 ===
from agents.qwen import inference as qwen_inference

# === 替换为 ===
# (不需要了，直接用 self.adapter.inference)
```

### 修改 agent.py 中所有 `qwen_inference(...)` 调用 → `self.adapter.inference(...)`

共计约 12 处，参数从 `(processor, model, images, prompt, ...)` 简化为 `(images, prompt, ...)`。

---

## 三、部署步骤

### Step 1: 确保 llama-server 在 R005 上运行

```bash
ssh admin@r005
bash ~/ai-r005/deploy_roboagent_r005.sh   # 如未部署
bash ~/ai-r005/start_server.sh            # 启动服务
curl http://localhost:8080/health          # 验证
```

### Step 2: 复制 RoboAgent 框架 + 适配器到 R005

```bash
# 在 x86 电脑上
scp -r RoboAgent_CVPR26-main/agents/          admin@r005:~/roboagent/
scp -r RoboAgent_CVPR26-main/runners/         admin@r005:~/roboagent/
scp    llm-r005/qwen_adapter.py               admin@r005:~/roboagent/
```

### Step 3: 在 R005 上安装 Python 依赖（轻量）

```bash
pip3 install requests pillow   # 只需要这两个，不需要 torch/transformers
```

### Step 4: 修改 agent.py（按上一节改 3 处）

### Step 5: 自定义环境运行

```python
from agents.agent import Agent

agent = Agent(vlm_model_path=None)  # 不再需要模型路径
agent.reset("/tmp/test")

# 调用能力
result = agent.call_ability("scene_description", None)
```

---

## 四、RoboAgent 的 7 种基础能力在 R005 上的效果估算

| 能力 | 输入 | 输出 | 预估延迟 (R005 CPU) |
|------|------|------|-------------------|
| object_grounding | 图片+目标名 | bounding box JSON | 15~25秒 |
| scene_description | 图片+对象名 | 场景文本描述 | 10~20秒 |
| exploration_planner | 纯文本目标 | 探索步骤列表 | 5~10秒 |
| manipulation_planner | 纯文本子任务 | 动作序列 | 5~10秒 |
| exploration_guidance | 纯文本目标 | 方向建议 | 3~5秒 |
| experience_summarization | 图片+历史 | 总结文本 | 10~20秒 |
| task_planner (CT) | 纯文本历史 | 下一步能力查询 | 5~15秒 |

一次完整的任务规划通常调用 5~15 次 VLM，总延迟 2~5 分钟。
**迁移到 NPU 后：每次调用 0.5~3 秒，总延迟 10~30 秒。**

---

## 五、关键风险与应对

| 风险 | 影响 | 应对 |
|------|------|------|
| llama-server 不支持多图输入 | object_grounding 和 scene_description 失败 | 检查 llama.cpp 的视觉支持版本 (需 >= b4000) |
| ARM CPU 推理太慢 (30秒/次) | 完整任务 5~10 分钟 | 先用纯文本能力 (exploration/manipulation planner)，少用图像能力 |
| qwen_adapter 和原版 inference 返回格式不完全一致 | 解析失败 | 适配器已做 strip() 处理；按需加 post-processing |
| R005 内存不足同时跑 server + Python 框架 | OOM | 用 Q3_K_M 量化模型释放内存 |

---

## 六、总结：你能复用什么，不能复用什么

| 能复用 | 不能复用 (需改造) |
|--------|-----------------|
| agent.py 的 7 种能力链逻辑 | agents/qwen.py (HuggingFace 推理) |
| prompt_aw.py / prompt_ebalf.py | model.generate() 的 sampling 参数 |
| runners/aw_runner.py 的执行循环 | PEFT LoRA 适配器加载 |
| 整个 "Chaining Basic Capabilities" 架构思想 | CUDA/bfloat16 推理 |

**核心改造量**: ~50 行适配器 + agent.py 中 3 处修改 (import, __init__, 12 处函数调用签名)。

---

## 七、文件清单

| 文件 | 用途 |
|------|------|
| `qwen_adapter.py` | HTTP 适配器，替代 HuggingFace transformers 推理 |
| `RoboAgent_R005_适配说明.md` | 本文档 |
| (无需改) `agents/agent.py` | RoboAgent 框架，只改 3 处 |
| (无需改) `agents/prompt_aw.py` | 7 种能力的 prompt 模板 |
| (无需改) `runners/aw_runner.py` | 环境交互循环 |
