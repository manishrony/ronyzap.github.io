# Runbook: "--storage-opt is supported only for overlay over xfs with pquota"

## Symptom

- Vast.ai machine card shows a red banner:
  `Error response from daemon: --storage-opt is supported only for overlay over xfs with "pquota" mount option`
  plus "Your machine is no longer visible in search due to an error."
- Every rental fails to start. `docker ps` is empty, `dump-machine-json` shows
  `listed_gpu_cost = None`, and the pricing engine logs
  `Machine <ID>: not listed - skipping price adjustment`.
- `kaalia.log` loops on a target container that never gets created:
  ```
  diff_conts() diff_next_cmd_ targ: C.<instance id>  cur:
  num cmds: 0 .
  ```

## Why it happens

Vast's agent creates every rental container with `--storage-opt size=...` to enforce the
renter's disk allocation. Docker can only honor that on **overlay2 over XFS mounted with
`pquota`** (the kernel shows it as `prjquota`). On any other filesystem the create fails
outright, so no rental can ever start.

The rigs ship with `/var/lib/docker` on a dedicated XFS volume. If that volume disappears --
drive pulled, LVM volume gone, fstab entry stale -- Docker silently falls back to the root
filesystem, which is ext4. Nothing looks broken locally; only rentals fail.

Seen on zappa2, 2026-09-14, after pulling the NVMe behind the faulty root port `00:01.4`
(see SERR notes). The Docker store lived on that drive's LVM volume.

## Diagnose

```bash
docker info | grep -iE 'storage driver|backing filesystem'   # want: overlay2 / xfs
grep loop0 /proc/mounts                                       # or the real device
findmnt -no SOURCE,FSTYPE,OPTIONS /var/lib/docker             # want xfs + prjquota
```

`Backing Filesystem: extfs` confirms the fallback.

## The trap that cost an hour

**A stale fstab entry for `/var/lib/docker` with `nofail` will silently swallow the mount.**
zappa2 had a curtin-era line pointing at a dm-uuid LVM device from the removed drive:

```
/dev/disk/by-id/dm-uuid-LVM-...  /var/lib/docker  xfs  rw,auto,pquota,nofail  0  0
```

`mount /var/lib/docker` matches the **first** matching fstab entry. The device was gone,
`nofail` suppressed the error, and mount **exited 0 without mounting anything** -- so the
new entry further down the file was never reached, and Docker started on ext4.

Always check for duplicates before debugging anything else:

```bash
grep -n docker /etc/fstab
```

Comment out any stale entry, then verify the mount actually happened -- `exit=0` is not
proof:

```bash
mountpoint /var/lib/docker
```

## Check the whole disk before rebuilding anything

Before creating a loopback or blaming a missing drive, look at what is actually
on the surviving disks. On zappa2 the Docker store was a **6.28 TB LV spanning
BOTH NVMes** (`vg0/lv-0`, created by the curtin installer), so pulling one drive
left the other drive's 2.6 TB stranded inside an unassemblable volume group --
and `df` showed only the 768 GB root partition, which looks like "the disk is
small" rather than "2.6 TB is sitting right there".

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT     # look for unmounted LVM2_member
parted /dev/nvme0n1 print free                # look for unallocated space
pvs; vgs; lvs                                 # "missing PV" / partial (p) attrs
vgdisplay vg0 | grep -E 'Cur PV|Act PV'       # Cur 2 / Act 1 = spanned + broken
```

`Cur PV 2, Act PV 1` with `lvs` showing a `p` attribute means the VG spans a
drive that is gone. The LV cannot activate, and any fstab entry pointing at it
silently does nothing (see the nofail trap above).

Two ways out:

1. **Reinstall the missing drive** -- the VG completes, the LV activates, and
   the original filesystem comes back with its data.
2. **Abandon the LV and reformat the present partition standalone** -- loses
   the LV's contents, but recovers that drive's capacity immediately with no
   hardware work.

Option 2 on zappa2 (2026-09-14) took the advertised disk from 140 GB to
2031 GB in about ten minutes:

```bash
systemctl stop docker docker.socket
umount /var/lib/docker                  # if a loopback was mounted there
vgchange -an vg0
vgremove -ff vg0                        # warns about the missing PV: expected
pvremove -ff /dev/nvme0n1p4
wipefs -a /dev/nvme0n1p4
mkfs.xfs -f -n ftype=1 /dev/nvme0n1p4
cp -a /etc/fstab /etc/fstab.bak-$(date +%Y%m%d-%H%M)
sed -i '\|/var/lib/docker|d' /etc/fstab          # drop ALL old docker lines
echo "UUID=$(blkid -s UUID -o value /dev/nvme0n1p4) /var/lib/docker xfs defaults,pquota 0 2" >> /etc/fstab
systemctl daemon-reload && mount /var/lib/docker
grep nvme0n1p4 /proc/mounts                      # must show prjquota
systemctl start docker
rm -f /var/docker-xfs.img                        # reclaim any loopback
```

**Do not recreate a spanning LV when adding the second drive back.** A linear LV
across two NVMes means either drive failing destroys the whole filesystem, which
is a poor trade on a rig that already has one suspect M.2 port. Give the second
drive its own filesystem.

## Fix A: dedicated XFS drive (preferred)

```bash
systemctl stop docker docker.socket
mv /var/lib/docker /var/lib/docker.bak
mkdir -p /var/lib/docker
mkfs.xfs -f -n ftype=1 /dev/nvmeXn1          # VERIFY the device with lsblk -o NAME,SERIAL,SIZE
echo "UUID=$(blkid -s UUID -o value /dev/nvmeXn1) /var/lib/docker xfs defaults,pquota 0 2" >> /etc/fstab
mount /var/lib/docker && grep docker /proc/mounts     # must show prjquota
cp -a /var/lib/docker.bak/. /var/lib/docker/
systemctl start docker
```

## Fix B: XFS loopback image (no spare drive)

Slightly slower on image extract and capped at the image size, but works immediately.

```bash
systemctl stop docker docker.socket
fallocate -l 600G /var/docker-xfs.img         # counts fully against root from creation
mkfs.xfs -f -n ftype=1 /var/docker-xfs.img
mv /var/lib/docker /var/lib/docker.bak
mkdir -p /var/lib/docker
echo "/var/docker-xfs.img /var/lib/docker xfs loop,defaults,pquota 0 0" >> /etc/fstab
systemctl daemon-reload
mount /var/lib/docker && grep loop /proc/mounts        # must show prjquota
cp -a /var/lib/docker.bak/. /var/lib/docker/
systemctl start docker
```

Pin Docker to the mount so a slow loop setup can't race it at boot:

```bash
mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=/var/lib/docker\n' \
  > /etc/systemd/system/docker.service.d/10-wait-for-xfs.conf
systemctl daemon-reload
```

## Verify -- this is the gate, do not skip it

```bash
docker info | grep -iE 'storage driver|backing filesystem'     # overlay2 / xfs
docker run --rm --storage-opt size=10G alpine df -h /          # must report a 10G root
```

The second command is the exact call Vast makes. If it fails, nothing else matters.
Keep `/var/lib/docker.bak` until it passes, then remove it.

## After the fix

1. `systemctl restart vastai` and watch `tail -f /var/lib/vastai_kaalia/kaalia.log` for clean
   heartbeats and no storage-opt errors. A restart is brief; do NOT `systemctl stop` and
   leave it stopped -- offline minutes cost reliability score (see
   TROUBLESHOOTING-CDI-ERROR.md, "Reliability score: do not spend it on cosmetics").
2. The machine relists on its own once the agent reports healthy -- watch `listed_gpu_cost`
   in `dump-machine-json` go from `None` to a price.
3. **The red banner is a cached last-error string, not a live check.** It can persist after
   the fault is fixed and after rentals resume. Don't keep chasing it.
4. **Update the advertised disk size** on the machine page to match the new volume. It is
   still carrying the old drive's figure, and renters size jobs against it.
5. Check for a stuck reservation holding disk:
   ```bash
   dump-machine-json | grep -E 'alloc_disk_space|avail_disk_space'
   ```
   A machine card showing `#Stored: D: 1` with `docker ps -a` empty means a stranded
   instance. If it is self-rented it will NOT appear under the machine's instance list --
   look under Instances (client side), or use the CLI:
   ```bash
   vastai show instances-v1
   vastai destroy instance <INSTANCE_ID>
   ```
   See also TROUBLESHOOTING-CDI-ERROR.md, root cause #1 -- same class of problem.

## Reboot test

The failure mode is boot-time, so a fix that works live can still regress on reboot. In a
vacancy window:

```bash
reboot
# then
grep docker /proc/mounts && docker info | grep -i 'backing filesystem'
```
