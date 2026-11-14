# syntax=docker/dockerfile:1.7
# Build context = repository root (RAILWAY_DOCKERFILE_PATH=apps/embeddings/Dockerfile).
FROM python:3.12-slim AS runner
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8000 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY apps/embeddings/pyproject.toml ./
RUN pip install --upgrade pip && pip install "fastapi==0.115.6" "uvicorn[standard]==0.32.1" "pydantic==2.10.3"
COPY apps/embeddings/app ./app
RUN useradd -r -m app && chown -R app:app /app
USER app
EXPOSE 8000
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT}"]
