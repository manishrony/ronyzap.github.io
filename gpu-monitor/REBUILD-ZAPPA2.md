# Rebuild runbook: zappa2 motherboard + CPU swap

Replacing the TYAN S8056GME after four hangs in five days. The working
hypothesis is **marginal SP5 socket contact** (see
`TROUBLESHOOTING-PCIE-SERR.md`), so the socket work is the experiment, not a
formality. Everything else is just not breaking things.

**Read the whole thing once before starting.** Several steps are only possible
before power-down and cannot be recovered afterwards.

---

## 0. Before you touch anything

### Confirm the machine is out of service

Run as `ronyzap` — `vastai` is not on root's PATH.

```bash
vastai show machine 143690 --raw | grep -E '"listed"|"gpu_occupancy"|"current_rentals_running"'
```

Want `"listed": false` and `gpu_occupancy` all `x`. If rentals are still
draining, wait — pulling power on a paying instance costs reliability score.

### Back up everything that matters

`machine_id` is the Vast identity. Losing it resets reliability history to zero.
It lives on the OS drive, which is being carried over, so it *should* survive —
back it up anyway, because the cost of being wrong is months of reputation.

```bash
sudo mkdir -p /var/tmp/zappa2-rebuild
cd /var/tmp/zappa2-rebuild

sudo cp /var/lib/vastai_kaalia/machine_id           machine_id.bak
sudo cp /etc/gpu_monitor.conf                        gpu_monitor.conf.bak
sudo cp /etc/fstab                                   fstab.bak
sudo cp /etc/default/grub                            grub.bak
sudo cp /etc/default/earlyoom                        earlyoom.bak
sudo cp -r /etc/netplan                              netplan.bak
sudo cp /etc/modprobe.d/ipmi_watchdog.conf           ipmi_watchdog.conf.bak 2>/dev/null

# identity and layout, for comparing against the new board
sudo dmidecode                        > dmidecode-OLD.txt
sudo lspci -tv                        > lspci-tree-OLD.txt
sudo lspci -vvv                       > lspci-verbose-OLD.txt
ip addr                               > ip-addr-OLD.txt
lsblk -o NAME,SIZE,MODEL,SERIAL,UUID,MOUNTPOINT > lsblk-OLD.txt
sudo blkid                            > blkid-OLD.txt
nvidia-smi --query-gpu=index,name,pci.bus_id,uuid,serial --format=csv > gpus-OLD.csv

# AER baseline to compare after the rebuild
sudo dmesg | grep -ci aer             > aer-dmesg-count-OLD.txt
for d in /sys/bus/pci/devices/*/; do
  [ -f "$d/aer_dev_correctable" ] && echo "$d $(grep TOTAL "$d"/aer_dev_* 2>/dev/null)"
done | sudo tee aer-counters-OLD.txt

cd /var/tmp && sudo tar czf zappa2-rebuild-backup.tar.gz zappa2-rebuild
ls -lh /var/tmp/zappa2-rebuild-backup.tar.gz
```

And a final evidence bundle:

```bash
cd /home/ronyzap/ronyzap.github.io
sudo ./gpu-monitor/capture-fault-evidence.sh
```

**Copy both off the machine.** From your Mac:

```bash
scp ronyzap@192.168.1.196:/var/tmp/zappa2-rebuild-backup.tar.gz ~/Downloads/
scp ronyzap@192.168.1.196:/var/tmp/fault-evidence-zappa2-*.tar.gz ~/Downloads/
```

The `gpus-OLD.csv` file matters more than it looks: it maps GPU index to PCI
address and serial. If the new board enumerates them in a different order, that
file tells you which physical card became which index.

### BIOS screenshots

Via iKVM at `https://192.168.1.247`, reboot into BIOS and photograph:

- **Above 4G Decoding** (must be enabled for 8 GPUs)
- **Resizable BAR**
- **IOMMU / SR-IOV**
- **PCIe link speed** settings per slot
- Boot order and any NVMe-specific settings

You will be setting these again on the new board and it is much easier to match
a photo than to rediscover them with eight GPUs failing to enumerate.

---

## 1. Last measurement on the old board

Only possible while it is still assembled. Five minutes, no live circuits.

**Power the host down and unplug all PSUs from the wall.** Wait 60 seconds.

Multimeter on **Ω** (ohms) or continuity:

1. One probe on a **ground screw of an Acxico breakout board**
2. Other probe on a **motherboard standoff** or the Corsair's metal case
3. Read

| Result | Meaning |
|---|---|
| Under 1 Ω / beeps | Grounds are bonded. Lead #1 (ground offset) weakened further. |
| High or unstable | Bonding is poor — a real finding, and cheap to fix on the rebuild. |

Repeat between **each** Acxico board and the Corsair case. Write the numbers
down; they go in the case file either way.

---

## 2. Power down and document

```bash
sudo poweroff
```

Then **unplug every PSU from the wall** and wait 60 seconds for rails to
discharge.

**Photograph everything before disconnecting anything.** Wide shots plus
close-ups of:

- Every cable at the motherboard end
- Riser cable routing and which riser goes to which GPU
- The front-panel header (power switch, LEDs) — the single most annoying thing
  to get wrong later
- Fan headers
- The Acxico → GPU 6-pin cable runs
- The SATA detection-port cable at each Acxico board

**Label the risers.** Masking tape and a marker: `GPU0`, `GPU1` … `GPU7`,
matching `gpus-OLD.csv`. Keeping the same physical card in the same slot keeps
the GPU indices stable, which keeps your `GPU_FAN_FLOOR` and any per-GPU config
meaningful.

---

## 3. Teardown

Order matters — work from the outside in.

1. **Disconnect all PSU cables** from the motherboard and risers. Leave the
   Acxico boards and PSUs alone if they are not in the way.
2. **Remove the GPUs** from the frame, or leave them hanging and just
   disconnect the risers at the motherboard end. Fewer things moved is fewer
   things broken.
3. **Remove the NVMe drives.** Note which slot each was in. The OS drive is
   going back in the new board — keep it separate and labelled.
4. **Remove RAM.** Note slot positions; photograph. DIMM population order
   matters on Genoa and the new board's manual may differ.
5. **Remove the CPU cooler.** Slow, even pressure. If it is stuck, gentle twist
   rather than pull — thermal paste can suction hard enough to lift a CPU out
   of a closed socket, which on SP5 means bent pins.
6. **Remove the motherboard** from the frame. Count the standoffs and note
   their positions.

### CPU removal from the old board

SP5 force frame uses **Torx T20** captive screws, numbered on the frame.

1. Loosen in **reverse numerical order**: 3 → 2 → 1. A turn or two each, in
   rotation, rather than fully unscrewing one at a time.
2. Lift the force frame, then the rail frame.
3. The CPU stays in its **carrier**. Lift the carrier out by its tabs — never
   touch the gold pads on the underside.
4. Put it in an anti-static tray or the original packaging, pads up.

**Photograph the CPU pads and the empty socket now**, under raking light — a
torch held almost parallel to the surface, so any damage casts a shadow. This
is evidence for the return and a check on your own hypothesis.

---

## 4. New board: inspect before anything goes in

1. **Socket inspection under raking light.** Look across the pin field at a
   shallow angle from several directions. You are looking for bent, flattened
   or missing pins. Photograph it.
2. If you see damage, **stop** — do not install the CPU. A bent pin under load
   can short and take the CPU with it.
3. Check the board for shipping damage, loose components, bent I/O shield.
4. **Test the BMC on standby before full assembly** if you can: connect ATX
   power and the network cable only, and see whether the BMC comes up and gets
   an address. Finding a dead BMC before the build is much better than after.
5. **Firmware.** A BIOS newer than `5411B0030009` exists. Update it now, on the
   bench, before the rig depends on it.

---

## 5. CPU installation — the part that matters

This is the experiment. Everything else is assembly.

**Before you start:** clean hands, no gloves with talc, no touching pads or
pins. Work on a flat surface with good light.

1. Open the rail frame and force frame on the new socket.
2. **Slide the carrier into the rail frame** until it clicks at all corners.
   It only goes one way — the notches align. Do not force it.
3. Lower the rail frame flat onto the socket.
4. Lower the force frame over it.
5. **Tighten the screws in numerical order: 1 → 2 → 3.**

### Torque

**Use the value printed on the socket frame and in the Tyan manual — not a
number from memory.** AMD commonly specifies around **16.1 kgf·cm** for SP5,
but the board's documentation takes precedence and you should verify before
touching a screw.

Use a **torque-limiting driver**, not feel. This is the whole point of the
rebuild: the leading hypothesis is that uneven clamping load left some pins in
one region making marginal contact, and "tight enough" by hand is exactly how
that happens.

Tighten in **stages** — go round 1→2→3 at partial torque, then again at full
torque — rather than driving each screw home in one go. Even load is what you
are buying.

**Photograph the installed CPU with the frame closed**, before the cooler goes
on.

---

## 6. Reassembly

Reverse of teardown, with two additions from the case file:

1. **Ground straps.** 14 AWG with ring terminals, from **each** Acxico board's
   PSU case to the **Corsair's** case, in a star to one common point. Short
   runs. Use shallow shell screws, not ones that go deep into the PSU. This
   addresses lead #1 preventively and costs about $20.
2. **OS on the NVMe as before** — the case file suggests a SATA SSD so DPC
   containment stops being fatal, but that is a bigger change and can wait.
   Keeping the same OS drive preserves `machine_id`.

RAM in the same slots. Risers to the same labelled GPUs. Front-panel header per
your photo.

**Before first power-on:** walk the whole build once looking for a loose screw,
a tool left inside, or a cable in a fan.

---

## 7. First boot

Expect it to take several minutes — Genoa memory training on a first boot with
lots of RAM is slow, and 8 GPUs enumerate slowly. **Do not assume it has hung
until 5+ minutes have passed.**

Watch on the iKVM console, not by ping.

### Set BIOS to match your photos

- Above 4G Decoding **enabled**
- Resizable BAR as before
- IOMMU as before
- Boot order to the OS NVMe

### Then verify, in this order

```bash
# all 8 GPUs, and compare the mapping against the old board
nvidia-smi --query-gpu=index,name,pci.bus_id,uuid,serial --format=csv

# Vast identity intact
cat /var/lib/vastai_kaalia/machine_id

# the comparison that tests the hypothesis
sudo dmesg | grep -ci aer
for d in /sys/bus/pci/devices/*/; do
  [ -f "$d/aer_dev_correctable" ] && echo "$d $(grep TOTAL "$d"/aer_dev_* 2>/dev/null)"
done

# kernel-side faults
sudo journalctl -k -b --no-pager | grep -iE 'Hardware Error|AER|SERR|PERR|Xid'

# BMC side
ipmitool sel elist | tail -30
```

### The number that matters

**Old board baseline: 14 AER errors at the endpoint, ~47 AER lines in dmesg**,
every cold boot.

| New board reading | Interpretation |
|---|---|
| Materially fewer, or zero | The board or the socket work fixed it. Ambiguous which — but good. |
| Same ~14 | **The CPU is indicted.** It is the only major component carried across. |

Record whichever it is in `TROUBLESHOOTING-PCIE-SERR.md`.

---

## 8. Back into service

Only after the machine has been up and stable for a few hours, and the AER
comparison is recorded.

```bash
# re-apply the memory mitigation — swap partition still exists on the same disk
swapon --show                       # expect empty
grep -n swap /etc/fstab             # expect the line still commented
systemctl status earlyoom           # expect active, swap total 0 MiB

vastai show machine 143690 --raw | grep -E '"listed"|"gpu_occupancy"'
vastai list machine 143690 --price_gpu <price>
```

`PRICING_ENABLED=0` is still set in `/etc/gpu_monitor.conf`. Decide
deliberately whether to turn it back on — it was disabled to stop the rental
end-date extending past the swap, and that reason has now expired.

---

## Things that go wrong, and what they mean

| Symptom on first boot | Likely cause |
|---|---|
| No POST, no BMC | PSU not connected, or front-panel header wrong |
| POST but no video | Normal for a headless server — use iKVM |
| Fewer than 8 GPUs | Riser seating, or Above 4G Decoding not enabled |
| GPUs at Gen1 x8 and staying there | Riser or slot seating; check under load before worrying |
| Boots but no network | Check the netplan backup; interface names can change with a new board |
| Won't boot from the NVMe | Boot order, or Secure Boot re-enabled by default |
| Memory training loops | DIMM population order — check the new board's manual, not the old layout |

**If the socket work was the fix, you will not know for certain** — the board
changed too. Only a recurrence indicts the CPU. Record the AER numbers either
way so the next person (or you, in three months) has the comparison.
