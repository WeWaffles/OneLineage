#!/bin/sh
# framework_patched.jar for a Pixel (AOSP) guest: the image's framework.jar
# with One UI's camera transaction codes (switcher/patches/pixel_camera_abi.py,
# table switcher/patches/host_camera.txt from scripts/aidl-table.py on One UI's
# framework.jar). Only the dex files the patcher changed are rebuilt; the rest
# of the jar is the image's, byte for byte (as make-overlays.sh does for the
# other jars). Nothing is written when the guest's tables already agree.
#
# Usage: scripts/patch-framework-camera.sh <framework.jar> <out dir>
#   writes <out dir>/framework_patched.jar (or removes it) and appends its
#   sha256 line to <out dir>/guards.txt when that file exists and lacks it.
# make-overlays.sh calls it for a Pixel image; for a set whose image is no
# longer on the server, call it with the jar pulled from the phone's stage.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$1" ] && [ -d "$2" ] || { echo "usage: $0 <framework.jar> <out dir>" >&2; exit 2; }
# Absolute paths: the zip step runs inside a temp dir.
JAR=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); OUT=$(cd "$2" && pwd)
APKTOOL=${APKTOOL:-$(ls "$ROOT"/mysticgsi/tools/apktool/*.jar | head -1)}
TABLE="$ROOT/switcher/patches/host_camera.txt"
[ -f "$TABLE" ] || { echo "$TABLE missing (scripts/aidl-table.py on One UI's framework.jar)" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
java -jar "$APKTOOL" d -q -f -r -o "$WORK/fw" "$JAR"
DIRS=$(python3 -I "$ROOT/switcher/patches/pixel_camera_abi.py" "$WORK/fw" "$TABLE")
if [ -z "$DIRS" ]; then
    rm -f "$OUT/framework_patched.jar"
    sed -i '/ framework_patched\.jar$/d' "$OUT/guards.txt" 2>/dev/null || true
    echo "framework_patched.jar: not needed (the guest's camera tables are One UI's)"
    exit 0
fi
java -jar "$APKTOOL" b -q -o "$WORK/fw-rebuilt.jar" "$WORK/fw"
cp "$JAR" "$OUT/framework_patched.jar"
for d in $DIRS; do
    DEX="$(echo "$d" | sed 's/^smali_//; s/^smali$/classes/').dex"
    rm -rf "$WORK/dex" && mkdir -p "$WORK/dex"
    unzip -q -o "$WORK/fw-rebuilt.jar" "$DEX" -d "$WORK/dex"
    (cd "$WORK/dex" && zip -q -0 "$OUT/framework_patched.jar" "$DEX")
    echo "built $OUT/framework_patched.jar (replaced $DEX)"
done
chmod 644 "$OUT/framework_patched.jar"
python3 -I "$ROOT/scripts/check-dex.py" "$OUT/framework_patched.jar"
if [ -f "$OUT/guards.txt" ]; then
    grep -v ' framework_patched\.jar$' "$OUT/guards.txt" > "$OUT/guards.txt.tmp"; mv "$OUT/guards.txt.tmp" "$OUT/guards.txt"
    (cd "$OUT" && sha256sum framework_patched.jar) >> "$OUT/guards.txt"
    echo "guards.txt: framework_patched.jar listed"
fi
