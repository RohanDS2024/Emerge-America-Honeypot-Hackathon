#!/bin/bash
# 🚨 EMERGENCY ROLLBACK 🚨
#
# Requires PANIC_TOKEN env var to match the value in ~/.svcd_panic_token
# (set up by install_svcd.sh). This prevents anyone with shell access from
# trivially DoS'ing the system during the gauntlet.
#
# The recommended bash alias does this for you:
#   alias panic='PANIC_TOKEN=$(cat ~/.svcd_panic_token) bash /home/cowrie/scalpel-kit/src/backup/panic.sh --yes'

set -euo pipefail
umask 077

TOKEN_FILE="$HOME/.svcd_panic_token"

if [ ! -f "$TOKEN_FILE" ]; then
    # If no token file, this is a fresh install. Allow it but warn.
    echo "[panic] No panic token configured. Run install_svcd.sh."
    echo "[panic] Continuing in degraded mode (anyone with shell can run panic)..."
elif [ -z "${PANIC_TOKEN:-}" ]; then
    echo "[panic] ERROR: PANIC_TOKEN not set. Use the 'panic' alias or:"
    echo "        PANIC_TOKEN=\$(cat ~/.svcd_panic_token) bash $0 --yes"
    exit 1
elif [ "$PANIC_TOKEN" != "$(cat $TOKEN_FILE)" ]; then
    echo "[panic] ERROR: PANIC_TOKEN doesn't match. Refusing."
    exit 1
fi

if [ "${1:-}" != "--yes" ] && [ "${2:-}" != "--yes" ]; then
    echo ""
    echo "   🚨 EMERGENCY ROLLBACK 🚨"
    echo ""
    echo "   This will:"
    echo "     - Stop Cowrie (~5s)"
    echo "     - Restore most recent snapshot (~30s)"
    echo "     - Restart Cowrie (~10s)"
    echo "     - Re-warm LLM (~5s)"
    echo ""
    echo "   Cost: ~50s downtime + 1 crash penalty (-10 realism)"
    echo ""
    echo "   Starting in 3 seconds. Ctrl-C to abort."
    for i in 3 2 1; do
        echo "   $i..."
        sleep 1
    done
fi

SNAPSHOT=""
for arg in "$@"; do
    case "$arg" in
        --yes) ;;  # flag, not a snapshot path
        *) [ -z "$SNAPSHOT" ] && SNAPSHOT="$arg" ;;
    esac
done

echo ""
echo "[$(date)] PANIC: rolling back"

cd "$(dirname $0)"
if [ -n "$SNAPSHOT" ]; then
    bash ./restore.sh "$SNAPSHOT" --yes
else
    bash ./restore.sh --yes
fi

echo ""
echo "[$(date)] PANIC: rollback complete"
