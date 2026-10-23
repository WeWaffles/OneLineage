#!/system/bin/sh
# m126_dogpet.sh — Nura pets Samsung's softdog (/dev/watchdog) in place of system_server.
# Without it the kernel panics ~11s after the panel turns off ("Software Watchdog Timer expired").
# stop cleanly (magic close 'V') before handing back to One UI: kill -TERM $(cat $S/dogpet.pid)
S=/data/local/tmp/nura_stage
echo $$ > $S/dogpet.pid
# Plan C (m305): the frozen system_server still holds it (one opener only) -> pet through its fd.
# Check for a holder BEFORE opening: a failed `exec 3>` makes sh exit on the spot (no `||` fallback).
for p in $(pidof system_server); do
  for fd in /proc/$p/fd/*; do
    if [ "$(readlink $fd)" = /dev/watchdog ]; then
      echo "$(date +%H:%M:%S) busy: stealing fd ${fd##*/} of system_server $p" >> $S/dogpet.log
      exec $S/s26_dogsteal $p ${fd##*/} >> $S/dogpet.log 2>&1
    fi
  done
done
echo "$(date +%H:%M:%S) opening /dev/watchdog" >> $S/dogpet.log
exec 3> /dev/watchdog
trap 'printf V >&3; exec 3>&-; echo "$(date +%H:%M:%S) released (magic close)" >> $S/dogpet.log; exit 0' TERM INT
echo "$(date +%H:%M:%S) petting" >> $S/dogpet.log
while true; do
  printf . >&3
  sleep 3 &
  wait $!   # (wait, not plain sleep, so TERM is handled immediately)
done
