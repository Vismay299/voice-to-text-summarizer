# Experimental Google Meet Boundary

This project includes a lab-only Google Meet boundary for Phase 5. It exists so we can prototype the integration shape, state model, and failure handling without tying the core product to an unsupported bot workflow.

## What It Is

- A feature-flagged boundary exposed at `/experimental/google-meet`
- A companion-side state model that tracks whether the lab boundary is available, enabled, blocked, or merely disabled
- A web UI control that surfaces the boundary separately from the stable meeting-helper workflow
- A way to test how the app reacts when Google Meet-specific support is turned on or off

## What It Is Not

- A real Google Meet bot
- A hidden participant or invite-based Meet assistant
- A replacement for the stable meeting-helper workflow
- A promise that Google Meet media access is supported today

## Flag

Set this environment variable before starting the companion to unlock the lab boundary:

```bash
VOICE_TO_TEXT_EXPERIMENTAL_GOOGLE_MEET=1
```

If the flag is not set, the companion reports the boundary as blocked and the UI should keep the lab control inactive.

## Isolation Rules

- Failures in the experimental path should stay in the experimental panel
- The normal session flow must continue working even if the experimental route is unavailable
- The meeting-helper workflow should continue to fall back to browser guidance when Google Meet is not supported
- Any future Meet-native work should start from this boundary instead of bypassing it
