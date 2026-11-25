"""Meesam embeddings service: a picture or a text in, its vector out.

Two frozen pretrained backbones (Data Architecture 14.3): SigLIP 2 (Apache 2.0), and DINOv3 ViT-B/16 (Meta's
DINOv3 License, accepted by the Founder on 25 Nov 2026; its files are released only to the account that accepted
it). Their files are put into the image when the service is built, and nothing is fetched while it runs. Where
the DINOv3 files are not in the image (no access key at build), asking for DINOv3 is refused, never answered by
the other model. Built with DINOv3.

A picture is prepared the same way every time, and that way is part of the engine's name stored beside every
vector: laid on white (a transparent logo would otherwise turn black), padded to a square so a wide mark is not
squeezed, then given to the model's own image processor. The vector is scaled to length 1.

The service is reached only inside the project's private network (the worker calls it); it has no public address.
"""
from __future__ import annotations

import base64
import io
import os
from contextlib import asynccontextmanager
from typing import Literal

import numpy as np
from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel, Field

SIGLIP = os.getenv("SIGLIP_MODEL", "google/siglip2-base-patch16-224")
DINO = os.getenv("DINO_MODEL", "facebook/dinov3-vitb16-pretrain-lvd1689m")
PREPARE = "white-square-1"           # how a picture is prepared; a change here is a new engine
MAX_PIXELS = 40_000_000              # a picture larger than this is refused, not read
Image.MAX_IMAGE_PIXELS = MAX_PIXELS

state: dict = {"model": None, "images": None, "tokens": None, "revision": None, "error": None,
               "dino": None, "dino_images": None, "dino_revision": None, "dino_error": None}


def load() -> None:
    import torch
    from transformers import AutoImageProcessor, AutoModel, AutoTokenizer

    torch.set_num_threads(max(1, int(os.getenv("TORCH_THREADS", "2"))))
    model = AutoModel.from_pretrained(SIGLIP).eval()
    state["images"] = AutoImageProcessor.from_pretrained(SIGLIP)
    state["tokens"] = AutoTokenizer.from_pretrained(SIGLIP)
    state["revision"] = (getattr(model.config, "_commit_hash", None) or "unknown")[:12]
    state["model"] = model
    # DINOv3 is there only where its files were put into the image; without them the service runs with SigLIP 2 alone
    try:
        dino = AutoModel.from_pretrained(DINO).eval()
        state["dino_images"] = AutoImageProcessor.from_pretrained(DINO)
        state["dino_revision"] = (getattr(dino.config, "_commit_hash", None) or "unknown")[:12]
        state["dino"] = dino
    except Exception as e:
        state["dino_error"] = f"{type(e).__name__}: {e}"[:200]


@asynccontextmanager
async def lifespan(_: FastAPI):
    try:
        load()
    except Exception as e:  # the service still answers /health, saying what is wrong
        state["error"] = f"{type(e).__name__}: {e}"[:300]
    yield


app = FastAPI(title="Meesam embeddings", version="0.3.0", docs_url=None, redoc_url=None, lifespan=lifespan)


class EmbedRequest(BaseModel):
    kind: Literal["image", "text"]
    # Base64-encoded image bytes or UTF-8 text, depending on kind.
    payload: str = Field(min_length=1, max_length=40_000_000)
    model: Literal["dinov3", "siglip2"] = "siglip2"


class EmbedResponse(BaseModel):
    model: str
    engine: str
    dim: int
    vector: list[float]
    phash: str | None = None


def engine(model: str = "siglip2") -> str:
    if model == "dinov3":
        return f"{DINO.split('/')[-1]}@{state['dino_revision']}+{PREPARE}"
    return f"{SIGLIP.split('/')[-1]}@{state['revision']}+{PREPARE}"


def prepared(raw: bytes) -> Image.Image:
    """The picture on white, padded to a square."""
    img = Image.open(io.BytesIO(raw))
    img.load()
    if img.mode in ("RGBA", "LA", "PA") or (img.mode == "P" and "transparency" in img.info):
        rgba = img.convert("RGBA")
        white = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        img = Image.alpha_composite(white, rgba).convert("RGB")
    else:
        img = img.convert("RGB")
    side = max(img.size)
    square = Image.new("RGB", (side, side), (255, 255, 255))
    square.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
    return square


def phash(img: Image.Image) -> str:
    """A 64-bit perceptual hash (the low frequencies of a 32 by 32 grey copy), as 16 hex digits: equal for exact copies."""
    g = np.asarray(img.convert("L").resize((32, 32), Image.LANCZOS), dtype=np.float64)
    n = 32
    k = np.arange(n)
    basis = np.cos(np.pi * (2 * k[None, :] + 1) * k[:, None] / (2 * n))
    low = (basis @ g @ basis.T)[:8, :8]
    bits = (low > np.median(low)).flatten()
    return f"{int(''.join('1' if b else '0' for b in bits), 2):016x}"


def unit(t) -> list[float]:
    v = t[0].detach().float().numpy().astype(np.float64)
    norm = float(np.linalg.norm(v))
    if not np.isfinite(norm) or norm == 0:
        raise HTTPException(status_code=422, detail="the model gave no usable vector")
    return [float(x) for x in (v / norm)]


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "service": "embeddings",
        "models_loaded": state["model"] is not None,
        "models": (["siglip2"] if state["model"] is not None else []) + (["dinov3"] if state["dino"] is not None else []),
        "engine": engine() if state["model"] is not None else None,
        "engines": {m: engine(m) for m, on in (("siglip2", state["model"]), ("dinov3", state["dino"])) if on is not None},
        "error": state["error"],
        "dinov3_missing": None if state["dino"] is not None else (state["dino_error"] or "not loaded"),
        "environment": os.getenv("RAILWAY_ENVIRONMENT_NAME", "local"),
    }


@app.post("/embed", response_model=EmbedResponse)
def embed(req: EmbedRequest) -> EmbedResponse:
    import torch

    if req.model == "dinov3":
        if state["dino"] is None:
            raise HTTPException(status_code=501, detail="DINOv3 is not installed in this service (its files were not in the image)")
        if req.kind != "image":
            raise HTTPException(status_code=422, detail="DINOv3 reads pictures only")
        try:
            img = prepared(base64.b64decode(req.payload, validate=True))
        except Exception as e:
            raise HTTPException(status_code=422, detail=f"the picture could not be opened: {type(e).__name__}") from e
        inputs = state["dino_images"](images=[img], return_tensors="pt")
        with torch.inference_mode():
            vector = unit(state["dino"](**inputs).pooler_output)
        return EmbedResponse(model="dinov3", engine=engine("dinov3"), dim=len(vector), vector=vector, phash=phash(img))
    model = state["model"]
    if model is None:
        raise HTTPException(status_code=503, detail=f"the model is not loaded{': ' + state['error'] if state['error'] else ''}")
    if req.kind == "text":
        text = req.payload.strip().lower()[:400]
        if not text:
            raise HTTPException(status_code=422, detail="empty text")
        # SigLIP 2 was trained with lower-cased text padded to 64 tokens
        tokens = state["tokens"]([text], padding="max_length", max_length=64, truncation=True, return_tensors="pt")
        with torch.inference_mode():
            vector = unit(model.get_text_features(**tokens))
        return EmbedResponse(model="siglip2", engine=engine(), dim=len(vector), vector=vector)
    try:
        raw = base64.b64decode(req.payload, validate=True)
        img = prepared(raw)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=422, detail=f"the picture could not be opened: {type(e).__name__}") from e
    inputs = state["images"](images=[img], return_tensors="pt")
    with torch.inference_mode():
        vector = unit(model.get_image_features(**inputs))
    return EmbedResponse(model="siglip2", engine=engine(), dim=len(vector), vector=vector, phash=phash(img))
