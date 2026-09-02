#!/usr/bin/env bash
#
# watch_incidents.sh — runs on zappa1 (the hub), on a cron schedule (every
# 1-2 min is plenty; hardware faults don't need sub-minute reaction and this
# keeps Claude API usage down to "only when something actually happens").
#
# Polls this host's own /var/tmp/gpu_monitor_incidents/ (dropped by
# check_bmc_sel_faults() in gpu_monitor.sh) plus zappa2/zappa3's over a
# dedicated read-only SSH key, and for each not-yet-seen incident invokes
# Claude Code headlessly with TRIAGE_PROMPT.md and the Tier-1 settings.json
# in this directory. Tier 1 = read-only diagnostics + Telegram report only;
# see settings.json and TRIAGE_PROMPT.md for the actual boundary.
#
# Setup (one-time, see README.md for the full walkthrough):
#   1. claude login   (persists auth so this can run unattended)
#   2. Generate a dedicated key: ssh-keygen -t ed25519 -f ~/.ssh/zappa1_triage_ro -N ""
#   3. Add the PUBLIC half to zappa2 and zappa3's authorized_keys, ideally
#      with a forced-command / restricted shell, not full access
#   4. Add SSH host aliases "zappa2"/"zappa3" in ~/.ssh/config using that key
#   5. crontab -e:  */2 * * * * /home/ronyzap/ronyzap.github.io/gpu-monitor/triage/watch_incidents.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/zappa1_triage"
PROCESSED_FILE="$STATE_DIR/processed_incidents.txt"
LOG_FILE="/var/log/zappa1_triage.log"
LOCAL_INCIDENT_DIR="/var/tmp/gpu_monitor_incidents"
PEERS=(zappa1 zappa2 zappa3)   # zappa1 = local, checked without SSH

mkdir -p "$STATE_DIR"
touch "$PROCESSED_FILE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

already_processed() {
    grep -qxF "$1" "$PROCESSED_FILE" 2>/dev/null
}

mark_processed() {
    echo "$1" >> "$PROCESSED_FILE"
    # Keep the state file from growing forever -- a few thousand lines of
    # incident IDs is plenty of history, trim the oldest once it's large.
    if [[ $(wc -l < "$PROCESSED_FILE") -gt 5000 ]]; then
        tail -2000 "$PROCESSED_FILE" > "${PROCESSED_FILE}.tmp" && mv "${PROCESSED_FILE}.tmp" "$PROCESSED_FILE"
    fi
}

run_triage() {
    local host="$1" incident_key="$2" incident_json="$3"
    log "New incident: $incident_key (host=$host) -- launching triage"

    local tmp_incident
    tmp_incident=$(mktemp /tmp/incident_XXXXXX.json)
    echo "$incident_json" > "$tmp_incident"

    # --settings scopes this run to Tier 1 (read-only + tg_notify.sh only,
    # see settings.json). -p runs non-interactively and exits when done --
    # this is a single headless triage pass per incident, not a persistent
    # session.
    (
        cd "$SCRIPT_DIR" || exit 1
        claude -p "$(cat TRIAGE_PROMPT.md)

Incident file contents for this run:
$(cat "$tmp_incident")" \
            --settings "$SCRIPT_DIR/settings.json" \
            >> "$LOG_FILE" 2>&1
    )
    local rc=$?
    rm -f "$tmp_incident"

    if [[ $rc -ne 0 ]]; then
        log "Triage run for $incident_key exited non-zero ($rc) -- notifying directly since the agent may not have gotten far enough to self-report"
        bash "$SCRIPT_DIR/tg_notify.sh" "⚠️ Triage watcher: run for incident <code>${incident_key}</code> (host ${host}) failed to complete (exit ${rc}). Check /var/log/zappa1_triage.log on zappa1." || true
    fi
    mark_processed "$incident_key"
}

check_local() {
    [[ -d "$LOCAL_INCIDENT_DIR" ]] || return
    for f in "$LOCAL_INCIDENT_DIR"/*.json; do
        [[ -e "$f" ]] || continue
        local key="zappa1:$(basename "$f")"
        already_processed "$key" && continue
        run_triage "zappa1" "$key" "$(cat "$f")"
    done
}

check_peer() {
    local peer="$1"
    # Read-only: list + cat, nothing else, over the dedicated restricted key
    # (see README.md -- this should be configured in ~/.ssh/config as an
    # alias already pointing at the right key/user/port).
    local files
    files=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$peer" \
        "ls $LOCAL_INCIDENT_DIR/*.json 2>/dev/null" 2>/dev/null) || {
        log "SSH to $peer failed or unreachable -- skipping this cycle"
        return
    }
    [[ -z "$files" ]] && return

    while IFS= read -r remote_path; do
        [[ -z "$remote_path" ]] && continue
        local key="${peer}:$(basename "$remote_path")"
        already_processed "$key" && continue
        local content
        content=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$peer" "cat '$remote_path'" 2>/dev/null)
        [[ -z "$content" ]] && continue
        run_triage "$peer" "$key" "$content"
    done <<< "$files"
}

for peer in "${PEERS[@]}"; do
    if [[ "$peer" == "zappa1" ]]; then
        check_local
    else
        check_peer "$peer"
    fi
done
