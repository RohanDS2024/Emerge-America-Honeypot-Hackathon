"""
unattended.py — Cowrie command intercept module.

(Internally: SCALPEL Cowrie integration. Module name chosen to blend in
with Cowrie's existing command modules. The class name is generic. No
strings in this file mention our actual purpose.)

Cowrie loads this via cowrie/commands/__init__.py and registers handlers
for the commands listed in the `commands` dict at module bottom.
"""

from __future__ import annotations
import sys
import os

# Disguised path
sys.path.insert(0, "/home/cowrie/.local/lib")

from cowrie.shell.command import HoneyPotCommand

from svcd.router import route, get_session


# Commands we intercept. Cowrie's built-in handlers handle the rest.
INTERCEPTED_COMMANDS = {
    "uname", "hostname", "whoami", "id", "uptime",
    "lscpu", "lsb_release", "hostnamectl", "timedatectl",
    "ip", "ss", "netstat", "iptables", "systemctl",
    "ps", "free", "df", "du",
    "apt", "apt-get", "dpkg",
    "find", "locate", "updatedb",
    "journalctl", "dmesg",
    "stat", "readlink",
    "type", "command", "alias",
}


class SystemCommand(HoneyPotCommand):
    """Routes intercepted commands through the local handler."""

    def call(self):
        # Reconstruct full command line
        if not self.args:
            cmd_full = self.protocol.cmdstack[-1].cmdpending[0] if self.protocol.cmdstack else ""
        else:
            cmd_name = self.__class__.__name__.replace("Command_", "").replace("command_", "")
            cmd_full = f"{cmd_name} {' '.join(self.args)}".strip()

        session_id = str(self.protocol.terminal.transport.session.session.sessionno)
        session = get_session(session_id)

        try:
            response = route(cmd_full, session)
            if response:
                self.write(response + "\n")
        except Exception:
            self.write(f"bash: {cmd_full.split()[0] if cmd_full.split() else 'sh'}: command not found\n")

        self.exit()


# Cowrie's command loader reads this dict
commands = {cmd: SystemCommand for cmd in INTERCEPTED_COMMANDS}
