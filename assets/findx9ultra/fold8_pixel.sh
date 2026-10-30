#!/system/bin/sh
# Pinned Pixel 11 Fold guest payloads on the Z Fold8 (pixel-f8) and Z Fold8 Ultra
# (pixel-f8u), which have the same Samsung folding-angle sensor. No host APK writes.
set -eu
STAGE=${STAGE:-/data/local/tmp/oneos}
BB=${BB:-/data/oneos_bin/busybox}
fail() { echo "Fold8 Pixel: $*" >&2; exit 3; }
selected() {
    grep -q '^  "image": "pixel11fold-yogi",$' "$STAGE/.oneos_stage" || return 1
    case "${ONEOS_PROFILE:-}" in
        f8) grep -q '^  "set": "pixel-f8",$' "$STAGE/.oneos_stage" ;;
        f8u) grep -q '^  "set": "pixel-f8u",$' "$STAGE/.oneos_stage" ;;
        *) return 1 ;;
    esac
}
case "$1" in
prepare)
    selected || exit 0
    target="$STAGE/rootfs/system/system_ext/priv-app/SystemUIGoogle/SystemUIGoogle.apk"
    "$BB" umount -l "$target" 2>/dev/null || true
    [ -f "$target" ] && [ ! -L "$target" ] || fail 'unexpected SystemUI path'
    [ "$(sha256sum "$target" | cut -d' ' -f1)" = 9934d2dac326f56290f459b9e649185cd5531e1b6ae1f5a72b11e88f865f8b03 ] || fail 'SystemUI donor differs'
    "$BB" mount --bind "$STAGE/Fold8PixelSystemUI.apk" "$target"
    "$BB" mount --make-private "$target"
    "$BB" mount -o remount,bind,ro "$STAGE/Fold8PixelSystemUI.apk" "$target"
    dest="$STAGE/data/oneos_pixel_hinge"
    [ ! -L "$STAGE/data" ] && [ ! -L "$dest" ] || fail 'symlink in guest payload path'
    [ ! -d "$dest" ] || [ -z "$(find "$dest" -type l -print -quit)" ] || fail 'symlink below guest payload path'
    mkdir -p "$dest"
    cp -f "$STAGE/Fold8AngleRelay.dex" "$dest/Fold8AngleRelay.dex"
    cp -f "$STAGE/fold8_pixel.sh" "$dest/runtime.sh"
    chown -R 0:0 "$dest"
    chmod 755 "$dest"; chmod 644 "$dest/Fold8AngleRelay.dex" "$dest/runtime.sh"
    chcon -R u:object_r:system_data_file:s0 "$dest"
    ;;
runtime)
    # Invoked only inside this guest, with its classpath and binder namespace.
    [ "$(pm path com.android.systemui)" = package:/system/system_ext/priv-app/SystemUIGoogle/SystemUIGoogle.apk ] || fail 'not the Pixel guest'
    D=/data/oneos_pixel_hinge
    [ -f "$D/Fold8AngleRelay.dex" ] || fail 'relay absent'
    ui=$(pidof com.android.systemui | cut -d' ' -f1)
    z=$(pidof zygote64 | cut -d' ' -f1)
    [ -n "$ui" ] && [ -n "$z" ] || fail 'guest UI not ready'
    uid=$(stat -c %u /proc/$ui)
    [ ! -L /data/oneos_hinge ] || fail 'hinge folder is a symlink'
    mkdir -p /data/oneos_hinge
    chown 1000:"$uid" /data/oneos_hinge; chmod 2750 /data/oneos_hinge
    chcon u:object_r:system_data_file:s0 /data/oneos_hinge
    if ! ps -A -o ARGS | grep -q "[a]pp_process /system/bin OneOSAngleRelay /data/oneos_hinge/angle.bin $z"; then
        (umask 027; CLASSPATH="$D/Fold8AngleRelay.dex" "$BB" nohup "$BB" setuidgid system /system/bin/app_process /system/bin OneOSAngleRelay /data/oneos_hinge/angle.bin "$z" >"$D/relay.log" 2>&1 </dev/null &)
    fi
    echo 'Pixel continuous-angle relay started; native public sensor remains fallback'
    ;;
*) fail 'expected prepare or runtime' ;;
esac
