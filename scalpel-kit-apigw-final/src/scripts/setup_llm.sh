#!/bin/bash
# Set up the local LLM (Ollama) on the honeypot Pi.
# Run as the cowrie user.
#
# Note: Ollama installs as a system service named 'ollama'. We can't fully
# disguise this without recompiling, so we minimize attack surface:
#   - Bind Ollama to localhost only (it does this by default)
#   - Don't expose port 11434 in firewall
#   - The Cowrie sandbox prevents the red team from doing 'systemctl status'
#     on real services anyway
#
# If even more paranoid, you could rename the systemd unit. But the cost-benefit
# isn't worth it given Cowrie's sandbox.

set -e

MODEL="${1:-qwen2.5:1.5b}"

if ! command -v ollama &>/dev/null; then
    echo "[1/4] Installing local LLM runtime..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo "[1/4] LLM runtime already installed"
fi

echo "[2/4] Enabling service..."
sudo systemctl enable --now ollama
sleep 3

# Verify it's bound to localhost only (default behavior)
if ss -tlnp 2>/dev/null | grep ":11434" | grep -v "127.0.0.1\|::1" > /dev/null; then
    echo "WARNING: LLM runtime is listening on a non-localhost interface."
    echo "         This must be fixed — set OLLAMA_HOST=127.0.0.1 in systemd unit."
fi

echo "[3/4] Pulling model: $MODEL ..."
ollama pull "$MODEL"

echo "[4/4] Warming model with 24h keep-alive..."
curl -s -X POST http://localhost:11434/api/generate \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"$MODEL\",
        \"prompt\": \"a\",
        \"keep_alive\": \"24h\",
        \"stream\": false,
        \"options\": {\"num_predict\": 1}
    }" > /dev/null

echo ""
echo "Loaded models:"
curl -s http://localhost:11434/api/ps | python3 -m json.tool

echo ""
echo "Done. Now install the keepalive cron:"
echo "  (crontab -l 2>/dev/null; echo '*/4 * * * * /home/cowrie/scalpel-kit/src/scripts/keepalive.sh > /dev/null 2>&1') | crontab -"
