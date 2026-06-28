#!/usr/bin/env bash
# GPU Power Management Monitor
# - Sets all GPUs to 500W on startup and every cycle
# - Checks every 20 minutes
# - Warns via Telegram if temp exceeds 75°C
# - Monitors Vast.ai rental start/end and sends Telegram alerts

set -euo pipefail

LOG_FILE="/var/log/gpu_monitor.log"
TEMP_THRESHOLD=75        # °C — Telegram alert if exceeded
POWER_LIMIT_DEFAULT=500  # Watts — applied to all GPUs always
CHECK_INTERVAL=1200      # 20 minutes in seconds

# --- Telegram config ---
TELEGRAM_TOKEN="8930785275:AAGFwVssjqAe5EW0e3quosU4u_D9M0XXrCo"
TELEGRAM_CHAT_ID=""      # Auto-populated by setup.sh, or set manually

# --- Vast.ai config ---
VASTAI_API_KEY=""        # Set your Vast.ai API key here
VASTAI_LAST_STATE_FILE="/var/tmp/gpu_monitor_vastai_state"

# ─────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ─────────────────────────────────────────────
# Telegram
# ─────────────────────────────────────────────
tg_send() {
    local msg="$1"
    if [[ -z "$TELEGRAM_CHAT_ID" || -z "$TELEGRAM_TOKEN" ]]; then
        log "TELEGRAM: not configured, skipping message"
        return
    fi
    curl -sf -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d parse_mode="HTML" \
        -d text="$msg" >> "$LOG_FILE" 2>&1 && \
        log "TELEGRAM: sent → $msg" || \
        log "TELEGRAM ERROR: failed to send message"
}

tg_load_chat_id() {
    local config_file="/etc/gpu_monitor.conf"
    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
    fi
}

# ─────────────────────────────────────────────
# GPU power management
# ─────────────────────────────────────────────
enable_persistence_mode() {
    log "Enabling nvidia-smi persistence mode..."
    nvidia-smi --persistence-mode=1 >> "$LOG_FILE" 2>&1 || \
        log "WARNING: Could not enable persistence mode (may already be on or need root)"
}

set_power_limits() {
    log "Setting all GPUs to ${POWER_LIMIT_DEFAULT}W..."
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits | wc -l)
    for (( i=0; i<gpu_count; i++ )); do
        if nvidia-smi -i "$i" --power-limit="$POWER_LIMIT_DEFAULT" >> "$LOG_FILE" 2>&1; then
            log "  GPU $i power limit → ${POWER_LIMIT_DEFAULT}W OK"
        else
            log "  GPU $i power limit ERROR (need root / persistence mode?)"
        fi
    done
}

check_gpus() {
    local gpu_data
    gpu_data=$(nvidia-smi \
        --query-gpu=index,name,temperature.gpu,power.draw,power.limit,fan.speed \
        --format=csv,noheader,nounits 2>&1) || {
        local err_msg="❌ <b>GPU Monitor ERROR</b> on <b>$(hostname)</b>\nnvidia-smi failed: $gpu_data"
        log "ERROR: nvidia-smi failed: $gpu_data"
        tg_send "$err_msg"
        return 1
    }

    log "--- GPU Status ---"
    local overtemp=0
    local status_lines=""
    while IFS=',' read -r idx name temp power_draw power_limit fan; do
        idx=$(echo "$idx" | xargs)
        name=$(echo "$name" | xargs)
        temp=$(echo "$temp" | xargs)
        power_draw=$(echo "$power_draw" | xargs)
        power_limit=$(echo "$power_limit" | xargs)
        fan=$(echo "$fan" | xargs)

        log "  GPU $idx | $name | Temp: ${temp}°C | Power: ${power_draw}W / ${power_limit}W | Fan: ${fan}%"
        status_lines+="  GPU $idx | $name | ${temp}°C | ${power_draw}W | Fan: ${fan}%\n"

        if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > TEMP_THRESHOLD )); then
            log "  WARNING: GPU $idx temp ${temp}°C exceeds ${TEMP_THRESHOLD}°C!"
            tg_send "🌡️ <b>HIGH TEMP WARNING</b> — $(hostname)
GPU $idx: <b>$name</b>
Temp: <b>${temp}°C</b> (limit: ${TEMP_THRESHOLD}°C)
Power: ${power_draw}W / ${power_limit}W | Fan: ${fan}%"
            overtemp=$((overtemp + 1))
        fi
    done <<< "$gpu_data"

    if (( overtemp == 0 )); then
        log "  All GPUs within thermal limits."
    else
        log "  WARNING: $overtemp GPU(s) over temperature threshold."
    fi
    log "--- End GPU Status ---"
}

# ─────────────────────────────────────────────
# Vast.ai rental monitoring
# ─────────────────────────────────────────────
vastai_check() {
    if [[ -z "$VASTAI_API_KEY" ]]; then
        log "VAST.AI: API key not set, skipping"
        return
    fi

    local response
    response=$(curl -sf \
        -H "Authorization: Bearer $VASTAI_API_KEY" \
        "https://console.vast.ai/api/v0/instances/?owner=me" 2>/dev/null) || {
        log "VAST.AI: API call failed"
        return
    }

    # Parse current instances
    local current_state
    current_state=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
instances = data.get('instances', [])
lines = []
for inst in instances:
    iid   = inst.get('id', '?')
    status = inst.get('actual_status', '?')
    gpus  = inst.get('num_gpus', 0)
    gpu_n = inst.get('gpu_name', '?')
    cost  = inst.get('dph_total', 0)
    lines.append(f'{iid}|{status}|{gpus}x {gpu_n}|\${cost:.3f}/hr')
print('\n'.join(lines))
" 2>/dev/null) || {
        log "VAST.AI: Failed to parse response"
        return
    }

    local last_state=""
    [[ -f "$VASTAI_LAST_STATE_FILE" ]] && last_state=$(cat "$VASTAI_LAST_STATE_FILE")

    if [[ "$current_state" != "$last_state" ]]; then
        log "VAST.AI: Rental state changed!"

        # Find new instances (started)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if ! grep -qF "$line" "$VASTAI_LAST_STATE_FILE" 2>/dev/null; then
                IFS='|' read -r iid status gpus cost <<< "$line"
                log "VAST.AI: NEW rental → ID $iid | $gpus | $cost"
                tg_send "✅ <b>Vast.ai Rental STARTED</b> — $(hostname)
Instance ID: <b>$iid</b>
GPUs: $gpus
Cost: $cost
Status: $status"
            fi
        done <<< "$current_state"

        # Find gone instances (ended)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if ! echo "$current_state" | grep -qF "$line"; then
                IFS='|' read -r iid status gpus cost <<< "$line"
                log "VAST.AI: ENDED rental → ID $iid | $gpus | $cost"
                tg_send "🔴 <b>Vast.ai Rental ENDED</b> — $(hostname)
Instance ID: <b>$iid</b>
GPUs: $gpus
Cost: $cost
Last status: $status"
            fi
        done <<< "$last_state"

        # Status changes on existing instances
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            IFS='|' read -r iid status gpus cost <<< "$line"
            local old_line
            old_line=$(grep "^${iid}|" "$VASTAI_LAST_STATE_FILE" 2>/dev/null || true)
            if [[ -n "$old_line" && "$old_line" != "$line" ]]; then
                IFS='|' read -r _ old_status _ _ <<< "$old_line"
                if [[ "$old_status" != "$status" ]]; then
                    log "VAST.AI: Instance $iid status $old_status → $status"
                    tg_send "🔄 <b>Vast.ai Status Change</b> — $(hostname)
Instance ID: <b>$iid</b>
Status: $old_status → <b>$status</b>
GPUs: $gpus | $cost"
                fi
            fi
        done <<< "$current_state"

        echo "$current_state" > "$VASTAI_LAST_STATE_FILE"
    else
        # Log current active rentals
        if [[ -n "$current_state" ]]; then
            log "VAST.AI: Active rentals:"
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                IFS='|' read -r iid status gpus cost <<< "$line"
                log "  Instance $iid | $gpus | $cost | $status"
            done <<< "$current_state"
        else
            log "VAST.AI: No active rentals."
        fi
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
main() {
    tg_load_chat_id

    local host
    host=$(hostname)

    log "======================================"
    log "GPU Monitor started (PID $$) on $host"
    log "Default power limit: ${POWER_LIMIT_DEFAULT}W per GPU"
    log "Temp warning threshold: ${TEMP_THRESHOLD}°C"
    log "Interval: ${CHECK_INTERVAL}s (20 min)"
    log "Telegram: $([ -n "$TELEGRAM_CHAT_ID" ] && echo 'configured' || echo 'NOT configured — run setup.sh')"
    log "Vast.ai:  $([ -n "$VASTAI_API_KEY" ] && echo 'configured' || echo 'NOT configured')"
    log "======================================"

    enable_persistence_mode
    set_power_limits

    tg_send "🚀 <b>GPU Monitor Started</b> — $host
Power limit: ${POWER_LIMIT_DEFAULT}W per GPU
Temp threshold: ${TEMP_THRESHOLD}°C
Check interval: every 20 min"

    while true; do
        log ">>> Cycle start"
        vastai_check
        set_power_limits
        check_gpus
        log ">>> Sleeping ${CHECK_INTERVAL}s until next check"
        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
