#!/system/bin/sh
# m162_fpgl_branches.sh — the GL.kgsl extension is per runtime GL branch; mirror the 26.08 build (m157/m159) to the
# other branches Flathub apps use (hardlinked, no extra space)
E=/data/local/tmp/nura_stage/rootfs/var/lib/flatpak/extension/org.freedesktop.Platform.GL.kgsl/aarch64
for br in 24.08 25.08; do
  [ -d $E/$br ] || cp -al $E/26.08 $E/$br
done
ls $E
