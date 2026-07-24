#!/usr/bin/env bash
#
# diag.sh — RonyZap GPU rig diagnostic (zappa1 / zappa2 / zappa3)
# Usage:  sudo ./diag.sh            # full report to stdout
#         sudo ./diag.sh | tee /tmp/diag_$(hostname)_$(date +%Y%m%d_%H%M).txt
#
# Read-only. Runs no repricing, starts/stops nothing. Safe to run anytime.

set -uo pipefail

LOG=/var/log/gpu_monitor.log
DATA=/var/log/gpu_monitor_data.jsonl
GRACE_SEC=3600

sec() { printf '\n\033[1m════ %s ════\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "RonyZap diag — host=$(hostname) — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ── 1. GPU state ─────────────────────────────────────────────
sec "1. GPU state (nvidia-smi)"
if have nvidia-smi; then
  nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,power.draw,power.limit,memory.used,memory.total,pstate \
    --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', ' '{printf "  GPU %s | %s | %s°C | util %s%% | %sW/%sW | %s/%s MiB | %s\n",$1,$2,$3,$4,$5,$6,$7,$8,$9}'
  echo "  -- processes --"
  nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory,process_name --format=csv,noheader 2>/dev/null \
    | sed 's/^/  /' || echo "  (none)"
else
  echo "  nvidia-smi not found"
fi

# ── 2. Throttle monitor state ────────────────────────────────
sec "2. Throttle state (busy-since files)"
now=$(date +%s); found=0
for f in /var/tmp/gpu_monitor_gpu_busy_since_*; do
  [ -e "$f" ] || continue
  found=1
  idx="${f##*gpu_monitor_gpu_busy_since_}"
  since=$(cat "$f" 2>/dev/null)
  [[ "$since" =~ ^[0-9]+$ ]] || { echo "  GPU $idx: unreadable ($f)"; continue; }
  elapsed=$(( now - since )); remaining=$(( GRACE_SEC - elapsed ))
  if (( remaining <= 0 )); then
    echo "  GPU $idx: busy $((elapsed/60))m — THROTTLED (past grace ~$((elapsed/60-60))m ago)"
  else
    echo "  GPU $idx: busy $((elapsed/60))m — throttle in ~$((remaining/60))m"
  fi
done
(( found == 0 )) && echo "  no busy-since files — nothing tracked toward throttle"
echo "  -- recent WORKLOAD THROTTLE lines --"
grep -a "WORKLOAD THROTTLE" "$LOG" 2>/dev/null | tail -5 | sed 's/^/  /' || true

# ── 3. Vast machine / rental snapshot ────────────────────────
sec "3. Vast machine snapshot (dump-machine-json)"
if have dump-machine-json; then
  dump-machine-json 2>/dev/null | grep -A0 -E \
    "num_gpus|gpu_occupancy|earn_hour|earn_day|listed_gpu_cost|min_bid_price|cur_state|rentable|end_date|client_run" \
    | sed 's/^/  /'
else
  echo "  dump-machine-json not found"
fi

# ── 4. Rental record the monitor has logged ──────────────────
sec "4. Monitor's rental record (last 3 rental_start)"
if [ -r "$DATA" ]; then
  grep -a '"type": "rental_start"' "$DATA" 2>/dev/null | tail -3 | sed 's/^/  /'
  echo "  -- last 3 data-log lines (any type) --"
  tail -3 "$DATA" 2>/dev/null | sed 's/^/  /'
else
  echo "  $DATA not readable"
fi

# ── 5. Pricing engine: erroring or just skipping? ────────────
sec "5. Pricing engine activity (last 40 relevant)"
if [ -r "$LOG" ]; then
  grep -a -E "Pricing Check|target\(|vacant=|price updated|idle-mode|ERROR|Traceback|Exception|skip" "$LOG" \
    2>/dev/null | tail -40 | sed 's/^/  /'
  echo
  # empty-block detector: Pricing Check immediately followed by End with nothing between
  echo "  -- empty vs non-empty pricing checks (last 20 pairs) --"
  awk '/--- Pricing Check ---/{s=NR; buf=""}
       /--- End Pricing Check ---/{ if(NR==s+1) empty++; else nonempty++ }
       END{printf "  empty=%d  non-empty=%d\n", empty+0, nonempty+0}' "$LOG"
else
  echo "  $LOG not readable"
fi

# ── 6. Monitor service health ───────────────────────────────
sec "6. Monitor service / process health"
if have systemctl; then
  for u in gpu-monitor gpu-dashboard; do
    st=$(systemctl is-active "$u" 2>/dev/null); en=$(systemctl is-enabled "$u" 2>/dev/null)
    echo "  $u: active=$st enabled=$en"
    echo "  -- journal: $u (last 12) --"
    journalctl -u "$u" --no-pager -n 12 2>/dev/null | sed 's/^/    /'
  done
fi
echo "  -- running processes --"
ps -eo pid,etime,cmd 2>/dev/null | grep -i -E "gpu[-_]monitor|gpu[-_]dashboard|vast" | grep -v grep | sed 's/^/  /' || echo "  (none matched)"

# ── 7. Deploy targets + repo git state (for cross-rig sync) ───
sec "7. Deploy targets + repo git state"
for p in /usr/local/bin/gpu_monitor.sh /opt/gpu-monitor/dashboard; do
  [ -e "$p" ] && ls -la "$p" 2>/dev/null | sed 's/^/  /'
done
echo "  -- config override (/etc/gpu_monitor.conf) --"
grep -a -E "WORKLOAD_THROTTLE_LIMITS|GPU_POWER_OVERRIDE" /etc/gpu_monitor.conf 2>/dev/null | sed 's/^/  /' || echo "  (no throttle/power override in conf — using script defaults)"
echo "  -- repo HEAD (compare across rigs) --"
REPO=/home/ronyzap/ronyzap.github.io
if [ -d "$REPO/.git" ]; then
  git -C "$REPO" log -1 --oneline 2>/dev/null | sed 's/^/  /'
  git -C "$REPO" status -s 2>/dev/null | sed 's/^/  /' || true
  echo "  deployed gpu_monitor.sh matches repo: $(cmp -s "$REPO/gpu-monitor/gpu_monitor.sh" /usr/local/bin/gpu_monitor.sh 2>/dev/null && echo yes || echo 'NO — needs deploy')"
else
  echo "  repo not found at $REPO"
fi

# ── 8. System hygiene ────────────────────────────────────────
sec "8. System hygiene"
echo "  uptime:$(uptime -p 2>/dev/null | sed 's/up //')"
echo "  disk /: $(df -h / | awk 'NR==2{print $5" used, "$4" free"}')"
echo "  load:  $(cut -d' ' -f1-3 /proc/loadavg)"
if have nvidia-smi; then
  echo "  driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
fi
echo

echo "diag complete — $(date -u '+%H:%M:%S UTC')"
