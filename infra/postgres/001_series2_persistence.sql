CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  display_name TEXT,
  email TEXT UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source_type TEXT NOT NULL CHECK (source_type IN ('microphone', 'system-audio', 'meeting-helper')),
  status TEXT NOT NULL CHECK (status IN ('starting', 'recording', 'processing', 'complete', 'failed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at TIMESTAMPTZ,
  ended_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS sessions_user_created_at_idx ON sessions (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS audio_chunks (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),
  mime_type TEXT NOT NULL,
  started_at TIMESTAMPTZ NOT NULL,
  ended_at TIMESTAMPTZ NOT NULL,
  object_path TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL CHECK (status IN ('registered', 'queued', 'processing', 'complete', 'failed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE (session_id, chunk_index)
);

CREATE INDEX IF NOT EXISTS audio_chunks_session_index_idx ON audio_chunks (session_id, chunk_index);

CREATE TABLE IF NOT EXISTS model_runs (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('asr', 'summary')),
  model_id TEXT NOT NULL,
  runtime TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'complete', 'failed')),
  input_ref TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  latency_ms INTEGER,
  error_message TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS model_runs_session_created_at_idx ON model_runs (session_id, created_at DESC);

CREATE TABLE IF NOT EXISTS transcript_segments (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  audio_chunk_id TEXT REFERENCES audio_chunks(id) ON DELETE SET NULL,
  model_run_id TEXT REFERENCES model_runs(id) ON DELETE SET NULL,
  sequence_number INTEGER NOT NULL,
  speaker_label TEXT,
  text TEXT NOT NULL,
  start_ms BIGINT NOT NULL,
  end_ms BIGINT NOT NULL,
  confidence NUMERIC(5,4),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (session_id, sequence_number)
);

CREATE INDEX IF NOT EXISTS transcript_segments_session_sequence_idx ON transcript_segments (session_id, sequence_number);

CREATE TABLE IF NOT EXISTS session_notes (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  model_run_id TEXT REFERENCES model_runs(id) ON DELETE SET NULL,
  source_segment_ids TEXT[] NOT NULL DEFAULT '{}'::text[],
  text TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS session_notes_session_created_at_idx ON session_notes (session_id, created_at DESC);

CREATE TABLE IF NOT EXISTS session_summaries (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  model_run_id TEXT REFERENCES model_runs(id) ON DELETE SET NULL,
  overview TEXT NOT NULL,
  key_points TEXT[] NOT NULL DEFAULT '{}'::text[],
  follow_ups TEXT[] NOT NULL DEFAULT '{}'::text[],
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS session_summaries_session_created_at_idx ON session_summaries (session_id, created_at DESC);

CREATE TABLE IF NOT EXISTS action_items (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  source_summary_id TEXT REFERENCES session_summaries(id) ON DELETE SET NULL,
  text TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('open', 'done', 'blocked')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS action_items_session_created_at_idx ON action_items (session_id, created_at DESC);

CREATE TABLE IF NOT EXISTS session_events (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (
    type IN (
      'session.created',
      'session.updated',
      'audio-chunk.registered',
      'model-run.created',
      'transcript.segment.created',
      'session.summary.created',
      'session.note.created',
      'error'
    )
  ),
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS session_events_session_created_at_idx ON session_events (session_id, created_at DESC);
