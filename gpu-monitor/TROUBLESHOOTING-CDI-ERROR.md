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

   **The Xid 154 wording varies.** Confirmed live on zappa1 (2026-10-30 08:32), the same
   fallen-off-the-bus fault produced `0x0 (None) to 0x1 (GPU Reset Required)` instead of
   `0x2 (Node Reboot Required)`. Treat both the same way -- they are the identical underlying
   fault, just a different recovery-action code from the driver. `gpu-monitor/xid79-autoreboot.sh`
   matches both strings for this reason; if you're grepping manually, match on
   `recovery action changed from 0x0` generally, not on one specific wording.

   **`Node Reboot Required` / `GPU Reset Required` means exactly that.** Xid 79 is not recoverable
   in software: the GPU stopped responding on PCIe and cannot be reset without a power cycle.
   Restarting Docker, regenerating CDI specs, or bouncing vastai will not bring it back. Do not
   waste an outage window on them.

   ```bash
   sudo reboot
   ```

   **`sudo reboot` can hang instead of completing.** The affected GPU's own PCIe device is what
   `reboot` needs to quiesce, and a card that has already fallen off the bus may not respond to
   that shutdown handshake — the command (and your SSH session) can just sit there. Confirmed live
   on zappa1 (2026-09-25): `sudo reboot` after a dual-GPU Xid 79 never returned; only pressing the
   physical reset button on the motherboard actually cycled the box. **Give `sudo reboot` at most
   ~30s to drop the SSH session — if it doesn't, stop waiting and power-cycle at the machine**
   (physical reset/power button, or IPMI/BMC power-cycle if you have remote access to it). Don't
   keep re-running `sudo reboot` from a hung session; it won't retry, it's just stuck.

   If you have no physical/IPMI access, the remote equivalent of a power-cycle is a magic SysRq
   hard reset, which bypasses the graceful shutdown path entirely instead of waiting on it:
   ```bash
   echo 1 > /proc/sys/kernel/sysrq
   echo b > /proc/sysrq-trigger
   ```
   Confirmed live on zappa1 (2026-10-30): recovered a dual-GPU-down state after `sudo reboot`
   hung, instantly. `xid79-autoreboot.sh` now goes straight to SysRq (sync `s`, read-only `u`,
   reboot `b`). It used to run `systemctl reboot` and fall back to SysRq after 30 s, but that
   fallback ran inside the watcher's own service, which the shutdown stops first. Its log shows
   every automatic reboot hanging that way: 2026-10-30 10:25:50 (back 10:39), 2026-10-31
   12:01:39 (back 12:17) and 2026-11-02 15:48:31 (back 16:02, only after someone pressed the
   power button). None of them logged the SysRq fallback.

   **A second, milder hang variant exists and is not Xid-related.** Also on zappa1 (2026-10-30,
   ~50 min after the Xid 79 above, on the next boot), an ordinary `reboot`/`shutdown` -- with no
   Xid 79/154 in the log at all -- hung for 7+ minutes on GPU0 during the Docker-unmount shutdown
   step:
   ```
   systemd: Failed unmounting var-lib-docker.mount - /var/lib/docker.
   kernel: nvidia-modeset: ERROR: GPU:0: Error while waiting for GPU progress: 0x0000ca7d:0 2:0:4048:4040
   ```
   (repeating every ~5s). This is `journalctl -b -1 -p err`'s signature for it -- different
   subsystem (`nvidia-modeset`, not `NVRM`/Xid), same family of problem: a GPU not releasing
   cleanly for shutdown. It self-resolved without intervention that time (box came up ~7 min
   later), so it is not yet known whether it ever needs the SysRq fallback above -- but if a
   reboot is stuck specifically on repeating `nvidia-modeset: ... waiting for GPU progress` lines
   rather than silence, this is why, and the same SysRq remedy applies if it doesn't self-resolve.

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

   **zappa1 repeat log, bus `0000:01:00` (GPU 0):** Xid 79 + 154 at 2026-10-31 12:01:08,
   2026-11-02 15:48:00 and 2026-11-03 06:38:52, each while that GPU was under a renter's full
   load (the 11-02 one with the mining throttle active at 450 W). The 11-03 line read `79,
   pid=175798, name=python, GPU has fallen off the bus`, which the watcher's exact-text match
   missed, so no auto-reboot fired and GPU 0 stayed dead until a manual reboot. Three times on
   the same bus in four days is a hardware fault, not a transient.

   **Reseated 2026-11-03 ~11:00-11:17 UTC:** GPU 0 (bus `01:00`) removed and reinserted during
   a SysRq power-off. Both GPUs back after boot (`01:00.0` and `03:00.0`, Gen5 x8 under load).
   If bus `01:00` drops again after this, reseat both ends of its power cable (not done this
   time), and if it repeats after that, swap GPU 0 and GPU 1 between slots to see whether the
   fault follows the card or the slot.

   **Repeat after the reseat, 2026-11-04 10:23:08:** Xid 79 + 154 on bus `01:00` again (4th
   time in 5 days), with GPU 0 under a renter (python3) and GPU 1 mining at 400 W. The fixed
   watcher caught it and SysRq-rebooted at 10:23:39; back up at 10:24 with both GPUs and both
   renters resumed (about 1 minute down, versus hours before). It happened ~1 min after zappa2
   came back from its own SysRq reboot (8 GPUs initialising); the PDU at `192.168.1.251`
   reads 4-4.8 kW, more than zappa1 alone draws, so the rigs likely share that circuit and a
   power sag is a candidate trigger. Reseating the card did not fix it. Next: reseat both ends
   of GPU 0's 12V-2x6 power cable and inspect the connector pins/housing for browning or
   melting; if it drops again, swap the two cards between slots.

   **Power cable reseated 2026-11-04 ~10:38-10:46 UTC** (during the driver-upgrade power-off):
   both ends of GPU 0's 12V-2x6 cable reseated; connector pins and housing looked normal, no
   browning or melting. Card and cable have now both been reseated. If bus `01:00` drops
   again, swap GPU 0 and GPU 1 between slots: fault follows the card -> RMA the card; stays at
   `01:00` -> slot/riser/motherboard.

   **zappa1 repeat, 2026-11-09 17:44:37:** bus `01:00` again, after 3.5 days clean (longest run
   yet). The watcher rebooted within a minute. Reliability fell 0.97 to 0.58. The same diag
   showed both GPUs at **525 W**, not the conf's `POWER_LIMITS=("5090:400")`. The source was
   `GPU_POWER_LIMIT=525` on line 21 of `/etc/gpu_monitor.conf` (install.sh's 5th argument
   can also put it in the systemd unit as `Environment=GPU_POWER_LIMIT=`). It forces one value
   on every GPU, logged as `GPU n -> 525W OK (override)`, and the per-model curve never
   applies. Removed 2026-11-09 and set `POWER_LIMITS=("5090:450")`; both GPUs now 450 W.
   diag.sh now prints `GPU_POWER_LIMIT` so this can't hide again.

   **zappa1 repeat, 2026-11-10 20:00:18:** bus `01:00` again, at 450 W this time, about 27 h
   after the last one and 7 min after a new 2-GPU ComfyUI renter (60115542, $0.47) started.
   The watcher rebooted at 20:00:49, back at 20:01:20 (~1 min). Reliability fell 0.90 to 0.50.
   The 450 W cap did not prevent it, so power limit is ruled out for this card. With every drop
   on `01:00`, the next step is the physical swap: put the `01:00` card in the other slot (or
   its riser/cable on the other card) at the next power-off. If the fault follows the card,
   it's the card; if it stays on `01:00`, it's the slot/riser.
   `01:00` is the **liquid-cooled ZOTAC** (subsystem `19da:1761`, VBIOS 98.02.2E.80.4A); `03:00`
   is an air-cooled MSI (`1462:5303`) that has never dropped. Before the swap, check the AIO
   tubing/radiator isn't pulling on the card (on an open rig the weight can twist the slot or
   riser connector, which gives exactly this intermittent fall-off-the-bus), check the
   pump/fan power lead, and the 12V-2x6 connector for browning and full seating.
   2026-11-11: AIO tubing/radiator checked by the owner, no strain on the card, so tube strain is ruled out. Still to do: 12V-2x6 seating/browning, the ZOTAC/MSI slot swap, Gen4 in BIOS (link still trains Gen5).

   **Again 2026-11-10 21:06:43, 65 min after that reboot:** the ZOTAC on `01:00` went into a
   `NV_ERR_GPU_IN_FULLCHIP_RESET` storm (`nvidia-smi`: "Unable to determine the device handle
   for GPU0: 0000:01:00.0: Unknown Error"). Inside the 2 h guard window, so the watcher alerted
   instead of rebooting, as designed. It also sent one Telegram alert per 5 log lines (5 in
   2 s); now limited to one per 30 min. Two failures in about an hour: the card or slot is
   getting worse, so take it out of service at the next power-off rather than reboot-looping.

   Full zappa1 list from diag (all `01:00`, the ZOTAC): 11-09 17:44:37, 11-09 20:59:56,
   11-10 20:00:18, 11-10 21:06:43. The last two each came within ~10 min of a new 2-GPU
   renter starting (19:53, then 60122040 at 20:57), so the card now fails as soon as it is
   loaded. Still dead at 22:24 with the guard window over: the watcher only reacts to new log
   lines, so a GPU that stays dead after the window waits for a human. By 22:24 the Vast
   snapshot showed `listed_gpu_cost`/`end_date` = None (offer gone).

   **zappa2 drop log (8x 5090, TYAN), from `journalctl _TRANSPORT=kernel | grep 'fallen off'`:**

   | When (UTC) | Bus | Index | Context |
   |---|---|---|---|
   | 2026-11-04 02:54:30 | `04:00` | GPU 0 | |
   | 2026-11-05 14:31:39 | `85:00` | GPU 5 (MSI) | renter python under load |
   | 2026-11-05 14:47:29 | `c2:00` | GPU 6 | renter python, 16 min after the one above |
   | 2026-11-06 19:33:33 | `85:00` | GPU 5 (MSI) | long-term renter at full 450 W; inlet *not* hot (no SEL alert since 15:13) |
   | 2026-11-07 05:32:06 | `c2:00` | GPU 6 | ~4 min after an 8-GPU renter started (05:28); renter ended `GPU_ERROR` |
   | 2026-11-09 15:38:05 | `c2:00` | GPU 6 | renter vLLM engine; card was already capped at 400 W by `GPU_POWER_OVERRIDE`, so the cap did not prevent it. Third drop on `c2:00` in 5 days |
   | 2026-11-09 21:47:09 | `c2:00` | slot 101 | 5.5 h after the 16:09 power-off/reboot. Afterwards the periodic bandwidthTest failed on the idle GPUs 0/1/3/4: a knock-on effect of the Xid 154 "Node Reboot Required" state, not four new faults |
   | 2026-11-10 13:32:52 | `83:00` | slot 105 | first drop on this slot; ~14 h after the Gen4 boot. `c2:00` (Gen4 + reseat) stayed up. Renter on GPU 0 (`04:00`, vLLM 400-450 W) unaffected; another renter ended `GPU_ERROR` at 13:50. With `83:00` gone the indices shift (idx4=`85:00`, idx5=`c2:00`, idx6=`c4:00`), so the index-based 400 W override sat on the wrong cards until the reboot. Recovered by a BMC power reset at 15:26, back at 15:32 with 8 GPUs, about 2 h down; reliability fell 0.866 to 0.56. A renter opened a Vast support ticket: their GPU (UUID `a0dab2ed...`, which is `06:00`/slot 110, the x4 card; the ticket's "C2:00" was wrong) gave `cuInit` error 999 with "GPU Recovery Action: Reboot". That is the Xid 154 state every surviving GPU enters after any drop, not a second fault, and only a host reboot clears it |

   **2026-11-09 ~23:50: BIOS PCIe link speed forced to Gen4 on all GPU slots** (was Auto/Gen5).
   After boot all 8 GPUs report `pcie.link.gen.max` 4, all x8 except `06:00` (slot 110, GPU 1),
   which has trained x4 since the 16:09 power-off and stayed x4 at Gen4 too, so it is physical
   (MCIO cable or seating), not signal speed. Judge Gen4 by `c2:00`: it dropped every 1-2 days
   (once 5.5 h after boot); 5+ days clean means Gen4 fixed it, then apply the same to zappa1.
   Also during the 2026-11-10 00:06 power-off, the MCIO cable for `c2:00` (slot 101) was
   reseated, so the 5-day test covers Gen4 plus the reseat together. The card was physically
   identified with a 2-minute load on index 6 (only that card's fan spins up; GPU 2 always
   idles at ~80% fan and GPU 5 at ~30%, so ignore those):
   `docker run --rm --device nvidia.com/gpu=6 --entrypoint python <local pytorch image> -c "..."`.

   **BMC PSU check, 2026-11-10: inconclusive.** `ipmitool sdr` lists PSU0/PSU1 sensors as
   `disabled` / `Not Readable`, so the BMC has no telemetry from these PSUs. The only power SEL
   events are `AC lost | Deasserted` (AC restored) at the planned power-ons (11-02, 11-07 04:16,
   11-09 16:08, 11-10 00:08), none at any drop time, so the board never lost AC input during a
   drop. Per-GPU 12V rails and the PSUs themselves remain unchecked; the PDU (`pdu-power.sh`) is
   the only power data source left.

   **BMC sensor snapshot, 2026-11-11 02:36, all 8 GPUs loaded (~3.5 kW):** 12V rails 12.00 /
   11.91 V, 3.3V 3.35 V: no sag at full load. `VDD_5_RUN` 4.66 V, below the usual 4.75 V
   (-5%) floor; the GPUs don't use 5V, but MCIO risers powered by SATA connectors would. Check
   whether it changes between idle and load (`ipmitool sensor get VDD_5_RUN`: 4.658 +/- 0.017 V, BMC lower critical 4.487 V = -10%, so "ok" to the board but under the ATX -5% spec). 10-min log 2026-11-11 10:34-10:45 with total GPU draw swinging 1905-2621 W: 5V stayed at 4.658 V and 12V at 11.913 V on every sample, so neither rail moves with load. The 5V is a fixed sensor offset, not sag; ruled out. Inlet MB 41 /
   OCP 35 C (50 C critical; last alert 11-06 15:13), CPU 48, VRM 48, DIMMs 35-37 C. No BMC fan
   or PSU readings on this open rig, and `dcmi power reading` returns 0 W, so the PDU is the
   only power meter. The SEL shows `Watchdog2 IPMI_Watchdog | Hard reset` at 11-07 07:07,
   11-09 23:49 and 11-10 15:26: those three recoveries were the BMC watchdog resetting a
   reboot that had hung, not someone pressing reset. That is why the zappa2 watcher ends
   with a BMC power cycle instead of a warm reboot.

   **2026-11-10: `xid79-autoreboot` installed on zappa2** after the 83:00 drop sat for 2 h.
   On a rig whose BMC answers `ipmitool mc info` it ends with `ipmitool chassis power cycle`
   (cold boot by the BMC, with SysRq `b` as the fallback after 60 s); zappa1 still uses SysRq.
   Install, then test BEFORE enabling (an injected line with the service running reboots for real):
   ```bash
   cd /home/ronyzap/ronyzap.github.io && git pull
   install -m 755 gpu-monitor/xid79-autoreboot.sh /usr/local/bin/
   install -m 644 gpu-monitor/xid79-autoreboot.service /etc/systemd/system/
   # terminal 1: dry run (logs + TEST Telegram, never reboots)
   AUTOREBOOT_DRY_RUN=1 /usr/local/bin/xid79-autoreboot.sh
   # terminal 2: fake fault on bus ff:00, marked TEST so it can't be mistaken for a real drop
   echo 'NVRM: Xid (PCI:0000:ff:00): 79, TEST ONLY GPU has fallen off the bus' > /dev/kmsg
   echo 'NVRM: Xid (PCI:0000:ff:00): 154, TEST ONLY Node Reboot Required' > /dev/kmsg
   tail -5 /var/log/xid79_autoreboot.log   # expect "reboot method: ipmi" and "DRY RUN"
   # Ctrl-C terminal 1, then:
   systemctl daemon-reload && systemctl enable --now xid79-autoreboot
   ```
   Enabled on zappa2 2026-11-10 ~20:00 UTC; startup log confirmed `reboot method: ipmi`. The
   TEST lines on bus `ff:00` in that day's kernel log were written after the dry run had
   exited, so detection was not exercised on zappa2 (the same matching code has caught real
   drops on zappa1). Ignore those `ff:00` lines in diag. Pasting the steps above into one
   terminal does not work: the dry run blocks it and the rest runs only after Ctrl-C.

   Bus to physical slot (from `/sys/bus/pci/slots/*/address`; GPUs report serial `0`, so slot
   is the only way to find the card): `04:00`=109, `06:00`=110, `42:00`=113, `44:00`=114,
   `83:00`=105, `85:00`=106, `c2:00`=101, `c4:00`=102. Pairs (101/102, 105/106, 109/110,
   113/114) share a PCIe switch.

   UUIDs never change with index shifts or reboots, so use them to match a renter ticket or
   a Vast error to a card (`nvidia-smi --query-gpu=index,pci.bus_id,uuid --format=csv`, 2026-11-10):

   | Bus | Slot | UUID |
   |---|---|---|
   | `04:00` | 109 | `GPU-566e5ae0-abb3-e627-f417-440f91768b67` |
   | `06:00` | 110 | `GPU-a0dab2ed-9b32-a1bb-a1e8-50e48ac95468` |
   | `42:00` | 113 | `GPU-bb45dbe5-4d67-b43c-348b-5d46d5626a1f` |
   | `44:00` | 114 | `GPU-ada5ae30-f911-9eae-aa7a-6a02e49997e0` |
   | `83:00` | 105 | `GPU-09430fe5-1897-ef75-3b74-0741bb7c1f3e` |
   | `85:00` | 106 | `GPU-8e951f0f-b7b6-64fd-5a69-db3cc5de782f` (MSI) |
   | `c2:00` | 101 | `GPU-4ca80fb9-44d5-485c-a75c-917c34a84f7c` |
   | `c4:00` | 102 | `GPU-819437f8-b208-8190-e7ef-0eb7e233edb8` |

   **As of 2026-11-10, four different slots have dropped (109, 106, 101, 105; 106 and 101 repeatedly) across all four PCIe switches**, so a single card, cable or link speed cannot explain them all. Gen4 did not stop drops on other slots; power delivery is now the main suspect.

   Two slots repeat (`85:00` twice, `c2:00` twice) and a third dropped once, on different root
   complexes. The two most recent drops had no inlet alert and one came minutes after a cold
   boot, so room heat no longer explains them; shared power delivery (PSUs, 12V-2x6 cables, the
   circuit shared with zappa1 via PDU `192.168.1.251`) is the leading suspect. The reboot sent
   at 2026-11-06 23:42 hung until ~04:17 (4.5 h down), and the 05:32 drop needed a BMC power
   reset at 07:07; reliability fell from 0.93 to 0.65 and the 30-day 4-GPU renter left.
   Mitigation in place 2026-11-07: `GPU_POWER_OVERRIDE` caps GPU 5 at 400 W (350 W at >=70 C).
   Next: check BMC PSU sensors/SEL, then in a window reseat the 12V-2x6 cables on `85:00` and
   `c2:00` (inspect for browning) and swap one of them with a card that has never dropped.

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
