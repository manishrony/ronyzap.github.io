#!/usr/bin/env python3
"""Paginated historical queries against the central Prometheus (hub only).

Only meaningful on the hub rig, where Prometheus actually runs and scrapes
every rig's /metrics — that's the whole point of the central-Prometheus
design (one place to query all three rigs' history, not three). On a
standalone (non-hub) rig this will just fail to connect, which is expected.

Deliberately re-implemented as a thin, allow-listed proxy rather than passing
raw PromQL through from the browser: this dashboard has no auth in front of
it (same posture as /api/data and /api/chat elsewhere in this file), so query
params are validated before ever reaching a query string.
"""
import re
import prom_client

# Metric name -> whether it's an aggregatable numeric series worth averaging
# over the step window (avg_over_time) vs. a 0/1 state flag worth taking the
# max of over the window (so a brief "rented" blip doesn't get averaged away
# to 0.3 and become meaningless — pagination steps can span many samples).
_METRICS = {
    "gpu_temp_celsius": "avg",
    "gpu_power_draw_watts": "avg",
    "gpu_power_limit_watts": "avg",
    "gpu_fan_percent": "avg",
    "gpu_util_percent": "avg",
    "machine_rental_rate_dollars_per_hour": "avg",
    "machine_earn_day_dollars": "avg",
    "market_price_dollars_per_hour": "avg",
    "listing_price_dollars_per_hour": "avg",
    "listing_target_dollars_per_hour": "avg",
    "rig_daily_earnings_dollars": "avg",
    "machine_rented": "max",
    "gpu_slot_rented": "max",
}

_LABEL_RE = re.compile(r'^[A-Za-z0-9_.:-]+$')


def metric_names():
    """Public accessor for the allow-listed metric names — so other modules
    (assistant.py's tool schema) don't reach into the "private" _METRICS
    dict directly."""
    return list(_METRICS)


def _safe_label(v):
    if v is None or not _LABEL_RE.match(v):
        return None
    return v.replace('"', '')


def build_query(metric, rig=None, machine_id=None, gpu_idx=None, window_s=3600):
    if metric not in _METRICS:
        raise ValueError(f"unknown metric '{metric}'")
    matchers = []
    for label, val in (("rig", rig), ("machine_id", machine_id), ("gpu_idx", gpu_idx)):
        if val is None:
            continue
        safe = _safe_label(str(val))
        if safe is None:
            raise ValueError(f"invalid value for label '{label}'")
        matchers.append(f'{label}="{safe}"')
    selector = metric + ("{" + ",".join(matchers) + "}" if matchers else "")
    agg = _METRICS[metric]
    return f"{agg}_over_time({selector}[{int(window_s)}s])"


def list_rigs(prom_url):
    """Actual `rig` label values Prometheus has seen — NOT the display names
    from /api/config. Those come from SELF_NAME/PEER_NAMES, which an operator
    can set to anything ("Zappa1") independent of the hostname the exporter
    actually labels metrics with; using the config names for the History
    dropdown would let a rig's display name silently stop matching its own
    data (confirmed happening: Zappa1's SELF_NAME vs. its hostname label)."""
    return prom_client.label_values(prom_url, "rig")


def handle_history_request(prom_url, query_params, now_ts):
    """query_params: dict of str -> list[str] (as from urllib.parse.parse_qs).
    now_ts: current unix time (injected so this stays testable without mocking time.time())."""
    def _get(name, default=None):
        v = query_params.get(name)
        return v[0] if v else default

    metric = _get("metric")
    if not metric:
        return {"error": "missing required 'metric' param",
                "available_metrics": sorted(_METRICS)}
    rig = _get("rig")
    machine_id = _get("machine_id")
    gpu_idx = _get("gpu_idx")
    hours = max(1, min(24 * 90, int(_get("hours", 24))))
    page = max(0, int(_get("page", 0)))
    points_target = max(10, min(2000, int(_get("points", 200))))

    window_s = hours * 3600
    end = int(now_ts) - page * window_s
    start = end - window_s
    step = max(1, window_s // points_target)

    query = build_query(metric, rig, machine_id, gpu_idx, window_s=step)
    result = prom_client.query_range(prom_url, query, start, end, step)

    return {
        "metric": metric,
        "rig": rig,
        "machine_id": machine_id,
        "gpu_idx": gpu_idx,
        "page": page,
        "hours": hours,
        "start": start,
        "end": end,
        "step": step,
        "result": result,
    }
