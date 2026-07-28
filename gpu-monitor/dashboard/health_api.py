#!/usr/bin/env python3
"""Fleet Health Score + active alerts (hub only), derived from Prometheus.

Health Score (0-100, per rig + fleet): the percentage of the scoring window
(default 24h) that every GPU and the CPU stayed OUT of the same amber-zone
thresholds events_api.py already alerts on (80C rise / 75C fall hysteresis,
imported from there rather than redefined here) — a single, simple thermal-
health number rather than a blend of unrelated signals. 100 = never crossed
into the amber zone in the window; a rig sitting at 90 spent about 10% of
the window in the alert zone. Deliberately narrow in scope: this measures
thermal health, not rental uptime or dashboard reachability — "is this rig
online" is already answered correctly today by the combined dashboard's own
per-rig client-side reachability check (each rig's own /api/data fetch
succeeding or not), which doesn't need or benefit from being re-derived
through Prometheus's `up` metric — that metric is keyed by scrape
`instance` (host:port), not by the `rig` label every other metric in this
codebase carries, and stitching one to the other would need a static
instance-to-rig map that (like the Zappa1/zappa1 mismatch earlier this
session) is exactly the kind of thing that quietly drifts out of sync.

Active Alerts: an INSTANT (not historical) check of whether any GPU or CPU
is over the threshold RIGHT NOW — "what needs attention this second," as
opposed to the Health Score's rearview window or the Recent Events feed's
history of things that already happened and resolved.

Like history_api.py/profit_api.py/occupancy_api.py/events_api.py, this only
ever runs a small, fixed set of hardcoded PromQL queries — never raw PromQL
from the browser — since this dashboard has no auth in front of it.
"""
import time
import prom_client
import events_api

GPU_TEMP_RISE_C = events_api.GPU_TEMP_RISE_C
CPU_TEMP_RISE_C = events_api.CPU_TEMP_RISE_C


def _time_above_by_key(series_by_key, threshold):
    """{key: (hours spent >= threshold, hours spanned)} — time-weighted,
    not a sample count: whenever a sample is already at/over threshold, the
    gap to the NEXT sample counts as time spent in-alert (right-open
    interval; a reasonable approximation at the exporter's fixed 30s scrape
    cadence). `hours spanned` is the actual observed range for that series
    (not the requested window), so a series with gaps or a late start
    doesn't get penalized against time it was never sampled."""
    out = {}
    for key, pts in series_by_key.items():
        if len(pts) < 2:
            out[key] = (0.0, 0.0)
            continue
        alert_hours = 0.0
        for (t0, v0), (t1, v1) in zip(pts, pts[1:]):
            if v0 >= threshold:
                alert_hours += (t1 - t0) / 3600.0
        span_hours = (pts[-1][0] - pts[0][0]) / 3600.0
        out[key] = (alert_hours, span_hours)
    return out


def get_health_score(prom_url, window_hours=24, now_ts=None):
    window_hours = max(1, min(24 * 90, window_hours))
    end_ts = now_ts if now_ts else time.time()
    start_ts = end_ts - window_hours * 3600
    step_s = 30

    try:
        gpu_temp = prom_client.range_by_series(prom_url, "gpu_temp_celsius", start_ts, end_ts, step_s, ("rig", "gpu_idx"))
    except Exception:
        gpu_temp = {}
    try:
        cpu_temp = prom_client.range_by_series(prom_url, "rig_cpu_temp_celsius", start_ts, end_ts, step_s, ("rig",))
    except Exception:
        cpu_temp = {}

    gpu_stats = _time_above_by_key(gpu_temp, GPU_TEMP_RISE_C)
    cpu_stats = _time_above_by_key(cpu_temp, CPU_TEMP_RISE_C)

    # Aggregate GPU stats per rig (sum across that rig's GPUs) before
    # turning them into a percentage — a rig's GPU health is "what fraction
    # of all its GPU-hours were spent in-alert," not an average of
    # per-GPU percentages (which would let one always-hot GPU get diluted
    # by several always-cool ones in a way that under-represents it, or
    # over-represents it, depending on how many GPUs happen to exist).
    gpu_alert_by_rig, gpu_span_by_rig = {}, {}
    for (rig, gpu_idx), (alert_h, span_h) in gpu_stats.items():
        gpu_alert_by_rig[rig] = gpu_alert_by_rig.get(rig, 0.0) + alert_h
        gpu_span_by_rig[rig] = gpu_span_by_rig.get(rig, 0.0) + span_h

    rigs = set(gpu_span_by_rig) | set(r for (r,) in cpu_stats)
    per_rig = {}
    for rig in rigs:
        gpu_alert_h = gpu_alert_by_rig.get(rig, 0.0)
        gpu_span_h = gpu_span_by_rig.get(rig, 0.0)
        gpu_pct = round(100.0 * (1 - gpu_alert_h / gpu_span_h), 1) if gpu_span_h > 0 else None

        cpu_alert_h, cpu_span_h = cpu_stats.get((rig,), (0.0, 0.0))
        cpu_pct = round(100.0 * (1 - cpu_alert_h / cpu_span_h), 1) if cpu_span_h > 0 else None

        parts = [p for p in (gpu_pct, cpu_pct) if p is not None]
        score = round(sum(parts) / len(parts), 1) if parts else None

        per_rig[rig] = {
            "score": score,
            "gpu_temp_health_pct": gpu_pct,
            "cpu_temp_health_pct": cpu_pct,
            "gpu_alert_hours": round(gpu_alert_h, 2),
            "cpu_alert_hours": round(cpu_alert_h, 2),
        }

    scores = [v["score"] for v in per_rig.values() if v["score"] is not None]
    fleet_score = round(sum(scores) / len(scores), 1) if scores else None

    return {
        "window_hours": window_hours,
        "per_rig": per_rig,
        "fleet": {"score": fleet_score},
    }


def get_active_alerts(prom_url, now_ts=None):
    """What's over threshold RIGHT NOW, not historically — a live snapshot,
    same thresholds as the Health Score and events_api.py so all three
    always agree with each other."""
    at = now_ts if now_ts else time.time()
    alerts = []

    try:
        gpu_now = prom_client.query_instant(prom_url, "gpu_temp_celsius", at=at)
    except Exception:
        gpu_now = []
    for r in gpu_now:
        m = r.get("metric", {})
        rig = m.get("rig")
        if rig is None:
            continue
        try:
            v = float(r["value"][1])
        except (KeyError, ValueError, TypeError, IndexError):
            continue
        if v >= GPU_TEMP_RISE_C:
            alerts.append({
                "rig": rig, "type": "gpu_temp", "severity": "warning",
                "detail": f"GPU {m.get('gpu_idx')} at {v:.0f}°C",
            })

    try:
        cpu_now = prom_client.query_instant(prom_url, "rig_cpu_temp_celsius", at=at)
    except Exception:
        cpu_now = []
    for r in cpu_now:
        m = r.get("metric", {})
        rig = m.get("rig")
        if rig is None:
            continue
        try:
            v = float(r["value"][1])
        except (KeyError, ValueError, TypeError, IndexError):
            continue
        if v >= CPU_TEMP_RISE_C:
            alerts.append({
                "rig": rig, "type": "cpu_temp", "severity": "warning",
                "detail": f"CPU at {v:.0f}°C",
            })

    alerts.sort(key=lambda a: a["rig"])
    return alerts


def handle_health_request(prom_url, query_params, now_ts=None):
    def _get(name, default=None):
        v = query_params.get(name)
        return v[0] if v else default

    try:
        hours = int(_get("hours", 24))
    except (TypeError, ValueError):
        hours = 24

    return {
        "health": get_health_score(prom_url, hours, now_ts),
        "active_alerts": get_active_alerts(prom_url, now_ts),
    }
