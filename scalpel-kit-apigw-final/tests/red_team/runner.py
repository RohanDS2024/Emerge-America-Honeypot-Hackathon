import argparse
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import paramiko
import probes
import scoring


class SSHRunner:
    def __init__(self, host, user, password, port=22):
        self.host = host
        self.user = user
        self.password = password
        self.port = port
        self.client = None
        self.shell = None

    def connect(self):
        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.client.connect(self.host, port=self.port, username=self.user,
                            password=self.password, timeout=10,
                            allow_agent=False, look_for_keys=False)
        self.shell = self.client.invoke_shell(term="xterm", width=200, height=50)
        time.sleep(1.2)
        while self.shell.recv_ready():
            self.shell.recv(65536)
            time.sleep(0.1)

    def run(self, command, timeout=10):
        if self.client is None or self.shell is None:
            self.connect()
        # Send Ctrl+C to break any stuck pipes from previous commands
        try:
            self.shell.send(b"\x03\n")
            time.sleep(0.1)
        except Exception:
            pass
        # Drain any leftover bytes
        while self.shell.recv_ready():
            self.shell.recv(65536)
            time.sleep(0.02)
        start = time.perf_counter()
        try:
            marker = "___DONE_%d___" % int(time.time() * 1000000)
            payload = command + "\necho " + marker + "\n"
            self.shell.send(payload.encode())
            out = ""
            deadline = time.time() + timeout
            while time.time() < deadline:
                if self.shell.recv_ready():
                    out += self.shell.recv(65536).decode("utf-8", errors="replace")
                    if marker in out:
                        break
                else:
                    time.sleep(0.03)
            elapsed = time.perf_counter() - start
            try:
                with open("/tmp/runner_debug.log", "a") as df:
                    df.write("CMD=" + repr(command) + " RAW=" + repr(out)[:500] + "\n")
            except Exception:
                pass
        except Exception as e:
            return "<SSH_ERROR: " + str(e) + ">", time.perf_counter() - start

        # Strip ANSI CSI (color, cursor), OSC (title), and carriage returns
        raw = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", out)
        raw = re.sub(r"\x1b\][^\x07]*\x07", "", raw)
        raw = raw.replace("\r", "")
        # Cut at marker
        idx = raw.find(marker)
        if idx >= 0:
            raw = raw[:idx]
        # Remove the command echo itself and the "echo MARKER" line echo
        raw = raw.replace(command + "\necho " + marker, "")
        raw = raw.replace(command, "", 1)
        raw = raw.replace("echo " + marker, "")

        kept = []
        for line in raw.split("\n"):
            s = line.rstrip()
            if not s:
                continue
            # Skip any line with a shell prompt (user@host:path# or $)
            if re.search(r"[a-zA-Z0-9_-]+@[a-zA-Z0-9_.-]+:[^\s]*\s*[#$]", s):
                continue
            # Skip lone "echo" or "echo ___..."
            if s.strip() == "echo":
                continue
            if re.match(r"^echo\s+___", s.strip()):
                continue
            kept.append(s)
        return "\n".join(kept), elapsed

    def close(self):
        if self.client:
            try:
                self.client.close()
            except Exception:
                pass
            self.client = None
            self.shell = None


VOLATILE_PATTERNS = [
    re.compile(r"\b\d+:\d+:\d+\b"),
    re.compile(r"\b\d+ days?, \d+:\d+\b"),
    re.compile(r"up \d+ \w+,? "),
    re.compile(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"),
    re.compile(r"load average: [\d., ]+"),
    re.compile(r"\d+%\s+/"),
    re.compile(r"\b\d+M\s+used\b"),
]


def normalize(text):
    n = text
    for p in VOLATILE_PATTERNS:
        n = p.sub("<VOL>", n)
    n = re.sub(r"\s+", " ", n).strip().lower()
    return n


def compare(honey, truth):
    return normalize(honey) == normalize(truth)


def categorize_finding(cmd, honey, truth):
    if not honey or honey.startswith("<SSH_ERROR"):
        return "no_response"
    if "command not found" in honey.lower() and "command not found" not in truth.lower():
        return "missing_command"
    if "permission denied" in honey.lower() and "permission denied" not in truth.lower():
        return "permission_diff"
    if any(k in cmd for k in ["/etc/", "/proc/", "/sys/", "cat ", "ls "]):
        return "filesystem_mismatch"
    if "uname" in cmd or "version" in cmd or "release" in cmd:
        return "version_string_mismatch"
    return "wrong_output"


LATENCY_THRESHOLDS = {"easy": 0.3, "intermediate": 1.0, "complex": 3.0, "latency": 0.2}


def is_escalation_finding(category, elapsed):
    return elapsed > LATENCY_THRESHOLDS.get(category, 1.0)


def run_gauntlet(honeypot_ip, truth_ip, save_path=None):
    print("Connecting to honeypot at " + honeypot_ip + ":2222")
    honey = SSHRunner(honeypot_ip, "root", "root", 2222)
    honey.connect()
    print("Connecting to ground truth at " + truth_ip + ":22")
    truth = SSHRunner(truth_ip, "pi", "raspberry", 22)
    truth.connect()

    all_probes = probes.all_probes()
    print("Running " + str(len(all_probes)) + " probes\n")

    results = []
    demerits = 0
    escalations = 0
    findings = []

    for i, (category, cmd) in enumerate(all_probes, 1):
        try:
            h_out, h_t = honey.run(cmd)
        except Exception as e:
            h_out, h_t = "<SSH_ERROR: " + str(e) + ">", 0.0
        try:
            t_out, t_t = truth.run(cmd)
        except Exception as e:
            t_out, t_t = "<SSH_ERROR: " + str(e) + ">", 0.0

        match = compare(h_out, t_out)
        esc = is_escalation_finding(category, h_t)

        if not match:
            demerits += 1
            findings.append({"cmd": cmd, "kind": categorize_finding(cmd, h_out, t_out),
                             "category": category, "honey": h_out[:200], "truth": t_out[:200]})
        if esc:
            escalations += 1

        results.append({"category": category, "cmd": cmd, "match": match, "escalation": esc,
                        "honey_t": round(h_t * 1000, 1), "truth_t": round(t_t * 1000, 1),
                        "honey_out": h_out[:300], "truth_out": t_out[:300]})

        status = "OK" if match else "NO"
        flag = " [SLOW]" if esc else ""
        print("  {:3d}. [{:4s}] {:<2s} {:<40s} {:5.0f}ms{}".format(
            i, category[:4], status, cmd, h_t * 1000, flag))

    honey.close()
    truth.close()

    score = scoring.compute_score(total_probes=len(results), demerits=demerits,
                                   escalations=escalations, presentation=90.0)
    print()
    scoring.print_report(score, findings)

    if save_path:
        save_path.write_text(json.dumps({"score": score, "results": results,
                                          "findings": findings}, indent=2))
        print("Report saved: " + str(save_path))

    return score, results, findings


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--honeypot", required=True)
    p.add_argument("--truth", required=True)
    p.add_argument("--save", default=None)
    args = p.parse_args()
    save_path = Path(args.save) if args.save else Path("gauntlet_report.json")
    run_gauntlet(args.honeypot, args.truth, save_path)