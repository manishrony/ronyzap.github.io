#!/usr/bin/env bash
# Print today's rental activity + revenue for THIS rig in one shot, from the
# monitor's event log (gpu_monitor_data.jsonl) plus kaalia.log for exact
# container-launch times. Read-only.
#
# Usage: sudo earnings-today [YYYY-MM-DD]
#   Defaults to today (UTC). Pass a date to inspect a past day.
#
# Note: rates shown are the LISTING price at detection. The exact locked rate for
# D-type background contracts isn't exposed to the host API — confirm precise
# numbers on the Vast console Earnings page.

set -uo pipefail

JSONL="${GPU_DATA:-/var/log/gpu_monitor_data.jsonl}"
KAALIA_GLOB="/var/lib/vastai_kaalia/kaalia.log"
DAY="${1:-$(date -u +%Y-%m-%d)}"

if [[ ! -f "$JSONL" ]]; then
    echo "[!] $JSONL not found" >&2
    exit 1
fi

python3 - "$JSONL" "$DAY" <<'PYEOF'
import sys, json, datetime

jsonl, day = sys.argv[1], sys.argv[2]

def loc(ts):
    try:
        u = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        return u.astimezone().strftime("%H:%M %Z")
    except Exception:
        return ts

starts, ends, changes, earn = [], [], [], None
for line in open(jsonl, errors="replace"):
    try:
        e = json.loads(line)
    except Exception:
        continue
    if not str(e.get("ts", "")).startswith(day):
        continue
    t = e.get("type")
    if t == "rental_start":        starts.append(e)
    elif t == "rental_end":        ends.append(e)
    elif t == "gpu_rental_change": changes.append(e)
    elif t == "daily_earnings":    earn = e

print("=" * 56)
print(f" Rental activity for {day}  (UTC day)")
print("=" * 56)

if changes:
    print("\nPer-GPU rental changes (catches incremental rentals):")
    for e in changes:
        d = e.get("delta", 0)
        what = "rented" if d > 0 else "freed"
        r = e.get("rate_estimate")
        rate = f"~${r:.3f}/hr" if isinstance(r, (int, float)) and r else ""
        print(f"  {loc(e.get('ts',''))}  {abs(d)} GPU {what:6s} -> {e.get('rented')}/{e.get('total')} rented  {rate}  (m{e.get('machine_id')})")

if starts:
    print("\nMachine rental_start events:")
    for e in starts:
        print(f"  {loc(e.get('ts',''))}  {e.get('gpus')} @ {e.get('rate')}  ({e.get('workload_type','?')})  m{e.get('machine_id')}")

if ends:
    print("\nMachine rental_end events:")
    for e in ends:
        print(f"  {loc(e.get('ts',''))}  m{e.get('machine_id')}")

if not (changes or starts or ends):
    print("\n(no rental start/change/end events today — the machine may have been")
    print(" continuously rented across the whole day)")

if earn:
    def money(k):
        try: return float(earn.get(k, 0) or 0)
        except Exception: return 0.0
    print(f"\nRevenue (monitor estimate): today ${money('today'):.2f}   |   30d ${money('total'):.2f}")

print("\nRates are the listing price at detection; D-type contract locked rates")
print("aren't host-visible. Confirm exact figures on the Vast Earnings page.")
PYEOF

echo ""
echo "=== Container launches today (kaalia.log, exact UTC times) ==="
found=0
while IFS= read -r ln; do
    found=1
    echo "  $ln"
done < <(grep -ahE 'cmd::Create' ${KAALIA_GLOB}* 2>/dev/null \
    | grep -a "$DAY" \
    | sed -E 's/.*\[([0-9-]+ [0-9:]+)\.[0-9]+\].*name: (C\.[0-9]+)[^A-Za-z]+base_image_: ([^ ]+).*/\1 UTC  \2  \3/' \
    | sort -u)
[[ "$found" == "0" ]] && echo "  (none found today — kaalia.log may have rotated)"
