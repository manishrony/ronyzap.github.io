#!/bin/bash
D1=$(date -u +%F); D2=$(date -u -d yesterday +%F)

echo "════ 1. Self-test verdicts (last 24h only) ════"
python3 - << 'PYEOF'
import re
from datetime import datetime, timedelta, timezone

path = "/var/lib/vastai_kaalia/self_test.log"
cutoff = datetime.now(timezone.utc) - timedelta(hours=24)

try:
    content = open(path, errors="ignore").read()
except FileNotFoundError:
    exit()

for block in content.split("=========================================\n"):
    m = re.search(r"Timestamp:\s*(.+)", block)
    if not m:
        continue
    ts = re.sub(r"\s+", " ", m.group(1).strip())
    try:
        dt = datetime.strptime(ts, "%a %b %d %I:%M:%S %p %Z %Y").replace(tzinfo=timezone.utc)
    except ValueError:
        continue
    if dt >= cutoff:
        for line in block.strip().splitlines():
            if re.search(r"Starting self-test|Self-test PASSED|Self-test FAILED|exit code|machine \d+ is|Timestamp:", line):
                print(line)
PYEOF

echo ""
echo "════ 2. Instances launched (last 24h) ════"
grep -ah "cmd::Create" /var/lib/vastai_kaalia/kaalia.log* 2>/dev/null | grep -E "$D1|$D2" | grep -oE "name: C\.[0-9]+  base_image_: [^ ]+" | sort -u

echo ""
echo "════ 3. Instance results (may be cleaned up by Vast already) ════"
find /var/lib/vastai_kaalia/data/instance_extra_logs -type f -mmin -1440 2>/dev/null | while read f; do echo "--- ${f##*/}"; grep -aE "TESTED|PASSED|FAILED|self-test|success|error" "$f" 2>/dev/null | tail -4; done

echo ""
echo "════ 4. Rental lifetimes (last 24h): how long each instance lived, on which GPU, how it ended ════"
# Short lifetimes that end in Destroy, after a 'success, running' in section 3, were ended by the
# renter (or Vast), not by a host fault. Compare the GPU column: if the short ones cluster on one
# card, renters are leaving that card.
GPU_MAP=$(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null | tr -d ' ')
RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null)
GPU_MAP="$GPU_MAP" RUNNING="$RUNNING" python3 - << 'PYEOF'
import glob, os, re
from datetime import datetime, timedelta, timezone

ts_re = re.compile(r'^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)')
now = datetime.now(timezone.utc).replace(tzinfo=None)
cutoff = now - timedelta(hours=24)
bus = {}
for row in os.environ.get("GPU_MAP", "").splitlines():
    if "," in row:
        i, b = row.split(",", 1)
        bus[i] = re.sub(r'^0+:', '', b.lower()).rsplit('.', 1)[0][-5:]
running = set(os.environ.get("RUNNING", "").split())

events = []
for f in glob.glob("/var/lib/vastai_kaalia/kaalia.log*"):
    if f.endswith(".gz"):
        continue
    with open(f, errors="ignore") as fh:
        for line in fh:
            if "C." not in line:
                continue
            m = ts_re.match(line)
            if not m:
                continue
            t = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
            if t >= cutoff - timedelta(hours=1):
                events.append((t, line))
events.sort(key=lambda e: e[0])

inst = {}
for t, line in events:
    if "cmd::Create" in line:
        n = re.search(r'name: C\.(\d+)', line)
        if n and t >= cutoff and n.group(1) not in inst:
            img = re.search(r'base_image_: (\S+)', line)
            inst[n.group(1)] = {"start": t, "img": img.group(1) if img else "?",
                                "gpus": "", "end": None, "how": ""}
        continue
    if "assign_and_update_used_gpus" in line and "gpus:" in line:
        for cid, g in re.findall(r'C\.(\d+) ([\d,]+)', line.split("gpus:", 1)[1]):
            if cid in inst:
                inst[cid]["gpus"] = g
        continue
    m = re.search(r'Task\((Destroy|Stop) C\.(\d+)\)', line)
    if m and m.group(2) in inst and inst[m.group(2)]["how"] != "Destroy":
        inst[m.group(2)].update(end=t, how=m.group(1))
        continue
    m = re.search(r'docker stop C\.(\d+)', line)
    if m and m.group(1) in inst and not inst[m.group(1)]["how"]:
        inst[m.group(1)].update(end=t, how="stopped")

def fmt(d):
    s = int(d.total_seconds())
    return f"{s // 3600}h{(s % 3600) // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"

if not inst:
    print("  no instances created in the last 24h")
for cid, i in sorted(inst.items(), key=lambda kv: kv[1]["start"]):
    gpus = ",".join(f"{g}({bus.get(g, '?')})" for g in i["gpus"].split(",") if g) or "?"
    name = f"C.{cid}"
    if name in running:
        state, life = "still running", fmt(now - i["start"])
    elif i["end"]:
        state, life = {"Destroy": "destroyed", "Stop": "stopped by renter", "stopped": "stopped"}[i["how"]], fmt(i["end"] - i["start"])
    else:
        state, life = "gone (end not in log)", "?"
    img = i["img"].split("/")[-1][:40]
    print(f"  {i['start']:%m-%d %H:%M}  {name:<12} gpu {gpus:<16} lived {life:>7}  {state:<20} {img}")
PYEOF
