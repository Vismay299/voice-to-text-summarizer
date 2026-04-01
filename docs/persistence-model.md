# Persistence Model

Series 2 replaces local JSON storage with a real persistence boundary.

## System Of Record

- PostgreSQL stores all structured session data.
- Google Cloud Storage stores raw audio and exportable artifacts.
- The API owns the persistence contract and repository interface.

## Tables

- `users` stores the operator account.
- `sessions` stores top-level session state and model configuration.
- `audio_chunks` stores per-chunk upload metadata and object paths.
- `model_runs` stores ASR and summary job runs.
- `transcript_segments` stores final timestamped transcript rows.
- `session_notes` stores rolling live notes.
- `session_summaries` stores final summaries and summary sections.
- `action_items` stores structured follow-ups.
- `session_events` stores the operational event trail.

## Repository Contract

- The canonical SQL schema lives in `infra/postgres/001_series2_persistence.sql`.
- The API uses a Postgres-backed repository whenever `POSTGRES_URL` is configured.
- The in-memory repository remains only as a local scaffold fallback when a database is not configured.
- Session creation, audio chunk registration, model-run recording, and session events are the first supported repository operations.

## Durability Rules

- Never treat local files as durable product data.
- Rebuildable derived data belongs in Postgres or GCS, not in prototype-only JSON.
- Every uploaded chunk and model run should remain traceable to a session row.
