# SpeakFlow

**Push-to-talk dictation for your Mac. Fully local. No cloud. No subscription.**

Hold a hotkey, speak, release — your words appear wherever your cursor is. Terminal, browser, editor, chat app. Nothing leaves your machine.

---

## Download

**[Download SpeakFlow-0.1.0.dmg](https://github.com/Vismay299/voice-to-text-summarizer/releases/latest)**

> Requires macOS 13+ and Apple Silicon (M1 or later).

---

## What it does

- **Hold Right Option** anywhere on your Mac to start recording
- **Release** to transcribe and insert text at your cursor
- Works in Terminal, iTerm2, Warp, Chrome, Safari, Notion, VS Code, Claude.ai — anywhere you can type
- **Never presses Enter** — you review before submitting
- Two modes: **Terminal** (safe for CLI prompts) and **Writing** (cleans up prose)
- Local snippet history — copy, resend, or review past dictations
- Runs entirely on your machine using Apple Silicon GPU

---

## How it works

```
Hold hotkey → record → release → transcribe locally → insert at cursor
```

Transcription runs on-device using [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) with `whisper-large-v3-turbo` on your Apple Silicon GPU. No API keys. No internet required. Audio never leaves your Mac.

---

## Install

### Step 1 — Install the Python transcription engine

```bash
pip install mlx-whisper
```

> First launch downloads the ~800MB `large-v3-turbo` model weights from HuggingFace and caches them locally. Subsequent launches are instant.

### Step 2 — Download and open the app

1. Download **SpeakFlow-0.1.0.dmg** from [Releases](https://github.com/Vismay299/voice-to-text-summarizer/releases/latest)
2. Open the DMG and drag **SpeakFlow** to your Applications folder
3. **Right-click → Open** on first launch (required for unsigned apps — Apple charges $99/year for notarization, we skip that)
4. Click **Open** when macOS asks for confirmation

### Step 3 — Grant permissions

The app will prompt you for:
- **Microphone** — to capture your voice
- **Accessibility** — to insert text into other apps

Both are required. Both stay local.

---

## Usage

| Action | What happens |
|---|---|
| Hold **Right Option** | Recording starts |
| Release **Right Option** | Transcribes and inserts at cursor |
| Click **Terminal** / **Writing** | Switch cleanup mode |
| Click **Open History** | Browse past dictations |

### Modes

**Terminal mode** — minimal cleanup, safe for AI CLI tools and terminal prompts. Preserves your exact words, strips leading filler words only.

**Writing mode** — cleans up prose. Removes filler words (um, uh, like, basically), fixes capitalization, normalizes punctuation.

### Voice commands

Speak these anywhere and they get converted:

| Say | Inserts |
|---|---|
| "new line" | `\n` |
| "slash command" | `/` |
| "open quote" | `"` |
| "code block" | ` ``` ` |

---

## Requirements

- macOS 13 Ventura or later
- Apple Silicon Mac (M1, M2, M3, M4)
- Python 3.10+ with `mlx-whisper` installed

---

## Build from source

```bash
# Clone
git clone https://github.com/Vismay299/voice-to-text-summarizer.git
cd voice-to-text-summarizer

# Install Python dependency
pip install mlx-whisper

# Run directly
npm run dev:macos

# Or build a .dmg
npm run build:dmg
# → dist/SpeakFlow-0.1.0.dmg
```

**Requirements for building:** Swift 6.2+, Xcode Command Line Tools, Node.js 18+

---

## Privacy

- All audio is processed locally on your Mac
- Transcripts are stored in `~/Library/Application Support/SpeakFlow/`
- No telemetry, no analytics, no network requests
- You can delete all data by removing that folder

---

## Supported apps

| App | Works |
|---|---|
| Terminal, iTerm2, Warp, Ghostty, Kitty | Yes |
| Chrome, Firefox, Safari, Edge, Brave | Yes |
| Notion (desktop) | Yes |
| VS Code, JetBrains | Yes |
| TextEdit, Notes, Xcode | Yes |
| Claude.ai, ChatGPT (browser) | Yes |

---

## Contributing

This is an open-source project. Issues and PRs welcome.

The planning docs live in `.planning/ROADMAP.md` — read that before contributing.
