#!/usr/bin/env python3
"""Prometheus text-exposition exporter for this rig's current state.

Reads the same JSONL event log + vastai state file the dashboard already
reads, and renders them as Prometheus gauges. This is a plain "current
value" snapshot exporter — the time dimension comes from Prometheus itself
re-scraping this endpoint every SCRAPE_INTERVAL, not from anything in here.
Historical data from before Prometheus existed is backfilled separately by
backfill-prometheus.py, which reads the same files but emits OpenMetrics
samples with real historical timestamps instead.
"""
import json
import os
import re
import socket
from pathlib import Path

import cooling_api

_RATE_RE = re.compile(r'[-+]?\d*\.?\d+')
_CONF_FILE = "/etc/gpu_monitor.conf"
# Cloudline controllers meter a physical space shared by more than one rig
# (T6/S6 cover zappa1+zappa2's basement) — tagging room/fan metrics with the
# polling host's `rig` label would wrongly imply the reading is zappa1-only.
# CLOUDLINE_LOCATION lets that be corrected per-deployment; same env-var
# naming convention as CLOUDLINE_TAPO_RIG_NAME in cloudline/scheduler.py.
CLOUDLINE_LOCATION = os.environ.get("CLOUDLINE_LOCATION", "basement")


def _read_energy_rate():
    """PDU_ENERGY_RATE ($/kWh) from /etc/gpu_monitor.conf — same default
    (0.25) as gpu_monitor.sh itself uses when the conf doesn't set one."""
    try:
        content = Path(_CONF_FILE).read_text(errors="replace")
    except FileNotFoundError:
        return 0.25
    m = re.search(r'^PDU_ENERGY_RATE=["\']?([\d.]+)', content, re.MULTILINE)
    return float(m.group(1)) if m else 0.25


def _to_float(s, default=0.0):
    if s is None:
        return default
    if isinstance(s, (int, float)):
        return float(s)
    m = _RATE_RE.search(str(s))
    return float(m.group()) if m else default


def _esc(v):
    return str(v).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


def _fmt_labels(labels):
    parts = [f'{k}="{_esc(v)}"' for k, v in labels.items()]
    return "{" + ",".join(parts) + "}"


class MetricSet:
    """Accumulates (help, type, samples) so render() can emit valid
    Prometheus text exposition format (HELP/TYPE once per metric name,
    grouped samples)."""

    def __init__(self):
        self._order = []
        self._meta = {}
        self._samples = {}

    def add(self, name, mtype, help_text, labels, value):
        if name not in self._meta:
            self._meta[name] = (mtype, help_text)
            self._samples[name] = []
            self._order.append(name)
        self._samples[name].append((labels, value))

    def render(self):
        lines = []
        for name in self._order:
            mtype, help_text = self._meta[name]
            lines.append(f"# HELP {name} {help_text}")
            lines.append(f"# TYPE {name} {mtype}")
            for labels, value in self._samples[name]:
                lines.append(f"{name}{_fmt_labels(labels)} {value}")
        return "\n".join(lines) + "\n"


def _read_jsonl(path):
    p = Path(path)
    if not p.exists():
        return
    with p.open(errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except Exception:
                continue


def _parse_state_file(path):
    """vastai_check()'s state file: mid|rented|gpus|cost|real_iid|rented_count|earn_day|end_epoch"""
    out = {}
    p = Path(path)
    if not p.exists():
        return out
    for line in p.read_text(errors="replace").splitlines():
        fields = line.split("|")
        if len(fields) < 8:
            continue
        mid, rented, gpus, cost, real_iid, rented_count, earn_day, end_epoch = fields[:8]
        out[mid] = {
            "rented": rented == "True",
            "gpus": gpus,
            "cost": _to_float(cost),
            "rented_count": _to_float(rented_count, 0),
            "earn_day": _to_float(earn_day, 0),
            "end_epoch": _to_float(end_epoch, 0),
        }
    return out


def render_metrics(data_file, state_file):
    # Always label by hostname, never by a display name (SELF_NAME) — the
    # hub's install.sh call passes a capitalized SELF_NAME ("Zappa1") for UI
    # display, but backfill-prometheus.py labels by whatever --rig string the
    # operator typed (conventionally the lowercase hostname). Labeling by
    # SELF_NAME here would split one rig's live and backfilled history into
    # two different `rig` values in Prometheus — confirmed happening on
    # Zappa1 (2026-07-19): "Zappa1" (live) vs. "zappa1" (backfilled) as
    # separate, non-matching series.
    rig = socket.gethostname()
    m = MetricSet()

    # --- Latest gpu_status snapshot (per-GPU temp/power/fan/util/proc) ---
    latest_gpu_status = None
    # --- Latest gpu_rental_status per machine (per-GPU-slot rented/rate) ---
    latest_rental_status = {}
    # --- Latest market_snapshot per machine ---
    latest_market = {}
    # --- Latest price_change per machine (target/floor/listing price) ---
    latest_price = {}
    # --- Latest daily_earnings PER DATE (not a single global latest) ---
    # A single global "latest by ts" pointer looked right but silently broke
    # yesterday's own figure every single day: vastai_sync_earnings() always
    # refreshes the last 3 days each cycle (so a still-settling "yesterday"
    # keeps climbing toward its true total for ~an hour past midnight — Vast's
    # own daily totals aren't finalized at day-end), but it ALSO writes
    # today's first (tiny, partial) entry in that same cycle. Once today's ts
    # became the new global max, this stopped exposing ANY value for
    # yesterday's date at all -- Prometheus never got scraped with yesterday's
    # later, correct updates, so its last recorded sample stayed frozen at
    # whatever total existed the moment before the switchover. Confirmed live
    # 2026-07-21: dashboard showed zappa1/zappa2/zappa3's PREVIOUS day revenue
    # frozen at ~23:00 UTC values ($10.34/$74.18/$4.23) while the JSONL (and
    # Vast's own API, queried directly with the same UTC day window) already
    # had the true settled totals ($11.27/$78.62/$4.49) from an hour later.
    latest_earnings_by_date = {}
    # --- Latest rental_start per machine (for rental_instance_info below) ---
    # Only ever read from the JSONL, never exposed as a Prometheus metric --
    # real_instance_id/image/workload_type had no historical record in
    # Prometheus/Grafana at all, only in this rig's local JSONL file. Track
    # the last rental_start per machine here; render_metrics only emits it
    # while `state` (this scrape's live /machines/ snapshot) says the
    # machine is CURRENTLY rented, so a rental that already ended doesn't
    # keep reporting a stale container as if it were still active.
    latest_rental_start = {}
    # --- Latest pdu_power per rig (real APC PDU / Tapo meter reading) ---
    # Never exposed to Prometheus before -- profit_api.py's electricity cost
    # was always GPU-power-draw-only (chip power, not full system draw) even
    # on rigs with a real meter, since this data simply didn't exist in the
    # database it queries. Confirmed live 2026-08-14: dashboard's "Previous
    # Day Summary" electricity ($19.79) vs. real metered wall power for the
    # same day, off by a wide margin.
    latest_pdu_power = None

    for ev in _read_jsonl(data_file):
        t = ev.get("type")
        if t == "pdu_power":
            latest_pdu_power = ev
        elif t == "gpu_status":
            latest_gpu_status = ev
        elif t == "gpu_rental_status":
            mid = str(ev.get("machine_id", ""))
            if mid:
                latest_rental_status[mid] = ev
        elif t == "market_snapshot":
            mid = str(ev.get("machine_id", ""))
            if mid:
                latest_market[mid] = ev
        elif t == "price_change":
            mid = str(ev.get("machine_id", ""))
            if mid:
                latest_price[mid] = ev
        elif t == "rental_start":
            mid = str(ev.get("machine_id", ""))
            if mid:
                latest_rental_start[mid] = ev
        elif t == "daily_earnings" and ev.get("source") == "vast_api":
            d = ev.get("date")
            ts = ev.get("ts", "")
            if d and ts >= latest_earnings_by_date.get(d, {}).get("ts", ""):
                latest_earnings_by_date[d] = ev

    if latest_gpu_status:
        for g in latest_gpu_status.get("gpus", []):
            labels = {"rig": rig, "gpu_idx": g.get("idx"), "gpu_name": g.get("name", "")}
            m.add("gpu_temp_celsius", "gauge", "Current GPU core temperature.", labels, _to_float(g.get("temp")))
            m.add("gpu_power_draw_watts", "gauge", "Current GPU power draw.", labels, _to_float(g.get("power_draw")))
            m.add("gpu_power_limit_watts", "gauge", "Current GPU power cap.", labels, _to_float(g.get("power_limit")))
            m.add("gpu_fan_percent", "gauge", "Current GPU fan speed.", labels, _to_float(g.get("fan")))
            m.add("gpu_util_percent", "gauge", "Current GPU compute utilization.", labels, _to_float(g.get("util")))
            proc_labels = dict(labels)
            proc_labels["proc"] = g.get("proc") or "idle"
            m.add("gpu_process_info", "gauge", "1 if this process is the current occupant of this GPU (label carries the name).", proc_labels, 1)
        cpu_temp = latest_gpu_status.get("cpu_temp")
        if cpu_temp is not None:
            m.add("rig_cpu_temp_celsius", "gauge", "Current host CPU temperature.", {"rig": rig}, _to_float(cpu_temp))

    if latest_pdu_power is not None:
        # Real meter reading (APC PDU or Tapo plug), NOT GPU-power-draw-only.
        # On zappa1 this is the FULL shared circuit (zappa1+zappa2 combined,
        # one physical APC PDU) -- see profit_api.py's SHARED_METER_RIG_LABEL
        # handling, which relies on that being true rather than per-rig.
        m.add("rig_pdu_power_watts", "gauge", "Real metered power draw (APC PDU or Tapo plug) -- full wall power, not just GPU chip draw. On a rig with a shared meter (see RIGS.md), this covers every rig on that circuit, not just this one.", {"rig": rig}, _to_float(latest_pdu_power.get("watts")))

    for mid, ev in latest_rental_status.items():
        for slot in ev.get("slots", []):
            labels = {"rig": rig, "machine_id": mid, "gpu_idx": slot.get("gpu_idx")}
            m.add("gpu_slot_rented", "gauge", "1 if this specific GPU slot is currently rented.", labels, 1 if slot.get("rented") else 0)
            rate = _to_float(slot.get("rate"), 0)
            if rate:
                m.add("gpu_slot_rate_dollars_per_hour", "gauge", "Per-slot rate if individually resolvable (0 for unresolved D-type slots).", labels, rate)

    state = _parse_state_file(state_file)
    for mid, s in state.items():
        labels = {"rig": rig, "machine_id": mid}
        m.add("machine_rented", "gauge", "1 if any GPU on this machine is currently rented.", labels, 1 if s["rented"] else 0)
        m.add("machine_rental_rate_dollars_per_hour", "gauge", "Current total $/hr this machine is earning (live instance rate, or earn_hour fallback for D-type).", labels, s["cost"])
        m.add("machine_rented_gpus", "gauge", "Number of GPUs on this machine currently rented.", labels, s["rented_count"])
        m.add("machine_earn_day_dollars", "gauge", "Vast's own live running total for today (earn_day).", labels, s["earn_day"])

    # Container/instance identity for the CURRENT rental, as a Prometheus info
    # metric (always 1, identifying data carried in labels — same pattern as
    # gpu_process_info above). Gated on state[mid]["rented"] (this scrape's
    # live /machines/ snapshot), not just "has a rental_start ever been seen"
    # -- otherwise a machine whose rental already ended would keep reporting
    # its last container as if it were still running. Each new rental_start
    # (a real_instance_id/image change) becomes a new label combination, so
    # Prometheus timestamps exactly when one rental's container was swapped
    # for another — that history didn't exist anywhere queryable before this,
    # only in this rig's local JSONL file.
    for mid, ev in latest_rental_start.items():
        if not state.get(mid, {}).get("rented"):
            continue
        labels = {
            "rig": rig,
            "machine_id": mid,
            "real_instance_id": str(ev.get("real_instance_id") or ""),
            "image": ev.get("image") or "",
            "workload_type": ev.get("workload_type") or "unknown",
        }
        m.add("rental_instance_info", "gauge", "1 while this container/instance is the CURRENT rental on this machine (labels carry real_instance_id/image/workload_type).", labels, 1)

    # latest_market/latest_price are the LAST-EVER-SEEN event per machine_id
    # from the full JSONL history — a machine deleted from Vast simply stops
    # getting new price_change/market_snapshot events, but its last one
    # never goes away on its own, so without this check a deleted machine
    # would keep re-emitting the same stale price/market gauges on every
    # single scrape forever, looking perpetually "live" to Prometheus (a
    # fresh sample every scrape never goes stale). `state` (this scrape's
    # snapshot of vastai_check()'s live /machines/ response) only ever
    # contains machines that currently exist on the account, so it's the
    # right filter. Confirmed live on zappa2 (2026-07-20): two machine_ids
    # deleted from Vast were still showing up in the Pricing Advisor with
    # their last-known (now meaningless) price.
    for mid, ev in latest_market.items():
        if mid not in state:
            continue
        labels_base = {"rig": rig, "machine_id": mid}
        for stat in ("p25", "median", "p75", "mean"):
            v = ev.get(stat)
            if v is not None:
                labels = dict(labels_base, stat=stat)
                m.add("market_price_dollars_per_hour", "gauge", "Comparable-listing market stat for this GPU model, fee-discounted.", labels, _to_float(v))

    for mid in set(latest_price) | set(latest_market):
        if mid not in state:
            continue
        price_ev = latest_price.get(mid)
        labels = {"rig": rig, "machine_id": mid}
        # A machine that's been fully rented every cycle since its last real
        # price adjustment never gets a NEW price_change event — vastai_pricing()
        # exits before writing one once a machine has no free GPU slot to
        # price (see "fully rented — skipping price adjustment" in
        # gpu_monitor.sh). Its market_snapshot event still fires every cycle
        # regardless of rented status though, and carries the listing price
        # at snapshot time as my_price — use that as a fallback so a
        # continuously-fully-rented machine still gets a
        # listing_price_dollars_per_hour instead of having none at all.
        # Confirmed live on zappa3 (2026-07-20): machine 143953 had market
        # comparables but zero listing price data, silently dropping it from
        # the Pricing Advisor entirely (it requires both to show a machine).
        if price_ev is not None and price_ev.get("new_price") is not None:
            m.add("listing_price_dollars_per_hour", "gauge", "This machine's current listing (ask) price.", labels, _to_float(price_ev.get("new_price")))
        else:
            market_ev = latest_market.get(mid)
            if market_ev is not None and market_ev.get("my_price") is not None:
                m.add("listing_price_dollars_per_hour", "gauge", "This machine's current listing (ask) price (from the last market snapshot — no recent price_change event, e.g. continuously fully rented).", labels, _to_float(market_ev.get("my_price")))
        if price_ev is not None:
            if price_ev.get("floor") is not None:
                m.add("listing_floor_dollars_per_hour", "gauge", "Configured price floor for this GPU model.", labels, _to_float(price_ev.get("floor")))
            if price_ev.get("target_value") is not None:
                target_labels = dict(labels, target_stat=price_ev.get("target_stat", "median"))
                m.add("listing_target_dollars_per_hour", "gauge", "The market stat value vastai_pricing() is targeting (see target_stat label).", target_labels, _to_float(price_ev.get("target_value")))

    # Expose the last few calendar dates seen, not just the single most
    # recent one — see the latest_earnings_by_date comment above for why
    # that broke "yesterday" every day at midnight. 5 days comfortably
    # covers vastai_sync_earnings()'s own 3-day active-refresh window with
    # margin; older dates have already settled and their last-exposed value
    # (from when they WERE within that window) stays correct in Prometheus's
    # own storage without needing re-exposure every scrape.
    for d in sorted(latest_earnings_by_date)[-5:]:
        ev = latest_earnings_by_date[d]
        m.add("rig_daily_earnings_dollars", "gauge", "Vast's own daily_earnings total for this date (last 5 synced dates exposed each scrape).", {"rig": rig, "date": d}, _to_float(ev.get("total")))

    # Configured $/kWh, exposed as its own gauge regardless of gpu_status
    # presence — lets anything computing HISTORICAL electricity cost (see
    # occupancy/profit period rollups) look up each rig's own rate via
    # Prometheus instead of needing filesystem access to that rig's conf.
    energy_rate = _read_energy_rate()
    m.add("rig_energy_rate_dollars_per_kwh", "gauge", "Configured PDU_ENERGY_RATE for this rig.", {"rig": rig}, energy_rate)

    # --- Live profit gauges: revenue vs. estimated electricity cost ---
    # GPU power draw only (not full system draw — CPU/fans/PSU losses aren't
    # metered per-rig anywhere; the PDU meters the whole rack collectively,
    # hub-only, so it can't attribute cost to one rig either) — a
    # conservative estimate of true cost, but the only per-rig-decomposable
    # signal actually available on every rig, not just the hub.
    if latest_gpu_status:
        gpus = latest_gpu_status.get("gpus", [])
        num_gpus = len(gpus)
        total_power_w = sum(_to_float(g.get("power_draw")) for g in gpus)
        total_revenue_hr = sum(s["cost"] for s in state.values())
        elec_cost_hr = total_power_w / 1000.0 * energy_rate
        profit_hr = total_revenue_hr - elec_cost_hr
        labels = {"rig": rig}
        m.add("rig_power_draw_total_watts", "gauge", "Total GPU power draw across this rig (not full system draw).", labels, total_power_w)
        m.add("rig_revenue_dollars_per_hour", "gauge", "Sum of this rig's machine(s) live rental rate.", labels, total_revenue_hr)
        m.add("rig_electricity_cost_dollars_per_hour", "gauge", f"Estimated electricity cost/hr from GPU power draw only, at ${energy_rate}/kWh (PDU_ENERGY_RATE).", labels, elec_cost_hr)
        m.add("rig_profit_dollars_per_hour", "gauge", "rig_revenue_dollars_per_hour minus rig_electricity_cost_dollars_per_hour.", labels, profit_hr)
        if num_gpus > 0:
            m.add("rig_revenue_per_gpu_dollars_per_hour", "gauge", "Revenue/hr divided by total GPU count (rented + free) — fleet monetization efficiency, not just the rented rate.", labels, total_revenue_hr / num_gpus)
        if total_power_w > 0:
            m.add("rig_revenue_per_watt_dollars_per_hour", "gauge", "Revenue/hr per watt of GPU power draw.", labels, total_revenue_hr / total_power_w)
            m.add("rig_revenue_per_kwh_dollars", "gauge", "Revenue/hr per kW of GPU power draw.", labels, total_revenue_hr / (total_power_w / 1000.0))

    # --- Cloudline room climate + fan state (hub-only, same as cooling_api.py) ---
    # No-ops on any rig without AC_INFINITY_EMAIL/PASSWORD set (cooling_api's
    # own gate) — lets GPU temp/util and room temp/fan speed live on the same
    # Prometheus time axis for Grafana correlation, without a second exporter
    # or standing up Home Assistant.
    if cooling_api.ENABLED:
        cooling = cooling_api.handle_cooling_get()
        for dev in cooling.get("devices", []) or []:
            dev_labels = {"location": CLOUDLINE_LOCATION, "device": dev.get("name") or dev.get("device_id") or ""}
            if dev.get("temp_c") is not None:
                m.add("room_temp_celsius", "gauge", "Cloudline controller's ambient temperature reading.", dev_labels, _to_float(dev.get("temp_c")))
            if dev.get("humidity_pct") is not None:
                m.add("room_humidity_percent", "gauge", "Cloudline controller's ambient humidity reading.", dev_labels, _to_float(dev.get("humidity_pct")))
            for p in dev.get("ports", []) or []:
                port_labels = dict(dev_labels, port=p.get("port"), port_name=p.get("name") or "")
                m.add("fan_online", "gauge", "1 if this Cloudline fan port reports online.", port_labels, 1 if p.get("online") else 0)
                if p.get("speed") is not None:
                    m.add("fan_speed", "gauge", "Current Cloudline fan speed, 0 (off) - 10 (max).", port_labels, _to_float(p.get("speed")))

    return m.render()
