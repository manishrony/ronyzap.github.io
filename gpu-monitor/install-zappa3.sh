#!/usr/bin/env bash
# Deploy gpu_monitor.sh + dashboard on Zappa3.
# Zappa3 runs standalone (no peers configured here) — its data is picked up
# by Zappa1's combined dashboard via server-side proxy. GPU power limit is
# auto-detected by model (RTX 5080 -> 300W), no argument needed.
#
# Usage: sudo bash install-zappa3.sh

set -euo pipefail

PORT=8082
SELF_NAME="Zappa3"

exec bash "$(dirname "$0")/install.sh" "$PORT" "" "" "$SELF_NAME"
