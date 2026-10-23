#!/system/bin/sh
# m290_planB.sh — Plan B driver: run right after a normal One UI boot (framework alive).
# 1) wifi off + data on (so LTE is forced)  2) wait for Android's data call on rmnet_data0
# 3) verify data from the Android shell     4) launch pivot v2 (targeted stops, call survives)
S=/data/local/tmp/nura_stage
[ -n "$(pidof system_server)" ] || { echo "NO system_server — is One UI fully booted?"; exit 1; }
echo "== forcing LTE: wifi off, data on"
svc wifi disable
svc data enable
echo "== waiting up to 3 min for the data call (global addr on rmnet_data0)..."
i=0
while [ $i -lt 36 ]; do
  if ip -6 addr show dev rmnet_data0 2>/dev/null | grep -q "scope global"; then
    echo "DATA CALL UP (x${i} checks = $((i*5)) s)"; break
  fi
  sleep 5; i=$((i+1))
done
ip -6 addr show dev rmnet_data0 2>/dev/null | grep -q "scope global" || {
  echo "DATA CALL NEVER CAME UP — check: data plan, APN, coverage, airplane mode"; exit 1
}
echo "== snapshot:"
ip -6 addr show dev rmnet_data0
echo "== routes (all tables, rmnet_data0):"
/data/adb/ksu/bin/busybox ip -6 route show table all 2>/dev/null | grep rmnet_data0 | head -n 8
echo "== Android-side ping over the LTE iface (framework still alive):"
/data/adb/ksu/bin/busybox ping -6 -I rmnet_data0 -c 3 -W 4 2606:4700:4700::1111 2>&1 | tail -n 2
echo "== launching pivot v2 (m291) detached:"
setsid nohup sh $S/m291_pivotv2.sh > $S/m81.log 2>&1 < /dev/null &
echo "started; read $S/m81.log to follow"
