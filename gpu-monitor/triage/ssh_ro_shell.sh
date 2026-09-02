#!/usr/bin/env bash
#
# ssh_ro_shell.sh — forced-command wrapper for the zappa1 triage automation's
# dedicated SSH key. Install this as the `command=` in zappa2/zappa3's
# authorized_keys for that key's public-key line (see README.md). Even if
# the key were fully compromised, the attacker only ever gets to run one of
# the exact commands below -- never an arbitrary shell.
#
# This is the THIRD layer of the same Tier-1 boundary: settings.json scopes
# the Claude Code tool calls, TRIAGE_PROMPT.md tells the agent the same
# boundary in plain language, and this enforces it again at the SSH layer
# on the machine actually being accessed -- independent of whether the
# other two layers ever get bypassed or misconfigured.

set -uo pipefail

cmd="${SSH_ORIGINAL_COMMAND:-}"

if [[ -z "$cmd" ]]; then
    echo "ssh_ro_shell: no command given" >&2
    exit 1
fi

# Exact allow-list, mirroring settings.json's Bash allow patterns. Match
# strictly -- no wildcarding beyond what's written here, no chaining via
# ; && || | (the incident-dir ls/cat commands are the only ones with
# variable arguments, and those are constrained to that one directory).
case "$cmd" in
    "ipmitool sel elist"* | "ipmitool sel list"* | "ipmitool sensor list"* | "ipmitool chassis status"*)
        ;;
    "nvidia-smi"*)
        ;;
    "dmesg"*)
        ;;
    "journalctl -u gpu-monitor"* | "journalctl -u gpu-dashboard"* | "journalctl -k"*)
        ;;
    "docker ps"* | "docker logs "* | "docker inspect "* | "docker top "*)
        ;;
    "ls /var/tmp/gpu_monitor_incidents/"*)
        ;;
    "cat /var/tmp/gpu_monitor_incidents/"* | "cat /var/log/gpu_monitor.log" | "cat /var/log/gpu_monitor_data.jsonl")
        ;;
    "tail "*" /var/log/gpu_monitor.log" | "tail "*" /var/log/gpu_monitor_data.jsonl")
        ;;
    "grep "*" /var/log/gpu_monitor.log" | "grep "*" /var/log/gpu_monitor_data.jsonl")
        ;;
    *)
        echo "ssh_ro_shell: command not permitted: $cmd" >&2
        logger -t zappa1_triage_ssh "REJECTED command from triage key: $cmd"
        exit 1
        ;;
esac

# Reject any attempt to chain commands even within an otherwise-matched
# prefix (e.g. "nvidia-smi; rm -rf /" would match the nvidia-smi* pattern
# above on prefix alone).
if [[ "$cmd" == *";"* || "$cmd" == *"&&"* || "$cmd" == *"||"* || "$cmd" == *"\`"* || "$cmd" == *'$('* ]]; then
    echo "ssh_ro_shell: command chaining/substitution not permitted" >&2
    logger -t zappa1_triage_ssh "REJECTED chained/substituted command from triage key: $cmd"
    exit 1
fi

exec bash -c "$cmd"
