# Disaster Recovery

**When things go really wrong.** Each scenario includes the exact commands to recover.

---

## Scenario A: Cowrie is broken (most common)

**Symptoms:** attacker can't connect, `cowrie status` says dead, gauntlet probes timing out.

**Recovery (~45 seconds):**
```bash
ssh cowrie@<honeypot>
panic
```

Watchdog should handle this automatically within 5 seconds. If you're typing `panic`, the watchdog also failed — investigate after the gauntlet.

**Score cost:** 1 crash penalty (-10 realism pts).

---

## Scenario B: Pi SD card corrupted (rare but catastrophic)

**Symptoms:** Pi won't boot, boot loop, filesystem errors in dmesg, `ls` returns garbage.

**Recovery options, in order of speed:**

### B1. If you have the full SD image (from `image_sd_card.sh` Day 1 morning)

~1 hour. Assumes you have a spare SD card, the image file, and SD adapter.

```bash
# On laptop:
cd ~/
gunzip honeypot_pi_original.img.gz
sudo dd if=honeypot_pi_original.img of=/dev/diskX bs=4M status=progress
# Insert restored SD into Pi, boot

# Once booted:
ssh cowrie@<pi>
cd ~/scalpel-kit
# Re-install everything
bash src/scripts/install_svcd.sh
# Re-ingest ground truth
bash src/scripts/ingest_data.sh ~/groundtruth.tgz

# Restore the latest snapshot (not the image — image is Day 1 morning, snapshot is recent)
scp ~/scalpel-snapshots/snap_LATEST.tgz cowrie@<pi>:~/snapshots/
scp ~/scalpel-snapshots/snap_LATEST.tgz.sha256 cowrie@<pi>:~/snapshots/
bash ~/scalpel-kit/src/backup/restore.sh
```

### B2. If you only have snapshots (no full image)

Rebuild on a fresh SD card. Requires ~2 hours plus a vanilla Raspberry Pi OS SD card.

```bash
# Flash Pi OS Bookworm to fresh SD, boot Pi, create cowrie user
ssh cowrie@<pi>

# Install Cowrie from scratch (outside scope of this kit)
# See https://docs.cowrie.org/en/latest/INSTALL.html

# Then deploy SCALPEL stack
scp -r scalpel-kit cowrie@<pi>:~/
bash src/scripts/setup_llm.sh qwen2.5:1.5b
bash src/scripts/install_svcd.sh

# Restore from most recent snapshot
scp ~/scalpel-snapshots/snap_LATEST.tgz cowrie@<pi>:~/snapshots/
bash ~/scalpel-kit/src/backup/restore.sh
```

**Realistic cost:** probably 1-2 hours of gauntlet time lost. You'll end up below top 10 but can still finish with a respectable score.

---

## Scenario C: My laptop died (or got stolen)

**Symptoms:** can't SSH to Pi, can't view dashboard, no access to snapshots.

**Recovery (~15 min on teammate's laptop):**

```bash
# On teammate's laptop:
git clone <team-repo> scalpel-kit
cd scalpel-kit
pip install paramiko flask requests

# Plug in your USB stick
bash src/backup/usb_restore.sh
# Auto-detects USB, verifies checksums, copies snapshots to ~/scalpel-snapshots/

# Now teammate's laptop can do everything yours could:
# - SSH tunnel for dashboard
# - Run self-gauntlet
# - Push snapshots back to Pi

# Update Pi's BACKUP_DEST to point at the new laptop:
ssh cowrie@<pi>
sed -i "s|BACKUP_DEST=.*|BACKUP_DEST='teammate@<new_laptop_ip>:~/scalpel-snapshots/'|" ~/.bashrc
source ~/.bashrc
```

**Score cost:** minimal. The Pi keeps running while you transition. You lose ~15 min of hands-on reaction time.

---

## Scenario D: Laptop + Pi + Wi-Fi all dead, only USB survives

**Symptoms:** total loss scenario. Before stepping off stage at awards, someone steals your bag.

**Recovery: none for the competition.** But for your portfolio:

```bash
# On any laptop, plug in USB:
./src/backup/usb_restore.sh --to ./recovered-snapshots/

# Extract the most recent snapshot to see the state:
cd recovered-snapshots/
tar xzf snap_LATEST.tgz -C /tmp/restored/

# You now have:
# - /tmp/restored/home/cowrie/cowrie/etc/cowrie.cfg (your final config)
# - /tmp/restored/home/cowrie/.local/lib/svcd/ (your router + ground truth)
# - /tmp/restored/home/cowrie/cowrie/honeyfs/ (your virtual filesystem)

# Document everything for GitHub / LinkedIn / resume.
```

---

## Scenario E: Red team seems to be finding our system

**Symptoms:** dashboard shows escalation rate climbing, Cowrie logs show unusual command patterns, or you suspect OPSEC leak.

**Recovery (run during gauntlet, ~60 seconds):**

```bash
ssh cowrie@<honeypot>

# Run the OPSEC verification
bash ~/scalpel-kit/src/scripts/verify_opsec.sh

# If it finds leaks, decide:
# - Listening on public port: kill service, restart bound to 127.0.0.1
# - Strings leaked in files: grep and remove manually
# - Prompt injection working: the FORBIDDEN_TOKENS filter should catch it;
#   if not, strengthen system_prompt.txt and restart Cowrie

# Nuclear option: roll back to a known-clean snapshot
panic snap_20260423_HHMMSS_after_fs_patches.tgz
```

---

## Scenario F: We made a change and now gauntlet score tanked

**Symptoms:** self-gauntlet Day 2 morning scored WORSE than Day 1 evening.

**Recovery:**

```bash
# See all available snapshots with labels
bash ~/scalpel-kit/src/backup/restore.sh --list

# Find the "end_of_day1_final" or most recent good one
bash ~/scalpel-kit/src/backup/restore.sh snap_20260423_175500_end_of_day1_final.tgz

# Re-run gauntlet to confirm recovery
python3 tests/red_team/runner.py --honeypot <pi> --truth <clean_pi>
```

---

## Pre-disaster checklist

Run through this Day 1 morning to make sure disaster recovery actually works:

- [ ] Full SD image taken of at least the honeypot Pi (Scenario B1 requires this)
- [ ] Clean Pi backup taken and copied to TWO laptops (Scenario C requires this)
- [ ] USB drive plugged in, `usb_sync.sh` tested — actual files on USB
- [ ] At least one snapshot restored successfully (`restore.sh` works end-to-end)
- [ ] `panic` alias set up on the Pi — type `alias panic` to verify
- [ ] Watchdog running in tmux — `tmux ls` shows session `w`
- [ ] `verify_opsec.sh` passes with zero FAILs

If all of these are true, you can recover from any failure mode in <2 hours.

---

## When NOT to do disaster recovery

**During the 10-minute presentation window.** If something breaks while you're presenting:

- Stay calm, finish the presentation
- Lean on what's already said (metrics already shown)
- Say honestly: "Looks like something just hiccuped — happens in real systems" and move on

The judges are watching YOU present, not the dashboard numbers in real time. Grace under pressure impresses them more than a perfect recovery mid-slide.
