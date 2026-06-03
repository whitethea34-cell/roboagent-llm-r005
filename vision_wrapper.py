"""RoboAgent Vision Wrapper — file upload + OpenAI-compatible proxy to llama-server."""

import base64
import os

import httpx
from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse

VLM_BASE = os.environ.get("VLM_BASE_URL", "http://host.docker.internal:8082")
CLIENT_TIMEOUT = float(os.environ.get("VLM_TIMEOUT", "180"))

app = FastAPI(title="RoboAgent Vision Wrapper", version="1.0.0")
client = httpx.AsyncClient(timeout=CLIENT_TIMEOUT)


@app.post("/vision")
async def vision(
    image: UploadFile = File(...),
    prompt: str = Form(...),
    system: str = Form("You are a helpful assistant."),
    temperature: float = Form(0.7),
    max_tokens: int = Form(4096),
    model: str = Form(""),
):
    """Accept an image file, encode to base64, forward to VLM backend."""
    contents = await image.read()
    b64 = base64.b64encode(contents).decode("utf-8")
    mime = image.content_type or "image/jpeg"

    payload = {
        "messages": [
            {"role": "system", "content": system},
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:{mime};base64,{b64}"},
                    },
                    {"type": "text", "text": prompt},
                ],
            },
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
    }
    if model:
        payload["model"] = model

    r = await client.post(f"{VLM_BASE}/v1/chat/completions", json=payload)
    r.raise_for_status()
    result = r.json()["choices"][0]["message"]["content"]
    return {"text": result, "model": model or "(default)"}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    """Transparent proxy to llama-server OpenAI-compatible API."""
    body = await request.json()
    r = await client.post(f"{VLM_BASE}/v1/chat/completions", json=body)
    return JSONResponse(content=r.json(), status_code=r.status_code)


@app.get("/v1/models")
async def models():
    """Proxy model list from llama-server."""
    r = await client.get(f"{VLM_BASE}/v1/models")
    return JSONResponse(content=r.json(), status_code=r.status_code)


@app.get("/health")
async def health():
    """Health check including backend reachability."""
    try:
        r = await client.get(f"{VLM_BASE}/health")
        return {"status": "ok", "backend": r.json()}
    except Exception as e:
        return JSONResponse(
            {"status": "degraded", "backend": str(e)}, status_code=502
        )
