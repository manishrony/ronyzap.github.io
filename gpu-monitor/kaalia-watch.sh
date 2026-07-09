#!/usr/bin/env bash
# kaalia-watch.sh — Vast.ai Kaalia log diagnostics for ronyzappa2
#
# Two modes:
#   sudo ./kaalia-watch.sh watch                  Live-tail kaalia.log, filtered to real issues only
#   sudo ./kaalia-watch.sh check <instance_id>    Summarize pass/fail for one instance (e.g. C.44313382)
#
# Edit the SUPPRESS list below as you confirm new noise patterns on your host.
#
# Telegram alerts fire on GPU-HW faults (Xid, ECC, thermal, throttle, NVML).
# Credentials are read from /etc/gpu_monitor.conf and /usr/local/bin/gpu_monitor.sh.

set -euo pipefail

KAALIA_LOG="/var/lib/vastai_kaalia/kaalia.log"
EXTRA_LOG_DIR="/var/lib/vastai_kaalia/data/instance_extra_logs"

# Lines matching these patterns are known benign noise on zappa2 and get filtered out.
SUPPRESS='pci_and_minor_no_info|protected_instances|already Enabled for GPU|assign_conts|assign_and_update_used_gpus|diff_conts|ContainerStats2|nvidia_smi_f|nvidia_smi_nvlink_f|send_nvidia_smi_f|streaming output|apt-select-out|_template_id|SubprocessUnsafe cexec_|docker cp |chmod u=rwX|push_ssh_forwarder|read_state:.*unknown|cexec_: docker |status: created|returned exit code 1'

# Keywords that indicate a real problem worth seeing.
WATCH='[Ee]rror|[Ee]xception|[Tt]raceback|[Xx]id|[Ff]ault|ECC|ecc|[Tt]hrottl|[Tt]hermal|[Dd]egrad|[Oo]ffline|[Dd]enied|[Rr]efused|[Ff]ail|[Cc]rash|[Tt]imeout|[Uu]nreachable|NVML|nvml'

# ─── Telegram setup ──────────────────────────────────────────────────────────
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

# Pull from /etc/gpu_monitor.conf (chat ID source)
[[ -f /etc/gpu_monitor.conf ]] && source /etc/gpu_monitor.conf 2>/dev/null || true

# Pull token from installed gpu_monitor.sh if not set
if [[ -z "$TELEGRAM_TOKEN" && -f /usr/local/bin/gpu_monitor.sh ]]; then
    TELEGRAM_TOKEN=$(grep -m1 '^TELEGRAM_TOKEN=' /usr/local/bin/gpu_monitor.sh \
        | cut -d'"' -f2 2>/dev/null || true)
fi

ALERT_THROTTLE_FILE="/var/tmp/kaalia_watch_alert_ts"
ALERT_THROTTLE_SEC=300   # max 1 Telegram per 5 minutes

tg_send() {
    local msg="$1"
    [[ -z "$TELEGRAM_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return
    curl -sf -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d parse_mode="HTML" \
        -d text="$msg" -o /dev/null 2>&1 || true
}

maybe_alert() {
    local line="$1"
    local now; now=$(date +%s)
    local last=0
    [[ -f "$ALERT_THROTTLE_FILE" ]] && last=$(cat "$ALERT_THROTTLE_FILE" 2>/dev/null || echo 0)
    if (( now - last >= ALERT_THROTTLE_SEC )); then
        echo "$now" > "$ALERT_THROTTLE_FILE"
        tg_send "🚨 <b>Kaalia GPU Fault — $(hostname)</b>
<code>$(printf '%s' "$line" | head -c 400)</code>"
    fi
}

# ─── watch mode ──────────────────────────────────────────────────────────────
watch_log() {
    echo "Watching ${KAALIA_LOG} — showing only real issues (Ctrl+C to stop)"
    echo "Suppressing known benign noise: SMI-field warning, protected_instances, stats polling, etc."
    echo "---"
    tail -F "$KAALIA_LOG" \
      | grep --line-buffered -E "$WATCH" \
      | grep --line-buffered -Ev "$SUPPRESS" \
      | while IFS= read -r line; do
          if echo "$line" | grep -qE 'Xid|xid|ECC|ecc|[Tt]hermal|[Tt]hrottl|NVML|nvml|[Ff]ault'; then
              printf '\033[1;31m[GPU-HW] %s\033[0m\n' "$line"
              maybe_alert "$line"
          elif echo "$line" | grep -qE '[Ee]rror|[Ee]xception|[Tt]raceback|[Cc]rash'; then
              printf '\033[1;33m[ERROR]  %s\033[0m\n' "$line"
          else
              printf '\033[0;36m[WARN]   %s\033[0m\n' "$line"
          fi
      done
}

# ─── check mode ──────────────────────────────────────────────────────────────
check_instance() {
    local id="$1"
    local extra="${EXTRA_LOG_DIR}/${id}"

    echo "=== Kaalia daemon log for ${id} ==="
    grep -E "${id}" "$KAALIA_LOG" \
      | grep -Ei "${WATCH}|Destroy|Create.*status" \
      | grep -Ev "$SUPPRESS" \
      || echo "  (no flagged lines)"
    echo

    if [ -f "$extra" ]; then
        echo "=== Instance extra log (${extra}) ==="
        grep -Ei "TESTED|passed|failed|error|exception|traceback|offline|self-test|NCCL|ResNet|ECC|stress|burn|success" "$extra" \
          || echo "  (no flagged lines)"
    else
        echo "No extra log found at ${extra}"
    fi
}

# ─── main ────────────────────────────────────────────────────────────────────
case "${1:-}" in
    watch)
        watch_log
        ;;
    check)
        if [ -z "${2:-}" ]; then
            echo "Usage: $0 check <instance_id>   e.g. $0 check C.44313382"
            exit 1
        fi
        check_instance "$2"
        ;;
    *)
        echo "Usage:"
        echo "  $0 watch                  Live-tail, filtered to real issues"
        echo "  $0 check <instance_id>    Summarize one instance's test/run result"
        exit 1
        ;;
esac
