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
> Root cause #2 below (stray self-rented instance) still applies to both.

## Root causes seen (check in this order)

1. **A GPU has fallen off the bus (Xid 79). CHECK THIS FIRST.**
   The CDI error is a *symptom* here, not the fault. If a GPU drops off PCIe, kaalia cannot write
   a CDI spec that includes it, so the next container asks for a device with no spec behind it and
   fails to launch. The visible error points at Docker; the cause is hardware, minutes earlier.

   **The check is fast and it invalidates every cause below it:** does `nvidia-smi` list all the
   GPUs the machine is supposed to have?

   ```bash
   nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv
   journalctl -k --since "6 hours ago" | grep -iE 'Xid|fallen off the bus|recovery action'
   ```

   Signature (zappa1, machine 138419, 2026-09-15 00:48):
   ```
   NVRM: Xid (PCI:0000:01:00): 79, pid=..., name=nvidia-smi, GPU has fallen off the bus.
   NVRM: Xid (PCI:0000:01:00): 154, GPU recovery action changed from 0x0 (None) to 0x2 (Node Reboot Required)
   ```
   with `nvidia-smi` showing 1 GPU on a 2-GPU machine, and the monitor logging
   `Unable to determine the device handle for GPU0: 0000:01:00.0: Unknown Error`.

   **`Node Reboot Required` means exactly that.** Xid 79 is not recoverable in software: the GPU
   stopped responding on PCIe and cannot be reset without a power cycle. Restarting Docker,
   regenerating CDI specs, or bouncing vastai will not bring it back. Do not waste an outage
   window on them.

   ```bash
   sudo reboot
   ```

   **Reboot immediately if the machine is vacant** (`gpu_occupancy` all `x`, no running
   containers). A delisted machine earns $0, so there is no reliability left to protect and
   waiting only extends the outage. This is the one case that overrides the "never reboot for
   cleanup" rule below — it is a real fault, not cosmetics.

   After the reboot:
   ```bash
   nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv   # expect the full count back
   vastai show machine <ID> --raw | grep -E '"listed"|"listed_gpu_cost"'
   ```
   Relisting takes a few minutes while kaalia re-registers; `VAST.AI INIT: API call failed` in the
   monitor log right after boot is just the agent not being up yet, not a fault.

   If the GPU does **not** come back, it is hardware — riser, power cable, or the card. The
   `PCI:0000:xx:00` address in the Xid line gives you the slot. Xid 79 after days of clean uptime
   on a rig that has been renting normally is more often a transient link drop than a dead card,
   so do not order parts off one event; do log it and watch for a repeat on the same bus address.

2. **Leftover self-test/self-rented instance holding the GPUs.**
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

3. **A missing per-container CDI spec.**

   **How CDI actually works on these rigs** (measured on zappa1 2026-09-15 — an earlier version
   of this runbook described it wrongly, so read this before judging any `cdi list` output):

   - Specs live in `/etc/cdi/` as YAML, one file per vendor.
   - `nvidia.yaml` is the **base** spec, vendor `nvidia.com/gpu=*`.
   - kaalia writes an **additional spec per container** at launch, vendor `D.<container-hash>`,
     named `/etc/cdi/D.<hash>.yaml`. These accumulate; they are not cleaned up on exit.
   - Each vendor contributes 5 devices: `gpu=0`, `gpu=1`, one per GPU UUID, and `gpu=all`.

   So on a healthy 2-GPU host: **5 x (1 base + N container specs)**. zappa1 showed `Found 35 CDI
   devices` (7 vendors) while completely healthy. A large number is normal and is **not** the
   fault. Only two things matter:

   - every vendor lists every GPU the machine has, and
   - the `D.<hash>` named in the error actually exists.

   ```bash
   nvidia-ctk cdi list
   ls -la /etc/cdi/
   docker ps -a
   ```

   **The real signature.** Take the hash out of the error message and look for it:
   ```
   unresolvable CDI devices D.da39805c259ed6a4...e200e2d621e/gpu=0: unknown
   ```
   If that `D.<hash>` is **absent** from `nvidia-ctk cdi list`, the spec was never written. That is
   not a corrupt registry — it means kaalia could not enumerate the GPUs at launch time, which
   sends you back to **root cause #1**. Regenerating specs will not fix it.

   **What regenerating can and cannot do:**
   ```bash
   sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml && nvidia-ctk cdi list
   ```
   This rewrites **only** `nvidia.yaml`. It is safe while listed and needs no service restart.
   It fixes a stale *base* spec (e.g. one written while a GPU was missing, or after a driver
   upgrade). It **cannot** create a missing `D.<hash>` spec — only kaalia writes those.

   **Fresh `D.*.yaml` files appearing every few minutes means the CDI path is working.** On zappa1
   four specs were written in 20 minutes (02:11, 02:16, 02:20, 02:25) while the console still
   showed the old banner — containers were launching fine and the banner was stale.

   **Orphaned specs:** correlate `/etc/cdi/D.*.yaml` against `docker ps -a`. A spec whose container
   is gone is dead weight, but it is ~15KB and harms nothing. **Never delete a spec whose container
   still exists** — that recreates exactly the unresolvable-device failure.

   **Dead containers.** `docker rm` is safe only once you know the rental is over:
   ```bash
   docker ps -a --format '{{.ID}}  {{.Names}}  {{.Status}}  {{.Image}}'
   ```
   `Exited (137)` is SIGKILL — how Vast stops an instance a renter **paused**, not necessarily one
   they abandoned. Those show as `current_rentals_resident` and the renter may still be paying for
   the disk and expecting to resume. Check the console for those instance IDs first. Deleting a
   paused renter's container destroys their data and invites a report against the machine, which
   costs far more than a stale banner. `clients: []` is suggestive, not proof.

4. **GPU GSP/UVM firmware crash (real hardware-adjacent fault).**
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

5. **Orphaned kaalia processes** from repeated `systemctl restart vastai.service` can cause
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

## The banner outlives the fault: `listed` is the field that matters

`error_description` is the **last error Vast recorded**, not live state. It does not clear on a
timer and nothing on the host clears it directly — it is overwritten the next time the machine
reports an instance outcome (a renter's container starting, or a passing self-test).

So after a fix, judge recovery by these, in this order:

```bash
vastai show machine <ID> --raw | grep -E '"listed"|"listed_gpu_cost"|"error_description"'
```

- `listed: true` **and** `listed_gpu_cost: <number>` → you are back in search and rentable. This is
  the part that earns. On zappa1 these flipped from `false`/`null` within ~3 minutes of the reboot.
- `error_description` still set while the above are good → **stale string, not a blocker.** It is
  gating nothing.

Do not reboot, restart vastai, or delete a renter's container to clear a banner. Per the
reliability rules below, that spends real score on a cosmetic field. Let the next rental or
self-test overwrite it.

If `listed` stays `false`, or `gpu_occupancy` stays `"x x "` after everything above, that is the
backend desync described in the escalation section — a support ticket, not more host-side work.

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
nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv   # FIRST: is every GPU present?
journalctl -k --since "6 hours ago" | grep -iE 'Xid|fallen off the bus'   # FIRST: Xid 79?
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
