#!/usr/bin/env bash
#
# xid79-autoreboot.sh — zappa1-only. Tails the kernel log for the confirmed
# Xid 79 ("GPU has fallen off the bus") + Xid 154 ("Node Reboot Required")
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
# non-recoverable in software -- Xid 79 plus the 0x0 -> 0x2 "Node Reboot
# Required" recovery-action change. It does NOT fire on other Xid codes,
# including the benign ones TROUBLESHOOTING-CDI-ERROR.md calls out
# (permission-denied register reads from renter mining software, etc).
#
# Loop guard: refuses a second auto-reboot within AUTOREBOOT_GUARD_SECS of
# the last one, so a genuinely failing card can't reboot-loop the box
# forever -- it keeps alerting instead.
#
# Reboot method: tries `systemctl reboot` first, but per the runbook a card
# that has already fallen off the bus can make `reboot` hang (confirmed live
# on zappa1, 2026-09-25 and 2026-10-28) because the kernel can't quiesce the
# dead PCIe device. If the box hasn't actually gone down within
# REBOOT_TIMEOUT_SECS, fall back to the magic-SysRq hard reset
# (`echo b > /proc/sysrq-trigger`), which bypasses the graceful-shutdown path
# and has reliably recovered this exact fault.
#
# Deploy: see xid79-autoreboot.service in this directory. Runs continuously
# via systemd (Restart=always), not on a timer -- it needs to react within
# seconds of the fault, not wait for the next poll cycle.

set -uo pipefail

LOG_FILE="/var/log/xid79_autoreboot.log"
GUARD_FILE="/var/tmp/gpu_monitor_last_autoreboot"
CONF="/etc/gpu_monitor.conf"

AUTOREBOOT_GUARD_SECS="${AUTOREBOOT_GUARD_SECS:-7200}"   # 2h between auto-reboots
REBOOT_TIMEOUT_SECS="${REBOOT_TIMEOUT_SECS:-30}"
ALERT_DELAY_SECS="${ALERT_DELAY_SECS:-30}"

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
    local bus="$1"
    date +%s > "$GUARD_FILE"

    tg_send "🔴 <b>Xid 79 — $(hostname) GPU bus $bus has fallen off the bus</b>
Node Reboot Required confirmed (matches the documented non-recoverable-in-software fault). Auto-rebooting in ${ALERT_DELAY_SECS}s. Reply/SSH in now if you need to abort or investigate first."
    log "Xid 79 confirmed on bus $bus -- Node Reboot Required. Rebooting in ${ALERT_DELAY_SECS}s."
    sleep "$ALERT_DELAY_SECS"

    log "Issuing systemctl reboot"
    systemctl reboot &
    local reboot_pid=$!

    sleep "$REBOOT_TIMEOUT_SECS"

    # If we're still here and able to run, the graceful reboot hasn't
    # completed -- matches the known hang pattern. Force it.
    if kill -0 "$reboot_pid" 2>/dev/null || [[ -d /proc/1 ]]; then
        log "systemctl reboot did not complete within ${REBOOT_TIMEOUT_SECS}s -- forcing via sysrq"
        tg_send "⚠️ <b>$(hostname): graceful reboot hung (known Xid 79 pattern) — forcing hard reset via sysrq now</b>"
        echo b > /proc/sysrq-trigger
    fi
}

log "xid79-autoreboot watcher started"

# Tail the kernel ring for the fatal pair. journalctl -k -f blocks and emits
# new lines as they arrive -- this process is meant to run continuously.
journalctl -k -f -n 0 --no-pager 2>/dev/null | while IFS= read -r line; do
    if echo "$line" | grep -qE 'Xid \(PCI:([0-9a-fA-F:.]+)\): 79, GPU has fallen off the bus'; then
        bus=$(echo "$line" | grep -oE 'PCI:[0-9a-fA-F:.]+' | head -1 | cut -d: -f2-)
        log "Xid 79 line seen on bus $bus -- waiting for recovery-action confirmation"
        pending_bus="$bus"
        continue
    fi

    if [[ -n "${pending_bus:-}" ]] && echo "$line" | grep -q 'Node Reboot Required'; then
        if ! guard_ok; then
            log "Xid 79 + Node Reboot Required confirmed on $pending_bus, but within ${AUTOREBOOT_GUARD_SECS}s guard window of the last auto-reboot -- alerting only, NOT rebooting"
            tg_send "🔴 <b>$(hostname): another Xid 79 (bus $pending_bus) within the auto-reboot guard window — NOT auto-rebooting (possible repeat/ongoing hardware failure). Needs manual investigation.</b>"
        else
            do_reboot "$pending_bus"
        fi
        unset pending_bus
    fi
done
