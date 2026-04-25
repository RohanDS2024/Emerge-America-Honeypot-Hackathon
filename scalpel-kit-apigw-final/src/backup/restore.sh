#!/bin/bash
# Hardened restore. Validates tarball paths, verifies checksum,
# refuses to extract anything outside our allowed directories.
#
# Usage:
#   ./restore.sh                              # restore most recent
#   ./restore.sh snap_20260423_143022_*.tgz   # specific
#   ./restore.sh --list                       # list available

set -euo pipefail
umask 077

SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/snapshots}"

# Allow-list of path prefixes the snapshot may contain
ALLOWED_PREFIXES=(
    "home/cowrie/"
    "home/cowrie/cowrie/"
    "home/cowrie/.local/lib/svcd/"
    "home/cowrie/.bashrc"
    "home/cowrie/.bashrc.sanitized"
    "tmp/"  # for crontab.txt
)

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
    echo "Available snapshots in $SNAPSHOT_DIR:"
    ls -lht "$SNAPSHOT_DIR"/snap_*.tgz 2>/dev/null | head -20
    exit 0
fi

# Parse args robustly: --yes can appear in position 1 or 2
AUTO_YES=false
SNAPSHOT=""
for arg in "$@"; do
    case "$arg" in
        --yes) AUTO_YES=true ;;
        --list|-l) ;;  # already handled
        *) [ -z "$SNAPSHOT" ] && SNAPSHOT="$arg" ;;
    esac
done

if [ -z "$SNAPSHOT" ]; then
    SNAPSHOT=$(ls -1t "$SNAPSHOT_DIR"/snap_*.tgz 2>/dev/null | head -1 || echo "")
    if [ -z "$SNAPSHOT" ]; then
        echo "ERROR: No snapshots found in $SNAPSHOT_DIR"
        exit 1
    fi
    echo "Using most recent snapshot: $(basename $SNAPSHOT)"
fi

if [ ! -f "$SNAPSHOT" ]; then
    if [ -f "$SNAPSHOT_DIR/$SNAPSHOT" ]; then
        SNAPSHOT="$SNAPSHOT_DIR/$SNAPSHOT"
    else
        echo "ERROR: $SNAPSHOT not found"
        exit 1
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo " RESTORE FROM SNAPSHOT"
echo "═══════════════════════════════════════════════════════"
echo " Snapshot: $(basename $SNAPSHOT)"
echo " Size:     $(du -h $SNAPSHOT | cut -f1)"

# === Integrity check ===
echo ""
echo "[1/6] Verifying integrity..."
if [ ! -f "${SNAPSHOT}.sha256" ]; then
    echo "    ⚠️  No checksum file found. Snapshot integrity unverifiable."
    if [ "$AUTO_YES" = false ]; then
        read -p "    Continue anyway? [y/N] " ANS
        [ "$ANS" = "y" ] || exit 1
    fi
else
    EXPECTED=$(cat "${SNAPSHOT}.sha256")
    ACTUAL=$(sha256sum "$SNAPSHOT" | awk '{print $1}')
    if [ "$EXPECTED" != "$ACTUAL" ]; then
        echo "    ✗ CHECKSUM MISMATCH — snapshot is corrupt or tampered with."
        echo "      Expected: $EXPECTED"
        echo "      Actual:   $ACTUAL"
        echo "    REFUSING to restore."
        exit 1
    fi
    echo "    ✓ SHA-256 verified"
fi

# === Path validation ===
echo "[2/6] Validating tarball contents (rejecting traversal/absolute paths)..."
BAD_PATHS=$(tar tzf "$SNAPSHOT" 2>/dev/null | python3 -c "
import sys
allowed = $(printf '%s\n' "${ALLOWED_PREFIXES[@]}" | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin]))')
bad = []
for line in sys.stdin:
    p = line.strip().rstrip('/')
    if not p: continue
    # Reject absolute paths
    if p.startswith('/'):
        bad.append('absolute: ' + p); continue
    # Reject parent traversal
    if '..' in p.split('/'):
        bad.append('traversal: ' + p); continue
    # Must match an allowed prefix
    if not any(p.startswith(a) or p == a.rstrip('/') for a in allowed):
        bad.append('unallowed: ' + p)
for b in bad[:10]:
    print(b)
sys.exit(1 if bad else 0)
" 2>&1) || {
    echo "    ✗ Tarball contains disallowed paths:"
    echo "$BAD_PATHS" | sed 's/^/      /'
    echo "    REFUSING to restore."
    exit 1
}
echo "    ✓ All paths within allowed prefixes"

# === Show metadata ===
if [ -f "${SNAPSHOT}.meta" ]; then
    echo ""
    echo " Metadata:"
    grep -v "sha256:" "${SNAPSHOT}.meta" | sed 's/^/   /'
fi
echo "═══════════════════════════════════════════════════════"
echo ""

if [ "$AUTO_YES" = false ]; then
    read -p "Proceed with restore? [y/N] " CONFIRM
    [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || exit 1
fi

echo "[3/6] Stopping Cowrie..."
~/cowrie/bin/cowrie stop 2>&1 || true
sleep 2

echo "[4/6] Taking safety snapshot of CURRENT state (in case restore is wrong)..."
bash "$(dirname $0)/snapshot.sh" "safety_before_restore" > /dev/null 2>&1 || true

echo "[5/6] Extracting snapshot to / ..."
# tar is given relative paths only (validated above), so it extracts under /
# Use --no-overwrite-dir to preserve dir perms; --keep-newer-files would be
# wrong here since we WANT to overwrite with the snapshot's contents.
cd /
if ! tar xzf "$SNAPSHOT" 2>&1 | tail -5; then
    echo "ERROR: extraction failed; restarting Cowrie to minimize downtime..."
    ~/cowrie/bin/cowrie start
    exit 1
fi

# Re-install crontab if present
if [ -f "/tmp/crontab.txt" ]; then
    crontab "/tmp/crontab.txt" 2>/dev/null || true
    rm -f /tmp/crontab.txt
fi

# Sanitized .bashrc came in as .bashrc.sanitized — promote it
if [ -f "$HOME/.bashrc.sanitized" ]; then
    # Preserve any cloud URL line that's currently active
    CLOUD_LINE=$(grep "SVCD_CLOUD_URL" "$HOME/.bashrc" 2>/dev/null || true)
    cp "$HOME/.bashrc.sanitized" "$HOME/.bashrc"
    [ -n "$CLOUD_LINE" ] && echo "$CLOUD_LINE" >> "$HOME/.bashrc"
    rm -f "$HOME/.bashrc.sanitized"
fi

echo "[6/6] Restarting Cowrie..."
~/cowrie/bin/cowrie start

# Wait for Cowrie to be responsive
for i in 1 2 3 4 5; do
    sleep 2
    if ~/cowrie/bin/cowrie status > /dev/null 2>&1; then
        echo ""
        echo "✓ Cowrie is back up."
        break
    fi
done

echo ""
echo "Re-warming LLM..."
curl -s -X POST http://localhost:11434/api/generate \
    -d '{"model":"qwen2.5:1.5b","prompt":"a","keep_alive":"24h","stream":false,"options":{"num_predict":1}}' \
    > /dev/null 2>&1 || true

echo ""
echo "═══════════════════════════════════════════════════════"
echo " RESTORE COMPLETE"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Verify:"
echo "  ssh root@\$(hostname -I | awk '{print \$1}') -p 2222"
echo ""
echo "If wrong, restore the safety snapshot:"
echo "  $0 \$(ls -1t $SNAPSHOT_DIR/snap_*safety_before_restore*.tgz | head -1)"
echo ""
echo "NOTE: auth.token was NOT in the snapshot (by design)."
echo "      If router can't reach cloud, re-run: echo TOKEN > ~/.local/lib/svcd/auth.token"
