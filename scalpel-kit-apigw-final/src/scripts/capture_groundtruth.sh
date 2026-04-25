#!/bin/bash
# Capture ground truth from the clean Pi.
# Run on the CLEAN PI (the one without Cowrie).
#
# Usage:
#   ./capture_groundtruth.sh
#
# Output:
#   /tmp/groundtruth/        — directory of .txt files, one per command
#   /tmp/groundtruth/manifest.json — maps commands to filenames
#   /tmp/groundtruth.tgz     — tarball ready to scp

set -e
OUT="/tmp/groundtruth"
rm -rf "$OUT"
mkdir -p "$OUT"

# Commands to capture. Add more as you discover what the Red Team probes.
COMMANDS=(
  "uname -a"
  "uname -r"
  "uname -m"
  "uname -s"
  "uname -n"
  "hostname"
  "whoami"
  "id"
  "id -u"
  "id -g"
  "pwd"
  "uptime"
  "uptime -p"
  "date"
  "date +%Y"
  "echo \$SHELL"
  "echo \$USER"
  "echo \$HOME"
  "echo \$PATH"
  "echo \$PWD"
  "cat /etc/os-release"
  "cat /etc/hostname"
  "cat /etc/debian_version"
  "cat /etc/issue"
  "cat /etc/passwd"
  "cat /etc/group"
  "cat /etc/shells"
  "cat /etc/timezone"
  "ls /"
  "ls /home"
  "ls /root"
  "ls /etc"
  "ls /var"
  "ls /tmp"
  "ls /opt"
  "ls /boot"
  "ls /boot/firmware"
  "ls -la"
  "ls -la /"
  "ls -la /home"
  "ls -la /root"
  "ls -la /etc/ssh"
  "df -h"
  "df -h /"
  "free -h"
  "free -m"
  "lscpu"
  "lsb_release -a"
  "lsb_release -d"
  "lsb_release -i"
  "which python3"
  "which bash"
  "which sudo"
  "which curl"
  "env"
  "cat /proc/cpuinfo"
  "cat /proc/meminfo"
  "cat /proc/version"
  "cat /proc/uptime"
  "ip a"
  "ip route"
  "ip link"
  "hostnamectl"
  "timedatectl"
  "bash --version"
  "type cd"
  "type ls"
  "type echo"
  "command -v sudo"
  "ls /etc/systemd/system"
  "systemctl --version"
  "ps -ef"
  "ps aux"
)

# Build manifest as we go
MANIFEST="$OUT/manifest.json"
echo "{" > "$MANIFEST"
FIRST=1

for cmd in "${COMMANDS[@]}"; do
  # Generate a stable filename hash
  fname="cmd_$(echo -n "$cmd" | md5sum | cut -c1-12).txt"

  # Run and capture output (stdout + stderr)
  # Using bash -c instead of eval — safer, limits scope to a subshell
  bash -c "$cmd" > "$OUT/$fname" 2>&1 || true

  # Append to manifest (escape command for JSON)
  esc=$(printf '%s' "$cmd" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
  if [ $FIRST -eq 1 ]; then
    FIRST=0
  else
    echo "," >> "$MANIFEST"
  fi
  printf '  %s: "%s"' "$esc" "$fname" >> "$MANIFEST"
done

echo "" >> "$MANIFEST"
echo "}" >> "$MANIFEST"

# Also capture key files attackers will cat
echo "Capturing key file contents..."
mkdir -p "$OUT/files"
for f in /etc/os-release /etc/passwd /etc/hostname /etc/debian_version \
         /etc/issue /etc/group /etc/shells /etc/timezone \
         /boot/firmware/config.txt /boot/firmware/cmdline.txt \
         /home/pi/.bashrc /home/pi/.profile; do
  if [ -r "$f" ]; then
    dest="$OUT/files$(echo $f | tr -c 'a-zA-Z0-9._/' '_')"
    mkdir -p "$(dirname $dest)"
    cp "$f" "$dest" 2>/dev/null || true
  fi
done

# Filesystem snapshot for fs.pickle generation
echo "Snapshotting filesystem metadata..."
sudo find /etc /home /root /var/log -xdev -printf '%p|%s|%T@|%m|%u|%g\n' 2>/dev/null > "$OUT/fs_snapshot.txt" || \
     find /etc /home /root /var/log -xdev -printf '%p|%s|%T@|%m\n' 2>/dev/null > "$OUT/fs_snapshot.txt"

# Tarball
cd /tmp
tar czf groundtruth.tgz groundtruth/

echo ""
echo "✓ Captured ${#COMMANDS[@]} commands"
echo "✓ Manifest: $MANIFEST"
echo "✓ Tarball: /tmp/groundtruth.tgz ($(du -h /tmp/groundtruth.tgz | cut -f1))"
echo ""
echo "Next: scp /tmp/groundtruth.tgz cowrie@<honeypot_pi>:~/"
