#!/usr/bin/env bash
# Build the OneLineage QEMU-milestone XNU kernel from the pinned patch series.
#
# macOS only: the build needs Xcode and blacktop/darwin-xnu-build, which
# supplies mig (built from bootstrap_cmds) and downloads the matching Kernel
# Debug Kit for the private headers. The output is a kernel image for offline
# QEMU work. Nothing here touches a phone, a boot partition, or a running
# Android kernel.
#
#   bash xnu/build_xnu.sh            # build (qemu profile by default)
#   bash xnu/build_xnu.sh --check    # environment preflight only
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIES="$ROOT/xnu/series.json"
PATCH_DIR="$ROOT/xnu/patches"
ADAPT_DIR="$ROOT/xnu/patches-onelineage"
TOOLS="$ROOT/tools/xnu"
WORK="${ONELINEAGE_XNU_WORK:-$ROOT/build/xnu-build}"
OUT="$ROOT/build/xnu"
LOG="$WORK/build.log"
# qemu: PL011 bootstrap console for QEMU validation (default).
# phone: panel framebuffer console; still non-executing, still not authorized.
PROFILE="${ONELINEAGE_XNU_PROFILE:-qemu}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

case "$PROFILE" in
  qemu) PROFILE_FLAGS="-DSWEET_QEMU_PROFILE" ;;
  phone) PROFILE_FLAGS="" ;;
  *) die "unknown ONELINEAGE_XNU_PROFILE '$PROFILE' (use qemu or phone)" ;;
esac

# Report the exact failing command: without this, a `set -e` exit inside a
# pipeline shows up only as "Process completed with exit code 1".
set -E
trap 'status=$?; printf "error: line %s failed (exit %s): %s\n" "$LINENO" "$status" "$BASH_COMMAND" >&2' ERR

CHECK_ONLY=0
for argument in "$@"; do
  case "$argument" in
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $argument" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "XNU is built on macOS only (this host is $(uname -s))"
command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

pin() {
  python3 - "$SERIES" "$1" <<'PY'
import json
import sys

series = json.load(open(sys.argv[1], encoding="utf-8"))
print(series["build"][sys.argv[2]])
PY
}

DXB_REPO="$(pin dxb_repo)"
DXB_SHA="$(pin dxb_sha)"
MACOS_VERSION="$(pin macos_version)"
KERNEL_CONFIG="$(pin kernel_config)"
MACHINE_CONFIG="$(pin machine_config)"
ARCH_CONFIG="$(pin arch_config)"

mkdir -p "$WORK"
say "verifying the vendored series and the $PROFILE adaptations against the manifest"
python3 "$TOOLS/verify_xnu_series.py" --verify-only --profile "$PROFILE" \
  --json "$WORK/series-report.json"

[[ -n "$(xcode-select -p 2>/dev/null || true)" ]] || die "select an Xcode installation with xcode-select"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
[[ -d "$DEVELOPER_DIR" ]] || die "DEVELOPER_DIR does not exist: $DEVELOPER_DIR"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[[ -n "$SDK_PATH" && -d "$SDK_PATH" ]] || die "no macOS SDK for $DEVELOPER_DIR"
xcrun --sdk macosx --find clang >/dev/null 2>&1 || die "clang was not found in the selected SDK"
say "Xcode: $DEVELOPER_DIR"
say "SDK:   $SDK_PATH"

# Two checks that used to live here were wrong for this harness, and made a
# working machine look broken:
#   * an SDK mig is not required - build.sh builds mig/migcom from
#     bootstrap_cmds and rewrites makedefs to use its own copies;
#   * the Kernel.framework private headers the kernel compiles against come
#     from a Kernel Debug Kit, not from the SDK, and build.sh downloads the
#     matching KDK (needs sudo) when it is absent.
# `find` on a missing directory exits 1; under `set -o pipefail` that would
# abort the script with no message, which is exactly how the first CI run died.
KDK_COUNT=0
if [[ -d /Library/Developer/KDKs ]]; then
  KDK_COUNT="$(find /Library/Developer/KDKs -maxdepth 1 -name '*.kdk' -print | wc -l | tr -d ' ')"
fi
if [[ "$KDK_COUNT" -eq 0 ]]; then
  say "no Kernel Debug Kit installed; build.sh will download the macOS $MACOS_VERSION KDK (needs sudo)"
else
  say "Kernel Debug Kits present: $KDK_COUNT"
fi
if ! xcrun --sdk macosx --find mig >/dev/null 2>&1; then
  say "no SDK mig; build.sh builds one from bootstrap_cmds"
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  say "preflight passed: series, adaptations, Xcode, SDK and clang are in place"
  say "not checked here: the KDK download, network access and the compile itself"
  exit 0
fi

DXB="$WORK/dxb"
if [[ ! -d "$DXB/.git" ]]; then
  say "fetching darwin-xnu-build at $DXB_SHA"
  git init -q "$DXB"
fi
git -C "$DXB" fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA"
git -C "$DXB" checkout -q FETCH_HEAD
HEAD_SHA="$(git -C "$DXB" rev-parse HEAD)"
[[ "$HEAD_SHA" == "$DXB_SHA" ]] || die "darwin-xnu-build is at $HEAD_SHA, expected $DXB_SHA"

say "installing the pinned series and $PROFILE adaptations into the build harness"
cp "$PATCH_DIR"/*.patch "$DXB/patches/"
# build.sh applies patches in sorted filename order, so the adaptations need a
# name that sorts after the pinned 0001-0018 range. The prefix exists only in
# the build harness; the vendored names and hashes stay authoritative.
for patch in "$ADAPT_DIR"/*.patch; do
  cp "$patch" "$DXB/patches/zz-$(basename "$patch")"
done
# libfirehose_kernel is built arm64e-only; the ported kernel is plain arm64.
sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' "$DXB/build.sh"
grep -q 'VALID_ARCHS="x86_64 arm64e arm64"' "$DXB/build.sh" \
  || die "could not widen libfirehose_kernel architectures in build.sh"

say "building $KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG ($PROFILE profile) on macOS $MACOS_VERSION (log: $LOG)"
# build.sh's exit status is handled explicitly below, so keep the trap quiet here.
trap - ERR
set +e
( cd "$DXB" && MACOS_VERSION="$MACOS_VERSION" KERNEL_CONFIG="$KERNEL_CONFIG" \
    ARCH_CONFIG="$ARCH_CONFIG" MACHINE_CONFIG="$MACHINE_CONFIG" \
    SWEET_PROFILE_FLAGS="$PROFILE_FLAGS" bash build.sh ) 2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -e
trap 'status=$?; printf "error: line %s failed (exit %s): %s\n" "$LINENO" "$status" "$BASH_COMMAND" >&2' ERR

# build.sh silently skips a patch it cannot apply, so a kernel can be produced
# with part of the series missing. Treat that as a failed build, not a warning.
say "confirming that the whole series was applied"
MISSING=""
for patch in "$PATCH_DIR"/*.patch; do
  name="$(basename "$patch")"
  grep -qF "Applying patch: " "$LOG" && grep -qF "$name" "$LOG" || MISSING="$MISSING $name"
done
for patch in "$ADAPT_DIR"/*.patch; do
  name="zz-$(basename "$patch")"
  grep -qF "Applying patch: " "$LOG" && grep -qF "$name" "$LOG" || MISSING="$MISSING $name"
done
[[ -z "$MISSING" ]] || die "these patches never applied, so the build is invalid:$MISSING"

[[ "$STATUS" -eq 0 ]] || die "build.sh exited $STATUS; see $LOG"

# `make install` puts kernel.<config>.<machine> under DSTROOT (fakeroot); the
# object tree keeps a copy too. Checks both, because which one survives depends
# on how far build.sh got.
KERNEL=""
for candidate in "$DXB/fakeroot/System/Library/Kernels"/kernel.* "$DXB/build/xnu.obj"/kernel.*; do
  if [[ -f "$candidate" ]]; then
    KERNEL="$candidate"
    break
  fi
done
[[ -n "$KERNEL" ]] || die "build.sh produced no kernel image (looked in fakeroot/System/Library/Kernels and build/xnu.obj)"

mkdir -p "$OUT"
TARGET="$OUT/$(basename "$KERNEL")"
cp "$KERNEL" "$TARGET"

say "structure check"
python3 "$TOOLS/inspect_macho.py" "$TARGET" || die "the produced kernel is not an inspectable ARM64 Mach-O image"

say "kernel: $TARGET ($PROFILE profile, SWEET_PROFILE_FLAGS='$PROFILE_FLAGS')"
shasum -a 256 "$TARGET"
say "next: generate the QEMU ADT, pack it with tools/xnu/build_payload.py, then run the QEMU harness"
