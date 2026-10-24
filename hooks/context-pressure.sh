#!/usr/bin/env bash
# clawd-wakes-up: Context pressure monitor
# Writes context usage percentage to a file so the recall engine
# can scale its budget inversely with pressure.

set -euo pipefail

CWU_DIR="${CWU_DIR:-$HOME/.claude/clawd}"
PRESSURE_FILE="${CWU_PRESSURE_FILE:-$HOME/.claude/context-pressure.dat}"

# Read hook input to extract token counts if available
HOOK_INPUT=$(cat)

# Try to extract context percentage from hook metadata
CTX_PCT=$(echo "$HOOK_INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # Hook input may contain token stats
    used = d.get('total_tokens_used', 0)
    limit = d.get('context_window', 200000)
    if used and limit:
        print(f'{(used/limit)*100:.1f}')
    else:
        print('0')
except: print('0')
" 2>/dev/null || echo "0")

echo "$CTX_PCT $(date +%s)" > "$PRESSURE_FILE"
