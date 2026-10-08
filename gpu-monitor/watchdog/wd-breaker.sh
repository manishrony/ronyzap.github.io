#!/bin/bash
# Runs once per boot before watchdog.service. Too many boots in a short
# window means the auto-reset isn't helping, so stop arming the watchdog
# instead of reset-looping. Clear with: rm /var/lib/wd-breaker/tripped
STATE=${WD_BREAKER_STATE:-/var/lib/wd-breaker}
WINDOW=1800
MAX_BOOTS=3

mkdir -p "$STATE"
now=$(date +%s)
echo "$now" >> "$STATE/boots"
tail -n 20 "$STATE/boots" > "$STATE/boots.tmp" && mv "$STATE/boots.tmp" "$STATE/boots"
recent=$(awk -v cutoff=$((now - WINDOW)) '$1 >= cutoff' "$STATE/boots" | wc -l)

if [ "$recent" -ge "$MAX_BOOTS" ]; then
    echo "$(date -u '+%F %T UTC') $recent boots in ${WINDOW}s" > "$STATE/tripped"
    logger -t wd-breaker "TRIPPED: $recent boots in ${WINDOW}s; watchdog will not be armed until $STATE/tripped is removed"
fi
exit 0
