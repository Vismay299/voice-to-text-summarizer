import { HOSTED_ENV_KEYS, HOSTED_SERVICE_NAMES } from "@voice/shared/hosted";

const modelId = process.env[HOSTED_ENV_KEYS.asrModelId] ?? "large-v3-turbo";
const pollIntervalMs = Number(process.env.ASR_POLL_INTERVAL_MS ?? 60000);

let heartbeat: ReturnType<typeof setInterval> | null = null;

function startHeartbeat() {
  heartbeat = setInterval(() => {
    console.log(
      `[asr-worker] waiting for audio jobs | model=${modelId} | project=${process.env[HOSTED_ENV_KEYS.gcpProjectId] ?? "unset"}`
    );
  }, pollIntervalMs);
}

function shutdown(signal: string) {
  if (heartbeat) {
    clearInterval(heartbeat);
    heartbeat = null;
  }

  console.log(`[asr-worker] shutting down from ${signal}`);
  process.exit(0);
}

console.log(`[asr-worker] scaffold ready for ${HOSTED_SERVICE_NAMES[2]}`);
console.log(`[asr-worker] ASR model: ${modelId}`);
console.log(`[asr-worker] Pub/Sub subscription: ${process.env[HOSTED_ENV_KEYS.pubsubAsrSubscription] ?? "unset"}`);

startHeartbeat();

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
