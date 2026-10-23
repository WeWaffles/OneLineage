#!/system/bin/sh
# m132_powerkeyd.sh — power key pressed while the panel is off -> make sure it comes back (m131_unblank.sh)
# (Phosh blanks fine on its own; it's the wake direction it misses)
S=/data/local/tmp/nura_stage
D=/sys/class/drm/card0-DSI-1/dpms
echo $$ > $S/powerkeyd.pid
P=$(for e in /sys/class/input/event*; do [ "$(cat $e/device/name)" = pmic_pwrkey ] && echo /dev/input/${e##*/}; done)
# (single-device getevent omits the device column: lines are "EV_KEY KEY_POWER DOWN")
getevent -l $P | while read line; do
  case "$line" in *KEY_POWER*DOWN*) ;; *) continue;; esac
  was=$(cat $D)
  sleep 1
  if [ "$was" = "Off" ] && [ "$(cat $D)" = "Off" ]; then
    sh $S/m131_unblank.sh
    echo "$(date +%H:%M:%S) power key, panel was off -> unblank: $(cat $D)" >> $S/powerkeyd.log
  fi
done
