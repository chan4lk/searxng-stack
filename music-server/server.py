"""On-demand music generation API for Apple silicon, backed by ACE-Step 1.5.

ACE-Step ships its own API server (async submit/poll, models kept resident,
no unload). This service supervises it instead of reimplementing it:

- The first request starts `acestep-api` (MLX LM backend) as a child process
  on loopback and waits for it; later requests reuse it.
- Each request is submitted to it, polled to completion, and the audio is
  downloaded into OUTPUT_DIR, so callers get one synchronous call.
- After MUSIC_IDLE_UNLOAD seconds without work the child process is stopped,
  which returns every byte of its memory to the machine.

Endpoints: POST /v1/music/generations, GET /music/<name>, GET /health,
POST /v1/unload.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import signal
import subprocess
import time
import urllib.parse
import urllib.request
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

log = logging.getLogger("music-server")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

ACE_DIR = Path(os.environ.get("ACE_STEP_DIR", Path.home() / "ace-step"))
BACKEND_PORT = int(os.environ.get("ACE_STEP_PORT", "8001"))
BACKEND = f"http://127.0.0.1:{BACKEND_PORT}"
LM_MODEL = os.environ.get("ACE_STEP_LM_MODEL", "acestep-5Hz-lm-1.7B")
IDLE_UNLOAD = int(os.environ.get("MUSIC_IDLE_UNLOAD", "600"))
MAX_QUEUE = int(os.environ.get("MUSIC_MAX_QUEUE", "4"))
JOB_TIMEOUT = int(os.environ.get("MUSIC_JOB_TIMEOUT", "1800"))
STARTUP_TIMEOUT = int(os.environ.get("MUSIC_STARTUP_TIMEOUT", "300"))
OUTPUT_DIR = Path(os.environ.get("MUSIC_OUTPUT_DIR", Path.home() / "music-server-outputs"))
OUTPUT_RETENTION_DAYS = int(os.environ.get("MUSIC_OUTPUT_RETENTION_DAYS", "14"))
BACKEND_LOG = Path(os.environ.get("MUSIC_BACKEND_LOG", Path.home() / "Library/Logs/music-backend.log"))
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

state = {"pending": 0, "busy": False, "last_used": None}
lock = asyncio.Lock()


# --- tiny HTTP client for the backend (stdlib, run in a thread) ------------

def _call(method: str, path: str, body: dict | None = None, timeout: float = 30) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BACKEND + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def _download(path: str, dest: Path) -> None:
    url = BACKEND + path if path.startswith("/") else path
    with urllib.request.urlopen(url, timeout=300) as resp, open(dest, "wb") as out:
        while chunk := resp.read(1 << 20):
            out.write(chunk)


async def call(method: str, path: str, body: dict | None = None, timeout: float = 30) -> dict:
    return await asyncio.to_thread(_call, method, path, body, timeout)


# --- backend process lifecycle ---------------------------------------------

class Backend:
    """The acestep-api child process: started on demand, stopped when idle."""

    def __init__(self) -> None:
        self.proc: subprocess.Popen | None = None
        self.started_at: float | None = None

    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    async def healthy(self) -> bool:
        try:
            return (await call("GET", "/health", timeout=3)).get("data", {}).get("status") == "ok"
        except Exception:
            return False

    async def ensure(self) -> float:
        """Start the backend if needed; returns seconds spent starting it."""
        if self.running() and await self.healthy():
            return 0.0
        if not self.running() and await self.healthy():
            # Someone else runs an ACE-Step server on this port; use it but don't own it.
            return 0.0
        started = time.monotonic()
        env = {
            **os.environ,
            "ACESTEP_LM_BACKEND": "mlx",  # what ACE-Step's macOS launcher sets
            "ACESTEP_INIT_LLM": "true",
            "ACESTEP_LM_MODEL_PATH": LM_MODEL,
            "TOKENIZERS_PARALLELISM": "false",
        }
        BACKEND_LOG.parent.mkdir(parents=True, exist_ok=True)
        log.info("starting acestep-api (lm=%s)", LM_MODEL)
        self.proc = subprocess.Popen(
            ["uv", "run", "acestep-api", "--host", "127.0.0.1", "--port", str(BACKEND_PORT)],
            cwd=ACE_DIR, env=env, stdout=open(BACKEND_LOG, "ab"), stderr=subprocess.STDOUT,
            start_new_session=True,  # own process group, so stop() takes uv's children too
        )
        self.started_at = time.time()
        while time.monotonic() - started < STARTUP_TIMEOUT:
            if self.proc.poll() is not None:
                raise HTTPException(500, f"acestep-api exited during startup (code {self.proc.returncode}); see {BACKEND_LOG}")
            if await self.healthy():
                took = time.monotonic() - started
                log.info("acestep-api ready in %.1fs", took)
                return took
            await asyncio.sleep(1)
        await self.stop()
        raise HTTPException(504, f"acestep-api did not become healthy within {STARTUP_TIMEOUT}s")

    async def stop(self) -> bool:
        if not self.running():
            self.proc = None
            return False
        log.info("stopping acestep-api")
        pgid = os.getpgid(self.proc.pid)
        os.killpg(pgid, signal.SIGTERM)
        for _ in range(30):
            if self.proc.poll() is not None:
                break
            await asyncio.sleep(1)
        else:
            os.killpg(pgid, signal.SIGKILL)
        self.proc, self.started_at = None, None
        return True


backend = Backend()


# --- API --------------------------------------------------------------------

class MusicRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=2000, description="Style/mood/instrument description (ACE-Step 'caption')")
    lyrics: str | None = Field(None, max_length=8000, description="Lyrics with [Verse]/[Chorus] tags; omit or set instrumental for none")
    instrumental: bool = False
    duration: float = Field(30, ge=10, le=600, description="Seconds")
    bpm: int | None = Field(None, ge=30, le=300)
    key: str | None = Field(None, max_length=20, description='e.g. "C Major", "Am"')
    time_signature: Literal["2", "3", "4", "6"] | None = None
    language: str = Field("en", max_length=8, description="Vocal language code")
    seed: int | None = None
    steps: int = Field(8, ge=1, le=20, description="Turbo model: 8 recommended")
    thinking: bool = Field(True, description="Let the 5Hz LM plan the song first (better structure)")
    format: Literal["mp3", "wav", "flac"] = "mp3"
    response_format: Literal["url", "path"] = "url"


async def idle_watcher() -> None:
    while True:
        await asyncio.sleep(30)
        idle = time.time() - (state["last_used"] or time.time())
        if backend.running() and not state["busy"] and state["pending"] == 0 and idle > IDLE_UNLOAD:
            log.info("idle for %ds, stopping backend", idle)
            await backend.stop()
        cutoff = time.time() - OUTPUT_RETENTION_DAYS * 86400
        for f in OUTPUT_DIR.iterdir():
            if f.is_file() and f.stat().st_mtime < cutoff:
                f.unlink(missing_ok=True)


@asynccontextmanager
async def lifespan(_: FastAPI):
    watcher = asyncio.create_task(idle_watcher())
    yield
    watcher.cancel()
    await backend.stop()


app = FastAPI(title="music-server", version="0.1.0", lifespan=lifespan)


@app.get("/health")
async def health():
    return {
        "model": "ace-step-1.5",
        "lm_model": LM_MODEL,
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


@app.post("/v1/music/generations")
async def generate(req: MusicRequest, request: Request):
    if state["pending"] >= MAX_QUEUE:
        raise HTTPException(429, f"queue full ({MAX_QUEUE} requests pending); retry later")
    seed = req.seed if req.seed is not None else random.randrange(2**31)
    lyrics = "[Instrumental]" if req.instrumental or not (req.lyrics or "").strip() else req.lyrics
    task = {
        "prompt": req.prompt, "lyrics": lyrics, "audio_duration": req.duration,
        "vocal_language": req.language, "thinking": req.thinking, "inference_steps": req.steps,
        "batch_size": 1, "use_random_seed": False, "seed": seed, "audio_format": req.format,
        **({"bpm": req.bpm} if req.bpm else {}),
        **({"key_scale": req.key} if req.key else {}),
        **({"time_signature": req.time_signature} if req.time_signature else {}),
    }
    state["pending"] += 1
    try:
        async with lock:
            state["busy"] = True
            try:
                started = time.monotonic()
                startup_s = await backend.ensure()
                task_id = (await call("POST", "/release_task", task))["data"]["task_id"]
                log.info("submitted task %s (%.0fs, seed %d)", task_id, req.duration, seed)
                while True:
                    if time.monotonic() - started > JOB_TIMEOUT:
                        raise HTTPException(504, f"generation did not finish within {JOB_TIMEOUT}s")
                    item = (await call("POST", "/query_result", {"task_id_list": [task_id]}))["data"][0]
                    if item["status"] == 2:
                        raise HTTPException(500, f"ACE-Step reported a failure: {item.get('result') or item}")
                    if item["status"] == 1:
                        break
                    await asyncio.sleep(2)
                results = json.loads(item["result"]) if isinstance(item["result"], str) else item["result"]
                first = results[0]
                if not first.get("file"):
                    # ACE-Step marks the task done even when saving the audio failed.
                    raise HTTPException(500, "ACE-Step generated the audio but could not save it "
                                        f"(e.g. ffmpeg missing for mp3); see {BACKEND_LOG}")
                name = f"{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}.{req.format}"
                await asyncio.to_thread(_download, first["file"], OUTPUT_DIR / name)
                elapsed = time.monotonic() - started
            except HTTPException:
                raise
            except Exception as error:
                log.exception("music generation failed")
                raise HTTPException(500, f"music generation failed: {error}") from error
            finally:
                state["busy"] = False
                state["last_used"] = time.time()
    finally:
        state["pending"] -= 1

    metas = first.get("metas") or {}
    out = {
        "created": int(time.time()),
        "model": "ace-step-1.5",
        "dit_model": first.get("dit_model"),
        "lm_model": first.get("lm_model"),
        "seed": seed,
        "duration": req.duration,
        "metas": metas,
        "startup_seconds": round(startup_s, 1),
        "seconds": round(elapsed, 1),
    }
    if req.response_format == "path":
        out["path"] = str(OUTPUT_DIR / name)
    out["url"] = str(request.base_url).rstrip("/") + f"/music/{name}"
    return out


MEDIA = {".mp3": "audio/mpeg", ".wav": "audio/wav", ".flac": "audio/flac"}


@app.get("/music/{name}")
async def music_file(name: str):
    path = (OUTPUT_DIR / name).resolve()
    if path.parent != OUTPUT_DIR.resolve() or not path.is_file():
        raise HTTPException(404, "not found")
    return FileResponse(path, media_type=MEDIA.get(path.suffix, "application/octet-stream"))
