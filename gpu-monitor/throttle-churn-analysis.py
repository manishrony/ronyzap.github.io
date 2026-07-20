#!/usr/bin/env python3
"""One-off analysis: does a workload_throttle "on" event on this rig correlate
with a rental ending sooner than usual? Answers the "do throttled miners not
come back" question with this rig's own history instead of guessing.

Reads the local gpu_monitor_data.jsonl (each rig's own event log — no `host`
field needed, every event in it already belongs to this rig) and correlates:
  - each workload_throttle {"state":"on"} event
against:
  - the next rental_end event on this rig after it
  - a baseline of ordinary rental_start -> rental_end durations fleet-wide,
    for comparison

Known limitation, stated up front rather than hidden: rental_end's own
"gpus" field is a count/model string (e.g. "2x RTX 5090"), not specific GPU
indices — gpu_monitor.sh never wrote per-GPU-index granularity into that
event type. So this can only show "some rental ended on this machine
this soon after a throttle event", not prove the SAME renter's SAME GPU
was the one that left. Still a real, fleet-specific signal — just not
100% attribution.

Also flags events before/after 2026-07-20 separately: the workload throttle
was RIG-WIDE (a confirmed bug — see RIGS.md) until that day's per-GPU fix,
and the grace period + idle-debounce (the parts most relevant to "does
throttling scare a miner off") only went live that same evening. Mixing
pre- and post-fix events together would blend two different mechanisms
into one misleading number.

Usage:
    python3 throttle-churn-analysis.py [--file /var/log/gpu_monitor_data.jsonl]
"""
import argparse
import datetime
import json
import sys

CUTOVER = datetime.datetime(2026, 7, 20, 18, 0, 0, tzinfo=datetime.timezone.utc)


def _parse_ts(ts):
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (ValueError, TypeError):
        return None


def load_events(path):
    throttle_on, throttle_off, rental_start, rental_end = [], [], [], []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            dt = _parse_ts(e.get("ts"))
            if dt is None:
                continue
            etype = e.get("type")
            if etype == "workload_throttle":
                if e.get("state") == "on":
                    throttle_on.append((dt, e.get("gpus", ""), e.get("source", "named"), e.get("types", "")))
                elif e.get("state") == "off":
                    throttle_off.append(dt)
            elif etype == "rental_start":
                rental_start.append((dt, e.get("gpus", ""), e.get("rate", "")))
            elif etype == "rental_end":
                rental_end.append((dt, e.get("gpus", ""), e.get("rate", "")))
    throttle_on.sort(key=lambda x: x[0])
    throttle_off.sort()
    rental_start.sort(key=lambda x: x[0])
    rental_end.sort(key=lambda x: x[0])
    return throttle_on, throttle_off, rental_start, rental_end


def _next_after(dt, items, key=lambda x: x):
    for item in items:
        if key(item) > dt:
            return item
    return None


def baseline_durations(rental_start, rental_end):
    durations_hours = []
    used_ends = set()
    for s_dt, s_gpus, _ in rental_start:
        for i, (e_dt, e_gpus, _) in enumerate(rental_end):
            if i in used_ends or e_dt <= s_dt:
                continue
            used_ends.add(i)
            durations_hours.append((e_dt - s_dt).total_seconds() / 3600.0)
            break
    return sorted(durations_hours)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", default="/var/log/gpu_monitor_data.jsonl", help="Path to this rig's event log")
    args = ap.parse_args()

    try:
        throttle_on, throttle_off, rental_start, rental_end = load_events(args.file)
    except FileNotFoundError:
        print(f"error: {args.file} not found", file=sys.stderr)
        sys.exit(1)

    print(f"Loaded: {len(throttle_on)} throttle-on, {len(throttle_off)} throttle-off, "
          f"{len(rental_start)} rental_start, {len(rental_end)} rental_end events\n")

    if not throttle_on:
        print("No workload_throttle 'on' events in this log — nothing to correlate. "
              "This rig hasn't had a mining/cracking rental throttled yet.")
        return

    durations = baseline_durations(rental_start, rental_end)
    if durations:
        median = durations[len(durations) // 2]
        print(f"Baseline: {len(durations)} ordinary rental_start->rental_end pairs, "
              f"median duration {median:.1f}h (range {durations[0]:.1f}h - {durations[-1]:.1f}h)\n")
    else:
        print("Baseline: no complete rental_start->rental_end pairs found to compare against.\n")

    print("Time from each throttle-on event to the NEXT rental ending on this rig:")
    print("(pre-2026-07-20 18:00 UTC events are marked LEGACY -- that's the confirmed")
    print(" rig-wide throttle bug, not the current per-GPU + grace-period behavior --")
    print(" interpret those separately, they're a different mechanism entirely)\n")

    for dt, gpus, source, types in throttle_on:
        era = "LEGACY (rig-wide bug)" if dt < CUTOVER else "current (per-GPU + grace period)"
        nxt = _next_after(dt, rental_end, key=lambda x: x[0])
        off = _next_after(dt, throttle_off)
        off_str = f", throttle itself cleared after {(off - dt).total_seconds()/60:.0f}m" if off else ""
        if nxt:
            gap_h = (nxt[0] - dt).total_seconds() / 3600.0
            flag = " <-- shorter than baseline median" if durations and gap_h < (durations[len(durations)//2]) else ""
            print(f"  [{era}] {dt.strftime('%Y-%m-%d %H:%M')} throttled (gpus {gpus or '?'}) "
                  f"-> rental ended {gap_h:.1f}h later{off_str}{flag}")
        else:
            print(f"  [{era}] {dt.strftime('%Y-%m-%d %H:%M')} throttled (gpus {gpus or '?'}) "
                  f"-> no rental_end after this yet in the log{off_str}")

    print("\nRead this as a signal, not proof: rental_end doesn't carry which exact GPU")
    print("ended (only a count/model string), so a short gap could be an unrelated")
    print("tenant on a different GPU ending on ordinary schedule, not the throttled")
    print("renter specifically leaving. If most current-era rows show gaps close to")
    print("or above the baseline median, that argues against the 'miners flee' worry;")
    print("if they cluster far below it, that's worth taking seriously.")


if __name__ == "__main__":
    main()
