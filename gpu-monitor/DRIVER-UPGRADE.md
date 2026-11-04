# NVIDIA driver upgrade runbook (Vast host)

Vast notice (Nov 2026): Blackwell cards on the 595 series must run at least **595.91.07**,
package **`nvidia-open`**, from NVIDIA's apt repository, pinned and held.
This procedure was run end-to-end on zappa3 on 2026-11-03 and worked.

| Rig | OS | Before | After | Done |
|---|---|---|---|---|
| zappa3 | Ubuntu 26.04, kernel 7.0 | 595.84 (Ubuntu archive) | 595.91.07 | 2026-11-03 |
| zappa1 | Ubuntu 24.04 | 595.84 | — | pending |
| zappa2 | Ubuntu 24.04 | 595.71.05 (Ubuntu archive) | 595.91.07 | 2026-11-04 (done during the Xid 79 reboot) |

Run everything as root.

## A. Preflight (no downtime, safe while rented)

```bash
DRIVER_VERSION=595.91.07; DRIVER_PACKAGE=nvidia-open
nvidia-smi --query-gpu=name,compute_cap,driver_version --format=csv,noheader | sort -u
apt-get install linux-headers-$(uname -r) $(dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${source:Package}\n' 'linux-image-*' 2>/dev/null | awk '$1 ~ /^[hi]i/ && $3 ~ /^linux-meta/ { sub(/^linux-image-(extra-)?/, "linux-headers-", $2); print $2 }' | sort -u)
apt-get install $(sed -n 's|^CONFIG_CC_VERSION_TEXT="*[^" ]*-\(gcc-[0-9]*\) .*|\1|p' /lib/modules/*/build/.config | sort -u)
. /etc/os-release; ARCH=$(uname -m | sed 's/aarch64/sbsa/'); wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${VERSION_ID//./}/$ARCH/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb && apt-get update
apt-cache policy nvidia-driver-pinning-$DRIVER_VERSION | grep Candidate
```

Expect `Candidate: 595.91.07-…`. `N: Some sources can be modernized` is harmless.
This does **not** change the driver; `nvidia-smi` still shows the old version.

Preview what will be removed (read-only):

```bash
dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${source:Package}\n' | awk -F'\t' '$1 ~ /^[hi]i/ && $3 ~ /^(nvidia-graphics-drivers|nvidia-kmod-open|nvidia-open|cuda-drivers|linux-restricted-(modules|signatures)|nvidia-settings|nvidia-persistenced|nvidia-modprobe|nvidia-xconfig|(nvidia-)?fabric-?manager|libnvidia-nscq|libnvsdm|(nvidia-)?imex|nvlink5|nvidia-driver-pinning)/ { print $2 }'
```

Every name must contain `nvidia`, `cuda`, `nvlink` or `nvsdm` (or be `libxnvctrl0`), and
none of `nvidia-container-toolkit`, `nvidia-container-toolkit-base`, `libnvidia-container1`,
`libnvidia-container-tools`, `nvidia-docker2` may appear.

## B. Do NOT upgrade under a renter

The new driver only loads after a reboot, and the reboot kills running containers.
Installing without rebooting is worse: host `nvidia-smi` fails with
"Driver/library version mismatch", which Vast's agent picks up and marks the machine
**Offline / bad nvidia_smi** (seen on zappa3).

1. Schedule a maintenance window in the Vast console (≥48 h ahead) so renters are warned.
2. Unlist in the console (existing rentals keep running; no new ones start).
3. Proceed only when this prints nothing:
   ```bash
   docker ps --format '{{.Names}} {{.Status}}' | grep '^C\.'
   ```
   Stopped (`Exited`) rentals are fine; their disk stays.

## C. Upgrade

```bash
systemctl stop gpu-monitor
DRIVER_VERSION=595.91.07; DRIVER_PACKAGE=nvidia-open
command -v nvidia-installer && nvidia-installer --uninstall
OLD_DRIVER_PACKAGES=$(dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${source:Package}\n' | awk -F'\t' '$1 ~ /^[hi]i/ && $3 ~ /^(nvidia-graphics-drivers|nvidia-kmod-open|nvidia-open|cuda-drivers|linux-restricted-(modules|signatures)|nvidia-settings|nvidia-persistenced|nvidia-modprobe|nvidia-xconfig|(nvidia-)?fabric-?manager|libnvidia-nscq|libnvsdm|(nvidia-)?imex|nvlink5|nvidia-driver-pinning)/ { print $2 }'); echo "$OLD_DRIVER_PACKAGES"
apt-get purge --allow-change-held-packages $OLD_DRIVER_PACKAGES   # check REMOVED list against the rules in A
apt-get install nvidia-driver-pinning-$DRIVER_VERSION
apt-get install $DRIVER_PACKAGE
modinfo -k $(ls /boot/vmlinuz-* | sed 's|.*/vmlinuz-||' | sort -V | tail -1) -F version nvidia
```

`modinfo` **must** print `595.91.07`. If not, or the install printed `Error!`, do not reboot.

**Install hangs at `Setting up nvidia-persistenced`** (zappa2, 2026-11-04: old driver still
loaded and a GPU off the bus). The postinst sits in `systemctl start nvidia-persistenced`.
From a second shell, cancel it; the service starts normally after the reboot:

```bash
systemctl stop --no-block nvidia-persistenced
systemctl kill -s KILL nvidia-persistenced
```

The same hang can recur at the end in needrestart's `systemctl restart nvidia-persistenced`;
cancel it the same way. Then `dpkg --configure -a; dpkg -C` must be clean before rebooting.
Do **not** run `apt autoremove` in between (it lists `dkms`).

Hold the driver:

```bash
apt-mark hold $(dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${source:Package}\n' | awk -F'\t' '$1 ~ /^[hi]i/ && $3 ~ /^(nvidia-graphics-drivers|nvidia-kmod-open|nvidia-open|cuda-drivers|nvidia-settings|nvidia-persistenced|nvidia-modprobe|nvidia-xconfig|(nvidia-)?fabric-?manager|libnvidia-nscq|libnvsdm|(nvidia-)?imex|nvlink5|nvidia-driver-pinning)/ { print $2 }')
```

Reboot. zappa2/zappa3: `reboot`. zappa1 (graceful reboot can hang after Xid 79):

```bash
sync; echo s > /proc/sysrq-trigger; sleep 3; echo u > /proc/sysrq-trigger; sleep 3; echo b > /proc/sysrq-trigger
```

## D. After reboot: rebuild CDI specs (required)

Docker hands GPUs to containers through CDI specs in `/etc/cdi/`. Those list
version-numbered library paths, so after the upgrade they still point at the deleted
old files and **every container fails**:

```
failed to fulfil mount request: open /usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.595.84: no such file or directory
```

That covers the base `nvidia.yaml` and every per-rental `D.<hash>.yaml` written by kaalia
(a stopped rental cannot restart until its spec is rebuilt). Rebuild each with its own
vendor/class name. Replace `595\.84` with the rig's old version (zappa2: `595\.71\.05`):

```bash
OLD='595\.84'
mkdir -p /root/cdi-backup && cp -a /etc/cdi/. /root/cdi-backup/
for f in $(grep -l "$OLD" /etc/cdi/*.yaml 2>/dev/null); do
  kind=$(sed -n 's/^kind: *//p' "$f" | tr -d "\"' "); vendor=${kind%/*}; class=${kind#*/}
  if [ -z "$vendor" ] || [ "$vendor" = "$kind" ]; then echo "SKIP $f (kind='$kind')"; continue; fi
  echo "== $f  ($vendor / $class)"
  nvidia-ctk cdi generate --vendor "$vendor" --class "$class" --output "$f"
done
grep -l "$OLD" /etc/cdi/*.yaml 2>/dev/null || echo "no stale specs"
```

`WARN Could not locate …` lines (X11, imex, fabricmanager, vulkan-producer) are normal on a
headless host.

## E. Verify and relist

```bash
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader   # every GPU: 595.91.07
systemctl is-active gpu-monitor docker                             # active, active
docker run --rm --device nvidia.com/gpu=all ubuntu nvidia-smi -L   # GPU list, no error
systemctl restart vastai                                           # clears the stale console error
```

Use `--device nvidia.com/gpu=all` (CDI), not `--gpus all`: with the toolkit in `cdi` mode
(zappa2) `--gpus all` fails with "invoking the NVIDIA Container Runtime Hook directly ... is
not supported" even when everything is healthy.

Wait ~5 min for the console's `bad nvidia_smi` / Offline to clear, then relist and click
**Mark As Done** on the driver notice.
