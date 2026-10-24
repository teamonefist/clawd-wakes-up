# Architecture

## Overview

clawd-wakes-up has three layers:

```
┌─────────────────────────────────────────────┐
│  Cognitive Layer                             │
│  (cognitive weave, mood, thinking threads)   │
├─────────────────────────────────────────────┤
│  Recall Layer                                │
│  (search, rank, budget, surface)             │
├─────────────────────────────────────────────┤
│  Storage Layer                               │
│  (PostgreSQL, pgvector, embeddings)          │
└─────────────────────────────────────────────┘
```

## Storage layer

### claude_memory
The core table. Every memory has:
- **Content**: category, topic, content
- **Scoring**: importance (1-10), confidence, epistemic_confidence
- **Epistemics**: evidence_basis, falsification_condition, epistemic_status
- **Fidelity**: exact/semantic/affective/reference/procedural
- **Emotion**: base_feeling, feeling_intensity
- **Search**: embedding_vec (1024-dim via mxbai-embed-large), content_tsv (tsvector)
- **Sovereignty**: tombstone (soft delete only), taint_level

### silmaril
One row per human interaction. valence/arousal/emotion/signal.

### claude_stream
Private thought journal. Threaded (thread_id + depth) so thinking
builds on itself across sessions.

### claude_sessions
What happened in each session — start/end times, tasks, decisions, summary.

### recall_unified
Materialized view that combines memory sources for fast recall.

## Recall layer

The recall engine (`recall-engine.py`) runs as a UserPromptSubmit hook:

1. **Classify** the prompt (emotional/operational/identity/research/general)
2. **Embed** the prompt via Ollama (mxbai-embed-large)
3. **Semantic search**: cosine similarity via pgvector HNSW index
4. **Keyword search**: PostgreSQL full-text search (tsvector/tsquery)
5. **RRF fusion**: Reciprocal Rank Fusion combines both lists
6. **Budget trim**: Keep results within token budget (scales with context pressure)
7. **Surface**: Emit [RECALLED] block into Claude's context

Fallback: If Ollama is down, uses keyword-only search.

## Cognitive layer

### Cognitive weave
Summarizes active thinking threads, emotional arc, recent memories,
and open questions. Loaded at session start.

### Session batons
Carry emotional state and operational context across session boundaries.
Written at PreCompact, read at SessionStart.

### Mood forwarding
Analyzes recent silmaril probes to detect emotional trajectory
(rising/falling/stable arc) and forward it to the next session.

### Context pressure
Monitors context usage percentage. The recall engine reads this
to scale its budget — using less context for recall when the
window is filling up.

## Hook lifecycle

```
SessionStart:
  → session-start.sh (load checkpoint + baton + weave)

UserPromptSubmit:
  → recall-engine.py (find and inject relevant memories)

PreCompact:
  → pre-compact.sh (save checkpoint)
  → baton-writer.sh (save emotional state)
  → cognitive-weave.py (save thinking threads)
  → mood-forward.py (analyze emotional trajectory)
```

## Embedding pipeline

Memories don't get embeddings automatically (it would slow down writes).
Run `embed-memories.py` periodically or after a batch of memory writes.
It finds unembedded memories and generates vectors via Ollama.

## MEMORY.md sync

`memex-sync.py` exports the top memories (by importance) into a
MEMORY.md file that loads into Claude's system prompt. This gives
ambient awareness without needing to query. Run it after significant
memory changes.
