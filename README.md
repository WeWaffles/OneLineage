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
| `kernel/xnu_probe/` | Inert load/unload-only module for exact-kernel ABI validation |
| `kernel/device-abi/` | Fail-closed records captured from tested device builds |
| `kernel/device-hardware/` | Sanitized hardware facts used by offline XNU tooling |
| `tools/verify_module_abi.py` | Offline module architecture/vermagic/CRC/import checker |
| `tools/xnu/` | Apple Device Tree, payload, `boot_args` and QEMU harness tooling; phone output is blocked |
| `xnu/` | Pinned XNU-8796 source, pinned and OneLineage patch series, macOS build harness |
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
11. **SMS.** `ims_watchdog.sh` keeps One UI's `imsd` running and `switch_to_lineage.sh` waits for voice registration before pivoting.
12. **Boot diagnostics.** Each boot writes `/data/boot_failures.log`.

## Known issues
- Returning to One UI may still need a manual reboot.
- The guest binds the host's `media.codec`, whose AIDL hash differs from the GSI's, which can cause high CPU during codec enumeration.
- No IMS stack in the guest, so **voice calls don't work** (data and SMS depend on One UI's `imsd`).
- Developer options crash (the guest registers no `adb` service).
- DTMF tones glitch, and deep-buffer audio hangs, so it stays disabled.
- Never kill the host `netd` while Lineage is running.

## Porting kit and compatibility profiles

OneLineage now has a deliberately conservative compatibility gate. It runs **before** SELinux is changed, the host zygote is stopped, or a guest process is launched. It mounts `system.raw` read-only just long enough to read `ro.build.version.sdk`, then checks that host and guest against a bundled, parsed (never executed) profile.

The default `a16-host-a16-guest` profile preserves the existing supported path: Android 16/API 36 host plus Android 16/API 36 guest. A mismatched or unreadable image fails closed, leaving the host userspace untouched.

The preflight also creates a timestamped report in `/data/local/tmp/lineage_stage/diagnostics/`. It records the capabilities needed by the container and non-invasive evidence for the vendor camera, radio/IMS/SMS, APEX, framework, and patch hand-off. It does not claim that a present vendor service is compatible; the report is a porting starting point and a regression record.

### Android 17 guest groundwork

`profiles/a16-host-a17-guest.conf` is a **blocked-by-default experimental profile** for an Android 17/API 37 guest on an Android 16/API 36 host. It adds no promise that camera, radio, IMS, APEX, framework, or ART ABI compatibility exists. To deliberately use it for controlled testing, create this separate override after the app has staged its assets:

```sh
su -c 'printf "%s\n" "profile=a16-host-a17-guest" > /data/local/tmp/lineage_stage/user-profile.conf'
su -c 'ONELINEAGE_ALLOW_EXPERIMENTAL_GUEST=1 /data/local/tmp/lineage_stage/switch_to_lineage.sh'
```

Review the newly written diagnostic report first and keep ADB/recovery access available. The normal app boot button does **not** set the experimental opt-in, so it remains safely blocked. Remove `user-profile.conf` to return to the Android 16 profile. New profiles must contain only the numeric API ranges, `backend=container`, and `experimental=true|false`; the parser rejects profile names with shell metacharacters and never sources profile contents.

### Vendor feature triage

Before changing a profile or patching a GSI, collect the report while One UI is alive:

```sh
su -c /data/local/tmp/lineage_stage/diagnostics.sh
```

Use the `[vendor HAL: camera]` section to confirm `cameraserver`, a camera-provider service, and vendor camera modules; use `[vendor HAL: radio and messaging]` to confirm `imsd`, radio/telephony services, SIM state, and voice registration; use `[APEX and framework]` to compare host APEX availability with the guest mount and required framework patches. Re-run after a failed boot before altering the switch scripts.

### Experimental kexec backend

`kexec_backend.sh` is intentionally only a capability probe. It reports architecture, kernel exposure, kexec binary availability, and bootloader-lock state to `diagnostics/kexec-capabilities.txt`. It never executes `kexec`, invokes a kexec syscall, reboots, loads an image, or writes a partition. Run it only to gather information:

```sh
su -c /data/local/tmp/lineage_stage/kexec_backend.sh
```

An execution backend is out of scope until a device-specific, independently reviewed recovery path and kernel support are available. A locked bootloader must not be treated as bypassable.

On the tested SM-S948U kernel, ARM64 advertises architectural kexec support, but Samsung compiled both `CONFIG_KEXEC` and `CONFIG_KEXEC_FILE` out. A userspace loader cannot restore missing kernel code, and a normal module cannot toggle those configuration options. Supporting this kernel would require a device-specific handoff module that independently implements image placement, CPU/device shutdown, page-table teardown, and the final ARM64 soft restart. That is substantially more invasive than a regular kexec loader and must remain non-executing until it can be built against the exact Samsung kernel sources and reviewed with a tested recovery path.

The intended payload is an ARM64 XNU port for the SM-S948U. It is not an unmodified Apple kernelcache: XNU needs new Qualcomm/Samsung platform code and drivers before it can run on this hardware. The loader contract, safety stages, proposed boot descriptor, and porting milestones are documented in `docs/xnu-handoff.md`.

The project uses `dipa-studio/ios-sweet` as the primary XNU-porting reference.
Its Mach-O payload, Apple Device Tree, boot-argument, Qualcomm GIC/PSCI/UFS,
and persistent-log work are relevant, but its unlocked-bootloader `fastboot
boot` shim is not usable on this locked Samsung. See
`docs/ios-sweet-adaptation.md` for the device-specific adaptation plan and the
ABI audit of the available older Samsung source.

An initial deterministic Apple Device Tree can now be generated for QEMU-only
format and early-boot validation:

```sh
python3 tools/xnu/mk_m3q_adt.py \
  kernel/device-hardware/sm-s948u-azf1.json build/m3q-qemu.adt
python3 -m unittest tests/test_xnu_tools.py -v
```

An uncompressed candidate XNU Mach-O can be checked without packaging or
executing it:

```sh
python3 tools/xnu/inspect_macho.py path/to/kernel.macho --json
```

The inspector rejects the wrong architecture, truncated commands, invalid
segment bounds, and overlapping VM mappings. A successful report is only a
structural check and always records `safe_for_phone_execution: false`.

After building an XNU Mach-O, create the QEMU-development payload with:

```sh
python3 tools/xnu/build_payload.py kernel.development.m3q \
  build/m3q-qemu.adt build/m3q-qemu.payload --target qemu
```

This resolves the supported chained rebases, extracts the ARM64 thread entry,
flattens segments, and embeds the ADT and command line. The tool deliberately
has no phone target, loader, reboot operation, or transfer-of-control code.

The QEMU side is `tools/xnu/qemu_run.py`. It reads that payload, lays out `virt`
RAM without overlaps, builds the AArch64 `boot_args` XNU expects in `x0`, and
prints (or, with `--execute`, starts) the `qemu-system-aarch64` command. It
refuses to run until a loader image exists:

```sh
python tools/xnu/qemu_run.py build/m3q-qemu.payload \
  --boot-args build/m3q-qemu.bootargs --boot-plan build/m3q-qemu.plan.json
```

The kernel those tools consume is now reproducible. `xnu/` pins XNU
`xnu-8796.141.3` by archive SHA-256, vendors the minimal ios-sweet patch
series needed for non-Apple arm64 bring-up, adds a small OneLineage adaptation
series on top (bootstrap console parameters, a PL011 console for the QEMU
profile, and the platform-expert identity), and builds it on macOS or a
`macos-14` runner. Verify the patches offline, or build the kernel:

```sh
python3 tools/xnu/verify_xnu_series.py --fetch                  # qemu profile
python3 tools/xnu/verify_xnu_series.py --fetch --profile phone   # panel console
bash xnu/build_xnu.sh          # macOS only, qemu profile by default
```

A clean series check is only evidence about patch text; it does not build,
boot, or authorize anything on the phone. The `macos-14` workflows now build
both halves of a boot: the pinned `DEVELOPMENT`/`ARM64`/`SWEET` kernel
(`xnu-kernel-qemu`) and the AArch64 loader that places its segments and puts
`boot_args` in `x0` (`xnu-loader`). Nothing has booted yet: that needs a host
with `qemu-system-aarch64`. See `xnu/README.md` for the pins, the status table,
and the gaps still blocking the first QEMU console line.

Ongoing state and the ordered next steps are maintained in `XNU_PROGRESS.md`.

The generator deliberately uses QEMU's RAM, GIC, and timer values instead of
the phone's physical addresses. `--mode phone` refuses to create an artifact
until a safe payload region and framebuffer are established and execution is
separately authorized. Generating this ADT does not boot or modify a device.

## Building
Edit the paths at the top of `build_apk.sh` (JDK 17, Android SDK build-tools 34, android-34 platform), provide your own signing keystore, then run `./build_apk.sh`.

On Windows, install JDK 17 plus Android SDK Platform 34 and Build-Tools 34.0.0, then run:

```powershell
.\build_apk.ps1 -SdkRoot C:\path\to\Android\Sdk -JavaHome C:\path\to\jdk-17
```

The Windows build creates and reuses `keystore/debug.keystore` and writes `build/OneLineage-debug.apk` unless `-OutputApk` is supplied. Use a private release key for any distributed build.

For source-level checks, run `bash tests/test_compat_profiles.sh` on a Unix-like build machine. It validates the profile schema and checks that the kexec script remains probe-only; it does not emulate a phone, mount a real GSI, or certify vendor HAL functionality.

## Credits
LineageOS GSI builds by MisterZtr (SourceForge). LineageOS and Android are trademarks of their respective owners. Not affiliated with Samsung, Google or LineageOS.
