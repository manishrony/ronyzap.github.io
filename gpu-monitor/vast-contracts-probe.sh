#!/usr/bin/env bash
# One-off diagnostic: find which Vast.ai API endpoint returns the per-contract
# data the console now shows under "Active Contracts" (contract id, rent type,
# GPU price, disk size/price, start/end). gpu_monitor.sh currently only gets
# machine-level totals (/machines/) and the renter-side /instances/, which is
# empty for a host, so per-slot rate and instance_id are logged as 0/null.
#
# Tries a list of candidate endpoints for each of this host's machines, plus
# POST /contracts/fetch/ (used by the CLI's `show invoices --instance_label`)
# with the contract ids of the C.<id> containers running right now.
#
# Read-only: GET requests and one "fetch" POST that changes nothing. Values
# under keys that could identify a renter or hold secrets (ssh, keys, env,
# email, ip, image, label...) are replaced with "<redacted>".
#
# Usage: sudo bash vast-contracts-probe.sh [output-file]
#   Defaults to /tmp/vast_contracts_probe_<hostname>.json
#   Reads VASTAI_API_KEY from /etc/gpu_monitor.conf.

set -euo pipefail

CONF="/etc/gpu_monitor.conf"
OUT="${1:-/tmp/vast_contracts_probe_$(hostname).json}"

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && source "$CONF"
: "${VASTAI_API_KEY:?VASTAI_API_KEY not set (check $CONF — run as root)}"

running_ids=$(docker ps --format '{{.Names}}' 2>/dev/null \
    | sed -nE 's/^C\.([0-9]+)$/\1/p' | paste -sd, || true)
echo "[*] Running contract containers: ${running_ids:-none}"

VASTAI_API_KEY="$VASTAI_API_KEY" python3 - "$OUT" "$running_ids" <<'PYEOF'
import json, os, re, socket, subprocess, sys

out_path, running = sys.argv[1], sys.argv[2]
key = os.environ["VASTAI_API_KEY"]
hn = socket.gethostname()
ids = [int(x) for x in running.split(",") if x]

SECRET = re.compile(r"ssh|key|token|secret|pass|email|user|env|onstart|"
                    r"jupyter|ip_|_ip|^ip|addr|port|label|image|template|"
                    r"args|cmd|url|login|direct", re.I)
INTEREST = re.compile(r"price|cost|dph|rate|disk|storage|start|end|"
                      r"rent|type|bid|ondemand|interruptible|reserved|"
                      r"num_gpus|gpu_ids|gpu_frac|^id$|machine|status|"
                      r"inet|bandwidth|earn|contract|duration", re.I)

def redact(v, k=""):
    if k and SECRET.search(k):
        return "<redacted>"
    if isinstance(v, dict):
        return {kk: redact(vv, kk) for kk, vv in v.items()}
    if isinstance(v, list):
        return [redact(x) for x in v[:20]]
    return v

def call(method, url, body=None):
    sep = "&" if "?" in url else "?"
    cmd = ["curl", "-s", "-m", "20", "-o", "-", "-w", "\n%{http_code}",
           "-H", f"Authorization: Bearer {key}", "-X", method]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(body)]
    cmd.append(f"{url}{sep}api_key={key}")
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout
    text, _, code = r.rpartition("\n")
    try:
        return code, json.loads(text)
    except Exception:
        return code, text[:200]

def first_records(d, path="$"):
    """Yield (path, list) for every list of dicts inside the response."""
    if isinstance(d, list) and d and isinstance(d[0], dict):
        yield path, d
    if isinstance(d, dict):
        for k, v in d.items():
            yield from first_records(v, f"{path}.{k}")
    elif isinstance(d, list):
        for i, v in enumerate(d[:3]):
            if isinstance(v, (dict, list)):
                yield from first_records(v, f"{path}[{i}]")

code, ms = call("GET", "https://console.vast.ai/api/v0/machines/")
mids = [m["id"] for m in (ms.get("machines", []) if isinstance(ms, dict) else [])
        if m.get("hostname") == hn]
print(f"[*] Machines for {hn}: {mids or 'none found (HTTP ' + code + ')'}")

cands = []
for base in ("https://console.vast.ai/api/v0", "https://console.vast.ai/api/v1"):
    for mid in mids:
        cands += [("GET", f"{base}/machines/{mid}/contracts/", None),
                  ("GET", f"{base}/machines/{mid}/instances/", None),
                  ("GET", f"{base}/machines/{mid}/rentals/", None),
                  ("GET", f"{base}/contracts/?machine_id={mid}", None)]
    cands += [("GET", f"{base}/contracts/", None),
              ("GET", f"{base}/contracts/?owner=me", None),
              ("GET", f"{base}/host/contracts/", None),
              ("GET", f"{base}/machines/contracts/", None),
              ("GET", f"{base}/instances/?owner=host", None)]
for mid in mids:
    cands.append(("GET", f"https://console.vast.ai/api/v0/machines/{mid}/?owner=me", None))
if ids:
    cands.append(("POST", "https://console.vast.ai/api/v0/contracts/fetch/",
                  {"contract_ids": ids}))

dump, hits = {}, []
for method, url, body in cands:
    code, d = call(method, url, body)
    label = f"{method} {url.replace('https://console.vast.ai', '')}"
    recs = list(first_records(d)) if isinstance(d, (dict, list)) else []
    useful = [(p, l) for p, l in recs
              if any(re.search(r"price|dph|cost", k, re.I) for k in l[0])]
    mark = "HIT " if code == "200" and useful else "    "
    top = list(d.keys())[:8] if isinstance(d, dict) else type(d).__name__
    print(f"{mark}{code}  {label}  top={top}")
    dump[label] = {"http": code, "body": redact(d)}
    if mark == "HIT ":
        hits.append((label, useful))

print()
for label, useful in hits:
    for path, lst in useful:
        print(f"=== {label}  {path}  ({len(lst)} record(s))")
        for k, v in sorted(redact(lst[0]).items()):
            if INTEREST.search(k) and v != "<redacted>":
                print(f"  {k:30s} = {json.dumps(v)[:90]}")
        print()
if not hits:
    print("[!] No candidate returned records with price fields.")

with open(out_path, "w") as f:
    json.dump(dump, f, indent=2, sort_keys=True)
print(f"[*] Full redacted responses: {out_path}")
PYEOF
