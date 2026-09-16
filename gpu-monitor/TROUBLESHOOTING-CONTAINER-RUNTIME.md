# Runbook: renters' containers won't start or stop (AppArmor / docker-default)

## Symptom

What you actually see, in order of how visible it is:

- Rentals end after minutes. On the console it just looks like **renters leaving fast**.
- `docker ps -a` shows containers in **`Exited (137)`** — SIGKILL, not a clean stop.
- Several different renters in a row, with unrelated images, all short.
- `earn_hour` sags while the machine looks perfectly healthy: no faults, no Xid,
  GPU idle and cool, `listed: true`, reliability high.

Nothing in the GPU telemetry points at this. The machine is not broken in any way
`nvidia-smi` or the BMC can see, which is exactly why it goes unnoticed.

> `gpu_monitor.sh` now alerts on this directly — see "Proactive alerting" below.
> If you got a **🚨 Container Runtime Fault** Telegram, start at the fix.

## Confirming it

One command decides it:

```bash
sudo dmesg | grep -E 'apparmor.*DENIED.*class="signal"'
```

The signature (captured live on zappa3, 2026-09-16):

```
apparmor="DENIED" operation="signal" class="signal" profile="docker-default"
  comm="runc" requested_mask="receive" denied_mask="receive" signal=term peer="runc"
apparmor="DENIED" operation="signal" class="signal" profile="docker-default"
  comm="runc" requested_mask="receive" denied_mask="receive" signal=kill peer="runc"
```

That is Docker's own AppArmor profile refusing to let Docker's own runtime
deliver SIGTERM/SIGKILL into containers. Corroborate in the docker journal:

```bash
sudo journalctl -u docker --since "1 hour ago" | grep -E 'unable to signal init|healthcheck failed fatally|is not running'
```

```
Error setting up exec command in container C.xxxxx: container ... is not running
healthcheck failed fatally: Unavailable: connection error
Error sending stop (signal 15) to container ...
  kaalia_docker_shim did not terminate successfully: exit status 1:
  unable to signal init: permission denied
Container failed to exit within 10s of kill - trying direct SIGKILL
```

**The kaalia shim error is a symptom, not the cause.** Vast's shim is the thing
that happens to be signalling when the denial lands; the denial itself is
`docker-default` vs `runc`. Don't open a Vast ticket for this one.

## Ignore this noise

Not every AppArmor denial is the fault. Same machine, same `dmesg`, unrelated:

```
apparmor="DENIED" operation="open"   class="file"   profile="tshark" ...
apparmor="DENIED" operation="ptrace" class="ptrace" profile="tshark" ...
```

`tshark` runs under its own profile (network testing) and its denials are
harmless. Only `class="signal"` with `profile="docker-default"` matters — which
is why the grep above filters on the class, not just on `DENIED`.

Also expected, and **not** a fault on its own:

```
apparmor="STATUS" operation="profile_replace" info="same as current profile, skipping" name="docker-default"
```

That line is a *clue*, though: Docker tried to reload `docker-default` and
AppArmor declined because it believed nothing had changed. A stale profile
pinned in the kernel is how the machine gets stuck in this state.

## Fix

```bash
sudo systemctl restart docker && sleep 5 && systemctl is-active docker
```

Regenerating the profile is what clears it. **Do this while the machine is
vacant** — it bounces every running container, so check `gpu_occupancy` first.
It does not touch `vastai`/kaalia, so reliability is unaffected.

Verify:

```bash
sudo dmesg -C
sudo docker run --rm --name sigtest alpine sh -c 'sleep 60 & wait $!' &
sleep 5; sudo docker stop sigtest; echo "stop exit=$?"
sudo dmesg | grep -cE 'apparmor.*DENIED.*class="signal"'
```

Want **`stop exit=0`** and a denial count of **`0`**.

> Gotcha: write the payload as `sleep 60 & wait $!`, not a bare `sleep 60`. A
> foreground child blocks the shell from running traps, and a bare `sleep` as
> PID 1 has no default SIGTERM handler at all — either way the container rides
> out the grace period and exits 137 even on a healthy host, which looks like a
> failure and isn't. The denial count is the signal that can't be faked.

If denials return immediately after the restart, the profile is genuinely
malformed rather than stale. Reload it explicitly:

```bash
sudo apparmor_parser -r -W /etc/apparmor.d/docker
```

`/etc/apparmor.d/docker not found` is **normal** — Docker generates
`docker-default` in memory rather than keeping it on disk, so there is usually
nothing there to reload. In that case the remaining levers are upgrading
`apparmor`/`docker.io` or pinning Docker to the version the distro's AppArmor
package was built against.

**Do not disable AppArmor.** It is part of the isolation between renters and the
host, and this is a profile bug, not a reason to remove confinement.

## Does it survive a reboot?

Unknown until tested — the fix regenerates a runtime profile, and boot may load
a bad one again. After the next reboot of an affected host:

```bash
sudo dmesg | grep -cE 'apparmor.*DENIED.*class="signal"'
```

Non-zero means it came back and needs to be made persistent, e.g. a drop-in
that restarts `docker.service` after `apparmor.service` at boot.

## Why one rig and not the others

zappa3 was hit; zappa1 and zappa2 never were. The difference is the platform:

| rig    | OS    | kernel     | docker |
|--------|-------|------------|--------|
| zappa1 | 24.04 | 6.8.0-136  | —      |
| zappa2 | 24.04 | 6.8.0-124  | —      |
| zappa3 | 26.04 | 7.0.0-28   | 29.7.1 |

Newer kernel + newer Docker + newer AppArmor. When something odd happens on
exactly one rig, check whether it is the one running ahead of the others before
chasing hardware — see RIGS.md.

## Proactive alerting

`check_container_runtime_faults()` in `gpu_monitor.sh` runs every main cycle and
pages Telegram on the first cycle that sees any of:

- `apparmor="DENIED"` with `class="signal"` (new dmesg lines only)
- `unable to signal init` in the docker journal
- `healthcheck failed fatally` in the docker journal

It alerts **once per episode** (state in
`/var/tmp/gpu_monitor_container_fault_active`) and sends a recovery message when
a later cycle comes back clean, so a persistent fault doesn't page every hour.

Deliberately **not** alerted on: short rentals or `Exited (137)` by themselves. A
renter destroying an instance after two minutes is ordinary behaviour and would
false-positive constantly. Only host-side faults with no legitimate cause page.

Disable per-rig with `CONTAINER_RUNTIME_ALERTS=0` in `/etc/gpu_monitor.conf`.
