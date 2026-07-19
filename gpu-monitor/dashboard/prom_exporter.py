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


def render_metrics(data_file, state_file, rig_name=None):
    rig = rig_name or socket.gethostname()
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

    for mid, ev in latest_market.items():
        labels_base = {"rig": rig, "machine_id": mid}
        for stat in ("p25", "median", "p75", "mean"):
            v = ev.get(stat)
            if v is not None:
                labels = dict(labels_base, stat=stat)
                m.add("market_price_dollars_per_hour", "gauge", "Comparable-listing market stat for this GPU model, fee-discounted.", labels, _to_float(v))

    for mid, ev in latest_price.items():
        labels = {"rig": rig, "machine_id": mid}
        if ev.get("new_price") is not None:
            m.add("listing_price_dollars_per_hour", "gauge", "This machine's current listing (ask) price.", labels, _to_float(ev.get("new_price")))
        if ev.get("floor") is not None:
            m.add("listing_floor_dollars_per_hour", "gauge", "Configured price floor for this GPU model.", labels, _to_float(ev.get("floor")))
        if ev.get("target_value") is not None:
            target_labels = dict(labels, target_stat=ev.get("target_stat", "median"))
            m.add("listing_target_dollars_per_hour", "gauge", "The market stat value vastai_pricing() is targeting (see target_stat label).", target_labels, _to_float(ev.get("target_value")))

    if latest_earnings:
        m.add("rig_daily_earnings_dollars", "gauge", "Vast's own daily_earnings total for the most recently synced date.", {"rig": rig, "date": latest_earnings.get("date", "")}, _to_float(latest_earnings.get("total")))

    return m.render()
