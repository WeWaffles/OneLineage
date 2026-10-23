#!/system/bin/sh
# m195_mm_debug.sh — ModemManager is D-Bus-activated (NetworkManager asks for it): make that instance log debug to
# /var/log/mm.log, restart it, and report what it found
S=/data/local/tmp/nura_stage
R=$S/rootfs
F=$R/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service
grep -q mm.log $F || sed -i 's#^Exec=.*#Exec=/bin/sh -c "exec /usr/sbin/ModemManager --debug >> /var/log/mm.log 2>\&1"#' $F
grep Exec $F
/data/adb/ksu/bin/busybox nsenter -t $(pidof phosh) -m chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root sh -c '
  : > /var/log/mm.log
  pkill ModemManager; sleep 2
  mmcli -L >/dev/null 2>&1; sleep 25
  mmcli -L 2>&1
  mmcli -m any 2>&1 | grep -v "^ *-*$" | head -n 50
  echo "== log"; grep -i -e "net port" -e rmnet -e "couldn.t" -e "<wrn>" /var/log/mm.log | grep -v -e mtk -e fibocom | tail -n 15'
