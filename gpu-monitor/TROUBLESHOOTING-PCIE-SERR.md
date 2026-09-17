# Case file: zappa2 PCIe SERR/PERR and unexplained hard hangs

Board under investigation: **TYAN S8056GME**, AMD Genoa/SP5, BIOS `5411B0030009`,
8× RTX 5090, `machine_id 143690`.

This is a diagnosis record, not a runbook — the fault is not resolved. It exists
so the evidence survives the board swap, and so the same ground isn't re-covered
from scratch on the replacement.

Status as of **2026-09-17**: root cause **not identified**. The leading theories
are power delivery and CPU/socket seating. The NVMe-link theory, which drove most
of the early work, has been substantially demoted — see "What the evidence ruled
out".

---

## Symptom

Two distinct things happen, and it took a while to establish they may not be the
same fault:

**1. PCIe SERR/PERR bursts.** The BMC logs `Critical Interrupt #0x80 | PCI PERR`,
typically 14 at a time, all within the same second. Visible only via IPMI:

```bash
ipmitool -I lanplus -H <bmc-ip> -U root -P '<pw>' sel elist | grep -E 'SERR|PERR'
```

**2. Silent hard hangs.** The host stops responding — no ping, no SSH — while
the BMC stays reachable and `chassis power status` reports **on**. Nothing is
logged on either side. Recovery requires `ipmitool chassis power cycle`.

The hangs are the expensive failure. They kill live rentals and require manual
intervention.

---

## Timeline

| Date | Event | Config at the time |
|---|---|---|
| (earlier board) | SERR attributed to **GPU slots 0/1** | motherboard #1 |
| 09/12–09/14 | 6 SERR events on root port `00:01.4` | 2 NVMe installed |
| 09/14–09/17 | 3 days clean | 1 NVMe (second removed) |
| 09/17 15:07 | SERR on port `00:01.5` + hard hang | 1 NVMe |
| 09/17 15:55 | 14× PERR at boot | after power cycle |
| 09/17 ~21:42 | **Second hard hang, zero logs anywhere** | `pcie_ports=native` active |
| 09/17 21:50 | 14× PERR at boot | after power cycle |

The single most important row is **09/17 ~21:42**, explained below.

---

## What the evidence established

### The boot-time PERR burst is not the fault

Every cold boot produces ~14 `PCI PERR` entries in the BMC SEL, and a matching
set of CPER records in the kernel log, all within one second of each other during
PCIe link training. Decoded:

```
{1}[Hardware Error]:   device_id: 0000:03:00.0
{1}[Hardware Error]:   vendor_id: 0xc0a9, device_id: 0x542b   # Micron/Crucial T705
{1}[Hardware Error]:   port_type: 0, PCIe end point
{1}[Hardware Error]:  Error 12, type: corrected
```

Key properties:

- `type: corrected` — the link recovered on its own.
- All errors land at the **endpoint** (`03:00.0`), **zero** at the root port.
  Confirmed via sysfs:
  ```bash
  for d in /sys/bus/pci/devices/0000:00:01.*/; do
    [ -f "$d/aer_dev_correctable" ] && echo "$d $(grep TOTAL "$d"/aer_dev_*)"
  done
  ```
  Endpoint: 14. Root port: 0. Downstream-only.
- `aer_status 0x00002000` = bit 13, **Advisory Non-Fatal**.
- All fire at t+6.5s, during link training, then stop. Stable for hours after.

This is a marginal-but-recovering link negotiating Gen5. It is noise against the
hangs, and mistaking it for the fault cost real time. **Do not treat a boot-time
PERR burst as a new event.**

### The SERR event data decodes to a specific port

```bash
ipmitool -I lanplus -H <bmc-ip> -U root -P '<pw>' sel get 0x421
```

Event data `a5000d` → bus `0x00`, device `1`, function `5` = **`00:01.5`**.

`00:01.4` and `00:01.5` are sibling functions of the **same CPU IO-die root
complex**, not independent slots. A fault moving between them has not moved
between physical subsystems — it has stayed inside one root complex.

### The link is running at its limit

```bash
lspci -vvv -s 03:00.0 | grep -E 'LnkSta|Retimer'
```

Gen5 (32GT/s), **Width x2** (not x4), **through 2 retimers**. Gen5 signalling
across retimers at reduced width is the most marginal configuration this drive
could be in, which explains the correctable errors — but not the hangs.

### The drive itself is healthy

Crucial T705 4TB, firmware `PACR5111` (confirmed current). SMART pristine, never
exceeded 87°C, currently 41°C, `Warning/Critical Comp Temperature Time` both 0.
`nvme error-log` clean. The drive is not failing.

---

## What the evidence ruled out

### The NVMe / M.2 / retimer theory — demoted

Three independent facts work against it:

1. **Motherboard #1 faulted on the GPU slots, not the NVMe.** No M.2-specific
   explanation survives this. It was the strongest objection in the whole
   investigation and it was raised early.
2. **The board has only 2 M.2 slots.** Several "move it to a cleaner slot"
   suggestions were made before this was established. They were not actionable.
3. **The 21:42 hang produced no PCIe errors at all** — see below.

### The watchdog did not cause the second hang

```
RuntimeWatchdogUSec=0
WatchdogLastPingTimestampMonotonic=18446744073709551615
```

`ipmi_watchdog` was loaded with `start_now=0` roughly 65 seconds before the hang,
which is an uncomfortable correlation. But the timer was never started (BMC
confirmed `Stopped`, `Action: No action`), systemd never opened `/dev/watchdog`
(`RuntimeUSec=0`, ping timestamp is the `2^64-1` never-pinged sentinel), the BMC
logged no `Watchdog2` assertion, and the chassis never lost power — a watchdog
reset would have power-cycled and recovered on its own. It did not.

Decisively: **the first hang at 15:07 happened with the module not loaded at
all.** The failure mode predates the watchdog work.

### The hang is not arriving through the PCIe error path

This is the most important single finding, and it only became available after
switching to OS-managed AER:

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="pcie_aspm=off pcie_ports=native ..."
sudo update-grub && reboot
```

`pcie_ports=native` takes PCIe error handling away from firmware and gives it to
the kernel. Before this change, firmware-first handling swallowed everything and
`journalctl -k -b -1` was empty after a crash — which looked like evidence but
was just the logging being disabled.

After the change, the 21:42 hang was captured on a kernel that **was** watching:

```bash
sudo journalctl -k -b -1 --no-pager | tail -120
```

Last line: `21:42:27`, a routine `nvidia-smi -pm 1` from kaalia. Before it, cron
at 21:42:01 and docker veth churn at 21:40. Then nothing. No panic, no AER, no
DPC containment, no NVMe timeout, no soft lockup, no OOM. A clean cutoff in the
middle of normal operation, with the BMC SEL equally silent.

A kernel configured to log PCIe errors, that logs none, during a hang, is
evidence that no PCIe error occurred. What remains is the class of faults that
kill a machine faster than it can write to disk: **power delivery, CPU/socket, or
the IO die itself**.

### DPC was already enabled and did not help

```
pcieport 0000:00:01.5: DPC: enabled with IRQ 58
DpcCtl: Trigger:1 ... INT+
```

Downstream Port Containment was armed on the faulting port during the 15:07
crash. The machine hung anyway. That is DPC working as designed with a fatal
outcome — containment disables the link, and the contained device held the root
filesystem, so the kernel could no longer read `/`.

**Implication for the rebuild:** put the OS on a SATA SSD. On a separate
controller, DPC containment of the NVMe becomes survivable instead of a wedge.

---

## Open leads

Ranked by how well each explains *both* boards and *both* failure modes.

### 1. Ground potential offset between PSU domains (leading)

Power architecture:

- GPUs: **HP 704604-001 1500W** common-slot PSUs → **Acxico** breakout boards.
  The HP units are **daisy-chained to each other**.
- Motherboard: **Corsair RM1200x SHIFT**.

These are separate ground domains. A potential difference between them appears as
common-mode noise on every PCIe link that spans the two — which is every GPU
link, and indirectly the whole root complex. It is the only mechanism proposed so
far that explains a fault crossing motherboards *and* moving between unrelated
subsystems (GPU slots on board #1, NVMe ports on board #2).

Supporting: `VDD_5_RUN = 4.62V`, below the ATX 4.75–5.25V minimum. All other
rails nominal.

Aggravating: **all PSU sensors report `Disabled`** — there is no PMBus telemetry,
so PSU-side voltage and current are invisible.

**The measurement that settles it**, with a DMM between an HP breakout board
ground terminal and the Corsair ground:

- Near 0 V, idle and under load → theory dead.
- Tens of mV or more, especially load-dependent → root cause found.

Do this before the rebuild. It is the single highest-value outstanding test, and
it is non-destructive.

### 2. CPU / socket seating

SP5 is LGA-6096 — pins in the socket, pads on the CPU. Marginal contact on IO-die
power or ground pins produces exactly this: instability that moves around the
root complex and doesn't localize to one device.

Inspection of the removed CPU showed no visibly bent pins and it seated with a
normal click, so this is not confirmed — but "looks flat" does not rule out
marginal contact, and the rebuild is the opportunity to eliminate it via correct
torque sequence.

### 3. Drive / M.2 / retimer marginality

Demoted, not dismissed. It cleanly explains the correctable boot-time AER bursts.
It does not explain the hangs or board #1.

---

## Capturing evidence

`gpu-monitor/capture-fault-evidence.sh` collects everything below into one
tarball. Run it **before** any teardown — a rebuild wipes the boot history that
`journalctl -b -1` depends on.

```bash
# From the affected host (BMC read locally over KCS):
sudo ./gpu-monitor/capture-fault-evidence.sh

# From another rig, when the host is wedged (BMC over the network):
export BMC_PASS='<bmc-password>'
sudo -E ./gpu-monitor/capture-fault-evidence.sh 192.168.1.247
```

The SEL is the part that matters most, because it survives a host hang. By hand:

```bash
BMC=192.168.1.247
ipmitool -I lanplus -H $BMC -U root -P "$BMC_PASS" sel elist > sel-elist.txt
ipmitool -I lanplus -H $BMC -U root -P "$BMC_PASS" sel list -v > sel-raw.txt
ipmitool -I lanplus -H $BMC -U root -P "$BMC_PASS" sel info > sel-info.txt
```

`sel elist` is the readable form. `sel list -v` includes the raw event bytes
needed to decode which bus/device/function a SERR came from — `sel get <id>` on a
specific entry gives the same detail for one event.

The SEL is a **ring buffer**. Check `sel info` for `Entries` vs `Free Space`; once
it fills, the oldest records are lost. Export before it wraps, and don't clear it
(`sel clear`) while a return is open.

---

## For the eBay return (order #12-15121-41590)

The defensible claim, stated in terms the evidence supports:

> Two unexplained hard hangs in one day on an **idle** machine. BMC responsive
> throughout, chassis power never lost. **Zero diagnostic output** on either the
> kernel or BMC side, on a boot explicitly configured for OS-managed PCIe error
> logging (`pcie_ports=native`). Repeated `PCI PERR` bursts logged by the BMC
> across multiple boots.

An idle box that wedges twice with no logged cause is not a workload or software
failure. Attach the bundle from `capture-fault-evidence.sh`.

---

## Rebuild checklist (new board)

Before teardown:

- [ ] Run `capture-fault-evidence.sh` and archive the tarball off-box.
- [ ] Back up `/var/lib/vastai_kaalia/machine_id` — **this is the Vast identity**.
      Losing it resets reliability history.
- [ ] Back up `/etc/gpu_monitor.conf`.
- [ ] Measure PSU ground potential (see lead #1) — idle and under load.
- [ ] BIOS screenshots via iKVM: Above 4G Decoding, Resizable BAR, IOMMU, PCIe
      settings.

On arrival:

- [ ] Socket inspection under raking light, photographed, before the CPU goes in.
- [ ] BMC standby test before installing anything.
- [ ] Firmware updates (BIOS newer than `5411B0030009` exists).

During the rebuild:

- [ ] Correct SP5 torque sequence.
- [ ] **OS on a SATA SSD**, not the NVMe (see DPC section).
- [ ] Reuse the same OS drive contents to preserve `machine_id`.
- [ ] Both NVMe slots populated, so slot-vs-drive stays testable.

After first boot:

- [ ] Compare AER baseline against this board: **14 errors / 47 dmesg AER lines**.
      Materially fewer means the board was the problem. The same means it wasn't.
- [ ] Configure the IPMI watchdog *here*, where a clean baseline makes the test
      meaningful — see below.

---

## Deferred: IPMI watchdog

Intentionally **not** enabled on this board. It was configured far enough to
confirm the BMC accepts the timeout, then left unarmed because the correlation
with the second hang couldn't be cleanly ruled out on hardware being replaced
anyway.

What was established: the driver loads and pushes `timeout=300` to the BMC, but
the BMC keeps `Action: No action` until something actually **starts** the timer.
With `start_now=0`, that means systemd opening `/dev/watchdog`.

On the new board:

```bash
cat <<'EOF' | sudo tee /etc/modprobe.d/ipmi_watchdog.conf
options ipmi_watchdog action=reset timeout=300 pretimeout=60 panic_wdt_timeout=120 nowayout=0 start_now=0
EOF
echo ipmi_watchdog | sudo tee /etc/modules-load.d/ipmi_watchdog.conf
sudo modprobe ipmi_watchdog
grep . /sys/module/ipmi_watchdog/parameters/{action,timeout,nowayout}   # reset / 300 / 0

# only after the above reads correctly:
sudo sed -i 's/^#\?RuntimeWatchdogSec=.*/RuntimeWatchdogSec=120/' /etc/systemd/system.conf
sudo systemctl daemon-reexec
ipmitool mc watchdog get    # expect: Hard Reset, countdown ticking below 300
```

Notes:

- `nowayout=0` lets the watchdog disarm cleanly on shutdown, instead of resetting
  mid-reboot.
- 300s is deliberately long. A rig under heavy GPU load can stall userspace
  briefly; a false reset kills a paying rental.
- If systemd doesn't arm it, check `ls -l /sys/class/watchdog/*/device/driver` —
  more than one watchdog device means you need an explicit `WatchdogDevice=`.
- **Test only while vacant.** `echo c > /proc/sysrq-trigger` forces a panic; the
  BMC should reset ~2 minutes later unaided.
