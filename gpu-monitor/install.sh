#!/usr/bin/env bash
# Deploy gpu_monitor.sh + dashboard as systemd services on this rig
# Run as root: sudo bash install.sh [dashboard_port]
# Default dashboard port: 8080  (pass 8081 for zappa2)

set -euo pipefail

SCRIPT_SRC="$(dirname "$0")/gpu_monitor.sh"
SCRIPT_DEST="/usr/local/bin/gpu_monitor.sh"
DASH_SRC="$(dirname "$0")/dashboard"
DASH_DEST="/opt/gpu-monitor/dashboard"
MONITOR_SVC="/etc/systemd/system/gpu-monitor.service"
DASHBOARD_SVC="/etc/systemd/system/gpu-dashboard.service"
LOG_FILE="/var/log/gpu_monitor.log"
DASHBOARD_PORT="${1:-8080}"

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
echo "     Status:    systemctl status gpu-monitor gpu-dashboard"
