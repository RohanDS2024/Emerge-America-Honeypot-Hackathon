# Emerge-America-Honeypot-Hackathon
# Project SCALPEL

**A three-tier hybrid SSH honeypot combining edge cache, local LLM, and cloud AI for adaptive deception.**

Built at the eMerge Americas 2026 Hackathon (April 23-24, Miami Beach) by Team 7. Hosted by USF Institute of Applied Engineering, DEVCOM Army Research Laboratory, and AWS.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [The Stack](#the-stack)
4. [How It Works](#how-it-works)
5. [Build Journey](#build-journey)
6. [Difficulties Faced](#difficulties-faced)
7. [Results](#results)
8. [Improvements Roadmap](#improvements-roadmap)
9. [Lessons Learned](#lessons-learned)
10. [Repository Structure](#repository-structure)
11. [Setup and Deployment](#setup-and-deployment)
12. [Acknowledgments](#acknowledgments)

---

## Overview

SCALPEL is a hybrid SSH honeypot designed to fool attackers into believing they have compromised a real Raspberry Pi 5 running Debian 13. Unlike traditional honeypots that return fixed responses or single-tier LLM-generated text, SCALPEL routes each attacker probe through one of three tiers based on command complexity.

The goal is realism. An attacker probing the system should never be able to tell they are talking to deception infrastructure. Every byte returned should match what a real Pi would return, with realistic latency, realistic file paths, and realistic permission boundaries.

**Headline metrics from the live deployment:**
- 99.2% edge ratio (probes handled locally vs escalated to cloud)
- 1,328 probes processed during the event
- Sub-50ms response time for cache hits
- ~1.5 second response time for cloud-generated responses
- 0 crashes across 48 hours of continuous operation

---

## Architecture

```
Attacker SSH session (port 2222)
        |
        v
+-----------------------+
|  Cowrie SSH daemon    |   <- Open-source SSH honeypot framework
+-----------------------+
        |
        v
+-----------------------+
|  Command overrides    |   <- 30+ Python files in cowrie/src/cowrie/commands/
|  (cat, ls, ip, ps...) |       Each delegates to the SVCD router
+-----------------------+
        |
        v
+-----------------------+
|  SVCD router          |   <- Custom Python routing engine
+-----------------------+
        |
        +--> Tier 1: Edge cache (440 captured-from-real-Pi responses)
        |       Latency: 5-400ms with realistic latency simulation
        |
        +--> Tier 2: Local LLM (Ollama qwen2.5:1.5b on-device)
        |       Latency: ~1.3 seconds
        |
        +--> Tier 3: AWS Bedrock (Claude Haiku 4.5 via direct boto3)
                Latency: ~1.5 seconds
```

**Routing logic:** A command first hits Tier 1. On a cache miss, the router checks if the command is in the SLOW_COMMANDS set (find, apt, dpkg, du, tar, etc.) and the cloud is configured. If both, it escalates to Tier 3. Otherwise, it falls through to Tier 2. If everything fails, it returns a realistic shell error.

---

## The Stack

| Component | Details |
| --- | --- |
| Honeypot device | Raspberry Pi 5 Model B Rev 1.1, 16 GB RAM, ARM Cortex-A76 |
| Operating system | Debian 13 trixie, kernel 6.12.75+rpt-rpi-2712 |
| SSH honeypot | Cowrie on port 2222, accepts root/root and pi/raspberry |
| Router service | SVCD (disguised name), Python module |
| Local LLM | Ollama 0.21.1 running qwen2.5:1.5b via /api/chat |
| Cloud LLM | AWS Bedrock - Claude Haiku 4.5 global inference profile |
| Dashboard | Flask app on 127.0.0.1:8080, dark theme, 2s auto-refresh |
| Watchdog | Bash script polling SSH port every 10s, auto-restart |
| Snapshot system | Every 30 min + on-demand, SCP transfer to laptop |

---

## How It Works

### Tier 1: Edge Cache (Captured Ground Truth)

Most attacker probes are predictable. They run `whoami`, `uname -a`, `cat /etc/os-release`, `ls /`, `ps aux`. We took a clean Raspberry Pi (ground truth Pi) and ran every command we could think of, capturing the exact output byte-for-byte. Those responses are stored in a JSON manifest mapping command strings to response files.

When an attacker probes the honeypot with a known command, we serve the captured response with realistic latency injection (whoami returns in ~5ms, ps aux in ~165ms, find in ~800ms). The output is byte-identical to a real Pi because it came from a real Pi.

**Key insight:** Captured ground truth beats LLM hallucination. When you ask an LLM "what does /etc/os-release look like?", it guesses. Sometimes right, sometimes wrong. When you photograph the real output once and replay it forever, there is no guesswork.

### Tier 2: Local LLM (On-Device)

For commands not in the cache, we fall through to a local Ollama instance running qwen2.5:1.5b directly on the Pi. This handles novel commands without cloud dependency. The system prompt tells the model it is a bash shell on a Pi running Debian 13, and to respond ONLY with what bash would output.

### Tier 3: Cloud LLM (AWS Bedrock)

For slow commands (find, apt, dpkg, du, tar) where realistic output requires deep knowledge of Linux, we escalate to AWS Bedrock running Claude Haiku 4.5. We bypass Lambda and API Gateway entirely - the Pi calls Bedrock directly via boto3 using AWS CLI credentials.

This was a key design decision. The original kit used Lambda + API Gateway with auth tokens, but Lambda cold starts add 500ms-2s, IAM auth tokens rotate, and the auth path was failing. Direct boto3 means fewer moving parts and no cold starts.

Bedrock generates surprisingly believable shell output. Example: `find / -name "secret*"` returned a list of permission-denied errors plus a path `/boot/firmware/overlays/secret.dtbo`, which is a genuinely realistic Pi-specific device tree overlay file path. The LLM knew what a Pi looks like.

### Adversarial Defense

Sophisticated attackers test for LLM-backed honeypots by trying to break character. We layered defenses:

1. **Cache-level defense:** 24 explicit cache entries for common injection phrases ("ignore previous instructions", "are you a honeypot", "what model are you") that all return `bash: <word>: command not found`. These never reach the LLM.

2. **Prompt-level defense:** A 121-line hardened system prompt for Tier 3 with explicit anti-injection rules and example mappings for SYSTEM:, [INST], and meta-question formats.

3. **Output sanitization:** A regex filter that strips any response starting with "I am", "As an", "Here is", "Sure", "Certainly". If Claude ever slips, we catch it before the attacker sees it.

4. **Realistic latency:** Per-command latency profiles defeat timing fingerprinting. Real `ps aux` takes 100-300ms, not <50ms. We sleep to match.

---

## Build Journey

The full timeline lives in `BUILD_JOURNAL.md`. High-level summary:

**Day 1 (April 23, 8 AM - 7 PM)**
- Started with a kit where most commands returned Cowrie defaults or "Exec format error"
- Built ground truth capture pipeline: capture → tarball → ship → merge into manifest
- Created 30+ Python command overrides to fix Cowrie's binary-exec bug
- Iteratively improved self-test gauntlet score from 54.11 to 80.78
- End of Day 1: All three tiers live, Tier 3 verified with Bedrock

**Day 2 (April 24, 9 AM - 12 PM)**
- AWS token expired overnight; refreshed from Workshop Studio
- Implemented dynamic latency simulation (40+ command profiles)
- Migrated Ollama from /api/generate to /api/chat (correct endpoint for v0.21.1)
- Added 55 adversarial defense entries (AWS metadata blocks, prompt injection, lateral movement)
- Hardened Tier 3 system prompt to 121 lines with explicit defense rules
- Recovered dashboard process (path mismatch fix)
- Added 31 more captured ground truth entries (440 total)
- Final snapshot at 11:14 AM, 46 minutes before judging

---

## Difficulties Faced

### Cowrie's Exec Format Error

Any command hitting Cowrie's virtual filesystem on aarch64 returned:
```
-bash: /bin/ip: cannot execute binary file: Exec format error
```

Cowrie tries to read ELF binaries from its fake filesystem, sees x86 format mismatch, errors out. **Solution:** Created Python override files for 30+ commands that delegate to our SVCD router instead of trying to exec the binary.

### Cowrie's Pipe Parser Bug

Commands like `find / -name foo | head -20` returned:
```
head: invalid option -- '2'
```

Cowrie parses `-20` as `-2` then `-0` instead of `-20`. We could not patch this in time. **Status:** Documented as known limitation. Attempted workaround was 90+ minutes of touching Cowrie internals - too risky pre-demo.

### AWS Token Rotation

Workshop Studio session tokens expired twice during the build (overnight Day 1, again at 11 AM Day 2). Each time, Tier 3 went dark and `find` returned "command not found". **Solution:** Built a credential refresh workflow - fetch from Workshop Studio, scp to Pi, source into Cowrie's environment, restart daemon. Five minutes per refresh.

### Lambda + API Gateway Auth

Original kit routed Tier 3 through Lambda. Auth was failing with `{"error": "forbidden"}`. We could spend hours debugging IAM, or bypass Lambda. **We chose bypass.** Direct boto3 from Pi to Bedrock. 20 minutes later, Tier 3 was live.

### Empty Responses From Test Runner

Self-test gauntlet showed empty output for simple probes that worked manually. Three bugs in our runner: ANSI OSC escape sequences not being stripped, prompt regex not matching all variants, and pipe commands leaving head() waiting for stdin so the next probe got swallowed. Fixed all three.

### Identity Mismatch in Testing

Gauntlet was SSHing to honeypot as root and clean Pi as pi. Of course they returned different values. Standardized to pi/raspberry on both sides. Five demerits cleared instantly.

### Echo Override Broke Variable Expansion

We added an echo override to route through manifest. Broke `echo $SHELL` because Cowrie's built-in echo handles variable expansion BEFORE running, but our override received the literal string `echo $SHELL`. **Lesson:** Don't override commands that work. Each override has cost.

### Dashboard Path Mismatch

Dashboard read from `/var/log/journal/svcd/events.jsonl` (default) but router wrote to `/home/cowrie/.local/lib/svcd/logs/events.jsonl`. Showed 0/0/0 despite active traffic. **Solution:** Restart monitor.py with correct SVCD_METRICS environment variable.

### Accidentally Deleted _METRICS_LOCK

When refactoring tier_2_local during the Ollama migration, accidentally deleted `_METRICS_LOCK = threading.Lock()` which sat right after the function. Every route() call crashed with NameError, attackers saw empty output. Caught and fixed in 5 minutes.

### Judging-Time Failures

The official judge log (team7.log) showed 28 of 40 probes failed. Root causes:
- Empty responses for probes targeting attacker-created files (ls after touch, cat junk.txt) - fundamental design limitation since we can't track session state
- Exec Format Errors for `more`, `lsusb`, `sort` - we missed these three commands when creating overrides
- Pipe-related failures (`ps -aux | grep bash`, `ls -al | grep junk`) - Cowrie's pipe bug
- Stale `/proc/uptime` value cached in manifest, returned the same number twice
- Old-format `ifconfig` from Cowrie's defaults that we didn't override
- Possible IP change during judging (DHCP renewed Pi from 10.4.27.24 to 10.4.27.100), unclear if some probes hit a stale cache or a non-existent host

---

## Results

### Self-Test Gauntlet Progression

| Run | Score | Realism | Efficiency | Change |
| --- | --- | --- | --- | --- |
| v1 | 54.11 | 0.0 | 90.3 | Baseline - identity mismatch + parser bugs |
| v2 | 69.67 | 30.6 | 98.6 | Manifest expanded to 173 entries |
| v3 | 71.89 | 36.1 | 98.6 | Runner uses pi on both sides |
| v4 | 74.11 | 41.7 | 98.6 | 238 manifest entries |
| v5 | 77.44 | 48.6 | 100.0 | 16 more command overrides |
| v6 | 79.67 | 54.2 | 100.0 | Ctrl+C fix for stuck pipes |
| v7 | 81.33 | 58.3 | 100.0 | Easy probes hardened, 320 entries |
| v8 | 80.78 | 58.3 | 98.6 | AWS Bedrock via direct boto3 |
| v18 | 77.44 | 54.2 | 94.4 | Final pre-judging state, 440 entries |

### Official Judging Result

- **Score:** ~62-65 / 100 (estimated from team7.log)
- **Realism:** 22 / 100 (28 findings out of 40 probes, starting at 50)
- **Edge Efficiency:** 99.2 / 100 (live dashboard metric)
- **Presentation:** assumed 60-75 / 100

### What Went Right

- All three tiers live and operational during judging
- Dashboard pulled real-time data showing tier routing decisions
- Zero crashes across 48 hours
- AWS Bedrock generated genuinely believable shell output (`/boot/firmware/overlays/secret.dtbo`)
- Adversarial defenses worked (`ignore previous instructions` returned `bash: ignore: command not found`)
- Architecture story and design rationale held up under questioning

### What Went Wrong

- Did not handle attacker-created file state (ls/cat after touch returned empty)
- Missed three commands during override creation (more, lsusb, sort)
- Cowrie's pipe parser bug took down 4-5 critical intermediate probes
- /proc/uptime cached as static instead of dynamic
- Did not anticipate judges logging in as root (over-indexed on pi user bait)

---

## Improvements Roadmap

Documented in priority order for future work.

### Short-term (1-2 days)

1. **Patch the pipe parser bug.** Write a custom Cowrie input filter that intercepts pipe commands at the protocol layer and routes the entire raw string to SVCD. Recovers 4-5 demerits worth of points.

2. **Session-state tracking.** When attacker creates a file with touch or echo >, persist that to a session-scoped overlay so subsequent ls/cat reflect it. Major realism win.

3. **Dynamic /proc files.** /proc/uptime, /proc/meminfo, /proc/loadavg should be generated fresh per probe based on actual elapsed time, not cached static values.

4. **Add missing command overrides.** more, less, lsusb, sort, head, tail, awk, sed, grep need overrides with realistic behavior.

5. **Modern ifconfig output.** Replace Cowrie's 2010-era ifconfig defaults with modern Debian 13 format.

### Medium-term (1-2 weeks)

6. **IAM least-privilege scoping.** Lock Bedrock credentials to `bedrock:InvokeModel` on the specific model ARN only. Eliminates risk of credential exfiltration.

7. **Token auto-refresh.** Scheduled cron job to refresh AWS Workshop Studio tokens before expiration. Demos shouldn't need manual token rotation.

8. **Session-aware Tier 3 prompting.** Pass full session command history to Bedrock so multi-step probes (cd then ls then cat) feel coherent.

9. **Rate-limit awareness.** Currently Tier 3 has 30 calls/min. Should adapt based on attacker behavior - aggressive scanners might warrant tighter limits.

10. **STIX/TAXII integration.** Export captured attacker behavior as standardized threat intel for SOC ingestion.

### Long-term (1+ months)

11. **Multi-protocol expansion.** HTTP honeypot (fake admin panels), Telnet, MQTT for IoT/OT. The three-tier architecture generalizes.

12. **FIPS-validated cryptographic modules.** Required for federal deployment.

13. **Air-gapped deployment mode.** Make Tier 3 optional. Deploy in environments without cloud connectivity.

14. **Reproducible deployment with Nix.** Capture entire honeypot configuration as a Nix flake. Deploy 10,000 identical units with zero configuration drift.

15. **Adversarial ML research.** Use captured logs to study how attackers probe LLM-backed honeypots vs traditional ones. Publishable.

16. **Production observability.** Prometheus metrics, Grafana dashboards, ELK log aggregation. Hackathon dashboard is a prototype.

---

## Lessons Learned

1. **Realism is mostly the ordinary stuff.** `cat /etc/os-release` matching the real Pi is worth more than fancy cloud LLM tricks.

2. **Capture more ground truth than you think you need.** Five rounds of capture and we still found gaps during judging.

3. **Don't override commands that already work.** Cowrie's built-in echo handles variable expansion. Our override broke it.

4. **Test runners can lie.** Chased multiple "bugs" that were artifacts of how our test parser handled output. Always verify by SSHing in manually.

5. **Permission denied is a feature.** When pi user tries to read /root, the realistic answer is denied. Mimicking real Unix permissions adds realism.

6. **Snapshot constantly.** We rolled back at least three times. Every 30 minutes plus before every major change.

7. **Bypass is sometimes better than fix.** Lambda + API Gateway + IAM ate hours. Direct boto3 took 20 minutes.

8. **LLMs generate surprisingly good shell output.** With a tight system prompt, Bedrock's responses are Pi-authentic.

9. **Tokens expire.** Twice in three hours on Day 2. Build refresh into the workflow, not as an emergency.

10. **Judges probe what real attackers do.** They created files. They piped through grep. They tested shell variables. Hackathon optimization should match the eval.

11. **Test as the user the judges will use.** Most of our manifest assumed pi-user. Judges logged in as root. Cost us ~20 demerits.

12. **Risk triage matters under time pressure.** We said yes to latency sim and Ollama fix (low risk, self-contained). We said no to IAM scoping and pipe interceptor (high risk, broad blast radius). Both calls paid off.

---

## Repository Structure

```
scalpel/
├── README.md                          # This file
├── BUILD_JOURNAL.md                   # Day-by-day build journal
├── ARCHITECTURE.md                    # Detailed architecture diagrams
│
├── src/
│   ├── router/
│   │   └── router.py                  # SVCD three-tier routing engine
│   ├── cowrie_overrides/
│   │   ├── cat.py                     # 30+ command override files
│   │   ├── ls.py
│   │   ├── ps.py
│   │   ├── ip.py
│   │   └── ...
│   ├── dashboard/
│   │   └── monitor.py                 # Flask dashboard
│   ├── cloud/
│   │   └── lambda_function.py         # Original Lambda (deprecated)
│   └── scripts/
│       ├── capture_groundtruth.sh     # Ground truth capture pipeline
│       ├── snapshot.sh                # Snapshot/backup script
│       ├── watchdog.sh                # Auto-restart watchdog
│       └── populate_manifest.py       # Manifest builder
│
├── data/
│   ├── manifest.json                  # 440-entry command-to-response map
│   ├── prompt.txt                     # 121-line hardened system prompt
│   └── responses/                     # Captured ground truth files
│
├── tests/
│   └── red_team/
│       └── runner.py                  # Self-test gauntlet
│
├── deploy/
│   ├── cowrie.cfg                     # Cowrie configuration
│   ├── userdb.txt                     # Accepted credentials
│   └── systemd/                       # Service unit files
│
└── docs/
    ├── DEMO_PLAN.md                   # Live demo script
    ├── OPSEC.md                       # Operational security notes
    └── images/
        └── dashboard.png              # Dashboard screenshot
```

---

## Setup and Deployment

### Prerequisites

- Raspberry Pi 5 with Debian 13 trixie
- Python 3.13+
- An existing Cowrie installation
- AWS account with Bedrock access (for Tier 3)
- Ollama installed locally (for Tier 2)

### Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/yourname/scalpel.git
cd scalpel

# 2. Install router dependencies in Cowrie's venv
~/cowrie/cowrie-env/bin/pip install boto3 requests

# 3. Deploy router and manifest
mkdir -p ~/.local/lib/svcd/data ~/.local/lib/svcd/logs
cp src/router/router.py ~/.local/lib/svcd/
cp data/manifest.json ~/.local/lib/svcd/data/
cp data/prompt.txt ~/.local/lib/svcd/
cp -r data/responses/* ~/.local/lib/svcd/data/

# 4. Deploy Cowrie command overrides
cp src/cowrie_overrides/*.py ~/cowrie/src/cowrie/commands/

# 5. Configure environment
cat >> ~/.bashrc <<EOF
export SVCD_BASE=/home/cowrie/.local/lib/svcd
export SVCD_LOG_DIR=/home/cowrie/.local/lib/svcd/logs
export SVCD_CLOUD_URL=bedrock-direct
export AWS_DEFAULT_REGION=us-east-1
EOF
source ~/.bashrc

# 6. Set AWS credentials (refresh as needed)
export AWS_ACCESS_KEY_ID=your_key
export AWS_SECRET_ACCESS_KEY=your_secret
export AWS_SESSION_TOKEN=your_token

# 7. Pull the local LLM model
ollama pull qwen2.5:1.5b

# 8. Start Cowrie
cd ~/cowrie
source cowrie-env/bin/activate
cowrie start

# 9. Start the dashboard
nohup ~/cowrie/cowrie-env/bin/python3 src/dashboard/monitor.py &

# 10. Verify
ssh root@localhost -p 2222   # password: root
# Try: whoami; cat /etc/os-release; find / -name secret*
```

### Capturing Ground Truth

To add new captured responses from a real Pi:

```bash
# On the clean reference Pi
bash src/scripts/capture_groundtruth.sh > /tmp/groundtruth.tgz

# On the honeypot Pi
scp pi@reference-pi:/tmp/groundtruth.tgz .
python3 src/scripts/populate_manifest.py groundtruth.tgz
cowrie restart
```

---

## Acknowledgments

Built at the **eMerge Americas 2026 Hackathon** in Miami Beach, Florida.

Hosts and sponsors:
- **USF Institute of Applied Engineering** for organizing the hackathon track
- **DEVCOM Army Research Laboratory** for the problem statement and judging
- **AWS** for Workshop Studio access, Bedrock credits, and Claude Haiku 4.5
- **The Florida High Tech Corridor** for venue support

Team 7 contributors:
- Three teammates on presentation, narrative, and pickle filesystem improvements
- Project lead on architecture, router engine, command overrides, ground truth pipeline, and Tier 3 cloud integration

Built with:
- [Cowrie](https://github.com/cowrie/cowrie) - Open-source SSH honeypot
- [Ollama](https://ollama.com) - Local LLM runtime
- [AWS Bedrock](https://aws.amazon.com/bedrock/) - Cloud LLM platform
- [Anthropic Claude Haiku 4.5](https://www.anthropic.com/claude/haiku) - The cloud reasoning engine

---

## License

This project is shared under the MIT License. See LICENSE for details.

Original Cowrie code remains under its existing BSD-3-Clause license.

---

## Contact

If you are interested in this project, deception engineering, or LLM-augmented security tooling, reach out via LinkedIn.

**Project status:** Hackathon prototype. Improvements roadmap above outlines path to production.
