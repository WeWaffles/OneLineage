# OneHyper

A fork of [OneLineage](https://github.com/WeWaffles/OneLineage) that hot-switches a rooted Samsung phone between stock **One UI** and a **Xiaomi HyperOS 3 Global (Android 16) GSI** instead of LineageOS. It uses the same container approach: the GSI is staged under `/data/local/tmp/hyper_stage`, pivoted into with its own zygote and system_server, and the screen can be handed back to One UI. No reflashing, no second partition.

OneHyper uses its own package name (`com.wewaffles.onehyper`) and stage directory, so it can be installed alongside OneLineage.

> ## Disclaimer
> **Experimental and not yet boot-tested.** The orchestration is inherited from OneLineage, which was tuned against the LineageOS 23.2 GSI. HyperOS is a heavily modified ROM (MIUI framework, Xiaomi services) and may need more bring-up work before it reaches the home screen. See *Status* below.
> It may not work on your Samsung model or One UI version at all. It replaces core parts of a running system, and it can crash, hang or soft-brick your phone, fill `/data`, or break radio/SMS. **Back up everything first. Use at your own risk.**

## Requirements
- A rooted Samsung phone on **Android 16** (One UI 8.x). The guest must match the host's Android version.
- **~13 GB free on `/data`.** The download is about 3.8 GB and the extracted `system.img` is 7.6 GB; both exist at once during extraction. The app checks this before downloading.
- Internet access for the GSI download

## The image
| | |
| --- | --- |
| Build | `Hyperos-goya-16-OS3.0.5.0.WOEMIXM-AB-20251207-MysticGSI.zip` |
| Source | [Mystic GSI on SourceForge](https://sourceforge.net/projects/mystic-gsi-updates/files/HyperOS/) (unofficial port, not from Xiaomi) |
| Region | `MIXM` = Global (`CNXM` would be China) |
| Contents | one raw, non-sparse **ext4** `system.img`. Checked over HTTP range requests: ext4 magic `0x53EF` at offset 1080, 7,620,681,728 bytes. The existing `7zz` → `system.raw` → `losetup` + `mount -t ext4` path works unchanged. |

At the time of the fork this was the only Android 16 Global HyperOS GSI that Mystic GSI published. The other Global and EEA builds are Android 15.

## Differences from OneLineage
- **Download:** one HyperOS 3 Global flavour instead of the LineageOS Vanilla/GAPPS choice. The second flavour card is hidden. Google Play ships in the ROM, so there is no GAPPS variant.
- **No `framework_patched.jar` / `services_patched.jar`.** Those were patched copies of *LineageOS's* framework. Bind-mounting them over HyperOS's framework would bootloop it, so they were removed. `master_prepare.sh` already skips the bind when the files are absent. If HyperOS needs equivalent fixes, they must be re-made against HyperOS's own `framework.jar`/`services.jar`.
- **Kept:** `PermissionController_patched.apk`. It patches the *host's* permission APEX, which is bound into the container, so it is not tied to the guest ROM.
- **Pre-created data dirs:** `com.miui.home` and `com.miui.securitycenter` replace `org.lineageos.lineagesettings`.
- **Detection:** the app checks `ro.mi.os.version.name` instead of `ro.lineage.version`. Cleanup kills `com.miui.*`/`com.xiaomi.*` instead of `org.lineageos.*`.
- **Renames:** `switch_to_lineage.sh` → `switch_to_hyperos.sh`; `lineage_stage`/`lineage_backups` → `hyper_stage`/`hyper_backups`.
- **Fully separate install:** everything OneHyper writes on the host lives under `/data/local/tmp/hyper_stage`: the image, rootfs, guest `/data`, the adb/imsd watchdogs and their logs, and `ui_activator.log`. Loop-device cleanup only detaches `hyper_stage/system.raw`. Installing, deleting or running OneHyper never touches `lineage_stage`. Shared on purpose: your photos and downloads (`/data/media`), as with One UI. Only one container can run at a time.
- **Build:** adds `build_apk_windows.sh` for Git Bash on Windows. It uses JDK 21 and SDK build-tools/platform 36.
- Internal Java identifiers (`btnBootLineage` and the like) are unchanged on purpose, so upstream OneLineage fixes merge cleanly.

## Status (tested on SM-S948U, One UI 8.5 / Android 16)
- **HyperOS boots to its first frame and then system_server dies.** system_server starts every service and reaches its main loop. SurfaceFlinger logs `Boot is finished`, `FallbackHome` is displayed, and SystemUI and `com.miui.home` are launched. The "There's an internal problem with your device" dialog also appears; it is expected for a GSI (system/vendor fingerprint mismatch).
- **Open blocker:** while unlocking user 0, `LockSettingsService.unlockUserKeyIfUnsecured` makes `StorageManagerService.unlockCeStorage` call the guest vold, which has no user-0 key and throws. One UI already unlocked that storage on the host. The fix is to skip that vold call while keeping the rest of `unlockCeStorage`, which marks the user as unlocked. Not done yet.

### What it took to get this far
- **Classpaths.** The original `zygote_exec` hard-coded LineageOS's BOOTCLASSPATH/SYSTEMSERVERCLASSPATH (including `org.lineageos.platform.jar`). It is rebuilt from `native/zygote_exec.c` to inherit its environment. `master_inner.sh` derives the classpaths from the guest's own fragments with `derive_classpath`: 62 boot jars, including miui/xiaomi/mediatek. All stdio stays on `/dev/null` (zygote's fd allowlist).
- **Host mounts and config.** Every host mount under `/sys` is bound in (cgroup2 for `createProcessGroup`, bpffs for NetworkStats), along with the host `cgroups.json`/`task_profiles.json`. A tmpfs overlay on `/system_ext` provides the `apex/` dir that host apexd reports.
- **Properties.** Guest-only `build.prop` keys are imported at runtime and never override host values. `return_to_oneui.sh` removes them again.
- **Settings.** The seeded `adb_enabled` entry uses a numeric id. A non-numeric one makes SettingsProvider reject the whole file.
- **KernelSU.** When the guest PMS finishes, KernelSU's allowlist gets pruned and persisted. A root agent started before the takeover keeps restoring `.allowlist` and runs adb commands from `hyper_stage/agent/cmd.sh`.
- **Framework stubs** made with `native/dexpatch.py`, then zipaligned. They live in `hyper_stage/patched/<path>` and are bind-mounted over `rootfs/<path>`. They are not shipped in the repo or APK because they are modified Xiaomi binaries:
  - `system_ext/framework/miui-services.jar`: the `MiuiNetworkManagementService` methods that call Xiaomi's `IOemNetd` (Samsung netd rejects them), plus `TorchModeHelper$TorchCallback.onTorchModeChanged` (Samsung cameraserver).
  - `system_ext/framework/miui-wifi-service.jar`: `AmlMiuiWifiHalHandler.getWifiSupplicantXmIface` (Xiaomi supplicant extension).
  - `system/framework/services.jar`:
    - `LockSettingsService.migrateUserToSpWithBoundKeysLocked`, a key migration the container must not run.
    - `SystemServer.startApexServices`. Host apexd reports Samsung APEX services, and skipping them also skips UWB, ranging, profiling and device-lock.

## What's in here
| Path | What it is |
| --- | --- |
| `src/`, `res/`, `AndroidManifest.xml` | The Android app (`com.wewaffles.onelineage`) |
| `assets/master_prepare.sh` | Stages the rootfs, binds the patched files, fixes labels/ownership |
| `assets/master_inner.sh` | Runs inside the container, starts the guest zygote |
| `assets/switch_to_hyperos.sh` / `return_to_oneui.sh` | Switch in and back out |
| `assets/zygote_exec` | Static aarch64 launcher for the guest zygote |
| `build_apk.sh` / `build_apk_windows.sh` | Builds and signs the APK (macOS / Windows Git Bash) |

## Patches (inherited from OneLineage)

Everything below was found and fixed against the LineageOS GSI. The host-side fixes should still apply; guest-side ones may not.

### Patched system files (bind-mounted over the GSI)
- *(OneLineage only: `services_patched.jar` / `framework_patched.jar`; removed in this fork, see above)*
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
Windows (Git Bash): `bash build_apk_windows.sh` → `build/OneHyper.apk`. macOS: edit the paths at the top of `build_apk.sh`, then run it.

## Credits
Forked from OneLineage by WeWaffles. HyperOS GSI ports by Mystic GSI (SourceForge). HyperOS and MIUI are trademarks of Xiaomi; Android is a trademark of Google. Not affiliated with Samsung, Xiaomi, Google or LineageOS.
