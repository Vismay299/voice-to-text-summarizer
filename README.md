# Voice-to-Text Summarizer

Monorepo scaffold for a web-first voice-to-text summarizer with a desktop companion and a shared bridge contract.

The repo is now being reshaped into a hosted rebuild. The new foundation adds:

- `apps/api` - hosted API scaffold
- `services/asr-worker` - transcription worker scaffold
- `services/summary-worker` - summary worker scaffold
- `packages/shared/src/hosted.ts` - hosted service contracts and environment keys
- `infra/cloud-run` - baseline Docker/build/deploy notes for the hosted services
- `apps/web` - dedicated hosted microphone capture flow using `MediaRecorder`

See [docs/hosted-architecture.md](docs/hosted-architecture.md) for the current hosted layout and storage model.

## Structure

- `apps/web` - minimal web app shell
- `apps/api` - hosted API scaffold
- `apps/companion` - minimal desktop companion/server shell
- `services/asr-worker` - hosted transcription worker scaffold
- `services/summary-worker` - hosted summary worker scaffold
- `packages/shared` - shared bridge types and contract constants

## Stack

- TypeScript
- npm workspaces
- Vite for the web shell
- `tsx` for the companion development server

## Getting Started

Hosted rebuild path:

```bash
npm install
npm run dev:hosted
```

Legacy prototype path:

```bash
npm run dev
```

## Scripts

- `npm run dev` - runs the legacy web app and companion prototype together
- `npm run dev:hosted` - runs the hosted API and worker scaffolds together
- `npm run dev:api` - runs only the hosted API scaffold
- `npm run dev:asr-worker` - runs only the hosted ASR worker scaffold
- `npm run dev:summary-worker` - runs only the hosted summary worker scaffold
- `npm run dev:web` - runs only the web app
- `npm run dev:companion` - runs only the companion server
- `npm run build` - builds all workspace packages
- `npm run typecheck` - type-checks all workspace packages

## Legacy Prototype Contract

The shared package exports the session, transcript, summary, runtime config, and bridge command types that the web app and companion will use as the product grows.

The companion also exposes an in-memory runtime config endpoint at `/config` so the web UI can display the current local runtime and the English-first defaults.

For Phase 2, the companion also serves a simulated transcript stream at `/transcript` so the web UI can poll and render incremental transcript chunks before real speech-to-text is wired in.

For Phase 3, the companion adds `/notes` and `/summary` so the web UI can display simulated live notes during a session and a generated final summary after the session stops.

Completed sessions are also archived locally under `.voice-to-text-summarizer/sessions.json` so the later history UI can read them back without needing a database yet.

The archive can be read from `/sessions` and `/sessions/:id` when the history screen needs to list or reopen a finished session.

For Phase 4, the companion exposes `/meeting-helper` so the web UI can steer a browser meeting or desktop meeting workflow. Google Meet is shown as a fallback path only; the app does not join Meet as a bot or hidden participant.

For Phase 5, the companion also exposes `/experimental/google-meet` behind the `VOICE_TO_TEXT_EXPERIMENTAL_GOOGLE_MEET=1` flag. The web UI renders this as a lab-only control so developers can prototype the integration boundary, status model, and failure handling without affecting the stable meeting-helper flow. This path still does not join Google Meet as a bot or hidden participant.

Developer notes for the experimental boundary live in [docs/experimental-google-meet.md](docs/experimental-google-meet.md).

## Hosted Rebuild

The hosted architecture now treats PostgreSQL and Google Cloud Storage as the durable product storage, with `faster-whisper` and a hosted LLM worker as the production inference path. The current prototype app is still present, but it is no longer the target architecture for Series 1 and beyond.

Series 2 adds the first durable persistence scaffold and documents it in:

- [infra/postgres/001_series2_persistence.sql](infra/postgres/001_series2_persistence.sql)
- [docs/persistence-model.md](docs/persistence-model.md)
- [docs/gcs-object-layout.md](docs/gcs-object-layout.md)

Series 3 adds the hosted microphone ingestion path:

- the web app creates hosted sessions on `apps/api`
- browser `MediaRecorder` chunks are uploaded sequentially with retry
- chunk payloads go to GCS when `GCS_BUCKET_NAME` is configured
- the API falls back to a dev-only filesystem mirror when the bucket is absent
- session stop is handled through the hosted API so the browser can complete cleanly
