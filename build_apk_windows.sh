#!/bin/bash
# Windows (Git Bash) counterpart of build_apk.sh. Same steps; Windows-named SDK
# tools, and `jar uf0` instead of `zip` (Git Bash ships no zip binary).
set -e

# JAVA_HOME may point at a JRE (no javac); fall back to the known JDK then.
[ -x "$JAVA_HOME/bin/javac" ] || [ -x "$JAVA_HOME/bin/javac.exe" ] || JAVA_HOME="/c/Program Files/Java/jdk-21.0.11"
SDK="${ANDROID_HOME:-$HOME/AppData/Local/Android/Sdk}"
SDK_TOOLS="$SDK/build-tools/36.0.0"
PLATFORM_JAR="$SDK/platforms/android-36/android.jar"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
OUT_APK="$BUILD_DIR/OneHyper.apk"

echo "=== 1. Cleaning & preparing build directories ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/gen" "$BUILD_DIR/classes" "$BUILD_DIR/dex"

cd "$PROJECT_DIR"

echo "=== 2. Compiling resources with aapt2 ==="
"$SDK_TOOLS/aapt2.exe" compile --dir res -o "$BUILD_DIR/compiled_res.zip"

echo "=== 3. Linking resources with aapt2 ==="
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
    src/com/wewaffles/onehyper/MainActivity.java \
    "$BUILD_DIR/gen/com/wewaffles/onehyper/R.java"

echo "=== 5. Generating Dalvik Executable (classes.dex) with d8 ==="
"$SDK_TOOLS/d8.bat" \
    --lib "$PLATFORM_JAR" \
    --output "$BUILD_DIR/dex" \
    "$BUILD_DIR/classes/com/wewaffles/onehyper"/*.class

echo "=== 6. Packaging classes.dex into APK ==="
(cd "$BUILD_DIR/dex" && "$JAVA_HOME/bin/jar" uf0 "$BUILD_DIR/base.apk" classes.dex)

echo "=== 7. Aligning APK with zipalign ==="
"$SDK_TOOLS/zipalign.exe" -f -p 4 "$BUILD_DIR/base.apk" "$BUILD_DIR/aligned.apk"

KEYSTORE="$PROJECT_DIR/keystore/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
    mkdir -p "$PROJECT_DIR/keystore"
    "$JAVA_HOME/bin/keytool" -genkey -v \
        -keystore "$KEYSTORE" \
        -storepass android \
        -alias androiddebugkey \
        -keypass android \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=OneHyper,O=WeWaffles,C=US"
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
