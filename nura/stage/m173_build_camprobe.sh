#!/system/bin/sh
# m173_build_camprobe.sh — build s26_camprobe like m164 (chroot gcc + device libs, no NDK) and run it
# usage: m173 [camera-id] [width height]
S=/data/local/tmp/nura_stage
R=$S/rootfs
mkdir -p $R/tmp/bionic
for l in libc.so libcamera2ndk.so libmediandk.so libbinder_ndk.so; do cp -L /system/lib64/$l $R/tmp/bionic/$l; done
cp $S/s26_camprobe.c $R/tmp/bionic/
chroot $R /usr/bin/env -i PATH=/usr/bin:/bin sh -c '
  cd /tmp/bionic
  gcc -O2 -fPIE -pie -nostdlib -nostartfiles -ffreestanding -fno-stack-protector -fno-builtin \
      -Wl,-dynamic-linker,/system/bin/linker64 -Wl,--hash-style=gnu -Wl,-z,noexecstack -Wl,--allow-shlib-undefined \
      -Wl,-z,max-page-size=16384 -o s26_camprobe s26_camprobe.c libc.so libcamera2ndk.so libmediandk.so libbinder_ndk.so' || exit 1
cp $R/tmp/bionic/s26_camprobe $S/s26_camprobe && chmod 755 $S/s26_camprobe
echo "cameraserver: $(getprop init.svc.cameraserver)"
rm -f $S/cam.bmp
timeout 30 $S/s26_camprobe ${1:-0} $S/cam.bmp $2 $3; echo "rc=$?"
ls -l $S/cam.bmp 2>/dev/null
