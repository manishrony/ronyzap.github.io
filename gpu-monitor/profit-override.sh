#!/usr/bin/env bash
# Manually override the profit-based power throttle for THIS rig (see
# PROFIT_THROTTLE_TIERS in gpu_monitor.sh) — e.g. to force full power despite
# a low-paying rental, or force savings even on a decent one.
#
# The override is TEMPORARY: gpu_monitor.sh clears it automatically the
# instant the current rental ends, so it only ever affects the rental you set
# it for — it never silently controls a future one you didn't mean it to.
# Takes effect on the monitor's next cycle (within THERMAL_CHECK_INTERVAL,
# ~60s) — no restart needed.
#
# Usage:
#   sudo profit-override <watts>   force this power cap (e.g. 360, 300, 250)
#   sudo profit-override off       disable profit throttling (full power / thermal curve only)
#   sudo profit-override clear     remove the override, resume automatic tiering
#   sudo profit-override status    show the current override + live rental rate

set -euo pipefail

OVERRIDE_FILE="/var/tmp/gpu_monitor_profit_override"
STATE_FILE="/var/tmp/gpu_monitor_vastai_state"

case "${1:-status}" in
    status)
        if [[ -f "$OVERRIDE_FILE" ]]; then
            echo "Override active: $(cat "$OVERRIDE_FILE") (clears automatically when the current rental ends)"
        else
            echo "No override set — running automatic profit-tier logic."
        fi
        if [[ -f "$STATE_FILE" ]]; then
            echo ""
            echo "Live rental state:"
            awk -F'|' '{printf "  machine %s | %s | %s | rented: %s\n", $1, $3, $4, $2}' "$STATE_FILE"
        fi
        ;;
    clear)
        rm -f "$OVERRIDE_FILE"
        echo "[OK] Override cleared. Automatic tiering resumes on the monitor's next cycle (~60s)."
        ;;
    off)
        echo "off" > "$OVERRIDE_FILE"
        echo "[OK] Profit throttle disabled — full power (still subject to the thermal curve)."
        echo "     Clears automatically when the current rental ends."
        ;;
    ''|*[!0-9]*)
        echo "Usage: profit-override <watts>|off|clear|status" >&2
        exit 1
        ;;
    *)
        echo "$1" > "$OVERRIDE_FILE"
        echo "[OK] Power cap overridden to ${1}W. Clears automatically when the current rental ends."
        ;;
esac
