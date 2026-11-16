#!/usr/bin/env bash
# Builds assets/OneLineageDisplayOverlay.apk and assets/OneLineageSystemUIOverlay.apk
# (see each AndroidManifest.xml for why).
# Needs ANDROID_SDK_ROOT (or ANDROID_HOME) with build-tools and an android-36
# (or ANDROID_PLATFORM) platform, JDK 17, and the project's debug keystore.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/AppData/Local/Android/Sdk}}"
BT="$SDK/build-tools/${BUILD_TOOLS_VERSION:-$(ls "$SDK/build-tools" | sort -V | tail -n 1)}"
JAR="$SDK/platforms/${ANDROID_PLATFORM:-android-36}/android.jar"
KS="${KEYSTORE:-$ROOT/keystore/debug.keystore}"
tool() {  # SDK tools are .exe/.bat on Windows
    for c in "$BT/$1" "$BT/$1.exe" "$BT/$1.bat"; do [ -f "$c" ] && { echo "$c"; return; }; done
    echo "missing $1 in $BT" >&2; exit 1
}
AAPT2=$(tool aapt2) ZIPALIGN=$(tool zipalign) APKSIGNER=$(tool apksigner)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
build() {  # build <source dir> <output apk>
    rm -rf "$W"/*
    "$AAPT2" compile --dir "$1/res" -o "$W/res.zip"
    "$AAPT2" link -I "$JAR" --manifest "$1/AndroidManifest.xml" -o "$W/base.apk" "$W/res.zip"
    "$ZIPALIGN" -f -p 4 "$W/base.apk" "$W/aligned.apk"
    "$APKSIGNER" sign --ks "$KS" --ks-pass "pass:${KEYSTORE_PASS:-android}"         --ks-key-alias "${KEY_ALIAS:-androiddebugkey}" --key-pass "pass:${KEY_PASS:-android}"         --out "$2" "$W/aligned.apk"
    rm -f "$2.idsig"
    echo "Built $2"
}
build "$HERE" "$ROOT/assets/OneLineageDisplayOverlay.apk"
build "$HERE/systemui" "$ROOT/assets/OneLineageSystemUIOverlay.apk"
