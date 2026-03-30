# Voice-to-Text Summarizer

Monorepo scaffold for a web-first voice-to-text summarizer with a desktop companion and a shared bridge contract.

## Structure

- `apps/web` - minimal web app shell
- `apps/companion` - minimal desktop companion/server shell
- `packages/shared` - shared bridge types and contract constants

## Stack

- TypeScript
- npm workspaces
- Vite for the web shell
- `tsx` for the companion development server

## Getting Started

```bash
npm install
npm run dev
```

## Scripts

- `npm run dev` - runs the web app and companion together
- `npm run dev:web` - runs only the web app
- `npm run dev:companion` - runs only the companion server
- `npm run build` - builds all workspace packages
- `npm run typecheck` - type-checks all workspace packages

## Bridge Contract

The shared package exports the session, transcript, summary, runtime config, and bridge command types that the web app and companion will use as the product grows.

The companion also exposes an in-memory runtime config endpoint at `/config` so the web UI can display the current local runtime and the English-first defaults.

For Phase 2, the companion also serves a simulated transcript stream at `/transcript` so the web UI can poll and render incremental transcript chunks before real speech-to-text is wired in.

For Phase 3, the companion adds `/notes` and `/summary` so the web UI can display simulated live notes during a session and a generated final summary after the session stops.

Completed sessions are also archived locally under `.voice-to-text-summarizer/sessions.json` so the later history UI can read them back without needing a database yet.

The archive can be read from `/sessions` and `/sessions/:id` when the history screen needs to list or reopen a finished session.

For Phase 4, the companion exposes `/meeting-helper` so the web UI can steer a browser meeting or desktop meeting workflow. Google Meet is shown as a fallback path only; the app does not join Meet as a bot or hidden participant.

For Phase 5, the companion also exposes `/experimental/google-meet` behind the `VOICE_TO_TEXT_EXPERIMENTAL_GOOGLE_MEET=1` flag. The web UI renders this as a lab-only control so developers can prototype the integration boundary, status model, and failure handling without affecting the stable meeting-helper flow. This path still does not join Google Meet as a bot or hidden participant.

Developer notes for the experimental boundary live in [docs/experimental-google-meet.md](docs/experimental-google-meet.md).
