#!/usr/bin/env bash
# GPU Power Management Monitor
# - Sets all GPUs to 500W on startup
# - Checks every 20 minutes
# - Logs a warning if temp exceeds 75°C
# - Logs all events with timestamps

set -euo pipefail

LOG_FILE="/var/log/gpu_monitor.log"
TEMP_THRESHOLD=75       # °C — warn if exceeded
POWER_LIMIT_DEFAULT=500 # Watts — applied to all GPUs on startup and every cycle
CHECK_INTERVAL=1200     # 20 minutes in seconds

# --- Rental platform config (edit for your platform) ---
# Options: nicehash | vastai | runpod | none
RENTAL_PLATFORM="none"
NICEHASH_API_BASE="https://api2.nicehash.com"
NICEHASH_ORG_ID=""      # set if using NiceHash
NICEHASH_KEY=""         # set if using NiceHash
NICEHASH_SECRET=""      # set if using NiceHash
VASTAI_API_KEY=""       # set if using Vast.ai

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

check_rental_status() {
    case "$RENTAL_PLATFORM" in
        nicehash)
            if [[ -z "$NICEHASH_ORG_ID" || -z "$NICEHASH_KEY" ]]; then
                log "RENTAL: NiceHash credentials not set, skipping rental check"
                return
            fi
            local rigs
            rigs=$(curl -sf -H "X-Request-Id: $(uuidgen)" \
                -H "X-Nonce: $(date +%s%3N)" \
                -H "X-Organization-Id: $NICEHASH_ORG_ID" \
                -H "X-Auth: $NICEHASH_KEY:$NICEHASH_SECRET" \
                "$NICEHASH_API_BASE/main/api/v2/mining/rigs2" 2>/dev/null) || true
            if [[ -n "$rigs" ]]; then
                local status
                status=$(echo "$rigs" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for rig in data.get('miningRigs', []):
    print(f\"  Rig: {rig.get('name','?')} | Status: {rig.get('minerStatus','?')} | Profitability: {rig.get('profitability',0):.6f} BTC/day\")
" 2>/dev/null) || status="(parse error)"
                log "RENTAL STATUS (NiceHash):"$'\n'"$status"
            fi
            ;;
        vastai)
            if [[ -z "$VASTAI_API_KEY" ]]; then
                log "RENTAL: Vast.ai API key not set, skipping rental check"
                return
            fi
            local instances
            instances=$(curl -sf -H "Authorization: Bearer $VASTAI_API_KEY" \
                "https://console.vast.ai/api/v0/instances/?owner=me" 2>/dev/null) || true
            if [[ -n "$instances" ]]; then
                local status
                status=$(echo "$instances" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for inst in data.get('instances', []):
    print(f\"  ID: {inst.get('id')} | Status: {inst.get('actual_status','?')} | GPUs: {inst.get('num_gpus',0)} | Rented: {inst.get('is_bid',False)}\")
" 2>/dev/null) || status="(parse error)"
                log "RENTAL STATUS (Vast.ai):"$'\n'"$status"
            fi
            ;;
        none|*)
            log "RENTAL: No platform configured (set RENTAL_PLATFORM in script)"
            ;;
    esac
}

set_power_limits() {
    log "Setting all GPUs to ${POWER_LIMIT_DEFAULT}W..."
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits | wc -l)
    for (( i=0; i<gpu_count; i++ )); do
        if nvidia-smi -i "$i" --power-limit="$POWER_LIMIT_DEFAULT" >> "$LOG_FILE" 2>&1; then
            log "  GPU $i power limit set to ${POWER_LIMIT_DEFAULT}W OK"
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
        log "ERROR: nvidia-smi failed: $gpu_data"
        return 1
    }

    log "--- GPU Status ---"
    local overtemp=0
    while IFS=',' read -r idx name temp power_draw power_limit fan; do
        idx=$(echo "$idx" | xargs)
        name=$(echo "$name" | xargs)
        temp=$(echo "$temp" | xargs)
        power_draw=$(echo "$power_draw" | xargs)
        power_limit=$(echo "$power_limit" | xargs)
        fan=$(echo "$fan" | xargs)

        log "  GPU $idx | $name | Temp: ${temp}°C | Power: ${power_draw}W / ${power_limit}W | Fan: ${fan}%"

        if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > TEMP_THRESHOLD )); then
            log "  WARNING: GPU $idx temp ${temp}°C exceeds ${TEMP_THRESHOLD}°C threshold!"
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

enable_persistence_mode() {
    log "Enabling nvidia-smi persistence mode..."
    nvidia-smi --persistence-mode=1 >> "$LOG_FILE" 2>&1 || \
        log "WARNING: Could not enable persistence mode (may already be on or need root)"
}

main() {
    log "======================================"
    log "GPU Monitor started (PID $$)"
    log "Default power limit: ${POWER_LIMIT_DEFAULT}W per GPU"
    log "Temp warning threshold: ${TEMP_THRESHOLD}°C"
    log "Interval: ${CHECK_INTERVAL}s (20 min)"
    log "Log: $LOG_FILE"
    log "======================================"

    enable_persistence_mode
    set_power_limits

    while true; do
        log ">>> Cycle start"
        check_rental_status
        set_power_limits
        check_gpus
        log ">>> Sleeping ${CHECK_INTERVAL}s until next check"
        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
