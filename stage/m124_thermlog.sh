#!/system/bin/sh
# m124_thermlog.sh — temperature log every 30s while Nura runs -> $S/therm.log (keeps last ~2000 lines)
# columns: time  battery°C  hottest-zone°C(name)  loadavg  panel
S=/data/local/tmp/nura_stage
L=$S/therm.log
echo $$ > $S/thermlog.pid
while true; do
  bat=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
  hot=0; hn=?
  for z in /sys/class/thermal/thermal_zone*; do
    t=$(cat $z/temp 2>/dev/null) || continue
    # skip bogus/virtual readings (negative or >150°C)
    [ "$t" -gt "$hot" ] 2>/dev/null && [ "$t" -lt 150000 ] && { hot=$t; hn=$(cat $z/type); }
  done
  echo "$(date '+%m-%d %H:%M:%S') bat=$((bat/10)).$((bat%10))C hot=$((hot/1000))C($hn) load=$(cut -d' ' -f1-3 /proc/loadavg) panel=$(cat /sys/class/drm/card0-DSI-1/dpms)" >> $L
  [ $(wc -l < $L) -gt 2200 ] && { tail -n 2000 $L > $L.tmp; mv $L.tmp $L; }
  sleep 30
done
