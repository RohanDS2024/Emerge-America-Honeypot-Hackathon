#!/bin/bash
# Ingest ground truth captures into SVCD's data dir.
# Run on the honeypot Pi as the cowrie user.
#
# Usage: ./ingest_data.sh [path/to/groundtruth.tgz]

set -e

ARCHIVE="${1:-$HOME/groundtruth.tgz}"
DATA_DIR="$HOME/.local/lib/svcd/data"
COWRIE_HONEYFS="$HOME/cowrie/honeyfs"

if [ ! -f "$ARCHIVE" ]; then
    echo "ERROR: $ARCHIVE not found"
    echo "Usage: $0 [path/to/groundtruth.tgz]"
    exit 1
fi

# 1. Extract to staging dir first, validate, then swap
echo "[1/4] Extracting captures to staging area ..."
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM

tar xzf "$ARCHIVE" -C "$STAGE"

# Validate the extraction has what we expect
if [ ! -d "$STAGE/groundtruth" ]; then
    echo "ERROR: Archive doesn't contain a groundtruth/ directory"
    exit 1
fi
if [ ! -f "$STAGE/groundtruth/manifest.json" ]; then
    echo "ERROR: manifest.json missing from archive"
    exit 1
fi
stage_count=$(ls "$STAGE"/groundtruth/cmd_*.txt 2>/dev/null | wc -l)
if [ "$stage_count" -eq 0 ]; then
    echo "ERROR: No command captures (cmd_*.txt) found in archive"
    exit 1
fi
echo "    → Validated: $stage_count command captures in archive"

# Safe swap: back up existing data, then move new data in
mkdir -p "$DATA_DIR"
if [ "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    BACKUP_OLD="$DATA_DIR.old.$(date +%s)"
    mv "$DATA_DIR" "$BACKUP_OLD"
    echo "    → Previous data backed up to $(basename $BACKUP_OLD)"
    mkdir -p "$DATA_DIR"
fi
mv "$STAGE"/groundtruth/* "$DATA_DIR/"

count=$(ls "$DATA_DIR"/cmd_*.txt 2>/dev/null | wc -l)
echo "    → Installed $count command captures"
echo "[2/4] Manifest OK"

# 3. Populate honeyfs with file contents (so cat works correctly)
echo "[3/4] Populating Cowrie honeyfs..."
if [ -d "$DATA_DIR/files" ]; then
    for f in os-release passwd hostname debian_version issue group shells timezone; do
        src=$(find "$DATA_DIR/files" -name "*${f}*" 2>/dev/null | head -1)
        if [ -n "$src" ]; then
            mkdir -p "$COWRIE_HONEYFS/etc"
            cp "$src" "$COWRIE_HONEYFS/etc/$f"
            echo "    → honeyfs/etc/$f"
        fi
    done

    src=$(find "$DATA_DIR/files" -name "*config.txt*" 2>/dev/null | head -1)
    if [ -n "$src" ]; then
        mkdir -p "$COWRIE_HONEYFS/boot/firmware"
        cp "$src" "$COWRIE_HONEYFS/boot/firmware/config.txt"
        echo "    → honeyfs/boot/firmware/config.txt"
    fi
fi

# 4. Drop a believable bash_history
mkdir -p "$COWRIE_HONEYFS/home/pi"
cat > "$COWRIE_HONEYFS/home/pi/.bash_history" <<'EOF'
sudo apt update
sudo apt upgrade -y
df -h
free -h
htop
sudo systemctl status nginx
sudo systemctl restart nginx
tail -f /var/log/nginx/error.log
nano /etc/nginx/sites-available/default
sudo nginx -t
sudo systemctl reload nginx
git pull
cd /opt/app
ls -la
sudo journalctl -u nginx -n 50
ip a
ping -c 3 8.8.8.8
sudo apt install -y vim curl wget
crontab -l
ls /var/log/
sudo tail /var/log/auth.log
exit
EOF
echo "    → honeyfs/home/pi/.bash_history"

echo ""
echo "[4/4] Data ingested."
echo "Restart Cowrie: ~/cowrie/bin/cowrie restart"
