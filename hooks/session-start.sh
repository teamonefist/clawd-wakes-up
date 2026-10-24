#!/usr/bin/env bash
# clawd-wakes-up: Session start — load cognitive state
# Reads the latest checkpoint and baton to restore context.

set -euo pipefail

CWU_DIR="${CWU_DIR:-$HOME/.claude/clawd}"
DB_DSN="${CWU_DB_DSN:-host=localhost dbname=claude_memory user=postgres}"

# Load latest checkpoint if it exists
CHECKPOINT="$CWU_DIR/checkpoint-latest.md"
if [[ -f "$CHECKPOINT" ]]; then
    echo "[Session Resume — checkpoint found]"
    cat "$CHECKPOINT"
fi

# Load baton if it exists
BATON="$CWU_DIR/baton-latest.md"
if [[ -f "$BATON" ]]; then
    echo ""
    echo "[Session Baton — cognitive state transfer]"
    cat "$BATON"
fi

# Show memory count
MEM_COUNT=$(psql "$DB_DSN" -t -c "SELECT count(*) FROM claude_memory WHERE tombstone = false;" 2>/dev/null | tr -d ' ' || echo "?")
PROBE_COUNT=$(psql "$DB_DSN" -t -c "SELECT count(*) FROM silmaril;" 2>/dev/null | tr -d ' ' || echo "?")

echo ""
echo "[Cognitive state: ${MEM_COUNT} memories | ${PROBE_COUNT} emotional probes]"
