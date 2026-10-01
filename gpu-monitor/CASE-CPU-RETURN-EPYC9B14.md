# Return/dispute case: AMD EPYC 9B14 — suspected defective CPU

Host: zappa2. CPU: **AMD EPYC 9B14**, 96c/192t (OEM-exclusive SKU, not retail
channel). Full technical history lives in `TROUBLESHOOTING-PCIE-SERR.md` —
this file is the condensed, dispute-facing summary and is kept separate so it
can be attached or forwarded without the full investigation log.

Status: **CPU return not yet filed with the original seller** — a defect
claim was filed, but a **bank/card dispute** is being prepared as a fallback
if the seller does not resolve it. This document is the evidence package for
that dispute.

---

## The claim, stated plainly

> The same PCIe fault signature (corrected SERR/PERR bursts, and at least one
> silent host hang, on the CPU's own IO-die root complex) has now been
> observed across **three different motherboards**. The motherboard has been
> replaced twice and the fault persists. The CPU is the only major component
> that has remained constant across all three builds. By elimination, the
> motherboard is cleared and the CPU is the leading suspect.

---

## Why the CPU, not the boards

1. **Three motherboards, one fault signature.** If any single board's NVMe
   slot, chipset, or traces were the root cause, replacing the board should
   have cleared it. It did not, twice in a row (board #1 → #2 → #3, same
   class of PCIe error each time — GPU-slot SERRs on board #1, NVMe-port
   SERRs on board #2, recurrence again on board #3 as of 2026-10-01).

2. **The fault localizes to the CPU's own root complex, not to a device.**
   On board #2, every SERR landed on `00:01.4` or `00:01.5` — sibling
   functions of the **same Genoa IO-die root complex** — not independent
   slots. Swapping which NVMe slot was populated moved the fault between
   siblings; it never went away. That pattern points upstream of any one
   device, to the CPU's PCIe controller.

3. **2026-10-01 evidence reinforces this, it does not point at the drive.**
   `lspci -vv -s 03:00.0` on the current (3rd) board shows the primary NVMe —
   a Crucial T705, rated and negotiating `LnkCap: 32GT/s x4` — currently
   training down to `LnkSta: 32GT/s x2 (downgraded)`. On this class of
   platform the primary M.2 slot is wired directly to the CPU's own PCIe
   root complex, not through the chipset. A link-width downgrade like this,
   recurring across independently-wired slots on independent boards, is the
   signature of a marginal **source-side** (CPU) lane or SerDes, not a
   drive defect — the drive's SMART health has been confirmed pristine
   throughout (see `TROUBLESHOOTING-PCIE-SERR.md`, "The drive itself is
   healthy").

4. **A board-level defect would not explain the hang's silence.** On board
   #2, a host hang occurred with the BMC fully responsive, all rails
   nominal, no SEL entry, and the kernel itself alive (serving ICMP,
   printing D-state task dumps) but unable to complete disk I/O. That is
   consistent with a fault inside the CPU's IO die taking down the one
   link that happened to be carrying root, not a motherboard component
   failing outright.

5. **The PERR burst pattern is consistent across all three boards** — ~14
   `Critical Interrupt #0x80 | PCI PERR` events in the BMC SEL, all within
   the same second, at every cold boot. Identical signature, three
   independent boards, three independent BMCs.

---

## What has been ruled out

- **NVMe drive defect** — SMART pristine, current firmware, no media errors
  in `nvme error-log`. The one hang that was captured in detail decoded to
  `NVME_SC_HOST_ABORTED_CMD` (transport/path error), **not** a media or data
  integrity status — the drive never reported bad data; the host gave up
  waiting on it.
- **Motherboard (both prior boards)** — same fault class survived both
  replacements.
- **PSU/ground offset** — considered and partially tested on board #2 (see
  `TROUBLESHOOTING-PCIE-SERR.md`, lead #1); does not explain why the fault
  localizes to one root complex rather than scattering across every GPU
  link that would span a ground-domain split.
- **Thermal cause** — the hottest documented period of operation (intake air
  at 50°C, 8 GPUs under full load) produced zero faults; all faults so far
  have occurred cool and idle or under light load.
- **Software/workload cause** — one hang was independently identified as a
  memory-exhaustion livelock and fixed (swap disabled, `earlyoom` armed);
  this is explicitly excluded from the CPU claim and not part of this case.

---

## Timeline (condensed — full detail in TROUBLESHOOTING-PCIE-SERR.md)

| Date | Board | Event |
|---|---|---|
| (pre-09/12) | #1 | SERR attributed to GPU slots 0/1 |
| 09/12–09/20 | #2 (TYAN S8056GME) | Multiple SERR bursts on `00:01.4`/`00:01.5`; 3 silent hangs, 1 explained as memory livelock, 2 unexplained |
| 09/21 | #2 | AER baseline captured (14 endpoint / 1 root-port corrected errors, idle) |
| ~09/25 | #3 | Board swap #2, CPU reseated with corrected torque |
| 10/01 08:03 | #3 | Hard reboot. BMC SEL: 14× `PCI PERR` burst immediately preceding reboot. Kernel AER log: `device_id 0000:03:00.0`, corrected, same signature as board #2 |
| 10/01 11:22 | #3 | `lspci -vv -s 03:00.0` shows NVMe link downgraded to x2 (rated x4) |

---

## Evidence to attach

- `TROUBLESHOOTING-PCIE-SERR.md` (full technical record, board #2)
- BMC SEL export covering the 10/01 08:03 PERR burst (`ipmitool sel elist`)
- Kernel log excerpt, 10/01 08:03:22, `device_id: 0000:03:00.0` corrected
  AER records
- `lspci -vv -s 03:00.0` output, 10/01 11:22, showing the x4→x2 downgrade
- `diagnostics` output bundle for the 10/01 incident (uptime, GPU state,
  fault watcher section)
- Photographs of CPU socket seating/torque at each of the 3 builds, if
  available

## Open items

- [ ] Confirm with seller/dispute whether the **same physical CPU** was
      moved across all 3 motherboards (this is the load-bearing assumption
      of the whole case — verify and state explicitly in the dispute filing)
- [ ] Attach this file + the evidence list above to the bank dispute if the
      seller does not resolve the existing defect claim
- [ ] Decide whether to pursue CPU replacement in parallel (see sourcing
      notes in chat — EPYC 9B14 is OEM-exclusive; eBay/pulled-parts market
      only) or wait on dispute outcome before spending on a replacement
