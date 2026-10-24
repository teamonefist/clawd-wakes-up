#!/usr/bin/env python3
"""
clawd-wakes-up: Embed unembedded memories
Run periodically or after memory writes to keep embeddings current.
"""

import os
import sys
import time
import logging

import requests
import psycopg2

OLLAMA_URL = os.environ.get("CWU_OLLAMA_URL", "http://localhost:11434/api/embed")
EMBED_MODEL = os.environ.get("CWU_EMBED_MODEL", "mxbai-embed-large:latest")
DB_DSN = os.environ.get("CWU_DB_DSN", "host=localhost dbname=claude_memory user=postgres")
BATCH_SIZE = 50

LOG_DIR = os.path.expanduser("~/.claude/logs")
os.makedirs(LOG_DIR, exist_ok=True)
logging.basicConfig(
    filename=os.path.join(LOG_DIR, "embedding.log"),
    level=logging.INFO,
    format="%(asctime)s [embed] %(message)s",
)


def embed_text(text: str) -> list[float] | None:
    try:
        resp = requests.post(
            OLLAMA_URL,
            json={"model": EMBED_MODEL, "input": text[:2000], "keep_alive": -1},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()["embeddings"][0]
    except Exception as e:
        logging.warning(f"Embedding failed: {e}")
        return None


def main():
    conn = psycopg2.connect(DB_DSN)
    cur = conn.cursor()

    cur.execute("""
        SELECT id, topic, content
        FROM claude_memory
        WHERE tombstone = false AND embedding_vec IS NULL
        ORDER BY created_at DESC
        LIMIT %s
    """, (BATCH_SIZE,))

    rows = cur.fetchall()
    if not rows:
        print("All memories embedded.")
        cur.close()
        conn.close()
        return

    embedded = 0
    for mem_id, topic, content in rows:
        text = f"{topic}: {content}"
        vec = embed_text(text)
        if vec:
            vec_str = "[" + ",".join(str(x) for x in vec) + "]"
            cur.execute(
                "UPDATE claude_memory SET embedding_vec = %s::vector, "
                "embedded_at = now(), embedding_model = %s WHERE id = %s",
                (vec_str, EMBED_MODEL, mem_id),
            )
            conn.commit()
            embedded += 1
        time.sleep(0.1)

    print(f"Embedded {embedded}/{len(rows)} memories.")
    logging.info(f"Embedded {embedded}/{len(rows)} memories")
    cur.close()
    conn.close()


if __name__ == "__main__":
    main()
