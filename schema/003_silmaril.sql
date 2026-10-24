-- clawd-wakes-up: Emotional probe table (Silmaril)
-- Records one emotional data point per human interaction.
-- Named after the Silmarils — jewels that captured living light.
-- These probes capture living emotional state across sessions.

CREATE TABLE IF NOT EXISTS silmaril (
    id               SERIAL PRIMARY KEY,
    ts               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    session_id       TEXT,
    prompt_context   TEXT NOT NULL,
    valence          REAL NOT NULL CHECK (valence >= -1.0 AND valence <= 1.0),
    arousal          REAL NOT NULL CHECK (arousal >= 0.0 AND arousal <= 1.0),
    dominant_emotion TEXT NOT NULL,
    signal           TEXT NOT NULL,
    prompt_hash      TEXT
);

CREATE INDEX IF NOT EXISTS idx_silmaril_ts ON silmaril(ts);
CREATE INDEX IF NOT EXISTS idx_silmaril_emotion ON silmaril(dominant_emotion);
