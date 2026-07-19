#!/usr/bin/env python3
"""Pricing Advisor (hub only): per-machine listing price vs. market
recommendation, from the central Prometheus.

gpu_monitor.sh's vastai_pricing() already auto-prices every machine toward
a configurable market stat (PRICE_TARGET_STAT, default median) every
GPU_CHECK_INTERVAL — see RIGS.md's "Pricing target" section. This is NOT a
second pricing engine or a replacement for that automation; it answers a
different question: given the occupancy actually observed at the current
price, does the number the automation converged on look right, or does the
demand signal disagree with it? A machine sitting at 90%+ occupancy priced
at/below the target stat is leaving money on the table (raise it); a
machine sitting well below 50% occupancy priced above the target stat
suggests the price itself is the problem (lower it); a machine with low
occupancy that's ALREADY priced at or below target isn't a pricing problem
at all (something else is keeping it empty — worth a look, but not a price
change). Rule-based and transparent on purpose, not a black-box score.

Never writes anything back to Vast — this dashboard has no auth in front
of it and no write path to the rental API. Recommendations are advisory
text plus a suggested number for a human to act on manually (e.g. via
gpu_monitor.conf's PRICE_TARGET_STAT, or a one-off manual price edit).

Like history_api.py/profit_api.py/occupancy_api.py/events_api.py/
health_api.py, this only ever runs a small, fixed set of hardcoded PromQL
queries — never raw PromQL from the browser — since this dashboard has no
auth in front of it.
"""
import time
import prom_client

OCCUPANCY_WINDOW_HOURS = 24 * 7  # 7 days — long enough to smooth out normal rental churn


def _latest_by_key(prom_url, query, label_keys, at=None):
    try:
        results = prom_client.query_instant(prom_url, query, at=at)
    except Exception:
        return {}
    out = {}
    for r in results:
        metric = r.get("metric", {})
        key = tuple(metric.get(k) for k in label_keys)
        if None in key:
            continue
        try:
            out[key] = float(r["value"][1])
        except (KeyError, ValueError, TypeError, IndexError):
            continue
    return out


def _occupancy_by_machine(prom_url, window_hours, at=None):
    """Per-machine occupancy % — averaged across that machine's own GPU
    slots (listing price is set per machine, not per GPU, so the
    recommendation needs a per-machine figure, unlike occupancy_api.py's
    per-rig aggregation)."""
    window_s = int(window_hours * 3600)
    try:
        results = prom_client.query_instant(prom_url, f"avg_over_time(gpu_slot_rented[{window_s}s])", at=at)
    except Exception:
        results = []
    sums, counts = {}, {}
    for r in results:
        metric = r.get("metric", {})
        key = (metric.get("rig"), metric.get("machine_id"))
        if None in key:
            continue
        try:
            v = float(r["value"][1])
        except (KeyError, ValueError, TypeError, IndexError):
            continue
        sums[key] = sums.get(key, 0.0) + v
        counts[key] = counts.get(key, 0) + 1
    return {k: (sums[k] / counts[k]) * 100 for k in sums}


def _current_idle_hours(prom_url, window_hours, now_ts=None):
    """Hours since each machine last had EVERY GPU slot rented — i.e. how
    long it's had at least one slot free to sell, mirroring
    gpu_monitor.sh's own vacancy_file semantics exactly (that clock starts
    the instant free_count > 0 and only clears once free_count == 0 again;
    see vastai_pricing()). Deliberately MIN across a machine's slots, not
    MAX: a 2-GPU machine with one slot rented and one sitting empty is
    still "idle" for pricing purposes (that's the whole reason idle mode
    exists — to re-attract renters for the free slot) — using MAX here
    would report it as fully occupied and hide the free slot entirely.
    Confirmed wrong the other way live on zappa1 (2026-07-19): machine
    138419's second RTX 5090 had been unrented for hours per Vast's own
    dashboard while this function's MAX-based first version reported
    idle_hours ~0 because slot 0 was rented.

    0 (or close to it) if every slot is currently rented. None if it's had
    a free slot for the entire lookback window — long enough that we can't
    tell exactly how much longer, only that it's at least window_hours."""
    now = now_ts if now_ts is not None else time.time()
    window_s = int(window_hours * 3600)
    step = max(300, window_s // 500)
    try:
        series = prom_client.range_by_series(
            prom_url, "min by(rig, machine_id)(gpu_slot_rented)",
            now - window_s, now, step, ("rig", "machine_id"))
    except Exception:
        return {}
    out = {}
    for key, pts in series.items():
        last_rented_ts = None
        for ts, v in pts:
            if v >= 0.5:
                last_rented_ts = ts
        out[key] = round(max(0.0, now - last_rented_ts) / 3600.0, 1) if last_rented_ts is not None else None
    return out


def _recommend(price, median, p25, p75, occ_pct, floor, idle_hours=None):
    """Rule-based, transparent recommendation — no hidden weights. Missing
    occupancy or market data degrades gracefully to a plain price-vs-market
    comparison instead of refusing to answer."""
    idle_note = f" Currently idle {idle_hours:.1f}h." if idle_hours is not None and idle_hours > 0 else ""

    if median is None or median == 0:
        return "UNKNOWN", None, "No market comparables available for this machine right now." + idle_note

    deviation_pct = (price - median) / median * 100

    if occ_pct is not None and occ_pct >= 90 and price <= median * 1.02:
        target = p75 if p75 is not None else median * 1.1
        suggested = price + (target - price) * 0.5
        return ("RAISE", suggested,
                f"Occupancy {occ_pct:.0f}% over the last 7d at a price already at/below market "
                f"median — demand is strong enough to support a higher rate." + idle_note)

    if occ_pct is not None and occ_pct < 50 and price > median * 1.05:
        target = p25 if p25 is not None else median * 0.9
        suggested = max(target + (price - target) * 0.5, floor or 0)
        return ("LOWER", suggested,
                f"Occupancy only {occ_pct:.0f}% over the last 7d while priced {deviation_pct:+.0f}% "
                f"vs. median — demand looks price-sensitive here." + idle_note)

    if occ_pct is not None and occ_pct < 50 and price <= median * 1.05:
        return ("HOLD", None,
                f"Occupancy only {occ_pct:.0f}% over the last 7d, but price is already at/below "
                f"market median — likely not a pricing problem (check machine health, listing "
                f"visibility, or market saturation instead)." + idle_note)

    # No occupancy data at all (new/never-rented machine, or a metric gap) —
    # a large price deviation here is NOT confirmed reasonable, just
    # unjudged: don't claim it looks fine when there's no signal to back
    # that up (this previously said "looks reasonable" even at +400% vs.
    # median, which is misleading — confirmed live on zappa2, 2026-07-19).
    if occ_pct is None and abs(deviation_pct) >= 25:
        return ("UNKNOWN", None,
                f"Priced {deviation_pct:+.0f}% vs. median but no occupancy data yet to judge "
                f"demand — worth a manual look, not enough signal for an automatic call." + idle_note)

    return ("HOLD", None,
            f"Priced {deviation_pct:+.0f}% vs. median" +
            (f" with {occ_pct:.0f}% occupancy over 7d" if occ_pct is not None else "") +
            " — looks reasonable, no action needed." + idle_note)


def get_recommendations(prom_url, occupancy_window_hours=None, now_ts=None):
    window_hours = occupancy_window_hours or OCCUPANCY_WINDOW_HOURS

    listing_price = _latest_by_key(prom_url, "listing_price_dollars_per_hour", ("rig", "machine_id"), at=now_ts)
    floor_price = _latest_by_key(prom_url, "listing_floor_dollars_per_hour", ("rig", "machine_id"), at=now_ts)
    target_price = _latest_by_key(prom_url, "listing_target_dollars_per_hour", ("rig", "machine_id"), at=now_ts)

    # p25/median/p75/mean market stats: one series PER stat (the `stat`
    # label), not a single series carrying all four values — grouped here
    # into {(rig, machine_id): {stat: value}}.
    market_by_stat = {}
    try:
        market_results = prom_client.query_instant(prom_url, "market_price_dollars_per_hour", at=now_ts)
    except Exception:
        market_results = []
    for r in market_results:
        metric = r.get("metric", {})
        key = (metric.get("rig"), metric.get("machine_id"))
        stat = metric.get("stat")
        if None in key or stat is None:
            continue
        try:
            v = float(r["value"][1])
        except (KeyError, ValueError, TypeError, IndexError):
            continue
        market_by_stat.setdefault(key, {})[stat] = v

    occupancy_by_machine = _occupancy_by_machine(prom_url, window_hours, at=now_ts)
    idle_hours_by_machine = _current_idle_hours(prom_url, window_hours, now_ts=now_ts)

    machines = set(listing_price) | set(market_by_stat)
    out = []
    for key in machines:
        rig, mid = key
        price = listing_price.get(key)
        market = market_by_stat.get(key, {})
        if price is None or not market:
            continue

        occ_pct = occupancy_by_machine.get(key)
        floor = floor_price.get(key)
        target_val = target_price.get(key)
        idle_hours = idle_hours_by_machine.get(key)

        recommendation, suggested_price, reason = _recommend(
            price, market.get("median"), market.get("p25"), market.get("p75"), occ_pct, floor, idle_hours)

        out.append({
            "rig": rig,
            "machine_id": mid,
            "current_price": round(price, 4),
            "floor_price": round(floor, 4) if floor is not None else None,
            "target_price": round(target_val, 4) if target_val is not None else None,
            "market": {k: round(v, 4) for k, v in market.items()},
            "occupancy_pct_7d": round(occ_pct, 1) if occ_pct is not None else None,
            "idle_hours": idle_hours,
            "recommendation": recommendation,
            "suggested_price": round(suggested_price, 4) if suggested_price is not None else None,
            "reason": reason,
        })

    out.sort(key=lambda m: (m["rig"], m["machine_id"]))
    return out


def handle_pricing_advisor_request(prom_url, query_params, now_ts=None):
    def _get(name, default=None):
        v = query_params.get(name)
        return v[0] if v else default

    try:
        hours = int(_get("hours", OCCUPANCY_WINDOW_HOURS))
    except (TypeError, ValueError):
        hours = OCCUPANCY_WINDOW_HOURS

    return {"occupancy_window_hours": hours, "machines": get_recommendations(prom_url, hours, now_ts)}
