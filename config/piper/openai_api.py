"""OpenAI-compatible TTS facade over Piper (OHF-Voice/piper1-gpl).

Open WebUI's "OpenAI" TTS engine calls three endpoints on its configured base
URL, so those are exactly what this serves:

    POST /v1/audio/speech   {"input": ..., "voice": ..., "speed": ...} -> WAV
    GET  /v1/audio/voices   {"voices": [{"id", "name"}, ...]}
    GET  /v1/audio/models   {"models": [{"id"}, ...]}

Piper reads a .onnx per voice off disk; loading one costs about a second, so
they are cached after first use. Synthesis is CPU-bound and releases no GIL
worth speaking of, hence the single worker and the lock: on this Pi the point is
to never take more than one core away from llama-cpp, which is sharing the same
three.
"""

from __future__ import annotations

import io
import logging
import os
import threading
import wave
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, Response
from piper import PiperVoice, SynthesisConfig
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("piper-openai")

VOICE_DIR = Path(os.environ.get("PIPER_VOICE_DIR", "/voices"))
DEFAULT_VOICE = os.environ.get("PIPER_DEFAULT_VOICE", "fr_FR-siwis-medium")

app = FastAPI(title="Piper OpenAI-compatible TTS")

_voices: dict[str, PiperVoice] = {}
_load_lock = threading.Lock()
_synth_lock = threading.Lock()


def available_voices() -> list[str]:
    """Voice ids, taken from the .onnx files baked into the image."""
    return sorted(p.stem for p in VOICE_DIR.rglob("*.onnx"))


def voice_path(name: str) -> Path | None:
    for path in VOICE_DIR.rglob("*.onnx"):
        if path.stem == name:
            return path
    return None


def get_voice(name: str) -> PiperVoice:
    """Load a voice once and keep it resident."""
    with _load_lock:
        if name not in _voices:
            path = voice_path(name)
            if path is None:
                raise HTTPException(status_code=400, detail=f"unknown voice: {name}")
            log.info("loading voice %s", name)
            _voices[name] = PiperVoice.load(str(path))
        return _voices[name]


class SpeechRequest(BaseModel):
    input: str = ""
    # Accepted and ignored: the model is the voice here. Open WebUI always sends
    # whatever is in its "TTS model" box (tts-1 by default).
    model: str | None = None
    voice: str | None = None
    response_format: str | None = None
    # OpenAI's 0.25-4.0 multiplier. Piper scales the other way round: its
    # length_scale stretches the audio, so speed 2.0 is length_scale 0.5.
    speed: float | None = None


@app.get("/v1/audio/voices")
def list_voices() -> JSONResponse:
    voices = [{"id": name, "name": name} for name in available_voices()]
    return JSONResponse({"voices": voices})


@app.get("/v1/audio/models")
def list_models() -> JSONResponse:
    # Open WebUI shows these in its "TTS model" dropdown. Piper has no separate
    # model axis, so report the voices again rather than an empty list.
    return JSONResponse({"models": [{"id": name} for name in available_voices()]})


@app.get("/health")
def health() -> JSONResponse:
    return JSONResponse({"status": "ok", "voices": available_voices()})


@app.post("/v1/audio/speech")
def speech(req: SpeechRequest) -> Response:
    text = (req.input or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="input is empty")

    name = req.voice or DEFAULT_VOICE
    if voice_path(name) is None:
        # Open WebUI ships OpenAI's own voice names (alloy, echo, ...) as its
        # default; fall back rather than fail the first play button.
        log.info("voice %r unavailable, falling back to %s", name, DEFAULT_VOICE)
        name = DEFAULT_VOICE

    voice = get_voice(name)

    config = SynthesisConfig()
    if req.speed and req.speed > 0:
        config.length_scale = 1.0 / req.speed

    buffer = io.BytesIO()
    with _synth_lock:
        with wave.open(buffer, "wb") as wav_file:
            voice.synthesize_wav(text, wav_file, syn_config=config)

    return Response(content=buffer.getvalue(), media_type="audio/wav")
