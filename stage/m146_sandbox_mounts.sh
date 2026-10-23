#!/system/bin/sh
# m146_sandbox_mounts.sh — per-boot mounts that let Flatpak's bwrap work in the guest (called by m81)
#  1. rootfs bind-mounted onto itself: bwrap needs "/" to be a mount point (a plain chroot dir -> EINVAL)
#  2. setuid bwrap 0.10 from the suid-capable image (m142/m143) -> /usr/libexec/bwrap-suid
#  3. s26_bwrap_wrap (drops PID/IPC/user ns the kernel lacks, incl. inside --args FD; m150) -> /usr/bin/bwrap
S=/data/local/tmp/nura_stage
R=$S/rootfs
M=$S/suidmnt
[ -f $S/suid.img ] || { echo "sandbox: no suid.img (run m142/m143)"; exit 0; }
grep -qE " $R (ext4|f2fs) " /proc/mounts || mount --rbind $R $R
mkdir -p $M
grep -q " $M " /proc/mounts || mount -o loop,suid $S/suid.img $M
touch $R/usr/libexec/bwrap-suid
grep -q " $R/usr/libexec/bwrap-suid " /proc/mounts || mount --bind $M/bwrap $R/usr/libexec/bwrap-suid
[ -x $R/usr/local/bin/bwrap-wrap ] || { echo "sandbox: no bwrap-wrap (run m150)"; exit 0; }
grep -q " $R/usr/bin/bwrap " /proc/mounts && umount $R/usr/bin/bwrap
mount --bind $R/usr/local/bin/bwrap-wrap $R/usr/bin/bwrap
#  4. setuid fusermount3: installs as "user" go through flatpak-system-helper's revokefs-fuse
cmp -s $R/usr/bin/fusermount3 $M/fusermount3 || { cp $R/usr/bin/fusermount3 $M/fusermount3; chown 0:0 $M/fusermount3; chmod 4755 $M/fusermount3; }
grep -q " $R/usr/bin/fusermount3 " /proc/mounts || mount --bind $M/fusermount3 $R/usr/bin/fusermount3
echo "sandbox: $(ls -l $R/usr/libexec/bwrap-suid | cut -c1-10) bwrap-suid, wrapper on /usr/bin/bwrap, $(ls -l $M/fusermount3 | cut -c1-10) fusermount3"
