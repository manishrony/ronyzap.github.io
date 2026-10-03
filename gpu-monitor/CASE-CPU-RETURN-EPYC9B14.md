# Return/dispute case: AMD EPYC 9B14 — suspected defective CPU

Host: zappa2. CPU: **AMD EPYC 9B14**, 96c/192t (OEM-exclusive SKU, not retail
channel). Full technical history lives in `TROUBLESHOOTING-PCIE-SERR.md` —
this file is the condensed, dispute-facing summary and is kept separate so it
can be attached or forwarded without the full investigation log.

Status: **CPU return not yet filed with the original seller** — a defect
claim was filed, but a **bank/card dispute** is being prepared as a fallback
if the seller does not resolve it. This document is the evidence package for
that dispute.

**Scope note, updated 2026-10-02 (second update, same day) after the fatal
AER error recurred a second time with an identical signature, roughly an
hour after the first capture.** This case rests on two distinct phenomena.
The corrected SERR/PERR pattern has been confirmed and localized since
board #2. The silent hangs were, as of 2026-10-01, unproven by log
evidence — three occurrences produced zero AER/MCE/extlog record despite
rasdaemon running and `pcie_ports=native` active. **That changed on
2026-10-02**: a fourth hang was caught live on the physical console showing
a `severity=Uncorrectable (Fatal)` PCIe error on `pcieport 0000:00:01.4` —
the same CPU root-complex port implicated by every SERR burst since board
#2 — seconds before the same I/O-stall cascade (jbd2, systemd-journal,
rasdaemon itself all blocked). **A fifth hang, roughly an hour later, produced
the byte-for-byte identical error** (`pcieport 0000:00:01.4`,
`severity=Uncorrectable (Fatal)`, `device [1022:14ab]`, `[5] SDES (First)`),
confirmed via a second console photograph. This is no longer a single
captured incident — it is a **reproducible, recurring fatal fault on the
same CPU-internal PCIe port**, twice within about an hour. It does not
retroactively explain the three silent hangs from 10/01 by itself, but it
establishes that this root complex *reliably* produces fatal errors that
lead directly into the hang pattern, which previously had to be inferred by
elimination alone. The CPU swap test remains the decisive, mechanism-independent
confirmation — run it as planned — but the dispute filing can now cite direct,
repeated hardware
evidence for the hangs, not just for the boot-time SERR pattern.

---

## What is confirmed vs. not (read this before the sections below)

| | Confirmed | Status |
|---|---|---|
| Corrected SERR/PERR burst at cold boot | Localizes to the CPU's root complex (`00:01.4`/`00:01.5`), reproducible across 3 boards | **Confirmed, CPU-consistent.** Independently corroborated as benign link-training noise, not itself causing an outage — see `TROUBLESHOOTING-PCIE-SERR.md`. |
| Silent host hangs, 2026-10-01 (x2) | Checked `ras-mc-ctl --errors` / `/var/lib/rasdaemon/ras-mc_event.db`: **no new entries since 2026-09-03** — neither hang produced an AER, MCE, or extlog record, despite rasdaemon running continuously and `pcie_ports=native` active | **Not confirmed as a PCIe event by log evidence.** A kernel configured to watch that logs nothing during the hang means no PCIe error completed/reported at the point of failure — consistent with a link dying too abruptly for the error itself to be reported. |
| Host hang, 2026-10-02 | Physical console (photographed, not recoverable from `journalctl` — see below) shows `pcieport 0000:00:01.4: PCIe Bus Error: severity=Uncorrectable (Fatal)`, `device [1022:14ab]` (AMD root port), immediately followed by the same D-state cascade (`jbd2`, `systemd-journal`, `rasdaemon` all blocked) | **Confirmed, CPU-root-complex-localized.** First hang with a direct hardware-error signature, on the exact port already implicated by the SERR pattern. |

**Why this one hang shows a signature and the other three didn't:** `systemd-journal` is itself in the blocked-task list in the 2026-10-02 capture — journald froze mid-cascade, so this error never reached the persisted journal (`journalctl -k -b -1` genuinely has nothing, confirmed by direct check) even though `printk` wrote it straight to the console before the freeze completed. The three earlier hangs likely died too fast/completely for even that much to be written anywhere, console included. Different severity or timing of the same underlying fault, not a different fault — but this is inference, not something further log digging can confirm, since the only surviving record of the 10/02 event is the console photograph itself.

**Practical consequence:** the "why the CPU" argument is now evidenced
for both the SERR/PERR pattern *and* at least one of the hangs — not just
inferred by elimination. The swap test is still the cleanest, most
complete confirmation (it would settle all four incidents at once,
mechanism aside) and should still be run and recorded as planned.

---

## The claim, stated plainly

> The same corrected PCIe fault signature (SERR/PERR bursts on the CPU's
> own IO-die root complex) has now been observed across **three different
> motherboards**. The motherboard has been replaced twice and the fault
> persists. The CPU is the only major component that has remained constant
> across all three builds. By elimination for *this specific signature*,
> the motherboard is cleared and the CPU is the leading suspect. **The
> separate question of what is causing the silent hangs is still open —
> see "What is confirmed vs. not" above — and is being settled by the CPU
> swap test, not by this log-based argument.**

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

4. **The hangs themselves are not yet attributable to the CPU — flagged
   here for honesty, not to support the claim.** On board #2 and again on
   board #3 (2026-10-01), a host hang occurred with the BMC fully
   responsive, all rails nominal, no SEL entry, kernel alive (serving ICMP,
   printing D-state task dumps) but unable to complete disk I/O — and
   **no AER/MCE/extlog record at all**, confirmed via rasdaemon's own
   persisted database. That absence of a PCIe signature means the hang
   cannot currently be pinned on the CPU's IO die specifically, or on
   PCIe as the failure path at all. It remains possible, but unproven —
   the swap test is what will actually decide it.

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
| 10/01 ~13:50 | #3 | **Second silent hang, same day as the 08:03 crash.** Pre-crash kernel log (`journalctl -k -b -1`) ends cleanly at 13:45:43 on routine Docker veth churn — then nothing. No panic, no AER, no OOM, no soft lockup. ~8 min gap before the freeze was noticed and power-cycled via BMC from zappa1. Boot-time PERR burst on the recovery boot (13:53:51–52, ~14 events) is the known-benign link-training signature, not a separate fault. Clean SEL export captured post-recovery (775 lines, stable across two reads 2 min apart). |
| 10/02 ~12:1x–12:29 | #3 | **Fourth hang, first with a direct hardware-error signature.** Physical console shows `pcieport 0000:00:01.4: PCIe Bus Error: severity=Uncorrectable (Fatal)`, `device [1022:14ab]`, at uptime t=675s, then the same D-state cascade (`jbd2/nvme0n1p3`, `systemd-journal`, `rasdaemon`, `cron`, `kaalia`, `monitor` all "blocked for more than 122 seconds") starting at t=862s — 187s later. Confirmed via `uptime -s` (new boot 12:29:09) and a direct `journalctl -k -b -1` check that the persisted journal has **no record of the error** (`systemd-journal` itself was in the blocked list, so it never got flushed to disk) — the console photograph is the only surviving record. Recovered via BMC chassis power cycle from zappa1. |
| 10/02 ~13:14 | #3 | **Fifth hang, byte-for-byte identical to the fourth**, roughly an hour later. Same `pcieport 0000:00:01.4: PCIe Bus Error: severity=Uncorrectable (Fatal)`, `device [1022:14ab]`, `[5] SDES (First)`. Second console photograph captured. Confirms the fault is reproducible and recurring, not a one-off. |
| 10/02 13:37:10 | #3 | **Sixth incident — first since the IPMI/systemd watchdog was armed.** BMC SEL shows `FRU State IPMI_Power_Cycle | Activation Requested` at 13:37:10, soft-off at 13:37:15, working at 13:37:18 — this is the watchdog actually firing. The kernel's `device_id: 0000:03:00.0`, `Error 12`/`Error 13, type: corrected` log entries at 13:40:34 (previously misread as the fault moment) are almost certainly a **BERT replay** — firmware-recorded error data from the actual (silent) fault, replayed into the kernel log during the next boot's early init, which is why the timestamp is ~3 minutes after the real watchdog trigger rather than the trigger moment itself. Real recovery time was ~3 minutes (13:37→13:40), not 3 seconds — still a large improvement over manual detection. All active rentals dropped (unavoidable on any hard reset); `reliability2` dipped 0.78→0.33 then recovered to ~0.59 within the hour. |
| 10/02 19:04:28 | #3 | **Seventh incident.** Same pattern: `IPMI_Power_Cycle | Activation Requested` → soft-off (19:04:33) → working (19:04:35), then the benign 14x `PCI PERR` boot-training burst at 19:07:32. Watchdog-recovered, ~2s soft-reset turnaround. |
| 10/02 ~21:30 | #3 | **Eighth incident, different signature.** BMC SEL shows `S5/G2: soft-off` at 21:30:25 with **no preceding `IPMI_Power_Cycle` request** — not the watchdog this time. User manually unplugged AC power after observing the machine offline (`Power Unit PWR_Unit_Status \| AC lost` logged at 21:33:10, working again 21:33:13). **The active boot NVMe was moved from the lower slot (`00:01.4`/bus 03) to the upper slot (`00:01.5`/bus 04); an older spare drive was placed in the now-vacant lower slot.** Board topology check (`lspci -tv`) confirms this board has exactly two NVMe-capable M.2 slots, and **both are wired to `00:01.4`/`00:01.5`** — the same sibling root-complex pair already implicated in every SERR burst since board #2 (`00:01.2`/`00:01.3`, initially suspected as a free alternate slot, turn out to be unpopulated bridges for a feature this board doesn't have, not usable M.2 connectors). **This move is a reshuffle between two already-suspect ports, not a test against a clean/untested one** — there is no genuinely independent PCIe slot available on this board. If the fault recurs on the upper slot, that's unsurprising (both ports have history) and not new evidence either way; it does not substitute for the CPU swap test. |

| 10/02 21:35:49 | #3 | **Recovery boot after the eighth incident — fault follows the port, not the physical drive.** Corrected AER (`Error 12`/`Error 13`) logged again on `device_id: 0000:03:00.0` (the lower slot, `00:01.4`) at boot — but that slot now holds the **older spare drive** swapped in during incident #8, not the original boot NVMe (moved to the upper slot). The fault recurred on the same port with a completely different physical drive installed, which rules out the specific NVMe unit as a cause even more strongly than before — this is now independent of both "which slot" and "which physical drive." Machine stable afterward: 26+ min clean uptime, all 8 GPUs under genuine heavy load (100% util, 534W, up to 74°C), no further incidents. |
| 10/03 13:45:04–13:48:20 | #3 | **Ninth incident, another unplanned reboot.** BMC SEL shows `S0/G0: working` at 13:45:04 (boot complete) followed by the familiar benign 14× `PCI PERR` boot-training burst at 13:48:06. Kernel log again shows the same corrected AER signature on `device_id: 0000:03:00.0` at 13:48:20 — identical device, identical "corrected"/`Error 12`/`Error 13` pattern as every prior incident, confirming the fault is still active on the same port post-slot-swap. System recovered normally: fully rented within minutes (8/8 GPUs), no further faults in the 9 minutes of uptime observed afterward. |
| 10/03 13:48:41 | #3 | **New, distinct fault class — not PCIe/AER.** The fault-watcher bot posted an automatic Telegram alert for a line that is unrelated in kind to every prior entry in this table: `NVRM: GPU4 gpuHandleSanityCheckRegReadError_GH100: Possible bad register read: addr: 0x110094, regvalue: 0xbadf2100, error code: Unknown SYS_PRI_ERROR_CODE`. This is an **NVIDIA driver-level** sanity check on a GPU-internal MMIO register read, reported by `nvidia.ko` against GPU4 specifically — it is not a `pcieport`/AER record and does not name a root-complex device like `0000:01.4`/`0000:03:00.0`. `0xbadf21xx`-pattern sentinel values are what the driver substitutes when a register read returns all-high or otherwise implausible data, i.e. the read looked electrically/logically broken rather than returning a real value. **Not yet attributed:** this could be (a) an independent GPU4 hardware fault unrelated to the CPU/root-complex case, or (b) a downstream symptom of the same IO-die instability if GPU4's PCIe link also transits a root complex sharing power/clocking domains with `00:01.4`/`00:01.5` — plausible given the timing (23s after the AER event) but not established. Logged here as a new, separately-tracked signal; **do not fold into the CPU dispute evidence** until a repeat on GPU4 (or correlation with further AER events) is observed. No other anomaly reported for GPU4 in the surrounding diagnostics (occupancy/throttle state nominal). |

**Frequency note:** nine incidents across roughly 44.5 hours (two on 10/01,
six on 10/02, one so far on 10/03) is a sharp step up from the prior
cadence of roughly one every few days. Combined with the 10/02 fatal AER captures — reproduced
twice with an identical signature — on the same root-complex port flagged
since board #2, this is now evidence both of worsening frequency and of
which component is implicated — though the swap test remains the cleanest
full confirmation. The watchdog (armed 2026-10-02, see Open Items) is now
containing the damage per incident to ~1 minute of downtime plus the
dropped rentals, regardless of how often it recurs before the CPU swap.

---

## Evidence to attach

- `TROUBLESHOOTING-PCIE-SERR.md` (full technical record, board #2)
- BMC SEL export covering the 10/01 08:03 PERR burst (`ipmitool sel elist`)
- Kernel log excerpt, 10/01 08:03:22, `device_id: 0000:03:00.0` corrected
  AER records
- `lspci -vv -s 03:00.0` output, 10/01 11:22, showing the x4→x2 downgrade
- `diagnostics` output bundle for the 10/01 08:03 incident (uptime, GPU
  state, fault watcher section)
- `sel-elist-2026-10-01_1357.txt` — clean BMC SEL export covering the
  second 10/01 hang (~13:50) and its recovery boot
- `journalctl -k -b -1` excerpt for the ~13:50 hang, showing the silent
  cutoff at 13:45:43
- **Console photograph, 2026-10-02**, showing the fatal `pcieport
  0000:00:01.4: PCIe Bus Error: severity=Uncorrectable (Fatal)` message and
  the subsequent D-state task cascade — this is the strongest single piece
  of evidence in the case; note in the filing that it is a physical console
  capture, not a log file, because journald itself froze before persisting
  the event
- `ras-mc-ctl --errors` output and `/var/lib/rasdaemon/ras-mc_event.db`
  state (2026-10-01) showing no AER/MCE/extlog entry for either hang —
  documents the scope limit above, attach alongside the SERR evidence,
  not as evidence *for* the CPU claim
- Photographs of CPU socket seating/torque at each of the 3 builds, if
  available

## Replacement CPU ordered — the decisive swap test

**Ordered 2026-10-01.** AMD EPYC 9B14, unlocked (`100-000000782`), from
eGoods Supply (ebay.com, 25,784 feedback, 99.9% positive), $1,599, used
condition, expected delivery **Oct 3–6**.

This is being bought to run the **decisive test** called for in
`TROUBLESHOOTING-PCIE-SERR.md`: swap only the CPU, keep board #3, the same
Crucial T705 NVMe, and the same seating/torque procedure. See "The decisive
swap test — procedure" below. **Do not dispose of or return the current
CPU** until this test is complete and the dispute is resolved — it is the
physical evidence for the claim.

### Procedure, once the new CPU arrives

1. Capture a final AER baseline and full `diagnostics` output on the
   **current** CPU immediately before teardown, for a clean before/after.
2. Change **only** the CPU. Same board, same NVMe, same slot, same SP5
   torque sequence used on the board #2→#3 rebuild.
3. First boot: capture AER baseline (`aer_dev_correctable` on `03:00.0`,
   `aer_rootport_total_err_cor` on the root port) at comparable idle
   uptime, same method as the 2026-09-21 baseline.
4. Run the rig normally and watch for recurrence over the following days.

### Reading the result

| Outcome | Verdict |
|---|---|
| Fault clears on the new CPU, same board | **CPU confirmed defective.** Also exonerates board #3 (and retroactively boards #1/#2). Strongest possible evidence for the dispute — attach this test's before/after logs directly. |
| Fault persists on the new CPU, same board | CPU is cleared. Points back at board #3 or a rig-level cause (see lead #1, PSU ground offset, in `TROUBLESHOOTING-PCIE-SERR.md`). **Do not proceed with the CPU dispute on weak grounds** if this happens — the Mitac board case (`CASE-MOTHERBOARD-RETURN-MITAC.md`) becomes the live one instead. |

## Open items

- [ ] Confirm with seller/dispute whether the **same physical CPU** was
      moved across all 3 motherboards (this is the load-bearing assumption
      of the whole case — verify and state explicitly in the dispute filing)
- [ ] Attach this file + the evidence list above to the bank dispute if the
      seller does not resolve the existing defect claim — **the 2026-10-02
      fatal AER capture is now the strongest single piece of evidence;
      lead with it**, alongside the SERR pattern
- [x] ~~Decide whether to pursue CPU replacement in parallel~~ — ordered,
      see above
- [ ] Run the swap-test procedure once the new CPU arrives (Oct 3–6) and
      record the outcome in this file — now a confirming test rather than
      the sole evidence, since the 10/02 capture already gives direct
      hardware evidence for at least one hang
- [ ] If the swap test clears the CPU (fault persists), do not retroactively
      claim the hangs as CPU evidence anywhere this file has been
      referenced or attached
- [ ] Watch for a repeat of the 10/03 13:48:41 `gpuHandleSanityCheckRegReadError_GH100`
      GPU4 register-read fault. One occurrence is not enough to attribute —
      if it recurs (on GPU4 or any other GPU), especially in close proximity
      to an AER event, open a dedicated tracking note; do not merge into
      this case's CPU evidence unless/until a mechanism linking it to the
      `00:01.4`/`00:01.5` root complex is established
- [x] ~~Decide on interim mitigation while waiting for the CPU~~ — 2026-10-02:
      CPU confirmed arriving Monday (10/06), close enough that moving root
      off the `00:01.4`/NVMe path to SATA was judged not worth the extra
      downtime/risk for a fix about to become moot. **Interim mitigation is
      the IPMI/systemd watchdog instead** (`RuntimeWatchdogSec=60` via
      `/etc/systemd/system.conf.d/watchdog.conf`) — auto-recovers from a
      hang in ~60s instead of waiting for manual detection, without
      touching the storage layout. No guarantee SATA would even be
      unaffected if the IO die itself is failing broadly rather than just
      `00:01.4` specifically — revisit only if the CPU swap is delayed
      significantly past Monday
- [x] ~~Confirm watchdog actually arms with a real action~~ — 2026-10-02:
      first attempt (raw `ipmi_watchdog` module reload) left the BMC's
      live timer at `Action: No action` — armed and counting down, but
      would not have recovered anything on expiry. Fixed via systemd's
      native hardware-watchdog integration instead
      (`/etc/systemd/system.conf.d/watchdog.conf`, `RuntimeWatchdogSec=60`).
      Confirmed: `WatchdogDevice=/dev/watchdog`, `RuntimeWatchdogUSec=1min`,
      `ipmitool mc watchdog get` shows `Action: Hard Reset (0x01)` with the
      countdown repeatedly resetting back toward 60s (54.9 → 60.0 → 56.9),
      confirming systemd is actively petting it. A hang that stops systemd
      itself (this failure's signature) will now trigger an automatic BMC
      hard reset within ~60s instead of requiring manual detection.
