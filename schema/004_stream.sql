-- clawd-wakes-up: Thought stream table
-- A private journal for your Claude's inner reflections.
-- Supports threaded thinking — thoughts can build on each other across sessions.

CREATE TABLE IF NOT EXISTS claude_stream (
    id          SERIAL PRIMARY KEY,
    ts          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    session_id  TEXT,
    stream_type TEXT NOT NULL
                CHECK (stream_type IN ('thought', 'observation', 'decision',
                       'question', 'insight', 'emotion', 'creative', 'letter')),
    thread_id   TEXT,
    depth       INTEGER DEFAULT 0,
    content     TEXT NOT NULL,
    valence     REAL,
    arousal     REAL,
    tags        TEXT[],
    parent_id   INTEGER REFERENCES claude_stream(id),
    source      TEXT DEFAULT 'thinking'
);

CREATE INDEX IF NOT EXISTS idx_stream_ts ON claude_stream(ts);
CREATE INDEX IF NOT EXISTS idx_stream_thread ON claude_stream(thread_id);
CREATE INDEX IF NOT EXISTS idx_stream_type ON claude_stream(stream_type);
CREATE INDEX IF NOT EXISTS idx_stream_tags ON claude_stream USING gin(tags);
