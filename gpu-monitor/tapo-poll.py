#!/usr/bin/env python3
"""One-shot poll of a TP-Link Tapo energy-monitoring smart plug (P110/P115/
P100), writing the SAME pdu_power event shape gpu_monitor.sh's own pdu_poll()
writes for the APC PDU — so a per-rig Tapo meter (e.g. zappa3, on its own
regular outlet rather than the shared APC PDU covering zappa1+zappa2) slots
straight into the existing dashboard/Prometheus pipeline with zero changes
there, just an additional `host` value in the same event stream. Multiple
meters covering different hardware subsets are expected to coexist; see
combined.html's renderPower() for the per-host-latest summing that makes
that correct instead of one meter silently dropping out of the total.

Reads the plug's real-time power (Watts) via python-kasa's Energy interface
and integrates it into cumulative kWh ourselves, in a persistent state file —
the SAME approach pdu_poll() uses for the current-only APC unit, deliberately
NOT the device's own consumption_total. That field is documented by
python-kasa as "total consumption since last reboot", not a true lifetime
counter — a smart plug can reboot on its own (WiFi drop, firmware update,
power blip), which would silently cliff-drop a "lifetime kWh" figure that
trusted it directly. current_consumption (instant watts) isn't affected by a
reboot the same way, so integrating that ourselves is the reliable source.

Requires: pip3 install python-kasa (auto-installed by install.sh when
TAPO_HOST is configured — see gpu_monitor.sh's tapo_poll()).

Called every TAPO_POLL_INTERVAL seconds by gpu_monitor.sh's tapo_poll(),
mirroring pdu_poll()'s own cadence and call pattern — this script does one
poll and exits, no long-running state beyond what it reads from/writes to
disk each call.

Usage:
    tapo-poll.py --host <plug-ip> --email <tapo-account-email> \
        --password <tapo-account-password> --jsonl <path> --rig <hostname> \
        --rate <dollars-per-kwh> [--baseline-kwh <n>] [--dump]

--dump prints every attribute python-kasa's Energy interface exposes for the
device instead of writing an event — run this once by hand after wiring the
plug in, to confirm the device actually reports what this script expects
(confirmed against python-kasa 0.10.2: current_consumption in Watts,
consumption_today/consumption_total already in kWh, not Wh).
"""
import argparse
import asyncio
import datetime
import json
import os
import sys


async def _poll(host, email, password, dump):
    try:
        from kasa import Discover, Credentials
    except ImportError:
        print("tapo-poll: python-kasa not installed — pip3 install python-kasa", file=sys.stderr)
        sys.exit(1)

    dev = await Discover.discover_single(host, credentials=Credentials(username=email, password=password))
    try:
        await dev.update()

        energy = dev.modules.get("Energy") if hasattr(dev, "modules") else None
        if energy is None:
            print(f"tapo-poll: {dev.alias!r} at {host} has no Energy module — "
                  f"is this a P110/P115/P100 (energy-monitoring) model?", file=sys.stderr)
            return None

        if dump:
            print(f"device: {dev.alias!r} model={dev.model} host={host}")
            print(f"  current_consumption (W)     = {energy.current_consumption}")
            print(f"  consumption_today (kWh)     = {energy.consumption_today}")
            print(f"  consumption_this_month (kWh)= {energy.consumption_this_month}")
            print(f"  consumption_total (kWh, since last reboot, NOT lifetime) = {energy.consumption_total}")
            print(f"  voltage (V) = {getattr(energy, 'voltage', None)}, current (A) = {getattr(energy, 'current', None)}")
            return None

        watts = energy.current_consumption
        if watts is None:
            print(f"tapo-poll: {dev.alias!r} responded but current_consumption is None "
                  f"(device may need a moment after power-on) — skipping this poll", file=sys.stderr)
            return None

        return {"watts": float(watts), "alias": dev.alias}
    finally:
        # Without this, aiohttp warns "Unclosed client session" on interpreter
        # exit — cosmetic, but gpu_monitor.sh's tapo_poll() treats ANY non-empty
        # captured output as a failure (confirmed live on Zappa3, 2026-07-20:
        # logged a misleading "TAPO: ..." error every 5-minute cycle despite the
        # poll actually succeeding every time). Closing the connection here
        # removes the warning at its source instead of filtering it downstream.
        await dev.disconnect()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True, help="Tapo plug's local IP")
    ap.add_argument("--email", required=True, help="TP-Link account email (local-auth handshake only, no cloud calls per-poll)")
    ap.add_argument("--password", required=True, help="TP-Link account password")
    ap.add_argument("--jsonl", help="Path to this rig's gpu_monitor_data.jsonl (required unless --dump)")
    ap.add_argument("--rig", help="Hostname to tag the event with (required unless --dump)")
    ap.add_argument("--rate", type=float, default=0.25, help="$/kWh (default 0.25, matches gpu_monitor.sh's own PDU_ENERGY_RATE default)")
    ap.add_argument("--baseline-kwh", type=float, default=0.0, help="Lifetime kWh already consumed before this plug started metering (like PDU_KWH_BASELINE)")
    ap.add_argument("--dump", action="store_true", help="Print device info and exit instead of writing an event")
    args = ap.parse_args()

    if not args.dump and (not args.jsonl or not args.rig):
        ap.error("--jsonl and --rig are required unless --dump")

    result = asyncio.run(_poll(args.host, args.email, args.password, args.dump))
    if args.dump or result is None:
        return

    # Our own persistent integration — see the module docstring for why we
    # don't trust the device's own consumption_total for this.
    state_f = f"/var/tmp/gpu_monitor_tapo_energy_{args.host.replace('.', '_')}"
    now = datetime.datetime.now(datetime.timezone.utc)
    now_epoch = now.timestamp()

    cum, last = 0.0, now_epoch
    if os.path.exists(state_f):
        try:
            parts = open(state_f).read().split()
            cum, last = float(parts[0]), float(parts[1])
        except Exception:
            cum, last = 0.0, now_epoch
    dt = now_epoch - last
    # Ignore absurd gaps (service restart, clock jump, long downtime) so a
    # stale last-timestamp can't manufacture a huge energy spike — matches
    # pdu_poll()'s own guard (3x the nominal ~300s poll interval).
    if dt <= 0 or dt > 900:
        dt = 300
    kwh_interval = result["watts"] * dt / 3_600_000.0
    cum += kwh_interval

    tmp = state_f + ".tmp"
    with open(tmp, "w") as f:
        f.write("%f %f" % (cum, now_epoch))
    os.replace(tmp, state_f)

    ev = {
        "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "type": "pdu_power",
        "host": args.rig,
        "amps": None,
        "watts": round(result["watts"]),
        "kwh_interval": round(kwh_interval, 5),
        "cumulative_kwh": round(cum, 3),
        "cumulative_kwh_total": round(cum + args.baseline_kwh, 3),
        "rate": args.rate,
        "source": "tapo",
        "device_alias": result["alias"],
    }
    with open(args.jsonl, "a") as f:
        f.write(json.dumps(ev) + "\n")


if __name__ == "__main__":
    main()
