#!/system/bin/sh
# probe-nura.sh — read-only feasibility probe for running a Nura (postmarketOS/Alpine)
# rootfs in a pivot_root container on this phone. Writes a report, changes nothing.
# Expected to run as root (adb shell su -c "sh /data/local/tmp/probe-nura.sh").

OUT="${1:-/data/local/tmp/nura_probe_report.txt}"
{
echo "######## NURA FEASIBILITY PROBE ($(date)) ########"

echo
echo "=== [0] whoami / root check ==="
id
su 0 sh -c id 2>/dev/null || su -c id 2>/dev/null || echo "NOTE: su not accessible!"

echo
echo "=== [1] device identity ==="
getprop ro.product.model
getprop ro.product.device
getprop ro.board.platform
getprop ro.soc.model
getprop ro.build.version.release
getprop ro.build.version.oneui_version
uname -a

echo
echo "=== [2] DISPLAY: DRM nodes ==="
ls -l /dev/dri 2>/dev/null || echo "NO /dev/dri"
for s in /sys/class/drm/*; do
  echo "$s status=$(cat "$s/status" 2>/dev/null)"
done 2>/dev/null
echo "--- drm driver(s) in use ---"
# resolve driver of the card devices (msm => mainline-style KMS; qualcomm fake/kgsl => android-side)
for d in /dev/dri/card*; do
  link=$(ls -l "$d" | sed 's/.* -> //')
  echo "$d -> $link"
done 2>/dev/null
find /sys/class -maxdepth 1 -name "kgsl*" 2>/dev/null
ls -l /dev/kgsl* 2>/dev/null || echo "no /dev/kgsl*"
echo "--- can we open card0 for testing? (open+close, needs root) ---"
su 0 sh -c 'dd if=/dev/zero bs=1 count=0 2>/dev/null; exec 3<>/dev/dri/card0 && echo "card0 OPEN OK" && exec 3>&-' 2>/dev/null \
  || echo "card0 open failed (may still be fine while SF is masterless/held by host)"

echo
echo "=== [3] GPU: krnl config hints (kgsl vs msm) ==="
KCFG=/proc/config.gz
if [ -f "$KCFG" ]; then
  zcat "$KCFG" 2>/dev/null | grep -E "CONFIG_(DRM|MSM|QCOM|KGSL|QRTR|QMI|ALSA|SND|USER_NS|PID_NS|NET_NS|UTS_NS|IPC_NS|OVERLAY|BINDER|BPF|MEMCG|CGROUP)" | sort
else
  echo "no /proc/config.gz (module configs may be readable below)"
  ls /sys/module 2>/dev/null | grep -iE "kgsl|msm_drm|qrtr|qmi" 
fi

echo
echo "=== [4] MODEM: QRTR / QMI visibility ==="
ls -l /dev/qrtr* 2>/dev/null || echo "no /dev/qrtr*"
cat /proc/net/qrtr 2>/dev/null | head -30 || echo "no /proc/net/qrtr"
ls /dev/smd* 2>/dev/null || echo "no /dev/smd* (fine on newer SoCs)"
ls /dev/rmtfs* /dev/ipc_router* 2>/dev/null

echo
echo "=== [5] AUDIO: ALSA cards ==="
cat /proc/asound/cards 2>/dev/null || echo "no /proc/asound/cards"
ls -l /dev/snd 2>/dev/null || echo "no /dev/snd"

echo
echo "=== [6] CONTAINER primitives ==="
echo "--- userns ---"
cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo "max_user_namespaces unavailable"
echo "--- mount test: can root create a mount ns? ---"
su 0 sh -c 'unshare -m true 2>&1 && echo "unshare -m OK"' 2>/dev/null || echo "unshare -m failed/unsupported"
echo "--- filesystems ---"
cat /proc/filesystems | grep -E "ext4|overlay|f2fs|tmpfs|binder"
echo "--- selinux ---"
getenforce
echo "--- current data free space ---"
df -h /data | tail -2
echo "--- memory ---"
free -m 2>/dev/null | head -3
echo "--- cgroups ---"
cat /proc/cgroups 2>/dev/null | head -10

echo
echo "=== [7] misc ==="
echo "--- busybox/toybox/unshare present? ---"
which unshare busybox ip 2>/dev/null
echo "--- OneLineage installed? ---"
pm list packages 2>/dev/null | grep -i onelineage || echo "onelineage app not found"
echo "--- zygote-ish procs (state before any switch) ---"
ps -A 2>/dev/null | grep -E "zygote|surfaceflinger|kernel" | head -10
echo
echo "######## PROBE END ########"
} > "$OUT" 2>&1
echo "report written to $OUT"
