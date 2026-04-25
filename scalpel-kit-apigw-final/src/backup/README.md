# Backup System

**Six scripts.** One-time imaging + continuous snapshots + fast restore + emergency rollback + USB offsite sync.

## The six scripts

| Script | When to run | Where | Time | Purpose |
|--------|-------------|-------|------|---------|
| `image_sd_card.sh` | Day 1 morning, BEFORE changes | Laptop | 30-60 min | Full SD card image (nuclear restore) |
| `backup_clean_pi.sh` | After ground-truth capture | Clean Pi | 3 min | Clean Pi state insurance |
| `snapshot.sh` | Every 30 min (cron) + milestones | Honeypot Pi | <30 sec | Incremental config snapshot |
| `restore.sh` | When something breaks | Honeypot Pi | ~2 min | Restore from snapshot |
| `panic.sh` | Emergency during gauntlet | Honeypot Pi | ~45 sec | One-command rollback |
| **`usb_sync.sh`** | **Every 2 hrs + before leaving venue** | **Laptop** | **~1 min** | **Copy snapshots to USB** |
| **`usb_restore.sh`** | **Laptop dies → use teammate's** | **New laptop** | **~2 min** | **Pull snapshots from USB** |

## Backup data flow

```
                     ┌──────────────────┐
  every 30 min (cron)│  Honeypot Pi     │
  ┌──────────────────│  ~/snapshots/    │
  │ via scp          └──────────────────┘
  ▼
┌──────────────────┐   every 2 hrs    ┌──────────────────┐
│  Your laptop     │ ──────────────── │  USB stick       │
│  ~/scalpel-      │    manual         │  /scalpel-       │
│  snapshots/      │    usb_sync.sh    │  snapshots/      │
└──────────────────┘                   └──────────────────┘
                                                │
                                                │ if laptop dies
                                                ▼
                                       ┌──────────────────┐
                                       │  Teammate laptop │
                                       │  usb_restore.sh  │
                                       └──────────────────┘
```

Three independent locations. Any one can fail and you're still operational.

## Full workflow by phase

### Day 1, 09:15 — Before touching either Pi

**Clean Pi:**
```bash
# (Optional but recommended if you have a spare SD card + USB adapter.)
# Power down the clean Pi. Remove SD card. Plug into laptop via USB.
# Find the device: diskutil list (Mac) or lsblk (Linux)
sudo ./src/backup/image_sd_card.sh /dev/disk4 clean_pi_original.img
# → clean_pi_original.img.gz (~10-15GB compressed)
# Put SD card back in Pi. Power on.
```

**Honeypot Pi:**
```bash
# Same process with the honeypot Pi's SD card.
sudo ./src/backup/image_sd_card.sh /dev/disk4 honeypot_pi_original.img
```

If SD imaging is too slow to fit in the 30-minute window, skip it. The config snapshots below cover 95% of failure modes.

### Day 1, 09:45 — Right after ground-truth capture

On the clean Pi:
```bash
scp src/backup/backup_clean_pi.sh pi@<clean_pi>:~/
ssh pi@<clean_pi> 'bash ~/backup_clean_pi.sh'

# IMMEDIATELY pull the backup to your laptop:
scp pi@<clean_pi>:/tmp/clean_pi_backup.tgz ~/clean_pi_backup.tgz
# And to a teammate's laptop for redundancy:
scp pi@<clean_pi>:/tmp/clean_pi_backup.tgz <teammate_laptop>:~/
```

### Day 1, 10:00+ — Hourly honeypot Pi snapshots

On the honeypot Pi:
```bash
# Set the offsite backup destination (your laptop)
export BACKUP_DEST="rohan@<laptop_ip>:~/scalpel-snapshots/"
echo "export BACKUP_DEST='$BACKUP_DEST'" >> ~/.bashrc

# Install the cron (every 30 min during work hours)
(crontab -l 2>/dev/null; echo "*/30 8-19 * * * /home/cowrie/scalpel-kit/src/backup/snapshot.sh auto > /tmp/snapshot.log 2>&1") | crontab -

# Also take one right now, labeled
bash ~/scalpel-kit/src/backup/snapshot.sh "initial_deploy"
```

### Take manual snapshots at milestones

```bash
# After ground-truth ingested
bash ~/scalpel-kit/src/backup/snapshot.sh "after_ground_truth"

# After filesystem patches work
bash ~/scalpel-kit/src/backup/snapshot.sh "after_fs_patches"

# Before trying something risky
bash ~/scalpel-kit/src/backup/snapshot.sh "before_risky_change"

# End of Day 1, known-good final state
bash ~/scalpel-kit/src/backup/snapshot.sh "end_of_day1"
```

The labels are critical. When you restore, you'll pick by label.

### During the gauntlet — the panic button

Keep a tmux pane open with `panic` ready to go:

```bash
# In .bashrc (run once, Day 1 morning):
alias panic='bash /home/cowrie/scalpel-kit/src/backup/panic.sh --yes'
```

Then if Cowrie is broken and you have 30 seconds:

```bash
panic
```

This restores the most recent snapshot. If you want a specific snapshot:

```bash
bash ~/scalpel-kit/src/backup/restore.sh --list     # see what's available
bash ~/scalpel-kit/src/backup/panic.sh snap_20260423_143022_after_fs_patches.tgz
```

### USB sync — at natural breaks

Plug your USB in at these checkpoints:
- Day 1, 12:00 (lunch break) — first sync
- Day 1, 17:00 (before leaving venue) — **critical**, this survives laptop issues
- Day 2, 09:00 (arriving) — verify USB has yesterday's final state
- Day 2, 12:00 (lunch)
- Day 2, 14:30 (after awards) — final sync for portfolio

On your laptop (with USB plugged in):
```bash
cd scalpel-kit
bash src/backup/usb_sync.sh
# Auto-detects USB, copies all snapshots, verifies checksums
```

Takes <60 seconds if nothing new, <3 min if it's a fresh USB.

**The USB is what saves you if your laptop is stolen, dropped, or battery-dies with no charger.** After a 17:00 sync, your entire system state is portable — any teammate's laptop can take over in 15 minutes.

### USB restore — teammate laptop becomes primary

If your laptop dies (or gets stolen, or you forget the charger):

On the teammate's laptop:
```bash
git clone <team-repo> scalpel-kit   # or unzip the kit from USB
cd scalpel-kit
pip install paramiko flask requests

# Plug in the USB. Then:
bash src/backup/usb_restore.sh
```

This pulls all snapshots from USB to the new laptop's `~/scalpel-snapshots/`. The new laptop is now the primary. Update the Pi's `BACKUP_DEST` to point at it and you're running again.

## The snapshot contains

| What | Why |
|------|-----|
| `~/cowrie/etc/cowrie.cfg` | Main Cowrie config |
| `~/cowrie/etc/userdb.txt` | Honeypot user creds |
| `~/cowrie/share/cowrie/fs.pickle` | Virtual filesystem (fragile — top restore target) |
| `~/cowrie/honeyfs/` | File-contents layer (what `cat` returns) |
| `~/cowrie/share/cowrie/txtcmds/` | Canned command outputs |
| `~/cowrie/src/cowrie/commands/unattended.py` | Our custom command handler |
| `~/cowrie/src/cowrie/commands/__init__.py` | Commands registry (modified) |
| `~/cowrie/src/cowrie/commands/__init__.py.bak` | Pristine backup |
| `~/.local/lib/svcd/` | Our disguised router + ground truth data |
| `~/.bashrc` | Env vars (SVCD_*) |
| crontab | Keepalive cron |

What's NOT in the snapshot:
- Cowrie binaries (they don't change)
- Ollama binaries (same)
- LLM model weights (same)
- System packages (same)

This is why snapshots are small (~50MB) and fast.

## Restore cost analysis

| Scenario | Restore method | Downtime | Score cost |
|----------|---------------|----------|------------|
| Bad config edit | `restore.sh` | ~90 sec | ~2-3 probes missed (~3 pts) |
| fs.pickle corrupted | `restore.sh` | ~90 sec | ~2-3 probes missed |
| Broken system, during gauntlet | `panic` | ~45 sec | 1 crash penalty = -10 realism pts |
| SD card corrupted | Flash full image | ~60 min | Effectively out of gauntlet |

The math: during a 2-hour gauntlet, a 90-second restore costs ~1 probe's worth of data. A 45-second panic restore during the gauntlet costs 10 realism points (the crash penalty) but recovers you to a known-good state. Either is better than staying broken.

## Offsite storage matters

**Always have snapshots in two places minimum.** Options:

1. **Laptop** (via `BACKUP_DEST` in snapshot.sh)
2. **Teammate's laptop** (rsync periodically)
3. **USB stick** (manually, if network is flaky)
4. **A GitHub private repo** (commit snapshots, push every hour)

If the Pi dies catastrophically and your laptop is sitting 10 feet away in your bag, you're still operational. If the snapshot only exists on the Pi and the Pi is dead, you're done.

## Cron setup summary

Once set up, your crontab should look like this:

```cron
*/4 * * * * /home/cowrie/scalpel-kit/src/scripts/keepalive.sh > /dev/null 2>&1
*/30 8-19 * * * /home/cowrie/scalpel-kit/src/backup/snapshot.sh auto > /tmp/snap.log 2>&1
```

The snapshot cron only runs during working hours (8-19) so it doesn't run overnight when Cowrie is powered down anyway.
