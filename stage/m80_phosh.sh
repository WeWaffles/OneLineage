#!/system/bin/sh
# m80_phosh.sh — install Phosh (phoc + phosh + squeekboard + GNOME mobile apps); needs One UI up (wifi)
CHROOT=/data/local/tmp/nura_stage/rootfs
cp /etc/resolv.conf $CHROOT/etc/resolv.conf 2>/dev/null
chroot $CHROOT /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root sh -c '
  grep -q nameserver /etc/resolv.conf || echo "nameserver 8.8.8.8" > /etc/resolv.conf
  apk update 2>&1 | tail -n 1
  WANT="phosh phoc squeekboard phosh-mobile-settings gnome-settings-daemon gnome-session gsettings-desktop-schemas feedbackd adwaita-icon-theme font-cantarell gnome-console gnome-calculator gnome-clocks gnome-weather gnome-contacts gnome-text-editor loupe nautilus epiphany gnome-software portfolio-file-manager gnome-calls chatty xdg-desktop-portal-gnome xdg-desktop-portal-gtk upower"
  OK=""; MISS=""
  for p in $WANT; do if apk search -x $p 2>/dev/null | grep -q .; then OK="$OK $p"; else MISS="$MISS $p"; fi; done
  echo "installing:$OK"; echo "not in repo:$MISS"
  apk add $OK 2>&1 | tail -n 3
  ls /usr/bin/ | grep -E "^(phoc|phosh|squeekboard)" ; ls /usr/libexec/ 2>/dev/null | grep -E "phosh|gsd-" | head
'
