#!/system/bin/sh
# The root manager's own busybox (as oneos_switch.sh checked), never a
# search of /data; after the pivot the guest's copy in its /data.
BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    [ -x "$c" ] && { BB=$c; break; }
done
[ -n "$BB" ] || [ "${ONEOS_APP:-0}" = 1 ] || BB=$(command -v busybox 2>/dev/null)
[ -n "$BB" ] || { echo "[Pivoted Root] FATAL: no busybox. Not starting the guest."; exit 1; }

echo "[Pivoted Root] Preparing pivot..."
cd /data/local/tmp/oneos/rootfs
$BB mount --make-rprivate /
if ! $BB pivot_root . postinstall; then
    echo "[Pivoted Root] Fallback: bind mounting rootfs onto itself..."
    $BB mount --bind . .
    if ! $BB pivot_root . postinstall; then
        echo "[Pivoted Root] FATAL: pivot_root failed completely! Aborting."
        exit 1
    fi
fi
# OneOS: guest_prepare.sh copied busybox into the guest /data, so nothing below
# (nor the keepers started from here) runs it from host /data/adb, which the
# guest sees read-only. The file keeps the name busybox: a multi-call busybox
# takes its applet from argv[0] and only reads it from argv[1] when it is called
# busybox (run 36a: /data/oneos_busybox answered every call 'applet not found').
/data/oneos_bin/busybox true 2>/dev/null && BB=/data/oneos_bin/busybox
echo "[Pivoted Root] busybox: $BB"
$BB mount -t proc proc /proc
# OneOS: the kernel is the phone's. No sysrq from the guest (its watchdog
# writes 'c' to crash the kernel; the framework patch stops that too).
if $BB mount --bind /dev/null /proc/sysrq-trigger 2>/dev/null; then
    echo "[Pivoted Root] /proc/sysrq-trigger hidden from the guest"
else
    echo "[Pivoted Root] FATAL: could not hide /proc/sysrq-trigger. Not starting the guest."
    exit 1
fi
# OneOS: pivot_root left the host's whole old root at /postinstall, including
# vold's bind of the phone's real /data/media and every unbridged /data tree.
# Nothing in the guest needs it (this namespace is rprivate, so this does not
# touch the host).
$BB umount -l /postinstall 2>/dev/null
if awk '$5 ~ "^/postinstall(/|$)"' /proc/self/mountinfo | grep -q .; then
    echo "[Pivoted Root] FATAL: host mounts still under /postinstall. Not starting the guest."
    exit 1
fi
echo "[Pivoted Root] Host root detached from /postinstall"

export PATH=/system/bin:/system/xbin

# OneOS: /mnt and /storage came in from the host, and its pass_through,
# installer, androidwritable, runtime and user views are binds of the phone's
# real /data/media. Drop them in this (private) namespace before anything in
# the guest runs; the guest builds its own from its staged /data/media below.
for m in $(awk '$5 ~ "^/(mnt/(pass_through|installer|androidwritable|runtime|user)|storage)(/|$)" {print $5}' /proc/self/mountinfo | sort -r); do
    $BB umount -l "$m" 2>/dev/null
done
left=$(awk '$5 ~ "^/(mnt/(pass_through|installer|androidwritable|runtime|user)|storage)(/|$)"' /proc/self/mountinfo | wc -l)
if [ "$left" != 0 ]; then
    echo "[Pivoted Root] FATAL: $left host storage views still mounted. Not starting the guest."
    exit 1
fi
echo "[Pivoted Root] Host storage views removed from the guest namespace"
# Rebuild the installer and androidwritable views the way init does, over the
# guest's own /mnt/user (zygote binds /mnt/installer/0 for apps that can
# install packages). /mnt is private to this namespace, so the new peer group
# is the guest's alone.
mkdir -p /mnt/user/0 /mnt/installer /mnt/androidwritable
$BB mount --make-shared /mnt
for v in installer androidwritable; do
    $BB mount --rbind /mnt/user /mnt/$v && $BB mount --make-rslave /mnt/$v
done

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
# oneos_switch.sh's TMPDIR ($STAGE/tmp) is not a path of the pivoted
# root; mksh would fail a long here-document with it (see there). The
# guest's /data/local/tmp is the stage's own, made by guest_prepare.sh.
mkdir -p /data/local/tmp 2>/dev/null
export TMPDIR=/data/local/tmp

# Class paths. This shell inherits the HOST's BOOTCLASSPATH and
# SYSTEMSERVERCLASSPATH (One UI's, with Samsung jars such as knoxanalyticssdk
# and semwifi-service). init normally runs derive_classpath and load_exports
# them; nothing does that in the container, so the guest zygote got the host's
# list. Lineage survived that, but ColorOS's libhwui aborts zygote looking for
# com/oplus/media/OplusBitmapChecker, which lives in oplus-framework.jar on
# ColorOS's own boot class path. Derive the guest's lists the way init does.
DERIVE=/apex/com.android.sdkext/bin/derive_classpath
CLASSPATH_FILE=/data/system/environ/classpath
mkdir -p /data/system/environ
if [ -x "$DERIVE" ] && "$DERIVE" "$CLASSPATH_FILE" > /data/derive_classpath.log 2>&1; then
    while read -r kw name value; do
        [ "$kw" = "export" ] && [ -n "$name" ] && export "$name=$value"
    done < "$CLASSPATH_FILE"
    echo "[Pivoted Root] Guest class paths loaded from $CLASSPATH_FILE:"
    sed 's/^/[Pivoted Root]   /' "$CLASSPATH_FILE" | cut -c1-400
else
    echo "[Pivoted Root] WARNING: derive_classpath failed, zygote keeps the host's class paths"
    sed 's/^/[Pivoted Root]   /' /data/derive_classpath.log 2>/dev/null | head -5
fi

# OneOS: every guest process, not just zygote, needs the guest class paths:
# app_process tools (oplus_defrag's defrag_wrap, settings/cmd/am run by the
# switch through nsenter) aborted with "Unable to find class
# com/oplus/media/OplusBitmapChecker" on the host's. Derive them first, and
# leave /data/oneos_genv.sh for commands entered from the host side.
cat > /data/oneos_genv.sh <<'GENV'
#!/system/bin/sh
[ -f /data/system/environ/classpath ] && while read -r kw name value; do
    [ "$kw" = "export" ] && [ -n "$name" ] && export "$name=$value"
done < /data/system/environ/classpath
exec "$@"
GENV
chmod 755 /data/oneos_genv.sh
echo "[Pivoted Root] Testing /dev/null resolution:"
exec 8< /dev/null
echo -n "FD 8: "
$BB readlink /proc/$$/fd/8
exec 8<&-

echo "[Pivoted Root] Testing su availability:"
su -c id || echo "su check non-fatal"
# OneOS: what the guest gets of host /data/adb and /data/apex (guest_prepare.sh
# binds both read-only); a failure above or a write error later points here.
for d in /data/adb /data/apex; do
    echo "[Pivoted Root] $d: $(awk -v p="$d" '$5 == p {print $6}' /proc/self/mountinfo | tail -n 1)"
done

# Foldable layouts. The host's display_layout_configuration.xml is Samsung's.
# ColorOS's DeviceStateToLayoutMapExtImpl.updateRealDisplayAddressId
# (oplus-services.jar) reads each <display>'s <address> without a null check
# and, for every state but 0, looks it up in a map that only state 0's displays
# fill (it takes the display disabled in state 0 for the big panel and the
# enabled one for the small panel). Samsung's file breaks one of these rules,
# and the NPE took DisplayManagerService and system_server down during
# bootstrap. Hide it in this namespace only; once the guest SurfaceFlinger
# reports both panels, ONEOS_GUEST_FOLD=layout (the default) writes our own file
# into the copy (below, after the HW overlay switch).
# The file has to be absent, not empty: an empty <layouts/> enables no display
# at all and DisplayManagerService times out waiting for a default display. A
# copy of the directory without it keeps the per-panel display_id_*.xml.
DISPLAYCONFIG=/vendor/etc/displayconfig
LAYOUT_HIDDEN=0
rm -f /data/oneos_fold_mode /data/oneos_inner_display
if [ -f "$DISPLAYCONFIG/display_layout_configuration.xml" ] && [ "${ONEOS_KEEP_FOLD_LAYOUT:-0}" != "1" ]; then
    rm -rf /data/oneos_displayconfig && mkdir -p /data/oneos_displayconfig
    for f in "$DISPLAYCONFIG"/*; do
        [ "$(basename "$f")" = display_layout_configuration.xml ] || cp -p "$f" /data/oneos_displayconfig/
    done
    chmod 755 /data/oneos_displayconfig && chmod 644 /data/oneos_displayconfig/*
    $BB mount --bind /data/oneos_displayconfig "$DISPLAYCONFIG" && LAYOUT_HIDDEN=1 && \
        echo "[Pivoted Root] Fold layout config hidden from the guest ($(ls /data/oneos_displayconfig | wc -l) display configs kept)"
fi

# Gap splash (oneos_switch.sh): [4b/6] froze One UI's surfaceflinger
# (SIGSTOP) on the switcher's OneOS screen instead of killing it, so its
# composer client stayed and the panel kept that frame through the host-side
# setup (run 32: 31.6 s of black, 23 s of it guest_prepare.sh). Kill it now,
# before the composer restart: alive, it would come back through the composer's
# "onrestart restart surfaceflinger". From here to ColorOS's first frame was
# 4.3 s in run 32 (composer restart 13:09:51.94, first frame 13:09:56.18).
if [ -s /data/oneos_host_sf_frozen ]; then
    FZ=$(cat /data/oneos_host_sf_frozen)
    rm -f /data/oneos_host_sf_frozen
    setprop ctl.stop surfaceflinger
    [ "$(cat /proc/$FZ/comm 2>/dev/null)" = surfaceflinger ] && kill -9 "$FZ" 2>/dev/null
    n=0
    while [ $n -lt 20 ] && [ -d "/proc/$FZ" ]; do n=$((n + 1)); sleep 0.1; done
    echo "[Pivoted Root] Gap splash: One UI's frozen surfaceflinger $FZ released at $(date +%T) ($([ -d "/proc/$FZ" ] && echo 'still there' || echo gone))"
fi

# The vendor composer still treats the killed host SurfaceFlinger as its client:
# every frame from the guest's came back NO_RESOURCES on both displays and the
# panel kept showing One UI's last frame. Restart it so the guest gets a fresh
# client.
# Snapdragon's composer service is vendor.qti.hardware.display.composer,
# Samsung's Exynos one vendor.hwcomposer-3 (Galaxy S26+ Exynos and Z Flip7
# probes, 2026-10-25). Not every phone uses one of those two names -- the
# Galaxy A56 probe (2026-10-30) runs the AIDL composer as
# android.hardware.graphics.composer3-service.exynos -- so when neither is
# there, take the running init service whose own name says it is the display
# composer rather than skip the restart (here) or fail the return
# (return_to_oneui.sh).
COMPOSER_SVC=""
for c in vendor.qti.hardware.display.composer vendor.hwcomposer-3; do
    [ -n "$(getprop init.svc.$c)" ] && { COMPOSER_SVC=$c; break; }
done
[ -n "$COMPOSER_SVC" ] || COMPOSER_SVC=$(getprop | "$BB" sed -n 's/^\[init\.svc\.\([^]]*\)\]: \[running\]$/\1/p' | "$BB" grep -m1 -E 'hwcomposer|display\.composer|graphics\.composer')
echo "[Pivoted Root] Restarting the vendor display composer (${COMPOSER_SVC:-none found})..."
[ -z "$COMPOSER_SVC" ] || setprop ctl.restart "$COMPOSER_SVC"
# With the gap splash, the black that is left is from here to the first boot
# animation frame, and most of it was fixed sleeps. Run 33 (all.log): the
# splash's surfaceflinger died 14:41:22.70, the new composer had registered
# AidlComposer at 14:41:23.157, the host surfaceflinger its onrestart revived
# (14:41:22.998) was gone before it got a composer client, but this sleep 2 and
# the one after the guest's surfaceflinger below kept the panel black until the
# animation's first frame at 14:41:27.31 (4.6 s). So wait for the new composer
# instead: 0.5 s first (the old one must be gone, or service check finds its
# entry), then until it is registered, at most the old 2 s.
# ONEOS_GAP_FAST=0 (guest_prepare.sh: /data/oneos_gap_slow) keeps both sleeps.
if [ -f /data/oneos_gap_slow ]; then
    sleep 2
else
    sleep 0.5
    n=0
    while [ $n -lt 15 ] && ! service check android.hardware.graphics.composer3.IComposer/default 2>/dev/null | grep -q ': found'; do
        n=$((n + 1)); sleep 0.1
    done
    echo "[Pivoted Root] Composer registered after $((5 + n))00 ms"
fi
# The composer's rc has "onrestart restart surfaceflinger", which brings the
# HOST surfaceflinger back. Any surfaceflinger alive now is the host's (the
# guest's is started below), so stop it before it owns the display and the
# "SurfaceFlinger" service name. oneos_switch.sh keeps it stopped.
setprop ctl.stop surfaceflinger
n=0
while [ $n -lt 20 ] && pidof surfaceflinger >/dev/null; do
    kill -9 $(pidof surfaceflinger) 2>/dev/null
    n=$((n + 1)); sleep 0.1
done
echo "[Pivoted Root] Host surfaceflinger after composer restart: $(pidof surfaceflinger || echo none)"

# What the composer has to offer, recorded BEFORE the guest's SurfaceFlinger
# asks for it. The diag rounds in oneos_switch.sh all start from
# `pidof surfaceflinger`, so a guest SF that dies leaves no display diag at all:
# the Galaxy S24 Ultra report of 2026-10-30 aborted with "No matching frame rate
# modes for primary range" and its bundle had nothing to say why, while its
# One UI offers 21 modes (its probe the same day). This runs first and keeps the
# mode list whatever SF then does with it.
# Reads files, and one lshal bounded by timeout, on a composer that has just
# registered: no plain dumpsys and no service walk here, the host's
# system_server is frozen at this point (0.4.11 hung every switch that way).
CD=$STAGE/diag_composer
mkdir -p "$CD"
{
    echo "== composer service ${COMPOSER_SVC:-none found}"
    [ -z "$COMPOSER_SVC" ] || echo "init.svc.$COMPOSER_SVC: $(getprop "init.svc.$COMPOSER_SVC")"
    service check android.hardware.graphics.composer3.IComposer/default 2>&1
    echo
    echo "== panel modes the kernel reports (/sys/class/drm)"
    for c in /sys/class/drm/card*-*; do
        [ -r "$c/modes" ] || continue
        echo "-- $(basename "$c") status=$(cat "$c/status" 2>/dev/null) enabled=$(cat "$c/enabled" 2>/dev/null)"
        cat "$c/modes" 2>/dev/null
    done
    echo
    echo "== vendor display configs (the file name is the display id it is for)"
    ls -l /vendor/etc/displayconfig /odm/etc/displayconfig 2>&1
} > "$CD/composer_before_sf.txt" 2>&1
# The composer's own dump: SDM lists its displays and each one's configs.
if command -v lshal >/dev/null 2>&1; then
    timeout 5 lshal debug android.hardware.graphics.composer3.IComposer/default \
        > "$CD/composer_debug.txt" 2>&1 || echo "lshal debug: no answer in 5 s" >> "$CD/composer_debug.txt"
fi

# Shader caches. init.rc makes /data/misc/surfaceflinger (0700 system system)
# and sets service.sf.cache_dir_available; the container has no init, so the
# guest's RenderEngine could not save one (run 32 all.log:276689, 39 times:
# "error creating cache file /data/misc/surfaceflinger/skia_shaders" and
# egl_shaders, "No such file or directory") and compiled every shader again in
# each session: a stutter the first time each blur, animation or window shape
# is drawn. This is the guest's own /data (the stage).
mkdir -p /data/misc/surfaceflinger && chown 1000:1000 /data/misc/surfaceflinger && chmod 0700 /data/misc/surfaceflinger
echo "[Pivoted Root] Starting guest SurfaceFlinger..."
# sf.log used to grow without bound: the guest's RenderEngine dumps LLVM IR for
# every shader it compiles ("Global Value @fullLiteral...") and got to 300+ MB in
# ~3 minutes, filling /data. SurfaceFlinger's real diagnostics go through logcat,
# so stderr can be dropped.
/system/bin/surfaceflinger > /dev/null 2>&1 &
SF_PID=$!
echo "[Pivoted Root] SurfaceFlinger PID: $SF_PID"
# The loop below already waits for the "SurfaceFlinger" service (5 s at most),
# and nothing else can hold that name now: the frozen host one died above and
# the revived one was killed before its init finished (run 33: it never got a
# composer client). Run 33's guest surfaceflinger was up 0.2 s after it started
# (14:41:25.337 -> power mode set 14:41:25.55), the fixed 2 s only delayed the
# boot animation (see the composer restart above).
if [ -f /data/oneos_gap_slow ]; then sleep 2; else sleep 0.5; fi

# Samsung's composer rejected ColorOS's surfaceflinger's command batches
# (executeCommands BAD_VALUE, presentOrValidate NO_RESOURCES on every frame:
# black panel). Disable hardware overlays (developer options "Disable HW
# overlays", SurfaceFlinger transaction 1008) so everything is GPU-composed
# and the composer only gets the client target buffer.
n=0
while [ $n -lt 25 ] && ! service check SurfaceFlinger 2>/dev/null | grep -q ": found"; do
    n=$((n + 1)); sleep 0.2
done
# /data/oneos_hwc (guest_prepare.sh) leaves the overlays on: the default since
# run 44 for guests without oplus-services.jar, ONEOS_GUEST_HWC=1 for ColorOS.
# The docs record that 1008 did not stop the rejected frames (run 23 still had
# 3890); the surfaceflinger patch that skips IQtiComposer3Client did, and the
# Pixel surfaceflinger has no such client. Forcing GPU composition is costly:
# every frame of the 2504x2256 panel goes through RenderEngine (run 32 diag_90
# surfaceflinger.txt: clientType=DEVOPTFORCECLIENT) and SurfaceFlinger counted
# 4800 GPU missed frames by 110 s (run 31: 5291 without window blur), about 45
# a second; run 43's Pixel about 2 a second (221 by diag_90).
if [ -f /data/oneos_hwc ]; then
    echo "[Pivoted Root] SurfaceFlinger HW overlays left on (no oplus-services.jar, or ONEOS_GUEST_HWC=1)"
    # Run 44: should the composer reject the frames anyway (a black panel),
    # force GPU composition by itself instead of waiting for the return keys.
    # Its rejections (run 23's executeCommands / presentOrValidate lines)
    # since now are counted 5, 15 and 30 s on; past 30, transaction 1008 once.
    HWC_T0=$(date +%s)
    (
        n=0
        for w in 5 10 15; do
            sleep $w
            n=$(logcat -d -b main -s SurfaceFlinger:E -T "$HWC_T0.000" 2>/dev/null | grep -c -E 'executeCommands failed|presentOrValidate failed')
            if [ "$n" -gt 30 ]; then
                service call SurfaceFlinger 1008 i32 1 > /data/sf_1008.log 2>&1
                echo "[Pivoted Root] composer rejected $n frames with HW overlays: GPU composition forced: $(cat /data/sf_1008.log)"
                exit 0
            fi
        done
        echo "[Pivoted Root] SurfaceFlinger HW overlays kept: $n composer rejections in the first 30 s"
    ) </dev/null 2>/dev/null &
else
    service call SurfaceFlinger 1008 i32 1 > /data/sf_1008.log 2>&1
    echo "[Pivoted Root] SurfaceFlinger HW overlays disabled: $(cat /data/sf_1008.log)"
fi

# Fold layout (see "Foldable layouts" above), like the Find N6: lid closed
# (Samsung's device state 0) puts ColorOS on the cover, lid open (3) on the
# inner panel; the other panel is switched off. State 0 comes first and lists
# both panels with the cover enabled: ColorOS maps addresses by that rule, so
# with the real ids its mapping is the identity. The ids come from the guest
# SurfaceFlinger: port 147 is the inner panel, 148 the cover (run 30; the Find
# N6's own overlay uses the same two ports). SurfaceFlinger keeps the port in
# the id's low byte, which is where DeviceStateToLayoutMap takes the port from
# when the file has no <port>. ONEOS_GUEST_FOLD=off: inner panel only (run 30).
# OneOS: the ports come from the host's touch-to-display associations
# (sec_touchscreen = inner, sec_touchscreen2 = cover), 147/148 when the file
# does not say, so another foldable does not get the Fold's.
if [ "$LAYOUT_HIDDEN" = 1 ] && [ "${ONEOS_GUEST_FOLD:-layout}" != off ]; then
    IN_PORT=''; CV_PORT=''
    for f in /vendor/etc/input-port-associations.xml /vendor/odm/etc/input-port-associations.xml; do
        [ -f "$f" ] || continue
        IN_PORT=$(sed -n 's/.*<port display="\([0-9][0-9]*\)" input="sec_touchscreen".*/\1/p' "$f" | head -1)
        CV_PORT=$(sed -n 's/.*<port display="\([0-9][0-9]*\)" input="sec_touchscreen2".*/\1/p' "$f" | head -1)
        break
    done
    [ -n "$IN_PORT" ] && [ -n "$CV_PORT" ] && [ "$IN_PORT" != "$CV_PORT" ] || { IN_PORT=147; CV_PORT=148; }
    echo "[Pivoted Root] Fold ports: inner $IN_PORT, cover $CV_PORT"
    INNER=''; COVER=''; n=0
    while [ $n -lt 25 ]; do
        DIDS=$(dumpsys SurfaceFlinger --display-id 2>/dev/null)
        INNER=$(echo "$DIDS" | sed -n "s/^Display \([0-9][0-9]*\) (HWC display [0-9]*): port=$IN_PORT .*/\1/p" | head -1)
        COVER=$(echo "$DIDS" | sed -n "s/^Display \([0-9][0-9]*\) (HWC display [0-9]*): port=$CV_PORT .*/\1/p" | head -1)
        [ -n "$INNER" ] && [ -n "$COVER" ] && break
        n=$((n + 1)); sleep 0.2
    done
    if [ -n "$INNER" ] && [ -n "$COVER" ] && [ "$INNER" != "$COVER" ]; then
        # Each entry: state, the panel it shows, the panel it switches off.
        # Run 44: a guest without oplus-services.jar (Pixel) gets AOSP's fold
        # states as yogi's own file maps them: 0 closed and 3 rear display on
        # the cover, 1 half open and 2 open on the inner panel (4 and 5, both
        # panels on, left out). Run 43 had only 0 and 3, so its rear display
        # state went to the inner panel. ColorOS keeps Samsung's 0 and 3.
        if [ -e /system/framework/oplus-services.jar ]; then
            # Samsung's states from the phone's own device_state_configuration.xml:
            # 0 (lid closed) on the cover, every other one on the inner panel.
            # The Z Fold8 Ultra and Z Fold7 list 0 CLOSE and 3 OPEN; the Z Fold8
            # (h8q) adds 1 TENT, which had no layout.
            STATES="0:$COVER:$INNER"
            DSC=/vendor/etc/devicestate/device_state_configuration.xml
            # Match the same root-prepared state file the guest framework reads.
            if [ -f /data/system/devicestate/device_state_configuration.xml ] && [ ! -L /data/system/devicestate/device_state_configuration.xml ]; then
                DSC=/data/system/devicestate/device_state_configuration.xml
            fi
            for id in $(sed -n 's/.*<identifier>\([0-9][0-9]*\)<\/identifier>.*/\1/p' "$DSC" 2>/dev/null | sort -un); do
                [ "$id" = 0 ] || STATES="$STATES $id:$INNER:$COVER"
            done
            [ "$STATES" != "0:$COVER:$INNER" ] || STATES="$STATES 3:$INNER:$COVER"
            LNOTE="Samsung's device states: 0 (lid closed) on the cover, the others ($(echo "$STATES" | tr ' ' '\n' | sed -n 's/:.*//p' | grep -v '^0$' | tr '\n' ' ')) on the inner panel."
        elif [ -e /system/system_ext/framework/miui-services.jar ] || [ -e /system_ext/framework/miui-services.jar ]; then
            # HyperOS's own states (guest_prepare.sh binds a lid-switch copy of
            # its product device_state_configuration.xml): 0 CLOSED and 1 TENT
            # outer primary, 2 HALF_OPENED and 3 OPENED inner, 4 OPENED_REVERSE
            # outer (the Pixel order below put 3 on the cover).
            STATES="0:$COVER:$INNER 1:$COVER:$INNER 2:$INNER:$COVER 3:$INNER:$COVER 4:$COVER:$INNER"
            LNOTE="HyperOS fold states 0 closed and 1 tent on the cover, 2 half open and 3 open on the inner panel, 4 reverse on the cover."
        else
            STATES="0:$COVER:$INNER 1:$INNER:$COVER 2:$INNER:$COVER 3:$COVER:$INNER"
            LNOTE="AOSP fold states 0 closed, 1 half open, 2 open, 3 rear display."
        fi
        {
            echo '<?xml version="1.0" encoding="utf-8"?>'
            echo "<!-- OneOS (guest_start.sh): $LNOTE -->"
            echo '<layouts>'
            for s in $STATES; do
                st=${s%%:*}; on=${s#*:}; off=${on#*:}; on=${on%%:*}
                cat <<LAYOUT
    <layout>
        <state>$st</state>
        <display enabled="true" defaultDisplay="true">
            <address>$on</address>
        </display>
        <display enabled="false">
            <address>$off</address>
        </display>
    </layout>
LAYOUT
            done
            echo '</layouts>'
        } > /data/oneos_displayconfig/display_layout_configuration.xml
        chmod 644 /data/oneos_displayconfig/display_layout_configuration.xml
        echo layout > /data/oneos_fold_mode
        # The inner panel's id for the UI activator's density and fold line
        # (oneos_switch.sh, run 44).
        echo "$INNER" > /data/oneos_inner_display; chmod 644 /data/oneos_inner_display
        echo "[Pivoted Root] Fold layout: lid closed -> cover $COVER, lid open -> inner $INNER (states$(for s in $STATES; do printf ' %s' "${s%%:*}"; done))"
    else
        echo "[Pivoted Root] WARNING: no fold layout (SurfaceFlinger gave inner '$INNER', cover '$COVER'); inner display only"
    fi
fi

# Render rate, Pixel guest (run 42). Pixel's DisplayModeDirector gives
# SurfaceFlinger an app-request render range of [0, 120] next to the primary
# [120, 120] the UI activator's min/peak refresh rate set (the cover: [0, inf]
# for both), and on these VRR panels (one mode each, 240 Hz vsync, 120 fps peak,
# rates down to 1 Hz) SurfaceFlinger dropped to 1 Hz within 10 ms of every
# window transition: 9 freezes of 1-2.4 s in 5 minutes (Davey 1038 ms, "Faking
# VSYNC due to driver stall"). ColorOS kept [120, 120] and never did. Each
# panel's primary and app-request render ranges are pinned with SurfaceFlinger's
# backdoor transaction 1035 (i32 mode id, i64 physical display id, f min, f max;
# this image's surfaceflinger: readInt32, readUint64, readFloat twice ->
# setActiveModeFromBackdoor), on the panel's active mode. While pinned,
# SurfaceFlinger ignores DisplayManager's policies
# (setDesiredDisplayModeSpecsInternal returns early on the backdoor flag), so
# the guest's thermal cap and refresh settings no longer reach it. Up to 0.4.22
# the range was [60, 120]: SurfaceFlinger's idle timer (250 ms) and content
# detection then rendered "normal" frame-rate-category content at 60 Hz (S25
# Ultra af6c2b17: 47 s of the first 2 minutes at 60 Hz, 74 s at 120; testers
# said it felt like 60 Hz). Since 0.4.23 it is [N, 120] with N the active
# mode's vsync rate, at most 120: 120 on the S25 Ultra and on the Fold's VRR
# panels (240 Hz vsync), and never more than a panel can show. The parcel result
# and the policy SurfaceFlinger then reports are logged. Pixel only (no
# oplus-services.jar); ONEOS_GUEST_SF_PIN=0 leaves the ranges to DisplayManager.
if [ -e /system/framework/oplus-services.jar ]; then
    :
elif [ "${ONEOS_GUEST_SF_PIN:-1}" = 0 ]; then
    echo "[Pivoted Root] SF render rate left to DisplayManager (ONEOS_GUEST_SF_PIN=0)"
else
    SFDUMP=$(dumpsys SurfaceFlinger 2>/dev/null)
    PINNED=0
    for id in $(dumpsys SurfaceFlinger --display-id 2>/dev/null | sed -n 's/^Display \([0-9][0-9]*\) (HWC display .*/\1/p'); do
        ml=$(echo "$SFDUMP" | awk -v d="$id" '$0 == "Display " d { f = 1; next } f && /^Display / { f = 0 }
            f && /^ *activeMode=\{id=[0-9]+,/ { m = $0; sub(/^ *activeMode=\{id=/, "", m); sub(/,.*/, "", m)
                v = $0; if (!sub(/.*vsyncRate=/, "", v)) v = 0; v = int(v + 0.5); if (v > 120) v = 120
                print m, v; exit }')
        mode=${ml% *} lo=${ml#* }
        case "$mode:$lo" in
            :*|*[!0-9:]*|*:) echo "[Pivoted Root] SF render rate on $id: no active mode in the dump, left alone"; continue ;;
        esac
        [ "$lo" -ge 60 ] || lo=60
        # The call waits on SurfaceFlinger's main thread: never longer than 5 s here.
        r=$(timeout 5 service call SurfaceFlinger 1035 i32 "$mode" i64 "$id" f "$lo" f 120 2>&1 | tr -s ' \n' ' ' | cut -c1-160)
        echo "[Pivoted Root] SF render rate pinned to $lo-120 Hz on $id (mode $mode): $r"
        PINNED=$((PINNED + 1))
    done
    [ "$PINNED" = 0 ] && echo "[Pivoted Root] SF render rate: no physical displays listed yet, left to DisplayManager"
    dumpsys SurfaceFlinger 2>/dev/null | awk '/^Display [0-9]+$/ { d = $2 } /debugDisplayModeSetByBackdoor/ { print "[Pivoted Root] SF " $0 }
        d != "" && /^ *displayManagerPolicy=/ { sub(/^ */, ""); print "[Pivoted Root] SF " d " " substr($0, 1, 440); d = "" }'
fi

# OneOS: screen recording from the boot animation on, when /data/oneos_record
# exists (the stage's data/oneos_record). ColorOS's screenrecord through its own
# SurfaceFlinger and the host's Codec2 encoder; 90 s segments at half size and
# 4 Mbps (each under Telegram's 50 MB), 6 segments. A segment that fails at
# once (SurfaceFlinger not ready yet) is retried. return_to_oneui.sh stops it
# with SIGINT so the last segment is finalised.
if [ -f /data/oneos_record ]; then
    rm -f /data/oneos_rec_*.mp4 /data/oneos_rec_stop
    (
        i=1; tries=0
        # return_to_oneui.sh creates /data/oneos_rec_stop before it stops the
        # recording, so no new segment starts during the teardown.
        while [ $i -le 6 ] && [ $tries -lt 30 ] && [ ! -f /data/oneos_rec_stop ]; do
            start=$(date +%s)
            /system/bin/screenrecord --time-limit 90 --size 1128x1252 --bit-rate 4000000 "/data/oneos_rec_$i.mp4" >> /data/screenrecord.log 2>&1
            if [ $(( $(date +%s) - start )) -ge 10 ]; then i=$((i + 1)); else tries=$((tries + 1)); sleep 2; fi
        done
    ) </dev/null >/dev/null 2>&1 &
    echo "[Pivoted Root] Recording the screen to /data/oneos_rec_N.mp4"
fi

echo "[Pivoted Root] Starting guest BootAnimation..."
setprop service.bootanim.exit 0
/system/bin/bootanimation > /data/anim.log 2>&1 &
ANIM_PID=$!
echo "[Pivoted Root] BootAnimation PID: $ANIM_PID"
sleep 1

# Backlight. With the host framework stopped nothing drives the panel
# brightness until the guest's system_server does, so the boot animation can
# play on a dark panel. Log both Fold panels and keep the inner one
# (panel0-backlight) lit for the first 3 minutes if it sits at 0.
# Snapdragon: panel0-backlight and panel1-backlight; Exynos: panel and panel1.
BL=/sys/class/backlight/panel0-backlight; BL2=/sys/class/backlight/panel1-backlight
[ -d "$BL" ] || { BL=/sys/class/backlight/panel; BL2=/sys/class/backlight/panel1; }
echo "[Pivoted Root] Backlight: inner=$(cat $BL/brightness 2>/dev/null) cover=$(cat $BL2/brightness 2>/dev/null)"
if [ -w "$BL/brightness" ]; then
    $BB sh -c "
        i=0
        while [ \$i -lt 60 ]; do
            # ColorOS drives the panel itself once the UI activator ran.
            [ \"\$(getprop service.bootanim.exit)\" = 1 ] && break
            if [ \"\$(cat $BL/brightness)\" = 0 ]; then
                # 928: about 135 nits on this panel (max/4 was ~660 nits).
                echo 928 > $BL/brightness
                echo \"\$(date +%T) inner backlight was 0, set to \$(cat $BL/brightness)\"
            fi
            sleep 3; i=\$((i + 1))
        done
    " </dev/null >> /data/backlight.log 2>&1 &
fi

# aconfig flag storage. init/aconfigd normally build /metadata/aconfig from
# every partition's and APEX's etc/{package.map,flag.map,flag.val,flag.info};
# the container had none, so flag lookups failed ("failed to open
# /metadata/aconfig/maps/system.package.map") and AdvancedProtectionService
# took system_server down on "Invalid feature flag". Lay out the guest's own
# files the same way on a tmpfs in this namespace.
AC=/metadata/aconfig
if $BB mount -t tmpfs -o mode=755 tmpfs /metadata 2>/dev/null; then
    mkdir -p $AC/maps $AC/boot $AC/flags
    n=0
    add_flags() {
        [ -f "$2/package.map" ] && [ -f "$2/flag.map" ] && [ -f "$2/flag.val" ] || return 0
        cp "$2/package.map" "$AC/maps/$1.package.map"
        cp "$2/flag.map" "$AC/maps/$1.flag.map"
        cp "$2/flag.val" "$AC/boot/$1.val"
        [ -f "$2/flag.info" ] && cp "$2/flag.info" "$AC/boot/$1.info"
        n=$((n + 1))
    }
    add_flags system /system/etc/aconfig
    add_flags system_ext /system_ext/etc/aconfig
    add_flags product /product/etc/aconfig
    add_flags vendor /vendor/etc/aconfig
    for a in /apex/*; do
        case "$a" in *@*) continue ;; esac
        add_flags "$(basename "$a")" "$a/etc"
    done
    chown -R 1000:1000 /metadata/aconfig
    chmod 775 $AC $AC/maps $AC/boot; chmod 770 $AC/flags; chmod 644 $AC/maps/* $AC/boot/* 2>/dev/null
    echo "[Pivoted Root] aconfig storage for $n containers on /metadata"
else
    echo "[Pivoted Root] WARNING: could not mount /metadata for aconfig storage"
fi
# (Built only after surfaceflinger and the boot animation started: with the
# guest's flag values surfaceflinger used composer features Samsung's composer
# rejects, executeCommands BAD_VALUE / presentOrValidate NO_RESOURCES on every
# frame, a black panel. Without flag storage it runs on defaults, which worked.)

# OneOS: the guest framework must get THIS vold, never One UI's (which holds the
# phone's real storage). Up to run 43 both registered "vold" in the shared
# servicemanager, the guest's last. Run 44: with vold_patched bound
# (guest_prepare.sh then writes gvld to /data/oneos_vold_name) the guest vold
# registers "gvld" and neither "vold" nor android.system.vold.IVold/default,
# and the guest framework looks up "gvld" (services.jar, service.incremental.so;
# docs/inplace-return.md). One UI's vold cannot be restarted (init.rc:
# reboot_on_failure), so returning to One UI without a reboot needs both names
# to stay its own all session. "gvld" has no service_contexts entry:
# servicemanager labels it default_android_service, which only this permissive
# session (oneos_switch.sh: setenforce 0) lets the guest add and find. Images
# without vold_patched (ColorOS) keep the guest vold on "vold", as up to run 43.

# The pid servicemanager has for a name, or nothing: only an all-digit line
# counts ("Can't find service: ..." is not a pid).
svc_pid() {
    o=$(timeout 5 dumpsys --pid "$1" 2>/dev/null | head -n 1)
    case "$o" in ''|*[!0-9]*) ;; *) echo "$o" ;; esac
}
# Why One UI's vold no longer has its names, or nothing: "vold" is the pid init
# started it as, and android.system.vold.IVold/default, when registered, too.
host_vold_lost() {
    hv=$(svc_pid vold)
    if [ -z "$HOST_VOLD" ] || [ "$hv" != "$HOST_VOLD" ]; then
        echo "servicemanager's vold is pid '$hv', not One UI's vold '$HOST_VOLD' (init.svc_debug_pid.vold)"
    elif [ "$(getprop init.svc_debug_pid.vold)" != "$HOST_VOLD" ]; then
        echo "One UI's vold is pid '$(getprop init.svc_debug_pid.vold)' now, was $HOST_VOLD"
    elif service check android.system.vold.IVold/default 2>/dev/null | grep -q ': found'; then
        hv=$(svc_pid android.system.vold.IVold/default)
        [ "$hv" = "$HOST_VOLD" ] || echo "android.system.vold.IVold/default is pid '$hv', not One UI's vold $HOST_VOLD"
    fi
}
# For the log: android.system.vold.IVold/default's pid, if registered.
vdef() { hv=$(svc_pid android.system.vold.IVold/default); echo "${hv:-not registered}"; }
VOLD_NAME=vold
if [ "$(cat /data/oneos_vold_name 2>/dev/null)" = gvld ]; then
    VOLD_NAME=gvld
    HOST_VOLD=$(getprop init.svc_debug_pid.vold)
    why=$(host_vold_lost)
    # Bound by guest_prepare.sh, which checked them against guards.txt. And the
    # services.jar: one that still looked up "vold" would hand the guest
    # StorageManagerService One UI's vold (connectVold, then IVold.reset()).
    # Its patched dex is stored, not deflated (make-overlays.sh: zip -0). On
    # ColorOS also oplus-services.jar (OplusStorageManagerFeature.connectVold),
    # HyperOS miui-services.jar (ExtendMImpl, AppCacheOptimizer).
    for f in /system/bin/vold /system/lib64/service.incremental.so /system/framework/services.jar \
             $([ -f /system/framework/oplus-services.jar ] && echo /system/framework/oplus-services.jar) \
             $([ -f /system/system_ext/framework/miui-services.jar ] && echo /system/system_ext/framework/miui-services.jar); do
        $BB grep -q gvld "$f" || why="$f is not the gvld build"
    done
    [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = 1 ] && why="SELinux is enforcing: servicemanager refuses gvld (default_android_service)"
    # RecoverySystem.rebootPromptAndWipeUserData (framework.jar) asks
    # checkService("vold"), One UI's vold now, for needsCheckpoint/abortChanges.
    # services.jar no longer calls it (patches/guest_storage_guards.py,
    # guest_own_vold.py); RescueParty's factory reset (crashrecovery APEX) does,
    # only when RescueParty is on: isDisabled() is false with
    # persist.sys.enable_rescue, true with persist.sys.disable_rescue
    # (oneos_switch.sh [1/6]).
    case "$(getprop persist.sys.disable_rescue)" in true|1|y|yes|on) ;; *) why="persist.sys.disable_rescue is not true (RescueParty would reach One UI's vold)" ;; esac
    case "$(getprop persist.sys.enable_rescue)" in true|1|y|yes|on) why="persist.sys.enable_rescue is set (RescueParty would reach One UI's vold)" ;; esac
    if [ -n "$why" ]; then
        echo "[Pivoted Root] FATAL: $why. Not starting the guest."
        exit 1
    fi
    echo "[Pivoted Root] One UI's vold: pid $HOST_VOLD, android.system.vold.IVold/default: $(vdef); SELinux $(getenforce 2>/dev/null); the guest's will register gvld"
fi
echo "[Pivoted Root] Starting guest Vold..."
/system/bin/vold --blkid_context=u:r:blkid:s0 --blkid_untrusted_context=u:r:blkid_untrusted:s0 --fsck_context=u:r:fsck:s0 --fsck_untrusted_context=u:r:fsck_untrusted:s0 > /data/vold.log 2>&1 &
VOLD_PID=$!
echo "[Pivoted Root] Vold PID: $VOLD_PID"
n=0
while [ $n -lt 50 ]; do
    [ "$(svc_pid $VOLD_NAME)" = "$VOLD_PID" ] && break
    n=$((n + 1)); sleep 0.2
done
if [ "$(svc_pid $VOLD_NAME)" != "$VOLD_PID" ]; then
    echo "[Pivoted Root] FATAL: servicemanager's $VOLD_NAME is pid '$(dumpsys --pid $VOLD_NAME 2>&1 | head -n 1)', not the guest's $VOLD_PID. Not starting the guest."
    exit 1
fi
echo "[Pivoted Root] servicemanager's $VOLD_NAME is the guest's ($VOLD_PID)"
# And One UI's vold kept both its names. Again right before zygote: the guest
# vold's vendor name would come a moment after gvld.
if [ "$VOLD_NAME" = gvld ]; then
    why=$(host_vold_lost)
    if [ -n "$why" ]; then
        echo "[Pivoted Root] FATAL: $why. Not starting the guest."
        exit 1
    fi
    echo "[Pivoted Root] One UI's vold ($HOST_VOLD) still has vold and android.system.vold.IVold/default ($(vdef))"
fi

# Wifi. oneos_switch.sh stops the host wificond; the guest's own registers
# IWificond before WifiService initialises, and drives Samsung's wifi HAL (which
# is still registered by host init) with matching AIDL.
# Pixel 17 has none and needs none: its wifi module drives nl80211 itself
# (useWificond: false); oneos_switch.sh restarts One UI's idle.
if [ -x /system/bin/wificond ]; then
    echo "[Pivoted Root] Starting guest wificond..."
    /system/bin/wificond > /data/wificond.log 2>&1 &
    WIFICOND_PID=$!
    echo "[Pivoted Root] wificond PID: $WIFICOND_PID"
    sleep 1
else
    echo "[Pivoted Root] No wificond in the image: the guest's wifi module drives nl80211 itself"
fi

# ColorOS list/feedback daemons ("class main" in system_ext/etc/init/
# mmlistservice.rc and atlasservice.rc; host init never starts them). ColorOS's
# AudioTrack, ToneGenerator and NuPlayer and its audioserver look them up with a
# blocking getService(): 5 s per lookup, several per track (run 29: Telecom built
# its call-connected tone for 25 s under its lock; the hang-up waited 16 s).
# Other systems (Pixel) have neither: no wait then.
MMLIST=0
for d in "/system_ext/bin/mmlistservice" "/system_ext/bin/atlasservice"; do
    [ -x "$d" ] || continue
    "$d" > /dev/null 2>&1 &
    echo "[Pivoted Root] $(basename "$d") PID: $!"
    MMLIST=1
done
if [ "$MMLIST" = 1 ]; then
    n=0
    while [ $n -lt 25 ] && ! service check MMListService 2>/dev/null | grep -q ": found"; do n=$((n + 1)); sleep 0.2; done
    echo "[Pivoted Root] MMListService:$(service check MMListService 2>/dev/null | cut -d: -f2), AtlasService:$(service check AtlasService 2>/dev/null | cut -d: -f2) after $((n / 5))s"
fi

# Guest media stack (see oneos_switch.sh: the host's copies are stopped).
# ColorOS ships mediaserverwrapper on Qualcomm; its plain mediaserver is 32-bit
# only and cannot run on this arm64-only phone.
if [ -f /data/guest_media.flag ]; then
    echo "[Pivoted Root] Starting guest media services..."
    # The wrapper picks mediaserver64 only when ro.mediaserver.64b.enable is
    # set, which OPPO's vendor does and Samsung's does not; it then ran the
    # 32-bit one, and media.player / media.resource_manager never registered.
    # Pixel has only a 64-bit /system/bin/mediaserver.
    MS=/system/bin/mediaserver64
    [ -x "$MS" ] || MS=/system/bin/mediaserverwrapper
    [ -x "$MS" ] || MS=/system/bin/mediaserver
    $MS > /dev/null 2>&1 &
    echo "[Pivoted Root] $(basename $MS) PID: $!"
    /system/bin/mediaextractor > /dev/null 2>&1 &
    echo "[Pivoted Root] mediaextractor PID: $!"
    /system/bin/mediametrics > /dev/null 2>&1 &
    echo "[Pivoted Root] mediametrics PID: $!"
fi

# Guest audioserver (oneos_switch.sh stopped Samsung's): ColorOS's audio
# interfaces are not numbered like Samsung's (run 29: no routing strategies,
# volume groups or ports; Samsung's AudioFlinger refused every app stream). The
# guest's drives Samsung's audio HAL through the stable audio.core AIDL, as a
# GSI does. It registers media.audio_flinger/media.audio_policy only after the
# guest framework's "activity" service exists (run 30: it waited for it, while
# this script waited for it to register before starting zygote), so it is
# started here and watched alongside the boot: if it has not registered after
# 60 s, or keeps dying, Samsung's audioserver takes over (AudioService waits
# for the policy service without a timeout).
if [ -f /data/guest_audio.flag ]; then
    echo "[Pivoted Root] Starting guest audioserver..."
    mkdir -p /data/misc/audioserver && chown 1041:1005 /data/misc/audioserver && chmod 0700 /data/misc/audioserver
    n=0
    while [ $n -lt 50 ] && ! service check android.hardware.audio.core.IModule/default 2>/dev/null | grep -q ": found"; do n=$((n + 1)); sleep 0.2; done
    echo "[Pivoted Root] audio HAL IModule/default:$(service check android.hardware.audio.core.IModule/default 2>/dev/null | cut -d: -f2) after $((n / 5))s"
    # A2DP offload (run 44): Samsung's QTI HAL turns its Bluetooth offload path
    # on only from the vendor parameter l_a2dp_format (bit 21 of the number,
    # Platform+8), which One UI's audioserver sends and a GSI's never does: every
    # connect logged "bt_offload state is disabled" and the earbuds played on the
    # speaker. Sent with the call keeper's IModule parcel (sizes 124, 76, 24 for
    # 2097152) and again whenever the HAL restarts. Never l_support_sec_audio_feature,
    # which would switch the HAL to One UI's module config. The value lives in the
    # HAL process only, and the return restarts the HAL before One UI's
    # audioserver. ColorOS guests: untouched. ONEOS_GUEST_A2DP_FORMAT=0 skips it.
    # Each send is checked against the HAL's own log, as the call keeper does
    # (run 43: a binder reply of 00000000 for a key the HAL never got), and
    # oneos_a2dp.log gets the HAL's line ("configured l_a2dp_format", or "not
    # configured ..." for a key it does not take). The log, like the keepers'
    # logs, grows across sessions: each session starts with a dated line.
    A2F=${ONEOS_GUEST_A2DP_FORMAT:-2097152}
    case "$A2F" in ""|*[!0-9]*) A2F=0 ;; esac
    if [ "$A2F" != 0 ] && [ ! -f /system/framework/oplus-services.jar ]; then
        echo "=== $(date '+%F %T') session: l_a2dp_format=$A2F to the audio HAL" >> /data/oneos_a2dp.log
        $BB sh -c 'v=$1; bb=$2
            s16() { echo $((4 + (${#1} * 2 + 5) / 4 * 4)); }
            vs=$((4 + $(s16 "$v"))); hs=$(($(s16 qti.audio.core.VString) + vs)); ps=$((4 + $(s16 l_a2dp_format) + 12 + hs))
            # The HAL (pid h) line for the key, the last one; empty if none.
            seen() { logcat -d --pid="$h" -s AHAL_SecModulePrimary 2>/dev/null | $bb grep -F "configured l_a2dp_format" | tail -n 1; }
            hp=""; n=0
            while :; do
                h=$(dumpsys --pid android.hardware.audio.core.IModule/default 2>/dev/null | head -n 1 | tr -dc 0-9)
                if [ -n "$h" ] && [ "$h" != "$hp" ]; then
                    b=$(seen)
                    r=$(service call android.hardware.audio.core.IModule/default 34 i32 1 i32 1 i32 $ps s16 l_a2dp_format i32 1 i32 1 i32 $hs s16 qti.audio.core.VString i32 $vs s16 "$v" i32 0 2>&1 | tr -s " \n" " " | head -c 100 | $bb sed "s/ *\$//")
                    sleep 1; a=$(seen)
                    [ -n "$a" ] && [ "$a" != "$b" ] || { sleep 2; a=$(seen); }
                    if [ -n "$a" ] && [ "$a" != "$b" ]; then ok="HAL: ${a#*: }"
                    else ok="HAL NEVER logged it (no AHAL_SecModulePrimary line for l_a2dp_format from pid $h)"; fi
                    echo "$(date +%T) l_a2dp_format=$v (sizes $ps $hs $vs) to the audio HAL pid $h: $r; $ok"
                    # Not logged by the HAL: sent again on the next round, 3 tries per HAL pid.
                    if [ -n "$a" ] && [ "$a" != "$b" ]; then hp=$h; n=0
                    else n=$((n + 1)); [ $n -lt 3 ] || { hp=$h; n=0; echo "$(date +%T) l_a2dp_format: gave up on HAL pid $h after 3 tries"; }; fi
                fi
                sleep 10
            done' oneos_a2dp "$A2F" "$BB" >> /data/oneos_a2dp.log 2>&1 &
        echo "[Pivoted Root] A2DP offload: l_a2dp_format=$A2F to the audio HAL, again on every HAL restart, each send checked in the HAL log (/data/oneos_a2dp.log)"
    else
        echo "[Pivoted Root] A2DP offload: l_a2dp_format not sent ($([ "$A2F" = 0 ] && echo ONEOS_GUEST_A2DP_FORMAT=0 || echo ColorOS guest))"
    fi
    /system/bin/audioserver > /dev/null 2>&1 &
    AS_PID=$!
    echo "[Pivoted Root] guest audioserver PID: $AS_PID (registers once the guest framework is up)"
    echo "=== $(date '+%F %T') session: guest audioserver $AS_PID" >> /data/audio_keeper.log
    $BB sh -c 'as=$1
        owner() { dumpsys --pid media.audio_policy 2>/dev/null | tr -dc 0-9; }
        handover() {
            kill -9 $as 2>/dev/null; rm -f /data/guest_audio.flag
            setprop ctl.start audioserver
            echo "$(date +%T) $1; handed over to the host audioserver"
        }
        t=0
        while [ $t -lt 60 ] && [ "$(owner)" != "$as" ] && kill -0 $as 2>/dev/null; do sleep 2; t=$((t + 2)); done
        if [ "$(owner)" != "$as" ]; then handover "guest audioserver did not register in ${t}s"; exit 0; fi
        echo "$(date +%T) guest audioserver $as registered after ${t}s"
        # Keep it the one servicemanager hands out (host init can bring
        # Samsung audioserver back through the HAL onrestart). Log why it
        # restarts. No apostrophes anywhere in this script: it is one
        # single-quoted sh -c argument, and the two this comment had (runs
        # 31-33) cut it here, so as was the word through, kill -0 failed,
        # every session handed over at 0s and dropped guest_audio.flag
        # while the guest audioserver went on serving (run 33: 15587 owned
        # media.audio_policy from 14:41:42 next to Samsung 15619).
        miss=0; r=0
        while [ -f /data/guest_audio.flag ]; do
            sleep 3
            if ! kill -0 $as 2>/dev/null; then why="died"
            elif [ "$(owner)" != "$as" ]; then why="media.audio_policy taken"
            else miss=0; continue; fi
            miss=$((miss + 1)); [ $miss -lt 2 ] && continue
            kill -9 $as 2>/dev/null
            if [ $r -ge 4 ]; then handover "guest audioserver $why 5 times"; break; fi
            /system/bin/audioserver > /dev/null 2>&1 & as=$!; miss=0; r=$((r + 1))
            echo "$(date +%T) guest audioserver $why, restarted as $as"
        done' sh "$AS_PID" </dev/null >> /data/audio_keeper.log 2>&1 &
fi

# Voice calls (run 32): a call on SIM 2 connected with no audio either way
# while media played. all.log 13:16:53: GsmCdmaCallTracker [1] OFFHOOK, and
# AHAL_Telephony_QTI "switchAudioMode: new call state is ACTIVE for vsid
# VSID_1", voice graph "..._VSID_VSID_DEFAULT". Samsung's HAL starts the voice
# session on the VSID that g_call_sim_slot last chose (Telephony::
# updateSecVSID: 0x01 -> VSID_1 0x11C05000, 0x02 -> VSID_2 0x11DC5000; VSID_1
# until told), and One UI's audioserver sends it right before every
# setMode(IN_CALL) (run 29: "CallStateManager: getCallSetParamByGuard:
# g_call_sim_slot=0x01"). ColorOS's audioserver never does, so the ADSP ran
# SIM 1's voice session while the modem had the call on SIM 2. Tell the HAL
# through the guest AudioFlinger's setParameters (IAudioFlingerService
# transaction 18 in this image's audioflinger-aidl-cpp.so). While idle: the
# ringing SIM, else the SIM of the last call (kept in /data/oneos_call_slot).
# An outgoing call reaches the HAL (Telecom's setMode) before the phone
# reports OFFHOOK, and the HAL skips a plain 0x01/0x02 while a call runs in
# IN_CALL mode, so a call already on the wrong VSID gets 0x10, the HAL's own
# swap (stop and restart the voice session on the other VSID). The HAL's own
# log (its current pid only) says which VSID it is on; call_audio.log keeps
# the decisions. ONEOS_GUEST_CALL_SIM=0 leaves the HAL alone.
# Run 33: call_audio.log stayed empty and all five calls ran on VSID_1 (SIM 1
# fine; SIM 2 silent, not even ringback; all.log 14:53:32, 14:53:59, 14:55:47)
# because the keeper above had dropped guest_audio.flag at 14:41:31 (see
# there), so this loop skipped every turn. From hal.so: updateSecVSID only
# stores 0x01/0x02 in mCurVSID while idle, and switchAudioMode copies that
# into the call at setMode(IN_CALL); during a call in IN_CALL mode it logs
# "skip to change vsid to VSID_n during call" and does nothing; 0x10
# (SIM_FORCE_UPDATE) needs a running call and restarts it on the OTHER VSID.
# Telecom setMode reached the HAL 16-20 ms either side of OFFHOOK, so an
# outgoing call on the other SIM always starts wrong: it gets 0x10 at once,
# and only once (a second one would swap back).
# OneOS: only with a vendor audio HAL that has both g_call_sim_slot and
# updateSecVSID (read from the F8U HAL only), looked up first in the vendor
# audio libraries the way oneos_switch.sh greps the sysinput HAL; without
# them the loop logs that and stops. ONEOS_GUEST_CALL_SIM=2 skips the look.
# Run 43 (Pixel): every SIM 2 call in runs 41-43 ran on VSID_1 and was silent
# both ways. AudioFlinger returned OK, but the HAL never logged "configured
# g_call_sim_slot": Pixel's libaudiohal@aidl hands unknown keys to
# IModule.setVendorParameters only through an IHalAdapterVendorExtension, and
# with ro.audio.ihaladaptervendorextension_enabled=false (guest_props.sh, run
# 38) it has none and drops them without a log line. One UI's and ColorOS's
# QTI audioservers load that extension (libaudiohalvendorextn.so) in-process,
# which is why ColorOS's keys arrived (run 34). So unless the property is true
# the keeper sends the key straight to the shared HAL (IModule/default
# transaction 34) with the parcel that extension builds, and checks every send
# against the HAL's own log. The path is checked as soon as the HAL is known
# (af: once the guest audioserver has registered; nothing goes out on a path
# that is not ready), before any call; when it is not delivered the keeper
# switches path once, and only on an idle 0x01/0x02 (never a 0x10), after a
# second look for a late HAL line. ONEOS_GUEST_CALL_SIM_VIA=af|hal
# forces the first path (af: through the guest AudioFlinger).
# call_audio.log grows across sessions and its lines carry the time only (run
# 44's capture still had a session of 09:07 before run 44's): a dated line
# first.
if [ -f /data/guest_audio.flag ] && [ "${ONEOS_GUEST_CALL_SIM:-1}" != 0 ]; then
    echo "=== $(date '+%F %T') session" >> /data/call_audio.log
    $BB sh -c 'bb=$1
        if [ "$2" != 2 ]; then
            lib=""
            for f in $(grep -l -s -F g_call_sim_slot /vendor/lib64/*audio*.so /vendor/lib64/hw/*audio*.so /vendor/bin/hw/*audio* 2>/dev/null); do
                grep -q -s -F updateSecVSID "$f" && { lib=$f; break; }
            done
            if [ -z "$lib" ]; then
                echo "$(date +%T) no vendor audio library has g_call_sim_slot and updateSecVSID: SIM slot loop off"
                exit 0
            fi
            echo "$(date +%T) audio HAL keys found in $lib"
        fi
        # How g_call_sim_slot reaches the HAL (run 43): af through the guest
        # AudioFlinger, whose libaudiohal forwards vendor keys only through
        # the QTI vendor extension (property true: ColorOS, run 34), or hal
        # straight to IModule/default. $3 is ONEOS_GUEST_CALL_SIM_VIA.
        ve=$(getprop ro.audio.ihaladaptervendorextension_enabled)
        case $3 in
            af|hal) via=$3; why="ONEOS_GUEST_CALL_SIM_VIA" ;;
            *) if [ "$ve" = true ]; then via=af; else via=hal; fi; why="ro.audio.ihaladaptervendorextension_enabled=${ve:-unset}" ;;
        esac
        first=$via; tried=""; probed=""
        # Which library gives the HAL qti.audio.core.VString (the ext type
        # below), and whether the HAL could check the caller uid (the keeper
        # is root, an audioserver 1041). Audio libraries only: boot is busy.
        vt=$(grep -l -s -F qti.audio.core.VString /vendor/lib64/*audio*.so /vendor/lib64/hw/*audio*.so 2>/dev/null | head -n 2 | tr "\n" " "); vt=${vt% }
        uc=$([ -n "$lib" ] && grep -c -s -F AIBinder_getCallingUid "$lib")
        echo "$(date +%T) g_call_sim_slot path $via first ($why; extension service:$(service check android.media.audio.IHalAdapterVendorExtension/default 2>&1 | cut -d: -f2))"
        # Run 44: true (the image value) kept SCO closed; guest_props.sh now
        # leaves it out for Pixel guests, so unset is what a call needs.
        sm=$(getprop bluetooth.sco.managed_by_audio)
        echo "$(date +%T) VString in: ${vt:-none}; AIBinder_getCallingUid in the HAL: ${uc:-?}; bluetooth.sco.managed_by_audio=${sm:-unset}"
        # IModule.setVendorParameters is transaction 34 (BpModule in the
        # image android.hardware.audio.core-V4-ndk.so). The parcel is the one
        # the QTI extension builds, the layout ColorOS sent in run 34:
        # count 1, non-null 1, VendorParameter {size, String16 id, non-null 1,
        # holder stability 1 (VINTF, the only one the HAL reads), holder size,
        # String16 qti.audio.core.VString, VString {size, String16 value}},
        # then async false. Each size counts its own 4 bytes; s16 is the size
        # of a String16 (length, UTF-16 with a NUL, padded to 4). For 0x10 the
        # data after the interface token is 136 bytes, sizes 124, 72 and 20.
        s16() { echo $((4 + (${#1} * 2 + 5) / 4 * 4)); }
        send() {
            if [ "$1" = hal ]; then
                vs=$((4 + $(s16 "$2"))); hs=$(($(s16 qti.audio.core.VString) + vs)); ps=$((4 + $(s16 g_call_sim_slot) + 12 + hs))
                service call android.hardware.audio.core.IModule/default 34 i32 1 i32 1 i32 $ps s16 g_call_sim_slot i32 1 i32 1 i32 $hs s16 qti.audio.core.VString i32 $vs s16 "$2" i32 0 2>&1
            else
                service call media.audio_flinger 18 i32 0 s16 "g_call_sim_slot=$2" 2>&1
            fi | tr -s " \n" " " | head -c 100 | $bb sed "s/ *\$//"
        }
        # Delivered when the last "configured g_call_sim_slot" line of the
        # HAL (its current pid) changed: its timestamp makes it unique, while
        # a count can stay the same as the log buffer rotates (all.log runs at
        # about 700 lines a second). A line can reach logd late, so a send is
        # called lost only after a second look 1 s later: a late line taken
        # for the other path would switch to a path that drops the key.
        seen() { logcat -d --pid="$hp" -s AHAL_SecModulePrimary 2>/dev/null | $bb grep -F "configured g_call_sim_slot" | tail -n 1; }
        got() { a=$(seen); [ -n "$a" ] && [ "$a" != "$b" ]; }
        dlv() { sleep 0.5; got || { sleep 1; got; }; }
        # af needs the guest audioserver, which registers late (run 30).
        ready() { [ "$1" = hal ] || service check media.audio_policy 2>/dev/null | $bb grep -q ": found"; }
        other() { if [ "$1" = hal ]; then echo af; else echo hal; fi; }
        # Returns 1 when nothing was sent (no flag, no HAL pid, path not
        # ready yet), so the caller tries again on a later turn.
        setp() {
            [ -f /data/guest_audio.flag ] && [ -n "$hp" ] && ready $via || return 1
            b=$(seen); r=$(send $via "$1")
            if dlv; then ok="HAL got it"; else ok="HAL NEVER got it"; fi
            w=$(hal); echo "$(date +%T) g_call_sim_slot=$1 via $via ($2): $r; $ok; HAL state ${w:-none}"
            # Switch path once, and only on an idle 0x01 or 0x02, which set
            # the same VSID however often they come. Never resend a 0x10
            # swap: a late first copy plus a second one would swap back.
            [ "$ok" = "HAL got it" ] || [ "$1" = 0x10 ] || [ -n "$tried" ] || ! ready "$(other $via)" || {
                tried=1; via=$(other $via)
                b=$a; r=$(send $via "$1")
                if dlv; then w=$(hal); echo "$(date +%T) g_call_sim_slot=$1 again via $via: $r; HAL got it, path $via from now on; HAL state ${w:-none}"; return 0; fi
                echo "$(date +%T) g_call_sim_slot=$1 again via $via: $r; HAL NEVER got it on either path, staying on $first"
                via=$first
                logcat -d --pid="$hp" -t 400 2>/dev/null | $bb grep -i -E "vendor|parcel|g_call" | tail -n 4
            }
            return 0
        }
        # What the HAL log (its current pid) said last: A1/A2 a call runs on
        # VSID_1/2 (a 0x10 swap counts at once, its updateCalls lines can
        # come later), I1/I2 idle and the next call starts on VSID_1/2,
        # empty if nothing yet. mCurVSID is logged only when it changes.
        hal() {
            [ -n "$hp" ] || return
            logcat -d --pid="$hp" -s AHAL_Telephony_QTI 2>/dev/null | $bb grep -o -E "INACTIVE -> ACTIVE vsid:VSID_[12]|ACTIVE -> INACTIVE vsid:VSID_[12]|change vsid to VSID_[12] by|mCurVSID to VSID_[12]" | tail -n 1 | $bb sed -e "s/^INACTIVE.*_\([12]\)\$/A\1/" -e "s/^change.*_\([12]\) by\$/A\1/" -e "s/^[Am].*_\([12]\)\$/I\1/"
        }
        cur=""; last=$(cat /data/oneos_call_slot 2>/dev/null); call=""; n=0; hp=""; on=""
        echo "$(date +%T) started, last call on SIM slot ${last:-none}"
        while true; do
            sleep 2
            if [ -f /data/guest_audio.flag ]; then f=1; else f=0; fi
            [ "$f" = "$on" ] || { on=$f; echo "$(date +%T) guest_audio.flag $([ $f = 1 ] && echo present, watching calls || echo gone, idle)"; }
            [ $f = 1 ] || continue
            # A restarted HAL starts over on VSID_1.
            h=$(dumpsys --pid android.hardware.audio.core.IModule/default 2>/dev/null | tr -dc 0-9)
            [ "$h" = "$hp" ] || { echo "$(date +%T) audio HAL pid ${h:-none}"; hp=$h; cur=""; }
            # The path check (run 43), once, as soon as the HAL is known and
            # before any call: the SIM of the last call (the idle send below
            # would come first anyway), else 0x01, which a restarted HAL is on.
            [ -n "$probed" ] || [ -z "$hp" ] || ! ready $via || {
                probed=1
                if [ -n "$last" ]; then setp 0x0$((last + 1)) "path check, last call was on SIM slot $last" && cur=$last
                else setp 0x01 "path check, VSID_1 as the HAL starts"; fi
            }
            st=$(dumpsys telephony.registry 2>/dev/null | $bb awk -F= "/^ *Phone Id=/ { p = \$2 } /^ *mCallState=/ { print p \":\" \$2 }")
            [ -n "$st" ] || continue
            ring=""; off=""
            for e in $st; do
                case ${e#*:} in 1) ring=${e%:*} ;; 2) off=${e%:*} ;; esac
            done
            if [ -z "$off" ]; then
                call=""; n=0; t=${ring:-$last}
                if [ -n "$t" ] && [ "$t" != "$cur" ]; then
                    if [ -n "$ring" ]; then setp 0x0$((t + 1)) "SIM slot $t ringing"; else setp 0x0$((t + 1)) "last call was on SIM slot $t"; fi && cur=$t
                fi
                continue
            fi
            [ "$call" = "$off" ] || { call=$off; n=0; }
            [ $n -ge 3 ] && continue
            n=$((n + 1)); want=$((off + 1)); s=$(hal)
            case $s in
                ?$want) ;;
                A?) setp 0x10 "call on SIM slot $off runs on VSID_${s#A}" && n=3; sleep 0.5; s=$(hal) ;;
                *) setp 0x0$want "call on SIM slot $off, HAL ${s:-silent}"; sleep 0.5; s=$(hal) ;;
            esac
            echo "$(date +%T) call on SIM slot $off: HAL ${s:-?}"
            [ "${s#?}" = "$want" ] && n=3
            [ $n -ge 3 ] || continue
            last=$off; echo "$off" > /data/oneos_call_slot
            if [ "${s#?}" = "$want" ]; then cur=$off; else cur=""; fi
        done' sh "$BB" "${ONEOS_GUEST_CALL_SIM:-1}" "${ONEOS_GUEST_CALL_SIM_VIA:-}" </dev/null >> /data/call_audio.log 2>&1 &
fi

# ColorOS system daemons that its init would start on demand ("interface aidl"
# in cotad.rc / defrag.rc). The host's init refuses ctl.interface_start for
# services it does not know, and oplus-services waits for them.
for d in "/system_ext/bin/cotad" "/system_ext/bin/oplus_defrag"; do
    [ -x "$d" ] || continue
    "$d" > /dev/null 2>&1 &
    echo "[Pivoted Root] $(basename "$d") PID: $!"
done

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
# sweep creates them while the guest runs, so Play Store/Aurora installs become
# launchable within ~15 s.
if [ -x /system/bin/setsid ]; then
    setsid /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
else
    /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
fi
echo "[Pivoted Root] App storage sweeper started..."


# Fresh netd for the guest. The DNS resolver lives in the host's netd and
# hands IDnsResolver.getUnstableInterface() to AID_SYSTEM only once; One UI's
# system_server took it at boot, so the guest's ConnectivityService died with
# "Already called by AID_SYSTEM". netd's rc has "onrestart restart zygote":
# oneos_switch.sh's loop stops the host zygote again, and the stale
# zygote sockets are removed just below, before the guest's launcher binds
# its own. Wifi is already down while the guest boots.
echo "[Pivoted Root] Restarting the host netd for a fresh DNS resolver..."
setprop ctl.restart netd
n=0
while [ $n -lt 50 ]; do
    [ "$(getprop init.svc.netd)" = running ] && service check dnsresolver 2>/dev/null | grep -q ": found" && break
    n=$((n + 1)); sleep 0.2
done
echo "[Pivoted Root] netd: $(getprop init.svc.netd), dnsresolver: $(service check dnsresolver 2>/dev/null | cut -d: -f2) after $((n / 5))s"
sleep 1


# Fresh GNSS HAL for the guest. The One UI app com.qualcomm.location holds the
# HAL A-GPS callback (vendor.qti.gnss ILocAidlAGnss.setCallbackExt), and libgnss
# keeps the callback with the higher priority (GnssAdapter::initAgpsCommand,
# cbPriority), so the IAGnss callback the guest sets at boot was ignored. That
# app died with One UI (run 34 16:28:34.332 IAGnssCallback died) and the guest
# image has none (IZatManager: IzatService not installed), so every SUPL data
# request went nowhere: 16:34:19.116 requestATL, Peer has gone, 15 s later
# LocSvc_Agps timeout. GPS ran without assistance and Weather gave up after
# 57 s four times. A restarted HAL has no callbacks until the guest sets its
# own. gnss_service has no onrestart actions and the return reboots anyway.
# ONEOS_GUEST_GNSS_RESTART=0 leaves the HAL alone.
if [ "${ONEOS_GUEST_GNSS_RESTART:-1}" != 0 ] && [ -n "$(getprop init.svc.gnss_service)" ]; then
    echo "[Pivoted Root] Restarting the vendor GNSS HAL (A-GPS callback for the guest)..."
    setprop ctl.restart gnss_service
    n=0
    while [ $n -lt 25 ]; do
        sleep 0.2; n=$((n + 1))
        [ "$(getprop init.svc.gnss_service)" = running ] && service check android.hardware.gnss.IGnss/default 2>/dev/null | grep -q ": found" && break
    done
    echo "[Pivoted Root] gnss_service: $(getprop init.svc.gnss_service), pid $(getprop init.svc_debug_pid.gnss_service) after $((n / 5))s"
fi

# OneOS: the guest's own idmap2d for the whole session (its overlay manager no
# longer asks host init to start One UI's, which cannot see the guest's
# partitions; switcher/patches/guest_own_idmap.py).
/system/bin/idmap2d > /data/idmap2d.log 2>&1 &
IDMAP_PID=$!
n=0
while [ $n -lt 25 ] && [ "$(dumpsys --pid idmap 2>/dev/null | tr -dc 0-9)" != "$IDMAP_PID" ]; do
    n=$((n + 1)); sleep 0.2
done
echo "[Pivoted Root] idmap2d PID: $IDMAP_PID, servicemanager's idmap: $(dumpsys --pid idmap 2>/dev/null | tr -dc 0-9)"
if [ -f /data/guest_media.flag ]; then
    echo "[Pivoted Root] media.player: $(service check media.player 2>/dev/null | cut -d: -f2), media.resource_manager: $(service check media.resource_manager 2>/dev/null | cut -d: -f2)"
fi

# The guest vold names, last before the guest framework starts (see above).
if [ "$VOLD_NAME" = gvld ]; then
    why=$(host_vold_lost)
    [ "$(svc_pid gvld)" = "$VOLD_PID" ] || why="servicemanager's gvld is pid '$(svc_pid gvld)', not the guest vold's $VOLD_PID"
    if [ -n "$why" ]; then
        echo "[Pivoted Root] FATAL: $why. Not starting the guest."
        exit 1
    fi
    echo "[Pivoted Root] Before zygote: gvld is the guest vold's ($VOLD_PID); vold One UI's ($HOST_VOLD), android.system.vold.IVold/default $(vdef)"
fi

# Forced JIT zygote (run 44). OneLineage's zygote_exec always passed
# -Xforcejitzygote, and so did ours: ART then ignores the image's own AOT boot
# image (/system/framework/arm64/boot*.art/.oat/.vdex, built with the image
# for its ART module and framework jars), compiles the boot class path in
# memory at every zygote start (run 44: dex2oat64 --compiler-filter=verify
# --oat-location=/nonx/arm64/boot.oat, 1.4 s, 3.4 s CPU) and runs framework
# code JIT-compiled only, in every guest process. zygote_exec (zygote_launcher.c)
# passes the flag only with ONEOS_GUEST_JIT_ZYGOTE=1: the default for ColorOS
# guests (oplus-services.jar), which have only ever run that way and are
# untested without it; 0, the image's boot image, for the others (Pixel).
case "${ONEOS_GUEST_JIT_ZYGOTE:-}" in
    0|1) JIT_WHY="ONEOS_GUEST_JIT_ZYGOTE=$ONEOS_GUEST_JIT_ZYGOTE" ;;
    *)
        [ -n "${ONEOS_GUEST_JIT_ZYGOTE:-}" ] && echo "[Pivoted Root] ONEOS_GUEST_JIT_ZYGOTE=$ONEOS_GUEST_JIT_ZYGOTE is not 0 or 1: the default"
        if [ -e /system/framework/oplus-services.jar ]; then
            ONEOS_GUEST_JIT_ZYGOTE=1; JIT_WHY="ColorOS default, oplus-services.jar"
        else
            ONEOS_GUEST_JIT_ZYGOTE=0; JIT_WHY="default, no oplus-services.jar"
        fi ;;
esac
export ONEOS_GUEST_JIT_ZYGOTE
if [ "$ONEOS_GUEST_JIT_ZYGOTE" = 1 ]; then
    echo "[Pivoted Root] zygote: -Xforcejitzygote ($JIT_WHY): boot class path compiled in memory, framework JIT only"
else
    # Whether ART can take that image: besides the jars' checksums (the image's
    # own jars, art_payload.img and i18n_payload.img from the image's APEXes)
    # it checks the boot oat's apex-versions (the image's build: "/" for each
    # factory module) against the versions /apex/apex-info-list.xml gives the
    # boot class path's modules. guest_prepare.sh copies One UI's list there
    # when the set has no clean_apex_info_list.xml, and an updated One UI ART
    # module makes ART reject the image (run 44's guest app_process tools:
    # "ValidateApexVersions found APEX versions mismatch ... Oat file:
    # '//////', Runtime: '/1792624397/..."). The zygote then compiles the boot
    # class path in memory, as with the flag. Read only.
    UPD=$(awk 'BEGIN { RS = "<" } /^apex-info[[:space:]]/ && /moduleName="com\.android\.(art|i18n)"/ && /isActive="true"/ && /isFactory="false"/ {
        m = $0; sub(/.*moduleName="/, "", m); sub(/".*/, "", m); printf "%s ", m }' /apex/apex-info-list.xml 2>/dev/null)
    BOOT_OATS=$(ls /system/framework/arm64/boot*.oat 2>/dev/null | wc -l)
    if [ -n "$UPD" ]; then
        echo "[Pivoted Root] zygote: the image's boot image ($JIT_WHY, $BOOT_OATS oat files), but /apex/apex-info-list.xml has ${UPD}as updated: ART will reject it (APEX versions) and compile the boot class path in memory"
    else
        echo "[Pivoted Root] zygote: the image's boot image ($JIT_WHY): $BOOT_OATS oat files in /system/framework/arm64, no updated ART or i18n module in /apex/apex-info-list.xml"
    fi
fi

echo "[Pivoted Root] Cleaning stale sockets..."
rm -f /dev/socket/zygote /dev/socket/usap_pool_primary 2>/dev/null || true

# HyperOS starts its "rust" packages (the launcher with Recents, Weather; their
# code is a Flutter library, the APK has no dex) through hyos_spawner, a
# zygote-like server its own init starts with "socket hyos_spawner stream 0660
# root system" once zygote runs and rust.runtime_active=1. One UI's init has
# no such service: with the rust path off (0.4.16) zygote started the launcher
# with no code, and it died 1008 times in 4 minutes (sixth HyperOS run). Start
# it here with its socket (socket_exec, the HyperOS set's), as root with the
# socket for group system like the image's rc. guest_props.sh set the two
# properties HyperOS's init would (rust.runtime_version, rust.runtime_active=1),
# and the return sweeps the spawner with the other guest processes.
if [ -x /system_ext/bin/hyos_spawner ] && [ -x /data/socket_exec ]; then
    rm -f /dev/socket/hyos_spawner
    /data/socket_exec hyos_spawner /system_ext/bin/hyos_spawner /system_ext/bin --spawner --start-spawner-server \
        </dev/null >/data/hyos_spawner.log 2>&1 &
    echo "[Pivoted Root] hyos_spawner PID: $! (socket /dev/socket/hyos_spawner)"
fi

echo "[Pivoted Root] Launching guest Zygote & SystemServer via zygote_exec..."
exec /data/zygote_exec
