# Cap the OS NVMe link at Gen4 (zappa2)

## Why

zappa2's OS drive (Crucial T705, root port `00:01.4`) trains at Gen5 x2.
On 2026-10-26 `nvme-temp-log` caught it going from 63 °C to 89 °C within a
minute during a container image pull, right before the link dropped and the
host hung (see `../CASE-CPU-RETURN-EPYC9B14.md`). The TYAN/MiTAC S8056 BIOS
has no link-speed option for the onboard M.2 slots, so this caps the link
from Linux instead.

Gen4 x2 is ~3.9 GB/s. That is still far faster than any image pull or
renter workload needs, and it halves the drive's peak transfer rate and cuts
its Gen5 PHY power, so heat builds up more slowly.

## How it works

`nvme-gen4-link.sh` finds the drive's root port from sysfs, writes Target
Link Speed (Link Control 2, bits 3:0) on that port, and sets Retrain Link.
This is the standard PCIe mechanism that Linux's own bandwidth controller
(`drivers/pci/pcie/bwctrl.c`) uses. The setting is lost on reboot, so the
systemd unit re-applies it at every boot, before Docker starts.

Not yet confirmed on this board. AMD documents nothing specific for Genoa,
so verify it the first time (below). A retrain on a marginal link can fail,
and a failure drops the OS disk exactly like the crashes it is meant to
prevent (the watchdog then reboots). Run the first test with no renters on
the machine.

## First run (during a maintenance window, as root)

```
install -m 755 gpu-monitor/nvme-gen4-link/nvme-gen4-link.sh /usr/local/sbin/nvme-gen4-link.sh
/usr/local/sbin/nvme-gen4-link.sh nvme0 4
lspci -s 03:00.0 -vv | grep -E "LnkSta:"          # expect: Speed 16GT/s, Width x2
```

If that works, make it persistent:

```
cp gpu-monitor/nvme-gen4-link/nvme-gen4-link.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable nvme-gen4-link
```

After the next reboot: `journalctl -u nvme-gen4-link -b` should end with
`link now 16.0 GT/s x2`.

To undo: `systemctl disable nvme-gen4-link`, then reboot (or run the script
with `5` to retrain back to Gen5).
