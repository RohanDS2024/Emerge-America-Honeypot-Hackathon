# fs_assets/ — files for Cowrie's virtual filesystem

This directory is for staging files you want to drop into Cowrie's
`honeyfs/` (the contents layer that backs `cat`).

## How Cowrie's filesystem works

Cowrie has TWO filesystem layers:
1. **fs.pickle** — metadata layer (file names, sizes, perms, timestamps) shown by `ls`
2. **honeyfs/** — contents layer (actual bytes returned by `cat`)

Both must be consistent. If `ls /etc/` shows `os-release` but `cat /etc/os-release` returns empty, that's a finding.

## Workflow (already wired by ingest_groundtruth.sh)

1. `capture_groundtruth.sh` on the clean Pi captures `/etc/`, `/home/pi/`, etc.
2. `ingest_groundtruth.sh` on the honeypot Pi:
   - Extracts captures to `~/scalpel/ground_truth/`
   - Copies critical file contents to `~/cowrie/honeyfs/etc/`
   - Drops a synthetic `~/cowrie/honeyfs/home/pi/.bash_history`

## Critical files (verified by self-gauntlet)

| File | Why |
|------|-----|
| `/etc/os-release` | Bookworm fingerprint check |
| `/etc/debian_version` | Confirms Bookworm |
| `/etc/hostname` | Says `raspberrypi` |
| `/etc/passwd` | Real Pi user list (pi, _apt, systemd-*) |
| `/etc/issue` | Greeting screen text |
| `/proc/cpuinfo` | BCM2712 / Cortex-A76 — Pi 5 specific |
| `/boot/firmware/config.txt` | Pi-specific boot params |
| `/home/pi/.bash_history` | Plausible admin history |

## The .bash_history honeypot trick

The `ingest_groundtruth.sh` script drops a synthetic bash history with realistic admin commands. A real Pi has command history; an empty one is suspicious. Customize the script if you want different content.

## Adding more files

If the self-gauntlet shows a `filesystem_mismatch` finding, manually copy the correct file:

```bash
ssh pi@<clean_pi> 'cat /etc/some/file' > /tmp/some_file
scp /tmp/some_file cowrie@<honeypot>:~/cowrie/honeyfs/etc/some/file
ssh cowrie@<honeypot> '~/cowrie/bin/cowrie restart'
```
