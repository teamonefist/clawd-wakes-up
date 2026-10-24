-- clawd-wakes-up: Session tracking table
-- Records what happened in each conversation session.

CREATE TABLE IF NOT EXISTS claude_sessions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id      TEXT NOT NULL UNIQUE,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at        TIMESTAMPTZ,
    summary         TEXT,
    tasks_completed TEXT[],
    tasks_pending   TEXT[],
    key_decisions   TEXT[],
    new_knowledge   TEXT[],
    metadata        JSONB NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_sessions_started ON claude_sessions(started_at DESC);
