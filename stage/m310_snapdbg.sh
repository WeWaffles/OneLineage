#!/bin/sh
# m310_snapdbg.sh (run via m161_insess.sh) — relaunch Snapshot with debug logging to /tmp/snap.log
export HOME=/home/user XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 GDK_BACKEND=wayland
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
export GST_PLUGIN_FEATURE_RANK=v4l2h264enc:NONE,v4l2h265enc:NONE,v4l2vp8enc:NONE,v4l2vp9enc:NONE
export G_MESSAGES_DEBUG=all RUST_LOG=debug GST_DEBUG=2,camerabin:4,encodebin:4,GST_ELEMENT_FACTORY:3
pkill -x snapshot; sleep 1
setsid nohup snapshot > /tmp/snap.log 2>&1 < /dev/null &
echo "snapshot started: $!"
