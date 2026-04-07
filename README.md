# Voice-to-Text Summarizer

Local-first voice tooling, now pivoting toward a native macOS dictation app for anywhere you type.

## Current Direction

- native macOS menu bar app in Swift/SwiftUI for push-to-talk dictation
- local `faster-whisper` ASR worker using `large-v3`
- terminal-safe insertion into the focused app without auto-submitting
- deterministic voice commands for formatting
- local SQLite snippet history
- local filesystem storage for utterance artifacts

The current planning source of truth is [.planning/ROADMAP.md](.planning/ROADMAP.md).

## Structure

- `apps/macos` - native Swift/SwiftUI macOS shell scaffold
- `apps/web` - legacy web client and useful debug shell
- `apps/api` - local API service
- `apps/companion` - legacy prototype companion
- `services/asr-worker` - Python ASR worker
- `services/summary-worker` - summary worker
- `packages/shared` - shared contracts and constants

## Stack

- Swift + SwiftUI for the native shell
- TypeScript for the existing local services and web tooling
- Python for the ASR worker
- npm workspaces
- Vite for the legacy web client
- `faster-whisper` for transcription

## Getting Started

Install dependencies:

```bash
npm install
python3 -m pip install -r services/asr-worker/requirements.txt
```

Run the native macOS shell:

```bash
npm run dev:macos
```

Build the native macOS shell:

```bash
npm run build:macos
```

Run the native shell self-tests:

```bash
npm run test:macos
```

The native self-test runner is intentionally pure-first. Live capture and real `large-v3` transcription smoke checks stay opt-in and never become part of the always-pass path.

Legacy local API, workers, and web app:

```bash
npm run dev:hosted
```

Legacy prototype path:

```bash
npm run dev
```

## Scripts

- `npm run dev:macos` - runs the native Swift/SwiftUI menu bar shell
- `npm run build:macos` - builds the native Swift package
- `npm run test:macos` - runs the native shell self-test harness
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

The active product reset is a local macOS dictation app:

1. run a native menu bar app that stays available from anywhere
2. capture one utterance per push-to-talk cycle and save it locally
3. transcribe locally with `faster-whisper + large-v3`
4. clean the transcript for `Terminal` or `Writing` mode
5. apply deterministic spoken formatting commands
6. insert the final text at the focused cursor without pressing Enter
7. keep local snippet history for copy and resend

The current native shell now covers Phase 12.1, 12.2, 12.3, and 12.4. It gives us:

- a real menu bar app entry point
- permissions and hotkey gating
- utterance-based local WAV artifact creation
- one saved local transcript per captured utterance through the bundled Python `large-v3` bridge
- a settings window
- a local history surface for capture artifacts and transcript results
- a clear place to add cleanup modes and insertion next

The previous web/session-summary architecture remains in the repo as legacy material and reusable infrastructure, but it is no longer the defining MVP product shape.
