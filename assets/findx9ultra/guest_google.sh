#!/system/bin/sh
# Google Play services and the Play Store in a ColorOS guest, on every phone.
# Pull request #1 added this for the Z Fold8 with the Find N6; since 0.4.16 it
# covers every ColorOS set. ColorOS 17 keeps Play services in a gmssystem APEX
# the phone's apexd never activates: my_product/priv-app/GmsCore holds only its
# modules (m), in the CN and IN builds alike. The guest got One UI's own APEX
# copy instead, without its privileged permissions (Galaxy S25, X9U IN: "You
# either need MANAGE_USERS or CREATE_USERS permission", and the Play Store
# found no gservices provider). The CN builds' Play Store is a 2022 stub
# (GooglePlayServicesUpdater).
#
# snapshot (oneos_switch.sh, while One UI's package manager still runs): copy
# One UI's own Play services and Play Store APK files, never their data, into
# $STAGE/google_apps, with the arm64 libraries from the same APKs. An unchanged
# copy is kept.
# prepare (guest_prepare.sh): check that copy and bind it read-only over
# priv-app/GmsCore in my_product, or else in the guest's product folder (with
# the image's own m), and over the CN stub next to it;
# an image with its own Play Store (the X9U IN) keeps it. The image is not
# changed. The guest's own installed copy of Play services (APK folder only)
# is removed, so the system copy runs. guest_prepare.sh then hides One UI's
# GmsCore in the guest's gmssystem APEX, so the guest finds Play services
# once, in that folder, where the image's own privapp permissions file grants
# it.
#
# Neither step stops a switch. Without a checked copy (old guest app ids, a
# missing guard, an unexpected APK path, no space) the guest starts as before.
STAGE=${STAGE:-/data/local/tmp/oneos}
BB=${BB:-/data/oneos_bin/busybox}
CACHE="$STAGE/google_apps"
say() { echo "Google apps: $*"; }
# ColorOS sets (their guards.txt lists oplus-services_patched.jar) and HyperOS
# sets (miui-services_patched.jar; the Xiaomi 18 Fold CN build has the same
# GmsCore folder with only m and the same Play Store stub, in product). Pixel
# sets present the image's own Play services (guest_prepare.sh GMS_WANT), and
# so does a set with a gmssystem payload (Infinity-X, 0.4.27, which has OPPO's
# jars too). Not when a launch hides Google services (ONEOS_GUEST_HIDE_GMS=1).
selected() {
    grep -q -E ' (oplus|miui)-services_patched.jar$' "$STAGE/guards.txt" 2>/dev/null && [ ! -f "$STAGE/gmssystem_payload.img" ] &&
        [ "${ONEOS_GUEST_GMS:-1}" = 1 ] && [ "${ONEOS_GUEST_HIDE_GMS:-0}" != 1 ]
}
# No links anywhere below the cache, a guest-planted link to host data included.
plain_tree() {
    [ ! -L "$1" ] && { [ ! -d "$1" ] || [ -z "$(find "$1" -type l -print -quit)" ]; }
}
verify() { # <dir>: every APK and library as the snapshot recorded it
    dir=$1
    [ -d "$dir" ] && plain_tree "$dir" || return 1
    (cd "$dir" && [ -s apk.sha256 ] && sha256sum -c apk.sha256 && [ -f native.sha256 ] &&
        { [ ! -s native.sha256 ] || sha256sum -c native.sha256; }) >/dev/null 2>&1
}
# Copy <package>'s APKs from One UI into $CACHE/<name>, unless the copy there
# still matches One UI's files (path, size and time).
copy_app() { # <package> <name>
    pkg=$1; name=$2; dir="$CACHE/$name"; new="$CACHE/.$name-$$"
    plain_tree "$dir" || { WHY="a link below $dir"; return 1; }
    pm path "$pkg" 2>/dev/null | sed -n 's/^package://p' > "$CACHE/.$name.paths"
    [ -s "$CACHE/.$name.paths" ] || { WHY="$pkg is not installed in One UI"; return 1; }
    : > "$CACHE/.$name.stat"
    while IFS= read -r source; do
        case "$source" in
            /data/app/*/*.apk|/product/*/*.apk|/system/*/*.apk|/system_ext/*/*.apk) ;;
            /apex/com.google.android.gmssystem/priv-app/*/*.apk) ;;
            *) WHY="unexpected APK path $source"; return 1 ;;
        esac
        [ -f "$source" ] && [ ! -L "$source" ] || { WHY="$source is missing or a link"; return 1; }
        stat -c '%n %s %Y' "$source" >> "$CACHE/.$name.stat" || { WHY="cannot stat $source"; return 1; }
    done < "$CACHE/.$name.paths"
    if verify "$dir" && cmp -s "$dir/source.stat" "$CACHE/.$name.stat"; then
        say "$name: One UI's copy is unchanged"
        return 0
    fi
    rm -rf "$new"
    mkdir "$new" && mkdir -p "$new/lib/arm64" || { WHY="cannot create $new"; return 1; }
    while IFS= read -r source; do
        cp "$source" "$new/${source##*/}" || { WHY="cannot copy $source (space?)"; return 1; }
    done < "$CACHE/.$name.paths"
    for apk in "$new"/*.apk; do
        # BusyBox awk treats the doubled slash escapes as the end of the
        # regex. Match path components instead, and check both commands:
        # errors inside a for-loop substitution otherwise look like no libs.
        "$BB" unzip -l "$apk" > "$new/archive.list" || { WHY='cannot list APK'; return 1; }
        entries=$("$BB" awk 'split($4, p, "/") == 3 && p[1] == "lib" && p[2] == "arm64-v8a" && p[3] ~ /^lib.*[.]so$/ {print $4}' "$new/archive.list") || { WHY='cannot read APK library list'; return 1; }
        for entry in $entries; do
            lib=${entry##*/}
            "$BB" unzip -p "$apk" "$entry" > "$new/lib/$lib" || { WHY='cannot extract native library'; return 1; }
            [ -s "$new/lib/$lib" ] || { WHY='empty native library'; return 1; }
            rm -f "$new/lib/arm64/$lib"
            ln "$new/lib/$lib" "$new/lib/arm64/$lib" || { WHY='cannot link native library'; return 1; }
        done
    done
    rm -f "$new/archive.list"
    # APKs without embedded arm64 libraries are valid too. Keep an explicit
    # empty manifest instead of passing an unmatched glob to sha256sum.
    (cd "$new" && sha256sum ./*.apk > apk.sha256 &&
        : > native.sha256 &&
        for f in lib/*.so lib/arm64/*.so; do
            [ -f "$f" ] || continue
            sha256sum "$f" >> native.sha256 || exit 1
        done) || { WHY='cannot write checksums'; return 1; }
    cp "$CACHE/.$name.stat" "$new/source.stat"
    chown -R 0:0 "$new"; find "$new" -type d -exec chmod 755 {} \;
    find "$new" -type f -exec chmod 644 {} \;
    # Only our own binary copy, replaced; no guest data.
    rm -rf "$dir"
    mv "$new" "$dir" && verify "$dir" || { WHY="the new copy of $name does not verify"; return 1; }
    say "$name: copied from One UI ($(wc -l < "$dir/apk.sha256") APK(s), $(wc -l < "$dir/native.sha256") library file(s))"
}
# The guest's own installed copy of <package> (an earlier session's, or an app
# store's): its APK folder in the guest's /data/app, never its data. Galaxy S25
# with the X9U IN build on 0.4.16: ColorOS kept running Play services from such
# a copy instead of the system copy bound in prepare, without its privileged
# permissions ("You either need MANAGE_USERS"), and it crashed 720 times in
# 7 minutes until the phone was too hot to hold. With the copy gone, the
# package manager takes the system copy (and keeps the package's data).
# Prepare runs before the bridges, with nothing mounted under the staged /data
# (guest_prepare.sh checks that at its start; checked again here).
remove_installed() { # <package>
    app="$STAGE/data/app"
    [ -d "$app" ] && [ ! -L "$app" ] || return 0
    if awk -v p="$app" '$5 == p || index($5, p "/") == 1 { f = 1 } END { exit !f }' /proc/self/mountinfo; then
        say "something is mounted under the guest's /data/app: its installed $1 left alone"
        return 0
    fi
    for d in "$app"/*/"$1"-* "$app"/"$1"-*; do
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        parent=${d%/*}
        if [ "$parent" != "$app" ]; then
            [ -d "$parent" ] && [ ! -L "$parent" ] || continue
        fi
        rm -rf "$d" && say "removed the guest's installed copy ${d#$STAGE/data/} (the system copy runs)"
        [ "$parent" = "$app" ] || rmdir "$parent" 2>/dev/null
    done
    return 0
}
case "$1" in
snapshot)
    selected || exit 0
    # 0.4.14-0.4.15 kept the Fold8's copy here; ours alone, no guest data.
    rm -rf "$STAGE/fold8_google"
    skip() {
        rm -rf "$CACHE"
        say "not added ($*); the guest starts without One UI's Play services and Play Store"
        exit 0
    }
    for t in gatekeeper pdb apexd appid15000; do
        grep '^#' "$STAGE/guards.txt" 2>/dev/null | grep -qw "$t" || skip "guards.txt lacks the $t guard"
    done
    awk '$2 ~ /^[0-9]+$/ && $2 >= 10000 && $2 <= 14999 { f = 1 } END { exit !f }' "$STAGE/data/system/packages.list" 2>/dev/null &&
        skip "the guest has app ids 10000-14999 from before the app-id guard; set up again with fresh guest data for Google apps"
    [ ! -e "$CACHE" ] || { [ -d "$CACHE" ] && [ ! -L "$CACHE" ]; } || skip "$CACHE is not a directory"
    mkdir -p "$CACHE" || skip "cannot create $CACHE"
    rm -rf "$CACHE"/.[!.]*
    WHY=
    copy_app com.google.android.gms GmsCore || skip "$WHY"
    copy_app com.android.vending Phonesky || skip "$WHY"
    rm -f "$CACHE"/.*.paths "$CACHE"/.*.stat
    ;;
prepare)
    rm -f "$CACHE/active"
    selected || exit 0
    ROOTFS="$STAGE/rootfs"
    [ -d "$CACHE" ] || { say "no copy from One UI (see the snapshot line before One UI stopped)"; exit 0; }
    for name in GmsCore Phonesky; do
        verify "$CACHE/$name" || { say "the copy of $name does not match its checksums: not used"; exit 0; }
    done
    # The image's Play services folder: in my_product (ColorOS) or in the
    # guest's product folder, found inside the rootfs (system/product can be an
    # absolute link to /product, which in this namespace is One UI's).
    PRODUCT="$ROOTFS/system/product"
    [ -L "$PRODUCT" ] && PRODUCT="$ROOTFS/product"
    gms=""
    for d in "$ROOTFS/my_product/priv-app" "$PRODUCT/priv-app"; do
        "$BB" umount -l "$d/GmsCore" 2>/dev/null
        [ -d "$d/GmsCore" ] && [ ! -L "$d/GmsCore" ] && [ ! -L "$d" ] && { gms="$d/GmsCore"; break; }
    done
    [ -n "$gms" ] || { say "the image has no priv-app/GmsCore folder: not used"; exit 0; }
    # The CN builds' Play Store stub next to it; an image with its own Play
    # Store keeps it.
    store="${gms%/GmsCore}/GooglePlayServicesUpdater"
    "$BB" umount -l "$store" 2>/dev/null
    [ -d "$store" ] && [ ! -L "$store" ] || store=
    # The image's own signed Dynamite modules stay with Play services.
    rm -rf "$CACHE/GmsCore/m"
    if [ -d "$gms/m" ]; then
        cp -a "$gms/m" "$CACHE/GmsCore/" || { rm -rf "$CACHE/GmsCore/m"; say "cannot copy the image's GmsCore/m: not used"; exit 0; }
    fi
    bound=
    for spec in "GmsCore:$gms" ${store:+"Phonesky:$store"}; do
        name=${spec%%:*}; target=${spec#*:}
        chcon -R u:object_r:system_file:s0 "$CACHE/$name" &&
            "$BB" mount --bind "$CACHE/$name" "$target" && bound="$bound $target" &&
            "$BB" mount --make-private "$target" &&
            "$BB" mount -o remount,bind,ro "$CACHE/$name" "$target" || {
            for b in $bound; do "$BB" umount -l "$b" 2>/dev/null; done
            say "could not bind $name over ${target#$ROOTFS/}: not used"
            exit 0
        }
        say "$name from One UI -> ${target#$ROOTFS/} (read-only)"
    done
    [ -n "$store" ] || say "the image keeps its own Play Store"
    remove_installed com.google.android.gms
    : > "$CACHE/active"
    ;;
*) echo "guest_google.sh: expected snapshot or prepare" >&2; exit 3 ;;
esac
