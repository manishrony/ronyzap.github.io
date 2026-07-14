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
CHECK_INTERVAL=3600      # 1 hour in seconds (GPU + rental check)

# Per-GPU-model power caps (Watts). Matched by substring against the GPU name
# reported by nvidia-smi (case-insensitive), first match wins. Add a line here
# when a new GPU model joins the fleet — applies automatically host-wide and
# per-GPU on mixed rigs, no per-rig install.sh config needed.
POWER_LIMITS=(
    "5090:500"
    "5080:300"
)
POWER_LIMIT_FALLBACK=500  # used if a GPU's name matches no rule above

# GPU_POWER_LIMIT (optional, via install.sh's power_limit arg) forces every
# GPU on this host to one value, bypassing model detection — manual escape
# hatch for one-off overrides. Leave unset for the dynamic per-model behavior.
# POWER_LIMIT_DEFAULT is only used for the human-readable startup log line.
POWER_LIMIT_DEFAULT="${GPU_POWER_LIMIT:-$POWER_LIMIT_FALLBACK}"
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
    "5090:25"
    "4090:20"
    "4080:15"
    "3090:10"
    "3080:8"
)
PRICE_ADJUST_MIN=1   # minimum cents to move per cycle
PRICE_ADJUST_MAX=5   # maximum cents to move per cycle
MAX_RENTAL_DAYS=5    # max rental duration set on every pricing update

# Vast.ai adds ~15% platform fee before listing; reduce their market prices by this
# factor so we target the real competitive price, not the inflated displayed price.
MARKET_PRICE_DISCOUNT=0.85

# --- GPU count watchdog ---
# 0 = auto-detect from first successful nvidia-smi run; set to e.g. 8 to override
EXPECTED_GPU_COUNT=0

# --- Kaalia log fault monitor ---
KAALIA_LOG="/var/lib/vastai_kaalia/kaalia.log"
KAALIA_POS_FILE="/var/tmp/gpu_monitor_kaalia_pos"
# GPU-hardware fault keywords (triggers 🚨 Telegram alert)
# Use \b word boundaries so "default" does not match "fault"
KAALIA_FAULT_PAT='Xid|xid|\bECC\b|\becc\b|[Tt]hermal|[Tt]hrottl|\bNVML\b|\bnvml\b|\b[Ff]ault\b'
# Verification success keywords (triggers ✅ Telegram alert)
# Require unambiguous past-tense or explicit result words — NOT function names like VerifySendMachInfo
KAALIA_VERIFY_PAT='\bverified\b|\bVerified\b|[Vv]erification.*(pass|success|succeed)|[Pp]assed.*verif|machine.*\bverified\b|\b[Ss]ucceeded\b|self.test.*pass|benchmark.*pass|test.*(pass|succeed)'
# Broader watch patterns (pre-filter before fault/verify check)
KAALIA_WATCH_PAT='[Ee]rror|[Ee]xception|[Tt]raceback|[Xx]id|[Ff]ault|ECC|ecc|[Tt]hrottl|[Tt]hermal|[Dd]egrad|[Oo]ffline|[Dd]enied|[Rr]efused|[Ff]ail|[Cc]rash|[Tt]imeout|[Uu]nreachable|NVML|nvml|\bverified\b|[Vv]erification.*(pass|success)|[Ss]ucceeded|self.test.*pass|benchmark.*pass'
# Known-benign noise to suppress
KAALIA_SUPPRESS_PAT='pci_and_minor_no_info|protected_instances|already Enabled for GPU|assign_conts|assign_and_update_used_gpus|diff_conts|ContainerStats2|nvidia_smi_f|nvidia_smi_nvlink_f|send_nvidia_smi_f|streaming output|apt-select-out|_template_id|SubprocessUnsafe cexec_|docker cp |chmod u=rwX|push_ssh_forwarder|read_state:.*unknown|cexec_: docker |status: created|returned exit code 1'

# Vast.ai self-test / verification activity monitoring.
# Self-test verdicts (PASSED/FAILED) are written to self_test.log, NOT kaalia.log;
# kaalia.log only shows the test container being created (cmd::Create ... self-test).
SELFTEST_LOG="/var/lib/vastai_kaalia/self_test.log"
SELFTEST_POS_FILE="/var/tmp/gpu_monitor_selftest_pos"
# Last self-test instance ID we alerted on (Create lines repeat dozens of times per instance)
SELFTEST_LAST_INSTANCE_FILE="/var/tmp/gpu_monitor_selftest_last_instance"

# --- Listing ancillary prices (applied on every price update) ---
PRICE_INET_UP=0.002    # $/GB upload   (~$2/TB)
PRICE_INET_DOWN=0.002  # $/GB download (~$2/TB)
# price_disk is hardcoded to $0.36/GB/month — never adjusted dynamically

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


# Returns the power cap in watts for a given GPU name, per POWER_LIMITS above.
get_power_limit_for_gpu() {
    local gpu_name="${1^^}"
    local rule pattern watts
    for rule in "${POWER_LIMITS[@]}"; do
        pattern="${rule%%:*}"
        watts="${rule##*:}"
        if [[ "$gpu_name" == *"${pattern^^}"* ]]; then
            echo "$watts"
            return
        fi
    done
    echo "$POWER_LIMIT_FALLBACK"
}

set_power_limits() {
    if [[ -n "$GPU_POWER_LIMIT" ]]; then
        log "Setting all GPUs to ${GPU_POWER_LIMIT}W (manual override via GPU_POWER_LIMIT)..."
        local gpu_count
        gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits | wc -l)
        for (( i=0; i<gpu_count; i++ )); do
            if nvidia-smi -i "$i" --power-limit="$GPU_POWER_LIMIT" >> "$LOG_FILE" 2>&1; then
                log "  GPU $i → ${GPU_POWER_LIMIT}W OK (override)"
            else
                log "  GPU $i power limit ERROR"
            fi
        done
        return
    fi

    log "Setting power limits per GPU model..."
    while IFS=',' read -r idx name; do
        idx=$(echo "$idx" | xargs); name=$(echo "$name" | xargs)
        local watts; watts=$(get_power_limit_for_gpu "$name")
        if nvidia-smi -i "$idx" --power-limit="$watts" >> "$LOG_FILE" 2>&1; then
            log "  GPU $idx ($name) → ${watts}W OK"
        else
            log "  GPU $idx power limit ERROR"
        fi
    done < <(nvidia-smi --query-gpu=index,name --format=csv,noheader)
}

# Effective per-GPU power cap actually in force, read back from nvidia-smi.
# Returns a single integer when all GPUs share a cap (e.g. "300"), or a
# "/"-joined list on mixed rigs (e.g. "300/500"). Used for the startup event
# and log line so the dashboard shows the real cap, not the fallback default.
get_effective_power_limit() {
    local limits
    limits=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null \
        | awk '{printf "%d\n", $1}' | sort -un | paste -sd'/' -)
    [[ -z "$limits" ]] && limits="$POWER_LIMIT_DEFAULT"
    echo "$limits"
}

# Map each GPU index to the compute process using the most memory on it, via
# nvidia-smi. This reveals what's ACTUALLY running (e.g. FahCore_27 =
# Folding@home, SRBMiner = mining, python3 = ML) even when the rental's base
# image (e.g. linux-desktop) doesn't. Populates the associative array named by
# the first arg: <idx> -> <process name>.
build_gpu_proc_map() {
    local -n _map="$1"
    local -A _uuid_idx _best_mem
    local gi guuid pid pname pmem
    # uuid -> index
    while IFS=',' read -r gi guuid; do
        gi="${gi// /}"; guuid="${guuid// /}"
        [[ -n "$guuid" ]] && _uuid_idx["$guuid"]="$gi"
    done < <(nvidia-smi --query-gpu=index,uuid --format=csv,noheader 2>/dev/null)
    # compute apps: keep the highest-memory process per GPU (the workload)
    while IFS=',' read -r guuid pid pname pmem; do
        guuid="$(echo "$guuid" | xargs)"; pname="$(echo "$pname" | xargs)"; pmem="$(echo "$pmem" | xargs)"
        [[ -z "$guuid" ]] && continue
        gi="${_uuid_idx[$guuid]:-}"
        [[ -z "$gi" ]] && continue
        pmem="${pmem//[^0-9]/}"; [[ -z "$pmem" ]] && pmem=0
        pname="$(basename "$pname" 2>/dev/null || echo "$pname")"
        if (( pmem >= ${_best_mem[$gi]:-0} )); then
            _best_mem["$gi"]="$pmem"; _map["$gi"]="$pname"
        fi
    done < <(nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null)

    # Fallback: nvidia-smi --query-compute-apps often returns nothing for
    # processes running inside a renter's container (PID-namespace isolation),
    # even while the GPU is at high load. 'pmon' resolves those names via a
    # different path, so fill any still-empty GPU from a one-shot pmon sample.
    local need_fallback=0 idx0
    while IFS=',' read -r idx0 _; do
        idx0="${idx0// /}"; [[ -z "$idx0" ]] && continue
        [[ -z "${_map[$idx0]:-}" ]] && need_fallback=1
    done < <(nvidia-smi --query-gpu=index,uuid --format=csv,noheader 2>/dev/null)
    if (( need_fallback )); then
        # pmon columns: gpu pid type sm mem enc dec [jpg ofa] command
        # command is the last field; skip '#' header lines and '-' (idle) rows.
        while read -r pgi ppid ptype _rest; do
            [[ "$pgi" == "#" || -z "$pgi" ]] && continue
            [[ "$ppid" == "-" ]] && continue
            local pcmd; pcmd="$(awk '{print $NF}' <<< "$pgi $ppid $ptype $_rest")"
            [[ -z "$pcmd" || "$pcmd" == "-" ]] && continue
            # only fill if compute-apps didn't already name this GPU
            [[ -z "${_map[$pgi]:-}" ]] && _map["$pgi"]="$pcmd"
        done < <(timeout 15 nvidia-smi pmon -c 1 2>/dev/null)
    fi
}

check_gpus() {
    local gpu_data
    gpu_data=$(nvidia-smi \
        --query-gpu=index,name,temperature.gpu,power.draw,power.limit,fan.speed,utilization.gpu \
        --format=csv,noheader,nounits 2>&1) || {
        log "ERROR: nvidia-smi failed: $gpu_data"
        return 1
    }

    local -A gpu_proc
    build_gpu_proc_map gpu_proc

    log "--- GPU Status ---"
    local overtemp=0
    local gpu_count_actual=0
    local gpu_json_arr="["
    local first=1
    while IFS=',' read -r idx name temp power_draw power_limit fan util; do
        idx=$(echo "$idx" | xargs); name=$(echo "$name" | xargs)
        temp=$(echo "$temp" | xargs); power_draw=$(echo "$power_draw" | xargs)
        power_limit=$(echo "$power_limit" | xargs); fan=$(echo "$fan" | xargs)
        util=$(echo "$util" | xargs)
        local proc="${gpu_proc[$idx]:-}"

        log "  GPU $idx | $name | Temp: ${temp}°C | Power: ${power_draw}W/${power_limit}W | Fan: ${fan}% | Util: ${util}%${proc:+ | Proc: $proc}"
        gpu_count_actual=$(( gpu_count_actual + 1 ))

        [[ $first -eq 0 ]] && gpu_json_arr+=","
        gpu_json_arr+="{\"idx\":$idx,\"name\":\"$name\",\"temp\":$temp,\"power_draw\":$power_draw,\"power_limit\":$power_limit,\"fan\":$fan,\"util\":$util,\"proc\":\"$proc\"}"
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

    check_gpu_count "$gpu_count_actual"

    log "--- End GPU Status ---"
}

# ─────────────────────────────────────────────
# GPU fault detection (Xid / NVRM PCIe errors)
# ─────────────────────────────────────────────

# Tracks the dmesg sequence number seen last cycle to avoid re-alerting.
GPU_FAULT_LAST_SEQ_FILE="/var/tmp/gpu_monitor_fault_seq"
GPU_COUNT_STATE_FILE="/var/tmp/gpu_monitor_gpu_count"

# Alert when GPUs silently vanish from PCIe (nvidia-smi reports fewer than expected).
# Called from check_gpus() with the actual detected count.
check_gpu_count() {
    local actual="$1"

    local expected=0
    if [[ "$EXPECTED_GPU_COUNT" -gt 0 ]]; then
        expected="$EXPECTED_GPU_COUNT"
    elif [[ -f "$GPU_COUNT_STATE_FILE" ]]; then
        expected=$(cat "$GPU_COUNT_STATE_FILE" 2>/dev/null || echo 0)
    fi

    if [[ "$expected" -eq 0 ]]; then
        echo "$actual" > "$GPU_COUNT_STATE_FILE"
        log "  GPU count baseline set: $actual GPU(s)"
        return
    fi

    if [[ "$actual" -lt "$expected" ]]; then
        local missing=$(( expected - actual ))
        log "  ⚠️ GPU COUNT MISMATCH: expected $expected, found $actual ($missing missing)"

        # Throttle to once per 4 hours so we don't spam every hourly cycle
        local alert_file="/var/tmp/gpu_count_alert"
        local now_ts last_ts=0
        now_ts=$(date +%s)
        [[ -f "$alert_file" ]] && last_ts=$(cat "$alert_file" 2>/dev/null || echo 0)
        if (( now_ts - last_ts > 14400 )); then
            local msg
            msg="GPU count dropped: expected ${expected}, found only ${actual} (${missing} GPU(s) missing from PCIe)"
            local escaped
            escaped=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$msg" 2>/dev/null || echo "\"$msg\"")
            write_event "gpu_fault" "{\"message\":${escaped},\"gpu_hint\":\"GPU_MISSING\"}"
            tg_send "🚨 <b>GPU(s) Missing — $(hostname)</b>
Expected: <b>${expected} GPUs</b>  |  Detected: <b>${actual} GPUs</b>
<b>${missing} GPU(s) disappeared from PCIe!</b>
Check dmesg for Xid/badf errors. Physical reboot may be required."
            echo "$now_ts" > "$alert_file"
        fi
    elif [[ "$actual" -gt "$expected" ]]; then
        log "  GPU count increased: $expected → $actual (updating baseline)"
        echo "$actual" > "$GPU_COUNT_STATE_FILE"
        rm -f "/var/tmp/gpu_count_alert" 2>/dev/null || true
    fi
}

check_gpu_faults() {
    # Read last seen dmesg sequence number (or 0 on first run)
    local last_seq=0
    [[ -f "$GPU_FAULT_LAST_SEQ_FILE" ]] && last_seq=$(cat "$GPU_FAULT_LAST_SEQ_FILE" 2>/dev/null || echo 0)

    # Grab dmesg with sequence numbers, filter to only new entries
    local new_faults
    new_faults=$(dmesg --notime --level=err,warn --facility=kern 2>/dev/null \
        | grep -iE "NVRM|Xid|badf[0-9a-f]{4}|gpu.*error|gpuHandleSanityCheck" \
        || true)

    # Also scan without level filter in case NVRM logs as info
    local nvrm_faults
    nvrm_faults=$(dmesg -T 2>/dev/null \
        | grep -iE "Xid \(|badf[0-9a-f]{4}|gpuHandleSanityCheck|NVRM:.*error|NVRM:.*fault|NVRM:.*GPU[0-9]" \
        | tail -20 \
        || true)

    # Save current dmesg line count as new watermark
    local cur_count
    cur_count=$(dmesg 2>/dev/null | wc -l || echo 0)

    # Only alert on lines beyond last watermark
    if [[ "$cur_count" -le "$last_seq" ]]; then
        echo "$cur_count" > "$GPU_FAULT_LAST_SEQ_FILE"
        return
    fi

    local new_lines
    new_lines=$(dmesg 2>/dev/null | tail -n +"$((last_seq + 1))" \
        | grep -iE "Xid \(|badf[0-9a-f]{4}|gpuHandleSanityCheck|NVRM:.*error|NVRM:.*fault|NVRM:.*GPU[0-9]" \
        || true)

    echo "$cur_count" > "$GPU_FAULT_LAST_SEQ_FILE"

    [[ -z "$new_lines" ]] && return

    log "  GPU FAULT DETECTED in dmesg:"
    while IFS= read -r fault_line; do
        [[ -z "$fault_line" ]] && continue
        log "    $fault_line"

        # Extract GPU index hint if present
        local gpu_hint=""
        if echo "$fault_line" | grep -qiE "GPU([0-9]+)"; then
            gpu_hint=$(echo "$fault_line" | grep -oiE "GPU[0-9]+" | head -1)
        fi

        # Write dashboard event
        local escaped
        escaped=$(echo "$fault_line" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo "\"$fault_line\"")
        write_event "gpu_fault" "{\"message\":${escaped},\"gpu_hint\":\"${gpu_hint}\"}"

        # Telegram alert
        tg_send "⚠️ <b>GPU Fault — $(hostname)</b>
${gpu_hint:+GPU: <b>$gpu_hint</b>
}$(echo "$fault_line" | head -c 300)"
    done <<< "$new_lines"
}

check_kaalia_faults() {
    [[ ! -f "$KAALIA_LOG" ]] && return

    local cur_size
    cur_size=$(wc -c < "$KAALIA_LOG" 2>/dev/null || echo 0)

    # First run: set watermark to current end of file, skip historical content
    if [[ ! -f "$KAALIA_POS_FILE" ]]; then
        echo "$cur_size" > "$KAALIA_POS_FILE"
        log "  Kaalia fault monitor: watermark set to byte $cur_size (skipping history)"
        return
    fi

    local last_pos
    last_pos=$(cat "$KAALIA_POS_FILE" 2>/dev/null || echo 0)

    # Handle log rotation — file shrank
    [[ "$cur_size" -lt "$last_pos" ]] && last_pos=0

    # Nothing new
    if [[ "$cur_size" -le "$last_pos" ]]; then
        echo "$cur_size" > "$KAALIA_POS_FILE"
        return
    fi

    # Read only new bytes since last check
    local new_content
    new_content=$(tail -c +"$((last_pos + 1))" "$KAALIA_LOG" 2>/dev/null || true)
    echo "$cur_size" > "$KAALIA_POS_FILE"

    [[ -z "$new_content" ]] && return

    # Pre-filter: lines that match WATCH and are not suppressed
    local filtered
    filtered=$(echo "$new_content" \
        | grep -E "$KAALIA_WATCH_PAT" \
        | grep -Ev "$KAALIA_SUPPRESS_PAT" \
        || true)

    [[ -z "$filtered" ]] && return

    # --- GPU-HW faults → 🚨 alert ---
    local faults
    faults=$(echo "$filtered" | grep -E "$KAALIA_FAULT_PAT" || true)
    if [[ -n "$faults" ]]; then
        local fault_count first_fault
        fault_count=$(echo "$faults" | wc -l)
        first_fault=$(echo "$faults" | head -1)
        log "  ⚠️ Kaalia GPU fault(s): $fault_count new line(s)"
        log "    $first_fault"
        local escaped
        escaped=$(echo "$first_fault" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo "\"$first_fault\"")
        write_event "gpu_fault" "{\"message\":${escaped},\"gpu_hint\":\"KAALIA_FAULT\"}"
        tg_send "🚨 <b>Kaalia GPU Fault — $(hostname)</b>
<b>${fault_count} fault line(s)</b> in kaalia.log
<code>$(echo "$first_fault" | head -c 350)</code>"
    fi

    # --- Verification success → ✅ alert ---
    local verified
    verified=$(echo "$filtered" | grep -E "$KAALIA_VERIFY_PAT" | grep -Ev "[Ff]ail|[Ee]rror|null|skip|receiv" || true)
    if [[ -n "$verified" ]]; then
        local first_ver
        first_ver=$(echo "$verified" | head -1)
        log "  ✅ Kaalia verification success detected"
        log "    $first_ver"
        tg_send "✅ <b>Vast.ai Verification — $(hostname)</b>
<code>$(echo "$first_ver" | head -c 350)</code>"
    fi

    # --- Self-test instance created → 🧪 alert (once per instance) ---
    # kaalia.log shows dozens of repeated "cmd::Create( name: C.xxx ... self-test" lines
    # per test; dedupe on the instance ID so we alert exactly once.
    local st_instance
    st_instance=$(echo "$new_content" \
        | grep -oE 'cmd::Create\( name: (C\.[0-9]+)[^)]*self-test' \
        | grep -oE 'C\.[0-9]+' | head -1 || true)
    if [[ -n "$st_instance" ]]; then
        local last_instance=""
        [[ -f "$SELFTEST_LAST_INSTANCE_FILE" ]] && last_instance=$(cat "$SELFTEST_LAST_INSTANCE_FILE" 2>/dev/null || true)
        if [[ "$st_instance" != "$last_instance" ]]; then
            echo "$st_instance" > "$SELFTEST_LAST_INSTANCE_FILE"
            log "  🧪 Vast.ai self-test instance created: $st_instance"
            write_event "selftest_start" "{\"instance\":\"$st_instance\"}"
            tg_send "🧪 <b>Vast.ai Self-Test Started — $(hostname)</b>
Instance <code>$st_instance</code> launched by Vast. Result alert follows when it finishes."
        fi
    fi
}

# Watch self_test.log for verdicts (PASSED/FAILED). Results are written here,
# not to kaalia.log, so the kaalia watcher alone never sees them.
check_selftest_log() {
    [[ ! -f "$SELFTEST_LOG" ]] && return

    local cur_size
    cur_size=$(wc -c < "$SELFTEST_LOG" 2>/dev/null || echo 0)

    # First run: skip history
    if [[ ! -f "$SELFTEST_POS_FILE" ]]; then
        echo "$cur_size" > "$SELFTEST_POS_FILE"
        log "  Self-test monitor: watermark set to byte $cur_size (skipping history)"
        return
    fi

    local last_pos
    last_pos=$(cat "$SELFTEST_POS_FILE" 2>/dev/null || echo 0)
    [[ "$cur_size" -lt "$last_pos" ]] && last_pos=0
    if [[ "$cur_size" -le "$last_pos" ]]; then
        echo "$cur_size" > "$SELFTEST_POS_FILE"
        return
    fi

    local new_content
    new_content=$(tail -c +"$((last_pos + 1))" "$SELFTEST_LOG" 2>/dev/null || true)
    echo "$cur_size" > "$SELFTEST_POS_FILE"
    [[ -z "$new_content" ]] && return

    if echo "$new_content" | grep -q "Self-test PASSED"; then
        log "  🧪✅ Self-test PASSED"
        write_event "selftest_result" "{\"result\":\"passed\"}"
        tg_send "🧪✅ <b>Vast.ai Self-Test PASSED — $(hostname)</b>
All tests completed successfully. Verification should progress."
    elif echo "$new_content" | grep -qE "Self-test FAILED|Self-test exit code: [^0]"; then
        local detail
        detail=$(echo "$new_content" | grep -E "Self-test FAILED|Self-test exit code:|ERROR|error" | head -2 || true)
        log "  🧪❌ Self-test FAILED"
        write_event "selftest_result" "{\"result\":\"failed\"}"
        tg_send "🧪❌ <b>Vast.ai Self-Test FAILED — $(hostname)</b>
<code>$(echo "$detail" | head -c 350)</code>"
    elif echo "$new_content" | grep -q "Starting self-test"; then
        log "  🧪 Self-test starting (self_test.log)"
    fi
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

    local response tmpfile slots_tmpfile
    response=$(vastai_get "$VASTAI_API/machines/") || {
        log "VAST.AI INIT: API call failed — skipping startup scan"
        return
    }

    tmpfile=$(mktemp)
    echo "$response" > "$tmpfile"

    slots_tmpfile=$(mktemp)
    vastai_fetch_gpu_slots > "$slots_tmpfile"

    python3 - "$tmpfile" "$JSONL_FILE" "$slots_tmpfile" <<'PYEOF' 2>/dev/null >> "$LOG_FILE" || true
import sys, json, datetime, socket, glob, re

tmpf, jsonl, slots_f = sys.argv[1], sys.argv[2], sys.argv[3]

def get_instance_image(instance_id):
    if not instance_id:
        return ''
    pattern = re.compile(r'name: C\.' + re.escape(str(instance_id)) + r'  base_image_: (\S+)')
    last = ''
    for path in glob.glob('/var/lib/vastai_kaalia/kaalia.log*'):
        try:
            with open(path, errors='ignore') as f:
                for line in f:
                    m = pattern.search(line)
                    if m:
                        last = m.group(1)
        except Exception:
            pass
    return last

def classify_workload(image):
    img = (image or '').lower()
    if not img:
        return 'unknown'
    if 'self-test' in img:
        return 'selftest'
    if any(k in img for k in ('srbminer', 'xmrig', 'nbminer', 't-rex', 'phoenixminer', 'lolminer', 'gminer', 'teamredminer')):
        return 'mining'
    if any(k in img for k in ('jupyter', 'linux-desktop', 'vscode', 'desktop', 'vnc')):
        return 'desktop'
    if any(k in img for k in ('llama', 'vllm', 'ollama', 'text-generation', 'tgi', 'triton', 'comfyui', 'stable-diffusion', 'automatic1111')):
        return 'inference'
    if any(k in img for k in ('pytorch', 'tensorflow', 'axolotl', 'unsloth', 'deepspeed', 'train')):
        return 'training'
    return 'unknown'

try:
    with open(tmpf) as f:
        data = json.load(f)
except Exception as e:
    print(f"[INIT] JSON parse error: {e}")
    sys.exit(0)

try:
    with open(slots_f) as f:
        slots_by_machine = json.load(f)
except Exception:
    slots_by_machine = {}

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
    cur_bid  = float(m.get('listed_gpu_cost') or m.get('min_bid_price', m.get('min_bid', 0)) or 0)

    # Prefer the actual total $/hr being earned (sum of rented instances' real
    # dph_total) over the per-GPU listed price — otherwise a partial rental
    # (e.g. 4 of 8 GPUs) gets backfilled at the single-GPU rate and the
    # dashboard's revenue math undercounts by the number of GPUs rented.
    rented_slots = [s for s in slots_by_machine.get(mid, {}).values() if s.get('instance_id')]
    if rented_slots:
        cur_bid = sum(float(s.get('rate', 0) or 0) for s in rented_slots)

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

    real_iid = rented_slots[0]['instance_id'] if rented_slots else ''
    image = get_instance_image(real_iid)
    workload_type = classify_workload(image)

    # Report GPUs actually rented, not the machine total — a partial rental
    # (4 of 8) should read "4x RTX 5090", matching the live vastai_check() path.
    rented_count = len(rented_slots) if rented_slots else num_gpus
    gpus_str = f'{rented_count}x {gpu_name}'

    event = {
        'ts':              now_str,
        'type':            'rental_start',
        'host':            socket.gethostname(),
        'machine_id':      mid,
        'instance_id':     mid,
        'real_instance_id': real_iid,
        'gpus':            gpus_str,
        'rate':            f'${cur_bid:.3f}/hr',
        'status':          'running',
        'backfilled':      True,
        'image':           image,
        'workload_type':   workload_type,
    }
    with open(jsonl, 'a') as f:
        f.write(json.dumps(event) + '\n')
    print(f"[INIT] Backfilled rental_start: machine {mid} ({gpus_str} @ ${cur_bid:.3f}/hr, {workload_type}: {image or 'unknown'})")
    count += 1

if not count:
    print("[INIT] No backfill needed — no newly rented machines")
PYEOF

    rm -f "$tmpfile" "$slots_tmpfile"
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

# Fetch per-GPU rental slot assignments from instances API.
# Returns JSON: {"<machine_id>": {"<gpu_idx>": {"instance_id":"C.x","rate":0.42}, ...}}
vastai_fetch_gpu_slots() {
    local raw
    # Try cloud then console — instances endpoint works with API key auth
    for base in "https://console.vast.ai" "https://cloud.vast.ai"; do
        raw=$(curl -sf -H "Authorization: Bearer ${VASTAI_API_KEY}" \
            "${base}/api/v0/instances/?api_key=${VASTAI_API_KEY}" 2>/dev/null || true)
        [[ -n "$raw" ]] && break
    done
    [[ -z "$raw" ]] && echo "{}" && return

    python3 -c "
import json, sys, socket
try:
    data = json.loads(sys.stdin.read())
    hn = socket.gethostname()
    instances = data.get('instances', data if isinstance(data, list) else [])
    result = {}
    for inst in instances:
        mid = str(inst.get('machine_id', inst.get('machine', '')))
        if not mid:
            continue
        # gpu_ids is a list of GPU slot indices used by this instance
        gpu_ids = inst.get('gpu_ids', inst.get('gpus', []))
        if not gpu_ids:
            # Fall back: assume starts at slot 0 for num_gpus count
            n = int(inst.get('num_gpus', 1) or 1)
            gpu_ids = list(range(n))
        rate = float(inst.get('dph_total', inst.get('dph_base', 0)) or 0)
        iid  = str(inst.get('id', ''))
        if mid not in result:
            result[mid] = {}
        for g in gpu_ids:
            result[mid][str(g)] = {'instance_id': iid, 'rate': round(rate / max(len(gpu_ids),1), 4)}
    print(json.dumps(result))
except Exception as e:
    import sys as _s; _s.stderr.write(str(e)+'\n')
    print('{}')
" <<< "$raw" 2>/dev/null || echo "{}"
}

# Look up the Docker image an instance is running, from vastai_kaalia's own
# create-container log lines (same source vast-activity uses). Best-effort —
# kaalia.log rotates, so older instances may not be found.
get_instance_image() {
    local instance_id="$1"
    [[ -z "$instance_id" ]] && return
    grep -ahoE "name: C\.${instance_id}  base_image_: [^ ]+" \
        /var/lib/vastai_kaalia/kaalia.log* 2>/dev/null \
        | tail -1 \
        | sed -E 's/.*base_image_: //'
}

# Classify a Docker image string into a coarse workload bucket for the
# rental-analysis dashboard. Vast.ai does not expose renter identity, so
# image name is the only signal available for "what's this rental doing".
classify_workload() {
    local image="${1,,}"
    [[ -z "$image" ]] && { echo "unknown"; return; }
    case "$image" in
        *self-test*)                                                  echo "selftest" ;;
        *srbminer*|*xmrig*|*nbminer*|*t-rex*|*phoenixminer*|*lolminer*|*gminer*|*teamredminer*) echo "mining" ;;
        *jupyter*|*linux-desktop*|*vscode*|*desktop*|*vnc*)            echo "desktop" ;;
        *llama*|*vllm*|*ollama*|*text-generation*|*tgi*|*triton*|*comfyui*|*stable-diffusion*|*automatic1111*) echo "inference" ;;
        *pytorch*|*tensorflow*|*axolotl*|*unsloth*|*deepspeed*|*train*) echo "training" ;;
        *) echo "unknown" ;;
    esac
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

    # Fetch per-GPU slot assignments from instances API
    local gpu_slots_json
    gpu_slots_json=$(vastai_fetch_gpu_slots)

    # State: one line per machine: {mid}|{rented}|{num_gpus}x{gpu_name}|{bid}/hr|{real_instance_id}
    # {bid} is the ACTUAL total $/hr being earned (sum of rented instances' real
    # dph_total from gpu_slots_json), not the per-GPU listed price — otherwise a
    # partial rental (e.g. 4 of 8 GPUs) would record only the single-GPU rate and
    # the dashboard's revenue math would undercount by the number of GPUs rented.
    # {real_instance_id} is Vast's actual numeric instance id (not the machine id)
    # — used to look up the rental's Docker image for workload classification.
    local current_state
    current_state=$(python3 -c "
import sys, json, socket
slots_by_machine = json.loads(sys.argv[1])
data = json.loads(sys.argv[2])
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
    per_gpu_price = float(m.get('listed_gpu_cost') or m.get('min_bid_price', m.get('min_bid', 0)) or 0)

    rented_slots = [s for s in slots_by_machine.get(str(mid), {}).values() if s.get('instance_id')]
    actual_rate = sum(float(s.get('rate', 0) or 0) for s in rented_slots)
    real_iid = rented_slots[0]['instance_id'] if rented_slots else ''
    rented_count = len(rented_slots)

    cost_val = actual_rate if (rented and rented_slots) else per_gpu_price
    # Field 3 keeps the TOTAL gpu count (num_gpus) — the per-GPU slot renderer
    # needs it to draw every physical slot. Field 6 is how many are actually
    # rented, used for the Telegram/dashboard 'GPUs rented' display so a partial
    # rental (e.g. 4 of 8) doesn't misreport as the whole machine.
    lines.append(f'{mid}|{rented}|{num_gpus}x {gpu_name}|\${cost_val:.3f}/hr|{real_iid}|{rented_count}')
print('\n'.join(lines))
" "$gpu_slots_json" "$response" 2>/dev/null) || { log "VAST.AI: Parse error"; return; }

    local last_state=""
    [[ -f "$VASTAI_LAST_STATE_FILE" ]] && last_state=$(cat "$VASTAI_LAST_STATE_FILE")

    if [[ "$current_state" != "$last_state" ]]; then
        log "VAST.AI: Machine state changed"

        # Check each current machine for rental status changes
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            IFS='|' read -r mid rented gpus cost real_iid rented_count <<< "$line"

            # GPUs actually rented (e.g. "4x RTX 5090"), not the whole machine.
            # gpus is "8x RTX 5090"; strip the count and prepend the rented count.
            local gpu_model rented_gpus
            gpu_model="${gpus#*x }"
            if [[ "$rented" == "True" && "${rented_count:-0}" -gt 0 ]]; then
                rented_gpus="${rented_count}x ${gpu_model}"
            else
                rented_gpus="$gpus"
            fi

            local old_line
            old_line=$(grep "^${mid}|" "$VASTAI_LAST_STATE_FILE" 2>/dev/null || true)

            if [[ -z "$old_line" ]]; then
                # Machine not in state file yet — just log current status.
                # vastai_init_state() already backfilled rental_start on startup.
                log "VAST.AI: Machine $mid | $rented_gpus | $cost | Rented: $rented (first seen)"
            else
                local old_rented old_cost old_rented_count
                IFS='|' read -r _ old_rented _ old_cost _ old_rented_count <<< "$old_line"
                if [[ "$old_rented" != "$rented" ]]; then
                    if [[ "$rented" == "True" ]]; then
                        local image workload_type
                        image=$(get_instance_image "$real_iid")
                        workload_type=$(classify_workload "$image")
                        log "VAST.AI: Machine $mid — rental STARTED ($rented_gpus, $workload_type: ${image:-unknown})"
                        tg_send "✅ <b>Vast.ai Rental STARTED</b> — $(hostname)
Machine: <b>$mid</b> | GPUs rented: $rented_gpus
Rate: <b>$cost</b>"
                        write_event "rental_start" "{\"machine_id\":\"$mid\",\"instance_id\":\"$mid\",\"real_instance_id\":\"$real_iid\",\"gpus\":\"$rented_gpus\",\"rate\":\"$cost\",\"status\":\"running\",\"image\":\"$image\",\"workload_type\":\"$workload_type\"}"
                    else
                        # Rental just ended — current rented_count is 0, so report
                        # what WAS rented (from the prior state) for a consistent
                        # "4x RTX 5090 ended" instead of the machine total.
                        local ended_gpus="$gpus"
                        [[ "${old_rented_count:-0}" -gt 0 ]] && ended_gpus="${old_rented_count}x ${gpu_model}"
                        log "VAST.AI: Machine $mid — rental ENDED ($ended_gpus)"
                        tg_send "🔴 <b>Vast.ai Rental ENDED</b> — $(hostname)
Machine: <b>$mid</b> | GPUs freed: $ended_gpus
Last rate: ${old_cost:-$cost}"
                        write_event "rental_end" "{\"machine_id\":\"$mid\",\"instance_id\":\"$mid\",\"gpus\":\"$ended_gpus\",\"rate\":\"${old_cost:-$cost}\",\"status\":\"ended\"}"
                    fi
                fi
            fi
        done <<< "$current_state"

        # Check for machines that disappeared while rented
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            IFS='|' read -r mid old_rented gpus cost _ old_rented_count <<< "$line"
            if ! echo "$current_state" | grep -q "^${mid}|"; then
                if [[ "$old_rented" == "True" ]]; then
                    local gone_gpus="$gpus"
                    [[ "${old_rented_count:-0}" -gt 0 ]] && gone_gpus="${old_rented_count}x ${gpus#*x }"
                    log "VAST.AI: Machine $mid disappeared while rented ($gone_gpus)"
                    write_event "rental_end" "{\"machine_id\":\"$mid\",\"instance_id\":\"$mid\",\"gpus\":\"$gone_gpus\",\"rate\":\"$cost\",\"status\":\"gone\"}"
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
                IFS='|' read -r mid rented gpus cost _ rented_count <<< "$line"
                local disp="$gpus"
                [[ "$rented" == "True" && "${rented_count:-0}" -gt 0 ]] && disp="${rented_count}x ${gpus#*x } (of ${gpus%%x*})"
                log "  Machine $mid | $disp | $cost | Rented: $rented"
            done <<< "$current_state"
        else
            log "VAST.AI: No machines found."
        fi
    fi

    # Write per-GPU rental status event every cycle (for dashboard GPU cards)
    if [[ -n "$current_state" && -n "$gpu_slots_json" && "$gpu_slots_json" != "{}" ]]; then
        echo "$current_state" | while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            IFS='|' read -r mid rented gpus cost _ _ <<< "$line"
            local slot_event
            slot_event=$(python3 -c "
import json, sys
slots = json.loads(sys.argv[1]).get(sys.argv[2], {})
total = int(sys.argv[3])
gpu_name = sys.argv[4]
rows = []
for i in range(total):
    s = slots.get(str(i))
    rows.append({'gpu_idx': i, 'rented': bool(s),
                 'instance_id': s['instance_id'] if s else None,
                 'rate': s['rate'] if s else 0})
print(json.dumps({'machine_id': sys.argv[2], 'gpu_name': gpu_name,
                  'total_gpus': total, 'slots': rows}))
" "$gpu_slots_json" "$mid" "${gpus%%x*}" "${gpus##*x }" 2>/dev/null || true)
            [[ -n "$slot_event" ]] && write_event "gpu_rental_status" "$slot_event"
        done
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
    # Confirmed working format: operator-style {"eq":...} inside q parameter.
    local encoded_q
    encoded_q=$(python3 -c "
import urllib.parse, json, sys
q = json.dumps({'gpu_name': {'eq': sys.argv[1]}, 'rentable': {'eq': True}})
print(urllib.parse.quote(q))
" "$gpu_name" 2>/dev/null || echo "")
    local raw=""
    for base_url in "https://cloud.vast.ai/api/v0/bundles" "https://console.vast.ai/api/v0/bundles"; do
        local url="${base_url}/?q=${encoded_q}"
        raw=$(vastai_get "$url" 2>/dev/null || true)
        local n
        n=$(echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('offers',d.get('bundles',[]))))" 2>/dev/null || echo "0")
        [[ "$n" -gt 0 ]] && break
        raw=""
    done
    if [[ -z "$raw" ]]; then
        log "  market_stats: bundles API returned no data for '$gpu_name'"
        echo "null"; return
    fi
    # Write raw JSON to a temp file — avoids bash stdin conflict between pipe and heredoc.
    # "echo $raw | python3 - <<'PYEOF'" causes heredoc to win over pipe, leaving stdin empty.
    local raw_file
    raw_file=$(mktemp)
    printf '%s' "$raw" > "$raw_file"
    python3 - "$gpu_name" "$raw_file" <<'PYEOF' 2>>"$LOG_FILE"
import sys, json
try:
    with open(sys.argv[2]) as _f:
        data = json.load(_f)
    gpu_filter = sys.argv[1].upper() if len(sys.argv) > 1 else ''
    offers = data.get('offers', data.get('instances', data.get('bundles', [])))
    if not offers:
        sys.stderr.write(f'market_stats: no offers key; got keys={list(data.keys())[:8]}\n')
    # Filter by GPU name similarity when the API returned unfiltered results
    if gpu_filter:
        offers = [o for o in offers if gpu_filter in str(o.get('gpu_name', '')).upper()]
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
PYEOF
    rm -f "$raw_file"
}

vastai_set_price() {
    local machine_id="$1"
    local new_price="$2"
    local floor_price="${3:-0.10}"
    local http_code tmpf resp end_ts body
    new_price=$(printf "%.4f" "$new_price")
    floor_price=$(printf "%.4f" "$floor_price")
    tmpf=$(mktemp)

    # Listing end = now + MAX_RENTAL_DAYS (Unix epoch). Extends the listing on every price update.
    end_ts=$(date -d "+${MAX_RENTAL_DAYS} days" '+%s' 2>/dev/null || \
             python3 -c "import time; print(int(time.time() + ${MAX_RENTAL_DAYS}*86400))" 2>/dev/null || \
             echo "0")

    body=$(python3 -c "
import json, sys
obj = {
    'machine':            int(sys.argv[1]),
    'price_gpu':          float(sys.argv[2]),
    'price_disk':         0.36,
    'price_inetu':        float(sys.argv[5]),
    'price_inetd':        float(sys.argv[6]),
    'price_min_bid':      float(sys.argv[3]),
    'min_chunk':          1,
    'end_date':           int(sys.argv[4]) if sys.argv[4] != '0' else None,
    'credit_discount_max': 0,
}
print(json.dumps(obj))
" "$machine_id" "$new_price" "$floor_price" "$end_ts" \
  "$PRICE_INET_UP" "$PRICE_INET_DOWN" 2>/dev/null)

    if [[ -z "$body" ]]; then
        log "  ERROR: could not build create_asks body"; rm -f "$tmpf"; return 1
    fi

    # PUT /api/v0/machines/create_asks/ sets the on-demand listing price
    # (the blue-button price in the Vast.ai console). Confirmed correct endpoint.
    for base in "https://console.vast.ai" "https://cloud.vast.ai"; do
        http_code=$(curl -s -o "$tmpf" -w "%{http_code}" -X PUT \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${VASTAI_API_KEY}" \
            -d "$body" \
            "${base}/api/v0/machines/create_asks/?api_key=${VASTAI_API_KEY}" 2>/dev/null)
        resp=$(head -c 300 "$tmpf" 2>/dev/null)
        log "  PUT ${base##*/}/create_asks/ HTTP ${http_code}: ${resp:0:200}"
        if [[ "$http_code" =~ ^2 ]]; then rm -f "$tmpf"; return 0; fi
    done

    rm -f "$tmpf"
    return 1
}

vastai_pricing() {
    [[ -z "$VASTAI_API_KEY" ]] && return

    log "--- Pricing Check ---"

    local machines_json
    machines_json=$(vastai_get_machines) || { log "PRICING: Could not fetch machines"; return; }

    # Write machine list to temp file; reading from a file (not a pipe) keeps the
    # while loop in the current shell — functions, write_event, and variable
    # assignments all work correctly without subshell interference.
    local tmpfile
    tmpfile=$(mktemp)
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
    # listed_gpu_cost is the on-demand listing price (the blue-button price in Vast.ai console).
    # min_bid_price is the interruptible bid floor — use as fallback only.
    listed_v  = m.get('listed_gpu_cost')
    min_bid_v = m.get('min_bid_price', m.get('min_bid', 0))
    cur_bid   = float(listed_v or min_bid_v or 0)
    num_gpus = m.get('num_gpus', 1)
    print(f'{mid}|{rented}|{listed}|{gpu_name}|{cur_bid}|{num_gpus}')
" 2>> "$LOG_FILE" > "$tmpfile"

    while IFS='|' read -r mid rented listed gpu_name cur_bid num_gpus; do

        [[ -z "$mid" ]] && continue

        # Round cur_bid to 4 decimal places to avoid floating point noise in logs/events
        cur_bid=$(printf "%.4f" "$cur_bid" 2>/dev/null || echo "$cur_bid")

        log "  Machine $mid | GPU: $gpu_name x$num_gpus | Listed: $listed | Rented: $rented | Bid: \$$cur_bid/hr"

        local floor
        floor=$(get_price_floor "$gpu_name")

        # Fetch market stats; parse p25 + median in one Python call (avoids
        # quoting fragility of separate inline python -c expressions)
        local stats_json market_price market_median
        stats_json=$(vastai_market_stats "$gpu_name")

        if [[ -n "$stats_json" && "$stats_json" != "null" ]]; then
            local mraw
            mraw=$(python3 - "$stats_json" <<'PYEOF' 2>/dev/null
import json, sys
d = json.loads(sys.argv[1])
print(f"{d.get('p25', 0):.4f}")
print(f"{d.get('median', 0):.4f}")
PYEOF
)
            market_price=$(printf '%s\n' "$mraw" | sed -n '1p')
            market_median=$(printf '%s\n' "$mraw" | sed -n '2p')
            [[ -z "$market_price"  ]] && market_price="0"
            [[ -z "$market_median" ]] && market_median="0"

            # Vast.ai displays prices with ~15% platform markup already baked in.
            # Discount our target so we compete at the real post-fee price.
            if [[ "${MARKET_PRICE_DISCOUNT:-1}" != "1" && "$market_price" != "0" ]]; then
                market_price=$(printf "%.4f" "$(echo "scale=4; $market_price * $MARKET_PRICE_DISCOUNT" | bc)")
                market_median=$(printf "%.4f" "$(echo "scale=4; $market_median * $MARKET_PRICE_DISCOUNT" | bc)")
                log "  Machine $mid: market prices after ${MARKET_PRICE_DISCOUNT} discount → p25=\$$market_price median=\$$market_median"
            fi

            # Write market_snapshot event — pass JSON via argv to avoid shell quoting issues
            local snap_json
            snap_json=$(python3 - "$stats_json" "$mid" "$gpu_name" "$num_gpus" "$cur_bid" <<'PYEOF' 2>/dev/null
import json, sys
stats   = json.loads(sys.argv[1])
mid_v   = sys.argv[2]
gpu_n   = sys.argv[3]
n_gpus  = int(sys.argv[4])
my_p    = float(sys.argv[5])
stats.update({
    'machine_id':   mid_v,
    'gpu_name':     gpu_n,
    'num_gpus':     n_gpus,
    'my_price':     my_p,
    'below_median': my_p < stats.get('median', 99),
})
print(json.dumps(stats))
PYEOF
)
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

        # Skip unlisted machines (fully rented machines auto-unlist on Vast.ai)
        if [[ "$listed" != "True" ]]; then
            log "  Machine $mid: not listed — skipping price adjustment"
            continue
        fi
        # Active rental (full or partial) — don't touch price. Renters lock in
        # the rate they started at; changing it mid-rental is surprising and,
        # for on-demand listings, can look like a bait-and-switch.
        if [[ "$rented" == "True" ]]; then
            log "  Machine $mid: active rental — skipping price adjustment"
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

        if vastai_set_price "$mid" "$new_price" "$floor"; then
            log "  Machine $mid: price updated OK"
            tg_send "💰 <b>Price Adjusted</b> — $(hostname)
Machine: <b>$mid</b> | GPU: $gpu_name x$num_gpus
<b>\$$cur_bid → \$$new_price/hr</b> $direction
Market p25: \$$market_price/hr | Median: \$$market_median/hr | Floor: \$$floor/hr"
            write_event "price_change" "{\"machine_id\":\"$mid\",\"gpu_name\":\"$gpu_name\",\"num_gpus\":$num_gpus,\"old_price\":$cur_bid,\"new_price\":$new_price,\"market_price\":$market_price,\"market_median\":$market_median,\"floor\":$floor,\"expire_date\":\"$expire_date\"}"
        else
            log "  Machine $mid: price update FAILED"
        fi

    done < "$tmpfile"

    rm -f "$tmpfile"
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
    if [[ -n "$GPU_POWER_LIMIT" ]]; then
        log "Power limit         : ${GPU_POWER_LIMIT}W per GPU (manual override)"
    else
        log "Power limit         : per-model (5090=500W, 5080=300W, fallback=${POWER_LIMIT_FALLBACK}W)"
    fi
    log "Temp threshold      : ${TEMP_THRESHOLD}°C"
    log "GPU/rental interval : ${CHECK_INTERVAL}s (1 hour)"
    log "Pricing interval    : ${PRICE_INTERVAL}s (30 min)"
    log "Telegram : $([ -n "$TELEGRAM_CHAT_ID" ] && echo 'configured' || echo 'NOT configured — run setup.sh')"
    log "Vast.ai  : $([ -n "$VASTAI_API_KEY"   ] && echo 'configured' || echo 'NOT configured')"
    log "======================================"

    touch "$JSONL_FILE" && chmod 644 "$JSONL_FILE"
    enable_persistence_mode
    set_power_limits
    # Report the power cap actually applied (read back from nvidia-smi), so the
    # dashboard shows 300 on an RTX 5080 rig rather than the 500 fallback.
    local effective_power_limit
    effective_power_limit=$(get_effective_power_limit)
    log "Effective power cap : ${effective_power_limit}W (read back from nvidia-smi)"
    write_event "startup" "{\"power_limit\":\"$effective_power_limit\",\"temp_threshold\":$TEMP_THRESHOLD}"

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
        check_gpu_faults
        check_kaalia_faults
        check_selftest_log

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
