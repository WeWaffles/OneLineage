#!/system/bin/sh
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

echo "[Pivoted Root] Preparing pivot..."
cd /data/local/tmp/lineage_stage/rootfs
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

# Mount propagation inside the container, like Android's init does: the
# guest vold mounts the FUSE storage (/mnt/user/0/emulated, ...) after zygote
# has already unshared its own namespace, and apps only see it if / is
# shared (zygote makes itself a slave of it). The old host root stays
# private so nothing propagates back into One UI.
$BB mount --make-rshared / 2>/dev/null || true
$BB mount --make-rprivate /postinstall 2>/dev/null || true

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

# --- Isolated mode (docs/ISOLATION.md phases 1-3) ---------------------------
# On by default for OnePixel. Opt out: touch
# /data/local/tmp/lineage_stage/data/local/tmp/ol_shared on the host. Lineage gets its own binder registry (a private
# binderfs instance over /dev/binderfs in this namespace only) and its own
# keystore2 / gatekeeperd / credstore with state in Lineage's /data.
# ol_bridge forwards One UI's hardware services in and Lineage's framework
# services out, but never One UI's keystore, gatekeeper service, vold, Weaver
# or authsecret. If anything fails before the guest starts, fall back to the
# shared mode below, exactly as before.
OL_ISOLATED=0
if [ ! -f /data/local/tmp/ol_shared ] && [ -x /data/ol_bridge ]; then
    echo "[Pivoted Root] Isolated mode: setting up a private binder registry..."
    P=/data/local/tmp/ol_binderfs
    mkdir -p $P
    rm -f /data/local/tmp/ol_bridge_ready
    if $BB mount -t binder binder $P; then
        # binderfs creates its devices root-only; system_server and apps
        # (non-root uids) must be able to open them.
        chmod 666 $P/binder $P/hwbinder $P/vndbinder 2>/dev/null
        /data/ol_bridge /dev/binderfs/binder $P/binder /data/local/tmp/ol_bridge_ready /data/ol_lazy_services.txt -v > /data/ol_bridge.log 2>&1 &
        BRIDGE_PID=$!
        sleep 0.5
        for d in binder hwbinder vndbinder; do $BB mount --bind $P/$d /dev/binderfs/$d; done
        /system/bin/servicemanager > /data/ol_sm.log 2>&1 &
        SM_PID=$!
        /system/bin/hwservicemanager > /data/ol_hwsm.log 2>&1 &
        HWSM_PID=$!
        VSM_PID=""
        if [ -x /vendor/bin/vndservicemanager ]; then
            /vendor/bin/vndservicemanager /dev/vndbinder > /data/ol_vsm.log 2>&1 &
            VSM_PID=$!
        fi
        i=0
        while [ ! -f /data/local/tmp/ol_bridge_ready ] && kill -0 $BRIDGE_PID 2>/dev/null && [ $i -lt 60 ]; do
            sleep 0.5; i=$((i + 1))
        done
        if [ -f /data/local/tmp/ol_bridge_ready ]; then
            OL_ISOLATED=1
            echo "[Pivoted Root] Bridge ready: $(grep 'sync:' /data/ol_bridge.log | tail -n 1)"
            # Lineage's own security daemons; their state stays in this /data.
            mkdir -p /data/misc/keystore /data/misc/gatekeeper /data/misc/credstore
            /system/bin/keystore2 /data/misc/keystore > /data/ol_keystore2.log 2>&1 &
            /system/bin/gatekeeperd /data/misc/gatekeeper > /data/ol_gatekeeperd.log 2>&1 &
            [ -x /system/bin/credstore ] && /system/bin/credstore /data/misc/credstore > /data/ol_credstore.log 2>&1 &
            # Guest installd: PackageManager needs one, and the host's is never
            # bridged (it once wiped One UI's app data). This one runs in this
            # mount namespace, so it only ever sees the container's /data.
            # User 0's storage dirs. The guest never runs UserDataPreparer (it is
            # stubbed: on failure it reboots to recovery and WIPES THE PHONE).
            for d in user/0 user_de/0 system_ce/0 system_de/0 misc_ce/0 misc_de/0 vendor_ce/0 vendor_de/0 media/0; do
                mkdir -p /data/$d
            done
            chown system:system /data/system_ce/0 /data/system_de/0
            chown media_rw:media_rw /data/media/0
            mkdir -p /data/misc/installd /data/misc/user /data/misc_ce /data/misc_de /data/misc/profiles/cur /data/misc/profiles/ref
            nohup sh -c 'while true; do /system/bin/installd; sleep 2; done' </dev/null >/data/ol_installd.log 2>&1 &
            # Guest artd: every app install waits on it for dexopt. The host's
            # is never bridged (it would compile into One UI's /data), so
            # without this one installs hang forever.
            nohup sh -c 'while true; do /apex/com.android.art/bin/artd; sleep 2; done' </dev/null >/data/ol_artd.log 2>&1 &
            sleep 1
            echo "[Pivoted Root] Lineage security daemons started (keystore2, gatekeeperd, credstore)"
        else
            echo "[Pivoted Root] !!! Bridge did not become ready; falling back to shared mode. See /data/ol_bridge.log"
            kill $BRIDGE_PID $SM_PID $HWSM_PID $VSM_PID 2>/dev/null
            sleep 0.5
            for d in binder hwbinder vndbinder; do $BB umount -l /dev/binderfs/$d 2>/dev/null; done
            $BB umount -l $P 2>/dev/null
        fi
    else
        echo "[Pivoted Root] !!! Could not mount a private binderfs; staying in shared mode"
    fi
fi
echo "[Pivoted Root] Binder mode: $([ $OL_ISOLATED = 1 ] && echo isolated || echo shared)"

echo "[Pivoted Root] Starting LineageOS SurfaceFlinger..."
# sf.log used to grow without bound: the guest's RenderEngine dumps LLVM IR for
# every shader it compiles ("Global Value @fullLiteral...") and got to 300+ MB in
# ~3 minutes, filling /data. SurfaceFlinger's real diagnostics go through logcat,
# so stderr can be dropped.
/system/bin/surfaceflinger > /dev/null 2>&1 &
SF_PID=$!
echo "[Pivoted Root] SurfaceFlinger PID: $SF_PID"
sleep 2

echo "[Pivoted Root] Starting LineageOS BootAnimation..."
setprop service.bootanim.exit 0
/system/bin/bootanimation > /data/anim.log 2>&1 &
ANIM_PID=$!
echo "[Pivoted Root] BootAnimation PID: $ANIM_PID"
sleep 1

echo "[Pivoted Root] Starting LineageOS Vold..."
/system/bin/vold --blkid_context=u:r:blkid:s0 --blkid_untrusted_context=u:r:blkid_untrusted:s0 --fsck_context=u:r:fsck:s0 --fsck_untrusted_context=u:r:fsck_untrusted:s0 > /data/vold.log 2>&1 &
VOLD_PID=$!
echo "[Pivoted Root] Vold PID: $VOLD_PID"
sleep 1

# Wifi. switch_to_lineage.sh stops the host wificond; the guest's own registers
# IWificond before WifiService initialises, and drives Samsung's wifi HAL (which
# is still registered by host init) with matching AIDL.
echo "[Pivoted Root] Starting LineageOS wificond..."
/system/bin/wificond > /data/wificond.log 2>&1 &
WIFICOND_PID=$!
echo "[Pivoted Root] wificond PID: $WIFICOND_PID"
sleep 1

# Overlay idmaps. idmap2 refuses the GSI's product overlays because framework-res
# does not declare the targeted resources as overlayable, so OMS ends up with no
# idmap at all and silently ignores every overlay: gesture navigation never
# applies (navbar stays 3-button) and the SystemUI accent overlays do nothing.
# Build the nav-bar idmap ourselves, before zygote can cache the empty overlay.
# LineageOS keeps product under /system/product; PixelOS has a real /product.
# The idmap file name is the overlay path with '/' -> '@'.
mkdir -p /data/resource-cache
# Every overlay that targets framework-res, not just gesture nav: the Pixel
# configs (circular icon mask, etc.) are refused by idmap2 just the same, and
# without them icons fall back to AOSP's rounded square. Overlays aimed at
# other packages fail the target check here and are simply skipped.
echo "[Pivoted Root] Generating framework overlay idmaps..."
: > /data/idmap.log
IDMAP_OK=0
for OV in $(find /product/overlay /system/product/overlay /system_ext/overlay /system/overlay             /vendor/overlay -name '*.apk' 2>/dev/null); do
    IDMAP="/data/resource-cache/$(echo "${OV#/}" | tr / @)@idmap"
    # Always rebuild: idmap2d leaves ~170-byte idmaps with no entries behind.
    if /system/bin/idmap2 create --target-apk-path /system/framework/framework-res.apk         --overlay-apk-path "$OV" --idmap-path "$IDMAP" --ignore-overlayable >> /data/idmap.log 2>&1; then
        chmod 644 "$IDMAP"; chown system:system "$IDMAP"
        IDMAP_OK=$((IDMAP_OK + 1))
    else
        rm -f "$IDMAP"
    fi
done
echo "[Pivoted Root] framework overlay idmaps: $IDMAP_OK"

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

echo "[Pivoted Root] Cleaning stale sockets..."
rm -f /dev/socket/zygote /dev/socket/usap_pool_primary 2>/dev/null || true

# Keep a logcat on disk: the guest UsbService resets the USB gadget during boot,
# which drops adb, so a live logcat from the PC stops right when it matters.
# Ends up at $STAGE/data/boot_logcat.txt* on the host.
rm -f /data/boot_logcat.txt*
nohup logcat -b all -v threadtime -f /data/boot_logcat.txt -r 16384 -n 4 </dev/null >/dev/null 2>&1 &
echo "[Pivoted Root] Boot logcat PID: $!"

# Guest mediaserver: registers a media.player whose IMediaPlayerService matches
# the guest libmedia (the host one is stopped by switch_to_lineage.sh).
nohup sh -c 'while true; do /system/bin/mediaserver; sleep 2; done' </dev/null >/data/mediaserver.log 2>&1 &
echo "[Pivoted Root] Guest mediaserver loop PID: $!"

# Guest idmap2d: keeps the guest's overlay idmaps and theme .frro files in the
# container's /data/resource-cache instead of One UI's (host one is stopped).
nohup sh -c 'while true; do /system/bin/idmap2d; sleep 2; done' </dev/null >/data/idmap2d.log 2>&1 &
echo "[Pivoted Root] Guest idmap2d loop PID: $!"

# Skip the setup wizard for now: once the guest settings service answers, mark
# the device provisioned / setup complete and disable both setup wizards.
nohup sh -c '
# Wait for the GUEST system_server: the Pixel setup wizard only exists there,
# so this never touches the host One UI settings/packages.
ok=0
for i in $(seq 1 180); do
    pm path com.google.android.pixel.setupwizard >/dev/null 2>&1 && { ok=1; break; }
    sleep 1
done
[ $ok = 1 ] || { echo "guest package manager never came up"; exit 1; }
settings put global device_provisioned 1
settings put secure user_setup_complete 1
settings put secure tv_user_setup_complete 1
for p in com.google.android.setupwizard com.google.android.pixel.setupwizard; do
    pm disable-user --user 0 "$p"
done
echo "setup skipped"
' </dev/null >/data/skip_setup.log 2>&1 &

echo "[Pivoted Root] Launching LineageOS Zygote & SystemServer via zygote_exec..."
exec /data/zygote_exec
