#!/system/bin/sh
# m150_build_bwrapwrap.sh — build s26_bwrap_wrap in the guest -> /usr/local/bin/bwrap-wrap, then remount
S=/data/local/tmp/nura_stage
R=$S/rootfs
cp $S/s26_bwrap_wrap.c $R/tmp/
grep -q " $R/usr/bin/bwrap " /proc/mounts && umount $R/usr/bin/bwrap
rm -f $R/usr/local/bin/bwrap-wrap
chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -c '
  gcc -O2 -Wall -o /usr/local/bin/bwrap-wrap /tmp/s26_bwrap_wrap.c && echo built'
sh $S/m146_sandbox_mounts.sh
