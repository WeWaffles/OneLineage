#!/bin/sh
# Build switcher/assets/OneOSEdmStub.dex from OneOSEdmStub.java.
#
#   switcher/patches/build_edm_stub.sh
#
# The dex is committed (like switcher/assets/zygote_exec and
# switcher/probe-av/avprobe.apk): the app ships it with the session scripts
# (sessionScripts in app/build.gradle.kts), so no package set has to be rebuilt
# for it. Re-run this after changing the .java and commit both.
#
# Needs ANDROID_HOME (default /opt/android-sdk): a platform's android.jar to
# compile against, and d8 from the build tools. --min-api 31 covers every phone
# OneOS runs on (Android 12 and newer).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SDK=${ANDROID_HOME:-/opt/android-sdk}

AJ=$(ls -d "$SDK"/platforms/* 2>/dev/null | sort -V | tail -1)/android.jar
[ -f "$AJ" ] || { echo "no android.jar under $SDK/platforms" >&2; exit 1; }
D8=$(ls "$SDK"/build-tools/*/d8 2>/dev/null | sort -V | tail -1)
[ -n "$D8" ] || { echo "no d8 under $SDK/build-tools" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/classes"

javac -nowarn --release 17 -classpath "$AJ" -d "$WORK/classes" "$HERE/OneOSEdmStub.java"
"$D8" --release --min-api 31 --lib "$AJ" --output "$WORK" "$WORK"/classes/*.class
mv "$WORK/classes.dex" "$ROOT/switcher/assets/OneOSEdmStub.dex"

echo "built switcher/assets/OneOSEdmStub.dex ($(stat -c%s "$ROOT/switcher/assets/OneOSEdmStub.dex") bytes)"
echo "android.jar: $AJ"
echo "d8:          $D8"
