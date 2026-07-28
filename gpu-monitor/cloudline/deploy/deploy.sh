#!/usr/bin/env bash
# Deploys the optional Cloudline temp-based scheduler to a rig host as its
# own systemd service, independent of gpu-monitor.service and gpu-dashboard.
# The dashboard's Cooling card and manual speed control need nothing from
# this script — this is only for the automatic temp-based speed loop.
#
# Usage: ./deploy.sh <host> [remote_dir]
set -euo pipefail

HOST="${1:?usage: deploy.sh <host> [remote_dir]}"
REMOTE_DIR="${2:-/opt/gpu-monitor/cloudline}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ssh "$HOST" "mkdir -p '$REMOTE_DIR'"
rsync -av --exclude deploy "$SCRIPT_DIR"/ "$HOST:$REMOTE_DIR/"

if ! ssh "$HOST" "test -f '$REMOTE_DIR/.env'"; then
  ssh "$HOST" "cat > '$REMOTE_DIR/.env' <<'EOF'
AC_INFINITY_EMAIL=
AC_INFINITY_PASSWORD=
CLOUDLINE_POLL_SECONDS=60
CLOUDLINE_MIN_TEMP_C=30
CLOUDLINE_MAX_TEMP_C=45
CLOUDLINE_MIN_SPEED=2
EOF"
  echo "Wrote template $REMOTE_DIR/.env — fill in AC_INFINITY_EMAIL/PASSWORD before enabling the service."
fi

scp "$SCRIPT_DIR/deploy/cloudline-scheduler.service" "$HOST:/tmp/cloudline-scheduler.service"
ssh "$HOST" "sudo mv /tmp/cloudline-scheduler.service /etc/systemd/system/cloudline-scheduler.service && sudo systemctl daemon-reload"

echo "Deployed. To enable the automatic temp-based scheduler:"
echo "  ssh $HOST 'sudo systemctl enable --now cloudline-scheduler'"
echo "Note: read_temp_c() in scheduler.py is still a stub — wire it to a real sensor before enabling, or the loop stays a no-op."
