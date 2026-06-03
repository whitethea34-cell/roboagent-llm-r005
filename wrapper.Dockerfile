FROM python:3.12-slim
RUN pip install --no-cache-dir fastapi uvicorn httpx python-multipart
WORKDIR /app
COPY vision_wrapper.py .
EXPOSE 8088
CMD ["uvicorn", "vision_wrapper:app", "--host", "0.0.0.0", "--port", "8088"]
