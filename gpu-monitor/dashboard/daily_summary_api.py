#!/usr/bin/env python3
"""Previous-day (full UTC calendar day) analysis + summary from the central
Prometheus (hub only).

Reuses the ground-truth-vs-estimate rules learned building profit_api.py:
revenue comes from rig_daily_earnings_dollars (Vast's own ground truth, has
real backfilled depth), electricity is estimated by integrating
gpu_power_draw_watts (also has real depth) against each rig's own
rig_energy_rate_dollars_per_kwh. Occupancy reuses occupancy_api.get_occupancy
verbatim, just anchored (via `now_ts`) at the end of the target day instead
of the live present moment, so a 24h lookback window lands exactly on that
day rather than a trailing window from "now".

Price-change counts come from PromQL's changes() over the existing
listing_price_dollars_per_hour gauge rather than a dedicated counter metric
— no counter for this exists yet, and one added today would have no history
for "yesterday" anyway (the same short-lived-gauge trap profit_api.py's fix
was about). changes() over a gauge that already has real depth sidesteps
that entirely.

Like history_api.py/profit_api.py/occupancy_api.py, this only ever runs a
small, fixed set of hardcoded PromQL queries — never raw PromQL from the
browser — since this dashboard has no auth in front of it.
"""
import datetime
import prom_client
import profit_api
import occupancy_api


def _previous_day_bounds(now_ts=None):
    now = datetime.datetime.utcfromtimestamp(now_ts) if now_ts else datetime.datetime.utcnow()
    now = now.replace(tzinfo=datetime.timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    day_start = today_start - datetime.timedelta(days=1)
    return day_start, today_start


def _day_bounds(date_str=None, now_ts=None):
    """Bounds for an explicit YYYY-MM-DD (full UTC calendar day), or the
    previous day relative to now_ts when date_str is omitted — same default
    behavior as before this got a date param."""
    if date_str:
        day_start = datetime.datetime.strptime(date_str, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
        return day_start, day_start + datetime.timedelta(days=1)
    return _previous_day_bounds(now_ts)


def _revenue_by_rig(prom_url, day_start, day_end, date_str):
    earnings = profit_api._earnings_by_rig_date(prom_url, day_start.timestamp(), day_end.timestamp())
    return {rig: v for (rig, date), v in earnings.items() if date == date_str}


def _electricity_by_rig(prom_url, day_start_ts, day_end_ts):
    """Delegates to profit_api's shared time-integral — this used to be its
    own avg_over_time x full-window-hours copy, which carried the same two
    bugs fixed there 2026-07-20 (partial-coverage rigs billed for the whole
    window, and backfill/live duplicate series double-counting each GPU)."""
    return profit_api._electricity_cost_by_rig(prom_url, day_start_ts, day_end_ts)


def _temps_by_rig(prom_url, day_start_ts, day_end_ts):
    window_s = int(day_end_ts - day_start_ts)
    try:
        max_results = prom_client.query_instant(prom_url, f"max_over_time(gpu_temp_celsius[{window_s}s])", at=day_end_ts)
    except Exception:
        max_results = []
    try:
        avg_results = prom_client.query_instant(prom_url, f"avg_over_time(gpu_temp_celsius[{window_s}s])", at=day_end_ts)
    except Exception:
        avg_results = []

    max_by_rig = {}
    for r in max_results:
        rig = r.get("metric", {}).get("rig")
        if rig is None:
            continue
        try:
            v = float(r["value"][1])
        except (KeyError, ValueError, TypeError, IndexError):
            continue
        max_by_rig[rig] = max(max_by_rig.get(rig, v), v)

    avg_sum, avg_cnt = {}, {}
    for r in avg_results:
        rig = r.get("metric", {}).get("rig")
        if rig is None:
            continue
        try:
            v = float(r["value"][1])
        except (KeyError, ValueError, TypeError, IndexError):
            continue
        avg_sum[rig] = avg_sum.get(rig, 0.0) + v
        avg_cnt[rig] = avg_cnt.get(rig, 0) + 1

    out = {}
    for rig in set(max_by_rig) | set(avg_sum):
        out[rig] = {
            "max_temp_c": round(max_by_rig[rig], 1) if rig in max_by_rig else None,
            "avg_temp_c": round(avg_sum[rig] / avg_cnt[rig], 1) if avg_cnt.get(rig) else None,
        }
    return out


def _price_changes_by_rig(prom_url, day_start_ts, day_end_ts):
    """How many times each rig's listing price actually moved during the
    day — counted via changes() over the existing gauge, per machine, summed
    per rig. Not a proxy for "alerts", just a straightforward activity count."""
    window_s = int(day_end_ts - day_start_ts)
    try:
        results = prom_client.query_instant(prom_url, f"changes(listing_price_dollars_per_hour[{window_s}s])", at=day_end_ts)
    except Exception:
        results = []
    out = {}
    for r in results:
        rig = r.get("metric", {}).get("rig")
        if rig is None:
            continue
        try:
            v = int(float(r["value"][1]))
        except (KeyError, ValueError, TypeError, IndexError):
            continue
        out[rig] = out.get(rig, 0) + v
    return out


def get_previous_day_summary(prom_url, now_ts=None, date_str=None):
    day_start, day_end = _day_bounds(date_str, now_ts)
    date_str = day_start.strftime("%Y-%m-%d")
    day_start_ts, day_end_ts = day_start.timestamp(), day_end.timestamp()

    revenue = _revenue_by_rig(prom_url, day_start, day_end, date_str)
    electricity = _electricity_by_rig(prom_url, day_start_ts, day_end_ts)
    temps = _temps_by_rig(prom_url, day_start_ts, day_end_ts)
    price_changes = _price_changes_by_rig(prom_url, day_start_ts, day_end_ts)

    try:
        occupancy = occupancy_api.get_occupancy(prom_url, window_hours=24, now_ts=day_end_ts)
    except Exception:
        occupancy = {"per_rig": {}, "fleet": {}}
    occ_per_rig = occupancy.get("per_rig", {})

    rigs_seen = set(revenue) | set(electricity) | set(temps) | set(price_changes) | set(occ_per_rig)
    rigs = {}
    for rig in rigs_seen:
        rev = revenue.get(rig, 0.0)
        elec = electricity.get(rig, 0.0)
        occ = occ_per_rig.get(rig, {})
        temp = temps.get(rig, {})
        rigs[rig] = {
            "revenue": round(rev, 2),
            "electricity": round(elec, 2),
            "profit": round(rev - elec, 2),
            "gpus": occ.get("gpus"),
            "occupancy_pct": occ.get("occupancy_pct"),
            "idle_hours": occ.get("idle_hours"),
            "estimated_lost_revenue": occ.get("estimated_lost_revenue"),
            "max_temp_c": temp.get("max_temp_c"),
            "avg_temp_c": temp.get("avg_temp_c"),
            "price_changes": price_changes.get(rig, 0),
        }

    fleet_revenue = sum(v["revenue"] for v in rigs.values())
    fleet_elec = sum(v["electricity"] for v in rigs.values())
    fleet_max_temp = max((v["max_temp_c"] for v in rigs.values() if v["max_temp_c"] is not None), default=None)
    fleet_price_changes = sum(v["price_changes"] for v in rigs.values())
    fleet_occ = occupancy.get("fleet", {})

    fleet = {
        "revenue": round(fleet_revenue, 2),
        "electricity": round(fleet_elec, 2),
        "profit": round(fleet_revenue - fleet_elec, 2),
        "gpus": fleet_occ.get("gpus"),
        "occupancy_pct": fleet_occ.get("occupancy_pct"),
        "idle_hours": fleet_occ.get("idle_hours"),
        "estimated_lost_revenue": fleet_occ.get("estimated_lost_revenue"),
        "max_temp_c": fleet_max_temp,
        "price_changes": fleet_price_changes,
    }

    return {
        "date": date_str,
        "rigs": rigs,
        "fleet": fleet,
    }


def handle_daily_summary_request(prom_url, now_ts=None, date_str=None):
    return get_previous_day_summary(prom_url, now_ts, date_str)
