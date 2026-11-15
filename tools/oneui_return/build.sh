#!/bin/bash
# Builds OneUIReturn.apk: the small "Go back to One UI" app installed inside PixelOS.
#   JAVA_HOME=/path/to/jdk-17 ANDROID_HOME=/path/to/sdk tools/oneui_return/build.sh
set -e
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/AppData/Local/Android/Sdk}}"
BT="$SDK/build-tools/${BUILD_TOOLS_VERSION:-34.0.0}"
JAR="$SDK/platforms/${ANDROID_PLATFORM:-android-34}/android.jar"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
B="$HERE/build"
OUT="${OUT_APK:-$ROOT/assets/OneUIReturn.apk}"
ext() { [ -e "$BT/$1.exe" ] && echo "$BT/$1.exe" || { [ -e "$BT/$1.bat" ] && echo "$BT/$1.bat" || echo "$BT/$1"; }; }

rm -rf "$B"; mkdir -p "$B/gen" "$B/classes" "$B/dex"
cd "$HERE"
"$(ext aapt2)" compile --dir res -o "$B/res.zip"
"$(ext aapt2)" link -I "$JAR" --manifest AndroidManifest.xml -o "$B/base.apk" --java "$B/gen" "$B/res.zip"
"$JAVA_HOME/bin/javac" -source 1.8 -target 1.8 -nowarn -cp "$JAR" -d "$B/classes" \
    src/com/eggdog/oneui/ReturnActivity.java "$B/gen/com/eggdog/oneui/R.java"
"$(ext d8)" --lib "$JAR" --min-api 31 --output "$B/dex" "$B/classes/com/eggdog/oneui"/*.class
(cd "$B/dex" && "$JAVA_HOME/bin/jar" uf0 "$B/base.apk" classes.dex)
"$(ext zipalign)" -f -p 4 "$B/base.apk" "$B/aligned.apk"
"$(ext apksigner)" sign --ks "$ROOT/keystore/debug.keystore" --ks-pass pass:android \
    --ks-key-alias androiddebugkey --key-pass pass:android --out "$OUT" "$B/aligned.apk"
rm -rf "$B"
echo "Built $OUT"
