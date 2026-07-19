#!/usr/bin/env python3
"""Live + period-to-date profit metrics from the central Prometheus (hub only).

'Live' figures are instant queries against gauges prom_exporter.py already
computes every scrape (rig_revenue_dollars_per_hour etc.).

Daily/monthly REVENUE uses rig_daily_earnings_dollars (Vast's own
ground-truth daily sync, one series per (rig, date) — a still-accumulating
running total for today, a settled total for a completed day) rather than
integrating the live rig_revenue_dollars_per_hour rate over the period.
That distinction matters: rig_revenue_dollars_per_hour only exists in
Prometheus since Live Profit Metrics was deployed (no history before that),
so integrating it over a multi-week "month to date" window would silently
average the last few hours of real samples and then multiply that average
across weeks it was never actually measured for — a large, confirmed
overestimate. rig_daily_earnings_dollars has real depth back to ~June 8
(the historical backfill), so summing actual per-day totals is correct —
though since Prometheus itself only retains 14 days (see install.sh), that
backfilled depth only matters within the retention window; the
RETENTION_LOOKBACK_DAYS cap below keeps "month to date" honest about that
instead of silently undercounting once a query window reaches past what
Prometheus still has.

Daily/monthly ELECTRICITY has no ground-truth equivalent (it's our own
estimate either way), so it's estimated by integrating gpu_power_draw_watts
(same depth problem solved the same way — it also has real backfilled
history, unlike the newer rig_electricity_cost_dollars_per_hour) against
each rig's own rig_energy_rate_dollars_per_kwh.

Like history_api.py, this only ever runs a small, fixed set of hardcoded
PromQL queries — never raw PromQL from the browser — since this dashboard
has no auth in front of it.
"""
import datetime
import prom_client

# Prometheus itself only retains 14 days (see install.sh) — a calendar
# "month to date" window reaching further back than that would silently
# drop the earlier days out of the sum rather than erroring, understating
# revenue for the back half of any month with no visible sign anything was
# wrong. Capping the query window here (with a 1-day safety margin) and
# reporting whether it got capped lets the caller show an honest label
# ("last 13d" rather than "since day 1") instead of a wrong-looking number.
RETENTION_LOOKBACK_DAYS = 13

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


def _earnings_by_rig_date(prom_url, start_ts, now_ts):
    """{(rig, date): total_dollars} for every distinct rig_daily_earnings_dollars
    series touched by [start_ts, now_ts] — each (rig, date) combination is its
    own Prometheus series (the exporter's `date` label only changes once a
    day), so the LAST sample in range for a given series is that day's most
    up-to-date total: a still-growing running total for today, a settled
    total for a completed day. Ground truth (Vast's own daily sync), not an
    extrapolation."""
    step = 3600  # this gauge only updates ~hourly; no need for finer resolution
    data = prom_client.query_range(prom_url, "rig_daily_earnings_dollars", start_ts, now_ts, step)
    out = {}
    for series in data.get("result", []):
        metric = series.get("metric", {})
        rig, date = metric.get("rig"), metric.get("date")
        if rig is None or date is None:
            continue
        values = series.get("values") or []
        if not values:
            continue
        try:
            out[(rig, date)] = float(values[-1][1])
        except (ValueError, TypeError, IndexError):
            continue
    return out


def _estimate_electricity_cost(prom_url, start_ts, now_ts):
    """Estimated total electricity $ over [start_ts, now_ts]: each rig's
    average total GPU power draw over the window (bare avg_over_time, no
    nested aggregation — summed per rig in Python instead of via a subquery)
    x hours elapsed x that rig's own configured rate."""
    hours = (now_ts - start_ts) / 3600.0
    if hours <= 0:
        return 0.0
    window_s = int(now_ts - start_ts)
    try:
        power_results = prom_client.query_instant(prom_url, f"avg_over_time(gpu_power_draw_watts[{window_s}s])", at=now_ts)
    except Exception:
        return 0.0
    power_by_rig = {}
    for r in power_results:
        rig = r.get("metric", {}).get("rig")
        if rig is None:
            continue
        try:
            power_by_rig[rig] = power_by_rig.get(rig, 0.0) + float(r["value"][1])
        except (KeyError, ValueError, TypeError, IndexError):
            continue

    try:
        rate_by_rig = prom_client.group_by_label(prom_client.query_instant(prom_url, "rig_energy_rate_dollars_per_kwh"), "rig")
    except Exception:
        rate_by_rig = {}

    total_cost = 0.0
    for rig, avg_watts in power_by_rig.items():
        rate = rate_by_rig.get(rig, 0.25)  # matches gpu_monitor.sh's own PDU_ENERGY_RATE default
        kwh = avg_watts / 1000.0 * hours
        total_cost += kwh * rate
    return total_cost


def get_period_profit(prom_url, now_ts=None):
    """Daily (today, calendar UTC) and monthly (month-to-date, calendar UTC)
    profit: ground-truth revenue (rig_daily_earnings_dollars) minus
    estimated electricity (integrated GPU power draw x each rig's rate)."""
    now = datetime.datetime.utcfromtimestamp(now_ts) if now_ts else datetime.datetime.utcnow()
    now = now.replace(tzinfo=datetime.timezone.utc)
    day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    month_start = day_start.replace(day=1)
    lookback_start = now - datetime.timedelta(days=RETENTION_LOOKBACK_DAYS)
    window_start = max(month_start, lookback_start)
    window_capped = window_start > month_start
    now_epoch = now.timestamp()
    today_str = now.strftime("%Y-%m-%d")

    earnings = _earnings_by_rig_date(prom_url, window_start.timestamp(), now_epoch)
    month_revenue = sum(earnings.values())
    day_revenue = sum(v for (rig, date), v in earnings.items() if date == today_str)

    day_elec = _estimate_electricity_cost(prom_url, day_start.timestamp(), now_epoch)
    month_elec = _estimate_electricity_cost(prom_url, window_start.timestamp(), now_epoch)

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
            "days_elapsed": round((now_epoch - window_start.timestamp()) / 86400.0, 1),
            "window_capped": window_capped,
        },
    }


def handle_profit_request(prom_url, now_ts=None):
    return {
        "live": get_live_profit(prom_url),
        "periods": get_period_profit(prom_url, now_ts),
    }
