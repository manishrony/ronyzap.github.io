#!/bin/bash
# Health check for the watchdog daemon. Drops the realtime priority inherited
# from the daemon so it fails when ordinary processes are starved, then checks
# uncached rootfs I/O and that sshd still answers with a banner.
chrt -o -p 0 $$ 2>/dev/null

f=/var/tmp/.wd-io-probe
dd if=/dev/urandom of="$f" bs=4k count=1 oflag=direct,sync status=none || exit 1
dd if="$f" of=/dev/null bs=4k count=1 iflag=direct status=none || exit 1

banner=$(timeout 15 head -c 4 </dev/tcp/127.0.0.1/22) || exit 2
[ "$banner" = "SSH-" ] || exit 2
exit 0
