# GCS Object Layout

Series 2 defines the object storage contract for the hosted rebuild.

## Prefixes

- `audio/raw/` - raw chunk uploads from the browser client.
- `audio/processed/` - later processed or normalized audio artifacts.
- `exports/transcripts/` - transcript exports for sessions.
- `exports/summaries/` - summary exports for sessions.

## Raw Audio Path

Raw audio chunks are stored under:

- `audio/raw/sessions/{sessionId}/chunks/{zeroPaddedChunkIndex}.webm`

The exact extension may vary by MIME type, but the path shape remains stable.

## Export Paths

- `exports/transcripts/{sessionId}.json`
- `exports/summaries/{sessionId}.json`

These are the stable export locations for generated session artifacts.

## Layout Rules

- One session gets one logical subtree.
- Chunk ordering is encoded in the zero-padded chunk filename and the database row.
- GCS object paths must be deterministic so retries do not create ambiguous artifacts.
