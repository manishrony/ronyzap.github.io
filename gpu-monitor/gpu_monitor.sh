#!/usr/bin/env bash
# GPU Power Management Monitor
# - Checks every 20 minutes
# - Reduces power limit to 500W per GPU if temp exceeds 75°C
# - Logs all events with timestamps

set -euo pipefail

LOG_FILE="/var/log/gpu_monitor.log"
TEMP_THRESHOLD=75       # °C
POWER_LIMIT_HIGH=500    # Watts applied when temp exceeds threshold
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

throttle_gpu() {
    local gpu_index=$1
    local current_temp=$2
    local gpu_name=$3

    log "THROTTLE: GPU $gpu_index ($gpu_name) temp=${current_temp}°C > ${TEMP_THRESHOLD}°C — setting power limit to ${POWER_LIMIT_HIGH}W"
    if nvidia-smi -i "$gpu_index" --power-limit="$POWER_LIMIT_HIGH" >> "$LOG_FILE" 2>&1; then
        log "THROTTLE: GPU $gpu_index power limit set to ${POWER_LIMIT_HIGH}W OK"
    else
        log "THROTTLE ERROR: Failed to set power limit on GPU $gpu_index (need sudo / persistence mode?)"
    fi
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
    local throttled=0
    while IFS=',' read -r idx name temp power_draw power_limit fan; do
        idx=$(echo "$idx" | xargs)
        name=$(echo "$name" | xargs)
        temp=$(echo "$temp" | xargs)
        power_draw=$(echo "$power_draw" | xargs)
        power_limit=$(echo "$power_limit" | xargs)
        fan=$(echo "$fan" | xargs)

        log "  GPU $idx | $name | Temp: ${temp}°C | Power: ${power_draw}W / ${power_limit}W | Fan: ${fan}%"

        if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > TEMP_THRESHOLD )); then
            throttle_gpu "$idx" "$temp" "$name"
            throttled=$((throttled + 1))
        fi
    done <<< "$gpu_data"

    if (( throttled == 0 )); then
        log "  All GPUs within thermal limits."
    else
        log "  $throttled GPU(s) throttled this cycle."
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
    log "Threshold: ${TEMP_THRESHOLD}°C → ${POWER_LIMIT_HIGH}W cap"
    log "Interval: ${CHECK_INTERVAL}s (20 min)"
    log "Log: $LOG_FILE"
    log "======================================"

    enable_persistence_mode

    while true; do
        log ">>> Cycle start"
        check_rental_status
        check_gpus
        log ">>> Sleeping ${CHECK_INTERVAL}s until next check"
        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
