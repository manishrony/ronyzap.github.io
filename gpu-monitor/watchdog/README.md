# I/O-probe hardware watchdog (zappa2)

## Why

On 2026-10-08 zappa2 hung for ~10 min: SSH refused, SOL console frozen, but
ping answered and the IPMI watchdog kept being petted, so it never reset.
systemd's `RuntimeWatchdogSec` only proves PID1 is alive — and PID1 stayed
alive while journald, sshd and the console were stuck. (Three git objects
were 0 bytes after the power cycle, but ext4 does that after any hard power
cut, so that proves nothing about the cause.)

This setup hands `/dev/watchdog` to the `watchdog` daemon, which pets the
BMC timer only while `wd-io-probe.sh` passes (every 10s): an uncached
(`O_DIRECT`) 4K write+read on the rootfs, and an `SSH-` banner from sshd on
127.0.0.1:22. The daemon runs non-realtime and the probe drops to
SCHED_OTHER, so a hang that starves ordinary processes stops the petting.

**Why non-realtime:** the second 10/08 hang (16:05) was missed because the
daemon ran `realtime = yes` and the probe inherited RT priority — it kept
passing while journald/sshd/console were starved.

## Expected recovery time

Probe hangs → fails after `test-timeout` (45s) → daemon's error retry window
(60s) → daemon attempts reboot and stops petting → BMC hard reset after
`watchdog-timeout` (60s). Worst case ≈ 3 min, vs. 10 h unattended on 10/07.
A fully frozen kernel still resets in ~60s, as before.

## Deploy (as root, from the repo clone)

```
install -m 755 gpu-monitor/watchdog/wd-io-probe.sh /usr/local/sbin/wd-io-probe.sh
apt install -y watchdog
cp gpu-monitor/watchdog/watchdog.conf /etc/watchdog.conf
cp /etc/systemd/system.conf.d/watchdog.conf /root/watchdog.conf.dropin.bak
sed -i 's/^RuntimeWatchdogSec=.*/RuntimeWatchdogSec=0/' /etc/systemd/system.conf /etc/systemd/system.conf.d/watchdog.conf
systemctl daemon-reexec
systemctl show -p RuntimeWatchdogUSec        # must be 0
systemctl reset-failed watchdog wd_keepalive
systemctl enable --now watchdog
```

Then install the reboot-loop circuit breaker (**before** enabling the
watchdog, so a bad probe can't loop):

```
install -m 755 gpu-monitor/watchdog/wd-breaker.sh /usr/local/sbin/wd-breaker.sh
cp gpu-monitor/watchdog/wd-breaker.service /etc/systemd/system/
mkdir -p /etc/systemd/system/watchdog.service.d
cp gpu-monitor/watchdog/watchdog-breaker.conf /etc/systemd/system/watchdog.service.d/breaker.conf
systemctl daemon-reload
```

Verify: `journalctl -u watchdog` shows `test binary ... wd-io-probe.sh` and
`alive=/dev/watchdog` (not `[none]`); `ipmitool ... mc watchdog get` countdown
keeps resetting.

## Reboot-loop circuit breaker

If the fault recurs right after every boot (as in the earlier "every boot
is failing" phase), the watchdog would reset the rig forever. `wd-breaker`
runs once per boot before `watchdog.service` and logs the boot time. On the
**3rd boot within 30 min** it writes `/var/lib/wd-breaker/tripped`, and
`watchdog.service` is skipped (`ConditionPathExists=!`). Nothing holds
`/dev/watchdog`, so the BMC timer stays disarmed and the rig stays as-is for
manual attention. That allows at most 2 automatic recoveries per 30 min.
Manual reboots count too.

- Check: `ls /var/lib/wd-breaker/tripped; journalctl -t wd-breaker`
- Re-arm after fixing: `rm /var/lib/wd-breaker/tripped && systemctl start watchdog`

## Gotchas hit during the first deploy

- **Drop-in override:** `/etc/systemd/system.conf.d/watchdog.conf` set
  `RuntimeWatchdogSec=60` and overrode `system.conf`. Until it was zeroed,
  systemd held `/dev/watchdog` and the daemon ran with `alive=[none]` (petting
  nothing). Always check `systemctl show -p RuntimeWatchdogUSec`.
- **Stop "failure" is normal:** on Debian/Ubuntu, stopping `watchdog.service`
  exits 1 on purpose to trigger `wd_keepalive.service` via `OnFailure=`.
  `wd_keepalive` then fails if systemd still holds the device. Harmless.
- `verbose` must be a number (`1`), not `yes`.
- `RebootWatchdogSec=10min` in the drop-in is kept: it only covers hangs
  during shutdown/reboot and doesn't conflict.
- `ipmi_watchdog` still loads at boot via `/etc/modules-load.d/ipmi-watchdog.conf`.

## Probe timing under load (2026-10-08)

20 runs at load ~7.6 with GPUs at 100%: all 0.00–0.01 s. 45s timeout leaves
a huge margin against false resets.

## Rollback

```
systemctl disable --now watchdog
cp /root/watchdog.conf.dropin.bak /etc/systemd/system.conf.d/watchdog.conf
sed -i 's/^RuntimeWatchdogSec=.*/RuntimeWatchdogSec=60s/' /etc/systemd/system.conf
systemctl daemon-reexec
```

If sshd moves off port 22, update the probe or it will reset the rig
(the breaker caps that at 2 resets per 30 min).

## Not yet proven

It has not caught a real hang yet. A forced test (make the probe fail and
watch the BMC reset the box) needs a reboot, so do it in a planned
maintenance window, not while the rig is rented.

No `nvidia-smi` check on purpose: a GPU fault would reboot a rented rig,
and `gpu_monitor.sh` already handles GPU faults.
