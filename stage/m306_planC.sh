#!/system/bin/sh
# m306_planC.sh — Plan C driver: run from a normal One UI boot. Makes sure Android holds the internet
# call (default data sub, cellular kept up next to Wi-Fi), then pivots with the framework frozen (m305).
S=/data/local/tmp/nura_stage
BB=/data/adb/ksu/bin/busybox
[ -n "$(pidof system_server)" ] || { echo "NO system_server — is One UI fully booted?"; exit 1; }
rm -f $S/frozen.pids
[ -x $S/s26_dogsteal ] || { echo "s26_dogsteal missing (m307): softdog would panic"; exit 1; }
# keep the cellular call up even while Wi-Fi is the default network
settings put global mobile_data_always_on 1
svc data enable
# Wi-Fi must be on at pivot time: with it off Android unloads the driver (RF-kill), and nothing can
# reload it once the framework is frozen
svc wifi enable
i=0; while [ $i -lt 20 ] && [ "$(getprop wlan.driver.status)" != "ok" ]; do sleep 1; i=$((i+1)); done
echo "wifi driver: $(getprop wlan.driver.status)"
if ! dumpsys isub | grep -q 'defaultDataSubId=[0-9]'; then
  echo "== defaultDataSubId unset -> m304_dds.sh"
  sh $S/m304_dds.sh
fi
echo "== waiting up to 2 min for the data call (global addr on rmnet_data0)..."
i=0
while [ $i -lt 24 ]; do
  ip -6 addr show dev rmnet_data0 2>/dev/null | grep -q "scope global" && break
  sleep 5; i=$((i+1))
done
ip -6 addr show dev rmnet_data0 2>/dev/null | grep -q "scope global" || { echo "DATA CALL NEVER CAME UP"; exit 1; }
echo "DATA CALL UP: $(ip -6 addr show dev rmnet_data0 | grep -m1 'scope global' | tr -s ' ' | cut -d' ' -f3)"
$BB ping -6 -I rmnet_data0 -c 2 -W 4 2606:4700:4700::1111 2>&1 | tail -n 2
echo "== launching pivot v3 (m305) detached:"
setsid nohup sh $S/m305_pivotv3.sh > $S/m81.log 2>&1 < /dev/null &
echo "started; read $S/m81.log to follow"
