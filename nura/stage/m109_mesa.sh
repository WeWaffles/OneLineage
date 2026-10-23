#!/system/bin/sh
# m109_mesa.sh — install lfdevs mesa-for-android-container (turnip on KGSL) into the guest + smoke test
# backup of every file it overwrites: $S/mesa_backup.tar.gz (restore: tar -xzf it -C rootfs)
S=/data/local/tmp/nura_stage
R=$S/rootfs
T=$S/mesa.tar.gz
if [ ! -f $S/mesa_backup.tar.gz ]; then
  tar -tzf $T | grep -v '/$' | sed 's#^\./##' | while read f; do [ -e "$R/$f" ] && echo "$f"; done > $S/mesa_overwrite.lst
  (cd $R && tar -czf $S/mesa_backup.tar.gz -T $S/mesa_overwrite.lst) && echo "backup: $(wc -l < $S/mesa_overwrite.lst) files"
fi
tar -xzf $T -C $R && echo "extracted"
ls $R/usr/lib/dri | grep -iE "kgsl|msm|zink"
chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -c '
  ldconfig / 2>/dev/null
  apk add vulkan-tools mesa-utils 2>&1 | tail -n 1
  echo "--- vulkan"; vulkaninfo --summary 2>&1 | grep -E "deviceName|driverName|driverInfo|apiVersion|ERROR|rror" | head -n 8
  echo "--- egl (kgsl)"; MESA_LOADER_DRIVER_OVERRIDE=kgsl eglinfo -B -p surfaceless 2>&1 | grep -E "renderer|version string|rror" | head -n 5
  echo "--- egl (zink)"; MESA_LOADER_DRIVER_OVERRIDE=zink eglinfo -B -p surfaceless 2>&1 | grep -E "renderer|version string|rror" | head -n 5'
