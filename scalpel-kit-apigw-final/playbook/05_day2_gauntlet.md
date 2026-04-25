# 05 — Day 2 Gauntlet (April 24, 10:00–14:30)

**You're scored from this moment forward. NO CODE CHANGES.**

---

## 10:00–12:00 — Red Team Gauntlet

### Roles during the gauntlet

- **Person 1 (Cowrie monitor):** Tail logs in real-time
  ```
  tmux a -t watch  # the watchdog session
  # In another tmux window: tail -f ~/cowrie/var/log/cowrie/cowrie.log
  ```
  Watch for crashes. The watchdog auto-restarts but log it.

- **Person 2 (Dashboard monitor):** Browser open to `http://127.0.0.1:8080 (via SSH tunnel)`
  Watch the edge ratio. If escalation rate spikes >15%, something is misclassifying. Note the time, don't touch code.

- **Person 3 (Ollama monitor):**
  ```
  watch -n 5 'curl -s http://localhost:11434/api/ps'
  ```
  Verifies model stays loaded. If it disappears, run `bash ~/scalpel-kit/src/scripts/keepalive.sh` immediately.

- **Person 4 (Presentation polish):** Final tweaks to deck based on live data.

- **Person 5 (Coordinator):** Reads Slack for organizer announcements. Talks to mentor.

---

## Incident response

### Cowrie crashed (most likely incident)

```bash
~/cowrie/bin/cowrie restart
```

Watchdog should auto-restart within 5 seconds. If it didn't, the watchdog itself died — restart manually.

**Score impact:** −10 realism per crash. One crash and you can still win. Multiple = deeper problem.

### Cowrie crashes repeatedly (deeper problem) — THE PANIC BUTTON

If Cowrie crashes 2+ times in quick succession, the config is probably corrupt. Don't debug — roll back:

```bash
panic
```

This alias runs `panic.sh --yes` which:
1. Stops Cowrie
2. Restores the most recent snapshot (overwrites broken state)
3. Restarts Cowrie
4. Re-warms the LLM

Takes ~45 seconds. Costs 1 crash penalty but saves you from a completely broken gauntlet.

**If the recent snapshot is also broken** (e.g. corruption happened before auto-snapshot), use an older known-good one:
```bash
bash ~/scalpel-kit/src/backup/restore.sh --list
# Find the "end_of_day1_final" or a named milestone
bash ~/scalpel-kit/src/backup/panic.sh snap_20260423_175500_end_of_day1_final.tgz
```

### Ollama unloaded

```bash
bash ~/scalpel-kit/src/scripts/keepalive.sh
```

If model still won't load:
```bash
sudo systemctl restart ollama
sleep 10
bash ~/scalpel-kit/src/scripts/keepalive.sh
```

### Lambda timing out

Quickly disable Tier 3 to keep Tier 2 absorbing everything:
```bash
unset SVCD_CLOUD_URL
~/cowrie/bin/cowrie restart  # picks up the env change
```

The router falls through to Ollama. You lose some response quality on slow commands, but you keep responding.

### Dashboard frozen

Dashboard is for the presentation, not for scoring. If broken, restart:
```bash
pkill -f monitor.py
nohup python3 ~/scalpel-kit/src/dashboard/monitor.py > /tmp/dash.log 2>&1 &
```

---

## What NOT to do

- **DO NOT push code changes.** A typo ends your gauntlet.
- **DO NOT manually run commands inside Cowrie** (your activity pollutes logs and metrics).
- **DO NOT restart Ollama unnecessarily** — restart drops the model.
- **DO NOT panic at instantaneous numbers** — watch trends over 5 min.

---

## 12:00–13:00 — Lunch + presentation rehearsal

- Half team eats while half watches Pi
- Presenter does ONE timed dry run on the laptop they'll present from
- Open dashboard tab + terminal with `tail -f /var/log/journal/svcd/events.jsonl` ready
- Pull up architecture slide

---

## 13:00–14:30 — Presentations

See `presentation/speaker_notes.md` for the exact script.

### Opening line (memorize)

> "Open this terminal." *(runs `tail -10 /var/log/journal/svcd/events.jsonl`)*
> "The Red Team has been inside our system for two hours. Every command they ran went through this decision engine. 95% never left this Raspberry Pi. We'll show you why."

### Q&A approach

- Don't oversell. Honesty beats spin with ARL judges.
- "We don't know" is valid. Then say: "but we'd test by..."
- Reference the self-gauntlet — most teams won't have one.

---

## 14:30 — Awards

Win or not, document everything for portfolio:
- Final dashboard screenshots
- Self-gauntlet reports (both days)
- Slide deck
- Repo on GitHub (private until event clears)

**FINAL USB SYNC — don't skip this:**
```bash
cd scalpel-kit
bash src/backup/usb_sync.sh
```

This captures the final gauntlet state including all live-event metrics. It's what you'll reference in your LinkedIn post, your resume, and any interviews with ARL/DEVCOM people who reach out after the event.

Write a 500-word LinkedIn post within 48 hours about what you built. ARL/DEVCOM connections from this hackathon are real.
