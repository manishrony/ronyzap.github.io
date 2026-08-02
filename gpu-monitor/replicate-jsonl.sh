#!/usr/bin/env bash
# Daily cross-rig replication of this rig's gpu_monitor_data.jsonl (the
# event-log "database" -- rentals, pricing, gpu_status, earnings) to a peer
# rig, via rsync over SSH. This is separate from backup-jsonl.sh's local
# gzip snapshots: that protects against accidental deletion/corruption on
# THIS disk, this protects against losing the whole rig (disk failure,
# theft, seizure) by keeping a live copy of the record on a second physical
# machine. rental_start/rental_end/price_change events are the primary
# attribution evidence tying a rental window to Vast's own instance id, so
# a single-host copy isn't durable enough on its own.
#
# Opt-in: does nothing unless REPLICATE_TARGET_HOST is set in
# /etc/gpu_monitor.conf, same pattern as this codebase's other optional
# integrations (CLOUDLINE_TAPO_HOST, etc.) -- silently skipping when
# unconfigured means this script is safe to enable/schedule everywhere
# without breaking rigs that haven't set up SSH access to a peer yet.
#
# Runs via the gpu-replicate.timer systemd unit (daily, end of day UTC);
# safe to also run manually -- sudo replicate-jsonl.
#
# Requires: passwordless SSH (key-based) from this rig's REPLICATE_SSH_USER
# to REPLICATE_TARGET_HOST -- set that up once with ssh-copy-id before
# enabling the timer. rsync must be installed on both ends (already present
# on stock Ubuntu).

set -euo pipefail

CONF_FILE="${GPU_MONITOR_CONF:-/etc/gpu_monitor.conf}"
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

JSONL_FILE="${GPU_DATA:-/var/log/gpu_monitor_data.jsonl}"
LOCAL_BACKUP_DIR="${GPU_BACKUP_DIR:-/var/backups/gpu-monitor}"

REPLICATE_TARGET_HOST="${REPLICATE_TARGET_HOST:-}"
REPLICATE_TARGET_USER="${REPLICATE_TARGET_USER:-$(whoami)}"
REPLICATE_TARGET_PATH="${REPLICATE_TARGET_PATH:-/var/backups/gpu-monitor-replica/$(hostname)}"
REPLICATE_SSH_KEY="${REPLICATE_SSH_KEY:-}"

if [[ -z "$REPLICATE_TARGET_HOST" ]]; then
    echo "[!] REPLICATE_TARGET_HOST not set in $CONF_FILE -- replication disabled, nothing to do" >&2
    exit 0
fi

if [[ ! -f "$JSONL_FILE" ]]; then
    echo "[!] $JSONL_FILE not found -- nothing to replicate" >&2
    exit 0
fi

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
[[ -n "$REPLICATE_SSH_KEY" ]] && ssh_opts+=(-i "$REPLICATE_SSH_KEY")

rsync_ssh="ssh ${ssh_opts[*]}"
dest="${REPLICATE_TARGET_USER}@${REPLICATE_TARGET_HOST}:${REPLICATE_TARGET_PATH}/"

# Ensure the destination directory exists before rsync writes into it.
ssh "${ssh_opts[@]}" "${REPLICATE_TARGET_USER}@${REPLICATE_TARGET_HOST}" \
    "mkdir -p '${REPLICATE_TARGET_PATH}'"

# Live JSONL, timestamped so today's replica doesn't overwrite yesterday's
# (the source file itself is append-only and grows forever, so a straight
# mirror would still capture full history -- the timestamp is extra safety
# against a partial/corrupted transfer clobbering the only remote copy).
stamp=$(date -u +%Y-%m-%d)
rsync -az --partial -e "$rsync_ssh" \
    "$JSONL_FILE" \
    "${REPLICATE_TARGET_USER}@${REPLICATE_TARGET_HOST}:${REPLICATE_TARGET_PATH}/gpu_monitor_data_${stamp}.jsonl"
echo "[OK] Replicated $JSONL_FILE -> $dest gpu_monitor_data_${stamp}.jsonl"

# Also mirror this rig's local gzip backup directory, if any exist, so the
# peer has the point-in-time snapshots too, not just today's live copy.
if [[ -d "$LOCAL_BACKUP_DIR" ]] && compgen -G "$LOCAL_BACKUP_DIR/*.jsonl.gz" > /dev/null; then
    rsync -az --partial -e "$rsync_ssh" \
        "$LOCAL_BACKUP_DIR/" \
        "${REPLICATE_TARGET_USER}@${REPLICATE_TARGET_HOST}:${REPLICATE_TARGET_PATH}/backups/"
    echo "[OK] Replicated local backup snapshots -> $dest backups/"
fi

exit 0
