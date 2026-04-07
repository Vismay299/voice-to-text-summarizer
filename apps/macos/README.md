# VoiceToTextMac

Native macOS shell scaffold for the local dictation app.

## Current Scope

- menu bar app shell
- lightweight status surface
- settings window
- snippet history placeholder window
- microphone and Accessibility permission status
- Right Option push-to-talk hotkey monitoring scaffold
- local utterance capture into deterministic Application Support storage
- local `faster-whisper + large-v3` utterance transcription
- locally persisted transcript JSON artifacts

This package does not yet implement:

- focused-app text insertion

The always-pass self-test runner checks pure helpers, queueing behavior, and local transcript persistence. Live smoke checks stay opt-in and must never block the default test path.

## Run Locally

Install the local ASR dependencies once:

```bash
python3 -m pip install -r ../../services/asr-worker/requirements.txt
```

Then run the app:

```bash
cd apps/macos
swift run VoiceToTextMac
```

## Build

```bash
cd apps/macos
swift build
```

## Self-Test

```bash
cd apps/macos
swift run VoiceToTextMacTestRunner
```

Optional best-effort smoke:

```bash
VOICE_TO_TEXT_MACOS_SMOKE_CAPTURE=1 swift run VoiceToTextMacTestRunner
```

```bash
VOICE_TO_TEXT_MACOS_SMOKE_TRANSCRIBE=1 swift run VoiceToTextMacTestRunner
```

`VOICE_TO_TEXT_MACOS_SMOKE_CAPTURE=1` uses the live microphone path. `VOICE_TO_TEXT_MACOS_SMOKE_TRANSCRIBE=1` generates a spoken sample with macOS `say`, routes it through the bundled Python bridge, and verifies a real `large-v3` local transcript.
