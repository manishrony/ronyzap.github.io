#!/usr/bin/env bash
# One-off, best-effort backfill: classify workload type for existing
# rental_start events that predate workload capture (see gpu_monitor.sh's
# classify_workload()/get_instance_image()). Matches instances from
# vastai_kaalia's own logs against rentals already in the JSONL history by
# machine_id + time proximity (kaalia.log rotates, so older rentals may not
# be found — this fills in what's still available, nothing more).
#
# Usage: sudo bash backfill-workloads.sh
# Safe to re-run — it appends new "workload_backfill" events, one per
# successfully classified rental_start event, and skips ones already done.

set -euo pipefail

JSONL_FILE="${GPU_DATA:-/var/log/gpu_monitor_data.jsonl}"
KAALIA_GLOB="/var/lib/vastai_kaalia/kaalia.log*"

if [[ ! -f "$JSONL_FILE" ]]; then
    echo "[!] $JSONL_FILE not found" >&2
    exit 1
fi

python3 - "$JSONL_FILE" "$KAALIA_GLOB" <<'PYEOF'
import sys, json, glob, re, datetime

jsonl_path, kaalia_glob = sys.argv[1], sys.argv[2]

def classify_workload(image):
    img = (image or '').lower()
    if not img:
        return 'unknown'
    if 'self-test' in img:
        return 'selftest'
    if any(k in img for k in ('srbminer', 'xmrig', 'nbminer', 't-rex', 'phoenixminer', 'lolminer', 'gminer', 'teamredminer')):
        return 'mining'
    if any(k in img for k in ('jupyter', 'linux-desktop', 'vscode', 'desktop', 'vnc')):
        return 'desktop'
    if any(k in img for k in ('llama', 'vllm', 'ollama', 'text-generation', 'tgi', 'triton', 'comfyui', 'stable-diffusion', 'automatic1111')):
        return 'inference'
    if any(k in img for k in ('pytorch', 'tensorflow', 'axolotl', 'unsloth', 'deepspeed', 'train')):
        return 'training'
    return 'unknown'

# Parse every "cmd::Create ... name: C.<id>  base_image_: <image>" line out of
# whatever kaalia.log* history is still on disk, keeping a timestamp if the
# log line has one (kaalia.log lines are prefixed "YYYY-MM-DD HH:MM:SS ...").
ts_pat = re.compile(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
create_pat = re.compile(r'name: C\.(\d+)\s+base_image_:\s*(\S+)')

instances = []  # list of (timestamp_or_None, instance_id, image)
for path in glob.glob(kaalia_glob):
    try:
        with open(path, errors='ignore') as f:
            for line in f:
                if 'cmd::Create' not in line:
                    continue
                m = create_pat.search(line)
                if not m:
                    continue
                iid, image = m.group(1), m.group(2)
                tm = ts_pat.match(line)
                ts = None
                if tm:
                    try:
                        ts = datetime.datetime.strptime(tm.group(1), '%Y-%m-%d %H:%M:%S')
                    except ValueError:
                        ts = None
                instances.append((ts, iid, image))
    except Exception:
        pass

if not instances:
    print("[BACKFILL] No instance-create records found in kaalia.log — nothing to backfill")
    sys.exit(0)

# Load existing rental_start events and figure out which already have a
# workload_backfill (or live-captured workload_type) so re-runs are cheap.
rental_starts = []
already_done = set()
with open(jsonl_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get('type') == 'rental_start':
            if ev.get('workload_type'):
                already_done.add((ev.get('ts'), str(ev.get('machine_id', ''))))
            else:
                rental_starts.append(ev)
        elif ev.get('type') == 'workload_backfill':
            already_done.add((ev.get('rental_ts'), str(ev.get('machine_id', ''))))

count = 0
skipped = 0
with open(jsonl_path, 'a') as out:
    for ev in rental_starts:
        key = (ev.get('ts'), str(ev.get('machine_id', '')))
        if key in already_done:
            continue
        try:
            rental_ts = datetime.datetime.strptime(ev['ts'], '%Y-%m-%dT%H:%M:%SZ')
        except Exception:
            skipped += 1
            continue

        # Best match: an instance-create record within +/- 30 min of rental_start,
        # preferring the closest one in time (kaalia logs the Create call right
        # as the rental begins).
        best = None
        best_delta = None
        for ts, iid, image in instances:
            if ts is None:
                continue
            delta = abs((ts - rental_ts).total_seconds())
            if delta <= 1800 and (best_delta is None or delta < best_delta):
                best, best_delta = (iid, image), delta

        if not best:
            skipped += 1
            continue

        iid, image = best
        workload_type = classify_workload(image)
        backfill_event = {
            'ts':            datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
            'type':          'workload_backfill',
            'machine_id':    ev.get('machine_id'),
            'rental_ts':     ev.get('ts'),
            'real_instance_id': iid,
            'image':         image,
            'workload_type': workload_type,
        }
        out.write(json.dumps(backfill_event) + '\n')
        count += 1

print(f"[BACKFILL] Classified {count} historical rental(s); {skipped} could not be matched (log rotated or no timestamp)")
PYEOF
