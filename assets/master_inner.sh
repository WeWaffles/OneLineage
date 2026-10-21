#!/system/bin/sh
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

echo "[Pivoted Root] Preparing pivot..."
cd /data/local/tmp/hyper_stage/rootfs
$BB mount --make-rprivate /
if ! $BB pivot_root . postinstall; then
    echo "[Pivoted Root] Fallback: bind mounting rootfs onto itself..."
    $BB mount --bind . .
    if ! $BB pivot_root . postinstall; then
        echo "[Pivoted Root] FATAL: pivot_root failed completely! Aborting."
        exit 1
    fi
fi
$BB mount -t proc proc /proc

export PATH=/system/bin:/system/xbin

echo "[Pivoted Root] Setting up /data_mirror and /data/data mounts for Zygote isolation..."
$BB mount --bind /data/user/0 /data/data 2>/dev/null || true
$BB mount -t tmpfs tmpfs /data_mirror 2>/dev/null || true
mkdir -p /data_mirror/data_de/null/0 /data_mirror/data_ce/null/0 /data_mirror/cur_profiles /data_mirror/ref_profiles
chmod -R 777 /data_mirror
$BB mount --bind /data/user_de/0 /data_mirror/data_de/null/0 2>/dev/null || true
$BB mount --bind /data/user/0 /data_mirror/data_ce/null/0 2>/dev/null || true
mkdir -p /data/misc/profiles/cur /data/misc/profiles/ref
$BB mount --bind /data/misc/profiles/cur /data_mirror/cur_profiles 2>/dev/null || true
$BB mount --bind /data/misc/profiles/ref /data_mirror/ref_profiles 2>/dev/null || true

echo "[Pivoted Root] Setting up /data/media and emulated storage..."
mkdir -p /data/media/0/Android /data/media/0/Pictures/Screenshots /data/media/0/Download /data/media/0/DCIM /data/media/0/Documents
chown -R 1023:1023 /data/media 2>/dev/null || true
chmod -R 777 /data/media 2>/dev/null || true
$BB mount -t tmpfs tmpfs /storage 2>/dev/null || true
mkdir -p /storage/emulated/0
$BB mount --bind /data/media/0 /storage/emulated/0 2>/dev/null || true
mkdir -p /mnt/user/0
$BB mount -t tmpfs tmpfs /mnt/user/0 2>/dev/null || true
mkdir -p /mnt/user/0/emulated
$BB mount --bind /data/media/0 /mnt/user/0/emulated 2>/dev/null || true

echo "[Pivoted Root] Rootfs successfully activated as /"
echo "[Pivoted Root] Testing /dev/null resolution:"
exec 8< /dev/null
echo -n "FD 8: "
$BB readlink /proc/$$/fd/8
exec 8<&-

echo "[Pivoted Root] Testing su availability:"
su -c id || echo "su check non-fatal"
# (UI sound-effect decode-hang fix lives in master_prepare.sh, where it masks
# the UI-sounds dirs on $ROOTFS before the pivot so zygote's children inherit it.)

echo "[Pivoted Root] Starting HyperOS SurfaceFlinger..."
# sf.log used to grow without bound: the guest's RenderEngine dumps LLVM IR for
# every shader it compiles ("Global Value @fullLiteral...") and got to 300+ MB in
# ~3 minutes, filling /data. SurfaceFlinger's real diagnostics go through logcat,
# so stderr can be dropped.
/system/bin/surfaceflinger > /dev/null 2>&1 &
SF_PID=$!
echo "[Pivoted Root] SurfaceFlinger PID: $SF_PID"
sleep 2

echo "[Pivoted Root] Starting HyperOS BootAnimation..."
setprop service.bootanim.exit 0
/system/bin/bootanimation > /data/anim.log 2>&1 &
ANIM_PID=$!
echo "[Pivoted Root] BootAnimation PID: $ANIM_PID"
sleep 1

echo "[Pivoted Root] Starting HyperOS Vold..."
/system/bin/vold --blkid_context=u:r:blkid:s0 --blkid_untrusted_context=u:r:blkid_untrusted:s0 --fsck_context=u:r:fsck:s0 --fsck_untrusted_context=u:r:fsck_untrusted:s0 > /data/vold.log 2>&1 &
VOLD_PID=$!
echo "[Pivoted Root] Vold PID: $VOLD_PID"
sleep 1

# Wifi. switch_to_hyperos.sh stops the host wificond; the guest's own registers
# IWificond before WifiService initialises, and drives Samsung's wifi HAL (which
# is still registered by host init) with matching AIDL.
echo "[Pivoted Root] Starting HyperOS wificond..."
/system/bin/wificond > /data/wificond.log 2>&1 &
WIFICOND_PID=$!
echo "[Pivoted Root] wificond PID: $WIFICOND_PID"
sleep 1

# Overlay idmaps. idmap2 refuses the GSI's product overlays because framework-res
# does not declare the targeted resources as overlayable, so OMS ends up with no
# idmap at all and silently ignores every overlay: gesture navigation never
# applies (navbar stays 3-button) and the SystemUI accent overlays do nothing.
# Build the nav-bar idmap ourselves, before zygote can cache the empty overlay.
NAV_IDMAP="/data/resource-cache/system@product@overlay@NavigationBarModeGestural@NavigationBarModeGesturalOverlay.apk@idmap"
NAV_OV="/system/product/overlay/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk"
mkdir -p /data/resource-cache
if [ ! -s "$NAV_IDMAP" ] && [ -f "$NAV_OV" ]; then
    echo "[Pivoted Root] Generating gesture-nav overlay idmap..."
    /system/bin/idmap2 create --target-apk-path /system/framework/framework-res.apk \
        --overlay-apk-path "$NAV_OV" --idmap-path "$NAV_IDMAP" --ignore-overlayable \
        > /data/idmap.log 2>&1 \
        && chmod 644 "$NAV_IDMAP" && chown system:system "$NAV_IDMAP" \
        && echo "[Pivoted Root] idmap OK ($(wc -c < "$NAV_IDMAP") bytes)" \
        || echo "[Pivoted Root] idmap FAILED: $(head -n1 /data/idmap.log 2>/dev/null)"
fi

# Newly installed apps have no data directories (the guest has no installd), and
# zygote kills their first launch with "Failed to mount /data_mirror/...". This
# sweep creates them while Lineage runs, so Play Store/Aurora installs become
# launchable within ~15 s.
if [ -x /system/bin/setsid ]; then
    setsid /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
else
    /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
fi
echo "[Pivoted Root] App storage sweeper started..."

# Media / codec list. The guest framework (system_server, SystemUI) fetches the
# codec list from the "media.player" service through the SHARED servicemanager.
# Samsung's host mediaserver owns that name, but its IMediaPlayerService binder
# layout differs from the GSI's, so the guest reads the reply as garbage
# ("enforceInterface() expected 'android.gui.IGraphicBufferProducer' but read
# 'android.media.IMediaCodecList'"), caches a bogus-length codec list and spins
# findCodecForFormat forever (~120% CPU per process, ~100 C - the overheating).
# Same play as wificond above: start the GSI's OWN mediaserver so it re-registers
# media.player with the guest-matching interface and builds a valid codec list
# from the vendor Codec2 HAL over hwbinder (a Treble-stable vendor interface,
# unlike Samsung's framework binder). addService is last-writer-wins and the
# host's mediaserver registered at boot, so starting ours now takes the name.
# This MUST precede zygote: MediaCodecList::getInstance() caches the first list
# it sees, so no guest process may query media.player before ours is registered.
if [ -x /system/bin/mediaserver ]; then
    echo "[Pivoted Root] Starting HyperOS mediaserver (guest-matching codec list)..."
    /system/bin/mediaserver > /data/mediaserver.log 2>&1 &
    MEDIA_PID=$!
    echo "[Pivoted Root] mediaserver PID: $MEDIA_PID"
    # Wait (max ~6 s) for ours to own media.player before zygote starts, so the
    # framework never caches the host's poisoned list.
    i=0
    while [ "$i" -lt 12 ]; do
        # "service check" prints "...: found" or "...: not found"; match only the
        # positive form (": not found" does not contain ": found").
        if /system/bin/service check media.player 2>/dev/null | grep -q ': found'; then
            break
        fi
        i=$((i + 1))
        sleep 0.5
    done
    echo "[Pivoted Root] media.player ready after $((i * 500))ms"
else
    echo "[Pivoted Root] WARNING: /system/bin/mediaserver not in GSI - codec spin mitigation (log silence) only"
fi

# Classpaths. This shell inherits the HOST's BOOTCLASSPATH/SYSTEMSERVERCLASSPATH
# (Samsung's: knoxsdk.jar, esecomm.jar, ...). The LineageOS GSI only needs AOSP
# jars so that happened to work, but HyperOS's framework.jar links against
# miui-framework/xiaomi-framework/mediatek-* boot jars in /system_ext/framework:
# zygote dies preloading SystemServiceRegistry with NoClassDefFoundError.
# Derive them from the guest's own classpath fragments, as init does on a real
# boot (system/etc/classpaths/*.pb + the APEX fragments).
DERIVED=/data/derived_classpath
rm -f "$DERIVED"
if /apex/com.android.sdkext/bin/derive_classpath "$DERIVED" 2>/data/derive_classpath.log \
        && grep -q '^export BOOTCLASSPATH ' "$DERIVED"; then
    while read -r kw name value; do
        [ "$kw" = export ] && [ -n "$name" ] && export "$name=$value"
    done < "$DERIVED"
    echo "[Pivoted Root] Classpaths derived from guest fragments ($(echo "$BOOTCLASSPATH" | tr ':' '\n' | wc -l) boot jars)"
else
    echo "[Pivoted Root] WARNING: derive_classpath failed, zygote keeps the host classpath: $(head -n1 /data/derive_classpath.log 2>/dev/null)"
fi

echo "[Pivoted Root] Cleaning stale sockets..."
rm -f /dev/socket/zygote /dev/socket/usap_pool_primary 2>/dev/null || true

echo "[Pivoted Root] Launching HyperOS Zygote & SystemServer via zygote_exec..."
exec /data/zygote_exec
