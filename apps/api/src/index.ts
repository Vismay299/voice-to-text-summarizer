import { randomUUID } from "node:crypto";
import { createServer } from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import {
  HOSTED_REQUEST_HEADERS,
  HOSTED_REQUEST_QUERY_PARAMS,
  buildHostedAudioChunkObjectPath,
  buildHostedSessionMergedAudioObjectPath,
  buildHostedSessionExportPath,
  HOSTED_ENV_KEYS,
  HOSTED_GCS_PREFIXES,
  HOSTED_POSTGRES_TABLES,
  HOSTED_SERVICE_NAMES,
  HOSTED_SESSION_STATUSES,
  HOSTED_SESSION_SOURCES,
  type HostedApiMetricsResponse,
  type HostedApiReadyResponse,
  type HostedHistoryDetailResponse,
  type HostedHistoryFilters,
  type HostedHistoryListEntry,
  type HostedHistoryListResponse,
  type HostedHistorySourceFilter,
  type HostedHistoryStatusFilter,
  type HostedActionItemRecord,
  type HostedAudioChunkUploadRequest,
  type HostedAudioChunkUploadResponse,
  type HostedModelRunCreateRequest,
  type HostedModelRunKind,
  type HostedModelRunRecord,
  type HostedNotesResponse,
  type HostedNotesState,
  type HostedPersistenceSnapshot,
  type HostedSessionCreateRequest,
  type HostedSessionStopRequest,
  type HostedSessionEventCreateRequest,
  type HostedSessionNoteRecord,
  type HostedSessionRecord,
  type HostedSessionSummaryRecord,
  type HostedSummaryResponse,
  type HostedSummaryState,
  type HostedSummaryValue,
  type HostedTranscriptResponse,
  type HostedTranscriptSegmentRecord,
  type HostedTranscriptState,
  type HostedSessionSource,
  type HostedSessionStatus
} from "@voice/shared/hosted";
import { createHostedAudioChunkStorage } from "./audio-storage.js";
import { createHostedRepository } from "./persistence.js";

const port = Number(process.env.API_PORT ?? 8080);
const repository = createHostedRepository();
const audioChunkStorage = createHostedAudioChunkStorage();
const apiStartedAtMs = Date.now();
const apiStartedAtIso = new Date(apiStartedAtMs).toISOString();

type HostedApiRouteMetricsState = {
  requestCount: number;
  errorCount: number;
  totalDurationMs: number;
  lastStatusCode: number | null;
};

const apiMetricsState = {
  total: 0,
  inFlight: 0,
  success: 0,
  clientError: 0,
  serverError: 0,
  unauthorized: 0,
  forbidden: 0,
  activeStreamCount: 0,
  routes: new Map<string, HostedApiRouteMetricsState>()
};

type HostedRequestContext = {
  requestId: string;
  userId: string | null;
  authRequired: boolean;
  defaultUserId: string | null;
  routeLabel: string;
};

function resolveRouteLabel(method: string | undefined, pathname: string) {
  const normalizedMethod = method ?? "GET";

  if (/^\/history\/sessions\/[^/]+$/.test(pathname)) {
    return `${normalizedMethod} /history/sessions/:id`;
  }
  if (/^\/sessions\/[^/]+\/(audio-chunks|model-runs|events|notes|stop|summary|transcript|stream)$/.test(pathname)) {
    return pathname.replace(/^\/sessions\/[^/]+\//, `${normalizedMethod} /sessions/:id/`);
  }
  if (/^\/sessions\/[^/]+$/.test(pathname)) {
    return `${normalizedMethod} /sessions/:id`;
  }

  return `${normalizedMethod} ${pathname}`;
}

function getOrCreateRouteMetrics(routeLabel: string) {
  const existing = apiMetricsState.routes.get(routeLabel);
  if (existing) {
    return existing;
  }

  const created: HostedApiRouteMetricsState = {
    requestCount: 0,
    errorCount: 0,
    totalDurationMs: 0,
    lastStatusCode: null
  };
  apiMetricsState.routes.set(routeLabel, created);
  return created;
}

function adjustActiveStreamCount(delta: number) {
  apiMetricsState.activeStreamCount = Math.max(0, apiMetricsState.activeStreamCount + delta);
}

function buildSessionStatusCounts(sessions: readonly HostedSessionRecord[]) {
  const counts = Object.fromEntries(HOSTED_SESSION_STATUSES.map((status) => [status, 0])) as Record<HostedSessionStatus, number>;

  for (const session of sessions) {
    counts[session.status] += 1;
  }

  return counts;
}

function buildMetricsResponse(snapshot: HostedPersistenceSnapshot): HostedApiMetricsResponse {
  return {
    service: "api",
    startedAt: apiStartedAtIso,
    uptimeMs: Date.now() - apiStartedAtMs,
    repositoryBackend: repository.getBackendKind(),
    storageBackend: audioChunkStorage.getStorageMode(),
    activeStreamCount: apiMetricsState.activeStreamCount,
    requests: {
      total: apiMetricsState.total,
      inFlight: apiMetricsState.inFlight,
      success: apiMetricsState.success,
      clientError: apiMetricsState.clientError,
      serverError: apiMetricsState.serverError,
      unauthorized: apiMetricsState.unauthorized,
      forbidden: apiMetricsState.forbidden
    },
    routes: [...apiMetricsState.routes.entries()]
      .map(([route, metrics]) => ({
        route,
        requestCount: metrics.requestCount,
        errorCount: metrics.errorCount,
        averageDurationMs: metrics.requestCount === 0 ? 0 : Number((metrics.totalDurationMs / metrics.requestCount).toFixed(1)),
        lastStatusCode: metrics.lastStatusCode
      }))
      .sort((a, b) => b.requestCount - a.requestCount || a.route.localeCompare(b.route)),
    repository: {
      sessionCount: snapshot.sessions.length,
      audioChunkCount: snapshot.audioChunks.length,
      transcriptSegmentCount: snapshot.transcriptSegments.length,
      noteCount: snapshot.sessionNotes.length,
      summaryCount: snapshot.sessionSummaries.length,
      actionItemCount: snapshot.actionItems.length,
      modelRunCount: snapshot.modelRuns.length,
      eventCount: snapshot.sessionEvents.length,
      sessionsByStatus: buildSessionStatusCounts(snapshot.sessions)
    }
  };
}

function normalizeOptionalString(value: string | null | undefined) {
  if (value === undefined || value === null) {
    return null;
  }

  const normalized = value.trim();
  return normalized.length > 0 ? normalized : null;
}

function parseBooleanEnv(name: string, defaultValue: boolean) {
  const rawValue = normalizeOptionalString(process.env[name]);
  if (!rawValue) {
    return defaultValue;
  }

  const normalized = rawValue.toLowerCase();
  if (normalized === "1" || normalized === "true" || normalized === "yes" || normalized === "on") {
    return true;
  }
  if (normalized === "0" || normalized === "false" || normalized === "no" || normalized === "off") {
    return false;
  }

  return defaultValue;
}

function resolveHostedRequestContext(req: IncomingMessage, url: URL): HostedRequestContext {
  const authRequired = parseBooleanEnv(HOSTED_ENV_KEYS.requireUserId, false);
  const defaultUserId = normalizeOptionalString(process.env[HOSTED_ENV_KEYS.defaultUserId]) ?? "demo-user";
  const explicitUserId =
    normalizeOptionalString(readHeaderValue(req, HOSTED_REQUEST_HEADERS.userId)) ??
    normalizeOptionalString(url.searchParams.get(HOSTED_REQUEST_QUERY_PARAMS.userId));

  return {
    requestId: normalizeOptionalString(readHeaderValue(req, HOSTED_REQUEST_HEADERS.requestId)) ?? randomUUID(),
    userId: explicitUserId ?? (authRequired ? null : defaultUserId),
    authRequired,
    defaultUserId: authRequired ? null : defaultUserId,
    routeLabel: resolveRouteLabel(req.method, url.pathname)
  };
}

function attachRequestContext(
  req: IncomingMessage,
  res: ServerResponse<IncomingMessage>,
  url: URL,
  context: HostedRequestContext
) {
  res.setHeader(HOSTED_REQUEST_HEADERS.requestId, context.requestId);
  if (context.userId) {
    res.setHeader(HOSTED_REQUEST_HEADERS.userId, context.userId);
  }

  const startedAt = Date.now();
  apiMetricsState.total += 1;
  apiMetricsState.inFlight += 1;
  const routeMetrics = getOrCreateRouteMetrics(context.routeLabel);
  res.on("finish", () => {
    const durationMs = Date.now() - startedAt;
    routeMetrics.requestCount += 1;
    routeMetrics.totalDurationMs += durationMs;
    routeMetrics.lastStatusCode = res.statusCode;
    if (res.statusCode >= 400) {
      routeMetrics.errorCount += 1;
    }
    apiMetricsState.inFlight = Math.max(0, apiMetricsState.inFlight - 1);
    if (res.statusCode >= 500) {
      apiMetricsState.serverError += 1;
    } else if (res.statusCode >= 400) {
      apiMetricsState.clientError += 1;
      if (res.statusCode === 401) {
        apiMetricsState.unauthorized += 1;
      }
      if (res.statusCode === 403) {
        apiMetricsState.forbidden += 1;
      }
    } else {
      apiMetricsState.success += 1;
    }
    console.info(
      `[api] ${context.routeLabel} status=${res.statusCode} requestId=${context.requestId} userId=${context.userId ?? "anonymous"} durationMs=${durationMs}`
    );
  });
}

function requireHostedUserId(
  res: ServerResponse<IncomingMessage>,
  context: HostedRequestContext
): context is HostedRequestContext & { userId: string } {
  if (context.userId) {
    return true;
  }

  writeJson(res, 401, {
    message: `Missing ${HOSTED_REQUEST_HEADERS.userId} header or ${HOSTED_REQUEST_QUERY_PARAMS.userId} query parameter.`
  });
  return false;
}

function requireInternalApiKey(req: IncomingMessage, res: ServerResponse<IncomingMessage>) {
  const configuredInternalApiKey = normalizeOptionalString(process.env[HOSTED_ENV_KEYS.internalApiKey]);
  if (!configuredInternalApiKey) {
    writeJson(res, 403, {
      message: "Internal mutation routes are disabled until HOSTED_INTERNAL_API_KEY is configured."
    });
    return false;
  }

  const providedInternalApiKey = normalizeOptionalString(readHeaderValue(req, HOSTED_REQUEST_HEADERS.internalApiKey));
  if (providedInternalApiKey !== configuredInternalApiKey) {
    writeJson(res, 403, {
      message: `Missing or invalid ${HOSTED_REQUEST_HEADERS.internalApiKey} header.`
    });
    return false;
  }

  return true;
}

function sessionMatchesUser(session: HostedSessionRecord | null, userId: string): session is HostedSessionRecord {
  return session !== null && session.userId === userId;
}

function writeJson(res: ServerResponse<IncomingMessage>, statusCode: number, body: unknown) {
  res.writeHead(statusCode, {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": [
      "content-type",
      HOSTED_REQUEST_HEADERS.internalApiKey,
      HOSTED_REQUEST_HEADERS.requestId,
      HOSTED_REQUEST_HEADERS.userId,
      "x-audio-chunk-index",
      "x-audio-chunk-started-at",
      "x-audio-chunk-ended-at"
    ].join(","),
    "access-control-expose-headers": [HOSTED_REQUEST_HEADERS.requestId, HOSTED_REQUEST_HEADERS.userId].join(","),
    "content-type": "application/json"
  });
  res.end(JSON.stringify(body, null, 2));
}

function writeSseHeaders(res: ServerResponse<IncomingMessage>) {
  res.writeHead(200, {
    "access-control-allow-origin": "*",
    "access-control-expose-headers": [HOSTED_REQUEST_HEADERS.requestId, HOSTED_REQUEST_HEADERS.userId].join(","),
    "cache-control": "no-cache, no-transform",
    connection: "keep-alive",
    "content-type": "text/event-stream; charset=utf-8"
  });
  res.flushHeaders?.();
}

function writeSseEvent(
  res: ServerResponse<IncomingMessage>,
  eventType: string,
  payload: unknown,
  id?: string | number | null
) {
  if (id !== undefined && id !== null) {
    res.write(`id: ${id}\n`);
  }
  res.write(`event: ${eventType}\n`);
  res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

function createHostedTranscriptState(
  session: HostedSessionRecord | null,
  segments: readonly HostedTranscriptSegmentRecord[]
): HostedTranscriptState {
  const orderedSegments = [...segments].sort((a, b) => a.sequenceNumber - b.sequenceNumber);
  const lastSegment = orderedSegments.at(-1) ?? null;
  const updatedAt = lastSegment?.createdAt ?? session?.updatedAt ?? null;

  return {
    sessionId: session?.id ?? null,
    revision: orderedSegments.length,
    updatedAt,
    startedAt: session?.startedAt ?? null,
    lastSegmentAt: lastSegment?.createdAt ?? null,
    segmentCount: orderedSegments.length,
    lastSequenceNumber: lastSegment?.sequenceNumber ?? null,
    isSimulated: false,
    isActive: session ? session.status === "starting" || session.status === "recording" : false,
    segments: orderedSegments
  };
}

function createHostedTranscriptSegmentState(session: HostedSessionRecord, segment: HostedTranscriptSegmentRecord): HostedTranscriptState {
  return {
    sessionId: session.id,
    revision: segment.sequenceNumber + 1,
    updatedAt: segment.createdAt,
    startedAt: session.startedAt ?? session.createdAt,
    lastSegmentAt: segment.createdAt,
    segmentCount: segment.sequenceNumber + 1,
    lastSequenceNumber: segment.sequenceNumber,
    isSimulated: false,
    isActive: session.status === "starting" || session.status === "recording",
    segments: [segment]
  };
}

function createHostedNotesState(
  session: HostedSessionRecord | null,
  notes: readonly HostedSessionNoteRecord[]
): HostedNotesState {
  const orderedNotes = [...notes].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  const lastNote = orderedNotes.at(-1) ?? null;

  return {
    sessionId: session?.id ?? null,
    revision: orderedNotes.length,
    updatedAt: lastNote?.createdAt ?? session?.updatedAt ?? null,
    noteCount: orderedNotes.length,
    isSimulated: false,
    isActive: session ? session.status === "starting" || session.status === "recording" || session.status === "processing" : false,
    notes: orderedNotes
  };
}

function resolveHostedSummaryModelInfo(
  summary: HostedSessionSummaryRecord | null,
  modelRuns: readonly HostedModelRunRecord[]
) {
  if (!summary?.modelRunId) {
    return "summary-worker";
  }

  const modelRun = modelRuns.find((candidate) => candidate.id === summary.modelRunId);
  if (!modelRun) {
    return "summary-worker";
  }

  return `${modelRun.runtime}:${modelRun.modelId}`;
}

function createHostedSummaryValue(
  summary: HostedSessionSummaryRecord | null,
  modelRuns: readonly HostedModelRunRecord[]
): HostedSummaryValue | null {
  if (!summary) {
    return null;
  }

  return {
    sessionId: summary.sessionId,
    overview: summary.overview,
    keyPoints: [...summary.keyPoints],
    followUps: [...summary.followUps],
    generatedAt: summary.createdAt,
    modelInfo: resolveHostedSummaryModelInfo(summary, modelRuns)
  };
}

function createHostedSummaryState(
  session: HostedSessionRecord | null,
  summaries: readonly HostedSessionSummaryRecord[],
  actionItems: readonly HostedActionItemRecord[],
  modelRuns: readonly HostedModelRunRecord[]
): HostedSummaryState {
  const orderedSummaries = [...summaries].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  const orderedActionItems = [...actionItems].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  const latestSummary = orderedSummaries.at(-1) ?? null;

  return {
    sessionId: session?.id ?? null,
    revision: orderedSummaries.length,
    generatedAt: latestSummary?.createdAt ?? null,
    isSimulated: false,
    isReady: latestSummary !== null,
    summary: createHostedSummaryValue(latestSummary, modelRuns),
    actionItemCount: orderedActionItems.length,
    actionItems: orderedActionItems
  };
}

function createTranscriptResponse(session: HostedSessionRecord | null, segments: readonly HostedTranscriptSegmentRecord[]): HostedTranscriptResponse {
  return {
    repositoryBackend: repository.getBackendKind(),
    session,
    transcript: createHostedTranscriptState(session, segments)
  };
}

function createNotesResponse(session: HostedSessionRecord | null, notes: readonly HostedSessionNoteRecord[]): HostedNotesResponse {
  return {
    repositoryBackend: repository.getBackendKind(),
    session,
    notes: createHostedNotesState(session, notes)
  };
}

function createSummaryResponse(
  session: HostedSessionRecord | null,
  summaries: readonly HostedSessionSummaryRecord[],
  actionItems: readonly HostedActionItemRecord[],
  modelRuns: readonly HostedModelRunRecord[]
): HostedSummaryResponse {
  return {
    repositoryBackend: repository.getBackendKind(),
    session,
    summary: createHostedSummaryState(session, summaries, actionItems, modelRuns)
  };
}

function parseTranscriptCursor(value: string | null) {
  if (!value) {
    return null;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function normalizeHistoryQuery(value: string | null) {
  return (value ?? "").trim().toLowerCase();
}

function parseHistorySourceFilter(value: string | null): HostedHistorySourceFilter {
  if (value === "microphone" || value === "system-audio" || value === "meeting-helper") {
    return value;
  }
  return "all";
}

function parseHistoryStatusFilter(value: string | null): HostedHistoryStatusFilter {
  if (value === "starting" || value === "recording" || value === "processing" || value === "complete" || value === "failed") {
    return value;
  }
  return "all";
}

function buildHistoryFilters(url: URL): HostedHistoryFilters {
  return {
    sourceType: parseHistorySourceFilter(url.searchParams.get("sourceType")),
    status: parseHistoryStatusFilter(url.searchParams.get("status")),
    query: url.searchParams.get("query")?.trim() ?? ""
  };
}

function buildHostedHistoryListEntry(
  session: HostedSessionRecord,
  transcriptSegments: readonly HostedTranscriptSegmentRecord[],
  notes: readonly HostedSessionNoteRecord[],
  summaries: readonly HostedSessionSummaryRecord[],
  actionItems: readonly HostedActionItemRecord[]
): HostedHistoryListEntry {
  const latestNote = [...notes].sort((a, b) => b.createdAt.localeCompare(a.createdAt))[0] ?? null;
  const latestSummary = [...summaries].sort((a, b) => b.createdAt.localeCompare(a.createdAt))[0] ?? null;
  const lastTranscriptSegment = [...transcriptSegments].sort((a, b) => b.sequenceNumber - a.sequenceNumber)[0] ?? null;

  return {
    session,
    transcriptSegmentCount: transcriptSegments.length,
    noteCount: notes.length,
    actionItemCount: actionItems.length,
    latestNoteText: latestNote?.text ?? null,
    summaryOverview: latestSummary?.overview ?? null,
    summaryGeneratedAt: latestSummary?.createdAt ?? null,
    lastActivityAt: latestSummary?.createdAt ?? latestNote?.createdAt ?? lastTranscriptSegment?.createdAt ?? session.updatedAt
  };
}

function matchesHistoryFilters(entry: HostedHistoryListEntry, filters: HostedHistoryFilters) {
  if (filters.sourceType !== "all" && entry.session.sourceType !== filters.sourceType) {
    return false;
  }

  if (filters.status !== "all" && entry.session.status !== filters.status) {
    return false;
  }

  const query = normalizeHistoryQuery(filters.query);
  if (!query) {
    return true;
  }

  return [
    entry.session.id,
    entry.session.sourceType,
    entry.summaryOverview ?? "",
    entry.latestNoteText ?? ""
  ]
    .join(" ")
    .toLowerCase()
    .includes(query);
}

function createSessionResponse(session: HostedSessionRecord) {
  return {
    session,
    repositoryBackend: repository.getBackendKind()
  };
}

function isHostedSessionSource(value: unknown): value is HostedSessionSource {
  return typeof value === "string" && HOSTED_SESSION_SOURCES.includes(value as HostedSessionSource);
}

function isHostedModelRunKind(value: unknown): value is HostedModelRunKind {
  return value === "asr" || value === "summary";
}

function isAudioChunkUploadRequest(value: Partial<HostedAudioChunkUploadRequest>): value is HostedAudioChunkUploadRequest {
  return (
    typeof value.chunkIndex === "number" &&
    Number.isInteger(value.chunkIndex) &&
    value.chunkIndex >= 0 &&
    typeof value.mimeType === "string" &&
    typeof value.startedAt === "string" &&
    typeof value.endedAt === "string"
  );
}

function isModelRunCreateRequest(value: Partial<HostedModelRunCreateRequest>): value is HostedModelRunCreateRequest {
  return (
    isHostedModelRunKind(value.kind) &&
    typeof value.modelId === "string" &&
    typeof value.runtime === "string" &&
    (value.inputRef === undefined || value.inputRef === null || typeof value.inputRef === "string")
  );
}

function isSessionEventCreateRequest(value: Partial<HostedSessionEventCreateRequest>): value is HostedSessionEventCreateRequest {
  return (
    typeof value.type === "string" &&
    typeof value.payload === "object" &&
    value.payload !== null &&
    !Array.isArray(value.payload)
  );
}

function isHostedSessionStopRequest(value: Partial<HostedSessionStopRequest>): value is HostedSessionStopRequest {
  return (
    (value.status === undefined || value.status === "complete" || value.status === "failed") &&
    (value.errorMessage === undefined || value.errorMessage === null || typeof value.errorMessage === "string")
  );
}

function isJsonContentType(contentType: string | undefined) {
  return Boolean(contentType && contentType.toLowerCase().includes("application/json"));
}

function readHeaderValue(req: IncomingMessage, name: string) {
  const value = req.headers[name.toLowerCase()];
  if (Array.isArray(value)) {
    return value[0] ?? null;
  }

  return value ?? null;
}

function parseNumericHeader(req: IncomingMessage, name: string) {
  const value = readHeaderValue(req, name);
  if (value === null) {
    return null;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
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

async function readRequestBuffer(req: IncomingMessage) {
  const chunks: Buffer[] = [];

  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }

  return Buffer.concat(chunks);
}

const server = createServer((req, res) => {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  const context = resolveHostedRequestContext(req, url);
  attachRequestContext(req, res, url, context);

  if (req.method === "OPTIONS") {
    writeJson(res, 204, {});
    return;
  }

  if (url.pathname === "/health") {
    writeJson(res, 200, {
      ok: true,
      service: "api",
      port,
      services: HOSTED_SERVICE_NAMES,
      startedAt: apiStartedAtIso,
      uptimeMs: Date.now() - apiStartedAtMs
    });
    return;
  }

  if (url.pathname === "/ready") {
    void repository
      .checkHealth()
      .then((repositoryHealth) => {
        const response: HostedApiReadyResponse = {
          ok: repositoryHealth.ok,
          service: "api",
          checkedAt: repositoryHealth.checkedAt,
          repositoryBackend: repository.getBackendKind(),
          storageBackend: audioChunkStorage.getStorageMode(),
          authRequired: context.authRequired,
          defaultUserId: context.defaultUserId,
          dependencies: {
            repository: repositoryHealth
          }
        };
        writeJson(res, repositoryHealth.ok ? 200 : 503, response);
      })
      .catch((error) => {
        const checkedAt = new Date().toISOString();
        const response: HostedApiReadyResponse = {
          ok: false,
          service: "api",
          checkedAt,
          repositoryBackend: repository.getBackendKind(),
          storageBackend: audioChunkStorage.getStorageMode(),
          authRequired: context.authRequired,
          defaultUserId: context.defaultUserId,
          dependencies: {
            repository: {
              ok: false,
              backend: repository.getBackendKind(),
              detail: error instanceof Error ? error.message : "Repository readiness check failed.",
              checkedAt
            }
          }
        };
        writeJson(res, 503, response);
      });
    return;
  }

  if (url.pathname === "/metrics") {
    void repository
      .snapshot()
      .then((snapshot) => {
        writeJson(res, 200, buildMetricsResponse(snapshot));
      })
      .catch((error) => {
        writeJson(res, 503, {
          ...buildMetricsResponse({
            sessions: [],
            audioChunks: [],
            transcriptSegments: [],
            sessionNotes: [],
            sessionSummaries: [],
            actionItems: [],
            modelRuns: [],
            sessionEvents: []
          }),
          repositoryError: error instanceof Error ? error.message : "Unable to load repository metrics."
        });
      });
    return;
  }

  if (url.pathname === "/config") {
    writeJson(res, 200, {
      repositoryBackend: repository.getBackendKind(),
      gcpProjectId: process.env[HOSTED_ENV_KEYS.gcpProjectId] ?? null,
      gcpRegion: process.env[HOSTED_ENV_KEYS.gcpRegion] ?? "us-central1",
      postgresConfigured: Boolean(process.env[HOSTED_ENV_KEYS.postgresUrl]),
      gcsBucketConfigured: Boolean(process.env[HOSTED_ENV_KEYS.gcsBucketName]),
      localAudioDirConfigured: Boolean(process.env[HOSTED_ENV_KEYS.localAudioDir]),
      pubsubConfigured: Boolean(process.env[HOSTED_ENV_KEYS.pubsubAsrTopic] && process.env[HOSTED_ENV_KEYS.pubsubSummaryTopic]),
      internalApiKeyConfigured: Boolean(normalizeOptionalString(process.env[HOSTED_ENV_KEYS.internalApiKey])),
      internalApiKeyHeader: HOSTED_REQUEST_HEADERS.internalApiKey,
      requestIdHeader: HOSTED_REQUEST_HEADERS.requestId,
      userIdHeader: HOSTED_REQUEST_HEADERS.userId,
      userIdQueryParam: HOSTED_REQUEST_QUERY_PARAMS.userId,
      authRequired: context.authRequired,
      defaultUserId: context.defaultUserId,
      storageBackend: audioChunkStorage.getStorageMode()
    });
    return;
  }

  if (url.pathname === "/contracts") {
    writeJson(res, 200, {
      envKeys: HOSTED_ENV_KEYS,
      serviceNames: HOSTED_SERVICE_NAMES,
      sessionSources: HOSTED_SESSION_SOURCES,
      postgresTables: HOSTED_POSTGRES_TABLES,
      gcsPrefixes: HOSTED_GCS_PREFIXES,
      gcsPatterns: {
        rawAudio: buildHostedAudioChunkObjectPath("SESSION_ID", 0, "audio/webm"),
        mergedAudio: buildHostedSessionMergedAudioObjectPath("SESSION_ID"),
        transcriptExport: buildHostedSessionExportPath("SESSION_ID", "transcript"),
        summaryExport: buildHostedSessionExportPath("SESSION_ID", "summary")
      },
      uploadContract: {
        route: "POST /sessions/:id/audio-chunks",
        jsonFallback: true,
        binaryHeaders: ["x-audio-chunk-index", "x-audio-chunk-started-at", "x-audio-chunk-ended-at", "content-type"]
      },
      authContract: {
        internalApiKeyConfigured: Boolean(normalizeOptionalString(process.env[HOSTED_ENV_KEYS.internalApiKey])),
        internalApiKeyHeader: HOSTED_REQUEST_HEADERS.internalApiKey,
        requestIdHeader: HOSTED_REQUEST_HEADERS.requestId,
        userIdHeader: HOSTED_REQUEST_HEADERS.userId,
        userIdQueryParam: HOSTED_REQUEST_QUERY_PARAMS.userId,
        authRequired: context.authRequired
      },
      internalMutationContract: {
        header: HOSTED_REQUEST_HEADERS.internalApiKey,
        modelRunsRoute: "POST /sessions/:id/model-runs",
        eventsRoute: "POST /sessions/:id/events",
        reprocessFinalAsrRoute: "POST /internal/sessions/:id/reprocess-final-asr"
      },
      transcriptContract: {
        route: "GET /sessions/:id/transcript",
        streamRoute: "GET /sessions/:id/stream",
        streamEvents: ["session.status", "transcript.segment", "summary.ready", "error"]
      },
      notesContract: {
        route: "GET /sessions/:id/notes",
        status: "legacy-compatibility-only"
      },
      summaryContract: {
        route: "GET /sessions/:id/summary"
      },
      historyContract: {
        listRoute: "GET /history/sessions?sourceType=&status=&query=",
        detailRoute: "GET /history/sessions/:id"
      },
      stopContract: "POST /sessions/:id/stop"
    });
    return;
  }

  const internalReprocessSessionMatch = /^\/internal\/sessions\/([^/]+)\/reprocess-final-asr$/.exec(url.pathname);
  if (internalReprocessSessionMatch && req.method === "POST") {
    if (!requireInternalApiKey(req, res)) {
      return;
    }

    const sessionId = decodeURIComponent(internalReprocessSessionMatch[1]);
    void repository
      .reprocessFinalAsrSession(sessionId)
      .then((session) => {
        writeJson(res, 200, {
          session,
          reprocessQueued: true,
          route: "reprocess-final-asr"
        });
      })
      .catch((error) => {
        writeJson(res, 409, {
          message: error instanceof Error ? error.message : "Unable to queue session for final ASR reprocessing."
        });
      });
    return;
  }

  const isProtectedRoute =
    url.pathname === "/history/sessions" ||
    url.pathname.startsWith("/history/sessions/") ||
    url.pathname === "/sessions" ||
    url.pathname.startsWith("/sessions/");
  if (isProtectedRoute && !requireHostedUserId(res, context)) {
    return;
  }
  const userId = context.userId as string;

  if (url.pathname === "/history/sessions" && req.method === "GET") {
    const filters = buildHistoryFilters(url);
    void repository
      .snapshot()
      .then((snapshot: HostedPersistenceSnapshot) => {
        const sessions = snapshot.sessions
          .filter((session) => session.userId === userId)
          .map((session) =>
            buildHostedHistoryListEntry(
              session,
              snapshot.transcriptSegments.filter((segment) => segment.sessionId === session.id),
              snapshot.sessionNotes.filter((note) => note.sessionId === session.id),
              snapshot.sessionSummaries.filter((summary) => summary.sessionId === session.id),
              snapshot.actionItems.filter((actionItem) => actionItem.sessionId === session.id)
            )
          )
          .filter((entry) => matchesHistoryFilters(entry, filters))
          .sort((a, b) => b.lastActivityAt.localeCompare(a.lastActivityAt));

        const response: HostedHistoryListResponse = {
          repositoryBackend: repository.getBackendKind(),
          filters,
          sessions
        };
        writeJson(res, 200, response);
      })
      .catch((error) => {
        writeJson(res, 500, { message: error instanceof Error ? error.message : "Unable to load hosted history." });
      });
    return;
  }

  const historySessionMatch = /^\/history\/sessions\/([^/]+)$/.exec(url.pathname);

  if (historySessionMatch && req.method === "GET") {
    const sessionId = decodeURIComponent(historySessionMatch[1]);
    void repository
      .snapshot()
      .then((snapshot: HostedPersistenceSnapshot) => {
        const session =
          snapshot.sessions.find((candidate) => candidate.id === sessionId && candidate.userId === userId) ?? null;
        if (!session) {
          writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
          return;
        }

        const transcriptSegments = snapshot.transcriptSegments.filter((segment) => segment.sessionId === sessionId);
        const notes = snapshot.sessionNotes.filter((note) => note.sessionId === sessionId);
        const summaries = snapshot.sessionSummaries.filter((summary) => summary.sessionId === sessionId);
        const actionItems = snapshot.actionItems.filter((actionItem) => actionItem.sessionId === sessionId);
        const modelRuns = snapshot.modelRuns.filter((modelRun) => modelRun.sessionId === sessionId);

        const response: HostedHistoryDetailResponse = {
          repositoryBackend: repository.getBackendKind(),
          session,
          transcript: createHostedTranscriptState(session, transcriptSegments),
          notes: createNotesResponse(session, notes).notes,
          summary: createSummaryResponse(session, summaries, actionItems, modelRuns).summary
        };
        writeJson(res, 200, response);
      })
      .catch((error) => {
        writeJson(res, 500, { message: error instanceof Error ? error.message : "Unable to load hosted history detail." });
      });
    return;
  }

  if (url.pathname === "/sessions" && req.method === "GET") {
    void repository
      .listSessions()
      .then((sessions) => {
        writeJson(res, 200, {
          repositoryBackend: repository.getBackendKind(),
          sessions: sessions.filter((session) => session.userId === userId)
        });
      })
      .catch((error) => {
        writeJson(res, 500, { message: error instanceof Error ? error.message : "Unable to list sessions." });
      });
    return;
  }

  if (url.pathname === "/sessions" && req.method === "POST") {
    void readJsonBody<HostedSessionCreateRequest>(req)
      .then((body) => {
        if (!isHostedSessionSource(body.sourceType)) {
          writeJson(res, 400, { message: "Session source type is missing or invalid." });
          return;
        }
        if (body.userId !== undefined && body.userId !== userId) {
          writeJson(res, 403, { message: "Session userId must match the authenticated hosted user." });
          return;
        }

        void repository
          .createSession({
            userId,
            sourceType: body.sourceType,
            captureStrategy: body.captureStrategy,
            meetingSurface: body.meetingSurface ?? null,
            metadata: body.metadata
          })
          .then(async (session) => {
            const audioChunks = await repository.listAudioChunks(session.id);
            writeJson(res, 201, {
              ...createSessionResponse(session),
              audioChunkCount: audioChunks.length
            });
          })
          .catch((error) => {
            writeJson(res, 500, {
              message: error instanceof Error ? error.message : "Unable to create session."
            });
          });
      })
      .catch(() => {
        writeJson(res, 400, { message: "Invalid session payload." });
      });
    return;
  }

  const sessionMatch = /^\/sessions\/([^/]+)$/.exec(url.pathname);
  const sessionSubrouteMatch = /^\/sessions\/([^/]+)\/(audio-chunks|model-runs|events|notes|stop|summary|transcript|stream)$/.exec(url.pathname);

  if (sessionMatch && req.method === "GET") {
    const sessionId = decodeURIComponent(sessionMatch[1]);
    void repository
      .getSession(sessionId)
      .then(async (session) => {
        if (!sessionMatchesUser(session, userId)) {
          writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
          return;
        }

        const audioChunks = await repository.listAudioChunks(sessionId);
        writeJson(res, 200, {
          session,
          audioChunkCount: audioChunks.length,
          repositoryBackend: repository.getBackendKind()
        });
      })
      .catch((error) => {
        writeJson(res, 500, { message: error instanceof Error ? error.message : "Unable to load session." });
      });
    return;
  }

  if (sessionSubrouteMatch && req.method === "GET" && sessionSubrouteMatch[2] === "transcript") {
    const sessionId = decodeURIComponent(sessionSubrouteMatch[1]);
    void repository
      .getSession(sessionId)
      .then(async (session) => {
        if (!sessionMatchesUser(session, userId)) {
          writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
          return;
        }

        const segments = await repository.listTranscriptSegments(sessionId);
        writeJson(res, 200, createTranscriptResponse(session, segments));
      })
      .catch((error) => {
        writeJson(res, 500, { message: error instanceof Error ? error.message : "Unable to load transcript." });
      });
    return;
  }

  if (sessionSubrouteMatch && req.method === "GET" && sessionSubrouteMatch[2] === "notes") {
    const sessionId = decodeURIComponent(sessionSubrouteMatch[1]);
    void repository
      .getSession(sessionId)
      .then(async (session) => {
        if (!sessionMatchesUser(session, userId)) {
          writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
          return;
        }

        const notes = await repository.listSessionNotes(sessionId);
        writeJson(res, 200, createNotesResponse(session, notes));
      })
      .catch((error) => {
        writeJson(res, 500, { message: error instanceof Error ? error.message : "Unable to load notes." });
      });
    return;
  }

  if (sessionSubrouteMatch && req.method === "GET" && sessionSubrouteMatch[2] === "summary") {
    const sessionId = decodeURIComponent(sessionSubrouteMatch[1]);
    void repository
      .getSession(sessionId)
      .then(async (session) => {
        if (!sessionMatchesUser(session, userId)) {
          writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
          return;
        }

        const [summaries, actionItems, modelRuns] = await Promise.all([
          repository.listSessionSummaries(sessionId),
          repository.listActionItems(sessionId),
          repository.listModelRuns(sessionId)
        ]);

        writeJson(res, 200, createSummaryResponse(session, summaries, actionItems, modelRuns));
      })
      .catch((error) => {
        writeJson(res, 500, { message: error instanceof Error ? error.message : "Unable to load summary." });
      });
    return;
  }

  if (sessionSubrouteMatch && req.method === "GET" && sessionSubrouteMatch[2] === "stream") {
    const sessionId = decodeURIComponent(sessionSubrouteMatch[1]);
    const cursorFromQuery = parseTranscriptCursor(url.searchParams.get("sinceSequenceNumber"));
    const cursorFromHeader = parseTranscriptCursor(readHeaderValue(req, "last-event-id"));
    let cursor = Math.max(cursorFromQuery ?? -1, cursorFromHeader ?? -1);
    let closed = false;
    let heartbeatTimer: ReturnType<typeof setInterval> | null = null;

    writeSseHeaders(res);
    res.write("retry: 3000\n\n");
    adjustActiveStreamCount(1);

    const cleanup = () => {
      if (closed) {
        return;
      }

      closed = true;
      adjustActiveStreamCount(-1);
      if (heartbeatTimer !== null) {
        clearInterval(heartbeatTimer);
        heartbeatTimer = null;
      }
    };

    const endStream = () => {
      cleanup();
      res.end();
    };

    req.on("close", cleanup);
    res.on("close", cleanup);

    heartbeatTimer = setInterval(() => {
      if (!closed) {
        res.write(": keep-alive\n\n");
      }
    }, 15000);

    const loadStreamState = async (session: HostedSessionRecord) => {
      const [segments, notes, summaries, actionItems, modelRuns] = await Promise.all([
        repository.listTranscriptSegments(session.id),
        repository.listSessionNotes(session.id),
        repository.listSessionSummaries(session.id),
        repository.listActionItems(session.id),
        repository.listModelRuns(session.id)
      ]);

      return {
        transcript: createHostedTranscriptState(session, segments),
        notes: createNotesResponse(session, notes).notes,
        summary: createSummaryResponse(session, summaries, actionItems, modelRuns).summary,
        segments
      };
    };

    void repository
      .getSession(sessionId)
      .then(async (session) => {
        if (!sessionMatchesUser(session, userId)) {
          writeSseEvent(res, "error", { message: `Session ${sessionId} does not exist.` }, cursor);
          endStream();
          return;
        }

        const initialState = await loadStreamState(session);
        let lastKnownSessionStatus = session.status;
        let lastKnownSessionUpdatedAt = session.updatedAt;
        let lastKnownNotesRevision = initialState.notes.revision;
        let lastKnownNotesUpdatedAt = initialState.notes.updatedAt;
        let lastKnownSummaryRevision = initialState.summary.revision;
        let lastKnownSummaryGeneratedAt = initialState.summary.generatedAt;
        let lastKnownActionItemCount = initialState.summary.actionItemCount;
        const pendingSegments = initialState.segments.filter((segment) => segment.sequenceNumber > cursor);
        for (const segment of pendingSegments) {
          const payload = {
            segment,
            transcript: createHostedTranscriptSegmentState(session, segment)
          };
          writeSseEvent(res, "transcript.segment", payload, segment.sequenceNumber);
          cursor = segment.sequenceNumber;
        }

        if (initialState.notes.revision > 0) {
          writeSseEvent(res, "notes.update", { notes: initialState.notes }, cursor);
        }

        if (initialState.summary.isReady) {
          writeSseEvent(res, "summary.ready", { summary: initialState.summary }, cursor);
        }

        writeSseEvent(res, "session.status", { session, transcript: initialState.transcript }, cursor);

        if (session.status === "failed" || (session.status === "complete" && initialState.summary.isReady)) {
          endStream();
          return;
        }

        let pollInFlight = false;
        const pollLoop = async () => {
          if (closed) {
            return;
          }

          const latestSession = await repository.getSession(sessionId);
          if (!sessionMatchesUser(latestSession, userId)) {
            writeSseEvent(res, "error", { message: `Session ${sessionId} no longer exists.` }, cursor);
            endStream();
            return;
          }

          const latestState = await loadStreamState(latestSession);
          const latestSegments = latestState.segments.filter((segment) => segment.sequenceNumber > cursor);

          for (const segment of latestSegments) {
            const payload = {
              segment,
              transcript: createHostedTranscriptSegmentState(latestSession, segment)
            };
            writeSseEvent(res, "transcript.segment", payload, segment.sequenceNumber);
            cursor = segment.sequenceNumber;
          }

          if (
            latestState.notes.revision !== lastKnownNotesRevision ||
            latestState.notes.updatedAt !== lastKnownNotesUpdatedAt
          ) {
            writeSseEvent(res, "notes.update", { notes: latestState.notes }, cursor);
            lastKnownNotesRevision = latestState.notes.revision;
            lastKnownNotesUpdatedAt = latestState.notes.updatedAt;
          }

          if (
            latestState.summary.revision !== lastKnownSummaryRevision ||
            latestState.summary.generatedAt !== lastKnownSummaryGeneratedAt ||
            latestState.summary.actionItemCount !== lastKnownActionItemCount
          ) {
            writeSseEvent(res, "summary.ready", { summary: latestState.summary }, cursor);
            lastKnownSummaryRevision = latestState.summary.revision;
            lastKnownSummaryGeneratedAt = latestState.summary.generatedAt;
            lastKnownActionItemCount = latestState.summary.actionItemCount;
          }

          if (latestSession.status !== lastKnownSessionStatus || latestSession.updatedAt !== lastKnownSessionUpdatedAt) {
            writeSseEvent(
              res,
              "session.status",
              { session: latestSession, transcript: latestState.transcript },
              cursor
            );
            lastKnownSessionStatus = latestSession.status;
            lastKnownSessionUpdatedAt = latestSession.updatedAt;
          }

          if (latestSession.status === "failed" || (latestSession.status === "complete" && latestState.summary.isReady)) {
            endStream();
          }
        };

        const interval = setInterval(() => {
          if (pollInFlight || closed) {
            return;
          }
          pollInFlight = true;
          void pollLoop().catch((error) => {
            writeSseEvent(res, "error", { message: error instanceof Error ? error.message : "Transcript stream failed." }, cursor);
            endStream();
          }).finally(() => {
            pollInFlight = false;
          });
        }, 1000);

        const cleanupInterval = () => {
          clearInterval(interval);
        };

        req.on("close", cleanupInterval);
        res.on("close", cleanupInterval);
      })
      .catch((error) => {
        writeSseEvent(res, "error", { message: error instanceof Error ? error.message : "Unable to open transcript stream." }, cursor);
        endStream();
      });
    return;
  }

  if (sessionSubrouteMatch && req.method === "POST" && sessionSubrouteMatch[2] === "audio-chunks") {
    const sessionId = decodeURIComponent(sessionSubrouteMatch[1]);
    const contentType = readHeaderValue(req, "content-type") ?? "";

    void repository
      .getSession(sessionId)
      .then((session) => {
        if (!sessionMatchesUser(session, userId)) {
          writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
          return;
        }

        if (isJsonContentType(contentType)) {
          void readJsonBody<HostedAudioChunkUploadRequest>(req)
            .then((body) => {
              if (!isAudioChunkUploadRequest(body)) {
                writeJson(res, 400, { message: "Audio chunk payload is missing required fields." });
                return;
              }

              void repository
                .registerAudioChunk(sessionId, body)
                .then(async (chunk) => {
                  const chunks = await repository.listAudioChunks(sessionId);
                  writeJson(res, 201, {
                    chunk,
                    audioChunkCount: chunks.length,
                    repositoryBackend: repository.getBackendKind()
                  });
                })
                .catch((error) => {
                  writeJson(res, 500, {
                    message: error instanceof Error ? error.message : "Unable to register audio chunk."
                  });
                });
            })
            .catch(() => {
              writeJson(res, 400, { message: "Invalid audio chunk payload." });
            });
          return;
        }

        void readRequestBuffer(req)
          .then((body) => {
            const chunkIndex = parseNumericHeader(req, "x-audio-chunk-index");
            const startedAt = readHeaderValue(req, "x-audio-chunk-started-at");
            const endedAt = readHeaderValue(req, "x-audio-chunk-ended-at");
            const mimeType = contentType.split(";")[0].trim() || "application/octet-stream";

            if (chunkIndex === null || !startedAt || !endedAt) {
              writeJson(res, 400, {
                message: "Audio chunk upload requires x-audio-chunk-index, x-audio-chunk-started-at, and x-audio-chunk-ended-at headers."
              });
              return;
            }

            if (body.byteLength === 0) {
              writeJson(res, 400, {
                message: "Audio chunk upload body was empty."
              });
              return;
            }

            const request: HostedAudioChunkUploadRequest = {
              chunkIndex,
              mimeType,
              startedAt,
              endedAt,
              byteLength: body.byteLength
            };

            void audioChunkStorage
              .storeAudioChunk(buildHostedAudioChunkObjectPath(sessionId, chunkIndex, mimeType), mimeType, body)
              .then((storageResult) =>
                repository
                  .registerAudioChunk(sessionId, request)
                  .then(async (chunk) => {
                    const chunks = await repository.listAudioChunks(sessionId);
                    const response: HostedAudioChunkUploadResponse = {
                      chunk,
                      storageMode: storageResult.storageMode,
                      storedBytes: storageResult.storedBytes,
                      storedPath: storageResult.storedPath
                    };
                    writeJson(res, 201, {
                      ...response,
                      audioChunkCount: chunks.length,
                      repositoryBackend: repository.getBackendKind()
                    });
                  })
                  .catch(async (error) => {
                    try {
                      await audioChunkStorage.deleteAudioChunk(
                        buildHostedAudioChunkObjectPath(sessionId, chunkIndex, mimeType)
                      );
                    } catch (cleanupError) {
                      console.warn(
                        `[api] failed to delete orphaned audio chunk ${sessionId}:${chunkIndex}`,
                        cleanupError
                      );
                    }
                    throw error;
                  })
              )
              .catch((error) => {
                writeJson(res, 500, {
                  message: error instanceof Error ? error.message : "Unable to store audio chunk."
                });
              });
          })
          .catch((error) => {
            writeJson(res, 500, {
              message: error instanceof Error ? error.message : "Unable to read audio chunk body."
            });
          });
      })
      .catch((error) => {
        writeJson(res, 500, {
          message: error instanceof Error ? error.message : "Unable to load session."
        });
      });
    return;
  }

  if (sessionSubrouteMatch && req.method === "GET" && sessionSubrouteMatch[2] === "audio-chunks") {
    const sessionId = decodeURIComponent(sessionSubrouteMatch[1]);
    void repository
      .getSession(sessionId)
      .then((session) => {
        if (!sessionMatchesUser(session, userId)) {
          writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
          return;
        }

        return repository.listAudioChunks(sessionId).then((audioChunks) => {
          writeJson(res, 200, {
            sessionId,
            repositoryBackend: repository.getBackendKind(),
            audioChunks
          });
        });
      })
      .catch((error) => {
        writeJson(res, 500, { message: error instanceof Error ? error.message : "Unable to list audio chunks." });
      });
    return;
  }

  if (sessionSubrouteMatch && req.method === "POST" && sessionSubrouteMatch[2] === "model-runs") {
    const sessionId = decodeURIComponent(sessionSubrouteMatch[1]);
    if (!requireInternalApiKey(req, res)) {
      return;
    }
    void readJsonBody<HostedModelRunCreateRequest>(req)
      .then((body) => {
        if (!isModelRunCreateRequest(body)) {
          writeJson(res, 400, { message: "Model run payload is missing required fields." });
          return;
        }

        void repository
          .getSession(sessionId)
          .then((session) => {
            if (!sessionMatchesUser(session, userId)) {
              writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
              return;
            }

            return repository.recordModelRun(sessionId, body).then((modelRun) => {
              writeJson(res, 201, {
                modelRun,
                repositoryBackend: repository.getBackendKind()
              });
            });
          })
          .catch((error) => {
            writeJson(res, 500, {
              message: error instanceof Error ? error.message : "Unable to record model run."
            });
          });
      })
      .catch(() => {
        writeJson(res, 400, { message: "Invalid model run payload." });
      });
    return;
  }

  if (sessionSubrouteMatch && req.method === "GET" && sessionSubrouteMatch[2] === "model-runs") {
    const sessionId = decodeURIComponent(sessionSubrouteMatch[1]);
    void repository
      .getSession(sessionId)
      .then((session) => {
        if (!sessionMatchesUser(session, userId)) {
          writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
          return;
        }

        return repository.listModelRuns(sessionId).then((modelRuns) => {
          writeJson(res, 200, {
            sessionId,
            repositoryBackend: repository.getBackendKind(),
            modelRuns
          });
        });
      })
      .catch((error) => {
        writeJson(res, 500, { message: error instanceof Error ? error.message : "Unable to list model runs." });
      });
    return;
  }

  if (sessionSubrouteMatch && req.method === "POST" && sessionSubrouteMatch[2] === "events") {
    const sessionId = decodeURIComponent(sessionSubrouteMatch[1]);
    if (!requireInternalApiKey(req, res)) {
      return;
    }
    void readJsonBody<HostedSessionEventCreateRequest>(req)
      .then((body) => {
        if (!isSessionEventCreateRequest(body)) {
          writeJson(res, 400, { message: "Session event payload is missing required fields." });
          return;
        }

        void repository
          .getSession(sessionId)
          .then((session) => {
            if (!sessionMatchesUser(session, userId)) {
              writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
              return;
            }

            return repository.appendSessionEvent(sessionId, body).then((event) => {
              writeJson(res, 201, {
                event,
                repositoryBackend: repository.getBackendKind()
              });
            });
          })
          .catch((error) => {
            writeJson(res, 500, {
              message: error instanceof Error ? error.message : "Unable to append session event."
            });
          });
      })
      .catch(() => {
        writeJson(res, 400, { message: "Invalid session event payload." });
      });
    return;
  }

  if (sessionSubrouteMatch && req.method === "POST" && sessionSubrouteMatch[2] === "stop") {
    const sessionId = decodeURIComponent(sessionSubrouteMatch[1]);
    const contentType = readHeaderValue(req, "content-type") ?? "";

    const handleStop = (request?: HostedSessionStopRequest) => {
      void repository
        .getSession(sessionId)
        .then((session) => {
          if (!sessionMatchesUser(session, userId)) {
            writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
            return;
          }

          return repository.stopSession(sessionId, request).then(async (stoppedSession) => {
            const audioChunks = await repository.listAudioChunks(sessionId);
            writeJson(res, 200, {
              session: stoppedSession,
              audioChunkCount: audioChunks.length,
              repositoryBackend: repository.getBackendKind()
            });
          });
        })
        .catch((error) => {
          writeJson(res, 500, {
            message: error instanceof Error ? error.message : "Unable to stop session."
          });
        });
    };

    if (isJsonContentType(contentType)) {
      void readJsonBody<HostedSessionStopRequest>(req)
        .then((body) => {
          if (!isHostedSessionStopRequest(body)) {
            writeJson(res, 400, { message: "Invalid stop session payload." });
            return;
          }

          handleStop(body);
        })
        .catch(() => {
          writeJson(res, 400, { message: "Invalid stop session payload." });
        });
      return;
    }

    handleStop();
    return;
  }

  writeJson(res, 200, {
    service: "voice-to-text-summarizer-api",
    message: "API scaffold is running.",
    routes: [
      "/health",
      "/ready",
      "/metrics",
      "/config",
      "/contracts",
      "/sessions",
      "/sessions/:id",
      "/sessions/:id/transcript",
      "/sessions/:id/stream",
      "/sessions/:id/audio-chunks",
      "/sessions/:id/model-runs",
      "/sessions/:id/events",
      "/sessions/:id/stop"
    ]
  });
});

server.listen(port, () => {
  console.log(`API server ready at http://localhost:${port}`);
  console.log(
    "Hosted scaffold routes: /health, /ready, /metrics, /config, /contracts, /sessions, /sessions/:id, /sessions/:id/transcript, /sessions/:id/stream, /sessions/:id/audio-chunks, /sessions/:id/model-runs, /sessions/:id/events, /sessions/:id/stop"
  );
});
