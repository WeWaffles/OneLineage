#!/system/bin/sh
# m186_userdirs.sh — standard XDG user folders for "user" (Snapshot: "Could not find XDG_PICTURES_DIR") + jifmux
S=/data/local/tmp/nura_stage
/data/adb/ksu/bin/busybox nsenter -t $(pidof phosh) -m chroot $S/rootfs /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root sh -c '
  apk add -q xdg-user-dirs 2>&1 | tail -n 2
  # jifmux (JPEG + EXIF muxer) lives in the "jpegformat" plugin
  gst-inspect-1.0 jifmux >/dev/null 2>&1 || apk add -q gst-plugins-bad 2>&1 | tail -n 2
  gst-inspect-1.0 jifmux >/dev/null 2>&1 && echo "jifmux ok" || { echo "jifmux missing; providers:"; apk search -x "so:libgstjpegformat.so" 2>/dev/null; ls /usr/lib/gstreamer-1.0 | grep -i -e jpeg -e exif; }
  su -s /bin/sh user -c "HOME=/home/user xdg-user-dirs-update && cat /home/user/.config/user-dirs.dirs | grep -v ^#"
  ls /home/user'
