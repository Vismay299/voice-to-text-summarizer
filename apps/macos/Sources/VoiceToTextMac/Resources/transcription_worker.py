#!/usr/bin/env python3
"""Persistent transcription worker for MLX Whisper large-v3-turbo.

Series 13 (Latency Optimization): keeps the model loaded in memory and
accepts newline-delimited JSON requests on stdin. Each request contains
an audio file path; the response is a single JSON line on stdout.

Protocol:
  - Startup: loads model, prints {"status":"ready"} to stdout.
  - Request:  {"input":"/path/to/audio.wav","utterance_id":"..."}
  - Response: {"utterance_id":"...","model_identifier":"large-v3",...}
  - Shutdown: EOF on stdin or SIGTERM → clean exit.
"""
from __future__ import annotations

import json
import math
import signal
import sys
import time

import mlx_whisper


_SILENT_WAV_PATH: str | None = None


def _silent_wav_path() -> str:
    """Return a path to a cached 0.1s silent WAV, creating it once per process.

    Warmup pings fire every ~90s; regenerating + deleting a temp file each
    time is unnecessary disk I/O that can wake storage on a battery-powered
    Mac. One file, written once, reused forever.
    """
    global _SILENT_WAV_PATH
    if _SILENT_WAV_PATH is not None:
        import os
        if os.path.exists(_SILENT_WAV_PATH):
            return _SILENT_WAV_PATH

    import io
    import struct
    import tempfile

    num_samples = 1600
    wav_buf = io.BytesIO()
    data_size = num_samples * 2
    wav_buf.write(b"RIFF")
    wav_buf.write(struct.pack("<I", 36 + data_size))
    wav_buf.write(b"WAVE")
    wav_buf.write(b"fmt ")
    wav_buf.write(struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16))
    wav_buf.write(b"data")
    wav_buf.write(struct.pack("<I", data_size))
    wav_buf.write(b"\x00" * data_size)

    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False, prefix="speakflow-silent-")
    tmp.write(wav_buf.getvalue())
    tmp.close()
    _SILENT_WAV_PATH = tmp.name
    return _SILENT_WAV_PATH


def _run_silent_transcribe(model_repo: str) -> None:
    """Run a 0.1s silent clip through the model to touch weights + GPU context."""
    mlx_whisper.transcribe(
        _silent_wav_path(),
        path_or_hf_repo=model_repo,
        language="en",
        task="transcribe",
        temperature=0.0,
    )


def load_model(model_repo: str) -> str:
    """Warm the model by running a trivial transcription.

    mlx_whisper.transcribe() loads weights on first call. We trigger that
    here so subsequent calls pay only inference cost, not load cost.
    """
    _run_silent_transcribe(model_repo)
    return model_repo


def transcribe_audio(audio_path: str, utterance_id: str, model_repo: str, language: str) -> dict:
    """Transcribe a single audio file. Model is already warm in memory."""
    result = mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=model_repo,
        language=language,
        task="transcribe",
        temperature=0.0,
        condition_on_previous_text=False,
        word_timestamps=False,
    )

    segments = []
    for i, seg in enumerate(result.get("segments", [])):
        avg_logprob = seg.get("avg_logprob")
        confidence = None
        if avg_logprob is not None:
            confidence = max(0.0, min(1.0, math.exp(float(avg_logprob))))

        segments.append({
            "index": i,
            "start_seconds": seg.get("start", 0.0),
            "end_seconds": seg.get("end", 0.0),
            "text": seg.get("text", "").strip(),
            "confidence": confidence,
        })

    duration = 0.0
    if segments:
        duration = max(s["end_seconds"] for s in segments)

    return {
        "utterance_id": utterance_id,
        "model_identifier": "large-v3-turbo",
        "language": result.get("language", language),
        "duration_seconds": duration,
        "text": result.get("text", "").strip(),
        "segments": segments,
    }


def main() -> int:
    model_repo = "mlx-community/whisper-large-v3-turbo"
    language = "en"

    # Parse optional CLI args for model/language override.
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=model_repo)
    parser.add_argument("--language", default=language)
    args = parser.parse_args()
    model_repo = args.model
    language = args.language

    # Graceful shutdown on SIGTERM.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    # Load model (warmup).
    t0 = time.monotonic()
    try:
        load_model(model_repo)
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}), file=sys.stdout, flush=True)
        return 1

    warmup_ms = int((time.monotonic() - t0) * 1000)
    print(json.dumps({"status": "ready", "warmup_ms": warmup_ms}), file=sys.stdout, flush=True)

    # Request loop: read JSON lines from stdin, write JSON lines to stdout.
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            print(json.dumps({"error": f"Invalid JSON: {e}"}), file=sys.stdout, flush=True)
            continue

        # Idle warmup ping: runs a silent clip through the model to keep
        # weights resident and the Metal context hot. Prevents the slow
        # "cold" dictation after the app has been idle for several minutes.
        if request.get("ping") is True:
            t0 = time.monotonic()
            try:
                _run_silent_transcribe(model_repo)
                ping_ms = int((time.monotonic() - t0) * 1000)
                print(json.dumps({"pong": True, "ping_ms": ping_ms}), file=sys.stdout, flush=True)
            except Exception as e:
                print(json.dumps({"error": f"Ping failed: {e}"}), file=sys.stdout, flush=True)
            continue

        audio_path = request.get("input")
        utterance_id = request.get("utterance_id", "")

        if not audio_path:
            print(json.dumps({"error": "Missing 'input' field", "utterance_id": utterance_id}),
                  file=sys.stdout, flush=True)
            continue

        try:
            t0 = time.monotonic()
            payload = transcribe_audio(audio_path, utterance_id, model_repo, language)
            payload["transcription_ms"] = int((time.monotonic() - t0) * 1000)
            print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), file=sys.stdout, flush=True)
        except Exception as e:
            print(json.dumps({"error": str(e), "utterance_id": utterance_id}),
                  file=sys.stdout, flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
