# Build context = repository root (RAILWAY_DOCKERFILE_PATH=apps/embeddings/Dockerfile).
FROM python:3.12-slim AS runner
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8000 PIP_NO_CACHE_DIR=1 HF_HOME=/app/models
WORKDIR /app
COPY apps/embeddings/requirements.txt ./
RUN pip install --upgrade pip && pip install --extra-index-url https://download.pytorch.org/whl/cpu -r requirements.txt
# The model's files are put into the image now (SigLIP 2, Apache 2.0, public: no account and no key is needed);
# the running service fetches nothing (HF_HUB_OFFLINE below). DINOv3 is not installed: its licence review is open.
ARG SIGLIP_MODEL=google/siglip2-base-patch16-224
ENV SIGLIP_MODEL=${SIGLIP_MODEL}
RUN python -c "import os; from huggingface_hub import snapshot_download; snapshot_download(os.environ['SIGLIP_MODEL'], allow_patterns=['*.json', '*.safetensors', '*.model', '*.txt'])"
ENV HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
COPY apps/embeddings/app ./app
RUN useradd -r -m app && chown -R app:app /app
USER app
EXPOSE 8000
# "::" listens on IPv6 and IPv4: the private network between services may be IPv6 only
CMD ["sh", "-c", "uvicorn app.main:app --host :: --port ${PORT}"]
