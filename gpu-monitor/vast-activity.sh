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
