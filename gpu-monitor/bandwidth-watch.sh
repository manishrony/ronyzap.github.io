#!/usr/bin/env bash
#
# bandwidth-watch.sh — periodically runs Vast's own bandwidthTest against
# every idle GPU and logs pass/fail with a timestamp. Exists to catch an
# intermittent PCIe fault (PCI SERR) *live* — this rig has had recurring
# SERR events in its BMC SEL and a matching Vast delisting
# ("bad bandwidthtest2: ERROR_CONDITION") that could not be reproduced
# on demand. If this test ever fails, dmesg/SEL/nvidia-smi state is
# snapshotted immediately, before the evidence ages out.
#
# Skips any GPU with an active process (rental in progress) so this never
# competes with a paying renter's workload for PCIe bandwidth.
#
# Deploy: see bandwidth-watch.service / bandwidth-watch.timer in this
# directory. Runs via systemd timer, not directly.

set -uo pipefail

LOG_FILE="/var/log/gpu_bandwidth_test.log"
FAIL_DIR="/var/tmp/gpu_bandwidth_failures"
CONF="/etc/gpu_monitor.conf"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

[[ -f "$CONF" ]] && source "$CONF"

tg_send() {
    [[ -z "${TELEGRAM_CHAT_ID:-}" || -z "${TELEGRAM_TOKEN:-}" ]] && return
    curl -sf -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d parse_mode="HTML" \
        --data-urlencode text="$1" >/dev/null 2>&1 || true
}

# Vast bundles its own copy of the CUDA bandwidthTest sample under its
# kaalia install dir, versioned. Find the newest non-backup version's copy
# rather than hardcoding a version number that will go stale on update.
BWTEST=$(find /var/lib/vastai_kaalia -maxdepth 1 -type d -name 'version_*' ! -name '*.backup' 2>/dev/null \
    | sort -V | tail -1)
BWTEST="${BWTEST}/bandwidthTest"

if [[ ! -x "$BWTEST" ]]; then
    log "ERROR: bandwidthTest binary not found (looked for $BWTEST) -- skipping this run"
    exit 0
fi

mkdir -p "$FAIL_DIR"

# GPUs currently in use by a rental -- never test these, would compete for
# PCIe bandwidth with a paying renter's workload.
busy_gpus=$(nvidia-smi --query-compute-apps=gpu_uuid --format=csv,noheader 2>/dev/null)
mapfile -t all_gpus < <(nvidia-smi --query-gpu=index,uuid --format=csv,noheader 2>/dev/null)

for line in "${all_gpus[@]}"; do
    idx="${line%%,*}"
    uuid="${line#*, }"
    idx="$(echo "$idx" | xargs)"
    uuid="$(echo "$uuid" | xargs)"

    if echo "$busy_gpus" | grep -qF "$uuid"; then
        log "GPU $idx skipped (active rental process)"
        continue
    fi

    out=$("$BWTEST" --device="$idx" --dtoh --htod --dtod --mode=quick 2>&1)
    rc=$?

    if [[ $rc -eq 0 ]] && echo "$out" | grep -q "Result = PASS"; then
        log "GPU $idx: PASS"
        continue
    fi

    # Failure -- snapshot everything we'd want to have caught in the act.
    ts="$(date -u '+%Y%m%dT%H%M%SZ')"
    snapshot="$FAIL_DIR/${ts}_gpu${idx}.txt"
    {
        echo "=== bandwidthTest failure: GPU $idx at $ts ==="
        echo "$out"
        echo
        echo "=== nvidia-smi (all GPUs) ==="
        nvidia-smi --query-gpu=index,pcie.link.gen.current,pcie.link.width.current,temperature.gpu,ecc.errors.uncorrected.volatile.total,utilization.gpu --format=csv 2>&1
        echo
        echo "=== dmesg -T tail (200 lines) ==="
        dmesg -T 2>&1 | tail -200
        echo
        echo "=== ipmitool sel elist tail (20) ==="
        ipmitool sel elist 2>&1 | tail -20
    } > "$snapshot"

    log "GPU $idx: FAIL -- snapshot saved to $snapshot"
    tg_send "⚠️ <b>bandwidthTest FAILED — $(hostname) GPU $idx</b>
Caught live during periodic watch. Snapshot (dmesg/SEL/link-state) saved to <code>${snapshot}</code> on the rig. Check for PCI SERR correlation."
done
