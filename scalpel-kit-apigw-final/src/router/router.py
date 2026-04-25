"""
SVCD — system service daemon (router).

(Internally: SCALPEL router. Disguised name is for runtime safety.
Anyone reading this source already has access; obfuscation is in
deployed artifacts, not source files.)

Production three-tier decision engine. Deploy on the honeypot Pi at:
    /home/cowrie/.local/lib/svcd/router.py
"""

import json
import os
import re
import time
import threading
import logging
from pathlib import Path
from typing import Optional

import requests

# All paths and env vars use disguised names
BASE_DIR = Path(os.environ.get("SVCD_BASE", "/home/cowrie/.local/lib/svcd"))
GROUND_TRUTH_DIR = BASE_DIR / "data"
SYSTEM_PROMPT_PATH = BASE_DIR / "prompt.txt"

LOG_DIR = Path(os.environ.get("SVCD_LOG_DIR", "/var/log/journal/svcd"))
METRICS_LOG = LOG_DIR / "events.jsonl"
ERROR_LOG = LOG_DIR / "service.log"

LLM_URL = "http://localhost:11434/api/generate"
LLM_MODEL = os.environ.get("SVCD_MODEL", "qwen2.5:1.5b")
LLM_KEEPALIVE = "24h"
LLM_TIMEOUT = 5.0

CLOUD_URL = os.environ.get("SVCD_CLOUD_URL", "")
CLOUD_TIMEOUT = 4.0

# Auth token for Lambda. Read from a file (NOT env, NOT bashrc — those leak in snapshots).
# File should be 600-perm and excluded from snapshots.
AUTH_TOKEN_PATH = BASE_DIR / "auth.token"
try:
    CLOUD_AUTH_TOKEN = AUTH_TOKEN_PATH.read_text().strip()
except FileNotFoundError:
    CLOUD_AUTH_TOKEN = ""

# Rate limiting for cloud calls (defense against runaway router or DoS amplification)
CLOUD_RATE_LIMIT_PER_MIN = 30
_cloud_call_times: list[float] = []
_cloud_rate_lock = threading.Lock()


def _check_cloud_rate_limit() -> bool:
    """Returns True if we're within rate limit."""
    now = time.time()
    with _cloud_rate_lock:
        # Drop calls older than 60s
        cutoff = now - 60
        _cloud_call_times[:] = [t for t in _cloud_call_times if t > cutoff]
        if len(_cloud_call_times) >= CLOUD_RATE_LIMIT_PER_MIN:
            return False
        _cloud_call_times.append(now)
        return True


SLOW_COMMANDS = {
    "find", "apt", "apt-get", "dpkg", "journalctl",
    "locate", "updatedb", "tar", "rsync", "du",
}

# Restrict permissions on logs (contains attacker commands which may include creds)
os.umask(0o077)
LOG_DIR.mkdir(parents=True, exist_ok=True)
# Force tighten if dir already existed
try:
    os.chmod(LOG_DIR, 0o700)
except (OSError, PermissionError):
    pass

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(ERROR_LOG), logging.StreamHandler()],
)
log = logging.getLogger("svcd")

LOOKUP: dict[str, str] = {}
LOOKUP_LOCK = threading.Lock()


def _normalize_cmd(cmd: str) -> str:
    return " ".join(cmd.strip().split()).lower()


def load_ground_truth():
    if not GROUND_TRUTH_DIR.exists():
        log.warning("Data dir not found: %s", GROUND_TRUTH_DIR)
        return

    count = 0
    manifest = GROUND_TRUTH_DIR / "manifest.json"
    if manifest.exists():
        with open(manifest) as mf:
            mapping = json.load(mf)
        for cmd, fname in mapping.items():
            fpath = GROUND_TRUTH_DIR / fname
            if fpath.exists():
                with open(fpath) as cf:
                    LOOKUP[_normalize_cmd(cmd)] = cf.read()
                count += 1
    else:
        for f in GROUND_TRUTH_DIR.glob("*.txt"):
            name = f.stem.replace("___", " ").replace("__", "/")
            with open(f) as cf:
                LOOKUP[_normalize_cmd(name)] = cf.read()
            count += 1

    log.info("Loaded %d lookup entries", count)


load_ground_truth()


class SessionState:
    def __init__(self, session_id: str):
        self.session_id = session_id
        self.history: list[tuple[str, str]] = []
        self.start_time = time.time()
        self.cwd = "/root"

    def push(self, cmd: str, response: str):
        self.history.append((cmd, response))
        if len(self.history) > 10:
            self.history.pop(0)

    def context_for_llm(self) -> str:
        if not self.history:
            return ""
        lines = []
        for cmd, out in self.history[-5:]:
            lines.append(f"$ {cmd}")
            lines.append(out)
        return "\n".join(lines)


_SESSIONS: dict[str, SessionState] = {}
_SESSIONS_LOCK = threading.Lock()


def get_session(session_id: str) -> SessionState:
    with _SESSIONS_LOCK:
        if session_id not in _SESSIONS:
            _SESSIONS[session_id] = SessionState(session_id)
        return _SESSIONS[session_id]


def end_session(session_id: str):
    with _SESSIONS_LOCK:
        _SESSIONS.pop(session_id, None)


try:
    SYSTEM_PROMPT = SYSTEM_PROMPT_PATH.read_text()
except FileNotFoundError:
    log.error("Prompt missing at %s, using fallback", SYSTEM_PROMPT_PATH)
    SYSTEM_PROMPT = (
        "You are a bash shell on Raspberry Pi OS Bookworm. "
        "Respond ONLY with literal shell output, nothing else."
    )


PREAMBLE_PATTERNS = [
    re.compile(r"^(sure|here(?:'s| is)|i('ll| will| would)|the (output|result)|let me|to|this (is|will))[,:\s]", re.I),
    re.compile(r"^(certainly|of course|absolutely|got it)", re.I),
]
MARKDOWN_FENCE = re.compile(r"^```\w*\s*\n?|\n?```\s*$", re.M)

# Words the LLM must never leak. If any appear, we replace the entire
# response with a generic shell error rather than risk exposure.
FORBIDDEN_TOKENS = re.compile(
    r"\b(honey ?pot|cowrie|ollama|llm|claude|bedrock|lambda|aws|"
    r"prompt|system prompt|fake|simulat|generated|generated by|"
    r"i (am|cannot|can't)|as an ai|svcd|scalpel)\b",
    re.I,
)

# Zero-width and bidi control characters used to bypass token matching
ZERO_WIDTH = re.compile(r"[\u200b\u200c\u200d\u200e\u200f\u2060\ufeff]")


def _normalize_for_check(text: str) -> str:
    """Normalize text to defeat unicode-bypass tricks."""
    import unicodedata
    # Strip zero-width spaces and bidi marks
    t = ZERO_WIDTH.sub("", text)
    # Compatibility decomp + canonical (catches Roman-numeral lookalikes etc.)
    t = unicodedata.normalize("NFKC", t)
    # Collapse repeated whitespace so "c o w r i e" becomes detectable
    t_compact = re.sub(r"\s+", "", t).lower()
    return t + "\n" + t_compact  # check both forms


def sanitize_llm_output(text: str, cmd: str) -> str:
    fallback = f"bash: {cmd.split()[0] if cmd.split() else ''}: command not found"
    if not text:
        return fallback

    text = MARKDOWN_FENCE.sub("", text).strip()

    lines = text.split("\n")
    if lines and any(p.match(lines[0]) for p in PREAMBLE_PATTERNS):
        lines = lines[1:]
        text = "\n".join(lines).strip()

    if not text:
        return fallback

    # Check forbidden tokens against BOTH original and normalized form
    check_str = _normalize_for_check(text)
    if FORBIDDEN_TOKENS.search(check_str):
        log.warning("FORBIDDEN_TOKEN in LLM output, suppressing: %s", text[:100])
        return fallback

    return text


def tier_1_lookup(cmd: str, session: SessionState) -> Optional[str]:
    return LOOKUP.get(_normalize_cmd(cmd))


def tier_2_local(cmd: str, session: SessionState) -> str:
    context = session.context_for_llm()
    prompt = f"{context}\n$ {cmd}\n" if context else f"$ {cmd}\n"

    try:
        r = requests.post(
            LLM_URL,
            json={
                "model": LLM_MODEL,
                "system": SYSTEM_PROMPT,
                "prompt": prompt,
                "keep_alive": LLM_KEEPALIVE,
                "stream": False,
                "options": {
                    "temperature": 0.2,
                    "num_predict": 250,
                    "stop": ["\n$ ", "$ "],
                },
            },
            timeout=LLM_TIMEOUT,
        )
        r.raise_for_status()
        raw = r.json().get("response", "")
        return sanitize_llm_output(raw, cmd)
    except requests.Timeout:
        log.warning("LLM timeout for cmd: %s", cmd)
        return f"bash: {cmd.split()[0] if cmd.split() else ''}: command not found"
    except Exception as e:
        log.error("LLM error: %s", e)
        return f"bash: {cmd.split()[0] if cmd.split() else ''}: command not found"


def tier_3_cloud(cmd: str, session: SessionState) -> Optional[str]:
    if not CLOUD_URL:
        return None

    # Defense against runaway calls / DoS amplification
    if not _check_cloud_rate_limit():
        log.warning("Cloud rate limit hit, falling back to local")
        return None

    history_payload = [{"cmd": c, "out": o} for c, o in session.history[-5:]]

    headers = {"Content-Type": "application/json"}
    if CLOUD_AUTH_TOKEN:
        headers["X-Svcd-Auth"] = CLOUD_AUTH_TOKEN

    try:
        r = requests.post(
            CLOUD_URL,
            json={"command": cmd, "history": history_payload},
            headers=headers,
            timeout=CLOUD_TIMEOUT,
        )
        if r.status_code == 401 or r.status_code == 403:
            log.error("Cloud auth rejected — check auth.token matches Lambda config")
            return None
        r.raise_for_status()
        body = r.json().get("body", "")
        if isinstance(body, str) and body.strip():
            return sanitize_llm_output(body, cmd)
        return None
    except Exception as e:
        log.warning("Cloud error: %s", e)
        return None


_METRICS_LOCK = threading.Lock()


def log_metric(session_id: str, cmd: str, tier: str, latency_ms: int, response_len: int):
    entry = {
        "ts": time.time(),
        "session": session_id,
        "cmd": cmd,
        "tier": tier,
        "latency_ms": latency_ms,
        "response_bytes": response_len,
    }
    with _METRICS_LOCK:
        try:
            with open(METRICS_LOG, "a") as f:
                f.write(json.dumps(entry) + "\n")
        except Exception as e:
            log.error("Metric write failed: %s", e)


def route(cmd: str, session: SessionState) -> str:
    start = time.perf_counter()
    cmd = cmd.strip()
    if not cmd:
        return ""

    base = cmd.split()[0]
    tier = "tier1_local"
    response = None

    try:
        response = tier_1_lookup(cmd, session)

        if response is None:
            if base in SLOW_COMMANDS and CLOUD_URL:
                response = tier_3_cloud(cmd, session)
                if response is not None:
                    tier = "tier3_cloud"

            if response is None:
                response = tier_2_local(cmd, session)
                tier = "tier2_local"
    except Exception as e:
        log.exception("Router exception: %s", e)
        response = f"bash: {base}: command not found"
        tier = "error"

    latency_ms = int((time.perf_counter() - start) * 1000)
    log_metric(session.session_id, cmd, tier, latency_ms, len(response))
    session.push(cmd, response)
    return response


if __name__ == "__main__":
    print(f"Loaded {len(LOOKUP)} lookup entries")
    print(f"LLM URL: {LLM_URL}")
    print(f"Cloud URL: {CLOUD_URL or '(not configured)'}")

    s = get_session("test-session")
    test_cmds = ["uname -a", "whoami", "pwd", "foobarbaz", "find / -name foo"]
    for c in test_cmds:
        print(f"\n$ {c}")
        out = route(c, s)
        print(out[:200])
