"""On-demand image generation API for Apple silicon.

Serves Qwen-Image 2.1 through mflux (MLX) behind an OpenAI-style
`POST /v1/images/generations` endpoint. The model is not loaded at startup:
the first request loads it, and it is unloaded again after IMAGE_IDLE_UNLOAD
seconds without work, so the ~20-45 GB it needs is only held while in use.

All model work (load, generate, unload) runs on one dedicated thread, which
both keeps MLX on a single thread and serializes requests into a queue.
"""

from __future__ import annotations

import asyncio
import base64
import gc
import io
import logging
import os
import random
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field, field_validator

log = logging.getLogger("image-server")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

MODEL_ID = "qwen-image-2.1"
DEFAULT_QUANTIZE = int(os.environ.get("IMAGE_QUANTIZE", "8")) or None  # 0 = bf16
IDLE_UNLOAD = int(os.environ.get("IMAGE_IDLE_UNLOAD", "600"))
MAX_QUEUE = int(os.environ.get("IMAGE_MAX_QUEUE", "4"))
OUTPUT_DIR = Path(os.environ.get("IMAGE_OUTPUT_DIR", Path.home() / "image-server-outputs"))
OUTPUT_RETENTION_DAYS = int(os.environ.get("IMAGE_OUTPUT_RETENTION_DAYS", "7"))
MAX_SIDE = 2048

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


class ModelManager:
    """Owns the mflux model; every method runs on the single worker thread."""

    def __init__(self) -> None:
        self.model = None
        self.quantize: int | None = None
        self.loaded_at: float | None = None
        self.last_used: float | None = None

    def load(self, quantize: int | None) -> float:
        if self.model is not None and self.quantize == quantize:
            return 0.0
        self.unload()
        from mflux.models.common.config import ModelConfig
        from mflux.models.qwen21.variants.txt2img.qwen_image_21 import QwenImage21

        started = time.monotonic()
        log.info("loading %s (quantize=%s)", MODEL_ID, quantize)
        self.model = QwenImage21(quantize=quantize, model_config=ModelConfig.qwen_image_21())
        self.quantize = quantize
        self.loaded_at = time.time()
        self.last_used = time.time()
        took = time.monotonic() - started
        log.info("loaded in %.1fs", took)
        return took

    def unload(self) -> bool:
        if self.model is None:
            return False
        import mlx.core as mx

        log.info("unloading %s", MODEL_ID)
        self.model = None
        self.quantize = None
        self.loaded_at = None
        gc.collect()
        mx.clear_cache()
        return True

    def generate(self, *, quantize: int | None, **kwargs):
        load_seconds = self.load(quantize)
        started = time.monotonic()
        assert self.model is not None
        result = self.model.generate_image(**kwargs)
        self.last_used = time.time()
        return result.image, load_seconds, time.monotonic() - started


manager = ModelManager()
worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
state = {"pending": 0, "busy": False}


async def on_worker(fn, *args, **kwargs):
    return await asyncio.get_running_loop().run_in_executor(worker, lambda: fn(*args, **kwargs))


class GenerationRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=4000)
    model: str | None = None
    n: int = Field(1, ge=1, le=4)
    size: str = "1024x1024"
    response_format: Literal["b64_json", "url"] = "b64_json"
    seed: int | None = None
    steps: int = Field(40, ge=1, le=100)
    guidance: float = Field(1.0, ge=1.0, le=10.0)
    negative_prompt: str | None = None
    quantize: Literal[0, 4, 8] | None = Field(None, description="0 = bf16; default from IMAGE_QUANTIZE")

    @field_validator("size")
    @classmethod
    def check_size(cls, v: str) -> str:
        try:
            w, h = (int(x) for x in v.lower().split("x"))
        except ValueError:
            raise ValueError("size must look like 1024x1024")
        if not (256 <= w <= MAX_SIDE and 256 <= h <= MAX_SIDE) or w % 16 or h % 16:
            raise ValueError(f"width and height must be multiples of 16 between 256 and {MAX_SIDE}")
        return v


async def idle_watcher() -> None:
    while True:
        await asyncio.sleep(30)
        idle = time.time() - (manager.last_used or time.time())
        if manager.model is not None and not state["busy"] and state["pending"] == 0 and idle > IDLE_UNLOAD:
            log.info("idle for %ds, unloading", idle)
            await on_worker(manager.unload)
        prune_outputs()


def prune_outputs() -> None:
    cutoff = time.time() - OUTPUT_RETENTION_DAYS * 86400
    for f in OUTPUT_DIR.glob("*.png"):
        if f.stat().st_mtime < cutoff:
            f.unlink(missing_ok=True)


@asynccontextmanager
async def lifespan(_: FastAPI):
    watcher = asyncio.create_task(idle_watcher())
    yield
    watcher.cancel()
    await on_worker(manager.unload)


app = FastAPI(title="image-server", version="0.1.0", lifespan=lifespan)


@app.get("/health")
async def health():
    return {
        "model": MODEL_ID,
        "loaded": manager.model is not None,
        "quantize": manager.quantize,
        "default_quantize": DEFAULT_QUANTIZE,
        "busy": state["busy"],
        "queued": max(0, state["pending"] - (1 if state["busy"] else 0)),
        "idle_unload_seconds": IDLE_UNLOAD,
        "last_used": manager.last_used,
    }


@app.get("/v1/models")
async def models():
    return {"object": "list", "data": [{"id": MODEL_ID, "object": "model", "owned_by": "mflux"}]}


@app.post("/v1/load")
async def load(quantize: Literal[0, 4, 8] | None = None):
    q = DEFAULT_QUANTIZE if quantize is None else (quantize or None)
    took = await on_worker(manager.load, q)
    return {"loaded": True, "quantize": q, "load_seconds": round(took, 1)}


@app.post("/v1/unload")
async def unload():
    return {"unloaded": await on_worker(manager.unload)}


@app.post("/v1/images/generations")
async def generate(req: GenerationRequest, request: Request):
    if state["pending"] >= MAX_QUEUE:
        raise HTTPException(429, f"queue full ({MAX_QUEUE} requests pending); retry later")
    width, height = (int(x) for x in req.size.lower().split("x"))
    quantize = DEFAULT_QUANTIZE if req.quantize is None else (req.quantize or None)
    base_seed = req.seed if req.seed is not None else random.randrange(2**31)

    state["pending"] += 1
    try:
        data = []
        timings = {"load_seconds": 0.0, "generate_seconds": 0.0}
        for i in range(req.n):
            def run(seed=base_seed + i):
                state["busy"] = True
                try:
                    return manager.generate(
                        quantize=quantize, seed=seed, prompt=req.prompt, num_inference_steps=req.steps,
                        width=width, height=height, guidance=req.guidance, negative_prompt=req.negative_prompt,
                    )
                finally:
                    state["busy"] = False

            try:
                image, load_s, gen_s = await on_worker(run)
            except Exception as error:  # surface model/runtime failures as a clean API error
                log.exception("generation failed")
                raise HTTPException(500, f"generation failed: {error}") from error
            timings["load_seconds"] += load_s
            timings["generate_seconds"] += gen_s

            name = f"{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}.png"
            image.save(OUTPUT_DIR / name)
            if req.response_format == "url":
                data.append({"url": str(request.base_url).rstrip("/") + f"/images/{name}"})
            else:
                buf = io.BytesIO()
                image.save(buf, format="PNG")
                data.append({"b64_json": base64.b64encode(buf.getvalue()).decode()})
            data[-1]["seed"] = base_seed + i
        return {
            "created": int(time.time()),
            "model": MODEL_ID,
            "quantize": quantize,
            "data": data,
            **{k: round(v, 1) for k, v in timings.items()},
        }
    finally:
        state["pending"] -= 1


@app.get("/images/{name}")
async def image_file(name: str):
    path = (OUTPUT_DIR / name).resolve()
    if path.parent != OUTPUT_DIR.resolve() or not path.is_file():
        raise HTTPException(404, "not found")
    return FileResponse(path, media_type="image/png")
