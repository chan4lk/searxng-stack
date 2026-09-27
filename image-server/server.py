"""On-demand image generation API for Apple silicon.

Serves Qwen-Image 2.1 through mflux (MLX) behind OpenAI-style endpoints:

- POST /v1/images/generations   text-to-image; optional transparent (RGBA)
                                output; optional `image` + `strength` for
                                strength-based image-to-image
- POST /v1/images/edits         instruction edits over 1-10 reference images:
                                change, restyle, or combine/merge them

The model is not loaded at startup: the first request loads it, and it is
unloaded again after IMAGE_IDLE_UNLOAD seconds without work. Only one variant
is resident at a time. `edit` (QwenImage21Edit, with the vision tower and
prefix KV cache) serves generations and edits; `img2img` (QwenImage21) is
loaded only for strength-based image-to-image, swapping the other out.

All model work runs on one dedicated thread, which keeps MLX on a single
thread and serializes requests into a queue.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import gc
import io
import logging
import os
import random
import tempfile
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Callable, Literal

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
GB = 1024**3
# Memory guardrails. MLX's set_memory_limit is only a guideline (it raises only
# once RAM and swap are exhausted), so the real guard is checking what macOS
# reports as available before loading and before each generation.
MEMORY_LIMIT_GB = float(os.environ.get("IMAGE_MEMORY_LIMIT_GB", "32"))
CACHE_LIMIT_GB = float(os.environ.get("IMAGE_CACHE_LIMIT_GB", "2"))
HEADROOM_GB = float(os.environ.get("IMAGE_MEMORY_HEADROOM_GB", "4"))
AUTO_DOWNGRADE = os.environ.get("IMAGE_AUTO_DOWNGRADE", "1") == "1"
# Conservative starting estimates of peak GB per (variant, quantize); replaced
# by the largest peak actually observed once a variant has run.
PEAK_ESTIMATE_GB = {
    ("edit", None): 46, ("edit", 8): 28, ("edit", 4): 22,
    ("img2img", None): 46, ("img2img", 8): 26, ("img2img", 4): 20,
}
MAX_REFERENCES = 10
MAX_INPUT_BYTES = 25 * 1024 * 1024
# Wording the mflux docs use to ask Qwen-Image 2.1 for a transparent (RGBA) result.
TRANSPARENT_PREFIX = "This is an RGBA image with transparency. "
TRANSPARENT_SUFFIX = " The image has alpha channel and the background is transparent."

Variant = Literal["edit", "img2img"]
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


class MemoryGuardError(RuntimeError):
    """Refused because the Mac doesn't have the memory for this request right now."""


def available_gb() -> float:
    import psutil

    return psutil.virtual_memory().available / GB


def configure_mlx_limits() -> None:
    import mlx.core as mx

    mx.set_memory_limit(int(MEMORY_LIMIT_GB * GB))
    mx.set_cache_limit(int(CACHE_LIMIT_GB * GB))


PEAKS_FILE = Path(os.environ.get("IMAGE_PEAKS_FILE", Path.home() / ".image-server-peaks.json"))


def load_peaks() -> dict[tuple[str, int | None], float]:
    """Observed peaks survive restarts, so the guard never falls back to guesses once calibrated."""
    import json

    try:
        raw = json.loads(PEAKS_FILE.read_text())
        return {(v, None if q == "bf16" else int(q)): float(p) for key, p in raw.items() for v, q in [key.split("/")]}
    except (OSError, ValueError):
        return {}


def save_peaks() -> None:
    import json

    PEAKS_FILE.write_text(json.dumps({f"{v}/{'bf16' if q is None else q}": round(p, 2) for (v, q), p in observed_peak_gb.items()}))


observed_peak_gb: dict[tuple[str, int | None], float] = load_peaks()


def expected_peak_gb(variant: str, quantize: int | None) -> float:
    return observed_peak_gb.get((variant, quantize), PEAK_ESTIMATE_GB[(variant, quantize)])


def fallback_chain(quantize: int | None) -> list[int | None]:
    """Quantization levels to try, from the requested one down to 4-bit."""
    chain = [None, 8, 4]
    chain = chain[chain.index(quantize):]
    return chain if AUTO_DOWNGRADE else chain[:1]


class ModelManager:
    """Owns the one resident mflux model; every method runs on the worker thread."""

    def __init__(self) -> None:
        self.model = None
        self.variant: Variant | None = None
        self.quantize: int | None = None
        self.last_used: float | None = None

    def load(self, variant: Variant, quantize: int | None) -> tuple[float, int | None]:
        """Load `variant`, stepping down the quantization if memory is short.

        Returns (seconds spent loading, quantization actually loaded).
        """
        # Reuse the resident model if it's at the requested level or one the guard
        # would step down to anyway; reloading just to fail the same check churns.
        if self.model is not None and self.variant == variant and self.quantize in fallback_chain(quantize):
            return 0.0, self.quantize
        self.unload()
        free = available_gb()
        for q in fallback_chain(quantize):
            need = expected_peak_gb(variant, q) + HEADROOM_GB
            if free >= need:
                if q != quantize:
                    log.warning("memory guard: %.1f GB available, stepping %s -> %s", free, quantize, q)
                return self._load(variant, q), q
        need = expected_peak_gb(variant, fallback_chain(quantize)[-1]) + HEADROOM_GB
        raise MemoryGuardError(
            f"not enough free memory to load the {variant} model: ~{need:.0f} GB needed "
            f"(peak estimate + {HEADROOM_GB:.0f} GB headroom), {free:.1f} GB available. "
            "Free memory on the Mac (e.g. stop or shrink the local LLM) or retry with a lower quantize."
        )

    def _load(self, variant: Variant, quantize: int | None) -> float:
        started = time.monotonic()
        log.info("loading %s variant=%s quantize=%s", MODEL_ID, variant, quantize)
        if variant == "edit":
            from mflux.models.qwen21.reference import QwenImage21Edit

            self.model = QwenImage21Edit(quantize=quantize)
        else:
            from mflux.models.common.config import ModelConfig
            from mflux.models.qwen21.variants.txt2img.qwen_image_21 import QwenImage21

            self.model = QwenImage21(quantize=quantize, model_config=ModelConfig.qwen_image_21())
        self.variant, self.quantize, self.last_used = variant, quantize, time.time()
        took = time.monotonic() - started
        log.info("loaded in %.1fs", took)
        return took

    def unload(self) -> bool:
        if self.model is None:
            return False
        import mlx.core as mx

        log.info("unloading %s variant=%s", MODEL_ID, self.variant)
        self.model = self.variant = self.quantize = None
        gc.collect()
        mx.clear_cache()
        return True

    def generate(self, *, variant: Variant, quantize: int | None, **kwargs):
        import mlx.core as mx

        load_seconds, quantize = self.load(variant, quantize)
        assert self.model is not None
        # Generation needs working memory on top of the resident weights.
        working = max(0.0, expected_peak_gb(variant, quantize) - mx.get_active_memory() / GB)
        free = available_gb()
        if free < working + HEADROOM_GB:
            raise MemoryGuardError(
                f"not enough free memory to generate right now: ~{working + HEADROOM_GB:.0f} GB needed, "
                f"{free:.1f} GB available. Retry shortly or free memory on the Mac."
            )
        mx.reset_peak_memory()
        started = time.monotonic()
        try:
            result = self.model.generate_image(**kwargs)
        finally:
            mx.clear_cache()
        peak = mx.get_peak_memory() / GB
        key = (variant, quantize)
        if peak > observed_peak_gb.get(key, 0.0):
            observed_peak_gb[key] = peak
            save_peaks()
        self.last_used = time.time()
        return result.image, load_seconds, time.monotonic() - started, quantize, peak


manager = ModelManager()
worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
state = {"pending": 0, "busy": False}


async def on_worker(fn, *args, **kwargs):
    return await asyncio.get_running_loop().run_in_executor(worker, lambda: fn(*args, **kwargs))


def parse_size(v: str) -> tuple[int, int]:
    try:
        w, h = (int(x) for x in v.lower().split("x"))
    except ValueError:
        raise ValueError("size must look like 1024x1024")
    if not (256 <= w <= MAX_SIDE and 256 <= h <= MAX_SIDE) or w % 32 or h % 32:
        raise ValueError(f"width and height must be multiples of 32 between 256 and {MAX_SIDE}")
    return w, h


def decode_image(data: str, label: str, into: Path) -> Path:
    """Decode a base64 or data-URL image, validate it, and write it as PNG."""
    from PIL import Image

    raw = data.split(",", 1)[1] if data.startswith("data:") else data
    try:
        blob = base64.b64decode(raw, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(422, f"{label} is not valid base64")
    if len(blob) > MAX_INPUT_BYTES:
        raise HTTPException(413, f"{label} is larger than {MAX_INPUT_BYTES // (1024 * 1024)} MB")
    try:
        image = Image.open(io.BytesIO(blob))
        image.load()
    except Exception:
        raise HTTPException(422, f"{label} is not a readable image")
    if max(image.size) > 8192:
        raise HTTPException(422, f"{label} is {image.size[0]}x{image.size[1]}; the longest side must be at most 8192")
    path = into / f"{label}.png"
    image.save(path, format="PNG")
    return path


def transparent_fraction(image) -> float:
    """Share of pixels that are (nearly) fully transparent; 0.0 for images without alpha."""
    if "A" not in image.getbands():
        return 0.0
    hist = image.getchannel("A").histogram()
    return round(sum(hist[:16]) / (image.width * image.height), 3)


def wrap_transparent(prompt: str, transparent: bool) -> str:
    return f"{TRANSPARENT_PREFIX}{prompt}{TRANSPARENT_SUFFIX}" if transparent else prompt


class CommonRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=4000)
    model: str | None = None
    n: int = Field(1, ge=1, le=4)
    response_format: Literal["b64_json", "url"] = "b64_json"
    seed: int | None = None
    steps: int = Field(40, ge=1, le=100)
    guidance: float = Field(1.0, ge=1.0, le=10.0)
    negative_prompt: str | None = None
    transparent: bool = Field(False, description="Ask for an RGBA result with a transparent background")
    quantize: Literal[0, 4, 8] | None = Field(None, description="0 = bf16; default from IMAGE_QUANTIZE")


class GenerationRequest(CommonRequest):
    size: str = "1024x1024"
    image: str | None = Field(None, description="Optional init image (base64 or data URL) for image-to-image")
    strength: float | None = Field(None, ge=0.05, le=0.95, description="How much to change `image`: 0.05 = barely, 0.95 = almost fully redrawn; default 0.6")

    @field_validator("size")
    @classmethod
    def check_size(cls, v: str) -> str:
        parse_size(v)
        return v


class EditRequest(CommonRequest):
    images: list[str] = Field(min_length=1, max_length=MAX_REFERENCES, description="Reference images, base64 or data URLs, in order")
    size: str | None = Field(None, description="Output WxH; default follows the last reference's aspect ratio")
    output_resolution: int = Field(1024, ge=256, le=MAX_SIDE, description="Pixel-area budget per reference and for automatic output size")

    @field_validator("size")
    @classmethod
    def check_size(cls, v: str | None) -> str | None:
        if v is not None:
            parse_size(v)
        return v


async def run_jobs(req: CommonRequest, request: Request, variant: Variant, kwargs_for: Callable[[int], dict]) -> dict:
    """Queue req.n generations on the worker and package them OpenAI-style."""
    if state["pending"] >= MAX_QUEUE:
        raise HTTPException(429, f"queue full ({MAX_QUEUE} requests pending); retry later")
    quantize = DEFAULT_QUANTIZE if req.quantize is None else (req.quantize or None)
    base_seed = req.seed if req.seed is not None else random.randrange(2**31)

    state["pending"] += 1
    try:
        data, timings = [], {"load_seconds": 0.0, "generate_seconds": 0.0, "peak_memory_gb": 0.0}
        for i in range(req.n):
            def run(seed=base_seed + i):
                state["busy"] = True
                try:
                    return manager.generate(variant=variant, quantize=quantize, seed=seed, **kwargs_for(seed))
                finally:
                    state["busy"] = False

            try:
                image, load_s, gen_s, used_q, peak = await on_worker(run)
            except HTTPException:
                raise
            except MemoryGuardError as error:
                log.warning("memory guard: %s", error)
                raise HTTPException(503, str(error)) from error
            except Exception as error:  # surface model/runtime failures as a clean API error
                log.exception("generation failed")
                raise HTTPException(500, f"generation failed: {error}") from error
            timings["load_seconds"] += load_s
            timings["generate_seconds"] += gen_s
            quantize = used_q
            timings["peak_memory_gb"] = max(timings.get("peak_memory_gb", 0.0), peak)

            name = f"{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}.png"
            image.save(OUTPUT_DIR / name)
            if req.response_format == "url":
                item = {"url": str(request.base_url).rstrip("/") + f"/images/{name}"}
            else:
                buf = io.BytesIO()
                image.save(buf, format="PNG")
                item = {"b64_json": base64.b64encode(buf.getvalue()).decode()}
            data.append({**item, "seed": base_seed + i, "width": image.width, "height": image.height, "mode": image.mode,
                         "transparent_fraction": transparent_fraction(image)})
        return {
            "created": int(time.time()),
            "model": MODEL_ID,
            "variant": variant,
            "quantize": quantize,
            "data": data,
            **{k: round(v, 1) for k, v in timings.items()},
        }
    finally:
        state["pending"] -= 1


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
    await on_worker(configure_mlx_limits)
    watcher = asyncio.create_task(idle_watcher())
    yield
    watcher.cancel()
    await on_worker(manager.unload)


app = FastAPI(title="image-server", version="0.3.0", lifespan=lifespan)


@app.get("/health")
async def health():
    return {
        "model": MODEL_ID,
        "loaded": manager.model is not None,
        "variant": manager.variant,
        "quantize": manager.quantize,
        "default_quantize": DEFAULT_QUANTIZE,
        "busy": state["busy"],
        "queued": max(0, state["pending"] - (1 if state["busy"] else 0)),
        "idle_unload_seconds": IDLE_UNLOAD,
        "last_used": manager.last_used,
        "memory": {
            "available_gb": round(available_gb(), 1),
            "headroom_gb": HEADROOM_GB,
            "mlx_memory_limit_gb": MEMORY_LIMIT_GB,
            "mlx_cache_limit_gb": CACHE_LIMIT_GB,
            "auto_downgrade": AUTO_DOWNGRADE,
            "observed_peak_gb": {f"{v}/{'bf16' if q is None else f'q{q}'}": round(p, 1) for (v, q), p in observed_peak_gb.items()},
        },
    }


@app.get("/v1/models")
async def models():
    return {"object": "list", "data": [{"id": MODEL_ID, "object": "model", "owned_by": "mflux",
                                        "capabilities": ["generate", "transparent", "img2img", "edit", "multi-reference"]}]}


@app.post("/v1/load")
async def load(variant: Variant = "edit", quantize: Literal[0, 4, 8] | None = None):
    q = DEFAULT_QUANTIZE if quantize is None else (quantize or None)
    try:
        took, used = await on_worker(manager.load, variant, q)
    except MemoryGuardError as error:
        raise HTTPException(503, str(error)) from error
    return {"loaded": True, "variant": variant, "quantize": used, "load_seconds": round(took, 1)}


@app.post("/v1/unload")
async def unload():
    return {"unloaded": await on_worker(manager.unload)}


@app.post("/v1/images/generations")
async def generate(req: GenerationRequest, request: Request):
    width, height = parse_size(req.size)
    prompt = wrap_transparent(req.prompt, req.transparent)
    if req.image is None:
        return await run_jobs(req, request, "edit", lambda _seed: dict(
            prompt=prompt, num_inference_steps=req.steps, width=width, height=height,
            guidance=req.guidance, negative_prompt=req.negative_prompt,
        ))
    with tempfile.TemporaryDirectory(prefix="img2img-") as tmp:
        init = decode_image(req.image, "image", Path(tmp))
        return await run_jobs(req, request, "img2img", lambda _seed: dict(
            prompt=prompt, num_inference_steps=req.steps, width=width, height=height,
            guidance=req.guidance, negative_prompt=req.negative_prompt,
            # mflux's image_strength is the fraction of the init image KEPT; the API's
            # strength follows the usual convention (higher = more change).
            image_path=init, image_strength=1.0 - (req.strength if req.strength is not None else 0.6),
        ))


@app.post("/v1/images/edits")
async def edit(req: EditRequest, request: Request):
    size = parse_size(req.size) if req.size else None
    prompt = wrap_transparent(req.prompt, req.transparent)
    with tempfile.TemporaryDirectory(prefix="edit-") as tmp:
        refs = [decode_image(img, f"image{i + 1}", Path(tmp)) for i, img in enumerate(req.images)]
        return await run_jobs(req, request, "edit", lambda _seed: dict(
            prompt=prompt, num_inference_steps=req.steps, guidance=req.guidance,
            negative_prompt=req.negative_prompt, image_paths=refs, output_resolution=req.output_resolution,
            **({"width": size[0], "height": size[1]} if size else {}),
        ))


@app.get("/images/{name}")
async def image_file(name: str):
    path = (OUTPUT_DIR / name).resolve()
    if path.parent != OUTPUT_DIR.resolve() or not path.is_file():
        raise HTTPException(404, "not found")
    return FileResponse(path, media_type="image/png")
