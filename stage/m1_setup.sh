#!/system/bin/sh
# m1_setup.sh — M1: Alpine minirootfs chroot on the phone + toolchain + test tool build.
# Reversible: everything under /data/local/tmp/nura_stage. Run as root.
set -e
BB=/data/adb/ksu/bin/busybox
STAGE=/data/local/tmp/nura_stage
RFS=$STAGE/rootfs
TARBALL=$STAGE/alpine-minirootfs-3.24.2-aarch64.tar.gz

mkdir -p "$STAGE"

# --- extract (idempotent) ---
if [ ! -e "$RFS/etc/alpine-release" ]; then
  echo "[m1] extracting minirootfs..."
  mkdir -p "$RFS"
  tar -xzf "$TARBALL" -C "$RFS"
fi
echo "[m1] alpine-release: $(cat $RFS/etc/alpine-release)"

# --- mounts (idempotent) ---
grep -q " $RFS/dev " /proc/mounts || $BB mount --bind /dev "$RFS/dev"
mkdir -p "$RFS/dev/pts"
grep -q " $RFS/dev/pts " /proc/mounts || $BB mount -t devpts -o newinstance,ptmxmode=0666 devpts "$RFS/dev/pts"
mkdir -p "$RFS/proc" "$RFS/sys"
grep -q " $RFS/proc " /proc/mounts || $BB mount -t proc proc "$RFS/proc"
grep -q " $RFS/sys " /proc/mounts || $BB mount -t sysfs sys "$RFS/sys"

# --- DNS (share host netns) ---
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$RFS/etc/resolv.conf"

# --- source in ---
cp -f $STAGE/test_kms.c "$RFS/root/test_kms.c" 2>/dev/null || echo "[m1] WARN test_kms.c not found yet"

# --- apk bootstrap + toolchain + build ---
echo "[m1] apk bootstrap (needs internet; ~1-3 min)..."
chroot "$RFS" /bin/sh -c '
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  apk update
  apk add --no-cache build-base libdrm-dev pkgconf
  echo "[m1-apk] toolchain ready: $(gcc --version | head -1)"
  cd /root
  gcc -O2 -Wall -o /root/test_kms test_kms.c $(pkg-config --cflags libdrm) $(pkg-config --libs libdrm) || echo "[m1] FAIL: gcc build error, fix and retry"
  ls -l /root/test_kms 2>/dev/null
  echo "[m1-apk] done"
' || echo "[m1] chroot step failed — see above"

echo "[m1] M1 complete. test_kms binary: $RFS/root/test_kms"
