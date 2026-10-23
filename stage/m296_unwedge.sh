#!/system/bin/sh
# m296_unwedge.sh — unwedge the eSIM WITHOUT phosh: QMI provisioning session toggle (runtime only)
# primary-activate (modem wakes) -> back to secondary-activate (Android's layout), then watch for binding.
S=/data/local/tmp/nura_stage
R=$S/rootfs
BB=/data/adb/ksu/bin/busybox
AID=A0:00:00:00:87:10:02:FF:FF:FF:FF:89:06:19:00:00

# minimal chroot runtime (no phosh pid available in One UI)
grep -q " $R/dev " /proc/mounts || $BB mount --bind /dev $R/dev
mkdir -p $R/dev/pts
grep -q " $R/dev/pts " /proc/mounts || $BB mount -t devpts -o newinstance,ptmxmode=0666 devpts $R/dev/pts
grep -q " $R/proc " /proc/mounts || $BB mount -t proc proc $R/proc
grep -q " $R/sys " /proc/mounts || $BB mount -t sysfs sys $R/sys

q() { timeout 12 $BB chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LD_LIBRARY_PATH=/usr/lib /usr/bin/qmicli -d qrtr://0 "$@" 2>&1 | head -n 8; }

echo "== SIM status before:"
q --uim-get-card-status | head -n 6
echo "== activate PRIMARY (wake):"
q --uim-change-provisioning-session="session-type=secondary-gw-provisioning,activate=no,slot=2,aid=$AID"
q --uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=yes,slot=2,aid=$AID"
sleep 5
echo "== back to SECONDARY (Android layout):"
q --uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=no,slot=2,aid=$AID"
q --uim-change-provisioning-session="session-type=secondary-gw-provisioning,activate=yes,slot=2,aid=$AID"
sleep 5
echo "== card status now:"
q --uim-get-card-status | head -n 6
echo "== android side:"
getprop gsm.sim.state
