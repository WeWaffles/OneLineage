#!/usr/bin/env bash
# Builds the native helpers into assets/ (static aarch64, no runtime deps).
# Needs the Android NDK: set ANDROID_NDK_HOME, or have it under
# $ANDROID_SDK_ROOT/ndk/<version> (the newest is used).
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
NDK="${ANDROID_NDK_HOME:-}"
if [[ -z "$NDK" && -n "$SDK" && -d "$SDK/ndk" ]]; then
    NDK="$SDK/ndk/$(ls "$SDK/ndk" | sort -V | tail -n 1)"
fi
[[ -n "$NDK" && -d "$NDK" ]] || { echo "Set ANDROID_NDK_HOME (or ANDROID_SDK_ROOT with an ndk/ folder)." >&2; exit 1; }
HOST_TAG=$(ls "$NDK/toolchains/llvm/prebuilt" | head -n 1)
BIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
CC="$BIN/clang"
[[ -x "$CC" || -x "$CC.exe" ]] || { echo "clang not found in $BIN" >&2; exit 1; }
SYSROOT="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/sysroot"
"$CC" --target=aarch64-linux-android34 --sysroot="$SYSROOT" -static -O2 -Wall -Wextra -Wno-unused-parameter \
    -pthread -o "$PROJECT_DIR/assets/ol_bridge" "$PROJECT_DIR/native/ol_bridge/ol_bridge.c"
"$BIN/llvm-strip" "$PROJECT_DIR/assets/ol_bridge" 2>/dev/null || true
echo "Built assets/ol_bridge"
