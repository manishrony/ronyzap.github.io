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
`{"enabled": false}`). Optional automatic temp-based speed control is a
separate systemd service — see `cloudline/deploy/deploy.sh` — and needs
`cloudline/scheduler.py`'s `read_temp_c()` wired to a real sensor before
enabling it.

## Thresholds (edit gpu_monitor.sh to change)

| Variable | Default | Meaning |
|---|---|---|
| `TEMP_THRESHOLD` | 75 | °C — trigger throttle above this |
| `POWER_LIMIT_HIGH` | 500 | W — cap per GPU when triggered |
| `CHECK_INTERVAL` | 1200 | seconds (20 min) between checks |
