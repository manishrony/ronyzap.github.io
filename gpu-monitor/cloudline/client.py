#!/usr/bin/env python3
"""Client for AC Infinity's unofficial cloud API (Cloudline fan controllers).

Reverse-engineered — not an official/documented API — matching the request
shape used by the community's Home Assistant AC Infinity integration
(dalinicus/homeassistant-acinfinity), confirmed working against a real
account on 2026-07-28. Two things about this API are easy to get wrong and
worth calling out explicitly since they cost real debugging time:

  - Every request needs a `User-Agent: okhttp/4.12.0` header (mimicking the
    Android app's HTTP client) or the server rejects it with a generic
    {"code": 999999, "msg": "Operation failed, please try again"} that
    looks exactly like a bad-credentials error but isn't.
  - Login sends the password in plaintext, truncated to 25 characters (the
    API's own limit, not a client-side choice) — no hashing.

Stdlib-only (urllib), matching the rest of this repo's dashboard/*_api.py
modules — no `requests` dependency.
"""
import json
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = "https://www.acinfinityserver.com"
LOGIN_URL = BASE_URL + "/api/user/appUserLogin"
DEVICE_LIST_URL = BASE_URL + "/api/user/devInfoListAll"
MODE_SETTINGS_URL = BASE_URL + "/api/dev/getdevModeSettingList"
ADD_MODE_URL = BASE_URL + "/api/dev/addDevMode"

USER_AGENT = "okhttp/4.12.0"

# AC Infinity's manual "On" mode — set a fixed fan speed 0 (off) - 10 (max),
# no temperature/humidity/schedule logic involved.
AT_TYPE_MANUAL = 2


class CloudlineError(Exception):
    pass


class CloudlineClient:
    """login() once, then list_devices()/set_speed()/turn_off() reuse the
    session token until it's rejected, at which point callers should
    re-login (this class does not auto-retry on auth failure)."""

    def __init__(self, email, password, timeout=10):
        self.email = email
        self.password = password
        self.timeout = timeout
        self.token = None

    def _request(self, url, fields, auth=True, in_query=False):
        """in_query=True puts `fields` in the URL's query string with an
        empty body — that's how addDevMode expects to receive its
        parameters (unlike every other endpoint here, which takes a normal
        form-encoded POST body)."""
        qs = urllib.parse.urlencode(fields)
        if in_query:
            req = urllib.request.Request(url + "?" + qs, data=b"", method="POST")
        else:
            req = urllib.request.Request(url, data=qs.encode(), method="POST")
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
        req.add_header("User-Agent", USER_AGENT)
        if auth:
            if not self.token:
                raise CloudlineError("not logged in")
            req.add_header("token", self.token)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = json.loads(resp.read())
        except urllib.error.URLError as e:
            raise CloudlineError(f"request to {url} failed: {e}") from e
        if data.get("code") != 200:
            raise CloudlineError(f"{url} -> {data.get('code')}: {data.get('msg')}")
        return data.get("data")

    def login(self):
        data = self._request(LOGIN_URL, {
            "appEmail": self.email,
            "appPasswordl": self.password[:25],
        }, auth=False)
        self.token = data.get("appId") or data.get("token")
        if not self.token:
            raise CloudlineError("login succeeded but no token in response")
        return self.token

    def list_devices(self):
        """[{device_id, device_name, ports: [{port, port_name, online, ...}]}]"""
        data = self._request(DEVICE_LIST_URL, {"userId": self.token}, auth=True) or []
        devices = []
        for dev in data:
            ports = []
            for p in dev.get("deviceInfo", {}).get("ports", dev.get("ports", [])) or []:
                ports.append({
                    "port": p.get("port"),
                    "name": p.get("portName") or p.get("name") or f"Port {p.get('port')}",
                    "online": bool(p.get("online", p.get("loadState"))),
                    "speed": p.get("speak", p.get("speed")),
                })
            devices.append({
                "device_id": dev.get("devId") or dev.get("deviceId"),
                "name": dev.get("devName") or dev.get("deviceName"),
                "online": bool(dev.get("online", dev.get("devOnline", True))),
                "ports": ports,
            })
        return devices

    def get_port_settings(self, device_id, port):
        """Current mode settings for one port — set_speed() must resubmit
        this whole dict (minus the fields it overrides), since addDevMode
        appears to replace the full mode config rather than patch it."""
        return self._request(MODE_SETTINGS_URL, {"devId": device_id, "port": port}, auth=True) or {}

    def set_speed(self, device_id, port, speed):
        """speed: 0 (off) - 10 (max), manual mode."""
        speed = max(0, min(10, int(speed)))
        settings = dict(self.get_port_settings(device_id, port))
        settings.update({
            "devId": device_id,
            "port": port,
            "atType": AT_TYPE_MANUAL,
            "onSpeed": speed,
            "offSpeed": 0,
        })
        self._request(ADD_MODE_URL, settings, auth=True, in_query=True)
        return speed

    def turn_off(self, device_id, port):
        return self.set_speed(device_id, port, 0)
