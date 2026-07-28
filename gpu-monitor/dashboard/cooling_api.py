#!/usr/bin/env python3
"""AC Infinity Cloudline fan status + manual control (this rig only) — see
gpu-monitor/cloudline/client.py. Read-only status is cheap and cached
briefly; speed changes hit the API directly. Deliberately independent of
gpu_monitor.sh — this module owns its own login session and never touches
the GPU monitor's state file or JSONL log.

Disabled (status endpoint returns {"enabled": false}) unless both
AC_INFINITY_EMAIL and AC_INFINITY_PASSWORD are set, so hosts without a
Cloudline controller don't pay any cost or show a broken card.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cloudline"))
from client import CloudlineClient, CloudlineError  # noqa: E402

EMAIL = os.environ.get("AC_INFINITY_EMAIL", "")
PASSWORD = os.environ.get("AC_INFINITY_PASSWORD", "")
ENABLED = bool(EMAIL and PASSWORD)

CACHE_SECONDS = 20
_client = None
_cache = {"ts": 0, "devices": None, "error": None}


def _get_client():
    global _client
    if _client is None:
        _client = CloudlineClient(EMAIL, PASSWORD)
        _client.login()
    return _client


def _list_devices_cached():
    now = time.time()
    if _cache["devices"] is not None and now - _cache["ts"] < CACHE_SECONDS:
        return _cache["devices"], _cache["error"]
    try:
        devices = _get_client().list_devices()
        _cache.update(ts=now, devices=devices, error=None)
        return devices, None
    except CloudlineError as e:
        # Token may have expired — one forced re-login retry before giving up.
        global _client
        _client = None
        try:
            devices = _get_client().list_devices()
            _cache.update(ts=now, devices=devices, error=None)
            return devices, None
        except Exception as e2:
            _cache.update(ts=now, devices=None, error=str(e2))
            return None, str(e2)


def handle_cooling_get():
    if not ENABLED:
        return {"enabled": False}
    devices, error = _list_devices_cached()
    if error:
        return {"enabled": True, "error": error, "devices": []}
    return {"enabled": True, "devices": devices}


def handle_cooling_set_speed(device_id, port, speed):
    if not ENABLED:
        return {"error": "cooling not configured on this host"}
    try:
        speed = int(speed)
    except (TypeError, ValueError):
        return {"error": "speed must be an integer 0-10"}
    if not (0 <= speed <= 10):
        return {"error": "speed must be between 0 and 10"}
    try:
        new_speed = _get_client().set_speed(device_id, port, speed)
    except CloudlineError as e:
        return {"error": str(e)}
    _cache["ts"] = 0  # force a fresh read on the next GET
    return {"device_id": device_id, "port": port, "speed": new_speed}
