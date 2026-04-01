# Master Execution Roadmap: Voice-to-Text Summarizer

> Status: Planning reset for hosted rebuild
>
> Last updated: 2026-03-31

Voice-to-Text Summarizer is now planned as a hosted, production-oriented AI application: a web-first product that captures live conversation audio, transcribes it quickly and accurately, generates rolling notes plus a final summary, and stores everything in durable cloud infrastructure instead of local JSON files or prototype-only session state.

The current repository is still useful, but it is not the target system. It contains a web UI scaffold, a local companion prototype, a local JSON archive, browser speech recognition experiments, and meeting-helper proof-of-concept flows. Those artifacts are legacy baseline code, not proof that the hosted AI architecture is already built.

Source of truth:
- `ROADMAP.md` is the main planning and session continuity document.
- `PROJECT.md` remains background context and original project framing.
- `STATE.md` is secondary and can lag behind this file.

## Vision

Build a fast, accurate conversation intelligence product that lets a user stay focused during a call while the system captures the audio, transcribes it with production-grade open-weight speech models, produces useful live notes and a final summary, and makes the entire session reviewable later from a real database-backed application.

## Product Goal

The MVP succeeds when all of the following are true:
- A user can start a session from the web app and capture microphone audio reliably.
- Audio is uploaded in near real time to hosted infrastructure on GCP.
- The backend produces usable transcript segments quickly enough to feel live during a conversation.
- The system generates rolling notes and a final summary from the actual transcript, not placeholder content.
- Completed sessions are persisted in PostgreSQL and raw audio is stored in Google Cloud Storage.
- A user can reopen past sessions and review transcript, notes, and summary without relying on local JSON files.
- The architecture is ready for mobile and future meeting capture expansion without a full redesign.

## Current Truth

- The repo currently contains a TypeScript monorepo with `apps/web`, `apps/companion`, and `packages/shared`.
- The current web UI is a useful shell for session control and transcript/history presentation.
- The local companion server is prototype scaffolding, not the final production backend.
- Local JSON persistence under `.voice-to-text-summarizer/` is temporary scaffolding and must not be treated as product storage.
- Browser `SpeechRecognition` / `webkitSpeechRecognition` is temporary scaffolding and must not be treated as the final transcription backend.
- The runtime selector currently exposes options such as `whisper.cpp`, `faster-whisper`, and `ollama`, but the repo does not yet run the target hosted ASR/LLM architecture.
- Meeting-helper and experimental Google Meet flows are exploratory UI/prototype work and are not real production capture paths.
- Existing code may be reused selectively for UI, shared types, and session concepts, but the roadmap assumes a hosted rebuild of the backend path.

## Target Architecture

Locked defaults for the hosted rebuild:

| Layer | Default Choice | Notes |
| --- | --- | --- |
| Frontend | Web app first | Keep the web product as the main operator surface for MVP. |
| Web client stack | Existing TypeScript/Vite frontend | Reuse the current client shell instead of adding framework churn in MVP. |
| Backend API | Hosted service on GCP | CPU service responsible for sessions, uploads, history reads, and realtime stream orchestration. |
| Transcription backend | `faster-whisper` | Primary ASR runtime for hosted transcription. |
| Default ASR model | `large-v3-turbo` | Best speed/quality tradeoff for MVP. |
| Higher-accuracy option later | `large-v3` | Optional accuracy tier after MVP baseline is stable. |
| Summarization LLM | `Qwen2.5-7B-Instruct` | Default hosted summary/action extraction model. |
| Stronger later summary model | `Mistral Small 3.1 24B` | Upgrade path if summary quality needs more headroom. |
| LLM serving runtime | `vLLM` | Default runtime for hosted open-weight summary inference. |
| Database | PostgreSQL | System of record for sessions, transcript segments, summaries, and jobs. |
| Object storage | Google Cloud Storage | Durable raw audio and generated artifact storage. |
| Hosting target | GCP | Cloud Run for services, Cloud SQL for Postgres, GCS for blobs. |
| Queue/event transport | Pub/Sub | Default async trigger path for transcription and summary work. |
| Realtime delivery | SSE | Simpler than WebSocket for MVP live transcript/note updates. |
| Persistence rule | Database plus object storage | No JSON archive as product storage. |
| Desktop companion role | Deferred | Not part of MVP critical path; future helper for system-audio capture in later series. |

Non-goals for the hosted MVP:
- No reliance on local JSON archives as durable product storage.
- No reliance on browser speech recognition as the core ASR path.
- No Google Meet bot or hidden participant workflow in MVP.
- No system-audio capture in the first hosted milestone.

## Core Systems

### 1. Web Client
- Starts and stops sessions.
- Captures microphone audio with `MediaRecorder`.
- Uploads chunked audio to the backend.
- Subscribes to live transcript/note events over SSE.
- Renders session status, transcript, notes, summary, and history.

### 2. API Service
- Runs as the main hosted application backend on GCP.
- Creates sessions and returns upload/session metadata to the client.
- Accepts audio chunk uploads and records chunk metadata.
- Publishes transcription and summary work onto Pub/Sub.
- Serves session history, session detail, and SSE feeds.

### 3. Audio Storage Layer
- Stores raw audio chunks in GCS.
- Keeps ordered chunk metadata in Postgres.
- Supports later reprocessing and debugging without losing raw source data.

### 4. ASR Worker
- Runs `faster-whisper` with `large-v3-turbo`.
- Pulls chunk jobs from Pub/Sub.
- Downloads audio chunks from GCS.
- Produces timestamped transcript segments.
- Writes transcript segments and model-run metadata to Postgres.

### 5. Summary Worker
- Runs `Qwen2.5-7B-Instruct` via `vLLM`.
- Builds rolling notes and final summary from persisted transcript segments.
- Writes summaries, action items, and decisions to Postgres.

### 6. Persistence Layer
- Postgres stores all structured session state.
- GCS stores all audio blobs and exportable artifacts.
- No product feature should depend on JSON files in the repo or local filesystem.

### 7. Realtime Delivery Layer
- API exposes SSE streams keyed by session ID.
- Transcript updates and summary/note updates are emitted when new rows are committed.
- Client reconnects cleanly without losing the canonical timeline because the source of truth is in Postgres.

## Data Model

### `users`
- The account/operator using the system.
- MVP can start single-user, but the schema should still allow future multi-user expansion.

### `sessions`
- One row per conversation session.
- Stores session ID, user ID, source type, status, start/end timestamps, and top-level model configuration.

### `audio_chunks`
- One row per uploaded chunk.
- Stores session ID, chunk sequence number, storage path, duration, uploaded timestamp, and processing status.

### `transcript_segments`
- One row per finalized transcript segment.
- Stores session ID, chunk reference, sequence number, text, start/end offsets, confidence, and ASR metadata.

### `session_notes`
- Rolling live notes derived from transcript windows.
- Stores session ID, note text, generation time, and optional source segment references.

### `session_summaries`
- Final summary plus structured summary sections.
- Stores overview, key points, optional follow-ups, generation timestamp, and summary model metadata.

### `action_items`
- Structured follow-up tasks extracted from transcript/summary.
- Stores session ID, text, status, and provenance.

### `model_runs`
- Audit trail for ASR and summary jobs.
- Stores session ID, model name, runtime, latency, status, and error details.

### `session_events`
- Operational event log for upload, transcription, summary, retry, and failure events.
- Supports debugging and live feed fan-out.

## End-to-End Pipeline

1. User opens the web app and starts a new session.
2. API creates a `session` record in Postgres and returns session metadata to the client.
3. Web client captures microphone audio using `MediaRecorder`.
4. Client emits 5-second audio chunks with a 1-second overlap to reduce boundary loss.
5. API stores each chunk in GCS and records a matching `audio_chunks` row in Postgres.
6. API publishes a Pub/Sub job for each ready chunk.
7. ASR worker receives the job, downloads the chunk, and runs `faster-whisper large-v3-turbo`.
8. ASR worker writes normalized transcript segments to `transcript_segments` and records the ASR model run.
9. API streams new transcript segments to the client over SSE.
10. Summary worker runs on transcript windows and produces rolling notes into `session_notes`.
11. When the session ends, the summary worker generates a final summary plus extracted action items and writes them to Postgres.
12. API streams final summary readiness to the client.
13. User reopens the session later and the web app reconstructs everything from Postgres plus GCS-backed artifacts.

## Execution Series

### Series 1: Platform Foundation

**Goal**
- Establish the hosted service layout and deployment baseline for the real product.

**Why it exists**
- The current repo only contains prototype app shells and local scaffolding. The hosted rebuild needs clear service boundaries before implementation starts.

**Depends on**
- Nothing. This is the first execution series.

**What gets built**
- Repo structure for a hosted system:
  - `apps/web`
  - `apps/api`
  - `services/asr-worker`
  - `services/summary-worker`
  - `packages/shared`
- Shared environment strategy with `.env.example` and GCP secret mapping.
- Dockerfiles and base deployment config for Cloud Run services.
- Initial GCP project assumptions:
  - Cloud Run CPU for API
  - Cloud Run GPU for ASR worker
  - Cloud Run GPU for summary worker
  - Cloud SQL Postgres
  - GCS bucket for audio and artifacts
  - Pub/Sub topics/subscriptions for async work
- Clear service contracts between client, API, and workers.

**Definition of done**
- Service boundaries are locked and reflected in the repo.
- Every major runtime has a defined responsibility and deployment target.
- No remaining ambiguity about whether the companion/local JSON architecture is the primary path.

**What it deliberately does not cover**
- Actual database schema.
- Actual audio capture implementation.
- Actual model inference logic.

### Series 2: Data and Persistence

**Goal**
- Replace local file storage assumptions with a real persistence model.

**Why it exists**
- Durable storage is required before transcript, note, and summary pipelines can be trusted.

**Depends on**
- Series 1.

**What gets built**
- PostgreSQL schema for users, sessions, audio chunks, transcript segments, notes, summaries, action items, model runs, and session events.
- Migration strategy and first migration set.
- GCS bucket layout:
  - raw chunk objects
  - merged session audio
  - optional exported transcripts/summaries
- API persistence logic for session creation and audio chunk metadata.

**Definition of done**
- A session can be created and stored in Postgres.
- Audio chunks can be registered and resolved to GCS object paths.
- History data no longer depends conceptually on local JSON.

**What it deliberately does not cover**
- Transcription inference.
- Summary generation.
- Realtime client delivery.

### Series 3: Audio Ingestion

**Goal**
- Capture real microphone audio in the browser and push it into the hosted backend.

**Why it exists**
- A real AI pipeline starts with real audio ingestion, not browser speech recognition text.

**Depends on**
- Series 1 and Series 2.

**What gets built**
- Web client microphone capture using `MediaRecorder`.
- Session-linked chunk upload flow to API.
- Chunk sequencing, overlap strategy, and upload retries.
- Clear client states:
  - recording
  - uploading
  - retrying
  - paused/error
- Server-side validation of chunk ordering and upload completeness.

**Definition of done**
- Starting a session results in real audio chunks landing in hosted storage.
- The client can recover from transient upload failures.
- Every uploaded chunk can be traced to one session row.

**What it deliberately does not cover**
- System-audio capture.
- Meeting-platform capture.
- Final transcript generation.

### Series 4: Transcription Service

**Goal**
- Turn stored audio chunks into accurate transcript segments using hosted Whisper inference.

**Why it exists**
- This is the core intelligence layer for the product and replaces all fake transcript behavior.

**Depends on**
- Series 1, Series 2, and Series 3.

**What gets built**
- Python ASR worker using `faster-whisper`.
- Default model: `large-v3-turbo`.
- Config path for later `large-v3` evaluation.
- Pub/Sub consumer for audio chunk jobs.
- Transcript normalization and overlap-aware segment merge strategy.
- Transcript segment persistence in Postgres.
- Model-run metrics:
  - latency
  - chunk size
  - model used
  - error status

**Definition of done**
- Uploaded chunks produce timestamped transcript segments in Postgres.
- The system no longer depends on browser speech recognition for the real transcript path.
- Latency and failure data are captured for tuning.

**What it deliberately does not cover**
- Live summary generation.
- Search and history UX polish.
- System-audio capture.

### Series 5: Realtime Transcript UX

**Goal**
- Make the transcript feel live in the product.

**Why it exists**
- The user experience depends on the transcript arriving during the conversation, not only after the session ends.

**Depends on**
- Series 4.

**What gets built**
- SSE session feed from API to client.
- Transcript event fan-out when new transcript rows are committed.
- UI handling for pending, received, delayed, and reconnected transcript states.
- Session timeline rendering based on canonical server data.

**Definition of done**
- User sees transcript updates in near real time during an active session.
- Reconnecting the client reconstructs the current transcript from server truth.
- No fake transcript placeholders remain in the main flow.

**What it deliberately does not cover**
- Summary generation.
- Meeting integrations.
- Mobile support.

### Series 6: Summary and Action Extraction

**Goal**
- Generate useful live notes and final summaries from actual transcript data.

**Why it exists**
- A transcript alone is not the final product; users want condensed understanding and follow-up extraction.

**Depends on**
- Series 4 and Series 5.

**What gets built**
- Summary worker using `Qwen2.5-7B-Instruct` via `vLLM`.
- Rolling note generation from transcript windows.
- Final summary generation when the session ends.
- Action item and decision extraction.
- Summary persistence in Postgres.

**Definition of done**
- Rolling notes appear from real transcript windows.
- Final summaries are generated from real transcript data.
- Action items are stored as structured records, not only free text.

**What it deliberately does not cover**
- Search/retrieval UX.
- Stronger alternate summary models.
- Meeting capture expansion.

### Series 7: History and Retrieval

**Goal**
- Make completed sessions useful after the meeting ends.

**Why it exists**
- Durable review is a core product promise and requires a real retrieval experience.

**Depends on**
- Series 2, Series 4, Series 5, and Series 6.

**What gets built**
- Session history list backed by Postgres.
- Session detail pages showing transcript, notes, summary, and action items.
- Filters by date, status, and source type.
- Basic search foundation across sessions and summaries.

**Definition of done**
- User can reopen a completed session and review everything from hosted storage.
- No session review flow depends on local filesystem artifacts.
- History UX works for growing session counts.

**What it deliberately does not cover**
- Semantic/vector retrieval.
- Team collaboration.
- Mobile-specific UX.

### Series 8: Meeting Capture Expansion

**Goal**
- Extend beyond plain microphone capture into harder real-world meeting inputs.

**Why it exists**
- The product vision includes desktop/browser meeting use cases, but they should not block the core hosted MVP.

**Depends on**
- Series 3 through Series 7.

**What gets built**
- System-audio capture strategy evaluation and first implementation path.
- Browser meeting capture workflow.
- Meeting source labeling in session records.
- Compatibility matrix for supported meeting surfaces.
- Future Google Meet work remains explicitly separate from MVP-critical flows.

**Definition of done**
- At least one non-microphone meeting path is real and documented.
- Meeting-origin sessions still reuse the same hosted transcript/summary pipeline.
- Unsupported meeting flows fail clearly with user-facing guidance.

**What it deliberately does not cover**
- Full Google Meet bot participation.
- Multi-platform perfection across all OS/browser combinations.

### Series 9: Production Hardening

**Goal**
- Make the hosted product reliable, observable, and safe to operate.

**Why it exists**
- MVP capability is not enough without operational discipline.

**Depends on**
- Series 1 through Series 8 as needed.

**What gets built**
- Authentication and session ownership controls.
- Logging, metrics, and alerting.
- Queue retry policy and dead-letter handling.
- Failure recovery for audio upload, transcription, and summary jobs.
- Cost/performance measurement and model tuning.

**Definition of done**
- The system can be monitored and debugged in production.
- Critical flows have retries and visible failure states.
- Cost and latency characteristics are measurable.

**What it deliberately does not cover**
- Native mobile clients.
- Team collaboration workflows.

### Series 10: Mobile Readiness

**Goal**
- Ensure the backend and product model support future mobile clients cleanly.

**Why it exists**
- Mobile is a later product expansion, but the architecture should be ready before that work begins.

**Depends on**
- Series 1 through Series 9.

**What gets built**
- Backend contracts that do not assume desktop-only behavior.
- Session and upload flows that can be reused from mobile.
- Cross-device session continuity assumptions.
- Mobile-specific backlog and constraints documentation.

**Definition of done**
- The backend can support a future mobile client without redesigning the session pipeline.
- Mobile work can start from existing contracts rather than reopening architecture decisions.

**What it deliberately does not cover**
- Shipping the native mobile app itself.
- Full mobile UX implementation.

## Current Focus

Active line: Series 4 planning and implementation for hosted transcription inference using `faster-whisper` and `large-v3-turbo`.

## Next Up

1. Implement the ASR worker runtime and job consumer for uploaded audio chunks.
2. Define how audio chunk jobs are dequeued from Pub/Sub and resolved against GCS or the dev filesystem mirror.
3. Add transcript segment persistence and sequence-number handling in Postgres.
4. Introduce a clear model-run record for ASR latency, errors, and model choice.
5. Decide the first end-to-end smoke test for audio chunk ingestion into transcript output.

## Blockers / Open Risks

- Real-time transcription quality and latency will depend on chunk size, overlap policy, and GPU service tuning.
- System-audio and browser meeting capture remain materially harder than microphone capture and should not be allowed to derail MVP.
- Summary quality may require prompt iteration or a stronger model if `Qwen2.5-7B-Instruct` underperforms on noisy transcripts.
- GCP cost control will matter once GPU-backed services run continuously; autoscaling and batching strategy must be measured, not assumed.
- The current repo still contains prototype flows that can confuse future sessions if this roadmap is not treated as the primary source of truth.

## Decisions Locked

- 2026-03-31: `ROADMAP.md` is the master planning and session continuity document.
- 2026-03-31: The product is now planned as a hosted rebuild on GCP, not as a local-first-only architecture.
- 2026-03-31: The current repo is prototype scaffolding, not proof that the target production backend exists.
- 2026-03-31: Use PostgreSQL for structured data and Google Cloud Storage for audio/artifacts; do not use JSON archives as product storage.
- 2026-03-31: Use `faster-whisper` as the primary ASR runtime.
- 2026-03-31: Use `large-v3-turbo` as the default ASR model for MVP, with `large-v3` as a later accuracy tier.
- 2026-03-31: Use `Qwen2.5-7B-Instruct` as the default summary/action extraction model.
- 2026-03-31: Use `vLLM` as the hosted LLM serving runtime.
- 2026-03-31: Use SSE as the default realtime transcript/note delivery path for MVP.
- 2026-03-31: Defer desktop companion and system-audio capture to later expansion instead of making them MVP-critical.
- 2026-03-31: Series 1 is complete with hosted service scaffolds, shared hosted contracts, Dockerfiles, `.dockerignore`, and a baseline Cloud Run deployment reference.
- 2026-04-01: Series 2 is complete with a canonical Postgres schema, GCS object layout, async API persistence seam, and a `pg`-backed repository path selected by `POSTGRES_URL`.
- 2026-04-01: Series 3 is complete with hosted microphone capture, sequential chunk upload, GCS-ready object storage, and a hosted session stop path.

## Session Restart Notes

- Start every future session by reading this file first, not `STATE.md`.
- Treat any browser speech recognition path and local JSON archive code as temporary scaffolding unless explicitly noted otherwise here.
- Series 1 is done; do not reopen service-boundary debates unless a later requirement forces a real architecture change.
- Series 2 is done; do not fork the schema again or reintroduce duplicate migration baselines.
- Series 3 is done; do not reopen the microphone upload path unless a bug fix or refinement is required.
- The next implementation work should begin with hosted transcription inference in the ASR worker, not Google Meet or prototype local-flow polish.
- When this file is updated in future sessions, keep `Current Focus` to one active line and keep `Decisions Locked` append-only.
