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

## What's in here
| Path | What it is |
| --- | --- |
| `src/`, `res/`, `AndroidManifest.xml` | The Android app (`com.wewaffles.onelineage`) |
| `assets/master_prepare.sh` | Stages the rootfs, binds the patched files, fixes labels/ownership |
| `assets/master_inner.sh` | Runs inside the container, starts the guest zygote |
| `assets/switch_to_lineage.sh` / `return_to_oneui.sh` | Switch in and back out |
| `assets/zygote_exec` | Static aarch64 launcher for the guest zygote |
| `build_apk.sh` | Builds and signs the APK |

## Patches

### Patched system files (bind-mounted over the GSI)
- `services_patched.jar` over `system/framework/services.jar`
- `framework_patched.jar` over `system/framework/framework.jar`
- `PermissionController_patched.apk`: removes the `android.permission.RANGING` reference so runtime-permission dialogs stop crashing (Samsung's PermissionController needs a permission the LineageOS 23.2 platform doesn't define)
- Optional bind-mounts when present: `framework-res_patched.apk`, `libaudio_aidl_conversion_common_cpp_patched.so`, `libaudioclient_aidl_conversion_patched.so`

### Boot and environment fixes
1. **APEX paths in the container.** Host `/system/apex` and `/system_ext/apex` are bound into the rootfs after the GSI payloads are extracted, so PackageManagerService stops dying in `scanApexPackages`.
2. **SELinux.** The staged `/data` is labeled with `restorecon` against One UI's file contexts, as if it were the real `/data` (app data keeps the per-app labels installd gives it), and every patched file bound into Lineage takes the label of the file it replaces. The takeover boots Lineage permissive, then switches SELinux to **enforcing** once the home screen is up, for the rest of the session. A few policy rules are added live with `ksud sepolicy patch` (gone at reboot): see `switch_to_lineage.sh`.
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

## Isolated mode
Isolated mode gives Lineage its own binder registry and its own keystore, gatekeeper and credential state, with `ol_bridge` passing One UI's hardware services in (see docs/ISOLATION.md). It keeps One UI's lock screen safe and is what the camera, Wi-Fi calling and the touch, audio and Wi-Fi fixes were tested on. It is opt-in for now: run `su -c touch /data/local/tmp/lineage_stage/data/local/tmp/ol_isolate` before switching.

## Known issues
Tested on an SM-S948U (T-Mobile) in isolated mode. On other phones, expect more of these.
- Returning to One UI needs a reboot. `return_to_oneui.sh` restores and checks One UI's lock-screen state first and says when the reboot is safe.
- Calls work both ways, but some outgoing calls fail with "call failed". Dialing with the country code (`+1...`) may help.
- Wi-Fi calling registers, but call audio over Wi-Fi is untested.
- RCS chats don't work ("RCS chat status not supported"): Google's RCS provisioning turns it off for this setup.
- NFC doesn't work (the guest has no NFC service), and Bluetooth is untested.
- Developer options crash (the guest registers no `adb` service).
- DTMF tones glitch, and deep-buffer audio hangs, so it stays disabled.
- Never kill the host `netd` while Lineage is running.

## Building
Set `ANDROID_SDK_ROOT` (or `ANDROID_HOME`) to your Android SDK directory, install JDK 17, Android SDK build-tools 34.0.0 and the android-34 platform, then run `./build_apk.sh`. The script writes the APK to `out/OneLineage.apk` and creates a development keystore on first use. You can override `BUILD_TOOLS_VERSION`, `ANDROID_PLATFORM`, and `OUT_APK`; set `KEYSTORE`, `KEYSTORE_PASS`, `KEY_ALIAS`, and `KEY_PASS` to sign with your own keystore.

## Credits
LineageOS GSI builds by MisterZtr (SourceForge). LineageOS and Android are trademarks of their respective owners. Not affiliated with Samsung, Google or LineageOS.
WeWaffles (creator of OneLineage)

## License
OneLineage is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attributions, including code adapted from [OneOS](https://github.com/fahadalijaved/OneOS), and for the parts of this repository that keep their own licenses.
