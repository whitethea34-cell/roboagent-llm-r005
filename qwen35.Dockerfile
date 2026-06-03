# ============================================================
# Qwen3.5-2B Docker 镜像 (ARM64 + NVIDIA CUDA)
#
# 与 4090 共用同一套技术栈，多架构镜像自动选择 arm64
#
# 模型: Qwen3.5-2B (多模态VLM, 2.35B 参数)
# GGUF: Qwen3.5-2B-Q4_K_M.gguf
# 后端: llama.cpp + CUDA 全层 GPU 卸载
#
# 用法:
#   docker build -t qwen35-2b:r005 -f qwen35.Dockerfile .
# ============================================================

# --------------------------------------------------
# Stage 1: 编译 llama.cpp (CUDA 版)
# --------------------------------------------------
FROM nvidia/cuda:12.4.0-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 https://github.com/ggerganov/llama.cpp.git && \
    cd llama.cpp && \
    ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/libcuda.so && \
    ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/libcuda.so.1 && \
    mkdir build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_EXE_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs" \
        -DGGML_CUDA=ON \
        -DGGML_CUDA_F16=ON \
        -DGGML_CUDA_FA_ALL_QUANTS=ON \
        -DGGML_CUDA_FORCE_MMQ=ON \
        -DGGML_NATIVE=ON \
        -DLLAMA_BUILD_SERVER=ON && \
    make -j$(nproc) llama-server llama-cli

# --------------------------------------------------
# Stage 2: 运行时
# --------------------------------------------------
FROM nvidia/cuda:12.4.0-runtime-ubuntu22.04 AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /src/llama.cpp/build/bin/ /app/

ENV LD_LIBRARY_PATH=/app

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -fs http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/llama-server"]
CMD ["-m", "/app/models/model.gguf", \
     "--host", "0.0.0.0", \
     "--port", "8080", \
     "--ctx-size", "8192", \
     "--threads", "8", \
     "--threads-batch", "8", \
     "--batch-size", "512", \
     "--n-gpu-layers", "99", \
     "--cache-type-k", "q8_0", \
     "--cache-type-v", "q8_0", \
     "--flash-attn", "on", \
     "--reasoning", "off", \
     "--verbose"]
