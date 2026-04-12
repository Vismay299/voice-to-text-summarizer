#!/usr/bin/env python3
"""Transcribe one utterance with MLX Whisper large-v3 on Apple Silicon GPU.

Phase 12.4.1 decision: mlx-whisper locked as the large-v3 runtime.
"""
from __future__ import annotations

import argparse
import json
import math
import sys

import mlx_whisper


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Transcribe one utterance with mlx-whisper large-v3.")
    parser.add_argument("--input", required=True, help="Path to the WAV file to transcribe.")
    parser.add_argument("--utterance-id", required=True, help="Utterance UUID for tracing.")
    parser.add_argument("--model", default="mlx-community/whisper-large-v3-turbo", help="HuggingFace model repo.")
    parser.add_argument("--language", default="en", help="Language code.")
    return parser.parse_args()


def transcribe(args: argparse.Namespace) -> dict:
    result = mlx_whisper.transcribe(
        args.input,
        path_or_hf_repo=args.model,
        language=args.language,
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

    # Compute audio duration from segments.
    duration = 0.0
    if segments:
        duration = max(s["end_seconds"] for s in segments)

    return {
        "utterance_id": args.utterance_id,
        "model_identifier": "large-v3-turbo",
        "language": result.get("language", args.language),
        "duration_seconds": duration,
        "text": result.get("text", "").strip(),
        "segments": segments,
    }


def main() -> int:
    args = parse_args()
    try:
        payload = transcribe(args)
        json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        sys.stdout.write("\n")
        return 0
    except Exception as error:
        print(f"[transcribe_utterance] {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
