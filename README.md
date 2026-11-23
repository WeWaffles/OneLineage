# OneLineage

 **NOTE: OneLineage is just a proof of concept, this repo should provide you with enough to port other roms to bootloader locked devices, the lineageos with this repo is just a demo of this capability, and therefore does not fully work. Have fun!**

 **IF YOU TRY THIS ON OTHER DEVICES AND IT DOESN'T WORK, THE SUPPORT I CAN GIVE IT EXTREMELY LIMITED, THERE IS A LOT OF VARIATION BETWEEN DEVICES**

Hot-switch between stock **One UI** and a **LineageOS 23.2 (Android 16) GSI** on a rooted Samsung phone, with no reflashing and no second partition. OneLineage stages the GSI under `/data/local/tmp`, pivots into it as a container with its own zygote and system_server, and can hand the screen back to One UI.

> ## Disclaimer
> **This has been tested on only a handful of devices, and it seems if you want to install it without making modifications, it has to be on Android 16**
> It may not work on other Samsung models, other One UI versions, or other devices at all. It is experimental, it replaces core parts of a running system, and it can crash, hang or soft-brick your phone, fill `/data`, or break radio/SMS. **Back up everything first. Use at your own risk.**
> Also, I did use AI a fair bit in this project, it would have taken a LOT longer without it.

> Hey, Contributor RealThalesGit here, if you somewhat get throw back to one ui after getting stuck at lineage boot screen, check your manager modules.

## Requirements
- A rooted samsung phone (the tested ones are: S26 Ultra, Base S26, and Samsung A25, both at One UI 8.5.) (Can be temp-root too.)
- Enough free space on `/data` for the extracted GSI
- Internet access for the GSI download (LineageOS 23.2 GSI, EXT4, VANILLA or GAPPS builds from SourceForge)

## Installing (OnePixel)
Install the APK and tap **Download**. The app does the rest on the phone, with nothing to push over adb:
1. It fetches only the `system`, `system_ext` and `product` partitions of the PixelOS 16.2 `waffle` OTA (`PixelOS_waffle-16.2-20260511-0722.zip` on SourceForge) with parallel HTTP range requests, decompresses them with the bundled 7-Zip and checks each against the SHA-256 in the OTA manifest (`tools/payload`, `assets/ol_payload.dex`). About 2.5 GB is downloaded and about 4.2 GB written to `/data`. An interrupted install resumes at the partition level.
2. `assets/build_pixelos.sh` patches the images in place: it removes the Oplus framework and OnePlus-only apps, daemons and overlays, fixes the boot classpath and one sepolicy file, gives the three `build.prop`s a generic PixelOS identity and copies this phone's own `framework-res` overlay into `product`.
3. `master_prepare.sh` loop-mounts `system_ext.raw` and `product.raw` over the system image at every switch.

The Pixel Camera port (MGC_9.8.102) has no direct download link. Put it at `Download/OnePixel/GoogleCamera.apk` and the next switch installs it as a system app; the lens fix it needs is applied automatically after its first launch.

A locally built merged image at `Download/OnePixel/system.img` still takes priority over the download.

## What's in here
| Path | What it is |
| --- | --- |
| `src/`, `res/`, `AndroidManifest.xml` | The Android app (`com.wewaffles.onelineage`) |
| `assets/build_pixelos.sh` | Patches the downloaded PixelOS images on the phone |
| `tools/payload/` | The on-phone OTA extractor (builds `assets/ol_payload.dex`) |
| `assets/master_prepare.sh` | Stages the rootfs, binds the patched files, fixes labels/ownership |
| `assets/master_inner.sh` | Runs inside the container, starts the guest zygote |
| `assets/switch_to_lineage.sh` / `return_to_oneui.sh` | Switch in and back out |
| `assets/zygote_exec` | Static aarch64 launcher for the guest zygote |
| `build_apk.sh` | Builds and signs the APK |

## Patches

### Patched system files (bind-mounted over the GSI)
- `services_patched.jar` over `system/framework/services.jar`. On the `onepixel` branch this is PixelOS 16.2's own `services.jar` with two methods stubbed by `dexpatch.py` (from the `onehyper` branch) and 4-byte aligned:
  - `LockSettingsService.migrateUserToSpWithBoundKeysLocked`, a key migration the container must not run.
  - `SystemServer.startApexServices`. Host apexd reports Samsung APEX services.
- `framework_patched.jar` (LineageOS only): not shipped on `onepixel`, so the guest uses PixelOS's stock `framework.jar`. The app deletes any copy left from an older install.
- `PermissionController_patched.apk`: removes the `android.permission.RANGING` reference so runtime-permission dialogs stop crashing (Samsung's PermissionController needs a permission the LineageOS 23.2 platform doesn't define)
- Optional bind-mounts when present: `framework-res_patched.apk`, `libaudio_aidl_conversion_common_cpp_patched.so`, `libaudioclient_aidl_conversion_patched.so`

### Boot and environment fixes
1. **APEX paths in the container.** Host `/system/apex` and `/system_ext/apex` are bound into the rootfs after the GSI payloads are extracted, so PackageManagerService stops dying in `scanApexPackages`.
2. **SELinux labels on the staged `/data`.** The tree is relabeled like a real `/data` (`system_data_file`, per-package `app_data_file`) instead of `shell_data_file`. Also `setenforce 0` during the takeover and `setenforce 1` on return.
3. **Audio hang.** Host `audioserver`/`cameraserver` are left running (they used to be stopped/frozen, which deadlocked `AudioService`). Only the host zygote is suppressed.
4. **Runaway `sf.log`.** SurfaceFlinger output goes to `/dev/null` (it was growing to hundreds of MB in minutes).
5. **App data ownership.** `fix_app_dirs.sh` re-owns app data dirs to the uid PackageManager assigned, strips write bits from dex/apk/jar files (ART refuses writable dex), and creates missing dirs such as `/data/misc/bluedroid`.
6. **No installd.** `ensure_app_storage.sh` plus a 15 s sweeper create `/data/user/0`, `/data/user_de/0` and shared-storage dirs for new installs, so apps installed inside Lineage can launch.
7. **Gesture navigation.** Overlay idmaps are generated with `idmap2 --ignore-overlayable` before zygote starts.
8. **Bluetooth crash loop** fixed by creating `/data/misc/bluedroid` before boot.
9. **adb.** `Settings.Global.ADB_ENABLED` is pre-seeded, host `adb_keys` are copied into the guest, and `adb_watchdog.sh` keeps adbd and the USB gadget alive.
10. **Networking.** The preferred APN is switched to `IPV4V6`, and `net_fix.sh` maintains a private routing table (4242) because the guest's ConnectivityService can't program the host's netd.
11. **SMS.** `ims_watchdog.sh` keeps One UI's `imsd` running and `switch_to_lineage.sh` waits for voice registration before pivoting.
12. **Boot diagnostics.** Each boot writes `/data/boot_failures.log`.

## Known issues
- Returning to One UI may still need a manual reboot.
- The guest binds the host's `media.codec`, whose AIDL hash differs from the GSI's, which can cause high CPU during codec enumeration.
- No IMS stack in the guest, so **voice calls don't work** (data and SMS depend on One UI's `imsd`).
- Developer options crash (the guest registers no `adb` service).
- DTMF tones glitch, and deep-buffer audio hangs, so it stays disabled.
- Never kill the host `netd` while Lineage is running.
- After some minutes (or 1 minute) after lineageos started, you get throw back at one ui 8, we're fixing this as we know the root cause.

## Building
Set `ANDROID_SDK_ROOT` (or `ANDROID_HOME`) to your Android SDK directory, install JDK 17, Android SDK build-tools 34.0.0 and the android-34 platform, then run `./build_apk.sh`. The script writes the APK to `out/OneLineage.apk` and creates a development keystore on first use. You can override `BUILD_TOOLS_VERSION`, `ANDROID_PLATFORM`, and `OUT_APK`; set `KEYSTORE`, `KEYSTORE_PASS`, `KEY_ALIAS`, and `KEY_PASS` to sign with your own keystore.

## Credits
LineageOS GSI builds by MisterZtr (SourceForge). LineageOS and Android are trademarks of their respective owners. Not affiliated with Samsung, Google or LineageOS.
WeWaffles (creator of OneLineage)
