"""
RoboAgent VLM 适配器 —— 将对 HuggingFace transformers 的调用替换为
对 llama-server 的 HTTP 调用，使 RoboAgent 框架可以在 R005 上运行。

用法:
    from qwen_adapter import QwenAdapter
    adapter = QwenAdapter(server_url="http://localhost:8080")

    # 替代原来的 qwen_inference(processor, model, ...):
    result = adapter.inference(image_paths=["step_0.png"], prompt="Locate Apple in the image...")
"""

import base64, json, requests, time

class QwenAdapter:
    def __init__(self, server_url="http://localhost:8080/v1/chat/completions", model_name="qwen25-vl"):
        self.api_url = server_url
        self.model = model_name
        self.history = []

    def inference(self, image_paths, prompt, sys_prompt="You are a helpful assistant.",
                  max_new_tokens=4096, temperature=0.7, more_args=None, log_file=None):
        """
        与 agents/qwen.py 里的 inference() 签名兼容。
        image_paths: 图片路径列表
        prompt: 文本提示
        返回: 模型生成的文本
        """
        content = []
        for img_path in (image_paths or []):
            b64 = self._encode_image(img_path)
            content.append({
                "type": "image_url",
                "image_url": {"url": f"data:image/jpeg;base64,{b64}"}
            })
        content.append({"type": "text", "text": prompt})

        messages = [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": content}
        ]

        payload = {
            "model": self.model,
            "messages": messages,
            "temperature": more_args.get("temperature", temperature) if more_args else temperature,
            "max_tokens": max_new_tokens
        }

        # 重试机制 (R005 ARM CPU 推理较慢)
        for attempt in range(3):
            try:
                resp = requests.post(self.api_url, json=payload, timeout=180)
                resp.raise_for_status()
                result = resp.json()["choices"][0]["message"]["content"]
                break
            except Exception as e:
                if attempt == 2:
                    raise RuntimeError(f"llama-server 调用失败: {e}")
                time.sleep(5)

        if log_file:
            with open(log_file, "a", encoding="utf-8") as f:
                f.write(f"[IMAGE] {image_paths}\n")
                f.write(f"[PROMPT] {prompt[:500]}\n")
                f.write(f"[RESPONSE] {result[:500]}\n")
                f.write("=" * 50 + "\n")

        return result

    def _encode_image(self, image_path):
        with open(image_path, "rb") as f:
            return base64.b64encode(f.read()).decode("utf-8")


# ============================================================
# 与原版 qwen.py inference() 的对比用法
# ============================================================
if __name__ == "__main__":
    adapter = QwenAdapter()

    # 原来: qwen_inference(processor, model, [img], prompt, ...)
    # 现在: adapter.inference([img], prompt, ...)

    result = adapter.inference(
        image_paths=[],
        prompt="场景:厨房。任务:做一个汉堡包。请给出分步动作计划。"
    )
    print(result)
