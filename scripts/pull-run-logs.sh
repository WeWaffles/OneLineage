#!/bin/sh
# Pull a session's logs from the phone into out/logs/<name>: the logcat capture
# (/data/local/tmp/oneos_logs), the switch/return logs, the diagnostics rounds
# (diag_*: the round folders and diag_series.txt, the 30 s session sampler)
# and the guest's start-up log. Everything is packed and gzipped on the phone
# first (about 10x smaller), which matters over the mobile-data tunnel.
# The capture's head/ holds the files of the boot (hard links made in the 90 s
# round, oneos_switch.sh); only those whose inode is no longer at the top
# level are taken from there (the rest are the same files), into head/.
#
# Usage: scripts/pull-run-logs.sh <name>     (e.g. run30; ANDROID_SERIAL picks the phone,
#        ADB="adb -H 127.0.0.1 -P 5575" uses a PC's adb server forwarded over SSH,
#        REC=1 also pulls the screen recording)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME="$1"
[ -n "$NAME" ] || { echo "usage: $0 <name>" >&2; exit 2; }
SERIAL="${ANDROID_SERIAL:-127.0.0.1:5565}"
OUT="$ROOT/out/logs/$NAME"
TMP=/data/local/tmp/oneos_pull
mkdir -p "$OUT"
# The stage (/data/local/tmp/oneos), or its path up to 0.3.6 while it is still there.
${ADB:-adb} -s "$SERIAL" shell "su -c '
S=/data/local/tmp/oneos
[ -d \$S ] || [ ! -d /data/local/tmp/lineage_stage ] || S=/data/local/tmp/lineage_stage
rm -rf $TMP $TMP.tgz && mkdir -p $TMP
L=/data/local/tmp/oneos_logs
T=\" \"
for f in \$L/*; do
  [ -f \$f ] || continue
  i=\$(stat -c %i \$f)
  cp \$f $TMP/ && [ -n \"\$i\" ] && T=\"\$T\$i \"
done
for f in \$L/head/*; do
  [ -f \$f ] || continue
  i=\$(stat -c %i \$f)
  [ -n \"\$i\" ] && case \"\$T\" in *\" \$i \"*) continue ;; esac
  mkdir -p $TMP/head && cp \$f $TMP/head/
done
cp -r \$S/*.log \$S/diag_* $TMP/ 2>/dev/null
cp \$S/data/takeover.log $TMP/takeover_inner.log 2>/dev/null
cp \$S/data/call_audio.log \$S/data/audio_keeper.log \$S/data/oneos_a2dp.log $TMP/ 2>/dev/null
cp /data/local/tmp/ui_activator.log $TMP/ 2>/dev/null
cd $TMP && /data/adb/ksu/bin/busybox tar czf $TMP.tgz . && chmod 644 $TMP.tgz && rm -rf $TMP
ls -l $TMP.tgz'"
${ADB:-adb} -s "$SERIAL" pull "$TMP.tgz" "$OUT/logs.tgz"
# all.log: head/ first (the boot), then the capture's own files, each oldest
# first (boot.log.NN before boot.log); a file whose content is already in it
# (same CRC and size) is skipped.
(cd "$OUT" && tar xzf logs.tgz && rm logs.tgz && {
    seen=" "
    for f in $( { ls head 2>/dev/null | grep '^boot\.log' | sort -r | sed 's|^|head/|'; ls | grep '^boot\.log' | sort -r; } ); do
        k=$(cksum < "$f" | tr ' ' :)
        case "$seen" in *" $k "*) echo "$f: already in all.log, skipped" >&2; continue ;; esac
        seen="$seen$k "
        cat "$f"
    done > all.log
})
echo "$OUT: $(wc -l < "$OUT/all.log") logcat lines"
# REC=1 also pulls the session's screen recording (guest_start.sh writes
# data/oneos_rec_N.mp4 in the stage; root-only, so copied out first).
if [ "${REC:-0}" = 1 ]; then
    ${ADB:-adb} -s "$SERIAL" shell "su -c 'S=/data/local/tmp/oneos; [ -d \$S ] || [ ! -d /data/local/tmp/lineage_stage ] || S=/data/local/tmp/lineage_stage
rm -rf /data/local/tmp/oneos_rec_pull && mkdir /data/local/tmp/oneos_rec_pull &&
cp \$S/data/oneos_rec_*.mp4 /data/local/tmp/oneos_rec_pull/ && chmod 755 /data/local/tmp/oneos_rec_pull && chmod 644 /data/local/tmp/oneos_rec_pull/*'"
    mkdir -p "$OUT/rec"
    ${ADB:-adb} -s "$SERIAL" pull /data/local/tmp/oneos_rec_pull/. "$OUT/rec/"
    ${ADB:-adb} -s "$SERIAL" shell "su -c 'rm -rf /data/local/tmp/oneos_rec_pull'"
    ls -l "$OUT/rec"
fi
