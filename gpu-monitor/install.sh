#!/usr/bin/env bash
# Deploy gpu_monitor.sh + dashboard as systemd services on this rig
# Usage: sudo bash install.sh [port] [peer_urls] [peer_names] [self_name] [power_limit]
#   port        : dashboard port (default 8080; zappa1=8080, zappa2=8081, zappa3=8082, ...)
#   peer_urls   : comma-separated base URLs of OTHER rigs' dashboards, for server-side
#                 proxy (works over LAN and from the internet). Only set this on the
#                 ONE rig that serves the combined view (typically zappa1).
#                 e.g. sudo bash install.sh 8080 "http://192.168.1.196:8081,http://192.168.1.150:8082"
#                 Setting this ALSO installs+configures a central Prometheus on THIS
#                 rig (scraping this rig's own /metrics plus every peer's, 10y
#                 retention) — see RIGS.md's "Prometheus" section.
#   peer_names  : optional comma-separated display names matching peer_urls order
#                 e.g. "Zappa2,Zappa3" — defaults to "Rig 2","Rig 3",... if omitted
#   self_name   : optional display name for THIS rig (defaults to hostname)
#   power_limit : per-GPU power cap in watts for THIS rig (default 500 if omitted —
#                 matches existing RTX 5090 rigs). Lower-TDP cards (e.g. RTX 5080,
#                 360W max) may need a lower cap to manage chassis heat, e.g. 300.
#                 Re-applied every hour by gpu_monitor.sh, so it persists across
#                 reboots and won't drift back to the default.
#
# To add a new rig later: install it standalone (no peer_urls needed on the new
# box itself), then re-run this script on the hub rig (zappa1) with the new
# rig's URL appended to peer_urls and restart — the combined dashboard picks
# it up automatically on next page load, no HTML/JS changes needed.

set -euo pipefail

SCRIPT_SRC="$(dirname "$0")/gpu_monitor.sh"
SCRIPT_DEST="/usr/local/bin/gpu_monitor.sh"
ACTIVITY_SRC="$(dirname "$0")/vast-activity.sh"
ACTIVITY_DEST="/usr/local/bin/vast-activity"
BACKFILL_SRC="$(dirname "$0")/backfill-workloads.sh"
BACKFILL_DEST="/usr/local/bin/backfill-workloads"
FIXRENTAL_SRC="$(dirname "$0")/fix-active-rental.sh"
FIXRENTAL_DEST="/usr/local/bin/fix-active-rental"
PURGEEARNINGS_SRC="$(dirname "$0")/purge-earnings.sh"
PURGEEARNINGS_DEST="/usr/local/bin/purge-earnings"
PROFITOVERRIDE_SRC="$(dirname "$0")/profit-override.sh"
PROFITOVERRIDE_DEST="/usr/local/bin/profit-override"
DUMPMACHINE_SRC="$(dirname "$0")/dump-machine-json.sh"
DUMPMACHINE_DEST="/usr/local/bin/dump-machine-json"
EARNINGS_SRC="$(dirname "$0")/earnings-today.sh"
EARNINGS_DEST="/usr/local/bin/earnings-today"
PDUPOWER_SRC="$(dirname "$0")/pdu-power.sh"
PDUPOWER_DEST="/usr/local/bin/pdu-power"
BACKFILLPROM_SRC="$(dirname "$0")/backfill-prometheus.py"
BACKFILLPROM_DEST="/usr/local/bin/backfill-prometheus"
BACKUP_SRC="$(dirname "$0")/backup-jsonl.sh"
BACKUP_DEST="/usr/local/bin/backup-jsonl"
BACKUP_SVC="/etc/systemd/system/gpu-backup.service"
BACKUP_TIMER="/etc/systemd/system/gpu-backup.timer"
DASH_SRC="$(dirname "$0")/dashboard"
DASH_DEST="/opt/gpu-monitor/dashboard"
MONITOR_SVC="/etc/systemd/system/gpu-monitor.service"
DASHBOARD_SVC="/etc/systemd/system/gpu-dashboard.service"
LOG_FILE="/var/log/gpu_monitor.log"
DASHBOARD_PORT="${1:-8080}"
PEER_URLS="${2:-}"
PEER_NAMES="${3:-}"
SELF_NAME="${4:-}"
GPU_POWER_LIMIT="${5:-}"

echo "[*] Copying monitor script..."
cp "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

echo "[*] Installing vast-activity helper..."
cp "$ACTIVITY_SRC" "$ACTIVITY_DEST"
chmod +x "$ACTIVITY_DEST"

echo "[*] Installing backfill-workloads helper (run manually, one-off)..."
cp "$BACKFILL_SRC" "$BACKFILL_DEST"
chmod +x "$BACKFILL_DEST"

echo "[*] Installing fix-active-rental helper (run manually, one-off)..."
cp "$FIXRENTAL_SRC" "$FIXRENTAL_DEST"
chmod +x "$FIXRENTAL_DEST"

echo "[*] Installing purge-earnings helper (run manually, one-off)..."
cp "$PURGEEARNINGS_SRC" "$PURGEEARNINGS_DEST"
chmod +x "$PURGEEARNINGS_DEST"

echo "[*] Installing profit-override helper (run manually, as needed)..."
cp "$PROFITOVERRIDE_SRC" "$PROFITOVERRIDE_DEST"
chmod +x "$PROFITOVERRIDE_DEST"

echo "[*] Installing dump-machine-json helper (run manually, one-off diagnostic)..."
cp "$DUMPMACHINE_SRC" "$DUMPMACHINE_DEST"
chmod +x "$DUMPMACHINE_DEST"

echo "[*] Installing earnings-today helper..."
cp "$EARNINGS_SRC" "$EARNINGS_DEST"
chmod +x "$EARNINGS_DEST"

echo "[*] Installing pdu-power helper..."
cp "$PDUPOWER_SRC" "$PDUPOWER_DEST"
chmod +x "$PDUPOWER_DEST"

echo "[*] Installing backfill-prometheus helper (run manually, one-off per rig)..."
cp "$BACKFILLPROM_SRC" "$BACKFILLPROM_DEST"
chmod +x "$BACKFILLPROM_DEST"

echo "[*] Installing backup-jsonl helper + daily backup timer (14-day retention)..."
cp "$BACKUP_SRC" "$BACKUP_DEST"
chmod +x "$BACKUP_DEST"
cat > "$BACKUP_SVC" <<EOF
[Unit]
Description=GPU Monitor daily JSONL backup

[Service]
Type=oneshot
ExecStart=$BACKUP_DEST
User=root
EOF
cat > "$BACKUP_TIMER" <<EOF
[Unit]
Description=Run gpu-backup daily (14-day retention)

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now gpu-backup.timer

echo "[*] Installing dashboard to $DASH_DEST ..."
mkdir -p "$DASH_DEST"
cp "$DASH_SRC/server.py"        "$DASH_DEST/"
cp "$DASH_SRC/assistant.py"     "$DASH_DEST/"
cp "$DASH_SRC/prom_exporter.py" "$DASH_DEST/"
cp "$DASH_SRC/history_api.py"   "$DASH_DEST/"
cp "$DASH_SRC/profit_api.py"        "$DASH_DEST/"
cp "$DASH_SRC/occupancy_api.py"     "$DASH_DEST/"
cp "$DASH_SRC/daily_summary_api.py" "$DASH_DEST/"
cp "$DASH_SRC/events_api.py"        "$DASH_DEST/"
cp "$DASH_SRC/prom_client.py"       "$DASH_DEST/"
cp "$DASH_SRC/index.html"       "$DASH_DEST/"
cp "$DASH_SRC/combined.html"    "$DASH_DEST/"
cp "$DASH_SRC/market.html"      "$DASH_DEST/"
cp "$DASH_SRC/history.html"     "$DASH_DEST/"

# Rig Assistant chat backend is swappable (see LLM_PROVIDER in RIGS.md) —
# install whichever provider's SDK this rig's conf actually selects (defaults
# to "openai" if LLM_PROVIDER isn't set, matching assistant.py's default).
CHAT_PROVIDER="openai"
if [[ -f /etc/gpu_monitor.conf ]]; then
    conf_provider=$(grep -oP '^LLM_PROVIDER=["\x27]?\K[^"\x27]*' /etc/gpu_monitor.conf 2>/dev/null || true)
    [[ -n "$conf_provider" ]] && CHAT_PROVIDER="$conf_provider"
fi
echo "[*] Ensuring the '$CHAT_PROVIDER' Python package is installed (dashboard chat assistant, LLM_PROVIDER=$CHAT_PROVIDER)..."
if command -v pip3 >/dev/null 2>&1; then
    pip3 install --quiet --break-system-packages "$CHAT_PROVIDER" 2>/dev/null \
        || pip3 install --quiet "$CHAT_PROVIDER" 2>/dev/null \
        || echo "  ⚠️  Could not auto-install '$CHAT_PROVIDER' — chat assistant stays disabled until: pip3 install $CHAT_PROVIDER"
else
    echo "  ⚠️  pip3 not found — chat assistant stays disabled until '$CHAT_PROVIDER' is installed for python3"
fi

echo "[*] Writing gpu-monitor systemd service..."
cat > "$MONITOR_SVC" <<EOF
[Unit]
Description=GPU Power Management Monitor
After=network.target nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=simple
ExecStart=/usr/local/bin/gpu_monitor.sh
Environment=GPU_POWER_LIMIT=$GPU_POWER_LIMIT
Restart=always
RestartSec=30
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Writing gpu-dashboard systemd service (port $DASHBOARD_PORT)..."
cat > "$DASHBOARD_SVC" <<EOF
[Unit]
Description=GPU Monitor Dashboard Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $DASH_DEST/server.py
Environment=GPU_DATA=/var/log/gpu_monitor_data.jsonl
Environment=GPU_STATE_FILE=/var/tmp/gpu_monitor_vastai_state
Environment=DASHBOARD_PORT=$DASHBOARD_PORT
Environment=PEER_URLS=$PEER_URLS
Environment=PEER_NAMES=$PEER_NAMES
Environment=SELF_NAME=$SELF_NAME
Environment=PROMETHEUS_URL=http://localhost:9090
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Enabling and starting services..."
systemctl daemon-reload
systemctl enable gpu-monitor gpu-dashboard
systemctl restart gpu-monitor gpu-dashboard

# Central Prometheus — hub only (peer_urls set means this is the rig serving
# the combined dashboard). Scrapes this rig's own /metrics plus every peer's,
# so there's one place with all three rigs' history instead of three. See
# RIGS.md's "Prometheus" section for the historical-backfill runbook
# (backfill-prometheus, installed above) and the pagination-vs-single-file
# rationale this replaces.
PROM_TARGETS=""
if [[ -n "$PEER_URLS" ]]; then
    echo "[*] Peer URLs set — this is the hub. Installing Prometheus..."
    if ! command -v prometheus >/dev/null 2>&1; then
        apt-get update -qq
        # --no-install-recommends: the 'prometheus' deb Recommends node-exporter
        # + ipmitool/smartmontools/nvme-cli (a whole hardware-monitoring stack we
        # don't use — our own custom /metrics exporter covers what we need). Skip it.
        apt-get install -y --no-install-recommends prometheus
    fi

    PROM_TARGETS="\"localhost:$DASHBOARD_PORT\""
    IFS=',' read -ra _peer_list <<< "$PEER_URLS"
    for _peer in "${_peer_list[@]}"; do
        _hostport="${_peer#http://}"; _hostport="${_hostport#https://}"; _hostport="${_hostport%/}"
        [[ -n "$_hostport" ]] && PROM_TARGETS+=", \"$_hostport\""
    done

    mkdir -p /etc/prometheus
    cat > /etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 30s
scrape_configs:
  - job_name: gpu_monitor
    static_configs:
      - targets: [$PROM_TARGETS]
EOF

    # 14-day retention — the dashboard's own history needs (History page,
    # Occupancy 24h/7d/14d, Daily Summary's "yesterday", month-to-date profit
    # capped to this same window — see profit_api.py) don't reach further
    # back than 2 weeks. The raw JSONL log + its own daily gzip backup
    # (gpu-backup.timer, 14-day retention) remain the longer-lived record.
    if [[ -f /etc/default/prometheus ]] && grep -q '^ARGS=' /etc/default/prometheus; then
        sed -i 's|^ARGS=.*|ARGS="--storage.tsdb.retention.time=14d"|' /etc/default/prometheus
    else
        echo 'ARGS="--storage.tsdb.retention.time=14d"' >> /etc/default/prometheus
    fi

    systemctl enable prometheus
    systemctl restart prometheus
fi

echo ""
echo "[OK] Services running."
echo "     Monitor:   tail -f $LOG_FILE"
echo "     Dashboard: http://localhost:$DASHBOARD_PORT"
echo "     Combined:  http://localhost:$DASHBOARD_PORT/combined"
echo "     Market:    http://localhost:$DASHBOARD_PORT/market"
echo "     History:   http://localhost:$DASHBOARD_PORT/history (paginated, DB-backed — hub only)"
[[ -n "$PEER_URLS" ]] && echo "     Peers:     $PEER_URLS (proxied via /api/peer, /api/peer/1, ...)"
if [[ -n "$PEER_URLS" ]]; then
    echo "     Prometheus:http://localhost:9090  (scraping: $PROM_TARGETS, retention 10y)"
fi
if [[ -n "$GPU_POWER_LIMIT" ]]; then
    echo "     Power cap: ${GPU_POWER_LIMIT}W per GPU (manual override, re-applied hourly)"
else
    echo "     Power cap: auto-detected per GPU model (5090=500W, 5080=300W, re-applied hourly)"
fi
echo "     Status:    systemctl status gpu-monitor gpu-dashboard"
echo "     Activity:  vast-activity (self-test verdicts, launched instances, results)"
echo "     Backfill:  backfill-workloads (one-off: classify past rentals' workload type from kaalia.log)"
echo "     Fix rental:fix-active-rental (one-off: correct the active rental's GPU count + rate from live API)"
echo "     Purge:     purge-earnings (one-off: wipe daily_earnings for this host + restart for a clean re-backfill)"
echo "     Profit ovr:profit-override <watts>|off|clear|status (force/inspect the profit power throttle; clears on rental end)"
echo "     Machine dump:dump-machine-json [outfile] (one-off: dump this rig's full raw Vast /machines/ JSON, for finding undocumented fields)"
echo "     Earnings:  earnings-today (today's rentals, times, prices + revenue; pass YYYY-MM-DD for a past day)"
echo "     PDU power: pdu-power (live rack watts + today/lifetime kWh & cost; hub rig only, needs PDU_HOSTS)"
echo "     Backfill:  backfill-prometheus --rig <name> --out <file>.om (one-off per rig: JSONL+log -> OpenMetrics for historical import, see RIGS.md)"
echo "     Backup:    daily JSONL backup -> /var/backups/gpu-monitor, 14-day retention (gpu-backup.timer; run backup-jsonl manually to test)"
CHAT_KEY_NAME=$(echo "$CHAT_PROVIDER" | tr '[:lower:]' '[:upper:]')_API_KEY
if [[ -f /etc/gpu_monitor.conf ]] && grep -q "^${CHAT_KEY_NAME}=.\+" /etc/gpu_monitor.conf 2>/dev/null; then
    echo "     Chat:      enabled ($CHAT_KEY_NAME set, LLM_PROVIDER=$CHAT_PROVIDER) — read-only Rig Assistant on the combined dashboard"
else
    echo "     Chat:      disabled — set $CHAT_KEY_NAME in /etc/gpu_monitor.conf on the hub to enable (LLM_PROVIDER=$CHAT_PROVIDER selected)"
fi

# Without /etc/gpu_monitor.conf the VASTAI_API_KEY is empty and ALL Vast.ai
# integration silently no-ops (no rental detection, no revenue, no pricing, no
# Telegram) — the rig looks "Free" forever. Warn loudly if it's missing.
if [[ ! -f /etc/gpu_monitor.conf ]]; then
    echo ""
    echo "  ⚠️  /etc/gpu_monitor.conf is MISSING on this rig."
    echo "      Vast.ai rental detection, revenue, pricing and Telegram alerts are DISABLED"
    echo "      until you create it. This rig will show as 'Free' with \$0 revenue regardless"
    echo "      of actual rentals. Create it (root-only) with your account values:"
    echo ""
    echo "        sudo tee /etc/gpu_monitor.conf >/dev/null <<'CONF'"
    echo "        VASTAI_API_KEY=\"<your Vast.ai API key>\""
    echo "        TELEGRAM_CHAT_ID=\"<your Telegram chat id>\""
    echo "        # LLM_PROVIDER=\"openai\"   # optional, this is the default — or \"anthropic\""
    echo "        OPENAI_API_KEY=\"<optional — enables the dashboard chat assistant, hub only>\""
    echo "        CONF"
    echo "        sudo chmod 600 /etc/gpu_monitor.conf"
    echo "        sudo systemctl restart gpu-monitor"
    echo ""
    echo "      Tip: it's the same VASTAI_API_KEY as your other rigs (account-level)."
elif ! grep -q '^VASTAI_API_KEY=.\+' /etc/gpu_monitor.conf 2>/dev/null; then
    echo ""
    echo "  ⚠️  /etc/gpu_monitor.conf exists but VASTAI_API_KEY looks empty — Vast.ai"
    echo "      integration will be disabled until it's set."
fi
