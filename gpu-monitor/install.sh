#!/usr/bin/env bash
# Deploy gpu_monitor.sh + dashboard as systemd services on this rig
# Usage: sudo bash install.sh [port] [peer_urls] [peer_names] [self_name]
#   port       : dashboard port (default 8080; zappa1=8080, zappa2=8081, zappa3=8082, ...)
#   peer_urls  : comma-separated base URLs of OTHER rigs' dashboards, for server-side
#                proxy (works over LAN and from the internet). Only set this on the
#                ONE rig that serves the combined view (typically zappa1).
#                e.g. sudo bash install.sh 8080 "http://192.168.1.196:8081,http://192.168.1.150:8082"
#   peer_names : optional comma-separated display names matching peer_urls order
#                e.g. "Zappa2,Zappa3" — defaults to "Rig 2","Rig 3",... if omitted
#   self_name  : optional display name for THIS rig (defaults to hostname)
#
# To add a new rig later: install it standalone (no peer_urls needed on the new
# box itself), then re-run this script on the hub rig (zappa1) with the new
# rig's URL appended to peer_urls and restart — the combined dashboard picks
# it up automatically on next page load, no HTML/JS changes needed.

set -euo pipefail

SCRIPT_SRC="$(dirname "$0")/gpu_monitor.sh"
SCRIPT_DEST="/usr/local/bin/gpu_monitor.sh"
DASH_SRC="$(dirname "$0")/dashboard"
DASH_DEST="/opt/gpu-monitor/dashboard"
MONITOR_SVC="/etc/systemd/system/gpu-monitor.service"
DASHBOARD_SVC="/etc/systemd/system/gpu-dashboard.service"
LOG_FILE="/var/log/gpu_monitor.log"
DASHBOARD_PORT="${1:-8080}"
PEER_URLS="${2:-}"
PEER_NAMES="${3:-}"
SELF_NAME="${4:-}"

echo "[*] Copying monitor script..."
cp "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

echo "[*] Installing dashboard to $DASH_DEST ..."
mkdir -p "$DASH_DEST"
cp "$DASH_SRC/server.py"      "$DASH_DEST/"
cp "$DASH_SRC/index.html"     "$DASH_DEST/"
cp "$DASH_SRC/combined.html"  "$DASH_DEST/"
cp "$DASH_SRC/market.html"    "$DASH_DEST/"

echo "[*] Writing gpu-monitor systemd service..."
cat > "$MONITOR_SVC" <<EOF
[Unit]
Description=GPU Power Management Monitor
After=network.target nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=simple
ExecStart=/usr/local/bin/gpu_monitor.sh
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
Environment=DASHBOARD_PORT=$DASHBOARD_PORT
Environment=PEER_URLS=$PEER_URLS
Environment=PEER_NAMES=$PEER_NAMES
Environment=SELF_NAME=$SELF_NAME
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

echo ""
echo "[OK] Services running."
echo "     Monitor:   tail -f $LOG_FILE"
echo "     Dashboard: http://localhost:$DASHBOARD_PORT"
echo "     Combined:  http://localhost:$DASHBOARD_PORT/combined"
echo "     Market:    http://localhost:$DASHBOARD_PORT/market"
[[ -n "$PEER_URLS" ]] && echo "     Peers:     $PEER_URLS (proxied via /api/peer, /api/peer/1, ...)"
echo "     Status:    systemctl status gpu-monitor gpu-dashboard"
