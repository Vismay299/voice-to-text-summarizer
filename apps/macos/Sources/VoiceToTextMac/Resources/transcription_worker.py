#!/usr/bin/env python3
"""Persistent transcription worker for local MLX Whisper models.

Series 13 (Latency Optimization): keeps the model loaded in memory and
accepts newline-delimited JSON requests on stdin. Each request contains
an audio file path; the response is a single JSON line on stdout.

Protocol:
  - Startup: loads default tier, prints {"status":"ready"} to stdout.
  - Request:  {"input":"/path/to/audio.wav","utterance_id":"...","model_tier":"fast"}
  - Response: {"utterance_id":"...","model_identifier":"mlx-community/...",...}
  - Shutdown: EOF on stdin or SIGTERM → clean exit.
"""
from __future__ import annotations

import json
import math
import os
import signal
import sys
import tempfile
import time
import wave
from array import array
from pathlib import Path

import mlx_whisper


_SILENT_WAV_PATH: str | None = None
_WARMED_MODELS: set[str] = set()
_SILENCE_ABS_THRESHOLD = 120
_SILENCE_RELATIVE_THRESHOLD = 0.015
_SILENCE_PADDING_MS = 120
_SILENCE_FRAME_MS = 20
_MIN_TRANSCRIBABLE_MS = 300
_SILENT_PEAK_THRESHOLD = 80
_HALLUCINATION_TEXTS = {
    "thanks for watching",
    "thanks for watching.",
    "please subscribe",
    "please subscribe.",
}


def _normalize_tier(value: object, default_tier: str = "fast") -> str:
    tier = str(value or default_tier).strip().lower()
    if tier in {"fast", "small", "tiny", "preview"}:
        return "fast"
    if tier in {"quality", "large", "large-v3", "large-v3-turbo", "final"}:
        return "quality"
    return default_tier if default_tier in {"fast", "quality"} else "fast"


def _model_repo_for_tier(tier: str, fast_model_repo: str, quality_model_repo: str) -> str:
    return fast_model_repo if tier == "fast" else quality_model_repo


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
        no_speech_threshold=0.6,
        logprob_threshold=-1.0,
        compression_ratio_threshold=2.4,
    )


def load_model(model_repo: str) -> str:
    """Warm the model by running a trivial transcription.

    mlx_whisper.transcribe() loads weights on first call. We trigger that
    here so subsequent calls pay only inference cost, not load cost.
    """
    if model_repo in _WARMED_MODELS:
        return model_repo

    _run_silent_transcribe(model_repo)
    _WARMED_MODELS.add(model_repo)
    return model_repo


def _empty_payload(
    utterance_id: str,
    model_identifier: str,
    model_tier: str,
    language: str,
    original_duration_seconds: float,
    timings_ms: dict,
    reason: str,
) -> dict:
    return {
        "utterance_id": utterance_id,
        "model_identifier": model_identifier,
        "model_tier": model_tier,
        "language": language,
        "duration_seconds": original_duration_seconds,
        "text": "",
        "segments": [],
        "timings_ms": timings_ms,
        "skipped_reason": reason,
    }


def _wav_samples(audio_path: str) -> tuple[array, wave._wave_params]:
    with wave.open(audio_path, "rb") as wav:
        params = wav.getparams()
        if params.sampwidth != 2 or params.nchannels != 1:
            raise ValueError("Only mono 16-bit PCM WAV can be trimmed safely")
        raw = wav.readframes(params.nframes)

    samples = array("h")
    samples.frombytes(raw)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples, params


def _write_wav(samples: array, params: wave._wave_params) -> str:
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False, prefix="speakflow-trimmed-")
    tmp_path = tmp.name
    tmp.close()

    out_samples = array("h", samples)
    if sys.byteorder != "little":
        out_samples.byteswap()

    with wave.open(tmp_path, "wb") as wav:
        wav.setnchannels(params.nchannels)
        wav.setsampwidth(params.sampwidth)
        wav.setframerate(params.framerate)
        wav.writeframes(out_samples.tobytes())

    return tmp_path


def _prepare_audio_for_transcription(audio_path: str) -> tuple[str | None, float, float, dict, str | None]:
    """Trim conservative leading/trailing silence from local PCM WAV audio.

    Returns: (path_to_transcribe, original_duration_s, trim_offset_s, timings, skip_reason)
    """
    t0 = time.monotonic()
    try:
        samples, params = _wav_samples(audio_path)
    except Exception as e:
        return audio_path, 0.0, 0.0, {
            "trim_prepare_ms": int((time.monotonic() - t0) * 1000),
            "trim_applied": False,
            "trim_error": str(e),
        }, None

    original_sample_count = len(samples)
    if original_sample_count == 0 or params.framerate <= 0:
        return None, 0.0, 0.0, {
            "trim_prepare_ms": int((time.monotonic() - t0) * 1000),
            "trim_applied": False,
            "silence_skip": True,
        }, "empty_audio"

    original_duration_s = original_sample_count / params.framerate
    original_duration_ms = int(original_duration_s * 1000)
    peak = max(abs(sample) for sample in samples)

    timings = {
        "trim_prepare_ms": 0,
        "original_duration_ms": original_duration_ms,
        "trimmed_duration_ms": original_duration_ms,
        "trim_leading_ms": 0,
        "trim_trailing_ms": 0,
        "trim_applied": False,
        "peak_amplitude": peak,
    }

    if original_duration_ms < _MIN_TRANSCRIBABLE_MS:
        timings["trim_prepare_ms"] = int((time.monotonic() - t0) * 1000)
        timings["silence_skip"] = True
        return None, original_duration_s, 0.0, timings, "too_short"

    if peak < _SILENT_PEAK_THRESHOLD:
        timings["trim_prepare_ms"] = int((time.monotonic() - t0) * 1000)
        timings["silence_skip"] = True
        return None, original_duration_s, 0.0, timings, "silent"

    threshold = max(_SILENCE_ABS_THRESHOLD, int(peak * _SILENCE_RELATIVE_THRESHOLD))
    frame_size = max(1, int(params.framerate * _SILENCE_FRAME_MS / 1000))

    first_voice = 0
    for start in range(0, original_sample_count, frame_size):
        frame = samples[start:start + frame_size]
        if frame and max(abs(sample) for sample in frame) >= threshold:
            first_voice = start
            break

    last_voice = original_sample_count
    for end in range(original_sample_count, 0, -frame_size):
        start = max(0, end - frame_size)
        frame = samples[start:end]
        if frame and max(abs(sample) for sample in frame) >= threshold:
            last_voice = end
            break

    padding = int(params.framerate * _SILENCE_PADDING_MS / 1000)
    trim_start = max(0, first_voice - padding)
    trim_end = min(original_sample_count, last_voice + padding)

    if trim_end <= trim_start:
        timings["trim_prepare_ms"] = int((time.monotonic() - t0) * 1000)
        timings["silence_skip"] = True
        return None, original_duration_s, 0.0, timings, "no_voice_detected"

    trimmed_sample_count = trim_end - trim_start
    trimmed_duration_ms = int(trimmed_sample_count / params.framerate * 1000)
    timings.update({
        "trim_prepare_ms": int((time.monotonic() - t0) * 1000),
        "trimmed_duration_ms": trimmed_duration_ms,
        "trim_leading_ms": int(trim_start / params.framerate * 1000),
        "trim_trailing_ms": int((original_sample_count - trim_end) / params.framerate * 1000),
        "trim_threshold": threshold,
    })

    if trimmed_duration_ms < _MIN_TRANSCRIBABLE_MS:
        timings["silence_skip"] = True
        return None, original_duration_s, trim_start / params.framerate, timings, "trimmed_too_short"

    saved_ms = original_duration_ms - trimmed_duration_ms
    if saved_ms < 80:
        return audio_path, original_duration_s, 0.0, timings, None

    trimmed_path = _write_wav(samples[trim_start:trim_end], params)
    timings["trim_applied"] = True
    timings["trimmed_path"] = Path(trimmed_path).name
    return trimmed_path, original_duration_s, trim_start / params.framerate, timings, None


def _transcribe_with_options(audio_path: str, model_repo: str, language: str, fast_text: bool) -> dict:
    options = {
        "path_or_hf_repo": model_repo,
        "language": language,
        "task": "transcribe",
        "temperature": 0.0,
        "condition_on_previous_text": False,
        "word_timestamps": False,
        "no_speech_threshold": 0.6,
        "logprob_threshold": -1.0,
        "compression_ratio_threshold": 2.4,
    }
    if fast_text:
        options["without_timestamps"] = True

    try:
        return mlx_whisper.transcribe(audio_path, **options)
    except TypeError:
        if not fast_text:
            raise
        options.pop("without_timestamps", None)
        return mlx_whisper.transcribe(audio_path, **options)


def transcribe_audio(
    audio_path: str,
    utterance_id: str,
    model_repo: str,
    model_tier: str,
    language: str,
    fast_text: bool,
) -> dict:
    """Transcribe a single audio file. Model is already warm in memory."""
    total_t0 = time.monotonic()
    prepared_path, original_duration_s, trim_offset_s, timings_ms, skip_reason = _prepare_audio_for_transcription(audio_path)
    cleanup_path = prepared_path if prepared_path not in (None, audio_path) else None
    load_t0 = time.monotonic()
    load_model(model_repo)
    timings_ms["model_load_ms"] = int((time.monotonic() - load_t0) * 1000)

    if prepared_path is None:
        timings_ms["total_worker_ms"] = int((time.monotonic() - total_t0) * 1000)
        return _empty_payload(
            utterance_id,
            model_repo,
            model_tier,
            language,
            original_duration_s,
            timings_ms,
            skip_reason or "skipped",
        )

    try:
        infer_t0 = time.monotonic()
        result = _transcribe_with_options(prepared_path, model_repo, language, fast_text)
        timings_ms["mlx_transcribe_ms"] = int((time.monotonic() - infer_t0) * 1000)
    finally:
        if cleanup_path:
            try:
                os.unlink(cleanup_path)
            except OSError:
                pass

    segments = []
    for i, seg in enumerate(result.get("segments", [])):
        avg_logprob = seg.get("avg_logprob")
        confidence = None
        if avg_logprob is not None:
            confidence = max(0.0, min(1.0, math.exp(float(avg_logprob))))

        segments.append({
            "index": i,
            "start_seconds": seg.get("start", 0.0) + trim_offset_s,
            "end_seconds": seg.get("end", 0.0) + trim_offset_s,
            "text": seg.get("text", "").strip(),
            "confidence": confidence,
        })

    text = result.get("text", "").strip()
    if text.lower() in _HALLUCINATION_TEXTS:
        text = ""
        segments = []

    duration = original_duration_s
    if segments:
        duration = max(original_duration_s, max(s["end_seconds"] for s in segments))
    elif text:
        trimmed_duration_s = timings_ms.get("trimmed_duration_ms", int(original_duration_s * 1000)) / 1000
        segments.append({
            "index": 0,
            "start_seconds": trim_offset_s,
            "end_seconds": min(original_duration_s, trim_offset_s + trimmed_duration_s),
            "text": text,
            "confidence": None,
        })

    timings_ms["total_worker_ms"] = int((time.monotonic() - total_t0) * 1000)
    timings_ms["fast_text"] = fast_text
    timings_ms["model_tier_fast"] = model_tier == "fast"

    return {
        "utterance_id": utterance_id,
        "model_identifier": model_repo,
        "model_tier": model_tier,
        "language": result.get("language", language),
        "duration_seconds": duration,
        "text": text,
        "segments": segments,
        "timings_ms": timings_ms,
    }


def main() -> int:
    quality_model_repo = "mlx-community/whisper-large-v3-turbo"
    fast_model_repo = os.environ.get("SPEAKFLOW_FAST_MODEL", "mlx-community/whisper-tiny")
    language = "en"

    # Parse optional CLI args for model/language override.
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", "--quality-model", dest="quality_model", default=quality_model_repo)
    parser.add_argument("--fast-model", default=fast_model_repo)
    parser.add_argument("--default-tier", default=os.environ.get("SPEAKFLOW_MODEL_TIER", "fast"))
    parser.add_argument("--language", default=language)
    args = parser.parse_args()
    quality_model_repo = args.quality_model
    fast_model_repo = args.fast_model
    default_tier = _normalize_tier(args.default_tier, "fast")
    language = args.language

    # Graceful shutdown on SIGTERM.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    # Load model (warmup).
    t0 = time.monotonic()
    try:
        load_model(_model_repo_for_tier(default_tier, fast_model_repo, quality_model_repo))
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}), file=sys.stdout, flush=True)
        return 1

    warmup_ms = int((time.monotonic() - t0) * 1000)
    print(json.dumps({
        "status": "ready",
        "warmup_ms": warmup_ms,
        "model_tier": default_tier,
        "model_identifier": _model_repo_for_tier(default_tier, fast_model_repo, quality_model_repo),
        "fast_model_identifier": fast_model_repo,
        "quality_model_identifier": quality_model_repo,
    }), file=sys.stdout, flush=True)

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
                tier = _normalize_tier(request.get("model_tier"), default_tier)
                model_repo = _model_repo_for_tier(tier, fast_model_repo, quality_model_repo)
                was_loaded = model_repo in _WARMED_MODELS
                load_model(model_repo)
                if was_loaded:
                    _run_silent_transcribe(model_repo)
                ping_ms = int((time.monotonic() - t0) * 1000)
                print(json.dumps({
                    "pong": True,
                    "ping_ms": ping_ms,
                    "model_tier": tier,
                    "model_identifier": model_repo,
                }), file=sys.stdout, flush=True)
            except Exception as e:
                print(json.dumps({"error": f"Ping failed: {e}"}), file=sys.stdout, flush=True)
            continue

        audio_path = request.get("input")
        utterance_id = request.get("utterance_id", "")
        fast_text = request.get("fast_text", True) is not False
        model_tier = _normalize_tier(request.get("model_tier"), default_tier)
        model_repo = _model_repo_for_tier(model_tier, fast_model_repo, quality_model_repo)

        if not audio_path:
            print(json.dumps({"error": "Missing 'input' field", "utterance_id": utterance_id}),
                  file=sys.stdout, flush=True)
            continue

        try:
            t0 = time.monotonic()
            payload = transcribe_audio(audio_path, utterance_id, model_repo, model_tier, language, fast_text)
            payload["transcription_ms"] = int((time.monotonic() - t0) * 1000)
            print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), file=sys.stdout, flush=True)
        except Exception as e:
            print(json.dumps({"error": str(e), "utterance_id": utterance_id}),
                  file=sys.stdout, flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
