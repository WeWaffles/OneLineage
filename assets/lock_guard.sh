#!/system/bin/sh
# OneLineage lock-state guard.
#
# Why this exists: the guest system_server shares the host's binder services
# (keystore2, vold, gatekeeper, weaver, authsecret). On its first boot the
# guest LockSettingsService creates a fresh synthetic password for user 0, and
# if any of those calls reaches the host's services it can replace One UI's
# real user-0 credential state. One UI then crashes on every boot in
# SyntheticPasswordManager.verifyChallenge (soft-reboot loop at the lock
# screen), and on a temp-rooted phone the only way out is a factory reset.
#
# Usage: lock_guard.sh backup|block|unblock|restore|verify
#   backup  - snapshot host credential state (once per session; never
#             overwrites the snapshot of a session that did not end cleanly)
#   block   - stop host weaver/gatekeeper/authsecret HALs for the session so
#             the guest cannot write to them
#   unblock - start them again
#   restore - put the snapshot back if anything in it changed
#   verify  - after One UI starts, watch system_server for 60 s and restore
#             again if it crash-loops in LockSettings

GUARD_DIR="/data/local/tmp/lineage_lockstate"
SNAP="$GUARD_DIR/snapshot"
ACTIVE="$GUARD_DIR/session_active"
LOG="$GUARD_DIR/guard.log"

# Host paths that hold user-0 credential and key state.
PATHS="/data/system/locksettings.db
/data/system/locksettings.db-wal
/data/system/locksettings.db-shm
/data/system/locksettings.db-journal
/data/system_de/0/spblob
/data/misc/gatekeeper
/data/misc/keystore
/data/misc/vold/user_keys
/data/vendor/gatekeeper"

mkdir -p "$GUARD_DIR"
chmod 700 "$GUARD_DIR"

log() { echo "[lock_guard] $*"; echo "$(date '+%F %T') $*" >> "$LOG"; }

# Find the init services that actually serve the credential HALs.
# Matching by name is not enough: Samsung serves IWeaver from "hermesd".
# The framework daemon gatekeeperd (IGateKeeperService) is deliberately left
# running: the guest's BiometricService refuses to start without its binder
# ("Gatekeeper service not available" -> system_server crash loop). With the
# hardware HALs below stopped, gatekeeperd cannot reach the secure hardware,
# and its own files (/data/misc/gatekeeper) are covered by the snapshot.
GUARD_IFACES="android.hardware.weaver.IWeaver/default
android.hardware.gatekeeper.IGatekeeper/default
android.hardware.authsecret.IAuthSecret/default"

hal_services() {
    {
        for i in $GUARD_IFACES; do
            pid=$(dumpsys --pid "$i" 2>/dev/null | tr -cd '0-9')
            [ -n "$pid" ] || continue
            getprop | sed -n 's/^\[init\.svc_debug_pid\.\([^]]*\)\]: \['"$pid"'\]$/\1/p'
        done
        getprop | sed -n 's/^\[init\.svc\.\([^]]*\)\]: \[running\]$/\1/p' | grep -iE 'weaver|gatekeeper|authsecret'
    } | grep -vx 'gatekeeperd' | sort -u
}

sums() {
    for p in $PATHS; do
        [ -e "$p" ] || continue
        find "$p" -type f 2>/dev/null | sort | while read -r f; do
            echo "$(md5sum "$f" 2>/dev/null | cut -d' ' -f1) $f"
        done
    done
}

do_backup() {
    # Keep an older snapshot only when One UI is NOT healthy right now. If One
    # UI booted fully (e.g. the phone was rebooted after an unclean session),
    # the current state is the known-good one: an old snapshot would roll back
    # keystore keys and lock settings One UI legitimately changed since then.
    if [ -f "$ACTIVE" ] && [ -d "$SNAP" ]; then
        if [ "$ONEUI_HEALTHY" = "1" ]; then
            log "Previous session did not return cleanly, but One UI booted fine since; taking a fresh snapshot."
            rm -f "$ACTIVE"
        else
            log "Previous session did not return cleanly and One UI is not healthy; keeping the old snapshot."
            return 0
        fi
    fi
    rm -rf "$SNAP.tmp"
    mkdir -p "$SNAP.tmp"
    for p in $PATHS; do
        [ -e "$p" ] || continue
        mkdir -p "$SNAP.tmp$(dirname "$p")"
        if ! cp -a "$p" "$SNAP.tmp$p"; then
            log "ERROR: could not back up $p"
            rm -rf "$SNAP.tmp"
            return 1
        fi
    done
    if [ ! -e "$SNAP.tmp/data/system_de/0/spblob" ] && [ ! -e "$SNAP.tmp/data/system/locksettings.db" ]; then
        log "ERROR: no lock-settings state found to back up"
        rm -rf "$SNAP.tmp"
        return 1
    fi
    sums > "$SNAP.tmp/checksums"
    rm -rf "$SNAP"
    mv "$SNAP.tmp" "$SNAP"
    touch "$ACTIVE"
    log "Backed up One UI credential state ($(wc -l < "$SNAP/checksums") files)."
    return 0
}

do_block() {
    # The credential HALs can NOT be stopped while the guest runs: IWeaver is a
    # VINTF-declared HAL, so the guest's LockSettingsService waits for it
    # forever while holding the SyntheticPasswordManager lock, which deadlocks
    # ActivityManager and gets system_server killed by its watchdog after 66 s
    # (the "Lineage drops out after a minute" symptom). gatekeeperd is needed
    # by BiometricService at boot. So the HALs stay up; instead we record
    # Samsung's Weaver write log so return can tell whether a slot was written
    # (the one thing a file restore cannot undo). Set OL_BLOCK_HALS=1 only for
    # experiments.
    if [ "$OL_BLOCK_HALS" != "1" ]; then
        if [ -f /data/vendor/gatekeeper/HLOG_WEAVER_WRITE ]; then
            md5sum /data/vendor/gatekeeper/HLOG_WEAVER_WRITE | cut -d' ' -f1 > "$GUARD_DIR/weaver_write.md5"
        fi
        log "Credential HALs left running (required by the guest); watching Weaver writes."
        return 0
    fi
    for s in $(hal_services); do
        setprop ctl.stop "$s" 2>/dev/null && log "Stopped host HAL $s for the session"
        echo "$s" >> "$GUARD_DIR/stopped_hals"
    done
    # init restarts some HALs on demand; keep them down while the guest runs.
    if ! ps -ef 2>/dev/null | grep -v grep | grep -q "lock_guard_hal_block"; then
        SVCS=$(sort -u "$GUARD_DIR/stopped_hals" 2>/dev/null | tr '\n' ' ')
        nohup sh -c "
# lock_guard_hal_block
while [ -f '$ACTIVE' ]; do
    for s in $SVCS; do
        [ \"\$(getprop init.svc.\$s)\" = running ] && setprop ctl.stop \$s
    done
    sleep 2
done
" </dev/null >/dev/null 2>&1 &
    fi
}

do_unblock() {
    pkill -9 -f "lock_guard_hal_block" 2>/dev/null || true
    if [ -f "$GUARD_DIR/stopped_hals" ]; then
        sort -u "$GUARD_DIR/stopped_hals" | while read -r s; do
            setprop ctl.start "$s" 2>/dev/null && log "Restarted host HAL $s"
        done
        rm -f "$GUARD_DIR/stopped_hals"
    fi
}

check_weaver_writes() {
    [ -f "$GUARD_DIR/weaver_write.md5" ] || return 0
    now=$(md5sum /data/vendor/gatekeeper/HLOG_WEAVER_WRITE 2>/dev/null | cut -d' ' -f1)
    if [ "$now" != "$(cat "$GUARD_DIR/weaver_write.md5")" ]; then
        log "!!! WARNING: a Weaver slot was WRITTEN during the Lineage session. Files are restored, but a Weaver slot cannot be. If One UI then loops at the lock screen, do NOT reboot; keep root and check guard.log."
        return 1
    fi
    log "No Weaver writes during the session."
    return 0
}

do_restore() {
    check_weaver_writes
    if [ ! -d "$SNAP" ]; then
        log "WARNING: no snapshot to restore"
        return 1
    fi
    sums > "$GUARD_DIR/checksums.now"
    if cmp -s "$SNAP/checksums" "$GUARD_DIR/checksums.now"; then
        log "One UI credential state unchanged."
        return 0
    fi
    log "One UI credential state CHANGED during the session; restoring snapshot."
    diff "$SNAP/checksums" "$GUARD_DIR/checksums.now" >> "$LOG" 2>&1
    for p in $PATHS; do
        if [ -e "$SNAP$p" ]; then
            rm -rf "$p"
            mkdir -p "$(dirname "$p")"
            cp -a "$SNAP$p" "$p"
        elif [ -e "$p" ]; then
            # Did not exist before the session: the guest created it.
            rm -rf "$p"
        fi
        restorecon -R "$p" 2>/dev/null || true
    done
    sums > "$GUARD_DIR/checksums.now"
    if cmp -s "$SNAP/checksums" "$GUARD_DIR/checksums.now"; then
        log "Restore verified."
        return 0
    fi
    log "ERROR: restore could not be verified"
    return 1
}

do_verify() {
    i=0
    crashes=0
    last=""
    while [ $i -lt 30 ]; do
        sleep 2
        pid=$(pidof system_server)
        if [ -n "$last" ] && [ "$pid" != "$last" ]; then
            crashes=$((crashes + 1))
        fi
        [ -n "$pid" ] && last="$pid"
        i=$((i + 1))
    done
    if [ $crashes -eq 0 ] && [ -n "$last" ]; then
        rm -f "$ACTIVE"
        remove_hook
        log "One UI system_server stable for 60 s. Session closed cleanly."
        return 0
    fi
    log "WARNING: One UI system_server restarted $crashes time(s)."
    if logcat -d -b crash 2>/dev/null | grep -q "SyntheticPasswordManager\|LockSettingsService"; then
        log "Crash is in LockSettings; restoring credential snapshot and restarting One UI."
        setprop ctl.stop zygote
        sleep 2
        do_restore
        setprop ctl.start zygote
    fi
    log "!!! Do NOT reboot until One UI is stable: with temp root, a reboot removes the only way to repair this. Snapshot: $SNAP"
    return 1
}

# Weaver slot fence. The guest's SyntheticPasswordManager picks "the lowest free
# Weaver slot" from its OWN records only; its /data is fresh, so it believes
# every slot is free and takes slot 0 - One UI's slot. Overwriting it is the
# one change a file restore cannot undo (bootloop at the lock screen).
# AOSP has a mechanism made for exactly this (DSU GSIs sharing Weaver with the
# host): PasswordSlotManager reads /metadata/password_slots/slot_map and treats
# every slot tagged with another OS's mode as used. We write a private copy for
# the guest (bind-mounted only inside the container) tagging One UI's slots,
# plus a reserved low range, as "oneui".
# Usage: lock_guard.sh reserve <slot_map path>
do_reserve() {
    out="$1"
    [ -n "$out" ] || { log "ERROR: reserve needs an output path"; return 1; }
    reserve_low="${OL_WEAVER_RESERVE:-8}"
    tmp="$out.tmp"
    : > "$tmp" || return 1
    {
        # Slots One UI recorded itself, if it uses PasswordSlotManager.
        if [ -f /metadata/password_slots/slot_map ]; then
            sed -n 's/^\([0-9][0-9]*\)=.*/\1/p' /metadata/password_slots/slot_map
        fi
        # Slots referenced by One UI's protectors: <id>.weaver = version byte +
        # big-endian int slot.
        for f in /data/system_de/*/spblob/*.weaver; do
            [ -f "$f" ] || continue
            set -- $(od -An -tu1 -j1 -N4 "$f" 2>/dev/null)
            [ $# -eq 4 ] && echo $(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
        done
        i=0
        while [ $i -lt "$reserve_low" ]; do echo $i; i=$((i + 1)); done
    } | grep -E '^[0-9]+$' | sort -un | while read -r s; do
        echo "$s=oneui" >> "$tmp"
    done
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        log "ERROR: could not build Weaver slot reservation"
        return 1
    fi
    mv -f "$tmp" "$out"
    chown 1000:1000 "$out" 2>/dev/null
    chmod 600 "$out"
    log "Reserved Weaver slots for One UI: $(cut -d= -f1 "$out" | tr '\n' ' ')"
    return 0
}

# Boot-time safety net (Magisk / KernelSU / APatch run post-fs-data.d before
# zygote). If the phone reboots in the middle of a session - crash, battery,
# forced reboot - One UI's credential files are put back before One UI reads
# them. It does nothing unless a session is still marked active, and removes
# itself after a clean return.
HOOK_NAME="onelineage_lock_restore.sh"
install_hook() {
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    for d in /data/adb/post-fs-data.d; do
        [ -d /data/adb ] || continue
        mkdir -p "$d" 2>/dev/null || continue
        cat > "$d/$HOOK_NAME" <<EOF
#!/system/bin/sh
# OneLineage: restore One UI lock state after an interrupted Lineage session.
[ -f "$ACTIVE" ] || exit 0
[ -f "$self" ] || exit 0
sh "$self" restore
EOF
        chmod 755 "$d/$HOOK_NAME" && log "Installed boot-time restore hook $d/$HOOK_NAME"
    done
}
remove_hook() {
    rm -f "/data/adb/post-fs-data.d/$HOOK_NAME" 2>/dev/null
}

case "$1" in
    reserve) do_reserve "$2" ;;
    hook)    install_hook ;;
    unhook)  remove_hook ;;
    backup)  do_backup ;;
    block)   do_block ;;
    unblock) do_unblock ;;
    restore) do_restore ;;
    verify)  do_verify ;;
    *) echo "usage: $0 reserve <file>|hook|unhook|backup|block|unblock|restore|verify"; exit 2 ;;
esac
