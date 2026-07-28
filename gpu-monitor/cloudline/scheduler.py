#!/usr/bin/env python3
"""Optional temp-based Cloudline fan speed loop — standalone, decoupled from
gpu_monitor.sh on purpose (see repo notes: the GPU monitor script is left
untouched). Run this as its own systemd service (see deploy/) if you want
automatic speed control; the dashboard's Cooling card and manual speed
control work fine without it.

Proportional control: fan speed scales linearly between MIN_TEMP_C (fans at
MIN_SPEED) and MAX_TEMP_C (fans at 10), clamped at both ends. NIGHT_SPEED_CAP
(if set) limits the max speed during NIGHT_START_HOUR-NIGHT_END_HOUR local
time, for a quieter house overnight.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from client import CloudlineClient  # noqa: E402

POLL_SECONDS = int(os.environ.get("CLOUDLINE_POLL_SECONDS", "60"))
MIN_TEMP_C = float(os.environ.get("CLOUDLINE_MIN_TEMP_C", "30"))
MAX_TEMP_C = float(os.environ.get("CLOUDLINE_MAX_TEMP_C", "45"))
MIN_SPEED = int(os.environ.get("CLOUDLINE_MIN_SPEED", "2"))
NIGHT_SPEED_CAP = os.environ.get("CLOUDLINE_NIGHT_SPEED_CAP")
NIGHT_START_HOUR = int(os.environ.get("CLOUDLINE_NIGHT_START_HOUR", "23"))
NIGHT_END_HOUR = int(os.environ.get("CLOUDLINE_NIGHT_END_HOUR", "7"))


def read_temp_c():
    """Stub — wire this to a real sensor (e.g. the GPU/CPU temps already
    collected by gpu_monitor.sh's JSONL log, or a dedicated ambient probe)
    before enabling automation. Returns None until it's wired up, which
    keeps the loop a no-op (fans left alone) rather than guessing."""
    return None


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
    print("[cloudline-scheduler] logged in, polling every", POLL_SECONDS, "s")

    last_speed = {}
    while True:
        try:
            temp_c = read_temp_c()
            speed = target_speed(temp_c)
            if speed is None:
                time.sleep(POLL_SECONDS)
                continue
            for dev in client.list_devices():
                for port in dev["ports"]:
                    key = (dev["device_id"], port["port"])
                    if last_speed.get(key) == speed:
                        continue
                    client.set_speed(dev["device_id"], port["port"], speed)
                    last_speed[key] = speed
                    print(f"[cloudline-scheduler] {dev['name']} port {port['port']} -> speed {speed}")
        except Exception as e:
            print(f"[cloudline-scheduler] error: {e}", file=sys.stderr)
            try:
                client.login()
            except Exception:
                pass
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
