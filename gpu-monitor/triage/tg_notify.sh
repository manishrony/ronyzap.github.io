#!/usr/bin/env bash
#
# tg_notify.sh — send a plain-text Telegram message using the token/chat ID
# already configured in /etc/gpu_monitor.conf. The Claude Code triage
# automation is only allowed to call this script (see settings.json's deny
# list for direct curl-to-Telegram) so it never needs the bot token in its
# own context or command line -- it just passes a message string.
#
# Usage: tg_notify.sh "message text (HTML parse_mode allowed)"

set -uo pipefail

CONF=/etc/gpu_monitor.conf
[[ -f "$CONF" ]] && source "$CONF"

if [[ -z "${TELEGRAM_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "tg_notify: TELEGRAM_TOKEN/TELEGRAM_CHAT_ID not set in $CONF" >&2
    exit 1
fi

msg="${1:-}"
if [[ -z "$msg" ]]; then
    echo "tg_notify: usage: tg_notify.sh \"message\"" >&2
    exit 1
fi

curl -sf -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d parse_mode="HTML" \
    --data-urlencode text="$msg" \
    && echo "tg_notify: sent OK" \
    || { echo "tg_notify: send failed" >&2; exit 1; }
