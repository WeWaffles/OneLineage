#!/system/bin/sh
# m131_unblank.sh — turn the panel back on through Phosh (Mutter DisplayConfig PowerSaveMode=0).
# Phosh's own power-key handling loses track after a blank (reports mode 0 with the panel off), so re-assert it.
S=/data/local/tmp/nura_stage
chroot $S/rootfs /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin su -s /bin/sh user -c '
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus gdbus call --session \
    --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig \
    --method org.freedesktop.DBus.Properties.Set org.gnome.Mutter.DisplayConfig PowerSaveMode "<0>"' >/dev/null
