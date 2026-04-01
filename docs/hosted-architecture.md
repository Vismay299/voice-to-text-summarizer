# Hosted Architecture

Series 1 reshapes the repository around a hosted rebuild instead of the earlier local-first prototype.

## Service Layout

- `apps/web` - browser UI for session control and live transcript review.
- `apps/api` - hosted API for sessions, uploads, history, and realtime fan-out.
- `services/asr-worker` - hosted transcription worker using `faster-whisper`.
- `services/summary-worker` - hosted summary worker using a local open-weight LLM via `vLLM`.
- `packages/shared` - shared contracts, service names, and hosted environment keys.
- `infra/cloud-run` - Series 1 deployment baseline for hosted service images and Cloud Run mapping.

## Storage

- PostgreSQL is the system of record for sessions, transcript segments, notes, summaries, and model runs.
- Google Cloud Storage stores raw audio chunks and exportable artifacts.
- JSON files are not part of the product storage model.

## Runtime Defaults

- ASR model: `large-v3-turbo`
- Summary model: `Qwen2.5-7B-Instruct`
- LLM upgrade path: `Mistral Small 3.1 24B`
- Realtime transport: SSE
- Hosting target: GCP

## What Remains Prototype-Only

- Browser speech recognition in the existing web prototype.
- Local JSON archive files under `.voice-to-text-summarizer/`.
- Experimental Google Meet flows.

These may remain useful as reference material, but they are not the production path for the hosted rebuild.

## Step 1 Deliverable

Series 1 is complete when the repository contains the hosted service scaffolds, shared hosted contracts, environment examples, Dockerfiles, and a deployment baseline for `apps/api`, `services/asr-worker`, and `services/summary-worker`.
