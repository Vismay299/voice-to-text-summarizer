export const HOSTED_SERVICE_NAMES = ["web", "api", "asr-worker", "summary-worker"] as const;
export const HOSTED_SESSION_SOURCES = ["microphone", "system-audio", "meeting-helper"] as const;
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
export const HOSTED_ENV_KEYS = {
  gcpProjectId: "GCP_PROJECT_ID",
  gcpRegion: "GCP_REGION",
  apiPort: "API_PORT",
  postgresUrl: "POSTGRES_URL",
  gcsBucketName: "GCS_BUCKET_NAME",
  localAudioDir: "HOSTED_LOCAL_AUDIO_DIR",
  pubsubAsrTopic: "PUBSUB_TOPIC_ASR",
  pubsubSummaryTopic: "PUBSUB_TOPIC_SUMMARY",
  pubsubAsrSubscription: "PUBSUB_SUBSCRIPTION_ASR",
  pubsubSummarySubscription: "PUBSUB_SUBSCRIPTION_SUMMARY",
  asrModelId: "ASR_MODEL_ID",
  summaryModelId: "SUMMARY_MODEL_ID",
  llmServerUrl: "LLM_SERVER_URL"
} as const;

export type HostedServiceName = (typeof HOSTED_SERVICE_NAMES)[number];
export type HostedSessionSource = (typeof HOSTED_SESSION_SOURCES)[number];
export type HostedSessionStatus = (typeof HOSTED_SESSION_STATUSES)[number];
export type HostedAudioChunkStatus = (typeof HOSTED_AUDIO_CHUNK_STATUSES)[number];
export type HostedModelRunKind = (typeof HOSTED_MODEL_RUN_KINDS)[number];
export type HostedModelRunStatus = (typeof HOSTED_MODEL_RUN_STATUSES)[number];
export type HostedSessionEventType = (typeof HOSTED_SESSION_EVENT_TYPES)[number];
export type HostedPostgresTable = (typeof HOSTED_POSTGRES_TABLES)[number];
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

export interface HostedPersistenceRepository {
  getBackendKind(): HostedPersistenceBackend;
  createSession(request: HostedSessionCreateRequest): Promise<HostedSessionRecord>;
  getSession(sessionId: string): Promise<HostedSessionRecord | null>;
  listSessions(): Promise<readonly HostedSessionRecord[]>;
  registerAudioChunk(sessionId: string, request: HostedAudioChunkUploadRequest): Promise<HostedAudioChunkRecord>;
  listAudioChunks(sessionId: string): Promise<readonly HostedAudioChunkRecord[]>;
  stopSession(sessionId: string, request?: HostedSessionStopRequest): Promise<HostedSessionRecord>;
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

export function buildHostedSessionExportPath(sessionId: string, kind: "transcript" | "summary") {
  return `${kind === "transcript" ? HOSTED_GCS_PREFIXES.transcriptExports : HOSTED_GCS_PREFIXES.summaryExports}/${sessionId}.json`;
}
