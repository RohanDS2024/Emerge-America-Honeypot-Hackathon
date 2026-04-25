# Senior Security Audit — Project SCALPEL Kit

**Auditor:** Senior Software & Cybersecurity Engineer
**Date:** April 23, 2026
**Scope:** Complete kit (36 files), threat model includes both red team probing AND opportunistic attackers on the venue network

---

## Executive Summary

The kit's core architecture is sound and the OPSEC disguise work is good. However, I identified **17 security issues** across 4 severity tiers. The most critical: the cloud Lambda is publicly callable by anyone with the URL ($-and-credit drain risk), the dashboard SSH tunnel doesn't survive laptop sleep, and snapshots leak the cloud endpoint via `.bashrc`.

I've grouped findings by severity. Critical and High issues need fixes BEFORE deployment. Medium and Low are improvements you can defer if time-pressured.

---

## CRITICAL (fix before deployment)

### C1. Lambda function URL is publicly callable
**File:** `src/scripts/deploy_cloud.sh`
**Issue:** `--auth-type NONE` plus `--principal "*"` means anyone with the URL can invoke it. URLs leak via:
- `.bashrc` snapshots transferred to laptops
- AWS billing alerts that contain the URL
- `/proc/<pid>/environ` of the router process (any user that can read it)

A motivated attacker could spam Bedrock invocations, draining your credits AND poisoning your cost analytics.

**Fix:** Add a shared-secret header. The router includes `X-Svcd-Auth: <random>`; the Lambda rejects requests without it. Not bulletproof against network capture, but raises the bar from "just hit the URL" to "intercept first."

### C2. Snapshot tarballs contain the cloud URL in plaintext
**File:** `src/backup/snapshot.sh`
**Issue:** `.bashrc` is included in every snapshot, and `.bashrc` contains `export SVCD_CLOUD_URL=https://...lambda-url.../`. Snapshots are transferred unencrypted via scp to laptops. If a snapshot leaks, the URL leaks.

**Fix:** Filter `.bashrc` through a sanitizer that redacts the cloud URL line before tarring. The actual env var stays on the Pi; restore script re-prompts for the URL or reads it from a separate, never-snapshotted file.

### C3. `restore.sh` extracts tarballs to `/` without validation
**File:** `src/backup/restore.sh` line 56-62
**Issue:** `cd / && tar xzf "$SNAPSHOT"` will write any path the tarball contains. A maliciously-crafted tarball with `../` paths or absolute paths to `/etc/sudoers` or `/etc/passwd` would trash the system. If snapshots came from a compromised laptop, this is RCE-as-root.

**Fix:** Validate tarball contents before extraction:
- Reject any path containing `..`
- Reject any absolute path NOT in our allowlist (`/home/cowrie/`, `/var/log/journal/svcd/`)
- Use `tar --no-overwrite-dir --no-absolute-names` with explicit allow list

### C4. `panic.sh` has no authentication
**File:** `src/backup/panic.sh`
**Issue:** Anyone with shell access (compromised SSH key, shared tmux session) can run `panic` and roll back the system. During the gauntlet, this is a denial-of-service vector if the venue WiFi gets compromised.

**Fix:** Require a confirmation token. The token is set in env at install time and required for `--yes` mode.

---

## HIGH (fix before deployment if possible)

### H1. SSH tunnel for dashboard dies on laptop sleep
**File:** `playbook/01_day1_morning.md`
**Issue:** `ssh -N -L 8080:127.0.0.1:8080` doesn't auto-reconnect. Laptop sleeps → tunnel dies → during presentation, dashboard shows nothing → recovery is awkward.

**Fix:** Use `autossh` with monitoring port. Add to playbook with installation step and copy-paste command.

### H2. Forbidden token regex is bypassable via Unicode/encoding
**File:** `src/router/router.py` and `src/cloud/lambda_function.py`
**Issue:** `re.compile(r"\b(honeypot|cowrie|...)\b", re.I)` matches ASCII. The LLM could output:
- `H\u200boneypot` (zero-width space)
- `c o w r i e` (spaced)
- Unicode lookalikes: `ⅽowrie` (Roman numeral c)
- Base64: `aG9uZXlwb3Q=`

**Fix:** Normalize Unicode (NFKC) before regex, strip zero-width chars, also check normalized output.

### H3. No rate limiting on Lambda calls from router
**File:** `src/router/router.py`
**Issue:** Buggy router or rapid-fire attacker probes can issue thousands of cloud calls/minute, draining Bedrock quota and credits. There's no circuit breaker.

**Fix:** Add per-process rate limit: max 30 cloud calls per minute. After threshold, fall through to Tier 2 silently.

### H4. Watchdog script has no rate limiting on restarts
**File:** `src/scripts/watchdog.sh`
**Issue:** If Cowrie crashes due to bad config, the watchdog will restart-crash-restart in an infinite loop, eating CPU and SD writes. No backoff.

**Fix:** Exponential backoff: after 3 restarts in 60 seconds, wait 5 minutes before next restart attempt. Log loudly.

### H5. Snapshot script writes to user-writable temp file path
**File:** `src/backup/snapshot.sh` line 60
**Issue:** `crontab -l > "$SNAPSHOT_DIR/.crontab.tmp"` is a TOCTOU race. If `$SNAPSHOT_DIR` is world-writable temporarily, an attacker could symlink that to `/etc/passwd`.

**Fix:** Use `mktemp` for the temp file. Clean up on signal trap.

### H6. Log files have default 644 permissions, world-readable
**File:** `src/router/router.py` (creates METRICS_LOG and ERROR_LOG)
**Issue:** Logs contain raw attacker commands which may include passwords, API keys, or session credentials they typed by mistake. World-readable means any local user can grep the logs.

**Fix:** Set `os.umask(0o077)` before opening log files, or chmod 600 explicitly.

---

## MEDIUM (fix if time permits)

### M1. Subprocess paths use `~` which breaks under cron
**Files:** `src/scripts/keepalive.sh`, `src/backup/snapshot.sh`
**Issue:** `~` requires shell tilde expansion. Some cron environments set HOME=/ and `~/foo` becomes `/foo`. Already partially mitigated (most uses are quoted strings inside heredocs), but check.

**Fix:** Use `$HOME` explicitly or hardcoded absolute paths in cron-invoked scripts.

### M2. `install_svcd.sh` is not idempotent on the `__init__.py` patch
**File:** `src/scripts/install_svcd.sh` line 60-65
**Issue:** The grep prevents duplicate appends, but if someone manually edits `__init__.py`, the grep might not catch it. A failed install + re-run could double-import.

**Fix:** Use a sentinel comment block with begin/end markers; replace the entire block on each install.

### M3. Lambda error responses leak exception messages
**File:** `src/cloud/lambda_function.py` line 77
**Issue:** `return {"statusCode": 500, "body": json.dumps({"body": "", "error": str(e)})}` leaks internal error details (file paths, AWS account info, Bedrock quota messages).

**Fix:** Log the exception server-side (CloudWatch); return generic `{"error": "internal"}` to client.

### M4. SSH password authentication is enabled (root/root)
**File:** Required by competition, but...
**Issue:** Cowrie's port 2222 accepts root/root. If our actual port 22 also has weak creds (default Pi `pi/raspberry`), we're vulnerable to opportunistic attacks from anyone on the venue WiFi.

**Fix:** Change the cowrie user's REAL SSH password (port 22) to a random 24-char string at deploy time. Keep Cowrie's port 2222 as root/root for the competition.

### M5. No integrity check on snapshots before restore
**File:** `src/backup/restore.sh`
**Issue:** Snapshot tarball could be corrupted in transit (scp interrupted, partial write). Restore would partially apply, leaving inconsistent state.

**Fix:** snapshot.sh writes a SHA-256 checksum file. restore.sh verifies before extraction.

### M6. Dashboard has no authentication beyond network isolation
**File:** `src/dashboard/monitor.py`
**Issue:** Bound to localhost is good, but anyone with shell access on the Pi can `curl 127.0.0.1:8080/api/recent` and see ALL session activity including attacker commands.

**Fix:** Add basic auth via env-supplied password. Low effort, meaningful.

### M7. The SCALPEL_AUTH header (proposed in C1) is in `.bashrc`
**Issue:** Same problem as C2 if not handled.
**Fix:** Store the auth token in a 600-perm file at `~/.local/lib/svcd/auth.token`, not `.bashrc`. Snapshot script explicitly excludes it.

---

## LOW (nice-to-have)

### L1. No protection against snapshot directory filling the SD card
- 50MB × 48 snapshots (24h × 2/hour) = 2.4GB. Pi might have only 5GB free.
- **Fix:** Already retains last 20, but enforce a 1GB total cap.

### L2. Watchdog logs to `/var/log/journal/svcd/watchdog.log` which is in snapshot
- Snapshot of the watchdog log of the snapshot of the watchdog log...
- **Fix:** Exclude watchdog.log from snapshot.

### L3. tmux session for watchdog is not auto-restarted if tmux dies
- Rare but possible.
- **Fix:** Use systemd user service instead of tmux.

### L4. The `ssh-pi` aliases in playbooks expose IPs in shell history
- **Fix:** Use SSH config aliases (`Host honeypot` blocks in `~/.ssh/config`).

### L5. No HTTPS on Lambda function URL
- Lambda function URLs are HTTPS by default, so this is fine. Just verify with `https://` in the URL.

### L6. The capture script captures `/etc/passwd` — fine, but also the synthetic bash_history mentions specific IPs
- **Fix:** Use generic IPs (10.0.0.x) in the synthetic history.

### L7. `setup_llm.sh` runs `curl | sh` for Ollama installer
- Standard practice but not auditable. Consider downloading the script first, reviewing, then executing.

---

## Now applying fixes

I'll implement C1, C2, C3, C4, H1, H2, H3, H4, H5, H6, M5, M6, M7. Skipping the rest as time-constrained nice-to-haves with documented fix instructions.
