#!/usr/bin/env python3
"""Optional temp-based Cloudline fan speed loop — standalone, decoupled from
gpu_monitor.sh on purpose (see repo notes: the GPU monitor script is left
untouched). Run this as its own systemd service (see deploy/) if you want
automatic speed control; the dashboard's Cooling card and manual speed
control work fine without it.

Temperature source is the Cloudline controller's own ambient sensor
(list_devices()' temp_c — the same reading shown on the dashboard's Cooling
card), not an external probe: it's exactly what the fans are meant to be
responding to, and needs no extra wiring. Each device is controlled off its
own reading (not a fleet-wide average), so a multi-controller setup adjusts
each room/device independently.

Proportional control: fan speed scales linearly between MIN_TEMP_C (fans at
MIN_SPEED) and MAX_TEMP_C (fans at 10), clamped at both ends. NIGHT_SPEED_CAP
(if set) limits the max speed during NIGHT_START_HOUR-NIGHT_END_HOUR local
time, for a quieter house overnight. MIN_SPEED > 0 keeps some airflow moving
even when it's cool rather than letting fans sit fully off.

Outdoor-air awareness: any port whose name matches CLOUDLINE_INTAKE_PORT_NAMES
(comma-separated, case-insensitive substring match — default "intake") is
assumed to pull outside air INTO the room. Ramping that fan up only helps
once outside is at least CLOUDLINE_OUTDOOR_MARGIN_C degrees cooler than the
room (default 4°C); short of that, doing so just imports heat, so that port
idles at CLOUDLINE_INTAKE_MIN_SPEED (default 0 — fully off) rather than the
general MIN_SPEED floor. Every other port (e.g. an exhaust/return fan moving
air within or out of the room) isn't outside-air-facing and keeps the plain
proportional room-temp response. Outdoor reading comes from the same free/
keyless Open-Meteo source as the dashboard's Cooling card
(gpu-monitor/dashboard/outdoor_weather_api.py) but fetched independently
here to keep this script standalone/decoupled from the dashboard process.

Power metering — Tapo when available, speed-based estimate otherwise: if
CLOUDLINE_TAPO_HOST is set, this loop polls a TP-Link Tapo energy-
monitoring smart plug (P110/P115/P100) powering the Cloudline fans and
logs a pdu_power event into the SAME JSONL gpu_monitor.sh writes to —
reusing ../tapo-poll.py exactly as-is (no edits, no gpu_monitor.sh changes)
via a plain subprocess call. Whenever that real reading isn't available
(CLOUDLINE_TAPO_HOST unset, or the plug's unreachable/offline), this loop
falls back to a SPEED-BASED ESTIMATE instead: each port's current draw is
approximated as (speed/10) * that port's rated max watts
(CLOUDLINE_PORT_MAX_WATTS, per port name; CLOUDLINE_DEFAULT_MAX_WATTS for
any port not listed), summed across all online ports and integrated into
its own cumulative-kWh state file exactly like tapo-poll.py does for a
real meter. Either way — real reading or estimate — the event is written
under the SAME rig tag (CLOUDLINE_TAPO_RIG_NAME, default
"<hostname>-cloudline") so the dashboard's existing per-host power summing
picks it up identically; an "estimate" flag on the event just lets the UI
note it's approximate rather than metered.

That distinct rig tag (rather than reusing gpu_monitor.sh's own
tapo_poll()/pdu_poll(), which always tags events with the real hostname)
is deliberate either way: if the fans' readings landed under the same tag
as zappa1's actual rack PDU, the two meters' events would interleave and
"Power Now" would flip-flop between full-rack wattage and fan wattage
instead of showing either correctly. combined.html's renderPower() already
sums multiple distinctly-tagged meters together correctly, so a separate
tag is all this needs to show up in the fleet's power/energy totals as its
own line.
"""
import datetime
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from client import CloudlineClient  # noqa: E402

TAPO_HOST = os.environ.get("CLOUDLINE_TAPO_HOST", "")
TAPO_EMAIL = os.environ.get("CLOUDLINE_TAPO_EMAIL", "")
TAPO_PASSWORD = os.environ.get("CLOUDLINE_TAPO_PASSWORD", "")
TAPO_JSONL = os.environ.get("CLOUDLINE_TAPO_JSONL", "/var/log/gpu_monitor_data.jsonl")
TAPO_RIG_NAME = os.environ.get("CLOUDLINE_TAPO_RIG_NAME", f"{socket.gethostname()}-cloudline")
TAPO_RATE = os.environ.get("CLOUDLINE_TAPO_RATE", "0.25")
TAPO_BASELINE_KWH = os.environ.get("CLOUDLINE_TAPO_BASELINE_KWH", "0")
TAPO_POLL_INTERVAL = int(os.environ.get("CLOUDLINE_TAPO_POLL_INTERVAL", "300"))
# Default assumes tapo-poll.py sits next to this repo's cloudline/ dir (i.e.
# gpu-monitor/tapo-poll.py) -- but gpu_monitor.sh's own tapo_poll() expects
# it alongside gpu_monitor.sh itself (typically /usr/local/bin/tapo-poll.py),
# which may be the only copy actually deployed on a given host. Override with
# CLOUDLINE_TAPO_POLL_SCRIPT if the default path doesn't exist there.
TAPO_POLL_SCRIPT = os.environ.get(
    "CLOUDLINE_TAPO_POLL_SCRIPT",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tapo-poll.py"),
)

# Speed-based fallback estimate, used whenever a real Tapo reading isn't
# available. "name:watts" pairs, matched against each port's name the same
# case-insensitive-substring way as CLOUDLINE_INTAKE_PORT_NAMES. Defaults
# assume two ~20W fans (a T6 and an "S6") until told otherwise per port.
def _parse_port_watts(raw):
    out = {}
    for pair in raw.split(","):
        pair = pair.strip()
        if not pair or ":" not in pair:
            continue
        name, watts = pair.rsplit(":", 1)
        try:
            out[name.strip().lower()] = float(watts)
        except ValueError:
            continue
    return out


PORT_MAX_WATTS = _parse_port_watts(os.environ.get("CLOUDLINE_PORT_MAX_WATTS", "intake:20,return:20"))
DEFAULT_MAX_WATTS = float(os.environ.get("CLOUDLINE_DEFAULT_MAX_WATTS", "20"))
ESTIMATE_STATE_FILE = os.environ.get("CLOUDLINE_ESTIMATE_STATE_FILE", "/var/tmp/gpu_monitor_cloudline_estimate_energy")

_last_power_poll = 0


def port_max_watts(port_name):
    name = (port_name or "").lower()
    for tag, watts in PORT_MAX_WATTS.items():
        if tag in name:
            return watts
    return DEFAULT_MAX_WATTS


def _write_power_event(watts, is_estimate):
    """Same event shape tapo-poll.py writes, integrated the same way (our
    own cumulative-kWh state file, not the device's own lifetime counter —
    see tapo-poll.py's docstring for why). A separate state file from
    tapo-poll.py's own so switching between real/estimate readings across
    restarts doesn't corrupt either one's running total."""
    now = datetime.datetime.now(datetime.timezone.utc)
    now_epoch = now.timestamp()
    cum, last = 0.0, now_epoch
    if os.path.exists(ESTIMATE_STATE_FILE):
        try:
            parts = open(ESTIMATE_STATE_FILE).read().split()
            cum, last = float(parts[0]), float(parts[1])
        except Exception:
            cum, last = 0.0, now_epoch
    dt = now_epoch - last
    if dt <= 0 or dt > 900:
        dt = TAPO_POLL_INTERVAL
    kwh_interval = watts * dt / 3_600_000.0
    cum += kwh_interval
    tmp = ESTIMATE_STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write("%f %f" % (cum, now_epoch))
    os.replace(tmp, ESTIMATE_STATE_FILE)

    ev = {
        "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "type": "pdu_power",
        "host": TAPO_RIG_NAME,
        "amps": None,
        "watts": round(watts),
        "kwh_interval": round(kwh_interval, 5),
        "cumulative_kwh": round(cum, 3),
        "cumulative_kwh_total": round(cum + float(TAPO_BASELINE_KWH), 3),
        "rate": float(TAPO_RATE),
        "source": "estimate" if is_estimate else "tapo",
    }
    with open(TAPO_JSONL, "a") as f:
        f.write(json.dumps(ev) + "\n")


def poll_tapo():
    """Real Tapo reading if configured and reachable; returns True on
    success so the caller knows whether to fall back to the estimate."""
    if not TAPO_HOST:
        return False
    try:
        subprocess.run([
            sys.executable, TAPO_POLL_SCRIPT,
            "--host", TAPO_HOST, "--email", TAPO_EMAIL, "--password", TAPO_PASSWORD,
            "--jsonl", TAPO_JSONL, "--rig", TAPO_RIG_NAME, "--rate", TAPO_RATE,
            "--baseline-kwh", TAPO_BASELINE_KWH,
        ], check=True, capture_output=True, text=True, timeout=30)
        return True
    except subprocess.CalledProcessError as e:
        print(f"[cloudline-scheduler] tapo poll failed, falling back to speed-based estimate: {e.stderr.strip()}", file=sys.stderr, flush=True)
        return False
    except Exception as e:
        print(f"[cloudline-scheduler] tapo poll error, falling back to speed-based estimate: {e}", file=sys.stderr, flush=True)
        return False


def poll_power(current_total_watts):
    """Called every CLOUDLINE_TAPO_POLL_INTERVAL regardless of whether
    Tapo is configured at all — an estimate is written even with no Tapo
    plug set up, so the dashboard always has *something* for Cloudline's
    power draw, real or approximate. `current_total_watts` is the caller's
    own live sum of (speed/10)*rated-max-watts across every online port —
    computed in the main loop, where the just-applied speeds are already
    known, rather than re-derived from a possibly-stale API read here."""
    global _last_power_poll
    now = time.time()
    if now - _last_power_poll < TAPO_POLL_INTERVAL:
        return
    _last_power_poll = now
    if poll_tapo():
        return  # real reading written by tapo-poll.py itself
    _write_power_event(current_total_watts, is_estimate=True)
    print(f"[cloudline-scheduler] no Tapo reading available — logged estimate: {current_total_watts:.1f} W -> rig={TAPO_RIG_NAME}", flush=True)

POLL_SECONDS = int(os.environ.get("CLOUDLINE_POLL_SECONDS", "60"))
MIN_TEMP_C = float(os.environ.get("CLOUDLINE_MIN_TEMP_C", "30"))
MAX_TEMP_C = float(os.environ.get("CLOUDLINE_MAX_TEMP_C", "45"))
MIN_SPEED = int(os.environ.get("CLOUDLINE_MIN_SPEED", "2"))
NIGHT_SPEED_CAP = os.environ.get("CLOUDLINE_NIGHT_SPEED_CAP")
NIGHT_START_HOUR = int(os.environ.get("CLOUDLINE_NIGHT_START_HOUR", "23"))
NIGHT_END_HOUR = int(os.environ.get("CLOUDLINE_NIGHT_END_HOUR", "7"))

INTAKE_PORT_NAMES = [
    s.strip().lower() for s in os.environ.get("CLOUDLINE_INTAKE_PORT_NAMES", "intake").split(",") if s.strip()
]
INTAKE_MIN_SPEED = int(os.environ.get("CLOUDLINE_INTAKE_MIN_SPEED", "0"))  # intake specifically idles at 0 (off), not the general MIN_SPEED floor
OUTDOOR_LAT = float(os.environ.get("OUTDOOR_WEATHER_LAT", "39.8467"))
OUTDOOR_LON = float(os.environ.get("OUTDOOR_WEATHER_LON", "-75.7057"))
OUTDOOR_MARGIN_C = float(os.environ.get("CLOUDLINE_OUTDOOR_MARGIN_C", "4"))  # outside must be at least this many °C cooler than the room before intake is allowed to ramp up (~3-5°C requested)
_outdoor_cache = {"ts": 0, "temp_c": None}


def is_intake_port(port_name):
    name = (port_name or "").lower()
    return any(tag in name for tag in INTAKE_PORT_NAMES)


def get_outdoor_temp_c():
    """Cached 10 min — same cadence as the dashboard's own outdoor fetch.
    Returns None (not an exception) on any failure, so callers can fall
    back to treating outdoor conditions as unknown rather than crashing
    the whole poll loop over a flaky weather API."""
    now = time.time()
    if _outdoor_cache["temp_c"] is not None and now - _outdoor_cache["ts"] < 600:
        return _outdoor_cache["temp_c"]
    try:
        # No temperature_unit param -> Open-Meteo's default is already
        # Celsius, so this is used as-is (no F->C conversion needed/wanted).
        qs = urllib.parse.urlencode({"latitude": OUTDOOR_LAT, "longitude": OUTDOOR_LON, "current": "temperature_2m"})
        with urllib.request.urlopen(f"https://api.open-meteo.com/v1/forecast?{qs}", timeout=8) as resp:
            data = json.loads(resp.read())
        temp_c = data.get("current", {}).get("temperature_2m")
        _outdoor_cache.update(ts=now, temp_c=temp_c)
        return temp_c
    except (urllib.error.URLError, ValueError, KeyError):
        return _outdoor_cache["temp_c"]  # last known value (possibly still None) rather than treating a transient fetch error as "cool outside"


def target_speed(temp_c):
    if temp_c is None:
        return None
    if temp_c <= MIN_TEMP_C:
        speed = MIN_SPEED
    elif temp_c >= MAX_TEMP_C:
        speed = 10
    else:
        frac = (temp_c - MIN_TEMP_C) / (MAX_TEMP_C - MIN_TEMP_C)
        speed = MIN_SPEED + frac * (10 - MIN_SPEED)
    speed = round(speed)

    if NIGHT_SPEED_CAP is not None:
        hour = time.localtime().tm_hour
        in_night = (NIGHT_START_HOUR <= hour or hour < NIGHT_END_HOUR) if NIGHT_START_HOUR > NIGHT_END_HOUR \
            else (NIGHT_START_HOUR <= hour < NIGHT_END_HOUR)
        if in_night:
            speed = min(speed, int(NIGHT_SPEED_CAP))

    return max(0, min(10, speed))


def main():
    email = os.environ["AC_INFINITY_EMAIL"]
    password = os.environ["AC_INFINITY_PASSWORD"]
    client = CloudlineClient(email, password)
    client.login()
    print("[cloudline-scheduler] logged in, polling every", POLL_SECONDS, "s", flush=True)
    if TAPO_HOST and not os.path.exists(TAPO_POLL_SCRIPT):
        print(f"[cloudline-scheduler] WARNING: CLOUDLINE_TAPO_HOST is set but {TAPO_POLL_SCRIPT} "
              f"doesn't exist — set CLOUDLINE_TAPO_POLL_SCRIPT to the real path (e.g. /usr/local/bin/tapo-poll.py)",
              file=sys.stderr, flush=True)
    elif TAPO_HOST:
        print(f"[cloudline-scheduler] Tapo metering enabled: {TAPO_HOST} -> rig={TAPO_RIG_NAME}, every {TAPO_POLL_INTERVAL}s", flush=True)

    last_speed = {}
    while True:
        try:
            outdoor_c = get_outdoor_temp_c()
            total_watts = 0.0
            for dev in client.list_devices():
                room_c = dev.get("temp_c")
                base_speed = target_speed(room_c)
                for port in dev["ports"]:
                    if not port.get("online"):
                        continue  # nothing physically connected — AC Infinity rejects writes to it

                    speed = base_speed
                    if base_speed is not None and is_intake_port(port.get("name")):
                        # Pulling in outside air only helps if it's
                        # meaningfully cooler than the room — otherwise
                        # ramping up an intake fan just imports heat,
                        # working against the very thing this loop is
                        # trying to do, so it idles at INTAKE_MIN_SPEED
                        # (off, by default) rather than the general floor.
                        outdoor_helps = outdoor_c is not None and room_c is not None and outdoor_c <= room_c - OUTDOOR_MARGIN_C
                        if not outdoor_helps:
                            speed = INTAKE_MIN_SPEED

                    # Wattage estimate uses the port's actual current speed
                    # (whatever we just decided it should be, or its last
                    # known value if this device has no sensor reading yet
                    # and base_speed is None), not just the ones we issue a
                    # fresh API call for — a port left unchanged this cycle
                    # is still drawing power.
                    key = (dev["device_id"], port["port"])
                    effective_speed = speed if speed is not None else last_speed.get(key, port.get("speed") or 0)
                    total_watts += (effective_speed / 10.0) * port_max_watts(port.get("name"))

                    if base_speed is None:
                        continue  # no sensor reading for this device yet — leave its fans alone
                    if last_speed.get(key) == speed:
                        continue
                    client.set_speed(dev["device_id"], port["port"], speed)
                    last_speed[key] = speed
                    outdoor_str = f"{outdoor_c:.1f}°C" if outdoor_c is not None else "unknown"
                    print(f"[cloudline-scheduler] {dev['name']} ({room_c}°C, outside {outdoor_str}) port {port['port']} -> speed {speed}", flush=True)

            poll_power(total_watts)
        except Exception as e:
            print(f"[cloudline-scheduler] error: {e}", file=sys.stderr)
            try:
                client.login()
            except Exception:
                pass
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
