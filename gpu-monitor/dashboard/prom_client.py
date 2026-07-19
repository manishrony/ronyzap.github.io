#!/usr/bin/env python3
"""Tiny shared HTTP client for querying the central Prometheus (hub only).

Used by history_api.py, profit_api.py, and occupancy_api.py so the actual
urllib plumbing and label-grouping logic exists in exactly one place.
"""
import json
import urllib.request
import urllib.parse


def query_instant(prom_url, query, at=None):
    """GET /api/v1/query. `at` (unix epoch) evaluates at a specific instant;
    omit for "now" (Prometheus's own server time)."""
    params = {"query": query}
    if at is not None:
        params["time"] = at
    qs = urllib.parse.urlencode(params)
    url = f"{prom_url.rstrip('/')}/api/v1/query?{qs}"
    with urllib.request.urlopen(url, timeout=10) as resp:
        data = json.loads(resp.read())
    return data.get("data", {}).get("result", [])


def query_range(prom_url, query, start, end, step):
    """GET /api/v1/query_range. Returns the raw {resultType, result} dict
    (callers want the matrix shape, not a flattened list, unlike query_instant)."""
    qs = urllib.parse.urlencode({"query": query, "start": start, "end": end, "step": step})
    url = f"{prom_url.rstrip('/')}/api/v1/query_range?{qs}"
    with urllib.request.urlopen(url, timeout=10) as resp:
        data = json.loads(resp.read())
    return data.get("data", {})


def label_values(prom_url, label):
    """GET /api/v1/label/<label>/values -> sorted list of strings."""
    url = f"{prom_url.rstrip('/')}/api/v1/label/{label}/values"
    with urllib.request.urlopen(url, timeout=10) as resp:
        data = json.loads(resp.read())
    return sorted(data.get("data", []))


def group_by_label(results, label):
    """[{"metric": {label: ..., ...}, "value": [ts, "123"]}] -> {label_value:
    float(value)}. Silently drops entries missing the label or an
    unparseable value (defensive default matching the rest of this codebase
    — a partial result beats a hard failure on one bad sample)."""
    out = {}
    for r in results:
        key = r.get("metric", {}).get(label)
        if key is None:
            continue
        try:
            out[key] = float(r["value"][1])
        except (KeyError, ValueError, TypeError, IndexError):
            pass
    return out


def group_by_labels(results, labels):
    """Like group_by_label but keys on a tuple of multiple label values —
    e.g. (rig, machine_id) — for series that need more than one label to
    identify uniquely."""
    out = {}
    for r in results:
        metric = r.get("metric", {})
        key = tuple(metric.get(l) for l in labels)
        if None in key:
            continue
        try:
            out[key] = float(r["value"][1])
        except (KeyError, ValueError, TypeError, IndexError):
            pass
    return out


def range_by_series(prom_url, query, start_ts, end_ts, step_s, label_keys):
    """query_range wrapper for callers that walk a metric's actual value
    history point-by-point (edge/threshold detection, time-weighted
    integrals) rather than just reading the matrix shape. Returns
    {label-tuple: [(ts, float value), ...]} for every series touched by the
    range, sorted by timestamp (query_range already returns them that way,
    but sort defensively). Used by events_api.py and health_api.py so the
    walk-the-samples logic exists in one place, not two."""
    data = query_range(prom_url, query, start_ts, end_ts, step_s)
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
