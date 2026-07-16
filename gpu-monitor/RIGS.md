# Rig Inventory & Network Reference

Deployment/network reference for the Vast.ai GPU rigs and the combined dashboard.
Keep this current when a rig's IP, hardware, or role changes.

_Last updated: 2026-07-16_

## Rigs

| Rig    | Hostname | LAN IP (enp13s0) | Dash port | Role                         | Notes |
|--------|----------|------------------|-----------|------------------------------|-------|
| Zappa1 | zappa1   | 192.168.1.171    | 8080      | **Hub** (serves combined view) | 2× RTX 5090 |
| Zappa2 | zappa2   | 192.168.1.196    | 8081      | Node                         | 8× RTX 5090 (GPU 5 = MSI, lazy-fan → per-GPU override in its conf); AMD EPYC 9 B14 |
| Zappa3 | zappa3   | 192.168.1.211    | 8082      | Node                         | 8× RTX 5090 |

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

## Config each rig needs (`/etc/gpu_monitor.conf`, chmod 600)

```bash
VASTAI_API_KEY="<account-level Vast.ai API key>"
TELEGRAM_CHAT_ID="<telegram chat id>"
# plus any per-rig GPU_POWER_OVERRIDE / GPU_FAN_FLOOR (see above)
```

Without this file, Vast.ai rental detection, revenue, pricing and Telegram
alerts are all disabled and the rig shows "Free / $0" regardless of actual
rentals.
