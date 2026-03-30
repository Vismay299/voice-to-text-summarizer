import fs from "node:fs";
import { createServer } from "node:http";
import path from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";
import type {
  ExperimentalGoogleMeetResponse,
  ExperimentalGoogleMeetState,
  UpdateExperimentalGoogleMeetRequest,
  UpdateExperimentalGoogleMeetResponse,
  MeetingHelperOption,
  MeetingHelperResponse,
  MeetingHelperState,
  MeetingSurface,
  SessionArchiveEntry,
  SessionArchiveListResponse,
  SessionArchiveResponse,
  SessionError,
  RuntimeConfig,
  RuntimeConfigResponse,
  RuntimeOption,
  FinalSummary,
  FinalSummaryState,
  LiveNote,
  LiveNotesPipelineState,
  LiveNotesResponse,
  SessionRecord,
  SessionStartResponse,
  SessionStatusResponse,
  SessionStopResponse,
  TranscriptPipelineState,
  TranscriptResponse,
  TranscriptSegment,
  SummaryResponse,
  StartSessionRequest,
  StopSessionRequest,
  UpdateMeetingHelperRequest,
  UpdateRuntimeConfigRequest,
  UpdateRuntimeConfigResponse
} from "@voice/shared";
import { CAPTURE_MODES, DEFAULT_RUNTIME_CONFIG, MEETING_SURFACES, RUNTIME_OPTIONS, bridgeCapabilities } from "@voice/shared";

const port = Number(process.env.PORT ?? 4545);
const experimentalGoogleMeetFlagName = "VOICE_TO_TEXT_EXPERIMENTAL_GOOGLE_MEET";
const experimentalGoogleMeetAvailable = process.env[experimentalGoogleMeetFlagName] === "1";
const archiveDir = path.join(process.cwd(), ".voice-to-text-summarizer");
const archivePath = path.join(archiveDir, "sessions.json");
let activeSession: SessionRecord | null = null;
let runtimeConfig: RuntimeConfig = { ...DEFAULT_RUNTIME_CONFIG };
let sessionArchive: SessionArchiveEntry[] = loadSessionArchive();
let transcriptState: TranscriptPipelineState = {
  sessionId: null,
  revision: 0,
  updatedAt: null,
  startedAt: null,
  lastSegmentAt: null,
  segmentCount: 0,
  isSimulated: true,
  isActive: false,
  segments: []
};
let liveNotesState: LiveNotesPipelineState = {
  sessionId: null,
  revision: 0,
  updatedAt: null,
  noteCount: 0,
  isSimulated: true,
  isActive: false,
  notes: []
};
let summaryState: FinalSummaryState = {
  sessionId: null,
  revision: 0,
  generatedAt: null,
  isSimulated: true,
  isReady: false,
  summary: null
};
let experimentalGoogleMeetState: ExperimentalGoogleMeetState = {
  available: experimentalGoogleMeetAvailable,
  enabled: false,
  status: experimentalGoogleMeetAvailable ? "disabled" : "blocked",
  featureFlag: experimentalGoogleMeetFlagName,
  updatedAt: null,
  activeSessionId: null,
  notes: experimentalGoogleMeetAvailable
    ? [
        "Google Meet remains isolated from the stable helper flow.",
        "When enabled, the boundary only prototypes routing metadata and guardrails.",
        "Real bot capture and Meet-native media access are intentionally unsupported."
      ]
    : [
        "Set VOICE_TO_TEXT_EXPERIMENTAL_GOOGLE_MEET=1 and restart the companion to unlock the prototype boundary.",
        "The stable meeting-helper workflow still falls back to browser guidance.",
        "Real bot capture and Meet-native media access are intentionally unsupported."
      ]
};

function buildMeetingHelperOptions(): readonly MeetingHelperOption[] {
  return [
  {
    surface: "desktop-meeting",
    label: "Desktop meeting",
    description: "Use when the meeting lives in a desktop app or routed system audio setup.",
    supportStatus: "supported",
    fallbackGuidance: [
      "Route the meeting audio into the local companion through system or loopback audio.",
      "This path shares the same transcript, live notes, and summary pipeline."
    ]
  },
  {
    surface: "browser-meeting",
    label: "Browser meeting",
    description: "Use when the meeting runs in a browser tab or window capture flow.",
    supportStatus: "supported",
    fallbackGuidance: [
      "Keep the meeting in a browser tab or window that the companion can observe.",
      "If tab capture is unavailable, switch to the desktop meeting helper."
    ]
  },
  {
    surface: "google-meet",
    label: "Google Meet",
    description: experimentalGoogleMeetState.enabled
      ? "Experimental Google Meet boundary is available, but capture still routes through the browser helper."
      : "Google Meet bot capture is not available yet, so this path falls back to the browser helper.",
    supportStatus: experimentalGoogleMeetState.enabled ? "experimental" : "fallback",
    fallbackSurface: "browser-meeting",
    fallbackGuidance: [
      experimentalGoogleMeetState.enabled
        ? "This is a lab-only boundary. It does not join Meet as a bot or hidden participant."
        : "Use the browser meeting helper for now.",
      "The current implementation does not join Meet as a bot or hidden participant."
    ]
  }
  ] as const;
}

let meetingHelperState: MeetingHelperState = {
  selectedSurface: "desktop-meeting",
  effectiveSurface: "desktop-meeting",
  supportStatus: "supported",
  updatedAt: null,
  activeSessionId: null,
  fallbackMessage: null,
  options: buildMeetingHelperOptions()
};
let transcriptTimer: ReturnType<typeof setInterval> | null = null;

const transcriptTemplates = [
  "We're aligning on the next step and confirming the main decision.",
  "The user wants a lightweight workflow that works while talking.",
  "We should keep the first pass local and avoid paid API dependencies.",
  "The summary should stay concise and easy to review later.",
  "We can layer richer meeting support after the core flow is stable."
];

const liveNoteTemplates = [
  "Live note: focus on the next step and keep the workflow lightweight.",
  "Live note: stay local-first and avoid paid APIs for the first pass.",
  "Live note: keep the summary concise and easy to review later.",
  "Live note: the current session is still in the simulated pipeline.",
  "Live note: future work can add richer meeting support."
];

function loadSessionArchive(): SessionArchiveEntry[] {
  try {
    if (!fs.existsSync(archivePath)) {
      return [];
    }

    const raw = fs.readFileSync(archivePath, "utf8");
    const parsed = JSON.parse(raw) as unknown;
    return Array.isArray(parsed) ? (parsed as SessionArchiveEntry[]) : [];
  } catch {
    return [];
  }
}

function persistSessionArchive() {
  fs.mkdirSync(archiveDir, { recursive: true });
  fs.writeFileSync(archivePath, JSON.stringify(sessionArchive, null, 2));
}

function writeJson(res: ServerResponse<IncomingMessage>, statusCode: number, body: unknown) {
  res.writeHead(statusCode, {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type",
    "content-type": "application/json"
  });
  res.end(JSON.stringify(body, null, 2));
}

function createSessionId() {
  return `session-${Math.random().toString(36).slice(2, 10)}`;
}

function getRuntimeOption(runtimeId: RuntimeConfig["runtimeId"]): RuntimeOption | undefined {
  return RUNTIME_OPTIONS.find((runtime) => runtime.id === runtimeId);
}

function resolveMeetingSurface(surface?: MeetingSurface) {
  const requestedSurface = surface ?? meetingHelperState.selectedSurface;
  const meetingHelperOptions = buildMeetingHelperOptions();
  const option = meetingHelperOptions.find((entry) => entry.surface === requestedSurface) ?? meetingHelperOptions[0];

  return {
    requestedSurface,
    effectiveSurface: option.fallbackSurface ?? requestedSurface,
    supportStatus: option.supportStatus,
    fallbackMessage:
      option.supportStatus === "experimental"
        ? "Google Meet is in an experimental lab boundary. It still routes through the browser helper and does not join Meet as a bot."
        : option.supportStatus === "fallback"
          ? "Google Meet is not supported as a bot workflow yet. Falling back to the browser meeting helper."
          : null
  };
}

function isValidMeetingHelperRequest(body: Partial<UpdateMeetingHelperRequest>): body is UpdateMeetingHelperRequest {
  return (
    typeof body.surface === "string" &&
    MEETING_SURFACES.includes(body.surface as (typeof MEETING_SURFACES)[number])
  );
}

function createTranscriptSegment(index: number, sessionId: string): TranscriptSegment {
  const template = transcriptTemplates[index % transcriptTemplates.length];
  const startMs = index * 4500;
  const endMs = startMs + 3200;

  return {
    id: `segment-${sessionId}-${index + 1}`,
    sessionId,
    text: `${template} [simulated transcript chunk ${index + 1}]`,
    startMs,
    endMs,
    speakerLabel: index % 2 === 0 ? "Speaker 1" : "Speaker 2",
    confidence: 0.84
  };
}

function createLiveNote(segment: TranscriptSegment, index: number): LiveNote {
  const template = liveNoteTemplates[index % liveNoteTemplates.length];
  return {
    id: `note-${segment.sessionId}-${index + 1}`,
    sessionId: segment.sessionId,
    text: `${template} Source chunk: ${segment.text}`,
    createdAt: new Date().toISOString(),
    derivedFromSegmentIds: [segment.id]
  };
}

function buildFinalSummary(session: SessionRecord, segments: readonly TranscriptSegment[], notes: readonly LiveNote[]): FinalSummary {
  const keyPoints = notes.length > 0
    ? notes.slice(0, 4).map((note) => note.text.replace(/^Live note:\s*/i, ""))
    : segments.slice(0, 3).map((segment) => segment.text);

  return {
    sessionId: session.id,
    overview: `Simulated summary for a ${session.sourceType} session with ${segments.length} transcript chunks and ${notes.length} live notes.`,
    keyPoints,
    followUps: [
      "Review the simulated summary structure against real transcript output.",
      "Replace the simulated note and summary generators with model-backed logic."
    ],
    generatedAt: new Date().toISOString(),
    modelInfo: `simulated-summary-${session.runtimeId}`
  };
}

function stopTranscriptTimer() {
  if (transcriptTimer) {
    clearInterval(transcriptTimer);
    transcriptTimer = null;
  }
}

function resetTranscriptState() {
  stopTranscriptTimer();
  transcriptState = {
    sessionId: null,
    revision: 0,
    updatedAt: null,
    startedAt: null,
    lastSegmentAt: null,
    segmentCount: 0,
    isSimulated: true,
    isActive: false,
    segments: []
  };
}

function resetLiveNotesState() {
  liveNotesState = {
    sessionId: null,
    revision: 0,
    updatedAt: null,
    noteCount: 0,
    isSimulated: true,
    isActive: false,
    notes: []
  };
}

function resetSummaryState() {
  summaryState = {
    sessionId: null,
    revision: 0,
    generatedAt: null,
    isSimulated: true,
    isReady: false,
    summary: null
  };
}

function updateMeetingHelperState(surface: MeetingSurface, activeSessionId: string | null = meetingHelperState.activeSessionId) {
  const resolved = resolveMeetingSurface(surface);
  meetingHelperState = {
    selectedSurface: resolved.requestedSurface,
    effectiveSurface: resolved.effectiveSurface,
    supportStatus: resolved.supportStatus,
    updatedAt: new Date().toISOString(),
    activeSessionId,
    fallbackMessage: resolved.fallbackMessage,
    options: buildMeetingHelperOptions()
  };
}

function updateExperimentalGoogleMeetState(enabled: boolean, activeSessionId: string | null = experimentalGoogleMeetState.activeSessionId) {
  if (!experimentalGoogleMeetAvailable) {
    experimentalGoogleMeetState = {
      ...experimentalGoogleMeetState,
      enabled: false,
      status: "blocked",
      activeSessionId,
      updatedAt: new Date().toISOString()
    };
    return;
  }

  experimentalGoogleMeetState = {
    ...experimentalGoogleMeetState,
    enabled,
    status: enabled ? "prototype" : "disabled",
    activeSessionId,
    updatedAt: new Date().toISOString()
  };

  if (meetingHelperState.selectedSurface === "google-meet") {
    updateMeetingHelperState("google-meet", activeSessionId);
    return;
  }

  meetingHelperState = {
    ...meetingHelperState,
    options: buildMeetingHelperOptions()
  };
}

function getMeetingHelperPayload(): MeetingHelperResponse {
  if (activeSession?.sourceType === "meeting-helper" && activeSession.meetingRequestedSurface && activeSession.meetingSurface) {
    return {
      meetingHelper: {
        selectedSurface: activeSession.meetingRequestedSurface,
        effectiveSurface: activeSession.meetingSurface,
        supportStatus: activeSession.meetingSupportStatus ?? "supported",
        updatedAt: activeSession.endedAt ?? activeSession.startedAt,
        activeSessionId: activeSession.id,
        fallbackMessage: activeSession.meetingFallbackMessage ?? null,
        options: buildMeetingHelperOptions()
      }
    };
  }

  return { meetingHelper: meetingHelperState };
}

function getExperimentalGoogleMeetPayload(): ExperimentalGoogleMeetResponse {
  return { experimentalGoogleMeet: experimentalGoogleMeetState };
}

function isValidExperimentalGoogleMeetRequest(body: Partial<UpdateExperimentalGoogleMeetRequest>): body is UpdateExperimentalGoogleMeetRequest {
  return typeof body.enabled === "boolean";
}

function appendLiveNote(segment: TranscriptSegment) {
  const note = createLiveNote(segment, liveNotesState.noteCount);
  liveNotesState = {
    ...liveNotesState,
    revision: liveNotesState.revision + 1,
    updatedAt: note.createdAt,
    noteCount: liveNotesState.noteCount + 1,
    isActive: true,
    sessionId: segment.sessionId,
    notes: [...liveNotesState.notes, note]
  };
}

function startLiveNotesPipeline(session: SessionRecord) {
  liveNotesState = {
    sessionId: session.id,
    revision: 1,
    updatedAt: new Date(session.startedAt).toISOString(),
    noteCount: 0,
    isSimulated: true,
    isActive: true,
    notes: []
  };
}

function finalizeLiveNotesPipeline(session: SessionRecord) {
  liveNotesState = {
    ...liveNotesState,
    revision: liveNotesState.revision + 1,
    updatedAt: new Date().toISOString(),
    isActive: false,
    sessionId: session.id
  };
}

function persistCompletedSession(session: SessionRecord) {
  const storedAt = new Date().toISOString();
  const archivedTranscript: TranscriptPipelineState = session.saveTranscript
    ? transcriptState
    : {
        ...transcriptState,
        segmentCount: 0,
        segments: []
      };
  const archivedSummary: FinalSummaryState = session.saveSummary
    ? summaryState
    : {
        ...summaryState,
        isReady: false,
        summary: null
      };

  sessionArchive = [
    {
      session,
      transcript: archivedTranscript,
      notes: liveNotesState,
      summary: archivedSummary,
      storedAt
    },
    ...sessionArchive.filter((entry) => entry.session.id !== session.id)
  ];
  persistSessionArchive();
}

function startTranscriptPipeline(session: SessionRecord) {
  stopTranscriptTimer();
  const startedAt = new Date(session.startedAt).toISOString();
  transcriptState = {
    sessionId: session.id,
    revision: 1,
    updatedAt: startedAt,
    startedAt,
    lastSegmentAt: startedAt,
    segmentCount: 0,
    isSimulated: true,
    isActive: true,
    segments: []
  };

  let nextSegmentIndex = 0;
  transcriptTimer = setInterval(() => {
    if (!activeSession || activeSession.id !== session.id || activeSession.status !== "recording") {
      stopTranscriptTimer();
      transcriptState = {
        ...transcriptState,
        revision: transcriptState.revision + 1,
        updatedAt: new Date().toISOString(),
        lastSegmentAt: transcriptState.lastSegmentAt,
        isActive: false
      };
      return;
    }

    const segment = createTranscriptSegment(nextSegmentIndex, session.id);
    nextSegmentIndex += 1;
    const segmentTimestamp = new Date().toISOString();
    transcriptState = {
      ...transcriptState,
      revision: transcriptState.revision + 1,
      updatedAt: segmentTimestamp,
      lastSegmentAt: segmentTimestamp,
      segmentCount: transcriptState.segmentCount + 1,
      segments: [...transcriptState.segments, segment]
    };
    appendLiveNote(segment);
  }, 2500);
}

function getTranscriptPayload(sinceSegmentCount?: number): TranscriptResponse {
  if (!sinceSegmentCount || sinceSegmentCount < 1) {
    return { transcript: transcriptState };
  }

  const segmentStartIndex = Math.max(0, sinceSegmentCount);
  return {
    transcript: {
      ...transcriptState,
      segments: transcriptState.segments.slice(segmentStartIndex)
    }
  };
}

function isValidStartRequest(body: Partial<StartSessionRequest>): body is StartSessionRequest {
  const meetingSurfaceIsValid =
    body.meetingSurface === undefined ||
    (typeof body.meetingSurface === "string" &&
      MEETING_SURFACES.includes(body.meetingSurface as (typeof MEETING_SURFACES)[number]));

  return (
    typeof body.sourceType === "string" &&
    CAPTURE_MODES.includes(body.sourceType as (typeof CAPTURE_MODES)[number]) &&
    typeof body.runtimeId === "string" &&
    Boolean(getRuntimeOption(body.runtimeId as RuntimeConfig["runtimeId"])) &&
    body.language === "en" &&
    typeof body.saveTranscript === "boolean" &&
    typeof body.saveSummary === "boolean" &&
    meetingSurfaceIsValid
  );
}

function isValidRuntimeUpdate(body: Partial<UpdateRuntimeConfigRequest>): body is UpdateRuntimeConfigRequest {
  return (
    typeof body.runtimeId === "string" &&
    Boolean(getRuntimeOption(body.runtimeId as RuntimeConfig["runtimeId"])) &&
    (body.language === undefined || body.language === "en") &&
    (body.saveTranscript === undefined || typeof body.saveTranscript === "boolean") &&
    (body.saveSummary === undefined || typeof body.saveSummary === "boolean")
  );
}

async function readJsonBody<T>(req: IncomingMessage): Promise<T> {
  const chunks: Buffer[] = [];

  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }

  if (chunks.length === 0) {
    return {} as T;
  }

  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as T;
}

const server = createServer((req, res) => {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);

  if (req.method === "OPTIONS") {
    writeJson(res, 204, {});
    return;
  }

  if (url.pathname === "/health") {
    writeJson(res, 200, { ok: true, service: "companion", port });
    return;
  }

  if (url.pathname === "/bridge-contract") {
    writeJson(res, 200, bridgeCapabilities);
    return;
  }

  if (url.pathname === "/meeting-helper" && req.method === "GET") {
    const payload = getMeetingHelperPayload();
    writeJson(res, 200, payload);
    return;
  }

  if (url.pathname === "/meeting-helper" && req.method === "POST") {
    void readJsonBody<UpdateMeetingHelperRequest>(req)
      .then((body) => {
        if (!isValidMeetingHelperRequest(body)) {
          const payload: SessionError = { message: "Meeting helper payload is missing a valid meeting surface." };
          writeJson(res, 400, payload);
          return;
        }

        updateMeetingHelperState(body.surface, activeSession?.sourceType === "meeting-helper" ? activeSession.id : null);
        const payload: MeetingHelperResponse = { meetingHelper: meetingHelperState };
        writeJson(res, 200, payload);
      })
      .catch(() => {
        const payload: SessionError = { message: "Invalid meeting helper payload." };
        writeJson(res, 400, payload);
      });
    return;
  }

  if (url.pathname === "/experimental/google-meet" && req.method === "GET") {
    const payload = getExperimentalGoogleMeetPayload();
    writeJson(res, 200, payload);
    return;
  }

  if (url.pathname === "/experimental/google-meet" && req.method === "POST") {
    void readJsonBody<UpdateExperimentalGoogleMeetRequest>(req)
      .then((body) => {
        if (!experimentalGoogleMeetAvailable) {
          const payload: SessionError = {
            message: `Experimental Google Meet is disabled. Set ${experimentalGoogleMeetFlagName}=1 and restart the companion to unlock the prototype boundary.`
          };
          writeJson(res, 403, payload);
          return;
        }

        if (!isValidExperimentalGoogleMeetRequest(body)) {
          const payload: SessionError = { message: "Experimental Google Meet payload is missing required fields." };
          writeJson(res, 400, payload);
          return;
        }

        updateExperimentalGoogleMeetState(
          body.enabled,
          activeSession?.meetingRequestedSurface === "google-meet" ? activeSession.id : null
        );
        const payload: UpdateExperimentalGoogleMeetResponse = {
          experimentalGoogleMeet: experimentalGoogleMeetState
        };
        writeJson(res, 200, payload);
      })
      .catch(() => {
        const payload: SessionError = { message: "Invalid experimental Google Meet payload." };
        writeJson(res, 400, payload);
      });
    return;
  }

  if (url.pathname === "/transcript" && req.method === "GET") {
    const sinceSegmentCountParam = url.searchParams.get("sinceSegmentCount");
    const sinceSegmentCount = sinceSegmentCountParam ? Number(sinceSegmentCountParam) : undefined;
    writeJson(res, 200, getTranscriptPayload(Number.isFinite(sinceSegmentCount) ? sinceSegmentCount : undefined));
    return;
  }

  if (url.pathname === "/notes" && req.method === "GET") {
    const payload: LiveNotesResponse = { notes: liveNotesState };
    writeJson(res, 200, payload);
    return;
  }

  if (url.pathname === "/summary" && req.method === "GET") {
    const payload: SummaryResponse = { summary: summaryState };
    writeJson(res, 200, payload);
    return;
  }

  if (url.pathname === "/sessions" && req.method === "GET") {
    const payload: SessionArchiveListResponse = { sessions: sessionArchive };
    writeJson(res, 200, payload);
    return;
  }

  const sessionMatch = /^\/sessions\/([^/]+)$/.exec(url.pathname);
  if (sessionMatch && req.method === "GET") {
    const sessionId = decodeURIComponent(sessionMatch[1]);
    const payload: SessionArchiveResponse = {
      session: sessionArchive.find((entry) => entry.session.id === sessionId) ?? null
    };
    writeJson(res, 200, payload);
    return;
  }

  if (url.pathname === "/config" && req.method === "GET") {
    const payload: RuntimeConfigResponse = {
      config: {
        options: RUNTIME_OPTIONS,
        defaults: DEFAULT_RUNTIME_CONFIG,
        current: runtimeConfig
      }
    };
    writeJson(res, 200, payload);
    return;
  }

  if (url.pathname === "/config" && req.method === "POST") {
    void readJsonBody<UpdateRuntimeConfigRequest>(req)
      .then((body) => {
        if (!isValidRuntimeUpdate(body)) {
          const payload: SessionError = { message: "Runtime config payload is missing required fields." };
          writeJson(res, 400, payload);
          return;
        }

        runtimeConfig = {
          runtimeId: body.runtimeId,
          language: body.language ?? runtimeConfig.language,
          saveTranscript: body.saveTranscript ?? runtimeConfig.saveTranscript,
          saveSummary: body.saveSummary ?? runtimeConfig.saveSummary
        };

        const payload: UpdateRuntimeConfigResponse = {
          config: {
            options: RUNTIME_OPTIONS,
            defaults: DEFAULT_RUNTIME_CONFIG,
            current: runtimeConfig
          }
        };
        writeJson(res, 200, payload);
      })
      .catch(() => {
        const payload: SessionError = { message: "Invalid runtime config payload." };
        writeJson(res, 400, payload);
      });
    return;
  }

  if (url.pathname === "/session" && req.method === "GET") {
    const payload: SessionStatusResponse = { session: activeSession };
    writeJson(res, 200, payload);
    return;
  }

  if (url.pathname === "/session/start" && req.method === "POST") {
    void readJsonBody<StartSessionRequest>(req)
      .then((body) => {
        if (activeSession?.status === "recording") {
          const payload: SessionError = { message: "A session is already active." };
          writeJson(res, 409, payload);
          return;
        }

        if (!isValidStartRequest(body)) {
          const payload: SessionError = { message: "Session payload is missing required fields." };
          writeJson(res, 400, payload);
          return;
        }

        const meetingSurface = body.sourceType === "meeting-helper" ? resolveMeetingSurface(body.meetingSurface) : null;

        const now = new Date().toISOString();
        activeSession = {
          id: createSessionId(),
          sourceType: body.sourceType,
          runtimeId: body.runtimeId,
          status: "recording",
          startedAt: now,
          language: body.language,
          saveTranscript: body.saveTranscript,
          saveSummary: body.saveSummary,
          meetingRequestedSurface: meetingSurface?.requestedSurface,
          meetingSurface: meetingSurface?.effectiveSurface,
          meetingSupportStatus: meetingSurface?.supportStatus,
          meetingFallbackMessage: meetingSurface?.fallbackMessage
        };

        if (meetingSurface) {
          updateMeetingHelperState(meetingSurface.requestedSurface, activeSession.id);
          if (meetingSurface.requestedSurface === "google-meet") {
            updateExperimentalGoogleMeetState(experimentalGoogleMeetState.enabled, experimentalGoogleMeetState.enabled ? activeSession.id : null);
          } else {
            updateExperimentalGoogleMeetState(experimentalGoogleMeetState.enabled, null);
          }
        } else {
          meetingHelperState = {
            ...meetingHelperState,
            activeSessionId: null,
            updatedAt: now
          };
          updateExperimentalGoogleMeetState(experimentalGoogleMeetState.enabled, null);
        }

        resetTranscriptState();
        resetLiveNotesState();
        resetSummaryState();
        startLiveNotesPipeline(activeSession);
        startTranscriptPipeline(activeSession);

        const payload: SessionStartResponse = { session: activeSession };
        writeJson(res, 201, payload);
      })
      .catch(() => {
        const payload: SessionError = { message: "Invalid session payload." };
        writeJson(res, 400, payload);
      });
    return;
  }

  if (url.pathname === "/session/stop" && req.method === "POST") {
    void readJsonBody<StopSessionRequest>(req)
      .then((body) => {
        if (!activeSession || activeSession.status !== "recording") {
          const payload: SessionError = { message: "No active session to stop." };
          writeJson(res, 409, payload);
          return;
        }

        if (body.sessionId !== activeSession.id) {
          const payload: SessionError = { message: "Session ID does not match the active session." };
          writeJson(res, 400, payload);
          return;
        }

        const endedAt = new Date().toISOString();
        activeSession = {
          ...activeSession,
          status: "complete",
          endedAt
        };

        meetingHelperState = {
          ...meetingHelperState,
          activeSessionId: null,
          updatedAt: endedAt
        };
        updateExperimentalGoogleMeetState(experimentalGoogleMeetState.enabled, null);

        stopTranscriptTimer();
        transcriptState = {
          ...transcriptState,
          revision: transcriptState.revision + 1,
          isActive: false,
          updatedAt: endedAt
        };
        finalizeLiveNotesPipeline(activeSession);
        summaryState = {
          sessionId: activeSession.id,
          revision: summaryState.revision + 1,
          generatedAt: endedAt,
          isSimulated: true,
          isReady: true,
          summary: buildFinalSummary(activeSession, transcriptState.segments, liveNotesState.notes)
        };
        persistCompletedSession(activeSession);

        const payload: SessionStopResponse = { session: activeSession };
        writeJson(res, 200, payload);
      })
      .catch(() => {
        const payload: SessionError = { message: "Invalid session payload." };
        writeJson(res, 400, payload);
      });
    return;
  }

    writeJson(res, 200, {
      service: "voice-to-text-summarizer-companion",
      message: "Companion shell is running.",
      routes: ["/health", "/bridge-contract", "/config", "/experimental/google-meet", "/meeting-helper", "/session", "/session/start", "/session/stop", "/transcript", "/notes", "/summary", "/sessions"]
    });
});

server.listen(port, () => {
  console.log(`Companion server ready at http://localhost:${port}`);
  console.log("Bridge contract endpoints: /health, /bridge-contract, /config, /experimental/google-meet, /meeting-helper, /session, /transcript, /notes, /summary, /sessions");
});
