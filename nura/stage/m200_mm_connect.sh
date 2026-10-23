#!/system/bin/sh
# m200_mm_connect.sh — mobile data via ModemManager: simple-connect on T-Mobile's APN, show the bearer
S=/data/local/tmp/nura_stage
/data/adb/ksu/bin/busybox nsenter -t $(pidof phosh) -m chroot $S/rootfs /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root sh -c '
  timeout 60 mmcli -m any --simple-connect="apn=${1:-fast.t-mobile.com},ip-type=ipv4v6" 2>&1
  B=$(mmcli -m any 2>/dev/null | grep -o "/Bearer/[0-9]*" | tail -n 1 | grep -o "[0-9]*$")
  echo "bearer=$B"; [ -n "$B" ] && mmcli -b $B 2>&1 | grep -v "^ *-*$" | head -n 40
  echo "== log"; grep -e "<wrn>" -e "<err>" -e "bearer" -e "rmnet" -e "link" /var/log/mm.log | grep -v -e "radio interface" | tail -n 20 | cut -c1-220'
