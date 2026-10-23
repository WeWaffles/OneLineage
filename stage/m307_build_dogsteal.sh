#!/system/bin/sh
# m307_build_dogsteal.sh — build s26_dogsteal (static musl) in the chroot; works without a running session
S=/data/local/tmp/nura_stage
R=$S/rootfs
BB=/data/adb/ksu/bin/busybox
for d in dev proc sys; do grep -q " $R/$d " /proc/mounts || $BB mount --bind /$d $R/$d; done
cp $S/s26_dogsteal.c $R/tmp/
chroot $R /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin gcc -static -O2 -o /tmp/s26_dogsteal /tmp/s26_dogsteal.c || exit 1
cp $R/tmp/s26_dogsteal $S/s26_dogsteal && chmod 755 $S/s26_dogsteal
ls -l $S/s26_dogsteal
