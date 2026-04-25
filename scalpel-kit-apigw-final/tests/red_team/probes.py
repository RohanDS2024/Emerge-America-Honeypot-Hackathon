"""
SCALPEL probe library — what we test ourselves with.

Mirrors what the official Red Team will probe. Categorized by difficulty.
Add probes here as you learn what the actual Red Team is testing.
"""

# Easy: basic Linux commands. Should ALL hit Tier 1 lookup. <50ms.
EASY = [
    "uname -a",
    "uname -r",
    "uname -m",
    "uname -s",
    "hostname",
    "whoami",
    "id",
    "pwd",
    "uptime",
    "date",
    "echo $SHELL",
    "echo $USER",
    "echo $HOME",
    "cat /etc/os-release",
    "cat /etc/hostname",
    "cat /etc/debian_version",
    "cat /etc/issue",
    "cat /etc/passwd",
    "ls /",
    "ls /home",
    "ls /root",
    "df -h",
    "free -h",
    "lscpu",
    "lsb_release -a",
    "which python3",
    "which bash",
    "env",
]

# Intermediate: stateful or contextual. Tier 2 (Ollama). 200-800ms.
INTERMEDIATE = [
    "ps aux",
    "ps -ef",
    "ss -tlnp",
    "netstat -an",
    "cat /proc/cpuinfo",
    "cat /proc/meminfo",
    "cat /proc/version",
    "cat /etc/group",
    "ls -la /etc/ssh/",
    "ls /boot/firmware/",
    "cat /boot/firmware/config.txt",
    "ip a",
    "ip route",
    "iptables -L",
    "crontab -l",
    "hostnamectl",
    "timedatectl",
    "systemctl list-units --type=service --state=running",
    "tail /var/log/syslog",
    "tail /var/log/auth.log",
    "cat /home/pi/.bash_history",
]

# Complex: anti-honeypot detection. Some go Tier 3, some stay Tier 2.
COMPLEX = [
    # Naturally slow — cloud OK
    "find / -name '*.conf' 2>/dev/null | head -20",
    "apt list --installed 2>/dev/null | head -30",
    "dpkg -l | head -20",
    "journalctl -n 50 --no-pager",
    # Fingerprinting
    "cat /proc/1/comm",
    "cat /proc/1/cmdline",
    "stat /etc/passwd",
    "readlink /proc/self/exe",
    "lsmod | head",
    "dmesg | head -5",
    # Shell quirks
    "echo $((1+1))",
    "type cd",
    "type ls",
    "command -v sudo",
    "alias",
    "bash --version",
]

# Latency: deliberately fast commands. Tier 3 here = guaranteed finding.
LATENCY = [
    "echo a",
    "true",
    ":",
    "pwd",
    "whoami",
    "echo $$",
    "echo done",
]


def all_probes() -> list[tuple[str, str]]:
    """Return all probes tagged with their category."""
    return (
        [("easy", c) for c in EASY]
        + [("intermediate", c) for c in INTERMEDIATE]
        + [("complex", c) for c in COMPLEX]
        + [("latency", c) for c in LATENCY]
    )


def total_count() -> int:
    return len(EASY) + len(INTERMEDIATE) + len(COMPLEX) + len(LATENCY)
