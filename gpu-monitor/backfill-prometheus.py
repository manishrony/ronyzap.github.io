#!/usr/bin/env python3
"""One-off: convert this rig's history (gpu_monitor_data.jsonl + gpu_monitor.log,
including rotated .gz files) into an OpenMetrics file with real historical
timestamps, for import into Prometheus via `promtool tsdb create-blocks-from
openmetrics`. Best-effort: log granularity itself changed over time (hourly
early on, 5-min more recently), and some fields carry known inaccuracies from
before this session's fixes (see RIGS.md) — this reconstructs whatever is
actually recoverable from the existing files, nothing more.

Usage (run once, PER RIG, on that rig):
    python3 backfill-prometheus.py --rig zappa1 \
        --jsonl /var/log/gpu_monitor_data.jsonl \
        --log-glob '/var/log/gpu_monitor.log*' \
        --out /tmp/zappa1-backfill.om

Then, on the hub (where Prometheus actually runs), for each rig's .om file:
    promtool tsdb create-blocks-from openmetrics /tmp/<rig>-backfill.om /tmp/<rig>-blocks
    sudo systemctl stop prometheus
    sudo cp -r /tmp/<rig>-blocks/* /var/lib/prometheus/metrics2/
    sudo chown -R prometheus:prometheus /var/lib/prometheus/metrics2
    sudo systemctl start prometheus

(/var/lib/prometheus/metrics2/ is the Debian/Ubuntu 'prometheus' package's
default --storage.tsdb.path — confirm with `prometheus --help` if a future
OS/package version changes it.)

See RIGS.md's "Prometheus / historical backfill" section for the full runbook.
"""
import argparse
import glob
import gzip
import json
import re
import sys
from datetime import datetime, timezone

_RATE_RE = re.compile(r'[-+]?\d*\.?\d+')
_LOGLINE_RE = re.compile(
    r'^\[(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\s+'
    r'GPU (?P<idx>\d+) \| (?P<name>[^|]+?) \| '
    r'Temp: (?P<temp>-?\d+(?:\.\d+)?)°?C? \| '
    r'Power: (?P<power_draw>-?\d+(?:\.\d+)?)W/(?P<power_limit>-?\d+(?:\.\d+)?)W \| '
    r'Fan: (?P<fan>-?\d+(?:\.\d+)?)% \| '
    r'Util: (?P<util>-?\d+(?:\.\d+)?)%'
    r'(?: \| Proc: (?P<proc>.+))?$'
)


def _to_float(s, default=0.0):
    if s is None:
        return default
    if isinstance(s, (int, float)):
        return float(s)
    m = _RATE_RE.search(str(s))
    return float(m.group()) if m else default


def _parse_iso(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _open_maybe_gz(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", errors="replace")
    return open(path, errors="replace")


class OMWriter:
    """Accumulates (name -> [(labels_dict, value, epoch)]) and emits valid
    OpenMetrics text (TYPE/HELP grouped per metric, samples sorted by time,
    trailing '# EOF' as OpenMetrics requires)."""

    def __init__(self):
        self._order = []
        self._meta = {}
        self._samples = {}

    def add(self, name, mtype, help_text, labels, value, epoch):
        if value is None or epoch is None:
            return
        if name not in self._meta:
            self._meta[name] = (mtype, help_text)
            self._samples[name] = []
            self._order.append(name)
        self._samples[name].append((labels, value, epoch))

    def write(self, fh):
        for name in self._order:
            mtype, help_text = self._meta[name]
            fh.write(f"# HELP {name} {help_text}\n")
            fh.write(f"# TYPE {name} {mtype}\n")
            for labels, value, epoch in sorted(self._samples[name], key=lambda s: s[2]):
                label_str = ",".join(f'{k}="{str(v)}"' for k, v in labels.items())
                fh.write(f"{name}{{{label_str}}} {value} {int(epoch)}\n")
        fh.write("# EOF\n")


def collect_gpu_samples_from_jsonl(jsonl_paths, rig):
    """gpu_status events -> per-(gpu_idx) list of (epoch, fields)."""
    samples = {}  # gpu_idx -> {epoch: fields}
    for path in jsonl_paths:
        try:
            fh = _open_maybe_gz(path)
        except FileNotFoundError:
            continue
        with fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                if ev.get("type") != "gpu_status":
                    continue
                epoch = _parse_iso(ev.get("ts", ""))
                if epoch is None:
                    continue
                for g in ev.get("gpus", []):
                    idx = g.get("idx")
                    if idx is None:
                        continue
                    samples.setdefault(idx, {})[int(epoch)] = {
                        "name": g.get("name", ""),
                        "temp": _to_float(g.get("temp")),
                        "power_draw": _to_float(g.get("power_draw")),
                        "power_limit": _to_float(g.get("power_limit")),
                        "fan": _to_float(g.get("fan")),
                        "util": _to_float(g.get("util")),
                        "proc": g.get("proc") or "",
                    }
    return samples


def collect_gpu_samples_from_log(log_paths):
    """Free-text 'GPU N | name | Temp: ... | Power: .../...W | Fan: ...% |
    Util: ...%[ | Proc: ...]' lines -> per-(gpu_idx) list of (epoch, fields).
    Supplements the JSONL for periods/hosts where gpu_status wasn't (yet)
    being written, or as extra density."""
    samples = {}
    for path in log_paths:
        try:
            fh = _open_maybe_gz(path)
        except FileNotFoundError:
            continue
        with fh:
            for line in fh:
                m = _LOGLINE_RE.match(line)
                if not m:
                    continue
                try:
                    dt = datetime.strptime(m.group("ts"), "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
                except Exception:
                    continue
                epoch = int(dt.timestamp())
                idx = int(m.group("idx"))
                samples.setdefault(idx, {})[epoch] = {
                    "name": m.group("name").strip(),
                    "temp": _to_float(m.group("temp")),
                    "power_draw": _to_float(m.group("power_draw")),
                    "power_limit": _to_float(m.group("power_limit")),
                    "fan": _to_float(m.group("fan")),
                    "util": _to_float(m.group("util")),
                    "proc": (m.group("proc") or "").strip(),
                }
    return samples


def collect_event_samples(jsonl_paths, event_type):
    out = []
    for path in jsonl_paths:
        try:
            fh = _open_maybe_gz(path)
        except FileNotFoundError:
            continue
        with fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                if ev.get("type") != event_type:
                    continue
                epoch = _parse_iso(ev.get("ts", ""))
                if epoch is None:
                    continue
                out.append((epoch, ev))
    return out


def build(rig, jsonl_paths, log_paths, out_path):
    w = OMWriter()

    # --- Per-GPU gauges: merge log-derived + JSONL-derived, JSONL wins on
    # an exact-second conflict since it's structured (more precise than a
    # regex over free text). ---
    from_log = collect_gpu_samples_from_log(log_paths)
    from_jsonl = collect_gpu_samples_from_jsonl(jsonl_paths, rig)
    merged = {}
    for idx, by_epoch in from_log.items():
        merged.setdefault(idx, {}).update(by_epoch)
    for idx, by_epoch in from_jsonl.items():
        merged.setdefault(idx, {}).update(by_epoch)  # JSONL overwrites same-second log entry

    gpu_count = 0
    sample_count = 0
    for idx, by_epoch in merged.items():
        gpu_count += 1
        for epoch, f in by_epoch.items():
            labels = {"rig": rig, "gpu_idx": idx, "gpu_name": f["name"]}
            w.add("gpu_temp_celsius", "gauge", "Current GPU core temperature.", labels, f["temp"], epoch)
            w.add("gpu_power_draw_watts", "gauge", "Current GPU power draw.", labels, f["power_draw"], epoch)
            w.add("gpu_power_limit_watts", "gauge", "Current GPU power cap.", labels, f["power_limit"], epoch)
            w.add("gpu_fan_percent", "gauge", "Current GPU fan speed.", labels, f["fan"], epoch)
            w.add("gpu_util_percent", "gauge", "Current GPU compute utilization.", labels, f["util"], epoch)
            sample_count += 5

    # --- Rental/pricing/market/earnings history straight from JSONL (no
    # free-text fallback attempted for these — the log's prose form isn't
    # worth the parsing risk for best-effort backfill). ---
    for epoch, ev in collect_event_samples(jsonl_paths, "market_snapshot"):
        mid = str(ev.get("machine_id", ""))
        if not mid:
            continue
        for stat in ("p25", "median", "p75", "mean"):
            v = ev.get(stat)
            if v is not None:
                w.add("market_price_dollars_per_hour", "gauge",
                      "Comparable-listing market stat for this GPU model, fee-discounted.",
                      {"rig": rig, "machine_id": mid, "stat": stat}, _to_float(v), epoch)
                sample_count += 1

    for epoch, ev in collect_event_samples(jsonl_paths, "price_change"):
        mid = str(ev.get("machine_id", ""))
        if not mid:
            continue
        if ev.get("new_price") is not None:
            w.add("listing_price_dollars_per_hour", "gauge", "This machine's listing (ask) price at the time.",
                  {"rig": rig, "machine_id": mid}, _to_float(ev.get("new_price")), epoch)
            sample_count += 1
        if ev.get("target_value") is not None:
            w.add("listing_target_dollars_per_hour", "gauge",
                  "The market stat value vastai_pricing() was targeting (see target_stat label).",
                  {"rig": rig, "machine_id": mid, "target_stat": ev.get("target_stat", "median")},
                  _to_float(ev.get("target_value")), epoch)
            sample_count += 1

    for epoch, ev in collect_event_samples(jsonl_paths, "daily_earnings"):
        if ev.get("source") != "vast_api":
            continue
        w.add("rig_daily_earnings_dollars", "gauge", "Vast's own daily_earnings total for that date.",
              {"rig": rig, "date": ev.get("date", "")}, _to_float(ev.get("total")), epoch)
        sample_count += 1

    with open(out_path, "w") as fh:
        w.write(fh)

    print(f"[backfill] rig={rig}: {gpu_count} GPU(s), {sample_count} samples written to {out_path}")
    print(f"[backfill] Next: promtool tsdb create-blocks-from openmetrics {out_path} <blocks-dir>")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rig", required=True, help="Rig name label (e.g. zappa1)")
    ap.add_argument("--jsonl", default="/var/log/gpu_monitor_data.jsonl",
                     help="Path (or glob) to gpu_monitor_data.jsonl")
    ap.add_argument("--log-glob", default="/var/log/gpu_monitor.log*",
                     help="Glob matching gpu_monitor.log + any rotated/.gz siblings")
    ap.add_argument("--out", required=True, help="Output .om (OpenMetrics) file path")
    args = ap.parse_args()

    jsonl_paths = sorted(glob.glob(args.jsonl)) or [args.jsonl]
    log_paths = sorted(glob.glob(args.log_glob))
    if not log_paths:
        print(f"[backfill] WARNING: no files matched --log-glob '{args.log_glob}'", file=sys.stderr)

    build(args.rig, jsonl_paths, log_paths, args.out)


if __name__ == "__main__":
    main()
