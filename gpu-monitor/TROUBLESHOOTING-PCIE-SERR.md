# Case file: zappa2 PCIe SERR/PERR and unexplained hard hangs

Board under investigation: **TYAN S8056GME**, SP5, BIOS `5411B0030009`,
8× RTX 5090, `machine_id 143690`.

CPU: **AMD EPYC 9B14**, 96 cores / 192 threads. A cloud/OEM SKU rather than a
retail part — worth knowing if a spare is ever needed for the swap test below,
since these come from the secondary market.

RAM: 515,443 MiB (503 GiB) against 260,856 MiB of VRAM — a **1.98× ratio**.

This is a diagnosis record, not a runbook — the fault is not resolved. It exists
so the evidence survives the board swap, and so the same ground isn't re-covered
from scratch on the replacement.

Status as of **2026-09-21**: root cause of the **SERR/PERR events and the two
09/17 hangs** is still **not identified**; the leading theory is now CPU/socket,
with a PSU ground offset second. The **third hang (09/19) is explained** — a
memory-exhaustion livelock, unrelated to the PCIe fault and fixable in software.
The NVMe-link theory, which drove most of the early work, has been substantially
demoted — see "What the evidence ruled out".

---

## Current diagnosis (2026-09-21, revised)

Three hangs and two classes of PCIe error have been investigated. They are
**not one fault**. Best current reading:

| Observation | Status | Cause |
|---|---|---|
| 14× PERR at every cold boot | **Explained, benign** | Marginal Gen5 x2 link through 2 retimers, negotiating during training. Corrected, Advisory Non-Fatal, endpoint-only. |
| Hang 09/19 17:20 | **Explained** | Memory-exhaustion reclaim livelock. Unrelated to PCIe. Fixable in software. |
| Runtime SERRs on `00:01.4` / `00:01.5` | **Unexplained** | — |
| Hangs 09/17 15:07, 09/17 ~21:42, 09/20 ~23:49 | **Unexplained** | — |

The 09/20 hang is the control that separates the two classes. It happened
**after** swap was disabled and `earlyoom` armed, and its crashed boot log ends
at `23:48:56` on a routine `containerd: shim disconnected` with **no memory
pressure messages at all** — unlike 09/19, which logged five minutes of them.
So the memory mitigation worked, and what remains is the original fault on its
third occurrence.

It also retires an assumption held earlier in this document: the unexplained
hangs are **not** idle-only. 09/20 had container churn and an active renter.
Load appears to be irrelevant in both directions, which is consistent with the
temperature finding and with a contact-level fault that does not care what the
machine is doing.

### The hangs are I/O stalls, not crashes — 09/21 console capture

**This supersedes the earlier reading that the hangs were unexplained and
silent.** On 09/21, a monitor happened to be attached during a hang and showed
the kernel very much alive:

```
INFO: task monitor:5022  blocked for more than 122 seconds.
INFO: task kaalia:5027   blocked for more than 122 seconds.
INFO: task python:19668  blocked for more than 122 seconds.
INFO: task python:19665  blocked for more than 122 seconds.
Tainted: G  OE  6.8.0-124-generic
zappa2 login:
```

The kernel was printing to console and getty was still issuing login prompts.
The blocked tasks are in **uninterruptible sleep (D state)** — waiting on
something that never returns.

**This is an I/O stall, and it explains every previously inexplicable
observation:**

| Observation | Explanation under an I/O stall |
|---|---|
| No SSH | `sshd` must read from disk to authenticate; it blocks |
| Nothing in `journalctl -b -1` past the cutoff | `journald` cannot write to a stalled disk |
| No panic, no oops | Nothing crashed — the kernel is waiting, correctly |
| No SEL entry | The board is healthy; this is not a hardware fault the BMC can see |
| Rails nominal during a hang (09/19) | Correct — power was never involved |
| No AER record despite `pcie_ports=native` | The kernel could not write the record to the disk that had just gone away |

That last row retires the argument this document leaned on hardest. "A kernel
watching for PCIe errors logged none, therefore no PCIe error occurred" assumed
the kernel could still write. If the root filesystem's link dropped, it could
not.

**The stalled device is almost certainly `nvme0n1` at `03:00.0`** — behind root
port `00:01.5`, the exact device the SERRs have pointed at from the start. Not
confirmed: the console was photographed but the stack traces were not captured
(`Alt+SysRq+W` would have dumped them). If this recurs before the rebuild, that
is the one command worth running.

### This unifies the whole case file

The SERRs and the hangs are **the same fault at two severities**:

```
marginal contact in one root complex (00:01.x)
        │
        ├── mild  → link errors, corrected → SERR/PERR in the BMC SEL
        │
        └── severe → link drops → NVMe stops answering
                         │
                         └── every task touching the filesystem blocks in D state
                                 │
                                 └── host looks dead; nothing can be logged
                                     because logging needs the dead disk
```

Board #1's GPU-slot faults fit as the same mechanism on a different root
complex — which is why swapping drives and slots never helped and why the fault
"moved" between `00:01.4` and `00:01.5`. It was never about the device.

**The NVMe-link theory demoted earlier was closer to right than the demotion
allowed**, though not in its original form: the drive is healthy (SMART
pristine, current firmware), and the drive was never the problem. The *link* is,
and what makes the link marginal is upstream of it.

### Leading hypothesis for what remains

**Marginal contact at the SP5 socket affecting one root complex** — most likely
from uneven seating or torque, with a CPU die fault the less likely variant of
the same lead.

The reasoning, in the order the evidence supports it:

1. **The fault localizes to one root complex, not to devices.** Every runtime
   SERR has landed on `00:01.4` or `00:01.5` — sibling *functions of the same
   Genoa IO-die root complex*, not independent slots. Swapping drives and
   removing one NVMe moved the fault between siblings rather than eliminating
   it. That pattern points upstream of the devices.

2. **It crossed motherboards** — and seating explains that better than silicon
   does. A bad die travels with the part. Marginal socket contact does not travel
   at all: it recurs because the same person installs the CPU the same way each
   time. That accounts for two boards showing faults without requiring either
   board *or* the CPU to be defective, which is the cheaper explanation.

   SP5 is LGA-6096. Uneven clamping load leaves some pins in one region of the
   socket making marginal contact, and that region maps to particular root
   complexes — which is the clustering in point 1.

3. **Localization discriminates between the two survivors.** A PSU ground offset
   would be diffuse — it rides every link spanning the domains, so faults should
   scatter across slots. They do not. A fault inside one root complex produces
   exactly the clustering observed.

4. **The silence fits.** Three hangs, zero kernel output, even on a boot running
   `pcie_ports=native` with the kernel explicitly watching for PCIe errors. A
   failure inside the CPU complex destroys the thing that would record it.

5. **The board was electrically healthy during a hang.** BMC queried live on
   09/19: all rails in spec, no power, cooling or chassis faults, no SEL entry.

**Confidence: moderate. This is not proven**, and two alternatives remain live:

- **PSU ground offset** (lead #1 below) — weakened by the localization argument
  and the nominal rails, but the BMC cannot see the HP PSU rails, common-mode
  offsets, or fast transients, so it is not excluded.

  **Note on capturing rails during a hang:** the BMC reading must be taken
  *before* the power cycle. On 09/20 it was taken afterwards and is therefore a
  normal running value, not hang data. The 09/19 set remains the only
  during-hang rail snapshot.
- **A CPU die fault** rather than a contact problem. Same lead, worse prognosis:
  correct torque would not fix it. Considered less likely — EPYC dies rarely fail
  this way, and the removed CPU showed no damage — but not excluded.
- **Two independently marginal boards** — improbable, but both are used units and
  coincidence has not been ruled out.

### The test that would settle it

The 09/25 rebuild changes **two variables at once**: new board *and* corrected
socket torque. That makes its result ambiguous in one direction:

| Outcome after rebuild | Interpretation |
|---|---|
| Faults **persist** | **CPU indicted.** It is the only major component unchanged across three boards' worth of evidence. |
| Faults **stop** | Ambiguous — could be the board, could be the torque. Does not clear the CPU, but is consistent with the seating hypothesis being right. |

To get a clean answer, the CPU would have to be swapped independently. If a
spare SP5 part is ever available, that is the decisive experiment.

**Practical consequence #1: get the OS off that link.** This was already
recommended on DPC grounds and is now much stronger. With root on a SATA SSD, a
drop of the `00:01.x` link becomes a lost data volume rather than a dead host —
the kernel stays writable, logs the failure, and you get a diagnosable event
instead of a silent brick. Do this at the rebuild.

**Practical consequence #2:** treat socket preparation as the highest-value
work of the rebuild — raking-light inspection photographed before the CPU goes
in, and the SP5 torque sequence followed exactly. It is the only variable you can
influence that the leading hypothesis depends on.

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
| 09/17 23:31 | `MB_Air_Inlet_T` **Upper Critical**, 50°C | 8/8 rented, ~3.1kW load |
| 09/18 23:28, 09/19 03:21 | two cgroup OOM kills, tenants at ~170–178 GB | 8 tenants |
| 09/19 ~17:20 | **Third hang — memory-exhaustion livelock, cause identified** | heavy multi-tenant load |
| 09/19 | swap disabled, `earlyoom` armed | mitigation for the above |
| 09/20 ~23:49 | **Fourth hang — silent again, no memory pressure** | light container churn, one renter |
| 09/21 ~00:20 | **Fifth hang** — console showed `INFO: task ... blocked for more than 122 seconds`; the I/O-stall class is identified | one renter |
| 09/21 ~02:4x | **Sixth hang — the cleanest instance yet, see below** | one renter, idle |

The two rows that matter most are **09/17 ~21:42** (a hang on a kernel watching
for PCIe errors that logged none) and **09/19 ~17:20** (a hang with an
identified, unrelated cause). Both are explained below.

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
  Endpoint: 14. Root port: 0 at the time of that reading.

  **Updated 2026-09-21:** the root port now reads
  `aer_rootport_total_err_cor = 1`. The burst is still overwhelmingly
  downstream, but "zero upstream" no longer holds exactly, so the baseline
  to compare against after the rebuild is the **pair 14 / 1**, not 14 alone.
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

### The board's M.2 slots share one root complex — SATA is the only escape

Confirmed on 2026-09-21 from the running host:

```
$ lspci -tv | head
 +-01.2-[01]--                              # empty M.2 slot
 +-01.3-[02]--                              # empty
 +-01.5-[03]----00.0  Micron/Crucial 542b   # the NVMe, the failing link
 ...
 +-07.2-[09]--+-00.0  AMD FCH SATA Controller [AHCI mode]
              \-00.1  AMD FCH SATA Controller [AHCI mode]
```

`00:01.2`, `00:01.3` and `00:01.5` are all functions of the **same** `00:01`
host bridge. Every M.2 slot on this board hangs off the one root complex under
suspicion, so **a second NVMe provides capacity, not isolation** — both drives
share the fault and go away together.

The AHCI controller at `00:07.2` sits on a **different host bridge**. It is the
only storage path on this board that is independent of `00:01.x`. That makes
"OS on SATA" a hardware-confirmed mitigation rather than an assumption.

Physical connector not yet identified: the board has both a 7-pin SATA header
near the top edge and two SlimSAS connectors silkscreened `PCIE0-15J/SATA`
(BIOS-selectable PCIe/SATA, needing an SFF-8654 → 4× SATA breakout cable).
Settle this from the Tyan S8056 manual's layout diagram before ordering.

### The corrected errors are reported by the drive, not the root port

```
port_type: 0, PCIe end point
vendor_id: 0xc0a9, device_id: 0x542b     # Micron/Crucial
aer_agent=Receiver ID
```

`Receiver ID` means the **drive's** receiver is the side seeing bad symbols.
This does not assign fault — marginal contact upstream produces exactly this
signature at the downstream receiver — but it does keep the drive as a live
variable. It is **not** testable in the same session as the board swap: two
changes at once make a clean result uninterpretable. The drive stays as-is
across the rebuild, and only becomes the next experiment if the new board
reproduces the same AER count.

### The sixth hang closes the question of what the failure is

Measured live, while the host was hung, from another rig (2026-09-21):

| Check | Result | What it means |
|---|---|---|
| `ping 192.168.1.196` | **0% loss, 0.22 ms** | kernel alive, servicing interrupts, network stack fine |
| `ssh` | **cannot log in** | sshd needs the disk; the disk is gone |
| BMC `sel elist` | **last entry `49a`, 01:52:03** — the boot burst | the BMC saw nothing at the hang |
| BMC `sensor list` rails | **all nominal**, every rail in spec | no power event |

Rails at hang time: `VCC_12_RUN` 12.000, `VDD_12_RUN` 11.739, `VDD_5_RUN` 4.624
(lower critical 4.487), `VDD_33_RUN` 3.300, `CPU_SOC` 1.004. Nothing near a
threshold.

**A host that answers ICMP but cannot start a login shell is not crashed.** The
kernel is running. Everything that touches the filesystem is blocked in D state.
This is the I/O stall, and it is now confirmed rather than inferred.

The BMC's silence is itself informative and should not be read as "no evidence".
The BMC is an independent processor on standby power watching rails, thermals
and the PCH. If the board were browning out, overheating, or taking a machine
check, it would log it — it has done so for lesser events throughout this case.
Six hangs, six times nothing, with every rail in spec, **rules out a power fault,
a thermal trip, and any hard component fault the BMC can observe.** A downstream
PCIe link state change is not in its sensor set, so a link drop is exactly the
kind of failure that would produce this signature: total BMC silence, total
kernel-log silence, a live network stack, and a dead filesystem.

### The console capture names the failure: a transport error, not a media error

Photographed from the attached monitor during a hang (console output; the
timestamps place it ~10h22m into the boot that began Sep 19 17:38, so it is one
of the silent hangs, not necessarily the most recent):

```
[37313.714780] I/O error, dev nvme0n1, sector 5030994696 op 0x0:(READ) flags 0x80700 phys_seg 8
[37313.714805] nvme0n1: I/O Cmd(0x2) @ LBA 5287508016, 256 blocks, I/O Error (sct 0x3 / sc 0x71)
[37480.679661] INFO: task jbd2/nvme0n1p3-:2372 blocked for more than 122 seconds.
[37480.681763] INFO: task systemd-journal:2453 blocked for more than 122 seconds.
[37480.683910] INFO: task rasdaemon:3326        blocked for more than 122 seconds.
[37480.686109] INFO: task rs:main Q:Reg:3661    blocked for more than 122 seconds.
[37480.688372] INFO: task bash:3624             blocked for more than 122 seconds.
[37480.690660] INFO: task monitor:5015          blocked for more than 122 seconds.
[37480.692856] INFO: task kaalia:5023           blocked for more than 122 seconds.
[37480.695257] INFO: task python:906201/2/3     blocked for more than 122 seconds.
[38272.514742] systemd[1]: Failed to start systemd-journald.service - Journal Service.
```

**Decoding `sct 0x3 / sc 0x71`.** NVMe status code type `0x3` is *Path Related
Status*. It is **not** `0x2`, *Media and Data Integrity Errors*. Within that
class, `0x71` is *Host Aborted Command* (`NVME_SC_HOST_ABORTED_CMD` in the Linux
driver).

The distinction is the whole case:

- The drive did **not** report bad data, a failed read, or a media defect.
- The **host** cancelled the command because the controller stopped responding.
- The fault is therefore in the **transport** — the PCIe path between the CPU
  and the drive — not in the NAND, the drive controller, or the filesystem.

This is independent confirmation of the SMART data, which was pristine, and it
is what a link drop looks like from the kernel's side.

**The cascade, and why six hangs left no logs.** 167 seconds after the I/O
error, every disk-touching task is in D state. The list includes:

- `jbd2/nvme0n1p3` — the ext4 journal thread for **root**. Once this blocks,
  no write to the root filesystem can complete, by anyone.
- `systemd-journal` — the journal writer. It cannot record what is happening.
- `rasdaemon` — **the daemon whose sole job is logging hardware errors.**

The logger was blocked by the very event it existed to record. The absence of
kernel logs across all six hangs was never evidence that nothing happened; it
was a direct consequence of the failure. Fourteen minutes later systemd gives
up trying to restart journald entirely.

This also confirms why the host still answers ICMP while refusing a login:
network interrupts are serviced from memory, while `sshd` must read from a
filesystem whose journal thread is blocked.

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

### Inlet air reaches the board's critical threshold under full load

First observed 2026-09-17 23:31, with all 8 GPUs rented and drawing ~390W each:

```
448 | 09/17/2026 | 11:31:42 PM UTC | Temperature MB_Air_Inlet_T |
     Upper Critical going high | Asserted | Reading 50 > Threshold 50 degrees C
```

That is the air entering the board, not a component temperature. The CPU sat at
63°C, which looks fine until you note it is being cooled by 50°C intake — there
is no headroom left, and every rail regulator and socket contact on the board is
sitting in that air.

**Heat is not the trigger.** The event timeline runs the wrong way, and it is
worth stating plainly because it is easy to re-assume later:

| Event | Machine state | Thermal state |
|---|---|---|
| 14× PERR, every boot | just powered on | **coldest it ever is** |
| Hang #1, 09/17 15:07 | vacant | cool |
| Hang #2, 09/17 ~21:42 | near-idle, docker churn, GPUs at P8 | cool |
| 09/17 23:31 – 09/18 03:54, intake at 50°C twice, 8 GPUs at ~390W | full load | **hottest on record** |
| → outcome of that hottest stretch | **no hang, no SERR, no PERR** | — |

The hottest documented period produced nothing. Both hangs happened cool and
idle. The PERR bursts fire during boot-time link training, when every component
is at room temperature. If marginal contact were being pushed over the edge by
heat, faults would cluster in the hot hours; they do the opposite.

Contact resistance and rail droop *are* temperature-dependent, so heat remains a
plausible **long-term degradation** factor — sustained 50°C intake and repeated
thermal cycling age solder joints, connectors and capacitors. That could help
explain why a board became marginal over months. It does not explain why a given
hang happened at 21:42 on a cool, idle machine.

This also sharpens the ranking below: a **ground potential offset is present
whenever the machine is powered**, idle or not, and tracks neither load nor
temperature. That fits an idle-machine hang better than any thermal mechanism.

So the airflow work stands on its own merits — protecting the hardware, stopping
the GPU 5 power-limit throttling, keeping the alarm quiet. It should **not** be
expected to fix the SERRs or the hangs.

It is also a rig-level problem, not a board-level one. ~3.1kW of GPU heat into
the room comes back around as intake air. **Replacing the motherboard will not
fix it**, so it needs handling separately from the board swap.

Related, and visible in the same diag: **GPU 5 runs hottest while holding the
lowest fan speed** — 75°C at 36% fan, against 63–67°C at 64–71% on its
neighbours. It has already crossed the 78°C knee in
`POWER_LIMITS=("5090:500:78@475:80@450")` and been capped to 475W, so it is
losing throughput. `GPU_FAN_FLOOR=("5:80")` exists to correct this and is
**inert** — fan control needs an X server and the host is headless. This went
unnoticed for a long time because GPU 5 is the *coolest* card at idle; it only
becomes the limiting one under a full 8-GPU load.

### The third hang was memory exhaustion, not hardware

09/19 ~17:20, after 1 day 6 hours of heavy multi-tenant load. Unlike the first
two, **this one left a trail**, and it points somewhere else entirely.

```
17:14:59  systemd-journald: Under memory pressure, flushing caches.
17:15:05  Under memory pressure, flushing caches.
17:17:58  Under memory pressure, flushing caches.
   ...    (accelerating)
17:19:34  Under memory pressure, flushing caches.
17:19:36  ... every 2 seconds ...
17:20:15  Under memory pressure, flushing caches.
          [host stops responding]
```

Five minutes of escalating memory pressure ending in silence. That is a
**reclaim livelock**: the kernel is alive but spending all its time trying to
free memory and never making progress. It is not a crash, which is why nothing
panicked and nothing was logged beyond journald's own complaints.

**The BMC was queried while the host was hung** — the first time this was done
during a live hang — and every rail was in spec:

```
VCC_12_RUN    12.000 V   ok      CPU_CORE0     0.820 V   ok
VDD_12_RUN    11.826 V   ok      CPU_SOC       1.014 V   ok
VDD_5_RUN      4.624 V   ok      VDD_33_RUN    3.300 V   ok
```

plus `Main Power Fault: false`, `Power Control Fault: false`, `Cooling/Fan
Fault: false`, and no new SEL entry. The board was electrically healthy
throughout.

**Correction to an earlier finding in this document.** `VDD_5_RUN = 4.62V` was
recorded above as "below the ATX 4.75V minimum" and treated as supporting
evidence for the power-delivery theory. The board's own lower critical threshold
is **4.487V**, so the BMC considers 4.624V normal — and it reads *identically*
whether the host is running or hung. That steadiness indicates it is simply
where this board's 5V sensor sits, not an anomaly. It should not have been
counted as evidence.

**What this rules out:** sustained rail droop or sag as the hang mechanism.

**What it does not rule out:** the BMC cannot see the HP PSU rails at all (all
PSU sensors report `Disabled`), a common-mode ground offset would not appear in
single-ended rail readings, and the BMC samples far too slowly to catch a
microsecond transient.

**What it does not explain:** the 09/17 hangs. That boot's log ended mid-routine
(`nvidia-smi -pm 1` at 21:42:27) with no pressure messages at all, and the
machine was idle. Either there are two distinct failure modes here, or the
earlier ones livelocked before journald could complain. Treat them as separate
until evidence says otherwise.

**Context.** Two cgroup OOM kills preceded it (09/18 23:28 and 09/19 03:21),
each on a tenant holding 170–178 GB of a 503 GB host, with 26 GB already in
swap. The kernel OOM killer fired successfully on those two occasions; on the
third it did not arrive before the system wedged. Swap thrashing to the root
NVMe under reclaim pressure makes livelock more likely, not less, since reclaim
then stalls on disk I/O.

**Mitigation — implemented 2026-09-19.** Swap disabled and `earlyoom` installed.

The swap partition (`/dev/nvme0n1p2`, 256 GB) was `swapoff`'d and its fstab entry
commented. On a 503 GB host with cgroup-limited containers, swap mostly granted
the kernel 256 GB of runway to thrash into before admitting defeat — and that
thrash, on the same NVMe as root and `/var/lib/docker`, is the livelock. A tenant
exceeding its limit should be OOM-killed promptly instead.

```bash
sudo swapoff -a
sudo sed -i '/swap/s/^/#/' /etc/fstab
sudo apt install -y earlyoom
sudo tee /etc/default/earlyoom >/dev/null <<'CONF'
EARLYOOM_ARGS="-m 10 -s 10 -r 3600 --avoid ^(systemd|sshd|dockerd|containerd|kaalia|monitor|launch_kaalia|gpu_monitor) --prefer ^(python|python3|ray|pt_main_thread)"
CONF
sudo systemctl restart earlyoom
```

Verified armed:

```
mem total: 515442 MiB, swap total:    0 MiB
sending SIGTERM when mem <= 10.00% and swap <= 10.00%
mem avail: 410063 of 515442 MiB (79.56%), swap free:    0 of    0 MiB ( 0.00%)
```

SIGTERM at ~50 GB available, SIGKILL at ~25 GB.

**Two gotchas worth remembering:**

- earlyoom requires free memory **and** free swap below threshold. With swap
  present and largely unused it will *never fire*, which is how it looked
  installed but inert on the first attempt. `swap total: 0 MiB` in its startup
  log is the line that confirms memory alone governs.
- `apt install` starts the service immediately, so it snapshots swap and reads
  `/etc/default/earlyoom` **before** you have written either. Always `systemctl
  restart earlyoom` afterwards and re-read the startup lines.

`--avoid` keeps it away from sshd, docker and kaalia, so a kill never costs
remote access or the Vast agent. Expect tenants to be OOM-killed sooner and more
often: the trade is one dead container instead of eight lost rentals and a manual
power cycle.

## Open leads

Ranked by how well each explains the **SERR/PERR events and the two 09/17
hangs**. The 09/19 hang has its own explanation (see above) and is excluded.

The nominal-rail reading taken during that hang weakens lead #1 as a *sag*
mechanism while leaving the ground-offset variant intact, and correspondingly
strengthens lead #2.

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

Also relevant: the `VDD_5_RUN` reading above was taken under favourable thermal
conditions, so it is a best case rather than a worst one.

#### Why this theory outranks the others

It is the only mechanism that survives all four constraints at once:

1. **Crosses motherboards.** Board #1 faulted on the GPU slots; board #2 on the
   NVMe ports. The PSUs are the only part that did not change.
2. **Crosses subsystems.** A ground offset rides on every link that spans the two
   domains, so it is not tied to any one slot, device or controller.
3. **Independent of load.** A ground offset exists whenever the machine is
   powered. Both hangs happened idle.
4. **Independent of temperature.** See the heat section above — the hottest
   stretch on record produced no faults at all.

Nothing else on the list satisfies more than two of those.

#### The measurement

**What you are looking for:** a voltage difference between the GPU PSU ground
domain and the motherboard PSU ground domain. In a correctly bonded system this
is essentially zero. Anything above a few tens of mV, especially if it moves with
load, means return current is finding a path it should not — and that path is
through the PCIe connectors' ground pins, which is exactly where it would corrupt
signalling.

**Tools:** any decent DMM on DC millivolts. An oscilloscope would be better (it
would show noise and transients a DMM averages away), but a DMM answers the
question well enough to act on.

**Safety first.** Mains-connected supplies, high current, exposed terminals:

- Measure **ground-to-ground only**. Never probe between a ground and a 12V rail
  with a meter set to a low range.
- Keep one hand behind your back on live work. Do not let a probe slip across
  adjacent terminals — an accidental short on an HP 1500W breakout board is
  violent.
- Use the DC millivolt range, not AC, not ohms. Never use continuity/ohms on a
  powered system.
- If anything feels wrong, power down and use test point (A) below instead — it
  is safe and still informative.

**Where to probe.** Three reference points, in increasing order of usefulness:

- **(A) Chassis-to-chassis, powered off.** Ohms between a GPU breakout board
  ground screw and the motherboard standoff. Should be well under 1 Ω. A high or
  unstable reading here means the bonding is bad and you have your answer without
  ever powering on.
- **(B) Breakout ground → PSU ground, idle.** DMM in DC mV between a ground
  terminal on one Acxico breakout board and a black wire / ground terminal on the
  Corsair. Machine powered, GPUs idle.
- **(C) Same two points, under full load.** The reading that matters. Needs all 8
  GPUs working, so take it while a renter is hammering the machine.

**Also worth taking:** between two *different* HP breakout boards. The HP units
are daisy-chained, so current sharing between them is itself a suspect, and a
difference here would point at the daisy-chain rather than the HP/Corsair split.

**Reading the result:**

| Idle | Under load | Interpretation |
|---|---|---|
| < 10 mV | < 10 mV | Theory dead. Move to lead #2 (socket/CPU). |
| < 10 mV | 50 mV+ | **Strong hit.** Load-dependent offset — return current is sharing a path it should not. |
| 50 mV+ | 50 mV+ | Static offset. Bonding problem, present at all times — fits idle hangs well. |
| Unstable / jumping | any | Intermittent bond. Worst case for diagnosis, best fit for intermittent faults. |

Record the actual numbers, idle and loaded, whatever they are. A clean near-zero
result is just as valuable — it eliminates the leading theory and promotes socket
seating to the top before the rebuild.

**If it confirms:** the fix is bonding the ground domains together — a heavy
(12–14 AWG) ground strap between the GPU PSU ground and the motherboard PSU
ground, keeping the connection short and low-impedance. Do this at the rebuild.
Note that bonding fixes the *symptom*; if one supply is faulty it still needs
replacing, which the PMBus blindness (all PSU sensors `Disabled`) makes harder to
determine.

**Timing.** Do this before the 09/25 swap, while the machine is still assembled
and under real load. Once the rig is apart the loaded reading is gone, and it is
the one that matters. It is non-destructive and does not disturb the rental.

### 2. CPU / socket seating

SP5 is LGA-6096 — pins in the socket, pads on the CPU. Marginal contact on IO-die
power or ground pins produces exactly this: instability that moves around the
root complex and doesn't localize to one device.

Inspection of the removed CPU showed no visibly bent pins and it seated with a
normal click, so this is not confirmed — but "looks flat" does not rule out
marginal contact, and the rebuild is the opportunity to eliminate it via correct
torque sequence.

**The CPU is as much a constant as the cabling is.** This was raised early in the
investigation and under-weighted: the same CPU moved from board #1 to board #2.
Any theory built on "what did not change between the two boards" applies to it
exactly as well as it applies to the PSUs and wiring.

The 09/19 BMC snapshot sharpens this. A host that stops executing while its
board reports clean power, no faults, and normal temperatures fits a fault
inside the CPU complex — core, IO die, or socket contact — better than anything
external. A failure there also destroys the thing that would have logged it,
which matches three hangs producing no kernel output.

This makes the socket inspection and torque work on 09/25 the **most important**
part of the rebuild rather than a secondary precaution. Photograph the socket
under raking light before the CPU goes in, and follow the SP5 sequence exactly.

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
failure. Attach the bundle from `gpu-monitor/capture-fault-evidence.sh`.

---

## Rebuild checklist (new board)

Before teardown:

- [ ] Run `/home/ronyzap/ronyzap.github.io/gpu-monitor/capture-fault-evidence.sh`
      (full path — it is not on `$PATH`) and archive the tarball off-box.
- [ ] Back up `/var/lib/vastai_kaalia/machine_id` — **this is the Vast identity**.
      Losing it resets reliability history.
- [ ] Back up `/etc/gpu_monitor.conf`.
- [ ] **Measure PSU ground potential (see lead #1) — idle AND under load.**
      The loaded reading is the one that matters and it is only available while
      the rig is assembled and rented. Once it is apart, that data is gone.
- [ ] BIOS screenshots via iKVM: Above 4G Decoding, Resizable BAR, IOMMU, PCIe
      settings.

On arrival:

- [ ] Socket inspection under raking light, photographed, before the CPU goes in.
- [ ] BMC standby test before installing anything.
- [ ] Firmware updates (BIOS newer than `5411B0030009` exists).

Separately from the board swap, because a new board will not change it:

- [ ] Address intake air. `MB_Air_Inlet_T` hitting 50°C is a room/airflow
      problem — ~3.1kW leaving 8 GPUs comes back as intake.
- [ ] Decide on GPU 5 fan control. Either a minimal X stub so `GPU_FAN_FLOOR`
      works, or accept the `POWER_LIMITS` cap and drop the inert setting.

During the rebuild:

- [ ] Correct SP5 torque sequence. **This is the experiment** — see the decision
      note below.
- [ ] **Move the existing Crucial T705 across untouched.** Do not change the
      drive in the same session. No spare drives are on hand, and even with
      one, changing two things at once means a clean result answers nothing.
      One variable: the board.
- [ ] Reuse the same OS drive contents to preserve `machine_id`.
- [x] **AER baseline captured 2026-09-21 02:21 UTC**, boot
      `fde9aaf598e34503a3017806116b3f22`, host idle, ~29 min uptime:

      | counter | path | value |
      |---|---|---|
      | `NonFatalErr` / `TOTAL_ERR_COR` | endpoint `03:00.0` | **14** |
      | `aer_rootport_total_err_cor`    | root port `00:01.5` | **1** |

      Every other endpoint counter (`RxErr`, `BadTLP`, `BadDLLP`, `Rollover`,
      `Timeout`, `CorrIntErr`, `HeaderOF`) reads 0. Stable across three
      consecutive reads, i.e. not accumulating while idle — the 14 are the
      link-training burst and nothing since.

      **Re-read both paths after the rebuild, at comparable idle uptime.**
      Lower or zero = the board or its seating was the fault. Still 14/1 =
      it was not, and the SATA root becomes the next step.

**Decision, 2026-09-21: SATA root is deferred.** The socket reseat is being
tried first, on the reasoning that if it fixes the fault nothing else was
needed. The cost accepted is that root stays on `00:01.5`, so a post-reseat
failure is still a silent, unloggable brick. **A second hang after the reseat
is the trigger to do the SATA root**, not to attempt a third mechanical fix.

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
