#!/bin/bash
# Hardened config snapshot.
# Excludes secrets (auth.token), redacts SVCD_CLOUD_URL from .bashrc,
# uses mktemp for temp files, computes SHA-256 for integrity, sets 600 perms.
#
# Usage:
#   ./snapshot.sh
#   ./snapshot.sh "before filesystem patches"   # optional label

set -euo pipefail

# Strict perms on everything we create
umask 077

LABEL="${1:-manual}"
LABEL_SAFE=$(echo "$LABEL" | tr ' /' '__' | tr -cd '[:alnum:]_-')
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/snapshots}"
mkdir -p "$SNAPSHOT_DIR"
chmod 700 "$SNAPSHOT_DIR"

OUT="$SNAPSHOT_DIR/snap_${TIMESTAMP}_${LABEL_SAFE}.tgz"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

echo "[1/4] Gathering files..."

# Sanitize .bashrc: remove the SVCD_CLOUD_URL line so the URL doesn't leak in snapshots
SAN_BASHRC="$TMPDIR/.bashrc.sanitized"
if [ -f "$HOME/.bashrc" ]; then
    grep -v "SVCD_CLOUD_URL" "$HOME/.bashrc" > "$SAN_BASHRC" || true
fi

INCLUDES=()

# Cowrie config and custom commands
for f in \
    "$HOME/cowrie/etc/cowrie.cfg" \
    "$HOME/cowrie/etc/userdb.txt" \
    "$HOME/cowrie/share/cowrie/fs.pickle" \
    "$HOME/cowrie/src/cowrie/commands/unattended.py" \
    "$HOME/cowrie/src/cowrie/commands/__init__.py" \
    "$HOME/cowrie/src/cowrie/commands/__init__.py.bak" \
; do
    [ -e "$f" ] && INCLUDES+=("$f")
done

[ -d "$HOME/cowrie/honeyfs" ] && INCLUDES+=("$HOME/cowrie/honeyfs")
[ -d "$HOME/cowrie/share/cowrie/txtcmds" ] && INCLUDES+=("$HOME/cowrie/share/cowrie/txtcmds")

# SVCD install — but EXCLUDE auth.token (secret, not for snapshots)
if [ -d "$HOME/.local/lib/svcd" ]; then
    # Build a temp staging dir that mirrors svcd EXCEPT auth.token
    SVCD_STAGE="$TMPDIR/svcd"
    mkdir -p "$SVCD_STAGE"
    # rsync would be cleaner but may not be installed; cp + delete works
    cp -a "$HOME/.local/lib/svcd/." "$SVCD_STAGE/"
    rm -f "$SVCD_STAGE/auth.token"
    INCLUDES+=("$SVCD_STAGE")
fi

# Use sanitized bashrc
[ -f "$SAN_BASHRC" ] && INCLUDES+=("$SAN_BASHRC")

# Crontab
CRON_TMP="$TMPDIR/crontab.txt"
if crontab -l > "$CRON_TMP" 2>/dev/null; then
    INCLUDES+=("$CRON_TMP")
fi

if [ ${#INCLUDES[@]} -eq 0 ]; then
    echo "ERROR: Nothing to snapshot. Has anything been deployed?"
    exit 1
fi

echo "[2/4] Creating tarball..."
# --absolute-names disabled by default; tar will record relative paths.
# --exclude patterns handle anything we missed.
tar czf "$OUT" \
    --exclude='*.pyc' \
    --exclude='__pycache__' \
    --exclude='auth.token' \
    "${INCLUDES[@]}" 2>/dev/null
chmod 600 "$OUT"

SIZE=$(du -h "$OUT" | cut -f1)
echo "    → $OUT ($SIZE)"

echo "[3/4] Computing checksum..."
sha256sum "$OUT" | awk '{print $1}' > "${OUT}.sha256"
chmod 600 "${OUT}.sha256"

# Metadata sidecar
cat > "${OUT}.meta" <<EOF
timestamp: $TIMESTAMP
label: $LABEL
host: $(hostname)
user: $USER
sha256: $(cat ${OUT}.sha256)
size_bytes: $(stat -c %s "$OUT")
cowrie_status: $(~/cowrie/bin/cowrie status 2>/dev/null || echo unknown)
ollama_model_loaded: $(curl -s http://localhost:11434/api/ps 2>/dev/null | grep -c qwen || echo 0)
includes:
$(printf '  - %s\n' "${INCLUDES[@]}")
EOF
chmod 600 "${OUT}.meta"

# Transfer offsite
if [ -n "${BACKUP_DEST:-}" ]; then
    echo "[4/4] Transferring to $BACKUP_DEST ..."
    if scp -q -o StrictHostKeyChecking=accept-new "$OUT" "${OUT}.sha256" "${OUT}.meta" "$BACKUP_DEST" 2>/dev/null; then
        echo "    → transferred"
    else
        echo "    ⚠️  transfer failed (local copy preserved)"
    fi
else
    echo "[4/4] (BACKUP_DEST not set, skipping offsite transfer)"
fi

# Retention: keep last 20 snapshots locally, cap total at 1GB
ls -1t "$SNAPSHOT_DIR"/snap_*.tgz 2>/dev/null | tail -n +21 | while read f; do
    rm -f "$f" "${f}.sha256" "${f}.meta"
done

# Hard cap: if dir exceeds 1GB, delete oldest until under
while [ "$(du -sm $SNAPSHOT_DIR | cut -f1)" -gt 1024 ]; do
    OLDEST=$(ls -1tr "$SNAPSHOT_DIR"/snap_*.tgz 2>/dev/null | head -1)
    [ -z "$OLDEST" ] && break
    rm -f "$OLDEST" "${OLDEST}.sha256" "${OLDEST}.meta"
done

echo ""
echo "Local snapshots:"
ls -lht "$SNAPSHOT_DIR"/snap_*.tgz 2>/dev/null | head -5
