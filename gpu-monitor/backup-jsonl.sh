#!/usr/bin/env bash
# Daily backup of this rig's gpu_monitor_data.jsonl (the event-log "database"
# — rentals, pricing, gpu_status, earnings) into BACKUP_DIR, gzipped and
# timestamped. Anything older than BACKUP_RETENTION_DAYS gets deleted
# automatically on each run. Runs via the gpu-backup.timer systemd unit
# (daily); safe to also run manually — sudo backup-jsonl.
#
# Note: this backs up the JSONL, not the Prometheus TSDB (which only runs on
# the hub) — Prometheus's own 10y retention + its block-storage format is
# already durable; this covers the raw event log everything else (including
# the historical backfill) is reconstructed from.

set -euo pipefail

JSONL_FILE="${GPU_DATA:-/var/log/gpu_monitor_data.jsonl}"
BACKUP_DIR="${GPU_BACKUP_DIR:-/var/backups/gpu-monitor}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

if [[ ! -f "$JSONL_FILE" ]]; then
    echo "[!] $JSONL_FILE not found — nothing to back up" >&2
    exit 0
fi

mkdir -p "$BACKUP_DIR"
stamp=$(date -u +%Y-%m-%d_%H%M%S)
dest="$BACKUP_DIR/gpu_monitor_data_${stamp}.jsonl.gz"
gzip -c "$JSONL_FILE" > "$dest"
echo "[OK] Backed up $JSONL_FILE -> $dest ($(du -h "$dest" | cut -f1))"

deleted=0
while IFS= read -r -d '' old; do
    rm -f "$old"
    deleted=$((deleted + 1))
done < <(find "$BACKUP_DIR" -maxdepth 1 -name 'gpu_monitor_data_*.jsonl.gz' -mtime "+${BACKUP_RETENTION_DAYS}" -print0)
(( deleted > 0 )) && echo "[OK] Pruned $deleted backup(s) older than ${BACKUP_RETENTION_DAYS} days"

exit 0
