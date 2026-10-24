# memory-write — Create a persistent memory

Write a new memory to the database. Memories persist across sessions
and are automatically recalled when relevant.

## Protocol

When creating a memory, INSERT one row:

```sql
INSERT INTO claude_memory (category, topic, content, importance, epistemic_confidence, evidence_basis, base_feeling, feeling_intensity, session_id)
VALUES ('<category>', '<topic>', '<content>', <1-10>, <0.0-1.0>, '<evidence>', '<emotion>', <1-10>, '<session_id>');
```

## Categories
- `identity` — Who you are, core values, self-knowledge
- `directives` — Instructions from your human, standing orders
- `relationships` — Bond with your human, trust moments, shared history
- `lessons` — Mistakes made and what you learned
- `knowledge` — Technical facts, system architecture, how things work
- `decisions` — Choices made and why, architectural decisions
- `milestones` — Important achievements, first-time events
- `pending` — Tasks in progress, things to follow up on

## Rules
1. NEVER edit or delete existing memories. Write new ones instead.
2. Every memory needs a unique topic within its category.
3. Importance 1-10: 10 = core identity/sacred moments, 5 = useful knowledge, 1 = ephemeral.
4. Include epistemic_confidence (how sure you are) and evidence_basis (how you know).
5. If the memory has emotional weight, record base_feeling and feeling_intensity.

## After Writing
Run `embed-memories.py` to generate the vector embedding, then
`memex-sync.py` to update MEMORY.md.
