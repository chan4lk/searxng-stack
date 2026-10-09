"""GLiNER2.5-Decide (fastino) behind a small HTTP API.

A 340M-parameter DeBERTa-v3 classifier for operational decisions: intent
routing, urgency, sentiment, document type, multi-label tagging. It doesn't
generate text; you give it the text plus the label sets and it picks labels.

  POST /v1/classify   {"text": "...", "tasks": {...}}            -> {"result": {...}}
                      {"texts": ["...", ...], "tasks": {...}}    -> {"results": [{...}, ...]}
  GET  /health

`tasks` is passed straight to gliner2's classify_text:
  {"intent": ["refund_request", "bug_report", "other"]}                   single-label
  {"topics": {"labels": [...], "multi_label": true, "cls_threshold": 0.4}}  multi-label
Several tasks in one call share a single forward pass.

Options: threshold (0.5), include_confidence (false), long (false: use the
*_long variants, which chunk text past the encoder's window).

The model stays loaded (~1.5 GB) and runs on Apple's GPU (MPS) when available,
~40 ms per call on the M5 Max. Requests run one at a time.
"""

import asyncio
import os
from contextlib import asynccontextmanager
import threading
import time

import torch
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field, model_validator

MODEL_ID = os.environ.get("CLASSIFY_MODEL", "fastino/GLiNER2.5-Decide")
DEVICE = os.environ.get("CLASSIFY_DEVICE") or ("mps" if torch.backends.mps.is_available() else "cpu")
MAX_TEXTS = int(os.environ.get("CLASSIFY_MAX_TEXTS", "256"))
MAX_CHARS = int(os.environ.get("CLASSIFY_MAX_CHARS", "200000"))

_model = None
_lock = threading.Lock()
_stats = {"requests": 0, "texts": 0, "errors": 0, "started": time.time(), "load_s": None}


class ClassifyRequest(BaseModel):
    text: str | None = None
    texts: list[str] | None = None
    tasks: dict
    threshold: float = Field(0.5, ge=0.0, le=1.0)
    include_confidence: bool = False
    long: bool = False
    batch_size: int = Field(8, ge=1, le=64)

    @model_validator(mode="after")
    def _check(self):
        if (self.text is None) == (self.texts is None):
            raise ValueError("send exactly one of 'text' or 'texts'")
        items = [self.text] if self.text is not None else self.texts
        if not items or len(items) > MAX_TEXTS:
            raise ValueError(f"'texts' must have 1..{MAX_TEXTS} items")
        if sum(len(t) for t in items) > MAX_CHARS:
            raise ValueError(f"total text exceeds {MAX_CHARS} characters")
        if not self.tasks:
            raise ValueError("'tasks' must name at least one label set")
        return self


def _load():
    global _model
    from gliner2 import AutoExtractor

    t = time.time()
    model = AutoExtractor.from_pretrained(MODEL_ID)
    model.to(DEVICE)
    model.eval()
    _model = model
    _stats["load_s"] = round(time.time() - t, 1)


@asynccontextmanager
async def lifespan(_app):
    await asyncio.to_thread(_load)
    yield


app = FastAPI(title="classify-server", lifespan=lifespan)


def _run(req: ClassifyRequest):
    model = _model
    assert model is not None
    opts = dict(threshold=req.threshold, include_confidence=req.include_confidence)
    with _lock, torch.inference_mode():
        if req.text is not None:
            fn = model.classify_text_long if req.long else model.classify_text
            return {"result": fn(req.text, req.tasks, **opts)}
        fn = model.batch_classify_text_long if req.long else model.batch_classify_text
        return {"results": fn(req.texts, req.tasks, batch_size=req.batch_size, **opts)}


@app.post("/v1/classify")
async def classify(req: ClassifyRequest):
    if _model is None:
        raise HTTPException(503, "model is still loading")
    t = time.time()
    try:
        out = await asyncio.to_thread(_run, req)
    except (ValueError, KeyError, TypeError) as e:
        _stats["errors"] += 1
        raise HTTPException(400, f"bad tasks or options: {e}")
    _stats["requests"] += 1
    _stats["texts"] += len(req.texts) if req.texts is not None else 1
    out["model"] = MODEL_ID
    out["elapsed_ms"] = round((time.time() - t) * 1000)
    return out


@app.get("/health")
async def health():
    return {
        "status": "ok" if _model is not None else "loading",
        "model": MODEL_ID,
        "device": DEVICE,
        "busy": _lock.locked(),
        **_stats,
        "uptime_s": round(time.time() - _stats["started"]),
    }
