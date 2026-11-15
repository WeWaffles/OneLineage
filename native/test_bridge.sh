#!/system/bin/sh
# Live bridge test while One UI runs. Everything happens in a throwaway mount
# namespace on a fresh binderfs instance; One UI's registry only receives
# read-only lookups (the private side has no services to mirror back).
# Usage (root): sh test_bridge.sh /path/to/ol_bridge
B="$1"
BB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox)
exec $BB unshare -m sh -c '
B="'"$B"'"; BB="'"$BB"'"
P=/data/local/tmp/ol_test_binderfs
$BB mount --make-rprivate /
mkdir -p $P
$BB mount -t binder binder $P || { echo "FAIL: binderfs"; exit 1; }
rm -f /data/local/tmp/ol_test_ready
$B /dev/binderfs/binder $P/binder /data/local/tmp/ol_test_ready > /data/local/tmp/ol_test_bridge.log 2>&1 &
BR=$!
sleep 0.5
for d in binder hwbinder vndbinder; do $BB mount --bind $P/$d /dev/binderfs/$d; done
/system/bin/servicemanager > /data/local/tmp/ol_test_sm.log 2>&1 &
SM=$!
i=0; while [ ! -f /data/local/tmp/ol_test_ready ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done
echo "== bridge log"; cat /data/local/tmp/ol_test_bridge.log
echo "== private registry: $(service list 2>/dev/null | head -n 1)"
echo "== check SurfaceFlinger-free names:"
for s in battery android.hardware.graphics.allocator.IAllocator/default android.hardware.security.keymint.IKeyMintDevice/default android.hardware.weaver.IWeaver/default android.system.keystore2.IKeystoreService/default vold; do
  printf "%-60s %s\n" "$s" "$(service check $s 2>&1 | tail -n 1)"
done
echo "== dumpsys battery through the bridge (fd passing):"
timeout 10 dumpsys battery 2>&1 | head -n 6
echo "== weaver stub call (should fail, not hang):"
timeout 5 service call android.hardware.weaver.IWeaver/default 1 2>&1 | head -n 2
kill $BR $SM 2>/dev/null
sleep 0.5
for d in binder hwbinder vndbinder; do $BB umount -l /dev/binderfs/$d; done
$BB umount -l $P
rm -f /data/local/tmp/ol_test_ready
echo "== done; private registry torn down"
'
