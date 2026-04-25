#!/bin/bash
# USB restore — rebuild the snapshot collection from USB onto a fresh laptop.
#
# Run this if:
#   - Your laptop dies and you need to continue on a teammate's laptop
#   - You want to verify a snapshot on the USB is good before trusting it
#   - You're setting up a new laptop and need all historical snapshots
#
# Usage:
#   ./usb_restore.sh                        # auto-detect USB, restore to ~/scalpel-snapshots/
#   ./usb_restore.sh /Volumes/SCALPEL       # explicit USB path
#   ./usb_restore.sh --to /tmp/restored     # restore to custom dir

set -euo pipefail

USB_PATH=""
DEST_DIR="$HOME/scalpel-snapshots"

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --to)
            DEST_DIR="$2"
            shift 2
            ;;
        --help|-h)
            head -15 "$0" | tail -13
            exit 0
            ;;
        *)
            [ -z "$USB_PATH" ] && USB_PATH="$1"
            shift
            ;;
    esac
done

# ============================================================
# 1. Locate USB
# ============================================================

if [ -z "$USB_PATH" ]; then
    case "$(uname)" in
        Darwin)
            for v in /Volumes/*; do
                [ -d "$v/scalpel-snapshots" ] && USB_PATH="$v" && break
            done
            ;;
        Linux)
            for base in "/media/$USER" "/run/media/$USER"; do
                [ -d "$base" ] || continue
                for v in "$base"/*; do
                    [ -d "$v/scalpel-snapshots" ] && USB_PATH="$v" && break 2
                done
            done
            ;;
    esac
fi

if [ -z "$USB_PATH" ] || [ ! -d "$USB_PATH/scalpel-snapshots" ]; then
    echo "Couldn't find a USB drive with scalpel-snapshots/ folder."
    echo "Plug in the USB and re-run, or pass the path:"
    echo "  $0 /Volumes/YOUR_USB"
    exit 1
fi

SRC_DIR="$USB_PATH/scalpel-snapshots"

# ============================================================
# 2. Show what's on the USB
# ============================================================

echo ""
echo "═══════════════════════════════════════════════════════"
echo " USB RESTORE"
echo "═══════════════════════════════════════════════════════"
echo " USB:          $SRC_DIR"
echo " Destination:  $DEST_DIR"
echo ""

if [ -f "$SRC_DIR/MANIFEST.txt" ]; then
    echo " USB manifest:"
    head -6 "$SRC_DIR/MANIFEST.txt" | sed 's/^/   /'
    echo ""
fi

SNAPSHOTS=$(ls "$SRC_DIR"/snap_*.tgz 2>/dev/null | wc -l | tr -d ' ')
echo " Snapshots on USB: $SNAPSHOTS"
echo " Latest 5:"
ls -lht "$SRC_DIR"/snap_*.tgz 2>/dev/null | head -5 | sed 's/^/   /'

# ============================================================
# 3. Verify checksums BEFORE restoring
# ============================================================

echo ""
echo "Verifying checksums on USB (refusing to restore corrupted data)..."
FAILED=0
PASSED=0
for tgz in "$SRC_DIR"/snap_*.tgz; do
    [ -f "$tgz" ] || continue
    sha_file="${tgz}.sha256"
    if [ ! -f "$sha_file" ]; then
        echo "  ⚠️  $(basename $tgz): no checksum (will skip)"
        continue
    fi
    expected=$(cat "$sha_file")
    actual=$(shasum -a 256 "$tgz" 2>/dev/null | awk '{print $1}' || \
             sha256sum "$tgz" 2>/dev/null | awk '{print $1}')
    if [ "$expected" = "$actual" ]; then
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ $(basename $tgz): CHECKSUM MISMATCH — will NOT copy"
        FAILED=$((FAILED + 1))
    fi
done

echo "  → $PASSED verified, $FAILED corrupt"

if [ "$FAILED" -gt 0 ] && [ "$PASSED" -eq 0 ]; then
    echo ""
    echo " ✗ No valid snapshots on this USB. Aborting."
    exit 1
fi

# ============================================================
# 4. Confirm, then copy
# ============================================================

echo ""
read -p "Copy $PASSED verified snapshots to $DEST_DIR? [y/N] " CONFIRM
[ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || exit 1

mkdir -p "$DEST_DIR"

COPIED=0
SKIPPED=0
for tgz in "$SRC_DIR"/snap_*.tgz; do
    [ -f "$tgz" ] || continue
    sha_file="${tgz}.sha256"
    meta_file="${tgz}.meta"

    # Only copy if we have a verified checksum
    if [ ! -f "$sha_file" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    expected=$(cat "$sha_file")
    actual=$(shasum -a 256 "$tgz" 2>/dev/null | awk '{print $1}' || \
             sha256sum "$tgz" 2>/dev/null | awk '{print $1}')
    [ "$expected" != "$actual" ] && continue

    base=$(basename "$tgz")
    # Skip if already present and checksum matches
    if [ -f "$DEST_DIR/$base" ]; then
        local_actual=$(shasum -a 256 "$DEST_DIR/$base" 2>/dev/null | awk '{print $1}' || \
                       sha256sum "$DEST_DIR/$base" 2>/dev/null | awk '{print $1}')
        if [ "$local_actual" = "$expected" ]; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi

    cp "$tgz" "$sha_file" "$DEST_DIR/" 2>/dev/null
    [ -f "$meta_file" ] && cp "$meta_file" "$DEST_DIR/"
    COPIED=$((COPIED + 1))
done

# Also grab clean_pi_backup if present
for f in "$SRC_DIR"/clean_pi_backup*.tgz; do
    [ -f "$f" ] || continue
    cp "$f" "$DEST_DIR/"
done

echo ""
echo "═══════════════════════════════════════════════════════"
echo " RESTORE TO LAPTOP COMPLETE"
echo "═══════════════════════════════════════════════════════"
echo " Copied:  $COPIED new snapshots"
echo " Skipped: $SKIPPED (already present)"
echo " Dest:    $DEST_DIR"
echo "═══════════════════════════════════════════════════════"
echo ""
echo " Next: to push a snapshot to a Pi, run:"
echo ""
echo "   scp $DEST_DIR/snap_LATEST.tgz cowrie@<pi>:~/snapshots/"
echo "   scp $DEST_DIR/snap_LATEST.tgz.sha256 cowrie@<pi>:~/snapshots/"
echo "   ssh cowrie@<pi> 'bash ~/scalpel-kit/src/backup/restore.sh'"
