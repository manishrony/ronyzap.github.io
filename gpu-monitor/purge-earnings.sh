#!/usr/bin/env bash
# One-off: strip ALL daily_earnings entries for THIS host out of the JSONL log,
# then restart gpu-monitor so vastai_sync_earnings does a clean full re-backfill
# (EARNINGS_SYNC_DAYS days, src_ver 3) with no doubled/tripled leftovers from
# earlier buggy sync versions to worry about.
#
# The dashboard already picks the newest entry per (date, machine) so old bad
# entries are normally harmless once a corrected one lands — this is for a full
# reset when you want the log itself clean (e.g. after chasing a sync bug) or
# don't want to wait/trust the newest-wins dedup while debugging.
#
# Only removes daily_earnings; every other event type (rental_start/end,
# gpu_status, pdu_power, etc.) is left untouched. The JSONL is backed up first.
#
# Usage: sudo bash purge-earnings.sh

set -euo pipefail

JSONL_FILE="${GPU_DATA:-/var/log/gpu_monitor_data.jsonl}"

if [[ ! -f "$JSONL_FILE" ]]; then
    echo "[!] $JSONL_FILE not found" >&2
    exit 1
fi

backup="${JSONL_FILE}.bak.$(date +%s)"
cp "$JSONL_FILE" "$backup"
echo "[*] Backed up JSONL to $backup"

python3 - "$JSONL_FILE" <<'PYEOF'
import sys, json, socket

jsonl = sys.argv[1]
host = socket.gethostname()

kept, removed = [], 0
for line in open(jsonl, errors='replace'):
    stripped = line.strip()
    if not stripped:
        continue
    try:
        ev = json.loads(stripped)
    except Exception:
        kept.append(line.rstrip('\n'))
        continue
    if ev.get('type') == 'daily_earnings' and ev.get('host', host) == host:
        removed += 1
        continue
    kept.append(line.rstrip('\n'))

with open(jsonl, 'w') as f:
    f.write('\n'.join(kept) + ('\n' if kept else ''))

print(f"[PURGE] Removed {removed} daily_earnings entry(ies) for host {host}. {len(kept)} other event(s) kept.")
PYEOF

echo "[*] Restarting gpu-monitor to trigger a clean full re-backfill..."
systemctl restart gpu-monitor

echo "[OK] Done. Watch the resync with:"
echo "     grep EARNINGS /var/log/gpu_monitor.log | tail -20"
echo "     (full backfill takes ~3s per day per machine on this host)"
