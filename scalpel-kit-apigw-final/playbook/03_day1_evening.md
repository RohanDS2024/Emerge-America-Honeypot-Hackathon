# 03 — Day 1 Evening (April 23, 18:30–22:00) — Hotel Work Session

**The Pi is gone. The Lambda and your code aren't.**

---

## Priorities (in order)

### 1. Refine the system prompt (90 min, B1 lead)

Take the gauntlet report from afternoon. For every Tier 2 finding, ask: "is the system prompt unambiguous about this?"

Common improvements to add to `src/router/system_prompt.txt`:
- Specific output formats for `ps aux`, `ss -tlnp`, `journalctl`
- Exact `/proc/cpuinfo` BCM2712 / Cortex-A76 details
- The exact Pi 5 kernel string (capture from clean Pi notes)
- Examples of what NOT to say (preambles, markdown)

Test against Lambda directly:
```bash
curl -X POST $SVCD_CLOUD_URL -d '{
  "command":"ps aux",
  "history":[]
}'
```

Iterate until output looks Pi-realistic.

### 2. Improve Tier 1 coverage (60 min, A2 lead)

Findings of type `missing_command` mean the gauntlet ran a command we didn't capture. Add them to `src/scripts/capture_groundtruth.sh` for tomorrow's re-run:

Open the COMMANDS array. Add the missing ones. Tomorrow morning before 9:00 you re-run the capture script.

### 3. Build the presentation (90 min, presenter + 1 helper)

Open `presentation/deck.md`. It's Marp-format markdown. Fill in:
- Your team name + member names
- Real numbers from the afternoon gauntlet
- Real screenshots from the dashboard
- Your benchmark numbers for qwen2.5 vs phi3 if you have them

Render to PDF for backup:
```bash
npx @marp-team/marp-cli@latest presentation/deck.md -o presentation/deck.pdf
```

Or use it directly in Marp/VS Code preview.

### 4. Lambda prompt tuning (45 min, B2 lead)

For Tier 3 commands (find, apt, dpkg, journalctl, locate), test the Lambda response quality:

```bash
for cmd in "find / -name '*.conf' | head -10" "apt list --installed | head -20" "dpkg -l | head -20" "journalctl -n 30"; do
  echo "=== $cmd ==="
  curl -s -X POST $SVCD_CLOUD_URL -d "{\"command\":\"$cmd\",\"history\":[]}" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])"
done
```

If responses look thin or wrong, the system prompt in the Lambda's deployment package needs improvement. Edit `src/cloud/system_prompt.txt` (it's a copy of the router's; keep them in sync), redeploy:

```bash
bash src/scripts/deploy_cloud.sh
```

---

## What you're NOT doing tonight

- **No major architectural changes.** No new tiers. No new components.
- **No new features.** "What if we also add an HTTP honeypot..." → NO.
- **No re-benchmarking models.** You picked qwen2.5:1.5b. Stick with it.
- **No Cowrie source patching.** The output-plugin approach is working.

---

## 22:00 — Sleep

- [ ] All changes pushed to git
- [ ] Presentation draft saved to laptop AND USB
- [ ] Alarm 06:30
- [ ] Phone charged

The morning is the second self-gauntlet + final hardening + presentation lock at 09:45.
