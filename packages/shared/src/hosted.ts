import type { MeetingSurface } from "./index.js";

export const HOSTED_SERVICE_NAMES = ["web", "api", "asr-worker", "summary-worker"] as const;
export const HOSTED_SESSION_SOURCES = ["microphone", "system-audio", "meeting-helper"] as const;
export const HOSTED_SESSION_CAPTURE_STRATEGIES = ["microphone", "display-media-audio"] as const;
export const HOSTED_SESSION_STATUSES = ["starting", "recording", "processing", "complete", "failed"] as const;
export const HOSTED_AUDIO_CHUNK_STATUSES = ["registered", "queued", "processing", "complete", "failed"] as const;
export const HOSTED_MODEL_RUN_KINDS = ["asr", "summary"] as const;
export const HOSTED_MODEL_RUN_STATUSES = ["queued", "running", "complete", "failed"] as const;
export const HOSTED_SESSION_EVENT_TYPES = [
  "session.created",
  "session.updated",
  "audio-chunk.registered",
  "model-run.created",
  "transcript.segment.created",
  "session.summary.created",
  "session.note.created",
  "error"
] as const;
export const HOSTED_TRANSCRIPT_STREAM_EVENT_TYPES = [
  "session.status",
  "transcript.segment",
  "notes.update",
  "summary.ready",
  "error"
] as const;
export const HOSTED_ASR_DEFAULT_MODEL_ID = "large-v3" as const;
export const HOSTED_ASR_DEFAULT_LANGUAGE = "en" as const;
export const HOSTED_ASR_DEFAULT_DEVICE = "cpu" as const;
export const HOSTED_ASR_DEFAULT_COMPUTE_TYPE = "int8" as const;
export const HOSTED_SUMMARY_DEFAULT_MODEL_ID = "Qwen2.5-7B-Instruct" as const;
export const HOSTED_AUDIO_CHUNK_PROCESSING_STATUSES = ["registered", "queued"] as const;
export const HOSTED_POSTGRES_TABLES = [
  "users",
  "sessions",
  "audio_chunks",
  "transcript_segments",
  "session_notes",
  "session_summaries",
  "action_items",
  "model_runs",
  "session_events"
] as const;
export const HOSTED_GCS_PREFIXES = {
  audioRaw: "audio/raw",
  audioProcessed: "audio/processed",
  transcriptExports: "exports/transcripts",
  summaryExports: "exports/summaries"
} as const;
export const HOSTED_REQUEST_HEADERS = {
  internalApiKey: "x-hosted-internal-key",
  requestId: "x-request-id",
  userId: "x-voice-user-id"
} as const;
export const HOSTED_REQUEST_QUERY_PARAMS = {
  userId: "userId"
} as const;
export const HOSTED_ENV_KEYS = {
  gcpProjectId: "GCP_PROJECT_ID",
  gcpRegion: "GCP_REGION",
  apiPort: "API_PORT",
  postgresUrl: "POSTGRES_URL",
  gcsBucketName: "GCS_BUCKET_NAME",
  localAudioDir: "HOSTED_LOCAL_AUDIO_DIR",
  defaultUserId: "HOSTED_DEFAULT_USER_ID",
  internalApiKey: "HOSTED_INTERNAL_API_KEY",
  requireUserId: "HOSTED_REQUIRE_USER_ID",
  pubsubAsrTopic: "PUBSUB_TOPIC_ASR",
  pubsubSummaryTopic: "PUBSUB_TOPIC_SUMMARY",
  pubsubAsrSubscription: "PUBSUB_SUBSCRIPTION_ASR",
  pubsubSummarySubscription: "PUBSUB_SUBSCRIPTION_SUMMARY",
  asrModelId: "ASR_MODEL_ID",
  asrPollIntervalMs: "ASR_POLL_INTERVAL_MS",
  asrClaimTimeoutMs: "ASR_CLAIM_TIMEOUT_MS",
  asrLanguage: "ASR_LANGUAGE",
  asrDevice: "ASR_DEVICE",
  asrComputeType: "ASR_COMPUTE_TYPE",
  asrBeamSize: "ASR_BEAM_SIZE",
  asrVadFilter: "ASR_VAD_FILTER",
  asrCpuThreads: "ASR_CPU_THREADS",
  asrNumWorkers: "ASR_NUM_WORKERS",
  asrModelCacheDir: "ASR_MODEL_CACHE_DIR",
  summaryModelId: "SUMMARY_MODEL_ID",
  summaryPollIntervalMs: "SUMMARY_POLL_INTERVAL_MS",
  summaryClaimTimeoutMs: "SUMMARY_CLAIM_TIMEOUT_MS",
  summaryNoteWindowSegments: "SUMMARY_NOTE_WINDOW_SEGMENTS",
  summaryMinSegments: "SUMMARY_MIN_SEGMENTS",
  summaryMaxTranscriptChars: "SUMMARY_MAX_TRANSCRIPT_CHARS",
  llmServerUrl: "LLM_SERVER_URL"
} as const;
export const HOSTED_WEB_ENV_KEYS = {
  userId: "VITE_HOSTED_USER_ID"
} as const;

export type HostedServiceName = (typeof HOSTED_SERVICE_NAMES)[number];
export type HostedSessionSource = (typeof HOSTED_SESSION_SOURCES)[number];
export type HostedSessionCaptureStrategy = (typeof HOSTED_SESSION_CAPTURE_STRATEGIES)[number];
export type HostedSessionStatus = (typeof HOSTED_SESSION_STATUSES)[number];
export type HostedAudioChunkStatus = (typeof HOSTED_AUDIO_CHUNK_STATUSES)[number];
export type HostedModelRunKind = (typeof HOSTED_MODEL_RUN_KINDS)[number];
export type HostedModelRunStatus = (typeof HOSTED_MODEL_RUN_STATUSES)[number];
export type HostedSessionEventType = (typeof HOSTED_SESSION_EVENT_TYPES)[number];
export type HostedTranscriptStreamEventType = (typeof HOSTED_TRANSCRIPT_STREAM_EVENT_TYPES)[number];
export type HostedPostgresTable = (typeof HOSTED_POSTGRES_TABLES)[number];
export type HostedAudioChunkProcessingStatus = (typeof HOSTED_AUDIO_CHUNK_PROCESSING_STATUSES)[number];
export type HostedPersistenceBackend = "memory" | "postgres";

export interface HostedSessionRecord {
  id: string;
  userId: string;
  sourceType: HostedSessionSource;
  status: HostedSessionStatus;
  createdAt: string;
  updatedAt: string;
  startedAt: string | null;
  endedAt: string | null;
  metadata: Record<string, string | number | boolean | null>;
}

export interface HostedSessionCreateRequest {
  userId?: string;
  sourceType: HostedSessionSource;
  captureStrategy?: HostedSessionCaptureStrategy;
  meetingSurface?: MeetingSurface | null;
  metadata?: Record<string, string | number | boolean | null>;
}

export interface HostedSessionCreateResponse {
  session: HostedSessionRecord;
}

export interface HostedConfigResponse {
  repositoryBackend: HostedPersistenceBackend;
  gcpProjectId: string | null;
  gcpRegion: string;
  postgresConfigured: boolean;
  gcsBucketConfigured: boolean;
  localAudioDirConfigured: boolean;
  pubsubConfigured: boolean;
  internalApiKeyConfigured: boolean;
  internalApiKeyHeader: string;
  requestIdHeader: string;
  userIdHeader: string;
  userIdQueryParam: string;
  authRequired: boolean;
  defaultUserId: string | null;
  storageBackend: HostedChunkStorageMode;
}

export interface HostedSessionStopRequest {
  status?: Extract<HostedSessionStatus, "complete" | "failed">;
  errorMessage?: string | null;
}

export interface HostedAudioChunkUploadRequest {
  chunkIndex: number;
  mimeType: string;
  startedAt: string;
  endedAt: string;
  byteLength?: number;
}

export interface HostedAudioChunkUploadResponse {
  chunk: HostedAudioChunkRecord;
  storageMode: HostedChunkStorageMode;
  storedBytes: number;
  storedPath: string;
}

export type HostedChunkStorageMode = "gcs" | "filesystem";

export interface HostedAudioChunkRecord {
  id: string;
  sessionId: string;
  chunkIndex: number;
  mimeType: string;
  startedAt: string;
  endedAt: string;
  objectPath: string;
  status: HostedAudioChunkStatus;
  createdAt: string;
  metadata: Record<string, string | number | boolean | null>;
}

export interface HostedTranscriptSegmentCreateRequest {
  audioChunkId?: string | null;
  modelRunId?: string | null;
  sequenceNumber: number;
  speakerLabel?: string | null;
  text: string;
  startMs: number;
  endMs: number;
  confidence?: number | null;
}

export interface HostedAsrWorkerSettings {
  modelId: string;
  language: string;
  device: string;
  computeType: string;
  beamSize: number;
  vadFilter: boolean;
  claimTimeoutMs: number;
  cpuThreads: number;
  numWorkers: number;
  pollIntervalMs: number;
  modelCacheDir: string | null;
}

export interface HostedTranscriptSegmentRecord {
  id: string;
  sessionId: string;
  audioChunkId: string | null;
  modelRunId: string | null;
  sequenceNumber: number;
  speakerLabel: string | null;
  text: string;
  startMs: number;
  endMs: number;
  confidence: number | null;
  createdAt: string;
}

export interface HostedTranscriptState {
  sessionId: string | null;
  revision: number;
  updatedAt: string | null;
  startedAt: string | null;
  lastSegmentAt: string | null;
  segmentCount: number;
  lastSequenceNumber: number | null;
  isSimulated: boolean;
  isActive: boolean;
  segments: readonly HostedTranscriptSegmentRecord[];
}

export interface HostedTranscriptResponse {
  repositoryBackend: HostedPersistenceBackend;
  session: HostedSessionRecord | null;
  transcript: HostedTranscriptState;
}

export interface HostedSessionNoteRecord {
  id: string;
  sessionId: string;
  modelRunId: string | null;
  sourceSegmentIds: readonly string[];
  text: string;
  createdAt: string;
}

export interface HostedSessionSummaryRecord {
  id: string;
  sessionId: string;
  modelRunId: string | null;
  overview: string;
  keyPoints: readonly string[];
  followUps: readonly string[];
  createdAt: string;
}

export interface HostedSummaryValue {
  sessionId: string;
  overview: string;
  keyPoints: readonly string[];
  followUps: readonly string[];
  generatedAt: string;
  modelInfo: string;
}

export interface HostedNotesState {
  sessionId: string | null;
  revision: number;
  updatedAt: string | null;
  noteCount: number;
  isSimulated: boolean;
  isActive: boolean;
  notes: readonly HostedSessionNoteRecord[];
}

export interface HostedNotesResponse {
  repositoryBackend: HostedPersistenceBackend;
  session: HostedSessionRecord | null;
  notes: HostedNotesState;
}

export interface HostedSummaryState {
  sessionId: string | null;
  revision: number;
  generatedAt: string | null;
  isSimulated: boolean;
  isReady: boolean;
  summary: HostedSummaryValue | null;
  actionItemCount: number;
  actionItems: readonly HostedActionItemRecord[];
}

export interface HostedSummaryResponse {
  repositoryBackend: HostedPersistenceBackend;
  session: HostedSessionRecord | null;
  summary: HostedSummaryState;
}

export type HostedHistorySourceFilter = HostedSessionSource | "all";

export type HostedHistoryStatusFilter = HostedSessionStatus | "all";

export interface HostedHistoryFilters {
  sourceType: HostedHistorySourceFilter;
  status: HostedHistoryStatusFilter;
  query: string;
}

export interface HostedHistoryListEntry {
  session: HostedSessionRecord;
  transcriptSegmentCount: number;
  noteCount: number;
  actionItemCount: number;
  latestNoteText: string | null;
  summaryOverview: string | null;
  summaryGeneratedAt: string | null;
  lastActivityAt: string;
}

export interface HostedHistoryListResponse {
  repositoryBackend: HostedPersistenceBackend;
  filters: HostedHistoryFilters;
  sessions: readonly HostedHistoryListEntry[];
}

export interface HostedHistoryDetailResponse {
  repositoryBackend: HostedPersistenceBackend;
  session: HostedSessionRecord | null;
  transcript: HostedTranscriptState;
  notes: HostedNotesState;
  summary: HostedSummaryState;
}

export interface HostedActionItemRecord {
  id: string;
  sessionId: string;
  sourceSummaryId: string | null;
  text: string;
  status: "open" | "done" | "blocked";
  createdAt: string;
}

export interface HostedModelRunRecord {
  id: string;
  sessionId: string;
  kind: HostedModelRunKind;
  modelId: string;
  runtime: string;
  status: HostedModelRunStatus;
  inputRef: string | null;
  createdAt: string;
  startedAt: string;
  completedAt: string | null;
  latencyMs: number | null;
  errorMessage: string | null;
  metadata: Record<string, string | number | boolean | null>;
}

export interface HostedModelRunCreateRequest {
  kind: HostedModelRunKind;
  modelId: string;
  runtime: string;
  inputRef?: string | null;
  startedAt?: string;
  metadata?: Record<string, string | number | boolean | null>;
}

export interface HostedSessionEventRecord {
  id: string;
  sessionId: string;
  type: HostedSessionEventType;
  createdAt: string;
  payload: Record<string, unknown>;
}

export interface HostedSessionEventCreateRequest {
  type: HostedSessionEventType;
  payload: Record<string, unknown>;
}

export interface HostedWorkerJob {
  jobId: string;
  sessionId: string;
  createdAt: string;
}

export interface HostedAsrJob extends HostedWorkerJob {
  chunkId: string;
  objectPath: string;
  modelId: string;
}

export interface HostedSummaryJob extends HostedWorkerJob {
  transcriptWindowStartId?: string;
  modelId: string;
}

export interface HostedSseEvent {
  type: "session.status" | "transcript.segment" | "notes.update" | "summary.ready" | "error";
  sessionId: string;
  createdAt: string;
  payload: unknown;
}

export interface HostedPersistenceSnapshot {
  sessions: readonly HostedSessionRecord[];
  audioChunks: readonly HostedAudioChunkRecord[];
  transcriptSegments: readonly HostedTranscriptSegmentRecord[];
  sessionNotes: readonly HostedSessionNoteRecord[];
  sessionSummaries: readonly HostedSessionSummaryRecord[];
  actionItems: readonly HostedActionItemRecord[];
  modelRuns: readonly HostedModelRunRecord[];
  sessionEvents: readonly HostedSessionEventRecord[];
}

export interface HostedRepositoryHealth {
  ok: boolean;
  backend: HostedPersistenceBackend;
  detail: string;
  checkedAt: string;
}

export interface HostedApiReadyResponse {
  ok: boolean;
  service: "api";
  checkedAt: string;
  repositoryBackend: HostedPersistenceBackend;
  storageBackend: HostedChunkStorageMode;
  authRequired: boolean;
  defaultUserId: string | null;
  dependencies: {
    repository: HostedRepositoryHealth;
  };
}

export interface HostedApiRouteMetric {
  route: string;
  requestCount: number;
  errorCount: number;
  averageDurationMs: number;
  lastStatusCode: number | null;
}

export interface HostedApiMetricsResponse {
  service: "api";
  startedAt: string;
  uptimeMs: number;
  repositoryBackend: HostedPersistenceBackend;
  storageBackend: HostedChunkStorageMode;
  activeStreamCount: number;
  requests: {
    total: number;
    inFlight: number;
    success: number;
    clientError: number;
    serverError: number;
    unauthorized: number;
    forbidden: number;
  };
  routes: readonly HostedApiRouteMetric[];
  repository: {
    sessionCount: number;
    audioChunkCount: number;
    transcriptSegmentCount: number;
    noteCount: number;
    summaryCount: number;
    actionItemCount: number;
    modelRunCount: number;
    eventCount: number;
    sessionsByStatus: Record<HostedSessionStatus, number>;
  };
}

export interface HostedPersistenceRepository {
  getBackendKind(): HostedPersistenceBackend;
  checkHealth(): Promise<HostedRepositoryHealth>;
  createSession(request: HostedSessionCreateRequest): Promise<HostedSessionRecord>;
  getSession(sessionId: string): Promise<HostedSessionRecord | null>;
  listSessions(): Promise<readonly HostedSessionRecord[]>;
  listTranscriptSegments(sessionId: string, sinceSequenceNumber?: number): Promise<readonly HostedTranscriptSegmentRecord[]>;
  listSessionNotes(sessionId: string): Promise<readonly HostedSessionNoteRecord[]>;
  listSessionSummaries(sessionId: string): Promise<readonly HostedSessionSummaryRecord[]>;
  listActionItems(sessionId: string): Promise<readonly HostedActionItemRecord[]>;
  registerAudioChunk(sessionId: string, request: HostedAudioChunkUploadRequest): Promise<HostedAudioChunkRecord>;
  listAudioChunks(sessionId: string): Promise<readonly HostedAudioChunkRecord[]>;
  listModelRuns(sessionId: string): Promise<readonly HostedModelRunRecord[]>;
  stopSession(sessionId: string, request?: HostedSessionStopRequest): Promise<HostedSessionRecord>;
  reprocessFinalAsrSession(sessionId: string): Promise<HostedSessionRecord>;
  recordModelRun(sessionId: string, request: HostedModelRunCreateRequest): Promise<HostedModelRunRecord>;
  appendSessionEvent(sessionId: string, request: HostedSessionEventCreateRequest): Promise<HostedSessionEventRecord>;
  snapshot(): Promise<HostedPersistenceSnapshot>;
}

function normalizeMimeType(mimeType: string) {
  return mimeType.toLowerCase().split(";")[0].trim();
}

function resolveAudioChunkExtension(mimeType: string) {
  switch (normalizeMimeType(mimeType)) {
    case "audio/webm":
      return "webm";
    case "audio/ogg":
      return "ogg";
    case "audio/mp4":
      return "m4a";
    case "audio/wav":
      return "wav";
    case "audio/mpeg":
      return "mp3";
    default:
      return "bin";
  }
}

export function buildHostedAudioChunkObjectPath(sessionId: string, chunkIndex: number, mimeType: string) {
  const chunkLabel = String(chunkIndex).padStart(6, "0");
  const extension = resolveAudioChunkExtension(mimeType);
  return `${HOSTED_GCS_PREFIXES.audioRaw}/sessions/${sessionId}/chunks/${chunkLabel}.${extension}`;
}

export function buildHostedSessionMergedAudioObjectPath(sessionId: string) {
  return `${HOSTED_GCS_PREFIXES.audioProcessed}/sessions/${sessionId}/merged.wav`;
}

export function buildHostedSessionExportPath(sessionId: string, kind: "transcript" | "summary") {
  return `${kind === "transcript" ? HOSTED_GCS_PREFIXES.transcriptExports : HOSTED_GCS_PREFIXES.summaryExports}/${sessionId}.json`;
}
