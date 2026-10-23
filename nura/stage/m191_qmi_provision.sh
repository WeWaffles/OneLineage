#!/system/bin/sh
# m191_qmi_provision.sh — Nura: provision the eSIM USIM (physical slot 2) as the PRIMARY GW subscription so
# single-SIM Linux tools (qmicli/ModemManager) see it. Runtime only: Android re-provisions when telephony starts.
# usage: m191 [primary|secondary]   (secondary = Android's layout)
S=/data/local/tmp/nura_stage
AID=A0:00:00:00:87:10:02:FF:FF:FF:FF:89:06:19:00:00
/data/adb/ksu/bin/busybox nsenter -t $(pidof phosh) -m chroot $S/rootfs /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root sh -c "
  q() { timeout 10 qmicli -d qrtr://0 \"\$@\" 2>&1 | head -n 6; }
  if [ '${1:-primary}' = primary ]; then
    q --uim-change-provisioning-session='session-type=secondary-gw-provisioning,activate=no,slot=2,aid=$AID'
    q --uim-change-provisioning-session='session-type=primary-gw-provisioning,activate=yes,slot=2,aid=$AID'
  else
    q --uim-change-provisioning-session='session-type=primary-gw-provisioning,activate=no,slot=2,aid=$AID'
    q --uim-change-provisioning-session='session-type=secondary-gw-provisioning,activate=yes,slot=2,aid=$AID'
  fi
  sleep 3; q --uim-get-card-status | head -n 6
  for i in 1 2 3 4 5 6; do
    sleep 5
    echo \"-- \$((i*5)) s\"; timeout 10 qmicli -d qrtr://0 --nas-get-serving-system 2>&1 | grep -e 'Registration state' -e 'PS:' -e 'Current PLMN' -A0 | head -n 4
  done"
