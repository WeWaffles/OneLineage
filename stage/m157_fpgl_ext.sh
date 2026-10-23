#!/system/bin/sh
# m157_fpgl_ext.sh — build an unmanaged flatpak GL extension "kgsl" (org.freedesktop.Platform.GL.kgsl) from lfdevs'
# Debian/glibc Mesa (has kgsl_dri) + the Debian libs it needs that the Flathub runtime lacks; then ldd it in the sandbox.
# Flatpak mounts it at /usr/lib/aarch64-linux-gnu/GL/kgsl when FLATPAK_GL_DRIVERS=kgsl.
S=/data/local/tmp/nura_stage
R=$S/rootfs
chroot $R /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin sh -c '
  set -e
  for br in 26.08; do
    E=/var/lib/flatpak/extension/org.freedesktop.Platform.GL.kgsl/aarch64/$br
    rm -rf $E; mkdir -p $E/lib $E/glvnd/egl_vendor.d $E/vulkan/icd.d $E/share
    M=/tmp/mesa_deb/usr
    cp -a $M/lib/aarch64-linux-gnu/* $E/lib/
    mkdir -p $E/lib/gbm; ln -sf ../dri/kgsl_dri.so $E/lib/gbm/dri_gbm.so 2>/dev/null || true
    cp -a /tmp/debx/usr/lib/aarch64-linux-gnu/lib*.so* $E/lib/
    for x in /tmp/debextra/*.so*; do [ -e "$x" ] && cp -a $x $E/lib/; done
    cp $M/share/glvnd/egl_vendor.d/50_mesa.json $E/glvnd/egl_vendor.d/
    sed "s#\"library_path\": \"[^\"]*/#\"library_path\": \"/usr/lib/aarch64-linux-gnu/GL/kgsl/lib/#" $M/share/vulkan/icd.d/freedreno_icd.aarch64.json > $E/vulkan/icd.d/freedreno_icd.aarch64.json
    cp -a $M/share/drirc.d $E/share/
    [ -f /usr/local/lib/s26_glfinish_glibc.so ] && cp /usr/local/lib/s26_glfinish_glibc.so $E/lib/s26_glfinish.so
    du -sh $E
  done'
# FLATPAK_GL_DRIVERS=kgsl puts our extension in front of GL.default
cat > $S/fpgl_ldd.sh <<'EOF'
export HOME=/home/user XDG_RUNTIME_DIR=/run/user/1000 FLATPAK_GL_DRIVERS=kgsl
timeout 30 flatpak run --device=all --command=sh org.gnome.Calculator -c '
  L=/usr/lib/aarch64-linux-gnu/GL/kgsl/lib; ls $L >/dev/null && echo "ext mounted"
  for f in $L/libEGL_mesa.so.0 $L/libgallium-26.3.0-devel.so $L/dri/kgsl_dri.so $L/libvulkan_freedreno.so; do
    [ -e $f ] && ldd $f | grep "not found" | sed "s#^#$(basename $f): #"
  done; ls -l /dev/kgsl-3d0' 2>&1 | grep -v "^F:"
EOF
cp $S/fpgl_ldd.sh $R/tmp/fpgl_ldd.sh
/data/adb/ksu/bin/busybox unshare -m --propagation slave chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin su -s /bin/sh user -c 'sh /tmp/fpgl_ldd.sh'
