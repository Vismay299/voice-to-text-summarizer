#!/usr/bin/env python3
"""Benchmark whisper runtimes for Phase 12.4.1.

Compares faster-whisper (CPU) vs MLX Whisper (Apple Silicon)
across large-v3 and large-v3-turbo models.

Outputs JSON with latency, transcript text, and quality metrics
for each configuration.
"""
from __future__ import annotations

import argparse
import gc
import json
import math
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(slots=True)
class BenchmarkResult:
    runtime: str
    model: str
    device: str
    compute_type: str
    load_time_s: float
    transcribe_time_s: float
    total_time_s: float
    audio_duration_s: float
    realtime_factor: float
    text: str
    segment_count: int
    avg_confidence: float | None
    error: str | None = None


def benchmark_faster_whisper(
    audio_path: str,
    model_id: str,
    device: str = "cpu",
    compute_type: str = "int8",
    beam_size: int = 5,
    cpu_threads: int = 0,
) -> BenchmarkResult:
    """Benchmark faster-whisper on CPU."""
    from faster_whisper import WhisperModel

    if cpu_threads <= 0:
        cpu_threads = max(1, os.cpu_count() or 1)

    t0 = time.perf_counter()
    model = WhisperModel(
        model_id,
        device=device,
        compute_type=compute_type,
        cpu_threads=cpu_threads,
        num_workers=1,
    )
    load_time = time.perf_counter() - t0

    t1 = time.perf_counter()
    segments_iter, info = model.transcribe(
        audio_path,
        language="en",
        beam_size=beam_size,
        vad_filter=False,
        temperature=0.0,
        condition_on_previous_text=False,
        word_timestamps=False,
        task="transcribe",
    )

    texts = []
    confidences = []
    seg_count = 0
    for segment in segments_iter:
        text = str(segment.text).strip()
        if not text:
            continue
        texts.append(text)
        seg_count += 1
        avg_logprob = getattr(segment, "avg_logprob", None)
        if avg_logprob is not None:
            confidences.append(max(0.0, min(1.0, math.exp(float(avg_logprob)))))

    transcribe_time = time.perf_counter() - t1
    total_time = time.perf_counter() - t0
    audio_dur = float(info.duration) if info.duration else 0.0

    # Explicitly free model to reclaim memory
    del model
    gc.collect()

    return BenchmarkResult(
        runtime="faster-whisper",
        model=model_id,
        device=device,
        compute_type=compute_type,
        load_time_s=round(load_time, 3),
        transcribe_time_s=round(transcribe_time, 3),
        total_time_s=round(total_time, 3),
        audio_duration_s=round(audio_dur, 3),
        realtime_factor=round(transcribe_time / audio_dur, 3) if audio_dur > 0 else 0.0,
        text=" ".join(texts).strip(),
        segment_count=seg_count,
        avg_confidence=round(sum(confidences) / len(confidences), 4) if confidences else None,
    )


def benchmark_mlx_whisper(
    audio_path: str,
    model_id: str,
) -> BenchmarkResult:
    """Benchmark mlx-whisper on Apple Silicon."""
    try:
        import mlx_whisper
    except ImportError:
        return BenchmarkResult(
            runtime="mlx-whisper",
            model=model_id,
            device="gpu",
            compute_type="float16",
            load_time_s=0.0,
            transcribe_time_s=0.0,
            total_time_s=0.0,
            audio_duration_s=0.0,
            realtime_factor=0.0,
            text="",
            segment_count=0,
            avg_confidence=None,
            error="mlx_whisper not installed",
        )

    # mlx-whisper uses HuggingFace model IDs
    hf_model_map = {
        "large-v3": "mlx-community/whisper-large-v3-mlx",
        "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
    }
    hf_model = hf_model_map.get(model_id, model_id)

    t0 = time.perf_counter()
    # mlx_whisper.transcribe handles model loading internally
    # First call includes model load time
    result = mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=hf_model,
        language="en",
        task="transcribe",
        temperature=0.0,
        condition_on_previous_text=False,
        word_timestamps=False,
    )
    total_time = time.perf_counter() - t0

    text = result.get("text", "").strip()
    segments = result.get("segments", [])

    confidences = []
    for seg in segments:
        avg_logprob = seg.get("avg_logprob")
        if avg_logprob is not None:
            confidences.append(max(0.0, min(1.0, math.exp(float(avg_logprob)))))

    # Estimate audio duration from segments or use a fallback
    audio_dur = 0.0
    if segments:
        audio_dur = max(seg.get("end", 0.0) for seg in segments)

    gc.collect()

    return BenchmarkResult(
        runtime="mlx-whisper",
        model=model_id,
        device="gpu",
        compute_type="float16",
        load_time_s=0.0,  # mlx bundles load+transcribe
        transcribe_time_s=round(total_time, 3),
        total_time_s=round(total_time, 3),
        audio_duration_s=round(audio_dur, 3),
        realtime_factor=round(total_time / audio_dur, 3) if audio_dur > 0 else 0.0,
        text=text,
        segment_count=len(segments),
        avg_confidence=round(sum(confidences) / len(confidences), 4) if confidences else None,
    )


def run_benchmark(audio_path: str, warmup: bool = True) -> list[dict]:
    """Run all benchmark configurations."""
    configs: list[tuple[str, str, dict]] = [
        # (runtime, model, extra_kwargs)
        ("faster-whisper", "large-v3", {"compute_type": "int8"}),
        ("faster-whisper", "large-v3-turbo", {"compute_type": "int8"}),
        ("mlx-whisper", "large-v3", {}),
        ("mlx-whisper", "large-v3-turbo", {}),
    ]

    results: list[dict] = []

    for runtime, model_id, kwargs in configs:
        print(f"\n{'='*60}", file=sys.stderr)
        print(f"Benchmarking: {runtime} + {model_id}", file=sys.stderr)
        print(f"{'='*60}", file=sys.stderr)

        try:
            if runtime == "faster-whisper":
                # Warmup run to ensure model is cached
                if warmup:
                    print("  Warmup run...", file=sys.stderr)
                    benchmark_faster_whisper(audio_path, model_id, **kwargs)

                print("  Benchmark run...", file=sys.stderr)
                result = benchmark_faster_whisper(audio_path, model_id, **kwargs)
            elif runtime == "mlx-whisper":
                if warmup:
                    print("  Warmup run...", file=sys.stderr)
                    benchmark_mlx_whisper(audio_path, model_id)

                print("  Benchmark run...", file=sys.stderr)
                result = benchmark_mlx_whisper(audio_path, model_id)
            else:
                continue

            print(f"  Result: {result.total_time_s}s total, RTF={result.realtime_factor}", file=sys.stderr)
            print(f"  Text: {result.text[:100]}...", file=sys.stderr)

            results.append({
                "runtime": result.runtime,
                "model": result.model,
                "device": result.device,
                "compute_type": result.compute_type,
                "load_time_s": result.load_time_s,
                "transcribe_time_s": result.transcribe_time_s,
                "total_time_s": result.total_time_s,
                "audio_duration_s": result.audio_duration_s,
                "realtime_factor": result.realtime_factor,
                "text": result.text,
                "segment_count": result.segment_count,
                "avg_confidence": result.avg_confidence,
                "error": result.error,
            })
        except Exception as e:
            print(f"  ERROR: {e}", file=sys.stderr)
            results.append({
                "runtime": runtime,
                "model": model_id,
                "error": str(e),
            })

    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark whisper runtimes for Phase 12.4.1")
    parser.add_argument("--input", required=True, help="Path to WAV file for benchmarking.")
    parser.add_argument("--no-warmup", action="store_true", help="Skip warmup runs.")
    parser.add_argument("--output", help="Path to write JSON results (default: stdout).")
    args = parser.parse_args()

    if not Path(args.input).exists():
        print(f"Error: {args.input} does not exist", file=sys.stderr)
        return 1

    print(f"\nBenchmarking with: {args.input}", file=sys.stderr)
    print(f"File size: {Path(args.input).stat().st_size / 1024:.1f} KB", file=sys.stderr)

    results = run_benchmark(args.input, warmup=not args.no_warmup)

    output = json.dumps({"benchmark_results": results}, indent=2, ensure_ascii=False)

    if args.output:
        Path(args.output).write_text(output + "\n")
        print(f"\nResults written to {args.output}", file=sys.stderr)
    else:
        print(output)

    # Print summary table
    print(f"\n{'='*80}", file=sys.stderr)
    print("SUMMARY", file=sys.stderr)
    print(f"{'='*80}", file=sys.stderr)
    print(f"{'Runtime':<20} {'Model':<20} {'Total(s)':<10} {'RTF':<8} {'Confidence':<12} {'Error'}", file=sys.stderr)
    print(f"{'-'*80}", file=sys.stderr)
    for r in results:
        error = r.get("error", "") or ""
        total = r.get("total_time_s", "N/A")
        rtf = r.get("realtime_factor", "N/A")
        conf = r.get("avg_confidence", "N/A")
        print(f"{r['runtime']:<20} {r['model']:<20} {total!s:<10} {rtf!s:<8} {conf!s:<12} {error}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
