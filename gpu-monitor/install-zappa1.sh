#!/usr/bin/env bash
# Deploy gpu_monitor.sh + dashboard on Zappa1.
# Zappa1 is the hub — it serves the combined dashboard on both the LAN
# (http://192.168.1.171:8080/combined) and the public URL
# (http://141.152.237.39:8080/combined), proxying Zappa2 and Zappa3's data.
#
# Usage: sudo bash install-zappa1.sh
#
# To add another rig to the hub later, edit PEER_URLS/PEER_NAMES below and
# re-run this script.

set -euo pipefail

PORT=8080
PEER_URLS="http://192.168.1.196:8081,http://192.168.1.211:8082"
PEER_NAMES="Zappa2,Zappa3"
SELF_NAME="Zappa1"

exec bash "$(dirname "$0")/install.sh" "$PORT" "$PEER_URLS" "$PEER_NAMES" "$SELF_NAME"
