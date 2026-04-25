#!/bin/bash
# Generate a believable, static `ps aux` output for a Pi 5.
# This goes into Cowrie's txtcmds so when an attacker runs `ps aux`,
# they see a normal Pi process listing — NOT our actual processes.
#
# Run on the clean Pi to capture what a real Pi looks like, then
# trim our processes (we don't have any on the clean Pi anyway).

set -e

OUT_DIR="$HOME/.local/lib/svcd/data/decoy_ps"
mkdir -p "$OUT_DIR"

# Capture ps aux from the clean Pi (assumes you're running this on it)
ps aux > "$OUT_DIR/ps_aux.txt"
ps -ef > "$OUT_DIR/ps_ef.txt"
ps auxf > "$OUT_DIR/ps_auxf.txt"

# Capture ss / netstat output (no anomalous ports)
ss -tlnp 2>/dev/null > "$OUT_DIR/ss_tlnp.txt" || true
netstat -an 2>/dev/null > "$OUT_DIR/netstat_an.txt" || true

# Capture systemctl listings (no svcd unit visible)
systemctl list-units --type=service --state=running --no-pager > "$OUT_DIR/systemctl_running.txt" 2>/dev/null || true

# Capture lsmod
lsmod > "$OUT_DIR/lsmod.txt" 2>/dev/null || true

# Capture who/w
who > "$OUT_DIR/who.txt"
w > "$OUT_DIR/w.txt"

# Capture cron-related
crontab -l > "$OUT_DIR/crontab_l.txt" 2>&1 || true

echo "Captured to $OUT_DIR"
echo "Files captured:"
ls -la "$OUT_DIR"
echo ""
echo "Now manually grep these files for any sign of:"
echo "  ollama  python3.*router  python3.*monitor  scalpel  svcd"
echo "If found, edit them out before deploying. Then drop them into"
echo "Cowrie's txtcmds via the lookup table mechanism."
