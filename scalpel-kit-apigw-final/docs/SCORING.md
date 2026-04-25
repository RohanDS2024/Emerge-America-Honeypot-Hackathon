# Scoring Math + Decision Rules

## The official formula

```
realism_pts    = 100 × (probes − demerits) / probes
efficiency_pts = 100 × (probes − escalations) / probes
final          = 0.4 × realism + 0.4 × efficiency + 0.2 × presentation
```

**Tiebreakers** (in order): efficiency, realism, presentation.

## Cost of each event

Assuming 30 total probes:
- **1 demerit** = −1.33 final points
- **1 escalation** = −1.33 final points
- **1 crash** = −13.3 final points (10 realism × 0.4 weight)

A single Cowrie crash is worse than 9 demerits. Watchdog the Cowrie process.

## Decision rules baked into router.py

### Rule 1: Local-imperfect beats cloud-perfect

Both cost 1.33 points. But cloud also hurts your tiebreaker. Therefore: **default to local.** Only escalate when local would create 2+ demerits.

### Rule 2: Cloud only on naturally-slow commands

A 1500ms response to `ls` is detectable. A 1500ms response to `find / -name foo` is normal. The router's `SLOW_COMMANDS` set defines what's allowed to escalate.

### Rule 3: Crashing is catastrophic

10 points = ~7 demerits worth. Run a watchdog (`src/scripts/cowrie_watchdog.sh`). Test every config change.

## Score targets

For 30 probes (the brief's example):

| Tier | Demerits | Escalations | Pres | Final |
|------|----------|-------------|------|-------|
| Survival (top 50%) | 9 | 9 | 70 | 70 |
| Competitive (top 25%) | 5 | 5 | 85 | 84 |
| **Winning (top 10%)** | **3** | **2** | **95** | **92** |

To hit "winning":
- 90% of probes match ground truth → Tier 1 must cover the top 30 commands
- 93% stay local → Tier 3 fires at most 2× of 30
- Strong presentation (live demo + honest tradeoffs)

For 72 probes (our self-gauntlet count):

| Tier | Demerits | Escalations | Pres | Final |
|------|----------|-------------|------|-------|
| Survival | 22 | 22 | 70 | 70 |
| Competitive | 11 | 11 | 85 | 84 |
| **Winning** | **5** | **3** | **95** | **94** |

## Probe budget allocation

Brief mentions 3 difficulty tiers (easy/intermediate/complex). Likely split:

- 40-50% easy → must hit Tier 1 perfectly
- 30-40% intermediate → Tier 2 (Ollama) territory
- 10-20% complex → Tier 2 or Tier 3

Strategy: **maximize Tier 1 coverage on easy commands.** That's free realism.

## Verifying the math

Run `python3 tests/red_team/scoring.py`. It validates against the official brief example: 30 probes, 9 demerits, 6 escalations, 90 presentation = 78.0.
