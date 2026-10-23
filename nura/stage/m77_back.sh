#!/system/bin/sh
# m77_back.sh — kill stuck apk + guest session, restore One UI display stack (wifi comes back with it)
CHROOT=/data/local/tmp/nura_stage/rootfs
S=/data/local/tmp/nura_stage
# Nura's Android-side helpers. dogpet gets TERM (not -9) so it does the watchdog magic close
# before system_server takes /dev/watchdog back.
for d in sleepd:m113_sleepd powerkeyd:m132_powerkeyd thermlog:m124_thermlog dogpet:m126_dogpet; do
  p=$(cat $S/${d%%:*}.pid 2>/dev/null); [ -n "$p" ] && grep -q "${d#*:}" /proc/$p/cmdline 2>/dev/null && kill -TERM $p
done
pkill -f "getevent -l" 2>/dev/null
pkill -f s26_audiobridge 2>/dev/null
# camera stand-ins (m175) hold names of surfaceflinger/system_server services: they must be gone before those start
kill $(pidof s26_camd) 2>/dev/null
kill $(pidof s26_fakeam) 2>/dev/null
setprop ctl.stop cameraserver
pkill -9 apk 2>/dev/null
# phoc holds DRM master -> must die or surfaceflinger comes back to a black panel.
# Whole user session + Nura's wifi (NM/wpa) + seat/login services go with it.
# Kill by "runs inside the chroot", never by uid: guest uid 1000 is Android's `system` uid.
for p in /proc/[0-9]*; do
  [ "$(readlink $p/root)" = "$CHROOT" ] && kill -9 ${p##*/} 2>/dev/null
done
rm -f $CHROOT/lib/apk/db/lock
sleep 1
setprop ctl.start vendor.qti.hardware.display.allocator
sleep 1
setprop ctl.start vendor.qti.hardware.display.composer
sleep 1
setprop ctl.start surfaceflinger
sleep 1
# hand wifi back to Android, then restart the framework (paused by m81_phosh_session.sh)
kill $(cat /data/local/tmp/nura_stage/wpa.pid 2>/dev/null) 2>/dev/null
ip rule del pref 31999 2>/dev/null
start
setprop ctl.start cameraserver
svc power stayon false
# the framework comes back "Dozing" (black panel) -> wake it once it's up (detached: adb may blip meanwhile)
setsid nohup sh -c 'for i in $(seq 60); do sleep 2; dumpsys power 2>/dev/null | grep -q "mWakefulness=" && break; done; sleep 3; input keyevent KEYCODE_WAKEUP' >/dev/null 2>&1 < /dev/null &
echo done
