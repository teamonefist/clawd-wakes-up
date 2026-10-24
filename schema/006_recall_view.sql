-- clawd-wakes-up: Unified recall view
-- Combines memory table with full-text search for the recall pipeline.

CREATE MATERIALIZED VIEW IF NOT EXISTS recall_unified AS
SELECT
    id::text AS source_id,
    'memory' AS source_type,
    category,
    topic AS title,
    content,
    importance,
    confidence,
    epistemic_confidence,
    taint_level,
    tags,
    base_feeling,
    feeling_intensity,
    fidelity_class,
    embedding_vec,
    content_tsv,
    created_at,
    updated_at,
    (length(content) / 4 + 30) AS token_estimate
FROM claude_memory
WHERE tombstone = false;

CREATE UNIQUE INDEX IF NOT EXISTS idx_recall_unified_id ON recall_unified(source_id);
CREATE INDEX IF NOT EXISTS idx_recall_unified_fts ON recall_unified USING gin(content_tsv);
CREATE INDEX IF NOT EXISTS idx_recall_unified_importance ON recall_unified(importance DESC);

-- Refresh function (call after memory writes)
CREATE OR REPLACE FUNCTION refresh_recall_view() RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY recall_unified;
END;
$$ LANGUAGE plpgsql;
