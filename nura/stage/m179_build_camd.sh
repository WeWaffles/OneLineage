#!/system/bin/sh
# m179_build_camd.sh — build s26_camd (Android camera -> NV12 FIFO, see s26_camd.c) like m164 (no NDK)
S=/data/local/tmp/nura_stage
R=$S/rootfs
mkdir -p $R/tmp/bionic $R/var/lib/s26cam; chmod 777 $R/var/lib/s26cam
for l in libc.so libcamera2ndk.so libmediandk.so libbinder_ndk.so; do cp -L /system/lib64/$l $R/tmp/bionic/$l; done
cp $S/s26_camd.c $R/tmp/bionic/
chroot $R /usr/bin/env -i PATH=/usr/bin:/bin sh -c '
  cd /tmp/bionic
  gcc -O2 -fPIE -pie -nostdlib -nostartfiles -ffreestanding -fno-stack-protector \
      -Wl,-dynamic-linker,/system/bin/linker64 -Wl,--hash-style=gnu -Wl,-z,noexecstack -Wl,--allow-shlib-undefined \
      -Wl,-z,max-page-size=16384 -o s26_camd s26_camd.c libc.so libcamera2ndk.so libmediandk.so libbinder_ndk.so' || exit 1
kill $(pidof s26_camd) 2>/dev/null; sleep 1
cp $R/tmp/bionic/s26_camd $S/s26_camd && chmod 755 $S/s26_camd && echo built
