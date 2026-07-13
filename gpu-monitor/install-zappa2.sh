#!/usr/bin/env bash
# Deploy gpu_monitor.sh + dashboard on Zappa2.
# Zappa2 runs standalone (no peers configured here) — its data is picked up
# by Zappa1's combined dashboard via server-side proxy.
#
# Usage: sudo bash install-zappa2.sh

set -euo pipefail

PORT=8081
SELF_NAME="Zappa2"

exec bash "$(dirname "$0")/install.sh" "$PORT" "" "" "$SELF_NAME"
