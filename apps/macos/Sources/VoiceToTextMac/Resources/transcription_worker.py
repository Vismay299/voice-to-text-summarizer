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


def load_model(model_repo: str) -> str:
    """Warm the model by running a trivial transcription.

    mlx_whisper.transcribe() loads weights on first call. We trigger that
    here so subsequent calls pay only inference cost, not load cost.
    Returns the model repo string for reuse.
    """
    # Create a tiny silent WAV in memory to trigger model load.
    import io
    import struct
    import tempfile
    import os

    # 0.1s of silence at 16kHz mono 16-bit PCM
    num_samples = 1600
    wav_buf = io.BytesIO()
    # WAV header
    data_size = num_samples * 2
    wav_buf.write(b"RIFF")
    wav_buf.write(struct.pack("<I", 36 + data_size))
    wav_buf.write(b"WAVE")
    wav_buf.write(b"fmt ")
    wav_buf.write(struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16))
    wav_buf.write(b"data")
    wav_buf.write(struct.pack("<I", data_size))
    wav_buf.write(b"\x00" * data_size)

    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    try:
        tmp.write(wav_buf.getvalue())
        tmp.close()
        mlx_whisper.transcribe(
            tmp.name,
            path_or_hf_repo=model_repo,
            language="en",
            task="transcribe",
            temperature=0.0,
        )
    finally:
        os.unlink(tmp.name)

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
