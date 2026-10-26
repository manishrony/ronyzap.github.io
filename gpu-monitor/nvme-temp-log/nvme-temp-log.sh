#!/bin/bash
# Log the OS NVMe's composite temperature and thermal-throttle counters every
# 30s, synced on each write, so the readings right before a hang survive it.
# Built for zappa2's Crucial T705 (2026-10-26): tells a heat-driven link drop
# (temp/T1/T2 climbing before the log stops) from a non-thermal one (flat).
DEV="${1:-/dev/nvme0}"
LOG=/var/log/nvme-temp.log
while true; do
    read -r temp t1 t2 < <(nvme smart-log "$DEV" 2>/dev/null | awk -F: '
        /^temperature/                      { split($2, a, " "); t = a[1] }
        /Thermal Management T1 Trans Count/ { gsub(/ /, "", $2); c1 = $2 }
        /Thermal Management T2 Trans Count/ { gsub(/ /, "", $2); c2 = $2 }
        END { print t, c1, c2 }')
    echo "$(date -u '+%F %T') ${temp:-?} T1=${t1:-?} T2=${t2:-?}" >> "$LOG"
    sync "$LOG"
    sleep 30
done
