#!/usr/bin/env bash
# Install GPU dashboard as a systemd service on port 8080
set -euo pipefail

DASH_DIR="$(dirname "$(realpath "$0")")"
SERVICE="/etc/systemd/system/gpu-dashboard.service"

echo "[*] Installing GPU dashboard from $DASH_DIR..."

cat > "$SERVICE" <<EOF
[Unit]
Description=GPU Monitor Web Dashboard
After=network.target gpu-monitor.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $DASH_DIR/server.py
Restart=always
RestartSec=5
Environment=GPU_DATA=/var/log/gpu_monitor_data.jsonl
Environment=DASHBOARD_PORT=8080
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gpu-dashboard
systemctl restart gpu-dashboard

echo ""
echo "[OK] Dashboard running at http://$(hostname -I | awk '{print $1}'):8080"
echo "     Logs: journalctl -u gpu-dashboard -f"
echo "     Status: systemctl status gpu-dashboard"
