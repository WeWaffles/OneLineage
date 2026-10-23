# OneNura

Hot-switch between stock **One UI** and **Nura (postmarketOS / Alpine Linux) with a Phosh session** on a rooted Samsung phone, with no reflashing, no second partition and no mainline kernel. Nura's userland runs on Samsung's downstream Android kernel: it takes DRM master on `card0` from the QTI composer, drives the panel itself, and hands the screen back to One UI on exit.

OneNura is a branch of [OneLineage](https://github.com/WeWaffles/OneLineage), which does the same with a LineageOS GSI. It reuses OneLineage's staging and SELinux handling and its approach of keeping the host's services alive.

If something isn't working and you have a fix feel free to make a pr!

> ## Disclaimer
> **This has been tested on one device (Galaxy S26, SM-S942U, Snapdragon) and is very much a work in progress.**
> It may not work on other Samsung models, other One UI versions, or other devices at all. It is experimental, it replaces core parts of a running system, and it can crash, hang or soft-brick your phone, fill `/data`, or break radio/SMS. **Back up everything first. Use at your own risk.**
> Also, I did use AI a fair bit in this project, it would have taken a LOT longer without it.

## Requirements
- A rooted Samsung phone (tested: Galaxy S26 SM-S942U, Snapdragon "canoe" SM8850, Adreno 840, One UI 8.5, KernelSU)
- A few GB free on `/data` for the Alpine rootfs
- Internet access on the phone for Alpine packages

## Status
| Feature | State |
| --- | --- |
| Display, touch, Phosh UI | Working |
| GPU (lfdevs Mesa, kgsl) | Working, with a glFlush→glFinish shim against tearing |
| Wi-Fi (NetworkManager) | Working |
| Audio | Working (PulseAudio pipe sink → AAudio bridge on the Android side) |
| Camera | Working (stand-in binder services for cameraserver, PipeWire camera node) |
| Flatpak / Flathub, incl. GPU | Working |
| Screen off/on, suspend | Working (suspend only while unplugged from USB) |
| Mobile data | Working over IPv6 with the Plan C session (`m306_planC.sh`); IPv4-only sites need 464XLAT, not done yet |
| SMS, calls | Not yet |
| Switch-to-Nura app | Not yet; Nura is started from scripts for now |

## Quick start
1. Push `stage/` to `/data/local/tmp/nura_stage` and build the Alpine chroot at `nura_stage/rootfs` (`m1_setup.sh`, then `m80_phosh.sh`).
2. Copy `stage/nura_wpa.conf.example` to `nura_wpa.conf` and fill in your Wi-Fi; `m100_nm_install.sh` imports it into NetworkManager.
3. Build the helpers (see below), then boot Nura: `adb shell su 0 sh /data/local/tmp/nura_stage/m99_run81.sh`
   For mobile data, boot with `m306_planC.sh` instead (build `s26_dogsteal` first with `m307_build_dogsteal.sh`). It freezes the Android framework rather than stopping it, so Android's LTE call survives and Nura reuses it.
4. Back to One UI: `adb shell su 0 sh /data/local/tmp/nura_stage/m77_back.sh`

Quoting through `adb shell su 0 sh -c` breaks easily: push a script and run it instead.

## What's in here
| Path | What it is |
| --- | --- |
| `stage/` | Mirrors `/data/local/tmp/nura_stage` on the phone. Scripts reference each other by that path, so push the folder as-is. |
| `probe/` | Read-only feasibility probe (`run-probe.ps1` pushes, runs and pulls results). |
| `FEASIBILITY.md` | The original feasibility study and milestone log. |
| `HANDOFF.md` | Detailed current state and open work. |
| `src/`, `res/`, `AndroidManifest.xml`, `assets/`, `build_apk.sh` | The OneLineage app and container scripts, kept as the base for the OneNura app |

## Scripts in `stage/`
**Session**
- `m99_run81.sh` → `m81_phosh_session.sh`: takeover and Phosh session (detached, logs to `m81.log`; `m90b_peek.sh` reads it)
- `m77_back.sh`: tear down and restore the Android display stack
- `m105_user.sh`, `m106_user_session.sh`, `m186_userdirs.sh`, `m138_onboard_install.sh`: guest user, session env, first run
- `m97_netup.sh`, `m95_wificonf.sh`, `m100_nm_install.sh`: networking
- `m113_sleepd.sh`, `m126_dogpet.sh`, `m131_unblank.sh`, `m132_powerkeyd.sh`, `m124_thermlog.sh`: suspend, softdog, screen wake, power key, thermals
- `m161_insess.sh`: run a script as `user` inside the live session's mount namespace

**GPU and apps**
- `m109_mesa.sh`: lfdevs Mesa (kgsl); `m136_build_glfinish.sh` + `s26_glfinish.c`: tearing shim
- `m146_sandbox_mounts.sh`, `m150_build_bwrapwrap.sh` + `s26_bwrap_wrap.c`: Flatpak/bwrap support
- `m157`/`m159`/`m160`/`m162`: the `org.freedesktop.Platform.GL.kgsl` Flatpak GL extension

**Android-side helpers** (bionic binaries built in the chroot with gcc `-nostdlib` against the device's `/system/lib64`, no NDK)
- Audio: `s26_audiobridge.c` (`m164`)
- Camera: `s26_fakeam.c` (`m174`, started by `m175_camstack.sh`), `s26_camd.c` (`m179`), `s26_pwcam.c` (`m182`), `s26_camfeed.sh`, `s26_camprobe.c` (`m173`)

**Cellular**
- `m306_planC.sh` → `m305_pivotv3.sh`: the data-capable session. Killing zygote kills `com.android.phone`, and Samsung's rild restarts with its client, dropping every data call. So Plan C SIGSTOPs the framework instead (only the composer dies, to free DRM master) and reuses Android's `rmnet_data0`.
- `s26_dogsteal.c` (`m307`): the frozen system_server still holds `/dev/watchdog`, so `m126_dogpet.sh` pets Samsung's softdog through system_server's own fd (`pidfd_getfd`) instead of panicking
- `m304_dds.sh`: fixes Android mobile data (default data subscription and SIM slot, then restarts the phone process); `m77_back.sh` re-applies it after a framework restart
- `m290_planB.sh` / `m291_pivotv2.sh`: the earlier targeted-stop attempt (the call doesn't survive it)
- `m296_unwedge.sh`: QMI provisioning toggle for the `CARD_IO_ERROR` SIM wedge
- `m191_qmi_provision.sh`, `m199_build_mm.sh` (+ `s26_mm_*.c/.py` patches), `m194_mm_netport.sh` + `77-s26-modem.rules`, `m195_mm_debug.sh`, `m200_mm_connect.sh`, `muxdump.c`

**Bring-up**
- `test_kms.c`: the plain-libdrm KMS test

## Known issues
- Real suspend only works while unplugged from USB, and adb doesn't recover after suspend while plugged in.
- `vendor.usbudev` crash-loops every ~10 s while Nura runs.
- No IPv4 over LTE yet (T-Mobile is IPv6-only; Android's CLAT doesn't survive the freeze).
- Camera and audio aren't re-verified under Plan C (their Android services may block on the frozen system_server).
- `m81_phosh_session.sh` (the non-data session) still has no IPv6 route on Wi-Fi; Plan C fixes this with an `ip -6 rule`.
- The guest user is uid 1000 (same as Android `system`): never `pkill -u user`.

## Credits
Built on OneLineage. postmarketOS, Alpine Linux, Phosh, Mesa (lfdevs kgsl builds) and ModemManager belong to their respective projects. Not affiliated with Samsung, Google, postmarketOS or Alpine.
