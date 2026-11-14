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

echo "=== 4. Setting up Core System Bind Mounts ==="
mount | grep -q "$ROOTFS/proc " || $BB mount -t proc proc "$ROOTFS/proc"
mount | grep -q "$ROOTFS/sys " || $BB mount -t sysfs sysfs "$ROOTFS/sys"

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

# --- Samsung's IMS app in the guest (VoLTE, SMS over IMS) -------------------
# T-Mobile and other VoLTE-only carriers refuse both calls and texts without
# IMS ("SMS over NAS is not supported"), and on a Samsung phone IMS is the One
# UI system app com.sec.imsservice, which dies with One UI's framework. Copy
# THIS phone's copy (never a bundled one) into a read-only overlay on the
# guest's system_ext, so Lineage sees /system_ext/priv-app/OneLineageSecIms.
# services_patched.jar admits it into android.uid.system from that path only
# (tools/patches/sec_ims_signature.py); One UI's framework.jar is offered as
# the optional library "secimshttpclient" so the app finds its Samsung
# classes. Approach from OneOS (docs/SAMSUNG_IMS.md). Opt out with
# $STAGE/data/local/tmp/ol_no_secims. Must run before the binds below that
# land inside system_ext.
SECIMS="$STAGE/secims"
SECIMS_APP="$SECIMS/priv-app/OneLineageSecIms"
rm -f "$STAGE/data/local/tmp/ol_secims_staged"
if [ -f "$STAGE/data/local/tmp/ol_no_secims" ]; then
    echo "Samsung IMS in the guest: off (ol_no_secims)"
elif mount | grep -q " $ROOTFS/system/system_ext type overlay"; then
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
        # Samsung's EngineeringModeManager (in the compat jar) loads this JNI
        # library; One UI's own public.libraries list makes it loadable from
        # any class loader. Without it the app dies at start.
        if [ -f /system/lib64/lib.engmodejni.samsung.so ] && [ -f /system/etc/public.libraries-engmodejni.samsung.txt ]; then
            mkdir -p "$SECIMS/lib64"
            cp /system/lib64/lib.engmodejni.samsung.so "$SECIMS/lib64/"
            cp /system/etc/public.libraries-engmodejni.samsung.txt "$SECIMS/etc/"
        fi
        {
            echo '<?xml version="1.0" encoding="utf-8"?>'
            echo '<permissions>'
            # Each shared library gets its own class loader, so the Samsung
            # libraries must depend on the compat jar to see its classes
            # (imsmanager's Capabilities needs android.os.SemSystemProperties).
            echo '    <library name="secimshttpclient" file="/system_ext/framework/ol-secims-compat.jar" />'
            echo '    <library name="imsmanager" file="/system_ext/framework/imsmanager.jar" dependency="secimshttpclient" />'
            echo '    <library name="rcsopenapi" file="/system_ext/framework/rcsopenapi.jar" dependency="secimshttpclient" />'
            # Optional libraries the app declares. vsimmanager is not optional
            # in practice: it carries the Gson the app needs at startup.
            for lib in vsimmanager EpdgManager svemanager; do
                if [ -f "/system/framework/$lib.jar" ] && cp "/system/framework/$lib.jar" "$SECIMS/framework/"; then
                    echo "    <library name=\"$lib\" file=\"/system_ext/framework/$lib.jar\" dependency=\"secimshttpclient\" />"
                fi
            done
            echo '</permissions>'
        } > "$SECIMS/etc/permissions/ol-secims-libraries.xml"
        chmod -R a+rX "$SECIMS"
        chcon -R u:object_r:system_file:s0 "$SECIMS" 2>/dev/null || true
        # overlayfs refuses every layer on this /data (EINVAL), so the layer
        # is a small tmpfs: the same tree with empty placeholders for the
        # binaries (and the real XMLs), and the binaries are then bound from
        # $SECIMS onto the placeholders inside the merged system_ext.
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
        if $BB mount -t overlay overlay -o "lowerdir=$LAYER:$ROOTFS/system/system_ext" "$ROOTFS/system/system_ext"; then
            bound=1
            for f in $(cd "$SECIMS" && find . -type f ! -name '*.xml'); do
                $BB mount --bind "$SECIMS/$f" "$ROOTFS/system/system_ext/$f" || bound=0
            done
            if [ $bound = 1 ]; then
                touch "$STAGE/data/local/tmp/ol_secims_staged"
                echo "Samsung IMS in the guest: staged ($(du -sk "$SECIMS" | cut -f1) KB)"
            else
                echo "Samsung IMS in the guest: off (binding the binaries failed)"
                $BB umount -l "$ROOTFS/system/system_ext" 2>/dev/null || true
            fi
        else
            echo "Samsung IMS in the guest: off (overlay mount failed)"
        fi
    else
        echo "Samsung IMS in the guest: off (copy failed)"
        rm -rf "$SECIMS"
    fi
fi

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
# Codec-list spin fix. The guest's MediaCodecList::getInstance() asks the shared
# "media.player" service for IMediaCodecList. On firmware where Samsung's
# mediaserver serves that itself (no separate media.codec, e.g. S26 Ultra
# AZCF), its reply does not match the GSI's AIDL, the list length is garbage and
# system_server/SystemUI/mediaserver spin at 400%+ CPU (overheating). Renaming
# the one "media.player" lookup in libstagefright (same length) makes the lookup
# fail, and getInstance() falls back to getLocalInstance(), building the list
# in-process from the Codec2 HAL. MediaPlayer itself uses libmedia's lookup and
# is untouched.
SF_SRC="$ROOTFS/system/lib64/libstagefright.so"
SF_PATCH="$STAGE/libstagefright_patched.so"
if [ ! -f "$SF_PATCH" ] && [ -f "$SF_SRC" ]; then
    SF_HITS=$(grep -c -a "media\.player" "$SF_SRC" 2>/dev/null)
    SF_OFF=$(grep -abo "media\.player" "$SF_SRC" 2>/dev/null | head -n 1 | cut -d: -f1)
    if [ "$SF_HITS" = "1" ] && [ -n "$SF_OFF" ]; then
        cp -f "$SF_SRC" "$SF_PATCH.tmp"
        printf 'nolist' | dd of="$SF_PATCH.tmp" bs=1 seek=$((SF_OFF + 6)) conv=notrunc 2>/dev/null
        if grep -q -a "media\.nolist" "$SF_PATCH.tmp" && ! grep -q -a "media\.player" "$SF_PATCH.tmp"; then
            mv -f "$SF_PATCH.tmp" "$SF_PATCH"
            echo "Created libstagefright_patched.so (codec-list lookup at offset $SF_OFF)"
        else
            rm -f "$SF_PATCH.tmp"
            echo "!!! WARNING: libstagefright patch verification failed, skipping"
        fi
    else
        echo "!!! WARNING: expected 1 media.player in libstagefright.so, found ${SF_HITS:-0}; skipping patch"
    fi
fi
if [ -f "$SF_PATCH" ]; then
    chmod 644 "$SF_PATCH"
    chcon u:object_r:system_lib_file:s0 "$SF_PATCH" 2>/dev/null || true
    $BB umount -l "$SF_SRC" 2>/dev/null || true
    $BB mount --bind "$SF_PATCH" "$SF_SRC"
    echo "Bound libstagefright_patched.so"
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
           com.wewaffles.onelineage; do
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

chmod -R 777 "$STAGE/data/user" "$STAGE/data/user_de" "$STAGE/data/misc" "$STAGE/data/misc_de" "$STAGE/data/misc_ce" "$STAGE/data/system" "$STAGE/data/system_de" "$STAGE/data/system_ce" "$STAGE/data/anr" "$STAGE/data/data" 2>/dev/null || true
chown -R 1000:1000 "$STAGE/data/system" "$STAGE/data/system_de" "$STAGE/data/system_ce" "$STAGE/data/user" "$STAGE/data/user_de" "$STAGE/data/misc" "$STAGE/data/misc_de" "$STAGE/data/misc_ce" 2>/dev/null || true
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
for d in data/system data/system_de data/system_ce data/user data/user_de \
         data/misc data/misc_de data/misc_ce data/anr data/dalvik-cache \
         data/local data/resource-cache data/app data/rollback data/incremental; do
    [ -e "$STAGE/$d" ] && $BB chcon -R u:object_r:system_data_file:s0 "$STAGE/$d" 2>/dev/null || true
done
for d in "$STAGE/data/user/0" "$STAGE/data/user_de/0"; do
    if [ -d "$d" ]; then
        $BB chcon u:object_r:system_data_file:s0 "$d" 2>/dev/null || true
        $BB chcon -R u:object_r:app_data_file:s0 "$d"/* 2>/dev/null || true
    fi
done
# data/apex (host /data/apex) and data/adb (host /data/adb) are left alone: they
# are the host's own directories bind-mounted in, already labeled correctly, and
# chcon-ing a bind mount would relabel the host's copy.

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
mount | grep -q "$ROOTFS/data/media " || $BB mount --bind /data/media "$ROOTFS/data/media" 2>/dev/null || true

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
    # `ip -o link` prints stacked links as "rmnet_data7@rmnet_ipa0": strip
    # the parent, or no interface name ever matches.
    for d in $(ip -o link show 2>/dev/null | awk -F': ' '{sub(/@.*/, "", $2); print $2}' \
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
ip route replace "$subnet" dev "$iface" table 4242 2>/dev/null
if [ -n "$gw" ]; then
    ip route replace default via "$gw" dev "$iface" table 4242 2>/dev/null
else
    # No IPv4 default anywhere (netd never installed one). Mobile links are
    # raw-IP point-to-point (T-Mobile's gateway 192.0.0.7 is not the subnet's
    # first host), so route straight out of the device; wifi needs a next
    # hop, so guess the first host there.
    case "$iface" in
        wlan*) ip route replace default via "${subnet%.*}.1" dev "$iface" table 4242 2>/dev/null ;;
        *)     ip route replace default dev "$iface" table 4242 2>/dev/null ;;
    esac
fi
# IPv6: the kernel puts the router-advertised default in its own table
# (ifindex + 1000), which no rule reaches. Copy it into 4242 as well;
# IPv6-only carriers (T-Mobile) send most traffic, DNS included, over it.
gw6=$(ip -6 route show table all 2>/dev/null | awk -v d="$iface" \
    '$1=="default" && $2=="via" && $4=="dev" && $5==d {print $3; exit}')
if [ -n "$gw6" ]; then
    ip -6 route replace default via "$gw6" dev "$iface" table 4242 2>/dev/null
    cur6=$(ip -6 rule show 2>/dev/null | awk '/^14999:/{print $NF; exit}')
    if [ "$cur6" != "4242" ]; then
        ip -6 rule del priority 14999 2>/dev/null
        ip -6 rule add from all lookup 4242 priority 14999 2>/dev/null
        echo "net route repaired (v6): $iface gw $gw6"
    fi
fi
# Priority must beat the per-uid rules netd already installed for previous
# networks (15040/29040/29998): app sockets carry an fwmark, so a catch-all
# placed after those still sends them into a dead table even though root's
# unmarked pings work.
cur=$(ip rule show 2>/dev/null | awk '/^14999:/{print $NF; exit}')
if [ "$cur" != "4242" ]; then
    ip rule del priority 14999 2>/dev/null
    ip rule add from all lookup 4242 priority 14999 2>/dev/null
    ip rule del priority 31999 2>/dev/null
    echo "net route repaired: $iface $subnet gw ${gw:-direct}"
fi
exit 0
NETFIX
chmod 755 "$STAGE/data/local/tmp/net_fix.sh" 2>/dev/null || true

cat > "$STAGE/data/local/tmp/app_storage_loop.sh" <<'APPLOOP'
#!/system/bin/sh
# Watches for installs/removals, gives the new package its data dirs, and makes
# the launcher re-query so the app actually shows up.
# Default display density for Lineage: 450 (the panel's native value) is very
# small on a 1440-wide screen. Set it as a guest-only override once booted,
# and only when no density was chosen yet, so a size picked in Settings or
# with `wm density` sticks. ro.sf.lcd_density is shared with One UI, so it is
# left alone.
OL_DENSITY=540
(
    # sys.boot_completed is shared with One UI (already 1), so wait for the
    # guest's own phone service, registered late in its boot.
    while ! service check phone 2>/dev/null | grep -q ': found'; do sleep 5; done
    sleep 10
    cur=$(settings get secure display_density_forced 2>/dev/null)
    case "$cur" in
        ""|null) wm density "$OL_DENSITY" 2>/dev/null &&
            echo "$(date) display density defaulted to $OL_DENSITY" >> /data/app_storage.log ;;
    esac
    # Samsung IMS staged by master_prepare.sh: make it the device IMS service
    # (calls, SMS over IMS) for both SIM slots. `cmd phone cc` is refused on a
    # user build; `ims set-ims-service` is allowed and is not persisted, so
    # this runs at every boot. The feature list (-f 0,1: EMERGENCY_MMTEL,
    # MMTEL) is required: without it Android 16 overrides no features and
    # nothing is bound. It is a device (-d) override because a carrier one is
    # dropped again on the next carrier-config change.
    if [ -f /data/local/tmp/ol_secims_staged ] && pm path com.sec.imsservice >/dev/null 2>&1; then
        for s in 0 1; do
            cmd phone ims set-ims-service -s $s -d -f 0,1 com.sec.imsservice >/dev/null 2>&1
        done
        echo "$(date) IMS: com.sec.imsservice set as MMTEL service (slot 1: $(cmd phone ims get-ims-service -s 1 -d -f 1))" >> /data/app_storage.log
    elif [ -f /data/local/tmp/ol_secims_staged ]; then
        echo "$(date) IMS: staged but com.sec.imsservice is not installed (signature carve-out missing?)" >> /data/app_storage.log
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
    if [ ! -f "$IMG" ]; then
        CAPEX="$ROOTFS/system/apex/com.android.${NAME}.capex"
        APEX="$ROOTFS/system/apex/com.android.${NAME}.apex"
        if [ -f "$CAPEX" ]; then
            $BB unzip -p "$CAPEX" original_apex > "$STAGE/temp_${NAME}.apex" 2>/dev/null
            $BB unzip -p "$STAGE/temp_${NAME}.apex" apex_payload.img > "$IMG" 2>/dev/null
            rm -f "$STAGE/temp_${NAME}.apex"
        elif [ -f "$APEX" ]; then
            $BB unzip -p "$APEX" apex_payload.img > "$IMG" 2>/dev/null
        fi
    fi
    [ -f "$IMG" ] || return 0
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
mount_payload "tethering" "com.android.tethering"
mount_payload "crashrecovery" "com.android.crashrecovery"
mount_payload "cellbroadcast" "com.android.cellbroadcast"
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
