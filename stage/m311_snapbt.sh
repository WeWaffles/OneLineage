#!/bin/sh
# m311_snapbt.sh (run via m161_insess.sh) — attach gdb to the running (hung) Snapshot; dump the
# GStreamer streaming threads only (Mesa/GLib worker threads are idle noise)
P=$(pgrep -x snapshot | head -n 1)
[ -n "$P" ] || { echo "no snapshot running"; exit 1; }
echo "snapshot pid $P"
timeout 90 gdb -batch -p $P -ex "set pagination off" -ex "thread apply all bt 25" 2>/dev/null > /tmp/snapbt.txt
awk '/^Thread /{keep = ($0 !~ /gdrv|zfq|zcq|zcfq|traceq|disk\$|gl0|pool-spawner|gmain|gdbus|dconf|fontcon|gldisplay|zbus|threaded-ml|async-io/)} keep' /tmp/snapbt.txt \
  | grep -E '^Thread|^#' | sed -e 's/ (.*) at / at /' | cut -c1-150 | head -n 220
