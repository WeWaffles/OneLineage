# Nura guest

OneNura runs a **Nura (postmarketOS / Alpine Linux) rootfs with a Phosh session** on a rooted One UI phone, using the same hot-switch idea as OneLineage: no reflashing, no mainline kernel. Nura's userland runs on Samsung's downstream Android kernel, takes DRM master on `card0` from the QTI composer, and hands the screen back to One UI on exit.

Tested on a Galaxy S26 (SM-S942U, Snapdragon "canoe" SM8850, Adreno 840) with KernelSU. Experimental; see the disclaimer in the top-level README.

## Layout
| Path | What it is |
| --- | --- |
| `stage/` | Mirrors `/data/local/tmp/nura_stage` on the phone. Scripts reference each other by that path, so push the folder as-is. |
| `probe/` | Read-only feasibility probe (`run-probe.ps1` pushes, runs and pulls results). |
| `FEASIBILITY.md` | The original feasibility study and milestone log. |
| `HANDOFF.md` | Current state, working features, and open work (cellular). |

## Quick start
1. Push `stage/` to `/data/local/tmp/nura_stage` and build the Alpine chroot at `nura_stage/rootfs` (`m1_setup.sh`, then `m80_phosh.sh`).
2. Copy `nura_wpa.conf.example` to `nura_wpa.conf` and fill in your Wi-Fi; `m100_nm_install.sh` imports it into NetworkManager.
3. Build the helpers (see below), then boot Nura: `adb shell su 0 sh /data/local/tmp/nura_stage/m99_run81.sh`
4. Back to One UI: `adb shell su 0 sh /data/local/tmp/nura_stage/m77_back.sh`

Quoting through `adb shell su 0 sh -c` breaks easily: push a script and run it instead.

## Scripts in `stage/`
**Session**
- `m99_run81.sh` → `m81_phosh_session.sh`: takeover and Phosh session (detached, logs to `m81.log`; `m90b_peek.sh` reads it)
- `m77_back.sh`: tear down and restore the Android display stack
- `m105_user.sh`, `m106_user_session.sh`, `m186_userdirs.sh`, `m138_onboard_install.sh`: guest user, session env, first run
- `m97_netup.sh`, `m95_wificonf.sh`, `m100_nm_install.sh`: networking
- `m113_sleepd.sh`, `m126_dogpet.sh`, `m131_unblank.sh`, `m132_powerkeyd.sh`, `m124_thermlog.sh`: suspend, softdog, screen wake, power key, thermals
- `m161_insess.sh`: run a script as `user` inside the live session's mount namespace

**GPU and apps**
- `m109_mesa.sh`: lfdevs Mesa (kgsl); `m136_build_glfinish.sh` + `s26_glfinish.c`: glFlush→glFinish tearing shim
- `m146_sandbox_mounts.sh`, `m150_build_bwrapwrap.sh` + `s26_bwrap_wrap.c`: Flatpak/bwrap support
- `m157`/`m159`/`m160`/`m162`: the `org.freedesktop.Platform.GL.kgsl` Flatpak GL extension

**Android-side helpers** (bionic binaries built in the chroot with gcc `-nostdlib` against the device's `/system/lib64`, no NDK)
- Audio: `s26_audiobridge.c` (`m164`), PulseAudio pipe sink → AAudio
- Camera: `s26_fakeam.c` (`m174`, stand-in binder services for cameraserver; started by `m175_camstack.sh`), `s26_camd.c` (`m179`), `s26_pwcam.c` (`m182`, PipeWire node), `s26_camfeed.sh`, `s26_camprobe.c` (`m173`)

**Cellular** (in progress; see `HANDOFF.md`)
- `m304_dds.sh`: **fixes Android mobile data** (sets the default data subscription and restarts the phone process)
- `m290_planB.sh` / `m291_pivotv2.sh`: let Android hold the data call, then pivot with targeted stops
- `m296_unwedge.sh`: QMI provisioning toggle for the `CARD_IO_ERROR` SIM wedge
- `m191_qmi_provision.sh`, `m199_build_mm.sh` (+ `s26_mm_*.c/.py` patches), `m194_mm_netport.sh` + `77-s26-modem.rules`, `m195_mm_debug.sh`, `m200_mm_connect.sh`, `muxdump.c`

**Bring-up**
- `test_kms.c`: the M2 plain-libdrm KMS test

## Not included
Alpine tarballs, APK indexes, upstream ModemManager/kwin sources and builds, and the roughly 250 one-off diagnostic scripts from bring-up. The kwin patches (TSP touch shim, phantom connector masking) were for the earlier Plasma Mobile guest; Phosh replaced it.
