#!/system/bin/sh
# probe2.sh — who holds DRM master + display handover facts (read-only)
echo "=== display stack fds ==="
for pid in $(pidof surfaceflinger) $(pidof vendor.qti.hardware.display.composer-service) $(pidof vendor.qti.hardware.display.allocator-service); do
  echo "--- PID $pid = $(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ')"
  ls -l /proc/$pid/fd 2>/dev/null | grep -E 'card0|renderD|kgsl'
done

echo
echo "=== DRM kernel master info ==="
su 0 true 2>/dev/null
cat /sys/kernel/debug/dri/0/dyndbg 2>/dev/null >/dev/null && echo debugfs-ok
for f in /sys/kernel/debug/dri/0/msm_*; do echo $f; done 2>/dev/null | head -5

echo
echo "=== glink/qrtr modem transport ==="
ls /dev/smd* 2>/dev/null
ls /dev/rmnet* 2>/dev/null | head -3
cat /proc/net/protocols 2>/dev/null | grep -i qrtr

echo
echo "=== brightness node ==="
ls -l /sys/class/backlight/panel0-backlight/ 2>/dev/null | head -8
cat /sys/class/backlight/panel0-backlight/max_brightness 2>/dev/null

echo
echo "=== input devices ==="
for i in /dev/input/event*; do echo "$i: $(cat /sys/class/input/$(basename $i)/device/name 2>/dev/null)"; done
