#!/system/bin/sh
STAGE="/data/local/tmp/oneos"
ROOTFS="$STAGE/rootfs"
# OneOS: init's mount namespace only (oneos_switch.sh's preflight makes
# sure of it). The bridges below are for One UI's installd and artd, which run
# there; made in any other namespace they would not reach them (run 25).
if [ -z "$(readlink /proc/$$/ns/mnt 2>/dev/null)" ] || [ "$(readlink /proc/$$/ns/mnt 2>/dev/null)" != "$(readlink /proc/1/ns/mnt 2>/dev/null)" ]; then
    echo "ERROR: not in init's mount namespace ($(readlink /proc/$$/ns/mnt 2>/dev/null), init $(readlink /proc/1/ns/mnt 2>/dev/null)); not starting the guest"
    exit 4
fi
# The root manager's own busybox, never a search of /data.
BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    [ -x "$c" ] && { BB=$c; break; }
done
[ -n "$BB" ] || [ "${ONEOS_APP:-0}" = 1 ] || BB=$(command -v busybox 2>/dev/null)
[ -n "$BB" ] && [ -x "$BB" ] || { echo "ERROR: no busybox at the root manager's paths; not starting the guest"; exit 4; }
# OneOS: nothing may be mounted at or under the staged /data while it is
# rebuilt. The rm -rf, chown -R and chcon -R below would go through such a
# mount into the phone's real data.
if awk -v p="$STAGE/data" '$5 == p || index($5, p "/") == 1' /proc/self/mountinfo | grep -q .; then
    echo "ERROR: something is mounted under $STAGE/data (an earlier session?); return to One UI first"
    awk -v p="$STAGE/data" '$5 == p || index($5, p "/") == 1 {print "  " $5}' /proc/self/mountinfo
    exit 4
fi
# One UI's own partitions as mounted now (mount points), compared after the
# setup below: nothing of the guest may land on them. In an image with
# system/product as an absolute link to /product, binds made through the
# rootfs's system/product in this (host) namespace went onto One UI's own
# /product (Z Fold8 Ultra, 2026-10-25): its product_seapp_contexts and
# split-permissions-google.xml were the guest's for the session, and the
# in-place return found them and rebooted.
host_part_mounts() {
    awk '$5 ~ /^\/(system|system_ext|product|vendor|vendor_dlkm|odm|odm_dlkm|oem|prism|optics|my_[a-z_]+)(\/|$)/ {print $5}' /proc/self/mountinfo | sort
}
host_part_mounts > "$STAGE/host_part_mounts.before"
# Nor may a host /data tree still be bridged from a session that never
# returned: refuse, and let the return (reboot) clean up.
[ -r "$STAGE/bridges.sh" ] || { echo "ERROR: $STAGE/bridges.sh missing"; exit 4; }
. "$STAGE/bridges.sh" || { echo "ERROR: $STAGE/bridges.sh unreadable"; exit 4; }
for need in app:app user:user user_de:user_de data:user/0 media:media; do
    case " $BRIDGES " in *" $need "*) ;; *) echo "ERROR: bridges.sh lacks $need; not starting the guest"; exit 4 ;; esac
done
for pair in $BRIDGES; do
    h=${pair%%:*}
    if awk -v p="/data/$h" '$5 == p' /proc/self/mountinfo | grep -q .; then
        echo "ERROR: /data/$h is still bridged from an earlier session; return to One UI (reboot) first"
        exit 4
    fi
done
# OneOS: no symlink may sit on any staged /data path the host root below writes
# through, binds or relabels. A guest with root (a ColorOS root daemon, or an
# app that got root) could, between sessions, point e.g. $STAGE/data/misc at
# /data/misc, or $STAGE/data/oneos_bin/busybox at a host file; the rm/cp, the
# chown/chcon and the bridge binds would then land in One UI's real /data. A
# symlinked PARENT escapes too, so every component is checked. Refuse (exit 3)
# before the first change.
[ -L "$STAGE/data" ] && { echo "ERROR: $STAGE/data is a symlink; not starting the guest"; exit 3; }
no_symlink() { # <relative path under $STAGE/data>: refuse if any component is a link
    _p="$STAGE/data"; _oifs=$IFS; IFS=/
    for _c in $1; do
        _p="$_p/$_c"
        if [ -L "$_p" ]; then
            IFS=$_oifs
            echo "ERROR: $_p is a symlink (a guest may have planted it to reach host /data); not starting the guest"
            exit 3
        fi
    done
    IFS=$_oifs
}
for pair in $BRIDGES; do no_symlink "${pair#*:}"; done
for s in data misc misc/adb misc/profiles misc/user misc/bluedroid misc/bluetooth \
         misc_ce/0 misc_de/0 system system/devicestate system/package_cache \
         system/watchdog_timestamps system_de system_ce user/0 user_de/0 \
         oneos_bin oneos_bin/busybox zygote_exec oplus oplus/multimedia \
         preapps-lib media/0 anr app local/tmp resource-cache oneos_fold8 oneos_pixel_hinge oneos_hinge; do
    no_symlink "$s"
done
# The framework jars must be the ones built with the storage, installd and
# power guards (scripts/make-overlays.sh records their hashes in guards.txt).
if [ ! -f "$STAGE/guards.txt" ]; then
    echo "ERROR: $STAGE/guards.txt missing: overlays not built with the guards; not starting the guest"
    exit 3
fi
# oplus-services_patched.jar too when guards.txt lists it; an image with
# oplus-services.jar is refused below unless that one is bound. So are
# vold_patched and service.incremental_patched.so (the guest vold as "gvld"),
# HyperOS's miui-services_patched.jar and apprecovery.proinstaller_patched.jar,
# and the Pixel camera client libraries.
for need in services_patched.jar $(awk '$2 == "oplus-services_patched.jar" || $2 == "vold_patched" || $2 == "service.incremental_patched.so" ||
                                        $2 == "miui-services_patched.jar" || $2 == "apprecovery.proinstaller_patched.jar" ||
                                        $2 == "framework_patched.jar" || $2 == "miui-wifi-service_patched.jar" || $2 == "miui-telephony-common_patched.jar" ||
                                        $2 == "libcamera_client_patched.so" || $2 == "libcameracompatbilityinfo_patched.so" { print $2 }' "$STAGE/guards.txt"); do
    sum=$(awk -v n="$need" '$2 == n {print $1}' "$STAGE/guards.txt")
    if [ -z "$sum" ] || [ "$(sha256sum "$STAGE/$need" 2>/dev/null | cut -d' ' -f1)" != "$sum" ]; then
        echo "ERROR: $STAGE/$need missing or not the guarded build in guards.txt; not starting the guest"
        exit 3
    fi
done
echo "Guarded overlays verified: $(grep -v '^#' "$STAGE/guards.txt" | awk '{print $2}' | tr '\n' ' ')"
# Google Play services in a Pixel guest (docs/pixel-guest.md, "Google services"):
# GmsCore from the image's own gmssystem APEX payload (make-overlays.sh stages
# gmssystem_payload.img), presented in section 8 and after the hidden folders
# below. Infinity-X (0.4.27) keeps Play services the same way, next to OPPO's
# jars; ColorOS sets never stage the payload (guest_google.sh is theirs). ONEOS_GUEST_GMS=1 (default) presents it when the payload is staged,
# 0 never. Refused here, before the first change:
# - with ONEOS_GUEST_HIDE_GMS=1, which hides Google Services Framework, the Play
#   Store and the PrebuiltGmsCore folder GmsCore is presented in;
# - without the guards guards.txt records for a Google services guest: the
#   phone's gatekeeper (screen lock), FRP partition (pdb) and apexd stay One
#   UI's, and guest apps get app ids from 15000 (no keystore namespace shared
#   with One UI's apps);
# - on a stage whose packages.list has app uids 10000-14999: made before the app
#   id guard, its apps keep the uids One UI's apps have. Such a stage needs a
#   fresh guest data dir (deploy-phone.sh --fresh).
GMS_WANT=0
case "${ONEOS_GUEST_GMS:-1}" in
    0) ;;
    1) [ -f "$STAGE/gmssystem_payload.img" ] && GMS_WANT=1 ;;
    *) echo "ERROR: ONEOS_GUEST_GMS=$ONEOS_GUEST_GMS (0 or 1); not starting the guest"; exit 3 ;;
esac
if [ "$GMS_WANT" = 1 ]; then
    if [ "${ONEOS_GUEST_HIDE_GMS:-0}" = 1 ]; then
        echo "ERROR: ONEOS_GUEST_GMS is on (the default) with gmssystem_payload.img staged, and ONEOS_GUEST_HIDE_GMS=1 hides Google services; set ONEOS_GUEST_GMS=0 or drop ONEOS_GUEST_HIDE_GMS. Not starting the guest"
        exit 3
    fi
    for t in gatekeeper pdb apexd appid15000; do
        grep '^#' "$STAGE/guards.txt" | grep -qw "$t" && continue
        echo "ERROR: guards.txt does not list the $t guard: services_patched.jar was built without the guards Google services need (scripts/make-overlays.sh). ONEOS_GUEST_GMS=0 starts without them. Not starting the guest"
        exit 3
    done
    GMS_LOW=$(awk '$2 ~ /^[0-9]+$/ && $2 >= 10000 && $2 <= 14999 { n++; if (n <= 3) l = l " " $1 "=" $2 } END { if (n) print n " (" substr(l, 2) ")" }' "$STAGE/data/system/packages.list" 2>/dev/null)
    if [ -n "$GMS_LOW" ]; then
        echo "ERROR: the staged guest has $GMS_LOW app uids in 10000-14999 (a stage from before the app id guard: its apps share keystore namespaces with One UI's). Google services need a fresh guest data dir (deploy-phone.sh --fresh); ONEOS_GUEST_GMS=0 starts this stage without them. Not starting the guest"
        exit 3
    fi
    echo "Google services: GmsCore from gmssystem_payload.img will be presented (ONEOS_GUEST_GMS=0 starts without it)"
elif [ "${ONEOS_GUEST_GMS:-1}" = 0 ]; then
    echo "Google services: not presented (ONEOS_GUEST_GMS=0)"
else
    echo "Google services: not presented (no gmssystem_payload.img staged)"
fi
# Set again only once GmsCore is bound (below); oneos_switch.sh's UI
# activator reads it (Pixel's setup wizard).
rm -f "$STAGE/data/oneos_gms_present"
# Stale state in the staged /data. The package manager's parse cache survives
# sessions and its freshness check is defeated by the image's 2009 mtimes, so
# /system paths bind-swapped here (NetworkStack, CaptivePortalLogin) kept their
# old parse ("Could not resolve the networking module" in run 25). ColorOS's
# watchdog counts kills across sessions in watchdog_timestamps.
rm -rf "$STAGE/data/system/package_cache" "$STAGE/data/system/watchdog_timestamps" 2>/dev/null
# How's it going? (0.4.30): the guest OneOS app's checklist is one session's;
# a new session starts without the last one's answers.
rm -f "$STAGE/data/user/0/com.fahadali.oneos.guest/files/oneos_checklist.json" 2>/dev/null

echo "=== 1. Ensuring Watchdog Feeder is Active ==="
# One UI's system_server opens /dev/watchdog (Samsung's softdog) unless
# persist.vendor.softdog is off, sets 100 s and kicks it (services.jar
# WatchdogSoftdog); stopped at [4b/6], it leaves the softdog running. The
# Galaxy Z Flip7 (d5e743e6) and S26+ (80387c66), both Exynos, panicked
# ("Software Watchdog Timer expired 100s") about 100 s after the guest's
# system_server started. Each write is "V": a ping, and the magic close, so the
# softdog stops on every close where the driver allows it, and stays stopped
# if this loop ever ends. Every change between written and refused goes to
# watchdog_feeder.log with the device's holders. A feeder of an older build
# (echo -n 1) is replaced.
# The S26+ (4cad07e6, 0.4.19) panicked the same way with that feeder running:
# on this phone /dev/watchdog is the hardware watchdog, held and fed by init's
# watchdogd the whole time (the feeder's writes were refused, EBUSY), and
# Samsung's "Software Watchdog Timer" is a second node, /dev/softdog, which
# One UI's system_server feeds and the community "Watchdog Feeder" module for
# OneLineage writes "1" to every 5 s (it waits for vendor.hotboot.rom=1, which
# OneOS never sets). The panic came 100 s after the guest's system_server
# died. 0.4.20 wrote "1" to /dev/softdog, but neither the S26+ nor the Z Flip7
# has that node (756047eb, aaeea148: both panicked again); oneos_switch.sh now
# turns the softdog off through Samsung's init (persist.vendor.softdog=off).
# The feeder kicks only watchdogs the kernel lists as active software ones
# (/sys/class/watchdog: identity "Software Watchdog"; never a hardware one it
# might start), and logs every watchdog node, its state and time left (every
# change, at most every 10 s), so the next Exynos session shows which one runs.
pkill -f 'echo -n 1 > /dev/watchdog' 2>/dev/null
if ! ps -ef | grep -v grep | grep -q "oneos_wdog_feeder.sh"; then
    echo "Starting watchdog feeder..."
    cat > "$STAGE/oneos_wdog_feeder.sh" <<'WDOG'
L=/data/local/tmp/oneos/watchdog_feeder.log
holders() {
    for p in /proc/[0-9]*; do
        ls -l "$p/fd" 2>/dev/null | grep -q '/dev/watchdog\|/dev/softdog' && printf ' %s:%s' "${p#/proc/}" "$(cat "$p/comm" 2>/dev/null)"
    done
}
# Every watchdog the kernel lists: name, identity, state, timeout, time left.
wdogs() {
    for w in /sys/class/watchdog/watchdog*; do
        [ -d "$w" ] || continue
        printf ' [%s "%s" %s timeout %s left %s]' "${w##*/}" "$(cat "$w/identity" 2>/dev/null)" "$(cat "$w/state" 2>/dev/null)" \
            "$(cat "$w/timeout" 2>/dev/null)" "$(cat "$w/timeleft" 2>/dev/null)"
    done
}
{ echo "$(date +%T) nodes: $(ls -ln /dev/watchdog* /dev/softdog* 2>/dev/null | awk '{printf "%s %s:%s %s; ", $NF, $3, $4, $1}')"
  echo "$(date +%T) persist.vendor.softdog=$(getprop persist.vendor.softdog) init.svc.watchdogd=$(getprop init.svc.watchdogd); kernel:$(wdogs)"; } >> "$L"
was=''; n=0; seen=''
while true; do
    if e=$(printf V 2>&1 > /dev/watchdog); then now=written; else now="refused ($e)"; fi
    # An active software watchdog other than /dev/watchdog: kicked ("V", the
    # magic close where the driver allows it), never started.
    for w in /sys/class/watchdog/watchdog*; do
        [ "$(cat "$w/state" 2>/dev/null)" = active ] || continue
        case "$(cat "$w/identity" 2>/dev/null)" in *[Ss]oft*) ;; *) continue ;; esac
        d=/dev/${w##*/}
        [ -c "$d" ] || continue
        if e=$(printf V 2>&1 > "$d"); then now="$now; $d kicked"; else now="$now; $d refused ($e)"; fi
    done
    if [ "$now" != "$was" ]; then
        echo "$(date +%T) /dev/watchdog $now; held by:$(holders)" >> "$L"
        was=$now
    fi
    n=$((n + 1))
    if [ $((n % 5)) = 0 ]; then
        k=$(wdogs)
        [ "$(echo "$k" | sed 's/ left [0-9]*\]/]/g')" != "$seen" ] || [ $((n % 30)) = 0 ] &&
            echo "$(date +%T) persist.vendor.softdog=$(getprop persist.vendor.softdog); kernel:$k" >> "$L"
        seen=$(echo "$k" | sed 's/ left [0-9]*\]/]/g')
    fi
    sleep 2
done
WDOG
    chmod 700 "$STAGE/oneos_wdog_feeder.sh"
    nohup $BB sh "$STAGE/oneos_wdog_feeder.sh" </dev/null >/dev/null 2>&1 &
fi

echo "=== 2. Creating Loop Device Nodes ==="
for i in $(seq 50 150); do
    minor=$((i * 8))
    rm -f /dev/block/loop$i /dev/loop$i 2>/dev/null || true
    mknod /dev/block/loop$i b 7 $minor
    mknod /dev/loop$i b 7 $minor
done

echo "=== 3. Mounting system.raw if needed ==="
# Read-only flag of a loop device, by its device number (the node names made
# above need not match the kernel's loopN).
loop_ro() {
    d=$(stat -L -c '%t %T' "$1" 2>/dev/null) || return 1
    set -- $d
    [ "$(cat "/sys/dev/block/$(printf '%d:%d' "0x$1" "0x$2")/ro" 2>/dev/null)" = 1 ]
}
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
    # OneOS: a read-only loop device. A plain one let the ro ext4 mount replay
    # a journal into system.raw, which changes the file the app verified (its
    # stat identity in system.raw.id, checked before every switch).
    if ! $BB losetup -r "$LOOP" "$STAGE/system.raw"; then
        echo "ERROR: could not attach system.raw read-only ($LOOP); not starting the guest"
        exit 3
    fi
    if ! loop_ro "$LOOP"; then
        if [ "${ONEOS_APP:-0}" = 1 ]; then
            echo "ERROR: $LOOP is not read-only after losetup -r; not starting the guest"
            $BB losetup -d "$LOOP" 2>/dev/null
            exit 3
        fi
        echo "WARNING: could not confirm that $LOOP is read-only (sysfs)"
    fi
    echo "Using LOOP: $LOOP (read-only)"
    $BB mount -t ext4 -o ro "$LOOP" "$ROOTFS"
fi

mkdir -p "$ROOTFS/postinstall" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" \
    "$ROOTFS/linkerconfig" "$ROOTFS/vendor" "$ROOTFS/odm" "$ROOTFS/vendor_dlkm" \
    "$ROOTFS/mnt" "$ROOTFS/storage" "$ROOTFS/apex" "$ROOTFS/data"

echo "=== 4. Setting up Core System Bind Mounts ==="
mount | grep -q "$ROOTFS/proc " || $BB mount -t proc proc "$ROOTFS/proc"
# The host's /sys with everything mounted under it (not a fresh sysfs): the
# guest needs the cgroup2 hierarchy at /sys/fs/cgroup, or zygote cannot put
# system_server in a process group ("createProcessGroup(1000, 0) failed: No
# such file or directory") and it dies on fork; selinuxfs and the bpf fs live
# there too.
if ! mount | grep -q "$ROOTFS/sys "; then
    $BB mount --rbind /sys "$ROOTFS/sys"
    $BB mount --make-rslave "$ROOTFS/sys"
fi

if [ ! -e /dev/binderfs/binder ]; then
    mount -t binder binder /dev/binderfs 2>/dev/null || true
    chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder 2>/dev/null || true
fi

$BB mount --make-rprivate "$ROOTFS" 2>/dev/null || true

if ! mount | grep -q "$ROOTFS/dev "; then
    $BB mount --rbind /dev "$ROOTFS/dev"
    $BB mount --make-rprivate "$ROOTFS/dev"
fi

# OneOS: each bind is made rslave right after it is created, like /dev and /sys
# above. These are peers of the host's shared /mnt, /linkerconfig, /vendor, ...
# mounts; the final --make-rprivate "$ROOTFS" is reached only on the success
# path, so without this an early exit (a missing payload, the /data/adb remount)
# left them shared, and return_to_oneui.sh's umount -l then propagated to the
# host's own /mnt/vendor/efs, /vendor etc. (One UI lost its wifi APEX contents,
# system_server boot loop).
if mount | grep -q "$ROOTFS/linkerconfig " || $BB mount --rbind /linkerconfig "$ROOTFS/linkerconfig"; then
    $BB mount --make-rslave "$ROOTFS/linkerconfig" 2>/dev/null || true
fi
for vb in vendor odm vendor_dlkm; do
    if mount | grep -q "$ROOTFS/$vb " || $BB mount --bind "/$vb" "$ROOTFS/$vb"; then
        $BB mount --make-rslave "$ROOTFS/$vb" 2>/dev/null || true
    fi
done
# apexd is a HOST daemon: it reports the Samsung apex set (/system/apex,
# /system_ext/apex, /vendor/apex) to the container system_server, which then
# tries to parse those exact paths inside this namespace. Keep the apex
# directories identical to what host apexd sees (an empty tmpfs or the GSI's
# own .capex layout makes PMS abort with "Unable to parse" at boot).
# OneOS: resolve system_ext inside the rootfs. In a GSI it is an absolute
# symlink (/system/system_ext), which in this (host) namespace points at the
# HOST's /system_ext, so the bind used to land on the host's own apex dir and
# the guest kept its own: PackageManagerService then died parsing
# /system_ext/apex/com.android.compos.apex, which host apexd reports but the
# guest's tree does not have.
GUEST_SYSTEM_EXT="$ROOTFS/system_ext"
[ -L "$GUEST_SYSTEM_EXT" ] && GUEST_SYSTEM_EXT="$ROOTFS/system/system_ext"
# product the same way, the other way round: ColorOS and Pixel images have
# system/product and an absolute link /product -> /system/product; others
# have /product and system/product -> /product, which in this namespace is One
# UI's /product (see host_part_mounts at the top).
GUEST_PRODUCT="$ROOTFS/system/product"
[ -L "$GUEST_PRODUCT" ] && GUEST_PRODUCT="$ROOTFS/product"
for d in "$GUEST_SYSTEM_EXT" "$GUEST_PRODUCT"; do
    if [ -L "$d" ] || [ ! -d "$d" ]; then
        echo "ERROR: ${d#$ROOTFS/} in the guest image is a link or missing (system_ext and product: one real folder each); not starting the guest"
        exit 3
    fi
done
# Signal bars in a guest without ColorOS's OplusSignalSmooth (run 43, Pixel):
# Samsung's RIL sends the guest no signal strength indication and AOSP polls
# only for opportunistic subscriptions, so both SIMs kept the all-invalid value
# read right after RADIO_POWER on (level 0 all session). TeleService's own
# TelephonyComponentFactory injection loads oneos-telephony.jar
# (scripts/make-overlays.sh), whose OneOSSignalPoll sends GET_SIGNAL_STRENGTH
# every 20 s with the screen on: the jar goes in a read-only overlay layer on
# the guest's system_ext below (the injection takes a jar only on a read-only
# mount under /system, /product or /system_ext), OneOSPhoneInjection.apk in its
# /oem/overlay names it. Only on the telephony-common.jar and TeleService.apk
# the jar was built and checked against (oneos-telephony.sha256): a stale RRO
# would replace another image's own injection config. The oplus jar is tested
# here directly (GUEST_OTC is set further down). ONEOS_GUEST_SIGNAL_POLL=0
# leaves it out.
INJ=0
if [ -d "$GUEST_SYSTEM_EXT" ] && [ ! -f "$GUEST_SYSTEM_EXT/framework/oplus-telephony-common.jar" ]; then
    if [ "${ONEOS_GUEST_SIGNAL_POLL:-1}" != 1 ]; then
        echo "Signal poll: off (ONEOS_GUEST_SIGNAL_POLL=0)"
    elif [ -f "$STAGE/oneos-telephony.jar" ] && [ -f "$STAGE/OneOSPhoneInjection.apk" ] && [ -f "$STAGE/oneos-telephony.sha256" ]; then
        INJ=1
        inj_n=0
        while read -r inj_sum inj_rel; do
            inj_n=$((inj_n + 1))
            [ -n "$inj_rel" ] && [ "$($BB sha256sum "$ROOTFS/$inj_rel" 2>/dev/null | cut -d' ' -f1)" = "$inj_sum" ] ||
                { INJ=0; echo "Signal poll: off ($inj_rel is not the file oneos-telephony.jar was built for)"; }
        done < "$STAGE/oneos-telephony.sha256"
        [ "$inj_n" = 2 ] || { INJ=0; echo "Signal poll: off (oneos-telephony.sha256 has $inj_n lines, 2 expected)"; }
    else
        echo "Signal poll: oneos-telephony.jar, .sha256 or OneOSPhoneInjection.apk not staged (make-overlays.sh builds them only for an image they fit)"
    fi
fi
# HIDL. libhidlbase uses hwservicemanager only when one of its binaries is
# there (system/system_ext/bin, system_ext/bin or system/bin; access() only,
# nothing runs it). Infinity-X is built for a phone without HIDL: its
# system/bin/hwservicemanager links to a system_ext file it does not ship, so
# every guest process took HIDL for absent. On the S23's HIDL-only display
# composer its surfaceflinger aborted ("failed to get hwcomposer service") and
# audioserver found no audio HAL (S23 Ultra session 99ef8224). One UI's
# hwservicemanager serves /dev/hwbinder to the guest as to the images that
# ship one (ColorOS), so an empty file at system_ext/bin/hwservicemanager in
# the overlay below lets the guest's HIDL clients ask it. Only when the image
# has none, One UI runs hwservicemanager, and this phone's vendor manifest
# declares no AIDL display composer or no AIDL audio HAL (as return_to_oneui.sh
# reads it): elsewhere the guests without one (Pixel) keep running as they do.
HWSM=0
HWSM_WHY=""
"$BB" grep -rqs 'android.hardware.graphics.composer3' /vendor/etc/vintf/ || HWSM_WHY="display composer"
"$BB" grep -rqs 'android.hardware.audio.core' /vendor/etc/vintf/ || HWSM_WHY="${HWSM_WHY:+$HWSM_WHY and }audio HAL"
if [ -n "$HWSM_WHY" ] && [ -d "$GUEST_SYSTEM_EXT/bin" ] &&
    [ ! -e "$GUEST_SYSTEM_EXT/bin/hwservicemanager" ] && [ ! -L "$GUEST_SYSTEM_EXT/bin/hwservicemanager" ] &&
    { [ -L "$ROOTFS/system/bin/hwservicemanager" ] || [ ! -e "$ROOTFS/system/bin/hwservicemanager" ]; } && pidof hwservicemanager >/dev/null; then
    HWSM=1
fi
# --- Samsung's IMS stack in the guest (ONEOS_GUEST_SEC_IMS=1) ----------------
# VoLTE on a Samsung phone is the system app com.sec.imsservice (the SIP stack
# is its libsec-ims.so). It reaches the modem through the vendor HAL channel
# vendor.samsung.hardware.radio.channel.ISehRadioChannel/imsd and the host
# daemon imsd over /dev/socket/imsd; both survive the switch (the guest sees
# the host's /dev), the app does not: it dies with One UI's framework, so every
# guest ran calls on 3G and a VoLTE-only carrier (T-Mobile US) got none. The
# app is a plain android.telephony.ims.ImsService (BIND_IMS_SERVICE), so the
# guest's telephony can bind it like its own. Nothing of it is shipped: every
# One UI build has its own, so it is taken from THIS phone's One UI at every
# prepare, read from /system and copied into $STAGE/secims, a lower layer of
# the guest's system_ext (below): the APK as a system_ext priv-app with its
# privapp-permissions list, its library jars with their XMLs, the three native
# libraries (the system linker namespace searches /system_ext/lib64). The 33
# Samsung-only framework classes it needs (307 with what they pull in: Sem*
# managers, CSC features, the HAL stubs) come from One UI's own framework.jar,
# handed to it as the optional library "secimshttpclient" that the app's
# manifest already declares and One UI does not define; the guest's boot
# classes win on every duplicate name, so only the Samsung classes load from
# it. The guest's package manager takes this Samsung-signed package into
# android.uid.system only from this staged path (a services.jar carve-out,
# scripts/make-overlays.sh patches/guest_sec_ims_signature.py; recorded as the
# secims word in guards.txt). Off unless ONEOS_GUEST_SEC_IMS=1.
SEC_IMS=0
SECIMS="$STAGE/secims"
rm -f "$STAGE/data/oneos_sec_ims"
sec_ims_off() { echo "Samsung IMS in the guest: off ($1)"; rm -rf "$SECIMS" 2>/dev/null; }
sec_ims_stage() {
    rm -rf "$SECIMS"
    mkdir -p "$SECIMS/priv-app/OneOSSecIms" "$SECIMS/framework" "$SECIMS/lib64" "$SECIMS/etc/permissions" || return 1
    cp /system/priv-app/imsservice/imsservice.apk "$SECIMS/priv-app/OneOSSecIms/" || return 1
    cp /system/framework/imsmanager.jar /system/framework/rcsopenapi.jar "$SECIMS/framework/" || return 1
    cp /system/framework/framework.jar "$SECIMS/framework/oneos-secims-compat.jar" || return 1
    cp /system/lib64/libsec-ims.so /system/lib64/libresampler_ims.so /system/lib64/libaresdns.so "$SECIMS/lib64/" || return 1
    cp /system/etc/permissions/privapp-permissions-com.sec.imsservice.phone.xml "$SECIMS/etc/permissions/" || return 1
    # Libraries the manifest lists as not required: along when One UI has them.
    for lib in vsimmanager EpdgManager; do
        [ -f "/system/framework/$lib.jar" ] && { cp "/system/framework/$lib.jar" "$SECIMS/framework/" || return 1; }
    done
    # The library XMLs name the guest's copies.
    for pair in imsmanager:imsmanager.jar rcsopenapi:rcsopenapi.jar secimshttpclient:oneos-secims-compat.jar \
                vsimmanager:vsimmanager.jar EpdgManager:EpdgManager.jar; do
        [ -f "$SECIMS/framework/${pair#*:}" ] || continue
        printf '<?xml version="1.0" encoding="utf-8"?>\n<permissions>\n    <library name="%s" file="/system_ext/framework/%s"/>\n</permissions>\n' \
            "${pair%%:*}" "${pair#*:}" > "$SECIMS/etc/permissions/${pair%%:*}_library.xml" || return 1
    done
    # Make the guest advertise IMS support. An AOSP-based guest (Infinity-X, the
    # Pixels) only starts ImsResolver when the device has FEATURE_TELEPHONY_IMS;
    # without it PhoneFactory logs "IMS is not supported on this device, skipping
    # ImsResolver" and the staged app is installed but never bound (report
    # 707642218d0049a0: S24 Ultra on Infinity-X, calls stayed on 3G/failed).
    # system_ext/etc/permissions is scanned for <feature>. One UI/ColorOS images
    # already declare it, so this is a no-op there.
    printf '<?xml version="1.0" encoding="utf-8"?>\n<permissions>\n    <feature name="android.hardware.telephony.ims"/>\n</permissions>\n' \
        > "$SECIMS/etc/permissions/oneos-telephony-ims.xml" || return 1
    find "$SECIMS" -type d -exec chmod 755 {} + && find "$SECIMS" -type f -exec chmod 644 {} + || return 1
    $BB chcon -h -R u:object_r:system_file:s0 "$SECIMS" 2>/dev/null || true
    $BB chcon -h u:object_r:system_lib_file:s0 "$SECIMS"/lib64/*.so 2>/dev/null || true
    return 0
}
# Bind the staged Samsung IMS tree onto the guest's system_ext (made writable by
# the overlay below) a file at a time, rather than adding $SECIMS as a second
# overlay lower layer: some kernels (Galaxy S24 Ultra, report 8fe87c0c9064a2a2)
# reject an overlay with more than one lower dir (mount ... : Invalid argument).
# Only empty mount points are created in the overlay's tmpfs upper; the content
# stays on the staged copy. The return path unmounts every mount under the stage.
sec_ims_bind() {
    local gse="$GUEST_SYSTEM_EXT" n=0 f t d
    mkdir -p "$gse/priv-app/OneOSSecIms" || return 1
    $BB mount --bind "$SECIMS/priv-app/OneOSSecIms" "$gse/priv-app/OneOSSecIms" || return 1
    $BB mount --make-rslave "$gse/priv-app/OneOSSecIms" 2>/dev/null || true
    for d in framework lib64 etc/permissions; do
        [ -d "$SECIMS/$d" ] || continue
        mkdir -p "$gse/$d" || return 1
        for f in "$SECIMS/$d"/*; do
            [ -f "$f" ] || continue
            t="$gse/$d/$(basename "$f")"
            [ -e "$t" ] || : > "$t" || return 1
            $BB mount --bind "$f" "$t" || return 1
            $BB mount --make-rslave "$t" 2>/dev/null || true
            n=$((n + 1))
        done
    done
    echo "Samsung IMS in the guest: staged set bind-mounted onto $gse (OneOSSecIms priv-app + $n files; this kernel rejects a second overlay lower layer)"
    return 0
}
if [ "${ONEOS_GUEST_SEC_IMS:-0}" = 1 ]; then
    secims_missing=""
    for f in /system/priv-app/imsservice/imsservice.apk /system/framework/framework.jar /system/framework/imsmanager.jar \
             /system/framework/rcsopenapi.jar /system/lib64/libsec-ims.so /system/lib64/libresampler_ims.so \
             /system/lib64/libaresdns.so /system/etc/permissions/privapp-permissions-com.sec.imsservice.phone.xml; do
        [ -f "$f" ] || secims_missing="$secims_missing $f"
    done
    if [ ! -d "$GUEST_SYSTEM_EXT" ]; then sec_ims_off "the guest has no system_ext"
    elif [ -L "$SECIMS" ]; then echo "ERROR: $SECIMS is a symlink; not starting the guest"; exit 3
    # Only the sets whose services.jar carries the carve-out can keep the
    # Samsung-signed package in android.uid.system; on the others the guest's
    # scan drops it and calls stay on 3G with nothing in the log to say why.
    # Say it here instead of staging 40 MB the guest will throw away.
    elif ! grep '^#' "$STAGE/guards.txt" | grep -qw secims; then
        sec_ims_off "this system's overlays were built without the secims carve-out (guards.txt): the guest would drop com.sec.imsservice"
    elif [ -n "$secims_missing" ]; then sec_ims_off "this One UI lacks$secims_missing"
    elif [ -f /system/etc/permissions/secimshttpclient_library.xml ] || [ -f /system_ext/etc/permissions/secimshttpclient_library.xml ]; then
        sec_ims_off "this One UI defines the secimshttpclient library itself; the compat jar needs that name"
    elif sec_ims_stage; then
        SEC_IMS=1
        touch "$STAGE/data/oneos_sec_ims"
        echo "Samsung IMS in the guest: staged from this One UI ($(du -sk "$SECIMS" 2>/dev/null | cut -f1) KB: $(ls "$SECIMS/framework" | tr '\n' ' ')$(ls "$SECIMS/lib64" | tr '\n' ' '))"
    else
        sec_ims_off "copy from /system failed"
    fi
else
    rm -rf "$SECIMS" 2>/dev/null
fi
# ColorOS's system_ext has no apex dir and the image is mounted read-only, so
# put a thin overlayfs on it to create the mount point. Its upper layer is a
# small tmpfs: overlayfs refuses an upper dir on the encrypted f2fs /data
# (EINVAL). return_to_oneui.sh unmounts $STAGE/system_ext_ov.
# With the signal poll (INJ=1) the same tmpfs is instead the top one of two
# lower layers (apex mount point and framework/oneos-telephony.jar), with no
# upper dir: a read-only overlay, which InjectedComponents requires (statvfs
# ST_RDONLY; on the rw form the jar is dropped from "validated paths").
# An overlay left by an earlier prepare is never unmounted here (umount
# propagation); the signal poll then goes ahead only if it is that read-only one
# with the same jar (checked below).
# With the Samsung IMS set (SEC_IMS=1) the staged tree is bind-mounted onto the
# guest's system_ext after the overlay is up (sec_ims_bind), not added as a second
# overlay lower layer, which some kernels reject (EINVAL). An overlay left by an
# earlier prepare cannot take it.
SECIMS_BOUND=0
if { [ -d /system_ext/apex ] && [ -d "$GUEST_SYSTEM_EXT" ]; } || [ $INJ = 1 ] || [ $HWSM = 1 ] || [ $SEC_IMS = 1 ]; then
    if mount | grep -q " $GUEST_SYSTEM_EXT type overlay"; then
        echo "Overlay on $GUEST_SYSTEM_EXT already there (an earlier prepare), left as it is"
        [ $SEC_IMS = 1 ] && { SEC_IMS=0; rm -f "$STAGE/data/oneos_sec_ims"; echo "Samsung IMS in the guest: off (that overlay has no secims layer)"; }
    elif [ ! -d "$GUEST_SYSTEM_EXT/apex" ] || [ $INJ = 1 ] || [ $HWSM = 1 ] || [ $SEC_IMS = 1 ]; then
        OV="$STAGE/system_ext_ov"
        mkdir -p "$OV"
        mount | grep -q " $OV " || $BB mount -t tmpfs -o size=1m,mode=755 tmpfs "$OV"
        mkdir -p "$OV/up/apex"
        if [ $HWSM = 1 ]; then
            mkdir -p "$OV/up/bin" && : > "$OV/up/bin/hwservicemanager" &&
                chmod 755 "$OV/up/bin" "$OV/up/bin/hwservicemanager" || HWSM=0
            $BB chcon u:object_r:system_file:s0 "$OV/up/bin" 2>/dev/null || true
            $BB chcon u:object_r:hwservicemanager_exec:s0 "$OV/up/bin/hwservicemanager" 2>/dev/null || true
        fi
        if [ $INJ = 1 ]; then
            mkdir -p "$OV/up/framework" && cp "$STAGE/oneos-telephony.jar" "$OV/up/framework/" &&
                chmod 755 "$OV/up" "$OV/up/framework" && chmod 644 "$OV/up/framework/oneos-telephony.jar"
            # A stage copy, labelled like the image's own framework files.
            $BB chcon u:object_r:system_file:s0 "$OV/up/framework" "$OV/up/framework/oneos-telephony.jar" 2>/dev/null || true
            if $BB mount -t overlay overlay -o "ro,lowerdir=$OV/up:$GUEST_SYSTEM_EXT" "$GUEST_SYSTEM_EXT"; then
                echo "Read-only overlay on $GUEST_SYSTEM_EXT (apex mount point, framework/oneos-telephony.jar)"
            else
                # The apex mount point matters more: today's rw form then.
                INJ=0
                rm -rf "$OV/up/framework"
                echo "Signal poll: off (read-only overlay on $GUEST_SYSTEM_EXT refused)"
            fi
        fi
        if [ $INJ = 0 ] && { [ ! -d "$GUEST_SYSTEM_EXT/apex" ] || [ $HWSM = 1 ] || [ $SEC_IMS = 1 ]; }; then
            mkdir -p "$OV/work"
            if $BB mount -t overlay overlay \
                -o "lowerdir=$GUEST_SYSTEM_EXT,upperdir=$OV/up,workdir=$OV/work" \
                "$GUEST_SYSTEM_EXT"; then
                echo "Overlay on $GUEST_SYSTEM_EXT for the apex mount point$([ $HWSM = 1 ] && echo ' and bin/hwservicemanager')"
                if [ $SEC_IMS = 1 ]; then
                    if sec_ims_bind; then SECIMS_BOUND=1; else
                        SEC_IMS=0; rm -f "$STAGE/data/oneos_sec_ims"
                        echo "Samsung IMS in the guest: off (bind-mount onto $GUEST_SYSTEM_EXT failed)"
                    fi
                fi
            elif [ $SEC_IMS = 1 ]; then
                SEC_IMS=0; rm -f "$STAGE/data/oneos_sec_ims"
                echo "Samsung IMS in the guest: off (overlay on $GUEST_SYSTEM_EXT refused)"
            fi
        fi
        # The Samsung IMS set needs the writable overlay above to bind onto; a
        # read-only (signal poll) or an earlier prepare's overlay has none.
        [ $SEC_IMS = 1 ] && [ $SECIMS_BOUND = 0 ] && { SEC_IMS=0; rm -f "$STAGE/data/oneos_sec_ims"; echo "Samsung IMS in the guest: off (no writable overlay to bind onto)"; }
        if [ $HWSM = 1 ]; then
            if [ -f "$GUEST_SYSTEM_EXT/bin/hwservicemanager" ]; then
                echo "HIDL: the guest sees system_ext/bin/hwservicemanager (an empty file; One UI's hwservicemanager $(pidof hwservicemanager) answers) for this phone's HIDL-only $HWSM_WHY"
            else
                echo "!!! HIDL: no system_ext/bin/hwservicemanager in the guest; it will not find this phone's HIDL-only $HWSM_WHY"
            fi
        fi
    fi
    if [ -d /system_ext/apex ]; then
        if [ -d "$GUEST_SYSTEM_EXT/apex" ]; then
            mount | grep -q " $GUEST_SYSTEM_EXT/apex " || $BB mount --bind /system_ext/apex "$GUEST_SYSTEM_EXT/apex"
            $BB mount --make-rslave "$GUEST_SYSTEM_EXT/apex" 2>/dev/null || true
            echo "Bound host /system_ext/apex -> $GUEST_SYSTEM_EXT/apex"
        else
            echo "!!! WARNING: no $GUEST_SYSTEM_EXT/apex mount point; PackageManagerService will fail on host system_ext apexes"
        fi
    fi
fi
if [ $INJ = 1 ]; then
    if ! grep -q " $GUEST_SYSTEM_EXT overlay ro[, ]" /proc/mounts; then
        INJ=0
        echo "Signal poll: off (no read-only overlay on $GUEST_SYSTEM_EXT, which the injection needs)"
    elif ! cmp -s "$GUEST_SYSTEM_EXT/framework/oneos-telephony.jar" "$STAGE/oneos-telephony.jar"; then
        INJ=0
        echo "Signal poll: off ($GUEST_SYSTEM_EXT/framework/oneos-telephony.jar missing or not the staged one)"
    fi
fi
# Display configs for the phone's two panels in a Pixel guest (run 49), in a
# read-only overlay on the guest's product/etc, made before anything is bound
# into product/etc (the seapp files below). Without a display_*.xml for these
# panels (One UI's vendor has Qualcomm reference files for other display ids)
# the Pixel framework maps its brightness linearly onto Samsung's composer
# float, which Samsung's composer maps linearly onto panel0-backlight
# 0..13510 (about 2650 nits at the top): adaptive brightness aimed at the wrong
# levels. And it had no proximity sensor: the phone's only
# android.sensor.proximity ("Palm Proximity Sensor", handle "_ear") lives in
# One UI's framework. Each file gives One UI's own nits -> float pairs (the
# table of patches/OneOSPanelBacklight.smali, from One UI's SurfaceFlinger
# logs; from 0.0026, the lowest level One UI uses, up to 520 nits, no high
# brightness mode yet) and names Samsung's IR proximity sensor
# (com.samsung.sensor.physical_proximity, wake-up; system_server passes its
# SSENSOR permission). DisplayDeviceConfig reads product/etc/displayconfig
# before vendor; display_port_147.xml is the inner panel, 148 the cover.
# The Z Fold8 Ultra (profile f8u) only: another phone's panels have their own
# curve (the Z Fold8's are other panels on the same ports).
# ColorOS has its own brightness path (samsung_backlight_curve.py).
# ONEOS_GUEST_DISPLAY_CONFIG=0 leaves it out.
# ddc_xml wide: the same curve from the lowest float to 1.0, for a framework
# whose brightness range is wider than One UI's (HyperOS: 3.66255E-4 to 1.0;
# with the plain curve DisplayDeviceConfig threw "Min or max values are
# invalid" and system_server died at once, fifth HyperOS run). Samsung's
# composer maps the float linearly onto the panel's backlight, and the curve's
# own slope (0.196 = 520 nits, a quarter of the backlight about 660) puts 1.0
# at about 2600 nits, the panel's peak.
ddc_xml() {
    if [ "$1" = wide ]; then LOW='        <point><value>0.000366255</value><nits>0.3</nits></point>'; HIGH='        <point><value>1.0</value><nits>2600.0</nits></point>'
    else LOW=''; HIGH=''; fi
    cat <<'DDCEOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- OneOS (guest_prepare.sh): One UI's nits for Samsung's composer float on this panel, and Samsung's IR proximity sensor. -->
<displayConfiguration>
    <screenBrightnessMap>
DDCEOF
    [ -z "$LOW" ] || echo "$LOW"
    cat <<'DDCEOF'
        <point><value>0.0026</value><nits>2.21</nits></point>
        <point><value>0.00333</value><nits>3.0</nits></point>
        <point><value>0.005015</value><nits>5.0</nits></point>
        <point><value>0.00694</value><nits>7.5</nits></point>
        <point><value>0.008891</value><nits>10.4</nits></point>
        <point><value>0.012079</value><nits>15.0</nits></point>
        <point><value>0.015279</value><nits>20.0</nits></point>
        <point><value>0.021151</value><nits>30.0</nits></point>
        <point><value>0.026566</value><nits>40.0</nits></point>
        <point><value>0.03701</value><nits>60.0</nits></point>
        <point><value>0.045723</value><nits>80.0</nits></point>
        <point><value>0.054391</value><nits>100.0</nits></point>
        <point><value>0.068653</value><nits>135.0</nits></point>
        <point><value>0.082069</value><nits>170.0</nits></point>
        <point><value>0.093062</value><nits>200.0</nits></point>
        <point><value>0.110574</value><nits>250.0</nits></point>
        <point><value>0.127287</value><nits>300.0</nits></point>
        <point><value>0.158918</value><nits>400.0</nits></point>
        <point><value>0.188764</value><nits>500.0</nits></point>
        <point><value>0.196299</value><nits>520.0</nits></point>
DDCEOF
    [ -z "$HIGH" ] || echo "$HIGH"
    cat <<'DDCEOF'
    </screenBrightnessMap>
    <proxSensor>
        <type>com.samsung.sensor.physical_proximity</type>
    </proxSensor>
</displayConfiguration>
DDCEOF
}
PETC="$GUEST_PRODUCT/etc"
if [ -e "$ROOTFS/system/framework/oplus-services.jar" ] || [ -L "$ROOTFS/system/framework/oplus-services.jar" ]; then
    :
elif [ "${ONEOS_GUEST_DISPLAY_CONFIG:-1}" != 1 ]; then
    echo "Display config: the image's own (ONEOS_GUEST_DISPLAY_CONFIG=0)"
elif [ "${ONEOS_GUEST_FORM:-fold}" != fold ] || [ "${ONEOS_PROFILE:-f8u}" != f8u ]; then
    echo "Display config: the image's own (the panel files are the Z Fold8 Ultra's; profile ${ONEOS_PROFILE:-f8u}, form ${ONEOS_GUEST_FORM:-fold})"
elif [ ! -d "$PETC" ] || [ -L "$PETC" ]; then
    echo "Display config: no product/etc folder in the image, left out"
elif mount | grep -q " $PETC type overlay"; then
    echo "Display config: overlay on product/etc already there (an earlier prepare), left as it is"
elif [ -e "$PETC/displayconfig/display_port_147.xml" ] || [ -e "$PETC/displayconfig/display_port_148.xml" ]; then
    echo "Display config: the image has its own display_port_147/148, left as it is"
else
    # An image with configs for its own panels only (HyperOS: display_id_<Xiaomi
    # panel>.xml) gets ours next to them in the merged folder; without a nits
    # mapping for the Fold's panels Xiaomi's brightness code ignored the slider
    # ("requesting nits when no mapping exists", 3 % brightness; 2026-10-25).
    DDC_RANGE=""
    if [ -e "$PETC/displayconfig" ]; then
        echo "Display config: the image's own product/etc/displayconfig ($(ls "$PETC/displayconfig" | tr '\n' ' ')) is kept; the Fold's two port files are added, over its whole brightness range"
        DDC_RANGE=wide
    fi
    DOV="$STAGE/product_etc_ov"
    mkdir -p "$DOV"
    if ! mount | grep -q " $DOV "; then
        $BB mount -t tmpfs -o size=256k,mode=755 tmpfs "$DOV" && $BB mount --make-private "$DOV" 2>/dev/null
    fi
    mkdir -p "$DOV/up/displayconfig"
    for port in 147 148; do ddc_xml $DDC_RANGE > "$DOV/up/displayconfig/display_port_$port.xml"; done
    chmod 755 "$DOV/up" "$DOV/up/displayconfig" && chmod 644 "$DOV/up/displayconfig/"*.xml
    $BB chcon -R u:object_r:system_file:s0 "$DOV/up" 2>/dev/null || true
    if $BB mount -t overlay overlay -o "ro,lowerdir=$DOV/up:$PETC" "$PETC"; then
        echo "Display config: product/etc/displayconfig/display_port_147.xml and 148 (One UI's nits curve, Samsung's IR proximity)"
    else
        echo "Display config: read-only overlay on product/etc refused, left out"
    fi
fi
if mount | grep -q "$ROOTFS/mnt " || $BB mount --rbind /mnt "$ROOTFS/mnt"; then
    # rslave at once: /mnt is a recursive bind of the host's shared storage
    # (/mnt/vendor/efs, /mnt/user/0/emulated); an early-exit umount on the way
    # back must never propagate to those host mounts.
    $BB mount --make-rslave "$ROOTFS/mnt" 2>/dev/null || true
fi
if [ -f "$STAGE/services_patched.jar" ]; then
    $BB umount -l "$ROOTFS/system/framework/services.jar" 2>/dev/null || true
    $BB mount --bind "$STAGE/services_patched.jar" "$ROOTFS/system/framework/services.jar"
    echo "Bound services_patched.jar -> $ROOTFS/system/framework/services.jar"
fi
# The guarded jar is what keeps the guest away from One UI's data.
if [ "$(stat -c %d:%i "$ROOTFS/system/framework/services.jar")" != "$(stat -c %d:%i "$STAGE/services_patched.jar")" ]; then
    echo "ERROR: the guarded services.jar is not in place; not starting the guest"
    exit 3
fi
# Patched guest surfaceflinger (no Qualcomm composer extension client; see
# scripts/make-overlays.sh). Inside the container only.
if [ -f "$STAGE/surfaceflinger_patched" ] && [ "${ONEOS_STOCK_SF:-0}" != "1" ]; then
    chmod 755 "$STAGE/surfaceflinger_patched"
    $BB umount -l "$ROOTFS/system/bin/surfaceflinger" 2>/dev/null || true
    $BB mount --bind "$STAGE/surfaceflinger_patched" "$ROOTFS/system/bin/surfaceflinger"
    echo "Bound surfaceflinger_patched -> $ROOTFS/system/bin/surfaceflinger"
fi
# The guest's own vold as "gvld" (run 44; scripts/make-overlays.sh,
# docs/inplace-return.md): vold_patched registers "gvld" and not
# android.system.vold.IVold/default, so One UI's vold keeps both its names all
# session (it cannot be restarted; the return without a reboot needs them).
# service.incremental_patched.so and the guarded services.jar look up "gvld".
# All three or none, as guards.txt lists them (hashes checked above): a
# services.jar that looks up "vold" next to this vold would get One UI's.
# guest_start.sh reads oneos_vold_name and checks both names before going on.
rm -f "$STAGE/data/oneos_vold_name"
VG=$(awk '$2 == "vold_patched" { v = 1 } $2 == "service.incremental_patched.so" { i = 1 } END { print v + i }' "$STAGE/guards.txt")
if [ "$VG" = 2 ]; then
    chmod 755 "$STAGE/vold_patched"
    chmod 644 "$STAGE/service.incremental_patched.so"
    for b in vold_patched:/system/bin/vold service.incremental_patched.so:/system/lib64/service.incremental.so; do
        src="$STAGE/${b%%:*}"; dst="$ROOTFS${b#*:}"
        $BB umount -l "$dst" 2>/dev/null || true
        $BB mount --bind "$src" "$dst"
        if [ "$(stat -c %d:%i "$dst" 2>/dev/null)" != "$(stat -c %d:%i "$src")" ]; then
            echo "ERROR: ${b%%:*} is not in place at $dst (guards.txt lists it); not starting the guest"
            exit 3
        fi
        echo "Bound ${b%%:*} -> $dst"
    done
    echo gvld > "$STAGE/data/oneos_vold_name"
    echo "Guest vold: registers gvld; One UI's vold keeps vold and android.system.vold.IVold/default"
elif [ "$VG" != 0 ]; then
    echo "ERROR: guards.txt lists only one of vold_patched and service.incremental_patched.so (a half-built set); not starting the guest"
    exit 3
elif [ -f "$STAGE/vold_patched" ]; then
    echo "Guest vold: vold_patched is staged but guards.txt does not list it (another overlay set): not bound, the guest vold takes vold"
else
    echo "Guest vold: no vold_patched for this image, the guest vold takes vold (no return without a reboot)"
fi
if [ -f "$STAGE/oplus-services_patched.jar" ] && [ -f "$ROOTFS/system/framework/oplus-services.jar" ]; then
    $BB umount -l "$ROOTFS/system/framework/oplus-services.jar" 2>/dev/null || true
    $BB mount --bind "$STAGE/oplus-services_patched.jar" "$ROOTFS/system/framework/oplus-services.jar"
    echo "Bound oplus-services_patched.jar -> $ROOTFS/system/framework/oplus-services.jar"
fi
# OneOS: checked like services.jar. This jar carries guards too (storage,
# installd callers, sysrq; scripts/make-overlays.sh), and a failed bind used
# to start the guest with ColorOS's own. An image without it (Pixel) has no
# OPPO framework to guard.
if [ -e "$ROOTFS/system/framework/oplus-services.jar" ] || [ -L "$ROOTFS/system/framework/oplus-services.jar" ]; then
    OSJ=$(stat -c %d:%i "$ROOTFS/system/framework/oplus-services.jar" 2>/dev/null)
    if [ -z "$OSJ" ] || [ "$OSJ" != "$(stat -c %d:%i "$STAGE/oplus-services_patched.jar" 2>/dev/null)" ] ||
        ! awk '$2 == "oplus-services_patched.jar" { f = 1 } END { exit !f }' "$STAGE/guards.txt"; then
        echo "ERROR: the guarded oplus-services.jar is not in place; not starting the guest"
        exit 3
    fi
else
    echo "No oplus-services.jar in the guest image: only services.jar carries guards"
fi
# HyperOS: Xiaomi's miui-services.jar (recovery, factory resets, preinstall
# copiers, vold, netd) and apprecovery.proinstaller.jar (installs apps by
# itself), both on the system server class path, guarded like
# oplus-services.jar (patches/miui_guards.py, docs/hyperos.md), and
# miui-wifi-service.jar, whose casts of One UI's Wi-Fi HAL extensions only
# take Xiaomi's (patches/hyperos_hal_ext.py), and miui-telephony-common.jar,
# whose IMS controller works without an IMS phone (patches/hyperos_telephony.py). Bound on the guest's system_ext
# after its overlay above; an image with miui-services.jar starts only with
# both guarded jars in place.
MIUI_FW="$GUEST_SYSTEM_EXT/framework"
if [ -e "$MIUI_FW/miui-services.jar" ] || [ -L "$MIUI_FW/miui-services.jar" ]; then
    for j in miui-services apprecovery.proinstaller miui-wifi-service miui-telephony-common; do
        if [ -f "$STAGE/${j}_patched.jar" ] && [ -f "$MIUI_FW/$j.jar" ] && [ ! -L "$MIUI_FW/$j.jar" ]; then
            $BB umount -l "$MIUI_FW/$j.jar" 2>/dev/null || true
            $BB mount --bind "$STAGE/${j}_patched.jar" "$MIUI_FW/$j.jar"
        fi
        MJ=$(stat -c %d:%i "$MIUI_FW/$j.jar" 2>/dev/null)
        if [ -z "$MJ" ] || [ "$MJ" != "$(stat -c %d:%i "$STAGE/${j}_patched.jar" 2>/dev/null)" ] ||
            ! awk -v n="${j}_patched.jar" '$2 == n { f = 1 } END { exit !f }' "$STAGE/guards.txt"; then
            echo "ERROR: the guarded $j.jar is not in place; not starting the guest"
            exit 3
        fi
        echo "Bound ${j}_patched.jar -> $MIUI_FW/$j.jar"
    done
    # framework.jar with AOSP's CameraStatus parcel (patches/hyperos_framework.py):
    # Xiaomi's two extra fields made every status from One UI's cameraserver
    # after the first null, and system_server died in BiometricService.
    HFW="$ROOTFS/system/framework/framework.jar"
    if [ -f "$STAGE/framework_patched.jar" ] && [ -f "$HFW" ] && [ ! -L "$HFW" ] && [ ! -L "$ROOTFS/system/framework" ]; then
        $BB umount -l "$HFW" 2>/dev/null || true
        $BB mount --bind "$STAGE/framework_patched.jar" "$HFW"
    fi
    MJ=$(stat -c %d:%i "$HFW" 2>/dev/null)
    if [ -z "$MJ" ] || [ "$MJ" != "$(stat -c %d:%i "$STAGE/framework_patched.jar" 2>/dev/null)" ] ||
        ! awk '$2 == "framework_patched.jar" { f = 1 } END { exit !f }' "$STAGE/guards.txt"; then
        echo "ERROR: HyperOS's framework.jar with One UI's camera status format is not in place; not starting the guest"
        exit 3
    fi
    echo "Bound framework_patched.jar -> $HFW"
    # HyperOS's audioserver without an audio HAL adapter vendor extension
    # (patches/hyperos_audio_ext.py): only One UI's own audioserver serves one,
    # it is stopped for the session, and HyperOS's waited for it with no time
    # limit. Sound only, so a missing or odd file leaves the image's library.
    HAH="$ROOTFS/system/lib64/libaudiohal@aidl.so"
    if [ -f "$STAGE/libaudiohal_aidl_patched.so" ] && [ -f "$HAH" ] && [ ! -L "$HAH" ] && [ ! -L "$ROOTFS/system/lib64" ]; then
        $BB umount -l "$HAH" 2>/dev/null || true
        $BB mount --bind "$STAGE/libaudiohal_aidl_patched.so" "$HAH" &&
            echo "Bound libaudiohal_aidl_patched.so -> $HAH (no audio HAL adapter vendor extension)"
    fi
fi

# ims-ext-common.jar with a 60 s QtiImsExtConnector bind retry instead of 500 ms
# (patches/qti_ims_ext_backoff.py). The guest skips Qualcomm's ims.apk (it needs
# persist.oplus.qspa.modem=enabled), so in run 34 com.android.phone's main thread
# retried bindService 6 times a second for the whole session.
# ONEOS_GUEST_IMS_EXT_BACKOFF=0 keeps ColorOS's jar.
if [ "${ONEOS_GUEST_IMS_EXT_BACKOFF:-1}" = 1 ] && [ -f "$STAGE/ims-ext-common_patched.jar" ] \
   && [ -f "$GUEST_PRODUCT/framework/ims-ext-common.jar" ]; then
    $BB umount -l "$GUEST_PRODUCT/framework/ims-ext-common.jar" 2>/dev/null || true
    $BB mount --bind "$STAGE/ims-ext-common_patched.jar" "$GUEST_PRODUCT/framework/ims-ext-common.jar"
    echo "Bound ims-ext-common_patched.jar -> $GUEST_PRODUCT/framework/ims-ext-common.jar"
fi

# Signal bars: OplusSignalSmooth polls GET_SIGNAL_STRENGTH every 20 s with the
# screen on (scripts/make-overlays.sh, patches/guest_signal_poll.py). Run 34:
# Samsung's RIL sent the guest no signal strength indication after boot, so both
# SIMs kept the all-invalid value read right after RADIO_POWER on (no bars).
# ONEOS_GUEST_SIGNAL_POLL=0 keeps ColorOS's jar. Other images: INJ above.
GUEST_OTC="$GUEST_SYSTEM_EXT/framework/oplus-telephony-common.jar"
if [ "${ONEOS_GUEST_SIGNAL_POLL:-1}" = 1 ] && [ -f "$STAGE/oplus-telephony-common_patched.jar" ] && [ -f "$GUEST_OTC" ]; then
    $BB umount -l "$GUEST_OTC" 2>/dev/null || true
    $BB mount --bind "$STAGE/oplus-telephony-common_patched.jar" "$GUEST_OTC"
    echo "Bound oplus-telephony-common_patched.jar -> $GUEST_OTC"
fi
# Play services and the Play Store from One UI's copy (oneos_switch.sh took it
# before One UI stopped), bound over the image's my_product slots, for every
# ColorOS set (switcher/assets/guest_google.sh). Never stops the start: without
# a checked copy the guest starts without it.
STAGE="$STAGE" BB="$BB" /system/bin/sh "$STAGE/guest_google.sh" prepare ||
    echo "!!! guest_google.sh prepare failed; the guest starts without One UI's Play services"
# Galaxy Z Fold8 with the Find N6 set (n6-f8): its SystemUI and guest fixes
# (switcher/assets/fold8_coloros.sh). Does nothing for any other profile or set.
# After the system_ext overlay above: a bind made under system_ext before it is
# hidden by it (0.4.14 on the Z Fold8: SystemUI kept the image's, no fold layout).
STAGE="$STAGE" BB="$BB" /system/bin/sh "$STAGE/fold8_coloros.sh" prepare || exit 3
STAGE="$STAGE" BB="$BB" /system/bin/sh "$STAGE/fold8_pixel.sh" prepare || exit 3
# ColorOS feature switches the guest needs, added to com.oplus.features_config.xml
# in its system_ext, a feature file it already loads (the my_* feature files are
# only read with CUST_LEVEL_LIST, which OPPO's init sets):
# - multibits_dimming_support: the Settings brightness slider steps through the
#   222..8191 levels one by one instead of 0..255 steps (run 28: jumpy slider).
# - the form factor, ONEOS_GUEST_FORM=fold (default) | tablet | phone. The Find
#   N6 is a ColorOS foldable: with type.fold the launcher follows Android's fold
#   state (Samsung's open state 3 is not in OPPO's folded list 0,1,100,102) and
#   uses its unfolded layout. tablet = run 29 (OPPO's pad grid turned into 6x10
#   cells, 1265 px off screen); phone = run 28 (Recents crashed with scaleX=NaN
#   on swipe home). Never tablet and fold together.
# - feature_unfold_width_small_high, with fold (ONEOS_GUEST_UNFOLD_PORTRAIT=0
#   leaves it out): the Find N6's open panel is landscape at rotation 0, ours is
#   portrait (2256x2504). Without the switch SystemUI's side gesture swaps width
#   and height on a large fold screen (SideGestureConfiguration; run 30 log:
#   SideGesture mScreenWidth = 2504, mScreenHeight = 2256), so the right back
#   zone sat at x 2442..2504, off the 2256 px panel (run 31 diag_90 input.txt,
#   InvalidRegion) and back from the right edge never fired. Only SystemUI's
#   side gesture reads it (not the launcher, framework or services).
# - windowmode.compact, with fold (ONEOS_GUEST_COMPACT_WINDOW=0 leaves it out):
#   the Find N6 has it (my_product/etc/permissions/oplus.feature.android.xml,
#   not read here; run 32 Settings: hasFeature = false). It is all that tells
#   com.oplus.wallpapers it runs on a foldable (f0.w: this framework-res has
#   no config_lidControlsDisplayFold). Without it every page of the app
#   (BaseDefaultDensityActivity.getResources -> o.a) is laid out at a phone
#   density, shortest side = 360dp = 6.27 px/dp, while text stays at 3.0:
#   the 386dp My theme header was 2419 px tall and filled the first screen,
#   the cards had 100 px padding instead of 48 (run 32 all.log: iconCardView
#   632,100-1089,557, the cards only reached at scrollY 2232). In WMS it also
#   turns on OPPO's full compact window mode (compat mode, starting windows,
#   animations); the .lite variant was already on.
# - radio.support_5g (ONEOS_GUEST_5G=0 leaves it out): without it ColorOS
#   telephony picks 4G mode 22 and masks NR out (run 29: LTE only on SIM 2's carrier
#   while One UI showed 5G).
# - radio.support_dual_nr, only with support_5g (ONEOS_GUEST_DUAL_5G=0 leaves
#   it out): the Find N6 is a dual-5G phone (its my_product feature file
#   declares it, its build.prop sets ro.oplus.radio.dual_nr_enabled=true).
#   Without it ColorOS offers and allows 5G only on the mobile-data SIM and
#   puts the other SIM on 4G mode 22. Run 32: SIM 2 switched off and on moved
#   data to SIM 1, so SIM 2's Preferred network type list had only 4G and 3G
#   (OplusExportPreferredNetworkSettings: primarySlotId 0, isSupportDual5g
#   false). With it telephony turns its dual_nr_enabled persist feature on at
#   boot and both SIMs list 5G and default to mode 33, like One UI here
#   (dumpsys isub: user=840583, NR included, on both SIMs).
# - connectivity.region_CN (ONEOS_GUEST_WIFI_CN=0 leaves it out): the Find N6's
#   own /my_region feature file sets it, but my_* files are never read here.
#   The image's WirelessSettings is the domestic build: after Connect it keeps
#   its modal Connecting dialog up until the wifi service sends the sticky
#   android.net.wifi.DISABLE_ALERT_NETWORKS (state COMPLETED), and Back or
#   Cancel on that dialog removes the network it just added. Only
#   OplusWifiConnectionAlert sends it, and OplusWifiInjector creates it only
#   with region_CN. Run 32: connected and validated at 13:14:02, no such
#   broadcast and no OplusWifiConnectionAlert line all session, Back at
#   13:14:12 -> remove by config -> removeNetwork -> disconnected, nothing
#   saved; the dialog left open is the Settings page that could not be left.
#   It also turns on OplusWifi's other CN paths (self-cure, smart assistant).
#   CN images only: my_region/build.prop says ro.oplus.pipeline.region=CN in
#   the Find N6 and Find X9 Ultra CN builds; a global build (the X9U IN) has
#   the export WirelessSettings and keeps its own region.
FEAT="$GUEST_SYSTEM_EXT/etc/permissions/com.oplus.features_config.xml"
$BB umount -l "$FEAT" 2>/dev/null
FORM="${ONEOS_GUEST_FORM:-fold}"
case "$FORM" in fold|tablet|phone) ;; *) echo "WARNING: ONEOS_GUEST_FORM=$FORM unknown, using fold"; FORM=fold ;; esac
if [ -f "$FEAT" ]; then
    ADDED="oplus.software.display.multibits_dimming_support"
    # Galaxy Z Fold8, Find N6 (pull request #1): Live Alerts, AOD, fold animations,
    # separate wallpapers per panel and haptic sounds, as the Find N6 declares them.
    if [ "${ONEOS_PROFILE:-}" = f8 ] &&
       grep -q '^  "image": "coloros17-findn6",$' "$STAGE/.oneos_stage"; then
        ADDED="$ADDED oplus.software.support_fluid_entry oplus.software.fluid_replace_ntf"
        ADDED="$ADDED oplus.software.display.aod_support oplus.software.adaptive_smooth_animation"
        ADDED="$ADDED oplus.software.flexible_exchange_animation"
        # Stock Find N6: my_stock/etc/extension/com.oplus.oplus-feature.xml.
        # The container does not load that component's feature catalogue.
        ADDED="$ADDED oplus.software.flexible_freeform.support oplus.software.pocketstudio.support"
        ADDED="$ADDED oplus.software.wallpaper.separate_wallpaper_for_multi_display"
        ADDED="$ADDED oplus.software.audio.haptic_channel_support"
    fi
    case "$FORM" in
        fold) ADDED="$ADDED oplus.hardware.type.fold"
            if [ "${ONEOS_GUEST_UNFOLD_PORTRAIT:-1}" = 1 ]; then
                ADDED="$ADDED oplus.software.feature_unfold_width_small_high"
            fi
            if [ "${ONEOS_GUEST_COMPACT_WINDOW:-1}" = 1 ]; then
                ADDED="$ADDED oplus.software.windowmode.compact"
            fi ;;
        tablet) ADDED="$ADDED oplus.hardware.type.tablet" ;;
    esac
    if [ "${ONEOS_GUEST_5G:-1}" = 1 ]; then
        ADDED="$ADDED oplus.software.radio.support_5g"
        if [ "${ONEOS_GUEST_DUAL_5G:-1}" = 1 ]; then
            ADDED="$ADDED oplus.software.radio.support_dual_nr"
        fi
    fi
    GUEST_REGION=$(sed -n 's/^ro\.oplus\.pipeline\.region=//p' "$ROOTFS/my_region/build.prop" 2>/dev/null | head -n 1)
    if [ "${ONEOS_GUEST_WIFI_CN:-1}" = 1 ] && [ "$GUEST_REGION" = CN ]; then
        ADDED="$ADDED oplus.software.connectivity.region_CN"
    else
        echo "Wi-Fi region_CN switch left out (image region ${GUEST_REGION:-unknown})"
    fi
    { grep -v '</oplus-config>' "$FEAT"
      for f in $ADDED; do echo "    <oplus-feature name=\"$f\"/>"; done
      echo '</oplus-config>'; } > "$STAGE/oplus_features_config.xml"
    $BB mount --bind "$STAGE/oplus_features_config.xml" "$FEAT" &&
        echo "Bound ColorOS feature switches (form $FORM): $ADDED"
fi
# The guest's /oem, built in $STAGE/oem and bound over the image's. /oem is
# empty in the images (ColorOS and Pixel) and scanned by the guest's
# PackageManagerService as a system partition (PackagePartitions: oem has an
# app and an overlay folder, no priv-app), so what is in it counts as
# preinstalled:
# - overlay/OneOSWallpapersFoldGrid.apk, fold form only. "Home screen, Lock
#   screen & style" (com.oplus.wallpapers): with type.fold the app takes its
#   Find N6 inner-screen page, a 4x4 grid where every card is 2x2 = half the
#   panel (run 30, "too zoomed in"; not density or compat scaling: the app
#   draws 2256x2504 at 408 dpi). This static RRO (make-overlays.sh) makes the
#   grid 8x2. ONEOS_GUEST_WALLPAPER_GRID=0 keeps ColorOS's own layout.
# - overlay/OneOSPixelStatusBar.apk, a guest with Pixel's SystemUIGoogle only
#   (never ColorOS's SystemUI). Run 42: the battery sat 47-60 px further from
#   the right edge than the clock from the left, on both panels; the corner
#   padding Pixel's own vendor overlay gives is 0dp on Samsung's vendor, the
#   privacy dot padding 20dp. This static RRO (make-overlays.sh,
#   switcher/overlays/pixel_statusbar) makes both 8dp.
#   ONEOS_GUEST_STATUSBAR_PADDING=0 leaves it out.
# - overlay/OneOSPhoneInjection.apk, with the signal poll only (INJ=1 above:
#   oneos-telephony.jar in place on a read-only system_ext). Run 43: no bars on
#   either SIM. This static RRO (make-overlays.sh,
#   switcher/overlays/phone_injection) gives TeleService the injection config
#   that names the jar. ONEOS_GUEST_SIGNAL_POLL=0 leaves it out.
# - app/OneOSGuest/OneOSGuest.apk, every guest: OneOS inside the guest
#   (app-android/guest), "Back to One UI" from its screen or its Quick Settings
#   tile. A plain system app, not privileged, no permission: it writes a
#   request file in its own data folder, which oneos_switch.sh's watcher
#   takes. ONEOS_GUEST_APP=0 leaves it out.
$BB umount -l "$ROOTFS/oem" 2>/dev/null
rm -rf "$STAGE/oem"
OEM_FILES=""
if [ "$FORM" = fold ] && [ "${ONEOS_GUEST_WALLPAPER_GRID:-1}" = 1 ] && [ -f "$STAGE/OneOSWallpapersFoldGrid.apk" ]; then
    mkdir -p "$STAGE/oem/overlay" &&
        cp "$STAGE/OneOSWallpapersFoldGrid.apk" "$STAGE/oem/overlay/" &&
        chmod 755 "$STAGE/oem" "$STAGE/oem/overlay" && chmod 644 "$STAGE/oem/overlay/OneOSWallpapersFoldGrid.apk" &&
        OEM_FILES="$OEM_FILES overlay/OneOSWallpapersFoldGrid.apk"
fi
if [ -f "$GUEST_SYSTEM_EXT/priv-app/SystemUIGoogle/SystemUIGoogle.apk" ] && [ -f "$STAGE/OneOSPixelStatusBar.apk" ]; then
    if [ "${ONEOS_GUEST_STATUSBAR_PADDING:-1}" = 1 ]; then
        mkdir -p "$STAGE/oem/overlay" &&
            cp "$STAGE/OneOSPixelStatusBar.apk" "$STAGE/oem/overlay/" &&
            chmod 755 "$STAGE/oem" "$STAGE/oem/overlay" && chmod 644 "$STAGE/oem/overlay/OneOSPixelStatusBar.apk" &&
            OEM_FILES="$OEM_FILES overlay/OneOSPixelStatusBar.apk"
    else
        echo "Pixel status bar overlay left out (ONEOS_GUEST_STATUSBAR_PADDING=0)"
    fi
fi
# Pixel 17's WallpaperDataParser calls next() once for <description>. Its
# indented serializer writes whitespace there, so next() returns TEXT and the
# saved component is skipped. Remove only whitespace between XML elements,
# preserving every component, crop, colour, content value and wallpaper file.
# Every Pixel guest (pull request #1 found it on the Fold8; same Pixel 17 code).
if [ -f "$GUEST_SYSTEM_EXT/priv-app/SystemUIGoogle/SystemUIGoogle.apk" ]; then
    WREL=system/users/0/wallpaper_info.xml
    no_symlink "$WREL"
    WFILE="$STAGE/data/$WREL"
    if [ -f "$WFILE" ] && [ ! -L "$WFILE" ] && [ "$(head -c 5 "$WFILE")" = '<?xml' ]; then
        no_symlink "$WREL.oneos-normalized"
        no_symlink "$WREL.oneos-spacing-backup"
        if cp -p "$WFILE" "$WFILE.oneos-normalized" &&
                "$BB" sed ':a
N
$!ba
s/>[[:space:]]*</></g' "$WFILE" > "$WFILE.oneos-normalized" &&
                [ -s "$WFILE.oneos-normalized" ]; then
            if ! cmp -s "$WFILE" "$WFILE.oneos-normalized"; then
                if cp -p "$WFILE" "$WFILE.oneos-spacing-backup"; then
                    mv -f "$WFILE.oneos-normalized" "$WFILE"
                    echo "Pixel wallpaper: normalized description spacing; saved selection retained"
                else
                    rm -f "$WFILE.oneos-normalized"
                    echo "WARNING: Pixel wallpaper backup failed; original retained"
                fi
            else
                rm -f "$WFILE.oneos-normalized"
            fi
        else
            rm -f "$WFILE.oneos-normalized"
            echo "WARNING: Pixel wallpaper normalization failed; original retained"
        fi
    fi
fi
# Pixel on the Fold8 / Fold8 Ultra: the unfold transition's boot flags, read by
# SystemUI and the launcher at start (pixel-f8: Fold8PixelUnfold.apk, which also
# has the Fold8's 48dp bar and AOD; pixel-f8u: OneOSPixelUnfold.apk, the gates only).
UNFOLD_RRO=""
if [ "${ONEOS_PROFILE:-}" = f8 ] && grep -q '^  "set": "pixel-f8",$' "$STAGE/.oneos_stage"; then
    UNFOLD_RRO=Fold8PixelUnfold.apk
elif [ "${ONEOS_PROFILE:-}" = f8u ] && grep -q '^  "set": "pixel-f8u",$' "$STAGE/.oneos_stage"; then
    UNFOLD_RRO=OneOSPixelUnfold.apk
fi
if [ -n "$UNFOLD_RRO" ] && [ -f "$STAGE/$UNFOLD_RRO" ]; then
    mkdir -p "$STAGE/oem/overlay" &&
        cp "$STAGE/$UNFOLD_RRO" "$STAGE/oem/overlay/" &&
        chmod 755 "$STAGE/oem" "$STAGE/oem/overlay" && chmod 644 "$STAGE/oem/overlay/$UNFOLD_RRO" &&
        OEM_FILES="$OEM_FILES overlay/$UNFOLD_RRO"
fi
if [ $INJ = 1 ]; then
    mkdir -p "$STAGE/oem/overlay" &&
        cp "$STAGE/OneOSPhoneInjection.apk" "$STAGE/oem/overlay/" &&
        chmod 755 "$STAGE/oem" "$STAGE/oem/overlay" && chmod 644 "$STAGE/oem/overlay/OneOSPhoneInjection.apk" &&
        OEM_FILES="$OEM_FILES overlay/OneOSPhoneInjection.apk" &&
        echo "Signal poll: TelephonyComponentFactory injection (oneos-telephony.jar), GET_SIGNAL_STRENGTH every 20 s with the screen on"
fi
if [ "${ONEOS_GUEST_APP:-1}" = 1 ]; then
    if [ -f "$STAGE/OneOSGuest.apk" ]; then
        mkdir -p "$STAGE/oem/app/OneOSGuest" &&
            cp "$STAGE/OneOSGuest.apk" "$STAGE/oem/app/OneOSGuest/" &&
            chmod 755 "$STAGE/oem" "$STAGE/oem/app" "$STAGE/oem/app/OneOSGuest" &&
            chmod 644 "$STAGE/oem/app/OneOSGuest/OneOSGuest.apk" &&
            OEM_FILES="$OEM_FILES app/OneOSGuest/OneOSGuest.apk"
    else
        echo "No $STAGE/OneOSGuest.apk: no OneOS app in the guest (Volume Up + Volume Down still return)"
    fi
fi
if [ -n "$OEM_FILES" ]; then
    # A stage copy, not a bind of host data: safe to label like a system file.
    $BB chcon -h -R u:object_r:system_file:s0 "$STAGE/oem" 2>/dev/null || true
    $BB mount --bind "$STAGE/oem" "$ROOTFS/oem" &&
        echo "Bound guest /oem -> $ROOTFS/oem:$OEM_FILES"
fi
# ColorOS apps whose SELinux domain the host policy does not have (run 31: 35
# zygote aborts in 6 minutes, crash/system/dropbox). The guest's system_ext and
# product seapp_contexts give OPPO apps their own domains
# (oplus_assistantscreen_app, oplus_phonemanager_app, oplus_backuprestore_app,
# oplus_game_service, oplus_instant_local_service, ...), but the loaded policy is
# Samsung's: selinux_android_setcontext fails with EINVAL, permissive or not
# (the kernel rejects a context with an unknown type), and the forked zygote
# child aborts. The launcher's card channel (pcs_server) pulls a provider of
# com.coloros.assistantscreen, so it was restarted every ~10 s (the AMS start
# timeout) for the whole session, each time with a tombstone and a dropbox
# entry; com.coloros.sceneservice was killed with it each time ("depends on
# provider ... in dying proc", run 30). Comment out every rule whose domain= or
# type= the host policy lacks: such a rule can never apply here. Those apps
# then get AOSP's generic rules (untrusted_app, priv_app, platform_app,
# system_app), the same ones the host's installd uses for their data (One UI's
# seapp_contexts has no OPPO rules either). Whole lines only, so the files stay
# parseable; plat_seapp_contexts (system_server's rule, same AOSP build as the
# host) is left alone. The host's types come from its CIL files, so this
# follows whatever policy the phone has. ONEOS_GUEST_SEAPP=0 keeps ColorOS's files.
SEAPP_FILES="$GUEST_SYSTEM_EXT/etc/selinux/system_ext_seapp_contexts $GUEST_PRODUCT/etc/selinux/product_seapp_contexts"
for f in $SEAPP_FILES; do $BB umount -l "$f" 2>/dev/null; done
if [ "${ONEOS_GUEST_SEAPP:-1}" = 1 ]; then
    HOST_TYPES="$STAGE/host_sepolicy_types.txt"
    for c in /system/etc/selinux/*.cil /system_ext/etc/selinux/*.cil /product/etc/selinux/*.cil \
        /vendor/etc/selinux/*.cil /odm/etc/selinux/*.cil; do
        case "$c" in *debug*) continue ;; esac
        [ -f "$c" ] && cat "$c"
    done | awk '$1 == "(type" || $1 == "(typealias" { t = $2; sub(/\).*$/, "", t); print t }' | sort -u > "$HOST_TYPES"
    SEAPP_OK=1
    for t in untrusted_app priv_app platform_app system_app app_data_file privapp_data_file system_app_data_file; do
        grep -qx "$t" "$HOST_TYPES" || SEAPP_OK=0
    done
    if [ "$SEAPP_OK" != 1 ]; then
        echo "WARNING: host SELinux types unreadable ($(wc -l < "$HOST_TYPES") found); guest seapp_contexts unchanged"
    else
        for f in $SEAPP_FILES; do
            [ -f "$f" ] || continue
            out="$STAGE/oneos_$(basename "$f")"
            awk -v types="$HOST_TYPES" '
                BEGIN { while ((getline t < types) > 0) known[t] = 1 }
                /^[ \t]*#/ || NF == 0 { print; next }
                {
                    bad = ""
                    for (i = 1; i <= NF; i++)
                        if ($i ~ /^(domain|type)=/) {
                            v = $i; sub(/^[a-z]*=/, "", v)
                            if (!(v in known)) bad = bad " " v
                        }
                    if (bad != "") print "# OneOS: host policy lacks" bad ": " $0
                    else print
                }' "$f" > "$out" || { echo "WARNING: could not rewrite $f; left as is"; continue; }
            chmod 644 "$out"
            $BB chcon u:object_r:seapp_contexts_file:s0 "$out" 2>/dev/null ||
                $BB chcon u:object_r:system_file:s0 "$out" 2>/dev/null || true
            $BB mount --bind "$out" "$f" &&
                echo "Bound $(basename "$f"): $(grep -c '^# OneOS: host policy lacks' "$out") rule(s) with types the host policy lacks commented out"
            echo "    types missing: $(grep '^# OneOS: host policy lacks' "$out" | cut -d: -f2 | sed 's/^ host policy lacks //' | tr ' ' '\n' | sort -u | tr '\n' ' ')"
        done
    fi
fi
# framework_patched.jar: a Pixel guest's framework.jar with One UI's camera
# transaction codes (patches/pixel_camera_abi.py). Listed in guards.txt and
# checked above, so a stage that has the jar binds the one the set was built
# with or does not start.
if [ -f "$STAGE/framework_patched.jar" ]; then
    $BB umount -l "$ROOTFS/system/framework/framework.jar" 2>/dev/null || true
    $BB mount --bind "$STAGE/framework_patched.jar" "$ROOTFS/system/framework/framework.jar"
    echo "Bound framework_patched.jar -> $ROOTFS/system/framework/framework.jar"
fi
# libcamera_client_patched.so, libcameracompatbilityinfo_patched.so: the guest's
# native camera client (legacy camera API, NDK camera2) with One UI's codes
# (patches/pixel_camera_native.py); guards.txt lists them, checked above.
for pair in libcamera_client_patched.so:libcamera_client.so libcameracompatbilityinfo_patched.so:libcameracompatbilityinfo.so; do
    if [ -f "$STAGE/${pair%%:*}" ]; then
        $BB umount -l "$ROOTFS/system/lib64/${pair#*:}" 2>/dev/null || true
        $BB mount --bind "$STAGE/${pair%%:*}" "$ROOTFS/system/lib64/${pair#*:}"
        echo "Bound ${pair%%:*} -> $ROOTFS/system/lib64/${pair#*:}"
    fi
done
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
# starting -- which is why adb dies right after the guest boots and macOS stops
# seeing the phone entirely. Writing the XML now keeps the gadget stable through
# the whole boot.
GSET="$STAGE/data/system/users/0/settings_global.xml"
# OneOS: only ever change the value of an existing entry, and only in a text
# XML file. Inserting <setting id="adb_enabled" ...> gave the entry a non-numeric
# id; ColorOS's SettingsProvider then failed to parse settings_global.xml, moved
# it aside and aborted system_server ("No fallback file found"). Any line a
# previous run inserted is removed again. If there is no entry yet, the UI
# activator's "settings put global adb_enabled 1" sets it once the guest is up.
# Each key is checked after the edit and that one edit is undone if the file
# did not come out as expected.
seed_settings() {
    f=$1; label=$2; shift 2
    [ -f "$f" ] && [ "$(head -c 5 "$f")" = "<?xml" ] || { echo "Guest $label: no text settings file, not seeded"; return; }
    for kv in "$@"; do
        k=${kv%=*}; v=${kv#*=}
        cp -f "$f" "$f.oneos-prev"
        if grep -q "name=\"$k\" " "$f"; then
            if grep "name=\"$k\" " "$f" | grep -q ' value="'; then
                sed -i "/name=\"$k\" /s/ value=\"[^\"]*\"/ value=\"$v\"/" "$f"
            else
                sed -i "s/ name=\"$k\" / name=\"$k\" value=\"$v\" /" "$f"
            fi
        else
            NEXT_ID=$(( $(grep -o ' id="[0-9]*"' "$f" | tr -dc '0-9\n' | sort -n | tail -1) + 1 ))
            sed -i "s#</settings>#<setting id=\"$NEXT_ID\" name=\"$k\" value=\"$v\" package=\"android\" />\n</settings>#" "$f"
        fi
        if [ "$(grep -c "name=\"$k\" value=\"$v\"" "$f")" != 1 ] || ! tail -c 32 "$f" | grep -q '</settings>'; then
            cp -f "$f.oneos-prev" "$f"
            echo "WARNING: Guest $label: could not set $k=$v, left as it was"
        else
            echo "Guest $label: $k=$v"
        fi
    done
    rm -f "$f.oneos-prev"
}
# A first ColorOS boot that died part-way leaves some of user 0's settings
# files and not the others. SettingsProvider then takes the upgrade path and
# crashes on the missing one in every later session (Galaxy S25, 2026-10-23:
# "No settings state /data/system/users/0/settings_global.xml", "Upgrading
# settings for user: 0 ... from version: 201", then a NullPointerException in
# SettingsRegistry$UpgradeController.onUpgradeLocked and system_server gone).
# Such a partial set is moved aside (never deleted) so ColorOS writes all three
# fresh. A stage that ran fine has all three; one never booted has none.
U0="$STAGE/data/system/users/0"
s_have=0; s_miss=0
for n in settings_global.xml settings_secure.xml settings_system.xml; do
    if [ -f "$U0/$n" ]; then s_have=$((s_have + 1)); else s_miss=$((s_miss + 1)); fi
done
if [ "$s_have" -gt 0 ] && [ "$s_miss" -gt 0 ]; then
    s_aside="$U0/oneos-partial-settings-$(date +%s)"
    if mkdir -p "$s_aside"; then
        for n in settings_global.xml settings_secure.xml settings_system.xml; do
            for f in "$U0/$n" "$U0/$n.fallback" "$U0/$n.bak"; do
                [ -f "$f" ] && mv -f "$f" "$s_aside/"
            done
        done
        echo "Guest settings: a partial set from an earlier first boot ($s_have of 3 files) moved to ${s_aside#$STAGE/}; ColorOS writes all three fresh"
    else
        echo "WARNING: guest settings are a partial set ($s_have of 3 files) and could not be moved aside"
    fi
fi
sed -i '/<setting id="adb_enabled" /d' "$GSET" 2>/dev/null
# adb_enabled=1: without it the guest's UsbDeviceManager drops adb from the
# USB gadget seconds after its system_server starts.
# OneOS: only when One UI has USB debugging on (oneos_switch.sh saved it
# in host_adb_on); a phone without it does not get adb from the guest either.
# data/oneos_host_adb tells fix_app_dirs.sh the same.
HOST_ADB=$(cat "$STAGE/host_adb_on" 2>/dev/null)
ADB_SEED=""
if [ "$HOST_ADB" = 1 ]; then
    ADB_SEED=adb_enabled=1; touch "$STAGE/data/oneos_host_adb"
else
    rm -f "$STAGE/data/oneos_host_adb"
fi
echo "Guest adb: $([ "$HOST_ADB" = 1 ] && echo 'on (One UI has USB debugging on)' || echo 'left alone (One UI has USB debugging off)')"
# auto_time=0 / auto_time_zone=0: the clock is the host's, and ColorOS's time
# detection set it to 1 Jan 2026 during a session.
# device_provisioned=1 / user_setup_complete=1: the image has no setup wizard,
# but with them at 0 ColorOS keeps the device in "setup" mode: the phone app
# opens its APN list over the home screen, Quick Settings, notifications and
# the home gesture stay off, and mobile data is forced off. Set before boot so
# no setup-complete observer fires (one writes persist.sys.* props).
# launcher_support_card_no_padding=1 (what the launcher itself writes): with it
# missing, Launcher.onCreate queries its own provider on the main thread, a
# suspect for the onCreate hang in runs 23-25.
# With Google services presented (GMS_WANT, top) the two provisioned keys are
# left to Pixel's setup wizard, which sets both when it finishes: a stage it
# has set up already has them, one it has not keeps its wizard.
PROV_GLOBAL=device_provisioned=1
if [ "$GMS_WANT" = 1 ]; then
    PROV_GLOBAL=""
    echo "Guest setup: device_provisioned / user_setup_complete left to Pixel's setup wizard (Google services presented)"
fi
seed_settings "$GSET" settings_global $ADB_SEED auto_time=0 auto_time_zone=0 $PROV_GLOBAL launcher_support_card_no_padding=1
[ "$GMS_WANT" = 1 ] || seed_settings "$STAGE/data/system/users/0/settings_secure.xml" settings_secure user_setup_complete=1

# The switcher's return combo (hold Volume Up + Volume Down 3 s, read on the
# host) is also Android's accessibility shortcut, and ColorOS aims that at
# TalkBack: settings_secure id 26, accessibility_shortcut_target_service from
# SettingsProvider's config_preinstalled_screen_reader_service, written at the
# guest's first boot. Run 34 (all.log): the first hold showed the shortcut's
# warning dialog at 16:43:59.409 and saved accessibility_shortcut_dialog_shown=1;
# the host watcher acted only at 16:44:06, so the user held the keys again, and
# with the dialog seen the shortcut needs only 1 s: TalkBack came on at
# 16:44:02.839 (enabled_accessibility_services, accessibility_enabled,
# touch_exploration_enabled: ids 1145-1148 in the staged file, all four new in
# run 34). An empty target turns the shortcut off (a missing one
# would fall back to config_defaultAccessibilityService): KeyGestureController
# then has no rule for the chord and the keys stay volume keys. Done only while
# the target is still the factory TalkBack one, so a shortcut picked later in
# Settings is kept; TalkBack goes off with it only when it is the sole enabled
# service, as the shortcut left it. ONEOS_GUEST_A11Y_SHORTCUT=1 keeps
# ColorOS's shortcut.
SSET="$STAGE/data/system/users/0/settings_secure.xml"
if [ "${ONEOS_GUEST_A11Y_SHORTCUT:-0}" != 1 ] &&
   grep -q 'name="accessibility_shortcut_target_service" value="com\.google\.android\.marvin\.talkback/' "$SSET" 2>/dev/null; then
    A11Y="accessibility_shortcut_target_service="
    grep -q 'name="accessibility_shortcut_dialog_shown" value="1"' "$SSET" && A11Y="$A11Y accessibility_shortcut_dialog_shown=0"
    grep -q -E 'name="enabled_accessibility_services" value="com\.google\.android\.marvin\.talkback/[^":]*TalkBackService"' "$SSET" &&
        A11Y="$A11Y enabled_accessibility_services= accessibility_enabled=0 touch_exploration_enabled=0"
    seed_settings "$SSET" settings_secure $A11Y
fi
A11T=$(sed -n 's/.* name="accessibility_shortcut_target_service" value="\([^"]*\)".*/\1/p' "$SSET" 2>/dev/null | head -n 1)
A11S=$(sed -n 's/.* name="enabled_accessibility_services" value="\([^"]*\)".*/\1/p' "$SSET" 2>/dev/null | head -n 1)
echo "Guest accessibility shortcut target: ${A11T:-none}; enabled services: ${A11S:-none}"

# Mobile data follows One UI's switch (oneos_switch.sh [4/6] saved it).
# Run 33: the guest's mobile_data and mobile_data2 were 0 (sub 2 = SIM 2 is
# the guest's data SIM, multi_sim_data_call=2) while One UI had mobile_data=1,
# so ColorOS never set up a data call (DSMGR-1 mIsDataEnabled=false all
# session), SIM 2's NR leg came without a data context id (all.log
# 14:42:04-14:42:12, mContextIds=[]) and the 5G icon could not show. On Wi-Fi
# nothing changes: mobile_data_always_on is 0, so no cellular data call while
# Wi-Fi is the default network. ONEOS_GUEST_MOBILE_DATA=0 leaves the guest's
# own values (the switch in ColorOS's Quick Settings is kept across sessions).
HMD=$(cat "$STAGE/host_mobile_data" 2>/dev/null)
GDDS=$(sed -n 's/.*name="multi_sim_data_call" value="\([0-9][0-9]*\)".*/\1/p' "$GSET" 2>/dev/null | head -1)
if [ "${ONEOS_GUEST_MOBILE_DATA:-1}" = 1 ] && [ "$HMD" = 1 ] && [ -n "$GDDS" ]; then
    seed_settings "$GSET" settings_global mobile_data=1 "mobile_data$GDDS=1"
else
    echo "Guest mobile data: left as it is (One UI: ${HMD:-unknown}, guest data sub: ${GDDS:-none})"
fi
# A binary-XML settings file (Pixel: starts with ABX) cannot be read here:
# run 43 printed "not forced" for it every time. The UI activator sets and
# logs the guest's density then (oneos_switch.sh, run 44).
if [ "$(head -c 3 "$SSET" 2>/dev/null)" = ABX ]; then
    echo "Guest display size: binary settings, set by the UI activator"
else
    echo "Guest display size: $(grep -o 'name="display_density_forced" value="[^"]*"' "$SSET" 2>/dev/null || echo 'not forced')"
fi
# ColorOS's cover screen on a fold (owner, 0.4.10 on the Z Fold8 Ultra: "outer
# display looks 720p", "set to high, still looks blurry"). The guest drew it at
# the panel's full 1080 x 2520 (SurfaceFlinger: 1:1 projection, full-size
# window buffers), but at Samsung's shared ro.sf.lcd_density 480, a 360 dp wide
# phone layout, about 14% larger than One UI's 420 on the same 422 dpi panel.
# The cover gets its own forced density in the guest's display_settings.xml,
# keyed like WindowManager keys it (the uniqueId, or port:<n> when the file
# says identifier 1), so the inner panel and Settings.Secure
# display_density_forced (display 0 at boot, whichever panel it is) stay as
# they are: auto = the panel's real dpi down to a multiple of 20 (420 here,
# also one of ColorOS's own display sizes), only under the base density, and
# never over a size chosen in the guest (an entry with forcedDensity).
# ONEOS_GUEST_COVER_DENSITY=off|auto|<dpi 120-640>.
# HyperOS too (run 10, owner: "feels like a zoomed in fold display like the
# dynamic island stuff is going out of bounds"): its cover ran at 480, 360 dp,
# and the Dynamic Island's window went past the right edge. Not the Pixel
# image, whose own cover is a 480 phone layout.
DSET="$STAGE/data/system/display_settings.xml"
CVD=$(cat "$STAGE/host_cover_display" 2>/dev/null)
CDEN="${ONEOS_GUEST_COVER_DENSITY:-auto}"
CV_GUEST=""
[ -e "$ROOTFS/system/framework/oplus-services.jar" ] && CV_GUEST=ColorOS
{ [ -e "$ROOTFS/system_ext/framework/miui-services.jar" ] || [ -e "$ROOTFS/system/system_ext/framework/miui-services.jar" ]; } && CV_GUEST=HyperOS
if [ "$FORM" != fold ] || [ -z "$CV_GUEST" ] || [ "$CDEN" = off ]; then
    :
elif [ "$(echo "$CVD" | wc -w)" != 5 ]; then
    echo "Cover density: not set (the cover panel was not read)"
else
    set -- $CVD
    CV_UID=$1 CV_PORT=$2 CV_XDPI=$5
    BASE=$(getprop ro.sf.lcd_density)
    case "$CDEN" in
        auto) CDEN=$((CV_XDPI / 20 * 20)) ;;
        [1-9][0-9][0-9]) [ "$CDEN" -ge 120 ] && [ "$CDEN" -le 640 ] || CDEN=0 ;;
        *) CDEN=0 ;;
    esac
    if [ "$CDEN" -lt 120 ] 2>/dev/null || [ -z "$BASE" ] || [ "$CDEN" -ge "$BASE" ]; then
        echo "Cover density: left at ${BASE:-the base} (${ONEOS_GUEST_COVER_DENSITY:-auto} gives $CDEN for $CV_XDPI dpi)"
    else
        mkdir -p "$STAGE/data/system"
        DTXT="$STAGE/display_settings.txt"
        rm -f "$DTXT"
        if [ ! -s "$DSET" ]; then
            printf '%s\n' "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>" '<display-settings>' '</display-settings>' > "$DTXT"
        elif [ "$(head -c 3 "$DSET")" = ABX ]; then
            abx2xml "$DSET" "$DTXT" 2>/dev/null || rm -f "$DTXT"
        else
            cp "$DSET" "$DTXT"
        fi
        IDT=$(sed -n 's/.*<config identifier="\([0-9]*\)".*/\1/p' "$DTXT" /vendor/etc/display_settings.xml 2>/dev/null | head -n 1)
        CV_NAME=$CV_UID; [ "$IDT" = 1 ] && CV_NAME="port:$CV_PORT"
        if [ ! -s "$DTXT" ] || ! grep -q '</display-settings>' "$DTXT"; then
            echo "Cover density: not set (display_settings.xml not readable)"
        elif grep "<display name=\"$CV_NAME\"" "$DTXT" | grep -q 'forcedDensity='; then
            echo "Cover density: $(grep "<display name=\"$CV_NAME\"" "$DTXT" | sed -n 's/.*forcedDensity="\([0-9]*\)".*/\1/p') kept (chosen in $CV_GUEST)"
        else
            if grep -q "<display name=\"$CV_NAME\"" "$DTXT"; then
                sed -i "s|<display name=\"$CV_NAME\"|<display name=\"$CV_NAME\" forcedDensity=\"$CDEN\"|" "$DTXT"
            else
                awk -v e="<display name=\"$CV_NAME\" forcedDensity=\"$CDEN\" />" '/<\/display-settings>/ { print e } { print }' "$DTXT" > "$DTXT.new" && mv -f "$DTXT.new" "$DTXT"
            fi
            CTX=$(ls -Z "$DSET" 2>/dev/null | awk '{ print $1 }')
            case "$CTX" in u:object_r:*) ;; *) CTX=u:object_r:system_data_file:s0 ;; esac
            if grep -q "forcedDensity=\"$CDEN\"" "$DTXT" && mv -f "$DTXT" "$DSET"; then
                chown 1000:1000 "$DSET"; chmod 600 "$DSET"; $BB chcon "$CTX" "$DSET" 2>/dev/null
                echo "Cover density: $CDEN for $CV_NAME ($CV_XDPI dpi panel, base $BASE)"
            else
                echo "Cover density: not set (display_settings.xml not written)"
            fi
        fi
        rm -f "$DTXT" "$DTXT.new"
    fi
fi

# ColorOS's touch-idle refresh rate (OTI, oplus_vrr_config.json "touch_idle")
# takes this panel's mode (240 Hz vsync, 120 fps at most) as 240 Hz: it
# rendered at 240 on touch and 60 Hz 2.5 s later, over the 120 Hz policy (run
# 29: 337 s at 240, 104 s at 60, 33 s at 120), which also heats the phone.
# OPlusRusHelper prefers data/system/oplus_vrr_config.json (relative to
# system_server's working directory, the guest's /) when its "version" is
# higher than my_product's. ONEOS_GUEST_OTI=1 keeps ColorOS's own setting.
VRRCFG="$ROOTFS/my_product/etc/oplus_vrr_config.json"
VRRDATA="$STAGE/data/system/oplus_vrr_config.json"
# data/system is only created further down; on a fresh stage (S25U dry run,
# session f075d93a) the write failed and the first session kept OTI on.
mkdir -p "$STAGE/data/system" 2>/dev/null || true
rm -f "$VRRDATA"
if [ "${ONEOS_GUEST_OTI:-0}" = 0 ] && [ -f "$VRRCFG" ]; then
    sed -e 's/"touch_idle": *true/"touch_idle": false/' -e 's/"version": *[0-9]*/"version": 20991231/' "$VRRCFG" > "$VRRDATA"
    if grep -q '"touch_idle": false' "$VRRDATA" && grep -q '"version": 20991231' "$VRRDATA"; then
        echo "Guest VRR config: touch idle (OTI) off"
    else
        rm -f "$VRRDATA"; echo "WARNING: guest VRR config not staged (unexpected oplus_vrr_config.json)"
    fi
fi

# ColorOS's ringtones, notification and UI sounds (run 31: "system ringtones
# are not there"; run 30: Settings_RingtoneUtils "getInternalRingtoneUri
# ringtone_001.ogg null", ModernMediaScanner "Failed to visit
# /data/oplus/multimedia/ringtones: AccessDeniedException"). The Find N6 has no
# plain ringtone folder: its sounds exist only as haptic-channel sets, one per
# motor frequency, in my_product/res/audio/haptic_ringtone/output<Hz>HZ. On the
# phone OplusAtlasService (RingCopyHelper) copies the set for its motor into
# /data/oplus/multimedia, which MediaProvider scans as internal media. It only
# does that with oplus.software.audio.haptic_channel_support, a my_product
# feature the guest does not load (run 30: "ringtone haptic is support:
# false"), and it reads the motor from OPPO's misc HAL, which a Samsung phone
# does not have, so it would take lra_level_middle. Stage that set here, into
# the guest's own /data only, system 0775 like ColorOS's init.rc. AudioFlinger
# drops the haptic channel on an output without one.
# ONEOS_GUEST_RINGTONES=0 leaves /data/oplus/multimedia alone.
if [ "${ONEOS_GUEST_RINGTONES:-1}" = 1 ]; then
    MM="$STAGE/data/oplus/multimedia"
    HR="$ROOTFS/my_product/res/audio/haptic_ringtone"
    LRA=$(sed -n 's/^ro\.oplus\.haptic\.lra_level_middle=//p' "$ROOTFS/my_product/build.prop" 2>/dev/null | head -n 1)
    RSRC="$HR/output${LRA:-166}HZ"
    [ -d "$RSRC/ringtones" ] || RSRC=$(ls -d "$HR"/output*HZ 2>/dev/null | head -n 1)
    if [ -n "$RSRC" ] && [ -d "$RSRC/ringtones" ]; then
        if [ "$(cat "$STAGE/guest_ringtones.src" 2>/dev/null)" != "$RSRC" ] || [ ! -d "$MM/ringtones" ]; then
            rm -f "$STAGE/guest_ringtones.src"
            mkdir -p "$MM"
            ok=1
            for k in ringtones notifications ui; do
                rm -rf "$MM/$k"
                if [ -d "$RSRC/$k" ]; then cp -r "$RSRC/$k" "$MM/$k" || ok=0; else mkdir -p "$MM/$k"; fi
            done
            [ "$ok" = 1 ] && echo "$RSRC" > "$STAGE/guest_ringtones.src"
        fi
        for d in "$STAGE/data/oplus" "$MM" "$MM/ringtones" "$MM/notifications" "$MM/ui"; do
            mkdir -p "$d"
            $BB chown 1000:1000 "$d" 2>/dev/null || true
            $BB chmod 0775 "$d" 2>/dev/null || true
        done
        for k in ringtones notifications ui; do
            $BB chown -h -R 1000:1000 "$MM/$k" 2>/dev/null || true
            for f in "$MM/$k"/*; do [ -f "$f" ] && $BB chmod 0644 "$f"; done
        done
        $BB chcon u:object_r:system_data_file:s0 "$STAGE/data/oplus" 2>/dev/null || true
        $BB chcon -h -R u:object_r:system_data_file:s0 "$MM" 2>/dev/null || true
        echo "Guest ringtones: $(ls "$MM/ringtones" | wc -l) ringtones, $(ls "$MM/notifications" | wc -l) notifications from ${RSRC#$ROOTFS}"
    else
        echo "WARNING: no ColorOS haptic ringtone set in my_product; guest ringtones not staged"
    fi
fi

# Screen recording of the session (guest_start.sh) only when asked for.
if [ "${ONEOS_RECORD:-0}" = 1 ]; then touch "$STAGE/data/oneos_record"; else rm -f "$STAGE/data/oneos_record"; fi
echo "Screen recording: $([ -f "$STAGE/data/oneos_record" ] && echo on || echo off)"
# Hardware overlays for the guest's SurfaceFlinger (see guest_start.sh). Off
# for ColorOS, whose composer extension client got its frames rejected. On by
# default since run 44 for other guests: run 43's Pixel surfaceflinger has no
# Qualcomm composer client, and forcing GPU composition there cost about 2
# missed frames a second; guest_start.sh still forces it if the composer
# rejects frames. ONEOS_GUEST_HWC=0|1 overrides either default.
HWC_DEF=1
{ [ -e "$ROOTFS/system/framework/oplus-services.jar" ] || [ -L "$ROOTFS/system/framework/oplus-services.jar" ]; } && HWC_DEF=0
if [ "${ONEOS_GUEST_HWC:-$HWC_DEF}" = 1 ]; then touch "$STAGE/data/oneos_hwc"; else rm -f "$STAGE/data/oneos_hwc"; fi
echo "Guest HW overlays: $([ -f "$STAGE/data/oneos_hwc" ] && echo 'on (GPU composition forced only if the composer rejects frames)' || echo 'off (GPU composition)')"

# ONEOS_GAP_FAST=0: guest_start.sh keeps its fixed 2 s sleeps after the
# composer restart and the SurfaceFlinger start (run 32 timing; see there).
if [ "${ONEOS_GAP_FAST:-1}" = 0 ]; then touch "$STAGE/data/oneos_gap_slow"; else rm -f "$STAGE/data/oneos_gap_slow"; fi


# OPPO's own default runtime permission grants (patches/oplus_default_grants.py
# in oplus-services_patched.jar reads the my_product and my_stock grant lists
# while this flag exists). Its OplusRuntimePermGrantPolicyManager finds them
# only through CUST_LEVEL_LIST, which OPPO's init exports and the container
# never has. Run 34: "default xmls not found", so the network location
# provider com.oplus.location had no location or phone permission, WifiService
# refused all 27 of its scans ("UID 10163 has no location permission") and
# Weather never got a location; 108 grants of 35 OPPO apps were missing. OPPO
# grants on every boot, only to system apps, only what an app requests and
# never over a choice the user made. ONEOS_GUEST_OPLUS_GRANTS=0 leaves the
# lists out (grants already given stay in the guest's permission state).
if [ "${ONEOS_GUEST_OPLUS_GRANTS:-1}" = 1 ]; then touch "$STAGE/data/oneos_oplus_grants"; else rm -f "$STAGE/data/oneos_oplus_grants"; fi
echo "OPPO default grants: $([ -f "$STAGE/data/oneos_oplus_grants" ] && echo on || echo off)"

# The guest's /data/misc/adb always exists, keys or not. ColorOS's (Android
# 17) AdbDebuggingManager takes a missing directory as null key files and
# AdbService's constructor throws on them ("ADB data directory does not
# exist", "Failure starting AdbService"); the Lifecycle then calls
# systemReady() on the never-created service at boot phase 550 and
# system_server dies of the NullPointerException. Session f075d93a (S25U,
# fresh stage): One UI had USB debugging on but no adb_keys (no computer was
# ever allowed over USB), so the only mkdir, the copy below, never ran; the
# F8U's stage had the directory from its adb_keys. A real /data/misc/adb is
# system:shell 02750 (init.rc); 5b labels it with the rest of data/misc.
# What goes into it is unchanged: the host's adb_keys only with One UI's USB
# debugging on, and never One UI's adb_temp_keys.xml.
mkdir -p "$STAGE/data/misc/adb" || { echo "ERROR: could not create $STAGE/data/misc/adb; not starting the guest"; exit 3; }
chown 1000:2000 "$STAGE/data/misc/adb" 2>/dev/null || true
chmod 02750 "$STAGE/data/misc/adb" 2>/dev/null || true
if [ "$HOST_ADB" = 1 ] && [ -f /data/misc/adb/adb_keys ]; then
    rm -f "$STAGE/data/misc/adb/adb_keys"
    cp -f /data/misc/adb/adb_keys "$STAGE/data/misc/adb/adb_keys" 2>/dev/null && \
        chmod 640 "$STAGE/data/misc/adb/adb_keys" 2>/dev/null && \
        echo "Copied host adb_keys into the guest /data"
elif [ "$HOST_ADB" != 1 ]; then
    # The guest's own copy from an earlier session (stage only, not One UI's).
    rm -f "$STAGE/data/misc/adb/adb_keys"
fi
if [ -f "$STAGE/zygote_exec" ]; then
    rm -f "$STAGE/data/zygote_exec"
    cp -f "$STAGE/zygote_exec" "$STAGE/data/zygote_exec"
    chmod 755 "$STAGE/data/zygote_exec"
fi
# OneOS: the guest's own busybox, copied like zygote_exec. guest_start.sh uses
# it after the pivot, so nothing in the guest needs host /data/adb (bound
# read-only below).
# Named busybox in its own dir: a multi-call busybox reads its applet from
# argv[0] unless it is called busybox. Checked here with the applets
# guest_start.sh needs first.
rm -f "$STAGE/data/oneos_busybox"
mkdir -p "$STAGE/data/oneos_bin"
rm -f "$STAGE/data/oneos_bin/busybox"
if cp -f "$BB" "$STAGE/data/oneos_bin/busybox" && chmod 755 "$STAGE/data/oneos_bin/busybox" &&
    "$STAGE/data/oneos_bin/busybox" true && "$STAGE/data/oneos_bin/busybox" mount --help >/dev/null 2>&1; then
    echo "Guest busybox: $STAGE/data/oneos_bin/busybox (from $BB)"
else
    rm -f "$STAGE/data/oneos_bin/busybox"
    echo "WARNING: could not copy $BB into the guest /data; guest_start.sh keeps the host's path"
fi
mkdir -p "$STAGE/data/user/0" "$STAGE/data/user_de/0"
mkdir -p "$STAGE/data/system/users/0" "$STAGE/data/system_de/0/spblob" "$STAGE/data/system_ce/0"
# A guest lock state from before the weaver guard (patches/guest_no_weaver.py)
# holds protectors in the phone's weaver slots, which the guarded framework
# can no longer read, so the guest could not unlock its own user 0. Only the
# stage's copy: One UI's lock state is never touched. The guest sets up a
# fresh software protector on its next boot, as on a fresh stage; a lock set
# inside ColorOS is gone with it.
if ls "$STAGE/data/system_de/0/spblob"/*.weaver >/dev/null 2>&1; then
    rm -f "$STAGE/data/system_de/0/spblob"/* "$STAGE/data/system/locksettings.db" \
          "$STAGE/data/system/locksettings.db-journal" "$STAGE/data/system/locksettings.db-wal" \
          "$STAGE/data/system/locksettings.db-shm" "$STAGE/data/system"/gatekeeper.*.key 2>/dev/null
    echo "Guest lock state from before the weaver guard removed (stage only); ColorOS makes a new one"
fi
mkdir -p "$STAGE/data/misc/user/0" "$STAGE/data/misc_de/0" "$STAGE/data/misc_ce/0"
# The guest has no vold_prepare_subdirs, so nothing creates the per-user APEX
# data dirs. WifiConfigStore only mkdir()s the last level (run 32: Could not
# create store directory /data/misc_ce/0/apexdata/com.android.wifi, Failed to
# create user store files): the user store (network suggestions, per-user
# networks) never loaded. Stage only; the chmod/chown pass below covers them.
mkdir -p "$STAGE/data/misc_ce/0/apexdata/com.android.wifi" "$STAGE/data/misc_de/0/apexdata/com.android.wifi"
mkdir -p "$STAGE/data/anr" "$STAGE/data/app" "$STAGE/data/rollback" "$STAGE/data/incremental"
# The guest's own shared storage. Never the phone's /data/media: in run 25 the
# guest's cleanup of a user it could not prepare deleted the photos in it.
mkdir -p "$STAGE/data/media/0" "$STAGE/data/media/obb" "$STAGE/data/vendor_de/0" "$STAGE/data/vendor_ce/0"

# OneOS: without OneLineage's LineageOS packages (Launcher3, LatinIME,
# LineageSettings; ColorOS has none of them) and with the OneOS app in place
# of the OneLineage switcher.
for pkg in com.android.providers.settings \
           com.android.providers.telephony \
           com.android.phone \
           com.android.systemui \
           com.android.settings \
           com.android.providers.media \
           com.android.providers.downloads \
           com.android.providers.contacts \
           com.android.providers.calendar \
           com.fahadali.oneos; do
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
chown -h -R 1000:1000 "$STAGE/data/system" "$STAGE/data/system_de" "$STAGE/data/system_ce" "$STAGE/data/misc" "$STAGE/data/misc_de" "$STAGE/data/misc_ce" 2>/dev/null || true
# The package dirs pre-created above are root-owned until something sets an
# owner: give them system's, as before; the realign below corrects the ones the
# guest gave another uid.
for pkg in com.android.providers.settings com.android.providers.telephony com.android.phone \
           com.android.systemui com.android.settings \
           com.android.providers.media com.android.providers.downloads com.android.providers.contacts \
           com.android.providers.calendar com.fahadali.oneos; do
    chown -h -R 1000:1000 "$STAGE/data/user_de/0/$pkg" "$STAGE/data/user/0/$pkg" 2>/dev/null
    chmod -R 777 "$STAGE/data/user_de/0/$pkg" "$STAGE/data/user/0/$pkg" 2>/dev/null
done
# OneOS: not the app data trees. Resetting every app dir to 1000:1000 on each
# switch made the host installd refuse to prepare 353 packages ("Expected path
# ... with owner NNNNN but found 1000:1000"). Only the top levels, then every
# package dir back to the uid the guest gave it.
chown system:system "$STAGE/data/user" "$STAGE/data/user_de" "$STAGE/data/user/0" "$STAGE/data/user_de/0" 2>/dev/null
chmod 0711 "$STAGE/data/user" "$STAGE/data/user_de" 2>/dev/null
chmod 0771 "$STAGE/data/user/0" "$STAGE/data/user_de/0" 2>/dev/null
realigned=0
if [ -f "$STAGE/data/system/packages.list" ]; then
    while read -r pkg auid rest; do
        case "$auid" in ''|*[!0-9]*) continue ;; esac
        for b in user/0 user_de/0; do
            d="$STAGE/data/$b/$pkg"
            [ -d "$d" ] || continue
            [ "$(stat -c %u "$d")" = "$auid" ] && continue
            chown -h -R "$auid:$auid" "$d" && chmod 0700 "$d" && realigned=$((realigned + 1))
        done
    done < "$STAGE/data/system/packages.list"
fi
echo "App data dirs realigned to their package uids: $realigned"
# Profiles: installd recreates them with the owners it expects.
rm -rf "$STAGE/data/misc/profiles/cur/0/"* "$STAGE/data/misc/profiles/ref/"* 2>/dev/null

# Create the bluetooth stack's storage before the guest ever starts. The GSI's
# GD stack asserts out of storage_module.cc if it cannot persist bt_config.conf,
# and the staged tree never had this directory, so com.android.bluetooth
# crash-looped every 4 s from early boot. uid 1002 = bluetooth.
mkdir -p "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null
chown 1002:1002 "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null || true
chmod 0770 "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null || true

# ColorOS's removable preinstalled apps (/my_stock/del-app) load their native
# libraries from /data/preapps-lib/<app>/lib/arm64, which the guest's
# PackageManager fills. The guest's init.rc makes the top directory 0771 system
# system; the container has no init, so PackageManager created it 0700 and no
# app could look inside. Run 32: Weather crashed on open (all.log:872820,
# UnsatisfiedLinkError: "libprivate-constants-v3.so" not found) although the
# file is in the stage's preapps-lib/OppoWeather2/lib/arm64, and the theme
# store could not load KeKeThemeSpace's libmmkv.so (all.log:1222929). Only
# the mode of the guest's own directory changes; made here if missing so
# PackageManager never creates it with 0700 again.
mkdir -p "$STAGE/data/preapps-lib" 2>/dev/null
chown 1000:1000 "$STAGE/data/preapps-lib" 2>/dev/null || true
chmod 0771 "$STAGE/data/preapps-lib" 2>/dev/null || true

# HyperOS's own /data folders. Its init rc files (system, system_ext, product)
# make /data/system/theme, theme_magic and fonts (owner system_theme, 6101 in
# the image's passwd), mcd, whetstone, miuilog and more at boot; One UI's init
# never reads them, and nothing else creates them in the guest's /data. Theme
# Store could not create them itself (seventh HyperOS run: "mkdirs failed",
# chmod ENOENT), and icons, fonts, lock styles and wallpapers could not be
# applied. Missing ones under /data/system and /data/miuilog are made in the
# guest's own /data with the rc's mode and owners; names the guest's
# passwd/group files lack fall back to system.
# GUEST_SYSTEM_EXT and GUEST_PRODUCT, never system/system_ext or system/product:
# HyperOS has both at its root and system/ links to them with absolute links,
# which here on the host are One UI's folders (r7 checked those, found no
# miui-services.jar and made nothing: eighth HyperOS run, "mkdirs failed" again).
if [ -e "$GUEST_SYSTEM_EXT/framework/miui-services.jar" ]; then
    aid() { # <name> <passwd or group file>: the id
        case "$1" in
            root) echo 0 ;; system) echo 1000 ;; radio) echo 1001 ;; bluetooth) echo 1002 ;;
            graphics) echo 1003 ;; input) echo 1004 ;; audio) echo 1005 ;; camera) echo 1006 ;;
            log) echo 1007 ;; wifi) echo 1010 ;; media) echo 1013 ;; media_rw) echo 1023 ;;
            audioserver) echo 1041 ;; cameraserver) echo 1047 ;; shell) echo 2000 ;; cache) echo 2001 ;;
            *) i=$(awk -F: -v n="$1" '$1 == n {print $3; exit}' "$2" 2>/dev/null)
               case "$i" in ''|*[!0-9]*) echo 1000 ;; *) echo "$i" ;; esac ;;
        esac
    }
    made=0
    for f in "$ROOTFS"/system/etc/init/*.rc "$GUEST_SYSTEM_EXT"/etc/init/*.rc "$GUEST_PRODUCT"/etc/init/*.rc; do
        [ -f "$f" ] && [ ! -L "$f" ] && cat "$f"
    done | awk '$1 == "mkdir" && $2 ~ /^\/data\/(system|miuilog)(\/|$)/ && $2 !~ /[$.][.]|[$]/ { sub(/\/$/, "", $2); print $2, ($3 ~ /^[0-7]+$/ ? $3 : "0771"), ($4 == "" ? "root" : $4), ($5 == "" ? ($4 == "" ? "root" : $4) : $5) }' |
        sort -u -k1,1 > "$STAGE/miui_data_dirs.txt"
    while read -r p mode u g; do
        d="$STAGE$p"
        [ -e "$d" ] || [ -L "$d" ] && continue
        # Root runs this on the host: never through a link the guest made.
        q="$STAGE/data"; ok=1
        for part in $(echo "${p#/data/}" | tr '/' ' '); do
            q="$q/$part"; [ -L "$q" ] && { ok=0; break; }
        done
        [ $ok = 1 ] || { echo "HyperOS /data folder $p: a link on the way, skipped"; continue; }
        mkdir -p "$d" && chmod "$mode" "$d" && chown "$(aid "$u" "$ROOTFS/system/etc/passwd"):$(aid "$g" "$ROOTFS/system/etc/group")" "$d" &&
            made=$((made + 1))
    done < "$STAGE/miui_data_dirs.txt"
    echo "HyperOS /data folders from its init rc files: $made made ($(wc -l < "$STAGE/miui_data_dirs.txt") listed)"
    rm -f "$STAGE/miui_data_dirs.txt"
fi

# Device states for the guest. Its DeviceStateProviderImpl reads /odm (the
# container has none), then /data/system/devicestate, then the host's
# /vendor/etc/devicestate (run 30: 0 CLOSE and 3 OPEN on the lid switch).
# ONEOS_GUEST_DEVICE_STATES=oneos keeps those ids and lid conditions and adds
# the properties the guest framework uses with device_state_property_migration
# (on, read-only, in the guest's aconfig_flags.pb): WindowManager counts
# OUTER_PRIMARY as folded and INNER_PRIMARY as open, TRIGGER_WAKE on 3 wakes the
# screen on unfold. State 0 has no TRIGGER_SLEEP, so folding moves ColorOS to
# the cover instead of sleeping (ColorOS itself only sleeps on fold with
# continue_using_apps_when_folded=2). vendor (default for now) = run 30.
DSDIR="$STAGE/data/system/devicestate"
DS_DEFAULT=vendor
FOLD8_COLOR_HINGE=0
# The Z Fold8 Ultra (n6-f8u) has the same lid states (0 CLOSE, 3 OPEN) and the
# same sensor ("Folding Angle  Non-wakeup", 65686, read on SM-F976B 2026-10-26).
if grep -q '^  "image": "coloros17-findn6",$' "$STAGE/.oneos_stage" &&
        { { [ "${ONEOS_PROFILE:-}" = f8 ] && grep -q '^  "set": "n6-f8",$' "$STAGE/.oneos_stage"; } ||
          { [ "${ONEOS_PROFILE:-}" = f8u ] && grep -q '^  "set": "n6-f8u",$' "$STAGE/.oneos_stage"; }; }; then
    DS_DEFAULT=fold8-hinge
    FOLD8_COLOR_HINGE=1
fi
if [ "$FOLD8_COLOR_HINGE" = 1 ] && [ "${ONEOS_GUEST_DEVICE_STATES:-$DS_DEFAULT}" = fold8-hinge ]; then
    mkdir -p "$DSDIR"
    cat > "$DSDIR/device_state_configuration.xml" <<'F8DSX'
<?xml version="1.0" encoding="utf-8"?>
<!-- OneOS Fold8 / Fold8 Ultra ColorOS hinge. Lid switch owns closed/open panels. -->
<device-state-config>
    <device-state>
        <identifier>0</identifier><name>CLOSE</name>
        <properties>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_HARDWARE_CONFIGURATION_FOLD_IN_CLOSED</property>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_DISPLAY_CONFIGURATION_OUTER_PRIMARY</property>
        </properties>
        <conditions><lid-switch><open>false</open></lid-switch></conditions>
    </device-state>
    <device-state>
        <identifier>1</identifier><name>TENT</name>
        <properties>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_HARDWARE_CONFIGURATION_FOLD_IN_CLOSED</property>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_DISPLAY_CONFIGURATION_OUTER_PRIMARY</property>
        </properties>
        <conditions><lid-switch><open>false</open></lid-switch></conditions>
    </device-state>
    <device-state>
        <identifier>2</identifier><name>HALF_OPENED</name>
        <properties>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_HARDWARE_CONFIGURATION_FOLD_IN_HALF_OPEN</property>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_DISPLAY_CONFIGURATION_INNER_PRIMARY</property>
        </properties>
        <conditions>
            <lid-switch><open>true</open></lid-switch>
            <sensor>
                <type>com.samsung.sensor.folding_angle</type>
                <name>Folding Angle  Non-wakeup</name>
                <value><min-inclusive>15</min-inclusive><max-inclusive>165</max-inclusive></value>
            </sensor>
        </conditions>
    </device-state>
    <device-state>
        <identifier>3</identifier><name>OPEN</name>
        <properties>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_HARDWARE_CONFIGURATION_FOLD_IN_OPEN</property>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_DISPLAY_CONFIGURATION_INNER_PRIMARY</property>
        </properties>
        <conditions><lid-switch><open>true</open></lid-switch></conditions>
    </device-state>
</device-state-config>
F8DSX
    chown 1000:1000 "$DSDIR" "$DSDIR/device_state_configuration.xml"
    chmod 644 "$DSDIR/device_state_configuration.xml"
    echo "Guest device states: fold hinge (0 closed, 2 half-open 15..165 degrees, 3 open)"
elif [ "${ONEOS_GUEST_DEVICE_STATES:-$DS_DEFAULT}" = oneos ]; then
    mkdir -p "$DSDIR"
    cat > "$DSDIR/device_state_configuration.xml" <<'DSX'
<?xml version="1.0" encoding="utf-8"?>
<!-- OneOS (guest_prepare.sh): Samsung's lid-switch states with OPPO/AOSP fold properties. -->
<device-state-config>
    <device-state>
        <identifier>0</identifier>
        <name>CLOSE</name>
        <properties>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_HARDWARE_CONFIGURATION_FOLD_IN_CLOSED</property>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_DISPLAY_CONFIGURATION_OUTER_PRIMARY</property>
        </properties>
        <conditions>
            <lid-switch>
                <open>false</open>
            </lid-switch>
        </conditions>
    </device-state>
    <device-state>
        <identifier>3</identifier>
        <name>OPEN</name>
        <properties>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_HARDWARE_CONFIGURATION_FOLD_IN_OPEN</property>
            <property>com.android.server.policy.PROPERTY_FOLDABLE_DISPLAY_CONFIGURATION_INNER_PRIMARY</property>
            <property>com.android.server.policy.PROPERTY_POWER_CONFIGURATION_TRIGGER_WAKE</property>
        </properties>
        <conditions>
            <lid-switch>
                <open>true</open>
            </lid-switch>
        </conditions>
    </device-state>
</device-state-config>
DSX
    chown 1000:1000 "$DSDIR" "$DSDIR/device_state_configuration.xml"
    chmod 644 "$DSDIR/device_state_configuration.xml"
    echo "Guest device states: OneOS file (0 CLOSE = lid closed, 3 OPEN = lid open)"
else
    # The staged /data persists between sessions: never leave an old file behind.
    rm -f "$DSDIR/device_state_configuration.xml"
fi

# HyperOS's device states. Its DeviceStateProviderImpl (Xiaomi's change) reads
# product/etc/devicestate/device_state_configuration.xml, whose states all wait
# on Xiaomi's hinge sensor (xiaomi.sensor.fold_status). This phone has none:
# "No declared device states match any of the required conditions", no state
# was ever committed, DisplayManager stayed on the inner panel's default layout
# and the cover screen never came on (seventh HyperOS run). A copy with
# Xiaomi's ids, names and properties is bound over it in the guest's view:
# 0 (CLOSED) on the lid switch closed and 3 (OPENED) on it open, like
# Samsung's own 0 and 3; the other states that waited on the sensor (TENT,
# HALF_OPENED) can only be requested (PROPERTY_EMULATED_ONLY). guest_start.sh
# writes the matching display layout.
# The guest's own product (r7 looked under system/product, One UI's /product
# from here, and bound nothing: no device state was ever committed in the
# eighth run either, "Failed to find Sensor with type: xiaomi.sensor.fold_status").
HDSC="$GUEST_PRODUCT/etc/devicestate/device_state_configuration.xml"
if [ -e "$GUEST_SYSTEM_EXT/framework/miui-services.jar" ] && [ -f "$HDSC" ] && [ ! -L "$HDSC" ] &&
   grep -q 'xiaomi.sensor.fold_status' "$HDSC" && [ "${ONEOS_GUEST_FORM:-fold}" = fold ]; then
    awk '
        function flush(   i, out) {
            if (n == 0) return
            for (i = 1; i <= n; i++) {
                if (skip[i]) continue
                out = buf[i]
                if (emul && buf[i] ~ /<\/properties>/)
                    print "            <property>com.android.server.policy.PROPERTY_EMULATED_ONLY</property>"
                print out
                if (lid != "" && buf[i] ~ /<\/properties>/) {
                    print "        <conditions>"
                    print "            <lid-switch>"
                    print "                <open>" lid "</open>"
                    print "            </lid-switch>"
                    print "        </conditions>"
                }
            }
            n = 0
        }
        /<device-state>/ { flush(); inst = 1; id = ""; cond = 0; n = 0; emul = 0; lid = "" }
        !inst { print; next }
        {
            buf[++n] = $0; skip[n] = 0
            if ($0 ~ /<identifier>/) { id = $0; gsub(/[^0-9]/, "", id) }
            if ($0 ~ /<conditions>/) cond = 1
            if (cond) skip[n] = 1
            if ($0 ~ /<\/conditions>/) {
                cond = 0
                if (id == "0") lid = "false"; else if (id == "3") lid = "true"; else emul = 1
            }
            if ($0 ~ /<\/device-state>/) { flush(); inst = 0 }
        }
        END { flush() }' "$HDSC" > "$STAGE/hyperos_device_state.xml"
    if grep -q '<lid-switch>' "$STAGE/hyperos_device_state.xml" && ! grep -q 'xiaomi.sensor' "$STAGE/hyperos_device_state.xml"; then
        chmod 644 "$STAGE/hyperos_device_state.xml"
        $BB mount --bind "$STAGE/hyperos_device_state.xml" "$HDSC" &&
            echo "Guest device states: HyperOS's file on the lid switch (0 CLOSED closed, 3 OPENED open; $(grep -c 'PROPERTY_EMULATED_ONLY' "$STAGE/hyperos_device_state.xml") request-only)"
    else
        echo "!!! HyperOS device states: the copy did not come out as expected, the image's file is left (no cover screen)"
    fi
fi

# SELinux labels matter just as much as modes here. Every directory below lives
# under /data/local/tmp, so it is created as u:object_r:shell_data_file:s0. The
# guest's system_server runs in u:r:system_server:s0 (Samsung policy) and is
# denied both read and write on shell_data_file: chmod 777 does not help, because
# the denial is MAC, not DAC. That broke UserManagerService (users/0.xml EACCES),
# EntropyMixer/BatteryStats/PackageWatchdog ("Failed to create directory for
# *.new") and finally the settings provider:
#   SQLiteCantOpenDatabaseException: /data/user_de/0/com.android.providers.settings/databases/settings.db
# Relabel the staged tree the way a real /data is labeled. The host bind mounts
# that live inside this tree (/data/apex, /data/adb) are deliberately excluded
# so host data never gets relabeled.
# OneOS: every recursive relabel below is -h (no-dereference). busybox chcon
# follows a symlink to its target unless -h is given, so an absolute symlink a
# guest app left in its own data dir (e.g. ~/storage -> /storage/emulated/0, or
# a Termux alternatives link into /data/data/com.termux) would otherwise get its
# HOST target relabelled, and One UI's copy would lose access on return. The
# chown of /data/media is -h for the same reason.
echo "=== 5b. Relabeling staged /data for guest SELinux ==="
$BB chcon u:object_r:system_data_file:s0 "$STAGE/data" 2>/dev/null || true
for d in data/system data/system_de data/system_ce data/user data/user_de \
         data/misc data/misc_de data/misc_ce data/anr data/dalvik-cache \
         data/local data/resource-cache data/app data/rollback data/incremental; do
    [ -e "$STAGE/$d" ] && $BB chcon -h -R u:object_r:system_data_file:s0 "$STAGE/$d" 2>/dev/null || true
done
for d in "$STAGE/data/user/0" "$STAGE/data/user_de/0"; do
    if [ -d "$d" ]; then
        $BB chcon u:object_r:system_data_file:s0 "$d" 2>/dev/null || true
        $BB chcon -h -R u:object_r:app_data_file:s0 "$d"/* 2>/dev/null || true
    fi
done
$BB chown -h -R 1023:1023 "$STAGE/data/media" 2>/dev/null || true
$BB chmod 0770 "$STAGE/data/media" "$STAGE/data/media/0" 2>/dev/null || true
$BB chcon -h -R u:object_r:media_rw_data_file:s0 "$STAGE/data/media" 2>/dev/null || true
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

# Pixel guest only (an image with oplus-services.jar is ColorOS, unchanged).
# After 5b and 5c, which relabel and re-own the staged trees every session.
GUEST_OPLUS=0
{ [ -e "$ROOTFS/system/framework/oplus-services.jar" ] || [ -L "$ROOTFS/system/framework/oplus-services.jar" ]; } && GUEST_OPLUS=1
[ "$GUEST_OPLUS" = 1 ] || echo "=== 5c2. One UI's preferred APNs and Bluetooth pairings for the guest ==="
# Preferred (attach) APN per SIM, from One UI: oneos_switch.sh recorded
# host_pref_apn ("slot mcc mnc apn") while One UI's telephony provider ran.
# Runs 41 and 42: with no preferred APN for SIM 2 (a fresh stage) Pixel's
# DataProfileManager took the carrier's first APN, web1, as the LTE attach APN;
# SIM 2 left LTE a second later and stayed on 3G for the session. One UI and
# ColorOS attach with web2. Picking it in Settings once the session runs is too
# late (the modem has given up on LTE by then), and that pick stays in the stage.
# So before every boot the guest's TelephonyProvider (com.android.providers.
# telephony, user_de/0, uid radio) gets One UI's APN in its preferred-full-apn
# prefs: apn<sub>, mcc<sub> and mnc<sub> as strings, every other <field><sub>
# removed; and apn_id<sub> / explicit_set_called<sub> are dropped from
# preferred-apn. With no saved id, getPreferredApnId looks the APN up by the
# fields present (getString(field + sub)) and keeps it when exactly one APN
# matches (web2: one, row 8 in run 42); no match leaves the guest's own
# choice, as before. Guest sub = slot + 1 (runs 41 and 42; the UI activator logs
# the guest's mapping). Android's SharedPreferences text XML; a .bak left by an
# interrupted write is what Android would load, so it is taken first. Never
# through a link. ONEOS_GUEST_APN=0 keeps the guest's own APNs.
TP_DIR="$STAGE/data/user_de/0/com.android.providers.telephony"
TP_PREFS="$TP_DIR/shared_prefs"
# <prefs file> <sub> ids|fields [<apn> <mcc> <mnc>]: one SharedPreferences file
# rewritten without apn_id<sub> / explicit_set_called<sub> (ids) or without any
# <field><sub> and with the three strings (fields). 0 done, 1 left as it was.
apn_prefs() {
    p_f=$1; p_s=$2; p_mode=$3; p_a=$4; p_c=$5; p_n=$6
    p_new="$p_f.oneos-new"
    rm -f "$p_new"
    if [ -f "$p_f.bak" ] && [ ! -L "$p_f.bak" ]; then mv -f "$p_f.bak" "$p_f"; else rm -f "$p_f.bak"; fi
    [ -L "$p_f" ] && rm -f "$p_f"
    p_src=/dev/null
    if [ -f "$p_f" ]; then
        [ "$(head -c 5 "$p_f")" = "<?xml" ] || return 1
        p_src=$p_f
    elif [ "$p_mode" = ids ]; then
        return 0
    fi
    # Field names end in a letter or _, so the trailing digits are the sub id
    # (apn12 is sub 12's, never sub 2's).
    awk -v s="$p_s" -v mode="$p_mode" -v a="$p_a" -v c="$p_c" -v n="$p_n" \
        -v hdr="<?xml version='1.0' encoding='utf-8' standalone='yes' ?>" '
        function drop(nm,   p) {
            if (mode == "ids") return nm == "apn_id" s || nm == "explicit_set_called" s
            if (length(nm) <= length(s) || substr(nm, length(nm) - length(s) + 1) != s) return 0
            p = substr(nm, 1, length(nm) - length(s))
            return p ~ /^[a-z_]([a-z0-9_]*[a-z_])?$/
        }
        function add() {
            if (mode != "fields") return
            print "    <string name=\"apn" s "\">" a "</string>"
            print "    <string name=\"mcc" s "\">" c "</string>"
            print "    <string name=\"mnc" s "\">" n "</string>"
        }
        skip { if (index($0, "</string>")) skip = 0; next }
        match($0, / name="[^"]*"/) && drop(substr($0, RSTART + 7, RLENGTH - 8)) {
            if ($0 ~ /<string / && !index($0, "</string>") && $0 !~ /\/>[ \t]*$/) skip = 1
            next
        }
        /<map[ \t]*\/>/ { print "<map>"; add(); print "</map>"; next }
        /<\/map>/ { add(); print; next }
        { print }
        END { if (NR == 0) { print hdr; print "<map>"; add(); print "</map>" } }' "$p_src" > "$p_new" &&
        grep -q '</map>' "$p_new" || { rm -f "$p_new"; return 1; }
    if [ "$p_mode" = fields ]; then
        for p_kv in "apn$p_s>$p_a" "mcc$p_s>$p_c" "mnc$p_s>$p_n"; do
            [ "$(grep -c -F " name=\"${p_kv%%>*}\"" "$p_new")" = 1 ] &&
                [ "$(grep -c -F "<string name=\"${p_kv%%>*}\">${p_kv#*>}</string>" "$p_new")" = 1 ] || { rm -f "$p_new"; return 1; }
        done
    elif grep -q -F -e " name=\"apn_id$p_s\"" -e " name=\"explicit_set_called$p_s\"" "$p_new"; then
        rm -f "$p_new"; return 1
    fi
    chown 1001:1001 "$p_new" && chmod 0660 "$p_new" && mv -f "$p_new" "$p_f" || { rm -f "$p_new"; return 1; }
    $BB chcon u:object_r:radio_data_file:s0 "$p_f" 2>/dev/null || $BB chcon u:object_r:app_data_file:s0 "$p_f" 2>/dev/null || true
    return 0
}
if [ "$GUEST_OPLUS" = 1 ]; then
    :
elif [ "${ONEOS_GUEST_APN:-1}" != 1 ]; then
    echo "Guest attach APN: the guest's own (ONEOS_GUEST_APN=0)"
elif [ ! -s "$STAGE/host_pref_apn" ] || [ -L "$STAGE/host_pref_apn" ]; then
    echo "Guest attach APN: the guest's own (no preferred APN read from One UI)"
elif [ -L "$TP_DIR" ] || [ -L "$TP_PREFS" ]; then
    echo "WARNING: ${TP_PREFS#$STAGE/} or its folder is a symlink; guest attach APN not seeded"
else
    if [ ! -d "$TP_PREFS" ]; then
        mkdir -p "$TP_PREFS" && chown 1001:1001 "$TP_DIR" "$TP_PREFS" && chmod 0771 "$TP_PREFS"
        $BB chcon u:object_r:radio_data_file:s0 "$TP_DIR" "$TP_PREFS" 2>/dev/null || true
    fi
    while read -r slot mcc mnc apn rest; do
        case "$slot:$mcc:$mnc" in
            [0-7]:[0-9][0-9][0-9]:[0-9][0-9]|[0-7]:[0-9][0-9][0-9]:[0-9][0-9][0-9]) ;;
            *) echo "Guest attach APN: host_pref_apn line '$slot $mcc $mnc' not used"; continue ;;
        esac
        case "$apn" in
            ''|*[!A-Za-z0-9._-]*) echo "Guest attach APN: slot $slot APN name not used (unexpected characters)"; continue ;;
        esac
        [ -z "$rest" ] && [ ${#apn} -le 100 ] || { echo "Guest attach APN: host_pref_apn line for slot $slot not used"; continue; }
        sub=$((slot + 1))
        if apn_prefs "$TP_PREFS/preferred-full-apn.xml" "$sub" fields "$apn" "$mcc" "$mnc" &&
           apn_prefs "$TP_PREFS/preferred-apn.xml" "$sub" ids; then
            echo "Guest attach APN: slot $slot (sub $sub) -> $apn ($mcc $mnc, from One UI)"
        else
            echo "WARNING: Guest attach APN: slot $slot (sub $sub) not seeded (unexpected prefs file in ${TP_PREFS#$STAGE/}); the guest's own stays"
        fi
    done < "$STAGE/host_pref_apn"
fi
# Bluetooth pairings (run 42): the guest's stack starts from its own
# bt_config.conf, so none of One UI's paired devices were there, and pairing
# one of them again in the guest replaces that device's key for this phone (both
# systems have the phone's one Bluetooth address): One UI's pairing would stop
# working. So One UI's /data/misc/bluedroid/bt_config.conf (paired devices and
# their keys) is copied one way into the guest's stage copy at every switch:
# only a regular file, never through a link; only the stage's file is replaced,
# nothing is ever copied back, and a guest-only pairing lasts until the next
# switch. bluetooth 1002:1002 0660, bluetooth_data_file; a bt_config.bak from
# the guest's last session (the stack falls back to it) is deleted.
# ONEOS_GUEST_BT_IMPORT=0 keeps the guest's file (through the LE check below).
# Run 43, the first run with the import: One UI's LE keys are not in the layout
# the Pixel stack reads (LE_KEY_PID = 16-byte IRK, address type 00 or 01, the
# identity address). Every device's PID decoded to type 149, 181 or 13 and a
# made-up identity address (earbuds xx:xx -> yy:yy), and the stack used it anyway:
# Java and native sent A2DP, HFP and the pairing record itself to that address,
# so A2DP had no active peer (no Bluetooth audio session, PAL -19 on every
# write), HFP never got its service-level connection and SCO was refused. So
# the stage file is now One UI's through BT_SAN_AWK: if any device's LE_KEY_PID
# is not that layout with its own address, the file's LE layout is not the
# guest's (a car kit's LE_KEY_PENC was refused too), so every device loses its
# LE records (LE_*, Le*, AddrType, ServiceLe, GATT caching, LE Audio, CSIP,
# hearing aid, VCP), LE-only devices (DevType 2) are dropped and dual-mode ones
# become BR/EDR (DevType 3 -> 1); BR/EDR link keys stay. An AOSP-layout file
# passes unchanged. If the filter or the check after it fails, the guest starts
# with no pairings (the stage's bt_config.conf and .bak deleted): never an
# unchecked copy, and never run 43's stage file (One UI's bad PID data plus the
# guest's own key for the earbuds). ONEOS_GUEST_BT_LE_SANITIZE=0 skips the LE part (since
# run 44 the link key check below still runs). diag_bt/ gets the shape of One
# UI's file and of the guest's previous one (BT_SHAPE_AWK: key names, value
# lengths, hex or not, small type values, where the device's own address sits
# in LE_KEY_PID), never a key value or a full address. Run 43 also had the
# imported link key rejected (HCI_ERR_AUTH_FAILURE at the earbuds' first
# connection); the earbuds then asked to pair again and the guest's stack
# auto-accepted it, which replaced their key for this phone and broke One UI's
# pairing. Never pair One UI's devices in the guest (docs/pixel-guest.md).
# Run 44: One UI's link keys are not AOSP's. diag_bt/shape_oneui.txt has
# LinkKey len=64 hex (32 bytes) for both BR/EDR devices, and One UI's LE keys
# are 64 hex too; the Pixel stack's own (shape_guest_prev.txt) is 32 hex (16
# bytes). The stack found no usable key: HCI_ERR_AUTH_FAILURE, "Bond loss
# detected ... KEY_MISSING", autonomous re-pairing, three pairing dialogs, and
# a CsipSetCoordinatorService.bondStateChanged NPE that took the Bluetooth
# process down (17:32:08 to 17:35:21); the earbuds now hold a guest key and
# need pairing again in One UI. So the import is off by default
# (ONEOS_GUEST_BT_IMPORT=1 turns it on), and BT_SAN_AWK drops every device
# whose LinkKey is not exactly 32 hex chars, whichever file it reads: the
# stage's own file kept One UI's imported records with their 64-hex keys
# across the guest's own saves (run 43's, shape_guest_prev.txt device 1), and
# such a record goes through the same KEY_MISSING and re-pairing as soon as
# that device connects. A key the Pixel stack wrote is always 32 hex, so the
# guest's own pairings stay as they are.
BTC=/data/misc/bluedroid/bt_config.conf
BTD="$STAGE/data/misc/bluedroid"
BTDIAG="$STAGE/diag_bt"
# Every guest: the stage's folder and file are never One UI's own (a hard link
# of the file, or the folder reached another way than the checks at the top
# refuse). Nothing below, and no guest stack, may write to them.
if [ "$BTD" -ef /data/misc/bluedroid ] || { [ -e "$BTC" ] && [ "$BTD/bt_config.conf" -ef "$BTC" ]; }; then
    echo "ERROR: ${BTD#$STAGE/} or its bt_config.conf is One UI's own Bluetooth config; not starting the guest"
    exit 3
fi
rm -rf "$BTDIAG"
# Shared by both filters. A device section is [xx:xx:xx:xx:xx:xx] (written out:
# mawk and older busybox awk have no {n}).
BT_AWK_FN='function hex(s) { s = tolower(s); gsub(/[^0-9a-f]/, "", s); return s }
function isdev(s) { return s ~ /^\[[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]\]$/ }
function key(s) { sub(/[ \t]*=.*$/, "", s); return s }
function val(s) { sub(/^[^=]*=[ \t]*/, "", s); sub(/[ \t\r]+$/, "", s); return s }
'
# Names, lengths and layout facts only: a section or key name that is not a
# plain word is not shown, value= only for small numbers, and a device is its
# number plus the last two bytes of its address (as logcat masks it). For
# LE_KEY_PID: byte 16 (the AOSP address type) and the byte offset of the
# device's own address, as written and reversed (17 and - in AOSP's layout).
BT_SHAPE_AWK='function rev(a,   r, i) { r = ""; for (i = length(a) - 1; i >= 1; i -= 2) r = r substr(a, i, 2); return r }
function pos(h, a,   i) { for (i = 1; i + 11 <= length(h); i += 2) if (substr(h, i, 12) == a) return (i - 1) / 2; return "-" }
function name(k) { return (k ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && length(k) <= 48 && !(length(k) >= 8 && k ~ /^[0-9A-Fa-f]+$/)) ? k : "(name not shown, " length(k) " chars)" }
/^\[/ { dev = isdev($0); a = hex($0)
    if (dev) print "[device " ++nd " xx:xx:xx:xx:" substr($0, 14); else print "[" name(substr($0, 2, length($0) - 2)) "]"
    next }
/=/ { k = key($0); v = val($0); x = (v ~ /^[0-9A-Fa-f]+$/) ? "hex" : "txt"; e = ""
    if (dev && x == "hex" && k == "LE_KEY_PID") { h = tolower(v); e = " byte16=" substr(h, 33, 2) " self_at=" pos(h, a) " self_rev_at=" pos(h, rev(a)) }
    if ((k == "DevType" || k == "AddrType" || k == "LinkKeyType" || k ~ /PairingAlgorithm$/) && v ~ /^[0-9]+$/ && length(v) <= 3) e = " value=" v
    printf "  %s len=%d %s%s\n", name(k), length(v), x, e
    next }
/[^ \t\r]/ { print "  (line without =, " length($0) " chars)" }'
# One UI's file is read once and kept in memory. A device whose LinkKey is not
# 32 hex chars (16 bytes, AOSP's form; One UI writes 64) is dropped whole (run
# 44), always. bad = devices whose LE_KEY_PID is not 23 bytes (IRK, type
# 00/01, the device's own address); with any, every device loses its LE
# records, LE-only devices are dropped and dual-mode ones become BR/EDR. A
# device dropped for its link key does not count: in the stage's own file
# those are One UI's leftovers (run 43's device 1 had a bad PID too), and they
# must not strip the LE keys of the pairings the guest made itself. LE=0
# (ONEOS_GUEST_BT_LE_SANITIZE=0) skips the LE part. The summary line goes to SUM.
BT_SAN_AWK='{ L[NR] = $0 }
/^\[/ { sec = $0; dev = isdev(sec); if (dev) ndev++; next }
dev && LE == 1 && /^LE_KEY_PID[ \t]*=/ { p = tolower(val($0)); t = substr(p, 33, 2)
    if (length(p) != 46 || p ~ /[^0-9a-f]/ || (t != "00" && t != "01") || substr(p, 35, 12) != hex(sec)) badpid[sec] = 1 }
dev && /^DevType[ \t]*=/ && val($0) == "2" { leonly[sec] = 1 }
dev && /^LinkKey[ \t]*=/ { lk = val($0); if (length(lk) != 32 || lk ~ /[^0-9A-Fa-f]/) badkey[sec] = 1 }
END { bad = 0; for (s in badpid) if (!(s in badkey)) bad++
    sec = ""; dev = 0; drop = 0
    for (i = 1; i <= NR; i++) { l = L[i]
        if (l ~ /^\[/) { sec = l; dev = isdev(sec); drop = 0
            if (dev && (sec in badkey)) { drop = 1; keygone++ }
            else if (bad && dev && (sec in leonly)) { drop = 1; gone++ } }
        if (drop) continue
        if (bad && dev && l !~ /^\[/) {
            k = key(l)
            if (k ~ /^(LE_|Le[A-Z]|AddrType$|Services?Le$|Gatt|Csis|HearingAid|Sink|Source|VolumeControl|Bass)/) { cut[sec] = 1; continue }
            if (k == "DevType" && val(l) == "3") { print "DevType = 1"; continue }
        }
        print l }
    n = 0; for (s in cut) n++
    printf "%d devices, %d with a LinkKey not in AOSP form (32 hex) dropped, ", ndev, keygone > SUM
    if (LE == 1) printf "%d LE_KEY_PID not in the guest layout: LE records removed from %d, %d LE-only dropped\n", bad, n, gone > SUM
    else printf "LE check off (ONEOS_GUEST_BT_LE_SANITIZE=0)\n" > SUM }'
# The stage's bt_config.conf from $1 (One UI's file, or the stage's own) through
# BT_SAN_AWK, via a temp file: the link key check always, the LE check unless
# ONEOS_GUEST_BT_LE_SANITIZE=0. A failure, or no [Adapter] in the result,
# deletes the stage's file and .bak: no pairings, never an unchecked file. Only
# the stage's folder is written; $1 is only read.
bt_stage_conf() {
    rm -f "$BTD/bt_config.conf.oneos-new" "$BTD/bt_config.bak"
    bt_le=1; [ "${ONEOS_GUEST_BT_LE_SANITIZE:-1}" = 0 ] && bt_le=0
    if $BB awk -v SUM="$BTDIAG/sanitize.txt" -v LE="$bt_le" "$BT_AWK_FN$BT_SAN_AWK" "$1" > "$BTD/bt_config.conf.oneos-new" &&
       grep -q '^\[Adapter\]' "$BTD/bt_config.conf.oneos-new" &&
       chown 1002:1002 "$BTD/bt_config.conf.oneos-new" && chmod 0660 "$BTD/bt_config.conf.oneos-new" &&
       mv -f "$BTD/bt_config.conf.oneos-new" "$BTD/bt_config.conf"; then
        $BB chcon u:object_r:bluetooth_data_file:s0 "$BTD/bt_config.conf" 2>/dev/null || true
        return 0
    fi
    rm -f "$BTD/bt_config.conf.oneos-new" "$BTD/bt_config.conf" "$BTD/bt_config.bak"
    return 1
}
# Run 44: no import unless ONEOS_GUEST_BT_IMPORT=1 (see above).
bt_own=0
if [ "$GUEST_OPLUS" = 1 ]; then
    :
elif [ "${ONEOS_GUEST_BT_IMPORT:-0}" != 1 ]; then
    echo "Guest Bluetooth pairings: the guest's own; One UI's are not imported (its link keys are not in AOSP form; ONEOS_GUEST_BT_IMPORT=1 imports them)"
    bt_own=1
elif [ -L /data/misc/bluedroid ] || [ -L "$BTC" ] || [ ! -f "$BTC" ]; then
    echo "Guest Bluetooth pairings: One UI's bt_config.conf is missing or not a regular file; the guest's own stays"
    bt_own=1
elif [ -L "$BTD" ] || [ ! -d "$BTD" ]; then
    echo "WARNING: ${BTD#$STAGE/} is missing or a symlink; One UI's Bluetooth pairings not copied"
else
    mkdir -p "$BTDIAG"
    if [ -f "$BTD/bt_config.conf" ] && [ ! -L "$BTD/bt_config.conf" ]; then
        $BB awk "$BT_AWK_FN$BT_SHAPE_AWK" "$BTD/bt_config.conf" > "$BTDIAG/shape_guest_prev.txt" 2>&1
    fi
    $BB awk "$BT_AWK_FN$BT_SHAPE_AWK" "$BTC" > "$BTDIAG/shape_oneui.txt" 2>&1
    if bt_stage_conf "$BTC"; then
        echo "Guest Bluetooth pairings: One UI's imported (ONEOS_GUEST_BT_IMPORT=1), never copied back; $(cat "$BTDIAG/sanitize.txt" 2>/dev/null)"
    else
        echo "WARNING: One UI's Bluetooth pairings not imported (the checks failed, or no [Adapter]); the guest starts with no pairings"
    fi
fi
# The guest's own file gets the same checks (run 44 review): the stage's file
# from runs 43 and 44 still holds One UI's records, LE ones with the bad PIDs
# and BR/EDR ones with 64-hex link keys (the guest's stack saved what it had
# loaded), so with no import, or no file in One UI, they would come back. A
# file the Pixel stack wrote from its own pairings passes unchanged.
if [ $bt_own = 1 ] && [ ! -L "$BTD" ] && [ -d "$BTD" ] &&
   [ -f "$BTD/bt_config.conf" ] && [ ! -L "$BTD/bt_config.conf" ]; then
    mkdir -p "$BTDIAG"
    $BB awk "$BT_AWK_FN$BT_SHAPE_AWK" "$BTD/bt_config.conf" > "$BTDIAG/shape_guest_prev.txt" 2>&1
    if bt_stage_conf "$BTD/bt_config.conf"; then
        echo "Guest Bluetooth pairings: the guest's own after the checks; $(cat "$BTDIAG/sanitize.txt" 2>/dev/null)"
    else
        echo "WARNING: the guest's own Bluetooth pairings failed the checks (or have no [Adapter]); the guest starts with no pairings"
    fi
fi
# Which of the guest's own devices One UI has paired too (run 45). A device
# keeps one key for the phone's one Bluetooth address, so once One UI has
# paired it again (as asked after run 44), the guest's key for it is out of
# date: at its first connection in the guest it fails authentication and the
# stack asks to pair again (run 44's bond loss and pairing dialogs), and
# accepting unpairs it in One UI. Counted, with the last two address bytes as
# logcat shows them, and One UI's file's shape in diag_bt/shape_oneui.txt (no
# key value, no full address). One UI's file is only read, as for the import.
if [ $bt_own = 1 ] && [ ! -L /data/misc/bluedroid ] && [ ! -L "$BTC" ] && [ -f "$BTC" ] &&
   [ ! -L "$BTD" ] && [ -f "$BTD/bt_config.conf" ] && [ ! -L "$BTD/bt_config.conf" ]; then
    mkdir -p "$BTDIAG"
    $BB awk "$BT_AWK_FN$BT_SHAPE_AWK" "$BTC" > "$BTDIAG/shape_oneui.txt" 2>&1
    both=$($BB awk "$BT_AWK_FN"'FILENAME == ARGV[1] { if (isdev($0)) one[tolower($0)] = 1; next }
        isdev($0) { n++; if (tolower($0) in one) { b++; s = s ", xx:xx:xx:xx:" substr($0, 14, 5) } }
        END { printf "%d of the %d devices paired in the guest%s", b, n, (b ? " (" substr(s, 3) ")" : "") }' "$BTC" "$BTD/bt_config.conf" 2>/dev/null)
    echo "Guest Bluetooth pairings: ${both:-not compared}: also paired in One UI (if One UI paired one again after the guest did, the guest's key is out of date: a pairing request at its first connection in the guest, and accepting it unpairs it in One UI)"
fi

echo "=== 5d. Bridging host /data app and storage trees into the staged /data ==="
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
# OneOS: /data/data and /data/media as well. For user 0, installd's CE app data
# path is /data/data, not /data/user/0, and in run 25 the guest's
# destroyUserData(0) went through the host installd into One UI's real
# /data/data and /data/media. Host path:stage path.
# $BRIDGES comes from bridges.sh (sourced at the top).
for pair in $BRIDGES; do
    h=${pair%%:*}; s=${pair#*:}
    mkdir -p "$STAGE/data/$s" 2>/dev/null || true
    if [ -d "/data/$h" ] && ! mount | grep -q " /data/$h "; then
        $BB mount --bind "$STAGE/data/$s" "/data/$h" 2>/dev/null && echo "Bridged /data/$h -> $STAGE/data/$s"
    fi
done
# Every one of them must now be the staged copy, or the guest is not started.
unbridged=""
for pair in $BRIDGES; do
    h=${pair%%:*}; s=${pair#*:}
    [ -e "/data/$h" ] || continue
    [ "$(stat -c %d:%i "/data/$h" 2>/dev/null)" = "$(stat -c %d:%i "$STAGE/data/$s" 2>/dev/null)" ] || unbridged="$unbridged /data/$h"
done
if [ -n "$unbridged" ]; then
    echo "ERROR: not bridged to the staged copy:$unbridged; not starting the guest"
    exit 3
fi
echo "All host data trees bridged to the staged copies ($BRIDGES)"

mount | grep -q "$ROOTFS/data " || $BB mount --bind "$STAGE/data" "$ROOTFS/data"
# OneOS: private before anything is mounted beneath it. $STAGE/data lives on
# the host's shared /data, so this bind joins /data's peer group and the binds
# below propagated back into the host as /data/local/tmp/oneos/data/apex
# etc.: One UI's live /data/apex (its decompressed APEXes) showed up inside the
# stage tree, and One UI's APEXes read back with I/O errors afterwards.
$BB mount --make-private "$ROOTFS/data"
mount | grep -q "$ROOTFS/data/adb " || $BB mount --bind /data/adb "$ROOTFS/data/adb"
mount | grep -q "$ROOTFS/data/apex " || $BB mount --bind /data/apex "$ROOTFS/data/apex"
# OneOS: both read-only for the guest. /data/adb is the root manager's own
# (ksud, modules, allowlist); nothing the container runs has to write it now
# that guest_start.sh uses data/oneos_bin/busybox (takeover.log has both binds'
# options and the guest's su -c id). Only host apexd writes /data/apex, from
# One UI's namespace, which this bind does not change. remount,bind changes
# this one bind, never the /data filesystem; checked below: host /data must
# still be read-write. ONEOS_GUEST_DATA_ADB_RW=1 / ONEOS_GUEST_DATA_APEX_RW=1
# keep a bind writable (not with ONEOS_APP).
for d in adb apex; do
    case "$d" in
        adb) knob=ONEOS_GUEST_DATA_ADB_RW; keep=${ONEOS_GUEST_DATA_ADB_RW:-0} ;;
        *) knob=ONEOS_GUEST_DATA_APEX_RW; keep=${ONEOS_GUEST_DATA_APEX_RW:-0} ;;
    esac
    [ "$keep" = 1 ] && [ "${ONEOS_APP:-0}" != 1 ] && { echo "Host /data/$d stays writable in the guest ($knob=1)"; continue; }
    # With the source given: busybox looks a lone target up in /proc/mounts and
    # gives up ('can't find ... in /proc/mounts', run 36a). nosuid,nodev,noatime
    # again, or the remount drops them. Never toybox mount here: it answered
    # EBUSY, a superblock remount of /data, not of this bind.
    r=$($BB mount -o remount,bind,ro,nosuid,nodev,noatime "/data/$d" "$ROOTFS/data/$d" 2>&1) ||
        echo "remount of the /data/$d bind failed: $r"
    opts=$(awk -v p="$ROOTFS/data/$d" '$5 == p {print $6}' /proc/self/mountinfo | tail -n 1)
    case ",$opts," in
        *,ro,*) echo "Host /data/$d read-only in the guest" ;;
        *) echo "WARNING: host /data/$d stays writable in the guest (bind options: ${opts:-none})"
           # The root manager's data must not be writable from the guest.
           [ "$d" = adb ] && [ "${ONEOS_APP:-0}" = 1 ] && { echo "ERROR: not starting the guest with host /data/adb writable"; exit 3; } ;;
    esac
done
# The remounts must not have touched host /data itself (its own bind options
# and the filesystem's), or One UI's /data would be read-only.
DATA_MNT=$(awk '$5 == "/data" {print $6}' /proc/self/mountinfo | tail -n 1)
DATA_SB=$(awk '$5 == "/data" {print $NF}' /proc/self/mountinfo | tail -n 1)
DATA_BAD=""
case ",$DATA_MNT," in *,rw,*) ;; *) DATA_BAD=1 ;; esac
case ",$DATA_SB," in *,rw,*) ;; *) DATA_BAD=1 ;; esac
if [ -n "$DATA_BAD" ]; then
    echo "ERROR: host /data is not read-write any more ($DATA_MNT / $DATA_SB); not starting the guest (the return reboots)"
    exit 3
fi
# $ROOTFS/data/media is the staged $STAGE/data/media (section 5), not the
# phone's: the guest never gets the real shared storage.

echo "=== 5e. Writing per-package data-dir helper ==="
# Apps installed before the /data bridge existed have no CE/DE data dirs in the
# guest tree, and the guest zygote refuses to fork them:
#   Failed to mount /data_mirror/data_de/null/0/<pkg> to /data/user_de/0/<pkg>
# This helper recreates the dirs for every package the guest knows about, with
# the uid PMS reports. oneos_switch.sh runs it once the container is up.
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
            chown -h -R "$auid:$auid" "$d" 2>/dev/null
            chmod -R go-w "$d" 2>/dev/null
            realigned=$((realigned + 1))
        done
    done < /data/system/packages.list
fi
echo "[fix_app_dirs] realigned $realigned data dirs to their app uid"

# Navigation mode: ColorOS's SystemUI owns it (secure hide_navigationbar_enable,
# see the UI activator). Forcing the gestural overlay here kept ColorOS in
# 3-button mode with no buttons drawn (run 28). Only record the state.
echo "[fix_app_dirs] navigation: hide_navigationbar_enable=$(settings get secure hide_navigationbar_enable) navigation_mode=$(settings get secure navigation_mode)"

# OneOS: no SMS role write. OneLineage made LineageOS's com.android.messaging
# the default SMS app here on every boot; ColorOS has no such package (its own
# is com.android.mms) and keeps the user's choice.

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
# seconds after the guest boots and macOS stops seeing the phone at all. Turn it
# on so the gadget keeps adb, and read back what actually happened.
# OneOS: only when One UI has USB debugging on (guest_prepare.sh leaves
# /data/oneos_host_adb then).
if [ -f /data/oneos_host_adb ]; then
    adb_before=$(getprop sys.usb.state)
    settings put global adb_enabled 1 2>/dev/null
    sleep 2
    echo "[fix_app_dirs] adb_enabled=1 (usb.state was '$adb_before', now '$(getprop sys.usb.state)')"
fi

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
# inside the guest -- Play Store, Aurora, adb -- used to crash on launch this way.
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
                chown -h -R "$auid:$auid" "$p" 2>/dev/null && realigned=$((realigned + 1))
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
                chown -h -R "$auid:1078" "$p" 2>/dev/null && realigned=$((realigned + 1))
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
# while the guest is running instead of at boot only. Started by guest_start.
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
# Usable = an IPv4 address AND a carrier. After One UI stops, wlan0 keeps One
# UI's DHCP address with the link down (run 28: 192.168.x.y on a "linkdown"
# wlan0 all session); picking it sent all traffic to a dead link.
usable() {
    [ "$(cat "/sys/class/net/$1/carrier" 2>/dev/null)" = 1 ] &&
        ip -4 addr show "$1" 2>/dev/null | grep -q "inet "
}
iface=""
if usable wlan0; then
    iface=wlan0
else
    for d in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep '^rmnet_data'); do
        if usable "$d"; then iface=$d; break; fi
    done
fi
[ -z "$iface" ] && exit 0
subnet=$(ip route show table all 2>/dev/null | awk -v d="$iface" \
    '$2=="dev" && $3==d && $0 ~ /scope link/ && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\// {print $1; exit}')
[ -z "$subnet" ] && exit 0
gw=$(ip route show table all 2>/dev/null | awk -v d="$iface" \
    '$1=="default" && $2=="via" && $4=="dev" && $5==d && $3 ~ /^[0-9]+\./ {print $3; exit}')
case "$iface" in
    # Raw-IP link, no ARP: a device route is enough. Carriers hand out small
    # subnets (run 27: a /30), where a guessed ".1" gateway is not even inside.
    rmnet_data*) via="dev $iface" ;;
    # no IPv4 default anywhere (netd never installed one): assume the first host
    *) [ -z "$gw" ] && gw="${subnet%.*}.1"; via="via $gw dev $iface" ;;
esac
cur_if=$(ip route show table 4242 2>/dev/null | awk '$1=="default"{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [ "$cur_if" != "$iface" ]; then
    ip route flush table 4242 2>/dev/null
    echo "net route: table 4242 now uses $iface ($via), was ${cur_if:-none}"
fi
ip route replace "$subnet" dev "$iface" table 4242 2>/dev/null
ip route replace default $via table 4242 2>/dev/null
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
rm -f "$STAGE/payload_loops"
mount_payload() {
    NAME="$1"
    TARGET="$2"
    IMG="$STAGE/${NAME}_payload.img"
    DEST="$ROOTFS/apex/$TARGET"
    # OneOS: from the app, only the payloads it staged and files.sha256 lists.
    # Extracting one here would leave an unlisted *_payload.img that the next
    # preflight refuses (and nothing checks what it extracted).
    # The module under OPPO's (AOSP) file names or Google's mainline ones
    # (global and Pixel images; same com.android.<name> inside), as in
    # scripts/make-overlays.sh. The compressed layouts carry original_apex.
    SRC=""
    for f in com.android.${NAME}.apex com.android.${NAME}.capex com.google.android.${NAME}.apex \
             com.google.android.${NAME}_compressed.apex com.google.android.${NAME}_tplus_compressed.apex; do
        [ -f "$ROOTFS/system/apex/$f" ] && { SRC="$ROOTFS/system/apex/$f"; break; }
    done
    # The cell broadcast service shares android.uid.networkstack with
    # tethering (always One UI's Google-signed module, see the list below) and
    # NetworkStack (One UI's NetworkStackGoogle, after section 9). A module built from source
    # (com.android.cellbroadcast.*: Infinity-X) is signed with the build's own
    # networkstack key, so system_server died in its first package scan (S25
    # Ultra session 26ea59af: "Signature mismatch on system package
    # com.android.cellbroadcastservice for shared user android.uid.networkstack").
    # The guest keeps One UI's module then, staged or not; Google's own (Pixel,
    # the X9U IN) is mounted as before.
    if [ "$NAME" = cellbroadcast ]; then
        case "$SRC" in
            */com.android.cellbroadcast.apex|*/com.android.cellbroadcast.capex)
                echo "cellbroadcast: the image's ${SRC##*/} is built from source, not Google's; One UI's module stays (android.uid.networkstack has one signer)"
                return 0 ;;
        esac
    fi
    if [ ! -f "$IMG" ] && [ "${ONEOS_APP:-0}" = 1 ]; then
        if [ -n "$SRC" ]; then
            echo "ERROR: the image has ${SRC##*/} but no ${NAME}_payload.img was staged; not starting the guest"
            exit 3
        fi
        return 0
    fi
    if [ ! -f "$IMG" ] && [ -n "$SRC" ]; then
        if $BB unzip -l "$SRC" 2>/dev/null | grep -q ' original_apex$'; then
            $BB unzip -p "$SRC" original_apex > "$STAGE/temp_${NAME}.apex" 2>/dev/null
            $BB unzip -p "$STAGE/temp_${NAME}.apex" apex_payload.img > "$IMG" 2>/dev/null
            rm -f "$STAGE/temp_${NAME}.apex"
        else
            $BB unzip -p "$SRC" apex_payload.img > "$IMG" 2>/dev/null
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
    # Read-only like system.raw: an ext4 payload mounted ro could still have
    # its journal replayed into the staged file (files.sha256).
    $BB losetup -r "$LOOP" "$IMG"
    # ColorOS ships erofs payloads; OneLineage assumed ext4.
    FSTYPE=ext4
    [ "$(od -An -tx4 -j1024 -N4 "$IMG" 2>/dev/null | tr -d ' ')" = "e0f5e1e2" ] && FSTYPE=erofs
    if ! $BB mount -t "$FSTYPE" -o ro "$LOOP" "$DEST"; then
        echo "!!! could not mount $NAME ($FSTYPE) from $IMG"
        $BB losetup -d "$LOOP" 2>/dev/null
        return 0
    fi
    echo "Direct mounted $NAME ($FSTYPE) on $LOOP -> $DEST"
    echo "$TARGET $LOOP $FSTYPE" >> "$STAGE/payload_loops"
    for vdir in "$ROOTFS/apex/${TARGET}"@*; do
        if [ -d "$vdir" ]; then
       $BB umount -l "$vdir" 2>/dev/null || true
       $BB mount -t "$FSTYPE" -o ro "$LOOP" "$vdir"
       echo "Direct mounted $NAME on $LOOP -> $vdir"
        fi
    done
}

mount_payload "art" "com.android.art"
mount_payload "i18n" "com.android.i18n"
mount_payload "runtime" "com.android.runtime"
mount_payload "sdkext" "com.android.sdkext"
mount_payload "nfcservices" "com.android.nfcservices"
# OneOS: tethering stays the HOST's module. Its BPF programs and maps were
# loaded at boot by the host's bpfloader for that module version; ColorOS's own
# connectivity module expects maps the host never pinned
# (map_netd_uid_permission_map and 7 more) and NetworkStatsService died on
# "Cannot open uid permission map". The rest of the networkstack shared-user
# group follows below.
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
# The image's own copies of modules One UI's build cannot serve it, only when
# make-overlays.sh staged them (Pixel: android.telecom lives in telephonycore;
# conscrypt and profiling match its ART and framework). Never extracted here.
for m in telephonycore conscrypt profiling; do
    [ -f "$STAGE/${m}_payload.img" ] && mount_payload "$m" "com.android.$m"
done
# Google Play services (GMS_WANT, top): the image's own gmssystem payload, a
# Google module name, so not com.android.<name>. mount_payload looks for the
# APEX itself only in system/apex (Pixel's is in product/apex), so the staged
# payload is what it mounts. The payload_loops pass after section 9 puts it on
# the @<version> dirs too: the guest never reads One UI's own gmssystem module.
if [ "$GMS_WANT" = 1 ]; then
    mount_payload "gmssystem" "com.google.android.gmssystem"
fi

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

# OneOS: the versioned dirs (com.android.tethering@<version>, the paths host
# apexd reports to the guest's PackageManagerService) only exist now, so
# mount_payload's own @-loop never matched and they got the HOST's module from
# the binds above. The guest then saw its own NetworkStack next to Samsung's
# tethering APK: "Signature mismatch on system package
# com.google.android.networkstack.tethering for shared user
# android.uid.networkstack". Put the guest payload on them too.
if [ -f "$STAGE/payload_loops" ]; then
    while read -r TARGET LOOP FSTYPE; do
        for vdir in "$ROOTFS/apex/${TARGET}"@*; do
            [ -d "$vdir" ] || continue
            $BB umount -l "$vdir" 2>/dev/null || true
            $BB mount -t "${FSTYPE:-ext4}" -o ro "$LOOP" "$vdir" && echo "Guest payload $TARGET on $LOOP -> $vdir"
        done
    done < "$STAGE/payload_loops"
fi

# Wi-Fi (run 41): Pixel's wifi module uses the mainline supplicant when its RRO
# sets config_wifiMainlineSupplicantEnabled, the SDK is 37+ and
# /apex/com.android.wifi/bin/wpa_supplicant_mainline is a file. The HOST's init
# then starts that daemon from One UI's wifi APEX, in One UI's namespace and
# /data, without Samsung's overlay conf: P2P lands on wlan0 and addStaInterface
# fails (code 1, "ISupplicantStaIface.addIface failed"). Without the file the
# guest takes Samsung's ISupplicant/default, as ColorOS does. Only the guest's
# own payload mounts are covered (bin/ holds nothing else).
# ONEOS_GUEST_MAINLINE_SUPPLICANT=1 keeps it.
if [ "${ONEOS_GUEST_MAINLINE_SUPPLICANT:-0}" != 1 ]; then
    for d in "$ROOTFS/apex/com.android.wifi" "$ROOTFS/apex/com.android.wifi"@*; do
        [ -f "$d/bin/wpa_supplicant_mainline" ] || continue
        $BB mount --make-private "$d" 2>/dev/null || { echo "!!! could not make $d private, leaving it alone"; continue; }
        $BB mount -t tmpfs -o ro,size=4k,mode=755 tmpfs "$d/bin" &&
            echo "Hid wpa_supplicant_mainline in $(basename "$d"): the guest uses the vendor supplicant"
    done
fi

# OneOS: modules the guest ships as plain system apps instead of APEXes
# (ColorOS: CellBroadcastService, NfcNci, Bluetooth). The host's APEX copies of
# those apps are Google-signed and collide with the guest's OPPO-signed ones
# ("Signature mismatch on system package com.google.android.cellbroadcastservice
# for shared user android.uid.networkstack"). Hide only their app dirs; the
# javalib/lib dirs stay, the boot class path references them. Each bind is made
# private first: it is still a shared peer of the host's /apex mount here, and
# a mount inside it would otherwise propagate into One UI's own APEX.
for m in com.android.nfcservices com.android.bt; do
    [ -f "$STAGE/${m#com.android.}_payload.img" ] && continue
    for d in "$ROOTFS/apex/$m" "$ROOTFS/apex/$m"@*; do
        [ -d "$d" ] || continue
        $BB mount --make-private "$d" 2>/dev/null || { echo "!!! could not make $d private, leaving it alone"; continue; }
        for sub in app priv-app; do
            [ -d "$d/$sub" ] || continue
            $BB mount -t tmpfs -o ro,size=4k,mode=755 tmpfs "$d/$sub" && echo "Hid host $m/$sub in $(basename "$d")"
        done
    done
done

# Play services from One UI's copy in my_product (guest_google.sh prepare wrote
# google_apps/active): hide One UI's own GmsCore in the gmssystem APEX bind, so
# the guest's package manager finds Play services once, where the image's
# privapp-permissions-google-product.xml grants it. Private first, as above.
if [ -f "$STAGE/google_apps/active" ]; then
    for d in "$ROOTFS/apex/com.google.android.gmssystem" "$ROOTFS/apex/com.google.android.gmssystem"@*; do
        [ -d "$d/priv-app" ] || continue
        $BB mount --make-private "$d" 2>/dev/null || { echo "!!! could not make $d private, leaving it alone"; continue; }
        $BB mount -t tmpfs -o ro,size=4k,mode=755 tmpfs "$d/priv-app" &&
            echo "Hid host com.google.android.gmssystem/priv-app in $(basename "$d") (Play services from One UI's copy in my_product)"
    done
fi

# The android.uid.networkstack group has to come from one signer. With the
# host's tethering (Google-signed) and cellbroadcast APEXes kept, use the
# host's NetworkStackGoogle and CaptivePortalLoginGoogle in place of ColorOS's
# OPPO-signed NetworkStack and CaptivePortalLogin, and hide ColorOS's own
# CellBroadcastService.
bind_host_app() {
    [ -d "$1" ] && [ -d "$2" ] || { echo "!!! cannot replace $2 with $1"; return 0; }
    $BB mount --bind "$1" "$2" && echo "Host $(basename "$1") -> $2"
}
bind_host_app /system/priv-app/NetworkStackGoogle "$ROOTFS/system/priv-app/NetworkStack"
bind_host_app /system/app/CaptivePortalLoginGoogle "$ROOTFS/system/app/CaptivePortalLogin"
if [ -d "$GUEST_SYSTEM_EXT/priv-app/CellBroadcastService" ]; then
    $BB mount -t tmpfs -o ro,size=4k,mode=755 tmpfs "$GUEST_SYSTEM_EXT/priv-app/CellBroadcastService" && \
        echo "Hid guest system_ext/priv-app/CellBroadcastService"
fi
# Pixel's PersistentBackgroundCameraServices registers three binder services
# that only Pixel's own VINTF manifest declares; the shared servicemanager checks
# One UI's and throws "VINTF declaration error", and the app is persistent: run
# 41, 9006 crashes in 6 minutes (a zygote fork every 40 ms, and a listener on One
# UI's cameraserver each time). Pixel's camera HAL is not here anyway.
if [ -d "$GUEST_SYSTEM_EXT/app/PersistentBackgroundCameraServices" ]; then
    $BB mount -t tmpfs -o ro,size=4k,mode=755 tmpfs "$GUEST_SYSTEM_EXT/app/PersistentBackgroundCameraServices" && \
        echo "Hid guest system_ext/app/PersistentBackgroundCameraServices (services only Pixel's VINTF declares)"
fi
# Pixel's ConnectivityThermalPowerManager throttles the Pixel modem and Wi-Fi
# through GRIL when the phone warms up. Here the modem is Samsung's and GRIL is
# not in the image: from the first LIGHT thermal status on, each throttling
# request came back "modem does not support data throttling" and crashed the
# app, which is persistent: S25 Ultra Pixel 9 Pro XL session af6c2b17, 1394
# crashes in 15 minutes (a zygote fork every 0.6 s at full CPU clock, skin
# 54 C).
if [ -d "$GUEST_SYSTEM_EXT/priv-app/ConnectivityThermalPowerManager" ] && \
   [ ! -L "$GUEST_SYSTEM_EXT/priv-app/ConnectivityThermalPowerManager" ]; then
    $BB mount -t tmpfs -o ro,size=4k,mode=755 tmpfs "$GUEST_SYSTEM_EXT/priv-app/ConnectivityThermalPowerManager" && \
        echo "Hid guest system_ext/priv-app/ConnectivityThermalPowerManager (Pixel modem throttling; crash loop on a Samsung modem)"
fi
# The phone's eSIM chip is shared hardware, and an eSIM manager (LPA) in the
# guest drives it directly: Pixel's EuiccGoogle opens the chip's ISD-R channel
# itself (run 43). A guest factory reset with "Erase eSIMs", Reset mobile
# network settings with "Erase downloaded SIMs", Erase SIM in the guest's SIM
# settings, or Find My Device's remote erase once a Google account is signed
# in, would delete One UI's eSIM profiles for good (the BCB and FRP guards
# stop the rest of such a wipe, not this part). Without an LPA the guest still
# uses the eSIM One UI left enabled (the modem runs it like a SIM card: calls,
# SMS, data); it cannot download, switch or erase profiles, and Settings hides
# those options. Every Euicc* app folder but RROs and permission-only
# packages: Pixel's product EuiccGoogle and system_ext EuiccSupportPixel-P23,
# the Find X9 Ultra's my_product EuiccOplus (the Find N6 has none).
# ONEOS_GUEST_ESIM_MANAGER=1 keeps them.
if [ "${ONEOS_GUEST_ESIM_MANAGER:-0}" != 1 ]; then
    for d in "$ROOTFS"/system/priv-app/Euicc* "$ROOTFS"/system/app/Euicc* \
             "$GUEST_PRODUCT"/priv-app/Euicc* "$GUEST_PRODUCT"/app/Euicc* \
             "$GUEST_SYSTEM_EXT"/priv-app/Euicc* "$GUEST_SYSTEM_EXT"/app/Euicc* \
             "$ROOTFS"/my_*/priv-app/Euicc* "$ROOTFS"/my_*/app/Euicc*; do
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        case ${d##*/} in *Overlay|*Permissions) continue ;; esac
        $BB mount -t tmpfs -o ro,size=4k,mode=755 tmpfs "$d" && \
            echo "Hid guest ${d#"$ROOTFS"/} (eSIM manager: the eSIM chip is One UI's; ONEOS_GUEST_ESIM_MANAGER=1 keeps it)"
    done
fi
# Google Play services (GMS_WANT, top; docs/pixel-guest.md). GmsCore is
# presented as a plain product priv-app, as Pixels had it before Android 17,
# and the image is not changed: a small tmpfs package folder ($STAGE/gmscore,
# labelled system_file, read-only once filled) holds the APK, bound from the
# guest's own gmssystem payload (section 8, checked to be the guest's loop
# device, never One UI's module), and the image's own app_chimera and m
# (GmsCore's Dynamite modules, which it looks for next to its APK), and is
# bound over system/product/priv-app/PrebuiltGmsCore. The image already
# allowlists GmsCore's privileged permissions (product
# privapp-permissions-google-p.xml) and its user types
# (preinstalled-packages-product-pixel-2017-and-newer.xml). The payload's own
# priv-app folder is then hidden in every mount of it, so the package manager
# can find GmsCore only once. Everything here mounts the guest's own files; the
# tmpfs on $STAGE/gmscore sits in One UI's shared /data and is made private
# right after it is mounted, so the binds made into it stay in the stage;
# return_to_oneui.sh unmounts it with the rest of the stage, deepest first,
# and its reboot frees the loop device. Anything unexpected stops the session
# (exit 3) before or instead of a half-made folder: ONEOS_GUEST_GMS=0 starts
# without Google services. data/oneos_gms_present tells the UI activator.
mount_source() { # <mount point>: the source of the topmost mount there
    awk -v p="$1" '$5 == p { s = ""; for (i = 7; i < NF; i++) if ($i == "-") { s = $(i + 2); break } } END { print s }' /proc/self/mountinfo
}
loop_devnum() { # <loop device node>: its major:minor (the nodes made in section 2 need not match the kernel's names)
    _lb=$(stat -L -c '%t %T' "$1" 2>/dev/null) || return 1
    set -- $_lb
    printf '%d:%d' "0x$1" "0x$2"
}
on_gms_loop() { # <mount point>: the topmost mount there is the guest's gmssystem loop device (by name or number)
    awk -v p="$1" -v l="$GMS_LOOP" -v d="$GMS_LOOP_DEV" '$5 == p { s = ""; for (i = 7; i < NF; i++) if ($i == "-") { s = $(i + 2); break }
        ok = (s == l || (d != "" && $3 == d)) } END { exit !ok }' /proc/self/mountinfo
}
if [ "$GMS_WANT" = 1 ]; then
    gms_refuse() {
        echo "ERROR: Google services: $*; not starting the guest (ONEOS_GUEST_GMS=0 starts without them)"
        exit 3
    }
    GMS_APEX="$ROOTFS/apex/com.google.android.gmssystem"
    GMS_DIR="$GUEST_PRODUCT/priv-app/PrebuiltGmsCore"
    GMS_PKG="$STAGE/gmscore"
    # 1. The payload is the guest's: its loop device (payload_loops, written by
    #    mount_payload), backed by the staged payload, on top at the APEX path.
    GMS_LOOP=$(awk '$1 == "com.google.android.gmssystem" { l = $2 } END { print l }' "$STAGE/payload_loops" 2>/dev/null)
    [ -n "$GMS_LOOP" ] || gms_refuse "gmssystem_payload.img was not mounted (section 8)"
    GMS_LOOP_DEV=$(loop_devnum "$GMS_LOOP")
    on_gms_loop "$GMS_APEX" ||
        gms_refuse "${GMS_APEX#$ROOTFS} is mounted from $(mount_source "$GMS_APEX"), not the guest's $GMS_LOOP ($GMS_LOOP_DEV)"
    g_bf=$(cat "/sys/dev/block/$GMS_LOOP_DEV/loop/backing_file" 2>/dev/null)
    [ -n "$GMS_LOOP_DEV" ] && [ "$g_bf" = "$STAGE/gmssystem_payload.img" ] ||
        gms_refuse "$GMS_LOOP (${GMS_LOOP_DEV:-no device}) is backed by ${g_bf:-nothing}, not $STAGE/gmssystem_payload.img"
    # Its @<version> dirs too (the payload_loops pass): one still on One UI's
    # module would show One UI's GmsCore to the guest, and a mount inside it
    # would reach One UI's own /apex.
    for g_d in "$GMS_APEX"@*; do
        [ -d "$g_d" ] || continue
        on_gms_loop "$g_d" || gms_refuse "${g_d#$ROOTFS} is mounted from $(mount_source "$g_d"), not the guest's $GMS_LOOP"
    done
    echo "Google services: payload ${GMS_APEX#$ROOTFS} (and its @ dirs) on $GMS_LOOP ($g_bf)"
    # 2. Exactly one GmsCore APK in it.
    GMS_APK_SRC=""; g_n=0
    for g_a in "$GMS_APEX"/priv-app/PrebuiltGmsCore*/PrebuiltGmsCore*.apk; do
        [ -f "$g_a" ] && [ ! -L "$g_a" ] || continue
        GMS_APK_SRC=$g_a; g_n=$((g_n + 1))
    done
    [ "$g_n" = 1 ] || gms_refuse "$g_n PrebuiltGmsCore APKs in the gmssystem payload (one expected)"
    GMS_APK_NAME=${GMS_APK_SRC##*/}
    echo "Google services: GmsCore ${GMS_APK_SRC#$GMS_APEX/} ($(stat -c %s "$GMS_APK_SRC") bytes)"
    # 3. The image's PrebuiltGmsCore folder: a real folder of the image (no link
    #    anywhere on the path: it would lead to One UI's own /product), with
    #    app_chimera and m, and no APK of its own.
    [ -d "$GMS_DIR" ] && [ "$(readlink -f "$GMS_DIR")" = "$GMS_DIR" ] ||
        gms_refuse "${GMS_DIR#$ROOTFS} is missing or reached through a link"
    for g_s in app_chimera m; do
        [ -d "$GMS_DIR/$g_s" ] && [ ! -L "$GMS_DIR/$g_s" ] ||
            gms_refuse "the image has no ${GMS_DIR#$ROOTFS}/$g_s (GmsCore's Dynamite modules)"
    done
    for g_a in "$GMS_DIR"/*.apk; do
        [ -e "$g_a" ] || [ -L "$g_a" ] || continue
        gms_refuse "the image already has ${g_a#$ROOTFS} (GmsCore would be there twice)"
    done
    [ -n "$(mount_source "$GMS_DIR")" ] && gms_refuse "${GMS_DIR#$ROOTFS} is already a mount point"
    # 4. The package folder: a tmpfs under the stage (never under the staged
    #    /data, whose tree is rewritten every session), labelled like the image.
    [ -L "$GMS_PKG" ] && rm -f "$GMS_PKG"
    mkdir -p "$GMS_PKG" && [ -d "$GMS_PKG" ] && [ ! -L "$GMS_PKG" ] || gms_refuse "could not create $GMS_PKG"
    [ -n "$(mount_source "$GMS_PKG")" ] && gms_refuse "$GMS_PKG is already a mount point"
    g_label=mount
    if ! $BB mount -t tmpfs -o size=64k,mode=755,context=u:object_r:system_file:s0 tmpfs "$GMS_PKG" 2>/dev/null; then
        $BB mount -t tmpfs -o size=64k,mode=755 tmpfs "$GMS_PKG" || gms_refuse "could not mount a tmpfs on $GMS_PKG"
        g_label=chcon
    fi
    # Private at once: the stage sits on One UI's shared /data mount.
    $BB mount --make-private "$GMS_PKG" 2>/dev/null || gms_refuse "could not make $GMS_PKG private"
    echo "Google services: tmpfs package folder $GMS_PKG (label by $g_label)"
    mkdir "$GMS_PKG/app_chimera" "$GMS_PKG/m" && : > "$GMS_PKG/$GMS_APK_NAME" &&
        chmod 755 "$GMS_PKG/app_chimera" "$GMS_PKG/m" && chmod 644 "$GMS_PKG/$GMS_APK_NAME" ||
        gms_refuse "could not fill $GMS_PKG"
    if [ "$g_label" = chcon ]; then
        $BB chcon -R u:object_r:system_file:s0 "$GMS_PKG" 2>/dev/null || gms_refuse "could not label $GMS_PKG system_file"
    fi
    $BB mount --bind "$GMS_APK_SRC" "$GMS_PKG/$GMS_APK_NAME" || gms_refuse "could not bind the GmsCore APK"
    echo "Google services: bound ${GMS_APK_SRC#$ROOTFS} -> $GMS_PKG/$GMS_APK_NAME"
    for g_s in app_chimera m; do
        $BB mount --bind "$GMS_DIR/$g_s" "$GMS_PKG/$g_s" || gms_refuse "could not bind ${GMS_DIR#$ROOTFS}/$g_s"
        echo "Google services: bound ${GMS_DIR#$ROOTFS}/$g_s -> $GMS_PKG/$g_s"
    done
    $BB mount -o remount,ro "$GMS_PKG" 2>/dev/null && echo "Google services: $GMS_PKG read-only" ||
        echo "!!! Google services: could not make $GMS_PKG read-only (its contents are: an erofs APK and the read-only image's folders)"
    # 5. Over the image's folder, recursively (the three binds come along).
    $BB mount --rbind "$GMS_PKG" "$GMS_DIR" || gms_refuse "could not bind $GMS_PKG over ${GMS_DIR#$ROOTFS}"
    $BB mount --make-rprivate "$GMS_DIR" 2>/dev/null || gms_refuse "could not make ${GMS_DIR#$ROOTFS} private"
    [ "$(stat -c %s "$GMS_DIR/$GMS_APK_NAME" 2>/dev/null)" = "$(stat -c %s "$GMS_APK_SRC")" ] && [ -d "$GMS_DIR/app_chimera/m" ] ||
        gms_refuse "${GMS_DIR#$ROOTFS} does not show the APK and app_chimera after the bind"
    echo "Google services: bound $GMS_PKG -> ${GMS_DIR#$ROOTFS} ($GMS_APK_NAME, app_chimera, m)"
    # 6. The payload's own priv-app folder, hidden in each mount of the payload
    #    (each checked again to be the guest's loop device, as in 1).
    g_hid=0
    for g_d in "$GMS_APEX" "$GMS_APEX"@*; do
        [ -d "$g_d/priv-app" ] || continue
        on_gms_loop "$g_d" || gms_refuse "${g_d#$ROOTFS} is mounted from $(mount_source "$g_d"), not the guest's $GMS_LOOP"
        $BB mount --make-private "$g_d" 2>/dev/null || gms_refuse "could not make ${g_d#$ROOTFS} private"
        $BB mount -t tmpfs -o ro,size=4k,mode=755 tmpfs "$g_d/priv-app" || gms_refuse "could not hide ${g_d#$ROOTFS}/priv-app"
        echo "Google services: hid ${g_d#$ROOTFS}/priv-app (GmsCore is found once, in product)"
        g_hid=$((g_hid + 1))
    done
    [ "$g_hid" -ge 1 ] || gms_refuse "no priv-app folder in ${GMS_APEX#$ROOTFS} to hide"
    rm -f "$STAGE/data/oneos_gms_present"
    echo "$GMS_APK_NAME $(stat -c %s "$GMS_DIR/$GMS_APK_NAME")" > "$STAGE/data/oneos_gms_present"
    echo "Google services presented: /system/product/priv-app/PrebuiltGmsCore/$GMS_APK_NAME (Pixel's setup wizard runs until it is finished)"
fi
# Google services in a global image (the Find X9 Ultra IN has Play services, the
# Play Store and their setup/restore helpers in my_product/priv-app).
# ONEOS_GUEST_HIDE_GMS=1 hides them for the session the same way: an empty
# read-only tmpfs over each folder, the image unchanged, so ColorOS's package
# manager never sees them and nothing Google signs in, restores or keeps keys
# there. For the first runs of such an image; off by default (owner: once a run
# with them on works, they stay on). Pixel's folders carry other names, some
# with a version (PrebuiltGmsCore, PartnerSetupPrebuilt,
# GoogleRestorePrebuilt-v<n>, product/app/PlayAutoInstallConfig_<key>, and
# Google Services Framework in system_ext), hence the patterns.
if [ "${ONEOS_GUEST_HIDE_GMS:-0}" = 1 ]; then
    hid=0
    for a in GmsCore PrebuiltGmsCore Phonesky GooglePartnerSetup PartnerSetupPrebuilt 'GoogleRestore*' \
             ConfigUpdater 'PlayAutoInstallConfig*' GoogleServicesFramework; do
        for d in "$ROOTFS/my_product/priv-app/"$a "$ROOTFS/system/priv-app/"$a "$GUEST_PRODUCT/priv-app/"$a \
                 "$GUEST_PRODUCT/app/"$a "$GUEST_SYSTEM_EXT/priv-app/"$a; do
            [ -d "$d" ] && [ ! -L "$d" ] || continue
            $BB mount -t tmpfs -o ro,size=4k,mode=755 tmpfs "$d" && { echo "Hid guest ${d#$ROOTFS/} (ONEOS_GUEST_HIDE_GMS=1)"; hid=$((hid + 1)); }
        done
    done
    echo "Google services hidden in the guest: $hid folder(s)"
fi
# Google's split permissions without Google Play services. Pixel's
# product/etc/permissions/split-permissions-google.xml (the X9U IN has one in
# my_product) splits com.google.android.gms.permission.ACTIVITY_RECOGNITION,
# which only GmsCore declares. Android 17's permission service throws on a
# split whose source nobody declares, and system_server died in
# PackageManagerService.<init> (run 38... run 39: "Unknown source permission
# com.google.android.gms.permission.ACTIVITY_RECOGNITION in split permissions").
# Pixel's GmsCore APK is in a product APEX the phone's apexd never activates,
# and ONEOS_GUEST_HIDE_GMS hides the others. So when the guest has no GmsCore
# APK, each such file is bound from a stage copy without the gms splits; the
# image is unchanged. Stale binds of a former session come off first: only this
# filter's own (oneos_split_*.xml). Up to 0.4.14 every bind on a permissions
# XML came off here, the ColorOS feature list bound above (FEAT) with them, so
# none of its additions reached a session (pull request #1, Z Fold8).
SPLIT_DIRS="$ROOTFS/system/etc/permissions $GUEST_PRODUCT/etc/permissions $GUEST_SYSTEM_EXT/etc/permissions $ROOTFS/my_product/etc/permissions"
for d in $SPLIT_DIRS; do
    for f in "$d"/*.xml; do
        [ -f "$f" ] || continue
        # Remove only this filter's bind, not ColorOS feature or other XML
        # overrides mounted earlier in prepare. On /data's filesystem the
        # mount root omits the /data prefix; retain support for both forms.
        split_source=$(awk -v target="$f" '$5 == target { source = $4 } END { print source }' /proc/self/mountinfo)
        case "$split_source" in
            "$STAGE"/oneos_split_*.xml|"${STAGE#/data}"/oneos_split_*.xml)
                split_id=${split_source##*/oneos_split_}; split_id=${split_id%.xml}
                case "$split_id" in ''|*[!0-9]*) continue ;; esac
                $BB umount -l "$f" 2>/dev/null
                ;;
        esac
    done
done
rm -f "$STAGE"/oneos_split_*.xml
GMS_APK=0
for a in "$ROOTFS"/my_product/priv-app/*GmsCore*/*.apk "$ROOTFS"/system/priv-app/*GmsCore*/*.apk \
         "$GUEST_PRODUCT"/priv-app/*GmsCore*/*.apk "$GUEST_SYSTEM_EXT"/priv-app/*GmsCore*/*.apk; do
    [ -f "$a" ] && GMS_APK=1
done
if [ "$GMS_APK" = 0 ]; then
    n=0
    for d in $SPLIT_DIRS; do
        for f in "$d"/*.xml; do
            [ -f "$f" ] && [ ! -L "$f" ] && grep -q '<split-permission[^>]*name="com.google.android.gms\.' "$f" || continue
            n=$((n + 1))
            c="$STAGE/oneos_split_$n.xml"
            # Whole <split-permission ...> ... </split-permission> blocks (or a
            # self-closed one) whose source is a gms permission.
            awk 'skip == 0 && /<split-permission[^>]*name="com\.google\.android\.gms\./ {
                     if ($0 !~ /\/>[[:space:]]*$/ && $0 !~ /<\/split-permission>/) skip = 1
                     next }
                 skip == 1 { if ($0 ~ /<\/split-permission>/) skip = 0; next }
                 { print }' "$f" > "$c" &&
                grep -q '</permissions>' "$c" && ! grep -q 'name="com.google.android.gms\.' "$c" || {
                echo "!!! could not filter ${f#$ROOTFS/}, left as it is"; rm -f "$c"; continue; }
            chmod 644 "$c"
            # A stage copy, not host data: labelled like the system file it replaces.
            $BB chcon u:object_r:system_file:s0 "$c" 2>/dev/null || true
            $BB mount --bind "$c" "$f" &&
                echo "Bound ${f#$ROOTFS/} without its gms split permissions (no GmsCore in the guest)"
        done
    done
    [ "$n" = 0 ] && echo "No GmsCore in the guest; no gms split permissions to drop"
fi
# OPPO region overlays in a global image (the Find X9 Ultra IN keeps them in
# my_product/cust/<region>/overlay, one folder per region). OPPO's own first
# stage maps the phone's region onto an allowed path; the container does not
# run it, so ColorOS's package manager finds them at the raw path, the zygote
# opens one while preloading, and its file-descriptor allowlist (fd_utils in
# libandroid_runtime: /my_product/overlay yes, /my_product/cust no) aborts the
# fork of system_server. Run 37 (IN on the Fold): "JNI FatalError called:
# (system_server) Not allowlisted (72): /my_product/cust/IN/overlay/
# GmsConfigOverlaySearchSelector/...", then zygote gone and the auto-return.
# Hidden for the session like the folders above (the region's dialer, contacts
# and Google config tweaks do not apply). The N6 and X9U CN images have
# my_product/cust/<region> folders but no overlay folder in any of them (checked
# with debugfs), so this finds nothing there; the IN image has 24.
# ONEOS_GUEST_REGION_OVERLAYS=1 keeps them (adb loop only: the abort above).
if [ "${ONEOS_GUEST_REGION_OVERLAYS:-0}" != 1 ] || [ "${ONEOS_APP:-0}" = 1 ]; then
    hid=0
    for d in "$ROOTFS"/my_product/cust/*/overlay; do
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        $BB mount -t tmpfs -o ro,size=4k,mode=755 tmpfs "$d" && hid=$((hid + 1))
    done
    [ "$hid" = 0 ] || echo "OPPO region overlays hidden in the guest: $hid my_product/cust/*/overlay folder(s) (outside the zygote's allowlist)"
fi

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

# OneOS: make every mount under the rootfs private. The binds of /apex/*,
# /linkerconfig, /mnt etc. inherit the host's shared propagation, so the
# unmounts on the way back to One UI propagated to the HOST's own mounts: One
# UI came back without its wifi APEX contents (WifiService NPE on its
# resources, system_server boot loop, reboot). A private bind does not change
# the source mount.
$BB mount --make-rprivate "$ROOTFS" 2>/dev/null || true

# Nothing of the guest on One UI's own partitions (host_part_mounts, top).
host_part_mounts > "$STAGE/host_part_mounts.after"
LEAKED=$(awk 'NR == FNR { b[$0] = 1; next } !($0 in b)' "$STAGE/host_part_mounts.before" "$STAGE/host_part_mounts.after")
if [ -n "$LEAKED" ]; then
    echo "ERROR: the setup mounted over One UI's own partitions:" $LEAKED
    for m in $(echo "$LEAKED" | sort -r); do $BB umount -l "$m" 2>/dev/null && echo "  unmounted $m"; done
    echo "Not starting the guest"
    exit 3
fi
echo "One UI's partitions: no mount added by the setup"

echo "=== ALL MOUNTS PREPARED SUCCESSFULLY ==="
