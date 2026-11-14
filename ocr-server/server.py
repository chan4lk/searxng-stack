"""On-demand OCR API for Apple silicon, backed by Surya 2 (datalab-to/surya-ocr-2).

Surya 2 is a 650M-parameter OCR VLM served by llama.cpp's `llama-server` from
its Q4 GGUF. It reads 90+ languages, Sinhala and Tamil included, which general
LLMs and PDF text layers get wrong. This service supervises that server:

- The first request starts `llama-server` as a child process on loopback and
  waits for it; later requests reuse it.
- Each page goes through surya's own full-page recognition (one prompt per
  page, block-mode fallback when the output loops or doesn't parse), one page
  at a time.
- After OCR_IDLE_UNLOAD seconds without work the child process is stopped,
  which returns every byte of its memory to the machine.

Endpoints: POST /v1/ocr (raw PDF or image bytes as the body, or JSON with the
file base64-encoded), GET /health,
POST /v1/unload.
"""

from __future__ import annotations

import asyncio
import base64
import gc
import html
import io
import json
import logging
import os
import re
import signal
import subprocess
import tempfile
import time
import urllib.request
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, HTTPException, Query, Request

log = logging.getLogger("ocr-server")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

MODELS_DIR = Path(os.environ.get("OCR_MODELS_DIR", Path(__file__).parent / "models"))
MODEL, MMPROJ = MODELS_DIR / "surya-2.gguf", MODELS_DIR / "surya-2-mmproj.gguf"
BACKEND_PORT = int(os.environ.get("OCR_BACKEND_PORT", "8124"))
BACKEND = f"http://127.0.0.1:{BACKEND_PORT}"
CTX = os.environ.get("OCR_CTX", "65536")
IDLE_UNLOAD = int(os.environ.get("OCR_IDLE_UNLOAD", "600"))
MAX_QUEUE = int(os.environ.get("OCR_MAX_QUEUE", "4"))
MAX_PAGES = int(os.environ.get("OCR_MAX_PAGES", "100"))
MAX_BYTES = int(os.environ.get("OCR_MAX_MB", "100")) * 1024 * 1024
STARTUP_TIMEOUT = int(os.environ.get("OCR_STARTUP_TIMEOUT", "300"))
BACKEND_LOG = Path(os.environ.get("OCR_BACKEND_LOG", Path.home() / "Library/Logs/ocr-backend.log"))

# surya reads these at import time: talk to our llama-server, never spawn its own.
os.environ.update({
    "SURYA_INFERENCE_BACKEND": "llamacpp",
    "SURYA_INFERENCE_URL": BACKEND,
    "SURYA_INFERENCE_AUTOSTART": "false",
    "SURYA_INFERENCE_KEEP_ALIVE": "true",
    "SURYA_INFERENCE_PARALLEL": "1",
})
# llama-server rejects requests whose model name differs from what surya sends.
SURYA_ALIAS = "datalab-to/surya-ocr-2"

state = {"pending": 0, "busy": False, "last_used": None}
lock = asyncio.Lock()
_predictor = None


def predictor():
    global _predictor
    if _predictor is None:
        from surya.inference import SuryaInferenceManager
        from surya.recognition import RecognitionPredictor
        _predictor = RecognitionPredictor(SuryaInferenceManager(method="llamacpp"))
    return _predictor


class _InferenceErrors(logging.Handler):
    """surya logs a failed request as a warning and returns an empty page; count them."""

    def __init__(self) -> None:
        super().__init__(level=logging.WARNING)
        self.count = 0

    def emit(self, record: logging.LogRecord) -> None:
        if "Inference error" in record.getMessage():
            self.count += 1


# --- backend process lifecycle ---------------------------------------------

def _healthy() -> bool:
    try:
        with urllib.request.urlopen(BACKEND + "/health", timeout=3) as resp:
            return resp.status == 200
    except Exception:
        return False


class Backend:
    """The llama-server child process: started on demand, stopped when idle."""

    def __init__(self) -> None:
        self.proc: subprocess.Popen | None = None

    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    async def ensure(self) -> float:
        """Start the backend if needed; returns seconds spent starting it."""
        if await asyncio.to_thread(_healthy):
            return 0.0
        if not (MODEL.is_file() and MMPROJ.is_file()):
            raise HTTPException(500, f"model files missing in {MODELS_DIR}; run ./ocr-server.sh install")
        started = time.monotonic()
        BACKEND_LOG.parent.mkdir(parents=True, exist_ok=True)
        log.info("starting llama-server (surya-2, ctx %s)", CTX)
        self.proc = subprocess.Popen(
            ["llama-server", "-m", str(MODEL), "--mmproj", str(MMPROJ), "-c", CTX, "--parallel", "1",
             "-ngl", "99", "--jinja", "--host", "127.0.0.1", "--port", str(BACKEND_PORT), "--alias", SURYA_ALIAS],
            stdout=open(BACKEND_LOG, "ab"), stderr=subprocess.STDOUT, start_new_session=True,
        )
        while time.monotonic() - started < STARTUP_TIMEOUT:
            if self.proc.poll() is not None:
                raise HTTPException(500, f"llama-server exited during startup (code {self.proc.returncode}); see {BACKEND_LOG}")
            if await asyncio.to_thread(_healthy):
                took = time.monotonic() - started
                log.info("llama-server ready in %.1fs", took)
                return took
            await asyncio.sleep(1)
        await self.stop()
        raise HTTPException(504, f"llama-server did not become healthy within {STARTUP_TIMEOUT}s")

    async def stop(self) -> bool:
        if not self.running():
            self.proc = None
            return False
        log.info("stopping llama-server")
        self.proc.send_signal(signal.SIGTERM)
        for _ in range(30):
            if self.proc.poll() is not None:
                break
            await asyncio.sleep(1)
        else:
            self.proc.kill()
        self.proc = None
        return True


backend = Backend()


# --- OCR ----------------------------------------------------------------------

def parse_pages(spec: str | None, count: int) -> list[int]:
    """"1-3,5" -> [0, 1, 2, 4] (0-based); None -> every page."""
    if not spec:
        return list(range(count))
    pages: list[int] = []
    for part in spec.split(","):
        a, _, b = part.strip().partition("-")
        try:
            lo, hi = int(a), int(b or a)
        except ValueError:
            raise HTTPException(422, f"bad pages spec {spec!r}; use e.g. 1-3,5")
        if not 1 <= lo <= hi <= count:
            raise HTTPException(422, f"pages {part.strip()} out of range 1-{count}")
        pages.extend(range(lo - 1, hi))
    return list(dict.fromkeys(pages))


def block_text(block_html: str) -> str:
    text = re.sub(r"\s*\n\s*", " ", block_html)  # source newlines aren't meaningful in HTML
    text = re.sub(r"</(p|div|tr|li|h\d)>|<br\s*/?>", "\n", text, flags=re.I)
    text = re.sub(r"</t[dh]>", "\t", text, flags=re.I)
    text = html.unescape(re.sub(r"<[^>]+>", "", text))
    return re.sub(r"\n\s*\n+", "\n", text).strip()


def page_out(result, fmt: str) -> str:
    blocks = sorted(result.blocks, key=lambda b: b.reading_order)
    parts = [b.html if fmt == "html" else block_text(b.html) for b in blocks if not (b.skipped or b.error)]
    return "\n\n".join(p for p in parts if p.strip())


def run_ocr(data: bytes, is_pdf: bool, pages: str | None, dpi: int, fmt: str) -> list[dict]:
    from PIL import Image

    errors = _InferenceErrors()
    client_log = logging.getLogger("surya.inference.backends.openai_client")
    client_log.addHandler(errors)
    out = []
    try:
        if not is_pdf:
            image = Image.open(io.BytesIO(data)).convert("RGB")
            (result,) = predictor()([image], full_page=True)
            out.append({"page": 1, "text": page_out(result, fmt)})
        else:
            import pypdfium2 as pdfium

            with tempfile.NamedTemporaryFile(suffix=".pdf") as tmp:
                tmp.write(data)
                tmp.flush()
                doc = pdfium.PdfDocument(tmp.name)
                try:
                    wanted = parse_pages(pages, len(doc))
                    if len(wanted) > MAX_PAGES:
                        raise HTTPException(413, f"{len(wanted)} pages requested; the limit is {MAX_PAGES} per call, use pages=")
                    for i in wanted:  # one page in flight at a time
                        image = doc[i].render(scale=dpi / 72).to_pil().convert("RGB")
                        (result,) = predictor()([image], full_page=True)
                        del image
                        gc.collect()
                        out.append({"page": i + 1, "text": page_out(result, fmt)})
                finally:
                    doc.close()
    finally:
        client_log.removeHandler(errors)
    if errors.count:
        raise HTTPException(502, f"{errors.count} OCR request(s) to llama-server failed; see {BACKEND_LOG}")
    return out


# --- API ----------------------------------------------------------------------

async def idle_watcher() -> None:
    while True:
        await asyncio.sleep(30)
        idle = time.time() - (state["last_used"] or time.time())
        if backend.running() and not state["busy"] and state["pending"] == 0 and idle > IDLE_UNLOAD:
            log.info("idle for %ds, stopping backend", idle)
            await backend.stop()


@asynccontextmanager
async def lifespan(_: FastAPI):
    watcher = asyncio.create_task(idle_watcher())
    yield
    watcher.cancel()
    await backend.stop()


app = FastAPI(title="ocr-server", version="0.1.0", lifespan=lifespan)


@app.get("/health")
async def health():
    return {
        "model": SURYA_ALIAS,
        "models_ready": MODEL.is_file() and MMPROJ.is_file(),
        "backend_running": backend.running(),
        "busy": state["busy"],
        "queued": max(0, state["pending"] - (1 if state["busy"] else 0)),
        "idle_unload_seconds": IDLE_UNLOAD,
        "last_used": state["last_used"],
    }


@app.post("/v1/unload")
async def unload():
    if state["busy"] or state["pending"]:
        raise HTTPException(409, "a job is running or queued")
    return {"stopped": await backend.stop()}


@app.post("/v1/ocr")
async def ocr(
    request: Request,
    filename: str = Query("upload", description="Echoed back and logged"),
    pages: str | None = Query(None, description='1-based pages of a PDF, e.g. "1-3,5"; default all'),
    dpi: int = Query(192, ge=72, le=400, description="PDF render resolution"),
    format: Literal["text", "html"] = Query("text", description="Plain text, or surya's block HTML (keeps tables)"),
):
    data = await request.body()
    if request.headers.get("content-type", "").startswith("application/json"):
        # JSON clients: {"file": "<base64 or data: URL>", "filename"?, "pages"?, "dpi"?, "format"?}
        try:
            body = json.loads(data)
            data = base64.b64decode(body["file"].split(",", 1)[-1], validate=True)
        except (ValueError, KeyError, TypeError, AttributeError):
            raise HTTPException(422, 'JSON body must be {"file": "<base64>", ...}')
        filename = body.get("filename", filename)
        pages = body.get("pages", pages)
        dpi = int(body.get("dpi", dpi))
        format = body.get("format", format)
        if not 72 <= dpi <= 400 or format not in ("text", "html"):
            raise HTTPException(422, "dpi must be 72-400 and format text or html")
    if not data:
        raise HTTPException(422, "send the PDF or image bytes as the request body")
    if len(data) > MAX_BYTES:
        raise HTTPException(413, f"file is over {MAX_BYTES // 1024 // 1024} MB")
    is_pdf = b"%PDF-" in data[:1024]  # the PDF header; some writers put junk before it
    if state["pending"] >= MAX_QUEUE:
        raise HTTPException(429, f"queue full ({MAX_QUEUE} requests pending); retry later")
    state["pending"] += 1
    try:
        async with lock:
            state["busy"] = True
            try:
                started = time.monotonic()
                startup_s = await backend.ensure()
                result = await asyncio.to_thread(run_ocr, data, is_pdf, pages, dpi, format)
                elapsed = time.monotonic() - started
            except HTTPException:
                raise
            except Exception as error:
                log.exception("ocr failed")
                raise HTTPException(500, f"ocr failed: {error}") from error
            finally:
                state["busy"] = False
                state["last_used"] = time.time()
    finally:
        state["pending"] -= 1
    log.info("%s: %d page(s) in %.1fs", filename, len(result), elapsed)
    return {
        "model": SURYA_ALIAS,
        "filename": filename,
        "format": format,
        "pages": result,
        "startup_seconds": round(startup_s, 1),
        "seconds": round(elapsed, 1),
    }
