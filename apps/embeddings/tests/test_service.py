"""The service with its real model: run in CI (the model is fetched there), not needed to start the service."""
import base64
import io

import numpy as np
from fastapi.testclient import TestClient
from PIL import Image, ImageDraw

from app.main import app, phash, prepared


def png(img: Image.Image) -> str:
    b = io.BytesIO()
    img.save(b, "PNG")
    return base64.b64encode(b.getvalue()).decode()


def word(text: str, size=(600, 160), ink=(0, 0, 0), paper=(255, 255, 255)) -> Image.Image:
    img = Image.new("RGB", size, paper)
    d = ImageDraw.Draw(img)
    d.text((30, 40), text, fill=ink, font_size=72)
    return img


def rings() -> Image.Image:
    img = Image.new("RGB", (400, 400), (255, 255, 255))
    d = ImageDraw.Draw(img)
    for r, c in ((180, (200, 0, 0)), (120, (0, 90, 200)), (60, (0, 150, 60))):
        d.ellipse((200 - r, 200 - r, 200 + r, 200 + r), outline=c, width=22)
    return img


def cos(a, b) -> float:
    return float(np.dot(np.array(a), np.array(b)))


def test_prepare_and_hash_without_model():
    a = word("CARRERA")
    assert prepared(base64.b64decode(png(a))).size == (600, 600)
    # a transparent logo lands on white, not on black
    t = Image.new("RGBA", (100, 50), (0, 0, 0, 0))
    assert prepared(base64.b64decode(png(t))).getpixel((50, 25)) == (255, 255, 255)
    assert phash(prepared(base64.b64decode(png(a)))) == phash(prepared(base64.b64decode(png(a.copy()))))
    assert phash(prepared(base64.b64decode(png(a)))) != phash(prepared(base64.b64decode(png(rings()))))
    assert len(phash(a)) == 16


def test_service_with_model():
    with TestClient(app) as c:
        h = c.get("/health").json()
        assert h["models_loaded"] is True, h
        assert h["models"] == ["siglip2"] and "white-square-1" in h["engine"]

        def emb(payload: str, kind="image", model="siglip2"):
            return c.post("/embed", json={"kind": kind, "payload": payload, "model": model})

        a = emb(png(word("CARRERA"))).json()
        assert a["dim"] == 768 and len(a["vector"]) == 768 and a["model"] == "siglip2" and a["engine"] == h["engine"]
        assert abs(float(np.linalg.norm(a["vector"])) - 1.0) < 1e-6
        again = emb(png(word("CARRERA"))).json()
        assert cos(a["vector"], again["vector"]) > 0.9999 and a["phash"] == again["phash"]
        near = emb(png(word("CARRERA", ink=(20, 20, 120), paper=(250, 250, 245)))).json()   # the same word in another colour
        far = emb(png(rings())).json()                                                       # a device with no word
        assert cos(a["vector"], near["vector"]) > cos(a["vector"], far["vector"]) + 0.05, (cos(a["vector"], near["vector"]), cos(a["vector"], far["vector"]))
        # a word and a picture of that word are nearer than the word and an unrelated device
        t = emb("carrera", kind="text").json()
        assert t["dim"] == 768 and t["phash"] is None
        assert cos(t["vector"], a["vector"]) > cos(t["vector"], far["vector"])
        # DINOv3 is refused until its licence review is closed; rubbish is refused, not embedded
        assert emb(png(rings()), model="dinov3").status_code == 501
        assert emb("bm90IGEgcGljdHVyZQ==").status_code == 422
        assert emb("not base64 !!").status_code == 422
