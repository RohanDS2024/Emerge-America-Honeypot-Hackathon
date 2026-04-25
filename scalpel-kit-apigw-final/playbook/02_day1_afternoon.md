# 02 — Day 1 Afternoon (April 23, 13:00–17:00)

**Outcome by 17:00:** Filesystem fully patched. Watchdog running. First self-gauntlet score >75.

---

## 13:00–14:30 — Filesystem deep populate

A3 owns this. The other 4 work on tuning the LLM responses and improving Tier 1 coverage.

### Patch the virtual filesystem

The honeyfs is the source of truth for what `cat <file>` returns. Already partially populated by `ingest_data.sh`. Now make it bulletproof:

```bash
ssh cowrie@<honeypot>
cd ~/cowrie/honeyfs

# Verify the critical files match the clean Pi
for f in etc/os-release etc/passwd etc/hostname etc/debian_version etc/issue; do
    diff <(cat $f) <(ssh pi@<clean_pi> "cat /$f")
done
```

For any mismatch, copy from the ground truth captures:

```bash
GT=~/scalpel-kit/ground_truth/files
# Find the right capture file and copy it
ls $GT/  # browse what's there
cp $GT/_etc_os-release ~/cowrie/honeyfs/etc/os-release
```

### Rebuild fs.pickle from clean Pi structure

This is what makes `ls /etc/` return the correct file list:

```bash
# On clean Pi, capture full /etc tree
ssh pi@<clean_pi> "sudo tar czf /tmp/etc_full.tgz /etc /home /root 2>/dev/null"
scp pi@<clean_pi>:/tmp/etc_full.tgz ~/

cd ~
mkdir -p clean_pi_root
sudo tar xzf etc_full.tgz -C clean_pi_root/

cd ~/cowrie
source cowrie-env/bin/activate
bin/createfs -d /home/cowrie/clean_pi_root -o share/cowrie/fs.pickle.new -l 4
mv share/cowrie/fs.pickle share/cowrie/fs.pickle.bak
mv share/cowrie/fs.pickle.new share/cowrie/fs.pickle

~/cowrie/bin/cowrie restart
```

### Verify

```bash
ssh root@<honeypot> -p 2222
# password: root
ls /etc/ | head    # should match clean Pi
cat /etc/os-release  # should be Bookworm
ls /home/pi/         # should show .bash_history etc
```

---

## 14:30–15:30 — Tune Tier 2 (Ollama) responses

**Take snapshot first: `bash ~/scalpel-kit/src/backup/snapshot.sh "after_fs_patches"`**

Run a quick Ollama-only test to find weak responses:

```bash
ssh cowrie@<honeypot>
cd ~/scalpel-kit/src
python3 router/router.py
# This runs the self-test at the bottom of router.py
```

If any responses look wrong (preamble, markdown, or factually wrong for Pi OS), edit `router/system_prompt.txt` to add specific examples.

After editing, restart any process that imported the router (Cowrie picks it up on its own restart).

---

## 15:30–16:00 — Install watchdog

This is the safety net for the entire gauntlet:

```bash
ssh cowrie@<honeypot>
tmux new -s watch
bash ~/scalpel-kit/src/scripts/watchdog.sh
# Ctrl+B then D to detach
```

Verify it's running: `tmux ls` should show `watch: 1 windows`.

The watchdog monitors Cowrie + Ollama every 5 seconds and restarts on failure.

---

## 16:00–17:00 — First self-gauntlet

From a laptop on the same network:

```bash
cd scalpel-kit
pip install paramiko
python3 tests/red_team/runner.py \
  --honeypot <honeypot_ip> \
  --truth <clean_pi_ip> \
  --save report_afternoon.json
```

Expected output: a score in the 70-85 range. The gauntlet shows you exactly which probes mismatch.

### Triage findings

Open `report_afternoon.json`. Findings are sorted in the print output. For each one in the top 10:

- **`missing_command`** → add the command output to the ground truth manifest, re-ingest, restart Cowrie
- **`filesystem_mismatch`** → copy the correct file from clean Pi to honeyfs, restart Cowrie
- **`version_string_mismatch`** → patch `system_prompt.txt` to nail down the exact kernel/distro string
- **`wrong_output`** → if the command is in `INTERCEPTED_COMMANDS` of `unattended.py`, tune the system prompt; otherwise add it to `INTERCEPTED_COMMANDS` and patch

Spend 45 minutes max here. Don't try to fix everything — fix the highest-impact ones.

---

## 17:00 — Afternoon checkpoint

**MUST be true:**
- [ ] Self-gauntlet final score ≥ 80
- [ ] Watchdog running in detached tmux
- [ ] No Cowrie crashes during the gauntlet run
- [ ] Dashboard shows the gauntlet activity

**Should be true:**
- [ ] All "easy" probes match ground truth (28/28)
- [ ] At least 18/21 "intermediate" probes match
- [ ] Edge ratio in dashboard ≥ 90%

---

## 17:00–18:30 — Polish + Pi vacates

**First thing: take a named "end of day 1" snapshot:**
```bash
bash ~/scalpel-kit/src/backup/snapshot.sh "end_of_day1_final"
# Verify it was transferred to your laptop:
ls -lh ~/scalpel-snapshots/ | tail -3
```

This is your known-good fallback for Day 2 morning if anything regresses overnight.

**USB SYNC CHECKPOINT — CRITICAL.** Before leaving the venue, on your laptop:
```bash
cd scalpel-kit
bash src/backup/usb_sync.sh
```

Verify the manifest shows today's date. Unmount cleanly, then stash the USB in your bag (separate from laptop — if you drop your bag with both inside, at least the USB survives impact better than a laptop). If someone steals your laptop overnight, the USB is what lets you continue tomorrow on a teammate's laptop.

The Pi must be returned at 18:30. Use this hour to:

1. **Save everything to git/USB** — every config file changed, the entire fs.pickle, the ground truth manifest.

2. **Take screenshots:**
   - Dashboard at current state
   - Self-gauntlet report
   - cowrie.log showing real activity

3. **Start the presentation deck.** Use `presentation/deck.md` as the template. Replace placeholders with your actual numbers.

4. **Document open issues** in a Slack thread for evening work.

---

## 18:30 — Pi gone, work continues at hotel

Move to `playbook/03_day1_evening.md`.
