#!/usr/bin/env bash
# Rebuilds assets/libaudioclient_aidl_conversion_patched.so and
# assets/libaudio_aidl_conversion_common_cpp_patched.so from the GSI staged on a
# connected, rooted phone (see patch_audio.py for what the patch does).
# Needs adb, Python 3 and an NDK (llvm-nm) under ANDROID_SDK_ROOT.
# After rebuilding, update the original-lib md5s in assets/master_prepare.sh.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
for lib in libaudioclient_aidl_conversion libaudio_aidl_conversion_common_cpp; do
    adb shell su -c "'cp /data/local/tmp/lineage_stage/rootfs/system/lib64/$lib.so /data/local/tmp/$lib.orig; chmod 644 /data/local/tmp/$lib.orig'"
    adb pull "/data/local/tmp/$lib.orig" "$W/$lib.so" >/dev/null
    adb shell su -c "'rm -f /data/local/tmp/$lib.orig'"
    python -I "$HERE/patch_audio.py" "$W/$lib.so" "$ROOT/assets/${lib}_patched.so"
    echo "original md5: $(md5sum "$W/$lib.so" | cut -d' ' -f1)"
done
