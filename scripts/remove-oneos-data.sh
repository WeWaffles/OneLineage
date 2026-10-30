#!/system/bin/sh
# Remove OneOS data from a root shell (Termux, or adb shell) in One UI: what
# Advanced > Remove OneOS data deletes in the app, for a phone without the app.
# In /data/local/tmp: the stage (oneos, and lineage_stage, its name up to app
# 0.3.6) with the system you set up and the apps and accounts in it, every old
# copy (oneos.old-*, oneos.trash-* and their lineage_stage.* names), the session
# logs (oneos_logs) and the session's helper files. Nothing else in
# /data/local/tmp, and nothing of One UI or of internal storage: downloaded
# system images stay where you saved them, and the OneOS app stays installed
# (uninstall it as usual).
#
# A session's mounts reach into One UI's data, and rm -rf goes through a mount,
# so it makes the app's checks first, for every folder, and refuses before
# deleting anything: nothing mounted in them in any mount namespace, no loop
# device on their files, no session running and no One UI folder still bridged
# from one. A session that never returned left its settings in One UI, and only
# its stage can restore them: refused too, unless --force (and always in the
# boot it ran in). Each folder is renamed to oneos.trash-<epoch>-<n> and checked
# again before it is deleted, so a delete that stops half way leaves a copy the
# app lists under Old copies.
#
# Termux: sh remove-oneos-data.sh [--dry-run] [--force] (it asks su for root)
#   --dry-run  list what would be deleted, and delete nothing
#   --force    delete a session that never returned, from an earlier boot; One
#              UI then keeps that session's settings
T=${ONEOS_TEST_ROOT:-}

say() { printf '%s\n' "$*"; }
refuse() { say "Nothing deleted: $*"; exit 1; }
die() { say "Stopped: $*"; exit 2; }

FORCE=0
DRY=0
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        --dry-run) DRY=1 ;;
        *) refuse "unknown option '$a' (there are --dry-run and --force)" ;;
    esac
done

if [ -n "$T" ]; then
    [ "$(id -u)" != 0 ] || refuse "ONEOS_TEST_ROOT is for tests, never as root"
    ROOT_UID=$(id -u)
else
    if [ "$(id -u)" != 0 ]; then
        case "$0" in /*) self=$0 ;; *) self="$PWD/$0" ;; esac
        case "$self" in *"'"*) refuse "run it as root: su, then sh $0" ;; esac
        command -v su >/dev/null 2>&1 || refuse "no su: run it as root"
        exec su -c "/system/bin/sh '$self' $*"
    fi
    ROOT_UID=0
    # Android's toybox before Termux's tools.
    PATH="/system/bin:/system/xbin:$PATH"
fi
PROC="$T/proc"
SYSFS="$T/sys"
DATA="$T/data"
TMPD="$DATA/local/tmp"
# Host /data trees a session bind-mounts (oneos_root.sh BRIDGE_HOSTS).
BRIDGE_HOSTS="app app-staging user user_de dalvik-cache misc/profiles data media misc/user misc_ce/0/sdksandbox misc_de/0/sdksandbox misc_ce/0/rollback misc_de/0/rollback resource-cache"

say "OneOS: Remove OneOS data"
[ -d "$TMPD" ] || refuse "no /data/local/tmp"

# --- The app's checks (oneos_root.sh) --------------------------------------
is_dec() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
boot_id() { cat "$PROC/sys/kernel/random/boot_id" 2>/dev/null; }
# Same rule as the app's old copies: <prefix><epoch, up to 12 digits>[-<up to 10 digits>].
old_name_ok() {
    case "$1" in
        oneos.old-*) on_rest=${1#oneos.old-} ;;
        oneos.trash-*) on_rest=${1#oneos.trash-} ;;
        lineage_stage.old-*) on_rest=${1#lineage_stage.old-} ;;
        lineage_stage.trash-*) on_rest=${1#lineage_stage.trash-} ;;
        *) return 1 ;;
    esac
    on_epoch=${on_rest%%-*}
    on_pid=${on_rest#"$on_epoch"}
    on_pid=${on_pid#-}
    is_dec "$on_epoch" && [ ${#on_epoch} -le 12 ] || return 1
    [ "$on_rest" = "$on_epoch" ] || { is_dec "$on_pid" && [ ${#on_pid} -le 10 ]; }
}
mountinfo_ok() {
    for m in "$PROC/1/mountinfo" "$PROC/self/mountinfo"; do
        awk '$5 == "/" { f = 1 } END { exit !f }' "$m" 2>/dev/null || refuse "could not read $m (is this root?)"
    done
}
# A mount at or under $1 in any mount namespace: init's, this process's and
# every other process's (a session's). A table that cannot be read counts.
mounted_anywhere() { # <path>
    for m in "$PROC"/[0-9]*/mountinfo "$PROC/self/mountinfo"; do
        [ -e "$m" ] || continue
        if [ ! -r "$m" ]; then echo "$m (unreadable)"; continue; fi
        awk -v p="$1" '$5 == p || index($5, p "/") == 1 { print $5 }' "$m" 2>/dev/null
    done | sort -u
}
backed_by_files_in() { # <path>
    for b in "$SYSFS"/block/loop*/loop/backing_file; do
        [ -r "$b" ] && cat "$b" 2>/dev/null
    done | awk -v p="$1/" 'index($0, p) == 1' | head -n 3
}
bridged() {
    for h in $BRIDGE_HOSTS; do
        awk -v p="$DATA/$h" '$5 == p { print $5 }' "$PROC/1/mountinfo" 2>/dev/null
    done | sort -u
}
# A path as the phone names it (without the test root).
show() { echo "${1#$T}"; }
# Everything that must hold for <path> just before it is deleted. $FAIL is
# refuse until the first delete, die after it.
FAIL=refuse
checks() { # <path>
    m=$(mounted_anywhere "$1" | head -n 3 | tr '\n' ' ')
    [ -z "$m" ] || $FAIL "something is mounted in $(show "$1"): $m- go back to One UI, or restart the phone"
    l=$(backed_by_files_in "$1" | tr '\n' ' ')
    [ -z "$l" ] || $FAIL "a loop device uses a file in $(show "$1"): $l- restart the phone first"
}

mountinfo_ok
b=$(bridged | head -n 3 | tr '\n' ' ')
[ -z "$b" ] || refuse "One UI folders are still bridged from a session: $b- restart the phone first"
now=$(boot_id)
[ -n "$now" ] || refuse "could not read this boot's id"

DIRS=""
SKIPPED=""
for d in "$TMPD/oneos" "$TMPD/lineage_stage" "$TMPD"/oneos.old-* "$TMPD"/oneos.trash-* "$TMPD"/lineage_stage.old-* "$TMPD"/lineage_stage.trash-* "$TMPD/oneos_logs"; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    n=${d##*/}
    case "$n" in
        oneos|lineage_stage|oneos_logs) ;;
        *) old_name_ok "$n" || continue ;;
    esac
    if [ -L "$d" ] || [ ! -d "$d" ] || [ "$(stat -c %u "$d" 2>/dev/null)" != "$ROOT_UID" ]; then
        SKIPPED="$SKIPPED $n"
        continue
    fi
    checks "$d"
    if [ -f "$d/guest_props.boot" ] && grep -q -F "$now" "$d/guest_props.boot" 2>/dev/null; then
        refuse "$(show "$d") has a session running: go back to One UI first"
    fi
    if [ -f "$d/persist_session.active" ]; then
        grep -q -F "$now" "$d/persist_session.active" 2>/dev/null &&
            refuse "$(show "$d") holds a session of this boot that never returned to One UI: restart the phone first"
        [ $FORCE = 1 ] ||
            refuse "$(show "$d") holds a session that never returned to One UI. Restore One UI's settings in OneOS (Last session), then use Remove OneOS data there; or run this again with --force, and One UI keeps that session's settings"
    fi
    DIRS="$DIRS $d"
done
FILES=""
for f in adb_watchdog.sh adb_watchdog.log ims_watchdog.sh ims_watchdog.log ui_activator.log restore_app.log; do
    { [ -f "$TMPD/$f" ] || [ -L "$TMPD/$f" ]; } && FILES="$FILES $TMPD/$f"
done

if [ -z "$DIRS$FILES" ]; then
    say "Nothing of OneOS in /data/local/tmp."
    for n in $SKIPPED; do say "Left alone (not a root-owned folder): /data/local/tmp/$n"; done
    exit 0
fi

kb_gb() { awk -v k="$1" 'BEGIN { if (k < 1048576) printf "%d MB", k / 1024; else printf "%.1f GB", k / 1048576 }'; }
free_kb() { df -Pk "$DATA" 2>/dev/null | awk 'NR == 2 { print $4 }'; }

if [ $DRY = 1 ]; then
    for d in $DIRS; do
        kb=$(du -sk "$d" 2>/dev/null | cut -f1)
        is_dec "$kb" || kb=0
        say "Would delete $(show "$d") ($(kb_gb "$kb"))"
    done
    for f in $FILES; do say "Would delete $(show "$f")"; done
    for n in $SKIPPED; do say "Left alone (not a root-owned folder): /data/local/tmp/$n"; done
    say "Dry run: nothing deleted."
    exit 0
fi

# --- Delete -------------------------------------------------------------------
before=$(free_kb)
FAIL=die
for f in $FILES; do
    rm -f "$f" || die "could not delete $(show "$f")"
    say "Deleted $(show "$f")"
done
i=0
for d in $DIRS; do
    case "${d##*/}" in
        oneos.trash-*|lineage_stage.trash-*) trash=$d ;;
        *)
            i=$((i + 1))
            trash="$TMPD/oneos.trash-$(date +%s)-$i"
            [ ! -e "$trash" ] && [ ! -L "$trash" ] || die "$(show "$trash") exists already"
            mv "$d" "$trash" || die "could not rename $(show "$d")"
            ;;
    esac
    # Again on the new name: nothing may have appeared in between.
    checks "$trash"
    say "Deleting $(show "$d") ..."
    rm -rf "$trash"
    [ ! -e "$trash" ] || die "could not delete all of $(show "$d"); what is left is $(show "$trash"), and OneOS lists it under Old copies"
done
after=$(free_kb)
if is_dec "$before" && is_dec "$after" && [ "$after" -ge "$before" ]; then
    say "Done: OneOS data removed, $(kb_gb $((after - before))) freed."
else
    say "Done: OneOS data removed."
fi
for n in $SKIPPED; do say "Left alone (not a root-owned folder): /data/local/tmp/$n"; done
say "One UI and internal storage were not touched. Uninstall the OneOS app as usual."
exit 0
