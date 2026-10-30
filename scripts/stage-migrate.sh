#!/system/bin/sh
# Runs ON THE PHONE as root: scripts/deploy-phone.sh pushes it (without the .sh,
# so it never lands in the stage) and runs it before it pushes anything into
# the stage. Renames the stage and the copies set aside from it from their
# names up to OneOS 0.3.6 (OneLineage's) to the OneOS names, the same suffix:
#
#   /data/local/tmp/lineage_stage               -> /data/local/tmp/oneos
#   /data/local/tmp/lineage_stage.old-<e>[-<p>] -> /data/local/tmp/oneos.old-<e>[-<p>]
#   /data/local/tmp/lineage_stage.trash-<e>     -> /data/local/tmp/oneos.trash-<e>
#
# With the checks of the app's root script (oneos_root.sh, migrate_legacy):
# each one only when it is a root-owned folder (not a link), nothing is
# mounted at or under it in any mount namespace (every /proc/<pid>/mountinfo;
# one that exists but cannot be read counts as mounted), no loop device is
# backed by a file in it, no host /data tree of bridges.sh is bridged in
# init's namespace, it holds no session of this boot (persist_session.active,
# guest_props.boot or return_keys/boot naming this boot), and the new name is
# free. Nothing else is written; nothing is deleted.
#
# Usage: stage-migrate <bridges.sh>
# Prints what it did; the last line is "stage-migrate: ok" (nothing is left at
# the old stage path) or "stage-migrate: refused <why>" (the old stage stays:
# busy, or both stages exist). A copy that cannot be renamed keeps its name
# (the OneOS app lists and deletes both names) and is only reported.
#
# ONEOS_TEST_ROOT (tests only, refused as root) prefixes every path.
T="${ONEOS_TEST_ROOT:-}"
if [ -n "$T" ]; then
    [ "$(id -u)" != 0 ] || { echo "stage-migrate: refused ONEOS_TEST_ROOT is for tests, never as root"; exit 2; }
    ROOT_UID=$(id -u)
else
    PATH="/system/bin:/system/xbin:$PATH"
    ROOT_UID=0
fi
TMPD="$T/data/local/tmp"
STAGE="$TMPD/oneos"
LEGACY="$TMPD/lineage_stage"
PROC="$T/proc"
SYSFS="$T/sys"

refused() { echo "stage-migrate: refused $*"; exit 2; }
[ -n "$T" ] || [ "$(id -u)" = 0 ] || refused "not root"
[ -f "$1" ] || refused "usage: stage-migrate <bridges.sh>"
BRIDGES=""
. "$1"
[ -n "$BRIDGES" ] || refused "$1 lists no bridges"

is_dec() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
# lineage_stage.old-<epoch>[-<pid>] or lineage_stage.trash-<epoch>, as the root script's old_name_ok.
old_name_ok() {
    case "$1" in
        lineage_stage.old-*) r=${1#lineage_stage.old-} ;;
        lineage_stage.trash-*) r=${1#lineage_stage.trash-} ;;
        *) return 1 ;;
    esac
    e=${r%%-*}
    p=${r#"$e"}
    p=${p#-}
    is_dec "$e" && [ ${#e} -le 12 ] || return 1
    [ "$r" = "$e" ] || { is_dec "$p" && [ ${#p} -le 10 ]; }
}
for m in "$PROC/1/mountinfo" "$PROC/self/mountinfo"; do
    awk '$5 == "/" { f = 1 } END { exit !f }' "$m" 2>/dev/null || refused "could not read $m"
done
# Why <path> cannot be renamed now; nothing when it is idle.
busy() {
    w=$(for m in "$PROC"/[0-9]*/mountinfo "$PROC/self/mountinfo"; do
            [ -e "$m" ] || continue
            if [ ! -r "$m" ]; then echo "$m (unreadable)"; continue; fi
            awk -v p="$1" '$5 == p || index($5, p "/") == 1 { print $5 }' "$m" 2>/dev/null
        done | sort -u | head -n 3 | tr '\n' ' ')
    [ -z "$w" ] || { echo "something is mounted in it: $w"; return 0; }
    w=$(for b in "$SYSFS"/block/loop*/loop/backing_file; do
            [ -r "$b" ] && cat "$b" 2>/dev/null
        done | awk -v p="$1/" 'index($0, p) == 1' | head -n 3 | tr '\n' ' ')
    [ -z "$w" ] || { echo "a loop device uses a file in it: $w"; return 0; }
    w=$(for pair in $BRIDGES; do
            awk -v p="$T/data/${pair%%:*}" '$5 == p { print $5 }' "$PROC/1/mountinfo" 2>/dev/null
        done | sort -u | head -n 3 | tr '\n' ' ')
    [ -z "$w" ] || { echo "still bridged from a session: $w"; return 0; }
    now=$(cat "$PROC/sys/kernel/random/boot_id" 2>/dev/null)
    [ -n "$now" ] || { echo "this boot's id is unreadable"; return 0; }
    for f in "$1/persist_session.active" "$1/guest_props.boot" "$1/return_keys/boot"; do
        if [ -f "$f" ] && grep -q -F "$now" "$f" 2>/dev/null; then echo "it had a session in this boot"; return 0; fi
    done
}
root_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1" 2>/dev/null)" = "$ROOT_UID" ]; }

for from in "$TMPD"/lineage_stage.old-* "$TMPD"/lineage_stage.trash-*; do
    [ -d "$from" ] && [ ! -L "$from" ] || continue
    n=${from##*/}
    old_name_ok "$n" || continue
    to="$TMPD/oneos.${n#lineage_stage.}"
    if ! root_dir "$from"; then echo "$n keeps its name: not a root-owned folder"; continue; fi
    if [ -e "$to" ] || [ -L "$to" ]; then echo "$n keeps its name: ${to##*/} exists"; continue; fi
    why=$(busy "$from")
    if [ -n "$why" ]; then echo "$n keeps its name for now: $why"; continue; fi
    if mv "$from" "$to"; then echo "renamed $n to ${to##*/}"; else echo "could not rename $n"; fi
done

if [ ! -d "$LEGACY" ] || [ -L "$LEGACY" ]; then
    echo "stage-migrate: ok"
    exit 0
fi
if [ -e "$STAGE" ] || [ -L "$STAGE" ]; then
    refused "both ${STAGE#$T} and ${LEGACY#$T} (the stage's path up to OneOS 0.3.6) exist: move the one you do not need aside (e.g. mv ${LEGACY#$T} ${STAGE#$T}.old-\$(date +%s)), then deploy again"
fi
root_dir "$LEGACY" || refused "${LEGACY#$T} is not a root-owned folder"
why=$(busy "$LEGACY")
[ -z "$why" ] || refused "${LEGACY#$T} cannot be renamed to ${STAGE#$T} now: $why - return to One UI (restart the phone) first"
mv "$LEGACY" "$STAGE" || refused "could not rename ${LEGACY#$T} to ${STAGE#$T}"
echo "renamed the stage ${LEGACY#$T} to ${STAGE#$T}"
echo "stage-migrate: ok"
