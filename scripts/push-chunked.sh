#!/bin/sh
# Push a large file over a flaky adb tunnel in fixed-size pieces, retrying each
# piece until it lands with the right size, then reassemble it on the phone.
# Pieces already on the phone are skipped, so the script can just be rerun.
#
# Usage: scripts/push-chunked.sh <local file> <remote file>
set -e
SERIAL="${ANDROID_SERIAL:-127.0.0.1:5555}"
CHUNK_MB="${CHUNK_MB:-128}"
SRC="$1"; DST="$2"
[ -f "$SRC" ] && [ -n "$DST" ] || { echo "usage: $0 <local file> <remote file>" >&2; exit 2; }

adb_() { adb -s "$SERIAL" "$@"; }
PARTS="$DST.parts"
SIZE=$(stat -c %s "$SRC")
CHUNK=$((CHUNK_MB * 1024 * 1024))
N=$(( (SIZE + CHUNK - 1) / CHUNK ))
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

adb_ shell "mkdir -p $PARTS"
i=0
while [ $i -lt $N ]; do
    name=$(printf 'part%05d' $i)
    want=$CHUNK
    [ $i -eq $((N - 1)) ] && want=$((SIZE - i * CHUNK))
    tries=0
    while :; do
        have=$(adb_ shell "stat -c %s $PARTS/$name 2>/dev/null" 2>/dev/null | tr -d '\r')
        [ "$have" = "$want" ] && break
        tries=$((tries + 1))
        [ $tries -le 20 ] || { echo "giving up on $name" >&2; exit 1; }
        [ -f "$TMP/$name" ] || dd if="$SRC" of="$TMP/$name" bs=1M skip=$((i * CHUNK_MB)) count=$CHUNK_MB status=none
        if ! adb_ push "$TMP/$name" "$PARTS/$name" >/dev/null 2>&1; then
            echo "$name: push failed (try $tries), reconnecting"
            phone-connect >/dev/null 2>&1 || sleep 10
        fi
    done
    rm -f "$TMP/$name"
    i=$((i + 1))
    echo "$name done ($i/$N)"
done

echo "reassembling on the phone..."
adb_ shell "cat $PARTS/part* > $DST.tmp && mv -f $DST.tmp $DST && rm -rf $PARTS"
got=$(adb_ shell "stat -c %s $DST" | tr -d '\r')
[ "$got" = "$SIZE" ] || { echo "size mismatch after reassembly: $got != $SIZE" >&2; exit 1; }
echo "pushed $SRC -> $DST ($SIZE bytes)"
