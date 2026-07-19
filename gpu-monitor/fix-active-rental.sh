#!/usr/bin/env bash
# One-off: correct the CURRENTLY-OPEN rental_start entry(ies) in the JSONL for
# machines on this host, using live Vast.ai API data. Fixes entries written
# before the rented-count / actual-rate fixes — i.e. entries that show the whole
# machine ("8x RTX 5090") instead of the rented count ("4x"), a zero/stale
# rate that makes the dashboard show $0 revenue for an active rental, or a
# missing expire_date (added later — vastai_init_state() only backfills
# expire_date onto NEW rental_start events, so a rental that was already open
# before that fix shipped needs this to pick it up).
#
# It only touches the single open rental_start per machine (the current session);
# closed/historical sessions are left as-is. The JSONL is backed up first.
#
# Usage: sudo bash fix-active-rental.sh
#   Reads VASTAI_API_KEY from /etc/gpu_monitor.conf.
#
# Safe to re-run. Also serves as a diagnostic: it prints each machine's live
# rented state so you can see why revenue was off.

set -euo pipefail

JSONL_FILE="${GPU_DATA:-/var/log/gpu_monitor_data.jsonl}"
CONF="/etc/gpu_monitor.conf"
VASTAI_API="https://console.vast.ai/api/v1"
MAX_RENTAL_DAYS="${MAX_RENTAL_DAYS:-14}"  # matches gpu_monitor.sh's default; overridden if the conf sets it

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && source "$CONF"
: "${VASTAI_API_KEY:?VASTAI_API_KEY not set (check $CONF — run as root)}"

if [[ ! -f "$JSONL_FILE" ]]; then
    echo "[!] $JSONL_FILE not found" >&2
    exit 1
fi

echo "[*] Fetching live machine + instance data from Vast.ai..."
machines_json=$(curl -sf "${VASTAI_API}/machines/?api_key=${VASTAI_API_KEY}" 2>/dev/null \
    || curl -sf -H "Authorization: Bearer $VASTAI_API_KEY" "${VASTAI_API}/machines/" 2>/dev/null \
    || echo '{"machines":[]}')

instances_json=""
for base in "https://console.vast.ai" "https://cloud.vast.ai"; do
    instances_json=$(curl -sf -H "Authorization: Bearer ${VASTAI_API_KEY}" \
        "${base}/api/v0/instances/?api_key=${VASTAI_API_KEY}" 2>/dev/null || true)
    [[ -n "$instances_json" ]] && break
done
[[ -z "$instances_json" ]] && instances_json='{"instances":[]}'

# Live GPU compute process names (this script runs ON the host, so it can see
# exactly what nvidia-smi sees) — used as a classification fallback below for
# D-type rentals where get_image() has nothing to go on (no /instances/ match
# means no container ID to look up in kaalia.log at all, not just a missing
# entry) — e.g. a "hashcat.bin"/"*miner*" process is still identifiable even
# though the image name is unavailable.
proc_names=$(nvidia-smi --query-compute-apps=process_name --format=csv,noheader 2>/dev/null || true)

backup="${JSONL_FILE}.bak.$(date +%s)"
cp "$JSONL_FILE" "$backup"
echo "[*] Backed up JSONL to $backup"

python3 - "$JSONL_FILE" "$machines_json" "$instances_json" "$MAX_RENTAL_DAYS" "$proc_names" <<'PYEOF'
import sys, json, socket, glob, re, datetime

jsonl, machines_raw, instances_raw = sys.argv[1], sys.argv[2], sys.argv[3]
proc_names = [p for p in sys.argv[5].splitlines() if p.strip()] if len(sys.argv) > 5 else []
try:
    max_rental_days = int(sys.argv[4])
except Exception:
    max_rental_days = 5
hn = socket.gethostname()

machines = json.loads(machines_raw).get('machines', [])
idata = json.loads(instances_raw)
instances = idata.get('instances', idata if isinstance(idata, list) else [])

def classify_workload(image):
    img = (image or '').lower()
    if not img: return 'unknown'
    if 'self-test' in img: return 'selftest'
    if any(k in img for k in ('miner','srbminer','xmrig','nbminer','t-rex','phoenixminer','lolminer','gminer','teamredminer','matador')): return 'mining'
    if any(k in img for k in ('hashcat','hcxdump','hcxtools','johntheripper','john-the-ripper')): return 'cracking'
    if any(k in img for k in ('jupyter','linux-desktop','vscode','desktop','vnc')): return 'desktop'
    if any(k in img for k in ('llama','vllm','ollama','text-generation','tgi','triton','comfyui','stable-diffusion','automatic1111')): return 'inference'
    if any(k in img for k in ('pytorch','tensorflow','axolotl','unsloth','deepspeed','train')): return 'training'
    return 'unknown'

def get_image(iid):
    if not iid: return ''
    pat = re.compile(r'name: C\.' + re.escape(str(iid)) + r'  base_image_: (\S+)')
    last = ''
    for p in glob.glob('/var/lib/vastai_kaalia/kaalia.log*'):
        try:
            for line in open(p, errors='ignore'):
                m = pat.search(line)
                if m: last = m.group(1)
        except Exception:
            pass
    return last

# Correct rented count + total $/hr per machine, from live instance data.
correct = {}
for m in machines:
    if m.get('hostname', '') != hn:
        continue
    mid = str(m.get('id', ''))
    gpu_name = m.get('gpu_name', '?')
    minst = [i for i in instances if str(i.get('machine_id', i.get('machine', ''))) == mid]
    count, total, iid = 0, 0.0, ''
    for i in minst:
        gpu_ids = i.get('gpu_ids', i.get('gpus', []))
        n = len(gpu_ids) if gpu_ids else int(i.get('num_gpus', 1) or 1)
        count += n
        total += float(i.get('dph_total', i.get('dph_base', 0)) or 0)
        if not iid:
            iid = str(i.get('id', ''))

    fallback_note = ""
    if (count <= 0 or total <= 0):
        # No /instances/ match at all — typical for a Dedicated (D-type)
        # background contract, invisible to that endpoint entirely.
        # /machines/'s own earn_hour is a real, live, per-machine rate;
        # confirmed 2026-07-18 (machine 143953) to match the account
        # console's actual "Avg earnings" almost exactly — use it, and
        # count rented GPUs from gpu_occupancy ('D'/'R' = rented) instead
        # of the (empty, for this case) instance list.
        earn_hour = float(m.get('earn_hour') or 0)
        occ_chars = (m.get('gpu_occupancy', '') or '').split()
        occ_count = sum(1 for c in occ_chars if c in ('D', 'R'))
        if earn_hour > 0 and occ_count > 0:
            count, total = occ_count, earn_hour
            fallback_note = "  [from /machines/ earn_hour + gpu_occupancy — no /instances/ match]"

    print(f"[LIVE] Machine {mid} ({gpu_name}): {count} GPU(s) rented, ${total:.3f}/hr total{fallback_note}")
    if count > 0 and total > 0:
        img = get_image(iid)
        workload = classify_workload(img)
        # D-type rentals have no iid at all, so get_image() has nothing to look
        # up (not just a missing kaalia.log entry) — fall back to classifying
        # whatever's actually running on the GPUs right now (this script runs
        # on the host, so it sees the same processes gpu_monitor.sh's live
        # throttle does).
        if workload == 'unknown' and proc_names:
            for p in proc_names:
                pw = classify_workload(p)
                if pw != 'unknown':
                    workload = pw
                    img = img or p
                    break
        correct[mid] = {'count': count, 'rate': total, 'gpu_name': gpu_name,
                        'iid': iid, 'image': img, 'workload': workload,
                        'end_date': m.get('end_date')}

if not correct:
    print("[FIX] No active rentals with a live rate on this host — nothing to patch.")
    sys.exit(0)

# Locate the OPEN rental_start per machine (last one not closed by a rental_end).
lines = open(jsonl).read().splitlines()
open_idx = {}
for idx, line in enumerate(lines):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    mid = str(ev.get('machine_id', ev.get('instance_id', '')))
    if ev.get('type') == 'rental_start':
        open_idx[mid] = idx
    elif ev.get('type') == 'rental_end':
        open_idx.pop(mid, None)

patched = 0
for mid, info in correct.items():
    if mid not in open_idx:
        print(f"[FIX] Machine {mid}: rented live but no open rental_start in log — "
              f"the monitor will capture it correctly on its next hourly cycle.")
        continue
    li = open_idx[mid]
    ev = json.loads(lines[li])
    new_gpus = f"{info['count']}x {info['gpu_name']}"
    new_rate = f"${info['rate']:.3f}/hr"
    old_gpus, old_rate = ev.get('gpus'), ev.get('rate')
    ev['gpus'] = new_gpus
    ev['rate'] = new_rate
    ev['real_instance_id'] = info['iid']
    if not ev.get('workload_type') or ev.get('workload_type') == 'unknown':
        ev['workload_type'] = info['workload']
        ev['image'] = info['image']
    expire_note = ""
    # Prefer /machines/'s own real end_date (confirmed 2026-07-18, machine
    # 143953, to match the account console's "Contract end" exactly) over
    # both the existing estimated value and the max_rental_days guess.
    real_end = info.get('end_date')
    if real_end and ev.get('expire_date_source') != 'vast_api':
        try:
            new_expire = datetime.datetime.fromtimestamp(float(real_end), tz=datetime.timezone.utc).strftime('%Y-%m-%d')
            old_expire = ev.get('expire_date')
            ev['expire_date'] = new_expire
            ev['expire_date_source'] = 'vast_api'
            if old_expire != new_expire:
                expire_note = f"  [expire_date {old_expire or '(none)'} -> {new_expire}, from Vast's real end_date]"
        except Exception:
            pass
    if not ev.get('expire_date'):
        ev['expire_date'] = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=max_rental_days)).strftime('%Y-%m-%d')
        ev['expire_date_source'] = 'estimated'
        expire_note = f"  [added expire_date {ev['expire_date']}]"
    ev['patched'] = True
    lines[li] = json.dumps(ev)
    print(f"[FIX] Machine {mid}: {old_gpus} @ {old_rate}  ->  {new_gpus} @ {new_rate}  ({ev.get('workload_type')}){expire_note}")
    patched += 1

if patched:
    with open(jsonl, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f"[FIX] Patched {patched} active rental entry(ies). Refresh the dashboard to see it.")
else:
    print("[FIX] Nothing patched.")
PYEOF

echo "[OK] Done. If a value was patched, the dashboard reflects it on the next refresh (no restart needed)."
