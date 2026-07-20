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
import re
import socket
from pathlib import Path

_RATE_RE = re.compile(r'[-+]?\d*\.?\d+')
_CONF_FILE = "/etc/gpu_monitor.conf"


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
    # --- Latest daily_earnings (by ts) ---
    latest_earnings = None
    latest_earnings_ts = ""

    for ev in _read_jsonl(data_file):
        t = ev.get("type")
        if t == "gpu_status":
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
        elif t == "daily_earnings" and ev.get("source") == "vast_api":
            ts = ev.get("ts", "")
            if ts >= latest_earnings_ts:
                latest_earnings_ts = ts
                latest_earnings = ev

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

    if latest_earnings:
        m.add("rig_daily_earnings_dollars", "gauge", "Vast's own daily_earnings total for the most recently synced date.", {"rig": rig, "date": latest_earnings.get("date", "")}, _to_float(latest_earnings.get("total")))

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

    return m.render()
