#!/usr/bin/env python3
"""Outdoor temperature/humidity for this rig's physical location, via
Open-Meteo (free, no API key). Shown next to the Cooling card's ambient
room reading for context — "is it hot outside too, or just this room."

Coordinates are hardcoded for zappa1's location (Kennett Square, PA) rather
than geocoded at request time — one less external call and one less
failure mode for a value that never changes. Override via
OUTDOOR_WEATHER_LAT/OUTDOOR_WEATHER_LON if this ever runs somewhere else.
"""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

LAT = float(os.environ.get("OUTDOOR_WEATHER_LAT", "39.8467"))
LON = float(os.environ.get("OUTDOOR_WEATHER_LON", "-75.7057"))
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"

CACHE_SECONDS = 600  # weather doesn't change fast enough to justify polling more often
_cache = {"ts": 0, "data": None, "error": None}


def _fetch():
    qs = urllib.parse.urlencode({
        "latitude": LAT,
        "longitude": LON,
        "current": "temperature_2m,relative_humidity_2m",
        "temperature_unit": "fahrenheit",
    })
    url = f"{FORECAST_URL}?{qs}"
    with urllib.request.urlopen(url, timeout=8) as resp:
        data = json.loads(resp.read())
    current = data.get("current", {})
    temp_f = current.get("temperature_2m")
    return {
        "temp_f": temp_f,
        "temp_c": round((temp_f - 32) * 5 / 9, 1) if temp_f is not None else None,
        "humidity_pct": current.get("relative_humidity_2m"),
    }


def handle_outdoor_weather_get():
    now = time.time()
    if _cache["data"] is not None and now - _cache["ts"] < CACHE_SECONDS:
        return {"enabled": True, **_cache["data"]}
    try:
        result = _fetch()
        _cache.update(ts=now, data=result, error=None)
        return {"enabled": True, **result}
    except (urllib.error.URLError, ValueError, KeyError) as e:
        _cache.update(ts=now, data=None, error=str(e))
        return {"enabled": True, "error": str(e)}
