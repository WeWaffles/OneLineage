#!/system/bin/sh
# The OneOS session: the userspace takeover (started from WeWaffles' OneLineage
# switch_to_lineage.sh).
STAGE="/data/local/tmp/oneos"
# ONEOS_APP=1 (session.env): started by the OneOS app's root script. Then every
# preflight check below has to pass. Without it (the owner's adb loop,
# scripts/deploy-phone.sh) the app-only checks are skipped and a few warn.
APP="${ONEOS_APP:-0}"
[ "$APP" = 1 ] || APP=0

# --- PREFLIGHT ------------------------------------------------------------
# Every refusal comes before the first change to the phone (SELinux, props,
# watchdogs, One UI's framework), so a refused switch leaves One UI exactly as
# it was. Up to run 35 system.raw was only checked at [4/6], after setenforce
# 0, the persist snapshot, the watchdogs, disable_rescue and the BPF update,
# and that exit undid none of them.
refuse() {
    echo "PREFLIGHT REFUSED: $*"
    echo "Nothing on the phone was changed; One UI keeps running."
    exit 2
}
app_refuse() {
    [ "$APP" = 1 ] && refuse "$*"
    echo "WARNING (no ONEOS_APP): $*"
}
# Owned by root and writable by root only (stat %A: group w is the 6th
# character, other w the 9th).
root_only() {
    case "$(stat -c '%u %A' "$1" 2>/dev/null)" in
        "0 "?????w*|"0 "????????w*) return 1 ;;
        "0 "*) return 0 ;;
    esac
    return 1
}
[ "$(id -u 2>/dev/null)" = 0 ] || refuse "not running as root"

# Root tools: the root manager's own busybox and resetprop (KernelSU, APatch,
# Magisk), never whatever a search of /data finds (OneLineage fell back to
# `find /data -name busybox`). A missing resetprop is fatal: without it
# guest_props.sh can neither snapshot nor restore One UI's persist.* props.
BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    [ -x "$c" ] && { BB=$c; break; }
done
RP=""
for c in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop; do
    [ -x "$c" ] && { RP=$c; break; }
done
if [ "$APP" != 1 ]; then
    [ -n "$BB" ] || BB=$(command -v busybox 2>/dev/null)
    [ -n "$RP" ] || RP=$(command -v resetprop 2>/dev/null)
fi
[ -n "$BB" ] && [ -x "$BB" ] || refuse "no busybox at the root manager's paths (/data/adb/ksu/bin, /data/adb/ap/bin, /data/adb/magisk)"
APPLETS=" $("$BB" --list 2>/dev/null | tr '\n' ' ') "
missing=""
for a in sh mount umount losetup unshare nsenter pivot_root setsid awk grep sed; do
    case "$APPLETS" in *" $a "*) ;; *) missing="$missing $a" ;; esac
done
[ -z "$missing" ] || refuse "$BB lacks the applets:$missing"
# guest_prepare.sh attaches system.raw read-only (losetup -r).
"$BB" losetup --help 2>&1 | grep -q -e '-[A-Za-z]*r' || app_refuse "$BB losetup shows no -r (read-only loop device)"
[ -n "$RP" ] && [ -x "$RP" ] || refuse "no resetprop at the root manager's paths: One UI's persist.* props could not be saved and restored"
FP=$(getprop ro.build.fingerprint 2>/dev/null)
[ -n "$FP" ] && [ "$("$RP" ro.build.fingerprint 2>/dev/null)" = "$FP" ] || refuse "$RP does not read properties"
command -v sha256sum >/dev/null 2>&1 || refuse "no sha256sum"
command -v getevent >/dev/null 2>&1 || app_refuse "no getevent: Volume Up + Volume Down could not return to One UI"

# init's mount namespace. One UI's installd and artd run there: binds made in
# any other namespace (a root shell can get its own, e.g. KernelSU's per-app
# mount namespace option) would never reach them, and they would write into
# One UI's real /data for the guest (run 25). The app's launch enters init's
# namespace with nsenter; the adb loop is run again there, once.
SELF_NS=$(readlink /proc/$$/ns/mnt 2>/dev/null)
INIT_NS=$(readlink /proc/1/ns/mnt 2>/dev/null)
if [ -z "$SELF_NS" ] || [ "$SELF_NS" != "$INIT_NS" ]; then
    if [ "$APP" != 1 ] && [ -z "$ONEOS_NS_REENTERED" ]; then
        echo "Not in init's mount namespace (${SELF_NS:-unreadable}, init ${INIT_NS:-unreadable}): running again in init's"
        export ONEOS_NS_REENTERED=1
        exec "$BB" nsenter -t 1 -m -- /system/bin/sh "$STAGE/oneos_switch.sh" "$@"
    fi
    refuse "not in init's mount namespace (this shell: ${SELF_NS:-unreadable}, init: ${INIT_NS:-unreadable})"
fi

# The stage's name up to app 0.3.6 (OneLineage's). The app's root script and
# scripts/deploy-phone.sh rename it to $STAGE, only while it is idle; a session
# never starts while it is still there, so nothing runs from two stages.
LEGACY_STAGE=/data/local/tmp/lineage_stage
if [ -d "$LEGACY_STAGE" ] && [ ! -L "$LEGACY_STAGE" ]; then
    [ -e "$STAGE" ] || [ -L "$STAGE" ] ||
        refuse "the stage is still at its old path $LEGACY_STAGE, not $STAGE: prepare again in the OneOS app (or run scripts/deploy-phone.sh), which renames it"
    refuse "both $STAGE and the old $LEGACY_STAGE are on this phone: OneOS uses one stage; move the one you do not need aside (e.g. to $STAGE.old-<epoch>, which the OneOS app lists under Old copies)"
fi
[ -d "$STAGE" ] && [ ! -L "$STAGE" ] || refuse "$STAGE is missing or not a directory"
root_only "$STAGE" || app_refuse "$STAGE is not root's or is writable by others ($(stat -c '%U:%G %A' "$STAGE" 2>/dev/null))"
[ -f "$STAGE/system.raw" ] || refuse "the guest image ($STAGE/system.raw) is not staged"
for f in oneos_switch.sh guest_prepare.sh guest_start.sh guest_props.sh return_to_oneui.sh \
         check_host_apex.sh bridges.sh fold8_coloros.sh guest_google.sh zygote_exec guards.txt services_patched.jar; do
    [ -f "$STAGE/$f" ] || refuse "$STAGE/$f is missing"
done
# The guarded jars: services_patched.jar, and oplus-services_patched.jar for a
# ColorOS image, miui-services_patched.jar and apprecovery.proinstaller_patched.jar
# for a HyperOS one (guards.txt lists what make-overlays.sh built;
# guest_prepare.sh refuses an image with oplus-services.jar or miui-services.jar
# that lacks them). A set's
# vold_patched and service.incremental_patched.so (Pixel 17, and ColorOS 17
# since 0.4.8) go with its guarded jars (the guest vold as "gvld", run 44), so
# they are checked the same way.
GUARD_JARS="services_patched.jar $(awk '$2 == "oplus-services_patched.jar" || $2 == "vold_patched" || $2 == "service.incremental_patched.so" ||
                                       $2 == "miui-services_patched.jar" || $2 == "apprecovery.proinstaller_patched.jar" ||
                                       $2 == "framework_patched.jar" || $2 == "miui-wifi-service_patched.jar" || $2 == "miui-telephony-common_patched.jar" { print $2 }' "$STAGE/guards.txt")"

if [ "$APP" = 1 ]; then
    # Every staged file (files.sha256, written by the app's root script; all
    # but system.raw) is checked, not only the two guarded jars: the scripts,
    # zygote_exec, bridges.sh, surfaceflinger_patched, the other jars, the
    # payloads and the RROs are all bound or run as root.
    SUMS="$STAGE/files.sha256"
    [ -f "$SUMS" ] && [ ! -L "$SUMS" ] && root_only "$SUMS" || refuse "files.sha256 is missing, or not root's"
    bad=$(awk 'NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $2 !~ /^[A-Za-z0-9_][A-Za-z0-9._-]*$/ ||
               $2 == "system.raw" || seen[$2]++ { print NR ": " $0 }' "$SUMS" | head -3)
    [ -z "$bad" ] || refuse "files.sha256 has malformed lines: $bad"
    for need in oneos_switch.sh guest_prepare.sh guest_start.sh guest_props.sh return_to_oneui.sh \
                check_host_apex.sh bridges.sh zygote_exec guards.txt $GUARD_JARS; do
        awk -v n="$need" '$2 == n { f = 1 } END { exit !f }' "$SUMS" || refuse "files.sha256 does not list $need"
    done
    while read -r sum name || [ -n "$sum" ]; do
        f="$STAGE/$name"
        [ -f "$f" ] && [ ! -L "$f" ] || refuse "$name (files.sha256) is missing or a link"
        root_only "$f" || refuse "$name is not root's or is writable by others"
        [ "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" = "$sum" ] || refuse "$name does not match files.sha256"
    done < "$SUMS"
    # A leftover the package does not carry would still be bound by
    # guest_prepare.sh (framework_patched.jar, libaudio*_patched.so,
    # PermissionController_patched.apk, an extra payload, an apex info list).
    for f in "$STAGE"/*; do
        [ -f "$f" ] || [ -L "$f" ] || continue
        n=${f##*/}
        case "$n" in
            *_patched*|*_payload.img|*.apk|clean_apex_info_list.xml)
                awk -v n="$n" '$2 == n { f = 1 } END { exit !f }' "$SUMS" ||
                    refuse "$n is in $STAGE but not in files.sha256 (left from an older stage)" ;;
        esac
    done
    # system.raw is verified once, at staging (10 GB); since then its identity
    # must be unchanged: "<size> <sha256>" and stat dev:inode:size:mtime.
    ID="$STAGE/system.raw.id"
    [ ! -L "$STAGE/system.raw" ] && root_only "$STAGE/system.raw" || refuse "system.raw is a link, or not root's"
    [ -f "$ID" ] && root_only "$ID" || refuse "system.raw.id is missing, or not root's"
    ID_STAT=$(tr '\n' ' ' < "$ID" | awk 'NF == 3 && $1 ~ /^[0-9]+$/ && length($2) == 64 && $2 !~ /[^0-9a-f]/ &&
        $3 ~ /^[0-9]+:[0-9]+:[0-9]+:[0-9]+$/ && split($3, s, ":") == 4 && s[3] == $1 { print $3 }')
    [ -n "$ID_STAT" ] || refuse "system.raw.id is not \"<size> <sha256> <dev:inode:size:mtime>\""
    [ "$(stat -c '%d:%i:%s:%Y' "$STAGE/system.raw" 2>/dev/null)" = "$ID_STAT" ] ||
        refuse "system.raw changed since it was verified (system.raw.id $ID_STAT, now $(stat -c '%d:%i:%s:%Y' "$STAGE/system.raw" 2>/dev/null))"
    # The ways back to One UI and the session log cannot be switched off from
    # the app: the root script never writes these keys, checked again here.
    ENVF="$STAGE/session.env"
    [ -f "$ENVF" ] && root_only "$ENVF" && grep -qx 'ONEOS_APP=1' "$ENVF" || refuse "session.env is missing, not root's, or lacks ONEOS_APP=1"
    RMAX=${ONEOS_RETURN_MAX:-600}; RBLACK=${ONEOS_RETURN_BLACK:-150}
    case "$RMAX:$RBLACK" in *[!0-9:]*|:*|*:) refuse "ONEOS_RETURN_MAX/ONEOS_RETURN_BLACK not numbers" ;; esac
    [ "$RMAX" -ge 300 ] && [ "$RMAX" -le 900 ] || refuse "ONEOS_RETURN_MAX=$RMAX (300..900)"
    [ "$RBLACK" -ge 60 ] && [ "$RBLACK" -le "$RMAX" ] || refuse "ONEOS_RETURN_BLACK=$RBLACK (60..ONEOS_RETURN_MAX)"
    [ "${ONEOS_RETURN_KEYS:-1}" = 1 ] || refuse "ONEOS_RETURN_KEYS=$ONEOS_RETURN_KEYS"
    # 0.4.7: the app's session.env asks for the in-place return (run 48); any
    # check that fails there still reboots (return_to_oneui.sh failsafe).
    case "${ONEOS_RETURN_MODE:-reboot}" in reboot|inplace) ;; *) refuse "ONEOS_RETURN_MODE=$ONEOS_RETURN_MODE" ;; esac
    [ "${ONEOS_LOGCAT:-1}" = 1 ] || refuse "ONEOS_LOGCAT=$ONEOS_LOGCAT"
    [ "${ONEOS_STOCK_SF:-0}" = 0 ] || refuse "ONEOS_STOCK_SF=$ONEOS_STOCK_SF"
    [ "${ONEOS_KEEP_FOLD_LAYOUT:-0}" = 0 ] || refuse "ONEOS_KEEP_FOLD_LAYOUT=$ONEOS_KEEP_FOLD_LAYOUT"
    # ColorOS's own use of the return chord would turn TalkBack on (run 34).
    [ "${ONEOS_GUEST_A11Y_SHORTCUT:-0}" = 0 ] || refuse "ONEOS_GUEST_A11Y_SHORTCUT=$ONEOS_GUEST_A11Y_SHORTCUT"
    case "${ONEOS_PREPARE_ONLY:-0}" in 0|1) ;; *) refuse "ONEOS_PREPARE_ONLY=$ONEOS_PREPARE_ONLY" ;; esac
    env | grep -q '^ONEOS_TUNNEL_' && refuse "ONEOS_TUNNEL_* set"
fi
# Google services in a Pixel guest (guest_prepare.sh, docs/pixel-guest.md):
# ONEOS_GUEST_GMS is 0 or 1, unset meaning 1, from the app and the adb loop
# alike; and not on together with ONEOS_GUEST_HIDE_GMS=1 when the payload is
# staged. guest_prepare.sh checks both again, with the guards and the stage's
# app ids, but only after One UI's framework is stopped.
case "${ONEOS_GUEST_GMS:-1}" in 0|1) ;; *) refuse "ONEOS_GUEST_GMS=$ONEOS_GUEST_GMS (0 or 1)" ;; esac
# Cool down when hot (the heat cap below): 0 or 1, unset meaning 1.
case "${ONEOS_HEAT_CAP:-1}" in 0|1) ;; *) refuse "ONEOS_HEAT_CAP=$ONEOS_HEAT_CAP (0 or 1)" ;; esac
[ "${ONEOS_GUEST_GMS:-1}" = 1 ] && [ "${ONEOS_GUEST_HIDE_GMS:-0}" = 1 ] && [ -f "$STAGE/gmssystem_payload.img" ] &&
    refuse "ONEOS_GUEST_GMS is on (the default) with gmssystem_payload.img staged, and ONEOS_GUEST_HIDE_GMS=1 hides Google services: set one of them to 0"
# The same guard and app-id checks as guest_prepare.sh, here so a refusal comes
# before One UI's framework stops (after it, guest_prepare's exit 3 reboots).
if [ "${ONEOS_GUEST_GMS:-1}" = 1 ] && [ -f "$STAGE/gmssystem_payload.img" ]; then
    for t in gatekeeper pdb apexd appid15000; do
        grep '^#' "$STAGE/guards.txt" 2>/dev/null | grep -qw "$t" ||
            refuse "Google services: guards.txt lacks the $t guard (ONEOS_GUEST_GMS=0 starts without Google services)"
    done
    awk '$2 ~ /^[0-9]+$/ && $2 >= 10000 && $2 <= 14999 { f = 1 } END { exit !f }' "$STAGE/data/system/packages.list" 2>/dev/null &&
        refuse "Google services: the stage has guest app ids 10000-14999 from before the app-id guard (a fresh guest data dir, or ONEOS_GUEST_GMS=0)"
fi

# The guarded framework jars (scripts/make-overlays.sh: storage, installd,
# power, sysrq and weaver guards). guest_prepare.sh checks them again.
for need in $GUARD_JARS; do
    sum=$(awk -v n="$need" '$2 == n {print $1}' "$STAGE/guards.txt")
    [ -n "$sum" ] && [ "$(sha256sum "$STAGE/$need" 2>/dev/null | cut -d' ' -f1)" = "$sum" ] ||
        refuse "$need is missing or not the guarded build in guards.txt"
done
# The guest vold as "gvld" takes both binaries (guest_prepare.sh refuses one
# alone too, but only once One UI's framework is stopped).
[ "$(awk '$2 == "vold_patched" { v = 1 } $2 == "service.incremental_patched.so" { i = 1 } END { print v + i }' "$STAGE/guards.txt")" = 1 ] &&
    refuse "guards.txt lists only one of vold_patched and service.incremental_patched.so (a half-built set)"
# The /data bridges (bridges.sh) and their floor, as guest_prepare.sh needs
# them; nothing may be left mounted under the stage or bridged from a session
# that never returned (the return reboots, which removes them).
BRIDGES=""
. "$STAGE/bridges.sh" || refuse "bridges.sh unreadable"
for need in app:app user:user user_de:user_de data:user/0 media:media; do
    case " $BRIDGES " in *" $need "*) ;; *) refuse "bridges.sh lacks $need" ;; esac
done
left=$(awk -v s="$STAGE/" 'index($5, s) == 1 {print $5}' /proc/self/mountinfo | head -3 | tr '\n' ' ')
[ -z "$left" ] || refuse "mounted under the stage ($left): a session is running or never returned; return to One UI (reboot) first"
for pair in $BRIDGES; do
    awk -v p="/data/${pair%%:*}" '$5 == p' /proc/self/mountinfo | grep -q . &&
        refuse "/data/${pair%%:*} is still bridged from an earlier session; return to One UI (reboot) first"
done
# The gap splash (below): the OneOS app's GapSplashActivity, started by root
# (it is not exported). ONEOS_SPLASH_COMPONENT names another package/.Activity,
# e.g. com.wewaffles.onelineage/.SplashActivity for the old switcher.
SPLASH_COMPONENT="${ONEOS_SPLASH_COMPONENT:-com.fahadali.oneos/.ui.GapSplashActivity}"
case "$SPLASH_COMPONENT" in
    */*/*|/*|*/|*[!A-Za-z0-9._/]*) refuse "ONEOS_SPLASH_COMPONENT=$SPLASH_COMPONENT is not package/.Activity" ;;
    */*) ;;
    *) refuse "ONEOS_SPLASH_COMPONENT=$SPLASH_COMPONENT is not package/.Activity" ;;
esac
# One UI's property space. Each property context is one fixed-size file in
# /dev/__properties__ (prop_area: a 128-byte header, bytes_used first) that
# only grows: a property resetprop deletes leaves its slot behind until the
# next reboot. With the in-place return the phone does not reboot between
# sessions, and every session adds the guest's build properties (the persist.sys.*
# ones to the same area as persist.sys.disable_rescue). The S25 Ultra's second
# session of a night (485d5ffa, 0.4.17): init "__system_property_add failed"
# for persist.sys.disable_rescue, guest_props added 339 of 439, and guest_start.sh
# rightly refused to start the guest without it, after One UI was already
# stopped. Checked here instead, before anything changes.
pa_free() { # bytes left in the property area file $1
    s=$(stat -c %s "$1" 2>/dev/null)
    u=$("$BB" od -An -tu4 -N4 "$1" 2>/dev/null | tr -d ' ')
    case "$s:$u" in *[!0-9:]*|:*|*:) return 1 ;; esac
    echo $((s - 128 - u))
}
PA_CTX=$(getprop -Z persist.sys.disable_rescue 2>/dev/null)
PA_FILE="/dev/__properties__/${PA_CTX:-u:object_r:system_prop:s0}"
if PA_LEFT=$(pa_free "$PA_FILE"); then
    [ "$PA_LEFT" -ge 16384 ] ||
        refuse "One UI's property space is nearly full ($((PA_LEFT / 1024)) KB left in ${PA_FILE##*/}): the sessions since the phone last restarted used it up. Restart the phone, then switch again"
    [ "$PA_LEFT" -ge 49152 ] || echo "WARNING: One UI's property space is getting full ($((PA_LEFT / 1024)) KB left in ${PA_FILE##*/}); some of the other system's settings may not load. Restart the phone before the next session"
else
    echo "WARNING: could not read the free property space in $PA_FILE"
fi
echo "Preflight passed (ONEOS_APP=$APP, profile ${ONEOS_PROFILE:-none}, busybox $BB, resetprop $RP, mount namespace $SELF_NS)"

# Every ColorOS set (pull request #1 began it for the Z Fold8): copy One UI's
# Play services and Play Store APK files, never their data, while One UI's
# package manager still runs, after checking the stage's guards
# (switcher/assets/guest_google.sh). It never refuses: without a copy the guest
# starts without them.
STAGE="$STAGE" BB="$BB" /system/bin/sh "$STAGE/guest_google.sh" snapshot ||
    echo "!!! guest_google.sh snapshot failed; the guest starts without One UI's Play services"

# mksh keeps a short here-document in memory and writes a long one to a temp
# file in $TMPDIR, a directory it accepts once, when the shell starts, and
# does not look at again. Started from the app, every long heredoc of
# guest_prepare.sh after its [5d] bridges failed with "can't create
# temporary file : No such file or directory" (run 36a; S25U session
# f075d93a): the shells had a TMPDIR that existed at their start and was gone
# by then (an app's own cache folder under /data/user/0 is what the bridges
# hide; adb shell's TMPDIR=/data/local/tmp never showed it), so
# fix_app_dirs.sh, ensure_app_storage.sh, net_fix.sh and app_storage_loop.sh
# were never written. The stage's own folder, root's alone, kept for the
# whole session; a link in its place (a guest with root) is refused like the
# other staged paths. guest_start.sh sets its own after the pivot.
[ ! -L "$STAGE/tmp" ] || refuse "$STAGE/tmp is a symlink"
mkdir -p "$STAGE/tmp" && chown 0:0 "$STAGE/tmp" && chmod 0700 "$STAGE/tmp" || refuse "could not make $STAGE/tmp"
export TMPDIR="$STAGE/tmp"

# Out of the launching app's cgroup and away from the OOM killer:
# ActivityManager kills an app's whole cgroup when the app dies, and a switch
# killed half way leaves One UI stopped with nothing to bring it back.
# Everything started below inherits both.
echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
echo -1000 > /proc/$$/oom_score_adj 2>/dev/null

export BB
export RP
export STAGE

set_prop() {
    if [ -n "$RP" ] && [ -x "$RP" ]; then
        "$RP" "$1" "$2" 2>/dev/null || true
    else
        setprop "$1" "$2" 2>/dev/null || true
    fi
}

echo "=== OneOS guest takeover starting ==="
# One header per session in auto_return.log, which every session appends to:
# the app's last-session screen reads the outcome of the newest session only.
echo "=== OneOS session $(date '+%F %T') epoch $(date +%s) boot $(cat /proc/sys/kernel/random/boot_id 2>/dev/null) app $APP profile ${ONEOS_PROFILE:-none} return max ${ONEOS_RETURN_MAX:-600}s black ${ONEOS_RETURN_BLACK:-150}s keys ${ONEOS_RETURN_KEYS:-1} ===" >> "$STAGE/auto_return.log"

# Prove resetprop can WRITE and DELETE a persist prop, not only read one (the
# preflight only read). Without this the snapshot below is useless and the
# return could not restore One UI's props: on some KernelSU/APatch builds
# resetprop cannot rewrite /data/property or rejects -p --delete, and that only
# showed up at return time. Its own throwaway prop, deleted again; a failure
# here is before the snapshot, so One UI is untouched.
if ! "$RP" -p persist.oneos.probe 1 2>/dev/null || [ "$("$RP" persist.oneos.probe 2>/dev/null)" != 1 ] ||
   ! "$RP" -p --delete persist.oneos.probe 2>/dev/null; then
    "$RP" -p --delete persist.oneos.probe 2>/dev/null
    echo "ERROR: resetprop cannot write persist props on this phone; not switching (One UI's props could not be restored on return)."
    exit 1
fi
# Snapshot the host's persist.* props before anything below or the guest can
# change them; return_to_oneui.sh puts them back (see guest_props.sh). This is
# the first change to the phone: if it fails, nothing else is done.
if ! /system/bin/sh "$STAGE/guest_props.sh" snapshot-persist; then
    echo "ERROR: One UI's persist.* props could not be saved; not switching."
    exit 1
fi
setprop oneos.guest.powerctl "" 2>/dev/null
# "Back to One UI" in the guest's OneOS app (app-android/guest) is a file in
# that app's own data folder: /data/user/0/com.fahadali.oneos.guest/files/
# oneos_return in the guest, whose /data is $STAGE/data. The watcher below acts
# on it like on the keys; one left from an earlier session must not end this
# one as soon as it starts.
GUEST_RETURN_REQ="$STAGE/data/user/0/com.fahadali.oneos.guest/files/oneos_return"
rm -f "$GUEST_RETURN_REQ"
# One UI's protected state, recorded now and compared by return_to_oneui.sh:
# the FRP partition, gatekeeper's files and the APEX state. The guest is kept
# off all three (patches/guest_no_gatekeeper.py, guest_pdb_readonly.py,
# guest_no_apex_installs.py); a difference means a path the guards missed.
# Read only; it only logs.
host_state() {
    f=$(readlink -f "$(getprop ro.frp.pst)" 2>/dev/null)
    [ -b "$f" ] && echo "frp $(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
    for p in /data/misc/gatekeeper /data/apex/active /data/apex/sessions; do
        [ -d "$p" ] && find "$p" -type f -exec stat -c '%n %s %Y' {} + 2>/dev/null | sort
    done
}
host_state > "$STAGE/host_state.before"
# A Wi-Fi capture from an earlier session must not be pulled as this one's.
# Nor a fold test or a display capture: run 43's diag_fold was run 41's (lid
# events at 04:17, nothing cleared it), and its HALF_OPENED after a flat
# unfold nearly decided the run-44 posture fix. Nor the rounds (mkdir -p and
# overwrite: a file a round skips this time, such as a stack of an app that is
# not running, would be the last session's) and the return's capture.
rm -rf "$STAGE/diag_wifi" "$STAGE/diag_fold" "$STAGE/diag_display" "$STAGE/diag_pages" \
       "$STAGE/diag_20" "$STAGE/diag_40" "$STAGE/diag_90" "$STAGE/diag_final" "$STAGE/diag_return"
echo "Host state recorded: $(wc -l < "$STAGE/host_state.before") entries"
# This phone's camera hole, while One UI's display service still runs, for
# guest_props.sh (bar phones): the image's ro.oplus.display.screenhole.positon
# is its own phone's. The S25 (1080 px) got the Find X9 Ultra's 679..762
# (1440 px): left of it past the middle (540) is HOLE_RIGHT_TYPE in
# OplusStatusBarUtils.isHoleType, so the status icons ended next to the camera
# with the right half of the bar empty. The top bounding rect of the one
# default-capable internal display (S25: 511,0:569,103), or nothing.
# The rect is in the size One UI runs the panel at, which the guest does not:
# the S25 Ultra at One UI's FHD+ (1080 of its 1440 px) gave 521,0:560,72, and
# ColorOS, on the whole 1440 px panel, took that for a hole left of the
# middle (HOLE_LEFT_TYPE, session e98f44ff): the clock started right of it,
# next to the real camera. Scaled to the panel's physical width
# (cutoutPathParserInfo physicalDisplayWidth / displayWidth).
rm -f "$STAGE/host_screenhole"
HLINE=$(dumpsys display 2>/dev/null | grep 'DisplayDeviceInfo{' | grep 'type INTERNAL' | grep 'FLAG_ALLOWED_TO_BE_DEFAULT_DISPLAY')
HOLE=$(printf '%s\n' "$HLINE" |
    sed -n 's/.*boundingRect={Bounds=\[Rect(-\{0,1\}[0-9]*, -\{0,1\}[0-9]* - -\{0,1\}[0-9]*, -\{0,1\}[0-9]*), Rect(\([0-9]*\), \([0-9]*\) - \([0-9]*\), \([0-9]*\)).*/\1,\2:\3,\4/p')
HDW=$(printf '%s\n' "$HLINE" | sed -n 's/.*CutoutPathParserInfo{displayWidth=\([0-9]*\) displayHeight=[0-9]* physicalDisplayWidth=\([0-9]*\) .*/\1/p')
HPW=$(printf '%s\n' "$HLINE" | sed -n 's/.*CutoutPathParserInfo{displayWidth=\([0-9]*\) displayHeight=[0-9]* physicalDisplayWidth=\([0-9]*\) .*/\2/p')
if [ -n "$HOLE" ] && [ "$HOLE" = "${HOLE%%[!0-9,:]*}" ]; then
    case "$HDW:$HPW" in
        *[!0-9:]*|:*|*:) ;;
        *) if [ "$HDW" -gt 0 ] && [ "$HPW" != "$HDW" ]; then
               UIHOLE=$HOLE
               HOLE=$(echo "$HOLE" | awk -F'[,:]' -v p="$HPW" -v d="$HDW" '{ printf "%d,%d:%d,%d", $1 * p / d + 0.5, $2 * p / d + 0.5, $3 * p / d + 0.5, $4 * p / d + 0.5 }')
               echo "Host camera hole: One UI's $UIHOLE at $HDW px, $HOLE on the $HPW px panel"
           fi ;;
    esac
    echo "$HOLE" > "$STAGE/host_screenhole" && echo "Host camera hole: $HOLE"
else
    echo "Host camera hole: not read ($(printf '%s\n' "$HOLE" | grep -c .) internal displays with a top cutout)"
fi
# This phone's cutout and status bar height, for the UI activator's overlays in a
# Pixel guest (a Galaxy S26 Ultra user, 0.4.17: Pixel's bar far taller than the
# camera hole). The image's own device overlays (product, above OneOS's /oem
# ones) give it the Pixel's cutout and status bar height. One UI's cutout spec
# (cutoutSpec, "@dp", so the same at any resolution) and its status bar's height
# (the statusBars inset at One UI's resolution, scaled to the panel's like the
# hole), from a phone with one default-capable internal display only (a fold's
# two panels are left alone).
rm -f "$STAGE/host_statusbar"
if [ "$(printf '%s\n' "$HLINE" | grep -c .)" = 1 ]; then
    HCS=$(printf '%s\n' "$HLINE" | sed -n 's/.*cutoutSpec={\([^}]*\)}.*/\1/p' | head -n 1)
    HSB=$(timeout 10 dumpsys window 2>/dev/null | sed -n "s/.*type=statusBars frame=\[0,0\]\[$HDW,\([0-9]*\)\].*/\1/p" | head -n 1)
    # The panel's corner radius (RoundedCorner{position=TopLeft, radius=<px>, ...}
    # at One UI's resolution): an image's own corners are its phone's (Infinity-X
    # on the S25 Ultra: radius 0, so SystemUI kept no clear of the curved corners).
    HRC=$(printf '%s\n' "$HLINE" | sed -n 's/.*RoundedCorner{position=TopLeft, radius=\([0-9]*\),.*/\1/p' | head -n 1)
    case "$HDW:$HPW:$HSB" in
        *[!0-9:]*|:*|*::*|*:) HSB='' ;;
        *) [ "$HDW" -gt 0 ] && HSB=$(( (HSB * HPW + HDW / 2) / HDW )) || HSB='' ;;
    esac
    case "$HDW:$HPW:$HRC" in
        *[!0-9:]*|:*|*::*|*:) HRC='' ;;
        *) [ "$HDW" -gt 0 ] && [ "$HRC" -gt 0 ] && HRC=$(( (HRC * HPW + HDW / 2) / HDW )) || HRC='' ;;
    esac
    case "$HCS" in *[!-0-9A-Za-z._,@\ ]*) HCS='' ;; esac
    if [ -n "$HCS$HSB$HRC" ]; then
        { echo "spec=$HCS"; echo "height=$HSB"; echo "radius=$HRC"; } > "$STAGE/host_statusbar"
        echo "Host status bar: cutout '${HCS:-none}', height ${HSB:-not read} px, corner radius ${HRC:-not read} px on the $HPW px panel"
    fi
fi
# One UI's scale, for the guest's density (UI activator; standing rule: right on
# every phone and image): the density One UI runs its main panel at (Screen zoom
# included) and the width it runs it at. An Ultra's One UI runs its 1440 px panel
# at FHD+ (1080) with the shared ro.sf.lcd_density 450 (384 dp wide); the guest
# always runs the whole panel, so at that density it was 512 dp wide, a third too
# small (S24/S25 Ultra reports), and One UI's cutout spec (@dp) missed the camera.
# The main panel is the largest internal one: a bar phone's only panel, a flip's
# inner one. Recorded only while it is One UI's display 0 (wm size, wm density),
# so a flip switched shut leaves the guest at the base density.
rm -f "$STAGE/host_display"
MLINE=$(printf '%s\n' "$HLINE" | while IFS= read -r l; do
            s=$(echo "$l" | sed -n 's/.*uniqueId="local:[0-9]*", \([0-9]*\) x \([0-9]*\), .*/\1 \2/p')
            [ -n "$s" ] && echo "$(echo "$s" | awk '{ print $1 * $2 }') $l"
        done | sort -n | tail -n 1 | cut -d' ' -f2-)
MW=$(printf '%s\n' "$MLINE" | sed -n 's/.*uniqueId="local:[0-9]*", \([0-9]*\) x [0-9]*, .*/\1/p')
MDW=$(printf '%s\n' "$MLINE" | sed -n 's/.*CutoutPathParserInfo{displayWidth=\([0-9]*\) displayHeight=[0-9]* physicalDisplayWidth=\([0-9]*\) .*/\1/p')
MPW=$(printf '%s\n' "$MLINE" | sed -n 's/.*CutoutPathParserInfo{displayWidth=\([0-9]*\) displayHeight=[0-9]* physicalDisplayWidth=\([0-9]*\) .*/\2/p')
# A panel without a cutout: One UI runs it at the size it reports.
[ -n "$MDW" ] || MDW=$MW
[ -n "$MPW" ] || MPW=$MW
H0W=$(timeout 10 wm size 2>/dev/null | sed -n 's/^Physical size: \([0-9]*\)x[0-9]*$/\1/p' | head -n 1)
HWD=$(timeout 10 wm density 2>/dev/null)
HUD=$(printf '%s\n' "$HWD" | sed -n 's/^Override density: \([0-9]*\)$/\1/p' | head -n 1)
[ -n "$HUD" ] || HUD=$(printf '%s\n' "$HWD" | sed -n 's/^Physical density: \([0-9]*\)$/\1/p' | head -n 1)
case "$HUD:$MDW:$MPW:$H0W" in
    *[!0-9:]*|:*|*::*|*:) echo "Host display scale: not read (density '${HUD}', width '${MDW}' of '${MPW}' px, display 0 '${H0W}' px)" ;;
    *) if [ "$H0W" != "$MPW" ] && [ "$H0W" != "$MDW" ] && [ "$H0W" != "$MW" ]; then
           echo "Host display scale: One UI's display 0 ($H0W px) is not the main panel ($MPW px), not recorded"
       elif [ "$HUD" -gt 0 ] && [ "$MDW" -gt 0 ]; then
           echo "density=$HUD width=$MDW physical=$MPW" > "$STAGE/host_display"
           echo "Host display scale: density $HUD at $MDW of the $MPW px main panel ($((MDW * 160 / HUD)) dp wide)"
       fi ;;
esac
# The cover panel of a fold, for guest_prepare.sh (ColorOS cover density): the
# smaller of the two default-capable internal displays, as
# "<uniqueId> <port> <width> <height> <xdpi>". The guest's SurfaceFlinger
# gives the panels the same ids (local:<id>) and ports as One UI's.
rm -f "$STAGE/host_cover_display"
if [ "${ONEOS_GUEST_FORM:-fold}" = fold ]; then
    # One record per panel (a dump may list a panel more than once).
    CVDS=$(printf '%s\n' "$HLINE" | while IFS= read -r l; do
        u=$(echo "$l" | sed -n 's/.*uniqueId="\(local:[0-9]*\)", \([0-9]*\) x \([0-9]*\), .*/\1 \2 \3/p')
        p=$(echo "$l" | sed -n 's/.*address [A-Za-z]*{[^}]*port=\([0-9]*\)[,}].*/\1/p')
        x=$(echo "$l" | sed -n 's/.*, density [0-9]*, \([0-9]*\)[.0-9]* x [.0-9]* dpi.*/\1/p')
        set -- $u
        [ -n "$3" ] && [ -n "$p" ] && [ -n "$x" ] && echo "$(($2 * $3)) $1 $p $2 $3 $x"
    done | sort -u)
    CVD=""
    [ "$(printf '%s\n' "$CVDS" | awk 'NF { print $2 }' | sort -u | wc -l)" = 2 ] &&
        CVD=$(printf '%s\n' "$CVDS" | sort -n | head -n 1 | cut -d' ' -f2-)
    if [ "$(echo "$CVD" | wc -w)" = 5 ]; then
        echo "$CVD" > "$STAGE/host_cover_display" && echo "Host cover display: $CVD"
    else
        echo "Host cover display: not read"
    fi
fi

# What a return without a reboot compares against (return_to_oneui.sh): One
# UI's APEX devices, props, SELinux mode and the servicemanager names it keeps,
# recorded while One UI is still whole. Read only; without it the return reboots.
/system/bin/sh "$STAGE/return_to_oneui.sh" baseline

# Full logcat of the session (host and guest share logd) for pull-run-logs.sh.
# Started here so no session runs without it: run 31 was launched without the
# separate capture, and the reboot back to One UI emptied the buffers. A
# capture that is already running (started by hand) is kept; otherwise the
# previous session's files move to oneos_logs.prev. ONEOS_LOGCAT=0 skips it.
# Size (run 44): 24 rotated files of 32 MiB and the current one, 800 MiB at
# most (the app's free-space gate counts 1 GiB for logs). Run 44 wrote 56 MiB
# in 8 minutes after a 45 MiB dump of One UI's history: about 1.7 h at its
# average rate, 1 h at its peak; with 11 x 20 MiB the rotation would have
# started dropping the oldest files (One UI's history, then the switch and the
# guest's boot) after about 26 minutes. The watcher's 90 s round also keeps
# the files of the boot in $LOGS/head (hard links, below).
LOGS=/data/local/tmp/oneos_logs
# LOGCAT_HEAD=1 only for a capture this session starts: a capture already
# running (by hand, or the last session's within the 120 s before
# return_to_oneui.sh stops it) keeps its head/, which may hold the boot of an
# earlier session that its rotation has dropped since.
LOGCAT_HEAD=0
if [ "${ONEOS_LOGCAT:-1}" = 1 ]; then
    # pgrep -f matches the same "^logcat ... boot.log" command line in one
    # process. The loop it replaces forked tr and grep for each of ~1100 pids:
    # 1.6 s with One UI idle (measured 22 Oct, pgrep 49 ms), and it runs before
    # the gap splash below, which in run 33 reached ActivityTaskManager 6 s
    # after the switch started (adbd 14:40:51.03, START 14:40:57.03).
    lp=$(pgrep -f "^logcat .*$LOGS/boot.log" 2>/dev/null | head -1)
    if [ -n "$lp" ]; then
        # The last return stops its capture two minutes after One UI is up
        # (return_to_oneui.sh) unless its token is gone: this session keeps it.
        rm -f "$LOGS/logcat.stop"
        echo "Logcat capture already running (pid $lp): kept, its head/ left as it is"
    else
        rm -rf "$LOGS.prev"; [ -d "$LOGS" ] && mv "$LOGS" "$LOGS.prev"
        mkdir -p "$LOGS"
        $BB setsid logcat -b all -v threadtime -f "$LOGS/boot.log" -r 32768 -n 24 </dev/null >/dev/null 2>&1 &
        LOGCAT_HEAD=1
        echo "Logcat capture: $LOGS/boot.log"
    fi
fi

# --- GAP SPLASH ---
# A still OneOS screen for the black gap at the start of the switch. Run 32
# (all.log): One UI's surfaceflinger was killed in [4b/6] at 13:09:24.55 (the
# composer destroyed its client and blanked the panel: NullCommit) and the
# guest's ColorOS boot animation drew its first frame at 13:09:56.18, so 31.6 s
# of black, 23 s of it guest_prepare.sh. Samsung's bootanimation only plays
# QMG files, and nothing of the guest can draw before its own SurfaceFlinger
# runs. So a splash activity (the OneOS app's GapSplashActivity, before that
# the switcher's SplashActivity; $SPLASH_COMPONENT, see the preflight) puts the
# OneOS wordmark on screen while One UI still runs, and [4b/6] freezes One
# UI's surfaceflinger (SIGSTOP) on that frame instead of killing it: its
# composer client stays, so nothing presents or blanks the panel.
# guest_start.sh kills it right before it restarts the composer (run 32: ~4 s
# before ColorOS's animation, which is unchanged). Started here in the
# background so the switch does not wait for it; [4b/6] waits 3 s at most and
# kills surfaceflinger as before when the splash is not up (no 'Status: ok'
# from am start, e.g. the component is not installed).
# ONEOS_GAP_SPLASH=0: the black gap of run 32.
GAP_SPLASH_LOG="$STAGE/gap_splash.log"
rm -f "$GAP_SPLASH_LOG" "$STAGE/data/oneos_host_sf_frozen"
if [ "${ONEOS_GAP_SPLASH:-1}" = 1 ]; then
    # settled = 0.6 s after the first frame, once the system bars slid out.
    # The times (inner shell's date) date the splash against the switch: run
    # 33's log had none, and its splash came 6 s after the switch started.
    /system/bin/sh -c "echo start \$(date +%T.%N); am start -W --activity-no-animation -n $SPLASH_COMPONENT; sleep 0.6; echo settled \$(date +%T.%N)" </dev/null >"$GAP_SPLASH_LOG" 2>&1 &
fi

# Put SELinux in permissive mode for the duration of the takeover. The guest
# userspace is a foreign, unlabelled-for-this-policy userspace: its
# system_server runs as u:r:system_server:s0 against Samsung's policy, and MAC
# denials there surface as confusing EACCES/ENOENT deep inside system_server
# (e.g. settings.db "doesn't exist", users/0.xml EACCES). guest_prepare.sh
# relabels the staged /data properly, but permissive is the safety net that
# keeps the rest of the guest boot from tripping over labels we cannot predict.
# return_to_oneui.sh restores enforcing.
setenforce 0 2>/dev/null || true
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"

# --- IMS / SMS REGISTRATION GATE -----------------------------------------
# The guest has no ImsService of its own, so the modem's IMS registration is
# owned by One UI's imsd and survives the takeover. That registration is what
# makes SMS behave: with it, T-Mobile delivers inbound SMS promptly (Samsung's
# RIL hands SMSoIP messages to the framework as normal SMS) and the modem
# accepts mobile-originated SMS. Without it, voice sits OUT_OF_SERVICE, sends
# fail with RESULT_ERROR_NO_SERVICE and inbound codes fall back to the SMSC
# retry schedule, arriving 20-40 minutes late - and every radio nudge then
# appears to "magically" deliver them.
# So: make sure imsd is up, and give the modem a moment to (re)register before
# the pivot. Never stop imsd afterwards; killing it was what degraded SMS.
if ! pidof imsd >/dev/null 2>&1; then
    setprop ctl.start imsd 2>/dev/null || true
fi
ims_i=0
ims_st=1
while [ "$ims_i" -lt 45 ]; do
    if dumpsys telephony.registry 2>/dev/null | grep -q 'mVoiceRegState=0'; then
        ims_st=0
        break
    fi
    ims_i=$((ims_i + 1))
    sleep 2
done
echo "IMS gate: voiceRegState=$ims_st after $((ims_i * 2))s, imsd=${ims_pid:-$(pidof imsd)}"

# --- ADB WATCHDOG ---------------------------------------------------------
# adb is the only way into the phone while the guest is up (until wifi is
# configured), and the host adbd occasionally dies or loses the adb function
# when the container's system_server touches the USB configuration. init does
# not reliably restart it, which is the "adb randomly stopped working" symptom.
# Keep it supervised from the host namespace for the whole session; the watchdog
# is stopped again by return_to_oneui.sh.
# OneOS: only when One UI has USB debugging on (read while its framework still
# runs). A phone without it gets no adb watchdog, and guest_prepare.sh then
# neither copies the host's adb_keys into the guest nor turns the guest's
# adb_enabled on ($STAGE/host_adb_on).
case "$(settings get global adb_enabled 2>/dev/null)" in
    1) HOST_ADB=1 ;;
    *) case "$(getprop persist.sys.usb.config)" in *adb*) HOST_ADB=1 ;; *) HOST_ADB=0 ;; esac ;;
esac
echo "$HOST_ADB" > "$STAGE/host_adb_on"
echo "Host USB debugging: $([ "$HOST_ADB" = 1 ] && echo on || echo off)"
if [ "$HOST_ADB" = 1 ] && ! ps -ef 2>/dev/null | grep -v grep | grep -q "adb_watchdog.sh"; then
    cat > /data/local/tmp/adb_watchdog.sh <<'ADBW'
#!/system/bin/sh
# Watchdog for the host adbd, which is the only way into the phone while the guest
# is up. Two failure modes are handled:
#   1. adbd simply died -> ask init to start it again.
#   2. adbd is alive but the USB gadget lost the adb function. The guest's own
#      UsbService rewrites sys.usb.config during boot, and a plain setprop is a
#      no-op in that state, so the gadget has to be re-applied by toggling it.
LOG=/data/local/tmp/adb_watchdog.log
last_toggle=0
while true; do
    sleep 10
    st=$(getprop init.svc.adbd)
    usb=$(getprop sys.usb.state)
    cfg=$(getprop sys.usb.config)
    if [ "$st" != "running" ]; then
        setprop ctl.start adbd 2>/dev/null
        echo "$(date) restarted adbd (was: $st, usb.state=$usb, usb.config=$cfg)" >> "$LOG"
    fi
    case "$cfg" in
        *adb*) ;;
        *)
            setprop sys.usb.config "$cfg,adb" 2>/dev/null
            echo "$(date) added adb to usb.config (was: $cfg)" >> "$LOG"
            ;;
    esac
    case "$usb" in
        *adb*) ;;
        "")
            ;;
        *)
            now=$(date +%s 2>/dev/null || echo 0)
            if [ $((now - last_toggle)) -gt 300 ]; then
                last_toggle=$now
                echo "$(date) gadget lost adb, toggling (state: $usb, config: $cfg)" >> "$LOG"
                setprop sys.usb.config none 2>/dev/null
                sleep 1
                setprop sys.usb.config rndis,adb 2>/dev/null
                sleep 2
                setprop ctl.start adbd 2>/dev/null
            fi
            ;;
    esac
done
ADBW
    chmod 755 /data/local/tmp/adb_watchdog.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/adb_watchdog.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/adb_watchdog.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "adbd watchdog started (log: /data/local/tmp/adb_watchdog.log)"
fi

# --- IMS KEEPALIVE --------------------------------------------------------
# imsd is the daemon holding the modem's IMS registration (see the IMS gate
# above). init does not always bring it back if it dies, and a dead imsd means
# SMS quietly degrades to "arrives whenever the SMSC next retries", so keep it
# supervised for the whole guest session.
if ! ps -ef 2>/dev/null | grep -v grep | grep -q "ims_watchdog.sh"; then
    cat > /data/local/tmp/ims_watchdog.sh <<'IMSW'
#!/system/bin/sh
LOG=/data/local/tmp/ims_watchdog.log
while true; do
    sleep 60
    if ! pidof imsd >/dev/null 2>&1; then
        setprop ctl.start imsd 2>/dev/null
        echo "$(date) restarted imsd (was missing)" >> "$LOG"
    fi
done
IMSW
    chmod 755 /data/local/tmp/ims_watchdog.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/ims_watchdog.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/ims_watchdog.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "imsd keepalive started (log: /data/local/tmp/ims_watchdog.log)"
fi

# Set permissive privapp permissions to avoid Signature|privileged fatal exceptions
set_prop ro.control_privapp_permissions log

# --- ONEUI PROTECTION & RESCUEPARTY DISABLE ---
echo "=== [1/6] Protecting OneUI Home Screen and Disabling RescueParty ==="
set_prop persist.sys.disable_rescue true
set_prop sys.rescue_boot_count 0
[ "$(getprop persist.sys.disable_rescue)" = true ] ||
    echo "!!! persist.sys.disable_rescue did not take (property space: $(pa_free "$PA_FILE") bytes left); guest_start.sh will not start the guest"
# OneOS: no snapshot of One UI Home's databases any more. OneLineage copied
# them to /data/local/tmp/lineage_backups here and back over the live ones on
# the way back: the only intended write into One UI's app data, never emptied.

# --- AUDIO LOW LATENCY TUNING ---
# Deep buffer must stay OFF. Tested live: with audio.deep_buffer.media=true the
# deep-buffer output opens but never consumes, and an AudioTrack write blocks
# forever (app_process hung in futex_wait). The 20 ms normal path is the one
# that actually works; a streamed tone on it is clean (0 underruns, 0 late
# writes). Offload stays off: no working vendor DSP session in the container.
echo "=== [2/6] Configuring Low-Latency Audio ==="
set_prop audio.offload.disable 1
set_prop audio.deep_buffer.media false
set_prop audio.offload.video false
set_prop vendor.audio.offload.track.enable false

# --- NETWORK BPF FIREWALL & DNS BYPASS ---
echo "=== [3/6] Configuring Network BPF Filters ==="
bpftool map update pinned /sys/fs/bpf/netd_shared/map_netd_configuration_map key hex 00 00 00 00 value hex 00 00 00 00 2>/dev/null || true
chmod 666 /dev/socket/dnsproxyd 2>/dev/null || true

# --- VERIFY STAGING ENVIRONMENT ---
echo "=== [4/6] Verifying Staging Environment ==="
# system.raw and the staged files were checked in the preflight, before the
# first change to the phone.
mkdir -p "$STAGE/data"
# OneOS: the staged scripts are the ones scripts/deploy-phone.sh pushed. They are
# no longer replaced by the switcher app's bundled copies, which can be older
# (an older APK would bring back scripts without the storage protections).
chmod 755 "$STAGE"/*.sh "$STAGE/zygote_exec" 2>/dev/null || true
# A namespace id left by a session that never returned (phone rebooted) must
# not make a failed switch's return kill whatever owns that id now.
rm -f "$STAGE/guest_mntns" "$STAGE/guest_rootdev"
# The return-key readers are armed last (below). Clear any set left by an
# earlier boot now, before any early return (a dry run, a guest_prepare
# failure): return_to_oneui.sh kills the PIDs listed there, which after a
# reboot are recycled and belong to other processes (run: a stale pids file
# signalled vold/apexd or the return script itself).
rm -rf "$STAGE/return_keys"

# OneOS: ColorOS components (the launcher among them) only log their info and
# debug lines with this set. guest_props.sh restore-persist removes it again on
# return (it is added after the persist snapshot).
setprop persist.sys.assert.panic true 2>/dev/null
# An app that crashes three times is moved to OPPO's zygote_ocomp, which nothing
# starts in the container: system_server then polled its socket for 62 s and no
# app could start (run 28, black home). oplus_boot_hangs.py blocks it as well.
setprop persist.sys.oplus.aotcrash_controller_enabled false 2>/dev/null
# The guest's own language, saved on the last return (guest_props.sh). The
# property is shared: One UI's value comes back with restore-persist. Only a
# language tag (en-US, zh-Hans-CN): the file may come from an older stage.
# Without one (a fresh stage): One UI's current language, its system_locales.
# persist.sys.locale is only One UI's boot default and can differ: run 41 got
# another language (the guest booted in it) while One UI showed en-GB,en-US. One UI's
# framework still runs here, so settings answers.
GL=$(head -n 1 "$STAGE/guest_locale" 2>/dev/null) GLW="saved guest locale"
case "$GL" in
    ''|-*|*[!A-Za-z0-9-]*) [ -n "$GL" ] && echo "Guest locale '$GL' in $STAGE/guest_locale is not a language tag; not used"; GL="" ;;
esac
if [ -z "$GL" ]; then
    GL=$(settings get system system_locales 2>/dev/null | head -n 1 | cut -d, -f1) GLW="One UI's language"
    case "$GL" in ''|null|-*|*[!A-Za-z0-9-]*) GL="" ;; esac
fi
if [ -n "$GL" ] && [ ${#GL} -le 35 ] && setprop persist.sys.locale "$GL" 2>/dev/null; then
    echo "Guest locale: $GL ($GLW)"
else
    echo "Guest locale: left at $(getprop persist.sys.locale) (no saved guest locale, One UI's language not readable)"
fi

# --- STOP THE HOST FRAMEWORK ---
# OneOS: before guest_prepare.sh, not after it. guest_prepare bind-mounts the
# guest's trees over the host's /data/app, /data/user, /data/user_de, ...; with
# One UI still running, its apps suddenly could not load their own APKs
# (1.2 million "ResourcesManager: failed to preload asset path" lines in a
# minute) and One UI's PackageManager saw its packages vanish.
# OneOS: silence the guest-session log storms (~30k lines/s in run 23: the
# host audioserver's "protected data in Parcel", the guest's CaptureStateTracker
# "Audio policy service died" retry spin, ResourcesManager). They pushed the
# SurfaceFlinger failures out of every tail-based check and can make logd drop
# lines. log.tag.* is not persistent; return_to_oneui.sh clears them.
# Run 32 (about 36k of 787k lines in the last 10 min, all from OPPO HALs and
# kernel nodes this phone does not have): PerformanceManager and ProjectManager
# log a full NullPointerException stack per call (1083 and 250 calls, on
# WindowManager and power key paths), SchedAssist "mSharedBinderUxFd=-1 is
# invalid" per binder call, GestureLog_OplusPenGestureManager per touch event,
# HoraeHelper "Cannot connect to HoraeService", OsenseResManagerService and
# OLC's postman "heap ... too small".
# Run 34 (678k lines in the 880 s after boot; the tags above logged 0): the
# guest system_server's UserAwareMgr logs every OPPO resource request and
# release (8684 lines, about 10/s; its urcc HAL is not declared here), and
# OplusUIFirst_TS "Failed to connect bpf bin" (396).
for t in CaptureStateTracker libbinder.Parcel Parcel ResourcesManager MediaCodecList AString BOOTPROF GED \
         PerformanceManager ProjectManager SchedAssist GestureLog_OplusPenGestureManager HoraeHelper OsenseResManagerService postman \
         UserAwareMgr OplusUIFirst_TS; do
    setprop "log.tag.$t" SILENT 2>/dev/null
done

# Wifi handover, recorded while One UI still runs. The guest's WifiService gets
# the supplicant (ISupplicant/default) from the shared servicemanager, which
# asks this init to start it; One UI's supplicant quits as soon as One UI's
# framework stops ("Client died. Terminating..."). The UI activator turns the
# guest's Wi-Fi on if One UI had it on. (Never print supplicant configs.)
case "$(settings get global wifi_on 2>/dev/null)" in 1|2) echo 1 ;; *) echo 0 ;; esac > "$STAGE/host_wifi_on"

# One UI's mobile data switch, for guest_prepare.sh (guest mobile data): it
# can only be read while One UI's framework runs.
HMD=$(settings get global mobile_data 2>/dev/null)
case "$HMD" in 0|1) echo "$HMD" ;; *) echo "" ;; esac > "$STAGE/host_mobile_data"
# One UI's preferred (attach) APN per SIM slot, for guest_prepare.sh (guest
# attach APN, a Pixel guest only: guards.txt without oplus-services_patched.jar).
# Runs 41 and 42: SIM 2 attached with the carrier's web1 in the guest and fell to 3G;
# One UI uses web2. Read only, from One UI's telephony provider (root's content
# queries): one "slot mcc mnc apn" line per SIM that has one, nothing when the
# provider gives no answer (the guest then keeps its own). ONEOS_GUEST_APN=0
# skips it.
rm -f "$STAGE/host_pref_apn"
if [ "${ONEOS_GUEST_APN:-1}" = 1 ] && ! grep -q ' oplus-services_patched.jar$' "$STAGE/guards.txt" 2>/dev/null; then
    # <row> <column>: the value of one column in a "Row: N a=1, b=2" line.
    row_val() { printf '%s\n' "$1" | tr ',' '\n' | sed -n "s/^ *\(Row: [0-9]* \)\{0,1\}$2=//p" | head -n 1; }
    timeout 10 content query --uri content://telephony/siminfo --projection _id:sim_id --where "sim_id>=0" 2>/dev/null |
        grep '^Row: ' | while IFS= read -r row; do
            sub=$(row_val "$row" _id); slot=$(row_val "$row" sim_id)
            case "$sub:$slot" in *[!0-9:]*|:*|*:) continue ;; esac
            prow=$(timeout 10 content query --uri "content://telephony/carriers/preferapn/subId/$sub" --projection apn:mcc:mnc 2>/dev/null | grep -m 1 '^Row: ')
            [ -n "$prow" ] || continue
            echo "$slot $(row_val "$prow" mcc) $(row_val "$prow" mnc) $(row_val "$prow" apn)"
        done | awk 'NF == 4 && $1 ~ /^[0-7]$/ && $2 ~ /^[0-9][0-9][0-9]$/ && $3 ~ /^[0-9][0-9][0-9]?$/ &&
                    $4 ~ /^[A-Za-z0-9._-]+$/ && !seen[$1]++' > "$STAGE/host_pref_apn"
    PA=$(tr '\n' ';' < "$STAGE/host_pref_apn" | sed 's/;$//; s/;/; /g')
    echo "One UI's preferred APNs (slot mcc mnc apn): ${PA:-none read}"
fi
SUPP_SVC=$(getprop | sed -n 's/^\[init\.svc\.\([^]]*supplicant[^]]*\)\]: .*/\1/p' | grep -v mainline | head -1)
echo "$SUPP_SVC" > "$STAGE/host_supplicant_svc"
echo "Host wifi_on: $(cat "$STAGE/host_wifi_on"), supplicant service: ${SUPP_SVC:-none} ($(getprop "init.svc.$SUPP_SVC"))"

# CPU caps and heat around the stop (run 44): One UI's thermal control (SIOP,
# in its system_server) had capped both CPU clusters at 2.112 GHz a second
# before the stop, and nothing lifted that cap for the whole session. Each
# cpufreq policy's scaling_max_freq/cpuinfo_max_freq, and the skin
# temperature from the thermal service (One UI's before the stop, none after)
# and from the vendor thermal daemon's log (Samsung: "thermal_core: pivot(AP)
# : 539, skin : 436", tenths of a degree). Read only.
cpu_caps() {
    caps=""
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -r "$p/scaling_max_freq" ] || continue
        caps="$caps ${p##*/} $(cat "$p/scaling_max_freq" 2>/dev/null)/$(cat "$p/cpuinfo_max_freq" 2>/dev/null)"
    done
    echo "${caps# }"
}
skin_temp() {
    ts=$(timeout 5 dumpsys thermalservice 2>/dev/null | sed -n '/^Current temperatures from HAL/,/^[^[:space:]]/p' |
        sed -n 's/.*mValue=\([-0-9.]*\), mType=[0-9]*, mName=SKIN,.*/\1/p' | head -n 1)
    tc=$(timeout 5 logcat -d -t 4000 -s thermal_core 2>/dev/null | sed -n 's/.* skin : \([0-9][0-9]*\).*/\1/p' | tail -n 1)
    if [ -n "$ts" ]; then ts="$ts C"; else ts="none"; fi
    if [ -n "$tc" ]; then tc="$((tc / 10)).$((tc % 10)) C"; else tc="none logged"; fi
    echo "thermal service $ts, thermal_core $tc"
}
echo "=== [4b/6] Stopping the One UI framework ==="
echo "Before the stop: CPU max/hw kHz: $(cpu_caps); skin: $(skin_temp)"
pkill -f "while true; do [ \"\$(getprop init.svc.zygote)\"" 2>/dev/null || true
pkill -f "while true; do for p in \\\$(pidof audioserver cameraserver)" 2>/dev/null || true
# Gap splash (see the top): once SplashActivity is on screen, freeze One UI's
# surfaceflinger on it before anything below removes a window (the deaths of
# system_server and the app would make it compose a frame without them). The
# pid goes to the guest's /data for guest_start.sh, and the loop below leaves
# surfaceflinger alone while that file exists.
SF_FROZEN=""
if [ "${ONEOS_GAP_SPLASH:-1}" = 1 ]; then
    n=0
    while [ $n -lt 15 ] && ! grep -q '^settled' "$GAP_SPLASH_LOG" 2>/dev/null; do n=$((n + 1)); sleep 0.2; done
    SFP=$(pidof surfaceflinger)
    if grep -q '^Status: ok' "$GAP_SPLASH_LOG" 2>/dev/null && grep -q '^settled' "$GAP_SPLASH_LOG" &&
       [ -n "$SFP" ] && [ "$SFP" = "${SFP%% *}" ] && echo "$SFP" > "$STAGE/data/oneos_host_sf_frozen"; then
        if kill -STOP "$SFP" 2>/dev/null; then SF_FROZEN=$SFP; else rm -f "$STAGE/data/oneos_host_sf_frozen"; fi
    fi
    echo "Gap splash: $(grep -E '^(Status|LaunchState|TotalTime|Error)' "$GAP_SPLASH_LOG" 2>/dev/null | tr '\n' ' ')waited $((n / 5)).$((n % 5 * 2))s; One UI's surfaceflinger ${SF_FROZEN:-not frozen, black gap}${SF_FROZEN:+ frozen on it at $(date +%T)}"
fi
setprop ctl.stop zygote
# zygote64_32 phones (Galaxy S23): One UI's 32-bit zygote is a service of its
# own, and stopping zygote leaves it running. The guest's system_server then
# asked it to preload (SecondaryZygotePreload, as the phone lists 32-bit ABIs):
# One UI's idmap2 rewrote the framework overlay idmaps in /data/resource-cache,
# the stage's through the bridge, under the guest's mapped copies, and the
# guest's system_server died in IdmapResMap::Lookup 0.4 s later, every session
# (699602d7). Stopped with zygote, kept stopped below, started on the return.
[ -n "$(getprop init.svc.zygote_secondary)" ] && setprop ctl.stop zygote_secondary
# Android 17's zygote_next (native-only processes, app zygotes) stays One UI's
# for now: the image's own, started by guest_start.sh in 0.4.25-hyperos, forked
# children that exited at once ("Failed to poll client socket: EBADF"), an app
# zygote never came up, system_server's process starts waited on it and it
# died after two minutes (HyperOS run 12, docs/hyperos.md).
[ -n "$SF_FROZEN" ] || setprop ctl.stop surfaceflinger
# audioserver/cameraserver are deliberately left running. The guest shares this
# binder namespace, and its AudioService.<init> -> AudioDeviceBroker.init ->
# AudioSystem::addAudioPortCallback waits on media.audiopolicy with no timeout:
# with no audio policy service registered, system_server's main thread hangs
# (~2 min watchdog stall, boot stuck on the animation). Freezing them with
# kill -STOP is the worst of both worlds - the binder registration survives
# while the process can never answer.
[ -n "$SF_FROZEN" ] || kill -9 $(pidof surfaceflinger) 2>/dev/null || true
kill -9 $(pidof bootanimation) 2>/dev/null || true
kill -9 $(pidof app_process64) 2>/dev/null || true
kill -9 $(pidof zygote_exec) 2>/dev/null || true
kill -9 $(pidof zygote64) 2>/dev/null || true
kill -9 $(pidof zygote_secondary) 2>/dev/null || true
kill -9 $(pidof system_server) 2>/dev/null || true
# Suppress the host zygote, so Samsung init does not resurrect it. OneOS: and
# the host surfaceflinger: guest_start.sh restarts the vendor composer, whose
# rc has "onrestart restart surfaceflinger", and the revived Samsung
# surfaceflinger then answered the guest's private SurfaceFlinger calls
# (ColorOS's OPlusRefreshRateConfigs got a SecurityException and took
# system_server down). init.svc.* only covers init's services, never the
# guest's own surfaceflinger. return_to_oneui.sh kills this loop by matching
# "ctl.stop zygote".
# A guest_audio.flag from an earlier session must not make the loop below stop
# Samsung's audioserver in a session that keeps it (ONEOS_GUEST_AUDIO=0).
rm -f "$STAGE/data/guest_audio.flag"
nohup $BB sh -c "while true; do [ \"\$(getprop init.svc.zygote)\" = \"running\" ] && setprop ctl.stop zygote; [ \"\$(getprop init.svc.zygote_secondary)\" = \"running\" ] && setprop ctl.stop zygote_secondary; [ ! -f $STAGE/data/oneos_host_sf_frozen ] && [ \"\$(getprop init.svc.surfaceflinger)\" = \"running\" ] && setprop ctl.stop surfaceflinger; [ \"\$(getprop init.svc.bootanim)\" = \"running\" ] && setprop ctl.stop bootanim; [ -f $STAGE/data/guest_audio.flag ] && [ \"\$(getprop init.svc.audioserver)\" = \"running\" ] && setprop ctl.stop audioserver; sleep 0.2; done" </dev/null >/dev/null 2>&1 &
sleep 1
# One UI's system_server kept Samsung's softdog (/dev/watchdog, 100 s) and is
# gone: its magic close now, before guest_prepare.sh's feeder takes over (see
# there; the Exynos phones panicked when nothing fed it).
SOFTDOG_V=0
if e=$(printf V 2>&1 > /dev/watchdog); then echo "Softdog: /dev/watchdog closed with V (One UI's system_server stopped)"; SOFTDOG_V=1
else echo "Softdog: /dev/watchdog not written ($e)"; fi
# The Exynos phones (S26+ 756047eb, Z Flip7 aaeea148, both 0.4.20) still
# panicked, "Software Watchdog Timer expired 100s" about 100 s after One UI's
# system_server stopped: /dev/watchdog is busy there (init's watchdogd) and
# neither has /dev/softdog, which 0.4.20 fed. Samsung's init owns the softdog
# (init.sysfw.rc: softdog init / settimeout 100 / disable): it disables it when
# zygote stops, which fired on both (resetreason restarted) and still did not
# hold, most likely because One UI's system_server kicked it again before it
# died. Its own off switch, persist.vendor.softdog=off ("softdog disable";
# Samsung sets it on unlocked and GSI phones, and One UI's system_server then
# leaves the softdog alone), now that system_server is gone. Only where the "V"
# above could not reach it; the snapshot taken before the switch puts the
# property back on the return (restore-persist), and after a hard reset too
# (recover).
if [ "$SOFTDOG_V" = 0 ] && grep -q '^on property:persist\.vendor\.softdog=off' /system/etc/init/init.sysfw.rc 2>/dev/null; then
    sd=$(getprop persist.vendor.softdog)
    if [ "$sd" = off ]; then echo "Softdog: persist.vendor.softdog already off"
    else
        setprop persist.vendor.softdog off
        echo "Softdog: persist.vendor.softdog off for the session (was ${sd:-unset}): Samsung's init disables its software watchdog"
    fi
fi
echo "After the stop: CPU max/hw kHz: $(cpu_caps); skin: $(skin_temp)"

# --- MOUNT PREPARATION ---
# OneOS safeguards: One UI's /apex mounts must look the same after the
# container setup, and its APEXes on /data must still read back cleanly.
# (Field 5 of mountinfo is the mount point; matching anywhere in the line
# also caught binds whose *source* was under /apex.)
awk '$5 ~ /^\/apex(\/|$)/ {print $5, $10}' /proc/1/mountinfo | sort > "$STAGE/host_apex.before"
/system/bin/sh "$STAGE/check_host_apex.sh" before-setup
# The device states, display layouts and touch-port associations the guest's
# framework finds on the host, copied for the logs (pull-run-logs.sh takes
# $S/diag_*). toybox grep has no \| in basic regexps, which left the summary
# line empty in run 30 (takeover_app.log:15): use -E.
mkdir -p "$STAGE/diag_host"
for f in /odm/etc/devicestate/device_state_configuration_private.xml /odm/etc/devicestate/device_state_configuration.xml /vendor/etc/devicestate/device_state_configuration.xml; do
    [ -f "$f" ] || continue
    echo "Device states for the guest from $f: $(tr -d ' \t\r\n' < "$f" | grep -o -E '<identifier>[0-9]+</identifier>|<name>[^<]*</name>|PROPERTY_[A-Z_]+' | sed 's/<[^>]*>//g' | tr '\n' ' ')"
    break
done
for f in /vendor/etc/devicestate/device_state_configuration.xml /vendor/etc/displayconfig/display_layout_configuration.xml /vendor/etc/input-port-associations.xml /vendor/odm/etc/input-port-associations.xml; do
    [ -f "$f" ] && cp "$f" "$STAGE/diag_host/$(echo "${f#/}" | tr / _)"
done
ls -l /vendor/etc/displayconfig /vendor/odm/etc/displayconfig /vendor/odm/etc/devicestate > "$STAGE/diag_host/displayconfig_ls.txt" 2>&1
# Samsung switches each panel's touch IC from One UI's framework through its
# sysinput HAL ("enabled@<display state>,<event>", "set_fold_state"; run 30
# all.log 10:13:06). In the guest only the activator's fold monitor does it, for
# the cover IC: record where the nodes are.
{ for d in /sys/class/sec/tsp*; do
      echo "== $d"; ls "$d" "$d/input" 2>&1
      echo "input/enabled: $(cat "$d/input/enabled" 2>&1)"
  done
  for b in /vendor/bin/hw/*sysinput*; do
      echo "== $b"; strings -a "$b" 2>/dev/null | grep -E '^/sys/|enabled|fold_state' | head -40
  done
} > "$STAGE/diag_host/touch_nodes.txt" 2>&1
echo "=== [5/6] Executing Mount Hierarchy Preparation ==="
/system/bin/sh "$STAGE/guest_prepare.sh"
PREP_RET=$?
if [ $PREP_RET -ne 0 ]; then
    echo "ERROR: guest_prepare.sh failed (code $PREP_RET)! Returning to One UI."
    # The One UI framework is already stopped; never leave the phone like that.
    /system/bin/sh "$STAGE/return_to_oneui.sh"
    exit 1
fi
awk '$5 ~ /^\/apex(\/|$)/ {print $5, $10}' /proc/1/mountinfo | sort > "$STAGE/host_apex.after"
if ! cmp -s "$STAGE/host_apex.before" "$STAGE/host_apex.after"; then
    echo "ERROR: the container setup changed One UI's /apex mounts:"
    diff "$STAGE/host_apex.before" "$STAGE/host_apex.after" | head -20
    echo "Aborting and returning to One UI."
    /system/bin/sh "$STAGE/return_to_oneui.sh"
    exit 1
fi
echo "One UI's /apex mounts unchanged by the container setup"
echo "Host mounts under $STAGE (outside the rootfs): $(awk -v s="$STAGE/" -v r="$STAGE/rootfs" 'index($2, s) == 1 && index($2, r) != 1 {print $2}' /proc/mounts | tr '\n' ' ')"
if ! /system/bin/sh "$STAGE/check_host_apex.sh" after-setup; then
    echo "ERROR: One UI's APEXes no longer read back after the container setup."
    echo "Aborting and returning to One UI."
    /system/bin/sh "$STAGE/return_to_oneui.sh"
    exit 1
fi
if [ "${ONEOS_PREPARE_ONLY:-0}" = "1" ]; then
    echo "ONEOS_PREPARE_ONLY=1: container prepared and checked, returning to One UI without starting the guest."
    /system/bin/sh "$STAGE/return_to_oneui.sh"
    /system/bin/sh "$STAGE/check_host_apex.sh" after-return
    exit 0
fi

# OneOS: keep the network usable while the guest boots. With One UI's
# ConnectivityService gone nothing maintains the routes, so the phone dropped
# off the network (and the adb tunnel with it) until the guest finished
# booting, which for a broken guest is never. Run guest_prepare's net_fix.sh
# from the host side for the whole session, and log what the network looked
# like, so a drop that routing cannot fix (wifi itself going away) shows up.
NETFIX="$STAGE/data/local/tmp/net_fix.sh"
$BB sh -c "
    while [ -f $STAGE/rootfs/system/build.prop ]; do
        /system/bin/sh $NETFIX 2>&1 | sed \"s/^/\$(date +%T) /\"
        {
            echo \"--- \$(date +%T)\"
            ip -4 -o addr show wlan0 2>&1 | awk '{print \$4}'
            ip rule show 2>&1 | head -6
            ip route show table 4242 2>&1
            ping -c 1 -W 2 \$(ip route show table 4242 2>/dev/null | awk '/default/{print \$3; exit}') >/dev/null 2>&1 && echo gateway: ok || echo gateway: unreachable
        } 2>&1
        # Watch One UI's APEX backing files: after earlier sessions One UI's
        # decompressed APEXes read back with dm-verity I/O errors.
        {
            echo \"--- \$(date +%T) apex\"
            ls -l /data/apex/decompressed/ 2>&1 | awk '{print \$5, \$6, \$7, \$NF}'
            for l in /sys/block/loop*/loop/backing_file; do
                case \"\$(cat \$l 2>/dev/null)\" in /data/apex/*) echo \"\$(basename \$(dirname \$(dirname \$l))): \$(cat \$l)\";; esac
            done
        } >> $STAGE/apex_watch.log 2>&1
        sleep 10
    done
" </dev/null >>"$STAGE/net_watch.log" 2>&1 &

# The guest's own build props (ro.oplus.* etc.), now that its rootfs is mounted.
/system/bin/sh "$STAGE/guest_props.sh" add "$STAGE/rootfs"

# --- STOP HOST DAEMONS & LAUNCH CONTAINER ---
echo "=== [6/6] Launching the guest takeover daemon ==="

# Stop the HOST media codec stack. The guest's libmedia binds `media.codec` from
# the shared servicemanager, i.e. Samsung's mediaserver - whose IMediaCodecList
# AIDL hash differs from the GSI's. The reply parcel is then parsed as garbage
# ("enforceInterface() expected 'android.gui.IGraphicBufferProducer' but read
# 'android.media.IMediaCodecList'", "AString: ctor got NULL"), which yields a
# codec list with a bogus length, so findCodecForFormat -> codecHandlesFormat
# spins ~2M times inside both system_server and SystemUI, round-tripping to
# mediaserver each iteration. That is the 125% CPU / constant overheating / GB
# of logcat. With no media.codec registered the lookup fails fast and the list
# is empty. Audio is unaffected (audioserver is its own process and is kept).
# mediaserver must stay UP even though the codec list is unusable: apps play
# short sounds with MediaPlayer, and MediaPlayer.setDataSource blocks in
# IMediaDeathNotifier::getMediaPlayerService when "media.player" is missing.
# That is a 5 s main-thread stall -> ANR -> force-close: Messaging died on every
# send because of its "sent" sound (playSentSound), and any app doing the same
# would die too. Keep only the codec processes down, which is what causes the
# spin described above.
#
# OneOS: on Android 17 there is no media.codec service any more (codecs go
# through the Codec2 HAL stores directly), yet guests still overheat talking to
# Samsung's modified mediaserver/mediaextractor/mediametrics. So by default the
# host's copies are stopped and guest_start.sh starts the GUEST's own, which
# share the guest framework's AIDL. The Codec2 HALs (vendor-qti-media-c2-hal,
# media.swcodec) stay on the host: they are stable versioned AIDL either way.
# Set ONEOS_GUEST_MEDIA=0 to get the old behaviour back.
if [ "${ONEOS_GUEST_MEDIA:-1}" = "1" ]; then
    for svc in media mediaextractor mediametrics media.codec media.metrics; do
        setprop ctl.stop $svc 2>/dev/null || true
    done
    kill -9 $(pidof mediaserver) $(pidof mediaextractor) $(pidof media.metrics) $(pidof media.codec) 2>/dev/null || true
    touch "$STAGE/data/guest_media.flag"
else
    rm -f "$STAGE/data/guest_media.flag"
    setprop ctl.start media 2>/dev/null || true
    for svc in media.codec media.metrics; do
        setprop ctl.stop $svc 2>/dev/null || true
    done
    kill -9 $(pidof media.codec) $(pidof media.metrics) 2>/dev/null || true
fi

# Audio handover (run 29): ColorOS's IAudioPolicyService numbering is not
# Samsung's (listAudioProductStrategies -61, setStreamVolumeIndex -22,
# getDevicesForAttributes arrived as an AudioFlinger-only call) and Samsung's
# AudioFlinger refused every app stream. Stop the host audioserver;
# guest_start.sh starts the GUEST's, which drives Samsung's audio HAL through
# the stable android.hardware.audio.core AIDL like a GSI, and falls back to
# Samsung's if it does not register. The HAL is stopped and started so the
# guest's gets it fresh. ONEOS_GUEST_AUDIO=0 keeps Samsung's audioserver.
if [ "${ONEOS_GUEST_AUDIO:-1}" = "1" ]; then
    touch "$STAGE/data/guest_audio.flag"
    AHAL=$(getprop | sed -n 's/^\[init\.svc\.\(vendor\.audio-hal[^]]*\)\]: \[running\]$/\1/p' | tr '\n' ' ')
    echo "$AHAL" > "$STAGE/host_audio_hal_svcs"
    setprop ctl.stop audioserver
    n=0
    while [ $n -lt 25 ] && pidof audioserver >/dev/null; do n=$((n + 1)); sleep 0.2; done
    kill -9 $(pidof audioserver) 2>/dev/null || true
    for s in $AHAL; do setprop ctl.stop $s; done
    sleep 1
    for s in $AHAL; do setprop ctl.start $s; done
    echo "Host audioserver: $(getprop init.svc.audioserver); audio HAL services restarted: ${AHAL:-none found}"
else
    rm -f "$STAGE/data/guest_audio.flag" "$STAGE/host_audio_hal_svcs"
    setprop ctl.start audioserver
    n=0; while [ $n -lt 25 ] && ! service check media.audio_policy 2>/dev/null | grep -q ": found"; do n=$((n + 1)); sleep 0.2; done
    echo "Host audioserver kept: $(getprop init.svc.audioserver)"
fi

# Same handover for wifi. The guest's WifiService binds IWificond (service
# "wifinl80211") and drives the vendor HAL through it. Samsung's wificond is
# still holding the client interface that One UI's (now dead) WifiService
# created, so every startScan() comes back "status: -1" and the framework sees
# "No scan results" - wifi looks broken but only the scanner is wedged. The
# GSI's own wificond starts in guest_start.sh and scans fine against the same
# vendor HAL.
setprop ctl.stop wificond 2>/dev/null || true
kill -9 $(pidof wificond) 2>/dev/null || true
sleep 1
# Pixel 17 has no wificond (only AOSP's /system/bin/wificond link to a
# system_ext binary its system_ext lacks) and needs none: its wifi module
# (config_wificondMigrationEnabled=true) drives nl80211 itself ("Nl80211Native:
# useWificond: false") and never binds "wifinl80211". One UI's is restarted idle,
# with no client interface, for One UI only; its "No handler for scan result
# notification" warnings are expected (ColorOS run 36a has them too). The link is
# absolute, so resolve it inside the guest's rootfs, not the host's.
GW=$(readlink "$STAGE/rootfs/system/bin/wificond" 2>/dev/null)
case "$GW" in /*) GW="$STAGE/rootfs$GW" ;; "") GW="$STAGE/rootfs/system/bin/wificond" ;; *) GW="$STAGE/rootfs/system/bin/$GW" ;; esac
if [ ! -f "$GW" ]; then
    setprop ctl.start wificond 2>/dev/null || true
    echo "No wificond in the guest image (its wifi module drives nl80211 itself): One UI's restarted idle ($(getprop init.svc.wificond))"
fi
# The phone's own A/B updater stays stopped while the guest runs. It is a
# shared binder service: the guest's Google Play services system update, or
# the setup wizard's update check, could hand it a payload for the phone.
# init does not restart a service stopped this way; the return's reboot starts
# it again (an interrupted One UI update resumes then).
if [ -n "$(getprop init.svc.update_engine)" ] && [ "$(getprop init.svc.update_engine)" != stopped ]; then
    setprop ctl.stop update_engine 2>/dev/null
    n=0; while [ $n -lt 10 ] && [ "$(getprop init.svc.update_engine)" = running ]; do n=$((n + 1)); sleep 0.2; done
    echo "Phone updater (update_engine) stopped for the session: $(getprop init.svc.update_engine)"
fi

# ColorOS's bootanimation opens /data/local/bootanimation.zip before its own
# Find N animation (run 30 logcat). The owner wants ColorOS's animation kept,
# so make sure nothing in the staged /data shadows it.
rm -f "$STAGE/data/local/bootanimation.zip"
# return_to_oneui.sh creates data/oneos_rec_stop as its first step (for the
# screen recording) and nothing removes it unless a recording starts; the
# session sampler below stops on it, so clear the last session's.
rm -f "$STAGE/data/oneos_rec_stop"

# Copy inner script and zygote_exec into container data partition. rm the
# destinations first: a guest could have left them as symlinks into host /data,
# and cp -f through such a link would overwrite a host file as root.
# (master_inner.sh: the copy's name up to app 0.3.6, removed with it.)
rm -f "$STAGE/data/guest_start.sh" "$STAGE/data/zygote_exec" "$STAGE/data/master_inner.sh"
cp -f "$STAGE/guest_start.sh" "$STAGE/data/guest_start.sh"
chmod 755 "$STAGE/data/guest_start.sh"
cp -f "$STAGE/zygote_exec" "$STAGE/data/zygote_exec"
chmod 755 "$STAGE/data/zygote_exec"
# HyperOS: the launcher for hyos_spawner (guest_start.sh), from its set only.
rm -f "$STAGE/data/socket_exec"
if [ -f "$STAGE/socket_exec" ] && [ ! -L "$STAGE/socket_exec" ]; then
    cp -f "$STAGE/socket_exec" "$STAGE/data/socket_exec" && chmod 755 "$STAGE/data/socket_exec"
fi

# Launch takeover inside isolated mount namespace
$BB unshare -m $BB sh "$STAGE/data/guest_start.sh" </dev/null >"$STAGE/data/takeover.log" 2>&1 &
TAKEOVER_PID=$!
# Remember the container's mount namespace: return_to_oneui.sh kills exactly
# the processes in it. Guest daemons share names and even command lines with
# the host's (the guest vold is launched with the same flags as One UI's), so
# killing by name took down the host vold and init rebooted ("vold-failed").
sleep 0.5
readlink "/proc/$TAKEOVER_PID/ns/mnt" > "$STAGE/guest_mntns" 2>/dev/null
# And the device of the guest's root filesystem: zygote gives every app its own
# mount namespace, but all of them share this root (return_to_oneui.sh).
stat -c %d "$STAGE/rootfs" > "$STAGE/guest_rootdev" 2>/dev/null
echo "Guest mount namespace: $(cat "$STAGE/guest_mntns" 2>/dev/null) (host: $(readlink /proc/1/ns/mnt))"
echo "Takeover daemon PID: $TAKEOVER_PID"
# The guest zygote's sockets. On an S24 Ultra with LSPosed's Vector daemon
# (0.4.15), 20 s into the session the daemon restarted One UI's zygote: init
# made /dev/socket/zygote and usap_pool_primary over the guest's, the loop
# above stopped that zygote, and init's cleanup unlinked both files. The
# guest's system_server then found no zygote socket ("Error connecting to
# zygote ... No such file or directory") and no app ever started. /dev is the
# same tmpfs in the guest, so once zygote_exec has made them and turned into
# app_process64 (the takeover pid), each is bound onto itself here, in init's
# mount namespace. init can then neither unlink nor replace them (EBUSY): a
# restarted One UI zygote starts without its sockets and the loop stops it,
# and the guest keeps its own. return_to_oneui.sh takes the binds off before
# One UI's zygote starts again; a reboot drops them.
protect_zygote_sockets() {
    n=0
    while :; do
        case "$(readlink "/proc/$TAKEOVER_PID/exe" 2>/dev/null)" in
            */app_process64) break ;;
            '') echo "Zygote sockets: the takeover process is gone, nothing to protect"; return 0 ;;
        esac
        n=$((n + 1))
        [ $n -lt 3000 ] || { echo "Zygote sockets: the guest zygote did not start within 300 s, not protected"; return 0; }
        sleep 0.1
    done
    for s in zygote usap_pool_primary; do
        f=/dev/socket/$s
        if [ -S "$f" ] && ! $BB awk -v m="$f" '$5 == m { f = 1 } END { exit !f }' /proc/self/mountinfo &&
           $BB mount --bind "$f" "$f"; then
            echo "Zygote sockets: $f bound onto itself at $(date +%T) (One UI's zygote is $(getprop init.svc.zygote))"
        else
            echo "!!! Zygote sockets: $f not protected (socket: $([ -S "$f" ] && echo yes || echo no))"
        fi
    done
}
protect_zygote_sockets </dev/null &
# Gap splash safety net: guest_start.sh releases the frozen surfaceflinger
# about 1 s after the pivot. If it never gets there (a FATAL exit), kill it
# here, so the panel and the auto-return below behave as without the splash.
if [ -n "$SF_FROZEN" ]; then
    $BB sh -c "sleep 20; f=$STAGE/data/oneos_host_sf_frozen; [ -s \$f ] || exit 0; p=\$(cat \$f); rm -f \$f; setprop ctl.stop surfaceflinger; [ \"\$(cat /proc/\$p/comm 2>/dev/null)\" = surfaceflinger ] && kill -9 \$p; echo \"\$(date +%T) guest_start.sh never released surfaceflinger \$p: killed\"" </dev/null >>"$GAP_SPLASH_LOG" 2>&1 &
fi

# ColorOS-only settings below (brightness scale, fold key) are left alone on
# other systems (Pixel): the rootfs is mounted since guest_prepare.sh.
GUEST_OPLUS=0
[ -f "$STAGE/rootfs/system/framework/oplus-services.jar" ] && GUEST_OPLUS=1
# HyperOS keeps system_ext at the image root (system/system_ext links to One UI's).
GUEST_MIUI=0
[ -f "$STAGE/rootfs/system_ext/framework/miui-services.jar" ] && GUEST_MIUI=1
# A guest whose status bar is AOSP's SystemUI, laid out from the framework's
# cutout: every non-ColorOS guest, and Infinity-X, which carries OPPO's framework
# jars (GUEST_OPLUS) on a LineageOS base. ColorOS's own SystemUI places its icons
# from ro.oplus.display.screenhole.positon (guest_props.sh) instead, and HyperOS's
# MIUI SystemUI places its own.
GUEST_AOSP_SYSUI=1
[ $GUEST_OPLUS = 1 ] && [ ! -f "$STAGE/rootfs/system/framework/org.lineageos.platform.jar" ] && GUEST_AOSP_SYSUI=0
[ $GUEST_MIUI = 1 ] && GUEST_AOSP_SYSUI=0
# Window-level blur default for a new stage (UI activator below); only 0 or 1
# reaches the root shell.
GUEST_BLUR=1; [ "${ONEOS_GUEST_BLUR:-1}" = 1 ] || GUEST_BLUR=0
# Settings for the UI activator (run 44), checked here so that only 0/1, off,
# auto or a plain number goes into its root shell.
# ONEOS_WIFI_VERBOSE=1: verbose Wi-Fi logging in the guest (debug text under
# every network); otherwise it is switched off on every boot.
WIFI_VERBOSE=0; [ "${ONEOS_WIFI_VERBOSE:-0}" = 1 ] && WIFI_VERBOSE=1
# ONEOS_GUEST_DENSITY=off|auto|<dpi 120-640>: the inner panel's density.
GUEST_DENSITY=auto
case "${ONEOS_GUEST_DENSITY:-auto}" in
    off|auto) GUEST_DENSITY=${ONEOS_GUEST_DENSITY:-auto} ;;
    [1-9][0-9][0-9]) [ "$ONEOS_GUEST_DENSITY" -ge 120 ] && [ "$ONEOS_GUEST_DENSITY" -le 640 ] && GUEST_DENSITY=$ONEOS_GUEST_DENSITY ;;
esac
[ "$GUEST_DENSITY" = "${ONEOS_GUEST_DENSITY:-auto}" ] || echo "ONEOS_GUEST_DENSITY=$ONEOS_GUEST_DENSITY is not off, auto or 120-640: auto"
# ONEOS_GUEST_POSTURE=live: the fold line's posture follows the guest's hinge
# state instead of always flat.
# Live by default with the hinge sets of pull request #1 (Fold8) and the Fold8 Ultra's.
POSTURE_DEFAULT=flat
case "${ONEOS_PROFILE:-}:$GUEST_OPLUS" in
    f8:1) HINGE_SET=n6-f8 ;;
    f8:0) HINGE_SET=pixel-f8 ;;
    f8u:1) HINGE_SET=n6-f8u ;;
    f8u:0) HINGE_SET=pixel-f8u ;;
    *) HINGE_SET="" ;;
esac
if [ -n "$HINGE_SET" ] && grep -q "^  \"set\": \"$HINGE_SET\",\$" "$STAGE/.oneos_stage"; then
    POSTURE_DEFAULT=live
fi
GUEST_POSTURE_LIVE=0; [ "${ONEOS_GUEST_POSTURE:-$POSTURE_DEFAULT}" = live ] && GUEST_POSTURE_LIVE=1
GUEST_FOLD_FORM=0; [ "${ONEOS_GUEST_FORM:-fold}" = fold ] && GUEST_FOLD_FORM=1
# Start UI Activator daemon
$BB sh -c "
BB=\"$BB\"
[ -n \"\$BB\" ] || BB=\$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox)
while true; do
    sleep 2
    PID=\$(pidof system_server | awk '{print \$1}')
    if [ -n \"\$PID\" ]; then
        if $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys window 2>/dev/null | grep -q 'mStatusBar'; then
            echo '[UI Activator] WindowManager is ready! Dismissing bootanim and unlocking...'
            setprop service.bootanim.exit 1
            kill -9 \$(pidof bootanimation) 2>/dev/null
            sleep 1
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/svc power stayon true
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put global stay_on_while_plugged_in 7
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put system screen_off_timeout 2147483647
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put system haptic_feedback_enabled 1
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put system peak_refresh_rate 120.0
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put system min_refresh_rate 120.0
            # ColorOS's touch idle (OTI) pushes SurfaceFlinger to 240/60 Hz over the
            # 120 Hz policy on this panel (run 29); also staged off by guest_prepare.sh.
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys oplus_vrr_service oti false >/dev/null 2>&1 && echo '[UI Activator] refresh rate: ColorOS touch idle off'
            # Navigation mode belongs to ColorOS: its SystemUI sets the navbar
            # overlay and navigation_mode from secure hide_navigationbar_enable
            # (0 buttons, 2/3 gestures). Forcing AOSP's gestural overlay left that
            # key at 0 (run 28): only a gesture handle was drawn while the
            # launcher stayed in 3-button mode, so neither worked. Keep the
            # user's choice; a stage that never had the key gets gestures.
            NAVK=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get secure hide_navigationbar_enable 2>/dev/null)
            [ \"\$NAVK\" = null ] && $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put secure hide_navigationbar_enable 3 2>/dev/null
            NAVM=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get secure navigation_mode 2>/dev/null)
            echo \"[UI Activator] navigation: hide_navigationbar_enable=\$NAVK navigation_mode=\$NAVM\"
            case \"\$NAVK:\$NAVM\" in 0:2|2:0|3:0) echo \"[UI Activator] WARNING: ColorOS nav key and AOSP navigation_mode disagree\" ;; esac
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/pm disable android.ext.services/android.ext.services.notification.Assistant 2>/dev/null || true
            # Fallback for a staged /data that had no settings files to seed, before
            # HOME: a fresh stage has none. Pixel's two setup wizards (ColorOS has
            # none) would take that first boot and wait for Google services.
            # With Google services presented (guest_prepare.sh wrote
            # data/oneos_gms_present) neither the keys nor the wizards are touched:
            # Pixel's setup wizard runs (HOME is the wizard while the stage is not
            # provisioned), sets both keys and turns itself off when it finishes
            # (it can be skipped without an account), and the stage keeps that.
            if [ -f $STAGE/data/oneos_gms_present ]; then
                echo \"[UI Activator] Google services presented: setup left to the setup wizard (device_provisioned=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get global device_provisioned 2>/dev/null) user_setup_complete=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get secure user_setup_complete 2>/dev/null))\"
            else
            for kv in 'global device_provisioned' 'secure user_setup_complete'; do
                [ \"\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get \$kv 2>/dev/null)\" = 1 ] || $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put \$kv 1
            done
            for p in com.google.android.setupwizard com.google.android.pixel.setupwizard; do
                $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/pm disable-user --user 0 \$p >/dev/null 2>&1 && echo \"[UI Activator] \$p disabled (setup is done in the container)\"
            done
            fi
            # Run 43: the verbose Wi-Fi logging run 42 switched on for its diag_wifi
            # capture (below) was saved in the stage's WifiConfigStore.xml and put
            # debug text (frequency, BSSID, RSSI, score) under every network in the
            # setup wizard and Settings. Set on every boot, for every guest, Wi-Fi
            # on or off, before HOME so the setup wizard's Wi-Fi page never shows
            # it: disabled (which also clears what runs 42 and 43 saved) unless
            # ONEOS_WIFI_VERBOSE=1.
            # Samsung's IMS app in the guest (guest_prepare.sh, ONEOS_GUEST_SEC_IMS=1):
            # the guest's telephony is told to bind it through the carrier config
            # override, both slots, kept in the guest's carrier config store; then
            # what the package manager and the ImsResolver made of it. The marker
            # is in data the guest can write: -e and never a link (see the blur
            # marker below).
            if [ -e $STAGE/data/oneos_sec_ims ] && [ ! -L $STAGE/data/oneos_sec_ims ]; then
                for s in 0 1; do
                    timeout 10 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd phone cc set-value -s \$s -p config_ims_mmtel_package_override_string com.sec.imsservice >/dev/null 2>&1
                done
                echo \"[UI Activator] Samsung IMS: package \$(timeout 10 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/pm path com.sec.imsservice 2>/dev/null | head -1 | cut -c9-)\"
                echo \"[UI Activator] Samsung IMS: mmtel override \$(timeout 10 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd phone cc get-value -s 0 config_ims_mmtel_package_override_string 2>/dev/null | tail -1)\"
                timeout 10 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys phone 2>/dev/null | grep -i -m 6 'ImsResolver\|imsservice\|MmTel' | sed 's/^/[UI Activator] Samsung IMS: /'
            fi
            if [ $WIFI_VERBOSE = 1 ]; then WV=enabled; else WV=disabled; fi
            timeout 10 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd wifi set-verbose-logging \$WV >/dev/null 2>&1
            echo \"[UI Activator] wifi: verbose logging \$WV -> \$(timeout 10 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd wifi is-verbose-logging 2>&1 | head -1)\"
            # Window-level blur (run 44, owner): guest_props.sh tells SurfaceFlinger
            # blur is supported, but the Pixel kept \"Allow window-level blurs\" off
            # (Developer options) until the owner turned it on. Allowed once, on a
            # stage's first boot (a marker in the guest's data); a later choice in
            # Developer options stays. ColorOS guests and ONEOS_GUEST_BLUR=0: untouched.
            # The marker is in data the guest can write, and this shell is host
            # root: it is made with mkdir and checked with -e and -L, never with
            # touch or -f, which follow a link the guest may have left there to
            # a path in One UI's /data (an older marker, a file, still counts).
            if [ $GUEST_OPLUS = 0 ] && [ -L $STAGE/data/oneos_blur_default ]; then
                echo \"[UI Activator] window blur: data/oneos_blur_default is a link, not made by OneOS; left alone\"
            elif [ $GUEST_OPLUS = 0 ] && [ $GUEST_BLUR = 1 ] && [ ! -e $STAGE/data/oneos_blur_default ]; then
                $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put global disable_window_blurs 0 >/dev/null 2>&1 &&
                    mkdir $STAGE/data/oneos_blur_default 2>/dev/null &&
                    echo \"[UI Activator] window blur: allowed (disable_window_blurs 0, first boot of this stage)\"
            fi
            # Cache quotas (S25 Ultra session af6c2b17): installd.setAppQuota is
            # blocked in the container (guest_installd_abi.py; quotas are set on
            # One UI's /data), but StorageStatsService still worked them out
            # after app installs and storage changes and logged a stack trace
            # per app: 33464 in 10 minutes of Play Store updates. Its own
            # setting turns the calculation off. Every boot, every guest.
            CQ=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get global enable_cache_quota_calculation 2>/dev/null)
            if [ \"\$CQ\" != 0 ]; then
                $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put global enable_cache_quota_calculation 0 >/dev/null 2>&1 &&
                    echo \"[UI Activator] cache quotas: calculation off (was \${CQ:-unset}; installd.setAppQuota is blocked in the container)\"
            fi
            # Knox's edmnativehelper, which One UI's cameraserver (shared with the
            # guest, left running) asks on every camera open. Only One UI's
            # system_server registers that name and the switch stops it, so the
            # lookup blocks libbinder's full 5 s while CameraX gives up at 3 s and
            # the first open fails (Z Flip5 and S25 reports, both images; the HAL
            # opens afterwards, so a retry sometimes worked). One UI's wrapper
            # treats an absent name as camera allowed, so this is latency, not
            # policy: a binder under the name makes the lookup immediate.
            # patches/OneOSEdmStub.java answers every code with the single plain
            # int32 1 that One UI's own service replies with, so no transaction
            # number is assumed. uid system through app_process, like the angle
            # relay; it exits with the guest. Off unless ONEOS_GUEST_EDM_STUB=1:
            # answering wrongly would turn the camera OFF, so it is opt-in until a
            # phone whose camera fails today has tried it.
            if [ \"${ONEOS_GUEST_EDM_STUB:-0}\" = 1 ] && [ -f $STAGE/OneOSEdmStub.dex ] && [ ! -L $STAGE/OneOSEdmStub.dex ]; then
                (umask 027; CLASSPATH=$STAGE/OneOSEdmStub.dex $BB nohup $BB setuidgid system /system/bin/app_process /system/bin OneOSEdmStub \$PID > $STAGE/edm_stub.log 2>&1 </dev/null &)
                sleep 2
                echo \"[UI Activator] Knox edm stub: \$(head -n 1 $STAGE/edm_stub.log 2>/dev/null | tr -d '\n' || true); \$(timeout 10 service check edmnativehelper 2>&1 | tr -d '\n')\"
            fi
            # Density and fold line of the inner panel (run 43), before HOME so the
            # setup wizard starts with them. With no init of its own the guest
            # takes ro.sf.lcd_density from the property area it shares with One
            # UI: Samsung's 480, so the 2256 px inner panel was 752 dp wide
            # (sw752), under the 840 dp Pixel's setup wizard needs for its
            # two-pane layouts (w840dp-h900dp sucTwoPaneLayoutStyle), and text was
            # about 14% over size on this 421 ppi panel. That prop (and
            # ro.config.density_override) is One UI's, so the guest gets a forced
            # density instead, kept per panel in the stage (display_settings.xml,
            # settings_secure): auto = the largest multiple of 20 that keeps the
            # short side at 840 dp (2256 px: 420, 859x954 dp), only if that is at
            # least 90% of the panel's real dpi and under the base density. Set
            # only while display 0 is the inner panel (after a folded start it is
            # the cover: the next session sets it), and never over a size chosen
            # in the guest (display_density_forced set). The cover keeps 480,
            # except after a folded start of a later session: WindowManagerService
            # gives display 0 (then the cover) display_density_forced at boot,
            # until the first lid event applies each panel's own (the fold test
            # logs the density at each event).
            # ONEOS_GUEST_DENSITY=off|auto|<dpi>. Google Calculator stays as it
            # is in portrait (sw600dp layout, as on a real Pixel Fold); its wide
            # pad is landscape-only.
            # Fold line: Pixel's product overlay gives WM Extensions yogi's own
            # hinge, fold-[1038,0,1038,2152], which fails its full-height check
            # here (WindowLayoutComponentImpl, 7 times), so apps saw no
            # FoldingFeature. Settings.Global display_features comes first
            # (RawFoldingFeatureProducer): the inner panel's middle line in its
            # rotation-0 coordinates, fold-[1128,0,1128,2504], with -flat because
            # the guest's hinge state cannot be trusted yet (run 41's fold test:
            # HALF_OPENED 3 s after a flat unfold would give apps a tabletop
            # layout). ONEOS_GUEST_POSTURE=live leaves the posture to the hinge.
            # The cover's 1080x2520 windows fail the full-height check: no feature.
            # Not for ColorOS: its fold pages (Wallpapers grid overlay, compact
            # window mode) were tuned at the density it has, and none of this was
            # seen there.
            if [ \"\$(cat $STAGE/data/oneos_fold_mode 2>/dev/null)\" = layout ] && [ $GUEST_FOLD_FORM = 1 ] && [ $GUEST_OPLUS = 1 ]; then
                echo '[UI Activator] density and fold line: left to ColorOS'
            elif [ \"\$(cat $STAGE/data/oneos_fold_mode 2>/dev/null)\" = layout ] && [ $GUEST_FOLD_FORM = 1 ]; then
                IN=\$(cat $STAGE/data/oneos_inner_display 2>/dev/null)
                case \"\$IN\" in ''|*[!0-9]*) IN=none ;; esac
                # DisplayDeviceInfo{\"Built-in Screen\": uniqueId=\"local:<id>\", 2256 x 2504, ..., density 480, 421.34116 x 421.20264 dpi, ...}
                L=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys display 2>/dev/null | grep -m1 \"DisplayDeviceInfo.*uniqueId=.local:\$IN.,\")
                W=\$(echo \"\$L\" | sed -n 's/.*uniqueId=.local:[0-9]*., \([0-9]*\) x \([0-9]*\), .*/\1/p')
                H=\$(echo \"\$L\" | sed -n 's/.*uniqueId=.local:[0-9]*., \([0-9]*\) x \([0-9]*\), .*/\2/p')
                BD=\$(echo \"\$L\" | sed -n 's/.*, density \([0-9]*\), \([0-9]*\)[.0-9]* x [.0-9]* dpi.*/\1/p')
                XDPI=\$(echo \"\$L\" | sed -n 's/.*, density \([0-9]*\), \([0-9]*\)[.0-9]* x [.0-9]* dpi.*/\2/p')
                if [ -n \"\$W\" ] && [ -n \"\$H\" ] && [ -n \"\$BD\" ] && [ -n \"\$XDPI\" ]; then
                    if [ \$W -lt \$H ]; then S=\$W; else S=\$H; fi
                    D=$GUEST_DENSITY
                    [ \$D = auto ] && D=\$((S * 160 / 840 / 20 * 20))
                    CUR=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get secure display_density_forced 2>/dev/null)
                    if [ \$D = off ]; then
                        echo \"[UI Activator] density: left at base \$BD (ONEOS_GUEST_DENSITY=off)\"
                    elif [ -n \"\$CUR\" ] && [ \"\$CUR\" != null ]; then
                        echo \"[UI Activator] density: \$CUR kept (forced in the guest already; base \$BD)\"
                    elif [ $GUEST_DENSITY = auto ] && { [ \$((D * 10)) -lt \$((XDPI * 9)) ] || [ \$D -ge \$BD ]; }; then
                        echo \"[UI Activator] density: left at base \$BD (inner \${W}x\${H} at \$XDPI dpi too small for 840 dp: \$D)\"
                    elif ! $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/wm size -d 0 2>/dev/null | grep -q -x \"Physical size: \${W}x\${H}\"; then
                        echo \"[UI Activator] density: not set, display 0 is not the inner panel (started folded); the next session sets it\"
                    else
                        # The density first: with a leading -d, wm only prints it.
                        $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/wm density \$D -d 0 >/dev/null 2>&1
                        echo \"[UI Activator] density: \$D (inner \${W}x\${H}, xdpi \$XDPI, base \$BD, was unforced) -> \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/wm density -d 0 2>&1 | tr '\n' ' ')\"
                    fi
                    F=\"fold-[\$((W / 2)),0,\$((W / 2)),\$H]\"
                    [ $GUEST_POSTURE_LIVE = 1 ] || F=\"\$F-flat\"
                    CF=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get global display_features 2>/dev/null)
                    [ \"\$CF\" = \"\$F\" ] || $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put global display_features \"\$F\" 2>/dev/null
                    echo \"[UI Activator] fold line: display_features \$CF -> \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get global display_features 2>/dev/null)\"
                else
                    echo \"[UI Activator] density and fold line: inner panel \$IN not found in dumpsys display, left alone\"
                fi
            else
                # A bar phone or flip (ONEOS_GUEST_FORM=phone): One UI's dp scale
                # (host_display, from the switch). The guest runs the panel at its
                # full width; One UI's density x physical / One UI's width keeps One
                # UI's dp width there (S25 Ultra at FHD+: 450 x 1440 / 1080 = 600,
                # 384 dp, where the shared 450 gave 512 dp). On a phone One UI runs
                # at full width it is One UI's own density (Screen zoom included).
                # A density chosen in the guest stays: data/oneos_auto_density holds
                # the one OneOS set, a forced density that differs is the user's.
                HUD=\$(sed -n 's/^density=\([0-9]*\) .*/\1/p' $STAGE/host_display 2>/dev/null)
                HW=\$(sed -n 's/.* width=\([0-9]*\) .*/\1/p' $STAGE/host_display 2>/dev/null)
                HP=\$(sed -n 's/.* physical=\([0-9]*\)$/\1/p' $STAGE/host_display 2>/dev/null)
                GW=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/wm size -d 0 2>/dev/null | sed -n 's/^Physical size: \([0-9]*\)x[0-9]*$/\1/p' | head -n 1)
                case \"\$HUD:\$HW:\$HP:\$GW\" in
                    *[!0-9:]*|:*|*::*|*:)
                        echo \"[UI Activator] density: One UI's scale not recorded (\${HUD:-?} at \${HW:-?} of \${HP:-?} px, guest \${GW:-?} px), left at base\" ;;
                    *)
                        D=\$(( (HUD * GW + HW / 2) / HW ))
                        CUR=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get secure display_density_forced 2>/dev/null)
                        AUTO=\$(cat $STAGE/data/oneos_auto_density 2>/dev/null)
                        if [ \$GW != \$HP ]; then
                            echo \"[UI Activator] density: guest display 0 is \$GW px wide, One UI's panel \$HP px; left at base\"
                        elif [ -n \"\$CUR\" ] && [ \"\$CUR\" != null ] && [ \"\$CUR\" != \"\$AUTO\" ]; then
                            echo \"[UI Activator] density: \$CUR kept (chosen in the guest; One UI's scale gives \$D)\"
                        elif [ \$D -lt 120 ] || [ \$D -gt 640 ]; then
                            echo \"[UI Activator] density: \$D from One UI's scale is outside 120-640, left at base\"
                        elif [ -L $STAGE/data/oneos_auto_density ]; then
                            echo \"[UI Activator] density: data/oneos_auto_density is a link, not made by OneOS; left at base\"
                        else
                            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/wm density \$D -d 0 >/dev/null 2>&1
                            echo \$D > $STAGE/data/oneos_auto_density
                            echo \"[UI Activator] density: \$D (One UI \$HUD at \$HW of \$HP px, \$((HW * 160 / HUD)) dp; was \${CUR:-unforced}) -> \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/wm density -d 0 2>&1 | tr '\n' ' ')\"
                        fi ;;
                esac
            fi
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/input keyevent 224
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/input keyevent 82
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/am unlock-user 0
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/am start -a android.intent.action.MAIN -c android.intent.category.HOME
            # Setup is marked done before boot (guest_prepare.sh), so ColorOS shows
            # its swipe keyguard; there is no credential in the guest.
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/wm dismiss-keyguard 2>/dev/null || true
            # The guest's updaters could hand an OTA to the phone's own
            # update_engine: ColorOS's, Pixel's factory OTA and Infinity-X's
            # Updater.
            for p in com.oplus.ota com.google.android.factoryota com.infinity.updater; do
                $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/pm disable-user --user 0 \$p >/dev/null 2>&1 || true
            done
            # Cover panel. With the fold layout (guest_start.sh wrote
            # data/oneos_fold_mode) ColorOS's DisplayManager switches the panels
            # on the lid switch and keeps the cover off while unfolded: only log
            # what it chose. Without it the cover only mirrors the inner panel
            # and its touches go nowhere: switch it off. The inner panel is display 0.
            if [ \"\$(cat $STAGE/data/oneos_fold_mode 2>/dev/null)\" = layout ]; then
                echo \"[UI Activator] fold layout: \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd device_state print-state 2>&1 | head -1); \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys display 2>/dev/null | grep -m1 -o 'mCurrentLayout=.*' | cut -c1-300)\"
                # What folding does (Settings > Foldable features > Screen switching,
                # system continue_using_apps_when_folded): 0 = swipe up to continue,
                # ColorOS's default, 1 = continue using, 2 = turn screen off. With 0
                # the cover asks for a swipe and locks after 3 s, and cover touch is
                # dead (run 31: cover_touch_N.txt empty), so a fold ends on a locked
                # cover; the user switched to continue using by hand at 12:03. A
                # stage set to 2 keeps it. ONEOS_GUEST_FOLD_CONTINUE=0 leaves it alone.
                # AOSP (Pixel): system fold_lock_behavior_setting, stay_awake_on_fold_key
                # = continue using, selective_stay_awake_key = swipe up (set like
                # ColorOS's 0), sleep_on_fold_key kept like ColorOS's 2.
                if [ $GUEST_OPLUS = 1 ]; then FOLDN=continue_using_apps_when_folded; else FOLDN=fold_lock_behavior_setting; fi
                FOLDK=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get system \$FOLDN 2>/dev/null)
                case \"${ONEOS_GUEST_FOLD_CONTINUE:-1}:\$FOLDN:\$FOLDK\" in
                    0:*|1:continue_using_apps_when_folded:1|1:continue_using_apps_when_folded:2|1:fold_lock_behavior_setting:stay_awake_on_fold_key|1:fold_lock_behavior_setting:sleep_on_fold_key) ;;
                    1:continue_using_apps_when_folded:*) $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put system continue_using_apps_when_folded 1 2>/dev/null ;;
                    *) $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put system fold_lock_behavior_setting stay_awake_on_fold_key 2>/dev/null ;;
                esac
                echo \"[UI Activator] fold behaviour: \$FOLDN \$FOLDK -> \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get system \$FOLDN 2>/dev/null)\"
            else
                for id in \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys display 2>/dev/null | grep -o 'type=INTERNAL, valid=true, isActive=true, displayId=[0-9]*' | grep -o '[0-9]*\$' | sort -u); do
                    [ \"\$id\" = 0 ] && continue
                    $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd display disable-display \$id 2>/dev/null && echo \"[UI Activator] cover display \$id switched off\"
                done
            fi
            # HyperOS's home wallpaper (run 10: only the lock screen took a new
            # one). Until the first fold state commits, about 4 s after
            # MiWallpaper binds, the display mapper shows the cover as a second
            # display (#7); when it closes, MiWallpaper's EngineServiceManager
            # drops the home engines (1 and the cover's 4) with it, and every
            # later apply finds none (requireEngineService returns null).
            # Once display 0 is the only active built-in one, its process is
            # restarted once: WallpaperManagerService rebinds a wallpaper that
            # died (it reverts to the built-in one only after a second death
            # within 10 s, or a low-memory kill) and the engines register again.
            if [ $GUEST_MIUI = 1 ]; then
                n=0
                while [ \$n -lt 30 ]; do
                    $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys display 2>/dev/null |
                        grep -o 'type=INTERNAL, valid=true, isActive=true, displayId=[0-9]*' | grep -q -v 'displayId=0\$' || break
                    n=\$((n + 1)); sleep 1
                done
                WP=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/pidof com.miui.miwallpaper 2>/dev/null)
                case \"\$WP\" in
                    ''|*[!0-9]*) echo \"[UI Activator] MiWallpaper: not running (\${WP:-no pid}), left alone\" ;;
                    *)
                        kill \$WP 2>/dev/null
                        n=0; NWP=
                        while [ \$n -lt 15 ]; do
                            sleep 1; n=\$((n + 1))
                            NWP=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/pidof com.miui.miwallpaper 2>/dev/null)
                            [ -n \"\$NWP\" ] && [ \"\$NWP\" != \"\$WP\" ] && break
                        done
                        echo \"[UI Activator] MiWallpaper restarted once for its home engines: pid \$WP -> \${NWP:-none after 15 s}\"
                        ;;
                esac
            fi
            # Brightness below ColorOS's minimum level (a fresh stage has 102):
            # its default, about 135 nits with the Samsung panel curve.
            # ColorOS's scale only (AOSP's screen_brightness is 0..255).
            if [ $GUEST_OPLUS = 1 ]; then
            b=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get system screen_brightness 2>/dev/null)
            [ \"\${b%%.*}\" -ge 222 ] 2>/dev/null || $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put system screen_brightness 4570
            # Once with the fixed panel curve: the saved value was chosen while the
            # curve was wrong (run 28: 1702 looked like ~420 nits, is ~15).
            [ -f $STAGE/data/.oneos_curve2 ] || { $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings put system screen_brightness 4570; touch $STAGE/data/.oneos_curve2; }
            fi
            echo \"[UI Activator] refresh: min \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get system min_refresh_rate) peak \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get system peak_refresh_rate); brightness \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get system screen_brightness)\"
            echo '[UI Activator] Home activated!'
            # Google Dialer and Nearby devices (run 44): 50 SecurityExceptions
            # (DialerAudioModeProvider, getRemoteAlias: Need
            # android.permission.BLUETOOTH_CONNECT) in the first call, until the
            # owner allowed it in a dialog in the middle of that call. Granted
            # once per stage (a marker in the guest's data, like the blur
            # default), so a later choice in the guest stays. Not BLUETOOTH_SCAN:
            # nothing in run 44 asked for it. Pixel guests only; the guest's own
            # package manager, nothing of One UI's. After HOME: it does not hold
            # up the first screen, and no call comes that early. The marker is
            # made and checked like the blur one (mkdir, -e and -L).
            if [ $GUEST_OPLUS = 0 ]; then
                DST=''
                if [ -L $STAGE/data/oneos_dialer_bt ]; then
                    DST='data/oneos_dialer_bt is a link, not made by OneOS; nothing granted'
                elif [ -e $STAGE/data/oneos_dialer_bt ]; then
                    DST='granted on an earlier boot of this stage, left to the guest'
                elif ! timeout 20 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/pm path com.google.android.dialer >/dev/null 2>&1; then
                    DST='com.google.android.dialer not installed (or pm path did not answer in 20 s), nothing granted'
                elif DR=\$(timeout 20 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/pm grant --user 0 com.google.android.dialer android.permission.BLUETOOTH_CONNECT 2>&1); then
                    mkdir $STAGE/data/oneos_dialer_bt 2>/dev/null
                    DST='BLUETOOTH_CONNECT granted (once per stage)'
                else
                    DST=\"pm grant BLUETOOTH_CONNECT failed: \$(echo \"\$DR\" | tr '\n' ' ' | cut -c1-200)\"
                fi
                echo \"[UI Activator] dialer: \$DST; now \$(timeout 20 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys package com.google.android.dialer 2>/dev/null | grep -m 1 -o 'android.permission.BLUETOOTH_CONNECT: granted=[a-z]*' || echo 'BLUETOOTH_CONNECT state not read')\"
            fi
            # This phone's cutout, status bar height and corner radius in a guest
            # with AOSP's SystemUI: Pixel, and Infinity-X (the switch saved One UI's
            # in host_statusbar). Infinity-X got none of them before (GUEST_OPLUS):
            # on the S25 Ultra its cutout and corners were empty, the icons off.
            # Fabricated overlays are mutable: enabled, they come above every
            # static overlay, the image's device ones in product included. The
            # guest's DisplayManager takes the cutout and corners again on the
            # overlay change and SystemUI the height; later sessions start with
            # them. Re-made every session (a resolution change moves the height).
            # ONEOS_GUEST_HOST_CUTOUT=0 leaves them out.
            if [ $GUEST_AOSP_SYSUI = 1 ] && [ \"${ONEOS_GUEST_HOST_CUTOUT:-1}\" = 1 ] && [ -f $STAGE/host_statusbar ] && [ ! -L $STAGE/host_statusbar ]; then
                gxo() { timeout 20 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd overlay \"\$@\" >/dev/null 2>&1; }
                HCS=\$(sed -n 's/^spec=//p' $STAGE/host_statusbar | head -n 1)
                HSB=\$(sed -n 's/^height=//p' $STAGE/host_statusbar | head -n 1)
                HRC=\$(sed -n 's/^radius=//p' $STAGE/host_statusbar | head -n 1)
                OVS=''
                if [ -n \"\$HCS\" ] &&
                   gxo fabricate --target android --name OneOSCutout android:string/config_mainBuiltInDisplayCutout string \"\$HCS\" &&
                   gxo fabricate --target android --name OneOSCutoutRect android:string/config_mainBuiltInDisplayCutoutRectApproximation string \"\$HCS\"; then
                    OVS='OneOSCutout OneOSCutoutRect'
                fi
                case \"\$HSB\" in
                    ''|*[!0-9]*) ;;
                    *) for r in status_bar_height_default:OneOSStatusBarHeight status_bar_height_portrait:OneOSStatusBarHeightPortrait; do
                           gxo fabricate --target android --name \${r#*:} android:dimen/\${r%%:*} 0x05 \$((HSB * 256)) && OVS=\"\$OVS \${r#*:}\"
                       done ;;
                esac
                case \"\$HRC\" in
                    ''|*[!0-9]*) ;;
                    *) for r in rounded_corner_radius:OneOSCornerRadius rounded_corner_radius_top:OneOSCornerRadiusTop rounded_corner_radius_bottom:OneOSCornerRadiusBottom; do
                           gxo fabricate --target android --name \${r#*:} android:dimen/\${r%%:*} 0x05 \$((HRC * 256)) && OVS=\"\$OVS \${r#*:}\"
                       done ;;
                esac
                ON=''
                for o in \$OVS; do gxo enable --user 0 com.android.shell:\$o && ON=\"\$ON \$o\"; done
                echo \"[UI Activator] status bar: One UI's cutout '\${HCS:-none}', height \${HSB:-?} px, corner radius \${HRC:-?} px; overlays on:\${ON:- none}\"
            fi
            # Fold test (fold layout only). On every lid switch event record what
            # the guest did: device state, layout, both touch mappers and
            # backlights, a screenshot of display 0, and after folding 10 s of
            # raw touches from the cover touchscreen (pull-run-logs.sh takes
            # $STAGE/diag_*).
            # Cover touch IC. Run 31: folding lit the cover and the guest mapped
            # sec_touchscreen2 DIRECT, but the cover never reacted and getevent on
            # it stayed empty (diag_fold/cover_touch_*.txt). Samsung's touch ICs
            # only scan while One UI's sysinput HAL says their panel is on, and One
            # UI switched the cover IC off at its last unfold before the session
            # (run 30 all.log 10:13:06: set_fold_state,0 to both ICs, then TSP_SUB
            # enabled@1,0 and @1,1; the HAL writes /sys/class/sec/tspN/enabled,
            # display state 2 ON / 1 OFF, event 0 early / 1 late around the panel
            # power change). tsp2 is sec_touchscreen2, port 148, the cover. Nothing
            # in the guest talks to that HAL, so the monitor plays One UI's part
            # for the cover IC only: fold = set_fold_state,1, 2,0, wait for the
            # cover backlight, 2,1; unfold = set_fold_state,0, 1,0, 1,1. The inner
            # IC (tsp1) is never written, so it stays on for the whole session and
            # unfolding always gives touch back. ONEOS_COVER_TSP=0 leaves both ICs
            # alone (run 31 behaviour).
            # OneOS: and only on a foldable, never by chance: fold form, a flip
            # lid switch and a sec_touchscreen2 must all be there. On a bar phone
            # (S Ultra) the one touch IC is a single /sys/class/sec/tsp, which
            # the TSP1 match below would find.
            if [ \"\$(cat $STAGE/data/oneos_fold_mode 2>/dev/null)\" = layout ]; then
                FD=$STAGE/diag_fold; mkdir -p \$FD
                FLIP=''; TS2=''; TSP1=''; TSP2=''; TSPLOG=''
                for e in /sys/class/input/event*; do
                    case \"\$(cat \$e/device/name 2>/dev/null)\" in
                        flip) FLIP=/dev/input/\${e##*/} ;;
                        sec_touchscreen2) TS2=/dev/input/\${e##*/} ;;
                    esac
                done
                if [ \"${ONEOS_COVER_TSP:-1}\" = 1 ] && [ \"${ONEOS_GUEST_FORM:-fold}\" = fold ] && [ -n \"\$FLIP\" ] && [ -n \"\$TS2\" ]; then
                    for d in /sys/class/sec/tsp*; do
                        [ \"\$(cat \$d/input/name 2>/dev/null)\" = sec_touchscreen2 ] && [ -w \$d/enabled ] && TSP2=\$d
                        [ \"\$(cat \$d/input/name 2>/dev/null)\" = sec_touchscreen ] && [ -w \$d/enabled ] && TSP1=\$d
                    done
                fi
                # The inner IC is only ever switched ON, and only when One UI left
                # it off: a session started folded (One UI powers the inner IC
                # down while folded; seen on the phone before run 32: tsp1
                # enabled 0, tsp2 1) would otherwise keep inner touch dead after
                # unfolding. Same sequence One UI uses when the inner panel comes on.
                inner_tsp_on() {
                    [ -n \"\$TSP1\" ] && [ \"\$(cat \$TSP1/enabled 2>/dev/null)\" = 0 ] || return 0
                    grep -q -w set_fold_state \$TSP1/cmd_list 2>/dev/null && echo set_fold_state,0 > \$TSP1/cmd
                    echo 2,0 > \$TSP1/enabled
                    i=0; while [ \$i -lt 15 ] && [ \"\$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null)\" = 0 ]; do sleep 0.2; i=\$((i + 1)); done
                    echo 2,1 > \$TSP1/enabled
                    echo \"inner touch IC \$TSP1 switched on: enabled \$(cat \$TSP1/enabled 2>&1)\"
                }
                # 1 = folded, 0 = unfolded. Writes the cover IC's own enabled and
                # cmd nodes (and the inner IC's only to switch it on, above); the
                # backlights are only read.
                cover_tsp() {
                    [ -n \"\$TSP2\" ] || return 0
                    if [ \"\$1\" = 1 ]; then
                        grep -q -w set_fold_state \$TSP2/cmd_list 2>/dev/null && echo set_fold_state,1 > \$TSP2/cmd
                        echo 2,0 > \$TSP2/enabled
                        i=0; while [ \$i -lt 15 ] && [ \"\$(cat /sys/class/backlight/panel1-backlight/brightness 2>/dev/null)\" = 0 ]; do sleep 0.2; i=\$((i + 1)); done
                        echo 2,1 > \$TSP2/enabled
                    else
                        grep -q -w set_fold_state \$TSP2/cmd_list 2>/dev/null && echo set_fold_state,0 > \$TSP2/cmd
                        echo 1,0 > \$TSP2/enabled; echo 1,1 > \$TSP2/enabled
                        inner_tsp_on
                    fi
                    echo \"cover touch IC \$TSP2 set for folded=\$1: enabled \$(cat \$TSP2/enabled 2>&1), cmd \$(cat \$TSP2/cmd_result 2>&1)\"
                }
                echo \"[UI Activator] fold test: lid switch \${FLIP:-not found}, cover touch \${TS2:-not found}, cover touch IC \${TSP2:-not used}\"
                # Started folded (device state 0 = CLOSE): no lid event will come.
                if [ \"\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd device_state print-state 2>/dev/null | head -1)\" = 0 ]; then
                    echo \"[UI Activator] \$(cover_tsp 1 2>&1)\"
                else
                    echo \"[UI Activator] \$(inner_tsp_on 2>&1)\"
                fi
                [ -n \"\$FLIP\" ] && ( n=0; getevent -lq \$FLIP 2>/dev/null | while read typ code val rest; do
                    [ \"\$code\" = SW_LID ] || continue
                    n=\$((n + 1)); ts=\$(date +%T)
                    case \"\$val\" in
                        00000001) TSPLOG=\$(cover_tsp 1 2>&1) ;;
                        00000000) TSPLOG=\$(cover_tsp 0 2>&1) ;;
                    esac
                    # Sampled in the background. Inline (run 31) the 3 s wait and the
                    # 10 s cover touch capture held the next lid event in the pipe: a
                    # fold undone within a second (event 7, the cover shows for about
                    # 1 s in the recording) was logged as folded in state 3 and its
                    # unfold never made the log. Each block is written in one go so
                    # overlapping samples do not interleave.
                    ( sleep 3
                      { echo \"== \$ts event \$n: SW_LID \$val (00000001 = folded), sampled \$(date +%T)\"
                        $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd device_state print-state 2>&1
                        $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys device_state 2>/dev/null | grep -E 'mCommittedState|mPendingState|mBaseState|mOverrideState' | head -4
                        # Run 44: the hinge reading behind HALF_OPENED (the fold
                        # line stays -flat until an unfold settles in OPENED) and the
                        # density each panel got (inner 420, cover 480 expected).
                        $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys device_state 2>/dev/null | grep -A2 mLastHingeAngleSensorEvent
                        echo \"density: \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/wm density -d 0 2>&1 | tr '\n' ' ')\"
                        $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys power 2>/dev/null | grep -m1 -E 'mWakefulness='
                        $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys display 2>/dev/null | grep -m1 -o 'mCurrentLayout=.*' | cut -c1-400
                        $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys input 2>/dev/null | grep -E '^  Device [0-9]+: sec_touchscreen|Touch Input Mapper \\(mode'
                        for b in panel0 panel1; do echo \"\$b-backlight \$(cat /sys/class/backlight/\$b-backlight/brightness 2>/dev/null)\"; done
                        [ -n \"\$TSP2\" ] && echo \"\$TSPLOG; after 3 s enabled \$(cat \$TSP2/enabled 2>&1), inhibited \$(cat \$TSP2/input/inhibited 2>&1)\"
                        # What the touch driver made of it (refused while it thinks
                        # the phone is open, already on, failed to power up).
                        [ -n \"\$TSP2\" ] && dmesg 2>/dev/null | grep -i -E 'sec_input|enabled|fold' | tail -n 20
                      } > \$FD/.event_\$n 2>&1
                      cat \$FD/.event_\$n >> \$FD/fold_test.log; rm -f \$FD/.event_\$n
                      $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/screencap -p /data/local/tmp/fold_\$n.png 2>/dev/null
                      cp $STAGE/data/local/tmp/fold_\$n.png \$FD/ 2>/dev/null
                      [ \"\$val\" = 00000001 ] && [ -n \"\$TS2\" ] && timeout 10 getevent -lt \$TS2 > \$FD/cover_touch_\$n.txt 2>&1
                      # Unfolded: the state again about 10 s on, to see whether a
                      # HALF_OPENED settles in OPENED (2) (run 44).
                      if [ \"\$val\" = 00000000 ]; then
                          sleep 7
                          { echo \"== \$ts event \$n: unfolded, sampled again \$(date +%T)\"
                            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd device_state print-state 2>&1
                            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys device_state 2>/dev/null | grep -E 'mCommittedState|mBaseState' | head -2
                            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys device_state 2>/dev/null | grep -A2 mLastHingeAngleSensorEvent
                          } > \$FD/.event_\${n}b 2>&1
                          cat \$FD/.event_\${n}b >> \$FD/fold_test.log; rm -f \$FD/.event_\${n}b
                      fi
                    ) &
                done ) </dev/null >/dev/null 2>&1 &
            fi
            # Wallpapers page probe. Run 31: on Home screen, Lock screen & style
            # the My theme header (dark card, All Flux themes) filled the first
            # screen, about 2400 px tall where its layout and the fragment ask for
            # 386dp = 984 px; the RRO card row below it was fine. Once that page is
            # the top app (oom_score_adj 0), save its view tree with frames
            # and a screenshot to diag_pages. Read-only, two captures at most,
            # polling a /proc file only; ONEOS_WALLPAPER_PROBE=0 skips it. Run 32:
            # dumpsys activity top 4 s later caught Settings Font instead (the user
            # had moved on), so dump every com.oplus.wallpapers activity, stopped
            # ones included, 2 s after it comes to the front.
            if [ '${ONEOS_WALLPAPER_PROBE:-1}' = 1 ]; then
                ( WD=$STAGE/diag_pages; mkdir -p \$WD; n=0; i=0; last=''
                  while [ \$n -lt 2 ] && [ \$i -lt 400 ]; do
                      i=\$((i + 1)); sleep 3
                      wp=\$(pidof com.oplus.wallpapers | awk '{print \$1}')
                      [ -n \"\$wp\" ] && [ \"\$wp\" != \"\$last\" ] || continue
                      [ \"\$(cat /proc/\$wp/oom_score_adj 2>/dev/null)\" = 0 ] || continue
                      sleep 2
                      n=\$((n + 1)); last=\$wp
                      timeout 20 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys activity activity com.oplus.wallpapers > \$WD/wallpapers_top_\$n.txt 2>&1
                      timeout 15 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/screencap -p /data/local/tmp/wallpapers_\$n.png 2>/dev/null
                      cp $STAGE/data/local/tmp/wallpapers_\$n.png \$WD/ 2>/dev/null
                  done ) </dev/null >/dev/null 2>&1 &
            fi
            # SIM attach APN (run 42). Each SIM's slot, the guest's sub id and the
            # preferred APN its telephony provider resolves (guest_prepare.sh
            # seeded One UI's for sub = slot + 1). Pixel guest, in the background.
            if [ $GUEST_OPLUS = 0 ]; then
                ( sleep 15
                  $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/content query --uri content://telephony/siminfo --projection _id:sim_id --where 'sim_id>=0' 2>/dev/null | grep '^Row: ' | while IFS= read -r row; do
                      sub=\$(echo \"\$row\" | sed -n 's/^Row: [0-9]* _id=\([0-9]*\),.*/\1/p')
                      slot=\$(echo \"\$row\" | sed -n 's/.* sim_id=\([0-9]*\).*/\1/p')
                      [ -n \"\$sub\" ] || continue
                      p=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/content query --uri content://telephony/carriers/preferapn/subId/\$sub --projection _id:name:apn 2>/dev/null | grep -m 1 '^Row: ' | sed 's/^Row: [0-9]* //')
                      echo \"[UI Activator] SIM slot \${slot:-?}: sub \$sub, preferred APN \${p:-none}\"
                  done ) </dev/null &
                # Comfort View (run 43: its switch did nothing; services.jar now
                # turns it into a color matrix, OneOSComfortView level 175): its
                # settings, SurfaceFlinger's color matrix, the overlay that decides
                # config_cv_available and the bridge's log, 60 s after Home, in
                # diag_display. Read only.
                ( sleep 60; WD=$STAGE/diag_display; mkdir -p \$WD
                  for k in cv_enabled cv_preferred_intensity cv_dynamic_enabled; do echo \"\$k=\$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get system \$k 2>&1)\"; done > \$WD/cv.txt
                  timeout 20 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys SurfaceFlinger 2>&1 | grep -i -E -A6 'color ?matrix|colortransform' > \$WD/sf_color.txt
                  timeout 15 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd overlay lookup android android:bool/config_cv_available > \$WD/cv_overlay.txt 2>&1
                  timeout 10 logcat -d -s OneOSComfortView DisplayTransformManager 2>/dev/null | tail -n 20 > \$WD/cv_log.txt ) </dev/null >/dev/null 2>&1 &
            fi
            echo '[UI Activator] Creating missing app data dirs...'
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/sh /data/local/tmp/fix_app_dirs.sh 2>/dev/null || true

            # Galaxy Z Fold8, Find N6 set: AOD, widgets, taskbar and the hinge relay in the guest.
            if [ \"${ONEOS_PROFILE:-}\" = f8 ] && grep -q coloros17-findn6 \"$STAGE/.oneos_stage\" && [ -f \"$STAGE/data/oneos_fold8/runtime.sh\" ]; then
                $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/sh /data/oneos_fold8/runtime.sh runtime >\"$STAGE/fold8_runtime.log\" 2>&1 || echo '[UI Activator] Fold8 runtime setup failed; see fold8_runtime.log'
            fi

            # Pixel Fold8 / Fold8 Ultra: start the system-UID sensor reader in the guest namespace
            # (fold8_pixel.sh prepare made runtime.sh only for those two sets).
            if { [ \"${ONEOS_PROFILE:-}\" = f8 ] || [ \"${ONEOS_PROFILE:-}\" = f8u ]; } && grep -q '\"set\": \"pixel-f8u\\{0,1\\}\",' \"$STAGE/.oneos_stage\" && [ -f \"$STAGE/data/oneos_pixel_hinge/runtime.sh\" ]; then
                $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/sh /data/oneos_pixel_hinge/runtime.sh runtime >\"$STAGE/pixel_hinge_runtime.log\" 2>&1 || echo '[UI Activator] Pixel hinge relay unavailable; native sensor fallback active'
            fi

            # Populate network permissions for all installed packages
            for uid in \$($BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/pm list packages -U 2>/dev/null | grep -o 'uid:[0-9]*' | cut -d: -f2 | sort -u); do
                [ -n \"\$uid\" ] || continue
                b0=\$(printf \"%02x\" \$((uid & 0xff)))
                b1=\$(printf \"%02x\" \$(((uid >> 8) & 0xff)))
                b2=\$(printf \"%02x\" \$(((uid >> 16) & 0xff)))
                b3=\$(printf \"%02x\" \$(((uid >> 24) & 0xff)))
                bpftool map update pinned /sys/fs/bpf/netd_shared/map_netd_uid_permission_map key hex \$b0 \$b1 \$b2 \$b3 value hex 0c 2>/dev/null || true
            done

            # Ensure default routing
            DEF_IF=\$(ip route | grep -o 'dev [^ ]*' | head -n 1 | awk '{print \$2}')
            [ -n \"\$DEF_IF\" ] && ip route add default dev \"\$DEF_IF\" 2>/dev/null || true

            # Mount emulated primary storage
            $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/sm mount \"emulated;0\" 2>/dev/null || true
            # Wifi: ColorOS boots scan-only (wifi_on=0) and One UI's supplicant
            # has exited. Turning Wi-Fi on makes the guest ask servicemanager for
            # the supplicant, so the host init starts Samsung's. wifi_on then
            # persists in the staged /data.
            if [ \"\$(cat $STAGE/host_wifi_on 2>/dev/null)\" = 1 ]; then
                (
                    $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd wifi set-wifi-enabled enabled 2>&1 | head -2
                    n=0
                    while [ \$n -lt 15 ]; do
                        service check android.hardware.wifi.supplicant.ISupplicant/default 2>/dev/null | grep -q ': found' && break
                        n=\$((n + 1)); sleep 1
                    done
                    SVC=\$(cat $STAGE/host_supplicant_svc 2>/dev/null)
                    if [ \$n -ge 15 ] && [ -n \"\$SVC\" ]; then
                        echo \"[UI Activator] wifi: supplicant not started on request, ctl.start \$SVC\"
                        setprop ctl.start \$SVC
                    fi
                    echo \"[UI Activator] wifi: supplicant \$(service check android.hardware.wifi.supplicant.ISupplicant/default 2>/dev/null | cut -d: -f2) after \${n}s\"
                    # Run 42 (Pixel): scans ran, no network was joined and the
                    # Internet page looked empty. 45 s after Wi-Fi came on, the
                    # guest's own status, scan results, saved networks and scanner
                    # state in diag_wifi (network names only there, never in this
                    # log). In the background. None of it needs verbose logging (set
                    # above; run 43: switching it on here gave the debug text).
                    if [ $GUEST_OPLUS = 0 ]; then
                        rm -rf $STAGE/diag_wifi
                        ( sleep 45; mkdir -p $STAGE/diag_wifi
                          for c in status list-scan-results list-networks is-verbose-logging; do echo \"== cmd wifi \$c\"; timeout 15 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd wifi \$c 2>&1; done > $STAGE/diag_wifi/wifi.txt
                          { echo '== dumpsys wifi (verbose)'; timeout 20 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys wifi 2>&1 | grep -m2 -i verbose; } >> $STAGE/diag_wifi/wifi.txt
                          timeout 20 $BB nsenter -t \$PID -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys wifiscanner > $STAGE/diag_wifi/wifiscanner.txt 2>&1 ) </dev/null >/dev/null 2>&1 &
                        echo '[UI Activator] wifi: status, scan results and saved networks to diag_wifi in 45 s'
                    fi
                )
            fi
            break
        fi
    fi
done
" </dev/null >/data/local/tmp/ui_activator.log 2>&1 &

# Session sampler (run 44: nothing was recorded after the 90 s round; window
# blur went off and on with the guest's thermal status, not the setting, while
# One UI's last CPU cap stayed). Every 30 s until the return, one line in
# $STAGE/diag_series.txt: time, the guest's thermal status and skin
# temperature (its thermal service on the shared HAL), each cpufreq policy's
# scaling_max_freq/cpuinfo_max_freq, WindowManager's mBlurEnabled,
# disable_window_blurs, battery level and status. Read only, each guest call
# with a timeout; until the guest's system_server runs only the kernel's
# values. It stops once return_to_oneui.sh has started (data/oneos_rec_stop,
# its first step; its pkill of system_server matches this command line too)
# or the guest's namespace record is gone. Out of the app cgroup, like the
# watcher, so it outlives the app that started the switch. Also, in
# $STAGE/cpu_top.log (collected with the stage's logs), the six busiest
# processes over one second and the CPU totals (HyperOS run 11: 42-44 C skin
# all session and nothing said which process kept the CPU busy).
$BB sh -c "
    echo \$\$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
    F=$STAGE/diag_series.txt
    T=$STAGE/cpu_top.log
    echo \"# \$(date) OneOS session sampler: every 30 s, CPU totals and the six busiest processes over 1 s (%CPU of one core)\" > \$T
    echo \"# \$(date) OneOS session sampler, one line every 30 s: time, thermal status, skin C, policyN=scaling_max_freq/cpuinfo_max_freq kHz, mBlurEnabled, disable_window_blurs, battery %,status\" > \$F
    while true; do
        [ -f $STAGE/data/oneos_rec_stop ] && { echo \"# \$(date +%T) the return started: sampler stopped\" >> \$F; exit 0; }
        [ -s $STAGE/guest_mntns ] || { echo \"# \$(date +%T) no guest namespace record: sampler stopped\" >> \$F; exit 0; }
        t0=\$(date +%s)
        P=\$(pidof system_server | awk '{print \$1}')
        st=''; sk=''; bl=''; dw=''
        if [ -n \"\$P\" ]; then
            TH=\$(timeout 10 $BB nsenter -t \$P -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys thermalservice 2>/dev/null)
            st=\$(echo \"\$TH\" | sed -n 's/^Thermal Status: *\([0-9][0-9]*\).*/\1/p' | head -n 1)
            sk=\$(echo \"\$TH\" | sed -n '/^Current temperatures from HAL/,/^[^[:space:]]/p' | sed -n 's/.*mValue=\([-0-9.]*\), mType=[0-9]*, mName=SKIN,.*/\1/p' | head -n 1)
            bl=\$(timeout 10 $BB nsenter -t \$P -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys window windows 2>/dev/null | grep -m 1 -o 'mBlurEnabled=[a-z]*' | sed 's/.*=//')
            dw=\$(timeout 10 $BB nsenter -t \$P -m /system/bin/sh /data/oneos_genv.sh /system/bin/settings get global disable_window_blurs 2>/dev/null)
        fi
        c=''
        for p in /sys/devices/system/cpu/cpufreq/policy*; do
            [ -r \$p/scaling_max_freq ] && c=\"\$c \${p##*/}=\$(cat \$p/scaling_max_freq 2>/dev/null)/\$(cat \$p/cpuinfo_max_freq 2>/dev/null)\"
        done
        bc=\$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
        bs=\$(cat /sys/class/power_supply/battery/status 2>/dev/null | tr ' ' _)
        echo \"\$(date +%T) thermal=\${st:--} skin=\${sk:--}\$c blur=\${bl:--} disable_window_blurs=\${dw:--} battery=\${bc:-?}%,\${bs:-?}\" >> \$F
        TOP=\$(timeout 10 top -b -n 1 -d 1 -m 6 -s 1 -o %CPU,PID,NAME 2>/dev/null)
        echo \"\$(date +%T) \$(echo \"\$TOP\" | grep -m 1 'cpu ' | tr -s ' ') |\$(echo \"\$TOP\" | awk '\$1 ~ /^[0-9.]+\$/ && \$2 ~ /^[0-9]+\$/ { printf \" %s %s\", \$1, \$3 }')\" >> \$T
        s=\$((t0 + 30 - \$(date +%s))); [ \$s -gt 0 ] || s=1
        sleep \$s
    done
" </dev/null >/dev/null 2>&1 &
echo "Session sampler: every 30 s to $STAGE/diag_series.txt"

# Heat cap (S25 Ultra af6c2b17; owner 2026-10-27: cap only when hot). One UI's
# heat control (SSRM) stops with One UI's system_server, and nothing in the
# guest caps the CPU: that session ran both clusters at full clock up to 54 C
# skin. Every 10 s the guest's SKIN temperature (its thermal service on the
# shared HAL, read as the sampler reads it) sets a level: from 45 C (Samsung's
# SEVERE) every cpufreq policy's scaling_max_freq is 80% of its
# cpuinfo_max_freq, from 47 C 65%, from 50 C 50%; a level ends 2 C under where
# it began. The first reading under 45 C lifts a cap One UI left (run 45: half
# clock for a whole session); after that the policies are written only when the
# level changes, each change logged in $STAGE/heat_cap.log. Only scaling_max_freq
# (the sysfs request) is written: the kernel's own thermal limits stay. It stops
# with the return (data/oneos_rec_stop) or when the guest's namespace record is
# gone, giving the policies their full clock back if it had capped them;
# return_to_oneui.sh stops it as well and does the same (heat_cap.active), for
# One UI's SSRM to set its own. ONEOS_HEAT_CAP=0 (Advanced: Cool down when hot
# off): not started. Out of the app cgroup, like the sampler.
rm -f "$STAGE/heat_cap.active"
if [ "${ONEOS_HEAT_CAP:-1}" = 1 ]; then
    : > "$STAGE/heat_cap.active"
    $BB sh -c "
    : oneos_heat_cap
    echo \$\$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
    F=$STAGE/heat_cap.log
    echo \"# \$(date) OneOS heat cap: from 45, 47, 50 C skin every CPU policy at 80, 65, 50% of its top clock (2 C hysteresis)\" > \$F
    full() {
        c=''
        for p in /sys/devices/system/cpu/cpufreq/policy*; do
            hw=\$(cat \$p/cpuinfo_max_freq 2>/dev/null)
            case \"\$hw\" in ''|*[!0-9]*) continue ;; esac
            echo \$hw > \$p/scaling_max_freq 2>/dev/null
            c=\"\$c \${p##*/}=\$(cat \$p/scaling_max_freq 2>/dev/null)/\$hw\"
        done
        echo \"\$(date +%T) \$1: full clock:\$c\" >> \$F
    }
    lvl=0; first=1
    while true; do
        if [ -f $STAGE/data/oneos_rec_stop ] || [ ! -s $STAGE/guest_mntns ]; then
            [ \$lvl = 0 ] || full stopped
            echo \"# \$(date +%T) stopped (the return started, or no guest namespace record)\" >> \$F
            exit 0
        fi
        P=\$(pidof system_server | awk '{print \$1}')
        sk=''
        [ -n \"\$P\" ] && sk=\$(timeout 10 $BB nsenter -t \$P -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys thermalservice 2>/dev/null | sed -n '/^Current temperatures from HAL/,/^[^[:space:]]/p' | sed -n 's/.*mValue=\([-0-9.]*\), mType=[0-9]*, mName=SKIN,.*/\1/p' | head -n 1)
        if [ -n \"\$sk\" ]; then
            new=\$(awk -v s=\"\$sk\" -v l=\$lvl 'BEGIN { t[1] = 45; t[2] = 47; t[3] = 50; while (l < 3 && s >= t[l + 1]) l++; while (l > 0 && s < t[l] - 2) l--; print l }')
            if [ \"\$new\" = 0 ] && [ \$first = 1 ]; then
                capped=''
                for p in /sys/devices/system/cpu/cpufreq/policy*; do
                    [ \"\$(cat \$p/scaling_max_freq 2>/dev/null)\" = \"\$(cat \$p/cpuinfo_max_freq 2>/dev/null)\" ] || capped=1
                done
                if [ -n \"\$capped\" ]; then full \"skin \$sk C, a cap from before the switch lifted\"
                else echo \"\$(date +%T) skin \$sk C: no cap\" >> \$F; fi
            elif [ \"\$new\" = 0 ] && [ \$lvl != 0 ]; then
                full \"skin \$sk C, level \$lvl to 0\"
            elif [ \"\$new\" != 0 ] && [ \"\$new\" != \$lvl ]; then
                case \$new in 1) pct=80 ;; 2) pct=65 ;; *) pct=50 ;; esac
                c=''
                for p in /sys/devices/system/cpu/cpufreq/policy*; do
                    hw=\$(cat \$p/cpuinfo_max_freq 2>/dev/null)
                    case \"\$hw\" in ''|*[!0-9]*) continue ;; esac
                    echo \$((hw / 100 * pct)) > \$p/scaling_max_freq 2>/dev/null
                    c=\"\$c \${p##*/}=\$(cat \$p/scaling_max_freq 2>/dev/null)/\$hw\"
                done
                echo \"\$(date +%T) skin \$sk C, level \$lvl to \$new: \$pct%:\$c\" >> \$F
            fi
            lvl=\$new; first=0
        fi
        sleep 10
    done
" </dev/null >/dev/null 2>&1 &
    echo "Heat cap: on (from 45 C skin; every 10 s to $STAGE/heat_cap.log)"
else
    echo "Heat cap: off (ONEOS_HEAT_CAP=0, Cool down when hot off in Advanced)"
fi

# OneOS dead-man switch. If the guest is not booting, put One UI back by itself:
# a stuck guest otherwise leaves a black screen and no network (so no remote
# adb either) until a forced reboot, which also drops temp root.
#   - black screen (guest surfaceflinger or bootanimation gone): after
#     ONEOS_RETURN_BLACK seconds (150)
#   - boot animation still running: it is loading, wait up to
#     ONEOS_RETURN_MAX seconds (600)
#   - guest home screen reached (UI activator): never
# The host's surfaceflinger/bootanimation were killed above, so these names
# are the guest's. Props are shared with the host, whose sys.boot_completed is
# already 1, which is why the UI activator is the boot signal.
# ONEOS_RETURN_MAX=0 disables it.
RETURN_BLACK="${ONEOS_RETURN_BLACK:-150}"
RETURN_MAX="${ONEOS_RETURN_MAX:-600}"
# ONEOS_SESSION_MAX (seconds, multiple of 10): end every session after this
# long, even one that reached the home screen, after a last round of
# diagnostics (diag_final). For unattended test runs: the guest has no
# network of its own yet, so the remote side cannot see a running session.
SESSION_MAX="${ONEOS_SESSION_MAX:-0}"
if [ "$RETURN_MAX" -gt 0 ]; then
    # OneOS: the watcher is the way back to One UI, so it must outlive the
    # app that started the switch: out of the app cgroup (killed with the
    # app) and never chosen by the OOM killer. Inherited by return_to_oneui.sh.
    $BB sh -c "
        echo \$\$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
        echo -1000 > /proc/\$\$/oom_score_adj 2>/dev/null
        t=0; total=0; dead=0; sfgone=0; prev_failed=0
        while [ \$t -lt $RETURN_MAX ]; do
            # The 10 s wait ends early on a request. Run 34: Volume Up + Volume
            # Down were held 3 s from 16:43:56, but the request was handled only
            # at 16:44:06 (the rest of this wait, then the diagnostics and the
            # logcat count below). Seeing nothing happen, the user held the
            # keys again, and that second hold turned TalkBack on in ColorOS.
            # Back to One UI in the guest's OneOS app (its screen or its Quick
            # Settings tile) is the request file in that app's data folder,
            # checked every second here: taken once (deleted) and turned into
            # the same request as the keys, app:app or app:tile. Only a plain
            # file is read, 16 bytes at most; nothing in it but the reason is used.
            i=0
            while [ \$i -lt 10 ] && [ -z \"\$(getprop oneos.guest.powerctl)\" ]; do
                if [ -f $GUEST_RETURN_REQ ] && [ ! -L $GUEST_RETURN_REQ ]; then
                    case \"\$(timeout 2 head -c 16 $GUEST_RETURN_REQ 2>/dev/null)\" in tile*) r=tile ;; *) r=app ;; esac
                    rm -f $GUEST_RETURN_REQ
                    echo \"\$(date) Back to One UI asked in the guest's OneOS app (\$r)\"
                    setprop oneos.guest.powerctl \"app:\$r\"
                    continue
                fi
                sleep 1; i=\$((i + 1))
            done
            t=\$((t + 10)); total=\$((total + 10))
            # A guest reboot/shutdown request (recorded by the guarded ShutdownThread
            # / PowerManagerService), the return keys or the guest's OneOS app end
            # the session from the host side, before the slow checks below.
            req=\$(getprop oneos.guest.powerctl)
            if [ -n \"\$req\" ]; then
                echo \"\$(date) guest requested '\$req' after \${t}s, returning to One UI\"
                # Who asked: the guarded ShutdownThread logs under the tag OneOS (run
                # 31 was Restart in ColorOS's power menu, seen only in the recording).
                timeout 5 logcat -d -b main,system -t 4000 2>/dev/null | grep -E ' OneOS|ShutdownThread|GlobalActions|RescueParty|PowerManagerService.*[Rr]eboot' | tail -15
                exec /system/bin/sh $STAGE/return_to_oneui.sh
            fi
            # Reaching the home screen only lifts the black-screen and time
            # limits; a dead guest still has to come back to One UI (the watcher
            # used to exit here and nothing returned after a later crash).
            home=0; grep -q 'Home activated' /data/local/tmp/ui_activator.log 2>/dev/null && home=1
            # Display diagnostics from inside the guest (its own screencap and
            # dumpsys talk to its own surfaceflinger), kept in the stage dir.
            dname=''
            case \$total in 20|40|90) dname=\$total ;; esac
            [ $SESSION_MAX -gt 0 ] && [ \$total -eq $((SESSION_MAX - 20)) ] && dname=final
            # Keep the boot (run 44): once the capture is full its rotation
            # drops the oldest files first, One UI's history, the switch and the
            # guest's boot. In the 90 s round the newest six files (all of the
            # boot at run 44's rates, 192 MiB at most) get a second name in
            # $LOGS/head: hard links, no copy, and no space used until the
            # rotation deletes their first name. This session's capture only.
            if [ \"\$dname\" = 90 ] && [ $LOGCAT_HEAD = 1 ]; then
                rm -rf $LOGS/head && mkdir -p $LOGS/head
                for f in $LOGS/boot.log $LOGS/boot.log.0[1-5]; do
                    [ -f \$f ] && $BB ln -f \$f $LOGS/head/ 2>/dev/null
                done
                echo \"\$(date) logcat capture: \$(ls $LOGS/head 2>/dev/null | wc -l) files of the boot kept in $LOGS/head (hard links)\"
            fi
            if [ -n \"\$dname\" ]; then
                SFP=\$(pidof surfaceflinger | awk '{print \$1}')
                if [ -n \"\$SFP\" ]; then
                    D=$STAGE/diag_\$dname; mkdir -p \$D
                    # Who has the vold names now: One UI's vold keeps vold and
                    # android.system.vold.IVold/default, the guest's is gvld (run 44).
                    { for n in vold android.system.vold.IVold/default gvld; do echo \"\$n: \$(timeout 5 dumpsys --pid \$n 2>&1 | head -n 1)\"; done
                      echo \"init.svc_debug_pid.vold: \$(getprop init.svc_debug_pid.vold)\"; } > \$D/vold_names.txt
                    timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys SurfaceFlinger > \$D/surfaceflinger.txt 2>&1
                    timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys display > \$D/display.txt 2>&1
                    for id in \$(grep -o 'Display [0-9]\\{6,\\}' \$D/surfaceflinger.txt | awk '{print \$2}' | sort -u); do
                        timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/screencap -d \$id -p /data/local/tmp/shot_\$id.png 2>>\$D/screencap.err
                        cp $STAGE/data/local/tmp/shot_\$id.png \$D/ 2>/dev/null
                    done
                    for b in /sys/class/backlight/panel0-backlight /sys/class/backlight/panel1-backlight /sys/class/backlight/panel /sys/class/backlight/panel1; do [ -d \$b ] || continue; echo \"\$b: \$(cat \$b/brightness) actual=\$(cat \$b/actual_brightness) max=\$(cat \$b/max_brightness)\"; done > \$D/backlight.txt 2>&1
                    tail -5 $STAGE/data/backlight.log >> \$D/backlight.txt 2>/dev/null
                    timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys power > \$D/power.txt 2>&1
                    timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys device_state > \$D/device_state.txt 2>&1
                    timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys oplus_vrr_service > \$D/vrr.txt 2>&1
                    for s in media.audio_flinger media.audio_policy; do timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys \$s > \$D/dumpsys_\$s.txt 2>&1; done
                    # Bluetooth (run 43: A2DP and HFP went to a made-up identity
                    # address): active devices, bond states and identity addresses.
                    timeout 20 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys bluetooth_manager > \$D/bluetooth_manager.txt 2>&1
                    cp $STAGE/data/audio_keeper.log $STAGE/data/call_audio.log $STAGE/data/oneos_a2dp.log $STAGE/data/hyos_spawner.log \$D/ 2>/dev/null
                    timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys SurfaceFlinger --list > \$D/layers.txt 2>&1
                    # Does each SurfaceFlinger -> composer transaction arrive at all?
                    for f in failed_transaction_log transaction_log stats; do timeout 5 cat /dev/binderfs/binder_logs/\$f > \$D/binder_\$f.txt 2>&1; done
                    # Heat (run 43: thermal status CRITICAL with 46-51 C skin during
                    # the first boot's dexopt): the guest's thermal service on the
                    # shared HAL, and the clocks the host kernel allows, read only.
                    timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys thermalservice > \$D/thermal.txt 2>&1
                    { for p in /sys/devices/system/cpu/cpufreq/policy*; do echo \"\$p cur/max/hw \$(cat \$p/scaling_cur_freq \$p/scaling_max_freq \$p/cpuinfo_max_freq 2>/dev/null | tr '\n' ' ')\"; done
                      echo \"gpu cur \$(cat /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq 2>&1) max \$(cat /sys/class/kgsl/kgsl-3d0/max_gpuclk 2>&1)\"
                      timeout 10 logcat -d -s thermal_core 2>/dev/null | tail -n 3; } > \$D/throttle.txt 2>&1
                    # Did user 0 unlock, did the launcher get a window, and if not,
                    # where are the launcher and SystemUI main threads stuck?
                    if [ \$dname != 20 ]; then
                        timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/am get-started-user-state 0 > \$D/user0.txt 2>&1
                        timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys window windows > \$D/windows.txt 2>&1
                        for app in com.android.launcher com.android.systemui; do
                            ap=\$(pidof \$app | awk '{print \$1}')
                            [ -n \"\$ap\" ] || continue
                            timeout 20 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/debuggerd -j \$ap > \$D/stack_\$app.txt 2>&1
                            timeout 5 cat /dev/binderfs/binder_logs/proc/\$ap > \$D/binder_\$app.txt 2>&1
                            # From the kernel, in case ART's stack dump hangs too:
                            # every thread's name, state and wait channel.
                            for tk in /proc/\$ap/task/*; do
                                echo \"\$(cat \$tk/comm) \$(sed 's/.*) //' \$tk/stat | cut -d' ' -f1) \$(cat \$tk/wchan)\"
                            done > \$D/threads_\$app.txt 2>&1
                            cat /proc/\$ap/task/\$ap/stack >> \$D/threads_\$app.txt 2>&1
                            timeout 20 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/debuggerd \$ap > \$D/native_\$app.txt 2>&1
                        done
                        cp -r $STAGE/data/anr \$D/anr 2>/dev/null
                        # Touch: where events go (guest input dispatcher state, focus),
                        # who has the touchscreen open, and raw events for 15 s.
                        timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys input > \$D/input.txt 2>&1
                        timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys window > \$D/window_all.txt 2>&1
                        # Mobile network as the guest sees it (run 30: no 5G): per SIM the
                        # service state, physical channel configs (an NR SecondaryServing
                        # entry means EN-DC is up), display info and allowed network types.
                        timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys telephony.registry > \$D/telephony_registry.txt 2>&1
                        # Signal poll in an AOSP guest (guest_prepare.sh, run 43: no bars): is
                        # OneOSPhoneInjection.apk enabled, is oneos-telephony.jar on a read-only
                        # system_ext, did TeleService load it, the polls so far (signal_polls.txt),
                        # and com.android.phone's pid (the same in diag_40 and diag_90: no crash
                        # loop). The host's RIL props too, without identifiers.
                        { timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd overlay list com.android.phone
                          timeout 5 $BB nsenter -t \$SFP -m /system/bin/sh -c 'ls -lZ /system_ext/framework/oneos-telephony.jar; grep system_ext /proc/self/mounts'
                          echo \"com.android.phone pid: \$(pidof com.android.phone)\"
                          timeout 10 logcat -d -b main,radio -s TelephonyComponentFactory OneOSSignalPoll
                          timeout 10 logcat -d -b radio -s RILJ | grep -E '[<>] SIGNAL_STRENGTH' > \$D/signal_polls.txt
                          echo \"SIGNAL_STRENGTH requests in the radio log: \$(grep -c '> SIGNAL_STRENGTH' \$D/signal_polls.txt)\"
                        } > \$D/overlays_phone.txt 2>&1
                        getprop | grep -iE 'ril|radio' | grep -viE 'serial|imei|imsi|iccid|meid|msisdn|number' > \$D/host_ril_props.txt 2>&1

                        # Location as the guest sees it (run 34: Weather found none): providers
                        # and the package each is bound to, GNSS satellites, fixes and TTFF.
                        timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys location > \$D/location.txt 2>&1
                        # Sensors and cameras as the guest sees them (Galaxy S25, X9U, session
                        # 55af6cc8: compass and camera did not work, and nothing in the logs told why).
                        timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys sensorservice > \$D/sensors.txt 2>&1
                        timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys media.camera > \$D/camera.txt 2>&1
                        # WebView and the zygote sockets (S24 Ultra, IN build, session 77e7789e: the
                        # WebView zygote start found no zygote socket file).
                        { timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys webviewupdate
                          echo; ls -la /dev/socket 2>&1 | grep -i zygote
                          echo; $BB nsenter -t \$SFP -m ls -la /dev/socket 2>&1 | grep -i zygote
                          echo; grep ' /dev/socket/' /proc/1/mountinfo
                          echo; getprop | grep -E 'abilist|ro.zygote'
                        } > \$D/webview.txt 2>&1
                        # Is the Wallpapers fold-grid overlay (guest_prepare.sh) enabled?
                        timeout 15 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh /system/bin/cmd overlay list com.oplus.wallpapers > \$D/overlays_wallpapers.txt 2>&1
                        for e in /sys/class/input/event*; do
                            [ \"\$(cat \$e/device/name 2>/dev/null)\" = sec_touchscreen ] || continue
                            dev=/dev/input/\${e##*/}
                            echo \"\$dev enabled=\$(cat \$e/device/enabled 2>/dev/null)\" > \$D/touch_holders.txt
                            ls -l /proc/[0-9]*/fd/* 2>/dev/null | grep \" \$dev\$\" >> \$D/touch_holders.txt
                            timeout 15 getevent -lt \$dev > \$D/touch_events.txt 2>&1
                        done
                        # system_server's own black-screen backtraces (OplusWmBlackDetector).
                        cp -r $STAGE/data/debugging/wm/black \$D/wm_black 2>/dev/null
                        # Run 44, in the background so a slow dump does not hold up the
                        # return keys (each call has its own timeout). Read only:
                        # - largescreen.txt: the density and fold line the UI activator
                        #   set, device state, configuration, WM Extensions warnings;
                        # - composition.txt: device or GPU composition, missed frames,
                        #   composer rejections (HW overlays are on by default now);
                        # - dexopt.txt: run 43's first boot failed to compile all 232
                        #   packages (NullPointerException in IArtd.maybeCreateSdc);
                        # - frames.txt: launcher and Settings frame pacing;
                        # - comfort.txt: Comfort View settings, color matrix, bridge log;
                        # - signal_poll.txt, host_ril_props.txt (identifiers left out),
                        #   call_audio_route.txt: phone process, its overlays and
                        #   telephony jar, RIL props, the SCO / communication device
                        #   route. Bluetooth has its own capture (bluetooth_manager.txt).
                        ( gx() { timeout 20 $BB nsenter -t \$SFP -m /system/bin/sh /data/oneos_genv.sh \"\$@\"; }
                          { gx /system/bin/wm size -d 0; gx /system/bin/wm density -d 0
                            echo \"display_density_forced=\$(gx /system/bin/settings get secure display_density_forced 2>&1)\"
                            echo \"display_features=\$(gx /system/bin/settings get global display_features 2>&1)\"
                            echo \"device state \$(gx /system/bin/cmd device_state print-state 2>&1 | head -1)\"
                            gx /system/bin/dumpsys window displays | grep -m3 -E 'init=|mGlobalConfiguration'
                            timeout 10 logcat -d -s WindowLayoutComponentImpl 2>/dev/null | tail -n 3; } > \$D/largescreen.txt 2>&1
                          { grep -E 'missed frame count|usesDeviceComposition|composition=' \$D/surfaceflinger.txt | sed -e 's/^ *//' -e 's/layer=0x[0-9a-f]* //' | sort | uniq -c
                            echo \"composer rejections in the log: \$(timeout 10 logcat -d -b main -s SurfaceFlinger:E 2>/dev/null | grep -c -E 'executeCommands failed|presentOrValidate failed')\"
                            grep -h -E 'HW overlays|GPU composition' $STAGE/data/takeover.log 2>/dev/null; } > \$D/composition.txt 2>&1
                          { for p in com.android.systemui com.google.android.apps.nexuslauncher com.android.settings; do echo \"== pm art dump \$p\"; gx /system/bin/pm art dump \$p 2>&1 | head -n 30; done
                            echo '== ArtService'; timeout 10 logcat -d -s ArtService 2>/dev/null | grep -m2 -A4 'Unexpected package-level'; } > \$D/dexopt.txt 2>&1
                          for p in com.google.android.apps.nexuslauncher com.android.settings; do echo \"== \$p\"; gx /system/bin/dumpsys gfxinfo \$p 2>&1 | grep -E 'Total frames|Janky|percentile'; done > \$D/frames.txt 2>&1
                          { for k in cv_enabled cv_preferred_intensity cv_dynamic_enabled; do echo \"\$k=\$(gx /system/bin/settings get system \$k 2>&1)\"; done
                            grep -i -E -A6 'color ?matrix|colortransform' \$D/surfaceflinger.txt | head -n 40
                            timeout 10 logcat -d -s OneOSComfortView DisplayTransformManager 2>/dev/null | tail -n 10; } > \$D/comfort.txt 2>&1
                          { echo \"com.android.phone pid: \$(pidof com.android.phone)\"
                            gx /system/bin/cmd overlay list com.android.phone
                            gx /system/bin/ls -lZ /system_ext/framework/oneos-telephony.jar
                            gx /system/bin/grep ' /system_ext' /proc/self/mountinfo; } > \$D/signal_poll.txt 2>&1
                          getprop | grep -i -E 'ril|radio' | grep -v -i -E 'imei|imsi|iccid|msisdn|meid|esn|mdn|euimid|serial|number|subinfo' > \$D/host_ril_props.txt 2>&1
                          gx /system/bin/dumpsys audio 2>&1 | grep -i -E 'sco|communication device' | head -n 20 > \$D/call_audio_route.txt
                        ) </dev/null >/dev/null 2>&1 &
                    fi
                    echo \"\$(date) display diagnostics saved in \$D\"
                fi
            fi
            # A running surfaceflinger can still show nothing: when the composer
            # rejects its frames the panel keeps the last host frame.
            # The guest framework is gone for good once its zygote died: the
            # launcher exec'd app_process64, so nothing restarts it.
            if pidof system_server >/dev/null || pidof zygote64 >/dev/null; then
                dead=0
            else
                dead=\$((dead + 10))
                if [ \$dead -ge 30 ]; then
                    echo \"\$(date) guest zygote/system_server gone for \${dead}s after \${t}s, returning to One UI\"
                    exec /system/bin/sh $STAGE/return_to_oneui.sh
                fi
            fi
            # Nothing restarts the guest's surfaceflinger either: once
            # guest_start.sh has started it (its takeover.log line), 30 s
            # without one is a black screen for good, so it need not wait for
            # ONEOS_RETURN_BLACK. S23 Ultra session 99ef8224: it aborted 27 s
            # into the switch and the phone was force-restarted 47 s later
            # (temp root lost), long before the 150 s.
            if pidof surfaceflinger >/dev/null || ! grep -q 'SurfaceFlinger PID:' $STAGE/data/takeover.log 2>/dev/null; then
                sfgone=0
            else
                sfgone=\$((sfgone + 10))
                if [ \$sfgone -ge 30 ]; then
                    echo \"\$(date) black screen after \${t}s (the guest's surfaceflinger gone for \${sfgone}s, nothing restarts it), returning to One UI\"
                    exec /system/bin/sh $STAGE/return_to_oneui.sh
                fi
            fi
            failed=\$(timeout 10 logcat -d -b main -s SurfaceFlinger 2>/dev/null | grep -c 'presentOrValidate failed\|executeCommands failed')
            # Only failures since the last check: a burst early in the boot must
            # not end a session that recovered.
            new_failed=\$((failed - prev_failed)); [ \$new_failed -lt 0 ] && new_failed=\$failed; prev_failed=\$failed
            if [ \$t -ge $RETURN_BLACK ] && { ! pidof surfaceflinger >/dev/null || [ \$new_failed -gt 100 ] || { [ \$home = 0 ] && ! pidof bootanimation >/dev/null; }; }; then
                echo \"\$(date) black screen after \${t}s (surfaceflinger: \$(pidof surfaceflinger), bootanimation: \$(pidof bootanimation), new failed frames: \$new_failed), returning to One UI\"
                exec /system/bin/sh $STAGE/return_to_oneui.sh
            fi
            if [ $SESSION_MAX -gt 0 ] && [ \$total -ge $SESSION_MAX ]; then
                echo \"\$(date) session limit ${SESSION_MAX}s reached (home: \$home), returning to One UI\"
                exec /system/bin/sh $STAGE/return_to_oneui.sh
            fi
            [ \$home = 1 ] && [ \$t -ge $((RETURN_MAX - 10)) ] && t=$((RETURN_MAX - 20))
        done
        echo \"\$(date) guest still not booted after ${RETURN_MAX}s, returning to One UI\"
        exec /system/bin/sh $STAGE/return_to_oneui.sh
    " </dev/null >>"$STAGE/auto_return.log" 2>&1 &
    echo "Auto-return to One UI armed: ${RETURN_BLACK}s on a black screen, ${RETURN_MAX}s at most"
    echo "Back to One UI in the guest's OneOS app: watching $GUEST_RETURN_REQ"
    # A way back to One UI from the hardware keys (run 32: only Restart in
    # ColorOS's power menu ended a session): hold Volume Up and Volume Down
    # together for 3 s. Host side, so it works whatever ColorOS is doing; it
    # only sets the request the watcher above acts on (within a second).
    # Only the key devices are read (getevent never grabs them, ColorOS still
    # gets the keys), so touches cost nothing. ONEOS_RETURN_KEYS=0 turns it off.
    # ColorOS also takes this chord as its accessibility shortcut, aimed at
    # TalkBack, which it turned on in run 34; guest_prepare.sh empties the
    # shortcut in the staged settings (ONEOS_GUEST_A11Y_SHORTCUT=1 keeps it).
    if [ "${ONEOS_RETURN_KEYS:-1}" = 1 ]; then
        KS="$STAGE/return_keys"; rm -rf "$KS"; mkdir -p "$KS"
        # Stamp this boot: return_to_oneui.sh only kills a listed PID when the
        # boot matches (and the PID is still a oneos_switch.sh shell).
        cat /proc/sys/kernel/random/boot_id 2>/dev/null > "$KS/boot"
        KDEVS=$(getevent -pl 2>/dev/null | awk '/^add device/ { dev = $NF } /KEY_VOLUME(UP|DOWN)/ { print dev }' | sort -u)
        for kd in $KDEVS; do
            # Like the watcher: not in the app cgroup, never OOM-killed (the
            # getevent and the loop below inherit it from this subshell; the
            # builtin echo writes as the subshell, and 0 means the writer).
            ( echo 0 > /sys/fs/cgroup/cgroup.procs 2>/dev/null
              echo -1000 > /proc/self/oom_score_adj 2>/dev/null
              getevent -lq "$kd" 2>/dev/null | while read -r typ code val rest; do
                case "$code" in KEY_VOLUMEUP) k=up ;; KEY_VOLUMEDOWN) k=down ;; *) continue ;; esac
                echo "$val" > "$KS/$k"
                if [ "$(cat "$KS/up" 2>/dev/null)" = DOWN ] && [ "$(cat "$KS/down" 2>/dev/null)" = DOWN ]; then
                    tok="$(date +%s).$RANDOM"; echo "$tok" > "$KS/both"
                    ( sleep 3
                      [ "$(cat "$KS/both" 2>/dev/null)" = "$tok" ] && [ "$(cat "$KS/up")" = DOWN ] && [ "$(cat "$KS/down")" = DOWN ] &&
                          echo "$(date) Volume Up + Volume Down held 3 s" >> "$STAGE/auto_return.log" &&
                          setprop oneos.guest.powerctl "keys:volume-up+down" ) &
                else
                    : > "$KS/both"
                fi
            done ) </dev/null >/dev/null 2>&1 &
            echo $! >> "$KS/pids"
        done
        echo "Return to One UI: hold Volume Up + Volume Down for 3 s (key devices: $(echo $KDEVS))"
    fi
fi

echo "=== TAKEOVER LAUNCHED SUCCESSFULLY ==="
