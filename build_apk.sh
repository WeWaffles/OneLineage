#!/bin/bash
set -e

export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
export PATH="$JAVA_HOME/bin:$PATH"

BUILD_DIR="/Users/waffles/.gemini/antigravity/scratch/LineageSwitcher/build"
SDK_TOOLS="/Users/waffles/Library/Android/sdk/build-tools/34.0.0"
PLATFORM_JAR="/Users/waffles/Library/Android/sdk/platforms/android-34/android.jar"
PROJECT_DIR="/Users/waffles/.gemini/antigravity/scratch/LineageSwitcher"
OUT_APK="/Users/waffles/Downloads/OneHyper.apk"

echo "=== 1. Cleaning & preparing build directories ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/gen" "$BUILD_DIR/classes" "$BUILD_DIR/dex"

cd "$PROJECT_DIR"

echo "=== 2. Compiling resources with aapt2 ==="
"$SDK_TOOLS/aapt2" compile --dir res -o "$BUILD_DIR/compiled_res.zip"

echo "=== 3. Linking resources with aapt2 ==="
"$SDK_TOOLS/aapt2" link \
    -I "$PLATFORM_JAR" \
    --manifest AndroidManifest.xml \
    -o "$BUILD_DIR/base.apk" \
    --java "$BUILD_DIR/gen" \
    "$BUILD_DIR/compiled_res.zip" \
    -A assets

echo "=== 4. Compiling Java sources ==="
javac -source 1.8 -target 1.8 \
    -cp "$PLATFORM_JAR" \
    -d "$BUILD_DIR/classes" \
    src/com/wewaffles/onehyper/MainActivity.java \
    "$BUILD_DIR/gen/com/wewaffles/onehyper/R.java"

echo "=== 5. Generating Dalvik Executable (classes.dex) with d8 ==="
"$SDK_TOOLS/d8" \
    --lib "$PLATFORM_JAR" \
    --output "$BUILD_DIR/dex" \
    "$BUILD_DIR/classes/com/wewaffles/onehyper"/*.class

echo "=== 6. Packaging classes.dex into APK ==="
cd "$BUILD_DIR/dex"
zip -u "$BUILD_DIR/base.apk" classes.dex
cd "$PROJECT_DIR"

echo "=== 7. Aligning APK with zipalign ==="
"$SDK_TOOLS/zipalign" -v -p 4 "$BUILD_DIR/base.apk" "$BUILD_DIR/aligned.apk"

KEYSTORE="$PROJECT_DIR/keystore/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
    mkdir -p "$PROJECT_DIR/keystore"
    keytool -genkey -v \
        -keystore "$KEYSTORE" \
        -storepass android \
        -alias androiddebugkey \
        -keypass android \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=OneHyper,O=WeWaffles,C=US"
fi

"$SDK_TOOLS/apksigner" sign \
    --ks "$KEYSTORE" \
    --ks-pass pass:android \
    --ks-key-alias androiddebugkey \
    --key-pass pass:android \
    --out "$OUT_APK" \
    "$BUILD_DIR/aligned.apk"

echo "=== BUILD SUCCESSFUL ==="
echo "Output APK: $OUT_APK"
ls -la "$OUT_APK"
