# zappa1 cross-rig triage watcher (Tier 1: read-only)

Runs a local Claude Code session on zappa1 that automatically triages a
hardware fault (PCI SERR / MCE / critical threshold) on any of the three
rigs the moment `gpu_monitor.sh`'s `check_bmc_sel_faults()` detects one, and
sends a short Telegram report. It is **read-only** — it cannot restart,
reboot, or modify anything on any rig; see `settings.json` and
`TRIAGE_PROMPT.md` for the enforced boundary.

This exists because this remote/cloud Claude session has no network path to
your LAN (confirmed: outbound SSH is blocked from that sandbox regardless of
destination). zappa1, already your dashboard/PDU hub with real LAN access,
is where an agent can actually SSH into zappa2/zappa3 and act.

## What it does, end to end

1. `check_bmc_sel_faults()` on any rig (already deployed to all three)
   detects a new SEL hardware fault, sends its own Telegram alert as before,
   **and now also** drops a small JSON incident file under
   `/var/tmp/gpu_monitor_incidents/`.
2. `watch_incidents.sh`, on a cron schedule on zappa1, checks its own
   incident directory plus zappa2/zappa3's (over a dedicated read-only SSH
   key) for anything not yet processed.
3. For each new incident, it runs `claude -p` headlessly with
   `TRIAGE_PROMPT.md` as the instructions and `settings.json` as the
   permission scope — a single one-shot triage pass, not a persistent
   session.
4. The agent gathers read-only context (SEL history, dmesg, sensor
   readings, whether a rental was active, whether other rigs show the same
   fault) and sends a short Telegram summary via `tg_notify.sh` — the only
   way it's allowed to reach Telegram at all.

## One-time setup on zappa1

```bash
# 1. Auth persists across headless runs once you log in interactively once
claude login

# 2. Generate a DEDICATED key for this automation -- do not reuse your
#    personal key. This key should only ever be used for this.
ssh-keygen -t ed25519 -f ~/.ssh/zappa1_triage_ro -N ""

# 3. Add the PUBLIC half to zappa2 and zappa3's authorized_keys.
#    Prefer restricting it with a forced command so even a fully
#    compromised key can't get an interactive shell -- e.g. in
#    authorized_keys on zappa2/zappa3:
#      command="/home/ronyzap/ronyzap.github.io/gpu-monitor/triage/ssh_ro_shell.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA...zappa1_triage_ro
#    (see ssh_ro_shell.sh below -- write it before wiring this up if you
#    want the forced-command restriction; it's optional but recommended)
cat ~/.ssh/zappa1_triage_ro.pub
# -> copy this, append to zappa2:~/.ssh/authorized_keys and zappa3's

# 4. Add convenience aliases so watch_incidents.sh's `ssh zappa2`/`ssh
#    zappa3` calls resolve correctly, in ~/.ssh/config on zappa1:
cat >> ~/.ssh/config <<'EOF'
Host zappa2
    HostName 192.168.1.196
    User ronyzap
    IdentityFile ~/.ssh/zappa1_triage_ro
    IdentitiesOnly yes

Host zappa3
    HostName 192.168.1.211
    User ronyzap
    IdentityFile ~/.ssh/zappa1_triage_ro
    IdentitiesOnly yes
EOF

# 5. Test SSH works before wiring up cron
ssh zappa2 "echo ok from zappa2"
ssh zappa3 "echo ok from zappa3"

# 6. Test one manual triage run before automating it
mkdir -p /var/tmp/gpu_monitor_incidents
echo '{"ts":"test","host":"zappa1","sel_record_id":"test","entries":"TEST: PCI SERR (manual trigger, not a real fault)"}' \
    > /var/tmp/gpu_monitor_incidents/test.json
bash /home/ronyzap/ronyzap.github.io/gpu-monitor/triage/watch_incidents.sh
tail -50 /var/log/zappa1_triage.log
# confirm you got a Telegram message, then:
rm /var/tmp/gpu_monitor_incidents/test.json

# 7. Install the cron job
crontab -e
# add:
*/2 * * * * /home/ronyzap/ronyzap.github.io/gpu-monitor/triage/watch_incidents.sh
```

## Why Tier 1 only, for now

This is deliberately scoped to read-only diagnostics + a Telegram report —
no restart/redeploy/fix capability at all, not even in a
draft-for-your-approval form yet. The plan (see conversation with Claude)
is to run this for a while, see how accurate and useful the triage reports
are, and only then consider adding a Tier 2 (drafts a suggested fix command
for you to approve and run yourself — never auto-executed). Review the cost
(API usage per incident), the false-positive rate, and whether the SSH key
restriction is actually holding up before expanding scope.

## Files in this directory

- `settings.json` — the Tier-1 permission scope (deny-by-default, narrow
  allow-list, explicit deny-list as defense-in-depth)
- `TRIAGE_PROMPT.md` — instructions given to the headless Claude run each
  time; repeats the read-only boundary as a second layer on top of
  `settings.json`
- `watch_incidents.sh` — the cron entry point; polls for new incidents
  locally and on peers, launches one triage run per incident
- `tg_notify.sh` — the only sanctioned path to Telegram; reads the token
  from `/etc/gpu_monitor.conf` itself so the agent never needs it directly

## Maintenance notes

- If you add a 4th rig, add it to `PEERS` in `watch_incidents.sh` and give
  it the same SSH setup.
- If zappa1 itself goes down, this whole watcher goes down with it — it has
  no redundancy. The existing cross-rig heartbeat (in `gpu_monitor.sh`)
  still covers "zappa1 itself went unreachable" independently of this.
- Watch `/var/log/zappa1_triage.log` occasionally for the watcher script's
  own health — a silently-broken cron job (bad path, expired auth, revoked
  key) fails closed (no reports), which is easy to not notice.
