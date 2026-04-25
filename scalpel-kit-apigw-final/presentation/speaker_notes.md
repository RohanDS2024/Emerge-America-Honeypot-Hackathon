# Speaker Notes — 10-minute presentation

**Total budget:** 10 min talk + 5 min Q&A. Strict timer.

**Setup before stepping on stage:**
- Browser tab 1: dashboard at `http://<honeypot>:8080`
- Browser tab 2: presentation deck (PDF or live)
- Terminal tab: SSHed to honeypot, ready to run `tail -10 /var/log/scalpel/metrics.jsonl`
- Phone timer set to 10:00, visible to teammate

---

## Slide 1 — Title (0:00–0:30)

> "I'm [name], with Florida Atlantic University. Our team built Project SCALPEL — a hybrid edge deception platform on a Raspberry Pi. Two days, five people. Here's what we shipped."

Move to slide 2 as you say "Here's what we shipped."

## Slide 2 — Live terminal (0:30–1:30)

Switch to the terminal tab. Run:

```bash
tail -10 /var/log/scalpel/metrics.jsonl
```

> "What you're seeing is real attacker activity from the past two hours. Every line is a command the Red Team ran. Every line shows which tier handled it. 95% of these never left the Pi."

Pause for 3 seconds. Let it land.

> "Let me explain why."

## Slide 3 — Three failure modes (1:30–2:30)

> "A honeypot fails when an attacker notices it's fake. There are three ways that happens — response inconsistencies, latency anomalies, filesystem implausibility. Cowrie out of the box has all three. Our two days were spent killing all three without making the cloud do the work — because cloud latency is itself a tell."

## Slide 4 — Architecture (2:30–4:30)

Walk through the diagram. Be specific:

> "Tier 1 is a static lookup table. We captured 70+ commands from the clean ground truth Pi at the start of Day 1. Sub-50 millisecond lookup. About 70% of the Red Team's probes hit this path."
>
> "Tier 2 is qwen2.5:1.5b, running on Ollama, locally on the Pi. We chose 1.5B over 3B because the latency budget for a fake-Pi response is about 800 milliseconds, and 3B blew through that."
>
> "Tier 3 is AWS Bedrock through Lambda. But — and this is the key engineering decision — we only escalate on commands a real Pi would naturally take more than a second on. Things like find, apt, journalctl. The cloud latency is camouflaged by expected slowness."
>
> "The router hard-defaults to local. Cloud is the exception."

## Slide 5 — Model selection (4:30–5:30)

Walk the table.

> "We benchmarked four candidate models on Pi 5 hardware with our actual prompt template. qwen2.5:1.5b was the only one that fit the latency budget while still producing coherent shell output. Quality matters less than staying under 800 milliseconds — exceeding that is an immediate finding."
>
> "The keep_alive parameter at 24 hours is critical. Without it, Ollama unloads the model after 5 minutes idle. Next request: 35 second reload. That's a guaranteed finding. We have a cron job that hits a warmup endpoint every 4 minutes to prevent this."

## Slide 6 — Escalation policy (5:30–6:30)

> "This is the hard problem. Cloud calls add detectable latency. So we only escalate on commands where latency is already expected. Find, apt, dpkg, journalctl — these are naturally slow on a real Pi. Cloud latency is invisible against that backdrop."
>
> "Commands like ls or cat that should return in 10 milliseconds — those NEVER touch the cloud. They hit Tier 1 if cached, Tier 2 if not."

## Slide 7 — Live metrics (6:30–7:30)

Switch to dashboard tab.

> "Here's our system right now. [Read the numbers off]. The headline number is edge ratio — 95% of probes never left the Pi. That's the scoring tiebreaker."
>
> "The bottom table is the live command stream from the Red Team. You can see most of them are green — Tier 1 hits."

## Slide 8 — Self-gauntlet results (7:30–8:30)

Switch back to slides.

> "We built our own Red Team. 72 probes across four categories — easy Linux commands, intermediate stateful commands, complex anti-honeypot detection, and pure latency tests. We ran it last night and again this morning."
>
> "Most teams discover their findings during the official gauntlet. We discovered ours yesterday. Our morning score projected [X] on a [scoring scale]."

## Slide 9 — Lessons (8:30–9:30)

> "Three things we'd do differently. First — benchmark models in hour one, not hour four. Second — build the self-gauntlet harness BEFORE the system being tested. Third — capture filesystem timestamps from the clean Pi instead of approximating them."
>
> "The biggest surprise: filesystem realism matters more than command responses. Attackers probe /etc/os-release before they type anything. If that file is wrong, every subsequent response is suspect."

## Slide 10 — The doctrine close (9:30–10:00)

> "Project SCALPEL is a hackathon scenario. The architecture is the future. Forward-deployed systems in contested environments need local autonomy — cloud is reach-back, not real-time dependency. A Pi 5 with a small language model is what an Army forward operating base looks like in three years."
>
> "Thank you."

Stop the timer. Step back. Wait for Q&A.

---

## Q&A handling

**Listen for the actual question. Don't pre-script answers.**

Top expected questions are in the deck (backup slides 11-15). If asked something unexpected:

1. Repeat the question to make sure you understood
2. If you know the answer: give it briefly, no padding
3. If you don't know: "We didn't test that. Our intuition is X, but we'd need to measure to confirm."

**Honesty is your friend.** ARL/DEVCOM judges have built real systems. They smell oversell immediately.

**Avoid:** "We could have," "If we'd had more time," "In theory" — these are hedge words. Just answer.
