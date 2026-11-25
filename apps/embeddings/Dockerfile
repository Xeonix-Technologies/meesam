# Build context = repository root (RAILWAY_DOCKERFILE_PATH=apps/embeddings/Dockerfile).
FROM python:3.12-slim AS runner
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8000 PIP_NO_CACHE_DIR=1 HF_HOME=/app/models
WORKDIR /app
COPY apps/embeddings/requirements.txt ./
RUN pip install --upgrade pip && pip install --extra-index-url https://download.pytorch.org/whl/cpu -r requirements.txt
# The model's files are put into the image now (SigLIP 2, Apache 2.0, public: no account and no key is needed);
# the running service fetches nothing (HF_HUB_OFFLINE below).
ARG SIGLIP_MODEL=google/siglip2-base-patch16-224
ENV SIGLIP_MODEL=${SIGLIP_MODEL}
RUN python -c "import os; from huggingface_hub import snapshot_download; snapshot_download(os.environ['SIGLIP_MODEL'], allow_patterns=['*.json', '*.safetensors', '*.model', '*.txt'])"
# DINOv3 ViT-B/16 (Meta's DINOv3 License, accepted 25 Nov 2026): its files are released only to the account that
# accepted the licence, so they are fetched only where the service's HF_TOKEN variable is set. Without it the
# image is built with SigLIP 2 alone and the service refuses a request for DINOv3. With it, a refusal by the
# model's page stops the build, so a missing access is seen at once. The key is used for this one step.
ARG HF_TOKEN=""
ARG DINO_MODEL=facebook/dinov3-vitb16-pretrain-lvd1689m
ENV DINO_MODEL=${DINO_MODEL}
RUN if [ -n "$HF_TOKEN" ]; then HF_TOKEN="$HF_TOKEN" python -c "import os; from huggingface_hub import snapshot_download; snapshot_download(os.environ['DINO_MODEL'], token=os.environ['HF_TOKEN'], allow_patterns=['*.json', '*.safetensors'])" && echo "DINOv3 files are in the image"; else echo "DINOv3 is not installed: no HF_TOKEN at build"; fi
ENV HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
COPY apps/embeddings/app ./app
RUN useradd -r -m app && chown -R app:app /app
USER app
EXPOSE 8000
# "::" listens on IPv6 and IPv4: the private network between services may be IPv6 only
CMD ["sh", "-c", "uvicorn app.main:app --host :: --port ${PORT}"]
