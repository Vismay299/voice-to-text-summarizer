import { createServer } from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import {
  buildHostedAudioChunkObjectPath,
  buildHostedSessionExportPath,
  HOSTED_ENV_KEYS,
  HOSTED_GCS_PREFIXES,
  HOSTED_POSTGRES_TABLES,
  HOSTED_SERVICE_NAMES,
  HOSTED_SESSION_SOURCES,
  type HostedAudioChunkUploadRequest,
  type HostedAudioChunkUploadResponse,
  type HostedModelRunCreateRequest,
  type HostedModelRunKind,
  type HostedPersistenceSnapshot,
  type HostedSessionCreateRequest,
  type HostedSessionEventCreateRequest,
  type HostedSessionRecord,
  type HostedSessionSource
} from "@voice/shared/hosted";
import { createHostedAudioChunkStorage } from "./audio-storage.js";
import { createHostedRepository } from "./persistence.js";

const port = Number(process.env.API_PORT ?? 8080);
const repository = createHostedRepository();
const audioChunkStorage = createHostedAudioChunkStorage();

function writeJson(res: ServerResponse<IncomingMessage>, statusCode: number, body: unknown) {
  res.writeHead(statusCode, {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type,x-audio-chunk-index,x-audio-chunk-started-at,x-audio-chunk-ended-at",
    "content-type": "application/json"
  });
  res.end(JSON.stringify(body, null, 2));
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

  if (req.method === "OPTIONS") {
    writeJson(res, 204, {});
    return;
  }

  if (url.pathname === "/health") {
    writeJson(res, 200, {
      ok: true,
      service: "api",
      port,
      services: HOSTED_SERVICE_NAMES
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
        transcriptExport: buildHostedSessionExportPath("SESSION_ID", "transcript"),
        summaryExport: buildHostedSessionExportPath("SESSION_ID", "summary")
      },
      uploadContract: {
        route: "POST /sessions/:id/audio-chunks",
        jsonFallback: true,
        binaryHeaders: ["x-audio-chunk-index", "x-audio-chunk-started-at", "x-audio-chunk-ended-at", "content-type"]
      },
      stopContract: "POST /sessions/:id/stop"
    });
    return;
  }

  if (url.pathname === "/sessions" && req.method === "GET") {
    void repository
      .listSessions()
      .then((sessions) => {
        writeJson(res, 200, {
          repositoryBackend: repository.getBackendKind(),
          sessions
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

        void repository
          .createSession({
          userId: body.userId,
          sourceType: body.sourceType
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
  const sessionSubrouteMatch = /^\/sessions\/([^/]+)\/(audio-chunks|model-runs|events|stop)$/.exec(url.pathname);

  if (sessionMatch && req.method === "GET") {
    const sessionId = decodeURIComponent(sessionMatch[1]);
    void repository
      .getSession(sessionId)
      .then(async (session) => {
        const audioChunks = session ? await repository.listAudioChunks(sessionId) : [];
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

  if (sessionSubrouteMatch && req.method === "POST" && sessionSubrouteMatch[2] === "audio-chunks") {
    const sessionId = decodeURIComponent(sessionSubrouteMatch[1]);
    const contentType = readHeaderValue(req, "content-type") ?? "";

    void repository
      .getSession(sessionId)
      .then((session) => {
        if (!session) {
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
                repository.registerAudioChunk(sessionId, request).then(async (chunk) => {
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
        if (!session) {
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
    void readJsonBody<HostedModelRunCreateRequest>(req)
      .then((body) => {
        if (!isModelRunCreateRequest(body)) {
          writeJson(res, 400, { message: "Model run payload is missing required fields." });
          return;
        }

        void repository
          .getSession(sessionId)
          .then((session) => {
            if (!session) {
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
        if (!session) {
          writeJson(res, 404, { message: `Session ${sessionId} does not exist.` });
          return;
        }

        return repository.snapshot().then((snapshot: HostedPersistenceSnapshot) => {
          writeJson(res, 200, {
            sessionId,
            repositoryBackend: repository.getBackendKind(),
            snapshot,
            modelRuns: snapshot.modelRuns.filter((modelRun) => modelRun.sessionId === sessionId)
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
    void readJsonBody<HostedSessionEventCreateRequest>(req)
      .then((body) => {
        if (!isSessionEventCreateRequest(body)) {
          writeJson(res, 400, { message: "Session event payload is missing required fields." });
          return;
        }

        void repository
          .getSession(sessionId)
          .then((session) => {
            if (!session) {
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

    void repository
      .stopSession(sessionId)
      .then(async (session) => {
        const audioChunks = await repository.listAudioChunks(sessionId);
        writeJson(res, 200, {
          session,
          audioChunkCount: audioChunks.length,
          repositoryBackend: repository.getBackendKind()
        });
      })
      .catch((error) => {
        writeJson(res, 500, {
          message: error instanceof Error ? error.message : "Unable to stop session."
        });
      });
    return;
  }

  writeJson(res, 200, {
    service: "voice-to-text-summarizer-api",
    message: "API scaffold is running.",
    routes: [
      "/health",
      "/config",
      "/contracts",
      "/sessions",
      "/sessions/:id",
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
    "Hosted scaffold routes: /health, /config, /contracts, /sessions, /sessions/:id, /sessions/:id/audio-chunks, /sessions/:id/model-runs, /sessions/:id/events, /sessions/:id/stop"
  );
});
