#!/system/bin/sh
# m100_nm_install.sh — NetworkManager + Alpine wpa_supplicant (D-Bus) in the guest, so Phosh sees wifi.
# Run with One UI up (Android's wifi carries the apk download).
S=/data/local/tmp/nura_stage
CHROOT=$S/rootfs
BB=/data/adb/ksu/bin/busybox
grep -q " $CHROOT/proc " /proc/mounts || $BB mount -t proc proc "$CHROOT/proc"
grep -q " $CHROOT/sys " /proc/mounts || $BB mount -t sysfs sys "$CHROOT/sys"
grep -q " $CHROOT/dev " /proc/mounts || $BB mount --bind /dev "$CHROOT/dev"
ip rule del pref 31999 2>/dev/null; ip rule add pref 31999 from all lookup wlan0

chroot $CHROOT /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -c '
  apk add networkmanager networkmanager-wifi networkmanager-cli wpa_supplicant 2>&1 | tail -n 3
  mkdir -p /etc/NetworkManager/conf.d /etc/NetworkManager/system-connections
  cat > /etc/NetworkManager/conf.d/90-s26.conf <<EOF
[main]
plugins=keyfile
dhcp=internal

[keyfile]
unmanaged-devices=except:interface-name:wlan0

[device]
wifi.backend=wpa_supplicant
wifi.scan-rand-mac-address=no
EOF
  echo "nm: $(NetworkManager --version 2>&1)  wpa: $(wpa_supplicant -v 2>&1 | head -n 1)"'

# import the saved network from nura_wpa.conf (never printed)
SSID=$(sed -n 's/^[[:space:]]*ssid="\(.*\)"/\1/p' $S/nura_wpa.conf | head -n 1)
PSK=$(sed -n 's/^[[:space:]]*psk="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' $S/nura_wpa.conf | head -n 1)
K=$CHROOT/etc/NetworkManager/system-connections/nura.nmconnection
cat > $K <<EOF
[connection]
id=$SSID
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$PSK

[ipv4]
method=auto

[ipv6]
method=auto
EOF
chmod 600 $K
echo "imported network: $SSID (psk ${#PSK} chars)"
