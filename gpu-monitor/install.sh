#!/usr/bin/env bash
# Deploy gpu_monitor.sh as a systemd service on this rig
# Run as root: sudo bash install.sh

set -euo pipefail

SCRIPT_SRC="$(dirname "$0")/gpu_monitor.sh"
SCRIPT_DEST="/usr/local/bin/gpu_monitor.sh"
SERVICE_FILE="/etc/systemd/system/gpu-monitor.service"
LOG_FILE="/var/log/gpu_monitor.log"

echo "[*] Copying monitor script..."
cp "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

echo "[*] Writing systemd service..."
cat > "$SERVICE_FILE" <<EOF
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

echo "[*] Enabling and starting service..."
systemctl daemon-reload
systemctl enable gpu-monitor
systemctl restart gpu-monitor

echo ""
echo "[OK] gpu-monitor service is running."
echo "     Logs: tail -f $LOG_FILE"
echo "     Status: systemctl status gpu-monitor"
