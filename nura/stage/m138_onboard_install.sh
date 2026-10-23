#!/system/bin/sh
# m138_onboard_install.sh — first-login onboarding: GNOME Initial Setup (existing-user) -> Phosh tour.
# Resets the guest user's ~/.config (guest only; Android untouched) so the next login is a "first boot".
S=/data/local/tmp/nura_stage
R=$S/rootfs
chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -c '
  apk add gnome-initial-setup phosh-tour 2>&1 | tail -n 1
  ls /usr/libexec/gnome-initial-setup /usr/bin/phosh-tour 2>&1
  # fresh first boot for "user": keep a backup of the old config
  if [ -d /home/user/.config ]; then
    tar -czf /home/user/config-backup-$(date +%Y%m%d%H%M).tar.gz -C /home/user .config && rm -rf /home/user/.config
    echo "user ~/.config reset (backup in /home/user)"
  fi
  mkdir -p /home/user/.config; chown user:user /home/user/.config'
cat > $R/usr/local/libexec/s26-firstrun <<'EOF'
#!/bin/sh
# s26-firstrun — once per user: the Phosh tour.
# (gnome-initial-setup --existing-user just logs "Skipping ... for existing user" on GNOME 50 -> not used)
F=$HOME/.config/s26-onboarded
[ -f "$F" ] && exit 0
L=$HOME/.cache/s26; mkdir -p $L
phosh-tour >$L/phosh-tour.log 2>&1
touch "$F"
EOF
chmod 755 $R/usr/local/libexec/s26-firstrun
echo "firstrun installed"
