#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from faster_whisper import WhisperModel


@dataclass(slots=True)
class SegmentPayload:
    index: int
    start_seconds: float
    end_seconds: float
    text: str
    confidence: float | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Transcribe one utterance with faster-whisper large-v3.")
    parser.add_argument("--input", required=True, help="Path to the WAV file to transcribe.")
    parser.add_argument("--utterance-id", required=True, help="Utterance UUID for tracing.")
    parser.add_argument("--model", default="large-v3", help="Whisper model identifier.")
    parser.add_argument("--language", default="en", help="Language code.")
    parser.add_argument("--device", default="cpu", help="faster-whisper device.")
    parser.add_argument("--compute-type", default="int8", help="faster-whisper compute type.")
    parser.add_argument("--beam-size", type=int, default=5, help="Beam size.")
    parser.add_argument("--cpu-threads", type=int, default=max(1, os.cpu_count() or 1), help="CPU thread count.")
    parser.add_argument("--num-workers", type=int, default=1, help="Decoder worker count.")
    return parser.parse_args()


def load_model(args: argparse.Namespace) -> WhisperModel:
    return WhisperModel(
        args.model,
        device=args.device,
        compute_type=args.compute_type,
        cpu_threads=args.cpu_threads,
        num_workers=args.num_workers,
    )


def transcript_payload(args: argparse.Namespace) -> dict[str, object]:
    model = load_model(args)
    segments_iter, info = model.transcribe(
        args.input,
        language=args.language,
        beam_size=args.beam_size,
        vad_filter=False,
        temperature=0.0,
        condition_on_previous_text=False,
        word_timestamps=False,
        task="transcribe",
    )

    segments: list[SegmentPayload] = []
    transcript_parts: list[str] = []

    for segment in segments_iter:
        text = str(segment.text).strip()
        if not text:
            continue

        avg_logprob = getattr(segment, "avg_logprob", None)
        confidence = None
        if avg_logprob is not None:
            confidence = max(0.0, min(1.0, math.exp(float(avg_logprob))))

        segments.append(
            SegmentPayload(
                index=len(segments),
                start_seconds=float(segment.start),
                end_seconds=float(segment.end),
                text=text,
                confidence=confidence,
            )
        )
        transcript_parts.append(text)

    return {
        "utterance_id": args.utterance_id,
        "model_identifier": args.model,
        "language": info.language or args.language,
        "duration_seconds": float(info.duration),
        "text": " ".join(transcript_parts).strip(),
        "segments": [
            {
                "index": segment.index,
                "start_seconds": segment.start_seconds,
                "end_seconds": segment.end_seconds,
                "text": segment.text,
                "confidence": segment.confidence,
            }
            for segment in segments
        ],
    }


def main() -> int:
    args = parse_args()
    try:
        payload = transcript_payload(args)
        json.dump(payload, sys.stdout, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        sys.stdout.write("\n")
        return 0
    except Exception as error:  # pragma: no cover - CLI boundary
        print(f"[transcribe_utterance] {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
