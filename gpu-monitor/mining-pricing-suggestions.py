#!/usr/bin/env python3
"""One-off analysis: is this rig's CURRENT mining/cracking rental priced
right, given what tonight's throttle-churn analysis (throttle-churn-
analysis.py) already showed about this segment's actual behavior?

gpu_monitor.sh's own vastai_pricing() already auto-prices toward a market
stat every cycle, and the dashboard's Pricing Advisor (pricing_advisor_api.py)
already gives a general RAISE/LOWER/HOLD call from live Prometheus occupancy
data. Neither of those is workload-type-aware — they treat a mining rental
at 100% occupancy identically to an inference one. This fills that specific
gap using the same local JSONL the churn script reads, no Prometheus needed:

  - the most recent market_snapshot (my_price vs. this GPU model's real
    comparable p25/median/p75/mean from Vast's own bundles API)
  - whether MINING_THROTTLE_RATE_BYPASS has ever actually fired for this
    rig (a "bypassed" workload_throttle event means this renter has, at
    least once, already paid at/above market for this GPU model -- direct
    evidence they tolerate a competitive rate, not just a guess)
  - how long the CURRENT rental (if it's still classified mining/cracking
    and hasn't seen a rental_end) has run against the baseline median
    rental duration on this rig -- reusing the exact same "sticky renter"
    evidence throttle-churn-analysis.py surfaces

Deliberately conservative about what it claims: a POWER cap costs the
renter nothing in dollars (they just mine slower), so "they didn't leave
after being throttled" is decent evidence they'll also tolerate that. A
PRICE increase costs them real money per hour -- true price elasticity is
a different, less-proven claim, so this suggests raising toward the
market MEDIAN when the evidence is favorable, never straight to p75,
and says so explicitly rather than overstating the case.

Two things this got wrong on the first pass, fixed here after checking
against a rig with a KNOWN, confirmed-live mining rental (Zappa2's
hashcat, 2026-07-20):
  1. It trusted rental_start's `workload_type` field to decide "is this
     mining/cracking" -- that field classifies the renter's DOCKER IMAGE
     name, not the actual process running inside it. Zappa2's hashcat
     rental showed workload_type='unknown' despite gpu_monitor.sh's own
     THERMAL/WORKLOAD-THROTTLE logs confirming hashcat.bin capped to
     400W all night -- a generic/custom image name doesn't have to
     mention hashcat even when that's what's running. Now uses the
     live workload_throttle on/off/bypassed state instead (the same
     ground truth workload_throttle_active() itself acts on), applied
     to whichever machine has the freshest market_snapshot.
  2. It analyzed the latest market_snapshot for EVERY machine_id ever
     seen in the log, including machines deleted from Vast weeks ago
     (stale snapshots, some 10-17 days old) -- producing wildly
     misleading "way overpriced" numbers for listings that don't exist
     anymore. Now skips any snapshot older than STALE_SNAPSHOT_HOURS.

Usage:
    python3 mining-pricing-suggestions.py [--file /var/log/gpu_monitor_data.jsonl]
"""
import argparse
import datetime
import json
import sys

STALE_SNAPSHOT_HOURS = 4  # market_snapshot older than this = probably a deleted/inactive machine


def _parse_ts(ts):
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (ValueError, TypeError):
        return None


def _to_float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def load_events(path):
    market_snapshots = []      # (dt, event dict)
    rental_starts = []         # (dt, event dict)
    rental_ends = []           # (dt, machine_id)
    bypass_events = []         # (dt,)
    throttle_states = []       # (dt, "on"|"off"|"bypassed") -- chronological, no machine_id (see module docstring)
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
            if etype == "market_snapshot":
                market_snapshots.append((dt, e))
            elif etype == "rental_start":
                rental_starts.append((dt, e))
            elif etype == "rental_end":
                rental_ends.append((dt, e.get("machine_id")))
            elif etype == "workload_throttle":
                state = e.get("state")
                if state in ("on", "off", "bypassed"):
                    throttle_states.append((dt, state))
                if state == "bypassed":
                    bypass_events.append((dt,))
    market_snapshots.sort(key=lambda x: x[0])
    rental_starts.sort(key=lambda x: x[0])
    rental_ends.sort(key=lambda x: x[0])
    bypass_events.sort()
    throttle_states.sort(key=lambda x: x[0])
    return market_snapshots, rental_starts, rental_ends, bypass_events, throttle_states


def is_currently_mining(throttle_states, now):
    """True if the LATEST workload_throttle state (on or bypassed) is more
    recent than the latest "off" -- i.e. something is classified mining/
    cracking right now, whether or not the rate bypass is currently
    suppressing the actual power cap. No machine_id on these events (see
    module docstring), so this applies to whichever machine currently has
    the freshest market_snapshot -- a reasonable proxy since a rig
    practically has one live machine at a time."""
    latest_on, latest_off = None, None
    for dt, state in throttle_states:
        if dt > now:
            break
        if state in ("on", "bypassed"):
            latest_on = dt
        elif state == "off":
            latest_off = dt
    if latest_on is None:
        return False
    return latest_off is None or latest_on > latest_off


def baseline_median_hours(rental_starts, rental_ends):
    """Fleet-wide (all machines in this rig's log) baseline -- matches
    throttle-churn-analysis.py's approach, doesn't filter by machine_id
    since the point is "what's typical here", not per-machine precision."""
    durations = []
    used = set()
    for s_dt, _ in rental_starts:
        for i, (e_dt, _mid) in enumerate(rental_ends):
            if i in used or e_dt <= s_dt:
                continue
            used.add(i)
            durations.append((e_dt - s_dt).total_seconds() / 3600.0)
            break
    if not durations:
        return None
    durations.sort()
    return durations[len(durations) // 2]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", default="/var/log/gpu_monitor_data.jsonl", help="Path to this rig's event log")
    args = ap.parse_args()

    try:
        market_snapshots, rental_starts, rental_ends, bypass_events, throttle_states = load_events(args.file)
    except FileNotFoundError:
        print(f"error: {args.file} not found", file=sys.stderr)
        sys.exit(1)

    if not market_snapshots:
        print("No market_snapshot events in this log yet -- vastai_pricing() writes one every "
              "pricing cycle (PRICE_INTERVAL, default 30 min) as long as VASTAI_API_KEY is set. "
              "Nothing to suggest against without at least one.")
        return

    now = datetime.datetime.now(datetime.timezone.utc)

    # Most recent snapshot per machine -- usually one machine per rig, but
    # don't assume it.
    latest_by_machine = {}
    for dt, e in market_snapshots:
        mid = e.get("machine_id")
        if mid is None:
            continue
        latest_by_machine[mid] = (dt, e)

    # Current/most-recent rental per machine, and whether it's still open
    # (no rental_end after it).
    latest_start_by_machine = {}
    for dt, e in rental_starts:
        mid = e.get("machine_id")
        if mid is None:
            continue
        latest_start_by_machine[mid] = (dt, e)

    baseline_h = baseline_median_hours(rental_starts, rental_ends)
    ever_bypassed = len(bypass_events) > 0

    print(f"Loaded: {len(market_snapshots)} market_snapshot, {len(rental_starts)} rental_start, "
          f"{len(rental_ends)} rental_end, {len(bypass_events)} rate-confirmed-bypass events\n")

    stale_cutoff = datetime.timedelta(hours=STALE_SNAPSHOT_HOURS)

    for mid, (snap_dt, snap) in sorted(latest_by_machine.items()):
        age = now - snap_dt
        if age > stale_cutoff:
            print(f"Machine {mid}: latest market_snapshot is {age.total_seconds()/3600:.0f}h old "
                  f"(>{STALE_SNAPSHOT_HOURS}h) -- likely deleted/inactive, skipping.\n")
            continue

        my_price = _to_float(snap.get("my_price"))
        median = _to_float(snap.get("median"))
        p25 = _to_float(snap.get("p25"))
        p75 = _to_float(snap.get("p75"))
        mean = _to_float(snap.get("mean"))
        count = snap.get("count")
        gpu_name = snap.get("gpu_name", "?")
        num_gpus = snap.get("num_gpus", "?")

        print(f"Machine {mid} ({num_gpus}x {gpu_name}) -- market snapshot as of "
              f"{snap_dt.strftime('%Y-%m-%d %H:%M')} UTC (n={count} comparable listings):")
        if my_price is None or median is None:
            print("  Incomplete snapshot (missing my_price or median) -- skipping.\n")
            continue
        print(f"  my_price=${my_price:.3f}  p25=${p25:.3f}  median=${median:.3f}  "
              f"p75=${p75:.3f}  mean=${mean:.3f}" if p25 is not None and p75 is not None and mean is not None
              else f"  my_price=${my_price:.3f}  median=${median:.3f}")

        deviation_pct = (my_price - median) / median * 100 if median else None
        if deviation_pct is not None and abs(deviation_pct) >= 100:
            print(f"  NOTE: priced {deviation_pct:+.0f}% vs. median -- that's an extreme gap, worth "
                  f"double-checking this listing is actually live/intentional before anything else.")

        start = latest_start_by_machine.get(mid)
        is_mining_now = is_currently_mining(throttle_states, now)

        if not is_mining_now:
            workload_type = start[1].get("workload_type") if start else None
            print(f"  Not currently classified mining/cracking (last known rental workload_type="
                  f"{workload_type!r}) -- this analysis doesn't apply right now. Use the dashboard's "
                  f"general Pricing Advisor instead.\n")
            continue

        rental_age_h = None
        if start:
            s_dt = start[0]
            # still open if no rental_end for THIS machine after this start
            still_open = not any(e_dt > s_dt for e_dt, e_mid in rental_ends if e_mid == mid)
            if still_open:
                rental_age_h = (now - s_dt).total_seconds() / 3600.0

        print(f"  Currently classified mining/cracking (live workload_throttle state), rental "
              f"{'still active, ' + format(rental_age_h, '.1f') + 'h so far' if rental_age_h is not None else 'not currently open in this log'}")
        if baseline_h:
            print(f"  Baseline median rental duration on this rig: {baseline_h:.1f}h")
        print(f"  Rate-confirmed bypass has fired at least once on this rig: {'yes' if ever_bypassed else 'no'}")

        # --- The actual suggestion ---
        if deviation_pct is None:
            print("  SUGGESTION: no market median to compare against -- can't recommend.\n")
            continue

        sticky = (rental_age_h is not None and baseline_h and rental_age_h > baseline_h * 1.5)

        if deviation_pct < -5 and sticky and ever_bypassed:
            suggested = median
            print(f"  SUGGESTION: RAISE toward market median (~${suggested:.3f}, currently "
                  f"{deviation_pct:+.0f}% vs. median). This renter has already paid at/above "
                  f"market at least once (rate bypass fired) AND has stayed {rental_age_h:.1f}h, "
                  f"well past this rig's {baseline_h:.1f}h median rental duration, despite being "
                  f"power-capped repeatedly -- the strongest evidence available that a move toward "
                  f"median won't push them out. Don't jump straight to p75 off this alone -- price "
                  f"elasticity is a real-dollar cost to them, unlike the power cap, and hasn't been "
                  f"tested the same way.\n")
        elif deviation_pct < -5 and sticky and not ever_bypassed:
            suggested = my_price + (median - my_price) * 0.5
            print(f"  SUGGESTION: consider a SMALL step toward median (~${suggested:.3f}, halfway; "
                  f"currently {deviation_pct:+.0f}% vs. median). This renter has stayed {rental_age_h:.1f}h "
                  f"vs. a {baseline_h:.1f}h baseline despite repeated power caps -- good churn "
                  f"resilience -- but the rate-confirmed bypass has never fired here, so there's no "
                  f"direct evidence yet that they've tolerated a market-rate price specifically. "
                  f"Smaller step, not a full move to median.\n")
        elif deviation_pct < -5:
            print(f"  SUGGESTION: priced {deviation_pct:+.0f}% below median, but not enough churn "
                  f"evidence yet (rental hasn't clearly outlasted the baseline) to recommend acting "
                  f"on it -- worth re-checking once this rental's been running longer.\n")
        elif deviation_pct > 15:
            print(f"  SUGGESTION: already priced {deviation_pct:+.0f}% above median -- no reason to "
                  f"raise further; if occupancy drops, that's the first thing to reconsider.\n")
        else:
            print(f"  SUGGESTION: priced {deviation_pct:+.0f}% vs. median -- already close to "
                  f"market, no strong case to move it either way.\n")


if __name__ == "__main__":
    main()
