#!/usr/bin/env bash
# GPU Power Management Monitor
# - Sets all GPUs to 500W on startup and every cycle
# - Checks GPU temps every 20 minutes, alerts on Telegram if >75°C
# - Monitors Vast.ai rental start/end every 20 min
# - Dynamic pricing every 30 min: adjusts ask price 1-5 cents to stay
#   competitive; skips if machine is rented; floor $0.30/hr for RTX 5090
# - Max rental duration capped at 5 days on every pricing update

set -euo pipefail

LOG_FILE="/var/log/gpu_monitor.log"
JSONL_FILE="/var/log/gpu_monitor_data.jsonl"
TEMP_THRESHOLD=75        # °C — Telegram alert if exceeded
POWER_LIMIT_DEFAULT=500  # Watts — applied to all GPUs always
CHECK_INTERVAL=1200      # 20 minutes in seconds (GPU + rental check)
PRICE_INTERVAL=1800      # 30 minutes in seconds (pricing check)

# --- Telegram config ---
TELEGRAM_TOKEN="8930785275:AAGFwVssjqAe5EW0e3quosU4u_D9M0XXrCo"
TELEGRAM_CHAT_ID=""      # Auto-populated by setup.sh

# --- Vast.ai config ---
VASTAI_API_KEY=""
VASTAI_API="https://console.vast.ai/api/v0"
VASTAI_LAST_STATE_FILE="/var/tmp/gpu_monitor_vastai_state"
VASTAI_LAST_PRICE_FILE="/var/tmp/gpu_monitor_vastai_prices"

# --- Pricing rules ---
# Format: "GPU_NAME_SUBSTRING:MIN_PRICE_CENTS"  (price in cents/hr)
PRICE_FLOORS=(
    "5090:30"
    "4090:20"
    "4080:15"
    "3090:10"
    "3080:8"
)
PRICE_ADJUST_MIN=1   # minimum cents to move per cycle
PRICE_ADJUST_MAX=5   # maximum cents to move per cycle
MAX_RENTAL_DAYS=5    # max rental duration set on every pricing update

# ─────────────────────────────────────────────
# Logging + structured JSON events
# ─────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Append a JSON event to the JSONL data file for the dashboard
write_event() {
    local type="$1"
    local payload="$2"
    python3 - <<PYEOF 2>/dev/null || true
import json, datetime, socket, os
event = {
    "ts":   datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "type": "$type",
    "host": socket.gethostname(),
}
event.update(json.loads(r"""$payload"""))
with open("$JSONL_FILE", "a") as f:
    f.write(json.dumps(event) + "\n")
PYEOF
}

# ─────────────────────────────────────────────
# Telegram
# ─────────────────────────────────────────────
tg_send() {
    local msg="$1"
    if [[ -z "$TELEGRAM_CHAT_ID" || -z "$TELEGRAM_TOKEN" ]]; then
        log "TELEGRAM: not configured, skipping"
        return
    fi
    curl -sf -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d parse_mode="HTML" \
        -d text="$msg" >> "$LOG_FILE" 2>&1 \
        && log "TELEGRAM: sent OK" \
        || log "TELEGRAM ERROR: failed to send"
}

tg_load_chat_id() {
    [[ -f "/etc/gpu_monitor.conf" ]] && source "/etc/gpu_monitor.conf"
}

# ─────────────────────────────────────────────
# GPU power management
# ─────────────────────────────────────────────
enable_persistence_mode() {
    log "Enabling nvidia-smi persistence mode..."
    nvidia-smi --persistence-mode=1 >> "$LOG_FILE" 2>&1 || \
        log "WARNING: Could not enable persistence mode"
}

set_power_limits() {
    log "Setting all GPUs to ${POWER_LIMIT_DEFAULT}W..."
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits | wc -l)
    for (( i=0; i<gpu_count; i++ )); do
        if nvidia-smi -i "$i" --power-limit="$POWER_LIMIT_DEFAULT" >> "$LOG_FILE" 2>&1; then
            log "  GPU $i → ${POWER_LIMIT_DEFAULT}W OK"
        else
            log "  GPU $i power limit ERROR"
        fi
    done
}

check_gpus() {
    local gpu_data
    gpu_data=$(nvidia-smi \
        --query-gpu=index,name,temperature.gpu,power.draw,power.limit,fan.speed \
        --format=csv,noheader,nounits 2>&1) || {
        log "ERROR: nvidia-smi failed: $gpu_data"
        tg_send "❌ <b>GPU Monitor ERROR</b> — $(hostname)
nvidia-smi failed: $gpu_data"
        return 1
    }

    log "--- GPU Status ---"
    local overtemp=0
    local gpu_json_arr="["
    local first=1
    while IFS=',' read -r idx name temp power_draw power_limit fan; do
        idx=$(echo "$idx" | xargs); name=$(echo "$name" | xargs)
        temp=$(echo "$temp" | xargs); power_draw=$(echo "$power_draw" | xargs)
        power_limit=$(echo "$power_limit" | xargs); fan=$(echo "$fan" | xargs)

        log "  GPU $idx | $name | Temp: ${temp}°C | Power: ${power_draw}W/${power_limit}W | Fan: ${fan}%"

        [[ $first -eq 0 ]] && gpu_json_arr+=","
        gpu_json_arr+="{\"idx\":$idx,\"name\":\"$name\",\"temp\":$temp,\"power_draw\":$power_draw,\"power_limit\":$power_limit,\"fan\":$fan}"
        first=0

        if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > TEMP_THRESHOLD )); then
            log "  WARNING: GPU $idx at ${temp}°C exceeds ${TEMP_THRESHOLD}°C!"
            tg_send "🌡️ <b>HIGH TEMP WARNING</b> — $(hostname)
GPU $idx: <b>$name</b>
Temp: <b>${temp}°C</b> (threshold: ${TEMP_THRESHOLD}°C)
Power: ${power_draw}W / ${power_limit}W | Fan: ${fan}%"
            write_event "temp_warning" "{\"gpu_idx\":$idx,\"gpu_name\":\"$name\",\"temp\":$temp,\"power_draw\":$power_draw,\"fan\":$fan}"
            overtemp=$((overtemp + 1))
        fi
    done <<< "$gpu_data"
    gpu_json_arr+="]"

    write_event "gpu_status" "{\"gpus\":$gpu_json_arr}"

    (( overtemp == 0 )) && log "  All GPUs within thermal limits." \
        || log "  WARNING: $overtemp GPU(s) over temp threshold."
    log "--- End GPU Status ---"
}

# ─────────────────────────────────────────────
# Vast.ai rental monitoring
# ─────────────────────────────────────────────
vastai_check() {
    [[ -z "$VASTAI_API_KEY" ]] && { log "VAST.AI: API key not set, skipping"; return; }

    local response
    response=$(curl -sf -H "Authorization: Bearer $VASTAI_API_KEY" \
        "$VASTAI_API/instances/?owner=me" 2>/dev/null) || {
        log "VAST.AI: API call failed"; return
    }

    local current_state
    current_state=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
lines = []
for inst in data.get('instances', []):
    iid    = inst.get('id', '?')
    status = inst.get('actual_status', '?')
    gpus   = inst.get('num_gpus', 0)
    gpu_n  = inst.get('gpu_name', '?')
    cost   = inst.get('dph_total', 0)
    lines.append(f'{iid}|{status}|{gpus}x {gpu_n}|\${cost:.3f}/hr')
print('\n'.join(lines))
" 2>/dev/null) || { log "VAST.AI: Parse error"; return; }

    local last_state=""
    [[ -f "$VASTAI_LAST_STATE_FILE" ]] && last_state=$(cat "$VASTAI_LAST_STATE_FILE")

    if [[ "$current_state" != "$last_state" ]]; then
        log "VAST.AI: State changed"

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if ! grep -qF "$line" "$VASTAI_LAST_STATE_FILE" 2>/dev/null; then
                IFS='|' read -r iid status gpus cost <<< "$line"
                log "VAST.AI: NEW rental → ID $iid | $gpus | $cost"
                tg_send "✅ <b>Vast.ai Rental STARTED</b> — $(hostname)
Instance: <b>$iid</b> | GPUs: $gpus
Rate: <b>$cost</b> | Status: $status"
                write_event "rental_start" "{\"instance_id\":\"$iid\",\"gpus\":\"$gpus\",\"rate\":\"$cost\",\"status\":\"$status\"}"
            fi
        done <<< "$current_state"

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if ! echo "$current_state" | grep -qF "$line"; then
                IFS='|' read -r iid status gpus cost <<< "$line"
                log "VAST.AI: ENDED rental → ID $iid"
                tg_send "🔴 <b>Vast.ai Rental ENDED</b> — $(hostname)
Instance: <b>$iid</b> | GPUs: $gpus
Rate was: $cost | Last status: $status"
                write_event "rental_end" "{\"instance_id\":\"$iid\",\"gpus\":\"$gpus\",\"rate\":\"$cost\",\"status\":\"$status\"}"
            fi
        done <<< "$last_state"

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            IFS='|' read -r iid status gpus cost <<< "$line"
            local old_line
            old_line=$(grep "^${iid}|" "$VASTAI_LAST_STATE_FILE" 2>/dev/null || true)
            if [[ -n "$old_line" && "$old_line" != "$line" ]]; then
                IFS='|' read -r _ old_status _ _ <<< "$old_line"
                [[ "$old_status" != "$status" ]] && {
                    log "VAST.AI: Instance $iid: $old_status → $status"
                    tg_send "🔄 <b>Vast.ai Status Change</b> — $(hostname)
Instance: <b>$iid</b> | $gpus
$old_status → <b>$status</b> | $cost"
                }
            fi
        done <<< "$current_state"

        echo "$current_state" > "$VASTAI_LAST_STATE_FILE"
    else
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
# Dynamic pricing
# ─────────────────────────────────────────────

# Returns floor price in dollars for a given GPU name
get_price_floor() {
    local gpu_name="${1^^}"   # uppercase
    for rule in "${PRICE_FLOORS[@]}"; do
        local pattern="${rule%%:*}"
        local floor_cents="${rule##*:}"
        if [[ "$gpu_name" == *"${pattern^^}"* ]]; then
            echo "scale=2; $floor_cents / 100" | bc
            return
        fi
    done
    echo "0.05"   # default floor: 5 cents
}

# Fetch your hosted machines from Vast.ai (host API)
vastai_get_machines() {
    curl -sf -H "Authorization: Bearer $VASTAI_API_KEY" \
        "$VASTAI_API/machines/?owner=me" 2>/dev/null
}

# Fetch market listings for a specific GPU to get competitive price
vastai_market_price() {
    local gpu_name="$1"
    curl -sf "$VASTAI_API/asks/?gpu_name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$gpu_name")&rentable=true&order=dph_total&limit=20" \
        2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    offers = data.get('offers', [])
    prices = [o.get('dph_total', 0) for o in offers if o.get('dph_total', 0) > 0]
    if prices:
        prices.sort()
        # Use 25th percentile — competitive but not lowest
        idx = max(0, len(prices)//4)
        print(f'{prices[idx]:.4f}')
    else:
        print('0')
except:
    print('0')
" 2>/dev/null
}

# Update ask price for a machine, capping max rental to MAX_RENTAL_DAYS
vastai_set_price() {
    local machine_id="$1"
    local new_price="$2"
    local end_date
    end_date=$(( $(date +%s) + MAX_RENTAL_DAYS * 86400 ))
    curl -sf -X PUT \
        -H "Authorization: Bearer $VASTAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"min_bid\": $new_price, \"listed\": true, \"end_date\": $end_date}" \
        "$VASTAI_API/machines/${machine_id}/" >> "$LOG_FILE" 2>&1
}

vastai_pricing() {
    [[ -z "$VASTAI_API_KEY" ]] && return

    log "--- Pricing Check ---"

    local machines_json
    machines_json=$(vastai_get_machines) || { log "PRICING: Could not fetch machines"; return; }

    echo "$machines_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
machines = data.get('machines', [])
for m in machines:
    mid      = m.get('id', '')
    rented   = m.get('rented', False)
    listed   = m.get('listed', False)
    gpu_name = m.get('gpu_name', 'unknown')
    cur_bid  = m.get('min_bid', 0)
    num_gpus = m.get('num_gpus', 1)
    print(f'{mid}|{rented}|{listed}|{gpu_name}|{cur_bid}|{num_gpus}')
" 2>/dev/null | while IFS='|' read -r mid rented listed gpu_name cur_bid num_gpus; do

        [[ -z "$mid" ]] && continue

        log "  Machine $mid | GPU: $gpu_name x$num_gpus | Listed: $listed | Rented: $rented | Current bid: \$$cur_bid/hr"

        # Skip if currently rented — never touch pricing of active rentals
        if [[ "$rented" == "True" ]]; then
            log "  Machine $mid: RENTED — skipping price adjustment"
            continue
        fi

        # Skip if not listed
        if [[ "$listed" != "True" ]]; then
            log "  Machine $mid: not listed — skipping"
            continue
        fi

        local floor
        floor=$(get_price_floor "$gpu_name")

        local market_price
        market_price=$(vastai_market_price "$gpu_name")

        if [[ -z "$market_price" || "$market_price" == "0" ]]; then
            log "  Machine $mid: could not fetch market price, skipping"
            continue
        fi

        log "  Machine $mid: market 25th-pct = \$$market_price/hr | floor = \$$floor/hr | current = \$$cur_bid/hr"

        # Calculate adjustment (1-5 cents random to avoid synchronized movement)
        local adjust_cents=$(( RANDOM % (PRICE_ADJUST_MAX - PRICE_ADJUST_MIN + 1) + PRICE_ADJUST_MIN ))
        local adjust
        adjust=$(echo "scale=4; $adjust_cents / 100" | bc)

        local new_price
        # If we're above market, come down; if below or at market, nudge up slightly
        if (( $(echo "$cur_bid > $market_price + 0.02" | bc -l) )); then
            new_price=$(echo "scale=4; $cur_bid - $adjust" | bc)
            local direction="↓ (above market)"
        elif (( $(echo "$cur_bid < $market_price - 0.02" | bc -l) )); then
            new_price=$(echo "scale=4; $cur_bid + $adjust" | bc)
            local direction="↑ (below market)"
        else
            log "  Machine $mid: price within 2 cents of market — no change"
            continue
        fi

        # Enforce floor
        if (( $(echo "$new_price < $floor" | bc -l) )); then
            new_price="$floor"
            local direction="↑ floored at \$$floor"
        fi

        # Only update if price actually changed meaningfully
        if (( $(echo "($new_price - $cur_bid)^2 < 0.0001" | bc -l) )); then
            log "  Machine $mid: negligible change, skipping"
            continue
        fi

        log "  Machine $mid: adjusting \$$cur_bid → \$$new_price/hr $direction"

        local expire_date
        expire_date=$(date -d "+${MAX_RENTAL_DAYS} days" '+%Y-%m-%d' 2>/dev/null \
            || date -v "+${MAX_RENTAL_DAYS}d" '+%Y-%m-%d' 2>/dev/null \
            || echo "in ${MAX_RENTAL_DAYS} days")

        if vastai_set_price "$mid" "$new_price"; then
            log "  Machine $mid: price updated OK (expires $expire_date)"
            tg_send "💰 <b>Price Adjusted</b> — $(hostname)
Machine: <b>$mid</b> | GPU: $gpu_name x$num_gpus
<b>\$$cur_bid → \$$new_price/hr</b> $direction
Market: \$$market_price/hr | Floor: \$$floor/hr
Max rental: <b>${MAX_RENTAL_DAYS} days</b> (until $expire_date)"
            write_event "price_change" "{\"machine_id\":\"$mid\",\"gpu_name\":\"$gpu_name\",\"num_gpus\":$num_gpus,\"old_price\":$cur_bid,\"new_price\":$new_price,\"market_price\":$market_price,\"floor\":$floor,\"expire_date\":\"$expire_date\"}"
        else
            log "  Machine $mid: price update FAILED"
        fi

    done

    log "--- End Pricing Check ---"
}

# ─────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────
main() {
    tg_load_chat_id

    local host
    host=$(hostname)

    log "======================================"
    log "GPU Monitor started (PID $$) on $host"
    log "Default power limit : ${POWER_LIMIT_DEFAULT}W per GPU"
    log "Temp threshold      : ${TEMP_THRESHOLD}°C"
    log "GPU/rental interval : ${CHECK_INTERVAL}s (20 min)"
    log "Pricing interval    : ${PRICE_INTERVAL}s (30 min)"
    log "Telegram : $([ -n "$TELEGRAM_CHAT_ID" ] && echo 'configured' || echo 'NOT configured — run setup.sh')"
    log "Vast.ai  : $([ -n "$VASTAI_API_KEY"   ] && echo 'configured' || echo 'NOT configured')"
    log "======================================"

    touch "$JSONL_FILE" && chmod 644 "$JSONL_FILE"
    enable_persistence_mode
    set_power_limits
    write_event "startup" "{\"power_limit\":$POWER_LIMIT_DEFAULT,\"temp_threshold\":$TEMP_THRESHOLD}"

    tg_send "🚀 <b>GPU Monitor Started</b> — $host
Power limit: ${POWER_LIMIT_DEFAULT}W/GPU | Temp alert: ${TEMP_THRESHOLD}°C
GPU check: every 20 min | Pricing: every 30 min"

    local last_price_check=0

    while true; do
        local now
        now=$(date +%s)

        log ">>> Cycle start"
        vastai_check
        set_power_limits
        check_gpus

        # Run pricing every 30 min
        if (( now - last_price_check >= PRICE_INTERVAL )); then
            vastai_pricing
            last_price_check=$now
        else
            local next_price=$(( PRICE_INTERVAL - (now - last_price_check) ))
            log ">>> Next pricing check in ${next_price}s"
        fi

        log ">>> Sleeping ${CHECK_INTERVAL}s"
        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
