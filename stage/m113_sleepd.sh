#!/system/bin/sh
# m113_sleepd.sh — Nura sleep daemon (Android side, root). Phosh blanks the panel on power key / idle;
# this suspends the kernel once the panel has been off for a while, the way Android's framework would.
#   - wakeup_count handshake: never suspend while a wake event is in flight
#   - woken by the power key but panel still off -> press it for Phosh so the screen comes back
#   - woken by anything else (wifi, modem, alarm) -> go back to sleep after GRACE seconds
# stop: kill $(cat $S/sleepd.pid)   log: $S/sleepd.log
S=/data/local/tmp/nura_stage
D=/sys/class/drm/card0-DSI-1/dpms
GRACE=10
PWR=$(for e in /sys/class/input/event*; do [ "$(cat $e/device/name)" = pmic_pwrkey ] && echo /dev/input/${e##*/}; done)
echo $$ > $S/sleepd.pid
log() { echo "$(date +%H:%M:%S) $*" >> $S/sleepd.log; }
# wake event in flight: log who holds it (at most once a minute)
lastbusy=0
busy() {
  now=$(date +%s); [ $((now - lastbusy)) -lt 60 ] && return; lastbusy=$now
  log "busy: $(for w in /sys/class/wakeup/*; do [ "$(cat $w/active_time 2>/dev/null)" != "0" ] && echo "$(cat $w/name)($(($(cat $w/active_time)/1000))s)"; done 2>/dev/null | head -n 8 | tr '\n' ' ')"
}
log "start pwrkey=$PWR"
off=0
while true; do
  sleep 2
  if [ "$(cat $D)" != "Off" ]; then off=0; continue; fi
  off=$((off + 2))
  [ $off -lt $GRACE ] && continue
  # Phosh session gone (back in One UI etc.) -> don't touch power
  pidof phoc >/dev/null || { off=0; continue; }
  # userspace wakelocks orphaned by the stopped framework (e.g. zygote_kwl) block suspend forever
  for wl in $(cat /sys/power/wake_lock); do
    case $wl in zygote*|PowerManager*|system_server*|SurfaceFlinger*)
      echo $wl > /sys/power/wake_unlock; log "released orphan wakelock $wl";;
    esac
  done
  c=$(timeout 3 cat /sys/power/wakeup_count) || { busy; continue; }
  echo $c > /sys/power/wakeup_count 2>/dev/null || continue
  log "suspend"
  echo mem > /sys/power/state 2>/dev/null || { log "suspend aborted"; continue; }
  why=$(cat /sys/kernel/wakeup_reasons/last_resume_reason 2>/dev/null | tr '\n' ' ')
  log "resume: $why"
  off=0
  if echo "$why" | grep -qiE "pwrkey|pon|power"; then
    # Phosh normally gets the waking keypress itself; give it time (pressing too early toggled it back off)
    t=""; for i in 1 2 3 4 5 6; do sleep 1; s=$(cat $D); t="$t $s"; [ "$s" = "On" ] && break; done
    log "pwrkey wake, panel:$t"
    if [ "$s" != "On" ]; then
      sh $S/m131_unblank.sh
      sleep 1
      log "unblank via phosh dbus -> panel $(cat $D)"
    fi
    sleep 5
  fi
done
