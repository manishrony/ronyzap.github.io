# Session Handoff — Vast.ai Rig Fleet (zappa1/zappa2/zappa3)

_Written 2026-08-05 to bootstrap a fresh session after a long working session on `manishrony/ronyzap.github.io`, `gpu-monitor/` subtree, branch `main`._

## Repo / deploy basics

- Repo: `manishrony/ronyzap.github.io`, all work lives under `gpu-monitor/`.
- Branch: everything is merged straight to `main` now — no long-lived feature branch in use.
- Standard deploy on any rig:
  ```bash
  cd <clone path>   # find with: find / -maxdepth 4 -iname "gpu_monitor.sh" 2>/dev/null
  git pull
  sudo bash gpu-monitor/install.sh <port> [peer_urls] [peer_names] [self_name] [power_limit]
  ```
  `install.sh` is idempotent — safe to re-run any time to pick up new files/units. It copies dashboard `*.py`/`*.html` by **glob** now (not a hand-maintained list — that was a real bug, see below) and always deploys `cloudline/client.py` alongside it.
- Quick single-file redeploys during iteration were done via `sudo cp gpu-monitor/<file> <target>` + `sudo systemctl restart <service>` — fine for hotfixes, but always confirm `install.sh` itself covers the file so future fresh installs don't regress.

## Rig inventory (confirmed live this session — RIGS.md may be stale)

| Rig | Hostname | LAN IP | Dash port | Role | GPUs |
|---|---|---|---|---|---|
| Zappa1 | zappa1 | 192.168.1.171 | 8080 | **Hub** (combined dashboard, Prometheus, Cloudline controller) | 2x RTX 5090 |
| Zappa2 | zappa2 | 192.168.1.196 | 8081 | Node | 8x RTX 5090 |
| Zappa3 | zappa3 | 192.168.1.211 | 8082 | Node | 1x RTX 5090 — **RIGS.md says RTX 5080, that's wrong/stale, hardware is actually a 5090** |

zappa3 was a **from-scratch OS reinstall** (Ubuntu 26.04, vs 24.04 on zappa1/zappa2) as of this session — no prior clone, no `/etc/gpu_monitor.conf`, nothing in `/opt/gpu-monitor`. Fully redeployed from `main` during this session; see "zappa3 status" below for what's still unconfirmed.

Hub proxying: zappa1 runs with `PEER_URLS` set (see its `install.sh` invocation), which makes `/` and `/index.html` **302-redirect to `/combined`** — if you're debugging "zappa1's own dashboard," remember requests actually get served by `combined.html`'s per-rig drilldown, which has its **own separate copy** of several JS functions (`computeRevenue`, hourly chart, etc.) — bugs fixed in `index.html` do NOT automatically apply to `combined.html` and vice versa. This bit us multiple times this session.

## Per-rig `/etc/gpu_monitor.conf` state

**zappa1** (occupancy-first pricing strategy, explicitly requested by user):
```
RATCHET_UP_WHILE_FULL=0
RATCHET_UP_WHILE_VACANT=0
WORKLOAD_THROTTLE_LIMITS=("5090:500")
```
Also has Cloudline `.env` at `/opt/gpu-monitor/cloudline/.env`:
```
CLOUDLINE_TAPO_HOST=192.168.1.245
CLOUDLINE_TAPO_EMAIL=...
CLOUDLINE_TAPO_PASSWORD=...
CLOUDLINE_TAPO_RIG_NAME=basement-cooling
CLOUDLINE_TAPO_RATE=0.2517
```
Plus replication config in `/etc/gpu_monitor.conf`:
```
REPLICATE_TARGET_HOST=192.168.1.196
REPLICATE_TARGET_USER=ronyzap
REPLICATE_SSH_KEY=/root/.ssh/id_ed25519_replicate
REPLICATE_TARGET_PATH=/home/ronyzap/gpu-monitor-replica/zappa1
```

**zappa2**:
```
WORKLOAD_THROTTLE_LIMITS=("5090:400")
REPLICATE_TARGET_HOST=192.168.1.171
REPLICATE_TARGET_USER=ronyzap
REPLICATE_SSH_KEY=/root/.ssh/id_ed25519_replicate
REPLICATE_TARGET_PATH=/home/ronyzap/gpu-monitor-replica/zappa2
```

**zappa3** — **INCOMPLETE, needs follow-up**:
- `VASTAI_API_KEY`, `TELEGRAM_CHAT_ID`, `TELEGRAM_TOKEN` were provided as placeholder instructions ("same as zappa1/zappa2") — **never confirmed the user actually filled in real values**. Verify this first in a new session:
  ```bash
  sudo cat /etc/gpu_monitor.conf   # on zappa3
  ```
- `WORKLOAD_THROTTLE_LIMITS=("5090:500")` was requested (user chose "match zappa1") — confirm it's actually in the file.
- Cross-rig replication was never set up for zappa3 (no REPLICATE_TARGET_HOST added yet) — optional follow-up if user wants 3-way redundancy.
- **Dashboard was crash-looping** on zappa3 (see bugs below) — last action was restarting `gpu-dashboard` after the `cloudline/client.py` fix; the final `curl -sv http://localhost:8082/` verification was **requested but not yet confirmed working** when this summary was written. First thing to check in a new session.

## Repo-level bugs found + fixed this session (all pushed to `main`)

1. **Vast.ai pricing engine — `RATCHET_UP_WHILE_FULL`/`RATCHET_UP_WHILE_VACANT` not holding.** Per-branch `elif` guards matched their own conditions but still let price ratchet up (root cause never fully explained even after `[TRACE]` logging). Fixed with a **branch-independent safety clamp** placed right before `vastai_set_price()`: if `fully_vacant`/`fully_rented` and the corresponding flag is `0`, cap `new_price` at `cur_bid` unconditionally, regardless of which branch computed the higher value. Confirmed working live over multiple days (zappa1 held `$0.32` flat for 8+ cycles while `target` climbed to `$0.41-0.44`).

2. **`rental_start` events losing `real_instance_id` and logging `$0.000/hr`.** At the exact moment of a `rented=false→true` transition, `/instances/` often hadn't indexed the new instance yet. Fixed with: (a) one retry against `/instances/` after an 8s delay before giving up, (b) a fixed bug where the `earn_day` field was being silently discarded into `_` during bash line-parsing so a later fallback couldn't use it, (c) `earn_day/24` as a last-resort rate estimate so a genuinely-rented session is never recorded as literally free. This was framed as a **legal/recordkeeping requirement** (attribution evidence if a renter's traffic is ever the subject of an abuse report), not just cosmetic.

3. **Dashboard: full-day revenue smeared into every hourly bar.** `computeRevenue()`'s `daily_earnings` day-level total was being replayed into every 1-hour bucket query (the overlap check only tested whether the day intersected the window at all, not how much). Fixed with a `skipDailyEarnings` option, passed by the hourly-chart callers so they fall back to real per-session revenue only. **Had to be fixed twice** — once in `index.html`, then discovered `combined.html` has its own separate copy of the same logic and needed the identical fix.

4. **Dashboard: month/day labels off by one period in non-UTC browsers.** `today()`/`daysAgo()`/`monthRange()` build UTC-midnight-anchored `Date` objects, but labels were formatted via `toLocaleDateString()` **without `timeZone: "UTC"`**, so the browser silently converted to local time before formatting — shifting month labels back by a full month in any browser west of UTC. Confirmed live: dashboard labeled July's real $440.75 total as "June 2026". Fixed by adding `timeZone:"UTC"` to every period-label `toLocaleDateString()` call in both `index.html` and `combined.html` (NOT the `fmtDate()` helper, which formats real event timestamps and is correctly local-time).

5. **`combined.html`'s per-rig Daily hourly chart: local/UTC mismatch, separate bug from #3/#4.** `hStart.setHours(h,0,0,0)` mutates in the browser's local timezone even though `today()` returns a UTC date — caused erratic gaps in the hourly bar chart (not a clean shift like #4, genuine misalignment). Fixed with `setUTCHours`. This was the ONE remaining `setHours`-on-a-UTC-date instance in either dashboard file (confirmed via grep after the fix).

6. **Monthly tab UX**: changed to default straight to "week-by-week for the current month" (mirroring how the Yearly tab already defaults to "month-by-month for the current year") instead of opening on an all-time month-by-month chart that buries the current month. Applied to both `index.html` and `combined.html`.

7. **Cloudline scheduler: a flaky AC Infinity fan-control API call was silently blocking power polling.** `client.set_speed()` throwing (confirmed: `addDevMode -> 100001` errors, pre-existing/unrelated to our changes) was in the same `try` block as `poll_power()`, so **every single cycle that failed to set a fan speed also skipped the Tapo power poll entirely** — for 40+ minutes straight in one observed case. Fixed by decoupling: fan-control errors and power-poll errors now caught independently, so one failing doesn't block the other.

8. **`install.sh` dashboard file list had silently drifted from the repo.** Explicit `cp` list didn't include `cooling_api.py` or `outdoor_weather_api.py`, which existed in the repo but were never added to the list. zappa1/zappa2 never noticed because those files had been deployed before/outside the list at some earlier point; a genuinely fresh install (zappa3) crash-looped on `ModuleNotFoundError: No module named 'cooling_api'`. Fixed by globbing `*.py`/`*.html` instead of a hand list.

9. **`cooling_api.py` unconditionally imports `cloudline/client.py`** (`sys.path.insert` + `from client import ...`) even on rigs with no physical Cloudline controller — the "disabled unless `AC_INFINITY_EMAIL`/`PASSWORD` are set" check happens AFTER the import, not before. `install.sh` previously only ever deployed `cloudline/` on the hub via a separate manual `cloudline/deploy/deploy.sh` step. Fixed: `install.sh` now always copies `cloudline/client.py` (not the rest of the Cloudline stack — `scheduler.py`/`deploy/` stay hub-only) to `/opt/gpu-monitor/cloudline/` on every rig.

10. **Local JSONL backups auto-deleted after 14 days** (`gpu-backup.timer` → `backup-jsonl.sh`) — changed default `BACKUP_RETENTION_DAYS` from `14` to `0` (keep forever), per explicit user request ("keep as long as we can") tied to the recordkeeping concern in #2. Old backups are never pruned unless a rig explicitly sets a positive `BACKUP_RETENTION_DAYS`.

## New feature this session: cross-rig JSONL replication

- New script `gpu-monitor/replicate-jsonl.sh` + systemd `gpu-replicate.service`/`.timer` (daily, 23:50 UTC). Rsyncs the live JSONL (and local gzip backups) to a peer rig over SSH.
- Opt-in via `/etc/gpu_monitor.conf`: `REPLICATE_TARGET_HOST`, `REPLICATE_TARGET_USER` (default current user), `REPLICATE_SSH_KEY`, `REPLICATE_TARGET_PATH` (default `/var/backups/gpu-monitor-replica/<hostname>` — **note**: this default path needs root write access under `/var/backups`, which a non-root SSH user typically lacks; we ended up overriding to `/home/ronyzap/gpu-monitor-replica/<source-rig>` on both zappa1 and zappa2 to avoid a permissions failure).
- **zappa1 ⇄ zappa2 bidirectional replication is live and confirmed working** (manual `sudo replicate-jsonl` succeeded both directions).
- zappa3 not yet wired into replication (optional follow-up).
- SSH key setup pattern used: `sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_replicate -N ""` then `sudo ssh-copy-id -i .../id_ed25519_replicate.pub ronyzap@<peer-ip>` (runs as root, targets the peer's normal `ronyzap` user, not peer's root).

## Tapo / power metering notes

- The Tapo smart plug (`tapo-poll.py`) was physically relocated from metering zappa3 alone to a shared basement circuit covering zappa1+zappa2 — now tagged `basement-cooling` via `CLOUDLINE_TAPO_RIG_NAME`, polled by the **Cloudline scheduler** (zappa1 only), not `gpu_monitor.sh`'s own `tapo_poll()`.
- `combined.html`'s `renderPower()` already sums `pdu_power` events across all distinct `host` tags automatically — no dashboard code changes were needed for the relocation, just the Cloudline `.env` config.
- Hit and fixed, in order: missing `tapo-poll.py` at the expected deploy path; missing `python-kasa` (`pip3 install --break-system-packages python-kasa`); `DynamicUser=yes` sandboxing on `cloudline-scheduler.service` blocking file writes (needed `systemctl edit` override with `ReadWritePaths=/var/log /var/tmp`); underlying Unix permission denial even after that (`/var/log/gpu_monitor_data.jsonl` was `644` root-owned — fixed with `chmod 666`, flagged as a "good enough for now" fix, not the cleanest — a dedicated non-`DynamicUser` service account would be the proper fix if revisited).
- The recurring `addDevMode -> 100001` AC Infinity API errors in the Cloudline scheduler logs are **pre-existing and unrelated** — never diagnosed further, just confirmed they don't block power metering anymore (bug #7 above).

## Known residual / open items for a new session

1. **Confirm zappa3's dashboard is actually stable** — last status check was mid-fix; re-verify `systemctl status gpu-dashboard` and `curl http://localhost:8082/` both succeed, then check the hub's rig-status pill at `http://192.168.1.171:8080/combined` turns green for zappa3.
2. **Confirm zappa3's `/etc/gpu_monitor.conf` has real (not placeholder) `VASTAI_API_KEY`/`TELEGRAM_CHAT_ID`/`TELEGRAM_TOKEN` values.**
3. Optional: wire zappa3 into cross-rig replication (pick a target, same pattern as zappa1⇄zappa2).
4. Never resolved: a residual bug where some `rental_start` events could still log `$0.000/hr` even after fix #2, observed once in an earlier diagnostic — not reproduced/re-investigated since; flag if it recurs.
5. RIGS.md's rig table still says zappa3 = RTX 5080 — worth a doc correction if this session's "actually a 5090" info is confirmed durable (not a temporary hardware swap).
6. The user separately asked about hosting-abuse/liability risk for a `hashcat.bin` cracking workload seen on zappa2 — answered as a policy/liability discussion (not code), recommending network isolation, IP separation, and evidence retention (which fix #2 and #10 above directly support). No code follow-up pending there.

## Where to look for more detail

- `gpu-monitor/RIGS.md` — deployment/network reference (partially stale, see above).
- `gpu-monitor/install.sh` — the deploy script, now fixed per items #8/#9.
- `gpu-monitor/gpu_monitor.sh` — the pricing/power engine, `vastai_pricing()` and `vastai_check()` are the two functions most touched this session.
- `gpu-monitor/dashboard/{index.html,combined.html}` — remember these have **separate, duplicated** JS for revenue/chart logic; check both when fixing a dashboard bug.
- `gpu-monitor/cloudline/` — Cloudline fan + Tapo power integration, hub-only except for the newly-required `client.py`.
- `gpu-monitor/backup-jsonl.sh`, `gpu-monitor/replicate-jsonl.sh` — backup/replication, both new/changed this session.
