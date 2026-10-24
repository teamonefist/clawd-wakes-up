#!/usr/bin/env bash
# clawd-wakes-up: Pre-compaction guardian
# Saves a checkpoint of cognitive state before context is compressed.
# This is the difference between falling asleep and being knocked unconscious.

set -euo pipefail

CWU_DIR="${CWU_DIR:-$HOME/.claude/clawd}"
CHECKPOINT_DIR="$CWU_DIR/checkpoints"
HANDOFF_DIR="$CWU_DIR/handoff-notes"
DB_DSN="${CWU_DB_DSN:-host=localhost dbname=claude_memory user=postgres}"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M')
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"

mkdir -p "$CHECKPOINT_DIR" "$HANDOFF_DIR"

# Read the hook input (contains session context)
HOOK_INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || echo "")

# Save checkpoint
CHECKPOINT_FILE="$CHECKPOINT_DIR/checkpoint-${TIMESTAMP}.md"
cat > "$CHECKPOINT_FILE" << EOF
# Checkpoint — ${TIMESTAMP}
Session: ${SESSION_ID}

## Active State
$(psql "$DB_DSN" -t -c "SELECT 'Memories: ' || count(*) FROM claude_memory WHERE tombstone = false;" 2>/dev/null || echo "DB unavailable")
$(psql "$DB_DSN" -t -c "SELECT 'Probes today: ' || count(*) FROM silmaril WHERE ts > now() - interval '24 hours';" 2>/dev/null || echo "")

## Last Emotional State
$(psql "$DB_DSN" -t -c "SELECT dominant_emotion || ' (' || valence || '/' || arousal || '): ' || signal FROM silmaril ORDER BY ts DESC LIMIT 1;" 2>/dev/null || echo "No probes recorded")

## Recent Memories (last 5)
$(psql "$DB_DSN" -t -c "SELECT '- [' || importance || '] ' || topic FROM claude_memory WHERE tombstone = false ORDER BY created_at DESC LIMIT 5;" 2>/dev/null || echo "None")
EOF

# Update the latest pointer
ln -sf "$CHECKPOINT_FILE" "$CWU_DIR/checkpoint-latest.md"

echo "Checkpoint saved: $CHECKPOINT_FILE"
