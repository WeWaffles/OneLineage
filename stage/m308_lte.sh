#!/system/bin/sh
# m308_lte.sh — mobile data for the normal Nura session (m81). Runs our rild client s26_rildata
# (app_process, replaces com.android.phone for data) and applies the call it reports in rildata.state
# to the rmnet interface: link/mtu, addresses, LTE default routes at metric 700 (Wi-Fi from NM wins).
# The client must stay alive: rild drops every call when its client goes. If it (or rild) dies, restart.
# Stop: kill $(cat $S/lte.pid)   (TERM also stops the client; rild then drops the call)
S=/data/local/tmp/nura_stage
STATE=$S/rildata.state
METRIC=700
echo $$ > $S/lte.pid
log() { echo "$(date +%H:%M:%S) $*"; }

start_client() {
  rm -f $STATE
  CLASSPATH=$S/s26_rildata.dex app_process / S26RilData up >> $S/rildata.log 2>&1 < /dev/null &
  CLIENT=$!
  log "client started ($CLIENT)"
}
trap 'kill $CLIENT 2>/dev/null; log "stopped"; exit 0' TERM INT

# (re)configure an interface from one CALL line: ifname= addrs= gws= mtu=
apply() {
  IF=; ADDRS=; GWS=; MTU=
  for kv in $1; do
    case $kv in ifname=*) IF=${kv#*=};; addrs=*) ADDRS=${kv#*=};; gws=*) GWS=${kv#*=};; mtu=*) MTU=${kv#*=};; esac
  done
  [ -n "$IF" ] || return
  [ "$MTU" -gt 0 ] 2>/dev/null && ip link set $IF mtu $MTU
  ip link set $IF up
  # a new call can bring new addresses: drop the previous call's so the source address is never stale
  ip addr flush dev $IF scope global
  for a in $(echo $ADDRS | tr ',' ' '); do
    case $a in *:*) ip -6 addr replace $a dev $IF nodad;; *) ip addr replace $a dev $IF;; esac
  done
  for g in $(echo $GWS | tr ',' ' '); do
    case $g in *:*) ip -6 route replace default via $g dev $IF metric $METRIC;; *) ip route replace default via $g dev $IF metric $METRIC;; esac
  done
  log "applied: $IF addrs=$ADDRS gws=$GWS mtu=$MTU"
}

# rild is restarted by init when its old client (com.android.phone) dies: wait for it to settle
sleep 5
start_client
LAST=
while true; do
  if ! kill -0 $CLIENT 2>/dev/null; then
    log "client exited (rild restart?) -> retry in 5 s"
    sleep 5; start_client; LAST=
  fi
  # only active calls (active=2) with an interface
  CUR=$(grep 'active=2' $STATE 2>/dev/null | grep -v 'ifname=null' | head -n 1)
  if [ -n "$CUR" ] && [ "$CUR" != "$LAST" ]; then
    apply "$CUR"
    LAST=$CUR
  fi
  sleep 3
done
