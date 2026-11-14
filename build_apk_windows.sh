#!/bin/bash
# Windows (Git Bash) counterpart of build_apk.sh. Same steps; Windows-named SDK
# tools (.exe/.bat), and `jar uf0` instead of `zip` (Git Bash ships no zip binary).
# Needs a JDK 17 (javac -source/-target 1.8 is gone in newer JDKs).
#   JAVA_HOME=/path/to/jdk-17 ANDROID_HOME=/path/to/sdk ./build_apk_windows.sh
set -e

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/AppData/Local/Android/Sdk}}"
SDK_TOOLS="$SDK/build-tools/${BUILD_TOOLS_VERSION:-34.0.0}"
PLATFORM_JAR="$SDK/platforms/${ANDROID_PLATFORM:-android-34}/android.jar"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
OUT_APK="${OUT_APK:-$PROJECT_DIR/out/OneLineage.apk}"

if [ ! -x "$JAVA_HOME/bin/javac" ] && [ ! -x "$JAVA_HOME/bin/javac.exe" ]; then
    echo "Set JAVA_HOME to a JDK 17." >&2; exit 1
fi
for f in aapt2.exe d8.bat zipalign.exe apksigner.bat; do
    [ -e "$SDK_TOOLS/$f" ] || { echo "Missing $SDK_TOOLS/$f" >&2; exit 1; }
done
[ -f "$PLATFORM_JAR" ] || { echo "Missing $PLATFORM_JAR" >&2; exit 1; }

echo "=== 1. Preparing build directories ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/gen" "$BUILD_DIR/classes" "$BUILD_DIR/dex" "$(dirname "$OUT_APK")"
cd "$PROJECT_DIR"

echo "=== 2. Compiling resources ==="
"$SDK_TOOLS/aapt2.exe" compile --dir res -o "$BUILD_DIR/compiled_res.zip"

echo "=== 3. Linking resources ==="
"$SDK_TOOLS/aapt2.exe" link \
    -I "$PLATFORM_JAR" \
    --manifest AndroidManifest.xml \
    -o "$BUILD_DIR/base.apk" \
    --java "$BUILD_DIR/gen" \
    "$BUILD_DIR/compiled_res.zip" \
    -A assets

echo "=== 4. Compiling Java sources ==="
"$JAVA_HOME/bin/javac" -source 1.8 -target 1.8 -nowarn \
    -cp "$PLATFORM_JAR" \
    -d "$BUILD_DIR/classes" \
    src/com/wewaffles/onelineage/MainActivity.java \
    "$BUILD_DIR/gen/com/wewaffles/onelineage/R.java"

echo "=== 5. Generating Dalvik executable ==="
"$SDK_TOOLS/d8.bat" \
    --lib "$PLATFORM_JAR" \
    --output "$BUILD_DIR/dex" \
    "$BUILD_DIR/classes/com/wewaffles/onelineage"/*.class

echo "=== 6. Packaging classes.dex ==="
(cd "$BUILD_DIR/dex" && "$JAVA_HOME/bin/jar" uf0 "$BUILD_DIR/base.apk" classes.dex)

echo "=== 7. Aligning APK ==="
"$SDK_TOOLS/zipalign.exe" -f -p 4 "$BUILD_DIR/base.apk" "$BUILD_DIR/aligned.apk"

KEYSTORE="${KEYSTORE:-$PROJECT_DIR/keystore/debug.keystore}"
if [ ! -f "$KEYSTORE" ]; then
    echo "Creating development keystore: $KEYSTORE"
    mkdir -p "$(dirname "$KEYSTORE")"
    "$JAVA_HOME/bin/keytool" -genkey -v \
        -keystore "$KEYSTORE" \
        -storepass android \
        -alias androiddebugkey \
        -keypass android \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=OneLineage Development,O=OneLineage,C=US"
fi

"$SDK_TOOLS/apksigner.bat" sign \
    --ks "$KEYSTORE" \
    --ks-pass pass:android \
    --ks-key-alias androiddebugkey \
    --key-pass pass:android \
    --out "$OUT_APK" \
    "$BUILD_DIR/aligned.apk"

echo "=== BUILD SUCCESSFUL ==="
echo "Output APK: $OUT_APK"
ls -la "$OUT_APK"
