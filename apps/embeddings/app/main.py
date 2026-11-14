"""Meesam embeddings service.

Step 2 scope: health endpoint and the API contract. Model loading (DINOv3 for image→image,
SigLIP 2 for cross-mode word↔device, perceptual hash as a cheap pre-filter) arrives in Step 3.8.
The models are frozen pretrained backbones by ruling (Data Architecture 14.3).
"""
from __future__ import annotations

import os
from typing import Literal

from fastapi import FastAPI
from pydantic import BaseModel, Field

app = FastAPI(title="Meesam embeddings", version="0.1.0", docs_url=None, redoc_url=None)


class EmbedRequest(BaseModel):
    kind: Literal["image", "text"]
    # Base64-encoded image bytes or UTF-8 text, depending on kind.
    payload: str = Field(min_length=1)
    model: Literal["dinov3", "siglip2"] = "siglip2"


class EmbedResponse(BaseModel):
    model: str
    dim: int
    vector: list[float]
    phash: str | None = None


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "service": "embeddings",
        "models_loaded": False,
        "environment": os.getenv("RAILWAY_ENVIRONMENT_NAME", "local"),
    }


@app.post("/embed", response_model=EmbedResponse)
def embed(req: EmbedRequest) -> EmbedResponse:
    # Placeholder contract so the worker can be wired end to end before models land.
    raise NotImplementedError("Model loading arrives in Step 3.8 (MSM-PRD-02 Section 6).")
