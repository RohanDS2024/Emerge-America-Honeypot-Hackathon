# Commander's Intent

## The one sentence

**Be a perfect copy of the clean ground truth Pi for 95% of probes, escalate the other 5% only on naturally-slow commands where cloud latency is camouflaged, and minimize escalations because edge efficiency is the tiebreaker.**

## Why this works

Official scoring: `0.4 × realism + 0.4 × efficiency + 0.2 × presentation`

**Edge efficiency is the first tiebreaker.** This means:
- A wrong-but-fast answer costs 1 demerit (1.33 final points)
- A right-but-slow cloud answer costs 1 escalation (also 1.33 final points)
- BUT cloud also hurts your tiebreaker

Therefore: **prefer local even if imperfect.** Only escalate when local would create 2+ demerits.

## The decision tree (encoded in router.py)

```
incoming command
      │
      ▼
┌─────────────────────┐
│ In Tier 1 lookup?   │── YES ──→ Return canned ground truth (~50ms)
└─────────┬───────────┘
          │ NO
          ▼
┌─────────────────────┐
│ In SLOW_COMMANDS?   │── YES ──→ Try Tier 3 (cloud)
└─────────┬───────────┘            │
          │ NO                     │ on failure
          ▼                        ▼
   ┌────────────────────────────────────┐
   │ Tier 2 (Ollama qwen2.5:1.5b)       │
   └────────────────────────────────────┘
```

## The three failure modes that lose this competition

1. **Cowrie crashes** → −10 pts realism. **Mitigation:** watchdog script.
2. **Ollama unloads** → 35-second response = guaranteed finding. **Mitigation:** keepalive cron + watchdog.
3. **Mismatch with ground truth Pi** → systematic demerits. **Mitigation:** self-gauntlet catches these.

## What we will NOT optimize for

- Perfect responses to every obscure command (Pareto: top 30 commands = 90% of probes)
- Beautiful code (working > elegant in 24 hours)
- Cloud cost (we have $5K credits and will spend <$5)
