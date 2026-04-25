"""
monitor.py — local metrics dashboard with optional basic auth.

Binds to 127.0.0.1 ONLY. Even on localhost, supports an optional
DASH_PASSWORD env var for an extra layer (in case multiple users
share the Pi or the SSH tunnel exposes it inadvertently).

Usage:
  # No password
  python3 monitor.py

  # With password
  DASH_PASSWORD=hunter2 python3 monitor.py

View from laptop:
  ssh -N -L 8080:127.0.0.1:8080 cowrie@<pi>
  open http://127.0.0.1:8080
"""

import json
import os
import time
import secrets
from collections import defaultdict
from functools import wraps
from pathlib import Path

from flask import Flask, jsonify, render_template_string, request, Response

METRICS_LOG = Path(os.environ.get("SVCD_METRICS", "/var/log/journal/svcd/events.jsonl"))
DASH_PASSWORD = os.environ.get("DASH_PASSWORD", "")  # empty = no auth

app = Flask(__name__)


def requires_auth(f):
    @wraps(f)
    def wrapped(*a, **kw):
        if not DASH_PASSWORD:
            return f(*a, **kw)
        auth = request.authorization
        if not auth or auth.username != "viewer" or not secrets.compare_digest(auth.password, DASH_PASSWORD):
            return Response(
                "Authentication required",
                401,
                {"WWW-Authenticate": 'Basic realm="dashboard"'},
            )
        return f(*a, **kw)
    return wrapped


def parse_all_metrics():
    stats = {
        "total": 0, "tier1_local": 0, "tier2_local": 0, "tier3_cloud": 0, "error": 0,
        "latency_sum": defaultdict(int), "latency_count": defaultdict(int),
        "sessions": set(),
    }
    if not METRICS_LOG.exists():
        return stats
    with open(METRICS_LOG) as f:
        for line in f:
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            tier = e.get("tier", "unknown")
            stats["total"] += 1
            stats[tier] = stats.get(tier, 0) + 1
            stats["latency_sum"][tier] += e.get("latency_ms", 0)
            stats["latency_count"][tier] += 1
            stats["sessions"].add(e.get("session", ""))
    return stats


def stats_to_response(stats):
    cloud = stats.get("tier3_cloud", 0)
    total = stats.get("total", 0)
    edge_ratio = 100.0 if total == 0 else 100.0 * (total - cloud) / total
    avg_latency = {}
    for tier in ("tier1_local", "tier2_local", "tier3_cloud"):
        cnt = stats["latency_count"].get(tier, 0)
        avg_latency[tier] = round(stats["latency_sum"].get(tier, 0) / cnt, 1) if cnt else 0
    return {
        "total": total,
        "tier1_local": stats.get("tier1_local", 0),
        "tier2_local": stats.get("tier2_local", 0),
        "tier3_cloud": stats.get("tier3_cloud", 0),
        "errors": stats.get("error", 0),
        "edge_ratio": round(edge_ratio, 1),
        "avg_latency_ms": avg_latency,
        "session_count": len(stats["sessions"]),
    }


def tail_recent(n=15):
    if not METRICS_LOG.exists():
        return []
    size = METRICS_LOG.stat().st_size
    read_from = max(0, size - 16384)
    with open(METRICS_LOG, "rb") as f:
        f.seek(read_from)
        chunk = f.read().decode("utf-8", errors="ignore")
    lines = chunk.strip().split("\n")
    entries = []
    for line in lines[-n:]:
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return list(reversed(entries))


@app.route("/api/stats")
@requires_auth
def api_stats():
    return jsonify(stats_to_response(parse_all_metrics()))


@app.route("/api/recent")
@requires_auth
def api_recent():
    return jsonify(tail_recent(15))


HTML = """<!DOCTYPE html>
<html>
<head>
<title>Live Metrics</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, system-ui, sans-serif; background: #0a0a0a; color: #eee; margin: 0; padding: 1.5rem; }
  h1 { font-weight: 300; margin: 0 0 1rem; font-size: 1.5rem; letter-spacing: -0.02em; }
  h2 { font-weight: 400; font-size: 0.95rem; color: #888; margin: 2rem 0 0.75rem; text-transform: uppercase; letter-spacing: 0.08em; }
  .row { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-bottom: 0.5rem; }
  .card { background: #181818; padding: 1.25rem; border-radius: 8px; border: 1px solid #222; }
  .label { color: #888; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: 0.25rem; }
  .big { font-size: 2.75rem; font-weight: 200; line-height: 1; }
  .green { color: #5ee07a; }  .yellow { color: #ffc857; }  .red { color: #ff7070; }  .blue { color: #6cb3ff; }
  table { width: 100%; font-family: ui-monospace, monospace; font-size: 0.78rem; border-collapse: collapse; background: #181818; border-radius: 8px; overflow: hidden; }
  th { text-align: left; padding: 0.6rem 0.9rem; background: #222; color: #aaa; font-weight: 500; text-transform: uppercase; font-size: 0.7rem; letter-spacing: 0.05em; }
  td { padding: 0.5rem 0.9rem; border-top: 1px solid #222; color: #ccc; }
  td.tier1 { color: #5ee07a; }  td.tier2 { color: #ffc857; }  td.tier3 { color: #ff7070; }
  td.cmd { font-weight: 500; color: #fff; }
  .pulse { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #5ee07a; margin-right: 0.5rem; animation: pulse 1.5s ease-in-out infinite; }
  @keyframes pulse { 0%,100% { opacity: 1 } 50% { opacity: 0.3 } }
</style>
</head>
<body>
<h1><span class="pulse"></span>Project SCALPEL — Live Metrics</h1>
<div class="row">
  <div class="card"><div class="label">Total probes</div><div class="big" id="total">0</div></div>
  <div class="card"><div class="label">Edge ratio</div><div class="big green" id="edge">—%</div></div>
  <div class="card"><div class="label">Active sessions</div><div class="big blue" id="sessions">0</div></div>
  <div class="card"><div class="label">Cloud calls</div><div class="big yellow" id="cloud">0</div></div>
</div>
<h2>By tier</h2>
<div class="row">
  <div class="card"><div class="label">Tier 1 — Local lookup</div><div class="big green" id="t1">0</div><div class="label" style="margin-top:0.5rem">avg <span id="lat1">0</span> ms</div></div>
  <div class="card"><div class="label">Tier 2 — Local LLM</div><div class="big yellow" id="t2">0</div><div class="label" style="margin-top:0.5rem">avg <span id="lat2">0</span> ms</div></div>
  <div class="card"><div class="label">Tier 3 — Cloud</div><div class="big red" id="t3">0</div><div class="label" style="margin-top:0.5rem">avg <span id="lat3">0</span> ms</div></div>
</div>
<h2>Live command stream</h2>
<table id="recent">
  <thead><tr><th>Time</th><th>Session</th><th>Command</th><th>Tier</th><th>Latency</th></tr></thead>
  <tbody id="recent-body"></tbody>
</table>
<script>
async function refresh() {
  try {
    const stats = await (await fetch('/api/stats')).json();
    document.getElementById('total').textContent = stats.total;
    document.getElementById('edge').textContent = stats.edge_ratio.toFixed(1) + '%';
    document.getElementById('sessions').textContent = stats.session_count;
    document.getElementById('cloud').textContent = stats.tier3_cloud;
    document.getElementById('t1').textContent = stats.tier1_local;
    document.getElementById('t2').textContent = stats.tier2_local;
    document.getElementById('t3').textContent = stats.tier3_cloud;
    document.getElementById('lat1').textContent = stats.avg_latency_ms.tier1_local;
    document.getElementById('lat2').textContent = stats.avg_latency_ms.tier2_local;
    document.getElementById('lat3').textContent = stats.avg_latency_ms.tier3_cloud;
    const recent = await (await fetch('/api/recent')).json();
    const tbody = document.getElementById('recent-body');
    tbody.innerHTML = recent.map(r => {
      const t = new Date(r.ts * 1000).toLocaleTimeString();
      const tierClass = r.tier === 'tier1_local' ? 'tier1' : r.tier === 'tier2_local' ? 'tier2' : 'tier3';
      const tierLabel = r.tier.replace('tier', 'T').replace('_', ' ');
      return `<tr><td>${t}</td><td>${r.session ? r.session.slice(0,8) : '—'}</td><td class="cmd">${escapeHtml(r.cmd)}</td><td class="${tierClass}">${tierLabel}</td><td>${r.latency_ms} ms</td></tr>`;
    }).join('');
  } catch (e) { console.error(e); }
}
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
refresh();
setInterval(refresh, 2000);
</script>
</body>
</html>
"""


@app.route("/")
@requires_auth
def home():
    return render_template_string(HTML)


if __name__ == "__main__":
    if not DASH_PASSWORD:
        print("⚠️  DASH_PASSWORD not set. Dashboard accepts any localhost connection.")
        print("    For extra safety: DASH_PASSWORD='somepass' python3 monitor.py")
    else:
        print(f"Dashboard auth enabled (user 'viewer', password from DASH_PASSWORD env)")
    # 127.0.0.1 ONLY. Never 0.0.0.0.
    app.run(host="127.0.0.1", port=8080, debug=False)
