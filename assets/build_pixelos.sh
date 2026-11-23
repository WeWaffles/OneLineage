#!/system/bin/sh
# Turns the stock PixelOS 16.2 (OnePlus 12 "waffle") OTA images into the images
# OnePixel boots: system.raw, system_ext.raw and product.raw in $STAGE, as the
# app's extractor wrote them. Everything here is a plain file edit on a
# loop-mounted ext4 image, and every step can be repeated safely.
#
# What it does (the recipe the hand-built image used, now on the phone):
#   system      drop the Oplus framework (oplus-fwk) and its boot image, take it out
#               of the boot classpath, give build.prop a generic PixelOS identity
#   system_ext  drop the OnePlus apps/daemons (KeyHandler, Dolby, eSIM switcher,
#               touch gestures, horae, tcmd, oplus-ims-ext), fix the sepolicy
#               file (genfscon lines this phone's policy rejects), generic props
#   product     drop the 21 waffle-only overlays, add this phone's own
#               framework-res overlay, generic props
# The three images stay separate; master_prepare.sh mounts system_ext and product
# over the system image's mount points.
#
# Usage: build_pixelos.sh        (STAGE can be overridden with OL_STAGE for tests)

STAGE="${OL_STAGE:-/data/local/tmp/lineage_stage}"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)
PATCH="$STAGE/patch"
CTX="u:object_r:system_file:s0"
FAILED=0

OLD_FP='OnePlus/CPH2573IN/OP595DL1:16/BP2A.250605.015/U.R4T3.37c1ac7-14b7cd5-14d96f8'
NEW_FP='PixelOS/pixelos_gsi_arm64/gsi_arm64:16/BP4A.251205.006/1778484076'

ENFORCE=$(getenforce 2>/dev/null)
[ "$ENFORCE" = "Enforcing" ] && setenforce 0 2>/dev/null
cleanup() {
    for n in system system_ext product; do
        $BB umount -l "$PATCH/$n" 2>/dev/null
    done
    [ "$ENFORCE" = "Enforcing" ] && setenforce 1 2>/dev/null
}
trap cleanup EXIT

log() { echo "[build_pixelos] $*"; }

# A free loop node, created like master_prepare.sh does (minor = index * 8).
free_loop() {
    i=60
    while [ $i -le 149 ]; do
        n=/dev/block/loop$i
        [ -b "$n" ] || mknod "$n" b 7 $((i * 8)) 2>/dev/null
        if [ -b "$n" ] && ! $BB losetup "$n" >/dev/null 2>&1; then echo "$n"; return 0; fi
        i=$((i + 1))
    done
    return 1
}

# The OTA images are packed full, and ext4 keeps ~2% of a volume back from writers, so
# an edit fails with "No space left". Give each image 64 MB of headroom first (once).
grow_img() {
    img="$STAGE/$1.raw"
    [ -f "$STAGE/$1.grown" ] && return 0
    # (relative size from toybox: shell arithmetic here is 32-bit and product is over 2 GB)
    truncate -s +64M "$img" || return 1
    e2fsck -fp "$img" >/dev/null 2>&1
    resize2fs "$img" >/dev/null 2>&1 || { log "resize2fs failed on $1.raw"; return 1; }
    touch "$STAGE/$1.grown"
}

# mount_rw <name> -> mounts $STAGE/<name>.raw read-write at $PATCH/<name>
mount_rw() {
    img="$STAGE/$1.raw"
    mkdir -p "$PATCH/$1"
    for l in $($BB losetup -a | grep "/$1.raw" | cut -d: -f1); do
        $BB umount -l "$PATCH/$1" 2>/dev/null
        $BB losetup -d "$l" 2>/dev/null
    done
    loop=$(free_loop) || { log "no free loop device"; return 1; }
    $BB losetup "$loop" "$img" || return 1
    if ! $BB mount -t ext4 -o rw,noatime "$loop" "$PATCH/$1"; then
        $BB losetup -d "$loop" 2>/dev/null
        return 1
    fi
    echo "$loop" > "$PATCH/$1.loop"
    return 0
}

umount_img() {
    sync
    $BB umount "$PATCH/$1" 2>/dev/null || $BB umount -l "$PATCH/$1" 2>/dev/null
    if [ -f "$PATCH/$1.loop" ]; then
        $BB losetup -d "$(cat "$PATCH/$1.loop")" 2>/dev/null
        rm -f "$PATCH/$1.loop"
    fi
}

# Fingerprint, flavor and device names: the same rules for all three build.props.
fix_props() {
    f="$1"
    [ -f "$f" ] || { log "missing $f"; FAILED=1; return; }
    # -E: the phone's busybox sed has no \| alternation in basic regexes.
    $BB sed -i -E \
        -e '/^ro\.product\.(system|system_ext|product)\.(brand|device|manufacturer|model|name)=/d' \
        -e '/^persist\.oplus\.qspa\.modem=/d' \
        -e '/^sys\.oplus\.ifaa\.model=/d' \
        -e '/^ro\.opa\.device_model_id=/d' \
        -e '/^ro\.product\.ab_ota_partitions=/d' \
        -e '/^# from device\/oneplus\//d' \
        -e "s#$OLD_FP#$NEW_FP#" \
        -e 's/^ro\.build\.flavor=custom_waffle-user/ro.build.flavor=pixelos_gsi_arm64-user/' \
        -e 's/^ro\.custom\.device=waffle/ro.custom.device=gsi_arm64/' \
        -e 's/^ro\.com\.google\.clientidbase=android-oneplus/ro.com.google.clientidbase=android-google/' \
        -e 's/^ro\.custom\.version=PixelOS_waffle-/ro.custom.version=PixelOS_gsi_arm64-/' \
        "$f" || { log "sed failed on $f"; FAILED=1; return; }
    chmod 600 "$f"; chown 0:0 "$f"; chcon "$CTX" "$f" 2>/dev/null
    if grep -qiE 'oneplus|oplus|waffle|CPH2573' "$f"; then
        log "note: $f still mentions OnePlus: $(grep -iE 'oneplus|oplus|waffle|CPH2573' "$f" | head -3 | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------- system
patch_system() {
    log "system: removing the Oplus framework"
    M="$PATCH/system/system"
    [ -d "$M/framework" ] || { log "system: no /system/framework in the image"; FAILED=1; return; }
    for f in oplus-fwk.jar boot-oplus-fwk.vdex arm64/boot-oplus-fwk.art arm64/boot-oplus-fwk.oat arm64/boot-oplus-fwk.vdex; do
        rm -f "$M/framework/$f" "$M/framework/$f.fsv_meta"
    done
    BCP="$M/etc/classpaths/bootclasspath.pb"
    # The stock file is 1052 bytes and lists oplus-fwk; 0 bytes is what a run that
    # hit "no space" earlier leaves behind. Anything else that is not already the
    # 978-byte clean file is not what this recipe was made for.
    bsz=$(stat -c %s "$BCP" 2>/dev/null)
    if [ "$bsz" = "1052" ] || [ "$bsz" = "0" ]; then
        if [ -f "$STAGE/bootclasspath.pb" ]; then
            rm -f "$BCP" "$BCP.fsv_meta"
            cp "$STAGE/bootclasspath.pb" "$BCP" && chmod 644 "$BCP" && chown 0:0 "$BCP" &&
                chcon "$CTX" "$BCP" 2>/dev/null
            if [ "$(stat -c %s "$BCP")" = "978" ]; then
                log "system: boot classpath without oplus-fwk"
            else
                log "system: could not write the boot classpath"; FAILED=1
            fi
        else
            log "system: no clean bootclasspath.pb in $STAGE"; FAILED=1
        fi
    elif [ "$bsz" = "978" ]; then
        log "system: boot classpath already clean"
    else
        log "system: bootclasspath.pb is not the one this recipe was made for (size $bsz)"
        FAILED=1
    fi
    fix_props "$M/build.prop"
}

# ------------------------------------------------------------ system_ext
patch_system_ext() {
    log "system_ext: removing OnePlus apps and daemons"
    M="$PATCH/system_ext"
    [ -d "$M/priv-app" ] || { log "system_ext: no /priv-app in the image"; FAILED=1; return; }
    rm -rf "$M/app/KeyHandler" "$M/priv-app/DolbyManager" "$M/priv-app/OplusEsimSwitcher" "$M/priv-app/TouchGestures"
    rm -f "$M/etc/init/horae.rc" "$M/etc/init/tcmd.rc" "$M/etc/permissions/OplusEsimSwitcher.xml" \
          "$M/bin/horae" "$M/bin/tcmd" "$M/etc/seccomp_policy/tcmd.policy"
    rm -rf "$M/etc/horae"
    for f in oplus-ims-ext.jar oat/arm64/oplus-ims-ext.odex oat/arm64/oplus-ims-ext.vdex; do
        rm -f "$M/framework/$f" "$M/framework/$f.fsv_meta"
    done
    CIL="$M/etc/selinux/system_ext_sepolicy.cil"
    if [ -f "$CIL" ]; then
        # This phone's kernel/policy has no iso9660 or udf genfs labels to attach to.
        $BB sed -i -E '/^\(genfscon (iso9660|udf) "\/"/d' "$CIL" && rm -f "$CIL.fsv_meta"
        chmod 644 "$CIL"; chown 0:0 "$CIL"; chcon "$CTX" "$CIL" 2>/dev/null
    else
        log "system_ext: no system_ext_sepolicy.cil"
        FAILED=1
    fi
    fix_props "$M/etc/build.prop"
}

# --------------------------------------------------------------- product
patch_product() {
    log "product: removing waffle-only overlays"
    M="$PATCH/product"
    [ -d "$M/overlay" ] || { log "product: no /overlay in the image"; FAILED=1; return; }
    rm -f "$M"/overlay/*__custom_waffle__*.apk "$M/overlay/EuiccPolicyOplus.apk" \
          "$M/overlay/KeyHandlerResTarget.apk" "$M/overlay/OPlusWifiResTarget.apk"
    # This phone's own framework-res overlay (the device config One UI runs with:
    # carrier/region resources, sensor and display settings), under its own name.
    cnt=0
    for f in /product/overlay/framework-res__*__auto_generated_rro_product.apk; do
        [ -f "$f" ] || continue
        cp "$f" "$M/overlay/$(basename "$f")" && chmod 644 "$M/overlay/$(basename "$f")" &&
            chown 0:0 "$M/overlay/$(basename "$f")" && chcon "$CTX" "$M/overlay/$(basename "$f")" 2>/dev/null
        cnt=$((cnt + 1))
    done
    log "product: copied $cnt framework-res overlay(s) from this phone"
    [ "$cnt" -ge 1 ] || { log "product: this phone has no framework-res overlay to copy"; FAILED=1; }
    fix_props "$M/etc/build.prop"
}

# ------------------------------------------------------------------ main
# OL_ONLY="system_ext" patches just that image (for testing a piece of the recipe).
NAMES="${OL_ONLY:-system system_ext product}"
for n in $NAMES; do
    [ -f "$STAGE/$n.raw" ] || { log "missing $STAGE/$n.raw"; exit 2; }
done
if [ -z "$OL_ONLY" ] && [ -f "$STAGE/.pixelos_patched" ]; then
    log "already patched ($(cat "$STAGE/.pixelos_patched"))"
    exit 0
fi
mkdir -p "$PATCH"

for n in $NAMES; do
    log "mounting $n"
    grow_img "$n" || { log "could not grow $n.raw"; exit 3; }
    mount_rw "$n" || { log "could not mount $n.raw read-write"; exit 3; }
    "patch_$n"
    umount_img "$n"
    # A quick consistency pass; exit code 1 just means it fixed something.
    e2fsck -fp "$STAGE/$n.raw" >/dev/null 2>&1
    rc=$?
    [ $rc -le 1 ] || { log "e2fsck on $n.raw returned $rc"; FAILED=1; }
done

if [ "$FAILED" = "0" ]; then
    [ -z "$OL_ONLY" ] && date > "$STAGE/.pixelos_patched"
    log "done"
    exit 0
fi
log "finished with problems, run again after fixing them"
exit 4
