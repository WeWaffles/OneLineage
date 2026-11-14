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
# Apps get /storage from /mnt/installer/0 (installers like the Play Store) or
# /mnt/androidwritable/0, not /mnt/user/0. The /mnt tree is a copy of One
# UI's, so those two still held One UI's FUSE mounts, which go dead with its
# MediaProvider ("Transport endpoint is not connected"): apps saw no shared
# storage and the Play Store refused every install for lack of space. Do what
# init.rc does on a normal boot: /mnt shared, and /mnt/installer and
# /mnt/androidwritable as slave binds of /mnt/user. The guest's vold clears
# /mnt/user/0 at start and mounts its FUSE at /mnt/user/0/emulated, which
# then reaches both binds and every app namespace forked later.
if $BB mount --make-shared /mnt 2>/dev/null; then
    for d in installer androidwritable; do
        mkdir -p /mnt/$d
        if $BB mount --bind /mnt/user /mnt/$d 2>/dev/null && $BB mount --make-slave /mnt/$d 2>/dev/null; then
            echo "[Pivoted Root] /mnt/$d follows /mnt/user"
        else
            echo "[Pivoted Root] WARN: could not link /mnt/$d to /mnt/user"
        fi
    done
else
    echo "[Pivoted Root] WARN: /mnt is not a mount point; shared storage may be missing in apps"
fi

echo "[Pivoted Root] Rootfs successfully activated as /"
echo "[Pivoted Root] Testing /dev/null resolution:"
exec 8< /dev/null
echo -n "FD 8: "
$BB readlink /proc/$$/fd/8
exec 8<&-

echo "[Pivoted Root] Testing su availability:"
su -c id || echo "su check non-fatal"

# --- Isolated mode (docs/ISOLATION.md phases 1-3) ---------------------------
# Opt-in: touch /data/local/tmp/lineage_stage/data/local/tmp/ol_isolate on the
# host before switching. Lineage gets its own binder registry (a private
# binderfs instance over /dev/binderfs in this namespace only) and its own
# keystore2 / gatekeeperd / credstore with state in Lineage's /data.
# ol_bridge forwards One UI's hardware services in and Lineage's framework
# services out, but never One UI's keystore, gatekeeper service, vold, Weaver
# or authsecret. If anything fails before the guest starts, fall back to the
# shared mode below, exactly as before.
OL_ISOLATED=0
if [ -f /data/local/tmp/ol_isolate ] && [ -x /data/ol_bridge ]; then
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

# --- Isolation phase 1 probe (docs/ISOLATION.md) ---------------------------
# Opt-in: touch /data/local/tmp/lineage_stage/data/local/tmp/ol_isolation_probe
# on the host before switching. In a throwaway mount namespace, mount a NEW
# binderfs instance, put its binder/hwbinder/vndbinder over /dev/binderfs, start
# the guest's own service managers on it, record what registers, then tear it
# all down. The guest's normal boot below is not changed, and nothing here can
# reach One UI's registry (a fresh binderfs instance has its own context).
if [ -f /data/local/tmp/ol_isolation_probe ]; then
    echo "[Pivoted Root] Running isolation probe (log: /data/isolation_probe.log)..."
    $BB unshare -m $BB sh -c '
        BB="'"$BB"'"
        P=/data/local/tmp/ol_binderfs
        say() { echo "$(date +%T) $*"; }
        $BB mount --make-rprivate /
        mkdir -p $P
        if ! $BB mount -t binder binder $P; then say "FAIL: kernel refused a second binderfs instance"; exit 1; fi
        say "private binderfs: $(ls $P | tr "\n" " ")"
        for d in binder hwbinder vndbinder; do
            if [ -e $P/$d ] && [ -e /dev/binderfs/$d ]; then
                $BB mount --bind $P/$d /dev/binderfs/$d && say "bound private $d"
            else
                say "missing $d (private: $([ -e $P/$d ] && echo yes || echo no))"
            fi
        done
        /system/bin/servicemanager >/data/probe_sm.log 2>&1 & SM=$!
        sleep 1
        /system/bin/hwservicemanager >/data/probe_hwsm.log 2>&1 & HWSM=$!
        VSM=""
        if [ -x /vendor/bin/vndservicemanager ]; then
            /vendor/bin/vndservicemanager /dev/vndbinder >/data/probe_vsm.log 2>&1 & VSM=$!
        fi
        sleep 2
        for p in $SM $HWSM $VSM; do
            kill -0 $p 2>/dev/null && say "manager $p running" || say "manager $p EXITED (see /data/probe_*sm.log)"
        done
        say "--- guest-private service list (should be tiny) ---"
        /system/bin/service list 2>&1 | head -n 50
        say "--- declared-but-missing HALs the bridge must forward ---"
        /system/bin/lshal --types=b,c,l -i 2>/dev/null | head -n 80
        kill $SM $HWSM $VSM 2>/dev/null
        sleep 1
        for d in binder hwbinder vndbinder; do $BB umount -l /dev/binderfs/$d 2>/dev/null; done
        $BB umount -l $P 2>/dev/null
        say "probe done; private registry torn down"
    ' > /data/isolation_probe.log 2>&1
    echo "[Pivoted Root] Isolation probe finished."
fi

echo "[Pivoted Root] Cleaning stale sockets..."
rm -f /dev/socket/zygote /dev/socket/usap_pool_primary 2>/dev/null || true

echo "[Pivoted Root] Launching LineageOS Zygote & SystemServer via zygote_exec..."
exec /data/zygote_exec
