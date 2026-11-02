#!/usr/bin/env bash
#
# xid79-autoreboot.sh — zappa1-only. Tails the kernel log for the confirmed
# Xid 79 ("GPU has fallen off the bus") + Xid 154 recovery-action-required
# signature and reboots automatically, instead of waiting for a human to see
# the Telegram alert and SSH in.
#
# Why zappa1 only: zappa2 has a BMC with its own hardware watchdog, so an OS
# that wedges gets power-cycled regardless. zappa1 has no IPMI/BMC access
# (confirmed 2026-10) -- if the OS doesn't reboot itself, nothing will, so
# this rig needs an OS-level substitute for what the BMC would normally do.
#
# Narrow trigger, not broad: this only fires on the specific pair the runbook
# (TROUBLESHOOTING-CDI-ERROR.md) documents as confirmed-fatal and
# non-recoverable in software -- Xid 79 plus a 0x0 -> non-zero Xid 154
# recovery-action change. NVIDIA's driver has been observed emitting this as
# either 0x2 "Node Reboot Required" (2026-09/10) or 0x1 "GPU Reset Required"
# (2026-10-30, zappa1) for what is the same underlying fallen-off-the-bus
# fault -- the watcher matches both strings so it isn't silently blind to
# whichever wording the driver picks this time. It does NOT fire on other
# Xid codes, including the benign ones TROUBLESHOOTING-CDI-ERROR.md calls out
# (permission-denied register reads from renter mining software, etc).
#
# Second, separate trigger: NV_ERR_GPU_IN_FULLCHIP_RESET assertion storm.
# Confirmed live on zappa1, 2026-10-31 02:22 -- a self-test container's
# bandwidth/GPU-init probe wedged the GSP without ever emitting a Xid 79/154
# pair, so the trigger above stayed silent and the GPU sat dead (repeated
# "GPU HANDLE ERROR" from gpu_monitor.sh) for over 3 hours until a manual
# reboot. NVRM logs this return code on ~every call that touches the GPU
# while GSP is mid-reset, so a SINGLE line is not proof of a real wedge --
# it can appear transiently during an expected, self-recovering reset. A
# sustained burst (FULLCHIP_RESET_THRESHOLD matches within
# FULLCHIP_RESET_WINDOW_SECS) is what distinguishes an actually-stuck GPU
# (dozens of lines, same second, for hours) from a brief blip.
#
# Loop guard: refuses a second auto-reboot within AUTOREBOOT_GUARD_SECS of
# the last one, so a genuinely failing card can't reboot-loop the box
# forever -- it keeps alerting instead.
#
# Reboot method: magic SysRq only -- sync (s), remount read-only (u), reboot
# (b). Per the runbook a card that has fallen off the bus can make a graceful
# `reboot` hang (confirmed live on zappa1, 2026-09-25 and 2026-10-28) because
# the kernel can't quiesce the dead PCIe device, while SysRq b has reliably
# recovered this exact fault. This used to try `systemctl reboot` first and
# fall back to SysRq after 30 s, but that fallback ran inside
# this service, which the graceful shutdown stops first -- so when the
# shutdown then hung, nothing forced the reset. zappa1 on 2026-11-02: every
# service stopped cleanly at 15:48:31 and the box stayed dead until someone
# pressed the power button at 16:02.
#
# Deploy: see xid79-autoreboot.service in this directory. Runs continuously
# via systemd (Restart=always), not on a timer -- it needs to react within
# seconds of the fault, not wait for the next poll cycle.

set -uo pipefail

LOG_FILE="/var/log/xid79_autoreboot.log"
GUARD_FILE="/var/tmp/gpu_monitor_last_autoreboot"
CONF="/etc/gpu_monitor.conf"

AUTOREBOOT_GUARD_SECS="${AUTOREBOOT_GUARD_SECS:-7200}"   # 2h between auto-reboots
ALERT_DELAY_SECS="${ALERT_DELAY_SECS:-30}"
FULLCHIP_RESET_THRESHOLD="${FULLCHIP_RESET_THRESHOLD:-5}"
FULLCHIP_RESET_WINDOW_SECS="${FULLCHIP_RESET_WINDOW_SECS:-60}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

[[ -f "$CONF" ]] && source "$CONF"

tg_send() {
    [[ -z "${TELEGRAM_CHAT_ID:-}" || -z "${TELEGRAM_TOKEN:-}" ]] && return
    curl -sf -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d parse_mode="HTML" \
        --data-urlencode text="$1" >/dev/null 2>&1 || true
}

guard_ok() {
    [[ -f "$GUARD_FILE" ]] || return 0
    local last now
    last=$(cat "$GUARD_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    (( now - last >= AUTOREBOOT_GUARD_SECS ))
}

do_reboot() {
    local reason="$1" alert_html="$2"
    date +%s > "$GUARD_FILE"

    tg_send "$alert_html"
    log "$reason -- rebooting in ${ALERT_DELAY_SECS}s."
    sleep "$ALERT_DELAY_SECS"

    log "Rebooting via sysrq (sync, remount read-only, reboot)"
    sync
    echo s > /proc/sysrq-trigger
    sleep 3
    echo u > /proc/sysrq-trigger
    sleep 3
    echo b > /proc/sysrq-trigger
}

log "xid79-autoreboot watcher started"

fullchip_hits=()

# Tail the kernel ring for the fatal pair. journalctl -k -f blocks and emits
# new lines as they arrive -- this process is meant to run continuously.
journalctl -k -f -n 0 --no-pager 2>/dev/null | while IFS= read -r line; do
    if echo "$line" | grep -qE 'Xid \(PCI:([0-9a-fA-F:.]+)\): 79, GPU has fallen off the bus'; then
        bus=$(echo "$line" | grep -oE 'PCI:[0-9a-fA-F:.]+' | head -1 | cut -d: -f2-)
        log "Xid 79 line seen on bus $bus -- waiting for recovery-action confirmation"
        pending_bus="$bus"
        continue
    fi

    if [[ -n "${pending_bus:-}" ]] && echo "$line" | grep -qE 'Node Reboot Required|GPU Reset Required'; then
        if ! guard_ok; then
            log "Xid 79 + Node Reboot Required confirmed on $pending_bus, but within ${AUTOREBOOT_GUARD_SECS}s guard window of the last auto-reboot -- alerting only, NOT rebooting"
            tg_send "🔴 <b>$(hostname): another Xid 79 (bus $pending_bus) within the auto-reboot guard window — NOT auto-rebooting (possible repeat/ongoing hardware failure). Needs manual investigation.</b>"
        else
            do_reboot "Xid 79 confirmed on bus $pending_bus -- Node Reboot Required" \
                "🔴 <b>Xid 79 — $(hostname) GPU bus $pending_bus has fallen off the bus</b>
Node Reboot Required confirmed (matches the documented non-recoverable-in-software fault). Auto-rebooting in ${ALERT_DELAY_SECS}s. Reply/SSH in now if you need to abort or investigate first."
        fi
        unset pending_bus
        continue
    fi

    if echo "$line" | grep -q 'NV_ERR_GPU_IN_FULLCHIP_RESET'; then
        now=$(date +%s)
        fullchip_hits+=("$now")
        # Drop hits outside the window.
        cutoff=$(( now - FULLCHIP_RESET_WINDOW_SECS ))
        new_hits=()
        for t in "${fullchip_hits[@]}"; do
            (( t >= cutoff )) && new_hits+=("$t")
        done
        fullchip_hits=("${new_hits[@]}")

        if (( ${#fullchip_hits[@]} >= FULLCHIP_RESET_THRESHOLD )); then
            fullchip_hits=()
            if ! guard_ok; then
                log "FULLCHIP_RESET burst confirmed (GSP stuck in reset), but within ${AUTOREBOOT_GUARD_SECS}s guard window of the last auto-reboot -- alerting only, NOT rebooting"
                tg_send "🔴 <b>$(hostname): another FULLCHIP_RESET burst within the auto-reboot guard window — NOT auto-rebooting (possible repeat/ongoing hardware failure). Needs manual investigation.</b>"
            else
                do_reboot "FULLCHIP_RESET burst confirmed (>=${FULLCHIP_RESET_THRESHOLD} hits in ${FULLCHIP_RESET_WINDOW_SECS}s) -- GSP stuck in reset" \
                    "🔴 <b>$(hostname): GPU wedged (GSP stuck in FULLCHIP_RESET)</b>
No Xid 79 was logged -- this is the 2026-10-31 self-test-triggered wedge pattern, invisible to the Xid 79 trigger. Auto-rebooting in ${ALERT_DELAY_SECS}s. Reply/SSH in now if you need to abort or investigate first."
            fi
        fi
    fi
done
