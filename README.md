# OneLineage

Hot-switch between stock **One UI** and a **LineageOS 23.2 (Android 16) GSI** on a rooted Samsung phone, with no reflashing and no second partition. OneLineage stages the GSI under `/data/local/tmp`, pivots into it as a container with its own zygote and system_server, and can hand the screen back to One UI.

If something isn't working and you have a fix feel free to make a pr!

> ## Disclaimer
> **This has been tested on only a handful of devices, and it seems if you want to install it without making modifications, it has to be on Android 16**
> It may not work on other Samsung models, other One UI versions, or other devices at all. It is experimental, it replaces core parts of a running system, and it can crash, hang or soft-brick your phone, fill `/data`, or break radio/SMS. **Back up everything first. Use at your own risk.**
> Also, I did use AI a fair bit in this project, it would have taken a LOT longer without it.

## Requirements
- A rooted Samsung phone (the tested one is an S26 Ultra on One UI 8.5)
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
2. **SELinux labels on the staged `/data`.** The tree is relabeled like a real `/data` (`system_data_file`, per-package `app_data_file`) instead of `shell_data_file`. Also `setenforce 0` during the takeover and `setenforce 1` on return.
3. **Audio hang.** Host `audioserver`/`cameraserver` are left running (they used to be stopped/frozen, which deadlocked `AudioService`). Only the host zygote is suppressed.
4. **Runaway `sf.log`.** SurfaceFlinger output goes to `/dev/null` (it was growing to hundreds of MB in minutes).
5. **App data ownership.** `fix_app_dirs.sh` re-owns app data dirs to the uid PackageManager assigned, strips write bits from dex/apk/jar files (ART refuses writable dex), and creates missing dirs such as `/data/misc/bluedroid`.
6. **No installd.** `ensure_app_storage.sh` plus a 15 s sweeper create `/data/user/0`, `/data/user_de/0` and shared-storage dirs for new installs, so apps installed inside Lineage can launch.
7. **Gesture navigation.** Overlay idmaps are generated with `idmap2 --ignore-overlayable` before zygote starts.
8. **Bluetooth crash loop** fixed by creating `/data/misc/bluedroid` before boot.
9. **adb.** `Settings.Global.ADB_ENABLED` is pre-seeded, host `adb_keys` are copied into the guest, and `adb_watchdog.sh` keeps adbd and the USB gadget alive.
10. **Networking.** The preferred APN is switched to `IPV4V6`, and `net_fix.sh` maintains a private routing table (4242) because the guest's ConnectivityService can't program the host's netd.
11. **SMS.** `ims_watchdog.sh` keeps One UI's `imsd` running (20 s poll, no radio nudging) and `switch_to_lineage.sh` waits for voice registration before pivoting.
12. **Boot diagnostics.** Each boot writes `/data/boot_failures.log`.

## Voice calling
There is no quick fix for native cellular voice in the guest, and it's worth being precise about why: placing a circuit/VoLTE call needs an `ImsService` the guest's telephony framework can bind to. The only IMS stack on the device is Samsung's proprietary `imsd`, living in One UI; the LineageOS GSI ships no vendor `ImsService`, and Samsung's isn't a drop-in for AOSP telephony (same AIDL/HIDL-mismatch class of problem as the codec list, but far deeper and vendor-locked). On a VoLTE-only carrier there's no CS fallback to catch the call either. A userspace script can't synthesize that stack.

The path that *does* work in the guest, because mobile data already does, is **VoIP**: a SIP/VoLTE app, a carrier Wi-Fi-calling client, or Google Voice/Fi over the data connection. That gives real inbound/outbound calling without touching the native IMS layer. If you want, that can be wired into the takeover (install + permission-grant the client the way microG is handled today).

## Known issues
- Returning to One UI may still need a manual reboot.
- **Overheating / high CPU (root cause known, only partially mitigated).** The guest's `MediaCodecList` fetches the codec-list service through the **shared servicemanager**, which on this device hands back one of Samsung's `mediaserver` binder nodes whose interface descriptor does not match the GSI's (`libbinder.Parcel: enforceInterface() expected 'android.gui.IGraphicBufferProducer' but read 'android.media.IMediaCodecList'`). The reply parcels as garbage; the lookup neither succeeds nor cleanly fails, so `system_server` **and** `systemui` retry it thousands of times a second (~110–120 % CPU each, ~100 °C, governor-capped). Profiled with `simpleperf` (2026-10): ~1/3 of the cost was merely **logging** the failure (`logd` ~55 %, kernel `vsnprintf` + Samsung `sec_pmsg`/pstore) — that is the "GB of logcat". `switch_to_lineage.sh` now silences those tags before the guest boots, which cut `system_server`/`systemui` to ~81 %/78 % and removed `logd` from the top. **This is a damage-limiter, not a fix** — the remaining spin is the binder retry itself.
  - Note the original S26 Ultra fix (kill `media.codec`) does **not** apply here: there is no `media.codec`/`IMediaCodecList` *process* — on this Android-16 build the codec list is served out of `mediaserver` (which must stay up for `MediaPlayer`), so it can't just be killed.
  - **Architectural fix applied (codec-list layer):** `master_inner.sh` now starts the GSI's own `/system/bin/mediaserver` inside the container *before* zygote (same play as `wificond`). It re-registers `media.player`/the codec list with the guest-matching interface and builds the list from the vendor Codec2 HAL over hwbinder (Treble-stable). Verified on SM-S948U: the `enforceInterface ... IMediaCodecList` errors disappear and `media.player` enumerates `codec2::*` components cleanly. Codec *resource* events drop to minutes apart (no longer a per-second storm).
  - **Still hot afterwards — multi-causal.** Removing the codec storm revealed/left other contributors keeping it ~100 °C (binder + lock-contention storm in the profile). The dominant remaining log sources are (a) Material You **dynamic-colour overlay idmaps failing** — `failed to read IDMAP /data/resource-cache/...systemui-{neutral,dynamic,accent}...frro` retried across `system_server`/`systemui`/`phone` (the `ResourcesManager` spam), and (b) telephony (`m.android.phone`, QNS/IMS quality monitors). These are the next targets — likely pre-generate or disable the Material You FRROs the way the nav-bar idmap is pre-generated. Diagnosis is awkward because guest `system_server`/`systemui` can't be `SIGQUIT`/`kill`-signalled from the host shell (EPERM across the security context); use `simpleperf -a` (system-wide) which works.
  - If the phone runs hot, return to One UI or reboot to cool it.
- No IMS stack in the guest, so **native cellular voice calls don't work** (data and SMS depend on One UI's `imsd`). A data/VoIP calling path works — see below.
- Developer options crash (the guest registers no `adb` service).
- DTMF tones glitch, and deep-buffer audio hangs, so it stays disabled.
- Never kill the host `netd` while Lineage is running.

## Building
Edit the paths at the top of `build_apk.sh` (JDK 17, Android SDK build-tools 34, android-34 platform), provide your own signing keystore, then run `./build_apk.sh`.

## Credits
LineageOS GSI builds by MisterZtr (SourceForge). LineageOS and Android are trademarks of their respective owners. Not affiliated with Samsung, Google or LineageOS.
