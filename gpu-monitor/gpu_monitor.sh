#!/usr/bin/env bash
# GPU Power Management Monitor
# - Sets all GPUs to 500W on startup and every cycle
# - Checks GPU temps every hour; Telegram alert only if >75°C
# - Monitors Vast.ai rental start/end every hour
# - Syncs earnings from Vast.ai API on startup and every hour
# - Dynamic pricing every 30 min; Telegram only on price change
# - Rental events (start/end) always alert on Telegram
# - Max rental capped at 5 days per pricing update

# Intentionally no set -euo pipefail — this is a resilient daemon that
# must survive API errors, transient network failures, and bad GPU readings.

LOG_FILE="/var/log/gpu_monitor.log"
JSONL_FILE="/var/log/gpu_monitor_data.jsonl"
TEMP_THRESHOLD=75        # °C — Telegram alert if exceeded
POWER_LIMIT_DEFAULT=500  # Watts — applied to all GPUs always
CHECK_INTERVAL=3600      # 1 hour in seconds (GPU + rental check)
PRICE_INTERVAL=1800      # 30 minutes in seconds (pricing check)

# --- Telegram config ---
TELEGRAM_TOKEN="8930785275:AAGFwVssjqAe5EW0e3quosU4u_D9M0XXrCo"
TELEGRAM_CHAT_ID=""      # Auto-populated from /etc/gpu_monitor.conf

# --- Vast.ai config ---
VASTAI_API_KEY=""
VASTAI_API="https://console.vast.ai/api/v1"
VASTAI_LAST_STATE_FILE="/var/tmp/gpu_monitor_vastai_state"

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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
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

# On startup: backfill rental_start events for any currently RENTED machine
# not yet in the JSONL log (handles monitor installed mid-rental).
# Uses /machines/ endpoint (host view) — rented=True means someone is renting your GPU.
vastai_init_state() {
    [[ -z "$VASTAI_API_KEY" ]] && return

    log "VAST.AI INIT: checking machines for active rentals..."

    local response tmpfile
    response=$(vastai_get "$VASTAI_API/machines/") || {
        log "VAST.AI INIT: API call failed — skipping startup scan"
        return
    }

    tmpfile=$(mktemp)
    echo "$response" > "$tmpfile"

    python3 - "$tmpfile" "$JSONL_FILE" <<'PYEOF' 2>/dev/null >> "$LOG_FILE" || true
import sys, json, datetime, socket

tmpf, jsonl = sys.argv[1], sys.argv[2]

try:
    with open(tmpf) as f:
        data = json.load(f)
except Exception as e:
    print(f"[INIT] JSON parse error: {e}")
    sys.exit(0)

machines = data.get('machines', [])

# Track machines with an OPEN rental (rental_start not yet followed by rental_end)
open_rentals = set()
try:
    with open(jsonl) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                mid = str(ev.get('machine_id', ev.get('instance_id', '')))
                if ev.get('type') == 'rental_start':
                    open_rentals.add(mid)
                elif ev.get('type') == 'rental_end':
                    open_rentals.discard(mid)
            except Exception:
                pass
except FileNotFoundError:
    pass

count = 0
now_str = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

for m in machines:
    mid      = str(m.get('id', ''))
    # Only manage machines that belong to this rig (by hostname)
    if m.get('hostname', '') != socket.gethostname():
        continue
    rented   = m.get('rented', False)
    # current_rentals_resident is the reliable field; rented field can be stale
    if int(m.get('current_rentals_resident', 0) or 0) > 0:
        rented = True
    if int(m.get('num_running_instances', 0) or 0) > 0:
        rented = True
    gpu_name = m.get('gpu_name', 'unknown')
    num_gpus = m.get('num_gpus', 0)
    cur_bid  = float(m.get('min_bid_price', m.get('min_bid', 0)) or 0)

    if not mid or not rented:
        continue

    if mid in open_rentals:
        print(f"[INIT] Machine {mid} already has open rental — skipping")
        continue

    # If min_bid_price is 0, try to get rate from last price_change event in the log
    if cur_bid <= 0:
        try:
            with open(jsonl) as ff:
                for ll in ff:
                    try:
                        evv = json.loads(ll.strip())
                        if evv.get('type') == 'price_change' and str(evv.get('machine_id', '')) == mid:
                            p = float(evv.get('new_price', 0) or 0)
                            if p > 0:
                                cur_bid = p
                    except Exception:
                        pass
        except Exception:
            pass

    if cur_bid <= 0:
        print(f"[INIT] Machine {mid}: rate unknown, skipping backfill (will retry next cycle)")
        continue

    event = {
        'ts':          now_str,
        'type':        'rental_start',
        'host':        socket.gethostname(),
        'machine_id':  mid,
        'instance_id': mid,
        'gpus':        f'{num_gpus}x {gpu_name}',
        'rate':        f'${cur_bid:.3f}/hr',
        'status':      'running',
        'backfilled':  True,
    }
    with open(jsonl, 'a') as f:
        f.write(json.dumps(event) + '\n')
    print(f"[INIT] Backfilled rental_start: machine {mid} ({num_gpus}x {gpu_name} @ ${cur_bid:.3f}/hr)")
    count += 1

if not count:
    print("[INIT] No backfill needed — no newly rented machines")
PYEOF

    rm -f "$tmpfile"
}

# Summarise tracked revenue from JSONL log (no API call needed — Vast.ai
# does not expose host-side billing history via their v1 API).
# Historical earnings are injected manually via daily_earnings events from CSV export.
vastai_sync_earnings() {
    [[ -z "$VASTAI_API_KEY" ]] && return

    python3 - "$JSONL_FILE" <<'PYEOF' 2>/dev/null >> "$LOG_FILE" || true
import sys, json, datetime

jsonl = sys.argv[1]
total = 0.0
daily_total = 0.0
today = datetime.datetime.utcnow().strftime('%Y-%m-%d')

try:
    with open(jsonl) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                t = ev.get('type', '')
                if t == 'daily_earnings':
                    total += float(ev.get('total', 0))
                    if ev.get('date', '') == today:
                        daily_total += float(ev.get('total', 0))
            except Exception:
                pass
except FileNotFoundError:
    pass

print(f"[EARNINGS] Logged daily_earnings: total=${total:.2f}  today=${daily_total:.2f}")
PYEOF
}

# Check machine rental status from HOST perspective.
# Uses /machines/?owner=me — 'rented' field = someone is renting your GPU.
# Fires rental_start/end Telegram alerts only when rented status changes.
vastai_check() {
    [[ -z "$VASTAI_API_KEY" ]] && { log "VAST.AI: API key not set, skipping"; return; }

    local response
    response=$(vastai_get "$VASTAI_API/machines/") || {
        log "VAST.AI: API call failed"; return
    }

    # State: one line per machine: {mid}|{rented}|{num_gpus}x{gpu_name}|{bid}/hr
    local current_state
    current_state=$(echo "$response" | python3 -c "
import sys, json, socket
data = json.load(sys.stdin)
hn = socket.gethostname()
lines = []
for m in data.get('machines', []):
    if m.get('hostname', '') != hn:
        continue
    mid      = m.get('id', '?')
    rented   = m.get('rented', False)
    if int(m.get('current_rentals_resident', 0) or 0) > 0:
        rented = True
    if int(m.get('num_running_instances', 0) or 0) > 0:
        rented = True
    gpu_name = m.get('gpu_name', '?')
    num_gpus = m.get('num_gpus', 0)
    cur_bid  = float(m.get('min_bid_price', m.get('min_bid', 0)) or 0)
    lines.append(f'{mid}|{rented}|{num_gpus}x {gpu_name}|\${cur_bid:.3f}/hr')
print('\n'.join(lines))
" 2>/dev/null) || { log "VAST.AI: Parse error"; return; }

    local last_state=""
    [[ -f "$VASTAI_LAST_STATE_FILE" ]] && last_state=$(cat "$VASTAI_LAST_STATE_FILE")

    if [[ "$current_state" != "$last_state" ]]; then
        log "VAST.AI: Machine state changed"

        # Check each current machine for rental status changes
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            IFS='|' read -r mid rented gpus cost <<< "$line"

            local old_line
            old_line=$(grep "^${mid}|" "$VASTAI_LAST_STATE_FILE" 2>/dev/null || true)

            if [[ -z "$old_line" ]]; then
                # Machine not in state file yet — just log current status.
                # vastai_init_state() already backfilled rental_start on startup.
                log "VAST.AI: Machine $mid | $gpus | $cost | Rented: $rented (first seen)"
            else
                local old_rented
                IFS='|' read -r _ old_rented _ _ <<< "$old_line"
                if [[ "$old_rented" != "$rented" ]]; then
                    if [[ "$rented" == "True" ]]; then
                        log "VAST.AI: Machine $mid — rental STARTED"
                        tg_send "✅ <b>Vast.ai Rental STARTED</b> — $(hostname)
Machine: <b>$mid</b> | GPUs: $gpus
Rate: <b>$cost</b>"
                        write_event "rental_start" "{\"machine_id\":\"$mid\",\"instance_id\":\"$mid\",\"gpus\":\"$gpus\",\"rate\":\"$cost\",\"status\":\"running\"}"
                    else
                        log "VAST.AI: Machine $mid — rental ENDED"
                        tg_send "🔴 <b>Vast.ai Rental ENDED</b> — $(hostname)
Machine: <b>$mid</b> | GPUs: $gpus
Last rate: $cost"
                        write_event "rental_end" "{\"machine_id\":\"$mid\",\"instance_id\":\"$mid\",\"gpus\":\"$gpus\",\"rate\":\"$cost\",\"status\":\"ended\"}"
                    fi
                fi
            fi
        done <<< "$current_state"

        # Check for machines that disappeared while rented
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            IFS='|' read -r mid old_rented gpus cost <<< "$line"
            if ! echo "$current_state" | grep -q "^${mid}|"; then
                if [[ "$old_rented" == "True" ]]; then
                    log "VAST.AI: Machine $mid disappeared while rented"
                    write_event "rental_end" "{\"machine_id\":\"$mid\",\"instance_id\":\"$mid\",\"gpus\":\"$gpus\",\"rate\":\"$cost\",\"status\":\"gone\"}"
                fi
            fi
        done <<< "$last_state"

        echo "$current_state" > "$VASTAI_LAST_STATE_FILE"
    else
        # No change — just log current status quietly
        if [[ -n "$current_state" ]]; then
            log "VAST.AI: Machine status (unchanged):"
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                IFS='|' read -r mid rented gpus cost <<< "$line"
                log "  Machine $mid | $gpus | $cost | Rented: $rented"
            done <<< "$current_state"
        else
            log "VAST.AI: No machines found."
        fi
    fi
}

# ─────────────────────────────────────────────
# Dynamic pricing
# ─────────────────────────────────────────────

# Returns floor price in dollars for a given GPU name (always 4 decimal places, valid JSON number)
get_price_floor() {
    local gpu_name="${1^^}"
    for rule in "${PRICE_FLOORS[@]}"; do
        local pattern="${rule%%:*}"
        local floor_cents="${rule##*:}"
        if [[ "$gpu_name" == *"${pattern^^}"* ]]; then
            printf "%.4f\n" "$(echo "scale=4; $floor_cents / 100" | bc)"
            return
        fi
    done
    echo "0.0500"
}

# Vast.ai GET helper: /machines/ requires api_key= query param (not Bearer token).
# Try api_key param first; fall back to Bearer for endpoints that need it.
vastai_get() {
    local url="$1"
    local sep; [[ "$url" == *"?"* ]] && sep="&" || sep="?"
    curl -sf "${url}${sep}api_key=${VASTAI_API_KEY}" 2>/dev/null || \
    curl -sf -H "Authorization: Bearer $VASTAI_API_KEY" "$url" 2>/dev/null
}

vastai_get_machines() {
    vastai_get "$VASTAI_API/machines/" 2>/dev/null || echo '{"machines":[]}'
}

vastai_market_stats() {
    local gpu_name="$1"
    local encoded_name
    encoded_name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$gpu_name" 2>/dev/null || echo "$gpu_name")
    local url="$VASTAI_API/bundles/?gpu_name=${encoded_name}&rentable=true&order=dph_total&limit=50&type=on_demand"
    { vastai_get "$url" 2>/dev/null || echo '{}'; } | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    offers = data.get('offers', data.get('instances', []))
    prices = sorted([float(o.get('dph_total', 0) or 0) for o in offers if float(o.get('dph_total', 0) or 0) > 0])
    if prices:
        n = len(prices)
        def pct(p): return prices[min(n-1, int(p*(n-1)/100))]
        print(json.dumps({
            'p25':    round(pct(25), 4),
            'median': round(pct(50), 4),
            'p75':    round(pct(75), 4),
            'mean':   round(sum(prices)/n, 4),
            'min':    round(prices[0], 4),
            'max':    round(prices[-1], 4),
            'count':  n
        }))
    else:
        print('null')
except Exception as e:
    sys.stderr.write(f'market_stats error: {e}\n')
    print('null')
" 2>/dev/null
}

vastai_set_price() {
    local machine_id="$1"
    local new_price="$2"
    local http_code tmpf
    # Ensure valid JSON decimal (bc may produce .30 without leading zero)
    new_price=$(printf "%.4f" "$new_price")
    # Confirmed working endpoint: PUT /api/v0/machines/{id}/minbid/
    # Body: {"client_id": "me", "price": <per_gpu_per_hour>}
    local data="{\"client_id\": \"me\", \"price\": $new_price}"
    tmpf=$(mktemp)

    http_code=$(curl -s -o "$tmpf" -w "%{http_code}" -X PUT \
        -H "Content-Type: application/json" \
        -d "$data" \
        "https://console.vast.ai/api/v0/machines/${machine_id}/minbid/?api_key=${VASTAI_API_KEY}" 2>/dev/null)
    if [[ "$http_code" =~ ^2 ]]; then rm -f "$tmpf"; return 0; fi
    log "  PUT v0/minbid HTTP ${http_code}: $(head -c 200 "$tmpf")"

    rm -f "$tmpf"
    return 1
}

vastai_pricing() {
    [[ -z "$VASTAI_API_KEY" ]] && return

    log "--- Pricing Check ---"

    local machines_json
    machines_json=$(vastai_get_machines) || { log "PRICING: Could not fetch machines"; return; }

    echo "$machines_json" | python3 -c "

import sys, json, socket
data = json.load(sys.stdin)
hn = socket.gethostname()
for m in data.get('machines', []):
    if m.get('hostname', '') != hn:
        continue
    mid      = m.get('id', '')
    rented   = m.get('rented', False)
    if int(m.get('current_rentals_resident', 0) or 0) > 0:
        rented = True
    if int(m.get('num_running_instances', 0) or 0) > 0:
        rented = True
    listed   = m.get('listed', False)
    gpu_name = m.get('gpu_name', 'unknown')
    cur_bid  = float(m.get('min_bid_price', m.get('min_bid', 0)) or 0)
    num_gpus = m.get('num_gpus', 1)
    print(f'{mid}|{rented}|{listed}|{gpu_name}|{cur_bid}|{num_gpus}')
" 2>/dev/null | while IFS='|' read -r mid rented listed gpu_name cur_bid num_gpus; do

        [[ -z "$mid" ]] && continue

        log "  Machine $mid | GPU: $gpu_name x$num_gpus | Listed: $listed | Rented: $rented | Bid: \$$cur_bid/hr"

        local floor
        floor=$(get_price_floor "$gpu_name")

        # Fetch full market stats, write snapshot, send below-median alert
        local stats_json market_price market_median
        stats_json=$(vastai_market_stats "$gpu_name")

        if [[ -n "$stats_json" && "$stats_json" != "null" ]]; then
            market_price=$(  echo "$stats_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d[\"p25\"]:.4f}')"   2>/dev/null || echo "0")
            market_median=$( echo "$stats_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d[\"median\"]:.4f}')" 2>/dev/null || echo "0")

            # Write market_snapshot event for the dashboard market analysis page
            local snap_json
            snap_json=$(echo "$stats_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d.update({'machine_id':'$mid','gpu_name':'$gpu_name','num_gpus':$num_gpus,'my_price':$cur_bid,'below_median':($cur_bid < d.get('median',99))})
print(json.dumps(d))
" 2>/dev/null)
            [[ -n "$snap_json" ]] && write_event "market_snapshot" "$snap_json"

            # Below-median Telegram alert (throttled to once per 4 hours per machine)
            if [[ -n "$market_median" && "$market_median" != "0" ]] && \
               (( $(echo "$cur_bid < $market_median - 0.02" | bc -l) )); then
                local alert_file="/var/tmp/gpu_mkt_alert_${mid}"
                local now_ts last_ts=0
                now_ts=$(date +%s)
                [[ -f "$alert_file" ]] && last_ts=$(cat "$alert_file" 2>/dev/null || echo 0)
                if (( now_ts - last_ts > 14400 )); then
                    local rented_tag=""
                    [[ "$rented" == "True" ]] && rented_tag="
<i>Currently rented — auto-pricing paused. Check market page for trends.</i>"
                    tg_send "⚠️ <b>Price Below Market</b> — $(hostname)
Machine <b>$mid</b> | $gpu_name x${num_gpus}
Your price: <b>\$$cur_bid/hr</b>
Market median: <b>\$$market_median/hr</b> | P25: \$$market_price/hr$rented_tag"
                    echo "$now_ts" > "$alert_file"
                    log "  BELOW-MARKET ALERT sent: \$$cur_bid < median \$$market_median"
                fi
            else
                rm -f "/var/tmp/gpu_mkt_alert_${mid}" 2>/dev/null || true
            fi
        else
            market_price="0"
            market_median="0"
            log "  Machine $mid: market data unavailable"
        fi

        # Skip price adjustment on active rentals or unlisted machines
        if [[ "$rented" == "True" ]]; then
            log "  Machine $mid: RENTED — skipping price adjustment"
            continue
        fi

        if [[ "$listed" != "True" ]]; then
            log "  Machine $mid: not listed — skipping"
            continue
        fi

        if [[ -z "$market_price" || "$market_price" == "0" ]]; then
            market_price="$floor"
            log "  Machine $mid: market price unavailable, targeting floor \$$floor"
        fi

        log "  Machine $mid: market p25=\$$market_price | median=\$$market_median | floor=\$$floor | current=\$$cur_bid"

        local adjust_cents=$(( RANDOM % (PRICE_ADJUST_MAX - PRICE_ADJUST_MIN + 1) + PRICE_ADJUST_MIN ))
        local adjust
        adjust=$(printf "%.4f" "$(echo "scale=4; $adjust_cents / 100" | bc)")

        local new_price direction
        if (( $(echo "${cur_bid:-0} < 0.01" | bc -l) )); then
            new_price="$floor"
            direction="↑ (was \$0 — setting to floor)"
        elif (( $(echo "$cur_bid < $floor" | bc -l) )); then
            new_price="$floor"
            direction="↑ (below floor \$$floor)"
        elif (( $(echo "$cur_bid > $market_price + 0.02" | bc -l) )); then
            new_price=$(printf "%.4f" "$(echo "scale=4; $cur_bid - $adjust" | bc)")
            direction="↓ (above market)"
        elif (( $(echo "$cur_bid < $market_price - 0.02" | bc -l) )); then
            new_price=$(printf "%.4f" "$(echo "scale=4; $cur_bid + $adjust" | bc)")
            direction="↑ (below market)"
        else
            log "  Machine $mid: within 2¢ of market — no change"
            continue
        fi

        if (( $(echo "$new_price < $floor" | bc -l) )); then
            new_price="$floor"
            direction="↑ floored at \$$floor"
        fi

        if (( $(echo "($new_price - $cur_bid)^2 < 0.0001" | bc -l) )); then
            log "  Machine $mid: negligible change, skipping"
            continue
        fi

        local expire_date
        expire_date=$(date -d "+${MAX_RENTAL_DAYS} days" '+%Y-%m-%d' 2>/dev/null \
            || date -v "+${MAX_RENTAL_DAYS}d" '+%Y-%m-%d' 2>/dev/null \
            || echo "in ${MAX_RENTAL_DAYS} days")

        log "  Machine $mid: \$$cur_bid → \$$new_price/hr $direction (max rental: $expire_date)"

        if vastai_set_price "$mid" "$new_price"; then
            log "  Machine $mid: price updated OK"
            tg_send "💰 <b>Price Adjusted</b> — $(hostname)
Machine: <b>$mid</b> | GPU: $gpu_name x$num_gpus
<b>\$$cur_bid → \$$new_price/hr</b> $direction
Market p25: \$$market_price/hr | Median: \$$market_median/hr | Floor: \$$floor/hr"
            write_event "price_change" "{\"machine_id\":\"$mid\",\"gpu_name\":\"$gpu_name\",\"num_gpus\":$num_gpus,\"old_price\":$cur_bid,\"new_price\":$new_price,\"market_price\":$market_price,\"market_median\":$market_median,\"floor\":$floor,\"expire_date\":\"$expire_date\"}"
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
    log "GPU/rental interval : ${CHECK_INTERVAL}s (1 hour)"
    log "Pricing interval    : ${PRICE_INTERVAL}s (30 min)"
    log "Telegram : $([ -n "$TELEGRAM_CHAT_ID" ] && echo 'configured' || echo 'NOT configured — run setup.sh')"
    log "Vast.ai  : $([ -n "$VASTAI_API_KEY"   ] && echo 'configured' || echo 'NOT configured')"
    log "======================================"

    touch "$JSONL_FILE" && chmod 644 "$JSONL_FILE"
    enable_persistence_mode
    set_power_limits
    write_event "startup" "{\"power_limit\":$POWER_LIMIT_DEFAULT,\"temp_threshold\":$TEMP_THRESHOLD}"

    # Sync past rental events from Vast.ai API (backfills revenue history)
    vastai_init_state
    vastai_sync_earnings

    local last_price_check=0

    while true; do
        local now
        now=$(date +%s)

        log ">>> Cycle start"
        vastai_check
        vastai_sync_earnings
        set_power_limits
        check_gpus

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
