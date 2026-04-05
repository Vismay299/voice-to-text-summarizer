import { Pool } from "pg";
import {
  buildHostedAudioChunkObjectPath,
  HOSTED_ENV_KEYS,
  type HostedActionItemRecord,
  type HostedAudioChunkRecord,
  type HostedAudioChunkUploadRequest,
  type HostedModelRunKind,
  type HostedModelRunCreateRequest,
  type HostedModelRunRecord,
  type HostedPersistenceBackend,
  type HostedPersistenceRepository,
  type HostedPersistenceSnapshot,
  type HostedSessionNoteRecord,
  type HostedTranscriptSegmentRecord,
  type HostedSessionCreateRequest,
  type HostedSessionSummaryRecord,
  type HostedSessionStopRequest,
  type HostedSessionEventCreateRequest,
  type HostedSessionEventRecord,
  type HostedSessionRecord,
  type HostedSessionStatus
} from "@voice/shared/hosted";

function createId(prefix: string) {
  return `${prefix}-${Math.random().toString(36).slice(2, 10)}`;
}

function now() {
  return new Date().toISOString();
}

function cloneSession(session: HostedSessionRecord): HostedSessionRecord {
  return {
    ...session,
    metadata: { ...session.metadata }
  };
}

function cloneAudioChunk(chunk: HostedAudioChunkRecord): HostedAudioChunkRecord {
  return {
    ...chunk,
    metadata: { ...chunk.metadata }
  };
}

function cloneModelRun(modelRun: HostedModelRunRecord): HostedModelRunRecord {
  return {
    ...modelRun,
    metadata: { ...modelRun.metadata }
  };
}

function cloneTranscriptSegment(segment: HostedTranscriptSegmentRecord): HostedTranscriptSegmentRecord {
  return {
    ...segment
  };
}

function cloneSessionNote(note: HostedSessionNoteRecord): HostedSessionNoteRecord {
  return {
    ...note,
    sourceSegmentIds: [...note.sourceSegmentIds]
  };
}

function cloneSessionSummary(summary: HostedSessionSummaryRecord): HostedSessionSummaryRecord {
  return {
    ...summary,
    keyPoints: [...summary.keyPoints],
    followUps: [...summary.followUps]
  };
}

function cloneActionItem(actionItem: HostedActionItemRecord): HostedActionItemRecord {
  return {
    ...actionItem
  };
}

function cloneSessionEvent(event: HostedSessionEventRecord): HostedSessionEventRecord {
  return {
    ...event,
    payload: { ...event.payload }
  };
}

function updateSessionStatus(
  session: HostedSessionRecord,
  status: HostedSessionStatus,
  patch: Partial<Pick<HostedSessionRecord, "startedAt" | "endedAt">> = {}
) {
  const updatedAt = now();
  return {
    ...session,
    status,
    updatedAt,
    startedAt: patch.startedAt ?? session.startedAt,
    endedAt: patch.endedAt ?? session.endedAt,
    metadata: { ...session.metadata }
  };
}

function sessionRejectsNewAudio(session: HostedSessionRecord) {
  return session.status === "complete" || session.status === "failed" || session.status === "processing";
}

function buildHostedSessionMetadata(request: HostedSessionCreateRequest) {
  const metadata: Record<string, string | number | boolean | null> = {
    ...(request.metadata ?? {})
  };

  metadata.captureStrategy = request.captureStrategy ?? (request.sourceType === "microphone" ? "microphone" : "display-media-audio");

  if (request.sourceType === "meeting-helper" && request.meetingSurface) {
    metadata.meetingSurface = request.meetingSurface;
  } else {
    delete metadata.meetingSurface;
  }

  return metadata;
}

export class InMemoryHostedRepository implements HostedPersistenceRepository {
  private readonly sessions = new Map<string, HostedSessionRecord>();

  private readonly audioChunksBySession = new Map<string, HostedAudioChunkRecord[]>();

  private readonly modelRunsBySession = new Map<string, HostedModelRunRecord[]>();

  private readonly eventsBySession = new Map<string, HostedSessionEventRecord[]>();

  private readonly transcriptSegments: HostedPersistenceSnapshot["transcriptSegments"] = [];

  private readonly sessionNotes: HostedPersistenceSnapshot["sessionNotes"] = [];

  private readonly sessionSummaries: HostedPersistenceSnapshot["sessionSummaries"] = [];

  private readonly actionItems: HostedPersistenceSnapshot["actionItems"] = [];

  getBackendKind(): HostedPersistenceBackend {
    return "memory";
  }

  async checkHealth() {
    return {
      ok: true,
      backend: "memory" as const,
      detail: "In-memory repository ready.",
      checkedAt: now()
    };
  }

  async createSession(request: HostedSessionCreateRequest): Promise<HostedSessionRecord> {
    const createdAt = now();
    const metadata = buildHostedSessionMetadata(request);
    const session: HostedSessionRecord = {
      id: createId("session"),
      userId: request.userId ?? "demo-user",
      sourceType: request.sourceType,
      status: "starting",
      createdAt,
      updatedAt: createdAt,
      startedAt: null,
      endedAt: null,
      metadata
    };

    this.sessions.set(session.id, session);
    await this.appendSessionEvent(session.id, {
      type: "session.created",
      payload: {
        sourceType: request.sourceType,
        userId: session.userId,
        metadata
      }
    });

    return cloneSession(session);
  }

  async getSession(sessionId: string): Promise<HostedSessionRecord | null> {
    return this.sessions.get(sessionId) ? cloneSession(this.sessions.get(sessionId) as HostedSessionRecord) : null;
  }

  async listSessions(): Promise<readonly HostedSessionRecord[]> {
    return [...this.sessions.values()]
      .map((session) => cloneSession(session))
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }

  async listTranscriptSegments(sessionId: string, sinceSequenceNumber?: number): Promise<readonly HostedTranscriptSegmentRecord[]> {
    return [...this.transcriptSegments]
      .filter((segment) => segment.sessionId === sessionId)
      .filter((segment) => sinceSequenceNumber === undefined || segment.sequenceNumber > sinceSequenceNumber)
      .map((segment) => cloneTranscriptSegment(segment))
      .sort((a, b) => a.sequenceNumber - b.sequenceNumber);
  }

  async listSessionNotes(sessionId: string): Promise<readonly HostedSessionNoteRecord[]> {
    return [...this.sessionNotes]
      .filter((note) => note.sessionId === sessionId)
      .map((note) => cloneSessionNote(note))
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  async listSessionSummaries(sessionId: string): Promise<readonly HostedSessionSummaryRecord[]> {
    return [...this.sessionSummaries]
      .filter((summary) => summary.sessionId === sessionId)
      .map((summary) => cloneSessionSummary(summary))
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  async listActionItems(sessionId: string): Promise<readonly HostedActionItemRecord[]> {
    return [...this.actionItems]
      .filter((actionItem) => actionItem.sessionId === sessionId)
      .map((actionItem) => cloneActionItem(actionItem))
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  async registerAudioChunk(sessionId: string, request: HostedAudioChunkUploadRequest): Promise<HostedAudioChunkRecord> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`Session ${sessionId} does not exist.`);
    }
    if (sessionRejectsNewAudio(session)) {
      throw new Error(`Session ${sessionId} is no longer accepting audio chunks.`);
    }

    const chunkId = `${sessionId}-chunk-${String(request.chunkIndex).padStart(6, "0")}`;
    const existingChunks = this.audioChunksBySession.get(sessionId) ?? [];
    const existingChunk = existingChunks.find((chunk) => chunk.chunkIndex === request.chunkIndex);
    if (existingChunk) {
      return cloneAudioChunk(existingChunk);
    }

    const createdAt = now();
    const chunk: HostedAudioChunkRecord = {
      id: chunkId,
      sessionId,
      chunkIndex: request.chunkIndex,
      mimeType: request.mimeType,
      startedAt: request.startedAt,
      endedAt: request.endedAt,
      objectPath: buildHostedAudioChunkObjectPath(sessionId, request.chunkIndex, request.mimeType),
      status: "complete",
      createdAt,
      metadata: request.byteLength !== undefined ? { byteLength: request.byteLength } : {}
    };

    this.audioChunksBySession.set(sessionId, [...existingChunks, chunk]);
    this.sessions.set(
      sessionId,
      updateSessionStatus(session, "recording", {
        startedAt: session.startedAt ?? request.startedAt
      })
    );
    await this.appendSessionEvent(sessionId, {
      type: "audio-chunk.registered",
      payload: {
        chunkId: chunk.id,
        chunkIndex: request.chunkIndex,
        mimeType: request.mimeType,
        objectPath: chunk.objectPath
      }
    });

    return cloneAudioChunk(chunk);
  }

  async listAudioChunks(sessionId: string): Promise<readonly HostedAudioChunkRecord[]> {
    return [...(this.audioChunksBySession.get(sessionId) ?? [])]
      .map((chunk) => cloneAudioChunk(chunk))
      .sort((a, b) => a.chunkIndex - b.chunkIndex);
  }

  async listModelRuns(sessionId: string): Promise<readonly HostedModelRunRecord[]> {
    return [...(this.modelRunsBySession.get(sessionId) ?? [])]
      .map((modelRun) => cloneModelRun(modelRun))
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  async stopSession(sessionId: string, request?: HostedSessionStopRequest): Promise<HostedSessionRecord> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`Session ${sessionId} does not exist.`);
    }

    const requestedStatus = request?.status ?? "complete";
    const endedAt = now();
    const existingChunks = this.audioChunksBySession.get(sessionId) ?? [];
    const uploadedChunkCount = existingChunks.filter((chunk) => chunk.status !== "failed").length;
    let terminalizedChunkCount = 0;
    if (requestedStatus === "failed") {
      this.audioChunksBySession.set(
        sessionId,
        existingChunks.map((chunk) => {
          if (chunk.status !== "registered" && chunk.status !== "queued") {
            return chunk;
          }
          terminalizedChunkCount += 1;
          return {
            ...chunk,
            status: "failed",
            metadata: {
              ...chunk.metadata,
              failedAt: endedAt,
              errorMessage: request?.errorMessage ?? "Session stopped before queued chunks could be transcribed."
            }
          };
        })
      );
    }
    const pendingChunkCount = 0;
    const status = requestedStatus === "failed" ? "failed" : uploadedChunkCount > 0 ? "processing" : "complete";
    const metadata = { ...session.metadata };
    metadata.captureStoppedAt = endedAt;
    metadata.awaitingFinalTranscript = requestedStatus === "complete" && uploadedChunkCount > 0;
    if (request?.errorMessage && request.errorMessage.trim().length > 0) {
      metadata.errorMessage = request.errorMessage;
    } else if (requestedStatus !== "failed") {
      delete metadata.errorMessage;
    }
    const updated = {
      ...updateSessionStatus(session, status, {
        startedAt: session.startedAt ?? session.createdAt,
        endedAt
      }),
      metadata
    };
    this.sessions.set(sessionId, updated);
    await this.appendSessionEvent(sessionId, {
      type: "session.updated",
      payload: {
        requestedStatus,
        status,
        endedAt,
        pendingChunkCount,
        uploadedChunkCount,
        terminalizedChunkCount,
        errorMessage: request?.errorMessage ?? null
      }
    });
    return cloneSession(updated);
  }

  async reprocessFinalAsrSession(sessionId: string): Promise<HostedSessionRecord> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`Session ${sessionId} does not exist.`);
    }
    if (!session.endedAt) {
      throw new Error(`Session ${sessionId} has not finished recording yet.`);
    }

    const audioChunks = this.audioChunksBySession.get(sessionId) ?? [];
    if (audioChunks.length === 0) {
      throw new Error(`Session ${sessionId} has no uploaded audio chunks to reprocess.`);
    }

    const transcriptSegmentCount = this.transcriptSegments.filter((segment) => segment.sessionId === sessionId).length;
    if (transcriptSegmentCount > 0) {
      throw new Error(`Session ${sessionId} already has transcript segments and is not eligible for empty-session reprocessing.`);
    }

    const reprocessRequestedAt = now();
    const updated: HostedSessionRecord = {
      ...updateSessionStatus(session, "processing"),
      metadata: {
        ...session.metadata,
        awaitingFinalTranscript: true,
        forceRetranscribe: true,
        reprocessRequestedAt
      }
    };
    delete updated.metadata.errorMessage;
    this.sessions.set(sessionId, updated);
    await this.appendSessionEvent(sessionId, {
      type: "session.updated",
      payload: {
        status: "processing",
        reprocessRequestedAt,
        reason: "empty-transcript-retry"
      }
    });
    return cloneSession(updated);
  }

  async recordModelRun(sessionId: string, request: HostedModelRunCreateRequest): Promise<HostedModelRunRecord> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`Session ${sessionId} does not exist.`);
    }

    const startedAt = request.startedAt ?? now();
    const modelRun: HostedModelRunRecord = {
      id: createId("model-run"),
      sessionId,
      kind: request.kind,
      modelId: request.modelId,
      runtime: request.runtime,
      status: "running",
      inputRef: request.inputRef ?? null,
      createdAt: startedAt,
      startedAt,
      completedAt: null,
      latencyMs: null,
      errorMessage: null,
      metadata: { ...(request.metadata ?? {}) }
    };

    const existingRuns = this.modelRunsBySession.get(sessionId) ?? [];
    this.modelRunsBySession.set(sessionId, [...existingRuns, modelRun]);
    this.sessions.set(sessionId, updateSessionStatus(session, "processing"));
    await this.appendSessionEvent(sessionId, {
      type: "model-run.created",
      payload: {
        modelRunId: modelRun.id,
        kind: request.kind,
        modelId: request.modelId,
        runtime: request.runtime
      }
    });

    return cloneModelRun(modelRun);
  }

  async appendSessionEvent(sessionId: string, request: HostedSessionEventCreateRequest): Promise<HostedSessionEventRecord> {
    const event: HostedSessionEventRecord = {
      id: createId("event"),
      sessionId,
      type: request.type,
      createdAt: now(),
      payload: { ...request.payload }
    };

    const existingEvents = this.eventsBySession.get(sessionId) ?? [];
    this.eventsBySession.set(sessionId, [...existingEvents, event]);
    return cloneSessionEvent(event);
  }

  async snapshot(): Promise<HostedPersistenceSnapshot> {
    return {
      sessions: await this.listSessions(),
      audioChunks: [...this.audioChunksBySession.values()].flat().map((chunk) => cloneAudioChunk(chunk)),
      transcriptSegments: [...this.transcriptSegments],
      sessionNotes: [...this.sessionNotes],
      sessionSummaries: [...this.sessionSummaries],
      actionItems: [...this.actionItems],
      modelRuns: [...this.modelRunsBySession.values()].flat().map((modelRun) => cloneModelRun(modelRun)),
      sessionEvents: [...this.eventsBySession.values()].flat().map((event) => cloneSessionEvent(event))
    };
  }
}

function mapSessionRow(row: Record<string, unknown>): HostedSessionRecord {
  return {
    id: String(row.id),
    userId: String(row.user_id),
    sourceType: String(row.source_type) as HostedSessionRecord["sourceType"],
    status: String(row.status) as HostedSessionStatus,
    createdAt: new Date(String(row.created_at)).toISOString(),
    updatedAt: new Date(String(row.updated_at)).toISOString(),
    startedAt: row.started_at ? new Date(String(row.started_at)).toISOString() : null,
    endedAt: row.ended_at ? new Date(String(row.ended_at)).toISOString() : null,
    metadata: ((row.metadata ?? {}) as Record<string, string | number | boolean | null>) ?? {}
  };
}

function mapAudioChunkRow(row: Record<string, unknown>): HostedAudioChunkRecord {
  return {
    id: String(row.id),
    sessionId: String(row.session_id),
    chunkIndex: Number(row.chunk_index),
    mimeType: String(row.mime_type),
    startedAt: new Date(String(row.started_at)).toISOString(),
    endedAt: new Date(String(row.ended_at)).toISOString(),
    objectPath: String(row.object_path),
    status: String(row.status) as HostedAudioChunkRecord["status"],
    createdAt: new Date(String(row.created_at)).toISOString(),
    metadata: ((row.metadata ?? {}) as Record<string, string | number | boolean | null>) ?? {}
  };
}

function mapModelRunRow(row: Record<string, unknown>): HostedModelRunRecord {
  return {
    id: String(row.id),
    sessionId: String(row.session_id),
    kind: String(row.kind) as HostedModelRunKind,
    modelId: String(row.model_id),
    runtime: String(row.runtime),
    status: String(row.status) as HostedModelRunRecord["status"],
    inputRef: row.input_ref ? String(row.input_ref) : null,
    createdAt: new Date(String(row.created_at)).toISOString(),
    startedAt: new Date(String(row.started_at)).toISOString(),
    completedAt: row.completed_at ? new Date(String(row.completed_at)).toISOString() : null,
    latencyMs: row.latency_ms === null || row.latency_ms === undefined ? null : Number(row.latency_ms),
    errorMessage: row.error_message ? String(row.error_message) : null,
    metadata: ((row.metadata ?? {}) as Record<string, string | number | boolean | null>) ?? {}
  };
}

function mapTranscriptSegmentRow(row: Record<string, unknown>): HostedTranscriptSegmentRecord {
  return {
    id: String(row.id),
    sessionId: String(row.session_id),
    audioChunkId: row.audio_chunk_id ? String(row.audio_chunk_id) : null,
    modelRunId: row.model_run_id ? String(row.model_run_id) : null,
    sequenceNumber: Number(row.sequence_number),
    speakerLabel: row.speaker_label ? String(row.speaker_label) : null,
    text: String(row.text),
    startMs: Number(row.start_ms),
    endMs: Number(row.end_ms),
    confidence: row.confidence === null || row.confidence === undefined ? null : Number(row.confidence),
    createdAt: new Date(String(row.created_at)).toISOString()
  };
}

function mapSessionNoteRow(row: Record<string, unknown>): HostedSessionNoteRecord {
  return {
    id: String(row.id),
    sessionId: String(row.session_id),
    modelRunId: row.model_run_id ? String(row.model_run_id) : null,
    sourceSegmentIds: Array.isArray(row.source_segment_ids) ? (row.source_segment_ids as string[]) : [],
    text: String(row.text),
    createdAt: new Date(String(row.created_at)).toISOString()
  };
}

function mapSessionSummaryRow(row: Record<string, unknown>): HostedSessionSummaryRecord {
  return {
    id: String(row.id),
    sessionId: String(row.session_id),
    modelRunId: row.model_run_id ? String(row.model_run_id) : null,
    overview: String(row.overview),
    keyPoints: Array.isArray(row.key_points) ? (row.key_points as string[]) : [],
    followUps: Array.isArray(row.follow_ups) ? (row.follow_ups as string[]) : [],
    createdAt: new Date(String(row.created_at)).toISOString()
  };
}

function mapActionItemRow(row: Record<string, unknown>): HostedActionItemRecord {
  return {
    id: String(row.id),
    sessionId: String(row.session_id),
    sourceSummaryId: row.source_summary_id ? String(row.source_summary_id) : null,
    text: String(row.text),
    status: String(row.status) as HostedActionItemRecord["status"],
    createdAt: new Date(String(row.created_at)).toISOString()
  };
}

function mapSessionEventRow(row: Record<string, unknown>): HostedSessionEventRecord {
  return {
    id: String(row.id),
    sessionId: String(row.session_id),
    type: String(row.type) as HostedSessionEventRecord["type"],
    createdAt: new Date(String(row.created_at)).toISOString(),
    payload: ((row.payload ?? {}) as Record<string, unknown>) ?? {}
  };
}

export class PostgresHostedRepository implements HostedPersistenceRepository {
  constructor(private readonly pool: Pool) {}

  getBackendKind(): HostedPersistenceBackend {
    return "postgres";
  }

  async checkHealth() {
    const checkedAt = now();

    try {
      await this.pool.query("SELECT 1");
      return {
        ok: true,
        backend: "postgres" as const,
        detail: "PostgreSQL repository ready.",
        checkedAt
      };
    } catch (error) {
      return {
        ok: false,
        backend: "postgres" as const,
        detail: error instanceof Error ? error.message : "PostgreSQL repository unavailable.",
        checkedAt
      };
    }
  }

  async createSession(request: HostedSessionCreateRequest): Promise<HostedSessionRecord> {
    const client = await this.pool.connect();
    const sessionId = createId("session");
    const userId = request.userId ?? "demo-user";
    const metadata = buildHostedSessionMetadata(request);

    try {
      await client.query("BEGIN");
      await client.query(
        `
          INSERT INTO users (id, display_name, email, metadata)
          VALUES ($1, NULL, NULL, '{}'::jsonb)
          ON CONFLICT (id) DO NOTHING
        `,
        [userId]
      );
      const sessionResult = await client.query(
        `
          INSERT INTO sessions (
            id, user_id, source_type, status, metadata
          )
          VALUES ($1, $2, $3, 'starting', $4::jsonb)
          RETURNING *
        `,
        [sessionId, userId, request.sourceType, JSON.stringify(metadata)]
      );
      await client.query(
        `
          INSERT INTO session_events (id, session_id, type, payload)
          VALUES ($1, $2, 'session.created', $3::jsonb)
        `,
        [
          createId("event"),
          sessionId,
          JSON.stringify({
            sourceType: request.sourceType,
            userId,
            metadata
          })
        ]
      );
      await client.query("COMMIT");
      return mapSessionRow(sessionResult.rows[0] as Record<string, unknown>);
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async getSession(sessionId: string): Promise<HostedSessionRecord | null> {
    const result = await this.pool.query("SELECT * FROM sessions WHERE id = $1", [sessionId]);
    return result.rows[0] ? mapSessionRow(result.rows[0] as Record<string, unknown>) : null;
  }

  async listSessions(): Promise<readonly HostedSessionRecord[]> {
    const result = await this.pool.query("SELECT * FROM sessions ORDER BY created_at DESC");
    return result.rows.map((row) => mapSessionRow(row as Record<string, unknown>));
  }

  async listTranscriptSegments(sessionId: string, sinceSequenceNumber?: number): Promise<readonly HostedTranscriptSegmentRecord[]> {
    const params: Array<string | number> = [sessionId];
    let query = "SELECT * FROM transcript_segments WHERE session_id = $1";

    if (sinceSequenceNumber !== undefined) {
      params.push(sinceSequenceNumber);
      query += " AND sequence_number > $2";
    }

    query += " ORDER BY sequence_number ASC";
    const result = await this.pool.query(query, params);
    return result.rows.map((row) => mapTranscriptSegmentRow(row as Record<string, unknown>));
  }

  async listSessionNotes(sessionId: string): Promise<readonly HostedSessionNoteRecord[]> {
    const result = await this.pool.query(
      "SELECT * FROM session_notes WHERE session_id = $1 ORDER BY created_at ASC",
      [sessionId]
    );
    return result.rows.map((row) => mapSessionNoteRow(row as Record<string, unknown>));
  }

  async listSessionSummaries(sessionId: string): Promise<readonly HostedSessionSummaryRecord[]> {
    const result = await this.pool.query(
      "SELECT * FROM session_summaries WHERE session_id = $1 ORDER BY created_at ASC",
      [sessionId]
    );
    return result.rows.map((row) => mapSessionSummaryRow(row as Record<string, unknown>));
  }

  async listActionItems(sessionId: string): Promise<readonly HostedActionItemRecord[]> {
    const result = await this.pool.query(
      "SELECT * FROM action_items WHERE session_id = $1 ORDER BY created_at ASC",
      [sessionId]
    );
    return result.rows.map((row) => mapActionItemRow(row as Record<string, unknown>));
  }

  async registerAudioChunk(sessionId: string, request: HostedAudioChunkUploadRequest): Promise<HostedAudioChunkRecord> {
    const client = await this.pool.connect();
    const chunkId = `${sessionId}-chunk-${String(request.chunkIndex).padStart(6, "0")}`;
    const objectPath = buildHostedAudioChunkObjectPath(sessionId, request.chunkIndex, request.mimeType);

    try {
      await client.query("BEGIN");
      const sessionResult = await client.query("SELECT * FROM sessions WHERE id = $1 FOR UPDATE", [sessionId]);
      const session = sessionResult.rows[0];
      if (!session) {
        throw new Error(`Session ${sessionId} does not exist.`);
      }
      const mappedSession = mapSessionRow(session as Record<string, unknown>);
      if (sessionRejectsNewAudio(mappedSession)) {
        throw new Error(`Session ${sessionId} is no longer accepting audio chunks.`);
      }

      const existingChunkResult = await client.query(
        "SELECT * FROM audio_chunks WHERE session_id = $1 AND chunk_index = $2",
        [sessionId, request.chunkIndex]
      );
      if (existingChunkResult.rows[0]) {
        await client.query("COMMIT");
        return mapAudioChunkRow(existingChunkResult.rows[0] as Record<string, unknown>);
      }

      const chunkResult = await client.query(
        `
          INSERT INTO audio_chunks (
            id, session_id, chunk_index, mime_type, started_at, ended_at, object_path, status, metadata
          )
          VALUES ($1, $2, $3, $4, $5, $6, $7, 'complete', $8::jsonb)
          RETURNING *
        `,
        [
          chunkId,
          sessionId,
          request.chunkIndex,
          request.mimeType,
          request.startedAt,
          request.endedAt,
          objectPath,
          JSON.stringify(request.byteLength !== undefined ? { byteLength: request.byteLength } : {})
        ]
      );

      await client.query(
        `
          UPDATE sessions
          SET
            status = 'recording',
            updated_at = NOW(),
            started_at = COALESCE(started_at, $2::timestamptz)
          WHERE id = $1
        `,
        [sessionId, request.startedAt]
      );

      await client.query(
        `
          INSERT INTO session_events (id, session_id, type, payload)
          VALUES ($1, $2, 'audio-chunk.registered', $3::jsonb)
        `,
        [
          createId("event"),
          sessionId,
          JSON.stringify({
            chunkId,
            chunkIndex: request.chunkIndex,
            mimeType: request.mimeType,
            objectPath
          })
        ]
      );

      await client.query("COMMIT");
      return mapAudioChunkRow(chunkResult.rows[0] as Record<string, unknown>);
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async listAudioChunks(sessionId: string): Promise<readonly HostedAudioChunkRecord[]> {
    const result = await this.pool.query(
      "SELECT * FROM audio_chunks WHERE session_id = $1 ORDER BY chunk_index ASC",
      [sessionId]
    );
    return result.rows.map((row) => mapAudioChunkRow(row as Record<string, unknown>));
  }

  async listModelRuns(sessionId: string): Promise<readonly HostedModelRunRecord[]> {
    const result = await this.pool.query(
      "SELECT * FROM model_runs WHERE session_id = $1 ORDER BY created_at ASC",
      [sessionId]
    );
    return result.rows.map((row) => mapModelRunRow(row as Record<string, unknown>));
  }

  async stopSession(sessionId: string, request?: HostedSessionStopRequest): Promise<HostedSessionRecord> {
    const client = await this.pool.connect();

    try {
      await client.query("BEGIN");
      const sessionResult = await client.query("SELECT * FROM sessions WHERE id = $1 FOR UPDATE", [sessionId]);
      const session = sessionResult.rows[0];
      if (!session) {
        throw new Error(`Session ${sessionId} does not exist.`);
      }

      const requestedStatus = request?.status ?? "complete";
      const endedAt = now();
      const terminalizedChunkResult =
        requestedStatus === "failed"
          ? await client.query(
              `
                UPDATE audio_chunks
                SET status = 'failed',
                    metadata = COALESCE(metadata, '{}'::jsonb)
                      || jsonb_build_object(
                           'failedAt', $2::text,
                           'errorMessage', $3::text
                         )
                WHERE session_id = $1
                  AND status IN ('registered', 'queued')
                RETURNING id
              `,
              [
                sessionId,
                endedAt,
                request?.errorMessage ?? "Session stopped before queued chunks could be transcribed."
              ]
            )
          : { rowCount: 0 };
      const terminalizedChunkCount = Number(terminalizedChunkResult.rowCount ?? 0);
      const uploadedChunkResult =
        requestedStatus === "complete"
          ? await client.query(
              `
                SELECT COUNT(*)::int AS uploaded_chunk_count
                FROM audio_chunks
                WHERE session_id = $1
                  AND status != 'failed'
              `,
              [sessionId]
            )
          : { rows: [{ uploaded_chunk_count: 0 }] };
      const uploadedChunkCount = Number(uploadedChunkResult.rows[0]?.uploaded_chunk_count ?? 0);
      const pendingChunkCount = 0;
      const status = requestedStatus === "failed" ? "failed" : uploadedChunkCount > 0 ? "processing" : "complete";
      const metadata: Record<string, string | number | boolean | null> = {
        ...(((session.metadata ?? {}) as Record<string, string | number | boolean | null>) ?? {}),
        captureStoppedAt: endedAt
      };
      metadata.awaitingFinalTranscript = requestedStatus === "complete" && uploadedChunkCount > 0;
      if (request?.errorMessage && request.errorMessage.trim().length > 0) {
        metadata.errorMessage = request.errorMessage;
      } else if (requestedStatus !== "failed") {
        delete metadata.errorMessage;
      }
      const stoppedResult = await client.query(
        `
          UPDATE sessions
          SET status = $3,
              started_at = COALESCE(started_at, created_at),
              ended_at = $2::timestamptz,
              metadata = $4::jsonb,
              updated_at = NOW()
          WHERE id = $1
          RETURNING *
        `,
        [sessionId, endedAt, status, JSON.stringify(metadata)]
      );

      await client.query(
        `
          INSERT INTO session_events (id, session_id, type, payload)
          VALUES ($1, $2, 'session.updated', $3::jsonb)
        `,
        [
          createId("event"),
          sessionId,
          JSON.stringify({
            requestedStatus,
            status,
            endedAt,
            pendingChunkCount,
            uploadedChunkCount,
            terminalizedChunkCount,
            errorMessage: request?.errorMessage ?? null
          })
        ]
      );

      await client.query("COMMIT");
      return mapSessionRow(stoppedResult.rows[0] as Record<string, unknown>);
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async reprocessFinalAsrSession(sessionId: string): Promise<HostedSessionRecord> {
    const client = await this.pool.connect();

    try {
      await client.query("BEGIN");
      const sessionResult = await client.query("SELECT * FROM sessions WHERE id = $1 FOR UPDATE", [sessionId]);
      const session = sessionResult.rows[0];
      if (!session) {
        throw new Error(`Session ${sessionId} does not exist.`);
      }
      if (!session.ended_at) {
        throw new Error(`Session ${sessionId} has not finished recording yet.`);
      }

      const audioChunkResult = await client.query(
        `
          SELECT COUNT(*)::int AS audio_chunk_count
          FROM audio_chunks
          WHERE session_id = $1
        `,
        [sessionId]
      );
      const audioChunkCount = Number(audioChunkResult.rows[0]?.audio_chunk_count ?? 0);
      if (audioChunkCount === 0) {
        throw new Error(`Session ${sessionId} has no uploaded audio chunks to reprocess.`);
      }

      const transcriptResult = await client.query(
        `
          SELECT COUNT(*)::int AS transcript_segment_count
          FROM transcript_segments
          WHERE session_id = $1
        `,
        [sessionId]
      );
      const transcriptSegmentCount = Number(transcriptResult.rows[0]?.transcript_segment_count ?? 0);
      if (transcriptSegmentCount > 0) {
        throw new Error(`Session ${sessionId} already has transcript segments and is not eligible for empty-session reprocessing.`);
      }

      const reprocessRequestedAt = now();
      const metadata: Record<string, string | number | boolean | null> = {
        ...(((session.metadata ?? {}) as Record<string, string | number | boolean | null>) ?? {}),
        awaitingFinalTranscript: true,
        forceRetranscribe: true,
        reprocessRequestedAt
      };
      delete metadata.errorMessage;

      const updatedResult = await client.query(
        `
          UPDATE sessions
          SET status = 'processing',
              metadata = $2::jsonb,
              updated_at = NOW()
          WHERE id = $1
          RETURNING *
        `,
        [sessionId, JSON.stringify(metadata)]
      );

      await client.query(
        `
          INSERT INTO session_events (id, session_id, type, payload)
          VALUES ($1, $2, 'session.updated', $3::jsonb)
        `,
        [
          createId("event"),
          sessionId,
          JSON.stringify({
            status: "processing",
            reprocessRequestedAt,
            reason: "empty-transcript-retry"
          })
        ]
      );

      await client.query("COMMIT");
      return mapSessionRow(updatedResult.rows[0] as Record<string, unknown>);
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async recordModelRun(sessionId: string, request: HostedModelRunCreateRequest): Promise<HostedModelRunRecord> {
    const client = await this.pool.connect();
    const modelRunId = createId("model-run");
    const startedAt = request.startedAt ?? now();

    try {
      await client.query("BEGIN");
      const sessionResult = await client.query("SELECT * FROM sessions WHERE id = $1 FOR UPDATE", [sessionId]);
      if (!sessionResult.rows[0]) {
        throw new Error(`Session ${sessionId} does not exist.`);
      }

      const modelRunResult = await client.query(
        `
          INSERT INTO model_runs (
            id, session_id, kind, model_id, runtime, status, input_ref, started_at, metadata
          )
          VALUES ($1, $2, $3, $4, $5, 'running', $6, $7, $8::jsonb)
          RETURNING *
        `,
        [
          modelRunId,
          sessionId,
          request.kind,
          request.modelId,
          request.runtime,
          request.inputRef ?? null,
          startedAt,
          JSON.stringify(request.metadata ?? {})
        ]
      );

      await client.query(
        `
          UPDATE sessions
          SET status = 'processing', updated_at = NOW()
          WHERE id = $1
        `,
        [sessionId]
      );

      await client.query(
        `
          INSERT INTO session_events (id, session_id, type, payload)
          VALUES ($1, $2, 'model-run.created', $3::jsonb)
        `,
        [
          createId("event"),
          sessionId,
          JSON.stringify({
            modelRunId,
            kind: request.kind,
            modelId: request.modelId,
            runtime: request.runtime
          })
        ]
      );

      await client.query("COMMIT");
      return mapModelRunRow(modelRunResult.rows[0] as Record<string, unknown>);
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async appendSessionEvent(sessionId: string, request: HostedSessionEventCreateRequest): Promise<HostedSessionEventRecord> {
    const result = await this.pool.query(
      `
        INSERT INTO session_events (id, session_id, type, payload)
        VALUES ($1, $2, $3, $4::jsonb)
        RETURNING *
      `,
      [createId("event"), sessionId, request.type, JSON.stringify(request.payload)]
    );
    return mapSessionEventRow(result.rows[0] as Record<string, unknown>);
  }

  async snapshot(): Promise<HostedPersistenceSnapshot> {
    const [sessions, audioChunks, transcriptSegments, sessionNotes, sessionSummaries, actionItems, modelRuns, sessionEvents] =
      await Promise.all([
        this.pool.query("SELECT * FROM sessions ORDER BY created_at DESC"),
        this.pool.query("SELECT * FROM audio_chunks ORDER BY created_at DESC"),
        this.pool.query("SELECT * FROM transcript_segments ORDER BY created_at DESC"),
        this.pool.query("SELECT * FROM session_notes ORDER BY created_at DESC"),
        this.pool.query("SELECT * FROM session_summaries ORDER BY created_at DESC"),
        this.pool.query("SELECT * FROM action_items ORDER BY created_at DESC"),
        this.pool.query("SELECT * FROM model_runs ORDER BY created_at DESC"),
        this.pool.query("SELECT * FROM session_events ORDER BY created_at DESC")
      ]);

    return {
      sessions: sessions.rows.map((row) => mapSessionRow(row as Record<string, unknown>)),
      audioChunks: audioChunks.rows.map((row) => mapAudioChunkRow(row as Record<string, unknown>)),
      transcriptSegments: transcriptSegments.rows.map((row) => mapTranscriptSegmentRow(row as Record<string, unknown>)),
      sessionNotes: sessionNotes.rows.map((row) => mapSessionNoteRow(row as Record<string, unknown>)),
      sessionSummaries: sessionSummaries.rows.map((row) => mapSessionSummaryRow(row as Record<string, unknown>)),
      actionItems: actionItems.rows.map((row) => mapActionItemRow(row as Record<string, unknown>)),
      modelRuns: modelRuns.rows.map((row) => mapModelRunRow(row as Record<string, unknown>)),
      sessionEvents: sessionEvents.rows.map((row) => mapSessionEventRow(row as Record<string, unknown>))
    };
  }
}

export function createHostedRepository(): HostedPersistenceRepository {
  const postgresUrl = process.env[HOSTED_ENV_KEYS.postgresUrl];
  if (!postgresUrl) {
    return new InMemoryHostedRepository();
  }

  const pool = new Pool({
    connectionString: postgresUrl
  });

  return new PostgresHostedRepository(pool);
}
