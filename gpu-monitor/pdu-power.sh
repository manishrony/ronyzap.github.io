#!/usr/bin/env bash
# Show rack power + energy + electricity cost for THIS operation, from the
# monitor's pdu_power events (gpu_monitor_data.jsonl). Read-only.
#
# Usage: sudo pdu-power [YYYY-MM-DD]
#   No arg  -> live power + today + lifetime totals.
#   A date  -> energy/cost for that UTC day.
#
# Power is DERIVED: the APC metered PDU (AP7811B) exposes only load current over
# SNMP, so the monitor computes watts = amps × voltage and integrates energy.
# Only the hub rig (the one with PDU_HOSTS set) logs these events.

set -uo pipefail

JSONL="${GPU_DATA:-/var/log/gpu_monitor_data.jsonl}"
DAY="${1:-}"

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
        return u.astimezone().strftime("%Y-%m-%d %H:%M %Z")
    except Exception:
        return ts

evs = []
for line in open(jsonl, errors="replace"):
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("type") == "pdu_power":
        evs.append(e)

if not evs:
    print("No pdu_power events yet. Is PDU_HOSTS set in /etc/gpu_monitor.conf on")
    print("this (hub) rig, and is snmpwalk installed (apt install snmp)?")
    sys.exit(0)

latest = evs[-1]
rate = float(latest.get("rate", 0) or 0)

def kwh_in_day(d):
    return sum(float(e.get("kwh_interval", 0) or 0) for e in evs if str(e.get("ts","")).startswith(d))

life = float(latest.get("cumulative_kwh_total", latest.get("cumulative_kwh", 0)) or 0)

print("=" * 60)
print(" Rack power / energy  (APC PDU, derived from load current)")
print("=" * 60)

if day:
    k = kwh_in_day(day)
    print(f"\n{day} (UTC):  {k:.2f} kWh   ≈ ${k*rate:.2f}  at ${rate:.2f}/kWh")
else:
    today = datetime.datetime.utcnow().strftime("%Y-%m-%d")
    kt = kwh_in_day(today)
    pdus = latest.get("pdus", [])
    print(f"\nLive ({loc(latest.get('ts',''))}):")
    print(f"  {latest.get('watts',0):,} W   {latest.get('amps',0)} A   @ ${rate:.2f}/kWh")
    for p in pdus:
        print(f"    - {p.get('host')}: {p.get('amps')} A  ({p.get('watts')} W)")
    print(f"\nToday   : {kt:.2f} kWh   ≈ ${kt*rate:.2f}")
    print(f"Lifetime: {life:,.1f} kWh  ≈ ${life*rate:,.2f}  (since metering began")
    print( "          + any PDU_KWH_BASELINE seed)")

print("\nNote: metered PDUs expose current only — no kWh register — so these are")
print("integrated estimates. Cross-check against your utility bill for exactness.")
PYEOF
