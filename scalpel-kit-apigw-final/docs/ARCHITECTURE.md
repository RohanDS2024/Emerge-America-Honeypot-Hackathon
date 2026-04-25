# Architecture

## System diagram

```
                        Red Team SSH attacker
                                │
                                │  ssh root@<pi> -p 2222 (password: root)
                                ▼
                  ┌─────────────────────────────┐
                  │  Cowrie SSH honeypot        │
                  │  (pre-installed, port 2222) │
                  └─────────────┬───────────────┘
                                │
                                │  intercepted command
                                ▼
                  ┌─────────────────────────────┐
                  │  ScalpelCommand handler     │
                  │  src/cowrie_patch/          │
                  │  scalpel_command.py         │
                  └─────────────┬───────────────┘
                                │
                                │  route(cmd, session)
                                ▼
                  ┌─────────────────────────────┐
                  │  Router                     │
                  │  src/router/router.py       │
                  └────┬───────┬───────┬────────┘
                       │       │       │
              ┌────────┘       │       └─────────┐
              ▼                ▼                 ▼
        ┌──────────┐    ┌──────────┐      ┌──────────┐
        │ Tier 1   │    │ Tier 2   │      │ Tier 3   │
        │ Lookup   │    │ Ollama   │      │ Lambda + │
        │  <50ms   │    │ qwen2.5  │      │ Bedrock  │
        │          │    │ 200-800ms│      │ 800-2s   │
        └──────────┘    └──────────┘      └──────────┘
                                │
                                │  log every call
                                ▼
                  ┌─────────────────────────────┐
                  │  /var/log/scalpel/          │
                  │  metrics.jsonl              │
                  └─────────────┬───────────────┘
                                │
                                ▼
                  ┌─────────────────────────────┐
                  │  Dashboard (Flask :8080)    │
                  │  src/dashboard/dashboard.py │
                  └─────────────────────────────┘
```

## Component responsibilities

| Component | What it does | Latency budget |
|---|---|---|
| Cowrie | SSH server, session management | (existing) |
| ScalpelCommand | Intercept commands for our list, call router | <5ms overhead |
| Router | Decide tier, call backend, log metrics | <10ms overhead |
| Tier 1 (lookup) | Return ground-truth captures verbatim | <50ms total |
| Tier 2 (Ollama) | LLM-generated Pi-OS-Bookworm responses | 200-800ms |
| Tier 3 (Lambda) | High-quality responses via Bedrock | 800-2000ms |
| Dashboard | Live metrics for presentation | N/A |
| Self-gauntlet | Score yourselves against ground truth | N/A |

## Data flow per command

1. Attacker types `uname -a`
2. Cowrie protocol layer hands command to `ScalpelCommand`
3. `ScalpelCommand.call()` extracts the command + session ID, calls `router.route()`
4. Router checks Tier 1 lookup (normalized command match)
5. If hit: returns canned ground-truth string
6. Router logs `{ts, cmd, tier:"tier1_local", latency_ms, ...}` to `metrics.jsonl`
7. ScalpelCommand writes string to attacker TTY via `self.write()`
8. Dashboard polls metrics, updates counts every 2 seconds

## Why no Cowrie source patching

The clean approach is to register custom command handlers via Cowrie's
`commands/` module. Our `ScalpelCommand` class is registered for ~30 commands
that need our routing. Cowrie's built-in handlers (`txtcmds`, scripted shell
commands like `cd`/`exit`) handle everything else.

This means:
- No Cowrie source files modified (clean upgrade path)
- No risk of breaking Twisted protocol handling
- Easy to add/remove intercepted commands via the `INTERCEPTED_COMMANDS` set

## Session state

Each SSH session gets a `SessionState` object containing:
- `session_id` (Cowrie's session number)
- `history`: list of (cmd, response) tuples — last 5 used as LLM context
- `start_time`: for any uptime calculations
- `cwd`: virtual current working directory

The router passes session state to Tier 2/3 so the LLM stays consistent
within a single attacker session. Critical for filesystem questions like
"I just did `mkdir foo && cd foo`, what's `pwd`?"
