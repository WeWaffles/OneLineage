#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CALLER_DIR="$PWD"
BUILD_DIR="$PROJECT_DIR/build"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-34.0.0}"
ANDROID_PLATFORM="${ANDROID_PLATFORM:-android-34}"
OUT_APK="${OUT_APK:-$PROJECT_DIR/out/OneLineage.apk}"
KEYSTORE="${KEYSTORE:-$PROJECT_DIR/keystore/debug.keystore}"
KEYSTORE_PASS="${KEYSTORE_PASS:-android}"
KEY_ALIAS="${KEY_ALIAS:-androiddebugkey}"
KEY_PASS="${KEY_PASS:-$KEYSTORE_PASS}"

if [[ "$OUT_APK" != /* ]]; then
    OUT_APK="$CALLER_DIR/$OUT_APK"
fi
if [[ "$KEYSTORE" != /* ]]; then
    KEYSTORE="$CALLER_DIR/$KEYSTORE"
fi

if [[ -n "${JAVA_HOME:-}" ]]; then
    export PATH="$JAVA_HOME/bin:$PATH"
fi

if [[ -z "$ANDROID_SDK_ROOT" ]]; then
    echo "Set ANDROID_SDK_ROOT (or ANDROID_HOME) to your Android SDK directory." >&2
    exit 1
fi

SDK_TOOLS="$ANDROID_SDK_ROOT/build-tools/$BUILD_TOOLS_VERSION"
PLATFORM_JAR="$ANDROID_SDK_ROOT/platforms/$ANDROID_PLATFORM/android.jar"

for tool in aapt2 d8 zipalign apksigner; do
    if [[ ! -x "$SDK_TOOLS/$tool" ]]; then
        echo "Missing executable: $SDK_TOOLS/$tool" >&2
        exit 1
    fi
done

if [[ ! -f "$PLATFORM_JAR" ]]; then
    echo "Missing Android platform jar: $PLATFORM_JAR" >&2
    exit 1
fi

for tool in javac zip keytool; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required command not found in PATH: $tool" >&2
        exit 1
    fi
done

echo "=== 1. Preparing build directories ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/gen" "$BUILD_DIR/classes" "$BUILD_DIR/dex" "$(dirname -- "$OUT_APK")"

cd "$PROJECT_DIR"

echo "=== 2. Compiling resources ==="
"$SDK_TOOLS/aapt2" compile --dir res -o "$BUILD_DIR/compiled_res.zip"

echo "=== 3. Linking resources ==="
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
    src/com/wewaffles/onelineage/MainActivity.java \
    "$BUILD_DIR/gen/com/wewaffles/onelineage/R.java"

echo "=== 5. Generating Dalvik executable ==="
"$SDK_TOOLS/d8" \
    --lib "$PLATFORM_JAR" \
    --output "$BUILD_DIR/dex" \
    "$BUILD_DIR/classes/com/wewaffles/onelineage"/*.class

echo "=== 6. Packaging classes.dex ==="
(cd "$BUILD_DIR/dex" && zip -u "$BUILD_DIR/base.apk" classes.dex)

echo "=== 7. Aligning APK ==="
"$SDK_TOOLS/zipalign" -v -p 4 "$BUILD_DIR/base.apk" "$BUILD_DIR/aligned.apk"

if [[ ! -f "$KEYSTORE" ]]; then
    echo "Creating development keystore: $KEYSTORE"
    mkdir -p "$(dirname -- "$KEYSTORE")"
    keytool -genkey -v \
        -keystore "$KEYSTORE" \
        -storepass "$KEYSTORE_PASS" \
        -alias "$KEY_ALIAS" \
        -keypass "$KEY_PASS" \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=OneLineage Development,O=OneLineage,C=US"
fi

"$SDK_TOOLS/apksigner" sign \
    --ks "$KEYSTORE" \
    --ks-pass "pass:$KEYSTORE_PASS" \
    --ks-key-alias "$KEY_ALIAS" \
    --key-pass "pass:$KEY_PASS" \
    --out "$OUT_APK" \
    "$BUILD_DIR/aligned.apk"

echo "=== BUILD SUCCESSFUL ==="
echo "Output APK: $OUT_APK"
ls -lh "$OUT_APK"
