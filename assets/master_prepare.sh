#!/system/bin/sh
STAGE="/data/local/tmp/lineage_stage"
ROOTFS="$STAGE/rootfs"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

# Disable kernel softlockup and hung-task panics for the duration of the
# container boot. The APEX extraction and pivot_root chain can stall a CPU for
# many seconds (especially on A35/M35 Exynos where the hardware is slow and the
# kernel's softlockup threshold is 100 s). Without this the kernel panics and
# reboots before the container even finishes mounting. These are written back to
# their default (1) by nothing — a hard reboot resets them — so this is safe.
echo 0 > /proc/sys/kernel/softlockup_panic 2>/dev/null || true
echo 0 > /proc/sys/kernel/hung_task_panic 2>/dev/null || true

echo "=== 1. Ensuring Watchdog Feeder is Active ==="
if ! ps -ef | grep -v grep | grep -q "/dev/watchdog"; then
    echo "Starting watchdog feeder..."
    nohup $BB sh -c "while true; do echo -n 1 > /dev/watchdog 2>/dev/null; sleep 2; done" </dev/null >/dev/null 2>&1 &
fi

echo "=== 2. Creating Loop Device Nodes ==="
for i in $(seq 50 150); do
    minor=$((i * 8))
    rm -f /dev/block/loop$i /dev/loop$i 2>/dev/null || true
    mknod /dev/block/loop$i b 7 $minor
    mknod /dev/loop$i b 7 $minor
done

echo "=== 3. Mounting system.raw if needed ==="
if mount | grep -q "$ROOTFS "; then
    if [ ! -f "$ROOTFS/system/bin/sh" ] || [ ! -f "$ROOTFS/init.environ.rc" ]; then
        echo "Rootfs mount is invalid or stale. Unmounting..."
        while mount | grep -q "$ROOTFS"; do
            $BB umount -l "$ROOTFS" 2>/dev/null || true
            sleep 0.1
        done
    else
        echo "Rootfs already mounted and healthy."
    fi
fi

mkdir -p "$ROOTFS"
if ! mount | grep -q "$ROOTFS "; then
    for l in $($BB losetup -a | grep "system.raw" | cut -d: -f1); do
        $BB losetup -d "$l" 2>/dev/null || true
    done
    LOOP=$($BB losetup -f)
    $BB losetup "$LOOP" "$STAGE/system.raw"
    echo "Using LOOP: $LOOP"
    $BB mount -t ext4 -o ro "$LOOP" "$ROOTFS"
fi

mkdir -p "$ROOTFS/postinstall" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" \
    "$ROOTFS/linkerconfig" "$ROOTFS/vendor" "$ROOTFS/odm" "$ROOTFS/vendor_dlkm" \
    "$ROOTFS/mnt" "$ROOTFS/storage" "$ROOTFS/apex" "$ROOTFS/data"

echo "=== 3b. Building guest aconfig flag storage ==="
# Android 16 reads feature flags from /metadata/aconfig. Without it every flag
# reads as off, so flag-gated permissions (android.permission.RANGING) are never
# defined and system_server dies in AppOpService.systemReady. Start from the
# host copy (right for vendor and the host apexes the guest uses) and replace
# the system/system_ext/product storage with the GSI's own files.
ACONFIG="$STAGE/metadata/aconfig"
if [ -d /metadata/aconfig ]; then
    rm -rf "$STAGE/metadata"
    mkdir -p "$STAGE/metadata"
    cp -a /metadata/aconfig "$STAGE/metadata/"
    for c in system system_ext product; do
        SRC=""
        for d in "$ROOTFS/$c/etc/aconfig" "$ROOTFS/system/$c/etc/aconfig"; do
            [ "$c" = "system" ] && d="$ROOTFS/system/etc/aconfig"
            [ -f "$d/package.map" ] && { SRC="$d"; break; }
        done
        if [ -z "$SRC" ]; then
            echo "WARNING: no GSI aconfig storage for $c"
            continue
        fi
        cp -f "$SRC/package.map" "$ACONFIG/maps/$c.package.map"
        cp -f "$SRC/flag.map" "$ACONFIG/maps/$c.flag.map"
        for sub in boot flags; do
            cp -f "$SRC/flag.val" "$ACONFIG/$sub/$c.val"
            cp -f "$SRC/flag.info" "$ACONFIG/$sub/$c.info"
        done
        # Host overrides name Samsung flags that do not exist in the GSI.
        rm -f "$ACONFIG/flags/${c}_local_overrides.pb"
        echo "Guest aconfig storage for $c from $SRC"
    done
    chown -R 1000:1000 "$STAGE/metadata" 2>/dev/null
    chmod -R a+rX "$STAGE/metadata" 2>/dev/null
    chcon -R u:object_r:aconfig_storage_metadata_file:s0 "$STAGE/metadata/aconfig" 2>/dev/null
    if [ ! -d "$ROOTFS/metadata" ]; then
        # The GSI root has no /metadata mountpoint; add one to system.raw once.
        $BB mount -o remount,rw "$ROOTFS" && mkdir -p "$ROOTFS/metadata"
        $BB mount -o remount,ro "$ROOTFS"
    fi
    mount | grep -q "$ROOTFS/metadata " || $BB mount --bind "$STAGE/metadata" "$ROOTFS/metadata"
fi

echo "=== 3c. Built-in 'One UI' return app ==="
# A tiny privileged system app inside PixelOS: a floating card with "Go back to
# One UI" that reboots the phone via the REBOOT permission (no root needed).
# system.raw's loop is read-only, so read-only overlays layer it in instead.
# The image's /system/product is an absolute symlink to /product, which from
# here would resolve to One UI's own /product. Never follow it.
RET_SRC="$STAGE/OneUIReturn.apk"
RET_PROD=""
if [ -d "$ROOTFS/product" ] && ! [ -L "$ROOTFS/product" ]; then RET_PROD="$ROOTFS/product"
elif [ -d "$ROOTFS/system/product" ] && ! [ -L "$ROOTFS/system/product" ]; then RET_PROD="$ROOTFS/system/product"
else echo "No product partition inside the image; skipping the One UI return app"; fi
# layer_dir <name> <image dir>: overlays $STAGE/extra/<name> (a tmpfs) onto it.
layer_dir() {
    LOWER="$STAGE/extra/$1"
    chown -R 0:0 "$LOWER"; chcon -R u:object_r:system_file:s0 "$LOWER" 2>/dev/null
    $BB mount -t overlay overlay -o "ro,lowerdir=$LOWER:$2" "$2"
}
if [ -n "$RET_PROD" ] && [ -f "$RET_SRC" ] && ! [ -f "$RET_PROD/priv-app/OneUIReturn/OneUIReturn.apk" ]; then
    # overlayfs rejects /data's case-insensitive f2fs, so the layers live on tmpfs.
    $BB umount "$STAGE/extra" 2>/dev/null; mkdir -p "$STAGE/extra"
    $BB mount -t tmpfs -o size=8m,mode=755 tmpfs "$STAGE/extra"
    mkdir -p "$STAGE/extra/priv-app/OneUIReturn" "$STAGE/extra/permissions"
    cp -f "$RET_SRC" "$STAGE/extra/priv-app/OneUIReturn/OneUIReturn.apk"
    cat > "$STAGE/extra/permissions/privapp-permissions-oneuireturn.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <privapp-permissions package="com.eggdog.oneui">
        <permission name="android.permission.REBOOT"/>
    </privapp-permissions>
</permissions>
XML
    # One UI declares the fingerprint feature in /system, which the guest
    # never sees, so PixelOS never started FingerprintService. Its
    # services_patched.jar keeps fingerprint read-only (tools/patches/
    # fp_readonly.py): it adopts One UI's enrolled fingers and never enrolls,
    # removes or invalidates on the shared HAL.
    if [ -f /system/etc/permissions/android.hardware.fingerprint.xml ]; then
        cp /system/etc/permissions/android.hardware.fingerprint.xml "$STAGE/extra/permissions/"
    fi
    # Image app changes. HIDE_APPS: folders of the image's /product/app that
    # PixelOS should not see (overlayfs whiteouts; the image is untouched).
    # Their package names also go in the leftover-removal loop in
    # master_inner.sh, which removes a /data update of them once.
    # SYSTEM_APPS: installed apps to turn into system apps, as Folder:package.
    # A copy (apk + native libs) is kept in $STAGE/sysapps, refreshed from the
    # installed one, so it survives the package manager dropping the /data
    # copy, and is bound in as /product/app/<Folder>.
    HIDE_APPS="Chrome-Stub Aperture ApertureLensLauncher"
    # An app that was never installed can be seeded by putting its apk at
    # $STAGE/sysapps/<Folder>/<Folder>.apk.
    SYSTEM_APPS="Firefox:org.mozilla.firefox GoogleCamera:com.android.MGC_9_8_102"
    mkdir -p "$STAGE/extra/app"
    for a in $HIDE_APPS; do mknod "$STAGE/extra/app/$a" c 0 0; done
    SYSAPP_BINDS=""
    for e in $SYSTEM_APPS; do
        d=${e%%:*}; pkg=${e#*:}; KEEP="$STAGE/sysapps/$d"
        SRC=$(ls -d "$STAGE/data/app/"*/"$pkg"-* 2>/dev/null | head -1)
        if [ -n "$SRC" ] && [ -f "$SRC/base.apk" ] &&
           [ "$(stat -c %s "$SRC/base.apk")" != "$(stat -c %s "$KEEP/$d.apk" 2>/dev/null)" ]; then
            rm -rf "$KEEP"; mkdir -p "$KEEP"
            cp "$SRC/base.apk" "$KEEP/$d.apk" && { [ ! -d "$SRC/lib" ] || cp -r "$SRC/lib" "$KEEP/"; } &&
                echo "System app $d: copied from ${SRC#$STAGE/data}"
        fi
        # A seeded apk has no extracted native libs; system apps need them
        # next to the apk (lib/arm64) when the apk compresses them.
        if [ -f "$KEEP/$d.apk" ] && ! [ -d "$KEEP/lib" ] &&
           $BB unzip -l "$KEEP/$d.apk" 2>/dev/null | grep -q ' lib/arm64-v8a/'; then
            mkdir -p "$KEEP/lib/arm64" "$KEEP/.x"
            $BB unzip -o -q "$KEEP/$d.apk" 'lib/arm64-v8a/*' -d "$KEEP/.x" &&
                mv "$KEEP/.x/lib/arm64-v8a/"* "$KEEP/lib/arm64/" && echo "System app $d: native libs extracted"
            rm -rf "$KEEP/.x"
        fi
        if [ -f "$KEEP/$d.apk" ]; then
            chown -R 0:0 "$KEEP"; chmod -R a+rX "$KEEP"; chmod 644 "$KEEP/$d.apk"
            chcon -R u:object_r:system_file:s0 "$KEEP" 2>/dev/null
            mkdir -p "$STAGE/extra/app/$d"; SYSAPP_BINDS="$SYSAPP_BINDS $d"
        else
            echo "System app $d: $pkg is not installed in PixelOS yet, skipped"
        fi
    done
    chmod -R 755 "$STAGE/extra"
    chmod 644 "$STAGE/extra/priv-app/OneUIReturn/OneUIReturn.apk" "$STAGE/extra/permissions/"*.xml
    if layer_dir priv-app "$RET_PROD/priv-app" && layer_dir permissions "$RET_PROD/etc/permissions" \
        && [ -f "$RET_PROD/priv-app/OneUIReturn/OneUIReturn.apk" ]; then
        echo "One UI return app layered into ${RET_PROD#$ROOTFS}/priv-app"
    else
        echo "Could not layer the One UI return app into ${RET_PROD#$ROOTFS}"
    fi
    if layer_dir app "$RET_PROD/app"; then
        for d in $SYSAPP_BINDS; do
            $BB mount --bind "$STAGE/sysapps/$d" "$RET_PROD/app/$d" && echo "System app $d layered in" ||
                echo "System app $d: bind failed"
        done
        echo "Hidden image apps: $HIDE_APPS"
    else
        echo "Could not layer ${RET_PROD#$ROOTFS}/app (app hiding and system apps off)"
    fi
fi

echo "=== 3c1. seapp_contexts rule for the Google NetworkStack ==="
# The guest runs the Google-signed NetworkStack (NetworkStackGoogle). PixelOS's
# mac_permissions only maps its own signing key to seinfo=network_stack, so this
# one gets seinfo=default, and the only network_stack rule in seapp_contexts
# needs seinfo=network_stack. Permissive let that slide; enforcing made zygote
# abort the process ("seapp_context_lookup_internal: No match for app with uid
# 1073 ... com.android.networkstack.process"), so IpClient never came up and
# Wi-Fi/mobile data had no network. One extra line, bound over the image's
# product_seapp_contexts (the image file itself is untouched).
NS_RULE="user=network_stack seinfo=default domain=network_stack type=radio_data_file"
NS_SRC="$RET_PROD/etc/selinux/product_seapp_contexts"
if [ -n "$RET_PROD" ] && [ -f "$NS_SRC" ]; then
    $BB umount -l "$NS_SRC" 2>/dev/null || true   # a bind from an earlier run
    { $BB grep -vxF "$NS_RULE" "$NS_SRC"; echo "$NS_RULE"; } > "$STAGE/product_seapp_contexts"
    chmod 644 "$STAGE/product_seapp_contexts"; $BB chcon u:object_r:system_file:s0 "$STAGE/product_seapp_contexts" 2>/dev/null || true
    if $BB mount --bind "$STAGE/product_seapp_contexts" "$NS_SRC"; then
        echo "seapp_contexts: network_stack rule added"
    else
        echo "!!! seapp_contexts: bind failed, NetworkStack will not start when enforcing"
    fi
else
    echo "!!! seapp_contexts: no product_seapp_contexts in the image"
fi

echo "=== 3c2. Screen shape overlay (camera hole, rounded corners) ==="
# The image's framework-res says the screen is a plain rectangle, so SystemUI
# laid the status bar out with the clock hugging the rounded top-left corner
# and the whole row shifted left. This static framework overlay carries the
# phone's real cutout and corner radius (tools/display_overlay). Overlays are
# scanned at boot, so it must be in place before the guest starts. Same trick
# as the IMS layer: a tiny tmpfs layer over product/overlay with an empty
# placeholder, and the real APK bound onto it.
DISP_APK="$STAGE/OneLineageDisplayOverlay.apk"
DISP_DIR="${RET_PROD:+$RET_PROD/overlay}"
if [ ! -f "$DISP_APK" ] || [ -z "$DISP_DIR" ] || [ ! -d "$DISP_DIR" ]; then
    echo "Display overlay: off (no APK or no product/overlay)"
elif mount | grep -q " $DISP_DIR type overlay"; then
    echo "Display overlay: already mounted"
else
    chmod 644 "$DISP_APK"
    chcon u:object_r:system_file:s0 "$DISP_APK" 2>/dev/null || true
    DLAYER="$STAGE/display_layer"
    mkdir -p "$DLAYER"
    $BB umount -l "$DLAYER" 2>/dev/null || true
    $BB mount -t tmpfs -o size=1m,mode=755 tmpfs "$DLAYER"
    mkdir -p "$DLAYER/OneLineageDisplay"
    touch "$DLAYER/OneLineageDisplay/OneLineageDisplayOverlay.apk"
    # SystemUI's pixel pitch, which sizes the lock screen fingerprint icon
    # (tools/display_overlay/systemui).
    SUI_APK="$STAGE/OneLineageSystemUIOverlay.apk"
    if [ -f "$SUI_APK" ]; then
        chmod 644 "$SUI_APK"
        chcon u:object_r:system_file:s0 "$SUI_APK" 2>/dev/null || true
        # A real copy in its own folder: a second bind mount next to the
        # display overlay left zygote without that overlay's idmap.
        mkdir -p "$DLAYER/OneLineageSystemUI"
        cp "$SUI_APK" "$DLAYER/OneLineageSystemUI/OneLineageSystemUIOverlay.apk"
    fi
    chmod -R a+rX "$DLAYER"
    chcon -R u:object_r:system_file:s0 "$DLAYER" 2>/dev/null || true
    if $BB mount -t overlay overlay -o "ro,lowerdir=$DLAYER:$DISP_DIR" "$DISP_DIR" &&
       $BB mount --bind "$DISP_APK" "$DISP_DIR/OneLineageDisplay/OneLineageDisplayOverlay.apk"; then
        echo "Display overlay: staged"
    else
        echo "Display overlay: off (mount failed)"
        $BB umount -l "$DISP_DIR" 2>/dev/null || true
    fi
fi

echo "=== 3d. Samsung IMS in the guest (calls, SMS over IMS) ==="
# T-Mobile runs voice only over IMS (and 5G SA has no circuit-switched voice at
# all), and on a Samsung modem IMS is One UI's com.sec.imsservice. Copy THIS
# phone's copy into a read-only overlay on the image's system_ext so PixelOS sees
# /system_ext/priv-app/OneLineageSecIms. services_patched.jar admits it into
# android.uid.system from that path only; framework_patched.jar adds the Samsung
# members it calls; One UI's framework.jar is offered as the library
# "secimshttpclient" so the app finds its Samsung classes. See
# docs/SAMSUNG_IMS.md. Opt out with $STAGE/data/local/tmp/ol_no_secims. Must run
# before step 4's binds that land inside system_ext (apex).
# Like product, /system/system_ext is an absolute symlink; use $ROOTFS/system_ext.
SYSEXT="$ROOTFS/system_ext"
# Helper the guest uses to tell the audio HAL which SIM a call is on (see the
# call-audio step in app_storage_loop.sh and tools/audioparam).
if [ -f "$STAGE/ol_audioparam.dex" ]; then
    cp -f "$STAGE/ol_audioparam.dex" "$STAGE/data/local/tmp/ol_audioparam.dex"
    chmod 644 "$STAGE/data/local/tmp/ol_audioparam.dex"
fi
SECIMS="$STAGE/secims"
SECIMS_APP="$SECIMS/priv-app/OneLineageSecIms"
rm -f "$STAGE/data/local/tmp/ol_secims_staged"
if [ -f "$STAGE/data/local/tmp/ol_no_secims" ]; then
    echo "Samsung IMS in the guest: off (ol_no_secims)"
elif [ -L "$SYSEXT" ] || ! [ -d "$SYSEXT/priv-app" ]; then
    echo "Samsung IMS in the guest: off (no system_ext directory in the image)"
elif mount | grep -q " $SYSEXT type overlay"; then
    echo "Samsung IMS in the guest: overlay already mounted"
    touch "$STAGE/data/local/tmp/ol_secims_staged"
elif [ ! -f /system/priv-app/imsservice/imsservice.apk ] || [ ! -f /system/lib64/libsec-ims.so ]; then
    echo "Samsung IMS in the guest: off (One UI has no imsservice)"
else
    rm -rf "$SECIMS"
    mkdir -p "$SECIMS_APP/lib/arm64" "$SECIMS/framework" "$SECIMS/etc/permissions"
    if cp /system/priv-app/imsservice/imsservice.apk "$SECIMS_APP/OneLineageSecIms.apk" &&
       cp /system/lib64/libsec-ims.so /system/lib64/libresampler_ims.so /system/lib64/libaresdns.so "$SECIMS_APP/lib/arm64/" &&
       cp /system/framework/imsmanager.jar /system/framework/rcsopenapi.jar "$SECIMS/framework/" &&
       cp /system/framework/framework.jar "$SECIMS/framework/ol-secims-compat.jar" &&
       cp /system/etc/permissions/privapp-permissions-com.sec.imsservice.xml "$SECIMS/etc/permissions/"; then
        # Stand-in Knox providers (tools/knox_stub): the IMS app registers
        # observers on com.sec.knox.provider2 at startup and dies without it.
        if [ -f "$STAGE/OneLineageKnoxStub.apk" ]; then
            mkdir -p "$SECIMS/app/OneLineageKnoxStub"
            cp "$STAGE/OneLineageKnoxStub.apk" "$SECIMS/app/OneLineageKnoxStub/"
        fi
        # EngineeringModeManager (in the compat jar) loads this JNI library;
        # One UI's public.libraries entry makes it loadable from any class loader.
        if [ -f /system/lib64/lib.engmodejni.samsung.so ] && [ -f /system/etc/public.libraries-engmodejni.samsung.txt ]; then
            mkdir -p "$SECIMS/lib64"
            cp /system/lib64/lib.engmodejni.samsung.so "$SECIMS/lib64/"
            cp /system/etc/public.libraries-engmodejni.samsung.txt "$SECIMS/etc/"
        fi
        {
            echo '<?xml version="1.0" encoding="utf-8"?>'
            echo '<permissions>'
            # Each shared library gets its own class loader, so the Samsung
            # libraries depend on the compat jar to see its classes.
            echo '    <library name="secimshttpclient" file="/system_ext/framework/ol-secims-compat.jar" />'
            echo '    <library name="imsmanager" file="/system_ext/framework/imsmanager.jar" dependency="secimshttpclient" />'
            echo '    <library name="rcsopenapi" file="/system_ext/framework/rcsopenapi.jar" dependency="secimshttpclient" />'
            # vsimmanager carries the Gson the app needs at startup.
            for lib in vsimmanager EpdgManager svemanager; do
                if [ -f "/system/framework/$lib.jar" ] && cp "/system/framework/$lib.jar" "$SECIMS/framework/"; then
                    echo "    <library name=\"$lib\" file=\"/system_ext/framework/$lib.jar\" dependency=\"secimshttpclient\" />"
                fi
            done
            echo '</permissions>'
        } > "$SECIMS/etc/permissions/ol-secims-libraries.xml"
        # PixelOS declares no IMS feature for this phone, and without it
        # PhoneFactory skips ImsResolver ("IMS is not supported on this
        # device"), so set-ims-service has nothing to bind and calls go out
        # over the circuit-switched path that 5G SA does not have.
        cat > "$SECIMS/etc/permissions/ol-secims-features.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <feature name="android.hardware.telephony.ims" />
</permissions>
XML
        chmod -R a+rX "$SECIMS"
        chcon -R u:object_r:system_file:s0 "$SECIMS" 2>/dev/null || true
        # overlayfs refuses layers on this /data, so the layer is a small tmpfs:
        # the same tree with empty placeholders for the binaries (and the real
        # XMLs); the binaries are then bound from $SECIMS onto the placeholders.
        LAYER="$STAGE/secims_layer"
        mkdir -p "$LAYER"
        $BB umount -l "$LAYER" 2>/dev/null || true
        $BB mount -t tmpfs -o size=4m,mode=755 tmpfs "$LAYER"
        (cd "$SECIMS" && find . -type d) | while read -r d; do mkdir -p "$LAYER/$d"; done
        (cd "$SECIMS" && find . -type f) | while read -r f; do
            case "$f" in
                *.xml) cp "$SECIMS/$f" "$LAYER/$f" ;;
                *) touch "$LAYER/$f" ;;
            esac
        done
        chmod -R a+rX "$LAYER"
        chcon -R u:object_r:system_file:s0 "$LAYER" 2>/dev/null || true
        if $BB mount -t overlay overlay -o "ro,lowerdir=$LAYER:$SYSEXT" "$SYSEXT"; then
            bound=1
            for f in $(cd "$SECIMS" && find . -type f ! -name '*.xml'); do
                $BB mount --bind "$SECIMS/$f" "$SYSEXT/$f" || bound=0
            done
            if [ $bound = 1 ]; then
                touch "$STAGE/data/local/tmp/ol_secims_staged"
                echo "Samsung IMS in the guest: staged ($(du -sk "$SECIMS" | cut -f1) KB)"
            else
                echo "Samsung IMS in the guest: off (binding the binaries failed)"
                $BB umount -l "$SYSEXT" 2>/dev/null || true
            fi
        else
            echo "Samsung IMS in the guest: off (overlay mount failed)"
        fi
    else
        echo "Samsung IMS in the guest: off (copy failed)"
        rm -rf "$SECIMS"
    fi
fi

echo "=== 3e. Under-display fingerprint location ==="
# Samsung's fingerprint HAL reports no sensor location, so PixelOS's lock
# screen never drew the fingerprint icon. The driver gives the position in mm
# ("<center from bottom>,<center from middle>,...,<icon size>,..."); convert it
# to pixels with One UI's real panel dpi while One UI is still up.
# services_patched.jar reads vendor.ol.udfps_{x,y,r} (tools/patches/
# udfps_location.py); master_inner.sh sets them in the guest.
rm -f "$STAGE/data/local/tmp/ol_udfps"
FPPOS=$(cat /sys/class/fingerprint/fingerprint/position 2>/dev/null)
FPDPI=$(dumpsys display 2>/dev/null | grep -o -m1 '[0-9.]* x [0-9.]* dpi' | cut -d' ' -f3)
FPSIZE=$(wm size 2>/dev/null | grep -o 'Physical size: [0-9]*x[0-9]*' | grep -o '[0-9]*x[0-9]*')
if [ -n "$FPPOS" ] && [ -n "$FPDPI" ] && [ -n "$FPSIZE" ]; then
    echo "$FPPOS $FPDPI $FPSIZE" | $BB awk '{
        split($1, p, ","); split($3, s, "x"); mm = $2 / 25.4
        x = s[1] / 2 + p[2] * mm; y = s[2] - p[1] * mm; r = p[7] / 2 * mm
        if (p[1] > 0 && r > 0) printf "%d %d %d\n", x + 0.5, y + 0.5, r + 0.5
    }' > "$STAGE/data/local/tmp/ol_udfps"
    echo "Fingerprint location: $(cat "$STAGE/data/local/tmp/ol_udfps") (from $FPPOS at $FPDPI dpi)"
else
    echo "Fingerprint location: unknown (no position, dpi or screen size)"
fi

echo "=== 4. Setting up Core System Bind Mounts ==="
mount | grep -q "$ROOTFS/proc " || $BB mount -t proc proc "$ROOTFS/proc"
mount | grep -q "$ROOTFS/sys " || $BB mount -t sysfs sysfs "$ROOTFS/sys"
# A fresh sysfs has none of the host's submounts (/sys/fs/cgroup, /sys/fs/bpf,
# /sys/fs/selinux, ...). PixelOS aborts without them: zygote in
# createProcessGroup (/sys/fs/cgroup/system/uid_1000) and system_server in
# ClatCoordinator (/sys/fs/bpf/net_shared). Bind every host mount under /sys.
for m in $($BB awk '$2 ~ "^/sys/" {print $2}' /proc/mounts | sort -u); do
    [ -d "$m" ] || continue
    mount | grep -q "$ROOTFS$m " && continue
    mkdir -p "$ROOTFS$m" 2>/dev/null
    $BB mount --bind "$m" "$ROOTFS$m" 2>/dev/null && echo "Bound $m"
done

if [ ! -e /dev/binderfs/binder ]; then
    mount -t binder binder /dev/binderfs 2>/dev/null || true
    chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder 2>/dev/null || true
fi

$BB mount --make-rprivate "$ROOTFS" 2>/dev/null || true

if ! mount | grep -q "$ROOTFS/dev "; then
    $BB mount --rbind /dev "$ROOTFS/dev"
    $BB mount --make-rprivate "$ROOTFS/dev"
fi

mount | grep -q "$ROOTFS/linkerconfig " || $BB mount --rbind /linkerconfig "$ROOTFS/linkerconfig"
mount | grep -q "$ROOTFS/vendor " || $BB mount --bind /vendor "$ROOTFS/vendor"
mount | grep -q "$ROOTFS/odm " || $BB mount --bind /odm "$ROOTFS/odm"
mount | grep -q "$ROOTFS/vendor_dlkm " || $BB mount --bind /vendor_dlkm "$ROOTFS/vendor_dlkm"
# apexd is a HOST daemon: it reports the Samsung apex set (/system/apex,
# /system_ext/apex, /vendor/apex) to the container system_server, which then
# tries to parse those exact paths inside this namespace. Keep the apex
# directories identical to what host apexd sees (an empty tmpfs or the GSI's
# own .capex layout makes PMS abort with "Unable to parse" at boot).
if [ -d /system_ext/apex ]; then
    mkdir -p "$ROOTFS/system_ext/apex"
    mount | grep -q "$ROOTFS/system_ext/apex " || $BB mount --bind /system_ext/apex "$ROOTFS/system_ext/apex"
fi
mount | grep -q "$ROOTFS/mnt " || $BB mount --rbind /mnt "$ROOTFS/mnt"
# NetworkStack shares android.uid.networkstack with the tethering apk from the
# HOST tethering apex (Google-signed). The GSI's own NetworkStack.apk is signed
# with the GSI's keys, so PMS aborts with "Signature mismatch ... for shared
# user android.uid.networkstack". Present the host's NetworkStack instead.
GSI_NS="$ROOTFS/system/priv-app/NetworkStack"
HOST_NS=""
for d in /system/priv-app/NetworkStackGoogle /system/priv-app/NetworkStack; do
    [ -d "$d" ] && ls "$d"/*.apk >/dev/null 2>&1 && { HOST_NS="$d"; break; }
done
if [ -d "$GSI_NS" ] && [ -n "$HOST_NS" ]; then
    $BB umount -l "$GSI_NS" 2>/dev/null || true
    $BB mount --bind "$HOST_NS" "$GSI_NS" && echo "Bound host NetworkStack $HOST_NS -> $GSI_NS"
    # packages.xml from a boot with the GSI-signed NetworkStack pins the old
    # signature on the shared user; drop it once so PMS re-learns it. Android 16
    # restores packages.xml from packages.xml.reservecopy, and the parsed-package
    # cache keeps the old apk path, so both have to go as well.
    if [ ! -f "$STAGE/data/.host_networkstack_v2" ]; then
        rm -f "$STAGE/data/system/packages.xml" "$STAGE/data/system/packages-backup.xml" \
              "$STAGE/data/system/packages.xml.reservecopy" \
              "$STAGE/data/system/packages.list" 2>/dev/null
        rm -rf "$STAGE/data/system/package_cache" 2>/dev/null
        touch "$STAGE/data/.host_networkstack_v2"
    fi
else
    echo "WARNING: host NetworkStack not found, keeping the GSI one"
fi

# OnePlus-modified apps left in the waffle build crash-loop without the OnePlus
# framework (com.qti.phone: ClassNotFoundException com.oplus.evolution.*,
# restarted every ~50 ms). Hide them behind an empty directory.
mkdir -p "$STAGE/empty_dir"
for app in system/system_ext/app/QtiTelephonyService system_ext/app/QtiTelephonyService; do
    if [ -d "$ROOTFS/$app" ] && ! mount | grep -q "$ROOTFS/$app "; then
        $BB mount --bind "$STAGE/empty_dir" "$ROOTFS/$app" && echo "Hid $app"
        break
    fi
done

if [ -f "$STAGE/services_patched.jar" ]; then
    $BB umount -l "$ROOTFS/system/framework/services.jar" 2>/dev/null || true
    $BB mount --bind "$STAGE/services_patched.jar" "$ROOTFS/system/framework/services.jar"
    echo "Bound services_patched.jar -> $ROOTFS/system/framework/services.jar"
fi
if [ -f "$STAGE/framework_patched.jar" ]; then
    $BB umount -l "$ROOTFS/system/framework/framework.jar" 2>/dev/null || true
    $BB mount --bind "$STAGE/framework_patched.jar" "$ROOTFS/system/framework/framework.jar"
    echo "Bound framework_patched.jar -> $ROOTFS/system/framework/framework.jar"
fi
# Signal bars from the modem's cell info (tools/patch_telephony.sh).
if [ -f "$STAGE/telephony-common_patched.jar" ]; then
    $BB umount -l "$ROOTFS/system/framework/telephony-common.jar" 2>/dev/null || true
    $BB mount --bind "$STAGE/telephony-common_patched.jar" "$ROOTFS/system/framework/telephony-common.jar"
    echo "Bound telephony-common_patched.jar -> $ROOTFS/system/framework/telephony-common.jar"
fi
if [ -f "$STAGE/libaudio_aidl_conversion_common_cpp_patched.so" ]; then
    $BB umount -l "$ROOTFS/system/lib64/libaudio_aidl_conversion_common_cpp.so" 2>/dev/null || true
    $BB mount --bind "$STAGE/libaudio_aidl_conversion_common_cpp_patched.so" "$ROOTFS/system/lib64/libaudio_aidl_conversion_common_cpp.so"
    echo "Bound libaudio_aidl_conversion_common_cpp_patched.so"
fi
if [ -f "$STAGE/libaudioclient_aidl_conversion_patched.so" ]; then
    $BB umount -l "$ROOTFS/system/lib64/libaudioclient_aidl_conversion.so" 2>/dev/null || true
    $BB mount --bind "$STAGE/libaudioclient_aidl_conversion_patched.so" "$ROOTFS/system/lib64/libaudioclient_aidl_conversion.so"
    echo "Bound libaudioclient_aidl_conversion_patched.so"
fi
if [ -f "$STAGE/framework-res_patched.apk" ]; then
    $BB umount -l "$ROOTFS/system/framework/framework-res.apk" 2>/dev/null || true
    $BB mount --bind "$STAGE/framework-res_patched.apk" "$ROOTFS/system/framework/framework-res.apk"
    echo "Bound framework-res_patched.apk -> $ROOTFS/system/framework/framework-res.apk"
fi

if [ -f "$STAGE/PermissionController_patched.apk" ]; then
    chmod 644 "$STAGE/PermissionController_patched.apk"
    PERM_APK=$(find "$ROOTFS/apex/com.android.permission" -name "PermissionController.apk" 2>/dev/null | head -n 1)
    if [ -n "$PERM_APK" ]; then
        $BB umount -l "$PERM_APK" 2>/dev/null || true
        $BB mount --bind "$STAGE/PermissionController_patched.apk" "$PERM_APK"
        echo "Bound PermissionController_patched.apk -> $PERM_APK"
    fi
fi



echo "=== 5. Setting up Isolated Data & Bridges ==="
mkdir -p "$STAGE/data/adb" "$STAGE/data/apex" "$STAGE/data/dalvik-cache/arm64"

# Give the guest the host's authorised ADB keys. The container has no
# AdbDebuggingManager (the guest system_server registers no "adb" service), so a
# guest adbd or wireless-debugging session cannot answer an authorisation prompt;
# pre-seeding the keys is the only way it can accept this machine silently.
# Pre-seed adb_enabled=1 into the guest's settings before its system_server runs.
# The in-boot fix (in fix_app_dirs.sh) only lands once the framework is up, but
# UsbDeviceManager drops the adb USB function within seconds of system_server
# starting -- which is why adb dies right after Lineage boots and macOS stops
# seeing the phone entirely. Writing the XML now keeps the gadget stable through
# the whole boot.
GSET="$STAGE/data/system/users/0/settings_global.xml"
if [ -f "$GSET" ]; then
    if grep -q 'id="adb_enabled"' "$GSET" 2>/dev/null; then
        sed -i 's/id="adb_enabled"\([^>]*\)value="[^"]*"/id="adb_enabled"\1value="1"/' "$GSET" 2>/dev/null
    else
        sed -i 's#</settings>#    <setting id="adb_enabled" name="adb_enabled" value="1" package="android" />\n</settings>#' "$GSET" 2>/dev/null
    fi
    echo "Pre-seeded adb_enabled=1 in guest settings_global.xml"
fi

if [ -f /data/misc/adb/adb_keys ]; then
    mkdir -p "$STAGE/data/misc/adb"
    cp -f /data/misc/adb/adb_keys "$STAGE/data/misc/adb/adb_keys" 2>/dev/null && \
        chmod 640 "$STAGE/data/misc/adb/adb_keys" 2>/dev/null && \
        echo "Copied host adb_keys into the guest /data"
fi
if [ -f "$STAGE/zygote_exec" ]; then
    cp -f "$STAGE/zygote_exec" "$STAGE/data/zygote_exec"
    chmod 755 "$STAGE/data/zygote_exec"
fi
mkdir -p "$STAGE/data/user/0" "$STAGE/data/user_de/0"
mkdir -p "$STAGE/data/system/users/0" "$STAGE/data/system_de/0/spblob" "$STAGE/data/system_ce/0"
mkdir -p "$STAGE/data/misc/user/0" "$STAGE/data/misc_de/0" "$STAGE/data/misc_ce/0"
mkdir -p "$STAGE/data/anr" "$STAGE/data/app" "$STAGE/data/rollback" "$STAGE/data/incremental"

for pkg in com.android.providers.settings \
           com.android.providers.telephony \
           com.android.phone \
           com.android.systemui \
           com.android.settings \
           com.android.launcher3 \
           com.android.inputmethod.latin \
           com.android.providers.media \
           com.android.providers.downloads \
           com.android.providers.contacts \
           com.android.providers.calendar \
           org.lineageos.lineagesettings \
           com.eggdog.onepixel; do
    mkdir -p "$STAGE/data/user_de/0/$pkg/databases" \
             "$STAGE/data/user_de/0/$pkg/shared_prefs" \
             "$STAGE/data/user_de/0/$pkg/files/datastore/education" \
             "$STAGE/data/user/0/$pkg/databases" \
             "$STAGE/data/user/0/$pkg/shared_prefs" \
             "$STAGE/data/user/0/$pkg/files"
done

mkdir -p "$STAGE/data/resource-cache"
chmod 771 "$STAGE/data/resource-cache"
chown 1000:1000 "$STAGE/data/resource-cache"

rm -rf "$STAGE/data/data" 2>/dev/null || true
mkdir -p "$STAGE/data/data"

chmod -R 777 "$STAGE/data/misc" "$STAGE/data/misc_de" "$STAGE/data/misc_ce" "$STAGE/data/system" "$STAGE/data/system_de" "$STAGE/data/system_ce" "$STAGE/data/anr" "$STAGE/data/data" 2>/dev/null || true
chown -R 1000:1000 "$STAGE/data/system" "$STAGE/data/system_de" "$STAGE/data/system_ce" "$STAGE/data/misc" "$STAGE/data/misc_de" "$STAGE/data/misc_ce" 2>/dev/null || true
# App data: only the user roots, never recursively. Each app's own dir must
# keep the uid installd gave it; a recursive chown to system made the guest's
# PackageManager fail to prepare every app's storage on boot and "recover" by
# deleting it, so app data (launcher layout, Firefox, ...) reset every switch.
for d in "$STAGE/data/user" "$STAGE/data/user_de" "$STAGE/data/user/0" "$STAGE/data/user_de/0"; do
    chown 1000:1000 "$d" 2>/dev/null || true
    chmod 0771 "$d" 2>/dev/null || true
done
chown -R 10109:10109 "$STAGE/data/user_de/0/com.android.inputmethod.latin" "$STAGE/data/user/0/com.android.inputmethod.latin" 2>/dev/null || true

# Create the bluetooth stack's storage before the guest ever starts. The GSI's
# GD stack asserts out of storage_module.cc if it cannot persist bt_config.conf,
# and the staged tree never had this directory, so com.android.bluetooth
# crash-looped every 4 s from early boot. uid 1002 = bluetooth.
mkdir -p "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null
chown 1002:1002 "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null || true
chmod 0770 "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null || true

# SELinux labels matter just as much as modes here. Every directory below lives
# under /data/local/tmp, so it is created as u:object_r:shell_data_file:s0. The
# guest's system_server runs in u:r:system_server:s0 (Samsung policy) and is
# denied both read and write on shell_data_file: chmod 777 does not help, because
# the denial is MAC, not DAC. That broke UserManagerService (users/0.xml EACCES),
# EntropyMixer/BatteryStats/PackageWatchdog ("Failed to create directory for
# *.new") and finally the settings provider:
#   SQLiteCantOpenDatabaseException: /data/user_de/0/com.android.providers.settings/databases/settings.db
# Relabel the staged tree the way a real /data is labeled. The host bind mounts
# that live inside this tree (/data/apex, /data/adb, /data/media) are deliberately
# excluded so host data never gets relabeled.
echo "=== 5b. Relabeling staged /data for guest SELinux ==="
$BB chcon u:object_r:system_data_file:s0 "$STAGE/data" 2>/dev/null || true
for d in data/system data/system_de data/system_ce \
         data/misc data/misc_de data/misc_ce data/anr \
         data/local data/resource-cache data/rollback data/incremental; do
    [ -e "$STAGE/$d" ] && $BB chcon -R u:object_r:system_data_file:s0 "$STAGE/$d" 2>/dev/null || true
done
# data/app and data/dalvik-cache are labeled by restorecon in master_inner.sh
# (apk_data_file, dalvikcache_data_file), not here.
# App data roots only: installd labels each app dir with that app's own MLS
# categories, and relabeling them recursively stripped those.
for d in "$STAGE/data/user" "$STAGE/data/user_de" "$STAGE/data/user/0" "$STAGE/data/user_de/0"; do
    [ -d "$d" ] && $BB chcon u:object_r:system_data_file:s0 "$d" 2>/dev/null || true
done
# data/apex (host /data/apex) and data/adb (host /data/adb) are left alone: they
# are the host's own directories bind-mounted in, already labeled correctly, and
# chcon-ing a bind mount would relabel the host's copy.

echo "=== 5b2. Labeling staged system files for enforcing SELinux ==="
# Everything below is bind-mounted or layered into the guest's /system, /product
# and /system_ext. Created under /data/local/tmp it is shell_data_file, which
# system_server may not read once SELinux is enforcing (the patched
# PermissionController then went missing: "exactly one permissions manager;
# found []"). Real system files are system_file.
for f in "$STAGE/extra" "$STAGE/sysapps" "$STAGE/secims" "$STAGE/display_layer" "$STAGE/secims_layer" "$STAGE/empty_dir" \
         "$STAGE"/*_patched.* "$STAGE"/OneLineage*.apk "$STAGE/PermissionController_patched.apk"; do
    [ -e "$f" ] && $BB chcon -R u:object_r:system_file:s0 "$f" 2>/dev/null || true
done

echo "=== 5b2b. No incremental installs ==="
# Play installs big apps (Cash App) over incremental-fs. The files on that mount
# get system_data_file, which app domains may not map executable, so the app's
# native libs fail with "dlopen failed: couldn't map ... Permission denied".
# The property is only read when system_server starts (and One UI is replaced
# by the guest), and it goes back with the next reboot.
/data/adb/ksu/bin/resetprop ro.incremental.enable no 2>/dev/null || true

echo "=== 5b3. SELinux policy for the enforcing guest ==="
# switch_to_lineage.sh starts permissive; master_inner.sh switches to enforcing
# right before zygote (zygote only installs its seccomp filters then). The guest
# runs PixelOS userspace against Samsung's policy, which is missing types the
# guest's own *_service_contexts / *_seapp_contexts use. servicemanager cannot
# even evaluate "add" for a type that does not exist (system_server died
# creating LineageHardwareService, "SELinux denied for service"), and allow
# rules for a missing type are silently ignored, so the types are defined first.
# Patched into the live policy with KernelSU (gone at the next boot). This has
# to happen here: from inside the guest's pivoted root ksud sepolicy patch exits
# 0 and changes nothing. ksud also exits 0 for statements it ignores, so the
# result is checked against the kernel's policy below.
KSUD=/data/adb/ksu/bin/ksud
OL_RULES_OK=0; OL_RULES_BAD=0
olpatch() {
    if $KSUD sepolicy patch "$1" >/dev/null 2>&1; then OL_RULES_OK=$((OL_RULES_OK+1))
    else OL_RULES_BAD=$((OL_RULES_BAD+1)); echo "sepolicy rule failed: $1"; fi
}
if [ -x "$KSUD" ] && [ ! -f "$STAGE/data/local/tmp/ol_permissive" ]; then
    # Service types the guest registers but Samsung's policy lacks.
    for t in adbroot_service horae_service lineage_globalactions_service lineage_hardware_service              lineage_health_interface_service lineage_livedisplay_service lineage_profile_service              lineage_trust_service osense_service vendor_audioserver_service vendor_qrs_service; do
        olpatch "type $t"
        olpatch "typeattribute $t service_manager_type"
        for d in system_server ksu system_app platform_app priv_app; do
            olpatch "allow $d $t service_manager { add find list }"
        done
        olpatch "allow appdomain $t service_manager { find }"
    done
    # App domains named in the guest's seapp_contexts that Samsung's policy lacks.
    for a in esim_switcher_app ifaa_app mediashell_app pen_app updater_app; do
        olpatch "type $a"; olpatch "typeattribute $a domain"; olpatch "typeattribute $a appdomain"
        olpatch "permissive $a"
    done
    while read -r rule; do
        [ -n "$rule" ] && olpatch "$rule"
    done <<'OLRULES'
allow appdomain ksu keystore2_key { delete gen_unique_id get_info rebind use update }
allow system_server ksu keystore2_key { rebind get_info use delete update }
allow system_server ksu keystore2 { add_auth lock unlock clear_ns change_password change_user get_state }
allow system_app default_android_service service_manager { add find }
allow system_app lineage_health_interface_service service_manager { find }
allow system_app lineage_hardware_service service_manager { find }
allow system_app adbroot_service service_manager { find }
allow ksu vendor_audioserver_service service_manager { add }
allow ksu lineage_hardware_service service_manager { find }
allow ksu lineage_livedisplay_service service_manager { find }
allow system_server ksu service_manager { list }
allow system_server lineage_hardware_service service_manager { add }
allow system_server lineage_livedisplay_service service_manager { add }
allow system_server default_android_service service_manager { find }
OLRULES
    # Safety net while the guest's labels are being tightened: the core system
    # domains log their denials but are not blocked. SELinux itself stays
    # enforcing (that is what turns seccomp on and what apps can read); app
    # domains such as untrusted_app and gmscore_app stay fully enforced.
    # Empty this list to enforce those too.
    for d in system_server system_app platform_app priv_app; do olpatch "permissive $d"; done
    # ksud cannot be trusted to say whether it worked: look in the real policy.
    $BB cat /sys/fs/selinux/policy > "$STAGE/.ol_policy_check" 2>/dev/null
    # (BusyBox grep has no -a; -c counts matching lines of the binary policy.)
    if [ "$($BB grep -c lineage_hardware_service "$STAGE/.ol_policy_check" 2>/dev/null || echo 0)" != 0 ]; then
        echo "SELinux policy check: lineage_hardware_service is defined"
    else
        echo "!!! SELinux policy check: lineage_hardware_service is MISSING, the guest will not boot enforcing"
    fi
    rm -f "$STAGE/.ol_policy_check"
fi
echo "SELinux policy patches applied: $OL_RULES_OK (failed: $OL_RULES_BAD)"

echo "=== 5c. Fixing staged /data ownership and modes ==="
# The stage tree is created by root under /data/local/tmp, so its top-level
# directories come out root:root 0755. A real /data is system:system 0771, and
# system_server (uid 1000) has to be able to create /data/app/vmdl*.tmp:
#   Failed to prepare session dir: /data/app/vmdl10992519.tmp
# With 0755 root:root that mkdir gets EACCES and *every* install fails, which is
# what "non-system apps / downloads crash" looked like from the outside.
$BB chown system:system "$STAGE/data" 2>/dev/null || true
$BB chmod 0771 "$STAGE/data" 2>/dev/null || true
for d in app app-staging anr dalvik-cache incremental property resource-cache rollback ss system; do
    [ -e "$STAGE/data/$d" ] || mkdir -p "$STAGE/data/$d" 2>/dev/null || continue
    $BB chown system:system "$STAGE/data/$d" 2>/dev/null || true
    $BB chmod 0771 "$STAGE/data/$d" 2>/dev/null || true
done
mkdir -p "$STAGE/data/misc/profiles/cur/0" "$STAGE/data/misc/profiles/ref/0" 2>/dev/null || true
$BB chown system:system "$STAGE/data/misc" "$STAGE/data/misc/profiles" 2>/dev/null || true
for d in "$STAGE/data/misc/profiles/cur" "$STAGE/data/misc/profiles/ref" \
         "$STAGE/data/misc/profiles/cur/0" "$STAGE/data/misc/profiles/ref/0"; do
    [ -d "$d" ] && $BB chown system:system "$d" 2>/dev/null || true
done

echo "=== 5d. Bridging host /data app trees into the staged /data ==="
# installd and artd are HOST daemons (started by Samsung init, they cannot be
# moved into the container namespace). Left alone they create every app data
# dir, dalvik-cache entry and dexopt profile in the real /data, which the guest
# can never see - so every app process the guest zygote forks dies with:
#   Failed to mount /data_mirror/data_de/null/0/<pkg> to /data/user_de/0/<pkg>:
#   No such file or directory
# ("Failed to attach" / "start timeout" in ActivityManager.) Bind the staged
# equivalents over those host paths for the duration of the session, so those
# daemons write into the guest's data. One UI is not running meanwhile and
# return_to_oneui.sh removes the binds again.
for d in app app-staging user user_de dalvik-cache misc/profiles; do
    mkdir -p "$STAGE/data/$d" 2>/dev/null || true
    if [ -d "/data/$d" ] && ! mount | grep -q " /data/$d "; then
        $BB mount --bind "$STAGE/data/$d" "/data/$d" 2>/dev/null && echo "Bridged /data/$d -> $STAGE/data/$d"
    fi
done

mount | grep -q "$ROOTFS/data " || $BB mount --bind "$STAGE/data" "$ROOTFS/data"
mount | grep -q "$ROOTFS/data/adb " || $BB mount --bind /data/adb "$ROOTFS/data/adb"
mount | grep -q "$ROOTFS/data/apex " || $BB mount --bind /data/apex "$ROOTFS/data/apex"
mkdir -p "$ROOTFS/data/media"
# PixelOS gets its OWN internal storage (stage/data/media), not One UI's.
# The guest unlocks user 0 with its own vold/installd, and those must never
# be able to see (or "recover") One UI's real /data/media.
while mount | grep -q " $ROOTFS/data/media "; do
    $BB umount -l "$ROOTFS/data/media" 2>/dev/null || break
done
chown 1023:1023 "$ROOTFS/data/media" 2>/dev/null || true
chmod 770 "$ROOTFS/data/media" 2>/dev/null || true

echo "=== 5e. Writing per-package data-dir helper ==="
# Apps installed before the /data bridge existed have no CE/DE data dirs in the
# guest tree, and the guest zygote refuses to fork them:
#   Failed to mount /data_mirror/data_de/null/0/<pkg> to /data/user_de/0/<pkg>
# This helper recreates the dirs for every package the guest knows about, with
# the uid PMS reports. switch_to_lineage.sh runs it once the container is up.
mkdir -p "$STAGE/data/local/tmp" 2>/dev/null || true
cat > "$STAGE/data/local/tmp/fix_app_dirs.sh" <<'FIXAPPDIRS'
#!/system/bin/sh
# Create missing CE/DE data dirs (and dexopt profile dirs) for every installed
# package, using the uid PMS reports. Idempotent.
created=0
profile_dirs=0
pkg=""
for tok in $(pm list packages -U 2>/dev/null); do
    case "$tok" in
        package:*) pkg="${tok#package:}"; uid="" ;;
        uid:*)     uid="${tok#uid:}" ;;
        *)         continue ;;
    esac
    [ -n "$pkg" ] && [ -n "$uid" ] || continue
    for d in "/data/user/0/$pkg" "/data/user_de/0/$pkg"; do
        [ -d "$d" ] && continue
        if mkdir -p "$d" 2>/dev/null; then
            chown "$uid:$uid" "$d" 2>/dev/null
            chmod 0700 "$d" 2>/dev/null
            created=$((created + 1))
        fi
    done
    for d in "/data/misc/profiles/cur/0/$pkg" "/data/misc/profiles/ref/0/$pkg"; do
        [ -d "$d" ] && continue
        if mkdir -p "$d" 2>/dev/null; then
            chown "$uid:$uid" "$d" 2>/dev/null
            chmod 0771 "$d" 2>/dev/null
            profile_dirs=$((profile_dirs + 1))
        fi
    done
    pkg=""; uid=""
done
echo "[fix_app_dirs] created $created data dirs, $profile_dirs profile dirs"

# Realign ownership of pre-existing data dirs with the uid PMS assigned.
# The staged /data tree was restored from a backup, so some app dirs are still
# owned by system:system with 0777 perms. ART then refuses to load any dex from
# them ("Writable dex file ... is not allowed"), and GMS/SQLite cannot chmod its
# own files ("FileUtils.setPermissions" warnings) and the app dies. Only dirs
# whose top-level owner is wrong are touched, so later boots stay cheap.
realigned=0
if [ -f /data/system/packages.list ]; then
    while read -r pkg auid rest; do
        case "$auid" in ''|*[!0-9]*) continue ;; esac
        for base in /data/user/0 /data/user_de/0; do
            d="$base/$pkg"
            [ -d "$d" ] || continue
            cur=$(stat -c %u "$d" 2>/dev/null)
            [ "$cur" = "$auid" ] && continue
            chown -R "$auid:$auid" "$d" 2>/dev/null
            chmod -R go-w "$d" 2>/dev/null
            realigned=$((realigned + 1))
        done
    done < /data/system/packages.list
fi
echo "[fix_app_dirs] realigned $realigned data dirs to their app uid"

# Gesture navigation. The UI activator writes navigation_mode too, but it can
# run before the settings provider is ready, which leaves the value at 0 and
# the navbar back to 3-button. Do it again here, after boot completed.
cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.gestural 2>/dev/null
settings put secure navigation_mode 2 2>/dev/null

# Keep Messaging as the default SMS app. Without a holder of
# android.app.role.SMS the framework's InboundSmsHandler drops every incoming
# text before it reaches the provider, so a delivered code would vanish.
if [ "$(settings get secure sms_default_application)" != "com.android.messaging" ]; then
    cmd role add-role-holder --user 0 android.app.role.SMS com.android.messaging 2>/dev/null
    settings put secure sms_default_application com.android.messaging 2>/dev/null
    echo "[fix_app_dirs] restored default SMS app"
fi

# Bluetooth's GD stack asserts out of `storage_module.cc SaveImmediately` when
# it cannot persist its own config, and com.android.bluetooth then restarts
# every ~4 seconds for the rest of the session (1880 tombstones in one boot).
# The staged tree had no /data/misc/bluedroid at all; create it with the
# bluetooth uid (1002) so the stack can save bt_config.conf.
if [ ! -d /data/misc/bluedroid ]; then
    mkdir -p /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    chown 1002:1002 /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    chmod 0770 /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    echo "[fix_app_dirs] created /data/misc/bluedroid for the bluetooth stack"
fi

# Code files must not be writable by the app that loads them. ART rejects any
# dex/apk/jar the calling uid could modify ("Writable dex file ... is not
# allowed"), which crash-looped GMS: its Dynamite modules in
# /data/user_de/0/.../app_chimera were installed 0755. The ownership pass above
# only touches dirs whose *top-level* owner is wrong, so GMS was skipped even
# though its files were wrong. Do this on both storages, cheaply.
code_files=0
for root in /data/user/0 /data/user_de/0; do
    [ -d "$root" ] || continue
    for f in $(find "$root" -type f \( -name '*.apk' -o -name '*.jar' -o -name '*.dex' \) -perm -0200 2>/dev/null); do
        chmod a-w "$f" 2>/dev/null && code_files=$((code_files + 1))
    done
done
echo "[fix_app_dirs] made $code_files code files read-only"

# The guest's Settings.Global.ADB_ENABLED defaults to null (treated as 0), and
# the guest's UsbDeviceManager drops the adb function from the USB gadget as
# soon as it starts. That is what kills the host adbd we rely on: adb dies
# seconds after Lineage boots and macOS stops seeing the phone at all. Turn it
# on so the gadget keeps adb, and read back what actually happened.
adb_before=$(getprop sys.usb.state)
settings put global adb_enabled 1 2>/dev/null
sleep 2
echo "[fix_app_dirs] adb_enabled=1 (usb.state was '$adb_before', now '$(getprop sys.usb.state)')"

# Record system services that failed to start (e.g. AdbService: "Failure
# starting ..."), so a problem behind a later crash can be traced without
# guessing from a fresh boot.
# SystemServer reports a service that threw during startup as
# "BOOT FAILURE starting X" (reportWtf) or "Failure starting X": catch both,
# plus anything mentioning AdbService, since that is the one we care about.
{
    logcat -d -b system 2>/dev/null | grep -a -E "BOOT FAILURE|Failure starting" | head -40
    echo "--- AdbService mentions ---"
    logcat -d -b system 2>/dev/null | grep -a -i "AdbService" | tail -10
} > /data/boot_failures.log 2>/dev/null || true
FIXAPPDIRS
chmod 755 "$STAGE/data/local/tmp/fix_app_dirs.sh" 2>/dev/null || true

# The guest has no installd, so nothing creates an app's data directories when
# it is installed. PMS records the package, then zygote aborts the first launch
# with "Failed to mount /data_mirror/data_de/null/0/<pkg> to
# /data/user_de/0/<pkg>: No such file or directory". Every app installed from
# inside Lineage -- Play Store, Aurora, adb -- used to crash on launch this way.
# Create the scaffolding installd would; /data_mirror is a bind of these trees.
cat > "$STAGE/data/local/tmp/ensure_app_storage.sh" <<'ENSUREAPP'
#!/system/bin/sh
created=0
[ -f /data/system/packages.list ] || exit 0
realigned=0
while read -r pkg auid rest; do
    case "$auid" in ''|*[!0-9]*) continue ;; esac
    for d in "/data/user/0/$pkg:0771" "/data/user_de/0/$pkg:0700"; do
        p=${d%:*}; mode=${d##*:}
        if [ -d "$p" ]; then
            # Reinstalling a package can assign a NEW uid while the old data
            # dirs survive (uninstall has no installd to delete them), and the
            # app then fails with "SQLiteCantOpenDatabaseException: unable to
            # open database file" because it cannot write its own directory.
            cur=$(stat -c %u "$p" 2>/dev/null)
            if [ -n "$cur" ] && [ "$cur" != "$auid" ]; then
                chown -R "$auid:$auid" "$p" 2>/dev/null && realigned=$((realigned + 1))
            fi
            continue
        fi
        mkdir -p "$p" 2>/dev/null || continue
        chown "$auid:$auid" "$p" 2>/dev/null
        chmod "$mode" "$p" 2>/dev/null
        created=$((created + 1))
    done
    # External storage: owner is the app, group is ext_data_rw (1078).
    for kind in data media obb; do
        p="/data/media/0/Android/$kind/$pkg"
        if [ -d "$p" ]; then
            cur=$(stat -c %u "$p" 2>/dev/null)
            if [ -n "$cur" ] && [ "$cur" != "$auid" ]; then
                chown -R "$auid:1078" "$p" 2>/dev/null && realigned=$((realigned + 1))
            fi
            continue
        fi
        mkdir -p "$p" 2>/dev/null || continue
        chown "$auid:1078" "$p" 2>/dev/null
        chmod 0770 "$p" 2>/dev/null
        created=$((created + 1))
    done
done < /data/system/packages.list

# Shared storage skeleton. Without it MediaProvider cannot create
# /storage/emulated/0/Pictures/Screenshots and taking a screenshot crashes
# SystemUI ("Failed to create directory: .../.pending-NNN"), and every save
# dialog has nowhere to put its file.
for d in Pictures Pictures/Screenshots DCIM DCIM/Camera Movies Music Documents \
         Alarms Notifications Podcasts Ringtones Download; do
    p="/data/media/0/$d"
    [ -d "$p" ] && continue
    mkdir -p "$p" 2>/dev/null || continue
    chown 1023:1023 "$p" 2>/dev/null
    chmod 0775 "$p" 2>/dev/null
    created=$((created + 1))
done

if [ "$created" -gt 0 ] || [ "$realigned" -gt 0 ]; then
    echo "[ensure_app_storage] created $created dirs, realigned $realigned to new uids"
fi
exit 0
ENSUREAPP
chmod 755 "$STAGE/data/local/tmp/ensure_app_storage.sh" 2>/dev/null || true

# A new install only becomes launchable once the dirs above exist, so sweep
# while Lineage is running instead of at boot only. Started by master_inner.
cat > "$STAGE/data/local/tmp/net_fix.sh" <<'NETFIX'
#!/system/bin/sh
# The guest's ConnectivityService cannot install its routes into the host's
# netd: every addRoute fails with "No such file or directory", so the final
# catch-all ip rule keeps pointing at a table from a previous network and all
# traffic ends in the "unreachable" rule. Symptom: the modem reports
# MOBILE[LTE] CONNECTED / VALIDATED, yet every app (Aurora, Play Store) says
# "check your internet connection" and even ping to the gateway fails.
# Keep a private table (4242) in sync with the live interface - wifi first,
# else mobile/CLAT - and point a catch-all rule at it. Idempotent.
have_v4() { ip -4 addr show "$1" 2>/dev/null | grep -q "inet "; }
iface=""
# Check wifi first (wlan0 on most devices, wlan1 on some).
for _w in wlan0 wlan1; do
    if have_v4 "$_w"; then iface=$_w; break; fi
done
if [ -z "$iface" ]; then
    # Mobile data: try Qualcomm rmnet_data*, Snapdragon IPA rmnet_ipa*, and
    # MediaTek ccmni* interfaces. Some Exynos builds use rmnet0/rmnet1.
    for d in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' \
               | grep -E '^(rmnet_data|rmnet_ipa|ccmni|rmnet)[0-9]'); do
        if have_v4 "$d"; then iface=$d; break; fi
    done
fi
[ -z "$iface" ] && exit 0
subnet=$(ip route show table all 2>/dev/null | awk -v d="$iface" \
    '$2=="dev" && $3==d && $0 ~ /scope link/ && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\// {print $1; exit}')
[ -z "$subnet" ] && exit 0
gw=$(ip route show table all 2>/dev/null | awk -v d="$iface" \
    '$1=="default" && $2=="via" && $4=="dev" && $5==d && $3 ~ /^[0-9]+\./ {print $3; exit}')
# no IPv4 default anywhere (netd never installed one): assume the first host
[ -z "$gw" ] && gw="${subnet%.*}.1"
ip route replace "$subnet" dev "$iface" table 4242 2>/dev/null
ip route replace default via "$gw" dev "$iface" table 4242 2>/dev/null
# Priority must beat the per-uid rules netd already installed for previous
# networks (15040/29040/29998): app sockets carry an fwmark, so a catch-all
# placed after those still sends them into a dead table even though root's
# unmarked pings work.
cur=$(ip rule show 2>/dev/null | awk '/^14999:/{print $NF; exit}')
if [ "$cur" != "4242" ]; then
    ip rule del priority 14999 2>/dev/null
    ip rule add from all lookup 4242 priority 14999 2>/dev/null
    ip rule del priority 31999 2>/dev/null
    echo "net route repaired: $iface $subnet gw $gw"
fi
exit 0
NETFIX
chmod 755 "$STAGE/data/local/tmp/net_fix.sh" 2>/dev/null || true

cat > "$STAGE/data/local/tmp/app_storage_loop.sh" <<'APPLOOP'
#!/system/bin/sh
# Watches for installs/removals, gives the new package its data dirs, and makes
# the launcher re-query so the app actually shows up.
(
    # sys.boot_completed is shared with One UI (already 1), so wait for the
    # guest's own phone service, registered late in its boot.
    while ! service check phone 2>/dev/null | grep -q ': found'; do sleep 5; done
    sleep 10
    # Samsung IMS staged by master_prepare.sh: make it the device IMS service
    # for both SIM slots. Not persisted, so this runs at every boot. -f 0,1
    # (EMERGENCY_MMTEL, MMTEL) is required on Android 16 or nothing is bound;
    # a device (-d) override survives carrier-config changes.
    if [ -f /data/local/tmp/ol_secims_staged ] && pm path com.sec.imsservice >/dev/null 2>&1; then
        for s in 0 1; do
            cmd phone ims set-ims-service -s $s -d -f 0,1 com.sec.imsservice >/dev/null 2>&1
        done
        echo "$(date) IMS: com.sec.imsservice set as MMTEL service (slot 0: $(cmd phone ims get-ims-service -s 0 -d -f 1))" >> /data/app_storage.log
    elif [ -f /data/local/tmp/ol_secims_staged ]; then
        echo "$(date) IMS: staged but com.sec.imsservice is not installed (signature carve-out missing?)" >> /data/app_storage.log
    fi
    # Call audio: Samsung's audio HAL plays a call through the voice channel
    # (VSID) of the SIM slot it was last told about. One UI's Telecom sends
    # g_call_sim_slot before every call; PixelOS's never does, so with the SIM
    # in slot 2 calls ran on slot 1's channel and were silent both ways. The
    # HAL keeps the slot between calls, so set it once here, to the first slot
    # with a SIM (gsm.sim.state is e.g. "ABSENT,LOADED" -> 0x02).
    if [ -f /data/local/tmp/ol_audioparam.dex ]; then
        slot=$(getprop gsm.sim.state | awk -F, '{ for (i = 1; i <= NF; i++) if ($i == "LOADED" || $i == "READY") { print i; exit } }')
        if [ -n "$slot" ]; then
            res=$(CLASSPATH=/data/local/tmp/ol_audioparam.dex app_process /system/bin com.onelineage.audioparam.Main "g_call_sim_slot=0x0$slot" 2>&1)
            echo "$(date) call audio: $res" >> /data/app_storage.log
        fi
    fi
) &
last=""
while true; do
    sleep 10
    case "$(getprop sys.boot_completed)" in 1) ;; *) continue ;; esac
    netout=$(/system/bin/sh /data/local/tmp/net_fix.sh 2>/dev/null)
    [ -n "$netout" ] && echo "$(date) $netout" >> /data/app_storage.log
    cur=$(md5sum /data/system/packages.list 2>/dev/null | cut -d' ' -f1)
    out=$(/system/bin/sh /data/local/tmp/ensure_app_storage.sh 2>/dev/null)
    if [ -n "$last" ] && { [ "$cur" != "$last" ] || [ -n "$out" ]; }; then
        # A package appeared or went away. LauncherApps caches the app list, so
        # something installed from Aurora or Play Store is missing from both the
        # drawer and app search until the launcher re-queries. Restarting the
        # launcher forces that and does not touch whatever app is in front.
        am force-stop com.android.launcher3 2>/dev/null
        echo "$(date) package list changed -> launcher refreshed ${out:+($out)}" >> /data/app_storage.log
    elif [ -n "$out" ]; then
        echo "$(date) $out" >> /data/app_storage.log
    fi
    last=$cur
done
APPLOOP
chmod 755 "$STAGE/data/local/tmp/app_storage_loop.sh" 2>/dev/null || true

echo "=== 6. Setting up /system/xbin/su (KernelSU Bridge) ==="
if ! mount | grep -q "$ROOTFS/system/xbin "; then
    $BB mount -t tmpfs tmpfs "$ROOTFS/system/xbin"
    SU_SRC="/data/adb/ksud"
    [ -f "$SU_SRC" ] || SU_SRC=$(which su 2>/dev/null)
    [ -f "$SU_SRC" ] || SU_SRC=$(find /data/adb /system/bin -name su 2>/dev/null | head -n 1)
    [ -f "$SU_SRC" ] && cp "$SU_SRC" "$ROOTFS/system/xbin/su" && chmod 755 "$ROOTFS/system/xbin/su"
fi

echo "=== 7. Setting up Fresh APEX tmpfs ==="
# Clean any stale submounts and ensure a clean, writable tmpfs
for m in $(cat /proc/mounts 2>/dev/null | grep "$ROOTFS/apex" | awk '{print $2}' | sort -r); do
    $BB umount -l "$m" 2>/dev/null || true
done
$BB umount -l "$ROOTFS/apex" 2>/dev/null || true
$BB mount -t tmpfs tmpfs "$ROOTFS/apex"

# NOTE: the list is only a hint; apexd (host daemon) owns the preinstalled set
# and PMS parses the paths it reports. That is why the host's apex directories
# are bound into this rootfs (see the /system_ext/apex and /system/apex binds):
# every path in this list must resolve after the pivot.
if [ -f "$STAGE/clean_apex_info_list.xml" ]; then
    cp "$STAGE/clean_apex_info_list.xml" "$ROOTFS/apex/apex-info-list.xml"
else
    cp -a /apex/apex-info-list.xml "$ROOTFS/apex/" 2>/dev/null || true
fi
chmod 644 "$ROOTFS/apex/apex-info-list.xml" 2>/dev/null || true

echo "=== 8. Direct Mounting Extracted APEX Payloads ==="
mount_payload() {
    NAME="$1"
    TARGET="$2"
    IMG="$STAGE/${NAME}_payload.img"
    DEST="$ROOTFS/apex/$TARGET"
    # A cached payload smaller than 64K is a failed extraction (seen: 0 and 4096
    # bytes), which leaves the apex dir empty and kills zygote. Re-extract it,
    # trying busybox unzip first and the system unzip as a fallback.
    [ -f "$IMG" ] && [ "$(stat -c %s "$IMG" 2>/dev/null || echo 0)" -lt 65536 ] && rm -f "$IMG"
    if [ ! -f "$IMG" ]; then
        CAPEX="$ROOTFS/system/apex/com.android.${NAME}.capex"
        APEX="$ROOTFS/system/apex/com.android.${NAME}.apex"
        for UZ in "$BB unzip" "unzip"; do
            if [ -f "$CAPEX" ]; then
                $UZ -p "$CAPEX" original_apex > "$STAGE/temp_${NAME}.apex" 2>/dev/null
                $UZ -p "$STAGE/temp_${NAME}.apex" apex_payload.img > "$IMG" 2>/dev/null
                rm -f "$STAGE/temp_${NAME}.apex"
            elif [ -f "$APEX" ]; then
                $UZ -p "$APEX" apex_payload.img > "$IMG" 2>/dev/null
            fi
            [ "$(stat -c %s "$IMG" 2>/dev/null || echo 0)" -ge 65536 ] && break
            echo "WARNING: $NAME payload extraction with '$UZ' failed"
            rm -f "$IMG"
        done
    fi
    [ -f "$IMG" ] || { echo "WARNING: no payload for $NAME, /apex/$TARGET will be empty"; return 0; }
    if mount | grep "$DEST " | grep -q "/dev/block/dm-"; then
        $BB umount -l "$DEST" 2>/dev/null || true
        for vdir in "$ROOTFS/apex/${TARGET}"@*; do
       [ -d "$vdir" ] && $BB umount -l "$vdir" 2>/dev/null || true
        done
    fi
    if mount | grep "$DEST " | grep -q "/dev/block/loop"; then
        echo "$NAME already mounted on loop at $DEST"
        return 0
    fi
    mkdir -p "$DEST"
    $BB umount -l "$DEST" 2>/dev/null || true
    LOOP=$($BB losetup -f)
    $BB losetup "$LOOP" "$IMG"
    $BB mount -t ext4 -o ro "$LOOP" "$DEST"
    echo "Direct mounted $NAME on $LOOP -> $DEST"
    for vdir in "$ROOTFS/apex/${TARGET}"@*; do
        if [ -d "$vdir" ]; then
       $BB umount -l "$vdir" 2>/dev/null || true
       $BB mount -t ext4 -o ro "$LOOP" "$vdir"
       echo "Direct mounted $NAME on $LOOP -> $vdir"
        fi
    done
}

mount_payload "art" "com.android.art"
mount_payload "i18n" "com.android.i18n"
mount_payload "runtime" "com.android.runtime"
mount_payload "sdkext" "com.android.sdkext"
mount_payload "nfcservices" "com.android.nfcservices"
# tethering: keep the HOST apex. Its BpfNetMaps must match the BPF maps the
# host netbpfload created; the GSI copy fails with "Cannot open netd
# configuration map" (EAGAIN) and kills system_server.
rm -f "$STAGE/tethering_payload.img"
mount_payload "crashrecovery" "com.android.crashrecovery"
# cellbroadcast: keep the HOST apex too. CellBroadcastService shares
# android.uid.networkstack with the host tethering/NetworkStack, so the GSI copy
# fails PMS with "Signature mismatch ... for shared user".
rm -f "$STAGE/cellbroadcast_payload.img"
mount_payload "extservices" "com.android.extservices"
mount_payload "permission" "com.android.permission"
mount_payload "wifi" "com.android.wifi"
mount_payload "appsearch" "com.android.appsearch"
mount_payload "mediaprovider" "com.android.mediaprovider"
mount_payload "adservices" "com.android.adservices"
mount_payload "rkpd" "com.android.rkpd"
mount_payload "healthfitness" "com.android.healthfitness"
mount_payload "ondevicepersonalization" "com.android.ondevicepersonalization"
mount_payload "configinfrastructure" "com.android.configinfrastructure"
mount_payload "bt" "com.android.bt"

# Payload extractions above used the GSI's own /system/apex files. Now that the
# images are cached, present the HOST's /system/apex to the container so the
# preinstalled paths reported by host apexd all resolve (see the note above
# about /system_ext/apex).
if [ -d /system/apex ]; then
    mkdir -p "$ROOTFS/system/apex"
    mount | grep -q "$ROOTFS/system/apex " || $BB mount --bind /system/apex "$ROOTFS/system/apex"
fi

echo "=== 9. Bind-mounting Remaining Non-Payload APEXes ==="
for a in /apex/*; do
    [ -d "$a" ] || continue
    base=$(basename "$a")
    case "$base" in
        *samsung*)
       continue
       ;;
    esac
    # Skip if already mounted
    if ! mount | grep -q "$ROOTFS/apex/$base "; then
        mkdir -p "$ROOTFS/apex/$base"
        $BB mount --bind "$a" "$ROOTFS/apex/$base" 2>/dev/null || true
        echo "Bound $base -> $ROOTFS/apex/$base"
    fi
done

# PermissionController patch, second pass. The same block near step 4 runs
# before the apex set is mounted, so find(1) finds nothing and Samsung's
# PermissionController stays behind. Samsung's build requires
# android.permission.RANGING, which the GSI platform does not define, so every
# runtime-permission dialog dies with
#   IllegalStateException: android.permission.RANGING not defined by platform
#   -> "Permission controller keeps stopping"
# and Gallery/Phone/Calendar can never be granted anything. Bind it now that
# /apex/com.android.permission actually exists.
if [ -f "$STAGE/PermissionController_patched.apk" ]; then
    chmod 644 "$STAGE/PermissionController_patched.apk" 2>/dev/null || true
    for PERM_APK in $(find "$ROOTFS/apex/com.android.permission" -name "PermissionController.apk" 2>/dev/null); do
        $BB umount -l "$PERM_APK" 2>/dev/null || true
        $BB mount --bind "$STAGE/PermissionController_patched.apk" "$PERM_APK" 2>/dev/null && echo "Bound PermissionController_patched.apk (late) -> $PERM_APK"
    done
else
    echo "!!! WARNING: PermissionController_patched.apk missing from $STAGE"
    echo "!!! Samsung's PermissionController will crash every runtime-permission dialog"
    echo "!!! (android.permission.RANGING not defined by platform)"
fi

echo "=== ALL MOUNTS PREPARED SUCCESSFULLY ==="
