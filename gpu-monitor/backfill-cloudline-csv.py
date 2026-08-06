#!/usr/bin/env python3
"""One-off: convert an AC Infinity app CSV export (Device -> Export Data)
into an OpenMetrics file with real historical timestamps, for import into
Prometheus via `promtool tsdb create-blocks-from openmetrics` — same
mechanism as backfill-prometheus.py, but for Cloudline room climate instead
of GPU/rental data (which the AC Infinity cloud API has no history endpoint
for; the app's own CSV export is the only source of the pre-existing data).

The CSV's own "Time" column is in whatever local timezone the phone/app
was set to when it exported — NOT UTC — so --tz is required and must be a
real IANA zone name (e.g. America/New_York).

Expected format (AC Infinity app, Device -> ... -> Export Data):
    "Device ID","Basement Room","",""
    "Export Time","08/05/2026 10:37:41 PM","",
    "Sample Frequency","1 MIN","",
    "Start Time","06/17/2026 1:10:00 PM","",
    "End Time","08/05/2026 10:37:37 PM","",
    "Temperature Units","°F","",
    "Leaf Temperature Offset","0","",
    "","","",""
    "Time","Temperature","Relative Humidity","VPD"
    "","","",""
    "07/27/2026 1:10 PM","84.60","47.24","2.14"
    "","","",""
    ...
(blank row between every data row; header block size can vary by app
version, so this locates the "Time","Temperature",... header row instead
of assuming a fixed line count.)

Usage (run once, on the box you'll later run promtool from — doesn't need
to be a rig, just needs the CSV and Python 3.9+ for zoneinfo):
    python3 backfill-cloudline-csv.py \
        --csv AC_INFINITY_Data.csv \
        --tz America/New_York \
        --location basement \
        --out /tmp/cloudline-backfill.om

Then on the hub (where Prometheus runs):
    promtool tsdb create-blocks-from openmetrics /tmp/cloudline-backfill.om /tmp/cloudline-blocks
    sudo systemctl stop prometheus
    sudo cp -r /tmp/cloudline-blocks/* /var/lib/prometheus/metrics2/
    sudo chown -R prometheus:prometheus /var/lib/prometheus/metrics2
    sudo systemctl start prometheus

Metric names/labels intentionally match prom_exporter.py's live Cloudline
metrics (room_temp_celsius{location,device}, room_humidity_percent) so the
backfilled history and live-going-forward data form one continuous series
in Grafana, not two disjoint ones.
"""
import argparse
import csv
import sys
from datetime import datetime
from zoneinfo import ZoneInfo


def _f_to_c(f):
    return (f - 32.0) * 5.0 / 9.0


class OMWriter:
    def __init__(self):
        self._order = []
        self._meta = {}
        self._samples = {}

    def add(self, name, mtype, help_text, labels, value, epoch):
        if name not in self._meta:
            self._meta[name] = (mtype, help_text)
            self._samples[name] = []
            self._order.append(name)
        self._samples[name].append((labels, value, epoch))

    def write(self, fh):
        for name in self._order:
            mtype, help_text = self._meta[name]
            fh.write(f"# HELP {name} {help_text}\n")
            fh.write(f"# TYPE {name} {mtype}\n")
            for labels, value, epoch in sorted(self._samples[name], key=lambda s: s[2]):
                label_str = ",".join(f'{k}="{v}"' for k, v in labels.items())
                fh.write(f"{name}{{{label_str}}} {value} {int(epoch)}\n")
        fh.write("# EOF\n")


def parse_csv(path, tz):
    with open(path, newline="", errors="replace") as fh:
        rows = list(csv.reader(fh))

    device_name = "Basement Room"
    header_idx = None
    for i, row in enumerate(rows):
        cells = [c.strip() for c in row]
        if cells and cells[0] == "Device ID" and len(cells) > 1 and cells[1]:
            device_name = cells[1]
        if cells[:2] == ["Time", "Temperature"]:
            header_idx = i
            break
    if header_idx is None:
        sys.exit("Couldn't find the 'Time,Temperature,...' header row — is this an AC Infinity export CSV?")

    zone = ZoneInfo(tz)
    samples = []  # (epoch, temp_c, humidity_pct, vpd_kpa)
    skipped = 0
    for row in rows[header_idx + 1:]:
        cells = [c.strip().strip('"') for c in row]
        if len(cells) < 3 or not cells[0]:
            continue  # blank separator rows
        time_str, temp_str, hum_str = cells[0], cells[1], cells[2]
        vpd_str = cells[3] if len(cells) > 3 else ""
        try:
            dt_local = datetime.strptime(time_str, "%m/%d/%Y %I:%M %p").replace(tzinfo=zone)
            epoch = dt_local.timestamp()
            temp_f = float(temp_str)
            humidity = float(hum_str)
        except (ValueError, TypeError):
            skipped += 1
            continue
        vpd_kpa = None
        if vpd_str:
            try:
                vpd_kpa = float(vpd_str)
            except ValueError:
                pass
        samples.append((epoch, _f_to_c(temp_f), humidity, vpd_kpa))

    return device_name, samples, skipped


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csv", required=True, help="AC Infinity app CSV export")
    ap.add_argument("--tz", required=True, help="IANA timezone the CSV's timestamps are in, e.g. America/New_York")
    ap.add_argument("--location", default="basement", help="location label value (default: basement)")
    ap.add_argument("--out", required=True, help="Output .om file")
    args = ap.parse_args()

    device_name, samples, skipped = parse_csv(args.csv, args.tz)
    if not samples:
        sys.exit("No usable data rows found in the CSV.")

    w = OMWriter()
    labels_base = {"location": args.location, "device": device_name}
    for epoch, temp_c, humidity, vpd_kpa in samples:
        w.add("room_temp_celsius", "gauge", "Cloudline controller's ambient temperature reading.", labels_base, round(temp_c, 2), epoch)
        w.add("room_humidity_percent", "gauge", "Cloudline controller's ambient humidity reading.", labels_base, humidity, epoch)
        if vpd_kpa is not None:
            w.add("room_vpd_kpa", "gauge", "Cloudline controller's computed vapor pressure deficit (kPa).", labels_base, vpd_kpa, epoch)

    with open(args.out, "w") as fh:
        w.write(fh)

    first_ts = datetime.fromtimestamp(min(s[0] for s in samples)).isoformat()
    last_ts = datetime.fromtimestamp(max(s[0] for s in samples)).isoformat()
    print(f"Wrote {len(samples)} samples ({first_ts} .. {last_ts}, local time) to {args.out}", file=sys.stderr)
    if skipped:
        print(f"Skipped {skipped} unparseable rows.", file=sys.stderr)


if __name__ == "__main__":
    main()
