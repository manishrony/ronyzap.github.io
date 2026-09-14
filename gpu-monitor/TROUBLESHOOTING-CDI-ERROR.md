# Runbook: "failed to inject CDI devices" / stuck gpu_occupancy

## Symptom

- Vast.ai dashboard shows a red banner: `failed to inject CDI devices: unresolvable CDI devices`
  and "Your machine is no longer visible in search due to an error."
- `vastai show machine <ID> --raw` shows:
  - `error_description`: `"failed to inject CDI devices: unresolvable CDI devices"` (or later `null`)
  - `gpu_occupancy`: stuck as `"x x "` (both GPUs flagged errored) even after fixes below
  - `listed: true` but `current_rentals_running: 0`, `earn_hour` collapses (e.g. ~$0.90/hr → ~$0.05/hr)
- `vastai self-test machine <ID> --ignore-requirements` fails with `Root state: zero_active_offers`
  ("no on-demand offer found") even though the machine is listed and hardware is healthy.

> If the banner instead reads `--storage-opt is supported only for overlay over xfs with
> "pquota" mount option`, that is a different fault -- see TROUBLESHOOTING-STORAGE-OPT.md.
> Root cause #1 below (stray self-rented instance) still applies to both.

## Root causes seen (check in this order)

1. **Leftover self-test/self-rented instance holding the GPUs.**
   This is the most common cause and the one that resolved the Sep 2026 zappa1 (machine 138419)
   incident. A self-test container (e.g. image `vastai/test:self-test-cu128`) can stay "running"
   for many hours in the instance list, pinning both GPUs and keeping `gpu_occupancy` at `"x x "`
   even though no real rental is running.

   Check:
   ```bash
   vastai show instances-v1
   ```
   Look for an instance on your machine ID with a self-test image and a long `age(hours)` /
   `uptime(mins)` with `Util. % == 0.0`. Destroy it:
   ```bash
   vastai destroy instance <INSTANCE_ID>
   ```
   Then recheck after ~30-60s:
   ```bash
   vastai show machine <ID> --raw | grep -E '"error_description"|"gpu_occupancy"|"listed"'
   ```

2. **Stale/dead container with incomplete CDI registration.**
   A crashed/orphaned container can leave a partial CDI entry that poisons new container launches.
   ```bash
   docker ps -a          # look for Exited/Dead containers
   nvidia-ctk cdi list    # healthy = 5 entries: gpu=0, gpu=1, both UUIDs, gpu=all
   docker rm <dead_container_id>
   ```

3. **GPU GSP/UVM firmware crash (real hardware-adjacent fault).**
   Check `dmesg` / `journalctl -k` for:
   ```
   NVRM: ... rpcSendMessage failed
   NVRM: GspRmFree failed
   NVRM: nvGpuOpsReportFatalError: uvm encountered global fatal error 0x60, requiring os reboot to recover
   ```
   If present, a full host reboot is required (not fixable at the container/software level).
   ```bash
   sudo reboot
   ```

4. **Orphaned kaalia processes** from repeated `systemctl restart vastai.service` can cause
   inconsistent status reporting. Check with `pgrep -a kaalia` — should be exactly one
   `launch_kaalia.sh` and one `kaalia`.

   **Kill the orphan by PID. Do NOT stop the service, and do NOT reboot for this.**
   ```bash
   pgrep -a kaalia          # identify the extra PID by its shorter elapsed time
   kill <orphan_pid>
   pgrep -a kaalia          # confirm one pair remains
   ```

   An orphaned kaalia on its own costs nothing measurable — it is untidiness, not a fault.
   Taking the machine offline to clean it up costs real reliability score (see below), so
   the cure is worse than the disease unless the machine is genuinely misreporting.

## Reliability score: do not spend it on cosmetics

The console's thumbs-up percentage is a rolling window that Vast weights heavily in search
ranking. Every minute the agent is not reporting counts against it.

On 2026-09-14 zappa2 climbed 57.86% -> 88.01% over ~20 hours of clean uptime after the PCI
SERR fix, then gave some of it back because `systemctl stop vastai` was used to clear a
duplicate kaalia — about four minutes offline for a cleanup that was not urgent.

Rules:

- **Never `systemctl stop vastai` for non-urgent work.** Target the specific process instead.
- Only an actual fault, or a deliberately scheduled test (e.g. the reboot test after fstab
  changes), justifies an offline window.
- Batch anything that *does* need downtime into one window rather than several.
- Do not try to compensate for a dip. The score recovers by itself as uptime accrues, the
  same way it climbed in the first place.

## Benign log noise that is NOT a fault

`gpu_monitor.sh`'s fault watcher greps broadly for `NVRM`, so some harmless driver messages
page as "GPU Fault". Before acting, check the BMC SEL (`ipmitool sel elist`) — a real fault
leaves a trace there; these do not.

```
NVRM: GPU7 gpuValidateRegOffset_IMPL: User does not have permission to access register offset 0x...
```

The driver **denying** an unprivileged register read. Mining and tuning software inside a
renter's container tries to poke GPU registers directly and cannot, so each attempt logs a
line — across 8 GPUs that is easily hundreds of lines. Seen on zappa2 2026-09-14 from a
`quantus-mining-fleet` rental. No Xid, no MCE, nothing in the SEL. Nothing to fix.

## Diagnostics to run (in order, before escalating)

```bash
nvidia-smi                                   # GPU health/temps
vastai show machine <ID> --raw               # error_description, gpu_occupancy, listed, earn_hour
vastai self-test machine <ID> --ignore-requirements   # NOTE: space before flag, not "138419--ignore..."
nvidia-ctk cdi list
docker ps -a
vastai show instances-v1                     # check for stray self-test/self-rented instances
dmesg | grep -iE 'nvrm|xid|gsp'
```

## Escalation to Vast.ai support

If `gpu_occupancy` stays stuck as `"x x "` after all of the above (especially after confirming
no stray self-test instance and no GSP crash), it's a backend-side desync between Vast.ai's
occupancy tracker and actual machine state — not fixable locally. Message support with:

- Machine ID, how long it's been stuck, earn_hour before/after
- Confirmation that: machine is listed, nvidia-smi is clean, CDI registry is correct, bandwidth
  test passes on both GPUs, no process/container is holding the GPUs
- Explicit ask: "Can you manually clear/reset the gpu_occupancy flag for machine <ID>?"

Support may ask you to unlist/relist — this does NOT help if the machine never actually
delisted (`listed: true` the whole time); say so if you've already tried it.

## Key gotcha

`vastai self-test machine <ID> --ignore-requirements` needs a **space** before the flag.
Missing it (`138419--ignore-requirements`) produces a malformed request / 400 error that looks
like a different problem.
