#!/system/bin/sh
# m126_dogpet.sh — Nura pets Samsung's softdog (/dev/watchdog) in place of system_server.
# Without it the kernel panics ~11s after the panel turns off ("Software Watchdog Timer expired").
# stop cleanly (magic close 'V') before handing back to One UI: kill -TERM $(cat $S/dogpet.pid)
S=/data/local/tmp/nura_stage
echo $$ > $S/dogpet.pid
exec 3> /dev/watchdog || { echo "$(date +%H:%M:%S) cannot open /dev/watchdog" >> $S/dogpet.log; exit 1; }
trap 'printf V >&3; exec 3>&-; echo "$(date +%H:%M:%S) released (magic close)" >> $S/dogpet.log; exit 0' TERM INT
echo "$(date +%H:%M:%S) petting" >> $S/dogpet.log
while true; do
  printf . >&3
  sleep 3 &
  wait $!   # (wait, not plain sleep, so TERM is handled immediately)
done
