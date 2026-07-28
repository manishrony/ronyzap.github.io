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
when outside is actually cooler than the room; if outside is as hot or
hotter, doing so just imports heat, so that port is capped at MIN_SPEED
regardless of how hot the room is. Every other port (e.g. an exhaust/return
fan moving air within or out of the room) isn't outside-air-facing and
keeps the plain proportional room-temp response. Outdoor reading comes from
the same free/keyless Open-Meteo source as the dashboard's Cooling card
(gpu-monitor/dashboard/outdoor_weather_api.py) but fetched independently
here to keep this script standalone/decoupled from the dashboard process.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from client import CloudlineClient  # noqa: E402

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
OUTDOOR_LAT = float(os.environ.get("OUTDOOR_WEATHER_LAT", "39.8467"))
OUTDOOR_LON = float(os.environ.get("OUTDOOR_WEATHER_LON", "-75.7057"))
OUTDOOR_MARGIN_C = float(os.environ.get("CLOUDLINE_OUTDOOR_MARGIN_C", "1"))  # require outside to be at least this much cooler before rewarding intake speed
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
        qs = urllib.parse.urlencode({"latitude": OUTDOOR_LAT, "longitude": OUTDOOR_LON, "current": "temperature_2m"})
        with urllib.request.urlopen(f"https://api.open-meteo.com/v1/forecast?{qs}", timeout=8) as resp:
            data = json.loads(resp.read())
        temp_f = data.get("current", {}).get("temperature_2m")
        temp_c = (temp_f - 32) * 5 / 9 if temp_f is not None else None
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

    last_speed = {}
    while True:
        try:
            outdoor_c = get_outdoor_temp_c()
            for dev in client.list_devices():
                room_c = dev.get("temp_c")
                base_speed = target_speed(room_c)
                if base_speed is None:
                    continue  # no sensor reading for this device yet — leave its fans alone
                for port in dev["ports"]:
                    if not port.get("online"):
                        continue  # nothing physically connected — AC Infinity rejects writes to it

                    speed = base_speed
                    if is_intake_port(port.get("name")):
                        # Pulling in outside air only helps if it's actually
                        # cooler than the room — otherwise ramping up an
                        # intake fan just imports heat, working against the
                        # very thing this loop is trying to do.
                        outdoor_helps = outdoor_c is not None and room_c is not None and outdoor_c <= room_c - OUTDOOR_MARGIN_C
                        if not outdoor_helps:
                            speed = MIN_SPEED

                    key = (dev["device_id"], port["port"])
                    if last_speed.get(key) == speed:
                        continue
                    client.set_speed(dev["device_id"], port["port"], speed)
                    last_speed[key] = speed
                    print(f"[cloudline-scheduler] {dev['name']} ({room_c}°C, outside {outdoor_c}°C) port {port['port']} -> speed {speed}", flush=True)
        except Exception as e:
            print(f"[cloudline-scheduler] error: {e}", file=sys.stderr)
            try:
                client.login()
            except Exception:
                pass
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
