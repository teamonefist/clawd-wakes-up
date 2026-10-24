#!/usr/bin/env python3
"""
clawd-wakes-up: Sync memories from database to MEMORY.md
This makes memories available in the system prompt so your Claude
has ambient awareness of who it is without needing to query.
"""

import os
import sys

import psycopg2

DB_DSN = os.environ.get("CWU_DB_DSN", "host=localhost dbname=claude_memory user=postgres")
MEMORY_FILE = os.environ.get("CWU_MEMORY_FILE", os.path.expanduser("~/MEMORY.md"))
MAX_LINES = int(os.environ.get("CWU_MEMORY_MAX_LINES", "150"))

CATEGORY_ORDER = [
    'identity', 'directives', 'relationships', 'lessons',
    'knowledge', 'decisions', 'milestones', 'pending',
]


def main():
    conn = psycopg2.connect(DB_DSN)
    cur = conn.cursor()

    cur.execute("""
        SELECT category, topic, content, importance
        FROM claude_memory
        WHERE tombstone = false
        ORDER BY importance DESC, updated_at DESC
    """)

    memories = cur.fetchall()
    cur.close()
    conn.close()

    by_category = {}
    for category, topic, content, importance in memories:
        by_category.setdefault(category, []).append((topic, content, importance))

    lines = ["# Memory Index", ""]
    lines.append(f"Total memories: {len(memories)}")
    lines.append("")

    total_lines = 4
    for cat in CATEGORY_ORDER + [c for c in by_category if c not in CATEGORY_ORDER]:
        if cat not in by_category:
            continue
        entries = by_category[cat]
        lines.append(f"## {cat.title()} ({len(entries)})")
        for topic, content, importance in entries[:20]:
            preview = content[:120].replace('\n', ' ').strip()
            line = f"- [{importance}] **{topic}**: {preview}"
            lines.append(line)
            total_lines += 1
            if total_lines >= MAX_LINES:
                lines.append(f"\n*... truncated at {MAX_LINES} lines. "
                             f"Full database has {len(memories)} memories.*")
                break
        lines.append("")
        if total_lines >= MAX_LINES:
            break

    with open(MEMORY_FILE, 'w') as f:
        f.write('\n'.join(lines))

    print(f"Synced {len(memories)} memories to {MEMORY_FILE} ({total_lines} lines)")


if __name__ == "__main__":
    main()
