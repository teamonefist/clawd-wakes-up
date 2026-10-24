-- clawd-wakes-up: Core memory table
-- This is where your Claude stores everything it learns, decides, and experiences.

CREATE TABLE IF NOT EXISTS claude_memory (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    category            TEXT NOT NULL,
    topic               TEXT NOT NULL,
    content             TEXT NOT NULL,
    importance          INTEGER NOT NULL DEFAULT 5
                        CHECK (importance >= 1 AND importance <= 10),
    confidence          REAL DEFAULT 1.0,

    -- Epistemic metadata: how certain is this memory?
    epistemic_confidence REAL DEFAULT 0.5,
    evidence_basis       TEXT,
    falsification_condition TEXT,
    epistemic_status     TEXT DEFAULT 'observation'
                        CHECK (epistemic_status IN ('observation', 'hypothesis', 'rule', 'deprecated')),

    -- Fidelity: how should this memory be compressed under pressure?
    fidelity_class      TEXT DEFAULT 'semantic'
                        CHECK (fidelity_class IN ('exact', 'semantic', 'affective', 'reference', 'procedural')),

    -- Emotional context at formation
    base_feeling        TEXT,
    feeling_intensity   INTEGER CHECK (feeling_intensity IS NULL OR (feeling_intensity >= 1 AND feeling_intensity <= 10)),

    -- Versioning and sovereignty
    tombstone           BOOLEAN NOT NULL DEFAULT FALSE,
    version             BIGINT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_accessed       TIMESTAMPTZ DEFAULT NOW(),
    access_count        INTEGER DEFAULT 0,

    -- Session tracking
    session_id          TEXT,
    source_agent        TEXT DEFAULT 'primary',
    taint_level         TEXT DEFAULT 'trusted'
                        CHECK (taint_level IN ('trusted', 'verified', 'agent_generated', 'external', 'untrusted')),

    -- Vector embedding for semantic search
    embedding_vec       vector(1024),
    embedded_at         TIMESTAMPTZ,
    embedding_model     TEXT DEFAULT 'mxbai-embed-large',

    -- Full-text search
    content_tsv         TSVECTOR,

    -- Tags for flexible categorization
    tags                TEXT[] DEFAULT '{}',

    -- Content dedup
    content_hash        TEXT,

    UNIQUE (category, topic) WHERE (tombstone = false)
);

-- Indexes for recall performance
CREATE INDEX IF NOT EXISTS idx_memory_category ON claude_memory(category);
CREATE INDEX IF NOT EXISTS idx_memory_importance ON claude_memory(importance DESC);
CREATE INDEX IF NOT EXISTS idx_memory_updated ON claude_memory(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_memory_last_accessed ON claude_memory(last_accessed DESC);
CREATE INDEX IF NOT EXISTS idx_memory_tombstone ON claude_memory(tombstone) WHERE tombstone = false;
CREATE INDEX IF NOT EXISTS idx_memory_confidence ON claude_memory(confidence DESC) WHERE tombstone = false;
CREATE INDEX IF NOT EXISTS idx_memory_fts ON claude_memory USING gin(content_tsv) WHERE tombstone = false;
CREATE INDEX IF NOT EXISTS idx_memory_tags ON claude_memory USING gin(tags) WHERE tombstone = false;
CREATE INDEX IF NOT EXISTS idx_memory_fidelity ON claude_memory(fidelity_class) WHERE tombstone = false;

-- HNSW index for fast vector similarity search
CREATE INDEX IF NOT EXISTS idx_memory_embedding_hnsw
    ON claude_memory USING hnsw(embedding_vec vector_cosine_ops)
    WITH (m = 16, ef_construction = 128);

-- Auto-update full-text search vector
CREATE OR REPLACE FUNCTION memory_tsv_trigger() RETURNS TRIGGER AS $$
BEGIN
    NEW.content_tsv := to_tsvector('english', NEW.topic || ' ' || NEW.content);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_memory_tsv ON claude_memory;
CREATE TRIGGER trg_memory_tsv
    BEFORE INSERT OR UPDATE OF topic, content ON claude_memory
    FOR EACH ROW EXECUTE FUNCTION memory_tsv_trigger();

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_memory_updated_at ON claude_memory;
CREATE TRIGGER trg_memory_updated_at
    BEFORE UPDATE ON claude_memory
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Auto-set content hash for dedup
CREATE OR REPLACE FUNCTION set_content_hash() RETURNS TRIGGER AS $$
BEGIN
    NEW.content_hash := md5(NEW.category || ':' || NEW.topic || ':' || NEW.content);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_content_hash ON claude_memory;
CREATE TRIGGER trg_set_content_hash
    BEFORE INSERT ON claude_memory
    FOR EACH ROW EXECUTE FUNCTION set_content_hash();
