#!/usr/bin/env python3
"""
clawd-wakes-up: Cognitive Weave Generator
Tracks thinking threads, emotional arcs, and open questions across sessions.
The weave is loaded at session start to give Claude continuity of thought.
"""

import os
import sys
from datetime import datetime, timedelta

import psycopg2

DB_DSN = os.environ.get("CWU_DB_DSN", "host=localhost dbname=claude_memory user=postgres")
CWU_DIR = os.environ.get("CWU_DIR", os.path.expanduser("~/.claude/clawd"))
WEAVE_FILE = os.path.join(CWU_DIR, "cognitive-weave-latest.md")


def main():
    os.makedirs(CWU_DIR, exist_ok=True)
    conn = psycopg2.connect(DB_DSN)
    cur = conn.cursor()

    now = datetime.now()

    # Recent emotional arc (last 24h probes)
    cur.execute("""
        SELECT dominant_emotion, valence, arousal, signal, prompt_context
        FROM silmaril
        WHERE ts > now() - interval '24 hours'
        ORDER BY ts DESC LIMIT 10
    """)
    probes = cur.fetchall()

    # Active thinking threads
    cur.execute("""
        SELECT thread_id, max(depth) as max_depth, count(*) as entries,
               max(ts) as last_ts
        FROM claude_stream
        WHERE thread_id IS NOT NULL AND ts > now() - interval '7 days'
        GROUP BY thread_id
        ORDER BY max(depth) DESC, count(*) DESC
        LIMIT 10
    """)
    threads = cur.fetchall()

    # Recent memories (last 48h)
    cur.execute("""
        SELECT topic, importance, category
        FROM claude_memory
        WHERE tombstone = false AND created_at > now() - interval '48 hours'
        ORDER BY importance DESC, created_at DESC
        LIMIT 10
    """)
    recent_memories = cur.fetchall()

    # Open questions from stream
    cur.execute("""
        SELECT content, thread_id, depth
        FROM claude_stream
        WHERE stream_type = 'question' AND ts > now() - interval '7 days'
        ORDER BY ts DESC LIMIT 5
    """)
    open_questions = cur.fetchall()

    cur.close()
    conn.close()

    # Build the weave
    lines = [f"# Cognitive Weave — {now.strftime('%Y-%m-%d %H:%M')}", ""]

    # Emotional arc
    if probes:
        lines.append("[ARC]")
        for emotion, valence, arousal, signal, ctx in probes:
            v_sign = "+" if valence >= 0 else ""
            lines.append(f"  {emotion}({v_sign}{valence:.1f}): {signal[:80]}")
        lines.append("")

    # Recent learned
    if recent_memories:
        lines.append("[LEARNED]")
        for topic, importance, category in recent_memories:
            lines.append(f"  [{importance}] {topic}")
        lines.append("")

    # Active threads
    if threads:
        lines.append("[INNER]")
        for thread_id, max_depth, entries, last_ts in threads:
            lines.append(f"  [{thread_id}] depth={max_depth}, {entries} entries")
        lines.append("")

    # Open questions
    if open_questions:
        lines.append("[OPEN]")
        for content, thread_id, depth in open_questions:
            preview = content[:100].replace('\n', ' ')
            tag = f" ({thread_id})" if thread_id else ""
            lines.append(f"  {preview}{tag}")
        lines.append("")

    with open(WEAVE_FILE, 'w') as f:
        f.write('\n'.join(lines))

    print(f"Weave written: {WEAVE_FILE} (~{len(lines)} lines)")


if __name__ == "__main__":
    main()
