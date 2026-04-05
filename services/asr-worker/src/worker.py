from __future__ import annotations

import json
import math
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

import psycopg
from faster_whisper import WhisperModel
from google.cloud import storage
from psycopg.rows import dict_row


def env(name: str, default: str | None = None, required: bool = False) -> str | None:
    value = os.getenv(name, default)
    if required and (value is None or value.strip() == ""):
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def parse_int(name: str, default: int) -> int:
    raw = env(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return int(raw)
    except ValueError as error:
        raise RuntimeError(f"Environment variable {name} must be an integer.") from error


def parse_bool(name: str, default: bool) -> bool:
    raw = env(name)
    if raw is None or raw.strip() == "":
        return default

    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False

    raise RuntimeError(f"Environment variable {name} must be a boolean flag.")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def uuid_text(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex[:12]}"


def json_text(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def build_merged_audio_object_path(session_id: str) -> str:
    return f"audio/processed/sessions/{session_id}/merged.wav"


@dataclass(slots=True)
class WorkerConfig:
    postgres_url: str
    worker_id: str
    poll_interval_ms: int
    claim_timeout_ms: int
    model_id: str
    language: str
    device: str
    compute_type: str
    beam_size: int
    vad_filter: bool
    retry_without_vad_on_empty: bool
    normalize_audio: bool
    normalization_filter: str | None
    cpu_threads: int
    num_workers: int
    model_cache_dir: str | None
    gcs_bucket_name: str | None
    gcp_project_id: str | None
    local_audio_dir: str | None


@dataclass(slots=True)
class SessionChunk:
    id: str
    chunk_index: int
    mime_type: str
    object_path: str


@dataclass(slots=True)
class ClaimedFinalSession:
    session_id: str
    started_at: str | None
    ended_at: str
    created_at: str
    metadata: dict[str, Any]
    chunk_count: int
    chunks: list[SessionChunk]
    model_run_id: str
    merged_audio_object_path: str


STOP_REQUESTED = threading.Event()


def build_config() -> WorkerConfig:
    postgres_url = env("POSTGRES_URL", required=True)
    poll_interval_ms = parse_int("ASR_POLL_INTERVAL_MS", 5000)
    return WorkerConfig(
        postgres_url=postgres_url,
        worker_id=env("HOSTED_WORKER_ID", f"asr-worker-{uuid.uuid4().hex[:8]}") or "asr-worker",
        poll_interval_ms=poll_interval_ms,
        claim_timeout_ms=parse_int("ASR_CLAIM_TIMEOUT_MS", max(30000, poll_interval_ms * 12)),
        model_id=env("ASR_MODEL_ID", "large-v3") or "large-v3",
        language=env("ASR_LANGUAGE", "en") or "en",
        device=env("ASR_DEVICE", "cpu") or "cpu",
        compute_type=env("ASR_COMPUTE_TYPE", "int8") or "int8",
        beam_size=parse_int("ASR_BEAM_SIZE", 5),
        vad_filter=parse_bool("ASR_VAD_FILTER", False),
        retry_without_vad_on_empty=parse_bool("ASR_RETRY_WITHOUT_VAD_ON_EMPTY", True),
        normalize_audio=parse_bool("ASR_NORMALIZE_AUDIO", True),
        normalization_filter=env(
            "ASR_NORMALIZATION_FILTER",
            "highpass=f=60,lowpass=f=7600,loudnorm=I=-16:TP=-1.5:LRA=11",
        ),
        cpu_threads=parse_int("ASR_CPU_THREADS", max(1, os.cpu_count() or 1)),
        num_workers=parse_int("ASR_NUM_WORKERS", 1),
        model_cache_dir=env("ASR_MODEL_CACHE_DIR"),
        gcs_bucket_name=env("GCS_BUCKET_NAME"),
        gcp_project_id=env("GCP_PROJECT_ID"),
        local_audio_dir=env("HOSTED_LOCAL_AUDIO_DIR"),
    )


class AsrWorker:
    def __init__(self, config: WorkerConfig):
        self.config = config
        self.model = self._load_model()
        self.bucket = self._load_bucket() if config.gcs_bucket_name else None

    def _load_model(self) -> WhisperModel:
        print(
            "[asr-worker] loading faster-whisper model "
            f"{self.config.model_id} on {self.config.device}/{self.config.compute_type}"
        )
        return WhisperModel(
            self.config.model_id,
            device=self.config.device,
            compute_type=self.config.compute_type,
            cpu_threads=self.config.cpu_threads,
            num_workers=self.config.num_workers,
            download_root=self.config.model_cache_dir,
        )

    def _load_bucket(self):
        client = storage.Client(project=self.config.gcp_project_id or None)
        return client.bucket(self.config.gcs_bucket_name)

    def connect(self):
        return psycopg.connect(self.config.postgres_url, row_factory=dict_row)

    def runtime_label(self) -> str:
        return f"faster-whisper:{self.config.model_id}:{self.config.device}/{self.config.compute_type}"

    def resolve_audio_path(self, object_path: str) -> tuple[Path, Callable[[], None], str]:
        if self.bucket is not None:
            blob = self.bucket.blob(object_path)
            if not blob.exists():
                raise FileNotFoundError(f"Missing GCS audio chunk: gs://{self.config.gcs_bucket_name}/{object_path}")

            temp_dir = Path(tempfile.mkdtemp(prefix="voice-to-text-asr-src-"))
            destination = temp_dir / Path(object_path).name
            blob.download_to_filename(str(destination))

            def cleanup() -> None:
                shutil.rmtree(temp_dir, ignore_errors=True)

            return destination, cleanup, "gcs"

        if not self.config.local_audio_dir:
            raise RuntimeError("HOSTED_LOCAL_AUDIO_DIR must be configured when GCS_BUCKET_NAME is absent.")

        root = Path(self.config.local_audio_dir)
        resolved = root / object_path
        if not resolved.exists():
            raise FileNotFoundError(f"Missing filesystem audio chunk: {resolved}")

        return resolved, lambda: None, "filesystem"

    def resolve_output_path(self, object_path: str) -> Path:
        if not self.config.local_audio_dir:
            raise RuntimeError("HOSTED_LOCAL_AUDIO_DIR must be configured for merged session output.")

        root = Path(self.config.local_audio_dir)
        destination = root / object_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        return destination

    def transcribe_once(self, audio_path: Path, vad_filter: bool) -> list[dict[str, Any]]:
        segments_iter, info = self.model.transcribe(
            str(audio_path),
            language=self.config.language,
            vad_filter=vad_filter,
            beam_size=self.config.beam_size,
            temperature=0.0,
            condition_on_previous_text=False,
            word_timestamps=False,
            task="transcribe",
        )
        print(
            "[asr-worker] transcription info "
            f"language={info.language} probability={info.language_probability:.4f} "
            f"duration={info.duration:.2f}s vadFilter={vad_filter}"
        )
        return [
            {
                "start": float(segment.start),
                "end": float(segment.end),
                "text": str(segment.text).strip(),
                "confidence": None
                if getattr(segment, "avg_logprob", None) is None
                else max(0.0, min(1.0, math.exp(float(getattr(segment, "avg_logprob"))))),
            }
            for segment in segments_iter
            if str(segment.text).strip()
        ]

    def transcribe(self, audio_path: Path) -> tuple[list[dict[str, Any]], bool, bool]:
        segments = self.transcribe_once(audio_path, self.config.vad_filter)
        if segments or not self.config.vad_filter or not self.config.retry_without_vad_on_empty:
            return segments, self.config.vad_filter, False

        print("[asr-worker] no transcript segments with VAD enabled; retrying authoritative pass without VAD")
        retry_segments = self.transcribe_once(audio_path, False)
        return retry_segments, False, True

    def requeue_stale_sessions(self, cur: psycopg.Cursor[Any]) -> int:
        stale_at = now_iso()
        cur.execute(
            """
            WITH stale_runs AS (
              SELECT mr.id, mr.session_id
              FROM model_runs mr
              WHERE mr.kind = 'asr'
                AND mr.status = 'running'
                AND COALESCE(mr.metadata->>'pass', '') = 'authoritative-final'
                AND mr.started_at <= NOW() - (%s * INTERVAL '1 millisecond')
              FOR UPDATE OF mr SKIP LOCKED
            )
            UPDATE model_runs mr
            SET status = 'failed',
                completed_at = %s::timestamptz,
                error_message = 'Authoritative ASR lease expired and was released for retry.',
                metadata = COALESCE(mr.metadata, '{}'::jsonb)
                  || jsonb_build_object(
                       'failedAt', %s::text,
                       'workerId', %s::text,
                       'requeueReason', 'claim-timeout'
                     )
            FROM stale_runs sr
            WHERE mr.id = sr.id
            RETURNING sr.session_id
            """,
            [self.config.claim_timeout_ms, stale_at, stale_at, self.config.worker_id],
        )
        stale_rows = cur.fetchall()
        return len(stale_rows)

    def claim_next_final_session(self) -> ClaimedFinalSession | None:
        claim_time = now_iso()
        with self.connect() as conn:
            with conn.cursor() as cur:
                requeued_count = self.requeue_stale_sessions(cur)
                if requeued_count > 0:
                    print(f"[asr-worker] released {requeued_count} stale authoritative ASR run(s)")

                cur.execute(
                    """
                    SELECT s.id, s.started_at, s.ended_at, s.created_at, s.metadata
                    FROM sessions s
                    WHERE s.ended_at IS NOT NULL
                      AND (
                        (
                          s.status = 'processing'
                          AND COALESCE(NULLIF(s.metadata->>'awaitingFinalTranscript', '')::boolean, false)
                        )
                        OR COALESCE(NULLIF(s.metadata->>'forceRetranscribe', '')::boolean, false)
                      )
                      AND NOT EXISTS (
                        SELECT 1
                        FROM model_runs mr
                        WHERE mr.session_id = s.id
                          AND mr.kind = 'asr'
                          AND mr.status = 'running'
                          AND COALESCE(mr.metadata->>'pass', '') = 'authoritative-final'
                      )
                      AND (
                        COALESCE(NULLIF(s.metadata->>'forceRetranscribe', '')::boolean, false)
                        OR NOT EXISTS (
                          SELECT 1
                          FROM model_runs mr
                          WHERE mr.session_id = s.id
                            AND mr.kind = 'asr'
                            AND mr.status = 'complete'
                            AND COALESCE(mr.metadata->>'pass', '') = 'authoritative-final'
                        )
                      )
                    ORDER BY s.updated_at ASC, s.created_at ASC
                    FOR UPDATE OF s SKIP LOCKED
                    LIMIT 1
                    """
                )
                session_row = cur.fetchone()
                if session_row is None:
                    conn.commit()
                    return None

                session_id = str(session_row["id"])
                metadata = dict(session_row["metadata"] or {})

                cur.execute(
                    """
                    SELECT id, chunk_index, mime_type, object_path
                    FROM audio_chunks
                    WHERE session_id = %s
                    ORDER BY chunk_index ASC
                    FOR UPDATE OF audio_chunks
                    """,
                    [session_id],
                )
                chunk_rows = cur.fetchall()
                if len(chunk_rows) == 0:
                    failed_metadata = {
                        **metadata,
                        "errorMessage": "No audio chunks were uploaded for this session.",
                        "transcriptionFailedAt": claim_time,
                        "finalizedBy": "asr-worker",
                    }
                    failed_metadata["awaitingFinalTranscript"] = False
                    cur.execute(
                        """
                        UPDATE sessions
                        SET status = 'failed',
                            updated_at = NOW(),
                            metadata = %s::jsonb
                        WHERE id = %s
                        """,
                        [json_text(failed_metadata), session_id],
                    )
                    cur.execute(
                        """
                        INSERT INTO session_events (id, session_id, type, payload)
                        VALUES (%s, %s, 'error', %s::jsonb)
                        """,
                        [
                            uuid_text("event"),
                            session_id,
                            json_text({"message": "No audio chunks were uploaded for this session."}),
                        ],
                    )
                    conn.commit()
                    return None

                chunks = [
                    SessionChunk(
                        id=str(row["id"]),
                        chunk_index=int(row["chunk_index"]),
                        mime_type=str(row["mime_type"]),
                        object_path=str(row["object_path"]),
                    )
                    for row in chunk_rows
                ]

                merged_audio_object_path = build_merged_audio_object_path(session_id)
                model_run_id = uuid_text("model-run")
                run_metadata = {
                    "pass": "authoritative-final",
                    "chunkCount": len(chunks),
                    "language": self.config.language,
                    "device": self.config.device,
                    "computeType": self.config.compute_type,
                    "workerId": self.config.worker_id,
                    "vadFilter": self.config.vad_filter,
                    "normalizedAudio": self.config.normalize_audio,
                    "normalizationFilter": self.config.normalization_filter,
                }

                cur.execute(
                    """
                    INSERT INTO model_runs (
                      id, session_id, kind, model_id, runtime, status, input_ref, created_at, started_at, metadata
                    )
                    VALUES (
                      %s, %s, 'asr', %s, %s, 'running', %s, %s::timestamptz, %s::timestamptz, %s::jsonb
                    )
                    """,
                    [
                        model_run_id,
                        session_id,
                        self.config.model_id,
                        self.runtime_label(),
                        merged_audio_object_path,
                        claim_time,
                        claim_time,
                        json_text(run_metadata),
                    ],
                )
                cur.execute(
                    """
                    UPDATE sessions
                    SET updated_at = NOW(),
                        metadata = COALESCE(metadata, '{}'::jsonb)
                          || jsonb_build_object(
                               'asrClaimedAt', %s::text,
                               'asrWorkerId', %s::text,
                               'mergedAudioPath', %s::text
                             )
                    WHERE id = %s
                    """,
                    [claim_time, self.config.worker_id, merged_audio_object_path, session_id],
                )
                cur.execute(
                    """
                    INSERT INTO session_events (id, session_id, type, payload)
                    VALUES (%s, %s, 'model-run.created', %s::jsonb)
                    """,
                    [
                        uuid_text("event"),
                        session_id,
                        json_text(
                            {
                                "modelRunId": model_run_id,
                                "kind": "asr",
                                "modelId": self.config.model_id,
                                "runtime": self.runtime_label(),
                                "pass": "authoritative-final",
                                "chunkCount": len(chunks),
                                "inputRef": merged_audio_object_path,
                            }
                        ),
                    ],
                )
            conn.commit()

        return ClaimedFinalSession(
            session_id=session_id,
            started_at=str(session_row["started_at"]) if session_row["started_at"] is not None else None,
            ended_at=str(session_row["ended_at"]),
            created_at=str(session_row["created_at"]),
            metadata=metadata,
            chunk_count=len(chunks),
            chunks=chunks,
            model_run_id=model_run_id,
            merged_audio_object_path=merged_audio_object_path,
        )

    def assemble_session_audio(
        self, job: ClaimedFinalSession
    ) -> tuple[Path, str, list[Callable[[], None]]]:
        temp_dir = Path(tempfile.mkdtemp(prefix="voice-to-text-asr-merge-"))
        cleanups: list[Callable[[], None]] = [lambda: shutil.rmtree(temp_dir, ignore_errors=True)]
        resolved_paths: list[Path] = []
        storage_modes: list[str] = []

        for chunk in job.chunks:
            resolved_path, cleanup, storage_mode = self.resolve_audio_path(chunk.object_path)
            cleanups.append(cleanup)
            resolved_paths.append(resolved_path)
            storage_modes.append(storage_mode)

        merged_audio_path = self.resolve_output_path(job.merged_audio_object_path)
        use_binary_webm_assembly = all(
            chunk.mime_type.startswith("audio/webm") or chunk.object_path.endswith(".webm") for chunk in job.chunks
        )

        ffmpeg_command = ["ffmpeg", "-y", "-v", "error"]
        if use_binary_webm_assembly:
            assembled_media_path = temp_dir / "assembled.webm"
            with assembled_media_path.open("wb") as destination:
                for resolved_path in resolved_paths:
                    with resolved_path.open("rb") as source:
                        shutil.copyfileobj(source, destination)
            ffmpeg_command.extend(["-i", str(assembled_media_path)])
            concat_manifest = None
        else:
            transcoded_paths: list[Path] = []
            for index, resolved_path in enumerate(resolved_paths):
                transcoded_path = temp_dir / f"chunk-{index:06d}.wav"
                subprocess.run(
                    [
                        "ffmpeg",
                        "-y",
                        "-v",
                        "error",
                        "-i",
                        str(resolved_path),
                        "-vn",
                        "-ac",
                        "1",
                        "-ar",
                        "16000",
                        "-c:a",
                        "pcm_s16le",
                        str(transcoded_path),
                    ],
                    check=True,
                )
                transcoded_paths.append(transcoded_path)

            concat_manifest = temp_dir / "concat.txt"
            concat_manifest.write_text(
                "\n".join(f"file {shlex.quote(str(path))}" for path in transcoded_paths),
                encoding="utf-8",
            )
            ffmpeg_command.extend(["-f", "concat", "-safe", "0", "-i", str(concat_manifest)])

        ffmpeg_command.extend(["-vn", "-ac", "1", "-ar", "16000"])
        if self.config.normalize_audio and self.config.normalization_filter:
            ffmpeg_command.extend(["-af", self.config.normalization_filter])
        ffmpeg_command.extend(["-c:a", "pcm_s16le", str(merged_audio_path)])
        try:
            subprocess.run(ffmpeg_command, check=True)
        except subprocess.CalledProcessError:
            if not (self.config.normalize_audio and self.config.normalization_filter):
                raise

            print(
                "[asr-worker] audio normalization failed, retrying merge without filter "
                f"filter={self.config.normalization_filter!r}"
            )
            subprocess.run(
                [
                    "ffmpeg",
                    "-y",
                    "-v",
                    "error",
                    *(
                        ["-i", str(temp_dir / "assembled.webm")]
                        if use_binary_webm_assembly
                        else ["-f", "concat", "-safe", "0", "-i", str(concat_manifest)]
                    ),
                    "-vn",
                    "-ac",
                    "1",
                    "-ar",
                    "16000",
                    "-c:a",
                    "pcm_s16le",
                    str(merged_audio_path),
                ],
                check=True,
            )

        source_storage_mode = storage_modes[0] if storage_modes else "filesystem"
        if any(mode != source_storage_mode for mode in storage_modes):
            source_storage_mode = "mixed"

        return merged_audio_path, source_storage_mode, cleanups

    def persist_success(
        self,
        job: ClaimedFinalSession,
        merged_audio_path: Path,
        segments: list[dict[str, Any]],
        effective_vad_filter: bool,
        retried_without_vad: bool,
        latency_ms: int,
        source_storage_mode: str,
    ) -> None:
        completion_time = now_iso()

        with self.connect() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT metadata FROM sessions WHERE id = %s FOR UPDATE", [job.session_id])
                session_row = cur.fetchone()
                if session_row is None:
                    raise RuntimeError(f"Session {job.session_id} vanished while persisting ASR output.")

                cur.execute("DELETE FROM transcript_segments WHERE session_id = %s", [job.session_id])
                inserted_segment_ids: list[str] = []

                for index, segment in enumerate(segments):
                    segment_id = uuid_text("segment")
                    start_ms = int(round(segment["start"] * 1000))
                    end_ms = int(round(segment["end"] * 1000))
                    cur.execute(
                        """
                        INSERT INTO transcript_segments (
                          id, session_id, audio_chunk_id, model_run_id, sequence_number,
                          speaker_label, text, start_ms, end_ms, confidence
                        )
                        VALUES (
                          %s, %s, NULL, %s, %s,
                          NULL, %s, %s, %s, %s
                        )
                        """,
                        [
                            segment_id,
                            job.session_id,
                            job.model_run_id,
                            index,
                            segment["text"],
                            start_ms,
                            end_ms,
                            segment["confidence"],
                        ],
                    )
                    inserted_segment_ids.append(segment_id)
                    cur.execute(
                        """
                        INSERT INTO session_events (id, session_id, type, payload)
                        VALUES (%s, %s, 'transcript.segment.created', %s::jsonb)
                        """,
                        [
                            uuid_text("event"),
                            job.session_id,
                            json_text(
                                {
                                    "segmentId": segment_id,
                                    "modelRunId": job.model_run_id,
                                    "sequenceNumber": index,
                                    "text": segment["text"],
                                    "startMs": start_ms,
                                    "endMs": end_ms,
                                }
                            ),
                        ],
                    )

                cur.execute(
                    """
                    UPDATE audio_chunks
                    SET status = 'complete',
                        metadata = COALESCE(metadata, '{}'::jsonb)
                          || jsonb_build_object(
                               'authoritativeModelRunId', %s::text,
                               'mergedAudioPath', %s::text,
                               'processedAt', %s::text,
                               'sourceStorageMode', %s::text
                             )
                    WHERE session_id = %s
                    """,
                    [
                        job.model_run_id,
                        job.merged_audio_object_path,
                        completion_time,
                        source_storage_mode,
                        job.session_id,
                    ],
                )
                cur.execute(
                    """
                    UPDATE model_runs
                    SET status = 'complete',
                        completed_at = %s::timestamptz,
                        latency_ms = %s::int,
                        metadata = COALESCE(metadata, '{}'::jsonb)
                          || jsonb_build_object(
                               'segmentCount', %s::int,
                               'chunkCount', %s::int,
                               'mergedAudioPath', %s::text,
                               'sourceStorageMode', %s::text,
                               'resolvedPath', %s::text,
                               'vadFilter', %s::boolean,
                               'retriedWithoutVad', %s::boolean,
                               'normalizedAudio', %s::boolean,
                               'normalizationFilter', %s::text
                             )
                    WHERE id = %s
                    """,
                    [
                        completion_time,
                        latency_ms,
                        len(inserted_segment_ids),
                        job.chunk_count,
                        job.merged_audio_object_path,
                        source_storage_mode,
                        str(merged_audio_path),
                        effective_vad_filter,
                        retried_without_vad,
                        self.config.normalize_audio,
                        self.config.normalization_filter,
                        job.model_run_id,
                    ],
                )

                metadata = dict(session_row["metadata"] or {})
                metadata["awaitingFinalTranscript"] = False
                metadata["mergedAudioPath"] = job.merged_audio_object_path
                metadata["transcriptReadyAt"] = completion_time
                metadata["transcriptionCompletedAt"] = completion_time
                metadata["finalizedBy"] = "asr-worker"
                metadata["sourceStorageMode"] = source_storage_mode
                metadata["chunkCount"] = job.chunk_count
                metadata["authoritativeModelRunId"] = job.model_run_id
                metadata["forceRetranscribe"] = False
                metadata["normalizedAudio"] = self.config.normalize_audio
                metadata["normalizationFilter"] = self.config.normalization_filter
                metadata["vadFilter"] = effective_vad_filter
                metadata["retriedWithoutVad"] = retried_without_vad

                cur.execute(
                    """
                    UPDATE sessions
                    SET status = 'complete',
                        updated_at = NOW(),
                        metadata = %s::jsonb
                    WHERE id = %s
                    """,
                    [json_text(metadata), job.session_id],
                )
                cur.execute(
                    """
                    INSERT INTO session_events (id, session_id, type, payload)
                    VALUES (%s, %s, 'session.updated', %s::jsonb)
                    """,
                    [
                        uuid_text("event"),
                        job.session_id,
                        json_text(
                            {
                                "status": "complete",
                                "transcriptReadyAt": completion_time,
                                "segmentCount": len(inserted_segment_ids),
                                "modelRunId": job.model_run_id,
                            }
                        ),
                    ],
                )
            conn.commit()

        print(
            "[asr-worker] completed authoritative transcription "
            f"session={job.session_id} segments={len(inserted_segment_ids)} latencyMs={latency_ms}"
        )

    def persist_failure(
        self,
        job: ClaimedFinalSession,
        latency_ms: int,
        error_message: str,
        source_storage_mode: str | None = None,
    ) -> None:
        failure_time = now_iso()

        with self.connect() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE model_runs
                    SET status = 'failed',
                        completed_at = %s::timestamptz,
                        latency_ms = %s::int,
                        error_message = %s,
                        metadata = COALESCE(metadata, '{}'::jsonb)
                          || jsonb_build_object(
                               'failedAt', %s::text,
                               'workerId', %s::text,
                               'sourceStorageMode', COALESCE(%s::text, 'unknown')
                             )
                    WHERE id = %s
                    """,
                    [
                        failure_time,
                        latency_ms,
                        error_message,
                        failure_time,
                        self.config.worker_id,
                        source_storage_mode,
                        job.model_run_id,
                    ],
                )
                cur.execute(
                    """
                    UPDATE audio_chunks
                    SET status = 'failed',
                        metadata = COALESCE(metadata, '{}'::jsonb)
                          || jsonb_build_object(
                               'failedAt', %s::text,
                               'errorMessage', %s::text,
                               'authoritativeModelRunId', %s::text
                             )
                    WHERE session_id = %s
                    """,
                    [failure_time, error_message, job.model_run_id, job.session_id],
                )
                cur.execute("SELECT metadata FROM sessions WHERE id = %s FOR UPDATE", [job.session_id])
                session_row = cur.fetchone()
                metadata = dict(session_row["metadata"] or {}) if session_row is not None else {}
                metadata["awaitingFinalTranscript"] = False
                metadata["forceRetranscribe"] = False
                metadata["transcriptionFailedAt"] = failure_time
                metadata["errorMessage"] = error_message
                metadata["finalizedBy"] = "asr-worker"
                if source_storage_mode is not None:
                    metadata["sourceStorageMode"] = source_storage_mode

                cur.execute(
                    """
                    UPDATE sessions
                    SET status = 'failed',
                        updated_at = NOW(),
                        metadata = %s::jsonb
                    WHERE id = %s
                    """,
                    [json_text(metadata), job.session_id],
                )
                cur.execute(
                    """
                    INSERT INTO session_events (id, session_id, type, payload)
                    VALUES (%s, %s, 'error', %s::jsonb)
                    """,
                    [
                        uuid_text("event"),
                        job.session_id,
                        json_text(
                            {
                                "message": error_message,
                                "modelRunId": job.model_run_id,
                                "workerId": self.config.worker_id,
                                "latencyMs": latency_ms,
                            }
                        ),
                    ],
                )
            conn.commit()

        print(
            "[asr-worker] failed authoritative transcription "
            f"session={job.session_id} latencyMs={latency_ms} error={error_message}"
        )

    def process_final_session(self, job: ClaimedFinalSession) -> None:
        started = time.monotonic()
        cleanups: list[Callable[[], None]] = []
        source_storage_mode: str | None = None
        try:
            merged_audio_path, source_storage_mode, assembly_cleanups = self.assemble_session_audio(job)
            cleanups.extend(assembly_cleanups)
            print(
                "[asr-worker] transcribing authoritative session audio "
                f"session={job.session_id} path={merged_audio_path}"
            )
            segments, effective_vad_filter, retried_without_vad = self.transcribe(merged_audio_path)
            if len(segments) == 0:
                raise RuntimeError(
                    "Authoritative final ASR produced no transcript segments after normalization and VAD fallback."
                )
            latency_ms = max(0, int((time.monotonic() - started) * 1000))
            self.persist_success(
                job,
                merged_audio_path,
                segments,
                effective_vad_filter,
                retried_without_vad,
                latency_ms,
                source_storage_mode,
            )
        except Exception as error:
            latency_ms = max(0, int((time.monotonic() - started) * 1000))
            message = str(error)
            print(f"[asr-worker] error while processing session {job.session_id}: {message}")
            traceback.print_exc()
            self.persist_failure(job, latency_ms, message, source_storage_mode)
        finally:
            for cleaner in cleanups:
                try:
                    cleaner()
                except Exception:
                    pass

    def run(self) -> None:
        print(
            "[asr-worker] ready "
            f"model={self.config.model_id} language={self.config.language} "
            f"pollIntervalMs={self.config.poll_interval_ms} claimTimeoutMs={self.config.claim_timeout_ms} "
            f"workerId={self.config.worker_id}"
        )
        while not STOP_REQUESTED.is_set():
            try:
                job = self.claim_next_final_session()
                if job is None:
                    time.sleep(self.config.poll_interval_ms / 1000)
                    continue
                self.process_final_session(job)
            except Exception as error:
                print(f"[asr-worker] unexpected loop error: {error}")
                traceback.print_exc()
                time.sleep(min(5, max(1, self.config.poll_interval_ms / 1000)))


def handle_signal(name: str, _signum: int, _frame: Any) -> None:
    print(f"[asr-worker] received {name}; stopping after current work")
    STOP_REQUESTED.set()


def main() -> int:
    try:
        config = build_config()
        signal.signal(signal.SIGINT, lambda signum, frame: handle_signal("SIGINT", signum, frame))
        signal.signal(signal.SIGTERM, lambda signum, frame: handle_signal("SIGTERM", signum, frame))
        worker = AsrWorker(config)
        worker.run()
        return 0
    except Exception as error:
        print(f"[asr-worker] fatal startup error: {error}")
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
