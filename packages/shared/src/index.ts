export const CAPTURE_MODES = ["speakerphone", "system-audio", "meeting-helper"] as const;
export const MEETING_SURFACES = ["desktop-meeting", "browser-meeting", "google-meet"] as const;
export const MEETING_SUPPORT_STATUSES = ["supported", "fallback", "experimental", "unsupported"] as const;
export const RUNTIME_IDS = ["whisper-cpp", "faster-whisper", "ollama"] as const;
export const DEFAULT_LANGUAGE = "en" as const;
export const SESSION_STATUSES = ["idle", "recording", "paused", "complete", "error"] as const;
export const BRIDGE_COMMANDS = [
  "startSession",
  "stopSession",
  "getTranscript",
  "appendTranscriptSegments",
  "getLiveNotes",
  "getMeetingHelper",
  "setMeetingHelper",
  "getExperimentalGoogleMeet",
  "setExperimentalGoogleMeet",
  "subscribeTranscript",
  "subscribeLiveNotes",
  "getSummary",
  "listSessions"
] as const;

export type CaptureMode = (typeof CAPTURE_MODES)[number];
export type MeetingSurface = (typeof MEETING_SURFACES)[number];
export type MeetingSupportStatus = (typeof MEETING_SUPPORT_STATUSES)[number];
export type RuntimeId = (typeof RUNTIME_IDS)[number];
export type SessionStatus = (typeof SESSION_STATUSES)[number];
export type BridgeCommand = (typeof BRIDGE_COMMANDS)[number];

export interface BridgeCapabilities {
  transport: "http+json";
  commands: readonly BridgeCommand[];
  captureModes: readonly CaptureMode[];
  runtimes: readonly RuntimeOption[];
  defaults: RuntimeConfig;
}

export interface RuntimeOption {
  id: RuntimeId;
  name: string;
  description: string;
  strengths: readonly string[];
}

export interface RuntimeConfig {
  runtimeId: RuntimeId;
  language: typeof DEFAULT_LANGUAGE;
  saveTranscript: boolean;
  saveSummary: boolean;
}

export interface RuntimeConfigState {
  options: readonly RuntimeOption[];
  defaults: RuntimeConfig;
  current: RuntimeConfig;
}

export interface StartSessionRequest {
  sourceType: CaptureMode;
  runtimeId: RuntimeId;
  language: typeof DEFAULT_LANGUAGE;
  saveTranscript: boolean;
  saveSummary: boolean;
  meetingSurface?: MeetingSurface;
}

export interface StopSessionRequest {
  sessionId: string;
}

export interface SessionError {
  message: string;
}

export interface TranscriptSegment {
  id: string;
  sessionId: string;
  text: string;
  startMs: number;
  endMs: number;
  speakerLabel?: string;
  confidence?: number;
}

export interface TranscriptIngestSegment {
  text: string;
  startMs?: number;
  endMs?: number;
  speakerLabel?: string;
  confidence?: number;
}

export interface TranscriptIngestRequest {
  sessionId: string;
  segments: readonly TranscriptIngestSegment[];
}

export interface TranscriptIngestResponse {
  transcript: TranscriptPipelineState;
  notes: LiveNotesPipelineState;
  summary: FinalSummaryState;
}

export interface LiveNote {
  id: string;
  sessionId: string;
  text: string;
  createdAt: string;
  derivedFromSegmentIds: string[];
}

export interface FinalSummary {
  sessionId: string;
  overview: string;
  keyPoints: string[];
  followUps: string[];
  generatedAt: string;
  modelInfo: string;
}

export interface SessionRecord {
  id: string;
  sourceType: CaptureMode;
  runtimeId: RuntimeId;
  status: SessionStatus;
  startedAt: string;
  endedAt?: string;
  language: typeof DEFAULT_LANGUAGE;
  saveTranscript: boolean;
  saveSummary: boolean;
  meetingRequestedSurface?: MeetingSurface;
  meetingSurface?: MeetingSurface;
  meetingSupportStatus?: MeetingSupportStatus;
  meetingFallbackMessage?: string | null;
}

export interface SessionStartResponse {
  session: SessionRecord;
}

export interface SessionStopResponse {
  session: SessionRecord;
}

export interface SessionStatusResponse {
  session: SessionRecord | null;
}

export interface RuntimeConfigResponse {
  config: RuntimeConfigState;
}

export interface MeetingHelperOption {
  surface: MeetingSurface;
  label: string;
  description: string;
  supportStatus: MeetingSupportStatus;
  fallbackSurface?: MeetingSurface;
  fallbackGuidance: readonly string[];
}

export interface MeetingHelperState {
  selectedSurface: MeetingSurface;
  effectiveSurface: MeetingSurface;
  supportStatus: MeetingSupportStatus;
  updatedAt: string | null;
  activeSessionId: string | null;
  fallbackMessage: string | null;
  options: readonly MeetingHelperOption[];
}

export interface MeetingHelperResponse {
  meetingHelper: MeetingHelperState;
}

export interface UpdateMeetingHelperRequest {
  surface: MeetingSurface;
}

export interface UpdateMeetingHelperResponse {
  meetingHelper: MeetingHelperState;
}

export interface ExperimentalGoogleMeetState {
  available: boolean;
  enabled: boolean;
  status: "disabled" | "prototype" | "blocked";
  featureFlag: string;
  updatedAt: string | null;
  activeSessionId: string | null;
  notes: readonly string[];
}

export interface ExperimentalGoogleMeetResponse {
  experimentalGoogleMeet: ExperimentalGoogleMeetState;
}

export interface UpdateExperimentalGoogleMeetRequest {
  enabled: boolean;
}

export interface UpdateExperimentalGoogleMeetResponse {
  experimentalGoogleMeet: ExperimentalGoogleMeetState;
}

export interface UpdateRuntimeConfigRequest {
  runtimeId: RuntimeId;
  language?: typeof DEFAULT_LANGUAGE;
  saveTranscript?: boolean;
  saveSummary?: boolean;
}

export interface UpdateRuntimeConfigResponse {
  config: RuntimeConfigState;
}

export interface TranscriptPipelineState {
  sessionId: string | null;
  revision: number;
  updatedAt: string | null;
  startedAt: string | null;
  lastSegmentAt: string | null;
  segmentCount: number;
  isSimulated: boolean;
  isActive: boolean;
  segments: readonly TranscriptSegment[];
}

export interface TranscriptResponse {
  transcript: TranscriptPipelineState;
}

export interface TranscriptQuery {
  sinceSegmentCount?: number;
}

export interface LiveNotesPipelineState {
  sessionId: string | null;
  revision: number;
  updatedAt: string | null;
  noteCount: number;
  isSimulated: boolean;
  isActive: boolean;
  notes: readonly LiveNote[];
}

export interface LiveNotesResponse {
  notes: LiveNotesPipelineState;
}

export interface FinalSummaryState {
  sessionId: string | null;
  revision: number;
  generatedAt: string | null;
  isSimulated: boolean;
  isReady: boolean;
  summary: FinalSummary | null;
}

export interface SummaryResponse {
  summary: FinalSummaryState;
}

export interface SessionArchiveEntry {
  session: SessionRecord;
  transcript: TranscriptPipelineState;
  notes: LiveNotesPipelineState;
  summary: FinalSummaryState;
  storedAt: string;
}

export interface SessionArchiveListResponse {
  sessions: readonly SessionArchiveEntry[];
}

export interface SessionArchiveResponse {
  session: SessionArchiveEntry | null;
}

export const RUNTIME_OPTIONS: readonly RuntimeOption[] = [
  {
    id: "whisper-cpp",
    name: "whisper.cpp",
    description: "Fast local speech-to-text for CPU-first machines.",
    strengths: ["offline", "broad device support", "simple deployment"]
  },
  {
    id: "faster-whisper",
    name: "faster-whisper",
    description: "Better throughput when the machine has more headroom.",
    strengths: ["higher throughput", "GPU-friendly", "good long-session latency"]
  },
  {
    id: "ollama",
    name: "Ollama",
    description: "Useful for local summarization and model experimentation.",
    strengths: ["easy model switching", "local LLM workflows", "good developer ergonomics"]
  }
] as const;

export const DEFAULT_RUNTIME_CONFIG: RuntimeConfig = {
  runtimeId: "whisper-cpp",
  language: DEFAULT_LANGUAGE,
  saveTranscript: true,
  saveSummary: true
};

export const bridgeCapabilities: BridgeCapabilities = {
  transport: "http+json",
  commands: BRIDGE_COMMANDS,
  captureModes: CAPTURE_MODES,
  runtimes: RUNTIME_OPTIONS,
  defaults: DEFAULT_RUNTIME_CONFIG
};
