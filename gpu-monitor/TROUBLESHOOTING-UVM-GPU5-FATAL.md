# zappa2: GPU5 UVM global fatal error 0x60 (2026-09-25)

## Summary

At 13:46:18 UTC all 8 GPUs stopped enumerating under `nvidia-smi`. Root cause
was **not** a PCIe/root-complex fault (see `TROUBLESHOOTING-PCIE-SERR.md` for
that, unrelated, CPU-side issue) — this is a distinct failure, isolated to a
single card's onboard GSP firmware, that took the whole driver down with it.

## Evidence

```
NVRM: nvGpuOpsReportFatalError: uvm encountered global fatal error 0x60,
requiring os reboot to recover.
```

repeated dozens of times, all attributed to **GPU5**, followed by a long
cascade of:

```
NVRM: GPU5 _issueRpcAndWait: rpcSendMessage failed with status 0x0000000f
NVRM: GPU5 rpcRmApiFree_GSP: GspRmFree failed ... status=0x0000000f
NVRM: GPU5 nvCheckOkFailedNoLog: Check failed: GPU lost from the bus
[NV_ERR_GPU_IS_LOST] (0x0000000F)
```

GPU5's GSP (GPU System Processor — onboard firmware co-processor) stopped
responding to the driver's RPC channel. GPU6 then also began stalling
(`nvidia-modeset: ERROR: GPU:6: Error while waiting for GPU progress`,
repeating every 5s for 2+ minutes) — this reads as a secondary symptom of
UVM's global fatal-error state affecting the whole subsystem, not a second
independent hardware fault on GPU6.

`nvidia-persistenced.service` had to be SIGKILLed after failing to stop
cleanly. `NVRM: nvGpuOpsReportFatalError` explicitly states the condition
requires an OS reboot to clear — which is why a full reboot (not a service
restart or driver reload) was the only recovery path.

## What this is NOT

- **No PCIe AER/SERR entries anywhere in this window.** No `[Hardware
  Error]`, no `PcieError`, no root-port complaints. This does not match the
  CPU/root-complex fault signature tracked elsewhere in this repo and should
  not be added to that evidence file — it would weaken, not strengthen, that
  case.
- Not memory pressure (earlyoom had >400GB free at the time).
- Not a kernel panic — the kernel itself stayed up throughout; only the
  NVIDIA driver's GPU/UVM state broke.

## Working theory

GPU5's GSP firmware hung or crashed under load. This is a known category of
fault on GSP-firmware-based drivers (open-source and proprietary `nvidia`
kernel modules on driver 595.71.05) and can be triggered by the GPU's own
firmware/silicon, or by a specific workload pattern that the GSP mishandles.

## Next steps if this recurs

- If GPU5 throws `uvm ... global fatal error` again specifically, treat GPU5
  as a suspect card — try it in a different physical slot to see if the
  fault follows the card (GPU-side) or stays with the slot (motherboard/PSU
  rail-side).
- Capture `nvidia-bug-report.sh` output immediately after a recurrence,
  before rebooting, if at all possible.
- Cross-check whether zappa1 (or other rigs) saw a UVM fatal error on the
  *same rented image* around the same time — would point at a
  workload/driver interaction rather than a per-machine hardware issue.
