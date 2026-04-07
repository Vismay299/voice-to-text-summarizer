# Master Execution Roadmap: Voice-to-Text Summarizer

> Status: Planning reset for macOS universal dictation
>
> Last updated: 2026-04-05

Voice-to-Text Summarizer is now planned as a local-first macOS dictation product: a push-to-talk app that captures microphone audio on the user's machine, transcribes it locally with `faster-whisper + large-v3`, cleans the text for the active context, and inserts the result into the currently focused text input without automatically pressing Enter.

The current repository is still useful, but it is no longer primarily a meeting-summary product. It contains a web UI shell, local API and worker infrastructure, session history concepts, and real local ASR work that can be reused. It also contains legacy meeting-summary assumptions that should now be treated as background context, not the active product direction.

Source of truth:
- `ROADMAP.md` is the main planning and session continuity document.
- `PROJECT.md` remains background context and original project framing.
- `STATE.md` is secondary and may lag behind this file.

## Vision

Build a fast, accurate local dictation layer for macOS that lets a user speak anywhere they would normally type, especially inside terminal-based AI tools, and have clean text inserted directly at the current cursor with zero cloud dependency.

## Product Goal

The MVP succeeds when all of the following are true:
- A user can hold one global push-to-talk hotkey from anywhere in macOS.
- The app records microphone audio locally and transcribes it locally with `large-v3`.
- The transcript is cleaned according to the active mode before insertion.
- The app can insert text into the currently focused input without auto-submitting it.
- Terminal usage is safe by default:
  - no automatic Enter press
  - no automatic command execution
- Voice commands work for core formatting cases:
  - `new line`
  - `slash command`
  - `open quote`
  - `code block`
- The app keeps local snippet history so the user can review, copy, and resend dictated text.
- The entire MVP runs locally and stays free to operate.

## Current Truth

- The repo currently contains a TypeScript monorepo with `apps/web`, `apps/api`, `apps/companion`, `services/asr-worker`, `services/summary-worker`, and `packages/shared`.
- The strongest reusable assets in the current codebase are:
  - local audio capture and chunk handling concepts
  - local `faster-whisper` integration
  - status/history/persistence patterns
  - shared contracts and worker boundaries
- The current product shell is still shaped around session capture, transcript review, and summary history rather than universal dictation into the focused app.
- There is no real macOS-native shell yet for:
  - global hotkeys
  - accessibility permission handling
  - focused-app detection
  - direct text insertion at the current cursor
- The current meeting-helper and Google Meet work is parked. It is legacy exploration, not active roadmap scope.
- Final-summary logic and session history are still useful as future optional features, but they are no longer the center of the MVP.
- The ASR plan remains standardized on `large-v3` only. There is no planned `large-v3-turbo` fallback in the MVP architecture.
- Existing code may be reused selectively, but the roadmap now assumes a product pivot toward universal dictation rather than meeting summarization.

## Target Architecture

Locked defaults for the new local-first dictation MVP:

| Layer | Default Choice | Notes |
| --- | --- | --- |
| Product surface | macOS menu bar app | Lightweight always-available UX for dictation from anywhere. |
| Platform | macOS only | Keep v1 narrow and reliable. |
| Capture model | Push-to-talk only | No always-listening behavior in MVP. |
| Input source | Local microphone | The first real path; richer capture modes can come later. |
| ASR runtime | `faster-whisper` now, `MLX Whisper` under benchmark in `12.4.1` | Keep the current CPU bridge working while we evaluate the Apple Silicon path and keep the better one. |
| ASR model | `large-v3` | Accuracy-first default for every dictated utterance. |
| Cleanup modes | `Terminal` and `Writing` | Terminal mode stays closer to the source; Writing mode cleans more aggressively. |
| Command handling | Deterministic parser | Voice commands should map predictably, not through fuzzy LLM behavior. |
| Insertion engine | macOS Accessibility APIs first | Use focused-element insertion when possible. |
| Insertion fallback | Simulated key events / paste path | Used only when focused-element insertion is not reliable enough. |
| History store | Local SQLite | Free, local, and sufficient for snippet history. |
| Artifact storage | Local filesystem | Raw audio and optional debug artifacts stay local. |
| Cloud dependency | None for MVP | No GCP, no paid APIs, no required Supabase path for v1. |
| Summary feature | Optional later | Not part of the main v1 dictation flow. |

Non-goals for the new MVP:
- No Google Meet bot or meeting-assistant workflow.
- No cloud-hosted transcription or summary service.
- No automatic command execution in terminals.
- No automatic Enter press after insertion.
- No requirement to support every rich editor perfectly in v1.
- No mobile client in the initial milestone.

## Core Systems

### 1. macOS Shell
- Runs as a menu bar app with a small preferences surface.
- Registers the global push-to-talk hotkey.
- Requests and checks microphone permission.
- Requests and checks Accessibility permission.
- Shows a minimal floating overlay for:
  - recording
  - transcribing
  - inserting
  - error states

### 2. Dictation Capture Pipeline
- Starts recording when the hotkey is held.
- Stops recording when the hotkey is released.
- Writes one local utterance artifact per dictation event.
- Keeps capture flow lightweight enough for repeated use all day.

### 3. Local ASR Engine
- Runs `large-v3` through the current local bridge.
- Benchmarks the current `faster-whisper` path against an `MLX Whisper` path on Apple Silicon before locking the long-term runtime.
- Produces one final transcript per utterance.
- Prefers accuracy over near-live partial text.
- Captures timing and failure metadata for tuning.

### 4. Text Cleanup Layer
- Takes the raw transcript and transforms it based on active mode.
- `Terminal` mode:
  - preserve intent closely
  - minimal smoothing
  - avoid over-rewriting
- `Writing` mode:
  - fix punctuation
  - remove filler words where appropriate
  - make prose more readable

### 5. Voice Command Layer
- Detects and transforms deterministic spoken commands.
- Initial commands:
  - `new line`
  - `slash command`
  - `open quote`
  - `code block`
- Should operate before insertion, and should be auditable in the snippet result.

### 6. Universal Insertion Engine
- Detects the currently focused app and editable element.
- Inserts text directly at the current cursor when possible.
- Never submits the terminal automatically.
- Falls back gracefully when an app exposes weak editing hooks.

### 7. Local History Layer
- Stores dictated snippets, insertion outcomes, timestamps, and mode used.
- Allows review, copy, resend, and debugging.
- Uses SQLite as the structured store of record for v1.

## Data Model

### `app_settings`
- Stores user preferences for:
  - push-to-talk hotkey
  - default mode
  - overlay behavior
  - audio device
  - cleanup toggles

### `utterances`
- One row per push-to-talk recording.
- Stores:
  - start/end timestamps
  - mode
  - source device
  - app target metadata
  - status

### `utterance_artifacts`
- Artifact references for one utterance.
- Stores:
  - raw audio path
  - normalized audio path if used
  - debug metadata

### `transcripts`
- Final transcript result for an utterance.
- Stores:
  - utterance ID
  - text
  - model name
  - runtime
  - latency
  - confidence metadata if available

### `insertions`
- Records insertion attempts and outcomes.
- Stores:
  - utterance ID
  - target app bundle identifier
  - target app name
  - insertion strategy used
  - success/failure status
  - error details if any

### `snippet_history`
- User-facing history of dictated output.
- Stores:
  - final inserted text
  - cleaned text
  - raw transcript
  - mode
  - created timestamp
  - resend / copy metadata

### `events`
- Operational event log for:
  - recording started
  - recording ended
  - transcription started
  - transcription completed
  - insertion attempted
  - insertion completed
  - insertion failed

## End-to-End Pipeline

1. User focuses any editable text input, including a terminal prompt.
2. User holds the global push-to-talk hotkey.
3. The macOS app starts local microphone capture.
4. User releases the hotkey.
5. The app finalizes one utterance audio artifact locally.
6. The ASR engine runs the current `large-v3` local bridge on that utterance.
7. If Phase `12.4.1` is active, the app can benchmark the utterance against both `faster-whisper` and `MLX Whisper` on the same machine.
8. The raw transcript is passed through the cleanup layer according to active mode.
9. The voice command layer converts supported spoken commands into formatting/output tokens.
10. The insertion engine detects the focused app and attempts direct cursor insertion.
11. The app inserts the text without pressing Enter.
12. The utterance, transcript, insertion result, and final snippet are stored in local SQLite.
13. The user can reopen recent snippet history, copy text, or resend it.

## Execution Series

### Series 1: Product Reset and Legacy Carve-Out

**Goal**
- Reset the project around universal dictation and freeze the previous meeting-summary work as legacy background.

**Why it exists**
- The repo currently points in two directions. We need one primary product before implementation continues.

**Depends on**
- Nothing. This is the active planning reset.

**What gets built**
- Updated roadmap and product language.
- Clear separation between:
  - active dictation MVP
  - legacy meeting-summary code
- Initial decision log for:
  - push-to-talk
  - terminal-safe insertion
  - local-only architecture
  - mode system

**Definition of done**
- The roadmap no longer frames Google Meet or meeting summaries as the active MVP.
- Future sessions can resume from this file without reopening product direction.

**What it deliberately does not cover**
- Any new runtime code.

### Series 2: macOS App Shell

**Goal**
- Create the native shell that can run continuously in the menu bar.

**Why it exists**
- Universal dictation needs OS-level presence that the current web shell cannot provide.

**Depends on**
- Series 1.

**What gets built**
- Menu bar app shell.
- Preferences window or lightweight settings panel.
- App lifecycle and background operation behavior.
- Minimal overlay window for status feedback.

**Definition of done**
- The app launches on macOS and remains available from the menu bar.
- There is a visible status surface for recording and transcription state.

**What it deliberately does not cover**
- Actual ASR.
- Actual insertion into external apps.

### Series 3: Permissions and Global Hotkey

**Goal**
- Make the app able to listen for push-to-talk and control other apps safely.

**Why it exists**
- Without microphone and Accessibility permissions, the product cannot exist.

**Depends on**
- Series 2.

**What gets built**
- Microphone permission flow.
- Accessibility permission flow.
- Trusted-state checks and recovery prompts.
- Global hotkey registration.

**Definition of done**
- User can grant permissions once and reliably trigger dictation from any app.

**What it deliberately does not cover**
- Transcription quality.
- Text insertion behavior.

### Series 4: Local Utterance Capture

**Goal**
- Record one utterance cleanly for each hotkey hold/release cycle.

**Why it exists**
- The product needs short, reliable, repeatable capture rather than long session recording.

**Depends on**
- Series 2 and Series 3.

**What gets built**
- Hold-to-record capture behavior.
- Utterance artifact creation.
- Device selection basics.
- Local debug artifacts when enabled.

**Definition of done**
- Each hotkey cycle produces one local utterance artifact ready for transcription.

**What it deliberately does not cover**
- Final app insertion.
- Cleanup logic.

### Series 5: Local Large-v3 Transcription

**Goal**
- Turn each captured utterance into one accurate final transcript.

**Why it exists**
- This is the core intelligence layer and the main quality driver for the product.

**Depends on**
- Series 4.

**What gets built**
- `faster-whisper + large-v3` invocation for utterances.
- Model boot and reuse strategy.
- Local latency/error tracking.
- Final transcript persistence.

**Definition of done**
- Releasing the hotkey eventually produces one final transcript for the utterance.
- The system no longer depends on browser speech recognition or session-summary assumptions.

**What it deliberately does not cover**
- Text cleanup.
- Cursor insertion.

### Series 6: Cleanup Modes

**Goal**
- Convert raw transcripts into text that fits the active writing context.

**Why it exists**
- Raw speech and useful typed text are not the same thing, especially in terminals versus prose editors.

**Depends on**
- Series 5.

**What gets built**
- `Terminal` mode cleanup rules.
- `Writing` mode cleanup rules.
- Filler-word removal policy.
- Punctuation normalization.

**Definition of done**
- The app produces clearly different output behavior for terminal dictation versus writing dictation.

**What it deliberately does not cover**
- Voice commands.
- App insertion.

### Series 7: Deterministic Voice Commands

**Goal**
- Support a small, reliable command vocabulary for formatting and prompt construction.

**Why it exists**
- Spoken formatting is necessary for practical dictation in terminals and documents.

**Depends on**
- Series 6.

**What gets built**
- Parsing for:
  - `new line`
  - `slash command`
  - `open quote`
  - `code block`
- Command-to-output transformation rules.
- Tests for ambiguous utterances and false positives.

**Definition of done**
- The command vocabulary produces predictable output and does not depend on fuzzy LLM interpretation.

**What it deliberately does not cover**
- Rich cursor integration with specific apps.

### Series 8: Universal Insertion Engine

**Goal**
- Insert dictated text into the currently focused input field.

**Why it exists**
- This is the core user-facing payoff of the product.

**Depends on**
- Series 3, Series 5, Series 6, and Series 7.

**What gets built**
- Focused app detection.
- Focused editable element detection.
- Direct insertion strategy through Accessibility APIs.
- Fallback strategy for difficult apps.
- No-auto-submit safety rule.

**Definition of done**
- The app can insert dictated text at the current cursor in at least one terminal and one standard text field without pressing Enter.

**What it deliberately does not cover**
- Perfect support for every rich editor.
- Full app-specific compatibility guarantees.

### Series 9: Terminal Hardening

**Goal**
- Make the insertion path trustworthy for AI CLI workflows.

**Why it exists**
- Terminal usage is the highest-value use case and the riskiest if insertion is sloppy.

**Depends on**
- Series 8.

**What gets built**
- Validation against macOS Terminal.
- Validation against iTerm2.
- Validation against common AI CLI flows.
- Multiline prompt handling.
- Explicit no-auto-enter protection.

**Definition of done**
- The user can dictate into terminal-based AI tools safely and review before submitting manually.

**What it deliberately does not cover**
- Executing commands on behalf of the user.

### Series 10: History and Resend

**Goal**
- Make dictated output recoverable and reusable.

**Why it exists**
- Snippet history is part of the agreed MVP and makes the product practical for repeated prompt writing.

**Depends on**
- Series 5 through Series 9.

**What gets built**
- SQLite snippet history.
- History UI.
- Copy and resend flows.
- Insert-again flow for recent snippets.

**Definition of done**
- The user can recover, copy, and resend recent dictated snippets locally.

**What it deliberately does not cover**
- Cloud sync.
- Multi-device history.

### Series 11: Editor Compatibility Expansion

**Goal**
- Expand beyond terminals and plain text fields into more complex editors.

**Why it exists**
- The long-term product should work in places like Google Docs, but that should not block the terminal-first MVP.

**Depends on**
- Series 8 through Series 10.

**What gets built**
- Browser textarea compatibility matrix.
- Rich-editor behavior notes.
- Google Docs strategy evaluation.
- App-specific fallback handling where justified.

**Definition of done**
- We have a documented support matrix and at least one browser-based rich editor path that works acceptably.

**What it deliberately does not cover**
- Perfect support for every editor.
- Native collaboration features.

## Immediate GSD Phase Queue

These are the next GSD-sized executable phases for the dictation pivot. Each phase is intentionally small enough to be planned and executed in focused sessions.

### Phase 12.1: macOS Shell Scaffold
- Goal: create the native menu bar shell and basic runtime wiring for the new product.
- Why now: the current web shell cannot own global hotkeys or universal insertion.
- Definition of done: the app launches as a macOS menu bar app with a minimal status surface.

### Phase 12.2: Permission and Hotkey Gate
- Goal: add microphone permission, Accessibility permission, and one global push-to-talk hotkey.
- Why now: every later feature depends on trusted OS-level access.
- Definition of done: the user can hold the hotkey from any app and the shell can verify required permissions.

### Phase 12.3: Local Utterance Capture
- Goal: capture one utterance artifact per hotkey cycle.
- Why now: the new product is utterance-based, not session-based.
- Definition of done: press-hold-release yields one saved local audio artifact.
- Test rule: the default self-test path stays pure; any live microphone smoke is opt-in only and must not block normal test runs.

### Phase 12.4: Large-v3 Utterance Transcription
- Goal: run `faster-whisper + large-v3` for one utterance and persist the transcript.
- Why now: transcript quality is the core product value.
- Definition of done: one utterance produces one final transcript locally.

### Phase 12.4.1: Apple Silicon Runtime Benchmark
- Goal: build an `MLX Whisper` bridge for `large-v3`, benchmark it against the current `faster-whisper` CPU path on this Mac, and lock the faster/better local runtime before cleanup and insertion work continues.
- Why now: Apple Silicon acceleration may materially improve dictation latency, and the correct move is to compare real local performance instead of assuming.
- Definition of done: the roadmap records one chosen `large-v3` runtime for the macOS app based on measured latency, transcript quality, startup behavior, and operational simplicity on the target machine.

### Phase 12.5: Cleanup Modes
- Goal: implement `Terminal` and `Writing` output modes.
- Why now: the same raw transcript should not be inserted the same way everywhere.
- Definition of done: the app can produce terminal-safe text and cleaned writing text from the same voice input.

### Phase 12.6: Voice Command Parser
- Goal: add deterministic support for the first four spoken commands.
- Why now: formatting control is essential for prompts and writing.
- Definition of done: `new line`, `slash command`, `open quote`, and `code block` work reliably.

### Phase 12.7: Terminal-Safe Insertion
- Goal: insert dictated text into the focused terminal input without auto-submitting.
- Why now: this is the most valuable initial target surface.
- Definition of done: dictated text appears at the cursor in a supported terminal and never presses Enter automatically.

### Phase 12.8: Local History
- Goal: store and expose snippet history with resend/copy support.
- Why now: history is part of the agreed MVP and improves trust.
- Definition of done: recent snippets are queryable locally and can be copied or reinserted.

## Current Focus

Active line: Phase 12.7 next: terminal-safe focused-input insertion without auto-submitting.

## Next Up

1. Plan Phase `12.4.1` for the `MLX Whisper` vs `faster-whisper` local runtime benchmark.
2. Plan Phase `12.6` for deterministic voice-command parsing (`new line`, `slash command`, `open quote`, `code block`).
3. Plan Phase `12.7` for terminal-safe focused-input insertion.
4. Plan Phase `12.8` for local history polish and resend behavior.

## Blockers / Open Risks

- macOS Accessibility support varies by app, so “works anywhere you can type” should be treated as an aspiration rather than a day-one guarantee.
- Rich editors such as browser-based document editors may expose weaker insertion hooks than terminals or standard text fields.
- `large-v3` quality will be strong, but startup latency and warm-model behavior may still need tuning for short utterances.
- We have not yet benchmarked `MLX Whisper` against the current `faster-whisper` CPU bridge on this exact machine, so runtime choice is not fully locked until Phase `12.4.1` completes.
- Deterministic voice commands need careful false-positive handling so ordinary speech is not mangled.
- The repo still contains meeting-summary and session-history assumptions that can confuse future sessions if this roadmap is not treated as the primary source of truth.

## Decisions Locked

- 2026-03-31: `ROADMAP.md` is the master planning and session continuity document.
- 2026-03-31: The current repo is prototype scaffolding, not proof that the target product backend already exists.
- 2026-03-31: Use `faster-whisper` as the primary ASR runtime.
- 2026-03-31: Use `large-v3` as the ASR model for the accuracy-first MVP.
- 2026-04-04: Accuracy is now prioritized over realtime. The authoritative transcript should come from a final local pass rather than weak live text.
- 2026-04-04: Live notes are removed from the target MVP.
- 2026-04-04: `large-v3` is the only planned ASR model for the MVP.
- 2026-04-05: Google Meet and meeting-assistant work are on hold and not part of the active MVP.
- 2026-04-05: The product is now a macOS universal dictation app rather than a meeting-summary-first app.
- 2026-04-05: v1 is macOS only.
- 2026-04-05: v1 uses a menu bar shell.
- 2026-04-05: v1 is push-to-talk only.
- 2026-04-05: v1 inserts text at the current cursor and never presses Enter automatically.
- 2026-04-05: v1 ships with two modes: `Terminal` and `Writing`.
- 2026-04-05: Voice commands are part of the MVP and must be deterministic.
- 2026-04-05: Local SQLite is the history store for v1.
- 2026-04-05: Google Docs is only an example target surface, not the defining integration for MVP.
- 2026-04-05: Phase 12.1 is complete with a native Swift/SwiftUI menu bar scaffold that runs locally via `swift run`.
- 2026-04-05: Phase 12.2 is complete with microphone and Accessibility permission state management, Right Option hotkey monitoring, and shell UI/status wiring in the native macOS app.
- 2026-04-05: Phase 12.3 must keep the always-pass test path pure; any live microphone smoke check is opt-in only and must not be flaky or required.
- 2026-04-05: Phase 12.3 is complete with one local WAV utterance artifact per hotkey cycle, deterministic Application Support storage, and single-owner hotkey-to-capture coordination in the native app.
- 2026-04-05: Phase 12.4 is complete with one final local transcript per saved utterance, a bundled Python `faster-whisper + large-v3` bridge, serialized transcription queueing, persisted transcript JSON artifacts, and an opt-in real `large-v3` smoke transcription check.
- 2026-04-06: `large-v3` remains locked as the model, but the long-term local runtime is now gated on a Phase `12.4.1` benchmark between the current `faster-whisper` CPU path and an `MLX Whisper` Apple Silicon path.
- 2026-04-06: Phase 12.5 is complete with `Terminal` and `Writing` cleanup modes wired into the transcription pipeline, persisted per-transcription, selectable in Settings and the menu bar panel, displayed with mode badges in History, and covered by 18 test assertions in the self-test runner.
- 2026-04-06: Phase 12.6 is complete with deterministic voice-command parsing (`new line`, `slash command`, `open quote`, `code block`), sentence-boundary detection to prevent false positives, command badges in HistoryView, command reference card in SettingsView, and 24 test assertions covering detection, false-positive prevention, edge cases, and pipeline integration.

## Session Restart Notes

- Start every future session by reading this file first, not `STATE.md`.
- Treat all Google Meet and meeting-summary work as parked unless this roadmap says otherwise.
- Reuse the local ASR and worker knowledge from earlier work, but do not let the old web-session product shape dictate the new app architecture.
- The macOS shell, permission/hotkey gate, utterance-capture path, local transcription path, and cleanup modes (Terminal + Writing) now exist under `apps/macos 12.5`. The next real build step is Phase `12.6` for deterministic voice commands.
- Keep the default self-test runner pure and gate any live smoke behind an explicit environment flag.
- Keep the terminal-safe rule non-negotiable: no automatic Enter and no automatic execution.
- Keep `Current Focus` to one active line and keep `Decisions Locked` append-only when updating this file.
