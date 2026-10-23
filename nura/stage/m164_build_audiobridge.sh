#!/system/bin/sh
# m164_build_audiobridge.sh — build s26_audiobridge (Android/bionic binary) with the chroot's gcc, linking against the
# device's own libc.so + libaaudio.so (no NDK). Output: $S/s26_audiobridge
S=/data/local/tmp/nura_stage
R=$S/rootfs
mkdir -p $R/tmp/bionic $R/var/lib/s26audio; chmod 777 $R/var/lib/s26audio
for l in libc.so libaaudio.so libaudioclient.so; do cp -L /system/lib64/$l $R/tmp/bionic/$l; done
cp $S/s26_audiobridge.c $R/tmp/bionic/
chroot $R /usr/bin/env -i PATH=/usr/bin:/bin sh -c '
  cd /tmp/bionic
  gcc -O2 -fPIE -pie -nostdlib -nostartfiles -ffreestanding -fno-stack-protector -fno-builtin \
      -Wl,-dynamic-linker,/system/bin/linker64 -Wl,--hash-style=gnu -Wl,-z,noexecstack -Wl,--allow-shlib-undefined \
      -Wl,-z,max-page-size=16384 -o s26_audiobridge s26_audiobridge.c libc.so libaaudio.so libaudioclient.so && scanelf -n s26_audiobridge'
cp $R/tmp/bionic/s26_audiobridge $S/s26_audiobridge && chmod 755 $S/s26_audiobridge
echo "== smoke test"; $S/s26_audiobridge /nonexistent_dir/x; echo "rc=$?"
