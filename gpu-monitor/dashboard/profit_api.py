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
(the historical backfill), so summing actual per-day totals is correct.
Prometheus itself never deletes this data (10y retention, effectively
"keep everything" — see install.sh), so no capping is needed here.

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
    extrapolation.

    Uses last_over_time() with a window wider than the query step, NOT a bare
    metric selector — confirmed live (2026-07-19) that a bare selector at a
    1h step silently returns NOTHING for this gauge's backfilled samples.
    gpu_monitor.sh's earnings sync writes each sample with ts=utcnow() (when
    the sync happened to run), not a fixed grid time, so a backfilled sample
    almost never falls within Prometheus's 5-minute default lookback of an
    hourly grid point — a bare selector query_range at 1h steps found ZERO
    of 7 known-good test samples. last_over_time(...[window]) with window >=
    step guarantees every real sample falls inside at least one evaluated
    window regardless of its exact timestamp.

    step is adaptive (same formula as _electricity_cost_by_rig below), NOT a
    fixed 3600s — confirmed live (2026-07-21) that a fixed 1h step, evaluated
    only at exact hour-boundary grid points, can miss a real sample that
    landed in the same partial hour as `now_ts`: a sample scraped at 02:45
    fell strictly between the 02:00 and 03:00 grid points, so the query's
    last evaluated instant (02:00, since 03:00 is still in the future) never
    saw it and returned an hour-old value instead. A finer step keeps the
    last grid point within minutes of now_ts regardless of where in the hour
    now_ts falls."""
    window_s_total = max(int(now_ts - start_ts), 1)
    step = max(300, min(3600, window_s_total // 500))
    window_s = step * 2  # generous overlap margin beyond just matching the step
    data = prom_client.query_range(prom_url, f"last_over_time(rig_daily_earnings_dollars[{window_s}s])", start_ts, now_ts, step)
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
            v = float(values[-1][1])
        except (ValueError, TypeError, IndexError):
            continue
        # max(), never last-write-wins: the same (rig, date) can exist as TWO
        # Prometheus series — the live-scraped one (carries instance/job
        # labels, added by Prometheus at scrape time) and a backfilled one
        # (promtool-created blocks have no scrape labels). The backfilled
        # series freezes at whatever the running total was when the .om file
        # was generated, while the live one keeps climbing to the real
        # end-of-day total. Since daily_earnings is a running accumulator
        # within a date, the larger value is by definition the more complete
        # one. Confirmed live (2026-07-20): zappa2's 2026-07-19 showed $38.09
        # (backfill frozen mid-day) instead of $77.43 (live final) on the
        # Previous Day Summary because the backfilled series happened to be
        # processed last and overwrote the live one.
        key = (rig, date)
        if key not in out or v > out[key]:
            out[key] = v
    return out


def _electricity_cost_by_rig(prom_url, start_ts, end_ts):
    """{rig: estimated electricity $} over [start_ts, end_ts], as a real
    time-integral of GPU power draw — NOT avg_over_time x full-window-hours.
    That shortcut had two confirmed live bugs (2026-07-20, MTD showed
    $815.66 when reality was far lower):

    1. avg_over_time only averages samples that EXIST, but the old code
       multiplied by the FULL window's hours — so a rig that came online
       mid-month (zappa2: July 10, zappa3: July 13) was billed its
       average-while-alive draw for the entire month, roughly doubling its
       share.
    2. gpu_power_draw_watts is a backfilled metric, so each GPU exists as
       TWO series (backfilled without instance/job labels + live-scraped
       with them — see RIGS.md's backfill warning), and summing every
       returned series counted each GPU's watts twice wherever both exist.

    The range-integral fixes both at once: `max by (rig, gpu_idx)` collapses
    the backfill/live duplicates to one reading per physical GPU, `sum by
    (rig)` totals a rig's GPUs, and integrating point-by-point over the
    range means grid points where a rig has no data contribute exactly $0 —
    a rig is only billed for time it actually reported power draw."""
    window_s = int(end_ts - start_ts)
    if window_s <= 0:
        return {}
    # Bound the point count regardless of window size (day vs. month), and
    # keep the last_over_time sub-window at 2x step so a scrape gap smaller
    # than the step can't punch a hole in the integral.
    step = max(300, min(3600, window_s // 500))
    subwin = step * 2
    query = f"sum by (rig) (max by (rig, gpu_idx) (last_over_time(gpu_power_draw_watts[{subwin}s])))"
    try:
        data = prom_client.query_range(prom_url, query, start_ts, end_ts, step)
    except Exception:
        return {}

    try:
        rate_by_rig = prom_client.group_by_label(prom_client.query_instant(prom_url, "rig_energy_rate_dollars_per_kwh"), "rig")
    except Exception:
        rate_by_rig = {}

    out = {}
    for series in data.get("result", []):
        rig = series.get("metric", {}).get("rig")
        if rig is None:
            continue
        watt_sum = 0.0
        for _, v in series.get("values") or []:
            try:
                watt_sum += float(v)
            except (ValueError, TypeError):
                continue
        kwh = watt_sum / 1000.0 * (step / 3600.0)
        rate = rate_by_rig.get(rig, 0.25)  # matches gpu_monitor.sh's own PDU_ENERGY_RATE default
        out[rig] = out.get(rig, 0.0) + kwh * rate
    return out


def _estimate_electricity_cost(prom_url, start_ts, now_ts):
    """Fleet-total electricity $ over the window — see _electricity_cost_by_rig."""
    return sum(_electricity_cost_by_rig(prom_url, start_ts, now_ts).values())


def get_period_profit(prom_url, now_ts=None):
    """Daily (today, calendar UTC) and monthly (month-to-date, calendar UTC)
    profit: ground-truth revenue (rig_daily_earnings_dollars) minus
    estimated electricity (integrated GPU power draw x each rig's rate)."""
    now = datetime.datetime.utcfromtimestamp(now_ts) if now_ts else datetime.datetime.utcnow()
    now = now.replace(tzinfo=datetime.timezone.utc)
    day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    month_start = day_start.replace(day=1)
    now_epoch = now.timestamp()
    today_str = now.strftime("%Y-%m-%d")

    earnings = _earnings_by_rig_date(prom_url, month_start.timestamp(), now_epoch)
    month_revenue = sum(earnings.values())
    day_revenue = sum(v for (rig, date), v in earnings.items() if date == today_str)

    day_elec = _estimate_electricity_cost(prom_url, day_start.timestamp(), now_epoch)
    month_elec = _estimate_electricity_cost(prom_url, month_start.timestamp(), now_epoch)

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
