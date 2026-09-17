#!/usr/bin/env bash
# Capture a complete hardware-fault evidence bundle before a board swap or RMA.
#
#   sudo ./capture-fault-evidence.sh [BMC_IP]
#
# Writes a timestamped tarball to /var/tmp. Everything in it is read-only
# collection -- this script changes nothing on the machine.
#
# BMC_IP is optional. If given, the SEL is pulled over the network (works even
# when the host is wedged, from another rig). If omitted, the SEL is read over
# the local KCS interface, which requires the host to be up.
set -uo pipefail

HOST=$(hostname -s)
STAMP=$(date -u +%Y%m%d-%H%M%SZ)
OUT="/var/tmp/fault-evidence-${HOST}-${STAMP}"
BMC_IP="${1:-}"
mkdir -p "$OUT"

# ipmitool, either over LAN to a given BMC or locally over KCS.
ipmi() {
  if [ -n "$BMC_IP" ]; then
    ipmitool -I lanplus -H "$BMC_IP" -U "${BMC_USER:-root}" -P "${BMC_PASS:?set BMC_PASS in the environment}" "$@"
  else
    ipmitool "$@"
  fi
}

run() {  # run <outfile> <command...>
  local f="$OUT/$1"; shift
  printf '$ %s\n\n' "$*" > "$f"
  "$@" >> "$f" 2>&1 || echo "[exit $?]" >> "$f"
}

echo "collecting into $OUT"

# ---- BMC: the SEL is the part that survives a host hang ----------------------
# Three formats on purpose: elist is human-readable, raw survives ipmitool
# version differences, and the CSV-ish dump is what you attach to an RMA.
run sel-elist.txt        ipmi sel elist
run sel-info.txt         ipmi sel info
run sel-raw.txt          ipmi sel list -v
run sensors-bmc.txt      ipmi sensor list
run sdr-full.txt         ipmi sdr elist full
run mc-info.txt          ipmi mc info
run watchdog.txt         ipmi mc watchdog get
run chassis-status.txt   ipmi chassis status
run fru.txt              ipmi fru print

# ---- Host: kernel's view, current boot and the one before ------------------
# -b -1 is the important one after a hang: it is the boot that died.
run dmesg-current.txt    journalctl -k -b  --no-pager
run dmesg-previous.txt   journalctl -k -b -1 --no-pager
run journal-previous.txt journalctl    -b -1 --no-pager -n 2000
run boots.txt            journalctl --list-boots --no-pager

# ---- PCIe topology and error counters --------------------------------------
run lspci-tree.txt       lspci -tv
run lspci-verbose.txt    lspci -vvv
run lspci-errors.txt     sh -c "lspci -vvv 2>/dev/null | grep -B3 -A6 -E 'UESta|CESta|DevSta|LnkSta|DPC'"
run aer-counters.txt     sh -c 'for f in /sys/bus/pci/devices/*/aer_dev_*; do [ -e "$f" ] && { echo "== $f"; cat "$f"; }; done'
run ras-mc.txt           sh -c 'ras-mc-ctl --errors 2>/dev/null || echo "ras-mc-ctl not installed"'

# ---- Storage ----------------------------------------------------------------
run nvme-list.txt        nvme list
run lsblk.txt            lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINT
for dev in /dev/nvme?n1; do
  [ -e "$dev" ] || continue
  n=$(basename "$dev")
  run "smart-${n}.txt"      smartctl -a "$dev"
  run "nvme-errlog-${n}.txt" nvme error-log "$dev"
done

# ---- Platform identity ------------------------------------------------------
run dmidecode.txt        dmidecode
run cmdline.txt          cat /proc/cmdline
run uname.txt            uname -a
run nvidia-smi.txt       nvidia-smi -q
run mcelog.txt           sh -c 'journalctl -k --no-pager | grep -iE "mce|machine check|hardware error" | tail -200'

tar czf "${OUT}.tar.gz" -C /var/tmp "$(basename "$OUT")"
echo
echo "bundle: ${OUT}.tar.gz"
ls -lh "${OUT}.tar.gz"
