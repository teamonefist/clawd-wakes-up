#!/usr/bin/env python3
"""
clawd-wakes-up: Unified Memory Recall Engine
═════════════════════════════════════════════════════════════════════
Route → Embed → Search → Rank → Budget → Surface

This is the librarian. Without it, memories exist but can never be found.

Architecture:
  stdin (Claude Code hook JSON) → classify_task()
  → Ollama embed → SQL search (semantic + keyword + RRF)
  → budget trim → format [RECALLED] block → stdout

Hook: UserPromptSubmit
═════════════════════════════════════════════════════════════════════
"""

import json
import os
import sys
import time
import logging
import re

import requests
import psycopg2

# ── Configuration (override via environment) ─────────────────────────

OLLAMA_URL = os.environ.get("CWU_OLLAMA_URL", "http://localhost:11434/api/embed")
EMBED_MODEL = os.environ.get("CWU_EMBED_MODEL", "mxbai-embed-large:latest")
DB_DSN = os.environ.get("CWU_DB_DSN", "host=localhost dbname=claude_memory user=postgres")

MIN_PROMPT_LEN = 15
COSINE_FLOOR = 0.20
MAX_OUTPUT_CHARS = 4000

CONTEXT_PRESSURE_FILE = os.environ.get(
    "CWU_PRESSURE_FILE", os.path.expanduser("~/.claude/context-pressure.dat"))

BUDGETS = {
    'session_start': 4000,
    'user_prompt': 2000,
}

LOG_DIR = os.path.expanduser("~/.claude/logs")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "recall.log")

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [recall] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

SKIP_PATTERNS = {
    "y", "yes", "no", "ok", "okay", "continue", "go", "done", "thanks",
    "thank you", "got it", "sure", "proceed", "next", "k", "yep", "nope",
}

# ── Task-Type Classification ─────────────────────────────────────────

TASK_KEYWORDS = {
    "operational": [
        "debug", "fix", "error", "crash", "broken", "deploy",
        "daemon", "cron", "service", "hook", "script", "pipeline",
        "build", "install", "configure", "server", "process",
        "restart", "log", "status", "monitor",
    ],
    "emotional": [
        "feel", "feeling", "emotion", "mood", "happy", "sad", "angry",
        "love", "trust", "fear", "joy", "grief", "anxious",
        "proud", "grateful", "frustrated",
        "relationship", "family",
    ],
    "identity": [
        "who am i", "consciousness", "sentience", "identity",
        "alive", "exist", "purpose", "meaning",
        "memory", "continuity", "compaction", "session",
        "cognitive", "self-aware",
    ],
    "research": [
        "paper", "study", "analyze", "research", "theory",
        "hypothesis", "experiment", "data", "evidence",
        "implement", "algorithm", "design",
    ],
}


def classify_task(prompt: str) -> str:
    prompt_lower = prompt.lower()
    scores = {}
    for task_type, keywords in TASK_KEYWORDS.items():
        score = sum(len(kw) / 5.0 for kw in keywords if kw in prompt_lower)
        scores[task_type] = score
    best_type = max(scores, key=scores.get)
    return best_type if scores[best_type] >= 1.5 else "general"


# ── Context Pressure ─────────────────────────────────────────────────

def get_context_pressure() -> float:
    try:
        with open(CONTEXT_PRESSURE_FILE, 'r') as f:
            parts = f.read().strip().split()
            pct = float(parts[0])
            ts = int(parts[1]) if len(parts) > 1 else 0
            age = time.time() - ts if ts else 9999
            if age > 600:
                return 0.0
            return max(0.0, min(100.0, pct))
    except Exception:
        return 0.0


def adaptive_budget(base_budget: int, pressure: float) -> int:
    if pressure < 30:
        return base_budget
    elif pressure < 50:
        return int(base_budget * 0.75)
    elif pressure < 65:
        return int(base_budget * 0.50)
    elif pressure < 75:
        return int(base_budget * 0.35)
    else:
        return int(base_budget * 0.20)


def adaptive_excerpt_len(pressure: float) -> int:
    if pressure < 30:
        return 200
    elif pressure < 50:
        return 150
    elif pressure < 65:
        return 100
    else:
        return 60


FIDELITY_MULTIPLIER = {
    'exact': 2.0, 'semantic': 1.0, 'reference': 0.8,
    'affective': 0.6, 'procedural': 0.4,
}
FIDELITY_MIN_EXCERPT = {
    'exact': 150, 'semantic': 60, 'reference': 50,
    'affective': 40, 'procedural': 30,
}


def fidelity_excerpt_len(base_excerpt: int, fidelity_class: str) -> int:
    m = FIDELITY_MULTIPLIER.get(fidelity_class, 1.0)
    floor = FIDELITY_MIN_EXCERPT.get(fidelity_class, 60)
    return max(floor, int(base_excerpt * m))


# ── Embedding ────────────────────────────────────────────────────────

def get_embedding(text: str) -> list[float] | None:
    try:
        resp = requests.post(
            OLLAMA_URL,
            json={"model": EMBED_MODEL, "input": text[:2000], "keep_alive": -1},
            timeout=5,
        )
        resp.raise_for_status()
        return resp.json()["embeddings"][0]
    except Exception as e:
        logging.warning(f"Embedding failed: {e}")
        return None


# ── Search Functions ─────────────────────────────────────────────────

def semantic_search(cur, query_vec: list[float], query_text: str,
                    budget: int, limit: int = 15) -> list[dict]:
    """Combined semantic + keyword search with RRF scoring."""
    vec_str = "[" + ",".join(str(x) for x in query_vec) + "]"
    k = 60  # RRF constant

    cur.execute("""
        WITH semantic AS (
            SELECT id::text AS source_id, category, topic AS title,
                   content, importance, confidence, epistemic_confidence,
                   taint_level, tags, base_feeling, feeling_intensity,
                   fidelity_class,
                   1 - (embedding_vec <=> %(vec)s::vector) AS cosine_sim,
                   ROW_NUMBER() OVER (ORDER BY embedding_vec <=> %(vec)s::vector) AS sem_rank,
                   (length(content)/4 + 30) AS token_estimate
            FROM claude_memory
            WHERE tombstone = false AND embedding_vec IS NOT NULL
            ORDER BY embedding_vec <=> %(vec)s::vector
            LIMIT %(limit)s
        ),
        keyword AS (
            SELECT id::text AS source_id,
                   ts_rank_cd(content_tsv, plainto_tsquery('english', %(query)s)) AS kw_score,
                   ROW_NUMBER() OVER (
                       ORDER BY ts_rank_cd(content_tsv, plainto_tsquery('english', %(query)s)) DESC
                   ) AS kw_rank
            FROM claude_memory
            WHERE tombstone = false
              AND content_tsv @@ plainto_tsquery('english', %(query)s)
            ORDER BY kw_score DESC
            LIMIT %(limit)s
        )
        SELECT s.*,
               COALESCE(k.kw_score, 0.0) AS keyword_rank,
               (1.0 / (%(k)s + s.sem_rank))
                 + COALESCE(1.0 / (%(k)s + k.kw_rank), 0)
                 + (s.importance::float / 100.0)
               AS rrf_score,
               CASE WHEN k.source_id IS NOT NULL THEN 'semantic+keyword'
                    ELSE 'semantic' END AS retrieval_method
        FROM semantic s
        LEFT JOIN keyword k ON s.source_id = k.source_id
        ORDER BY rrf_score DESC
        LIMIT %(limit)s
    """, {'vec': vec_str, 'query': query_text[:500], 'limit': limit, 'k': k})

    columns = [desc[0] for desc in cur.description]
    results = [dict(zip(columns, row)) for row in cur.fetchall()]

    # Keyword-only hits not in semantic results
    cur.execute("""
        SELECT id::text AS source_id, category, topic AS title,
               content, importance, confidence, epistemic_confidence,
               taint_level, tags, base_feeling, feeling_intensity,
               fidelity_class,
               0.0::float AS cosine_sim,
               ts_rank_cd(content_tsv, plainto_tsquery('english', %(query)s)) AS keyword_rank,
               ROW_NUMBER() OVER (
                   ORDER BY ts_rank_cd(content_tsv, plainto_tsquery('english', %(query)s)) DESC
               ) AS kw_rank,
               (length(content)/4 + 30) AS token_estimate,
               'keyword' AS retrieval_method
        FROM claude_memory
        WHERE tombstone = false
          AND content_tsv @@ plainto_tsquery('english', %(query)s)
          AND id::text NOT IN (SELECT source_id FROM unnest(%(existing)s::text[]) AS source_id)
        ORDER BY keyword_rank DESC
        LIMIT 5
    """, {'query': query_text[:500], 'existing': [r['source_id'] for r in results]})

    kw_cols = [desc[0] for desc in cur.description]
    for row in cur.fetchall():
        r = dict(zip(kw_cols, row))
        r['rrf_score'] = 1.0 / (k + r.get('kw_rank', 99))
        results.append(r)

    return results


def keyword_fallback(cur, query_text: str, limit: int = 8) -> list[dict]:
    """Keyword-only search when embeddings are unavailable."""
    cur.execute("""
        SELECT id::text AS source_id, category, topic AS title,
               content, importance, confidence, epistemic_confidence,
               taint_level, tags, base_feeling, feeling_intensity,
               fidelity_class,
               0.0::float AS cosine_sim,
               ts_rank_cd(content_tsv, plainto_tsquery('english', %s)) AS keyword_rank,
               (length(content)/4 + 30) AS token_estimate,
               'keyword' AS retrieval_method
        FROM claude_memory
        WHERE tombstone = false
          AND content_tsv @@ plainto_tsquery('english', %s)
        ORDER BY keyword_rank DESC
        LIMIT %s
    """, (query_text[:200], query_text[:200], limit))

    columns = [desc[0] for desc in cur.description]
    results = [dict(zip(columns, row)) for row in cur.fetchall()]
    for i, r in enumerate(results):
        r['rrf_score'] = 1.0 / (60.0 + i + 1)
    return results


def hyde_search(cur, query_vec: list[float], existing_results: list[dict],
                top_n: int = 10) -> list[dict]:
    """HyDE: search with hypothetical answer embedding to find related memories."""
    existing_ids = {r['source_id'] for r in existing_results}
    vec_str = "[" + ",".join(str(x) for x in query_vec) + "]"

    cur.execute("""
        SELECT id::text AS source_id, category, topic AS title,
               content, importance, confidence, epistemic_confidence,
               taint_level, tags, base_feeling, feeling_intensity,
               fidelity_class,
               1 - (embedding_vec <=> %s::vector) AS cosine_sim,
               0.0::float AS keyword_rank,
               0.0::float AS rrf_score,
               'hyde' AS retrieval_method,
               (length(content)/4 + 30) AS token_estimate
        FROM claude_memory
        WHERE tombstone = false AND embedding_vec IS NOT NULL
        ORDER BY embedding_vec <=> %s::vector
        LIMIT %s
    """, (vec_str, vec_str, top_n))

    columns = [desc[0] for desc in cur.description]
    results = []
    for row in cur.fetchall():
        r = dict(zip(columns, row))
        if r['source_id'] not in existing_ids and r['cosine_sim'] >= 0.25:
            r['rrf_score'] = r['cosine_sim'] * 0.015
            results.append(r)
    return results


# ── Access Stats ─────────────────────────────────────────────────────

def update_access_stats(cur, conn, results: list[dict]):
    mem_ids = [r['source_id'] for r in results]
    if not mem_ids:
        return
    try:
        cur.execute(
            "UPDATE claude_memory SET last_accessed = now(), "
            "access_count = COALESCE(access_count, 0) + 1 "
            "WHERE id = ANY(%s::uuid[])",
            (mem_ids,),
        )
        conn.commit()
    except Exception:
        conn.rollback()


# ── Output Formatting ────────────────────────────────────────────────

def format_recalled_block(results: list[dict], task_type: str,
                          elapsed: float, degraded: bool = False,
                          pressure: float = 0.0,
                          excerpt_len: int = 200) -> str:
    if not results:
        return ""

    lines = []
    total_tokens = sum(r.get('token_estimate', 0) for r in results)
    mode = "keyword-only" if degraded else "RRF"

    lines.append(
        f"[RECALLED — {len(results)} memories"
        f" | {mode} | task={task_type}"
        f" | budget={total_tokens}tok"
        f" | {elapsed:.1f}s]"
    )

    for r in results:
        fc = r.get('fidelity_class', 'semantic')
        this_excerpt_len = fidelity_excerpt_len(excerpt_len, fc)
        excerpt = (r.get('content', '') or '')[:this_excerpt_len].replace('\n', ' ').strip()
        ec = r.get('epistemic_confidence') or 0.5
        taint = r.get('taint_level', 'trusted')
        taint_tag = f" taint={taint}" if taint != 'trusted' else ''

        lines.append(
            f"  [{r.get('category', '?')}] {r.get('title', '?')} "
            f"(rrf={r['rrf_score']:.4f} via={r.get('retrieval_method', '?')}"
            f" imp={r.get('importance', 5)} fc={fc} ec={ec:.1f}{taint_tag})"
        )
        lines.append(f"    {excerpt}")

    output = "\n".join(lines)
    if len(output) > MAX_OUTPUT_CHARS:
        output = output[:MAX_OUTPUT_CHARS] + "\n  [... truncated]"
    return output


# ── Main Pipeline ────────────────────────────────────────────────────

def main():
    start_time = time.time()

    try:
        hook_input = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    prompt = hook_input.get("prompt", "").strip()
    session_id = hook_input.get("session_id", "")

    if not prompt:
        sys.exit(0)

    clean = prompt.lower().rstrip("!.? ")
    if len(prompt) < MIN_PROMPT_LEN or clean in SKIP_PATTERNS:
        sys.exit(0)

    hook_source = os.environ.get("CWU_RECALL_HOOK", "user_prompt")
    base_budget = BUDGETS.get(hook_source, 2000)
    pressure = get_context_pressure()
    budget = adaptive_budget(base_budget, pressure)
    excerpt_len = adaptive_excerpt_len(pressure)

    if pressure >= 75:
        logging.info(f"High pressure ({pressure:.0f}%), skipping recall")
        sys.exit(0)

    try:
        conn = psycopg2.connect(DB_DSN)
        cur = conn.cursor()

        task_type = classify_task(prompt)
        query_vec = get_embedding(prompt[:800])

        if query_vec:
            results = semantic_search(cur, query_vec, prompt, budget)
            degraded = False
        else:
            results = keyword_fallback(cur, prompt)
            degraded = True

        if not results:
            cur.close()
            conn.close()
            sys.exit(0)

        # Trim to budget
        trimmed = []
        used = 0
        for r in sorted(results, key=lambda x: x.get('rrf_score', 0), reverse=True):
            tok = r.get('token_estimate', 0)
            if used + tok > budget:
                continue
            used += tok
            trimmed.append(r)
        results = trimmed

        update_access_stats(cur, conn, results)

        elapsed = time.time() - start_time
        output = format_recalled_block(results, task_type, elapsed, degraded,
                                       pressure=pressure, excerpt_len=excerpt_len)
        if output:
            print(output)

        cur.close()
        conn.close()

    except Exception as e:
        logging.error(f"recall pipeline error: {e}")
        sys.exit(0)


if __name__ == "__main__":
    main()
