#!/system/bin/sh
# m105_user.sh — one-time: create the guest's normal user "user" (Phosh session runs as it, not root)
chroot /data/local/tmp/nura_stage/rootfs /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -c '
  # store backend: gnome-software -> apk via polkit
  apk add apk-polkit-rs gnome-software-plugin-apk 2>&1 | tail -n 1

  # Android kernel (PARANOID_NETWORK): only members of AID_INET (3003) / AID_NET_RAW (3004) may open sockets
  grep -q ":3003:" /etc/group || addgroup -g 3003 aid_inet
  grep -q ":3004:" /etc/group || addgroup -g 3004 aid_net_raw
  id user >/dev/null 2>&1 || adduser -D -u 1000 -s /bin/sh -g "User" user
  for g in wheel video input audio netdev plugdev seat users aid_inet aid_net_raw; do addgroup user $g 2>/dev/null; done

  # phone-style: the owner (wheel) is never asked for a password (wifi, installs, settings)
  mkdir -p /etc/polkit-1/rules.d
  cat > /etc/polkit-1/rules.d/50-s26-owner.rules <<EOF
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel")) return polkit.Result.YES;
});
EOF
  echo "user: $(id user)"
  su -s /bin/sh user -c "wget -q -O /dev/null https://alpinelinux.org && echo net-as-user: OK || echo net-as-user: FAIL"'
