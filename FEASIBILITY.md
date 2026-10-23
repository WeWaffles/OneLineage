# S26 Nura feasibility study

Goal: figure out whether we can take the [OneLineage](https://github.com/WeWaffles/OneLineage)
hot-switch approach (pivot_root container on a rooted One UI phone) and use it to run a
**Nura** (postmarketOS / Alpine Linux) rootfs instead of a LineageOS 23.2 GSI â€” on a
Galaxy S26 (non-Ultra, Snapdragon).

This is **not** a native Nura port. No mainline kernel, no device package. It would be
Nura's userland running on Samsung's downstream Android kernel.

## What OneLineage gives us that we can keep

- pivot_root staging machinery (`assets/master_prepare.sh`)
- SELinux relabeling of the staged tree + `setenforce` dance
- host `zram`, keep-host-service tricks (audio/modem/netd stay alive)
- screen hand-back on return to One UI

## What we must replace (guest side is Android-only in OneLineage)

- guest zygote / `system_server` â†’ an OpenRC-lite bootstrap or plain `init.sh` + Wayland session
- Android HAL reuse â†’ direct kernel interfaces (DRM/KMS, ALSA, QRTR)

## The five feasibility questions (probe answers these)

| # | Question | What to look at | Why it matters |
|---|----------|-----------------|----------------|
| 1 | Can userspace get DRM master for the display? | `/dev/dri/card*`, `/sys/class/drm/*/status` | Without KMS, a Wayland compositor can't own the screen. OneLineage's guest SurfaceFlinger getting the screen suggests yes, but confirm driver + nodes |
| 2 | GPU: kgsl or msm DRM? | `/sys/class/drm/*/device/driver`, `/dev/kgsl*` | Mesa (freedreno/turnip) needs **msm DRM**. kgsl â†’ no Vulkan/GL accel, software rendering (llvmpipe) only |
| 3 | Modem reachable from userspace? | `/dev/qrtr`, `/proc/net/qrtr` | pmOS ModemManager speaks QRTR/AT. If QRTR nodes exist we might (maybe) get data; calls/SMS stay on One UI regardless |
| 4 | ALSA exposed? | `/dev/snd/*`, `/proc/asound/cards` | tinyalsa already uses kernel ALSA, so PipeWire/ALSA can use `/dev/snd` â€” mixer routing by hand with tinymix |
| 5 | Container primitives OK? | user/ns mounts, overlayfs, ext4 perms, SELinux | rootfs pivot sanity |

## Files

- `probe-nura.sh` â€” read-only probe script, pushed to `/data/local/tmp` and run as root
- `run-probe.ps1` â€” pushes + runs + pulls the probe results into `results/`
- `results/` â€” captured probe output per run

## Decision point after probing â€” RESULTS (2026-10-20, SM-S942U / m1q / SM8850 "canoe")

Probe report: `results/nura_probe_20261020_162936.txt` (+ `probe2.sh` interactive checks).

| # | Question | Result |
|---|----------|--------|
| 1 | Display | âœ… msm/SDE KMS via `/dev/dri/card0`. DRM master = QTI composer HAL (`vendor.qti.hardware.display.composer-service`); OneLineage's GSI binds it via hwbinder, we must instead stop it and take master directly. Backlight = `/sys/class/backlight/panel0-backlight` |
| 2 | GPU | âœ… (conditional) kgsl, `CONFIG_DRM_MSM` off â€” but mesa turnip has an official **kgsl KMD backend** and 26.x supports Adreno 8xx; zink-on-turnip for GL. Needs a musl build (recipes public: Droid-Deck/Drivers, lfdevs). v1 fallback = llvmpipe |
| 3 | Modem | ðŸŸ¢ better than expected: `QIPCRTR` protocol family live + `[qrtr_rx]` kthreads; `AF_QIPCRTR` sockets reachable. uqmi/ModemManager data attempt worthwhile. No calls/SMS in guest regardless |
| 4 | Audio | âœ… `canoe-snd-card` kernel ALSA, 40+ PCMs; PipeWire + manual tinymix routing |
| 5 | Container | âœ… `unshare -m` ok, overlayfs ok, NET_NS ok, USER_NS off (n/a for root), SELinux Enforcing (same OneLineage dance), 196G free |

**Input**: `sec_touchscreen` = plain evdev MT-B touchscreen (event7; kernel-correct) — but see M4-touch: **libinput misclassifies it as a touchpad/pointer**; kwin needs the TSP shim patch.
**Root**: KernelSU (DirtyFrag), su at `/system/bin/su` after enabling ADB root. busybox at `/data/adb/ksu/bin/busybox`.
**Verdict**: container hot-switch is **go**. Architecture = fork OneLineage, keep pivot/SELinux/host-service machinery, guest = Nura rootfs + own init + Wayland compositor taking KMS master on card0.

### Phase-2 milestones
- **M1** â€” âœ… DONE (2026-10-20): Alpine 3.24.2 chroot at `/data/local/tmp/nura_stage/rootfs`, gcc+libdrm installed, test tool built
- **M2** â€” âœ… **PASSED** (2026-10-20): stop QTI composer+allocator+host SF â†’ `drmSetMaster` OK from chroot â†’ **solid-color commit on 1080x2340@120Hz panel via plain libdrm** â†’ clean restore (`ctl.start` composer/allocator/SF). Pretest confirmed EBUSY while composer alive. SELinux enforcing throughout. Scripts: `m2_take.sh` / `m2_undo.sh` / `test_kms.c`

Fallback if M2 fails: Nura inside the Lineage guest (proot), or fling via Wayland-over-X11-in-Android.
- **M5** - fork OneLineage into a "OneNura" app: switch-to-Nura / return-to-OneUI
- **M3b** - PASSED (2026-10-20 late): patched kwin 6.6.6 renders foot client AND owns the panel under Plasma Mobile target! Update checklist: (1) connector truth map corrected - conn 70 type = DSI = THE PANEL (1 mode 1080x2340x120, card0-DSI-1); conn 34/67 type = VIRTUAL = phantom writeback/backlight mirrors with 37 fake modes (SDE quirk) - MUST be masked or every compositor misroutes; conn 91 = DP-1 disconnected. (2) KWIN_DRM_NO_AMS=1 env var IS honored in kwin 6.6.6 (switches DrmGpu to full legacy drmModeSetCrtc/PageFlip path). (3) kwin source patches (kwin-src/kwin-v6.6.6/src/backends/drm/): drm_connector.cpp masks phantom VIRTUAL connectors as disconnected + filters DSI no-EDID mode lists to panel family; drm_pipeline_legacy.cpp treats missing gamma LUT (ENOSYS) and failing hw-cursor ioctls as non-fatal (sde has neither legacy gamma ramp nor hw cursor plane). (4) Built kwin in-chroot (gcc 15.2, samurai/ninja, ~20 min for 3057 targets; install over /usr); build deps 4.2 GB incl. knighttime-dev/libei-dev. kwin.log zero fatal lines; kernel confirms card0-DSI-1 enabled + dpms On. Cursor theme still missing (breeze pkg has no cursors on Alpine) - cosmetic, hw/sw cursor disabled. plasma-shell/plasma-nano UI stack + maliit kb are the next client-side items.
- **M4-touch** - **PASSED (2026-10-20 late)**: REAL finger touch in the guest session (no more ghost-cursor clicks). Root cause chain: (a) kernel `sec_touchscreen` (event7) is a proper MT-B touchscreen (ABS_MT_SLOT/TRACKING_ID/POSITION_X/Y, BTN_TOUCH, axes 0..4095) but has no `INPUT_PROP_DIRECT` and NO BTN_LEFT in kernel caps; (b) libinput 1.31.3 therefore classifies it touch/pointer-wise WRONG: kwin sees `capa touch=0 pointer=1` → treats as touchpad/pointer → every tap = synthesized `BTN_LEFT` pointer click at the stale parked-cursor position (user complaint "taps don't work"), drags = pointer motion (worked by accident); (c) seat `hasTouch=yes` came spuriously from `haechitech-digital-hall` (EV_REL hall sensor misflagged touch+pointer+keyboard!), masking the truth (clients thought touch existed, raw `wl_touch` never flowed). ALSO: kwin `/dev/input/event7` sit inside the TSP: **kwin patch #4 "TSP shim"** (src/backends/libinput/connection.{h,cpp}): on DEVICE_ADDED for `sec_touchscreen`/`sec_touchpad` (kwin Device sysName → /dev/input/<sysName>), open the node directly, parse raw MT-B events (slot/tracking-id/position, own QSocketNotifier), convert kernel 0..4095 axes onto `workspace()->geometry()` px, and Q_EMIT real `touchDown/touchMotion/touchUp/touchFrame` on the same kwin Device so the standard TouchInputRedirection → seat filter chain (verified: `processDown → findToplevel → notifyTouchDown → TouchInterface::sendDown (touchResources=1)`) delivers genuine `wl_touch` to clients; all libinput pointer/keyboard/scroll events from those nodes are swallowed. Result: plasmashell reacts at the tapped spot (top bar, drawer). **No launcher changes needed** — fix lives inside patched kwin. Diagnostic scripts: `m61..m67*.sh` (registry probe, wl_touch probe client `touchc.c` with WAYLAND_DEBUG, evdump). TODO: quiet the NWU-* fprintf probes on next rebuild; verify long-press/gestures + maliit keyboard still compete correctly with touch.
- **M3c** - typing/input polish (interim under sway) / maliit under kwin; plasma-shell/nano UI; cursor theme package hunt
- **M4** - real pmbootstrap-built Nura rootfs (plasma-mobile variant); PipeWire audio; on-screen keyboard (maliit, KDE); net; modem via uqmi; Mesa kgsl turnip build
- **M5** - fork OneLineage into a "OneNura" app: switch-to-Nura / return-to-OneUI
