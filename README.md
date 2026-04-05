# Voice-to-Text Summarizer

Local-first voice capture, final transcription, and final summary application.

## Current Direction

- web app for recording, status, transcript, summary, and history
- local API service for session lifecycle and upload handling
- local `faster-whisper` ASR worker using `large-v3`
- local summary worker for one final summary plus action items
- Supabase Postgres for structured session data
- local filesystem storage for raw chunks and merged audio artifacts

The current planning source of truth is [.planning/ROADMAP.md](.planning/ROADMAP.md).

## Structure

- `apps/web` - web client
- `apps/api` - local API service
- `apps/companion` - legacy prototype companion
- `services/asr-worker` - Python ASR worker
- `services/summary-worker` - summary worker
- `packages/shared` - shared contracts and constants

## Stack

- TypeScript
- Python for the ASR worker
- npm workspaces
- Vite for the web client
- `faster-whisper` for transcription

## Getting Started

Install dependencies:

```bash
npm install
```

Run the local API, workers, and web app:

```bash
npm run dev:hosted
```

Legacy prototype path:

```bash
npm run dev
```

## Scripts

- `npm run dev` - runs the legacy prototype app and companion together
- `npm run dev:hosted` - runs the local API, ASR worker, summary worker, and web app
- `npm run dev:api` - runs only the API
- `npm run dev:asr-worker` - runs only the ASR worker
- `npm run dev:summary-worker` - runs only the summary worker
- `npm run dev:web` - runs only the web app
- `npm run dev:companion` - runs only the legacy companion
- `npm run build` - builds all workspace packages
- `npm run typecheck` - type-checks all workspace packages

## Architecture Reset

The active product reset is accuracy-first and post-call:

1. capture real audio in the browser
2. store raw chunks on the local filesystem
3. assemble one merged session artifact after capture ends
4. normalize the merged session audio for quiet speech and run `faster-whisper` with `large-v3` on the final artifact
5. generate one final summary from the authoritative transcript
6. review transcript, summary, and action items from Supabase-backed session history

Live notes are legacy scaffolding and are not part of the target MVP.

For the authoritative final pass, VAD is disabled by default and the ASR worker keeps an internal reprocess path for sessions that ended with uploaded audio but no usable transcript segments.

## Legacy Prototype

The repository still includes:

- a companion app shell
- simulated transcript and note paths
- meeting-helper experiments
- experimental Google Meet scaffolding

Those pieces are useful reference material, but they are not the target product architecture.
