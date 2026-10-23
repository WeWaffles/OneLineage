#!/system/bin/sh
# m97_netup.sh — Nura-owned wifi once Android's framework is stopped:
#   vendor wpa_supplicant on wlan0 with nura_wpa.conf -> DHCP via Alpine udhcpc -> route via main table
S=/data/local/tmp/nura_stage
CHROOT=$S/rootfs
CONF=$S/nura_wpa.conf
[ -f $CONF ] || { echo "no $CONF - push it first"; exit 1; }
grep -q YOUR_WIFI_NAME $CONF && { echo "nura_wpa.conf still has the placeholder"; exit 1; }

# Android's supplicant/HAL client is gone with the framework; replace it
setprop ctl.stop wpa_supplicant 2>/dev/null
pkill -9 wpa_supplicant 2>/dev/null
sleep 1
# SELinux: the vendor supplicant domain can't read shell_data_file -> stage conf in /data/vendor/wifi/wpa
# with the same label/owner as Android's own wpa_supplicant.conf
W=/data/vendor/wifi/wpa
cp $CONF $W/nura_wpa.conf
sed -i "s#^ctrl_interface=.*#ctrl_interface=$W/nura_ctrl#" $W/nura_wpa.conf
chown wifi:wifi $W/nura_wpa.conf; chmod 660 $W/nura_wpa.conf
chcon --reference=$W/wpa_supplicant.conf $W/nura_wpa.conf 2>/dev/null || chcon u:object_r:vendor_wifi_data_file:s0 $W/nura_wpa.conf
mkdir -p $W/nura_ctrl; chown wifi:wifi $W/nura_ctrl; chcon --reference=$W/sockets $W/nura_ctrl 2>/dev/null
ip link set wlan0 up
WPA=$(ls /vendor/bin/hw/wpa_supplicant /system/bin/wpa_supplicant 2>/dev/null | head -n 1)
$WPA -B -i wlan0 -D nl80211 -c $W/nura_wpa.conf -P $S/wpa.pid 2>&1 | tail -n 3
sleep 1
logcat -d -s wpa_supplicant | grep -E " E wpa_supplicant" | grep -viE "psk|passphrase" | tail -n 3
echo "wpa_supplicant: $(pidof wpa_supplicant)"

# wait for association (no iw on Android -> ask the supplicant)
CLI="wpa_cli -p $W/nura_ctrl -i wlan0"
$CLI reconfigure >/dev/null 2>&1
$CLI scan >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  $CLI status 2>/dev/null | grep -q "wpa_state=COMPLETED" && break
  sleep 2
done
echo "link: $($CLI status 2>&1 | grep -E 'wpa_state|^ssid' | tr '\n' ' ')"
echo "networks: $($CLI list_networks 2>&1 | tail -n +2 | cut -f2,4 | tr '\n' ' ')"

# DHCP from the chroot (busybox udhcpc + Alpine's default.script sets addr, default route, resolv.conf)
ip addr flush dev wlan0
DH=$(chroot $CHROOT /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin udhcpc -i wlan0 -n -q -t 8 2>&1)
echo "$DH" | tail -n 3

# default.script's "route add default" fails here (Network unreachable) -> add it ourselves.
# Gateway = the DHCP server from the lease line (home routers serve both).
GW=$(echo "$DH" | sed -n 's/.*obtained from \([0-9.]*\).*/\1/p' | tail -n 1)
# (the connected subnet route isn't in main yet at this point -> host route to the gateway first)
if [ -n "$GW" ]; then
  ip route replace $GW dev wlan0 scope link table main
  ip route replace default via $GW dev wlan0 table main
fi

# Android policy routing: let everything fall through to the main table
ip rule del pref 31999 2>/dev/null
ip rule add pref 31999 from all lookup main
echo "route: $(ip route show table main | grep default)"
ping -c 1 -W 4 1.1.1.1 >/dev/null 2>&1 && echo "NET: OK" || echo "NET: FAIL"
