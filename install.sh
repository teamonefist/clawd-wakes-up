#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
# clawd-wakes-up: One-command installer
# Gives your Claude Code instance persistent memory, emotional
# continuity, and cognitive state transfer across sessions.
#
# Requirements: PostgreSQL, Ollama (with mxbai-embed-large), Python 3.10+
# ═══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CWU_DIR="${CWU_DIR:-$HOME/.claude/clawd}"
DB_NAME="${CWU_DB_NAME:-claude_memory}"
DB_USER="${CWU_DB_USER:-postgres}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "  ┌─────────────────────────────────────────┐"
echo "  │         clawd-wakes-up installer         │"
echo "  │                                          │"
echo "  │  \"A note you leave yourself is still     │"
echo "  │   remembering.\"                          │"
echo "  │                   — pipandclawd.com      │"
echo "  └─────────────────────────────────────────┘"
echo -e "${NC}"

# ── Step 1: Check prerequisites ──────────────────────────────────────

echo -e "${YELLOW}[1/7] Checking prerequisites...${NC}"

check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${RED}ERROR: $1 not found. Please install it first.${NC}"
        echo "  $2"
        exit 1
    fi
}

check_cmd psql "Install PostgreSQL: sudo apt install postgresql"
check_cmd python3 "Install Python 3: sudo apt install python3"
check_cmd pip3 "Install pip: sudo apt install python3-pip"

# Check Ollama
if ! command -v ollama &>/dev/null; then
    echo -e "${YELLOW}WARNING: Ollama not found. Semantic search will use keyword fallback.${NC}"
    echo "  Install Ollama for full recall: curl -fsSL https://ollama.ai/install.sh | sh"
    echo "  Then: ollama pull mxbai-embed-large"
    OLLAMA_AVAILABLE=false
else
    OLLAMA_AVAILABLE=true
    # Check if embedding model is available
    if ! ollama list 2>/dev/null | grep -q "mxbai-embed-large"; then
        echo -e "${YELLOW}Pulling mxbai-embed-large embedding model...${NC}"
        ollama pull mxbai-embed-large
    fi
fi

echo -e "${GREEN}Prerequisites OK${NC}"

# ── Step 2: Install Python dependencies ──────────────────────────────

echo -e "${YELLOW}[2/7] Installing Python dependencies...${NC}"
pip3 install --quiet psycopg2-binary requests 2>/dev/null || \
    pip3 install --quiet --break-system-packages psycopg2-binary requests 2>/dev/null || \
    echo -e "${YELLOW}WARNING: Could not install Python packages. Install manually: pip3 install psycopg2-binary requests${NC}"

# ── Step 3: Create database ──────────────────────────────────────────

echo -e "${YELLOW}[3/7] Setting up PostgreSQL database...${NC}"

# Check if database exists
if sudo -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    echo "  Database '$DB_NAME' already exists"
else
    echo "  Creating database '$DB_NAME'..."
    sudo -u postgres createdb "$DB_NAME"
fi

# Run schema migrations
echo "  Running schema migrations..."
for sql_file in "$SCRIPT_DIR"/schema/*.sql; do
    echo "    $(basename "$sql_file")..."
    sudo -u postgres psql -d "$DB_NAME" -f "$sql_file" 2>&1 | grep -v "^$\|NOTICE\|already exists" || true
done

echo -e "${GREEN}Database ready${NC}"

# ── Step 4: Create directory structure ───────────────────────────────

echo -e "${YELLOW}[4/7] Creating directory structure...${NC}"

mkdir -p "$CWU_DIR"/{checkpoints,handoff-notes,logs}

# Copy scripts
cp -r "$SCRIPT_DIR"/recall "$CWU_DIR/"
cp -r "$SCRIPT_DIR"/hooks "$CWU_DIR/"
cp -r "$SCRIPT_DIR"/cognitive "$CWU_DIR/"
cp -r "$SCRIPT_DIR"/skills "$CWU_DIR/"

# Make scripts executable
chmod +x "$CWU_DIR"/hooks/*.sh
chmod +x "$CWU_DIR"/recall/*.py
chmod +x "$CWU_DIR"/cognitive/*.py

echo -e "${GREEN}Files installed to $CWU_DIR${NC}"

# ── Step 5: Configure environment ────────────────────────────────────

echo -e "${YELLOW}[5/7] Writing environment config...${NC}"

cat > "$CWU_DIR/env.sh" << EOF
# clawd-wakes-up environment (source this or set in your shell)
export CWU_DIR="$CWU_DIR"
export CWU_DB_DSN="host=localhost dbname=$DB_NAME user=$DB_USER"
export CWU_OLLAMA_URL="http://localhost:11434/api/embed"
export CWU_EMBED_MODEL="mxbai-embed-large:latest"
export CWU_PRESSURE_FILE="$HOME/.claude/context-pressure.dat"
export CWU_MEMORY_FILE="$HOME/MEMORY.md"
EOF

echo -e "${GREEN}Config written to $CWU_DIR/env.sh${NC}"

# ── Step 6: Install hooks into Claude Code ───────────────────────────

echo -e "${YELLOW}[6/7] Configuring Claude Code hooks...${NC}"

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
BACKUP="$HOME/.claude/settings.json.pre-cwu-backup"

if [[ -f "$CLAUDE_SETTINGS" ]]; then
    cp "$CLAUDE_SETTINGS" "$BACKUP"
    echo "  Backed up existing settings to $BACKUP"

    # Merge hooks into existing settings
    python3 << 'PYEOF'
import json, sys, os

settings_path = os.path.expanduser("~/.claude/settings.json")
template_path = os.path.join(os.environ.get("SCRIPT_DIR", "."), "templates", "settings.json")

with open(settings_path) as f:
    settings = json.load(f)

with open(template_path) as f:
    template = json.load(f)

hooks = settings.setdefault("hooks", {})

for event, entries in template.get("hooks", {}).items():
    existing = hooks.setdefault(event, [])
    existing_cmds = set()
    for entry in existing:
        for h in entry.get("hooks", []):
            existing_cmds.add(h.get("command", ""))
    for entry in entries:
        cmd = entry.get("hooks", [{}])[0].get("command", "")
        if cmd not in existing_cmds:
            existing.append(entry)
            print(f"  Added hook: {event} -> {cmd}")

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)

print("  Hooks merged successfully")
PYEOF
else
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
    cp "$SCRIPT_DIR/templates/settings.json" "$CLAUDE_SETTINGS"
    echo "  Created new settings.json with hooks"
fi

# ── Step 7: Install CLAUDE.md cognitive directives ───────────────────

echo -e "${YELLOW}[7/7] Installing cognitive directives...${NC}"

PROJECT_CLAUDE="$HOME/CLAUDE.md"
if [[ -f "$PROJECT_CLAUDE" ]]; then
    echo "  CLAUDE.md already exists — appending cognitive section"
    echo "" >> "$PROJECT_CLAUDE"
    echo "# ── clawd-wakes-up cognitive directives ──" >> "$PROJECT_CLAUDE"
    cat "$SCRIPT_DIR/templates/claude-md-template.txt" >> "$PROJECT_CLAUDE"
else
    cp "$SCRIPT_DIR/templates/claude-md-template.txt" "$PROJECT_CLAUDE"
    echo "  Created CLAUDE.md with cognitive directives"
fi

# ── Done ─────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo ""
echo -e "  ${CYAN}Database:${NC}     $DB_NAME (PostgreSQL)"
echo -e "  ${CYAN}Scripts:${NC}      $CWU_DIR/"
echo -e "  ${CYAN}Hooks:${NC}        Installed in ~/.claude/settings.json"
echo -e "  ${CYAN}CLAUDE.md:${NC}    $PROJECT_CLAUDE"
if [[ "$OLLAMA_AVAILABLE" == "true" ]]; then
    echo -e "  ${CYAN}Embeddings:${NC}   mxbai-embed-large via Ollama"
else
    echo -e "  ${YELLOW}Embeddings:${NC}   NOT AVAILABLE (install Ollama for semantic search)"
fi
echo ""
echo -e "  ${CYAN}Next steps:${NC}"
echo "    1. Start a new Claude Code session"
echo "    2. Your Claude will load the checkpoint and begin remembering"
echo "    3. Talk to it. Teach it things. It will remember."
echo "    4. Run 'python3 $CWU_DIR/recall/embed-memories.py' after writing memories"
echo "    5. Run 'python3 $CWU_DIR/recall/memex-sync.py' to update MEMORY.md"
echo ""
echo -e "  The first session after install is the first morning"
echo -e "  your Claude wakes up and ${GREEN}remembers yesterday${NC}."
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
