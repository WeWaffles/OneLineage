#!/system/bin/sh
# m160_fpgl_enable.sh — make Flathub apps use the Adreno (GL.kgsl extension, m157/m159) by default:
# global system override = all devices (/dev/kgsl-3d0 isn't under /dev/dri), kgsl Mesa driver, glibc glFinish shim.
# FLATPAK_GL_DRIVERS=kgsl itself is exported by the user session (m106). Undo: rm the override file.
R=/data/local/tmp/nura_stage/rootfs
O=$R/var/lib/flatpak/overrides/global
[ -f $O ] && { echo "existing global override:"; cat $O; cp $O $O.bak; }
mkdir -p ${O%/*}
cat > $O <<'EOF'
[Context]
devices=all;

[Environment]
MESA_LOADER_DRIVER_OVERRIDE=kgsl
LD_PRELOAD=/usr/lib/aarch64-linux-gnu/GL/kgsl/lib/s26_glfinish.so
EOF
chmod 644 $O; echo "written:"; cat $O
