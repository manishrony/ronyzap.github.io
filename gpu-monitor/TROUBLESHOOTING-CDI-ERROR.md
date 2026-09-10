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
   inconsistent status reporting. Check with `ps -ef | grep kaalia` — should be exactly one
   process. A reboot cleans this up naturally.

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
