#!/system/bin/sh
# m182_build_pwcam.sh — build s26-pwcam (PipeWire camera node, s26_pwcam.c) in the chroot -> /usr/local/bin
S=/data/local/tmp/nura_stage
R=$S/rootfs
cp $S/s26_pwcam.c $R/tmp/s26_pwcam.c
/data/adb/ksu/bin/busybox nsenter -t $(pidof phosh) -m chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -c '
  apk add -q pipewire-dev 2>&1 | tail -n 2
  gcc -O2 -Wall -o /usr/local/bin/s26-pwcam /tmp/s26_pwcam.c $(pkg-config --cflags --libs libpipewire-0.3) && echo built'
