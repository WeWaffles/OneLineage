#!/system/bin/sh
# Return to One UI / Safe State Restoration

# Every unmount here goes through umnt, never Android's own umount (toybox).
# After unmounting, toybox umount also sends LOOP_CLR_FD to the mount's source
# device unless given -D. For the stage's binds of One UI's /data APEXes (com.
# android.uwb, wifi@<ver>, nfcservices, ...) that device is One UI's dm-verity
# device; dm passes the ioctl down to its loop, which then stops serving reads
# while the APEX stays mounted. That was every failed in-place return: SIGBUS in
# NfcNciApex.apk and framework-ranging.jar, WifiService NPE, RescueParty, and
# "EXT4-fs (device dm-66): panic forced after error" when the next program read
# a module directory (attempts 9-13 and the scratch tests of 2026-10-21; runs
# 28/29 died inside the return). busybox umount detaches a loop only with -d.
# guest_prepare.sh and guest_start.sh only ever use busybox, which is why the
# setup checks always read clean. The reboot return had the same risk before
# restore-persist ran.
BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    [ -x "$c" ] && { BB=$c; break; }
done
umnt() {
    if [ -n "$BB" ]; then "$BB" umount "$@" 2>/dev/null; else umount -D "$@" 2>/dev/null; fi
}
S=/data/local/tmp/oneos
# What the in-place return compares against (taken by oneos_switch.sh with
# "return_to_oneui.sh baseline" while One UI still runs, before any change but
# the persist snapshot).
BASE=$S/inplace_base

# One UI's block-backed /apex mounts ("maj:min mount point"), from init's table.
apex_mounts() {
    "$BB" awk '$5 ~ /^\/apex\// && $3 !~ /^0:/ {print $3, $5}' /proc/1/mountinfo | "$BB" sort
}
loop_line() {
    b=/sys/block/$1
    echo "loop $1 dev=$("$BB" cat $b/dev 2>/dev/null) file=$("$BB" cat $b/loop/backing_file 2>/dev/null) offset=$("$BB" cat $b/loop/offset 2>/dev/null) limit=$("$BB" cat $b/loop/sizelimit 2>/dev/null) size=$("$BB" cat $b/size 2>/dev/null)"
}
# Everything about those devices that a broken teardown would change: which
# device backs each module, the dm table's name, uuid and size, the loop under
# it and that loop's backing file. Sysfs only; nothing reads through a module.
apex_state() {
    apex_mounts | while read -r mm mp; do echo "mount $mp $mm"; done
    for mm in $(apex_mounts | "$BB" awk '{print $1}' | "$BB" sort -u); do
        d=$("$BB" readlink /sys/dev/block/$mm 2>/dev/null); d=${d##*/}
        [ -n "$d" ] || { echo "dev $mm missing"; continue; }
        b=/sys/block/$d
        case $d in
            dm-*)
                echo "dev $mm $d name=$("$BB" cat $b/dm/name 2>/dev/null) uuid=$("$BB" cat $b/dm/uuid 2>/dev/null) size=$("$BB" cat $b/size 2>/dev/null) ro=$("$BB" cat $b/ro 2>/dev/null) slaves=$("$BB" ls $b/slaves 2>/dev/null | "$BB" tr '\n' ,)"
                for l in $("$BB" ls $b/slaves 2>/dev/null); do loop_line "$l"; done ;;
            loop*) echo "dev $mm $d"; loop_line "$d" ;;
            *) echo "dev $mm $d size=$("$BB" cat $b/size 2>/dev/null)" ;;
        esac
    done | "$BB" sort -u
}
# The pid servicemanager has for a name, or nothing. Only a line that is all
# digits counts: "Can't find service: ...keystore2..." would otherwise read as 2.
svc_pid() {
    o=$(timeout 5 dumpsys --pid "$1" 2>/dev/null | head -n 1)
    case "$o" in ''|*[!0-9]*) ;; *) echo "$o" ;; esac
}
# servicemanager names the guest must never have taken from One UI. One UI's
# vold cannot be restarted (init.rc: reboot_on_failure), keystore2 is critical.
HOST_NAMES="vold android.system.vold.IVold/default android.system.keystore2.IKeystoreService/default installd android.service.gatekeeper.IGateKeeperService"

if [ "$1" = baseline ]; then
    [ -n "$BB" ] || { echo "In-place baseline: no busybox, not taken (the return will reboot)"; exit 0; }
    rm -rf "$BASE"; mkdir -p "$BASE" || exit 0
    cat /proc/sys/kernel/random/boot_id > "$BASE/boot_id" 2>/dev/null
    getprop > "$BASE/props"
    getenforce > "$BASE/selinux" 2>&1
    apex_state > "$BASE/apex"
    ip rule show > "$BASE/iprule" 2>&1
    for f in /sys/fs/f2fs/*/gc_urgent; do [ -f "$f" ] && echo "$f $(cat "$f" 2>/dev/null)"; done > "$BASE/gc_urgent"
    for n in $HOST_NAMES; do p=$(svc_pid "$n"); echo "$n ${p:-none}"; done > "$BASE/svcpid"
    ls -lZ /dev/watchdog* > "$BASE/watchdog" 2>&1
    # The kernel log from here on is scanned for I/O errors on these devices.
    m="oneos-baseline $(date +%s)"
    echo "$m" > /dev/kmsg 2>/dev/null && echo "$m" > "$BASE/kmsg"
    echo "In-place baseline: $(grep -c '^mount ' "$BASE/apex") One UI APEX mounts on $(grep -c '^dev ' "$BASE/apex") devices, vold pid $(awk '$1 == "vold" {print $2}' "$BASE/svcpid"), SELinux $(cat "$BASE/selinux")"
    exit 0
fi
# The return must finish even if the adb session that started it goes away.
trap '' HUP PIPE
# The session runs Permissive (oneos_switch.sh [1/6]). Run 46 found SELinux
# Enforcing again by the return (who flips it is not known yet): root's
# property writes (sys.powerctl, the persist restore), its service lookups and
# its reboot(2) were refused, so the in-place checks failed on a false "vold is
# not registered" and neither reboot happened (5 min black screen until a
# forced restart). The return runs Permissive; the in-place path sets One UI's
# own mode again at [4/4], a reboot resets it.
SE_AT_RETURN=$(getenforce 2>/dev/null)
if [ "$SE_AT_RETURN" != Permissive ]; then
    setenforce 0 2>/dev/null
    echo "SELinux was ${SE_AT_RETURN:-unreadable} at the return: Permissive again for it ($(getenforce 2>/dev/null))"
fi

# The call keepers' logs (guest_start.sh: call_audio.log, audio_keeper.log;
# HyperOS: hyos_spawner.log)
# next to the session's logcat capture (oneos_switch.sh), first, before anything
# is stopped and on both return paths. Run 44: both calls came after diag_90 and
# the reboot return leaves no diag_final, so the per-call keeper lines were in
# no capture. Regular files only, a copy (the stage keeps its own); nothing here
# can fail the return.
LOGS=/data/local/tmp/oneos_logs
if [ -d "$LOGS" ] && [ ! -L "$LOGS" ]; then
    for f in call_audio.log audio_keeper.log oneos_a2dp.log hyos_spawner.log; do
        [ -f "$S/data/$f" ] && [ ! -L "$S/data/$f" ] || continue
        rm -f "$LOGS/$f" 2>/dev/null
        cp "$S/data/$f" "$LOGS/$f" 2>/dev/null
    done
fi

# Bluetooth and audio as the guest has them at the end, also before anything
# is stopped (run 44: the earbuds connected minutes after diag_90 and a reboot
# return writes no diag_final, so no capture showed the bonds, the A2DP codec
# and offload state, HFP and SCO, or which audio module had the A2DP device).
# The guest's own dumpsys, run in the mount namespace of its surfaceflinger
# (or system_server) and only when that process is the guest's: read only, the
# dumps side by side and 8 s at most each, so a hung guest holds the return up
# 8 s at most and nothing here can fail it (whatever still runs is in the
# guest's namespace and killed with it below). Lines that are only base64 (a
# Bluetooth snoop summary can hold link keys) are left out. $S/diag_return:
# oneos_switch.sh clears it at the switch; the app's log collection and
# pull-run-logs.sh take $S/diag_*.
DR=$S/diag_return
GNS=$(cat "$S/guest_mntns" 2>/dev/null)
GRD=$(cat "$S/guest_rootdev" 2>/dev/null)
[ "$GRD" = "$(stat -L -c %d /proc/1/root/ 2>/dev/null)" ] && GRD=""
gp=""
for p in $(pidof surfaceflinger 2>/dev/null) $(pidof system_server 2>/dev/null); do
    if [ -n "$GNS" ] && [ "$(readlink "/proc/$p/ns/mnt" 2>/dev/null)" = "$GNS" ]; then gp=$p; break; fi
    if [ -n "$GRD" ] && [ "$(stat -L -c %d "/proc/$p/root/" 2>/dev/null)" = "$GRD" ]; then gp=$p; break; fi
done
if [ -n "$BB" ] && [ -n "$gp" ] && [ ! -L "$DR" ] && rm -rf "$DR" 2>/dev/null && mkdir -p "$DR" 2>/dev/null; then
    gd() { timeout 8 "$BB" nsenter -t "$gp" -m /system/bin/sh /data/oneos_genv.sh /system/bin/dumpsys "$@" 2>&1; }
    gd bluetooth_manager | "$BB" awk 'length($0) >= 60 && $0 ~ /^[A-Za-z0-9+\/=]+$/ { n++; next } { print } END { if (n) print "(" n " base64 lines left out)" }' > "$DR/bluetooth_manager.txt" 2>&1 &
    p1=$!
    gd media.audio_policy > "$DR/dumpsys_media.audio_policy.txt" 2>&1 &
    p2=$!
    gd audio > "$DR/dumpsys_audio.txt" 2>&1 &
    p3=$!
    { for k in bluetooth.sco.managed_by_audio persist.bluetooth.a2dp_offload.disabled ro.bluetooth.a2dp_offload.supported \
               persist.bluetooth.leaudio_offload.disabled ro.bluetooth.leaudio_offload.supported; do
          echo "$k=$(getprop "$k")"
      done
      echo "audio HAL pid: $(timeout 3 dumpsys --pid android.hardware.audio.core.IModule/default 2>/dev/null | head -n 1)"
    } > "$DR/bt_props.txt" 2>&1
    wait $p1 $p2 $p3 2>/dev/null
    echo "Guest Bluetooth and audio at the return (pid $gp's namespace): $(ls "$DR" 2>/dev/null | tr '\n' ' ')in $DR"
else
    why="no guest surfaceflinger or system_server"
    [ -n "$gp" ] && why="no busybox, or $DR not usable"
    echo "Guest Bluetooth and audio at the return: not read ($why)"
fi

echo "=== [1/4] Terminating Container Supervision & Zygote ==="
# A screen recording (guest_start.sh) is finalised on SIGINT; SIGKILL would
# leave an unplayable segment. Nothing on the host is called screenrecord.
# The flag stops guest_start.sh's segment loop first: in run 31 it started
# segment 6 as soon as segment 5 was finalised, that one was killed with the
# guest (a 30 KB unplayable file) and its retry logged 'Failed to get display
# id' once SurfaceFlinger was gone.
touch /data/local/tmp/oneos/data/oneos_rec_stop 2>/dev/null
# The return-keys readers (oneos_switch.sh) live in the host namespace.
# Only kill a listed PID when it was armed this boot AND is still a
# oneos_switch.sh shell: after a reboot the pids file is stale and the ids
# are recycled (an early return before arming would otherwise signal vold/apexd
# or this script itself). oneos_switch.sh clears return_keys at its own
# preflight, so the file only ever holds this boot's readers.
KS=/data/local/tmp/oneos/return_keys
if [ "$(cat "$KS/boot" 2>/dev/null)" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ]; then
    for p in $(cat "$KS/pids" 2>/dev/null); do
        case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in
            *oneos_switch.sh*) kill "$p" 2>/dev/null ;;
        esac
    done
fi
pkill -INT -x screenrecord 2>/dev/null && sleep 2
pkill -9 -f "ctl.stop zygote" 2>/dev/null || true
pkill -9 -f "kill -STOP" 2>/dev/null || true
pkill -9 -f "ui_activator" 2>/dev/null || true
pkill -9 -f "zygote_exec" 2>/dev/null || true
# Stop the adb watchdog started by oneos_switch.sh before One UI's own
# system_server comes back, so it cannot fight init over sys.usb.config.
pkill -9 -f "adb_watchdog.sh" 2>/dev/null || true
pkill -9 -f "ims_watchdog.sh" 2>/dev/null || true
pkill -9 -f "system_server" 2>/dev/null || true
pkill -9 -f org.lineageos 2>/dev/null || true
pkill -9 -x zygote64 2>/dev/null || true
kill -9 $(pidof surfaceflinger) 2>/dev/null || true
# The heat cap (oneos_switch.sh) is stopped (its loop names system_server, so
# the pkill above may have done it already) before the CPU policies get their
# full clock back, for One UI's SSRM to set its own.
pkill -9 -f "oneos_heat_cap" 2>/dev/null || true
if [ -f $S/heat_cap.active ]; then
    hc=""
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        hw=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
        case "$hw" in ''|*[!0-9]*) continue ;; esac
        echo "$hw" > "$p/scaling_max_freq" 2>/dev/null
        hc="$hc ${p##*/}=$(cat "$p/scaling_max_freq" 2>/dev/null)/$hw"
    done
    rm -f $S/heat_cap.active
    echo "Heat cap: stopped, CPU policies at full clock:$hc"
fi

# Every process still in the container's mount namespace (recorded by
# oneos_switch.sh). The host's own namespace is never touched.
GUEST_NS=$(cat /data/local/tmp/oneos/guest_mntns 2>/dev/null)
HOST_NS=$(readlink /proc/1/ns/mnt)
# Apps have mount namespaces of their own (zygote unshares one per app); they
# are found by their root, which is the guest's root filesystem.
GUEST_DEV=$(cat /data/local/tmp/oneos/guest_rootdev 2>/dev/null)
HOST_DEV=$(stat -L -c %d /proc/1/root/ 2>/dev/null)
[ "$GUEST_DEV" = "$HOST_DEV" ] && GUEST_DEV=""
if [ -n "$GUEST_NS" ] && [ "$GUEST_NS" != "$HOST_NS" ]; then
    # Repeated: a guest zygote or init-like parent can fork while the first
    # pass runs, and nothing of the guest may outlive the return.
    pass=1
    while [ $pass -le 5 ]; do
        killed=""
        for p in /proc/[0-9]*; do
            if [ "$(readlink "$p/ns/mnt" 2>/dev/null)" != "$GUEST_NS" ]; then
                [ -n "$GUEST_DEV" ] && [ "$(stat -L -c %d "$p/root/" 2>/dev/null)" = "$GUEST_DEV" ] || continue
            fi
            pid=${p#/proc/}
            killed="$killed $pid:$(cat "$p/comm" 2>/dev/null)"
            kill -9 "$pid" 2>/dev/null
        done
        if [ $pass = 1 ]; then echo "Killed guest processes:${killed:- none}"
        elif [ -n "$killed" ]; then echo "Killed guest processes (pass $pass):$killed"; fi
        [ -n "$killed" ] || break
        pass=$((pass + 1)); sleep 0.3
    done
fi
# net_watch (oneos_switch.sh) rewrote routes until the rootfs was gone, 8 s
# into run 43's return; it has no business in the return.
pkill -9 -f "$S/rootfs/system/build.prop" 2>/dev/null || true
rm -f /data/local/tmp/oneos/guest_mntns
# HyperOS: the spawner's socket (guest_start.sh made it in /dev/socket).
rm -f /dev/socket/hyos_spawner 2>/dev/null

# The guest zygote's sockets were bound onto themselves in init's mount
# namespace (oneos_switch.sh, protect_zygote_sockets), so that init could not
# remove them while One UI's zygote was restarted during the session (LSPosed).
# Off before anything starts One UI's zygote: init makes its own sockets at the
# same paths, and replaces the dead guest's files itself. A bind that stays
# means a reboot return.
in_init_ns() {
    if [ "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)" ]; then "$@"
    elif [ -n "$BB" ]; then "$BB" nsenter -t 1 -m -- "$@"
    else nsenter -t 1 -m -- "$@"; fi
}
zs_bound() { awk -v m="$1" '$5 == m { f = 1 } END { exit !f }' /proc/1/mountinfo 2>/dev/null; }
zs_left=""
for f in /dev/socket/zygote /dev/socket/usap_pool_primary; do
    n=0
    while [ $n -lt 5 ] && zs_bound "$f"; do
        if [ -n "$BB" ]; then in_init_ns "$BB" umount -l "$f" 2>/dev/null; else in_init_ns umount -D -l "$f" 2>/dev/null; fi
        n=$((n + 1))
    done
    if zs_bound "$f"; then zs_left="$zs_left $f"
    elif [ $n -gt 0 ]; then echo "Took the guest zygote's bind off $f"; fi
done
if [ -n "$zs_left" ]; then
    echo "!!! still bound:$zs_left (One UI's zygote could not make its sockets); rebooting"
    ONEOS_RETURN_MODE=reboot
fi

# Put the host's own /data trees back FIRST: guest_prepare.sh bridges the
# staged app trees (installd/artd write there), and nothing may start One UI
# on top of the guest's copies.
# (Fallback if bridges.sh is gone; keep in step with it.)
BRIDGES="app:app app-staging:app-staging user:user user_de:user_de dalvik-cache:dalvik-cache misc/profiles:misc/profiles data:user/0 media:media misc/user:misc/user misc_ce/0/sdksandbox:misc_ce/0/sdksandbox misc_de/0/sdksandbox:misc_de/0/sdksandbox misc_ce/0/rollback:misc_ce/0/rollback misc_de/0/rollback:misc_de/0/rollback resource-cache:resource-cache"
[ -f /data/local/tmp/oneos/bridges.sh ] && . /data/local/tmp/oneos/bridges.sh
for pair in $BRIDGES; do
    d=${pair%%:*}
    umnt "/data/$d" || umnt -l "/data/$d" || true
done
# Never touch One UI's files, or start One UI in place, while a bridge is
# still there: it would act on the guest's staged copy.
still_bridged=""
for pair in $BRIDGES; do
    d=${pair%%:*}
    awk -v p="/data/$d" '$5 == p' /proc/self/mountinfo | grep -q . && still_bridged="$still_bridged /data/$d"
done
if [ -n "$still_bridged" ]; then
    echo "!!! still bridged:$still_bridged; rebooting"
    ONEOS_RETURN_MODE=reboot
fi
# OneOS: One UI Home's databases are no longer copied back here from
# /data/local/tmp/lineage_backups (OneLineage's snapshot): that was the only
# intended write into One UI's app data, and the switch no longer takes it.

# One UI's protected state against the record the switch made (see
# oneos_switch.sh): every guest process is gone by now. Logged only.
host_state() {
    f=$(readlink -f "$(getprop ro.frp.pst)" 2>/dev/null)
    [ -b "$f" ] && echo "frp $(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
    for p in /data/misc/gatekeeper /data/apex/active /data/apex/sessions; do
        [ -d "$p" ] && find "$p" -type f -exec stat -c '%n %s %Y' {} + 2>/dev/null | sort
    done
}
if [ -f "$S/host_state.before" ]; then
    host_state > "$S/host_state.after"
    if cmp -s "$S/host_state.before" "$S/host_state.after"; then
        echo "$(date) host state unchanged ($(wc -l < "$S/host_state.after") entries)" >> "$S/host_state.log"
    else
        { echo "$(date) !!! host state changed during the session:"
          diff "$S/host_state.before" "$S/host_state.after"; } >> "$S/host_state.log" 2>&1
    fi
    tail -n 1 "$S/host_state.log" | grep -q "unchanged" && echo "Host state unchanged" || echo "!!! Host state changed: see $S/host_state.log"
fi

echo "=== [2/4] Unmounting Container Overlays ==="
# OneOS: never unmount through a glob of the rootfs. The guest image's top
# level has absolute symlinks (system_ext -> /system/system_ext, product,
# sdcard, ...), and in the host namespace "umount -l rootfs/*" followed them to
# the HOST's /system_ext and /product partitions: One UI's surfaceflinger then
# failed with "CANNOT LINK ... libdisplayconfig.system.qti.so not found" and the
# phone rebooted. Unmount exactly what /proc/mounts lists under the rootfs,
# deepest first.
# Everything under the stage dir, not just the rootfs: binds that leaked out of
# the rootfs (e.g. $STAGE/data/apex) and the system_ext overlay tmpfs too.
ROOTFS=/data/local/tmp/oneos/rootfs
STAGE_ROOT=/data/local/tmp/oneos
# OneOS: detach the whole stage tree from host propagation first. guest_prepare
# makes each bind rslave/rprivate as it creates it, but an early exit may have
# left one shared; make-rprivate here is a floor, so the umount -l below can
# never propagate to the host's own /mnt, /vendor or APEX mounts.
for c in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    [ -x "$c" ] && { "$c" mount --make-rprivate "$STAGE_ROOT" 2>/dev/null; break; }
done
n=0
while [ $n -lt 10 ] && grep -q " $STAGE_ROOT/" /proc/mounts; do
    awk -v r="$STAGE_ROOT" 'index($2, r "/") == 1 {print $2}' /proc/mounts | sort -r | while read -r m; do
        umnt -l "$m" || true
    done
    n=$((n + 1))
done
echo "Mounts left under $STAGE_ROOT: $(grep -c " $STAGE_ROOT/" /proc/mounts)"
# The tmpfs behind guest_prepare's system_ext overlay (outside the rootfs).
umnt -l /data/local/tmp/oneos/system_ext_ov || true

# The return reboots unless ONEOS_RETURN_MODE=inplace and everything the
# in-place return relies on is there. In place is only ever attempted with the
# baseline of this very boot and with no stage mount or bridge left; a guest
# shutdown request always takes the reboot path (it powers off).
MODE=${ONEOS_RETURN_MODE:-reboot}
if [ "$MODE" = inplace ]; then
    RP=""
    for c in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop; do
        [ -x "$c" ] && { RP=$c; break; }
    done
    why=""
    case "$(getprop oneos.guest.powerctl)" in shutdown*) why="the guest asked to shut down" ;; esac
    [ -n "$BB" ] || why="no busybox"
    [ -n "$RP" ] || why="no resetprop"
    [ -s "$BASE/apex" ] && [ -s "$BASE/props" ] && [ -s "$BASE/svcpid" ] || why="no baseline from the switch"
    [ "$(cat "$BASE/boot_id" 2>/dev/null)" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ] || why="the baseline is from another boot"
    grep -q '^vold [0-9]' "$BASE/svcpid" 2>/dev/null || why="One UI's vold was not found at the switch"
    grep -q " $STAGE_ROOT/" /proc/mounts && why="stage mounts left"
    if [ -n "$why" ]; then
        echo "In place not possible ($why): rebooting instead."
        MODE=reboot
    fi
fi

# OneOS: return by rebooting unless asked otherwise. Restarting One UI in place
# after a session left one of its decompressed APEXes unreadable every time
# (NFC, uwb, wifi): SIGBUS crash loops, RescueParty, and once an ext4
# errors=panic kernel panic. Temp root does not survive either way. Undo what
# would persist (guest persist.* props; /data binds and mounts are gone above)
# and reboot cleanly. ONEOS_RETURN_MODE=inplace: see below.
if [ "$MODE" != inplace ]; then
    rm -f /data/local/tmp/oneos/data/guest_audio.flag /data/local/tmp/oneos/host_audio_hal_svcs
    STAGE=/data/local/tmp/oneos /system/bin/sh /data/local/tmp/oneos/guest_props.sh restore-persist
    pkill -9 -f "app_storage_loop.sh" 2>/dev/null || true
    sync
    # A guest shutdown request (low battery, thermal, power off), recorded by the
    # guarded ShutdownThread, becomes a real host shutdown; anything else reboots.
    req=$(getprop oneos.guest.powerctl)
    setprop oneos.guest.powerctl "" 2>/dev/null
    case "$req" in
        shutdown*)
            echo "Guest asked to shut down ($req): powering off."
            setprop sys.powerctl shutdown,oneos-guest-shutdown ;;
        *)
            echo "Rebooting into One UI (ONEOS_RETURN_MODE=inplace restarts it in place instead)."
            setprop sys.powerctl reboot,oneos-return ;;
    esac
    sleep 30
    reboot
    # Neither request rebooted (run 46 showed both refused under Enforcing):
    # the kernel's reboot after a sync.
    sleep 10
    sync
    "$BB" reboot -f
    exit 0
fi

# === In place: One UI's framework restarts on the same kernel boot ===========
# What Android itself does after a system_server crash (a runtime restart: One
# UI's SystemServer only uses mRuntimeRestart for boot metrics), with the
# session undone first. It relies on One UI's vold having kept its
# servicemanager name all session (the guest vold registers as "gvld", see
# docs/inplace-return.md): vold cannot be restarted, and with its name gone One
# UI's StorageManagerService retries "vold not found" forever. Every step is
# logged to return_inplace.log; any check that fails ends in failsafe(), the
# reboot return. Gates:
#   A  after the unmounts, before any One UI program starts: One UI's APEX
#      devices exactly as at the switch and readable below their filesystems
#      (sysfs, LOOP_GET_STATUS64, an O_DIRECT read of each dm device, the kernel
#      log), only busybox until it passes; then vold & co. still One UI's.
#   B  before One UI's zygote: props and SELinux back, the services the
#      framework waits on registered, nothing of the guest left.
#   C  after: system_server keeps its pid until user 0 is unlocked and 30 s more.
IPLOG=$S/return_inplace.log
: > "$IPLOG"
say() {
    m="$("$BB" date +%T) $*"
    echo "$m"; echo "$m" >> "$IPLOG"
}
failsafe() {
    say "FAILSAFE: $* - rebooting into One UI instead"
    # Permissive for the restore and the reboot requests (run 46: refused under
    # Enforcing, the phone stayed black).
    [ "$(getenforce 2>/dev/null)" = Permissive ] || setenforce 0 2>/dev/null
    STAGE=$S /system/bin/sh $S/guest_props.sh restore-persist >> "$IPLOG" 2>&1
    sync
    setprop sys.powerctl reboot,oneos-inplace-failsafe
    sleep 20
    # init did not reboot: the kernel's reboot, after the sync above; then the
    # kernel's own sysrq reboot as the last resort.
    sync
    "$BB" reboot -f
    sleep 5
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null
    sleep 2
    echo b > /proc/sysrq-trigger 2>/dev/null
    exit 1
}
base_prop() { "$BB" sed -n "s/^\[$1\]: \[\(.*\)\]\$/\1/p" "$BASE/props" | "$BB" head -n 1; }
base_has() { "$BB" grep -q "^\[$1\]: " "$BASE/props"; }
# Put a non-persist prop back to its value at the switch, in memory only
# (resetprop -n: no property triggers), or delete it if One UI had none.
put_back() {
    if base_has "$1"; then "$RP" -n "$1" "$(base_prop "$1")" 2>/dev/null
    else "$RP" --delete "$1" 2>/dev/null; fi
}
wait_found() { # <name> <seconds>
    w=0
    while [ $w -lt $(($2 * 2)) ]; do
        timeout 3 service check "$1" 2>/dev/null | grep -q ': found' && return 0
        sleep 0.5; w=$((w + 1))
    done
    return 1
}

# No system wakelock is held while no framework runs: keep the phone from
# suspending in the middle of the return. Released when One UI is up.
echo oneos_return > /sys/power/wake_lock 2>/dev/null
say "In-place return (baseline: $(cat "$BASE/kmsg" 2>/dev/null); SELinux at the return: ${SE_AT_RETURN:-unreadable}, now $(getenforce 2>/dev/null))"

echo "=== [3/4] Checking One UI's modules (in place) ==="
# Leftovers in the host namespace. The suppression loop must be gone before
# anything is started (its last 'ctl.stop' can land after a start); the audio
# flag makes it stop audioserver too.
rm -f $S/data/guest_audio.flag
# app_storage_loop.sh runs net_fix.sh, which would add ip rule 14999 back.
"$BB" pkill -9 -f "app_storage_loop.sh" 2>/dev/null
"$BB" pkill -9 -f "ctl.stop zygote" 2>/dev/null
n=0
while [ $n -lt 10 ] && "$BB" pgrep -f "ctl.stop zygote" >/dev/null 2>&1; do
    "$BB" pkill -9 -f "ctl.stop zygote" 2>/dev/null; sleep 0.2; n=$((n + 1))
done
"$BB" pgrep -f "ctl.stop zygote" >/dev/null 2>&1 && failsafe "the session's stop loop is still running"
sleep 0.5
# Stage mounts another mount namespace still holds (run 45): Android's bootstrap
# namespace (early vendor daemons, kernel threads) gets its own copy of what the
# session mounts below /data, and the unmounts in init's namespace do not reach
# it: /proc/1000/mountinfo kept $S/rootfs, rootfs/proc and rootfs/sys, and the
# check below rebooted. Unmounted in that namespace, deepest first, only mount
# points below the stage, through one process per namespace. The check below
# still decides.
# Every one of them is made private there FIRST (runs 46 and 47): the copy of
# $S/rootfs/sys is a peer of the phone's own /sys, so unmounting its submounts
# while still shared also unmounted the real /sys/fs/selinux (getenforce
# "Disabled", servicemanager and property checks failing, false "not
# registered" findings, the reboot request refused). init's namespace does the
# same with mount --make-rprivate in [2/4]. And selinuxfs is checked after.
SEFS_BEFORE=0; [ -e /sys/fs/selinux/enforce ] && SEFS_BEFORE=1
I_NS=$(readlink /proc/1/ns/mnt 2>/dev/null)
seen=" "
for p in /proc/[0-9]*; do
    n=$(readlink "$p/ns/mnt" 2>/dev/null) || continue
    [ -n "$n" ] && [ -n "$I_NS" ] && [ "$n" != "$I_NS" ] || continue
    case "$seen" in *" $n "*) continue ;; esac
    seen="$seen$n "
    mps=$("$BB" awk -v s="$S/" 'index($5, s) == 1 {print $5}' "$p/mountinfo" 2>/dev/null | "$BB" sort -r)
    [ -n "$mps" ] || continue
    u=0; t=0; pv=0
    for mp in $mps; do
        t=$((t + 1))
        "$BB" nsenter -t "${p##*/}" -m -- "$BB" mount --make-private "$mp" 2>/dev/null && pv=$((pv + 1))
    done
    if [ $pv != $t ]; then
        say "stage mounts in another mount namespace ($n, pid ${p##*/} $(cat "$p/comm" 2>/dev/null)): only $pv of $t could be made private, none unmounted there"
        continue
    fi
    for mp in $mps; do
        "$BB" nsenter -t "${p##*/}" -m -- "$BB" umount -l "$mp" 2>/dev/null && u=$((u + 1))
    done
    say "stage mounts in another mount namespace ($n, pid ${p##*/} $(cat "$p/comm" 2>/dev/null)): $t made private, $u of $t unmounted there"
done
[ $SEFS_BEFORE = 0 ] || [ -e /sys/fs/selinux/enforce ] || failsafe "/sys/fs/selinux is gone after the stage unmounts"
# Nothing of the stage may stay mounted in any process's table (a namespace
# made mid-session keeps its own copy): by mount point or by source (a bind
# from the stage shows its path below /data in field 4).
left=$("$BB" grep -H -F "/local/tmp/oneos/" /proc/[0-9]*/mountinfo 2>/dev/null |
    "$BB" awk -v s="$S/" -v r="/local/tmp/oneos/" 'index($5, s) == 1 || index($4, r) == 1 {print $1 " " $4 " " $5}' | "$BB" head -n 3)
[ -z "$left" ] || failsafe "stage still mounted: $left"
# Nor anything on One UI's own partitions that the session added (mount
# points recorded by guest_prepare.sh before its setup, host_part_mounts). An
# image with system/product as a link to /product put an overlay on One UI's
# /product/etc (2026-10-25), whose source is no stage path.
if [ -f "$S/host_part_mounts.before" ]; then
    "$BB" awk '$5 ~ /^\/(system|system_ext|product|vendor|vendor_dlkm|odm|odm_dlkm|oem|prism|optics|my_[a-z_]+)(\/|$)/ {print $5}' /proc/1/mountinfo |
        "$BB" sort > "$S/host_part_mounts.return"
    extra=$("$BB" awk 'NR == FNR { b[$0] = 1; next } !($0 in b)' "$S/host_part_mounts.before" "$S/host_part_mounts.return" | "$BB" head -n 3)
    [ -z "$extra" ] || failsafe "mounted over One UI's own partitions: $extra"
fi
# Private device nodes from sysfs maj:min for every loop and dm device the
# return touches: guest_prepare.sh re-creates /dev/block/loop50-150 itself, so
# a name there proves nothing.
NODES=/dev/oneos_nodes
"$BB" rm -rf $NODES; "$BB" mkdir -p $NODES || failsafe "no $NODES"
node() { # <sysfs block name>: prints a node for it
    mm=$("$BB" cat /sys/block/$1/dev 2>/dev/null) && [ -n "$mm" ] &&
        { [ -b $NODES/$1 ] || "$BB" mknod $NODES/$1 b ${mm%%:*} ${mm#*:} 2>/dev/null; } && echo $NODES/$1
}
# The stage's own loop devices (system.raw and the APEX payloads,
# guest_prepare.sh), now that nothing has them mounted. Only loops whose
# backing file is in the stage and that nothing holds; never One UI's.
freed=0
for b in /sys/block/loop*; do
    f=$("$BB" cat $b/loop/backing_file 2>/dev/null) || continue
    case "$f" in "$S/"*) ;; *) continue ;; esac
    [ -z "$("$BB" ls $b/holders 2>/dev/null)" ] || continue
    nd=$(node ${b##*/}) && "$BB" losetup -d $nd 2>/dev/null && freed=$((freed + 1))
done
say "stage loop devices detached: $freed"

# Gate A, part 1: One UI's APEX devices, without reading through any module's
# filesystem and with busybox only (every dynamically linked program maps
# bionic from /apex). A device whose loop stopped serving reads fails here,
# not later as SIGBUS or an ext4 errors=panic.
apex_state > "$S/inplace_apex.after"
if ! "$BB" cmp -s "$BASE/apex" "$S/inplace_apex.after"; then
    "$BB" diff "$BASE/apex" "$S/inplace_apex.after" >> "$IPLOG" 2>&1
    failsafe "One UI's APEX devices changed during the session (diff in return_inplace.log)"
fi
DIRECT=0; "$BB" dd --help 2>&1 | "$BB" grep -q direct && DIRECT=1
read_mb=0
for d in $("$BB" awk '$1 == "dev" {print $3} $1 == "loop" {print $2}' "$BASE/apex" | "$BB" sort -u); do
    nd=$(node $d) || failsafe "$d is gone"
    case $d in
        loop*) "$BB" losetup $nd >/dev/null 2>&1 || failsafe "$d no longer serves its backing file" ;;
        dm-*)
            [ "$("$BB" cat /sys/block/$d/dm/suspended 2>/dev/null)" = 0 ] || failsafe "$d is suspended"
            # Every block through dm-verity and its loop, past the page cache.
            # Never a buffered read instead: that one goes through the cache.
            if [ $DIRECT = 1 ]; then
                "$BB" timeout 60 "$BB" dd if=$nd of=/dev/null bs=1M iflag=direct 2>/dev/null ||
                    failsafe "reading $d failed"
                read_mb=$((read_mb + $("$BB" cat /sys/block/$d/size) / 2048))
            fi ;;
    esac
done
# The kernel log since the switch, for errors on exactly these devices.
# Joined with "|" and no empty entry: a trailing "|" ("loop9|)") made busybox
# grep -E fail with "empty (sub)expression", and the scan then found nothing
# (S25 Ultra and Galaxy S23 returns, 0.4.17: "kernel log clean" unscanned).
devs=$("$BB" awk '$1 == "dev" {print $3; print $2} $1 == "loop" {print $2}' "$BASE/apex" | "$BB" grep -v '^$' | "$BB" sort -u | "$BB" tr '\n' '|' | "$BB" sed 's/|*$//')
mark=$(cat "$BASE/kmsg" 2>/dev/null)
klog=$("$BB" dmesg 2>/dev/null | "$BB" awk -v m="$mark" 'm != "" && index($0, m) {f = 1; next} f || m == ""')
"$BB" dmesg 2>/dev/null | "$BB" grep -qF "$mark" || say "kernel log: the switch's marker rotated out, scanning all of it"
re="(^|[[:space:](,])($devs)([^0-9]|\$)"
if [ -z "$devs" ] || ! echo | "$BB" grep -qE "$re|^$" 2>/dev/null; then
    say "kernel log: not scanned (no device list, or busybox grep refused the pattern)"
    kl="kernel log not scanned"
else
    kl="kernel log clean"
    bad=$(echo "$klog" | "$BB" grep -E "$re" | "$BB" grep -iE 'error|corrupt|verity|capacity change' | "$BB" head -n 3)
    [ -z "$bad" ] || failsafe "kernel log: $bad"
fi
say "Gate A: $(grep -c '^mount ' "$BASE/apex") One UI APEX mounts as at the switch, loops serving, ${read_mb} MB read below the modules (O_DIRECT $DIRECT), $kl"

# Gate A, part 2: the servicemanager names One UI keeps (first dynamically
# linked programs of the return). vold above all.
while read -r name pid; do
    [ "$pid" = none ] && continue
    now=$(svc_pid "$name")
    # One retry, and what dumpsys answered in the failure (run 46: an empty
    # answer under Enforcing read as "not registered").
    [ "$now" = "$pid" ] || { sleep 1; now=$(svc_pid "$name"); }
    [ "$now" = "$pid" ] || failsafe "$name is ${now:-not registered} now, was One UI's $pid at the switch (dumpsys: $(timeout 5 dumpsys --pid "$name" 2>&1 | head -n 1 | cut -c1-80); init.svc_debug_pid.vold $(getprop init.svc_debug_pid.vold); SELinux $(getenforce 2>/dev/null))"
done < "$BASE/svcpid"
[ "$(getprop init.svc_debug_pid.vold)" = "$(base_prop init.svc_debug_pid.vold)" ] || failsafe "One UI's vold restarted"
say "Gate A: vold $(awk '$1 == "vold" {print $2}' "$BASE/svcpid") and the other names are still One UI's"

echo "=== [4/4] Starting One UI in place ==="
g=0
for p in /proc/[0-9]*; do
    if [ -n "$GUEST_NS" ] && [ "$(readlink "$p/ns/mnt" 2>/dev/null)" = "$GUEST_NS" ]; then g=$((g + 1))
    elif [ -n "$GUEST_DEV" ] && [ "$(stat -L -c %d "$p/root/" 2>/dev/null)" = "$GUEST_DEV" ]; then g=$((g + 1)); fi
done
[ $g = 0 ] || failsafe "$g guest processes still running"
[ "$(getprop init.svc.zygote)" != running ] && ! pidof system_server >/dev/null || failsafe "One UI's zygote or system_server started before the return was ready"
# Props before any One UI daemon reads them: the guest's own (added and
# overridden ones), what the switch set, then persist.* from the snapshot.
STAGE=$S /system/bin/sh $S/guest_props.sh remove >> "$IPLOG" 2>&1
for k in ro.control_privapp_permissions sys.rescue_boot_count crashrecovery.rescue_boot_count \
         audio.offload.disable audio.deep_buffer.media audio.offload.video vendor.audio.offload.track.enable \
         service.bootanim.exit oneos.guest.powerctl; do
    put_back "$k"
done
for k in $(getprop | "$BB" sed -n 's/^\[\(log\.tag\.[^]]*\)\]: .*/\1/p'); do put_back "$k"; done
# debug.* (surfaceflinger, hwui, renderengine) the guest set through the shared
# property service: One UI's surfaceflinger reads them at start.
getprop > "$S/inplace_props.mid"
for k in $("$BB" awk -F'\\]: \\[' 'NR == FNR {b[$1] = $2; next} $1 ~ /^\[debug\./ && (!($1 in b) || b[$1] != $2) {sub(/^\[/, "", $1); print $1}' "$BASE/props" "$S/inplace_props.mid"); do
    put_back "$k"
done
STAGE=$S /system/bin/sh $S/guest_props.sh restore-persist >> "$IPLOG" 2>&1 || failsafe "One UI's persist props could not be restored"
# RescueParty stays off until One UI is up (in memory: the stored value is the
# snapshot's again); the guest's system_server starts counted towards it.
"$RP" -n persist.sys.disable_rescue true 2>/dev/null
# Every other difference to the switch's props, by name only (values can be
# personal: SIM, operator), for the log.
getprop > "$S/inplace_props.after"
# Empty names not there at the switch are the guest's, blanked (guest_props.sh remove).
changed=$("$BB" awk -F'\\]: \\[' 'NR == FNR {b[$1] = $2; next} ($1 in b) ? b[$1] != $2 : $2 != "]" {sub(/^\[/, "", $1); print $1}' "$BASE/props" "$S/inplace_props.after" |
    "$BB" grep -vE '^(init\.svc|init\.svc_debug_pid|ro\.boottime|persist\.|sys\.system_server|debug\.|log\.tag|vendor\.debug)' | "$BB" tr '\n' ' ')
say "props: restored; other changes since the switch: ${changed:-none}"
# SELinux back before any One UI process starts (was last, after zygote).
[ "$(cat "$BASE/selinux")" = Enforcing ] && setenforce 1 2>/dev/null
[ "$(getenforce 2>/dev/null)" = "$(cat "$BASE/selinux")" ] || failsafe "SELinux is $(getenforce 2>/dev/null), was $(cat "$BASE/selinux")"

# Session leftovers. One UI's idmap2d is lazy: stopped, it starts again on
# request (the guest's took the "idmap" name). One UI's supplicant: its
# HalDeviceManager starts it. net_fix.sh's rule and table.
setprop ctl.stop idmap2d
SUPP=$(cat $S/host_supplicant_svc 2>/dev/null)
[ -n "$SUPP" ] && setprop ctl.stop "$SUPP"
if ip rule show 2>/dev/null | "$BB" grep -q '^14999:.*lookup 4242'; then
    ip rule del priority 14999 2>/dev/null
    ip route flush table 4242 2>/dev/null
fi
"$BB" grep -q '^14999:' "$BASE/iprule" || ! ip rule show 2>/dev/null | "$BB" grep -q '^14999:' || say "!!! ip rule 14999 still there"
# guest_prepare.sh re-made /dev/block/loop50-150 and /dev/loop50-150 with mknod:
# their SELinux label is gone (One UI's apexd and vold need loop_device).
restorecon /dev/block/loop* /dev/loop* 2>/dev/null
# A guest vold killed in its idle maintenance leaves f2fs in urgent GC.
[ -f "$BASE/gc_urgent" ] && while read -r f v; do
    [ "$(cat "$f" 2>/dev/null)" = "$v" ] && continue
    say "f2fs $f is $(cat "$f" 2>/dev/null), was $v at the switch"
    case "$v" in 0|GC_NORMAL) echo 0 > "$f" 2>/dev/null ;; esac
done < "$BASE/gc_urgent"

# Display: the composer still holds the guest's dead surfaceflinger as its
# client (guest_start.sh restarted it for the guest); its onrestart starts One
# UI's surfaceflinger, which starts the boot animation.
# Snapdragon's composer service, or Samsung's Exynos one, or -- when the phone
# names it something else, as the Galaxy A56 does -- whichever running init
# service calls itself the display composer (guest_start.sh restarts the same
# one). Only then is there nothing to restart and the return cannot finish.
COMPOSER_SVC=""
for c in vendor.qti.hardware.display.composer vendor.hwcomposer-3; do
    [ -n "$(getprop init.svc.$c)" ] && { COMPOSER_SVC=$c; break; }
done
[ -n "$COMPOSER_SVC" ] || COMPOSER_SVC=$(getprop | "$BB" sed -n 's/^\[init\.svc\.\([^]]*\)\]: \[running\]$/\1/p' | "$BB" grep -m1 -E 'hwcomposer|display\.composer|graphics\.composer')
[ -n "$COMPOSER_SVC" ] || failsafe "no display composer service found"
setprop ctl.restart "$COMPOSER_SVC"
# The SM8550 phones (Galaxy S23) have only the HIDL composer
# (android.hardware.graphics.composer@2.x): waiting for the AIDL one rebooted
# every return there (1f4f0c7f). The vendor manifest says which one this phone
# serves; lshal, bounded, for the HIDL one.
if "$BB" grep -rqs 'android.hardware.graphics.composer3' /vendor/etc/vintf/; then
    wait_found android.hardware.graphics.composer3.IComposer/default 10 || failsafe "the display composer did not come back"
else
    sleep 1  # past the old instance's registration
    n=0
    while [ $n -lt 20 ] && ! timeout 3 lshal list -i 2>/dev/null | "$BB" grep -q 'android\.hardware\.graphics\.composer@[0-9.]*::IComposer/default'; do
        sleep 0.5; n=$((n + 1))
    done
    [ $n -lt 20 ] || failsafe "the display composer (HIDL) did not come back"
    say "display: the HIDL composer is back after $((n / 2)) s"
fi
wait_found SurfaceFlinger 5 || setprop ctl.start surfaceflinger
wait_found SurfaceFlinger 10 || failsafe "One UI's surfaceflinger did not start"
setprop service.bootanim.exit 0
setprop ctl.start bootanim
say "display: composer, surfaceflinger $(pidof surfaceflinger) and boot animation up"

# Audio: a fresh HAL for One UI (the guest's audioserver drove it), then One
# UI's audioserver. AudioService waits for the policy service with no timeout.
setprop ctl.stop audioserver
AHAL=$(cat $S/host_audio_hal_svcs 2>/dev/null)
for s in $AHAL; do setprop ctl.stop $s; done
[ -n "$AHAL" ] && sleep 1
for s in $AHAL; do setprop ctl.start $s; done
rm -f $S/host_audio_hal_svcs
setprop ctl.start audioserver
wait_found media.audio_policy 20 || failsafe "One UI's audioserver did not register"
# zygote's own onrestart list, which ctl.start skips: cameraserver, media,
# wificond (netd follows below). The guest held the GNSS HAL's callbacks.
setprop ctl.restart cameraserver
for svc in media mediaextractor mediametrics; do setprop ctl.start $svc; done
setprop ctl.restart wificond
[ "$(base_prop init.svc.gnss_service)" = running ] && setprop ctl.restart gnss_service
# One UI's init.zygote64.rc also restarts these two (read on the phone, run 44):
# Samsung's perf daemon and, when it runs, the tuner service.
for svc in perfmond media.tuner; do
    [ "$(base_prop init.svc.$svc)" = running ] && setprop ctl.restart $svc
done
# The switch stopped the phone updater; init does not start it again by itself.
[ "$(base_prop init.svc.update_engine)" = running ] && setprop ctl.start update_engine
say "audio, camera, media, Wi-Fi, GNSS, perf and tuner services restarted"

# Gate B: nothing of the guest, everything One UI's framework waits for.
g=0
GUEST_DEV=$(cat $S/guest_rootdev 2>/dev/null)
[ "$GUEST_DEV" = "$HOST_DEV" ] && GUEST_DEV=""
if [ -n "$GUEST_DEV" ]; then
    for p in /proc/[0-9]*; do
        [ "$(stat -L -c %d "$p/root/" 2>/dev/null)" = "$GUEST_DEV" ] && g=$((g + 1))
    done
fi
[ $g = 0 ] || failsafe "$g guest processes still running"
for name in vold SurfaceFlinger media.audio_policy media.audio_flinger installd; do
    wait_found "$name" 5 || failsafe "$name is not registered"
done
for svc in vold keystore2 servicemanager hwservicemanager logd lmkd installd; do
    [ "$(base_prop init.svc.$svc)" = running ] || continue
    [ "$(getprop init.svc.$svc)" = running ] || failsafe "$svc is $(getprop init.svc.$svc), was running"
done
svcs=$(getprop | "$BB" awk -F'\\]: \\[' 'NR == FNR {b[$1] = $2; next} $1 ~ /^\[init\.svc\./ && ($1 in b) && b[$1] != $2 {sub(/^\[init\.svc\./, "", $1); print $1}' "$BASE/props" - | "$BB" tr '\n' ' ')
say "init services not as at the switch: ${svcs:-none}"
say "Gate B: no guest process, One UI's services up, SELinux $(getenforce)"

# One UI's framework. zygote's onrestart actions by hand: abort the FUSE
# connections the old session left. netd's restart re-creates DnsResolver
# (the guest's system_server took its one-time unstable interface) and its
# own onrestart starts zygote; ctl.start covers a netd without one.
timeout 10 vdc volume abort_fuse >/dev/null 2>&1
setprop ctl.restart netd
n=0
while [ $n -lt 20 ] && [ "$(getprop init.svc.zygote)" != running ]; do sleep 0.5; n=$((n + 1)); done
[ "$(getprop init.svc.zygote)" = running ] || setprop ctl.start zygote
say "One UI's zygote started ($(getprop init.svc.zygote))"
# One UI's 32-bit zygote (zygote64_32 phones), stopped by the switch.
if [ "$(base_prop init.svc.zygote_secondary)" = running ] && [ "$(getprop init.svc.zygote_secondary)" != running ]; then
    setprop ctl.start zygote_secondary
    say "One UI's zygote_secondary started"
fi
# One UI's zygote_next if anything stopped it (0.4.25-hyperos's switch did).
if [ "$(base_prop init.svc.zygote_next)" = running ] && [ "$(getprop init.svc.zygote_next)" != running ]; then
    setprop ctl.start zygote_next
    say "One UI's zygote_next started"
fi

# Gate C: system_server must come up and keep its pid until user 0 is
# unlocked and 30 s more. Any death reboots right away: Samsung's bootchecker
# reboots after a few anyway, and RescueParty would reset One UI's settings.
t=0; ss=""
while [ $t -lt 60 ]; do
    ss=$(pidof system_server); [ -n "$ss" ] && break
    sleep 1; t=$((t + 1))
done
[ -n "$ss" ] || failsafe "One UI's system_server did not start in 60 s"
say "One UI's system_server $ss"
t=0; up=0
while :; do
    sleep 2; t=$((t + 2))
    now=$(pidof system_server)
    [ "$now" = "$ss" ] || failsafe "One UI's system_server $ss died after ${t}s (now ${now:-none})"
    [ "$(getprop init.svc.zygote)" = running ] || failsafe "zygote is $(getprop init.svc.zygote)"
    if [ $up = 0 ]; then
        st=$(timeout 5 am get-started-user-state 0 2>&1)
        case "$st" in
            *RUNNING_UNLOCKED*) up=$t; say "user 0 unlocked after ${t}s" ;;
            # An am without the command: One UI's home screen process instead.
            *nknown*|*rror*) pidof com.sec.android.app.launcher >/dev/null && { up=$t; say "One UI Home running after ${t}s"; } ;;
        esac
    fi
    [ $up -gt 0 ] && [ $t -ge $((up + 30)) ] && break
    [ $up = 0 ] && [ $t -ge 180 ] && failsafe "user 0 not unlocked within 180 s"
done

ip rule show 2>/dev/null | "$BB" diff "$BASE/iprule" - >> "$IPLOG" 2>&1 || say "!!! ip rules differ from the switch (diff in return_inplace.log)"
# One UI is up. RescueParty back to the stored value, the modules read through
# their filesystems (safe now: Gate A read them below), the session's logcat
# capture and the wakelock end.
v=$("$BB" sed -n 's/^persist\.sys\.disable_rescue=//p' $S/persist_props.snapshot 2>/dev/null | "$BB" head -n 1)
if [ -n "$v" ]; then "$RP" -n persist.sys.disable_rescue "$v" 2>/dev/null; else "$RP" --delete persist.sys.disable_rescue 2>/dev/null; fi
/system/bin/sh $S/check_host_apex.sh after-inplace >> "$IPLOG" 2>&1 || say "!!! a One UI APEX file read failed after the restart (see return_inplace.log)"
# Two more minutes of the session's logcat capture for anything late, then
# this return stops it, unless a session started meanwhile: that one keeps the
# capture as its own (oneos_switch.sh) and deletes $LOGS/logcat.stop, and the
# stop below then leaves it running. S25 Ultra, 28 Oct: the next session
# started 78 s after a return, and this stop ended its capture 40 s into it,
# with no logcat of the session at all.
if [ -d "$LOGS" ] && [ ! -L "$LOGS" ]; then
    STOP_TOKEN="$(date +%s).$$"
    echo "$STOP_TOKEN" > "$LOGS/logcat.stop" 2>/dev/null
    "$BB" sh -c "sleep 120; [ \"\$(cat $LOGS/logcat.stop 2>/dev/null)\" = $STOP_TOKEN ] || exit 0; rm -f $LOGS/logcat.stop; pkill -f '^logcat .*/data/local/tmp/oneos_logs/boot.log'" </dev/null >/dev/null 2>&1 &
fi
"$BB" rm -rf $NODES
echo "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) $(date +%s)" > $S/return_inplace.done
echo oneos_return > /sys/power/wake_unlock 2>/dev/null
say "One UI restored in place ($(getenforce))."
