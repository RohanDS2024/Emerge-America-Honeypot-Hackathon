#!/bin/bash
# LLM keepalive cron. Disguised name (no scalpel/honeypot strings).
# Install: (crontab -l; echo "*/4 * * * * /home/cowrie/scalpel-kit/src/scripts/keepalive.sh > /dev/null 2>&1") | crontab -

MODEL="${SVCD_MODEL:-qwen2.5:1.5b}"

curl -s -X POST http://localhost:11434/api/generate \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"$MODEL\",
        \"prompt\": \"a\",
        \"keep_alive\": \"24h\",
        \"stream\": false,
        \"options\": {\"num_predict\": 1}
    }" > /dev/null
