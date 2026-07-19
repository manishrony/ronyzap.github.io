#!/usr/bin/env python3
"""Live + period-to-date profit metrics from the central Prometheus (hub only).

'Live' figures are instant queries against gauges prom_exporter.py already
computes every scrape (rig_revenue_dollars_per_hour etc.). Daily/monthly
profit are estimated by integrating those same live-rate gauges over the
elapsed period (avg rate x hours elapsed) — this is a continuously-updating
ESTIMATE, not Vast's own ground-truth daily_earnings sync (which only
updates once a day and lags "right now"); rig_daily_earnings_dollars is
still exposed separately by the exporter for cross-checking against this
estimate.

Like history_api.py, this only ever runs a small, fixed set of hardcoded
PromQL queries — never raw PromQL from the browser — since this dashboard
has no auth in front of it.
"""
import datetime
import prom_client

_INSTANT_METRICS = [
    "rig_revenue_dollars_per_hour",
    "rig_electricity_cost_dollars_per_hour",
    "rig_profit_dollars_per_hour",
    "rig_revenue_per_gpu_dollars_per_hour",
    "rig_revenue_per_watt_dollars_per_hour",
    "rig_revenue_per_kwh_dollars",
    "rig_power_draw_total_watts",
]


def get_live_profit(prom_url):
    """Current instant per-rig values for every _INSTANT_METRICS entry, plus
    a fleet-wide summary. The per-GPU/watt/kWh ratios are NOT summed across
    rigs (summing a ratio is meaningless) — the fleet versions of those are
    recomputed from fleet-wide totals instead."""
    rigs = {}
    for metric in _INSTANT_METRICS:
        try:
            results = prom_client.query_instant(prom_url, metric)
        except Exception:
            results = []
        for rig, val in prom_client.group_by_label(results, 'rig').items():
            rigs.setdefault(rig, {})[metric] = round(val, 6)

    fleet_revenue = sum(v.get("rig_revenue_dollars_per_hour", 0) for v in rigs.values())
    fleet_elec = sum(v.get("rig_electricity_cost_dollars_per_hour", 0) for v in rigs.values())
    fleet_power_w = sum(v.get("rig_power_draw_total_watts", 0) for v in rigs.values())
    try:
        gpu_counts = prom_client.group_by_label(prom_client.query_instant(prom_url, "count by(rig)(gpu_temp_celsius)"), 'rig')
    except Exception:
        gpu_counts = {}
    total_gpus = sum(gpu_counts.values())

    fleet = {
        "revenue_per_hour": round(fleet_revenue, 4),
        "electricity_per_hour": round(fleet_elec, 4),
        "profit_per_hour": round(fleet_revenue - fleet_elec, 4),
        "revenue_per_gpu_per_hour": round(fleet_revenue / total_gpus, 4) if total_gpus else None,
        "revenue_per_watt_per_hour": round(fleet_revenue / fleet_power_w, 6) if fleet_power_w else None,
        "revenue_per_kwh": round(fleet_revenue / (fleet_power_w / 1000.0), 4) if fleet_power_w else None,
        "total_gpus": int(total_gpus),
        "total_power_watts": round(fleet_power_w, 1),
    }
    return {"rigs": rigs, "fleet": fleet}


def _integrate(prom_url, metric, start_ts, now_ts):
    """Estimated total $ over [start_ts, now_ts] for a $/hour gauge: average
    value over the window (per rig, via a bare avg_over_time — no nested
    aggregation, so no subquery syntax needed) x hours elapsed, summed
    across rigs."""
    hours = (now_ts - start_ts) / 3600.0
    if hours <= 0:
        return 0.0
    window_s = int(now_ts - start_ts)
    query = f"avg_over_time({metric}[{window_s}s])"
    try:
        results = prom_client.query_instant(prom_url, query, at=now_ts)
    except Exception:
        return 0.0
    per_rig_avg = prom_client.group_by_label(results, 'rig')
    return sum(per_rig_avg.values()) * hours


def get_period_profit(prom_url, now_ts=None):
    """Daily (today, calendar UTC) and monthly (month-to-date, calendar UTC)
    profit, estimated by integrating the live rate gauges over the elapsed
    period so far."""
    now = datetime.datetime.utcfromtimestamp(now_ts) if now_ts else datetime.datetime.utcnow()
    now = now.replace(tzinfo=datetime.timezone.utc)
    day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    month_start = day_start.replace(day=1)
    now_epoch = now.timestamp()

    day_revenue = _integrate(prom_url, "rig_revenue_dollars_per_hour", day_start.timestamp(), now_epoch)
    day_elec = _integrate(prom_url, "rig_electricity_cost_dollars_per_hour", day_start.timestamp(), now_epoch)
    month_revenue = _integrate(prom_url, "rig_revenue_dollars_per_hour", month_start.timestamp(), now_epoch)
    month_elec = _integrate(prom_url, "rig_electricity_cost_dollars_per_hour", month_start.timestamp(), now_epoch)

    return {
        "today": {
            "revenue": round(day_revenue, 2),
            "electricity": round(day_elec, 2),
            "profit": round(day_revenue - day_elec, 2),
            "hours_elapsed": round((now_epoch - day_start.timestamp()) / 3600.0, 1),
        },
        "month_to_date": {
            "revenue": round(month_revenue, 2),
            "electricity": round(month_elec, 2),
            "profit": round(month_revenue - month_elec, 2),
            "days_elapsed": round((now_epoch - month_start.timestamp()) / 86400.0, 1),
        },
    }


def handle_profit_request(prom_url, now_ts=None):
    return {
        "live": get_live_profit(prom_url),
        "periods": get_period_profit(prom_url, now_ts),
    }
