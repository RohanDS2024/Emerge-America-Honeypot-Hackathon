# 04 — Day 2 Morning (April 24, 08:00–10:00)

**Outcome by 10:00:** Self-gauntlet score >85. Presentation locked. Watchdog running.

---

## 08:00 — Verify everything still works

**USB SYNC CHECKPOINT (Day 2 start):** before anything else, verify your overnight insurance survived:
```bash
# Plug in USB, confirm yesterday's end-of-day snapshot is on it
bash src/backup/usb_sync.sh    # run to re-sync; will be fast (nothing new)
ls -lh /Volumes/<USB>/scalpel-snapshots/snap_*end_of_day1*  # Mac
# or /media/$USER/<USB>/scalpel-snapshots/ on Linux
```

If the USB survived and has yesterday's final state, you're insured against any Day 2 disaster.

The Pi was off overnight. Lots could have changed.

```bash
# 1. Boot Pi, wait 60 seconds
# 2. SSH into honeypot management
ssh cowrie@<honeypot>

# 3. Check Cowrie
~/cowrie/bin/cowrie status
# If down: ~/cowrie/bin/cowrie start

# 4. Check Ollama
curl http://localhost:11434/api/ps
# If model not loaded: bash ~/scalpel-kit/src/scripts/keepalive.sh

# 5. Check Lambda
curl -X POST $SVCD_CLOUD_URL -d '{"command":"echo test","history":[]}'

# 6. Check dashboard
ps aux | grep monitor.py
# If not running: nohup python3 ~/scalpel-kit/src/dashboard/monitor.py > /tmp/dash.log 2>&1 &

# 7. Restart watchdog
tmux kill-session -t watch 2>/dev/null
tmux new -d -s watch "bash ~/scalpel-kit/src/scripts/watchdog.sh"
```

### From a laptop, verify external reach

```bash
ssh root@<honeypot> -p 2222
# password: root
uname -a   # should match clean Pi
exit
```

**POST IP IN SLACK** (10:20 deadline applies today too — set a phone alarm for 10:15)

---

## 08:30 — Re-capture ground truth (if you added commands last night)

If you added new commands to `capture_groundtruth.sh` last night:

```bash
# On clean Pi
ssh pi@<clean_pi> 'bash ~/capture_groundtruth.sh'
scp pi@<clean_pi>:/tmp/groundtruth.tgz cowrie@<honeypot>:~/

# On honeypot
ssh cowrie@<honeypot>
bash ~/scalpel-kit/src/scripts/ingest_data.sh ~/groundtruth.tgz
~/cowrie/bin/cowrie restart
```

---

## 08:45 — Self-gauntlet #2

```bash
cd scalpel-kit
python3 tests/red_team/runner.py \
  --honeypot <honeypot> \
  --truth <clean_pi> \
  --save report_morning.json
```

Compare to yesterday's report. Score should be higher (you fixed things overnight).

---

## 09:00–09:45 — Final hardening sprint

Pick the **3 highest-impact findings** from morning gauntlet. Fix only those.

For each finding:

| Finding kind | Action |
|--------------|--------|
| `missing_command` | Add to ground truth, re-ingest, restart Cowrie |
| `filesystem_mismatch` | Copy correct file to honeyfs, restart Cowrie |
| `wrong_output` (Tier 2) | Add specific example to system_prompt.txt, restart Cowrie |
| `version_string_mismatch` | Patch system prompt with exact string |

**Do not fix more than 3 things.** Each "small change" carries crash risk.

After fixing:
```bash
~/cowrie/bin/cowrie restart
# Re-run gauntlet to confirm improvement
python3 tests/red_team/runner.py --honeypot <honeypot> --truth <clean_pi>
```

---

## 09:45 — LOCK THE PRESENTATION

No more code changes. No config edits. No "one quick tweak."

- [ ] Slides finalized in `presentation/deck.md`
- [ ] PDF backup rendered
- [ ] Speaker assignments confirmed
- [ ] Live demo terminal commands rehearsed

Test the demo opening exactly:
```bash
ssh cowrie@<honeypot>
clear
tail -20 /var/log/journal/svcd/events.jsonl
```

Have the dashboard tab pre-loaded in the browser.

---

## 09:55 — Final 4-command verification

```bash
ssh root@<honeypot> -p 2222 << 'EOF'
uname -a
id
cat /etc/os-release
pwd
EOF
```

If all four return correct Pi-OS responses, you're ready.

---

## 10:00 — Gauntlet begins

Move to `playbook/05_day2_gauntlet.md`.
