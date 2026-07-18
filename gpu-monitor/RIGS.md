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

**Zappa3** — the Ryzen 5 9600X runs hot under load, so it uses the CPU-frequency
throttle (`amd-pstate-epp`, `scaling_max_freq` writable). Its conf must carry:

```bash
CPU_FREQ_HOT_TEMP=80     # cap max CPU freq to 4.5GHz at/above 80°C
CPU_FREQ_COOL_TEMP=60    # only restore full boost once genuinely idle-cool (≤60°C)
```

⚠️ `CPU_FREQ_COOL_TEMP` **must be below the temp a capped CPU runs at under load**
(~67°C at 4.5GHz on this chip). An earlier value of 68 sat *above* that, so every
cycle it restored full boost, spiked to ~89°C, re-capped, and flapped once a
minute. At 60 it caps once and holds ~67°C for the whole workload, lifting only
when the job actually ends. If Zappa3 ever flaps between capped/restored in
`/var/log/gpu_monitor.log`, this is the knob — lower it, don't raise it.

**Zappa3** also carries the profitability power throttle — its RTX 5080s at
full power (360W curve, ~800W wall) can run break-even or at a loss against a
cheap rental once electricity ($0.25/kWh) is counted. Its conf carries:

```bash
PROFIT_THROTTLE_TIERS="5.00:250 7.00:300"
#   rate <  $5.00/day → cap 250W (VBIOS floor)
#   rate <  $7.00/day → cap 300W
#   rate >= $7.00/day → no cap (full 360W curve)
```

This composes with the thermal curve and workload throttle exactly like they
compose with each other (whichever cap is lowest wins), reacts within one
`THERMAL_CHECK_INTERVAL` (~60s) of a rental starting/ending, and needs no
restart to pick up a conf edit — restart `gpu-monitor` after changing the
tiers themselves.

Rate source (updated 2026-07-18): the primary signal is now `/machines/`'s own
live **`earn_hour`/`earn_day`** fields — confirmed directly against the Vast.ai
console (machine 143953, Zappa3) to match the account's real "Avg earnings"
almost exactly (console: $0.19/hr, $3.92/day; our field: $0.1880/hr,
$3.9189/day). This solved the actual root problem: Zappa3's rental is a
D-type background contract, invisible to Vast's `/instances/` API entirely —
the old live-rate signal (`vastai_check()`'s per-instance `dph_total` sum)
simply had no data for it and fell back to the LISTING price (what's
advertised for the *next* rental, e.g. $2.50/hr), wildly different from what
the current one actually pays. `earn_hour`/`earn_day` have no such gap — they
come from `/machines/` itself, which every rig already polls every cycle, so
there's no dependency on `/instances/` visibility at all.

Priority order now: **live `earn_day`** (`_profit_live_earn_rate()`, updates
every cycle) → yesterday's completed `daily_earnings` total
(`_profit_earned_daily_rate()`, ground truth but a day stale) → the old
`/instances/`-based live rate (`_profit_live_daily_rate()`, weakest — blind to
D-type contracts) as a last resort for a rental in its first few hours before
either of the first two have data. See `profit-override status` to inspect
all the signals directly.

The same `/machines/` fields fixed two related things: `fix-active-rental.sh`
and `vastai_init_state()`'s startup backfill both now fall back to
`earn_hour` (rate) + `gpu_occupancy` (rented GPU count) when there's no
`/instances/` match, instead of guessing from the listed price — this is what
produced Zappa3's stale backfilled `$0.140/hr` in the first place. And
`/machines/`'s own **`end_date`** field (confirmed to match the console's
"Contract end" exactly) now replaces the `estimated_expire_date()` guess
(`expire_date_source: "vast_api"` vs `"estimated"` on the `rental_start`
event) whenever Vast actually reports one.

If you ever want to check for other undocumented `/machines/` fields we
aren't using yet, `sudo dump-machine-json` (see below) dumps the full raw
response.

To temporarily force a specific cap (e.g. a renter's workload needs full
power despite a low listed rate, or you want to force savings on a
currently-good rental), use the `profit-override` CLI helper on that rig:

```bash
sudo profit-override 360      # force this wattage regardless of the computed tier
sudo profit-override off      # disable profit throttling — full power (thermal curve still applies)
sudo profit-override status   # show current override + live rental rate
sudo profit-override clear    # remove the override, resume automatic tiering
```

The override is scoped to the **current rental only** — `gpu_monitor.sh`
clears it automatically the instant that rental ends (`rental_end`), so it
never silently carries over and controls a future rental you didn't mean it
to. If you raise Zappa3's price and want the new rental to run unthrottled by
default, you don't need to do anything — once the old rental ends the
override (if any) clears and the next rental starts fresh under the normal
tier logic (which will naturally apply no cap if the new rate is ≥$7/day).

Tune the tiers if reality diverges from the plan: if renters bail or jobs
slow unacceptably at 250W, raise the low tier to 300W in the conf; if the
break-even point moves (electricity rate or actual wall power changes),
adjust the thresholds accordingly.

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

### Unnamed-miner heuristic fallback

`classify_workload()` only recognizes a fixed list of known miner/cracker
binary names (`srbminer`, `xmrig`, `nbminer`, `t-rex`, `phoenixminer`,
`lolminer`, `gminer`, `teamredminer`, `matador`, `hashcat`, ...) — we missed
`matador-miner` on Zappa1 until it was seen live and added (2026-07-18). Any
future miner running under a name not on that list would bypass the throttle
the same way, so there's now a behavioral fallback for exactly that case.

If the running process classifies as `unknown` and, for **30 minutes
straight**, every active GPU shows **≥95% compute utilization, ~0% NVENC/NVDEC
use, and no VRAM growth** (miners settle into a fixed working set and never
touch the video engines — a training/inference job doesn't typically hold
that exact combination that long), it's treated the same as a named
mining/cracking match: same `WORKLOAD_THROTTLE_WATTS` cap, same auto-lift the
instant the workload or rental changes — plus a one-time Telegram alert,
since (unlike a named match) this is an inference worth a human glance, not a
certainty. **Any** disqualifying sample (utilization dips, encode/decode
activity, VRAM growth) resets the 30-minute counter to zero — deliberately
strict, to keep false positives on legitimate heavy-compute rentals rare.

```bash
MINING_HEURISTIC=1                       # default on; set 0 in a rig's conf to disable
MINING_HEURISTIC_MIN_UTIL=95             # % GPU compute utilization
MINING_HEURISTIC_MAX_ENCDEC=2            # % — ceiling on NVENC/NVDEC use
MINING_HEURISTIC_MAX_MEM_GROWTH_MIB=256  # vs. the previous ~60s sample
MINING_HEURISTIC_SUSTAIN_SECONDS=1800    # 30 min
```

This is a heuristic, not a certainty — a sustained, video-engine-idle,
memory-flat 95%+ compute job is *usually* mining, but check `nvidia-smi` /
the Telegram alert if you want to confirm, and use `profit-override` to force
full power back if it's a false positive.

## Config each rig needs (`/etc/gpu_monitor.conf`, chmod 600)

```bash
VASTAI_API_KEY="<account-level Vast.ai API key>"
TELEGRAM_CHAT_ID="<telegram chat id>"
# LLM_PROVIDER="openai"     # optional — this is the default. Or "anthropic".
OPENAI_API_KEY="<optional — enables the dashboard chat assistant, hub only>"
# plus any per-rig GPU_POWER_OVERRIDE / GPU_FAN_FLOOR (see above)
```

Without this file, Vast.ai rental detection, revenue, pricing and Telegram
alerts are all disabled and the rig shows "Free / $0" regardless of actual
rentals.

## Rig Assistant chat backend (hub only, read-only, swappable LLM provider)

The combined dashboard's chat panel ("Rig Assistant") can answer from the
loaded stats digest alone (no API key — this is the default, fully local and
private), or, if an LLM provider is configured in the **hub's** (Zappa1)
`/etc/gpu_monitor.conf`, it's backed by that provider with **read-only** tool
access to live GPU status, CPU load/temp, network status, and kaalia-log
search on any named rig.

**The provider is a config switch, not a code change.** `dashboard/assistant.py`
defines an `LLMProvider` interface (`complete(system_prompt, turns, tools)`)
that the tool-use loop (`run_chat()`) drives entirely in provider-agnostic
terms — a small list of `{role, text?, tool_calls?}` turns. Each provider
subclass is only responsible for translating that to and from its own wire
format (message shape, tool-call schema, SDK client). Two are built in:

| `LLM_PROVIDER` | Key needed | Default model | Notes |
|---|---|---|---|
| `openai` (default) | `OPENAI_API_KEY` | `gpt-4o-mini` (override: `OPENAI_MODEL`) | Largest complimentary daily token allowance (10M/day on gpt-4o-mini) under OpenAI's data-sharing free-tokens program — see below. |
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-haiku-4-5` (override: `ANTHROPIC_MODEL`) | Cheapest/fastest Claude tier; ~$5 one-time trial credit for new accounts, no ongoing free tier. |

To switch providers on the hub: set `LLM_PROVIDER="anthropic"` (or back to
`"openai"`) plus that provider's own `<PROVIDER>_API_KEY` in
`/etc/gpu_monitor.conf`, `pip3 install anthropic` (or `openai`) if not
already present — `install.sh` does this automatically based on whatever
`LLM_PROVIDER` your conf currently has — then `sudo systemctl restart
gpu-dashboard`. No HTML/JS changes, no changes to the tool set. Adding a
*third* provider later means implementing one `LLMProvider` subclass and
adding it to `PROVIDERS` in `assistant.py` — `run_chat()`, the tools, and the
frontend don't change.

To use OpenAI's free daily tokens instead of paying per-token: enable data
sharing at platform.openai.com/settings/organization/data-controls/sharing
(org owner only). That grants up to 10M tokens/day free on `gpt-4o-mini`,
but means your prompts/tool outputs (rig stats, log lines) may be used for
OpenAI's training — fine for this use case (no secrets in the digest or
diagnostics) but worth knowing. You still need a positive account balance to
use the API at all, sharing or not — this is an account-level toggle, not
something the code here configures.

Architecture (why it's safe to run on a dashboard that has no login):

- The active provider's API key is read server-side only, straight out of
  `/etc/gpu_monitor.conf` (`dashboard/assistant.py`, `_conf_value()` — a plain
  regex read, the file is never `source`d by Python). It never reaches the
  browser; the frontend only ever calls this server's own `POST /api/chat`.
- Every tool is a **fixed, dedicated read function** — `nvidia-smi` with a
  fixed argument list, `/proc/loadavg` + hwmon reads, `ip -brief addr` + a
  ping to a hardcoded target, and kaalia-log search done with Python's `re`
  module directly (never a shelled-out `grep`). There is no raw/bash tool
  exposed to the model, so there's no command-injection surface regardless of
  what the model or a user types — and this holds for any provider, since the
  tool set is defined once, outside any provider class.
- No tool can write, restart, reconfigure, or change price/power on any rig —
  everything is a query. The system prompt also tells the model to say so if
  asked to change something.
- To answer about a rig other than the hub itself, the hub's `/api/chat`
  handler calls that peer's own `GET /api/diag/<gpu|cpu|network|kaalia>` —
  the same server-side proxy pattern `/api/peer` already uses for `/api/data`.
  Every rig serves its own `/api/diag/*` for itself; only the hub needs an LLM
  API key since only the hub's dashboard has the chat panel.
- `/api/chat` and `/api/diag/*` have no auth (matching every other endpoint
  on this dashboard), so `/api/chat` is rate-limited server-side (20
  requests/hour/IP, 100/hour total) since — unlike the other endpoints — it
  costs real money (or free-tier tokens) per call.

Nothing to do on the node rigs (Zappa2/Zappa3) besides the normal `install.sh`
run — they automatically pick up `/api/diag/*` and will serve it if the hub's
assistant asks about them. Only the hub needs the provider key.

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
