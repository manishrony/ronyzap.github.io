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

| 10/03 14:10:27 | #3 | **Tenth incident, 22 minutes after the ninth.** Same `device_id: 0000:03:00.0` corrected AER signature (`Error 12`/`Error 13`, `fru_text: PcieError`). Boot history across this window: 13:33:27 → 13:48:24 → 14:10:29 — **three reboots in under 40 minutes**, a sharp acceleration even against the already-elevated 10/02–10/03 cadence. `reliability2` dropped 0.85→0.58 across this stretch. Recovery normal each time: fully rented within minutes, GPU3 workload resumed at 100%/535W. No new fault signature — this entry is logged primarily to capture the frequency acceleration itself as a data point (consistent with progressive degradation rather than a steady-state intermittent fault). |
| 10/03 13:16:53–13:48:24 | #3 | **Confirmed: the 13:33 and 13:48 reboots were genuine watchdog-caught hangs, not spontaneous/manual resets.** BMC SEL shows `Watchdog2 IPMI_Watchdog | Hard reset | Asserted` at 13:16:53 → `FRU State IPMI_Power_Cycle | Activation Requested` at 13:30:03 → boot completes 13:33:27; then a **second** `Watchdog2 Hard reset` at 13:39:16 → activation 13:44:56 → boot completes 13:48:24 (incident #9). This means the system actually froze twice within roughly 30 minutes, each time caught and recovered by the watchdog — this is a materially worse signal than "AER logged at boot" alone suggested: hang *frequency* is accelerating, not just boot-time noise. Cross-referencing the full watchdog history: 1 hard-reset on 10/01 (07:45), 1 on 10/02 (12:01), 2 on 10/03 by 13:39 alone — the daily hang count is climbing. Full SEL confirms **no** watchdog/power-cycle event accounts for the 14:10:29 boot (incident #10) — the eleventh incident below likely explains it. |
| 10/03 ~14:1x (uptime 128.7s at capture) | #3 | **Eleventh incident — third fatal AER capture, and the first on the *other* root-complex sibling port.** Physical console photograph shows `pcieport 0000:00:01.5: PCIe Bus Error: severity=Uncorrectable (Fatal)`, `device [1022:14ab]`, `[5] SDES (First)` — identical vendor/device signature to the two 10/02 fatal captures, but on `00:01.5` (the upper slot) rather than `00:01.4` (lower). The upper slot currently holds the **original boot NVMe** (moved there during incident #8's slot swap). Critically, this capture also shows **actual I/O-layer failures**, not just a link-level AER record: `nvme1n1: I/O Cmd(0x2) @ LBA ...` followed by dozens of `I/O Error (sct 0x3 / sc 0x71)` across many LBAs and `I/O error, dev nvme1n1, sector ..., class 2` entries — the drive itself could not complete reads while the link was down. This is the clearest evidence yet that the root complex, not a specific port or a specific drive, is the common failure point: both `00:01.4` and `00:01.5` have now independently produced fatal AER events, and both the original and the spare NVMe have now been present during a hard fault on their respective slots. Likely explains the untriggered 14:10:29 reboot immediately above — a fatal crash of this kind freezes the system hard enough that journald/BMC SEL logging may not capture a clean watchdog entry, matching the pattern already established for the 10/02 fatal captures (console photo is the only record). Photo saved to evidence folder. |
| 10/03 18:00–18:17 | #3 | **Twelfth incident — a second cluster of three reboots in 17 minutes** (18:00:15 → 18:08:57 → 18:17:07), separate from and even tighter than the 13:33–14:10 cluster. Not yet individually decoded (which port, corrected vs. fatal) — logged here primarily to correct the running incident/boot count, which undercounted this day significantly before this cluster was discovered via a later `journalctl` service-start listing rather than a live diagnostics paste. |
| 10/03 19:47 and 20:35 | #3 | **Thirteenth and fourteenth incidents.** Boots at 19:47:29 and 20:35:33. The 20:35 boot is the one captured in the console photograph showing `pcieport 0000:00:01.4` fatal-pattern-adjacent output plus a D-state cascade (`jbd2/nvme0n1p3`, `systemd-journal`, `rasdaemon`, `monitor`, `kaalia`, `cmfd-miner`, `python3` all blocked >122s) **and**, unusually, `systemd[1]: Failed to start systemd-journald.service` repeating across large timestamp jumps (493s → 616s → 1277s → 1729s → 2180s → 2631s) before the capture ends. This raised a filesystem-corruption concern (repeated real `nvme1n1` I/O errors the day before, per incident #11, made this plausible). **Confirmed as a false alarm, not corruption:** `fsck -n /dev/nvme0n1p3` (dry-run) reports `clean, 177181/50331648 files, 6040140/201326592 blocks`; `dmesg` shows only the standard boot-time `mounted ro → systemd-remount-fs → remounted rw` sequence, not a fault response; the one genuine anomaly is `systemd-journald[2357]: File ... system.journal corrupted or uncleanly shut down, renaming and replacing` — journald self-healing its own log file after an unclean shutdown, which is expected after any hard/watchdog reset and explains the earlier "Failed to start" messages (journald was busy discarding the old journal, not broken). |
| 10/03 20:35:34 (4s after boot) | #3 | **Second occurrence of the NVRM register-read fault, now on a different GPU.** `NVRM: GPU1 gpuHandleSanityCheckRegReadError_GH100: Possible bad register read: addr: 0x110094, regvalue: 0xbadf2100` — identical address and sentinel value to the 10/03 13:48:41 occurrence on GPU4, but this time on **GPU1**, and only 4 seconds after boot (tighter correlation with the boot-time AER than the first occurrence's 23s gap). Per the standing open item, a recurrence on a *different* GPU meets the bar for tracking this as a real, repeating signal rather than a one-off: it is not GPU4-specific, and its consistent timing relative to boot/AER events makes the "downstream symptom of the same IO-die/root-complex instability" hypothesis more plausible than "independent per-GPU hardware fault." Still not conclusively linked to the CPU dispute evidence — but promote to "actively tracked, probably related" rather than "isolated, unattributed." |

| 10/04 10:45:22–10:55:45 | #3 | **Fifteenth incident, first on 10/04.** BMC SEL shows `Watchdog2 IPMI_Watchdog | Hard reset | Asserted` at 10:45:22 — the watchdog caught and reset a hang on its own, same as every prior watchdog-recovered incident. A manual IPMI power cycle (issued from zappa1 via `ipmitool ... chassis power cycle`) landed 7 minutes later at 10:52:24, effectively redundant with the already-completed automatic recovery. Boot completed cleanly at 10:52:32; the usual benign PERR boot-training burst followed at 10:55:29-30, with the standard corrected AER signature (`device_id: 0000:03:00.0`, `Error 12`/`Error 13`) logged at 10:55:45. No new signature — watchdog continues working as designed. Machine then ran stable for the rest of 10/04 (14h38m clean uptime observed that evening, zero new faults). |
| 10/05 13:19:47–13:19:50 | #3 | **Sixteenth incident, first on 10/05.** Same corrected AER signature (`device_id: 0000:03:00.0`, `Error 12`/`Error 13`) at 13:19:47, boot completed 13:19:50 (BMC SEL `S0/G0: working` 13:16:34, benign PERR boot-training burst 13:19:32). `reliability2` dropped 0.91→0.57 across this reboot, consistent with every prior incident's pattern. Recovered normally: fully functional within minutes, GPU0/GPU4 correctly throttled to the new 450W mining cap post-boot (`WORKLOAD THROTTLE` fired again at 13:21:09, confirming the `tsc-engine` mining-classification fix and the 450W setting both survive across reboots). No new signature — the ~14.5-hour gap since incident #15 is the longest stable stretch yet recorded in this case. |
| 10/05 15:53:59–15:54:01 | #3 | **Seventeenth incident.** Same corrected AER signature (`device_id: 0000:03:00.0`, `Error 12`/`Error 13`) at 15:53:59, boot completed 15:54:01 (BMC SEL `S0/G0: working` 15:50:46, benign PERR boot-training burst 15:53:44). Only ~2.5 hours since incident #16 — the encouraging ~14.5h gap before it did not hold, and the fault rate is back to its usual cadence rather than genuinely improving. Recovered normally; GPU0/GPU4 again correctly capped at 450W post-boot. No new signature. |
| 10/05 16:49:29 | #3 | **Eighteenth incident.** Boot completed 16:49:29 (only ~55 min after #17), confirmed by the recovery-time `WORKLOAD THROTTLE` log firing again at 16:50:49 (GPU 7/6/4/0 re-capped post-boot). Discovered via the `gpu-monitor`/`gpu-dashboard` service-start boot listing rather than a live diagnostics capture of the fault itself — same pattern as incidents #12-14 being found late. Individual AER signature not captured live but assumed identical given the consistent pattern of every prior incident. |
| 10/05 17:54:19–17:54:22 | #3 | **Nineteenth incident, ~65 min after #18.** Same corrected AER signature (`device_id: 0000:03:00.0`, `Error 12`/`Error 13`) at 17:54:19, boot completed 17:54:22. Three reboots in the last ~2 hours (15:54 → 16:49 → 17:54) — frequency is accelerating again, consistent with progressive degradation rather than a steady-state fault. User confirms replacement CPU (with correctly-specced NEIKO 10573B torque driver, 10.8-13.0 in-lbf target for the SP5 ILM screws) arrives tomorrow and the swap test will be performed then. |
| 10/06 13:50 (status check) | #3 | **New stable-stretch record: 19h56m uptime, no new incident since #19.** Beats the prior 14.5h record (between #15 and #16). System healthy — 6/8 GPUs rented with genuine compute workloads, `tsc-engine` still correctly throttled at 450W, `reliability2` climbed to 0.90. Logged for the record; CPU swap test is scheduled for today. |
| 10/06 14:57:08–14:57:11 | #3 | **Twentieth incident — ends the stable stretch at a new record of ~21h03m** (17:54:22 on 10/05 → 14:57:08 on 10/06), beating the just-logged 19h56m mark. Same corrected AER signature (`device_id: 0000:03:00.0`, `Error 12`/`Error 13`), boot completed 14:57:11 (BMC SEL `S0/G0: working` 14:53:54, benign PERR boot-training burst 14:56:52-53). `reliability2` dropped 0.90→0.64 across this reboot — same pattern as every prior incident. GPU0/GPU4 re-throttled to 450W correctly post-boot (`WORKLOAD THROTTLE` fired at 14:58:30). Recovered normally. Still awaiting the CPU swap test, scheduled for today. |

**Frequency note:** twenty incidents across roughly 123 hours (two on 10/01,
six on 10/02, six on 10/03, one on 10/04, five on 10/05-10/06 so far) — including two reboot clusters of 3-in-17-min and
3-in-40-min on 10/03 — is a sharp
step up from the prior cadence of roughly one every few days — and still
accelerating. Combined with the 10/02 fatal AER captures — reproduced
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
- **Console photograph, 2026-10-03** (`evidence/console-fatal-aer-2026-10-03-port5.jpg`),
  showing a third fatal AER capture — same `device [1022:14ab]` signature,
  but on `0000:00:01.5` (the sibling root-complex port) rather than
  `00:01.4`, with actual `nvme1n1` I/O-layer read errors visible
  alongside the link-level fault. Confirms the fault is a property of
  the CPU's root complex itself, not a single port or physical drive —
  both sibling ports and both physical NVMe units have now independently
  faulted
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

### RESULT — 2026-10-07: test complete, CPU exonerated, board #3 implicated

CPU physically swapped 2026-10-06/07 (new EPYC 9B14, unlocked, `100-000000782`,
from eGoods Supply). Teardown, socket, and new-CPU pin inspection all
photographed clean — no bent pins, no socket damage. New CPU correctly
detected post-boot: **AMD EPYC 9B14 96-Core, 2600 MHz**, 524288MB DDR5
4800MT/s, TYAN BIOS v2.03. Same board (#3), same NVMe, same slot, same
SP5 torque spec (~12 in-lbf, T20 Torx, single ILM screw).

**At 77.8 seconds of uptime on the first boot after the swap**, the
identical-signature fault recurred — and worse than any prior occurrence:

```
[ 77.846245] pcieport 0000:00:01.4: PCIe Bus Error: severity=Uncorrectable (Fatal), type=Transaction Layer
[ 77.846359] pcieport 0000:00:01.4:   device [1022:14ab] error status/mask=00000020/00000000
[ 77.866139+] nvme0n1: mass I/O Cmd(0x2) READ failures across hundreds of LBAs, I/O error (sct 0x3 / sc 0x71), class 2
```

Same root port (`00:01.4`), same device ID (`[1022:14ab]`), same
`severity=Uncorrectable (Fatal)` class already seen twice on 2026-10-02 —
but this is the first time it has struck this early post-boot (77s vs.
hours/days previously), and the first time it cascaded into an actual
NVMe I/O error flood visible at the console rather than being caught only
in AER/BMC logs.

**Confirming boot — 2026-10-07 01:10 UTC:** after properly restoring/saving BIOS
settings (the 77s-fault boot above ran on BIOS defaults post-CMOS-clear, an
open question at the time), the fault recurred again within seconds of this
clean boot: BMC SEL logged 14x "PCI PERR" assertions at 01:10:32, followed
immediately by corrected AER errors on the same `device_id: 0000:03:00.0`
at 01:10:46. This was a corrected (not fatal) event, but it removes the
BIOS-defaults confound entirely — the fault reproduces under the rig's
actual configured settings, not just stock defaults.

**Correction/escalation — 2026-10-07, the 01:10 boot above hung and required
manual recovery.** What was logged as a routine corrected AER event at
01:10:46 actually cascaded into the same D-state hang pattern seen in
every prior fatal incident: `jbd2/nvme0n1p3`, `rasdaemon`, `kaalia`,
multiple `kworker` threads, and `python`/`python3` processes all reported
"blocked for more than 122 seconds" (later 245 seconds), with
`systemd-journald.service` repeatedly failing to start — identical
signature to incidents #4/#5/#14. The machine was unresponsive until
manually power-cycled via `ipmitool ... chassis power cycle` from zappa1;
recovery boot completed by 11:17:47 UTC. This is now the **21st incident**
and confirms the corrected/fatal distinction doesn't predict whether a
given event escalates into a hang — even a "corrected" AER log entry can
precede a full freeze requiring manual intervention. Does not change the
verdict (same device, same signature, post-CPU-swap), but strengthens it
further: the fault keeps producing full hangs on the replacement CPU, not
just transient log entries.

**Board history evidence — 2026-10-07, FRU + full SEL history.**
Board #3's FRU EEPROM (`Baseboard FRU`, non-volatile, not editable by a
reseller without specialized tools) records:
- Board Manufacturer: TYAN, Product: S8056GME
- Board Serial Number: `CRMF3CN10007`
- **Manufacture Date: 2023-03-21** — roughly 3.5 years before this
  board's installation (~Sept 2026).

Also pulled the **full SEL history** (not just the recent tail).
Entries #1-8 (dated 07/04-05/2003) are the BMC's default/unsynced-clock
placeholder, a universal artifact before the clock gets a real time
source — not real events. Entry #9, "Timestamp Clock Sync" on
2025-07-09 00:27:02 UTC, is the first entry with a plausible-looking
(non-placeholder) date, immediately followed by an AC-lost/power-on
cycle and an 11x "PCI PERR" burst matching the fault signature tracked
throughout this case.

**Caveat (self-corrected, do not overstate):** a plausible-looking BMC
timestamp is not proof of accuracy. Without NTP configured, a BMC's
clock sync can come from a depleted/replaced CMOS battery, a stale RTC
value, or an incorrect sync source, and still produce a date that looks
real rather than an obvious placeholder. **07/09/2025 should be read as
a weak, inconclusive signal, not proof that the board was powered on and
faulting over a year before this investigation.** It's consistent with
that story, but not independently verified — the BMC's time source at
that boot is unknown. Worth noting as a secondary data point alongside
the 2023-03-21 manufacture date, but **do not cite this SEL timestamp as
decisive evidence of prior use in the seller/MiTAC dispute** unless the
clock's reliability can be independently confirmed (e.g., checking
whether NTP was ever configured on this board, or whether the timestamp
lines up with anything externally verifiable).

**Independent cross-corroboration — 2026-10-07, MiTAC RMA ticket #3280.**
A *separate* TYAN board (serial `CRMF3CN10001`, a different physical unit
from board #3's `...10007`, fault reported on a different bus
`0000:07:00.x`) was sent directly to MiTAC/TYAN's own RMA facility under
warranty, RMA# FR26370197, for the same class of fault: "Recurring PCI
SERR fault" on a root port. On 2026-10-07, MiTAC's support (Alvin Chong)
reported: *"Our tech just reported that they were able to replicate the
issue you facing during the system stress test however the error
intermittently popped up which is why they needed more time."* This is
independent, third-party confirmation — MiTAC's own lab technicians,
with no input from this investigation, reproduced an SERR/root-port fault
on a different physical board from the same family under controlled
stress testing. While not proof that board #3 specifically shares the
same root cause, it meaningfully supports that this board design/family
can produce exactly this fault class independent of CPU, cabling, or
rig-specific conditions — useful corroborating context for the board #3
dispute even though it is a separate ticket/unit.

**PSU/cable reseat performed — 2026-10-07, ~12:13 UTC boot.** The 24-pin
ATX and EPS12V cables (Corsair RM1200x SHIFT, dedicated to the
motherboard only, not shared with GPU power) were physically disconnected
and reseated at both the PSU and board ends during this boot, closing out
an earlier open question about whether this specific test had actually
been done. This boot is now the tracked data point for whether loose
power cabling played any role: as of 2h+ post-boot, zero new incidents —
encouraging, but not yet conclusive, since prior stable stretches of
14.5h, 19h56m, and 21h03m were already observed earlier in this case
while the fault was still fully active and unrelated to any cable work.
**Read this test as: fault recurring sooner than ~21h (the prior best
stretch) = reseat likely irrelevant, board conclusion stands. Fault
staying clear well beyond 21h = reseat may have been a real contributing
factor, worth revisiting the board-defect conclusion.**

**Result — 2026-10-07 15:08:09 UTC: fault recurred at ~2h53m post-reseat**
(12:13:47 boot → 15:08:09 fault), the 22nd incident, same corrected
`device_id: 0000:03:00.0` signature. This is well short of the ~21h bar,
so **the PSU/cable reseat does not appear to have changed anything** —
consistent with the board remaining the root cause, not loose cabling.
This closes out the cable-reseat line of investigation without
overturning the board #3 verdict.

**Verdict: CPU is cleared. Fault persists on the new CPU, same board.**
Per the table above, this points at **board #3 (TYAN S8056GME) itself**,
not the CPU, and retroactively supports the same conclusion for boards
#1/#2 before it. The CPU return/dispute should **not** proceed on the
strength of this test — the evidence now runs the other way. The live
case going forward is the **board #3 return** (see Open items below),
not a CPU replacement claim.

## Open items

- [ ] **URGENT — contact seller for board #3 (TYAN S8056GME) before the
      return window closes.** Confirmed order details:
      - Seller: **5starsbargain** (eBay)
      - Order #: **04-15170-52658**
      - Purchased: 2026-09-12, **delivered 2026-09-18**
      - Price: $479.16
      - **Listing states "Returns not accepted"** — a standard eBay return
        request would likely be auto-rejected, so the plan is to **message
        the seller directly first**, and escalate to a formal RMA / eBay
        Money Back Guarantee claim afterward if needed (MBG applies to
        defective-item claims even on no-returns listings). eBay's MBG
        window is based on **delivery date**, not purchase date — Sep 18
        delivery gives roughly until **~2026-10-18**, a few days more
        buffer than the purchase-date estimate below.

      **Step 1 — message sent to seller 2026-10-05 via eBay messaging**
      (confirmed sent, matches draft below verbatim):

      > To: 5starsbargain — Re: Order #04-15170-52658 — Tyan S8056GME
      > Server Motherboard
      >
      > Hi,
      >
      > I'm reaching out about the Tyan S8056GME motherboard from order
      > #04-15170-52658, delivered Sep 18, 2026.
      >
      > Since installation, this board has shown a recurring PCIe hardware
      > fault — repeated corrected and, on at least two occasions,
      > uncorrectable/fatal PCIe bus errors reported by the CPU's root
      > complex (`pcieport 0000:00:01.4`, device `[1022:14ab]`), causing
      > multiple unexplained system hangs that require a hard power cycle
      > to recover. This has been happening multiple times per day over
      > the past week.
      >
      > I've confirmed this through:
      > - BMC System Event Log entries (hardware-level, independent of the
      >   OS)
      > - Kernel-level PCIe AER (Advanced Error Reporting) logs
      > - Ruled out the storage drive (SMART health fully normal)
      > - Ruled out software/workload causes
      >
      > I understand the listing states returns are not accepted, but this
      > is a hardware defect, not a change-of-mind return. I'm currently
      > running a further isolation test (swapping only the CPU) to
      > confirm the fault is board-specific before deciding how to
      > proceed, but wanted to flag this now given the issue and open a
      > conversation about options — replacement, partial refund, or
      > return — depending on what the test shows.
      >
      > Happy to share diagnostic logs/screenshots if helpful.
      >
      > Thanks,
      > [Your name]

      **Seller replied 2026-10-05** — reasonable, technically literate
      response (not a canned rejection). Seller states these are new
      boards, factory-tested, "sold 10s with zero issues," and argues
      `0000:00:01.4` could point to: (1) add-in card not fully seated,
      (2) riser not fully seated/damaged, (3) defective MCIO/NVMe cable,
      (4) defective OCP card, (5) defective CPU/root complex, (6) bad
      marginal PCIe Gen5 device. Requested removing the OCP NIC, pulling
      secondary add-in cards, moving MCIO cables to different ports,
      moving the primary PCIe card to another slot, and moving the M.2
      drive to the other M.2 slot, then checking whether the error code
      stays on `0000:00:01.4` or changes.

      **Response not yet sent — holding 24h before replying** (not
      immediate). Draft prepared, citing work already done rather than
      repeating physical teardown on a live 8-GPU production server:

      > Hi,
      >
      > Appreciate the detailed troubleshooting steps. A few of these
      > don't apply to this specific fault, and for the others I already
      > have conclusive data from testing over the past week — here's why:
      >
      > Root port `0000:00:01.4` (and its sibling `00:01.5`) are dedicated
      > exclusively to this board's two M.2 NVMe slots — confirmed via
      > `lspci -tv` topology mapping. They don't share any electrical path
      > with the OCP slot, GPU/add-in card slots, or risers. So removing
      > the OCP card or any add-in card wouldn't be expected to change
      > anything on this port — and separately, I've already tested this
      > board with the OCP card fully removed for an unrelated BMC issue,
      > and this PCIe fault was unaffected.
      >
      > On the MCIO/NVMe side: I've already moved the drive between both
      > of the board's M.2 slots (it only has two) and swapped in a
      > second, different physical drive. The fault follows the port, not
      > the drive — and it has now occurred independently on both
      > `00:01.4` and `00:01.5`, including once with a fatal/uncorrectable
      > severity that caused real I/O errors on the drive itself.
      >
      > Given that, I don't believe reseating cables or swapping slots
      > again will produce new information — I've already isolated slot
      > and drive as variables. The remaining open question is CPU vs.
      > board, which I'm resolving directly: I have a second EPYC 9B14 in
      > hand and am running a CPU-only swap test (same board, same NVMe,
      > same slot) to settle it conclusively. I'll share that result as
      > soon as it's done — if the fault clears with the new CPU, that
      > confirms the board; if it persists, that points back to something
      > board-level I haven't found yet and I'm open to further diagnosis
      > then.
      >
      > Happy to send the kernel/BMC logs from the testing already done if
      > that's useful in the meantime.
      >
      > Thanks,
      > [Your name]

      **Step 2 — if the seller doesn't resolve it (or the swap test
      confirms the board), formally request RMA / open an eBay Money Back
      Guarantee case** before ~2026-10-18, citing the same evidence plus
      the swap-test result once available.
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
- [x] ~~Watch for a repeat of the 10/03 13:48:41 `gpuHandleSanityCheckRegReadError_GH100`
      GPU4 register-read fault~~ — recurred 10/03 20:35:34, this time on
      GPU1, 4s after boot (vs. 23s after boot the first time), same
      address/sentinel value. Promoted from "isolated, unattributed" to
      "actively tracked, probably related" — not GPU-specific and tightly
      correlated with boot/AER timing. Still short of a confirmed
      mechanism linking it to the `00:01.4`/`00:01.5` root complex, so
      still **not** folded into the CPU dispute evidence directly — but
      worth a one-line mention as a secondary symptom if filing before
      the swap test resolves this
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
