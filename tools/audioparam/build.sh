#!/usr/bin/env bash
# Builds assets/ol_audioparam.dex (see src/.../Main.java for why).
# Needs ANDROID_SDK_ROOT (or ANDROID_HOME) with build-tools and an android-36
# (or ANDROID_PLATFORM) platform, and JDK 17.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/AppData/Local/Android/Sdk}}"
BT="$SDK/build-tools/${BUILD_TOOLS_VERSION:-$(ls "$SDK/build-tools" | sort -V | tail -n 1)}"
JAR="$SDK/platforms/${ANDROID_PLATFORM:-android-36}/android.jar"
OUT="$ROOT/assets/ol_audioparam.dex"
D8="$BT/d8"
for c in "$BT/d8" "$BT/d8.bat" "$BT/d8.exe"; do [ -f "$c" ] && D8="$c"; done
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/classes" "$W/dex"
javac -source 1.8 -target 1.8 -cp "$JAR" -d "$W/classes" $(find "$HERE/src" -name '*.java') 2>&1 | grep -v "warning: \[options\]" || true
"$D8" --lib "$JAR" --min-api 34 --output "$W/dex" $(find "$W/classes" -name '*.class')
cp "$W/dex/classes.dex" "$OUT"
echo "Built $OUT"
