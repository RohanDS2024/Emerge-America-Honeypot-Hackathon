#!/bin/bash
# Persistent SSH tunnel for the dashboard. Survives laptop sleep / WiFi flap.
# Run on YOUR LAPTOP, not the Pi.
#
# Requires: autossh (brew install autossh / apt install autossh)
#
# Usage:
#   ./tunnel_dashboard.sh <pi_ip> [user]
#
# Then open: http://127.0.0.1:8080

set -e

PI="${1:-}"
USER_NAME="${2:-cowrie}"

if [ -z "$PI" ]; then
    echo "Usage: $0 <honeypot_pi_ip> [ssh_user=cowrie]"
    exit 1
fi

if ! command -v autossh &>/dev/null; then
    echo "autossh not installed. Install it first:"
    echo "  Mac:   brew install autossh"
    echo "  Linux: sudo apt install autossh"
    exit 1
fi

# Kill any prior instance
pkill -f "autossh.*8080:127.0.0.1:8080" 2>/dev/null || true
sleep 1

echo "Starting persistent tunnel: $USER_NAME@$PI:8080 → localhost:8080"
echo "Open http://127.0.0.1:8080 in your browser."
echo "Tunnel will auto-reconnect on failure. Ctrl-C to stop."

# -M 0 disables monitor port (use ServerAliveInterval instead, more reliable)
# ServerAliveInterval/Max keeps connection alive across NAT/sleep
exec autossh -M 0 -N \
    -o "ServerAliveInterval 30" \
    -o "ServerAliveCountMax 3" \
    -o "ExitOnForwardFailure yes" \
    -L 8080:127.0.0.1:8080 \
    "$USER_NAME@$PI"
