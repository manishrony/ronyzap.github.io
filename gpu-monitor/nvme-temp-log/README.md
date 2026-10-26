# OS NVMe temperature logger (zappa2)

## Why

zappa2's silent hangs are the OS NVMe (Crucial T705, `00:01.4`) dropping off
the PCIe bus (console capture 2026-10-25: `SDES` on `00:01.4`, then
`nvme0n1` I/O errors). Once the drive is gone nothing more reaches the
journal, so there is no record of the drive's state just before the drop.

This logs the drive's composite temperature and its thermal-throttle
transition counters (T1/T2) every 30s to `/var/log/nvme-temp.log`, with a
`sync` after each line so the readings up to the moment of the drop survive
the hard reset.

```
2026-10-26 11:50:07 47 T1=455 T2=209
```

## Reading it after a hang

```
tail -40 /var/log/nvme-temp.log
```

- Temp climbing toward 80 °C+ and T1/T2 rising in the last minutes →
  heat-driven; a heatsink/airflow fix is the answer.
- Flat (~45–60 °C) with unchanged T1/T2 up to the last line → not thermal;
  points at the Gen5 link or the drive itself (force Gen4 / replace drive).

## Deploy (as root, from the repo clone)

```
install -m 755 gpu-monitor/nvme-temp-log/nvme-temp-log.sh /usr/local/sbin/nvme-temp-log.sh
cp gpu-monitor/nvme-temp-log/nvme-temp-log.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now nvme-temp-log
systemctl restart nvme-temp-log    # picks up a new script if already running
sleep 35; tail -2 /var/log/nvme-temp.log
```

The log grows ~3 MB/month; trim it with `truncate -s 0 /var/log/nvme-temp.log`
if it ever matters.
