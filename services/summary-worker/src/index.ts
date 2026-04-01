import { HOSTED_ENV_KEYS, HOSTED_SERVICE_NAMES } from "@voice/shared/hosted";

const modelId = process.env[HOSTED_ENV_KEYS.summaryModelId] ?? "Qwen2.5-7B-Instruct";
const pollIntervalMs = Number(process.env.SUMMARY_POLL_INTERVAL_MS ?? 60000);

let heartbeat: ReturnType<typeof setInterval> | null = null;

function startHeartbeat() {
  heartbeat = setInterval(() => {
    console.log(
      `[summary-worker] waiting for transcript windows | model=${modelId} | llm=${process.env[HOSTED_ENV_KEYS.llmServerUrl] ?? "unset"}`
    );
  }, pollIntervalMs);
}

function shutdown(signal: string) {
  if (heartbeat) {
    clearInterval(heartbeat);
    heartbeat = null;
  }

  console.log(`[summary-worker] shutting down from ${signal}`);
  process.exit(0);
}

console.log(`[summary-worker] scaffold ready for ${HOSTED_SERVICE_NAMES[3]}`);
console.log(`[summary-worker] summary model: ${modelId}`);
console.log(`[summary-worker] Pub/Sub subscription: ${process.env[HOSTED_ENV_KEYS.pubsubSummarySubscription] ?? "unset"}`);

startHeartbeat();

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
