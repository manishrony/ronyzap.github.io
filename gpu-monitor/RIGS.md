# Rig Inventory & Network Reference

Deployment/network reference for the Vast.ai GPU rigs and the combined dashboard.
Keep this current when a rig's IP, hardware, or role changes.

_Last updated: 2026-07-16_

## Rigs

| Rig    | Hostname | LAN IP (enp13s0) | Dash port | Role                         | Notes |
|--------|----------|------------------|-----------|------------------------------|-------|
| Zappa1 | zappa1   | 192.168.1.171    | 8080      | **Hub** (serves combined view) | 2× RTX 5090 |
| Zappa2 | zappa2   | 192.168.1.196    | 8081      | Node                         | 8× RTX 5090 (GPU 5 = MSI, lazy-fan → per-GPU override in its conf); AMD EPYC 9 B14 |
| Zappa3 | zappa3   | 192.168.1.211    | 8082      | Node                         | RTX 5080 (300W curve, 275W@80°C; conf sets WORKLOAD_THROTTLE_WATTS=250 → cracking/mining throttle to 250W) |

> ⚠️ These are **DHCP** addresses and have drifted before (Zappa3 moved
> 192.168.1.150 → .211 on 2026-07-16, which broke the hub's peer link). Set a
> **DHCP reservation / static lease** for each rig's MAC in the router so the
> peer URLs never go stale. Get each rig's MAC with: `ip link show enp13s0`
> (the `link/ether` line).

## Combined dashboard (hub = Zappa1)

Zappa1 proxies the other rigs server-side via `PEER_URLS`. Re-run install on
Zappa1 whenever a peer IP changes:

```bash
# on Zappa1, from its repo clone:
sudo bash gpu-monitor/install.sh 8080 \
  "http://192.168.1.196:8081,http://192.168.1.211:8082" \
  "Zappa2,Zappa3" "Zappa1"
```

- Combined view: http://192.168.1.171:8080/combined
- A **red** rig pill on the dashboard = the hub can't reach that peer
  (peer's IP moved, or its `gpu-dashboard` service is down) — it is NOT a data
  bug. Check `hostname -I` on the peer and the peer URL above.

## Per-node install (no peers)

```bash
# on a node, from its repo clone (branch: claude/gpu-rig-power-management-yo6oxs):
git fetch origin claude/gpu-rig-power-management-yo6oxs
git checkout -B claude/gpu-rig-power-management-yo6oxs origin/claude/gpu-rig-power-management-yo6oxs
sudo bash gpu-monitor/install.sh <port>     # Zappa2=8081, Zappa3=8082
```

## Per-rig tuning (in each rig's /etc/gpu_monitor.conf — NOT in the shared script)

Rig-specific overrides live in `/etc/gpu_monitor.conf` (root-only, sourced at
startup). The shared `gpu_monitor.sh` defaults to none.

**Zappa2** — GPU 5 is a lazy-fan MSI board; it runs ~5 °C hotter than its
siblings and its VBIOS won't spin the fan up. Its conf carries:

```bash
GPU_POWER_OVERRIDE=("5:500:78@450:80@400")   # GPU 5 only: 450W@78°C, 400W@80°C
GPU_FAN_FLOOR=("5:80")                        # hold GPU 5 fan >=80% (needs X+Coolbits)
```

Note: fan control needs an X server with Coolbits, which the headless rigs
don't have — so on Zappa2 the fan floor is inert and GPU 5 relies on the 400W
power floor (safe, ~10% hashrate trim only when ≥80 °C). The other rigs have no
override (their GPU 5 is a normal card).

## Workload throttle (global default, all rigs)

Low-value rentals get capped without kicking the renter: when a running GPU
workload classifies as **cracking** (hashcat/john) or **mining**, every GPU is
capped to **400W**; the cap lifts automatically when the rental flips to
anything else or ends. Defaults live in `gpu_monitor.sh`:

```bash
WORKLOAD_THROTTLE_WATTS=400
WORKLOAD_THROTTLE_TYPES="cracking mining"
```

- Only affects cards whose curve exceeds 400W — i.e. the **RTX 5090s**
  (Zappa1/Zappa2). **Zappa3's RTX 5080s are unaffected** (300W curve is already
  below 400W).
- Override per rig in `/etc/gpu_monitor.conf`: `WORKLOAD_THROTTLE_WATTS=0` to
  disable, or change the watts / type list.
- **Zappa3 (RTX 5080)** carries `WORKLOAD_THROTTLE_WATTS=250` in its conf, so its
  cracking/mining rentals throttle to 250W — below the 5080's normal 300 / 275°C
  curve. Non-cracking/mining rentals run the normal curve.

## Config each rig needs (`/etc/gpu_monitor.conf`, chmod 600)

```bash
VASTAI_API_KEY="<account-level Vast.ai API key>"
TELEGRAM_CHAT_ID="<telegram chat id>"
# plus any per-rig GPU_POWER_OVERRIDE / GPU_FAN_FLOOR (see above)
```

Without this file, Vast.ai rental detection, revenue, pricing and Telegram
alerts are all disabled and the rig shows "Free / $0" regardless of actual
rentals.

## APC PDU power metering (hub only)

The rack's APC Metered PDU (AP7811B) is read over SNMP to show real power draw,
energy (kWh) and electricity cost on the dashboard, plus **net profit** (combined
rental revenue − power cost) on the combined view.

**Configure it on ONE rig only — the hub (Zappa1).** The PDU meters the whole
rack, so if every rig polled it the energy would be counted 2–3×. The poller is
built into `gpu_monitor.sh` and no-ops silently unless `PDU_HOSTS` is set, so
it's safe that the same script ships everywhere.

Add to **Zappa1's** `/etc/gpu_monitor.conf`:

```bash
PDU_HOSTS="192.168.1.<pdu-ip>"   # one or more PDU IPs, space/comma separated
PDU_SNMP_COMMUNITY="zappa1"      # SNMPv1 read community (NOT the default "public")
PDU_VOLTAGE=240                  # line voltage for the amps→watts conversion
PDU_ENERGY_RATE=0.25             # $/kWh blended rate
PDU_KWH_BASELINE=0               # optional: kWh already consumed before metering began
```

Then `apt install snmp` (for `snmpwalk`) and `sudo systemctl restart gpu-monitor`.

Why derived, not read directly: the AP7811B exposes **only load current** over
SNMP — its power (W) and cumulative-kWh registers return `notsupported`. The
monitor snmpwalks the phase-current column (`.1.3.6.1.4.1.318.1.1.26.6.3.1.5`,
tenths of an amp), sums all rows (handles 1- or 3-phase), multiplies by
`PDU_VOLTAGE`, and integrates over time into cumulative kWh. Because energy is
accumulated only while the monitor runs, seed `PDU_KWH_BASELINE` with any
pre-existing consumption if you want the lifetime figure to include it.

Check it from the terminal with `sudo pdu-power` (live watts + today + lifetime)
or `sudo pdu-power YYYY-MM-DD` for a past day. If SNMP can't be reached the
monitor logs one clear warning and keeps running; the dashboard power row simply
stays hidden until samples arrive.
