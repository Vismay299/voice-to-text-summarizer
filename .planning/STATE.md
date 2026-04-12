# Project State

## Resume Here

Repository: `voice-to-text-summarizer`
Current branch: `main`
HEAD: `3205b93` `Merge branch 'feature/series-13-worker-fix-no-live-cli'`

When resuming, start with:
1. Read `.planning/ROADMAP.md`
2. Confirm branch is still `main`
3. Treat the current shipped baseline as:
   - worker race fix included
   - final-only insertion on hotkey release
   - experimental live CLI insertion not merged

## Current Product Baseline

The repo is now centered on the local macOS dictation app, not the old meeting-summary direction.

Stable behavior on `main`:
- push-to-talk capture
- persistent Python transcription worker
- worker concurrency/race fix retained
- final transcript insertion on release
- no live CLI insertion during recording
- local snippet/history persistence

Known good checks on `main`:
- `npm run build:macos`
- `npm run test:macos`

Current git state when this note was written:
- `main` is ahead of `origin/main` by 6 commits
- untracked local folder exists: `.qwen/`

## Important Branches

- `main`
  Stable merge target. Use this as the baseline for packaging and release work.

- `feature/series-13-worker-fix-no-live-cli`
  Stable Series 13 cleanup branch that was merged into `main`.

- `feature/series-13-live-cli-insertion`
  Experimental branch. Do not merge as-is. It explored live CLI insertion and was intentionally left out of the stable merge target.

- `fix/cgEvent-sleep-wake-tap`
  Older branch used during debugging. Not the preferred baseline for release work.

## Next Recommended Task

Package the macOS app for distribution and prepare a GitHub `v1` release.

Current packaging status:
- no `.app` bundling pipeline
- no `.dmg` creation script
- no GitHub release workflow
- no signing/notarization setup

Recommended next steps:
1. Create a release branch from `main`
2. Add packaging scripts to produce a distributable `.app`
3. Add a script to create a `.dmg`
4. Decide between:
   - quick unsigned tester release
   - proper signed/notarized public release
5. Document the release process
6. Optionally add GitHub Actions for tagged releases

## Explicit Non-Goals For Next Session

- Do not continue the experimental live CLI insertion branch unless explicitly requested.
- Do not use `fix/cgEvent-sleep-wake-tap` as the release baseline.
- Do not assume Google Docs/browser-rich-editor insertion is reliable.

## Notes

- The user tested the experimental live CLI insertion and found it too inconsistent and too slow.
- The user preferred the branch with the worker fix and final-only insertion.
- The next conversation should pick up from packaging/release work, not transcription experimentation.
