# Build context = repository root (RAILWAY_DOCKERFILE_PATH=apps/embeddings/Dockerfile).

# Stage 1: the models' files. SigLIP 2 (Apache 2.0) is public. DINOv3 ViT-B/16 (Meta's DINOv3 License, accepted
# 25 Nov 2026) is released only to the account that accepted the licence, so it is fetched only where the
# service's HF_TOKEN variable is set; without it the image holds SigLIP 2 alone and the service refuses a request
# for DINOv3. The key is read by the script from the environment: it is never written in a command here (a value
# written in a command is printed in the build log), and this stage's layers are not part of the final image.
FROM python:3.12-slim AS models
ENV PIP_NO_CACHE_DIR=1 HF_HOME=/models
RUN pip install "huggingface_hub>=0.34,<1.0"
ARG SIGLIP_MODEL=google/siglip2-base-patch16-224
ARG DINO_MODEL=facebook/dinov3-vitb16-pretrain-lvd1689m
ENV SIGLIP_MODEL=${SIGLIP_MODEL} DINO_MODEL=${DINO_MODEL}
COPY apps/embeddings/fetch_models.py /fetch_models.py
ARG HF_TOKEN
RUN python /fetch_models.py

# Stage 2: the service. Nothing is fetched while it runs (HF_HUB_OFFLINE).
FROM python:3.12-slim AS runner
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8000 PIP_NO_CACHE_DIR=1 HF_HOME=/app/models
WORKDIR /app
COPY apps/embeddings/requirements.txt ./
RUN pip install --upgrade pip && pip install --extra-index-url https://download.pytorch.org/whl/cpu -r requirements.txt
ARG SIGLIP_MODEL=google/siglip2-base-patch16-224
ARG DINO_MODEL=facebook/dinov3-vitb16-pretrain-lvd1689m
ENV SIGLIP_MODEL=${SIGLIP_MODEL} DINO_MODEL=${DINO_MODEL} HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
COPY --from=models /models /app/models
COPY apps/embeddings/app ./app
RUN useradd -r -m app && chown -R app:app /app
USER app
EXPOSE 8000
# "::" listens on IPv6 and IPv4: the private network between services may be IPv6 only
CMD ["sh", "-c", "uvicorn app.main:app --host :: --port ${PORT}"]
