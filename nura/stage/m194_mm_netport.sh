#!/system/bin/sh
# m194_mm_netport.sh — tell ModemManager that rmnet_ipa0 (Android vendor IPA driver, not mainline "ipa") is the
# QRTR modem's net port, then restart MM and look again
S=/data/local/tmp/nura_stage
R=$S/rootfs
mkdir -p $R/etc/udev/rules.d
cat > $R/etc/udev/rules.d/77-s26-modem.rules <<'EOF'
# Nura: the SoC modem (QRTR, MM "qcom-soc" device) uses the vendor IPA netdev rmnet_ipa0 for data;
# it is a virtual netdev, which MM filters out unless ID_MM_DEVICE_PROCESS is set; Android already holds QMAP mux
# ids 1..15 (rmnet_data0..14), so MM starts its own links at mux 20; its links (qmapmux*) are virtual too
SUBSYSTEM=="net", KERNEL=="rmnet_ipa0|qmapmux*", ENV{ID_MM_CANDIDATE}="1", ENV{ID_MM_DEVICE_PROCESS}="1", ENV{ID_MM_PHYSDEV_UID}="qcom-soc", ENV{ID_MM_INITIAL_QMAP_MUX_ID}="20"
EOF
/data/adb/ksu/bin/busybox nsenter -t $(pidof phosh) -m chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root sh -c '
  udevadm control --reload 2>&1; udevadm trigger --subsystem-match=net --sysname-match=rmnet_ipa0 --action=add 2>&1; udevadm settle -t 5
  udevadm info /sys/class/net/rmnet_ipa0 | grep -e ID_MM -e DRIVER
  for i in 1 2 3 4 5; do pkill ModemManager || break; sleep 1; done; pgrep -l ModemManager
  setsid nohup ModemManager --debug > /root/mm.log 2>&1 < /dev/null &
  sleep 25
  mmcli -L 2>&1
  mmcli -m any 2>&1 | grep -v "^ *-*$" | head -n 50
  echo "== log"; grep -i -e "net port" -e rmnet -e "couldnt" -e "couldn.t" -e wrn /root/mm.log | tail -n 15'
