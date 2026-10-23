#!/system/bin/sh
# m291_pivotv2.sh — S26 Phosh session v2 (Plan B): TARGETED stop — rild/ipacm/netd/audioserver
# stay alive so Android's live LTE data call (rmnet_data0) survives the pivot; we reuse it as-is.
CHROOT=/data/local/tmp/nura_stage/rootfs
BB=/data/adb/ksu/bin/busybox

grep -q " $CHROOT/dev " /proc/mounts || $BB mount --bind /dev "$CHROOT/dev"
mkdir -p "$CHROOT/dev/pts"
grep -q " $CHROOT/dev/pts " /proc/mounts || $BB mount -t devpts -o newinstance,ptmxmode=0666 devpts "$CHROOT/dev/pts"
grep -q " $CHROOT/proc " /proc/mounts || $BB mount -t proc proc "$CHROOT/proc"
grep -q " $CHROOT/sys " /proc/mounts || $BB mount -t sysfs sys "$CHROOT/sys"
mkdir -p "$CHROOT/dev/shm" 2>/dev/null
grep -q " $CHROOT/dev/shm " /proc/mounts || $BB mount -t tmpfs -o size=256m tmpfs "$CHROOT/dev/shm"
# Flatpak sandbox (setuid bwrap on a suid image + ns-dropping wrapper)
sh /data/local/tmp/nura_stage/m146_sandbox_mounts.sh

# sec_touchscreen: libinput calls it a touchpad -> force touchscreen via udev (replaces the kwin-only TSP shim)
mkdir -p $CHROOT/etc/udev/rules.d
cat > $CHROOT/etc/udev/rules.d/90-s26-touch.rules <<'EOF'
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="sec_touchscreen", ENV{ID_INPUT_TOUCHPAD}="", ENV{ID_INPUT_MOUSE}="", ENV{ID_INPUT_TOUCHSCREEN}="1"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="haechitech-digital-hall", ENV{LIBINPUT_IGNORE_DEVICE}="1"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="sec_touchproximity", ENV{LIBINPUT_IGNORE_DEVICE}="1"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="sec_touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
EOF

# phoc: only the real panel (DSI-1); phantom VIRTUAL connectors off
mkdir -p $CHROOT/etc/phosh
cat > $CHROOT/etc/phosh/phoc.ini <<'EOF'
[core]
xwayland=false

[output:DSI-1]
scale=2.5

[output:Virtual-1]
enable=false

[output:Virtual-2]
enable=false
EOF

chroot $CHROOT /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -c 'for p in kwin_wayland plasmashell kded6 kactivitymanagerd maliit-keyboard phoc phosh squeekboard gnome-session sway foot seatd dbus-daemon; do pkill -9 $p; done 2>/dev/null; sleep 1; rm -f /run/xdg/wayland-* /run/xdg/bus'

# wake Android first or the touch controller stays asleep
svc power stayon true
input keyevent KEYCODE_WAKEUP
sleep 2

# v2 (Plan B): NO blanket `stop`. Targeted stops only — the UI/framework stack dies,
# but rild, ipacm, netd, audioserver, camera HALs survive and keep the LTE data call up.
setprop ctl.stop zygote
setprop ctl.stop zygote_secondary
setprop ctl.stop vendor.qti.hardware.display.composer
setprop ctl.stop vendor.qti.hardware.display.allocator
setprop ctl.stop surfaceflinger
setprop ctl.stop cameraserver
setprop ctl.stop wificond
setprop ctl.stop wifi
kill -9 $(pidof surfaceflinger) 2>/dev/null
kill -9 $(pidof vendor.qti.hardware.display.composer-service) 2>/dev/null
kill -9 $(pidof system_server) 2>/dev/null
sleep 1
echo 2000 > /sys/class/backlight/panel0-backlight/brightness 2>/dev/null

# snapshot the surviving LTE state into the session log (visible evidence the call survived)
echo "== LTE after targeted stop:"
ip -6 addr show dev rmnet_data0 2>/dev/null | grep -m1 "scope global"
ip -6 rule show 2>/dev/null | head -n 6
echo "== rild/netd/ipacm still up: rild=$(pidof rild) netd=$(pidof netd) ipacm=$(pidof ipacm)"

# Networking: the framework is stopped, so Nura owns wifi. NetworkManager (started in the chroot below,
# after the system bus) drives Alpine's wpa_supplicant so Phosh can show/choose networks.
# Android's vendor supplicant must be gone first. m97_netup.sh is the no-NM fallback.
setprop ctl.stop wpa_supplicant 2>/dev/null
pkill -9 wpa_supplicant 2>/dev/null
ip addr flush dev wlan0
ip link set wlan0 up
# Android policy routing: let everything fall through to the main table (where NM puts its routes)
ip rule del pref 31999 2>/dev/null
ip rule add pref 31999 from all lookup main

mkdir -p $CHROOT/usr/local/libexec
cp /data/local/tmp/nura_stage/m106_user_session.sh $CHROOT/usr/local/libexec/s26-user-session
chmod 755 $CHROOT/usr/local/libexec/s26-user-session
# Nura side of the camera (PipeWire nodes fed by s26_camd), started by the user session
cp /data/local/tmp/nura_stage/s26_camfeed.sh $CHROOT/usr/local/libexec/s26-camfeed
chmod 755 $CHROOT/usr/local/libexec/s26-camfeed
mkdir -p $CHROOT/var/lib/s26cam; chmod 777 $CHROOT/var/lib/s26cam

# own mount namespace, slave propagation: Android's /data is shared, and bwrap's pivot_root (Flatpak) refuses
# under a shared parent. Android mounts still flow in; nothing mounted inside leaks back out.
$BB unshare -m --propagation slave chroot $CHROOT /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root XDG_RUNTIME_DIR=/run/xdg \
  WLR_RENDERER=pixman \
  XDG_CURRENT_DESKTOP=Phosh:GNOME \
  XDG_SESSION_DESKTOP=phosh \
  XDG_SESSION_TYPE=wayland \
  GDK_BACKEND=wayland \
  WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
  /bin/sh -c '
    mkdir -p /run/dbus /run/xdg; chmod 700 /run/xdg
    pgrep udevd >/dev/null || udevd --daemon
    udevadm control --reload; udevadm trigger; udevadm settle
    TS=$(grep -l "^sec_touchscreen$" /sys/class/input/event*/device/name | head -n 1 | cut -d/ -f5)
    echo "touch udev ($TS): $(udevadm info /dev/input/$TS | grep -E "ID_INPUT_TOUCH" | tr "\n" " ")"
    # seat group: lets "user" (phoc) open DRM/input through seatd
    SEATD_VTBOUND=0 setsid nohup seatd -g seat >/root/seatd.log 2>&1 &
    sleep 1
    # stale pid/socket from an earlier session blocks the system bus -> gnome-control-center aborts without it
    rm -f /run/dbus/dbus.pid /run/dbus/system_bus_socket
    # /data is nosuid -> dbus-daemon-launch-helper (setuid) can never activate upower/polkit/login1.
    # Run the system bus as root with no servicehelper so it fork/execs activated services itself.
    # (must live in /usr/share/dbus-1: its relative <includedir>system.d</includedir> holds the service policies)
    sed -e "/<user>/d" -e "/<servicehelper>/d" /usr/share/dbus-1/system.conf > /usr/share/dbus-1/s26-system.conf
    dbus-daemon --config-file=/usr/share/dbus-1/s26-system.conf --fork || echo "system dbus FAILED"
    # SAFETY: elogind must never suspend/poweroff the shared Android kernel
    mkdir -p /etc/elogind/logind.conf.d
    printf "[Login]\nHandlePowerKey=ignore\nHandlePowerKeyLongPress=ignore\nHandleSuspendKey=ignore\nHandleHibernateKey=ignore\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\nIdleAction=ignore\n" > /etc/elogind/logind.conf.d/90-s26.conf
    mkdir -p /etc/elogind/sleep.conf.d
    printf "[Sleep]\nAllowSuspend=no\nAllowHibernation=no\nAllowSuspendThenHibernate=no\n" > /etc/elogind/sleep.conf.d/90-s26.conf
    # logind (elogind) for phosh screensaver/suspend; upower for battery
    setsid nohup /usr/libexec/elogind/elogind >/root/elogind.log 2>&1 &
    # polkit: "user" (wheel) gets wifi/installs without a password (rule from m105_user.sh)
    pgrep polkitd >/dev/null || setsid nohup /usr/lib/polkit-1/polkitd --no-debug >/root/polkit.log 2>&1 &
    sleep 2
    # S26 Nura Plan B: NEVER let NM touch the Android-owned LTE interface (it would flush the call config)
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-s26-rmnet.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:rmnet_data0,interface-name:rmnet_data1,interface-name:rmnet_data2,interface-name:rmnet_data3,interface-name:rmnet_data4,interface-name:rmnet_data5,interface-name:rmnet_data6,interface-name:rmnet_data7,interface-name:rmnet_data8,interface-name:rmnet_data9,interface-name:rmnet_data10,interface-name:rmnet_data11,interface-name:rmnet_data12,interface-name:rmnet_data13,interface-name:rmnet_data14,interface-name:rmnet_ipa0
EOF
    # wifi: Alpine wpa_supplicant on D-Bus (-u) + NetworkManager
    pkill -9 NetworkManager 2>/dev/null; rm -f /run/wpa_supplicant/wlan0
    setsid nohup wpa_supplicant -u -s >/root/wpa.log 2>&1 &
    sleep 1
    setsid nohup NetworkManager --no-daemon >/root/nm.log 2>&1 &
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      nmcli -t -f STATE general 2>/dev/null | grep -q "^connected" && break
      sleep 2
    done
    echo "wifi: $(nmcli -t -f DEVICE,STATE,CONNECTION device 2>&1 | grep wlan0)"
    ping -c 1 -W 4 1.1.1.1 >/dev/null 2>&1 && echo "NET: OK" || echo "NET: FAIL (fallback: m97_netup.sh)"
    # ---- S26 Nura Plan B LTE test: Android brought the data call up; it must still be alive here
    IF=rmnet_data0
    A=$(ip -6 addr show dev $IF 2>/dev/null | grep -m1 "scope global" | tr -s " " | cut -d" " -f3)
    echo "LTE addr on $IF: $A"
    if [ -n "$A" ]; then
      GW=$(ip -6 route show table all 2>/dev/null | grep -m1 "default via" | grep "dev $IF" | tr -s " " | cut -d" " -f3)
      echo "LTE gw: $GW"
      ip -6 route replace default via $GW dev $IF metric 700 2>/dev/null || ip -6 route replace default dev $IF metric 700 2>/dev/null
      echo "LTE ping: $(ping -6 -I $IF -c 3 -W 4 2606:4700:4700::1111 2>&1 | tail -n 1)"
      echo "LTE counters: tx=$(cat /sys/class/net/$IF/statistics/tx_packets) rx=$(cat /sys/class/net/$IF/statistics/rx_packets)"
      echo "LTE dns: $(nslookup example.com 2606:4700:4700::1111 2>&1 | tail -n 3 | tr "\n" " ")"
    else
      echo "LTE FAIL: no global address on rmnet_data0 (call did not survive the pivot)"
    fi
    # ---- end LTE test
    echo "power svcs: polkit=$(pgrep polkitd) upowerd=$(pgrep upowerd) elogind=$(pgrep elogind)"
    upower -i /org/freedesktop/UPower/devices/DisplayDevice 2>&1 | grep -E "percentage|state"
    # Files/Software refuse to run as root -> the graphical session runs as "user" (m105_user.sh)
    mkdir -p /run/user/1000; chown user:user /run/user/1000; chmod 700 /run/user/1000
    chmod 1777 /tmp /dev/shm
    rm -f /run/user/1000/wayland-* /run/user/1000/bus
    echo "seatd: $(pgrep -l seatd | head -n 1)"
    su -s /bin/sh user -c /usr/local/libexec/s26-user-session
  '
# temperature log every 30s -> therm.log (m124_thermlog.sh)
# (pid files survive reboots -> only kill if that pid is still our script)
killold() { p=$(cat /data/local/tmp/nura_stage/$1.pid 2>/dev/null); [ -n "$p" ] && grep -q "$2" /proc/$p/cmdline 2>/dev/null && kill $p; }
killold thermlog m124_thermlog
setsid nohup sh /data/local/tmp/nura_stage/m124_thermlog.sh >/dev/null 2>&1 < /dev/null &

# Samsung softdog: system_server pets /dev/watchdog; with it stopped the kernel panics ~11s after
# the panel turns off ("Software Watchdog Timer expired"). Nura pets it instead (m77 hands it back).
killold dogpet m126_dogpet
setsid nohup sh /data/local/tmp/nura_stage/m126_dogpet.sh >/dev/null 2>&1 < /dev/null &
# Phosh blanks on the power key but misses the wake direction -> m132 re-asserts it over D-Bus
killold powerkeyd m132_powerkeyd
setsid nohup sh /data/local/tmp/nura_stage/m132_powerkeyd.sh >/dev/null 2>&1 < /dev/null &
# real sleep: suspend the kernel while Phosh has the panel off (m113_sleepd.sh)
killold sleepd m113_sleepd
setsid nohup sh /data/local/tmp/nura_stage/m113_sleepd.sh >/dev/null 2>&1 < /dev/null &
# audio: PulseAudio pipe sink (m106) -> FIFO -> s26_audiobridge (bionic, m164) -> AAudio -> audioserver -> HAL
start audioserver
pkill -f s26_audiobridge
setsid nohup /data/local/tmp/nura_stage/s26_audiobridge > /data/local/tmp/nura_stage/audiobridge.log 2>&1 < /dev/null &
# camera: allocator + stand-in system_server services + cameraserver (m175)
sh /data/local/tmp/nura_stage/m175_camstack.sh > /data/local/tmp/nura_stage/camstack.log 2>&1
# one s26_camd per camera (0 = back, 1 = front); each opens its camera only while Nura's s26-camfeed asks for it
kill $(pidof s26_camd) 2>/dev/null
[ -f $CHROOT/var/lib/s26cam/res ] || echo "1920 1440" > $CHROOT/var/lib/s26cam/res
read CW CH < $CHROOT/var/lib/s26cam/res
for c in back:0 front:1; do
  n=${c%%:*}
  setsid nohup /data/local/tmp/nura_stage/s26_camd ${c#*:} $CHROOT/var/lib/s26cam/$n.fifo $CHROOT/var/lib/s26cam/$n.want $CW $CH \
    > /data/local/tmp/nura_stage/camd-$n.log 2>&1 < /dev/null &
done
echo "=== panel:$(cat /sys/class/drm/card0-DSI-1/enabled) $(cat /sys/class/drm/card0-DSI-1/dpms)"
