# 00 — Pre-Event (Tonight, April 22)

**Time budget: 90 minutes**

---

## 1. AWS Bedrock model access (DO FIRST — can take hours)

```
1. Log into AWS Console → us-east-1 region
2. Search "Bedrock" → Model access (left sidebar)
3. Click "Manage model access"
4. Check: Anthropic → Claude Haiku (claude-haiku-4-5)
5. Submit. Approval can take a few hours.
```

If approval doesn't come through by Day 1 morning, the router automatically falls back to Ollama for everything. You'll lose some Tier 3 quality but won't be blocked.

---

## 2. Verify AWS CLI access

```bash
aws sts get-caller-identity
aws bedrock list-foundation-models --region us-east-1 | head
```

If this fails, fix it tonight. You can't do it at the venue.

---

## 3. Pull the deployment kit onto your laptop

The kit is in this zip. Verify everything works locally before the venue:

```bash
unzip scalpel-build-and-win-kit.zip
cd scalpel-kit
pip install paramiko flask requests boto3
python3 tests/red_team/scoring.py  # should print "Math validated"
```

---

## 4. Pull qwen2.5:1.5b on your laptop

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama serve &
ollama pull qwen2.5:1.5b
```

Test the system prompt:

```bash
curl http://localhost:11434/api/generate -d "{
  \"model\":\"qwen2.5:1.5b\",
  \"system\":\"$(cat src/router/system_prompt.txt | tr '\n' ' ')\",
  \"prompt\":\"$ uname -a\n\",
  \"stream\":false
}" | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])"
```

You should get something close to a real Pi response. If it's adding preamble or markdown, the system prompt may need strengthening — note this for tomorrow.

---

## 5. Read in this order

1. `docs/COMMANDERS_INTENT.md` — 5 minutes
2. `docs/SCORING.md` — 10 minutes
3. `docs/ARCHITECTURE.md` — 10 minutes
4. Skim `src/router/router.py` — 10 minutes (you'll modify this tomorrow)

---

## 6. Team coordination

- [ ] Slack channel created, all 5 + mentor in it
- [ ] GitHub repo created with this kit pushed, everyone can clone
- [ ] Sub-team A (3 people): Cowrie, filesystem, ground truth
- [ ] Sub-team B (2 people): Ollama, router, AWS, dashboard
- [ ] Who's presenting Day 2? Decide tonight.

---

## 7. Pack list

- Laptop + charger
- USB-C cable (for Pi serial if needed)
- Ethernet cable (some venues are flaky on WiFi)
- Phone hotspot ready as backup
- USB stick with this kit (in case GitHub is blocked at venue)
- **A SECOND USB stick (8GB+, empty, formatted FAT32 or exFAT) dedicated for SCALPEL backups.** Label it "SCALPEL-BACKUP" with tape. Test it tonight: plug into laptop, create `scalpel-snapshots/` folder, unmount. If it throws errors, bring a different one.
- USB SD card adapter if you have one (enables full SD imaging Day 1 morning)
- Sticky notes (for labeling which laptop/cable belongs to which teammate)

---

## 8. Sleep checklist

- [ ] Alarm set for 06:30
- [ ] AWS Bedrock access requested
- [ ] Kit cloned and tested on laptop
- [ ] Slack notifications on for the team channel

---

**Tomorrow at 09:00 you walk in with a working kit on your laptop and a clear plan. That's the goal.**
