#!/usr/bin/env python3
"""Major-event feed derived from Prometheus time-series (hub only).

Rather than tailing each rig's own JSONL event log (which requires proxying
through that rig's own dashboard and mixes in high-frequency noise — a
gpu_status snapshot every scrape cycle, market snapshots, etc.), this
detects discrete "things that changed" directly from the same gauges every
rig already scrapes into the central Prometheus: GPU temp crossing into the
amber zone, CPU temp crossing into its own warning zone, GPU rental slots
flipping rented/idle, and listing price changes. One source of truth,
works uniformly for every rig from the hub, with no dependency on a peer
rig's dashboard being reachable.

Thresholds use hysteresis (rise/fall a few degrees apart) rather than a
single cutoff — a temperature sitting right at 80.0°C would otherwise flap
in and out of "alert" on every scrape and bury the feed in noise.

Like history_api.py/profit_api.py/occupancy_api.py, this only ever runs a
small, fixed set of hardcoded PromQL queries — never raw PromQL from the
browser — since this dashboard has no auth in front of it.
"""
import datetime
import time
import prom_client

GPU_TEMP_RISE_C = 80.0
GPU_TEMP_FALL_C = 75.0
CPU_TEMP_RISE_C = 80.0
CPU_TEMP_FALL_C = 75.0


def _iso(ts):
    return datetime.datetime.utcfromtimestamp(ts).isoformat() + "Z"


def _range_by_series(prom_url, query, start_ts, end_ts, step_s, label_keys):
    """{label-tuple: [(ts, float value), ...]} for every series touched by
    the range, sorted by timestamp (query_range already returns them that
    way, but sort defensively)."""
    data = prom_client.query_range(prom_url, query, start_ts, end_ts, step_s)
    out = {}
    for series in data.get("result", []):
        metric = series.get("metric", {})
        key = tuple(metric.get(k) for k in label_keys)
        if None in key:
            continue
        pts = []
        for ts, v in series.get("values") or []:
            try:
                pts.append((float(ts), float(v)))
            except (ValueError, TypeError):
                continue
        pts.sort(key=lambda p: p[0])
        out[key] = pts
    return out


def _temp_alerts(series_by_key, label_keys, rise_at, fall_at, event_type, badge):
    """Hysteresis crossing detection: an "alert" event when a series rises
    through `rise_at`, a "recovered" event when it later falls back through
    the lower `fall_at` — the gap between the two prevents a value
    oscillating near one cutoff from generating an event on every sample."""
    events = []
    for key, pts in series_by_key.items():
        labels = dict(zip(label_keys, key))
        rig = labels.get("rig", "?")
        who = f"GPU {labels['gpu_idx']}" if "gpu_idx" in labels else "CPU"
        above = None
        for ts, v in pts:
            if above is None:
                above = v >= rise_at
                continue
            if not above and v >= rise_at:
                events.append({
                    "ts": _iso(ts), "rig": rig, "type": event_type, "severity": "warning",
                    "badge": badge, "detail": f"{who} hit {v:.0f}°C (≥ {rise_at:.0f}°C)",
                })
                above = True
            elif above and v <= fall_at:
                events.append({
                    "ts": _iso(ts), "rig": rig, "type": event_type, "severity": "info",
                    "badge": badge, "detail": f"{who} back to {v:.0f}°C (≤ {fall_at:.0f}°C)",
                })
                above = False
    return events


def _rental_changes(series_by_key, label_keys):
    events = []
    for key, pts in series_by_key.items():
        labels = dict(zip(label_keys, key))
        rig = labels.get("rig", "?")
        who = f"machine {labels.get('machine_id')} GPU {labels.get('gpu_idx')}"
        prev = None
        for ts, v in pts:
            rented = v >= 0.5
            if prev is None:
                prev = rented
                continue
            if rented != prev:
                events.append({
                    "ts": _iso(ts), "rig": rig, "type": "rental_change",
                    "severity": "info", "badge": "▶ RENTED" if rented else "■ FREED",
                    "detail": f"{who} {'started renting' if rented else 'went idle'}",
                })
            prev = rented
    return events


def _price_changes(series_by_key, label_keys):
    events = []
    for key, pts in series_by_key.items():
        labels = dict(zip(label_keys, key))
        rig = labels.get("rig", "?")
        mid = labels.get("machine_id", "?")
        prev = None
        for ts, v in pts:
            if prev is not None and abs(v - prev) > 1e-9:
                events.append({
                    "ts": _iso(ts), "rig": rig, "type": "price_change",
                    "severity": "info", "badge": "\U0001f4b0 PRICE",
                    "detail": f"machine {mid} ${prev:.2f} → ${v:.2f}/hr",
                })
            prev = v
    return events


def _collect_events(prom_url, window_hours, now_ts=None):
    window_hours = max(1, min(24 * 90, window_hours))
    end_ts = now_ts if now_ts else time.time()
    start_ts = end_ts - window_hours * 3600
    step_s = 30  # matches the exporter's own scrape cadence

    events = []

    try:
        gpu_temp = _range_by_series(prom_url, "gpu_temp_celsius", start_ts, end_ts, step_s, ("rig", "gpu_idx"))
        events += _temp_alerts(gpu_temp, ("rig", "gpu_idx"), GPU_TEMP_RISE_C, GPU_TEMP_FALL_C, "gpu_temp_alert", "\U0001f321️ GPU TEMP")
    except Exception:
        pass

    try:
        cpu_temp = _range_by_series(prom_url, "rig_cpu_temp_celsius", start_ts, end_ts, step_s, ("rig",))
        events += _temp_alerts(cpu_temp, ("rig",), CPU_TEMP_RISE_C, CPU_TEMP_FALL_C, "cpu_temp_alert", "\U0001f525 CPU TEMP")
    except Exception:
        pass

    try:
        rented = _range_by_series(prom_url, "gpu_slot_rented", start_ts, end_ts, step_s, ("rig", "machine_id", "gpu_idx"))
        events += _rental_changes(rented, ("rig", "machine_id", "gpu_idx"))
    except Exception:
        pass

    try:
        price = _range_by_series(prom_url, "listing_price_dollars_per_hour", start_ts, end_ts, step_s, ("rig", "machine_id"))
        events += _price_changes(price, ("rig", "machine_id"))
    except Exception:
        pass

    events.sort(key=lambda e: e["ts"], reverse=True)
    return events


def get_recent_events(prom_url, window_hours=24, limit=60, now_ts=None):
    return _collect_events(prom_url, window_hours, now_ts)[:limit]


def handle_events_request(prom_url, query_params, now_ts=None):
    def _get(name, default=None):
        v = query_params.get(name)
        return v[0] if v else default

    try:
        hours = int(_get("hours", 24))
    except (TypeError, ValueError):
        hours = 24
    try:
        limit = int(_get("limit", 60))
    except (TypeError, ValueError):
        limit = 60

    events = _collect_events(prom_url, hours, now_ts)
    rig_filter = _get("rig")
    if rig_filter:
        events = [e for e in events if e["rig"].lower() == rig_filter.lower()]
    return {"window_hours": hours, "events": events[:limit]}
