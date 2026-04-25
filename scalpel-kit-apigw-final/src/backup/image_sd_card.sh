#!/bin/bash
# Full SD card image backup.
# Run ONCE, Day 1 morning, BEFORE making any changes to the Pi.
# This is the nuclear-option restore target — if everything else fails,
# flash this image to a fresh SD card and you're back to start.
#
# Must be run from a LAPTOP with the SD card removed from the Pi and
# inserted via USB adapter. Pi must be shut down during this.
#
# For the honeypot Pi: do this BEFORE installing our SCALPEL stack.
# For the clean Pi: do this right after ground-truth capture.
#
# Usage:
#   # Plug SD card into laptop via USB adapter
#   # Find the device (e.g. /dev/disk4 on Mac, /dev/sdb on Linux)
#   diskutil list          # Mac
#   lsblk                  # Linux
#
#   # Run:
#   sudo ./image_sd_card.sh /dev/disk4 clean_pi_image.img
#   # OR
#   sudo ./image_sd_card.sh /dev/sdb honeypot_pi_image.img

set -e

DEVICE="${1:-}"
OUTPUT="${2:-}"

if [ -z "$DEVICE" ] || [ -z "$OUTPUT" ]; then
    echo "Usage: $0 <device> <output.img>"
    echo ""
    echo "Find your device:"
    echo "  Mac:   diskutil list"
    echo "  Linux: lsblk"
    echo ""
    echo "Example:"
    echo "  sudo $0 /dev/disk4 clean_pi.img"
    exit 1
fi

# Safety: confirm device size (Pi SD should be 16-128GB)
if command -v diskutil &>/dev/null; then
    # Mac
    SIZE=$(diskutil info "$DEVICE" | grep "Disk Size" | awk '{print $3}')
    echo "Device $DEVICE reports size: $SIZE"
elif command -v lsblk &>/dev/null; then
    # Linux
    SIZE=$(lsblk -bno SIZE "$DEVICE" | head -1)
    SIZE_GB=$((SIZE / 1024 / 1024 / 1024))
    echo "Device $DEVICE reports size: ${SIZE_GB}GB"

    if [ "$SIZE_GB" -gt 256 ]; then
        echo ""
        echo "⚠️  WARNING: Device is ${SIZE_GB}GB. That's bigger than a typical Pi SD card."
        echo "    You might be pointing at your laptop's main drive!"
        echo "    DOUBLE CHECK before continuing."
        read -p "Type 'YES I AM SURE' to continue: " CONFIRM
        [ "$CONFIRM" = "YES I AM SURE" ] || exit 1
    fi
fi

echo ""
echo "About to image $DEVICE → $OUTPUT"
echo "This will take approximately 30-60 minutes for a 32GB SD card."
echo "Do not remove the SD card during imaging."
echo ""
read -p "Continue? [y/N] " CONFIRM
[ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || exit 1

echo ""
echo "Imaging started: $(date)"
START=$(date +%s)

# Use conv=sparse to skip zero blocks (dramatically faster, smaller image)
# status=progress shows throughput
sudo dd if="$DEVICE" of="$OUTPUT" bs=4M conv=sparse status=progress

ELAPSED=$(($(date +%s) - START))
echo ""
echo "Imaging done in $((ELAPSED / 60))m $((ELAPSED % 60))s"
echo ""

# Compress it — saves 60-80% typically
echo "Compressing image with gzip..."
gzip --fast "$OUTPUT"
echo ""

SIZE_MB=$(du -m "${OUTPUT}.gz" | cut -f1)
echo "Final image: ${OUTPUT}.gz (${SIZE_MB}MB)"
echo ""
echo "TO RESTORE (in disaster scenario only):"
echo "  gunzip ${OUTPUT}.gz"
echo "  sudo dd if=${OUTPUT} of=$DEVICE bs=4M status=progress"
echo ""
echo "Store this image in TWO places:"
echo "  1. Your laptop"
echo "  2. A second laptop or USB drive"
