# Roadmap: Voice-to-Text Summarizer

## Overview

This roadmap takes the project from a greenfield workspace to a usable local-first call and meeting summarizer. The first milestone is a dependable web app plus desktop companion for live transcription, live notes, final summaries, and saved history, followed by a meeting-helper workflow and a separate experimental Google Meet track.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Foundation Runtime** - Establish the app architecture, local bridge, and session bootstrap flow
- [x] **Phase 2: Live Transcription Experience** - Deliver real-time transcript streaming and session UX
- [x] **Phase 3: Summaries And History** - Add live notes, final summaries, and persisted session review
- [x] **Phase 4: Meeting Helper Workflow** - Support browser and desktop meeting capture through a stable helper flow
- [x] **Phase 5: Experimental Google Meet Track** - Isolate and prototype a Meet-specific assistant path without destabilizing the core app

## Phase Details

### Phase 1: Foundation Runtime
**Goal**: Create the baseline architecture for a web UI and desktop companion that can start and stop sessions with configurable local runtime settings.
**Depends on**: Nothing (first phase)
**Requirements**: [SESS-01, SESS-02, AUD-01, AUD-03, CONF-01, CONF-03]
**Success Criteria** (what must be TRUE):
  1. User can launch the product, configure a session, and start or stop capture from the web UI
  2. Desktop companion and web app can communicate through a stable local bridge
  3. Local runtime and language settings exist for the first English-first workflow
**Plans**: 3 plans

Plans:
- [x] 01-01: Bootstrap repository structure, app shells, and local bridge contract
- [x] 01-02: Implement session lifecycle controls and capture-mode configuration
- [x] 01-03: Wire local runtime selection and English-first defaults into the product shell

### Phase 2: Live Transcription Experience
**Goal**: Deliver streaming transcript updates and a usable live session screen for long-running sessions.
**Depends on**: Phase 1
**Requirements**: [SESS-03, TRNS-01, TRNS-02, TRNS-03]
**Success Criteria** (what must be TRUE):
  1. User sees transcript segments appear incrementally during an active session
  2. Transcript segments are timestamped and preserved without continuity loss during long sessions
  3. Live session screen clearly communicates session state, timing, and incoming transcript data
**Plans**: 3 plans

Plans:
- [x] 02-01: Integrate local transcription pipeline with chunked streaming updates
- [x] 02-02: Build the live session transcript experience in the web app
- [x] 02-03: Harden long-session handling, buffering, and timestamp persistence

### Phase 3: Summaries And History
**Goal**: Turn transcripts into useful live notes and final summaries, then make completed sessions reviewable later.
**Depends on**: Phase 2
**Requirements**: [SUM-01, SUM-02, SUM-03, SUM-04, HIST-01, HIST-02, HIST-03, CONF-02]
**Success Criteria** (what must be TRUE):
  1. User receives live notes during a session and a final concise summary after ending it
  2. Completed sessions are saved by default with transcript and summary artifacts
  3. User can revisit prior sessions and review saved transcript and summary content
**Plans**: 3 plans

Plans:
- [x] 03-01: Add live note generation and final summary orchestration
- [x] 03-02: Implement persistence for session transcripts, summaries, and metadata
- [x] 03-03: Build history and session detail views with save-behavior controls

### Phase 4: Meeting Helper Workflow
**Goal**: Support a stable meeting-oriented workflow that captures desktop or browser meeting context without relying on a true Meet bot.
**Depends on**: Phase 3
**Requirements**: [AUD-02, MEET-01, MEET-03]
**Success Criteria** (what must be TRUE):
  1. User can run the product during a desktop or browser meeting through a supported helper workflow
  2. Product communicates clearly when a meeting-specific path is unsupported and offers a fallback
  3. Meeting-helper capture integrates with the same transcript, notes, and summary pipeline as normal sessions
**Plans**: 2 plans

Plans:
- [x] 04-01: Add meeting-helper input handling for desktop and browser meeting scenarios
- [x] 04-02: Add compatibility messaging, fallback guidance, and validation for supported meeting flows

### Phase 5: Experimental Google Meet Track
**Goal**: Prototype and isolate a Meet-specific assistant path without making the core product depend on it.
**Depends on**: Phase 4
**Requirements**: [MEET-02]
**Success Criteria** (what must be TRUE):
  1. Any Google Meet-specific workflow is clearly labeled experimental
  2. Failures or platform limits in the experimental path do not affect the stable product flow
  3. The project has a concrete prototype boundary for future Meet-specific iteration
**Plans**: 2 plans

Plans:
- [x] 05-01: Define and prototype the Meet-specific integration boundary behind a feature flag
- [x] 05-02: Add isolation, failure handling, and developer documentation for the experimental track

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation Runtime | 3/3 | Complete | 2026-03-30 |
| 2. Live Transcription Experience | 3/3 | Complete | 2026-03-30 |
| 3. Summaries And History | 3/3 | Complete | 2026-03-30 |
| 4. Meeting Helper Workflow | 2/2 | Complete | 2026-03-30 |
| 5. Experimental Google Meet Track | 2/2 | Complete | 2026-03-30 |
