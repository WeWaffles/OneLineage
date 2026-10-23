#!/system/bin/sh
# m308_lte.sh — mobile data for the normal Nura session (m81). Runs our rild client s26_rildata
# (app_process, replaces com.android.phone for data) and applies the calls it reports in rildata.state:
#   internet: link/mtu, addresses, LTE default routes at metric 700 (Wi-Fi from NM wins)
#   ims:      link/mtu, addresses only (no default route); P-CSCFs go to $S/ims.pcscf for the IMS client
# The client must stay alive: rild drops every call when its client goes. If it (or rild) dies, restart.
# Stop: kill $(cat $S/lte.pid)   (TERM also stops the client; rild then drops the calls)
S=/data/local/tmp/nura_stage
STATE=$S/rildata.state
INET=fast.t-mobile.com
METRIC=700
echo $$ > $S/lte.pid
log() { echo "$(date +%H:%M:%S) $*"; }

start_client() {
  rm -f $STATE $S/ims.pcscf
  CLASSPATH=$S/s26_rildata.dex app_process / S26RilData up $INET ims >> $S/rildata.log 2>&1 < /dev/null &
  CLIENT=$!
  log "client started ($CLIENT)"
}
trap 'kill $CLIENT 2>/dev/null; log "stopped"; exit 0' TERM INT

# (re)configure an interface from one CALL line: ifname= addrs= gws= mtu= pcscf=; $2 = routes yes/no
apply() {
  IF=; ADDRS=; GWS=; MTU=; PCSCF=
  for kv in $1; do
    case $kv in ifname=*) IF=${kv#*=};; addrs=*) ADDRS=${kv#*=};; gws=*) GWS=${kv#*=};; mtu=*) MTU=${kv#*=};; pcscf=*) PCSCF=${kv#*=};; esac
  done
  [ -n "$IF" ] || return
  [ "$MTU" -gt 0 ] 2>/dev/null && ip link set $IF mtu $MTU
  ip link set $IF up
  # a new call can bring new addresses: drop the previous call's so the source address is never stale
  ip addr flush dev $IF scope global
  for a in $(echo $ADDRS | tr ',' ' '); do
    case $a in *:*) ip -6 addr replace $a dev $IF nodad;; *) ip addr replace $a dev $IF;; esac
  done
  if [ "$2" = yes ]; then
    for g in $(echo $GWS | tr ',' ' '); do
      case $g in *:*) ip -6 route replace default via $g dev $IF metric $METRIC;; *) ip route replace default via $g dev $IF metric $METRIC;; esac
    done
  else
    # IMS: only the P-CSCFs go via this interface (host routes through its IPv6 gateway)
    G6=$(echo $GWS | tr ',' '\n' | grep : | head -n 1)
    for p in $(echo $PCSCF | tr ',' ' '); do
      case $p in *:*) ip -6 route replace $p via $G6 dev $IF;; *) ip route replace $p dev $IF;; esac
    done
  fi
  log "applied: $IF addrs=$ADDRS gws=$GWS mtu=$MTU routes=$2${PCSCF:+ pcscf=$PCSCF}"
}

# rild is restarted by init when its old client (com.android.phone) dies: wait for it to settle
sleep 5
start_client
LAST_INET=; LAST_IMS=
while true; do
  if ! kill -0 $CLIENT 2>/dev/null; then
    log "client exited (rild restart?) -> retry in 5 s"
    sleep 5; start_client; LAST_INET=; LAST_IMS=
  fi
  # only active calls (active=2) with an interface
  CUR=$(grep "apn=$INET " $STATE 2>/dev/null | grep 'active=2' | grep -v 'ifname=null' | head -n 1)
  if [ -n "$CUR" ] && [ "$CUR" != "$LAST_INET" ]; then apply "$CUR" yes; LAST_INET=$CUR; fi
  CUR=$(grep 'apn=ims ' $STATE 2>/dev/null | grep 'active=2' | grep -v 'ifname=null' | head -n 1)
  if [ -n "$CUR" ] && [ "$CUR" != "$LAST_IMS" ]; then
    apply "$CUR" no; LAST_IMS=$CUR
    # IMS client config: interface + P-CSCF list
    { echo "$CUR" | tr ' ' '\n' | grep -E '^(ifname|addrs|pcscf)='; } > $S/ims.pcscf
  fi
  sleep 3
done
