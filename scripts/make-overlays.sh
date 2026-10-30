#!/bin/sh
# Build the framework overlays that guest_prepare.sh bind-mounts over the
# guest image (services_patched.jar etc.), from the GSI image itself.
#
# Only the dex files that contain a patched class are rebuilt; the rest of each
# jar is copied byte for byte from the image.
#
# Usage: scripts/make-overlays.sh <system.img> [outdir]   (default out/overlays)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG="$1"
OUT="${2:-$ROOT/out/overlays}"
APKTOOL=${APKTOOL:-$(ls "$ROOT"/mysticgsi/tools/apktool/*.jar 2>/dev/null | ls /opt/homebrew/Cellar/apktool/*/libexec/apktool_*.jar 2>/dev/null | head -1)}
# aapt2, zipalign, apksigner and android.jar for the checks and static RROs below.
SDK="${ANDROID_HOME:-${HOME}/Library/Android/sdk}"
BT=$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)
AJ=$(ls "$SDK"/platforms/android-*/android.jar | sort -V | tail -1)
DEBUGFS=${DEBUGFS:-$(command -v debugfs || find /opt/homebrew/Cellar/e2fsprogs -name debugfs 2>/dev/null | head -1 || echo /usr/sbin/debugfs)}
# A file the image has (ColorOS's own jars are not in a Pixel image).
in_image() { "$DEBUGFS" -R "stat $1" "$IMG" 2>&1 | grep -q '^Inode:'; }
[ -f "$IMG" ] || { echo "usage: $0 <system.img> [outdir]" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
# Absolute: the zip steps below run in their own directories.
OUT=$(cd "$OUT" && pwd)

# vold: the guest's own vold registers "gvld" instead of "vold" (run 44). Up to
# run 43 it took over "vold" and android.system.vold.IVold/default in the shared
# servicemanager; One UI's vold kept running without its names and cannot be
# restarted (init.rc: reboot_on_failure), so only a reboot gave One UI its
# storage back (docs/inplace-return.md). Only the builds pinned below, by
# sha256; done before services.jar, whose patch (patches/guest_own_vold.py)
# goes with it. Offsets are the Pixel 17 (yogi) build's, then ColorOS 17
# CP2A.260605.016's (the Find N6 and Find X9 Ultra images carry the same vold
# and service.incremental.so):
# - vold 0xde12 / 0x104e7 "vold" -> "gvld": the String16
#   VoldNativeService::start() passes to addService (adrp 0x65100 + add
#   0x65104 / adrp 0x79174 + add 0x79178); the other 9 references are
#   async_safe log tags in forked children. 4 bytes: "gvld" has no '/' or '.',
#   so servicemanager wants no VINTF declaration for it.
# - vold 0x64ac8 / 0x78b64 "tbz w19, #0, +0xd4" -> "b +0xd4":
#   VendorVoldNativeService::try_start always takes its "not declared" path
#   (returns OK), so the guest never registers android.system.vold.IVold/
#   default. Not renamed: a VINTF name servicemanager refuses unless the
#   manifest declares it.
# - service.incremental.so 0x64129 / 0x6536c "vold" -> "gvld": both
#   IncrementalService lookups (adr, and adrp + add with String16(s, 4)); the
#   guest system_server loads it (run 43: incfs v2).
# Function addresses from each binary's .gnu_debugdata symbols; segments: file
# offset == vaddr in all four files. The crashrecovery APEX is pinned too: its
# RescueParty is the guest's one call left that reaches One UI's "vold"
# (RecoverySystem.rebootPromptAndWipeUserData), and only while RescueParty is
# on (AOSP's isDisabled() in both builds), which guest_start.sh checks. On
# ColorOS, OPPO's OplusStorageManagerFeature looks up "vold" too
# (oplus-services.jar, guest_own_vold.py --oplus below). Other images are not
# patched and their guest vold keeps "vold" (no return without a reboot).
# "gvld" falls to service_contexts' catch-all default_android_service, which
# only a permissive session may add and find.
rm -f "$OUT/vold_patched" "$OUT/service.incremental_patched.so"
"$DEBUGFS" -R "dump /system/bin/vold $WORK/vold" "$IMG" 2>/dev/null
"$DEBUGFS" -R "dump /system/lib64/service.incremental.so $WORK/service.incremental.so" "$IMG" 2>/dev/null
"$DEBUGFS" -R "dump /system/apex/com.google.android.crashrecovery.apex $WORK/crashrecovery-google.apex" "$IMG" 2>/dev/null
"$DEBUGFS" -R "dump /system/apex/com.android.crashrecovery.apex $WORK/crashrecovery-aosp.apex" "$IMG" 2>/dev/null
"$DEBUGFS" -R "dump /system/apex/com.google.android.crashrecovery_compressed.apex $WORK/crashrecovery-google-compressed.apex" "$IMG" 2>/dev/null
"$DEBUGFS" -R "dump /system/apex/com.android.crashrecovery.capex $WORK/crashrecovery-aosp.capex" "$IMG" 2>/dev/null
python3 -I - "$WORK" "$OUT/vold_patched" "$OUT/service.incremental_patched.so" <<'PYEOF'
import hashlib, os, sys
work, vold_out, inc_out = sys.argv[1:4]
# The NULs either side: the whole string, not a suffix of a longer one.
NAME = (b"\0vold\0", b"\0gvld\0")
TRY_START = (bytes.fromhex("b3060036"), bytes.fromhex("35000014"))
BUILDS = [
    ("Pixel 17 (yogi)", {
        "vold": "5ecfb2f67a941129a382a150a865d01ad62898d534dafc102ac1fab832b335b7",
        "service.incremental.so": "3add0c259ba1e76378359d556d792136f96ce75197c99ff9d3d7fe850d8e4a92",
        "crashrecovery-google.apex": "fc82e88e3234efc0db0fff5da07e66005f6530e930671a42ac64788421793947",
    }, [("vold", 0xde11, NAME), ("vold", 0x64ac8, TRY_START), ("service.incremental.so", 0x64128, NAME)]),
    # The Pixel 11 Pro (kodiak) image of the same build: the same vold and
    # service.incremental.so, a crashrecovery APEX packaged differently whose
    # service-crashrecovery.jar decompiles to the same smali as yogi's.
    ("Pixel 17 (kodiak)", {
        "vold": "5ecfb2f67a941129a382a150a865d01ad62898d534dafc102ac1fab832b335b7",
        "service.incremental.so": "3add0c259ba1e76378359d556d792136f96ce75197c99ff9d3d7fe850d8e4a92",
        "crashrecovery-google.apex": "8ae8917117e528bc876f8658633a65ed370b32ac1f8b77180909a94a5d1f87b9",
    }, [("vold", 0xde11, NAME), ("vold", 0x64ac8, TRY_START), ("service.incremental.so", 0x64128, NAME)]),
    # The Pixel 9 Pro XL (komodo) image, CP3A.261005.005: the same code at other
    # offsets. start() takes the string at 0xdbcb (adrp 0x653f0 + add 0x653f4; the
    # other 9 references are umount/remountStorageDirs log tags), try_start's tbz
    # on isDeclared() is at +0x68 (0x64db8), service.incremental.so has both
    # lookups (adr 0xc0f7c, adrp + add 0xc3870 with String16(s, 4)) on the string
    # at 0x64328. Its crashrecovery APEX (compressed) has the same
    # RescueParty.isDisabled() as yogi's.
    ("Pixel 17 (komodo)", {
        "vold": "498c6d86fb7232e1b7d486ac6202672aab60837dd1e665bfc303ba14ff31c16a",
        "service.incremental.so": "b519753a86b5389434b170434913e8216c263de73606dd368d1098b04d583e9c",
        "crashrecovery-google.apex": "4c47853948d58166facca39a6b58d00bf47302e38b6e8a8989c622a0e15c6521",
    }, [("vold", 0xdbca, NAME), ("vold", 0x64db8, TRY_START), ("service.incremental.so", 0x64327, NAME)]),
    ("ColorOS 17 CP2A.260605.016 (Find N6, Find X9 Ultra)", {
        "vold": "3df4d13bb9636cb9833a6ee2027d189c6acfd25b0404058ca130afb164a55896",
        "service.incremental.so": "43ae83091df41f9cd43fa985e7b629e09ba9f581d93336d0efb38dd05de1bab8",
        "crashrecovery-aosp.apex": "a8396ec6bebe9511a701315964314aa8a755bef32d20cf4458293ed319bfdcf1",
    }, [("vold", 0x104e6, NAME), ("vold", 0x78b64, TRY_START), ("service.incremental.so", 0x6536b, NAME)]),
    # The Find X9 Ultra IN (global) build of the same release: its vold is
    # the CN one laid out 0x2000 later (the same instructions; start() takes
    # the string at 0x7b178, try_start's tbz is at +0x68 as in the CN build),
    # service.incremental.so has the string and both lookups where the CN one
    # has them, and its compressed crashrecovery APEX holds the same
    # service-crashrecovery.jar as Pixel's yogi, byte for byte.
    ("ColorOS 17 CP2A.260605.016 IN (Find X9 Ultra global)", {
        "vold": "7fe53478f0e482e64a680bd12f6ead83f0501d62cab5d6de085bfeec8acecc5f",
        "service.incremental.so": "25979ef93ee4b1a781c16adc783febdba2462563e5a7e69f4ba24d011d4b8427",
        "crashrecovery-google-compressed.apex": "304784481c167b3d196c9ba8ce8d45ea7b59b04b2c061d0b19ed0a4e93574f50",
    }, [("vold", 0x104e6, NAME), ("vold", 0x7ab64, TRY_START), ("service.incremental.so", 0x6536b, NAME)]),
    # Project Infinity-X 4.1 for the Find X9 Ultra (lighthouse, CP2A.260605.016),
    # built from source: its own layout. start() takes the string at 0xe164
    # (adrp 0xe000 + add 0x164), try_start's tbz w19 is at 0x64d8c (+0xd4, as
    # above), service.incremental.so has the string at 0x646c1 with both
    # lookups (adr at 0xc051c, adrp + add at 0xc2a7c). Its compressed
    # crashrecovery APEX (.capex) holds the same service-crashrecovery.jar as
    # Pixel's yogi, byte for byte.
    ("Infinity-X 4.1 CP2A.260605.016 (Find X9 Ultra)", {
        "vold": "7bc11b794ac19af6a2e1e7dc2bcf9baad3f3a673079f574b90132469a303c613",
        "service.incremental.so": "c964e27681a3632a7f83acb1698acffa572b3ece773690bc64444dff7bfaf7a7",
        "crashrecovery-aosp.capex": "1c4fa1a8417b233765db1621f3911b66de230049c39b248f116c3d18a8920ca6",
    }, [("vold", 0xe163, NAME), ("vold", 0x64d8c, TRY_START), ("service.incremental.so", 0x646c0, NAME)]),
    # HyperOS OS4.0 (Xiaomi lhasa, 2026-10): start() takes "vold" at 0xf3fd
    # (adrp 0xf000 + add 0x3fd at 0x6e8f4, the binary's only "\0vold\0"),
    # try_start's tbz w19, #0, +0xd4 is at 0x6e2d4, and service.incremental.so
    # has the string at 0x64746 with its two lookups (adr at 0xc0794, adrp + add
    # at 0xc2e28). Its crashrecovery APEX (com.android.crashrecovery.capex) has
    # AOSP's RescueParty.isDisabled (persist.sys.disable_rescue), and the wipe
    # behind it. The seventh HyperOS run's guest vold took "vold", and the
    # return could only reboot ("vold is not registered").
    ("HyperOS OS4.0 (lhasa)", {
        "vold": "06c00894fa5ce1bb1c6bc7821ef60ae18907ed9d9a213d37987cdfe633c798f7",
        "service.incremental.so": "e7da297ddedc625df330317c2321b5a2fd25f4dd2535f9c65a1490b5b8d6687d",
        "crashrecovery-aosp.capex": "d31bc1ccbb9bd60d2c78f0bd045cbb194838f936aafe2b551ab5d8344c9f2cd8",
    }, [("vold", 0xf3fc, NAME), ("vold", 0x6e2d4, TRY_START), ("service.incremental.so", 0x64745, NAME)]),
]
def read(name):
    p = os.path.join(work, name)
    return bytearray(open(p, "rb").read()) if os.path.isfile(p) else bytearray()
def sha(d):
    return hashlib.sha256(d).hexdigest()
data = {n: read(n) for n in ("vold", "service.incremental.so", "crashrecovery-google.apex", "crashrecovery-aosp.apex", "crashrecovery-google-compressed.apex", "crashrecovery-aosp.capex")}
build = next((b for b in BUILDS if all(sha(data[n]) == want for n, want in b[1].items())), None)
if build is None:
    have = ", ".join("%s %s" % (n, sha(d)[:12] if d else "missing") for n, d in data.items())
    print("vold: not a build this was written against (%s): not patched, the guest vold keeps the name vold" % have)
    sys.exit(0)
for name, off, (old, new) in build[2]:
    d = data[name]
    if d[off:off + len(old)] != old:
        sys.exit("%s: unexpected bytes at %#x, not patching" % (name, off))
    d[off:off + len(old)] = new
open(vold_out, "wb").write(data["vold"])
open(inc_out, "wb").write(data["service.incremental.so"])
print("built %s for %s (registers gvld, not android.system.vold.IVold/default)" % (vold_out, build[0]))
print("built %s (looks up gvld)" % inc_out)
PYEOF
VOLD_GVLD=0
if [ -f "$OUT/vold_patched" ]; then
    chmod 755 "$OUT/vold_patched"
    chmod 644 "$OUT/service.incremental_patched.so"
    VOLD_GVLD=1
fi

# services.jar: LocalDisplayAdapter falls back to the active mode when
# SurfaceFlinger has no desired mode specs (see patches/display_mode_specs.py).
"$DEBUGFS" -R "dump /system/framework/services.jar $WORK/services.jar" "$IMG" 2>/dev/null
java -jar "$APKTOOL" d -q -f -r -o "$WORK/services" "$WORK/services.jar"
SMALI=$(grep -rl "Desired display mode specs from SurfaceFlinger are null" "$WORK/services" | head -1)
[ -n "$SMALI" ] || { echo "LocalDisplayAdapter not found in services.jar" >&2; exit 1; }
python3 -I "$ROOT/switcher/patches/display_mode_specs.py" "$SMALI"
DISPLAY_DIR="$(basename "$(dirname "$(dirname "$(dirname "$(dirname "$(dirname "$SMALI")")")")")")"
# And never let the guest send user-key calls to the host's vold
# (patches/guest_no_vold_keys.py).
KEY_DIRS=$(python3 -I "$ROOT/switcher/patches/guest_no_vold_keys.py" "$WORK/services")
# Skip the host vendor's APEX system services (patches/skip_host_apex_services.py).
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/skip_host_apex_services.py" "$WORK/services")"
# Never let the guest reboot or shut down the shared phone (patches/guest_power_guards.py).
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_power_guards.py" "$WORK/services")"
# Never let the guest delete or rewrite the phone's data through the shared
# installd, vold or keystore2 (patches/guest_storage_guards.py).
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_storage_guards.py" "$WORK/services")"
# Send installd calls with One UI's transaction codes, block the rest
# (patches/guest_installd_abi.py, table from scripts/host-installd-table.sh).
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_installd_abi.py" "$WORK/services" "$ROOT/switcher/patches/host_installd.txt")"
# No kernel crash from the guest's watchdog (patches/guest_no_sysrq_crash.py).
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_no_sysrq_crash.py" "$WORK/services")"
# The guest never touches the phone's weaver slots, where One UI's lock
# protectors live (patches/guest_no_weaver.py).
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_no_weaver.py" "$WORK/services")"
# Nor removes templates from the phone's fingerprint and face sensors, where
# One UI's enrolments live (patches/guest_no_biometric_cleanup.py).
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_no_biometric_cleanup.py" "$WORK/services")"
# The phone's gatekeeper (screen lock), FRP partition and apexd stay One UI's;
# guest apps get app ids from 15000 (no keystore namespace shared with One UI's
# apps) and the guest makes no users or profiles (their per-user keys share
# aliases with One UI's). patches/guest_no_gatekeeper.py, guest_pdb_readonly.py,
# guest_no_apex_installs.py, guest_app_id_offset.py, guest_no_new_users.py.
for g in guest_no_gatekeeper guest_pdb_readonly guest_no_apex_installs guest_app_id_offset guest_no_new_users; do
    NEW=$(python3 -I "$ROOT/switcher/patches/$g.py" "$WORK/services")
    KEY_DIRS="$KEY_DIRS $NEW"
done
# The guest's own idmap2d instead of One UI's (patches/guest_own_idmap.py).
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_own_idmap.py" "$WORK/services")"
# A WebView zygote that cannot start is logged, not fatal (S24 Ultra, Find X9
# Ultra IN, session 77e7789e: system_server died 60 s into boot;
# patches/guest_webview_zygote_safe.py).
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_webview_zygote_safe.py" "$WORK/services")"
# A native-only service fails to start instead of waiting on One UI's
# zygote_next (S25 Ultra, Pixel 9 Pro XL, app 0.4.25: Chrome's renderer held
# every process start of the session; patches/guest_no_native_services.py).
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_no_native_services.py" "$WORK/services")"
# Samsung's VoLTE app (com.sec.imsservice) keeps android.uid.system in the guest,
# but only from the staged read-only path /system_ext/priv-app/OneOSSecIms
# (guest_prepare.sh, ONEOS_GUEST_SEC_IMS=1): verifySignatures admits that one
# package there despite its Samsung platform signature, and nothing else
# (patches/guest_sec_ims_signature.py, docs/samsung-ims-in-guest.md). Always
# applied; dormant unless such a package is staged at that path.
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_sec_ims_signature.py" "$WORK/services")"
# The wipe paths never delete the phone's secrets: Secretkeeper, the secure
# element, vold's storage and metadata keys (Infinity-X's duress wipe calls
# them directly; patches/guest_no_wipe_secrets.py). Before guest_own_vold.py.
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_no_wipe_secrets.py" "$WORK/services")"
# The guest's own vold as "gvld", with vold_patched above; no guest call left
# that reaches One UI's "vold" (patches/guest_own_vold.py).
if [ "$VOLD_GVLD" = 1 ]; then
    KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_own_vold.py" "$WORK/services")"
fi
# StorageManagerService waits for OPPO's DefragService, which never registers.
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/oplus_wait_for_service.py" "$WORK/services" --only DefragService)"
# Pixel's Comfort View as a color matrix, like Night Light (run 43: the switch
# did nothing; patches/comfort_view_bridge.py). Left out, with a warning, on an
# image without ColorDisplayService.setUp, and not run for ColorOS: its
# services.jar has the anchor too, but nothing there writes cv_enabled, so its
# system_server stays as it was.
if in_image /system/framework/oplus-services.jar; then
    echo "Comfort View bridge: ColorOS image, left out"
else
    KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/comfort_view_bridge.py" "$WORK/services" "$ROOT/switcher/patches/OneOSComfortView.smali")"
    # Window blur stays on when the phone is warm (owner, run 45): only the
    # thermal term leaves updateBlurEnabled(); Developer options and battery
    # saver still turn it off (patches/guest_blur_no_thermal.py).
    KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_blur_no_thermal.py" "$WORK/services")"
    echo "Window blur: not turned off by heat (BlurController.updateBlurEnabled)"
fi
# Qualcomm's display additions make a second built-in panel private, and the
# Z Fold's cover becomes display 0 when it folds: no app could use it
# (patches/qti_builtin_display_public.py; nothing in images without them).
KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/qti_builtin_display_public.py" "$WORK/services")"
# A dex the added OneOS classes push past 65536 method references (the Pixel 9
# Pro XL's classes2: 65568) gets them moved to a dex of their own after the
# last one: one jar, one class loader, so they keep their package access.
# Builds that fit are unchanged.
if ! java -jar "$APKTOOL" b -q -o "$WORK/rebuilt.jar" "$WORK/services" 2> "$WORK/apktool.err"; then
    FULL=$(sed -n 's/.*Could not smali folder: \(smali[_a-z0-9]*\).*/\1/p' "$WORK/apktool.err" | head -1)
    if [ -z "$FULL" ] || ! grep -q 'Unsigned short value out of range' "$WORK/apktool.err" ||
       [ -z "$(cd "$WORK/services/$FULL" && find . -name 'OneOS*.smali')" ]; then
        cat "$WORK/apktool.err" >&2
        exit 1
    fi
    LAST=$(ls -d "$WORK"/services/smali_classes* 2>/dev/null | sed 's/.*smali_classes//' | sort -n | tail -1)
    OWN="smali_classes$((${LAST:-1} + 1))"
    (cd "$WORK/services/$FULL" && find . -name 'OneOS*.smali') | while read -r f; do
        mkdir -p "$WORK/services/$OWN/$(dirname "$f")"
        mv "$WORK/services/$FULL/$f" "$WORK/services/$OWN/$f"
        echo "services.jar: $FULL is past 65536 method references, $f moved to $OWN"
    done
    java -jar "$APKTOOL" b -q -o "$WORK/rebuilt.jar" "$WORK/services"
    KEY_DIRS="$KEY_DIRS $OWN"
fi
cp "$WORK/services.jar" "$OUT/services_patched.jar"
for d in $(printf '%s\n' "$DISPLAY_DIR" $KEY_DIRS | sort -u); do
    DEX="$(echo "$d" | sed 's/^smali_//; s/^smali$/classes/').dex"
    rm -rf "$WORK/dex" && mkdir -p "$WORK/dex"
    unzip -q -o "$WORK/rebuilt.jar" "$DEX" -d "$WORK/dex"
    (cd "$WORK/dex" && zip -q -0 "$OUT/services_patched.jar" "$DEX")
    echo "built $OUT/services_patched.jar (replaced $DEX)"
done

# oplus-services.jar: waitForService -> checkService for OPPO-only services
# (patches/oplus_wait_for_service.py). Every dex it touched is replaced.
# Only in ColorOS images; without it guest_prepare.sh needs no second guard jar.
if in_image /system/framework/oplus-services.jar; then
    "$DEBUGFS" -R "dump /system/framework/oplus-services.jar $WORK/oplus-services.jar" "$IMG" 2>/dev/null
    java -jar "$APKTOOL" d -q -f -r -o "$WORK/oplus" "$WORK/oplus-services.jar"
    DIRS=$(python3 -I "$ROOT/switcher/patches/oplus_wait_for_service.py" "$WORK/oplus")
    # QSPM wait in GameGpuControlPanel, ctl.start dumpenvironment and gettpinfo (patches/oplus_boot_hangs.py).
    # (Each patcher in a plain assignment, so set -e stops the build when it fails.)
    NEW=$(python3 -I "$ROOT/switcher/patches/oplus_boot_hangs.py" "$WORK/oplus")
    DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    # Same storage guards as services.jar (patches/guest_storage_guards.py).
    NEW=$(python3 -I "$ROOT/switcher/patches/guest_storage_guards.py" "$WORK/oplus")
    DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    NEW=$(python3 -I "$ROOT/switcher/patches/guest_no_sysrq_crash.py" "$WORK/oplus")
    DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    NEW=$(python3 -I "$ROOT/switcher/patches/guest_no_wipe_secrets.py" "$WORK/oplus")
    DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    # With the guest vold as "gvld": OPPO's own "vold" lookup too
    # (OplusStorageManagerFeature, patches/guest_own_vold.py --oplus).
    if [ "$VOLD_GVLD" = 1 ]; then
        NEW=$(python3 -I "$ROOT/switcher/patches/guest_own_vold.py" --oplus "$WORK/oplus")
        DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    fi
    # OPPO's own IInstalld.Stub.asInterface() calls go through services.jar's
    # OneOSInstalldProxy too (patches/guest_installd_abi.py --callers).
    NEW=$(python3 -I "$ROOT/switcher/patches/guest_installd_abi.py" --callers "$WORK/oplus")
    DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    # Brightness on Samsung's panel (patches/samsung_backlight_curve.py).
    NEW=$(python3 -I "$ROOT/switcher/patches/samsung_backlight_curve.py" "$WORK/oplus" "$ROOT/switcher/patches/OneOSPanelBacklight.smali")
    DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)

    # OPPO's default runtime grants without CUST_LEVEL_LIST (patches/oplus_default_grants.py).
    NEW=$(python3 -I "$ROOT/switcher/patches/oplus_default_grants.py" "$WORK/oplus")
    DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    # No charge error warnings from the missing OPPO charger HAL's -1 (patches/oplus_battery_notify.py).
    NEW=$(python3 -I "$ROOT/switcher/patches/oplus_battery_notify.py" "$WORK/oplus")
    DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    java -jar "$APKTOOL" b -q -o "$WORK/oplus-rebuilt.jar" "$WORK/oplus"
    cp "$WORK/oplus-services.jar" "$OUT/oplus-services_patched.jar"
    for d in $DIRS; do
        DEX="$(echo "$d" | sed 's/^smali_//; s/^smali$/classes/').dex"
        rm -rf "$WORK/odex" && mkdir -p "$WORK/odex"
        unzip -q -o "$WORK/oplus-rebuilt.jar" "$DEX" -d "$WORK/odex"
        (cd "$WORK/odex" && zip -q -0 "$OUT/oplus-services_patched.jar" "$DEX")
        echo "built $OUT/oplus-services_patched.jar (replaced $DEX)"
    done
else
    rm -f "$OUT/oplus-services_patched.jar"
    echo "oplus-services.jar: not in the image, nothing to patch"
fi

# HyperOS: Xiaomi's miui-services.jar runs in the same system_server, with its
# own recovery, factory reset, preinstall and vold paths (patches/miui_guards.py,
# docs/hyperos.md), the storage guards and installd callers like
# oplus-services.jar's, and with "gvld" its two "vold" lookups
# (guest_own_vold.py --miui). apprecovery.proinstaller.jar (also on the system
# server class path) installs apps by itself: its InstallService does nothing
# (miui_guards.py --proinstaller). Only in HyperOS images; guest_prepare.sh
# refuses one without them.
MIUI_JAR=/system/system_ext/framework/miui-services.jar
PRO_JAR=/system/system_ext/framework/apprecovery.proinstaller.jar
if in_image $MIUI_JAR; then
    "$DEBUGFS" -R "dump $MIUI_JAR $WORK/miui-services.jar" "$IMG" 2>/dev/null
    java -jar "$APKTOOL" d -q -f -r -o "$WORK/miui" "$WORK/miui-services.jar"
    DIRS=$(python3 -I "$ROOT/switcher/patches/miui_guards.py" "$WORK/miui")
    NEW=$(python3 -I "$ROOT/switcher/patches/guest_storage_guards.py" "$WORK/miui")
    DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    NEW=$(python3 -I "$ROOT/switcher/patches/guest_installd_abi.py" --callers "$WORK/miui")
    DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    if [ "$VOLD_GVLD" = 1 ]; then
        NEW=$(python3 -I "$ROOT/switcher/patches/guest_own_vold.py" --miui "$WORK/miui")
        DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    fi
    # HAL extension casts (patches/hyperos_hal_ext.py): the vibrator's.
    NEW=$(python3 -I "$ROOT/switcher/patches/hyperos_hal_ext.py" --expect 1 "$WORK/miui" HalExtServices)
    DIRS=$(printf '%s\n' $DIRS $NEW | sort -u)
    java -jar "$APKTOOL" b -q -o "$WORK/miui-rebuilt.jar" "$WORK/miui"
    cp "$WORK/miui-services.jar" "$OUT/miui-services_patched.jar"
    for d in $DIRS; do
        DEX="$(echo "$d" | sed 's/^smali_//; s/^smali$/classes/').dex"
        rm -rf "$WORK/mdex" && mkdir -p "$WORK/mdex"
        unzip -q -o "$WORK/miui-rebuilt.jar" "$DEX" -d "$WORK/mdex"
        (cd "$WORK/mdex" && zip -q -0 "$OUT/miui-services_patched.jar" "$DEX")
        echo "built $OUT/miui-services_patched.jar (replaced $DEX)"
    done
    in_image $PRO_JAR || { echo "ERROR: $MIUI_JAR without $PRO_JAR: another HyperOS layout, not guarded" >&2; exit 1; }
    "$DEBUGFS" -R "dump $PRO_JAR $WORK/proinstaller.jar" "$IMG" 2>/dev/null
    java -jar "$APKTOOL" d -q -f -r -o "$WORK/pro" "$WORK/proinstaller.jar"
    DIRS=$(python3 -I "$ROOT/switcher/patches/miui_guards.py" --proinstaller "$WORK/pro")
    java -jar "$APKTOOL" b -q -o "$WORK/pro-rebuilt.jar" "$WORK/pro"
    cp "$WORK/proinstaller.jar" "$OUT/apprecovery.proinstaller_patched.jar"
    for d in $DIRS; do
        DEX="$(echo "$d" | sed 's/^smali_//; s/^smali$/classes/').dex"
        rm -rf "$WORK/mdex" && mkdir -p "$WORK/mdex"
        unzip -q -o "$WORK/pro-rebuilt.jar" "$DEX" -d "$WORK/mdex"
        (cd "$WORK/mdex" && zip -q -0 "$OUT/apprecovery.proinstaller_patched.jar" "$DEX")
        echo "built $OUT/apprecovery.proinstaller_patched.jar (replaced $DEX)"
    done
    # miui-wifi-service.jar (MiuiWifiService in system_server): its casts of
    # the Wi-Fi HALs' extensions (supplicant, hardware, hostapd) to Xiaomi
    # interfaces, which One UI's HALs answer with Samsung's
    # (patches/hyperos_hal_ext.py; the third HyperOS run died in
    # ISupplicantXm.registerCallback).
    WIFI_JAR=/system/system_ext/framework/miui-wifi-service.jar
    in_image $WIFI_JAR || { echo "ERROR: $MIUI_JAR without $WIFI_JAR" >&2; exit 1; }
    "$DEBUGFS" -R "dump $WIFI_JAR $WORK/miui-wifi-service.jar" "$IMG" 2>/dev/null
    java -jar "$APKTOOL" d -q -f -r -o "$WORK/mwifi" "$WORK/miui-wifi-service.jar"
    DIRS=$(python3 -I "$ROOT/switcher/patches/hyperos_hal_ext.py" --expect 5 "$WORK/mwifi" HalExtWifi)
    java -jar "$APKTOOL" b -q -o "$WORK/mwifi-rebuilt.jar" "$WORK/mwifi"
    cp "$WORK/miui-wifi-service.jar" "$OUT/miui-wifi-service_patched.jar"
    for d in $DIRS; do
        DEX="$(echo "$d" | sed 's/^smali_//; s/^smali$/classes/').dex"
        rm -rf "$WORK/mdex" && mkdir -p "$WORK/mdex"
        unzip -q -o "$WORK/mwifi-rebuilt.jar" "$DEX" -d "$WORK/mdex"
        (cd "$WORK/mdex" && zip -q -0 "$OUT/miui-wifi-service_patched.jar" "$DEX")
        echo "built $OUT/miui-wifi-service_patched.jar (replaced $DEX)"
    done
    rm -rf "$WORK/mwifi" "$WORK/mwifi-rebuilt.jar"
    # miui-telephony-common.jar (com.android.phone): Xiaomi's IMS controller
    # without an IMS phone (patches/hyperos_telephony.py; the fourth HyperOS
    # run's phone process died on every service state poll).
    TEL_JAR=/system/system_ext/framework/miui-telephony-common.jar
    in_image $TEL_JAR || { echo "ERROR: $MIUI_JAR without $TEL_JAR" >&2; exit 1; }
    "$DEBUGFS" -R "dump $TEL_JAR $WORK/miui-telephony-common.jar" "$IMG" 2>/dev/null
    java -jar "$APKTOOL" d -q -f -r -o "$WORK/mtel" "$WORK/miui-telephony-common.jar"
    DIRS=$(python3 -I "$ROOT/switcher/patches/hyperos_telephony.py" "$WORK/mtel")
    java -jar "$APKTOOL" b -q -o "$WORK/mtel-rebuilt.jar" "$WORK/mtel"
    cp "$WORK/miui-telephony-common.jar" "$OUT/miui-telephony-common_patched.jar"
    for d in $DIRS; do
        DEX="$(echo "$d" | sed 's/^smali_//; s/^smali$/classes/').dex"
        rm -rf "$WORK/mdex" && mkdir -p "$WORK/mdex"
        unzip -q -o "$WORK/mtel-rebuilt.jar" "$DEX" -d "$WORK/mdex"
        (cd "$WORK/mdex" && zip -q -0 "$OUT/miui-telephony-common_patched.jar" "$DEX")
        echo "built $OUT/miui-telephony-common_patched.jar (replaced $DEX)"
    done
    rm -rf "$WORK/mtel" "$WORK/mtel-rebuilt.jar"
    # libaudiohal@aidl.so: HyperOS's audioserver waited for an audio HAL
    # adapter vendor extension that only One UI's own audioserver serves, and
    # a session stops it (patches/hyperos_audio_ext.py, sixth run: no sound).
    AH_LIB=/system/lib64/libaudiohal@aidl.so
    in_image $AH_LIB || { echo "ERROR: $MIUI_JAR without $AH_LIB" >&2; exit 1; }
    "$DEBUGFS" -R "dump $AH_LIB $WORK/libaudiohal_aidl.so" "$IMG" 2>/dev/null
    python3 -I "$ROOT/switcher/patches/hyperos_audio_ext.py" "$WORK/libaudiohal_aidl.so" "$OUT/libaudiohal_aidl_patched.so"
    rm -f "$WORK/libaudiohal_aidl.so"
    # socket_exec (switcher/native): guest_start.sh starts hyos_spawner with
    # it, the service that runs HyperOS's rust packages (the launcher).
    cp -f "$ROOT/switcher/native/bin/socket_exec" "$OUT/socket_exec"
    # framework.jar: Xiaomi's CameraStatus parcel back to AOSP's fields, as One
    # UI's cameraserver writes them (patches/hyperos_framework.py; the first
    # HyperOS run died in BiometricService on a null CameraStatus).
    FW_JAR=/system/framework/framework.jar
    in_image $FW_JAR || { echo "ERROR: $MIUI_JAR without $FW_JAR" >&2; exit 1; }
    # The camera transaction codes step further down builds on this jar (HYPEROS_FW).
    HYPEROS_FW=1
    "$DEBUGFS" -R "dump $FW_JAR $WORK/framework.jar" "$IMG" 2>/dev/null
    java -jar "$APKTOOL" d -q -f -r -o "$WORK/fw" "$WORK/framework.jar"
    DIRS=$(python3 -I "$ROOT/switcher/patches/hyperos_framework.py" "$WORK/fw")
    java -jar "$APKTOOL" b -q -o "$WORK/fw-rebuilt.jar" "$WORK/fw"
    cp "$WORK/framework.jar" "$OUT/framework_patched.jar"
    for d in $DIRS; do
        DEX="$(echo "$d" | sed 's/^smali_//; s/^smali$/classes/').dex"
        rm -rf "$WORK/mdex" && mkdir -p "$WORK/mdex"
        unzip -q -o "$WORK/fw-rebuilt.jar" "$DEX" -d "$WORK/mdex"
        (cd "$WORK/mdex" && zip -q -0 "$OUT/framework_patched.jar" "$DEX")
        echo "built $OUT/framework_patched.jar (replaced $DEX)"
    done
    rm -rf "$WORK/fw" "$WORK/fw-rebuilt.jar" "$WORK/framework.jar"
else
    rm -f "$OUT/miui-services_patched.jar" "$OUT/apprecovery.proinstaller_patched.jar" "$OUT/framework_patched.jar" "$OUT/miui-wifi-service_patched.jar" \
          "$OUT/miui-telephony-common_patched.jar" "$OUT/socket_exec" \
          "$OUT/libaudiohal_aidl_patched.so"
    echo "miui-services.jar: not in the image, nothing to patch"
fi


# product/framework/ims-ext-common.jar: QtiImsExtConnector retries a failed
# bind every 60 s instead of every 500 ms (patches/qti_ims_ext_backoff.py).
# Not a guard jar: guest_prepare.sh binds it only when it is there.
if in_image /system/product/framework/ims-ext-common.jar; then
    "$DEBUGFS" -R "dump /system/product/framework/ims-ext-common.jar $WORK/ims-ext-common.jar" "$IMG" 2>/dev/null
    java -jar "$APKTOOL" d -q -f -r -o "$WORK/imsext" "$WORK/ims-ext-common.jar"
    DIRS=$(python3 -I "$ROOT/switcher/patches/qti_ims_ext_backoff.py" "$WORK/imsext")
    java -jar "$APKTOOL" b -q -o "$WORK/imsext-rebuilt.jar" "$WORK/imsext"
    cp "$WORK/ims-ext-common.jar" "$OUT/ims-ext-common_patched.jar"
    for d in $DIRS; do
        DEX="$(echo "$d" | sed 's/^smali_//; s/^smali$/classes/').dex"
        rm -rf "$WORK/idex" && mkdir -p "$WORK/idex"
        unzip -q -o "$WORK/imsext-rebuilt.jar" "$DEX" -d "$WORK/idex"
        (cd "$WORK/idex" && zip -q -0 "$OUT/ims-ext-common_patched.jar" "$DEX")
        echo "built $OUT/ims-ext-common_patched.jar (replaced $DEX)"
    done
else
    rm -f "$OUT/ims-ext-common_patched.jar"
    echo "ims-ext-common.jar: not in the image, nothing to patch"
fi


# oplus-telephony-common.jar (system_ext, not on the boot class path, so the
# boot image stays valid): poll the signal strength every 20 s. Samsung's RIL
# sent the guest no currentSignalStrength indication in all of run 34 and AOSP
# polls only for opportunistic subscriptions, so both SIMs showed no bars
# (patches/guest_signal_poll.py). ONEOS_GUEST_SIGNAL_POLL=0 on the phone keeps
# ColorOS's jar (guest_prepare.sh).
if in_image /system/system_ext/framework/oplus-telephony-common.jar; then
    "$DEBUGFS" -R "dump /system/system_ext/framework/oplus-telephony-common.jar $WORK/oplus-telephony-common.jar" "$IMG" 2>/dev/null
    java -jar "$APKTOOL" d -q -f -r -o "$WORK/otc" "$WORK/oplus-telephony-common.jar"
    NEW=$(python3 -I "$ROOT/switcher/patches/guest_signal_poll.py" "$WORK/otc" "$ROOT/switcher/patches/OneOSSignalPoll.smali")
    java -jar "$APKTOOL" b -q -o "$WORK/otc-rebuilt.jar" "$WORK/otc"
    cp "$WORK/oplus-telephony-common.jar" "$OUT/oplus-telephony-common_patched.jar"
    for d in $NEW; do
        DEX="$(echo "$d" | sed 's/^smali_//; s/^smali$/classes/').dex"
        rm -rf "$WORK/tdex" && mkdir -p "$WORK/tdex"
        unzip -q -o "$WORK/otc-rebuilt.jar" "$DEX" -d "$WORK/tdex"
        (cd "$WORK/tdex" && zip -q -0 "$OUT/oplus-telephony-common_patched.jar" "$DEX")
        echo "built $OUT/oplus-telephony-common_patched.jar (replaced $DEX)"
    done
else
    rm -f "$OUT/oplus-telephony-common_patched.jar"
    echo "oplus-telephony-common.jar: not in the image, nothing to patch"
fi

# Signal bars in any other AOSP-based guest (run 43, Pixel 17): the same missing
# indication as ColorOS's run 34 (both SIMs at level 0 all session; Pixel's
# stacked dual-SIM icon at level 0 even looked like a row of "!"), but no
# OplusSignalSmooth to hook. TeleService's own TelephonyComponentFactory
# injection loads oneos-telephony.jar for the one component
# SignalStrengthController: OneOSTelephonyComponentFactory returns the image's
# controller and starts OneOSSignalPoll on it (patches/OneOSSignalPollAosp.smali,
# GET_SIGNAL_STRENGTH every 20 s with the screen on). The static RRO
# OneOSPhoneInjection.apk (switcher/overlays/phone_injection) names it in
# TeleService's xml/telephony_injection. No Google dex changes: telephony-common.jar
# is on the boot class path and in the boot image. guest_prepare.sh puts the jar
# in a read-only overlay layer on the guest's system_ext and the RRO in its
# /oem/overlay, only on the files oneos-telephony.sha256 names
# (ONEOS_GUEST_SIGNAL_POLL=0 leaves it out). Built only when (a) the image has
# telephony-common.jar and TeleService.apk, (b) is not ColorOS
# (oplus-telephony-common_patched.jar polls there), (c) TeleService's injection
# config is empty, (d) TeleService declares no overlayable resources (an /oem
# overlay may then override any), (e) no RRO in the image overrides that config
# (9 target com.android.phone in the Pixel image, TrebleDroid's among them), and
# (f) patches/aosp_signal_poll_check.py finds every class, member and message
# the jar relies on as expected: there is no ART verifier here, and
# check-dex.py below is not one.
INJ_TC=/system/framework/telephony-common.jar
INJ_TS=/system/priv-app/TeleService/TeleService.apk
INJ_RRO="$ROOT/switcher/overlays/phone_injection"
rm -f "$OUT/oneos-telephony.jar" "$OUT/oneos-telephony.sha256" "$OUT/OneOSPhoneInjection.apk"
INJ_WHY=""
if in_image /system/system_ext/framework/oplus-telephony-common.jar; then
    INJ_WHY="ColorOS image: oplus-telephony-common_patched.jar polls instead"
elif ! in_image "$INJ_TC" || ! in_image "$INJ_TS"; then
    INJ_WHY="no $INJ_TC or $INJ_TS in the image"
else
    "$DEBUGFS" -R "dump $INJ_TS $WORK/TeleService.apk" "$IMG" 2>/dev/null
    "$DEBUGFS" -R "dump $INJ_TC $WORK/telephony-common.jar" "$IMG" 2>/dev/null
    INJ_XML=$("$BT/aapt2" dump resources "$WORK/TeleService.apk" 2>/dev/null |
        grep -A1 ' xml/telephony_injection$' | sed -n 's/.*(file) \([^ ]*\) type=XML.*/\1/p' | head -1)
    if [ -z "$INJ_XML" ]; then
        INJ_WHY="TeleService.apk has no xml/telephony_injection"
    elif ! "$BT/aapt2" dump xmltree --file "$INJ_XML" "$WORK/TeleService.apk" > "$WORK/inj_xml.txt" 2>/dev/null ||
         ! grep -Eq '^ *A: jar=""( \(Raw: ""\))?$' "$WORK/inj_xml.txt" ||
         ! grep -Eq '^ *A: package=""( \(Raw: ""\))?$' "$WORK/inj_xml.txt"; then
        INJ_WHY="TeleService.apk's $INJ_XML is not empty:$(grep -E '^ *A: (jar|package)=' "$WORK/inj_xml.txt" | tr -s ' \n' ' ')"
    elif [ -n "$("$BT/aapt2" dump overlayable "$WORK/TeleService.apk" 2>/dev/null | head -n 3)" ]; then
        INJ_WHY="TeleService.apk declares overlayable resources"
    else
        INJ_PHONE_RROS=0
        for d in /system/product/overlay /system/overlay /system/system_ext/overlay; do
            in_image "$d" || continue
            rm -rf "$WORK/ovl" && mkdir -p "$WORK/ovl"
            "$DEBUGFS" -R "rdump $d $WORK/ovl" "$IMG" 2>/dev/null || true
            find "$WORK/ovl" -type f -name '*.apk' > "$WORK/ovl.txt"
            while read -r a; do
                "$BT/aapt2" dump badging "$a" 2>/dev/null | grep -q "targetPackage='com.android.phone'" || continue
                INJ_PHONE_RROS=$((INJ_PHONE_RROS + 1))
                if "$BT/aapt2" dump resources "$a" 2>/dev/null | grep -q ' xml/telephony_injection$'; then
                    INJ_WHY="$INJ_WHY${INJ_WHY:+, }$d/${a#"$WORK"/ovl/*/} overrides xml/telephony_injection"
                fi
            done < "$WORK/ovl.txt"
        done
        rm -rf "$WORK/ovl" "$WORK/ovl.txt"
        echo "signal poll injection: $INJ_PHONE_RROS RRO(s) in the image target com.android.phone"
        if [ -z "$INJ_WHY" ]; then
            # Another image's jar that apktool cannot read only leaves this out,
            # like every other reason here: not a failed build.
            if ! java -jar "$APKTOOL" d -q -f -r -o "$WORK/tc" "$WORK/telephony-common.jar"; then
                INJ_WHY="apktool could not decode telephony-common.jar"
            elif INJ_CHECK=$(python3 -I "$ROOT/switcher/patches/aosp_signal_poll_check.py" "$WORK/tc" 2>&1); then
                echo "$INJ_CHECK"
            else
                INJ_WHY="patches/aosp_signal_poll_check.py: $INJ_CHECK"
            fi
            rm -rf "$WORK/tc"
        fi
    fi
fi
if [ -n "$INJ_WHY" ]; then
    echo "signal poll injection: not built ($INJ_WHY)"
else
    mkdir -p "$WORK/inj/smali/oneos/telephony"
    cp "$ROOT/switcher/patches/OneOSTelephonyComponentFactory.smali" "$WORK/inj/smali/oneos/telephony/"
    cp "$ROOT/switcher/patches/OneOSSignalPollAosp.smali" "$WORK/inj/smali/oneos/telephony/OneOSSignalPoll.smali"
    printf '%s\n' "version: 3.0.3" "apkFileName: oneos-telephony.jar" "sdkInfo:" "  minSdkVersion: 29" \
        "doNotCompress:" "- dex" > "$WORK/inj/apktool.yml"
    java -jar "$APKTOOL" b -q -o "$OUT/oneos-telephony.jar" "$WORK/inj"
    # The files the jar was checked against, as paths in the guest's root:
    # guest_prepare.sh enables the injection only when the image has these.
    for f in "$INJ_TC" "$INJ_TS"; do
        echo "$(sha256sum < "$WORK/$(basename "$f")" | cut -d' ' -f1) ${f#/}"
    done > "$OUT/oneos-telephony.sha256"
    "$BT/aapt2" compile --dir "$INJ_RRO/res" -o "$WORK/inj_rro.zip"
    "$BT/aapt2" link -o "$WORK/inj_rro.apk" -I "$AJ" --manifest "$INJ_RRO/AndroidManifest.xml" \
        --min-sdk-version 35 --target-sdk-version 37 "$WORK/inj_rro.zip"
    # TeleService reads the component name verbatim: one text node, no whitespace.
    "$BT/aapt2" dump xmltree --file res/xml/telephony_injection.xml "$WORK/inj_rro.apk" > "$WORK/inj_rro_xml.txt"
    if ! grep -q "^ *T: 'com.android.internal.telephony.SignalStrengthController'\$" "$WORK/inj_rro_xml.txt" ||
       ! grep -Eq '^ *A: jar="/system_ext/framework/oneos-telephony\.jar"( \(Raw: .*\))?$' "$WORK/inj_rro_xml.txt" ||
       ! grep -Eq '^ *A: package="oneos\.telephony\.OneOSTelephonyComponentFactory"( \(Raw: .*\))?$' "$WORK/inj_rro_xml.txt"; then
        echo "phone_injection overlay: unexpected telephony_injection.xml:" >&2
        cat "$WORK/inj_rro_xml.txt" >&2
        exit 1
    fi
    "$BT/zipalign" -p -f 4 "$WORK/inj_rro.apk" "$WORK/inj_rro-aligned.apk"
    "$BT/apksigner" sign --ks "${KEYSTORE:-$HOME/.android/debug.keystore}" \
        --ks-pass pass:android --ks-key-alias androiddebugkey --key-pass pass:android \
        --out "$OUT/OneOSPhoneInjection.apk" "$WORK/inj_rro-aligned.apk"
    rm -f "$OUT/OneOSPhoneInjection.apk.idsig"
    echo "built $OUT/oneos-telephony.jar, oneos-telephony.sha256 and OneOSPhoneInjection.apk (signal poll through TeleService's TelephonyComponentFactory injection)"
fi
rm -rf "$WORK/inj" "$WORK/TeleService.apk" "$WORK/telephony-common.jar"

# A Pixel (AOSP) or ColorOS guest's camera calls with One UI's transaction codes
# (patches/pixel_camera_abi.py and pixel_camera_native.py, docs/pixel-guest.md
# "What differs"): the image's framework.jar as framework_patched.jar and its
# native client libraries as libcamera_client_patched.so and
# libcameracompatbilityinfo_patched.so (the legacy camera API and the NDK ride
# on those). guest_prepare.sh binds them and guards.txt pins them. ColorOS's
# ICameraService has Oplus methods and its own numbering (21-28), the same
# treatment as the Pixels'. scripts/patch-framework-camera.sh and
# patch-camera-native.sh do the same for a set whose image is no longer on the
# server, from files pulled from the phone.
# HyperOS (0.4.31): on top of its own framework_patched.jar (hyperos_framework.py's
# CameraStatus, made above in this run), so the set carries both.
if [ "${HYPEROS_FW:-0}" = 1 ] && [ -f "$OUT/framework_patched.jar" ]; then
    cp "$OUT/framework_patched.jar" "$WORK/framework-cam.jar"
fi
rm -f "$OUT/framework_patched.jar" "$OUT/libcamera_client_patched.so" "$OUT/libcameracompatbilityinfo_patched.so"
if in_image /system/framework/framework.jar; then
    [ -f "$WORK/framework-cam.jar" ] || "$DEBUGFS" -R "dump /system/framework/framework.jar $WORK/framework-cam.jar" "$IMG" 2>/dev/null
    "$ROOT/scripts/patch-framework-camera.sh" "$WORK/framework-cam.jar" "$OUT"
    rm -f "$WORK/framework-cam.jar"
fi
if in_image /system/lib64/libcamera_client.so && in_image /system/lib64/libcameracompatbilityinfo.so; then
    "$DEBUGFS" -R "dump /system/lib64/libcamera_client.so $WORK/libcamera_client.so" "$IMG" 2>/dev/null
    "$DEBUGFS" -R "dump /system/lib64/libcameracompatbilityinfo.so $WORK/libcameracompatbilityinfo.so" "$IMG" 2>/dev/null
    "$ROOT/scripts/patch-camera-native.sh" "$WORK/libcamera_client.so" "$WORK/libcameracompatbilityinfo.so" "$OUT"
    rm -f "$WORK/libcamera_client.so" "$WORK/libcameracompatbilityinfo.so"
fi

# ART rejects a whole class for an empty try range, which a patcher leaves when
# it drops the only call inside a try block (run 26: Installer, system_server
# died at boot). Fail the build instead.
JARS=""
for j in services_patched.jar oplus-services_patched.jar ims-ext-common_patched.jar oplus-telephony-common_patched.jar \
         oneos-telephony.jar miui-services_patched.jar apprecovery.proinstaller_patched.jar framework_patched.jar \
         miui-wifi-service_patched.jar miui-telephony-common_patched.jar; do
    [ -f "$OUT/$j" ] && JARS="$JARS $OUT/$j"
done
python3 -I "$ROOT/scripts/check-dex.py" $JARS

# The phone refuses jars that were not built with the guards above
# (guest_prepare.sh checks these hashes, and needs oplus-services_patched.jar
# whenever the image has oplus-services.jar, miui-services_patched.jar and
# apprecovery.proinstaller_patched.jar whenever it has miui-services.jar). vold_patched and
# service.incremental_patched.so are listed with the services_patched.jar that
# looks up "gvld": guest_prepare.sh binds all three or none of them.
{
    echo "# framework overlays built by scripts/make-overlays.sh with the storage, installd, power, sysrq, weaver, biometric, gatekeeper, pdb, apexd, appid15000, nousers, nativeservices and wipesecrets guards, and the secims carve-out (com.sec.imsservice kept in android.uid.system from /system_ext/priv-app/OneOSSecIms only)"
    [ "$VOLD_GVLD" = 1 ] && echo "# guest vold name: gvld (vold_patched, service.incremental_patched.so and services_patched.jar)"
    # HyperOS images (miui-services_patched.jar) and Pixel images list their
    # files in the order and with the notes each set was built with.
    if [ -f "$OUT/miui-services_patched.jar" ]; then
        echo "# HyperOS: miui-services_patched.jar and apprecovery.proinstaller_patched.jar (patches/miui_guards.py)"
        [ -f "$OUT/framework_patched.jar" ] && echo "# HyperOS: framework_patched.jar (patches/hyperos_framework.py, CameraStatus as One UI's cameraserver writes it; 0.4.31: and One UI's camera transaction codes, patches/pixel_camera_abi.py)"
        [ -f "$OUT/miui-wifi-service_patched.jar" ] && echo "# HyperOS: miui-wifi-service_patched.jar (patches/hyperos_hal_ext.py, Xiaomi's HAL extension casts only on Xiaomi's)"
        [ -f "$OUT/miui-telephony-common_patched.jar" ] && echo "# HyperOS: miui-telephony-common_patched.jar (patches/hyperos_telephony.py, the IMS controller without an IMS phone)"
        [ -f "$OUT/libcamera_client_patched.so" ] && echo "# libcamera_client_patched.so, libcameracompatbilityinfo_patched.so: the native camera client with One UI's codes (patches/pixel_camera_native.py)"
        (cd "$OUT" && sha256sum services_patched.jar $([ -f oplus-services_patched.jar ] && echo oplus-services_patched.jar) \
            miui-services_patched.jar apprecovery.proinstaller_patched.jar framework_patched.jar miui-wifi-service_patched.jar \
            miui-telephony-common_patched.jar \
            $([ "$VOLD_GVLD" = 1 ] && echo vold_patched service.incremental_patched.so) \
            $([ -f libcamera_client_patched.so ] && echo libcamera_client_patched.so) \
            $([ -f libcameracompatbilityinfo_patched.so ] && echo libcameracompatbilityinfo_patched.so))
    else
        [ -f "$OUT/framework_patched.jar" ] && echo "# framework_patched.jar: the image's framework.jar with One UI's camera transaction codes (patches/pixel_camera_abi.py)"
        [ -f "$OUT/libcamera_client_patched.so" ] && echo "# libcamera_client_patched.so, libcameracompatbilityinfo_patched.so: the native camera client with One UI's codes (patches/pixel_camera_native.py)"
        (cd "$OUT" && sha256sum services_patched.jar $([ -f oplus-services_patched.jar ] && echo oplus-services_patched.jar) \
            $([ "$VOLD_GVLD" = 1 ] && echo vold_patched service.incremental_patched.so) \
            $([ -f framework_patched.jar ] && echo framework_patched.jar) \
            $([ -f libcamera_client_patched.so ] && echo libcamera_client_patched.so) \
            $([ -f libcameracompatbilityinfo_patched.so ] && echo libcameracompatbilityinfo_patched.so))
    fi
} > "$OUT/guards.txt"

# surfaceflinger: skip the Qualcomm composer extension client, so every frame
# goes through the plain IComposerClient.executeCommands path. Samsung's
# composer answered ColorOS's qtiExecuteCommands batches with BAD_VALUE on
# every frame (black panel). At 0x470bc8 "cbz x8, 0x470c14" (no extension ->
# skip IQtiComposer3Client::fromBinder) becomes "b 0x470c14"; SurfaceFlinger
# then takes its own "Failed to get QtiComposer3Client service" fallback.
# Code segment: file offset == vaddr (LOAD 0x1d0000). Only for the exact builds
# below: the Find N6 and Find X9 Ultra CN images share one binary; the Find X9
# Ultra IN image (CPH2841IN) has the same code 0x5b0 later (0x471178, after
# AIBinder_getExtension, before IQtiComposer3Client::fromBinder), same bytes.
"$DEBUGFS" -R "dump /system/bin/surfaceflinger $WORK/surfaceflinger" "$IMG" 2>/dev/null
python3 -I - "$WORK/surfaceflinger" "$OUT/surfaceflinger_patched" <<'PYEOF'
import hashlib, os, sys
src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, "rb").read())
SITES = {"9896c0cba131": 0x470bc8, "a09087821954": 0x471178}
off = SITES.get(hashlib.sha1(data).hexdigest()[:12])
if off is None and b"IQtiComposer3Client" not in data:
    # Google's own build (Pixel image): no QTI composer client to skip.
    if os.path.exists(dst):
        os.remove(dst)
    print("surfaceflinger: no QTI composer client in this build, not patched (the image's runs)")
    sys.exit(0)
if off is None:
    sys.exit("surfaceflinger: unexpected build, not patching")
old, new = bytes.fromhex("680200b4"), bytes.fromhex("13000014")
if data[off:off + 4] != old:
    sys.exit("surfaceflinger: unexpected bytes at %#x, not patching" % off)
data[off:off + 4] = new
open(dst, "wb").write(data)
print("built %s (QTI composer client skipped)" % dst)
PYEOF
[ ! -f "$OUT/surfaceflinger_patched" ] || chmod 755 "$OUT/surfaceflinger_patched"

# com.oplus.wallpapers "Home screen, Lock screen & style": with type.fold the app
# uses its Find N6 inner-screen page, a 4x4 grid where every card is 2x2 = half
# the panel (run 30: 1072 px cards, "too zoomed in"). This static RRO
# (switcher/overlays/wallpapers_fold_grid) makes it 8x2, one row of four ~520 px
# cards; guest_prepare.sh binds it in the guest's /oem/overlay. Built only if
# the image's layout is still the 4x4 one it was written against.
RRO="$ROOT/switcher/overlays/wallpapers_fold_grid"
"$DEBUGFS" -R "dump /my_stock/priv-app/Wallpapers/Wallpapers.apk $WORK/Wallpapers.apk" "$IMG" 2>/dev/null
LAYOUT=$("$BT/aapt2" dump resources "$WORK/Wallpapers.apk" 2>/dev/null | grep -A1 ' layout/personal_card_fold_large_layout$' | sed -n 's/.*(file) \([^ ]*\) type=XML.*/\1/p')
if [ -n "$LAYOUT" ] && "$BT/aapt2" dump xmltree --file "$LAYOUT" "$WORK/Wallpapers.apk" | grep -q 'columnCount(0x[0-9a-f]*)=4'; then
    "$BT/aapt2" compile --dir "$RRO/res" -o "$WORK/rro.zip"
    "$BT/aapt2" link -o "$WORK/rro.apk" -I "$AJ" --manifest "$RRO/AndroidManifest.xml" \
        --min-sdk-version 35 --target-sdk-version 36 "$WORK/rro.zip"
    "$BT/zipalign" -p -f 4 "$WORK/rro.apk" "$WORK/rro-aligned.apk"
    "$BT/apksigner" sign --ks "${KEYSTORE:-$HOME/.android/debug.keystore}" \
        --ks-pass pass:android --ks-key-alias androiddebugkey --key-pass pass:android \
        --out "$OUT/OneOSWallpapersFoldGrid.apk" "$WORK/rro-aligned.apk"
    rm -f "$OUT/OneOSWallpapersFoldGrid.apk.idsig"
    echo "built $OUT/OneOSWallpapersFoldGrid.apk (Wallpapers fold grid 8x2)"
else
    rm -f "$OUT/OneOSWallpapersFoldGrid.apk"
    echo "Wallpapers.apk: fold card layout not as expected, grid overlay not built"
fi

# Pixel's status bar (run 42): SystemUIGoogle's StatusBarContentInsetsProvider
# leaves ongoing_appops_dot_min_padding (20dp, for the privacy dot) on the end
# side and only rounded_corner_content_padding on the start side, which points to
# the framework's 0dp here (Pixel's vendor overlay sets it; the guest runs on
# Samsung's vendor partition): the battery sat 47-60 px further from the right
# edge than the clock from the left, on both panels. This static RRO
# (switcher/overlays/pixel_statusbar, signed like the grid overlay) makes both
# paddings 8dp and keeps a 4dp end padding on the inner panel (sw600dp, 0dp in
# the image); guest_prepare.sh puts it in the guest's /oem/overlay when the
# guest has SystemUIGoogle. Built only when the image's SystemUIGoogle has the
# three dimens and declares no overlayable resources (an /oem overlay may then
# override any of them), and not when the image gives one of them a value for a
# configuration the overlay lacks and a phone panel can match: that target
# value would win over the overlay's (sw1000dp and up is ignored here).
SYSUI=/system/system_ext/priv-app/SystemUIGoogle/SystemUIGoogle.apk
SB_RRO="$ROOT/switcher/overlays/pixel_statusbar"
SB_DIMENS="rounded_corner_content_padding ongoing_appops_dot_min_padding status_bar_padding_end"
# "<name> <(config)>" for each of those dimens in an APK's resource dump.
sb_cfgs() {
    awk -v names=" $SB_DIMENS " '
        /^ *resource 0x/ { n = $3; cur = ""; if (sub(/^dimen\//, "", n) && index(names, " " n " ")) cur = n; next }
        cur != "" && /^ *\(/ { print cur, $1 }' "$1"
}
rm -f "$OUT/OneOSPixelStatusBar.apk"
if in_image "$SYSUI"; then
    "$DEBUGFS" -R "dump $SYSUI $WORK/SystemUIGoogle.apk" "$IMG" 2>/dev/null
    "$BT/aapt2" dump resources "$WORK/SystemUIGoogle.apk" > "$WORK/sysui_res.txt" 2>/dev/null || true
    SB_MISSING=""
    for d in $SB_DIMENS; do
        grep -q " dimen/$d\$" "$WORK/sysui_res.txt" || SB_MISSING="$SB_MISSING $d"
    done
    SB_OVERLAYABLE=$("$BT/aapt2" dump overlayable "$WORK/SystemUIGoogle.apk" 2>/dev/null | head -n 3) || true
    if [ -n "$SB_MISSING" ]; then
        echo "SystemUIGoogle.apk: no dimen$SB_MISSING, status bar overlay not built"
    elif [ -n "$SB_OVERLAYABLE" ]; then
        echo "SystemUIGoogle.apk declares overlayable resources, status bar overlay not built"
    else
        # No deduping: aapt2 drops the sw600dp value equal to the default one,
        # and the image's sw600dp 0dp would then win on the inner panel.
        "$BT/aapt2" compile --dir "$SB_RRO/res" -o "$WORK/sb.zip"
        "$BT/aapt2" link -o "$WORK/sb.apk" -I "$AJ" --manifest "$SB_RRO/AndroidManifest.xml" \
            --min-sdk-version 35 --target-sdk-version 36 --no-resource-deduping "$WORK/sb.zip"
        "$BT/aapt2" dump resources "$WORK/sb.apk" > "$WORK/sb_res.txt"
        sb_cfgs "$WORK/sb_res.txt" > "$WORK/sb_cfgs.txt"
        SB_UNCOVERED=$(sb_cfgs "$WORK/sysui_res.txt" | while read -r n c; do
            grep -qxF "$n $c" "$WORK/sb_cfgs.txt" && continue
            sw=$(echo "$c" | sed -n 's/^(sw\([0-9][0-9]*\)dp.*/\1/p')
            [ -n "$sw" ] && [ "$sw" -ge 1000 ] && continue
            printf ' %s%s' "$n" "$c"
        done) || true
        if [ "$(wc -l < "$WORK/sb_cfgs.txt")" != 4 ]; then
            echo "pixel_statusbar overlay: unexpected resources ($(tr '\n' ' ' < "$WORK/sb_cfgs.txt")), not built" >&2
            exit 1
        elif [ -n "$SB_UNCOVERED" ]; then
            echo "SystemUIGoogle.apk has$SB_UNCOVERED, which the overlay does not cover: status bar overlay not built"
        else
            "$BT/zipalign" -p -f 4 "$WORK/sb.apk" "$WORK/sb-aligned.apk"
            "$BT/apksigner" sign --ks "${KEYSTORE:-$HOME/.android/debug.keystore}" \
                --ks-pass pass:android --ks-key-alias androiddebugkey --key-pass pass:android \
                --out "$OUT/OneOSPixelStatusBar.apk" "$WORK/sb-aligned.apk"
            rm -f "$OUT/OneOSPixelStatusBar.apk.idsig"
            echo "built $OUT/OneOSPixelStatusBar.apk (Pixel status bar insets: $(tr '\n' ' ' < "$WORK/sb_cfgs.txt"))"
        fi
    fi
else
    echo "SystemUIGoogle.apk: not in the image, no status bar overlay"
fi

# The guest's own APEX payloads, which guest_prepare.sh loop-mounts into the
# container ($STAGE/<name>_payload.img). Extracting them on the phone picked up
# the HOST's modules (Google-signed tethering next to ColorOS's OPPO-signed
# NetworkStack: PackageManagerService "Signature mismatch ... shared user
# android.uid.networkstack"), so take them from the image here.
# OPPO's CN images carry com.android.<name>.apex/.capex; a global image (the
# Find X9 Ultra IN, CPH2841IN) carries Google's mainline builds of the same
# modules instead, com.google.android.<name>[_tplus]_compressed.apex (the
# compressed layout: original_apex inside) or com.google.android.<name>.apex.
# The module name inside is com.android.<name> either way, which is what
# guest_prepare.sh mounts the payload as.
# Pixel 17 (yogi) has no /system/framework/framework-telecom.jar: android.telecom
# is in its telephonycore module (framework-telecom.jar, service-telecom.jar).
# One UI's telephonycore has neither (One UI, like ColorOS, keeps the platform
# jar), so run 38's guest zygote died preloading SystemServiceRegistry
# (NoClassDefFoundError for android.telecom.TelecomFrameworkInitializer). Such an
# image gets its own telephonycore, and its conscrypt and profiling: One UI's
# newer builds of those call into ART and framework APIs Pixel's lack
# (javax.crypto KEM/KDF, ActivityManagerLocal.crashApplication,
# Process.setProcessThreadGroup). guest_prepare.sh mounts these only when
# staged; ColorOS's images have the platform jar, so their sets are unchanged.
EXTRA=""
if ! in_image /system/framework/framework-telecom.jar; then
    EXTRA="telephonycore conscrypt profiling"
    echo "no platform framework-telecom.jar: also the image's $EXTRA"
fi
for name in art i18n runtime sdkext nfcservices tethering crashrecovery cellbroadcast \
            extservices permission wifi appsearch mediaprovider adservices rkpd \
            healthfitness ondevicepersonalization configinfrastructure bt $EXTRA; do
    rm -f "$WORK/m.apex" "$WORK/m.capex"
    for f in com.android.$name.apex com.android.$name.capex com.google.android.$name.apex \
             com.google.android.${name}_compressed.apex com.google.android.${name}_tplus_compressed.apex; do
        "$DEBUGFS" -R "dump /system/apex/$f $WORK/m.capex" "$IMG" 2>/dev/null
        [ -s "$WORK/m.capex" ] || continue
        # Compressed (original_apex inside) or a plain APEX.
        if unzip -l "$WORK/m.capex" original_apex >/dev/null 2>&1; then
            unzip -p "$WORK/m.capex" original_apex > "$WORK/m.apex"
        else
            mv "$WORK/m.capex" "$WORK/m.apex"
        fi
        echo "payload $name: from /system/apex/$f"
        break
    done
    if [ -s "$WORK/m.apex" ]; then
        unzip -p "$WORK/m.apex" apex_payload.img > "$OUT/${name}_payload.img"
        echo "payload $name: $(file -b "$OUT/${name}_payload.img" | cut -d, -f1)"
    else
        rm -f "$OUT/${name}_payload.img"
        echo "payload $name: not in the image (the host's module stays)"
    fi
done

# OneOS inside the guest (app-android/guest): "Back to One UI" from its screen
# or its Quick Settings tile. guest_prepare.sh puts it in every guest's /oem as
# app/OneOSGuest/OneOSGuest.apk, from $STAGE/OneOSGuest.apk. The release build,
# signed with the OneOS key: cd app-android && ./gradlew :guest:assembleRelease
GUEST_APK=$(ls "$ROOT"/app-android/guest/build/outputs/apk/release/*.apk 2>/dev/null | head -1)
ONEOS_CERT=37560f7ba9e82a7977c239b77a47c7fa6df0f381cdad44810ffdcab12295f83a
if [ -z "$GUEST_APK" ]; then
    rm -f "$OUT/OneOSGuest.apk"
    echo "OneOS guest app not built (app-android: ./gradlew :guest:assembleRelease): no OneOSGuest.apk copied"
elif ! "$BT/apksigner" verify --print-certs "$GUEST_APK" 2>/dev/null | grep -q "certificate SHA-256 digest: $ONEOS_CERT"; then
    rm -f "$OUT/OneOSGuest.apk"
    echo "$GUEST_APK is not signed with the OneOS release key: not copied" >&2
    exit 1
else
    cp -f "$GUEST_APK" "$OUT/OneOSGuest.apk"
    echo "copied $GUEST_APK to $OUT/OneOSGuest.apk (OneOS app in the guest)"
fi

# Google Play services for a Pixel guest (docs/pixel-guest.md, "Google
# services"). Pixel 17 ships GmsCore only inside the product APEX
# /system/product/apex/com.google.android.gmssystem*.apex, which the phone's
# apexd never activates, so the guest's package manager never scanned it
# ("Missing required system package: com.google.android.gms", runs 40-42). Its
# payload (EROFS, ~155 MB: the GmsCore APK and two XMLs) is staged here;
# guest_prepare.sh loop-mounts it at the guest's /apex/com.google.android.gmssystem
# and presents the APK as a plain product priv-app (ONEOS_GUEST_GMS, default on).
# Staged only when exactly one priv-app/PrebuiltGmsCore*/PrebuiltGmsCore*.apk is
# inside and it is com.google.android.gms; deploy-phone.sh pushes it like the
# other payloads.
EXTRACT_EROFS=${EXTRACT_EROFS:-$ROOT/mysticgsi/tools/bin/Linux/x86_64/extract.erofs}
GMSAPEX=$("$DEBUGFS" -R "ls -p /system/product/apex" "$IMG" 2>/dev/null |
    awk -F/ '$6 ~ /^com\.google\.android\.gmssystem.*\.apex$/ { print $6; exit }')
# Pixel's layout only: its product PrebuiltGmsCore folder (app_chimera) waiting
# for the APK. The ColorOS images carry the same APEX but their own GmsCore in
# my_product/priv-app, and no product PrebuiltGmsCore at all.
if [ -n "$GMSAPEX" ] && { ! in_image /system/product/priv-app/PrebuiltGmsCore/app_chimera || in_image /my_product/priv-app/GmsCore; }; then
    echo "payload gmssystem: $GMSAPEX is there but not in Pixel's layout (no product PrebuiltGmsCore/app_chimera, or its own GmsCore in my_product): none staged"
    GMSAPEX=""
fi
GP="$OUT/gmssystem_payload.img"
rm -f "$GP"
if [ -z "$GMSAPEX" ]; then
    echo "payload gmssystem: no /system/product/apex/com.google.android.gmssystem*.apex in the image, none staged (no Google services from an APEX)"
else
    [ -x "$EXTRACT_EROFS" ] || { echo "payload gmssystem: $EXTRACT_EROFS missing, cannot check the payload" >&2; exit 1; }
    rm -f "$WORK/g.apex" "$WORK/g.capex"
    "$DEBUGFS" -R "dump /system/product/apex/$GMSAPEX $WORK/g.capex" "$IMG" 2>/dev/null
    [ -s "$WORK/g.capex" ] || { echo "payload gmssystem: could not dump /system/product/apex/$GMSAPEX" >&2; exit 1; }
    # Compressed (original_apex inside) or a plain APEX, as above.
    if unzip -l "$WORK/g.capex" original_apex >/dev/null 2>&1; then
        unzip -p "$WORK/g.capex" original_apex > "$WORK/g.apex"
        rm -f "$WORK/g.capex"
    else
        mv "$WORK/g.capex" "$WORK/g.apex"
    fi
    unzip -p "$WORK/g.apex" apex_payload.img > "$GP"
    rm -f "$WORK/g.apex"
    # The APK guest_prepare.sh binds. EROFS (Pixel's) or ext4, which
    # guest_prepare.sh's mount_payload tells apart by the same magic.
    GMS_FS=ext4
    if [ "$(od -An -tx4 -j1024 -N4 "$GP" | tr -d ' ')" = e0f5e1e2 ]; then
        GMS_FS=erofs
        GMS_IN=$("$EXTRACT_EROFS" -i "$GP" -p 2>/dev/null |
            sed -n 's#.*type=FILE .*fsConfig=\[/\(priv-app/PrebuiltGmsCore[^/ ]*/PrebuiltGmsCore[^/ ]*\.apk\) .*#\1#p')
    else
        GMS_IN=""
        for d in $("$DEBUGFS" -R "ls -p /priv-app" "$GP" 2>/dev/null | awk -F/ '$6 ~ /^PrebuiltGmsCore/ { print $6 }'); do
            GMS_IN="$GMS_IN $("$DEBUGFS" -R "ls -p /priv-app/$d" "$GP" 2>/dev/null |
                awk -F/ -v d="$d" '$6 ~ /^PrebuiltGmsCore.*\.apk$/ { print "priv-app/" d "/" $6 }')"
        done
    fi
    GMS_N=$(echo $GMS_IN | wc -w)
    if [ "$GMS_N" != 1 ]; then
        rm -f "$GP"
        echo "payload gmssystem: $GMSAPEX has $GMS_N PrebuiltGmsCore APKs in its payload (one expected): none staged, no Google services in the guest"
    else
        # Its package name and version, from the APK itself.
        rm -rf "$WORK/gx" && mkdir -p "$WORK/gx"
        if [ "$GMS_FS" = erofs ]; then
            (cd "$WORK/gx" && "$EXTRACT_EROFS" -i "$GP" -X "/$GMS_IN" -o "$WORK/gx" -s >/dev/null 2>&1) || true
        else
            "$DEBUGFS" -R "dump /$GMS_IN $WORK/gx/g.apk" "$GP" 2>/dev/null || true
        fi
        GX=$(find "$WORK/gx" -type f -name '*.apk' | head -1)
        GMS_APK_SIZE=""; GMS_BADGING=""
        if [ -n "$GX" ]; then
            GMS_APK_SIZE=$(stat -c %s "$GX")
            GMS_BADGING=$("$BT/aapt2" dump badging "$GX" 2>/dev/null | sed -n '1s/^package: //p')
        fi
        rm -rf "$WORK/gx"
        case "$GMS_BADGING" in
            "name='com.google.android.gms' "*) ;;
            *) rm -f "$GP"
               echo "payload gmssystem: $GMS_IN in $GMSAPEX is not GmsCore (${GMS_BADGING:-unreadable}): none staged" >&2
               exit 1 ;;
        esac
        echo "payload gmssystem: from /system/product/apex/$GMSAPEX ($GMS_FS, $(stat -c %s "$GP") bytes)"
        echo "payload gmssystem: $GMS_IN, $GMS_APK_SIZE bytes, $(echo "$GMS_BADGING" | cut -d' ' -f1-2)"
    fi
fi
