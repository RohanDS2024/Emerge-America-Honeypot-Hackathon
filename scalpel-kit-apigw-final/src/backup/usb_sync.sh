#!/bin/bash
# USB sync — copy all snapshots from laptop to a USB drive.
#
# Workflow:
#   - Snapshots auto-sync from Pi to laptop every 30 min (via BACKUP_DEST scp)
#   - At natural breaks (lunch, end of day, leaving venue) plug in USB
#   - Run this script. It syncs everything new to the USB.
#
# Usage:
#   ./usb_sync.sh                          # auto-detect USB, interactive
#   ./usb_sync.sh /Volumes/SCALPEL         # explicit path (Mac)
#   ./usb_sync.sh /media/rohan/SCALPEL     # explicit path (Linux)
#
# The USB drive should have a folder named "scalpel-snapshots/" at root.
# If it doesn't exist, this script creates it.

set -euo pipefail

SRC_DIR="${SRC_DIR:-$HOME/scalpel-snapshots}"
USB_PATH="${1:-}"

# ============================================================
# 1. Find the USB drive
# ============================================================

if [ -z "$USB_PATH" ]; then
    echo "Auto-detecting USB drive..."

    CANDIDATES=()
    case "$(uname)" in
        Darwin)
            # Mac: /Volumes/<name>
            for v in /Volumes/*; do
                [ -d "$v" ] || continue
                # Skip internal disk
                [ "$v" = "/Volumes/Macintosh HD" ] && continue
                CANDIDATES+=("$v")
            done
            ;;
        Linux)
            # Linux: /media/$USER/<name> or /run/media/$USER/<name>
            for base in "/media/$USER" "/run/media/$USER"; do
                [ -d "$base" ] || continue
                for v in "$base"/*; do
                    [ -d "$v" ] && CANDIDATES+=("$v")
                done
            done
            ;;
        *)
            echo "Unsupported OS: $(uname). Pass USB path explicitly."
            exit 1
            ;;
    esac

    if [ ${#CANDIDATES[@]} -eq 0 ]; then
        echo "No USB drive detected."
        echo ""
        echo "Mac:   plug in USB, verify it shows in Finder sidebar"
        echo "Linux: plug in USB, run 'lsblk' to confirm it's mounted"
        echo ""
        echo "Then re-run this script, or pass the path explicitly:"
        echo "  $0 /Volumes/YOUR_USB"
        exit 1
    fi

    if [ ${#CANDIDATES[@]} -eq 1 ]; then
        USB_PATH="${CANDIDATES[0]}"
        echo "Found USB: $USB_PATH"
    else
        echo "Multiple mounted drives detected. Pick one:"
        for i in "${!CANDIDATES[@]}"; do
            echo "  $((i+1))) ${CANDIDATES[$i]}"
        done
        read -p "Choice [1]: " CHOICE
        CHOICE=${CHOICE:-1}
        USB_PATH="${CANDIDATES[$((CHOICE-1))]}"
    fi
fi

if [ ! -d "$USB_PATH" ]; then
    echo "ERROR: $USB_PATH is not a directory or isn't mounted"
    exit 1
fi

# ============================================================
# 2. Verify source and prep destination
# ============================================================

if [ ! -d "$SRC_DIR" ]; then
    echo "ERROR: $SRC_DIR doesn't exist"
    echo "       Is BACKUP_DEST on the Pi pointing to this laptop?"
    exit 1
fi

DEST_DIR="$USB_PATH/scalpel-snapshots"
mkdir -p "$DEST_DIR"

# Check free space on USB
case "$(uname)" in
    Darwin)
        FREE_MB=$(df -m "$USB_PATH" | tail -1 | awk '{print $4}')
        ;;
    Linux)
        FREE_MB=$(df -BM "$USB_PATH" | tail -1 | awk '{print $4}' | tr -d 'M')
        ;;
esac

SRC_MB=$(du -sm "$SRC_DIR" | cut -f1)
echo ""
echo "Source:      $SRC_DIR (${SRC_MB}MB)"
echo "Destination: $DEST_DIR"
echo "USB free:    ${FREE_MB}MB"

if [ "$FREE_MB" -lt "$SRC_MB" ]; then
    echo ""
    echo "⚠️  USB has less free space than snapshots directory."
    echo "   Older snapshots on USB may need to be cleaned up first."
    read -p "   Continue anyway? [y/N] " ANS
    [ "$ANS" = "y" ] || exit 1
fi

# ============================================================
# 3. Sync (rsync if available, cp otherwise)
# ============================================================

echo ""
echo "Syncing..."

if command -v rsync &>/dev/null; then
    # rsync is ideal: incremental, preserves perms, verifies integrity
    rsync -av --progress \
        --include='snap_*.tgz' \
        --include='snap_*.tgz.sha256' \
        --include='snap_*.tgz.meta' \
        --include='clean_pi_backup*.tgz' \
        --exclude='*' \
        "$SRC_DIR/" "$DEST_DIR/"
else
    echo "(rsync not found, using cp — no progress bar)"
    NEW_COUNT=0
    for f in "$SRC_DIR"/snap_*.tgz "$SRC_DIR"/snap_*.tgz.sha256 "$SRC_DIR"/snap_*.tgz.meta "$SRC_DIR"/clean_pi_backup*.tgz; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        if [ ! -f "$DEST_DIR/$base" ] || \
           [ "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" -gt \
             "$(stat -f %m "$DEST_DIR/$base" 2>/dev/null || stat -c %Y "$DEST_DIR/$base" 2>/dev/null || echo 0)" ]; then
            cp "$f" "$DEST_DIR/"
            NEW_COUNT=$((NEW_COUNT + 1))
        fi
    done
    echo "  copied $NEW_COUNT new/updated files"
fi

# ============================================================
# 4. Verify checksums on USB
# ============================================================

echo ""
echo "Verifying checksums on USB..."
FAILED=0
PASSED=0
for tgz in "$DEST_DIR"/snap_*.tgz; do
    [ -f "$tgz" ] || continue
    sha_file="${tgz}.sha256"
    if [ ! -f "$sha_file" ]; then
        echo "  ⚠️  $(basename $tgz): no checksum file"
        continue
    fi
    expected=$(cat "$sha_file")
    actual=$(shasum -a 256 "$tgz" 2>/dev/null | awk '{print $1}' || \
             sha256sum "$tgz" 2>/dev/null | awk '{print $1}')
    if [ "$expected" = "$actual" ]; then
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ $(basename $tgz): CHECKSUM MISMATCH"
        FAILED=$((FAILED + 1))
    fi
done

# ============================================================
# 5. Write a manifest with a timestamp
# ============================================================

cat > "$DEST_DIR/MANIFEST.txt" <<EOF
SCALPEL Snapshot Backup
========================
Last synced:  $(date)
From host:    $(hostname)
Source dir:   $SRC_DIR
Snapshots:    $(ls "$DEST_DIR"/snap_*.tgz 2>/dev/null | wc -l)
Total size:   $(du -sh "$DEST_DIR" | cut -f1)

To restore on a fresh laptop:
  1. Plug this USB into the new laptop
  2. Mkdir ~/scalpel-snapshots/
  3. cp $DEST_DIR/*.tgz* ~/scalpel-snapshots/
  4. To restore to a Pi:
       scp ~/scalpel-snapshots/snap_LATEST.tgz cowrie@<pi>:~/snapshots/
       ssh cowrie@<pi> 'bash ~/scalpel-kit/src/backup/restore.sh'
EOF

# ============================================================
# 6. Summary
# ============================================================

echo ""
echo "═══════════════════════════════════════════════════════"
echo " USB SYNC COMPLETE"
echo "═══════════════════════════════════════════════════════"
echo " USB:          $DEST_DIR"
echo " Snapshots:    $(ls $DEST_DIR/snap_*.tgz 2>/dev/null | wc -l)"
echo " Total size:   $(du -sh $DEST_DIR | cut -f1)"
echo " Checksums:    $PASSED passed, $FAILED failed"
echo "═══════════════════════════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo " ⚠️  $FAILED snapshot(s) have bad checksums — DO NOT TRUST them."
    echo "     Re-sync before relying on these for restore."
    exit 1
fi

echo ""
echo " Now safely eject the USB before unplugging:"
case "$(uname)" in
    Darwin)  echo "   diskutil unmount \"$USB_PATH\"" ;;
    Linux)   echo "   sudo umount \"$USB_PATH\"" ;;
esac
