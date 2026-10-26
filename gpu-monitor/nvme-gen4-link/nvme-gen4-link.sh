#!/bin/bash
# Cap an NVMe drive's PCIe link speed by writing Target Link Speed (Link
# Control 2, bits 3:0) on its upstream root port and retraining the link —
# the same mechanism as the kernel's own PCIe bandwidth controller. Built for
# zappa2 (2026-10-26): the Crucial T705 at 00:01.4 trains at Gen5 x2, heats
# from 63 to 89 °C within a minute under a heavy write burst, then drops off
# the bus. The S8056 BIOS has no M.2 link-speed option, so this runs at boot.
#
# Usage: nvme-gen4-link.sh [nvme-ctrl] [gen]    (defaults: nvme0 4)
# Does not persist on its own; the systemd unit re-applies it each boot.
set -u
CTRL="${1:-nvme0}"
GEN="${2:-4}"
declare -A SPEED=([3]="8.0" [4]="16.0" [5]="32.0")
want="${SPEED[$GEN]:-}"
[[ -n "$want" ]] || { echo "nvme-gen4-link: unsupported gen '$GEN' (use 3, 4 or 5)"; exit 2; }

dev_path=$(readlink -f "/sys/class/nvme/$CTRL/device") || { echo "nvme-gen4-link: no $CTRL"; exit 1; }
ep=$(basename "$dev_path")                # e.g. 0000:03:00.0 (the drive)
port=$(basename "$(dirname "$dev_path")") # e.g. 0000:00:01.4 (its root port)
[[ "$port" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || { echo "nvme-gen4-link: can't find root port for $ep"; exit 1; }

cur=$(cut -d' ' -f1 "/sys/bus/pci/devices/$ep/current_link_speed")
echo "nvme-gen4-link: $CTRL $ep via $port at $cur GT/s, target Gen$GEN ($want GT/s)"
if awk -v c="$cur" -v w="$want" 'BEGIN { exit !(c + 0 <= w + 0) }'; then
    echo "nvme-gen4-link: already at or below target — nothing to do"
    exit 0
fi

setpci -s "$port" CAP_EXP+30.w="000${GEN}:000f"   # Target Link Speed only
setpci -s "$port" CAP_EXP+10.w=0020:0020          # Retrain Link
sleep 2

now=$(cut -d' ' -f1 "/sys/bus/pci/devices/$ep/current_link_speed" 2>/dev/null)
width=$(cat "/sys/bus/pci/devices/$ep/current_link_width" 2>/dev/null)
echo "nvme-gen4-link: link now ${now:-?} GT/s x${width:-?} (LnkCtl2=$(setpci -s "$port" CAP_EXP+30.w))"
[[ "$now" == "$want" ]] || { echo "nvme-gen4-link: link did not retrain to $want GT/s"; exit 1; }
