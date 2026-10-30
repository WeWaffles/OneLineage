#!/bin/sh
# Push a built GSI and the switcher scripts to the phone's stage directory.
# Needs root on the phone (KernelSU su). Nothing is flashed: everything lives
# under /data/local/tmp/oneos and is removed by deleting that dir.
#
# Up to OneOS 0.3.6 the stage was /data/local/tmp/lineage_stage (and its
# copies lineage_stage.old-<epoch>): before anything is pushed into the stage,
# scripts/stage-migrate.sh renames them on the phone to the OneOS names, only
# while they are idle (the app's root script does the same); a stage that
# cannot be renamed yet stops the deploy.
#
# The adb tunnel is slow (~1 MB/s), so the image travels gzipped and is
# unpacked on the phone. A system.raw.gz already in the incoming dir with the
# right size is reused, so an interrupted deploy does not push it again.
#
# An image.gz the phone already downloaded itself (e.g. rsync in Termux) can be
# used instead of pushing: set ON_PHONE_GZ=/sdcard/Download/<name>.img.gz.
#
# The framework overlays come from out/overlays (make-overlays.sh for the Find
# N6 image) unless --overlays (or OVERLAYS=) names another set, e.g.
# out/overlays_x9u for the Find X9 Ultra image. A set's guards.txt only vouches
# for its own jars, so the set must be the one built from the image deployed.
#
# Overlays the stage has but the set does not (a ColorOS set's
# surfaceflinger_patched or APEX payloads before a Pixel image, say) are moved
# to $STAGE/attic/<epoch>/: guest_prepare.sh would bind them. So do the session
# scripts' names up to 0.3.6 (switch_to_lineage.sh, master_prepare.sh,
# master_inner.sh: now oneos_switch.sh, guest_prepare.sh, guest_start.sh).
#
# --fresh moves the whole stage aside first (oneos.old-<epoch>, which the
# OneOS app lists under Old copies and can delete): another system needs its
# own /data, not the last one's.
#
# Usage: scripts/deploy-phone.sh [--fresh] [--overlays <dir>] <system.img> | --scripts-only
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SERIAL="${ANDROID_SERIAL:-127.0.0.1:5555}"
STAGE=/data/local/tmp/oneos
LEGACY_STAGE=/data/local/tmp/lineage_stage
INCOMING=/data/local/tmp/oneos_incoming
OVERLAYS="${OVERLAYS:-$ROOT/out/overlays}"
FRESH=0
if [ "$1" = "--fresh" ]; then FRESH=1; shift; fi
if [ "$1" = "--overlays" ]; then
    [ -n "$2" ] || { echo "usage: $0 [--fresh] [--overlays <dir>] <system.img> | --scripts-only" >&2; exit 2; }
    OVERLAYS="$2"; shift 2
fi
[ -d "$OVERLAYS" ] || { echo "overlays dir not found: $OVERLAYS" >&2; exit 1; }
# guest_prepare.sh refuses jars that do not match guards.txt; catch a mixed or
# half-built set here, before anything reaches the phone. oplus-services is a
# ColorOS set's, vold_patched and service.incremental_patched.so a Pixel set's
# (make-overlays.sh lists them in guards.txt when it built them).
[ -f "$OVERLAYS/guards.txt" ] || { echo "$OVERLAYS: no guards.txt" >&2; exit 1; }
for need in services_patched.jar $(awk '$2 == "oplus-services_patched.jar" || $2 == "vold_patched" || $2 == "service.incremental_patched.so" { print $2 }' "$OVERLAYS/guards.txt"); do
    sum=$(awk -v n="$need" '$2 == n {print $1}' "$OVERLAYS/guards.txt" 2>/dev/null || true)
    if [ -z "$sum" ] || [ ! -f "$OVERLAYS/$need" ] || [ "$(sha256sum "$OVERLAYS/$need" | cut -d' ' -f1)" != "$sum" ]; then
        echo "$OVERLAYS: $need missing or not the one in its guards.txt" >&2
        exit 1
    fi
done
if [ "$(awk '$2 == "vold_patched" { v = 1 } $2 == "service.incremental_patched.so" { i = 1 } END { print v + i }' "$OVERLAYS/guards.txt")" = 1 ]; then
    echo "$OVERLAYS: guards.txt lists only one of vold_patched and service.incremental_patched.so" >&2
    exit 1
fi
echo "overlays: $OVERLAYS"
# No plain umount in the session scripts: Android's toybox umount also detaches
# the source's loop device (LOOP_CLR_FD) unless given -D, and through dm-verity
# that stops one of One UI's APEX loops (return_to_oneui.sh explains). busybox
# ($BB umount) or umnt only.
PLAIN=$(grep -n '^[^#]*umount' "$ROOT"/assets/findx9ultra/*.sh | grep -v 'BB" umount\|$BB umount\|BB umount\|umnt\|umount -D\|applets\|for a in sh mount umount' || true)
if [ -n "$PLAIN" ]; then
    echo "plain umount in the session scripts (use \$BB umount or umnt):" >&2
    echo "$PLAIN" >&2
    exit 1
fi

# ADB can point at another adb server, e.g. a laptop's USB connection
# forwarded to this machine: ADB="adb -H 127.0.0.1 -P 5575" ANDROID_SERIAL=<usb serial>
adb_() { ${ADB:-adb} -s "$SERIAL" "$@"; }
su_() { adb_ shell "su -c '$*'"; }

[ "$(su_ id -u | tr -d '\r')" = "0" ] || { echo "no root on the phone (su -c id failed)" >&2; exit 1; }

for s in $STAGE $LEGACY_STAGE; do
    if su_ "mount | grep -q \" $s/rootfs \""; then
        echo "the container is mounted ($s/rootfs); return to One UI first" >&2
        exit 1
    fi
done
# Nor while a host /data tree is still bridged to the stage (an unclean session).
. "$ROOT/assets/findx9ultra/bridges.sh"
MOUNTS=$(su_ "cat /proc/self/mountinfo" | awk '{print $5}')
for pair in $BRIDGES; do
    if echo "$MOUNTS" | grep -qx "/data/${pair%%:*}"; then
        echo "/data/${pair%%:*} is still bridged to the stage; return to One UI (reboot) first" >&2
        exit 1
    fi
done

# The old switcher app (com.wewaffles.onelineage, switcher/src) copies its
# bundled scripts into /data/local/tmp/lineage_stage under their old names
# whenever it opens, which would make a second stage next to $STAGE; the
# OneOS app refuses to prepare or switch while it is installed, and so does
# this deploy. It is no longer built from here.
# (com.wewaffles.onelineage check removed: scripts run standalone, app is separate)

adb_ shell "mkdir -p $INCOMING"
adb_ push "$ROOT"/assets/findx9ultra/*.sh "$ROOT"/assets/findx9ultra/zygote_exec "$INCOMING/"
# The stage's names up to 0.3.6 become the OneOS ones before anything is
# pushed into the stage (scripts/stage-migrate.sh, run as root on the phone).
adb_ push "$ROOT/scripts/stage-migrate.sh" "$INCOMING/stage-migrate"
MIGRATE=$(su_ "sh $INCOMING/stage-migrate $INCOMING/bridges.sh" | tr -d '\r' || true)
[ -z "$MIGRATE" ] || echo "$MIGRATE"
if [ "$(echo "$MIGRATE" | tail -n 1)" != "stage-migrate: ok" ]; then
    echo "the stage was not renamed to $STAGE; nothing was pushed into it" >&2
    exit 1
fi

if [ "$FRESH" = 1 ] && su_ "[ -d $STAGE ] && echo yes" | grep -q yes; then
    ASIDE="$STAGE.old-$(date +%s)"
    su_ "mv $STAGE $ASIDE"
    echo "moved the old stage aside: $ASIDE"
fi

# The stage is root's and writable by root only: every file in it runs as root.
su_ "mkdir -p $STAGE && chown 0:0 $STAGE && chmod 755 $STAGE && cp -f $INCOMING/*.sh $INCOMING/zygote_exec $STAGE/ && chmod 755 $STAGE/*.sh $STAGE/zygote_exec"

# Framework overlays from scripts/make-overlays.sh (bind-mounted by
# guest_prepare.sh). Only pushed when they differ from what is staged.
# Staged overlays this set does not carry go to the attic first (oneos-telephony.jar
# and .sha256 too: guest_prepare.sh would offer them to another image), and so
# do the session scripts under their names up to 0.3.6.
ATTIC="$STAGE/attic/$(date +%s)"
for name in $(su_ "ls $STAGE" | tr -d '\r'); do
    case "$name" in
        switch_to_lineage.sh|master_prepare.sh|master_inner.sh)
            su_ "mkdir -p $ATTIC && mv -f $STAGE/$name $ATTIC/"
            echo "moved $name to $ATTIC (renamed since 0.3.6)"
            continue
            ;;
        *_patched*|*_payload.img|*.apk|oneos-*|clean_apex_info_list.xml) ;;
        *) continue ;;
    esac
    [ -f "$OVERLAYS/$name" ] && continue
    su_ "mkdir -p $ATTIC && mv -f $STAGE/$name $ATTIC/"
    echo "moved $name to $ATTIC (not in $OVERLAYS)"
done
for f in "$OVERLAYS"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    want=$(sha256sum "$f" | cut -d' ' -f1)
    have=$(su_ "sha256sum $STAGE/$name 2>/dev/null" | cut -d' ' -f1 | tr -d '\r')
    [ "$have" = "$want" ] && continue
    adb_ push "$f" "$INCOMING/$name"
    mode=644; [ -x "$f" ] && mode=755
    su_ "mv -f $INCOMING/$name $STAGE/$name && chmod $mode $STAGE/$name"
done

if [ "$1" != "--scripts-only" ]; then
    IMG="$1"
    [ -f "$IMG" ] || { echo "image not found: $IMG" >&2; exit 1; }
    # ext4 only: guest_prepare.sh loop-mounts system.raw as ext4.
    file -L "$IMG" | grep -q "ext[234]" || { echo "$IMG is not an ext4 image" >&2; exit 1; }
    GZ="$IMG.gz"
    [ -f "$GZ" ] || gzip -6 -c "$IMG" > "$GZ"
    want=$(sha256sum "$IMG" | cut -d' ' -f1)
    SRC_GZ="${ON_PHONE_GZ:-$INCOMING/system.raw.gz}"
    have_size=$(adb_ shell "stat -c %s $SRC_GZ 2>/dev/null" | tr -d '\r')
    if [ "$have_size" != "$(wc -c < "$GZ" | tr -d ' ')" ]; then
        [ -z "$ON_PHONE_GZ" ] || { echo "$ON_PHONE_GZ is missing or incomplete ($have_size bytes)" >&2; exit 1; }
        adb_ push "$GZ" "$SRC_GZ"
    fi
    echo "unpacking on the phone..."
    su_ "gunzip -c $SRC_GZ > $STAGE/system.raw.tmp && mv -f $STAGE/system.raw.tmp $STAGE/system.raw && chmod 644 $STAGE/system.raw"
    got=$(su_ "sha256sum $STAGE/system.raw" | cut -d' ' -f1 | tr -d '\r')
    [ "$got" = "$want" ] || { echo "checksum mismatch on the phone: $got != $want" >&2; exit 1; }
    [ -n "$ON_PHONE_GZ" ] || su_ "rm -f $SRC_GZ"
    echo "image verified"
fi
su_ "rm -rf $INCOMING; ls -la $STAGE"
# A stage the OneOS app set up: its files.sha256 no longer matches what was
# pushed, so the app's switch refuses until the app stages its own files again.
if su_ "[ -f $STAGE/files.sha256 ] && echo yes" | grep -q yes; then
    echo "note: $STAGE has the OneOS app's files.sha256; a switch from the app refuses until the app stages its files again"
fi
