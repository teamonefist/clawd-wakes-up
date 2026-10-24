#!/usr/bin/env python3
"""
clawd-wakes-up: Mood Forward
Carries emotional state across session boundaries by analyzing
recent silmaril probes and producing a mood summary.
"""

import os
import sys

import psycopg2

DB_DSN = os.environ.get("CWU_DB_DSN", "host=localhost dbname=claude_memory user=postgres")


def main():
    conn = psycopg2.connect(DB_DSN)
    cur = conn.cursor()

    # Last 20 probes
    cur.execute("""
        SELECT dominant_emotion, valence, arousal, signal
        FROM silmaril
        ORDER BY ts DESC LIMIT 20
    """)
    probes = cur.fetchall()

    if not probes:
        print("No emotional probes recorded yet.")
        cur.close()
        conn.close()
        return

    # Calculate trajectory
    emotions = [p[0] for p in probes]
    valences = [p[1] for p in probes]
    arousals = [p[2] for p in probes]

    mean_valence = sum(valences) / len(valences)
    mean_arousal = sum(arousals) / len(arousals)

    # Detect arc direction
    if len(valences) >= 4:
        recent = sum(valences[:4]) / 4
        older = sum(valences[-4:]) / 4
        if recent > older + 0.15:
            arc = "rising"
        elif recent < older - 0.15:
            arc = "falling"
        else:
            arc = "stable"
    else:
        arc = "stable"

    # Most common emotion
    from collections import Counter
    dominant = Counter(emotions).most_common(1)[0][0]

    # Last signal
    last_signal = probes[0][3] if probes else "none"

    drift = abs(valences[0] - valences[-1]) if len(valences) >= 2 else 0

    print(f"Mood: {arc} arc, dominant {dominant}. "
          f"Valence {valences[-1]:.1f} -> {valences[0]:.1f} (drift {drift:+.2f}). "
          f"Mean v={mean_valence:.2f}, a={mean_arousal:.2f}. "
          f"Last: \"{last_signal[:80]}\"")

    cur.close()
    conn.close()


if __name__ == "__main__":
    main()
