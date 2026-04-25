#!/bin/bash
# Clean Pi backup — the ground-truth insurance.
# Run this IMMEDIATELY AFTER ground truth capture, BEFORE anything
# else touches the clean Pi.
#
# The clean Pi is your test oracle. If it's accidentally modified
# (or someone `rm -rf /etc/`s it) you lose:
#   1. Ability to re-capture ground truth
#   2. Ability to run the self-gauntlet's diff comparison
#
# Both are catastrophic. This script creates a restorable tarball
# of the clean Pi's critical dirs.
#
# Usage (run ON the clean Pi):
#   ./backup_clean_pi.sh
#
# Output goes to /tmp/clean_pi_backup.tgz — scp it to your laptop
# IMMEDIATELY after it's created.

set -e

OUT="/tmp/clean_pi_backup.tgz"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

echo "═══════════════════════════════════════════════════════"
echo " CLEAN PI BACKUP"
echo "═══════════════════════════════════════════════════════"
echo ""

# 1. Capture filesystem metadata listing (for later comparison)
echo "[1/4] Capturing filesystem listing..."
sudo find / -xdev -type f -printf '%p|%s|%T@|%m|%u|%g\n' 2>/dev/null > /tmp/clean_pi_files.txt

# 2. Tar up the critical dirs we'd ever need to restore or re-capture
echo "[2/4] Creating backup tarball..."
sudo tar czf "$OUT" \
    --exclude='/home/pi/.cache' \
    --exclude='/var/log/*.gz' \
    --exclude='/var/log/*.1' \
    --exclude='/var/cache' \
    --exclude='/var/lib/apt/lists' \
    /etc /home /root /boot/firmware \
    /var/log/syslog /var/log/auth.log /var/log/dpkg.log \
    /tmp/clean_pi_files.txt \
    2>/dev/null || echo "(some files skipped due to permissions)"

# 3. Also capture everything we need for ground truth re-capture
echo "[3/4] Capturing system state..."
{
    echo "=== CLEAN PI STATE CAPTURE ==="
    echo "timestamp: $TIMESTAMP"
    echo "hostname: $(hostname)"
    echo "kernel: $(uname -a)"
    echo ""
    echo "=== /etc/os-release ==="
    cat /etc/os-release
    echo ""
    echo "=== /etc/debian_version ==="
    cat /etc/debian_version
    echo ""
    echo "=== lsb_release -a ==="
    lsb_release -a 2>&1
    echo ""
    echo "=== /proc/cpuinfo ==="
    cat /proc/cpuinfo
    echo ""
    echo "=== /proc/meminfo ==="
    cat /proc/meminfo
    echo ""
    echo "=== df -h ==="
    df -h
    echo ""
    echo "=== dpkg -l (top 50) ==="
    dpkg -l 2>/dev/null | head -50
    echo ""
    echo "=== systemctl list-units --state=running ==="
    systemctl list-units --state=running --no-pager 2>/dev/null | head -30
} > /tmp/clean_pi_state.txt

# Now rebuild the tarball with state file included
echo "    Including state capture in tarball..."
sudo tar czf "$OUT" \
    --exclude='/home/pi/.cache' \
    --exclude='/var/log/*.gz' \
    --exclude='/var/log/*.1' \
    --exclude='/var/cache' \
    --exclude='/var/lib/apt/lists' \
    /etc /home /root /boot/firmware \
    /var/log/syslog /var/log/auth.log /var/log/dpkg.log \
    /tmp/clean_pi_files.txt \
    /tmp/clean_pi_state.txt \
    2>/dev/null || echo "(some files skipped due to permissions)"

SIZE=$(du -h "$OUT" | cut -f1)
echo "[4/4] Done. Backup size: $SIZE"

sudo chown $USER:$USER "$OUT" 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════"
echo " BACKUP COMPLETE"
echo "═══════════════════════════════════════════════════════"
echo ""
echo " File: $OUT"
echo " Size: $SIZE"
echo ""
echo " IMMEDIATELY scp this to TWO places:"
echo "   scp pi@\$(hostname -I | awk '{print \$1}'):$OUT ~/clean_pi_backup_laptop1.tgz"
echo "   scp pi@\$(hostname -I | awk '{print \$1}'):$OUT ~/clean_pi_backup_laptop2.tgz"
echo ""
echo " Or to a USB stick:"
echo "   cp $OUT /media/usb/"
echo ""
echo " Label the backup with the Pi's IP and timestamp."
echo ""
echo "═══════════════════════════════════════════════════════"
echo " HOW TO RESTORE (if the clean Pi gets corrupted):"
echo "═══════════════════════════════════════════════════════"
echo ""
echo " 1. scp clean_pi_backup.tgz pi@<pi>:/tmp/"
echo " 2. On clean Pi: sudo tar xzf /tmp/clean_pi_backup.tgz -C /"
echo " 3. Reboot: sudo reboot"
echo ""
echo " (For faster partial restore of /etc only:)"
echo "   sudo tar xzf /tmp/clean_pi_backup.tgz -C / etc/"
