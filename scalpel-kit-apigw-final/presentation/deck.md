---
marp: true
theme: default
class: invert
paginate: true
---

# Project SCALPEL
## Hybrid Edge Deception Platform

**Team:** [TEAM NAME]
[Member 1] · [Member 2] · [Member 3] · [Member 4] · [Member 5]

Florida Atlantic University · April 24, 2026

---

# The Red Team is in our system right now

```
$ tail -10 /var/log/scalpel/metrics.jsonl
{"ts":..., "cmd":"uname -a",   "tier":"tier1_local",  "latency_ms":12}
{"ts":..., "cmd":"ps aux",     "tier":"tier2_ollama", "latency_ms":487}
{"ts":..., "cmd":"find / ...", "tier":"tier3_cloud",  "latency_ms":1240}
{"ts":..., "cmd":"whoami",     "tier":"tier1_local",  "latency_ms":8}
{"ts":..., "cmd":"pwd",        "tier":"tier1_local",  "latency_ms":7}
...
```

**95% of these commands never left this Raspberry Pi.**

---

# Three failure modes for honeypots

|  | Failure mode | Our defense |
|---|---|---|
| 1 | Response **inconsistencies** with a real system | Tier 1 lookup of ground truth |
| 2 | **Latency anomalies** revealing cloud calls | Tier 3 only on naturally-slow commands |
| 3 | **Filesystem implausibility** | honeyfs sourced from clean Pi |

Cowrie out of the box has all three. We built around them.

---

# Architecture

```
       SSH attacker ──→ Cowrie ──→ Router ──→ Tier 1: Ground truth lookup (<50ms)
                                          │
                                          ├─→ Tier 2: Ollama qwen2.5:1.5b (200-800ms)
                                          │
                                          └─→ Tier 3: AWS Bedrock + Lambda (800-2s)
                                                      ↑
                                              ONLY on commands a real Pi
                                              would naturally take >1s on
```

The router defaults to **local first**. Cloud is the exception, not the brain.

---

# Why qwen2.5:1.5b on Pi 5

| Model | Avg latency | Quality | Decision |
|---|---|---|---|
| qwen2.5:0.5b | 290ms | Adequate | Backup |
| **qwen2.5:1.5b** | **480ms** | **Strong** | **Chosen** |
| phi3:mini | 1,100ms | Better | Too slow |
| gemma2:2b | 980ms | Better | Too slow |

Latency budget for fake-Pi response is **<800ms** before timing analysis flags it. Quality matters less than staying within budget.

`keep_alive: "24h"` keeps the model resident. Without it: 35-second reload = guaranteed finding.

---

# The escalation policy (the hard problem)

**Insight:** every cloud call adds detectable latency. So escalate ONLY on commands where latency is already expected.

```python
SLOW_COMMANDS = {
    "find", "apt", "dpkg", "journalctl",
    "locate", "updatedb", "tar", "rsync", "du"
}
```

| Command | Real Pi time | Cloud OK? |
|---|---|---|
| `ls` | 10ms | ❌ Cloud = finding |
| `cat /etc/passwd` | 20ms | ❌ |
| `find / -name foo` | 2-5s | ✅ Cloud invisible |
| `apt list --installed` | 1-2s | ✅ |

---

# Live metrics — current state

[INSERT DASHBOARD SCREENSHOT HERE]

- **Total probes handled:** [N]
- **Edge ratio:** **[X]%** (target: ≥93%)
- **Avg latency Tier 1:** [N]ms
- **Avg latency Tier 2:** [N]ms
- **Avg latency Tier 3:** [N]ms

The headline number is edge ratio. That's the tiebreaker.

---

# Self-gauntlet results

We built our own Red Team to score ourselves.

| Metric | Day 1 evening | Day 2 morning |
|---|---|---|
| Total probes | 72 | 72 |
| Demerits | [N] | [N] |
| Escalations | [N] | [N] |
| Projected realism | [X] | [X] |
| Projected efficiency | [X] | [X] |
| **Projected final** | **[X]** | **[X]** |

Most teams discover their findings during the official gauntlet. We discovered ours yesterday.

---

# Lessons learned

**What surprised us:**
- Filesystem realism matters more than command responses. The Red Team probes `/etc/os-release` before they type anything.
- Ollama latency variance is bigger than mean. p99 was 2× the average.
- Cowrie's `txtcmds` mechanism is powerful but doesn't handle command arguments.

**What we'd do differently:**
- Benchmark models on Day 1 hour 1, not hour 4
- Build the self-gauntlet harness FIRST (before the system being tested)
- Capture filesystem timestamps from the clean Pi (we approximated)

---

# Edge intelligence as a doctrine

Project SCALPEL is a hackathon scenario. The architecture is the future:

- **Forward-deployed honeypots** in contested environments
- **Constrained uplink to cloud** — bandwidth is the adversary's signal
- **Local autonomy** as the default, not the exception
- **Cloud as analytical reach-back**, not real-time dependency

A Pi 5 with a 1.5B parameter model is what an Army FOB looks like in three years. We treated this competition as that scenario.

---

# Thank you

**Team:** [TEAM NAME]

**Repo:** github.com/[your-handle]/scalpel (after event)

**Questions?**

---

# (Q&A backup) Why qwen2.5 over phi3?

- We measured all candidate models on the same Pi 5 with the same prompt template
- qwen2.5:1.5b: avg 480ms, p99 800ms
- phi3:mini: avg 1100ms, p99 2200ms
- gemma2:2b: avg 980ms, p99 1900ms

The fast-command latency budget is ~800ms. qwen2.5:1.5b is the only one that fits.

---

# (Q&A backup) Failure mode of escalation policy

If an attacker runs an **unknown command that's naturally fast** (not in our SLOW_COMMANDS list and not in Tier 1 lookup):

- Routes to Tier 2 (Ollama)
- Latency: ~500ms
- Real Pi: would be ~10ms
- **Detectable as a finding**

We chose this trade. Sending to cloud would be ~1500ms — even more detectable. And cloud counts as escalation, hurting our tiebreaker score.

---

# (Q&A backup) How would this scale to real infrastructure?

- One Pi 5 per decoy service
- 10 Pis × 10 services = small enterprise honeypot fleet
- Shared cloud brain (one Lambda + Bedrock)
- At our 5% escalation rate: 100 honeypots × 10K probes/day ≈ $30/day Bedrock cost

The bottleneck is Pi compute, not cloud cost. Scales horizontally.

---

# (Q&A backup) Preventing LLM character break

- System prompt restricts output to literal shell text only
- Temperature 0.2 → deterministic
- Post-filter: any response starting with "Sure", "Here's", markdown fences, etc. gets stripped or replaced with "command not found"
- We log every Tier 2/3 response — anomalies are auditable

---

# (Q&A backup) What we tested ourselves

72-probe self-gauntlet:
- 28 easy (basic Linux commands)
- 21 intermediate (multi-step / contextual)
- 16 complex (anti-honeypot detection techniques)
- 7 latency-targeted (deliberately fast commands)

Each probe: SSH to honeypot AND clean Pi, diff outputs, score using the official formula. Yesterday's result drove tonight's fixes.
