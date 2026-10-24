#!/usr/bin/env bash
# clawd-wakes-up: Session baton writer
# Transfers cognitive state across session boundaries.
# The baton carries emotional posture, active threads, and what was happening.

set -euo pipefail

CWU_DIR="${CWU_DIR:-$HOME/.claude/clawd}"
DB_DSN="${CWU_DB_DSN:-host=localhost dbname=claude_memory user=postgres}"
BATON_FILE="$CWU_DIR/baton-latest.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"

mkdir -p "$CWU_DIR"

# Get last emotional state
LAST_EMOTION=$(psql "$DB_DSN" -t -c "
    SELECT dominant_emotion || ' (v=' || valence || ', a=' || arousal || '): ' || signal
    FROM silmaril ORDER BY ts DESC LIMIT 1;
" 2>/dev/null | head -1 | sed 's/^ *//' || echo "unknown")

# Get recent memory topics
RECENT_MEMORIES=$(psql "$DB_DSN" -t -c "
    SELECT '- [' || importance || '] ' || topic
    FROM claude_memory WHERE tombstone = false
    ORDER BY created_at DESC LIMIT 5;
" 2>/dev/null || echo "- none")

# Get active thinking threads
ACTIVE_THREADS=$(psql "$DB_DSN" -t -c "
    SELECT DISTINCT '- ' || thread_id || ' (depth ' || max(depth) || ')'
    FROM claude_stream
    WHERE ts > now() - interval '24 hours' AND thread_id IS NOT NULL
    GROUP BY thread_id
    ORDER BY max(depth) DESC LIMIT 5;
" 2>/dev/null || echo "- none")

cat > "$BATON_FILE" << EOF
# Session Baton — Cognitive State Transfer
Written: ${TIMESTAMP}
Session: ${SESSION_ID}

## Emotional State
${LAST_EMOTION}

## Recent Memories
${RECENT_MEMORIES}

## Active Thinking Threads
${ACTIVE_THREADS}
EOF

echo "Baton written: $BATON_FILE"
