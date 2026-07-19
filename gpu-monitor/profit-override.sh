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
JSONL_FILE="${GPU_DATA:-/var/log/gpu_monitor_data.jsonl}"

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
            awk -F'|' '{
                if ($6+0>0)        src="yes, matched live instance";
                else if ($7+0>0)   src="no live instance match, but using live earn_day rate ($" $7/24 "/hr, reliable)";
                else               src="no (listing-price fallback, unreliable)";
                printf "  machine %s | %s | %s | rented: %s | rate source: %s\n", $1, $3, $4, $2, src
            }' "$STATE_FILE"
        fi
        if [[ -f "$JSONL_FILE" ]]; then
            echo ""
            echo "Earned-revenue estimate (what the throttle actually uses):"
            python3 - "$JSONL_FILE" <<'PYEOF' 2>/dev/null
import sys, json, datetime, socket
jsonl = sys.argv[1]
host = socket.gethostname()
now = datetime.datetime.now(datetime.timezone.utc)
today = now.strftime('%Y-%m-%d')
yesterday = (now - datetime.timedelta(days=1)).strftime('%Y-%m-%d')
by_date = {}
try:
    for line in open(jsonl, errors='replace'):
        try:
            e = json.loads(line)
        except Exception:
            continue
        # Missing source (not "vast_api") only means an entry predates the
        # write format adding that field — same real data, see gpu_monitor.sh.
        if e.get('type') == 'daily_earnings' and e.get('source') in ('vast_api', None) and e.get('host') == host:
            d = e.get('date')
            ts = e.get('ts', '')
            prev = by_date.get(d)
            if not prev or ts > prev[0]:
                by_date[d] = (ts, float(e.get('total', 0) or 0))
except FileNotFoundError:
    print("  no earnings data yet")
    sys.exit(0)
if yesterday in by_date:
    print(f"  yesterday ({yesterday}): ${by_date[yesterday][1]:.2f}" + ("  <- used as the daily-rate estimate" if by_date[yesterday][1] > 0 else ""))
else:
    print(f"  yesterday ({yesterday}): no data")
if today in by_date:
    elapsed_h = now.hour + now.minute / 60.0
    extrap = by_date[today][1] / elapsed_h * 24 if elapsed_h > 0 else 0
    note = ""
    if not (yesterday in by_date and by_date[yesterday][1] > 0):
        note = "  <- used as the daily-rate estimate" if elapsed_h >= 3.0 else "  (too early in the day to extrapolate yet)"
    print(f"  today so far ({today}): ${by_date[today][1]:.2f} ({elapsed_h:.1f}h elapsed -> ~${extrap:.2f}/day extrapolated){note}")
else:
    print(f"  today ({today}): no data yet")
PYEOF
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
