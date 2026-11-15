#!/usr/bin/env bash
# Builds assets/OneLineageDisplayOverlay.apk (see AndroidManifest.xml for why).
# Needs ANDROID_SDK_ROOT (or ANDROID_HOME) with build-tools and an android-36
# (or ANDROID_PLATFORM) platform, JDK 17, and the project's debug keystore.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/AppData/Local/Android/Sdk}}"
BT="$SDK/build-tools/${BUILD_TOOLS_VERSION:-$(ls "$SDK/build-tools" | sort -V | tail -n 1)}"
JAR="$SDK/platforms/${ANDROID_PLATFORM:-android-36}/android.jar"
KS="${KEYSTORE:-$ROOT/keystore/debug.keystore}"
OUT="$ROOT/assets/OneLineageDisplayOverlay.apk"
tool() {  # SDK tools are .exe/.bat on Windows
    for c in "$BT/$1" "$BT/$1.exe" "$BT/$1.bat"; do [ -f "$c" ] && { echo "$c"; return; }; done
    echo "missing $1 in $BT" >&2; exit 1
}
AAPT2=$(tool aapt2) ZIPALIGN=$(tool zipalign) APKSIGNER=$(tool apksigner)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
"$AAPT2" compile --dir "$HERE/res" -o "$W/res.zip"
"$AAPT2" link -I "$JAR" --manifest "$HERE/AndroidManifest.xml" -o "$W/base.apk" "$W/res.zip"
"$ZIPALIGN" -f -p 4 "$W/base.apk" "$W/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass "pass:${KEYSTORE_PASS:-android}" \
    --ks-key-alias "${KEY_ALIAS:-androiddebugkey}" --key-pass "pass:${KEY_PASS:-android}" \
    --out "$OUT" "$W/aligned.apk"
rm -f "$OUT.idsig"
echo "Built $OUT"
