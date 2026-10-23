#!/system/bin/sh
# m174_build_fakeam.sh — build s26_fakeam (stand-in "activity" binder service, see s26_fakeam.c) like m164
S=/data/local/tmp/nura_stage
R=$S/rootfs
mkdir -p $R/tmp/bionic
for l in libc.so libbinder_ndk.so; do cp -L /system/lib64/$l $R/tmp/bionic/$l; done
cp $S/s26_fakeam.c $R/tmp/bionic/
chroot $R /usr/bin/env -i PATH=/usr/bin:/bin sh -c '
  cd /tmp/bionic
  gcc -O2 -fPIE -pie -nostdlib -nostartfiles -ffreestanding -fno-stack-protector -fno-builtin \
      -Wl,-dynamic-linker,/system/bin/linker64 -Wl,--hash-style=gnu -Wl,-z,noexecstack -Wl,--allow-shlib-undefined \
      -Wl,-z,max-page-size=16384 -o s26_fakeam s26_fakeam.c libc.so libbinder_ndk.so' || exit 1
cp $R/tmp/bionic/s26_fakeam $S/s26_fakeam && chmod 755 $S/s26_fakeam && echo built
