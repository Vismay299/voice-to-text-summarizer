# Cloud Run Baseline

This directory captures the Series 1 deployment baseline for the hosted rebuild.

## Services

- `voice-api` -> `apps/api/Dockerfile`
- `voice-asr-worker` -> `services/asr-worker/Dockerfile`
- `voice-summary-worker` -> `services/summary-worker/Dockerfile`

## Required GCP Services

- Cloud Run
- Cloud SQL for PostgreSQL
- Cloud Storage
- Pub/Sub
- Secret Manager

## Baseline Environment Variables

All services should read from the root `.env.example` as the local contract source.

Cloud Run service mapping:

- `voice-api`
  - `API_PORT`
  - `POSTGRES_URL`
  - `GCS_BUCKET_NAME`
  - `PUBSUB_TOPIC_ASR`
  - `PUBSUB_TOPIC_SUMMARY`
  - `GCP_PROJECT_ID`
  - `GCP_REGION`

- `voice-asr-worker`
  - `ASR_MODEL_ID`
  - `ASR_POLL_INTERVAL_MS`
  - `ASR_CLAIM_TIMEOUT_MS`
  - `ASR_LANGUAGE`
  - `ASR_DEVICE`
  - `ASR_COMPUTE_TYPE`
  - `ASR_BEAM_SIZE`
  - `ASR_VAD_FILTER`
  - `ASR_NORMALIZE_AUDIO`
  - `ASR_NORMALIZATION_FILTER`
  - `PUBSUB_SUBSCRIPTION_ASR`
  - `GCP_PROJECT_ID`
  - `GCP_REGION`
  - `GCS_BUCKET_NAME`
  - `HOSTED_LOCAL_AUDIO_DIR`
  - `POSTGRES_URL`

- `voice-summary-worker`
  - `SUMMARY_MODEL_ID`
  - `SUMMARY_POLL_INTERVAL_MS`
  - `SUMMARY_CLAIM_TIMEOUT_MS`
  - `SUMMARY_NOTE_WINDOW_SEGMENTS`
  - `SUMMARY_MAX_TRANSCRIPT_CHARS`
  - `LLM_SERVER_URL`
  - `PUBSUB_SUBSCRIPTION_SUMMARY`
  - `GCP_PROJECT_ID`
  - `GCP_REGION`
  - `POSTGRES_URL`

## Example Build Commands

From the repo root:

```bash
docker build -f apps/api/Dockerfile -t "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/voice-to-text/voice-api:series-1" .
docker build -f services/asr-worker/Dockerfile -t "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/voice-to-text/voice-asr-worker:series-1" .
docker build -f services/summary-worker/Dockerfile -t "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/voice-to-text/voice-summary-worker:series-1" .
```

Push the images after they build:

```bash
docker push "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/voice-to-text/voice-api:series-1"
docker push "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/voice-to-text/voice-asr-worker:series-1"
docker push "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/voice-to-text/voice-summary-worker:series-1"
```

## Example Cloud Run Deploy Skeleton

```bash
gcloud run deploy voice-api \
  --image "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/voice-to-text/voice-api:series-1" \
  --region "$GCP_REGION" \
  --set-env-vars API_PORT=8080

gcloud run deploy voice-asr-worker \
  --image "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/voice-to-text/voice-asr-worker:series-1" \
  --region "$GCP_REGION"

gcloud run deploy voice-summary-worker \
  --image "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/voice-to-text/voice-summary-worker:series-1" \
  --region "$GCP_REGION"
```

These commands are only a baseline skeleton for the hosted rebuild. They intentionally assume:

- an Artifact Registry repository named `voice-to-text`
- prebuilt and pushed images
- manual environment variable wiring for now

For Series 4, the ASR worker now runs as a Python `faster-whisper` process that polls Cloud SQL for the next claimable chunk, resolves audio from GCS or the dev filesystem mirror, and writes transcript segments back into Postgres. It also requeues stale `processing` claims after `ASR_CLAIM_TIMEOUT_MS` so a dead worker does not strand audio forever. Pub/Sub remains a later transport optimization, but the first working inference path is the database-backed poller so the end-to-end transcription loop can be validated before transport hardening.

For Series 6, the summary worker now polls Cloud SQL for sessions with new transcript windows, persists live notes plus final summaries/action items, and reclaims stale `running` summary jobs after `SUMMARY_CLAIM_TIMEOUT_MS` so a dead worker does not strand summary generation forever.
