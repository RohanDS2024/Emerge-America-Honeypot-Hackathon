#!/bin/bash
# Install SVCD into Cowrie with hardened security defaults.
#
# - Generates panic token (controls who can run rollback during gauntlet)
# - Generates auth token placeholder (you set this from deploy_cloud.sh output)
# - Strict file permissions on all secrets (600/700)
# - Idempotent install via sentinel-block markers
# - Logs go to a 700-permission dir
#
# Run as the cowrie user.

set -euo pipefail
umask 077

COWRIE_DIR="$HOME/cowrie"
KIT_DIR="${KIT_DIR:-$HOME/scalpel-kit}"
COWRIE_COMMANDS_DIR="$COWRIE_DIR/src/cowrie/commands"
COWRIE_INIT="$COWRIE_COMMANDS_DIR/__init__.py"

INSTALL_LIB="$HOME/.local/lib/svcd"
LOG_DIR="/var/log/journal/svcd"

if [ ! -d "$COWRIE_DIR" ]; then
    echo "ERROR: $COWRIE_DIR not found"
    exit 1
fi
if [ ! -d "$KIT_DIR" ]; then
    echo "ERROR: $KIT_DIR not found. scp the kit here first."
    exit 1
fi

# --- 1. Disguised install dir ---
echo "[1/8] Setting up ~/.local/lib/svcd/ ..."
mkdir -p "$INSTALL_LIB"
chmod 700 "$INSTALL_LIB"
cp "$KIT_DIR/src/router/router.py" "$INSTALL_LIB/router.py"
cp "$KIT_DIR/src/router/system_prompt.txt" "$INSTALL_LIB/prompt.txt"
touch "$INSTALL_LIB/__init__.py"
chmod 600 "$INSTALL_LIB"/*.py "$INSTALL_LIB"/*.txt 2>/dev/null || true

# --- 2. Log dir with 700 perms ---
echo "[2/8] Setting up /var/log/journal/svcd/ ..."
sudo mkdir -p "$LOG_DIR"
sudo chown "$USER:$USER" "$LOG_DIR"
sudo chmod 700 "$LOG_DIR"

# --- 3. Cowrie integration ---
echo "[3/8] Installing Cowrie command interceptor (unattended.py) ..."
cp "$KIT_DIR/src/cowrie_patch/unattended.py" "$COWRIE_COMMANDS_DIR/unattended.py"

# --- 4. Idempotent registration via sentinel block ---
echo "[4/8] Registering interceptor (idempotent sentinel-block) ..."
if [ ! -f "${COWRIE_INIT}.bak" ]; then
    cp "$COWRIE_INIT" "${COWRIE_INIT}.bak"
fi
# Strip any prior svcd block, re-add cleanly
python3 - <<PYEOF
import re
p = "$COWRIE_INIT"
with open(p) as f:
    content = f.read()
# Remove existing block (between sentinels, inclusive)
content = re.sub(
    r"\n# >>> SVCD-INSTALL >>>.*?# <<< SVCD-INSTALL <<<\n",
    "\n", content, flags=re.S
)
# Append fresh block
content = content.rstrip() + "\n\n# >>> SVCD-INSTALL >>>\nfrom cowrie.commands import unattended  # noqa\n# <<< SVCD-INSTALL <<<\n"
with open(p, "w") as f:
    f.write(content)
PYEOF

# --- 5. Python deps ---
echo "[5/8] Installing Python deps in Cowrie venv ..."
source "$COWRIE_DIR/cowrie-env/bin/activate"
pip install requests --quiet

# --- 6. Generate auth tokens ---
echo "[6/8] Generating panic token ..."
PANIC_TOKEN_FILE="$HOME/.svcd_panic_token"
if [ ! -f "$PANIC_TOKEN_FILE" ]; then
    python3 -c "import secrets; print(secrets.token_urlsafe(24))" > "$PANIC_TOKEN_FILE"
    chmod 600 "$PANIC_TOKEN_FILE"
    echo "    → New panic token: $(cat $PANIC_TOKEN_FILE)"
else
    echo "    → Re-using existing panic token at $PANIC_TOKEN_FILE"
fi

# Auth token placeholder (you fill from deploy_cloud.sh output)
AUTH_TOKEN_FILE="$INSTALL_LIB/auth.token"
if [ ! -f "$AUTH_TOKEN_FILE" ]; then
    touch "$AUTH_TOKEN_FILE"
    chmod 600 "$AUTH_TOKEN_FILE"
    echo "    → Auth token file created (empty). Populate from deploy_cloud.sh output:"
    echo "       echo 'YOUR_TOKEN' > $AUTH_TOKEN_FILE"
fi

# --- 7. Env vars in .bashrc (sentinel block) ---
echo "[7/8] Setting up env vars in ~/.bashrc ..."
python3 - <<PYEOF
import re, os
p = os.path.expanduser("~/.bashrc")
content = open(p).read() if os.path.exists(p) else ""
content = re.sub(
    r"\n# >>> SVCD-ENV >>>.*?# <<< SVCD-ENV <<<\n",
    "\n", content, flags=re.S
)
block = """
# >>> SVCD-ENV >>>
export SVCD_BASE=/home/cowrie/.local/lib/svcd
export SVCD_LOG_DIR=/var/log/journal/svcd
export SVCD_MODEL=qwen2.5:1.5b
# SVCD_CLOUD_URL set separately after deploying cloud function
# Auth token is read from \$SVCD_BASE/auth.token (NOT here, to avoid snapshot leak)
alias panic='PANIC_TOKEN=\$(cat \$HOME/.svcd_panic_token) bash $KIT_DIR/src/backup/panic.sh --yes'
# <<< SVCD-ENV <<<
"""
content = content.rstrip() + "\n" + block
open(p, "w").write(content)
PYEOF

# --- 8. Verify perms ---
echo "[8/8] Verifying permissions ..."
ls -la "$INSTALL_LIB/auth.token" "$PANIC_TOKEN_FILE"

echo ""
echo "═══════════════════════════════════════════════════════"
echo " INSTALL COMPLETE"
echo "═══════════════════════════════════════════════════════"
echo ""
echo " NEXT STEPS:"
echo ""
echo " 1. Populate the cloud auth token (from deploy_cloud.sh output):"
echo "    echo 'TOKEN_HERE' > $INSTALL_LIB/auth.token"
echo ""
echo " 2. Set the cloud URL:"
echo "    echo 'export SVCD_CLOUD_URL=https://...' >> ~/.bashrc"
echo "    source ~/.bashrc"
echo ""
echo " 3. Verify Ollama: curl http://localhost:11434/api/ps"
echo ""
echo " 4. Ingest ground truth:"
echo "    bash $KIT_DIR/src/scripts/ingest_data.sh ~/groundtruth.tgz"
echo ""
echo " 5. Restart Cowrie:"
echo "    ~/cowrie/bin/cowrie restart"
echo ""
echo " 6. View dashboard via SSH tunnel from your laptop:"
echo "    ssh -N -L 8080:127.0.0.1:8080 cowrie@\$(hostname -I | awk '{print \$1}')"
echo "    → http://127.0.0.1:8080"
echo ""
echo " For panic rollback during gauntlet, just type:  panic"
echo "═══════════════════════════════════════════════════════"
