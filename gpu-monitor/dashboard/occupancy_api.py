#!/usr/bin/env python3
"""Occupancy analytics from the central Prometheus (hub only).

Answers "how much of the fleet's GPU-time is actually rented vs. idle" —
per-GPU-slot occupancy % over a selectable window, plus an estimated dollar
cost of the idle time (idle hours x that machine's own average listing/ask
price during the window — a conservative "what we were actually offering
it for," not an optimistic market-rate assumption).

Like history_api.py/profit_api.py, this only ever runs a small, fixed set
of hardcoded PromQL queries — never raw PromQL from the browser — since
this dashboard has no auth in front of it.
"""
import prom_client


def get_occupancy(prom_url, window_hours=24, now_ts=None):
    window_hours = max(1, min(24 * 90, window_hours))
    window_s = int(window_hours * 3600)
    at = now_ts

    # avg(gpu_slot_rented) over the window, per (rig, machine_id, gpu_idx) —
    # the fraction of the window each slot was actually rented.
    slot_results = prom_client.query_instant(prom_url, f"avg_over_time(gpu_slot_rented[{window_s}s])", at=at)
    # avg(listing_price_dollars_per_hour) over the same window, per
    # (rig, machine_id) — what we were actually asking during idle stretches,
    # used to price the idle time rather than assuming market rate.
    price_results = prom_client.query_instant(prom_url, f"avg_over_time(listing_price_dollars_per_hour[{window_s}s])", at=at)
    listing_by_machine = prom_client.group_by_labels(price_results, ("rig", "machine_id"))

    per_slot = []
    rig_totals = {}
    for r in slot_results:
        metric = r.get("metric", {})
        rig = metric.get("rig")
        mid = metric.get("machine_id")
        gidx = metric.get("gpu_idx")
        if rig is None or mid is None or gidx is None:
            continue
        try:
            occ_frac = float(r["value"][1])
        except (KeyError, ValueError, TypeError, IndexError):
            continue

        idle_frac = 1.0 - occ_frac
        occ_hours = occ_frac * window_hours
        idle_hours = idle_frac * window_hours
        rate = listing_by_machine.get((rig, mid), 0.0)
        lost_revenue = idle_hours * rate

        per_slot.append({
            "rig": rig,
            "machine_id": mid,
            "gpu_idx": gidx,
            "occupancy_pct": round(occ_frac * 100, 1),
            "occupied_hours": round(occ_hours, 2),
            "idle_hours": round(idle_hours, 2),
            "estimated_lost_revenue": round(lost_revenue, 2),
        })

        t = rig_totals.setdefault(rig, {"gpus": 0, "occupied_hours": 0.0, "idle_hours": 0.0, "estimated_lost_revenue": 0.0})
        t["gpus"] += 1
        t["occupied_hours"] += occ_hours
        t["idle_hours"] += idle_hours
        t["estimated_lost_revenue"] += lost_revenue

    per_rig = {}
    for rig, t in rig_totals.items():
        total_hours = t["gpus"] * window_hours
        per_rig[rig] = {
            "gpus": t["gpus"],
            "occupancy_pct": round(t["occupied_hours"] / total_hours * 100, 1) if total_hours else None,
            "occupied_hours": round(t["occupied_hours"], 2),
            "idle_hours": round(t["idle_hours"], 2),
            "estimated_lost_revenue": round(t["estimated_lost_revenue"], 2),
        }

    fleet_gpus = sum(t["gpus"] for t in rig_totals.values())
    fleet_occ_hours = sum(t["occupied_hours"] for t in rig_totals.values())
    fleet_idle_hours = sum(t["idle_hours"] for t in rig_totals.values())
    fleet_lost = sum(t["estimated_lost_revenue"] for t in rig_totals.values())
    fleet_total_hours = fleet_gpus * window_hours

    fleet = {
        "gpus": fleet_gpus,
        "occupancy_pct": round(fleet_occ_hours / fleet_total_hours * 100, 1) if fleet_total_hours else None,
        "occupied_hours": round(fleet_occ_hours, 2),
        "idle_hours": round(fleet_idle_hours, 2),
        "estimated_lost_revenue": round(fleet_lost, 2),
    }

    per_slot.sort(key=lambda s: (s["rig"], s["machine_id"], s["gpu_idx"]))
    return {
        "window_hours": window_hours,
        "per_slot": per_slot,
        "per_rig": per_rig,
        "fleet": fleet,
    }


def handle_occupancy_request(prom_url, query_params, now_ts=None):
    def _get(name, default=None):
        v = query_params.get(name)
        return v[0] if v else default

    try:
        hours = int(_get("hours", 24))
    except (TypeError, ValueError):
        hours = 24
    return get_occupancy(prom_url, window_hours=hours, now_ts=now_ts)
