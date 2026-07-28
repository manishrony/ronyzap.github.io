# GPU Power Management Monitor

Monitors GPU temperatures every 20 minutes and caps power to 500W if any GPU exceeds 75°C.

## Deploy on each rig

```bash
# On rig 192.168.1.171 and 192.168.1.196:
git clone https://github.com/manishrony/ronyzap.github.io.git
cd ronyzap.github.io/gpu-monitor
sudo bash install.sh
```

## Watch live logs

```bash
tail -f /var/log/gpu_monitor.log
```

## Configure rental platform

Edit `/usr/local/bin/gpu_monitor.sh` and set:

```bash
RENTAL_PLATFORM="nicehash"   # or: vastai | runpod | none
NICEHASH_ORG_ID="your-org-id"
NICEHASH_KEY="your-api-key"
NICEHASH_SECRET="your-api-secret"
```

Then restart: `sudo systemctl restart gpu-monitor`

## Manual one-time GPU check

```bash
nvidia-smi --query-gpu=index,name,temperature.gpu,power.draw,power.limit,fan.speed \
  --format=csv,noheader,nounits
```

## Cooling card (AC Infinity Cloudline)

Separate from gpu_monitor.sh/gpu-monitor.service — see `cloudline/`. The
dashboard's Cooling card (status + manual 0-10 speed control) turns on as
soon as the `gpu-dashboard` service has these env vars set (e.g. via a
systemd `Environment=` override or an EnvironmentFile), no restart of
gpu-monitor.service required:

```bash
AC_INFINITY_EMAIL=you@example.com
AC_INFINITY_PASSWORD=yourpassword
```

Without them the card just stays hidden (`GET /api/cooling` returns
`{"enabled": false}`). Optional automatic temp-based speed control
(`cloudline/scheduler.py`) is a separate systemd service — see
`cloudline/deploy/deploy.sh` — that reads each Cloudline controller's own
ambient temperature (the same reading shown on the Cooling card) and
proportionally adjusts fan speed between `CLOUDLINE_MIN_TEMP_C` (fans at
`CLOUDLINE_MIN_SPEED`) and `CLOUDLINE_MAX_TEMP_C` (fans at 10), so they
throttle down automatically instead of running flat-out all the time.

Any port named per `CLOUDLINE_INTAKE_PORT_NAMES` (default `intake`, case-
insensitive substring match) is treated as pulling outside air in — that
port idles at `CLOUDLINE_INTAKE_MIN_SPEED` (default `0`, fully off) unless
outdoor temp is at least `CLOUDLINE_OUTDOOR_MARGIN_C` degrees cooler than
the room (default 4°C), since ramping up an intake fan when it's just as
hot or hotter outside imports heat instead of removing it. Every other
port (e.g. an exhaust/return fan) isn't outside-air-facing and just follows the plain
room-temp curve above.

### Metering the fans' own electricity use

The Cloudline fans aren't on the same PDU circuit as the GPUs, and the
AC Infinity API has no real wattage reporting (only speed 0-10) — so if you
want their actual power draw reflected in the dashboard's Power & Energy
totals, plug them into a TP-Link Tapo energy-monitoring smart plug (P110/
P115/P100) and point the scheduler at it:

```bash
CLOUDLINE_TAPO_HOST=192.168.1.x       # the plug's local IP
CLOUDLINE_TAPO_EMAIL=you@example.com  # TP-Link account (local-auth handshake only)
CLOUDLINE_TAPO_PASSWORD=yourpassword
CLOUDLINE_TAPO_RATE=0.25              # $/kWh, match your PDU's rate
```

Needs `pip3 install python-kasa` (same dependency `tapo-poll.py` already
uses for gpu_monitor.sh's own Tapo support). This reuses `tapo-poll.py`
completely unmodified — no gpu_monitor.sh changes — just calls it on its
own schedule (`CLOUDLINE_TAPO_POLL_INTERVAL`, default 300s) tagged with a
distinct rig name (`CLOUDLINE_TAPO_RIG_NAME`, default `<hostname>-cloudline`)
so its readings add to the fleet's power totals as their own meter instead
of colliding with the real rack PDU's own "zappa1"-tagged readings.
**Don't also set gpu_monitor.sh's own `TAPO_HOST` to this same plug** — that
would tag its events with the real hostname and mix fan wattage into the
rack PDU's own numbers, which is exactly what the distinct rig name above
avoids.

## Thresholds (edit gpu_monitor.sh to change)

| Variable | Default | Meaning |
|---|---|---|
| `TEMP_THRESHOLD` | 75 | °C — trigger throttle above this |
| `POWER_LIMIT_HIGH` | 500 | W — cap per GPU when triggered |
| `CHECK_INTERVAL` | 1200 | seconds (20 min) between checks |
