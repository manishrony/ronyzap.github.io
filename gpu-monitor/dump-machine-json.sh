#!/usr/bin/env bash
# One-off diagnostic: dump the FULL raw Vast.ai API JSON for this host's
# machine(s) — both the bulk /machines/ list entry and (if reachable) the
# single-machine /machines/{id} response — so we can check for any field not
# currently parsed by gpu_monitor.sh that might carry a Dedicated (D-type)
# contract's actual locked rate. See RIGS.md's "Rate source" section: no
# endpoint in the public API/CLI is documented to expose this, but the CLI's
# displayed columns are a curated subset — the raw response may carry more.
#
# Read-only: only ever makes GET requests, writes only to the output file.
#
# Usage: sudo bash dump-machine-json.sh [output-file]
#   Defaults to /tmp/vast_machine_dump_<hostname>.json
#   Reads VASTAI_API_KEY from /etc/gpu_monitor.conf.

set -euo pipefail

CONF="/etc/gpu_monitor.conf"
VASTAI_API="https://console.vast.ai/api/v1"
OUT="${1:-/tmp/vast_machine_dump_$(hostname).json}"

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && source "$CONF"
: "${VASTAI_API_KEY:?VASTAI_API_KEY not set (check $CONF — run as root)}"

echo "[*] Fetching /machines/ (bulk list)..."
machines_json=$(curl -sf "${VASTAI_API}/machines/?api_key=${VASTAI_API_KEY}" 2>/dev/null \
    || curl -sf -H "Authorization: Bearer $VASTAI_API_KEY" "${VASTAI_API}/machines/" 2>/dev/null \
    || echo '{"machines":[]}')

python3 - "$machines_json" "$OUT" "$VASTAI_API_KEY" "$VASTAI_API" <<'PYEOF'
import sys, json, socket, subprocess

machines_raw, out_path, apikey, api_base = sys.argv[1:5]
hn = socket.gethostname()

try:
    data = json.loads(machines_raw)
except Exception as e:
    print(f"[!] Could not parse /machines/ response: {e}")
    sys.exit(1)

mine = [m for m in data.get('machines', []) if m.get('hostname', '') == hn]
if not mine:
    print(f"[!] No machine in the response matches hostname '{hn}' — nothing to dump.")
    sys.exit(1)

result = {"bulk_list_entries": mine, "single_machine_detail": {}}

for m in mine:
    mid = m.get('id')
    if mid is None:
        continue
    print(f"[*] Fetching /machines/{mid} (single-machine detail)...")
    url = f"{api_base}/machines/{mid}/?owner=me&api_key={apikey}"
    try:
        out = subprocess.run(["curl", "-sf", url], capture_output=True, text=True, timeout=15).stdout
        result["single_machine_detail"][str(mid)] = json.loads(out) if out else {"note": "empty/non-200 response"}
    except Exception as e:
        result["single_machine_detail"][str(mid)] = {"error": str(e)}

with open(out_path, 'w') as f:
    json.dump(result, f, indent=2, sort_keys=True)

print(f"\n[OK] Wrote {len(mine)} machine(s) to {out_path}\n")
for m in mine:
    print(f"Machine {m.get('id')} — bulk list entry has {len(m.keys())} fields:")
    for k in sorted(m.keys()):
        v = m[k]
        vs = json.dumps(v) if not isinstance(v, (int, float, str, bool, type(None))) else str(v)
        print(f"  {k:28s} = {vs[:80]}")
    print()
PYEOF

echo "[*] Full dump (including single-machine detail, if fetched OK) is at: $OUT"
echo "    Paste back the field list above, plus $OUT's contents if anything"
echo "    looks promising (especially fields mentioning rate/price/earn/"
echo "    contract/dedicated/locked that we aren't already using)."
