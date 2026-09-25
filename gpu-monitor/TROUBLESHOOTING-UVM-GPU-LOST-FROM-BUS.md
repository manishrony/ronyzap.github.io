# Cross-machine "GPU lost from the bus" incident, 2026-09-25

## Summary

Within about a minute of each other, two independent rigs on the same PDU
each lost one GPU to the identical NVIDIA driver fault:

- **zappa1**, GPU1 — logged fatal at **13:45:26 UTC**
- **zappa2**, GPU5 — logged fatal at **13:46:18 UTC**

On zappa2 this took the whole driver down (`nvidia-smi` stopped enumerating
all 8 GPUs); zappa1 needed a manual reboot shortly after. Root cause is
**not** a PCIe/root-complex fault (see `TROUBLESHOOTING-PCIE-SERR.md` for
that separate, CPU-side issue on zappa2) — this is a distinct failure in a
single GPU's onboard GSP firmware on each machine.

## Why this is one incident, not two coincidences

- **Identical fault signature** on both machines (see Evidence below),
  down to the same assertion lines (`rs_client.c:844`, `rs_server.c:259`).
- **~52 seconds apart.**
- **Different hardware on every axis that would normally distinguish a
  per-machine defect**: different CPU vendor/platform (zappa1: consumer
  AMD Ryzen 9 9900X / Gigabyte B850; zappa2: server EPYC), different GPU
  slot (GPU1 vs GPU5), different driver build (595.84 vs 595.71.05).
- **Only thing they share: the same PDU** (`192.168.1.251`).

A hardware coincidence producing this exact rare signature on two unrelated
machines within under a minute is implausible. Treat this as one shared
event until proven otherwise.

## Evidence

Both machines show the same shape, one GPU per host:

```
NVRM: GPU<n> _issueRpcAndWait: rpcSendMessage failed with status 0x0000000f
NVRM: GPU<n> rpcRmApiFree_GSP: GspRmFree failed ... status=0x0000000f
NVRM: GPU<n> kgmmuInvalidateTlb_GM107: TLB invalidation failed waiting for
    prior invalidate (status=0x0000000f), ...
NVRM: GPU<n> nvAssertFailedNoLog: Assertion failed:
    (status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET)
    @ rs_client.c:844
NVRM: nvAssertFailedNoLog: Assertion failed: ... @ rs_server.c:259
NVRM: GPU<n> nvCheckOkFailedNoLog: Check failed: GPU lost from the bus
    [NV_ERR_GPU_IS_LOST] (0x0000000F)
```

zappa2 additionally hit the UVM-level fatal wrapper around this same event:

```
NVRM: nvGpuOpsReportFatalError: uvm encountered global fatal error 0x60,
requiring os reboot to recover.
```

and GPU6 (a second, different card on zappa2) then also began stalling
(`nvidia-modeset: ERROR: GPU:6: Error while waiting for GPU progress`,
every 5s for 2+ minutes) — read as a secondary symptom of the whole UVM
subsystem wedging, not a second independent hardware fault.

`nvidia-persistenced.service` on zappa2 had to be SIGKILLed after failing
to stop cleanly. Both machines needed a full reboot to clear — a UVM
global fatal error explicitly requires one.

## Power correlation: checked, inconclusive but suggestive

Both rigs log `pdu_power` readings from the same shared PDU
(`192.168.1.251`). Before this event, load was steady: 12.7–19.5A
(3.0–4.7kW) from 13:06 through 13:37:21. Then:

```
13:37:21  14.4A / 3456W   <- normal
13:42:24   4.5A / 1080W   <- ~70% drop, 3 min before the first logged fault
13:45:26  (zappa1 GPU1 fatal)
13:46:18  (zappa2 GPU5 fatal)
14:03:27   6.1A / 1464W   <- post-reboot recovery, climbing back over ~30 min
```

**Read this carefully: the draw dropped before the kernel logged anything,
not after.** That argues against a classic brownout/sag *causing* the
fault (which would show as a dip coincident with or after the failure,
often with a compensating spike). It's more consistent with the affected
GPUs having already gone unresponsive several minutes earlier — quietly,
with no logged error yet — and the loud `GPU lost from the bus` cascade at
13:45:26/13:46:18 being the moment a periodic health-check RPC
(`_gpushareddataSendDataPollRpc`, present in both machines' logs) finally
timed out against an already-dead GPU, not the moment the GPU actually
died.

The gpu-monitor logging process itself died in the same event on both
machines (it's what writes `pdu_power`), so there is no reading from
*during* the fault window on either host — this is a hard limitation of
host-side logging for this specific incident and can't be resolved after
the fact from these logs alone. If the PDU itself exposes an independent
event log (web UI / SNMP, not host-side), that would be the only source
immune to this gap.

## Revised working theory

The real onset is likely in the **13:37–13:42 UTC** window, on both
machines, quietly — not at the 13:45/13:46 timestamps where the kernel
first logged it loudly. What actually triggered two GPUs on two unrelated
machines to go unresponsive within that same 5-minute window is still
unexplained. Candidates, roughly most to least likely:

1. Some shared external trigger in that window unrelated to raw power
   delivery (e.g. a fleet-wide Vast.ai host-daemon action, both rigs
   picking up a similarly-timed workload/API event) that interacts badly
   with the GSP firmware on driver builds in this range.
2. A power-quality event too brief or too shaped to show as a clean
   amps/watts anomaly in 5-minute-interval logging (both readings
   bracketing the event are normal-shaped, single points — real sampling
   resolution here is coarse).
3. Independent GSP firmware bugs on both cards, coincidentally timed —
   ranked last given how well the timing and signature line up.

## What this is NOT

- **Not the zappa2 CPU/PCIe-root-complex issue.** No PCIe AER/SERR entries
  anywhere in this window on either machine — no `[Hardware Error]`, no
  `PcieError`, no root-port complaints. Keep this separate from
  `TROUBLESHOOTING-PCIE-SERR.md`; mixing them in would weaken, not
  strengthen, that case.
- Not memory pressure (zappa2's earlyoom had >400GB free at the time).
- Not a kernel panic on either machine — the kernel itself stayed up
  throughout; only the NVIDIA driver's GPU/UVM state broke.

## Next steps if this recurs

- If either GPU1 (zappa1) or GPU5 (zappa2) throws this again specifically,
  treat that card as suspect — try it in a different physical slot to see
  if the fault follows the card or stays with the slot/rail.
- Capture `nvidia-bug-report.sh` output immediately after a recurrence,
  before rebooting, if at all possible.
- If it recurs on *both* machines again within the same short window,
  that's strong enough to escalate to checking the PDU/circuit directly
  (its own logs, an electrician, or a dedicated power-quality monitor)
  rather than relying on host-side `pdu_power` sampling, which has now
  been shown to have a blind spot around exactly this kind of event.
- Check Vast.ai's host-daemon (`kaalia`) logs and status page/Discord for
  any fleet-wide action or reported incident in the 13:37–13:46 UTC window
  on 2026-09-25.
