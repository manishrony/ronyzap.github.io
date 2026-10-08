#!/bin/bash
# Fails if the root filesystem can't complete an uncached write+read — the
# path that wedges during the silent hangs while PID1 stays alive.
f=/var/tmp/.wd-io-probe
dd if=/dev/urandom of="$f" bs=4k count=1 oflag=direct,sync status=none || exit 1
dd if="$f" of=/dev/null bs=4k count=1 iflag=direct status=none || exit 1
