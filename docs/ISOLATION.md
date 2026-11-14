# Full isolation plan: Lineage with its own system

Goal: nothing Lineage does can change One UI. Today the guest shares One UI's
binder service registry, property store and network stack, so its system_server
talks directly to One UI's vold, keystore2, gatekeeper and Weaver HAL.

## Target architecture

```
 One UI side (host)                         Lineage side (guest)
 ------------------                         --------------------
 /dev/binderfs/binder  (host registry)      <rootfs>/dev/binderfs  (NEW private binderfs mount)
 host servicemanager                        guest servicemanager / hwservicemanager / vndservicemanager
 vold, keystore2, gatekeeperd, Weaver  X    guest keystore2 (software), guest gatekeeperd (software),
                                            NO Weaver, guest vold stub
 audio/camera/radio/codec HALs  <-------->  ol_binder_bridge (forwards an ALLOWLIST of services only)
 /dev/__properties__ (host props)      X    guest property area (own init in second stage)
 host net namespace                    X    guest net namespace + veth (or forwarded netd)
```

`X` = no path between the two sides. The only connection is the bridge, and it
only forwards hardware services on the allowlist. Security services are never on it.

## Phases (each can be tested on its own)

1. **Private binder registry.** Mount a new binderfs instance inside the
   container (`mount -t binder binder <rootfs>/dev/binderfs`; Linux 5.0+
   supports multiple instances), and start the guest's own servicemanager,
   hwservicemanager and vndservicemanager on it before zygote.
   *Check:* `service list` inside the container shows only guest services.
2. **Guest security stack.** Start the GSI's keystore2 and gatekeeperd with a
   software keymint/gatekeeper (AOSP `android.hardware.security.keymint-service`
   default / `android.hardware.gatekeeper-service.software`), with no Weaver.
   Lock state is in the guest's /data only.
   *Check:* `HLOG_WEAVER_WRITE` and host `/data/misc/vold`, keystore and
   gatekeeper are byte-identical before and after a session.
3. **Binder bridge (`ol_binder_bridge`, native, aarch64).** For each allowlisted
   service, get it from the host registry and register a forwarding stub in
   the guest registry (raw transaction passthrough, including fd and binder
   object translation). Start the allowlist with: audio HAL, audioserver,
   cameraserver, media.player/Codec2, radio HALs (IRadio*), power, light,
   sensors, composer/allocator (SurfaceFlinger), vibrator, health, usb.
   *Check:* each service works in Lineage one at a time.
4. **Own property area.** Run a small guest init stage that creates the guest's
   own `/dev/__properties__` and `/data/property` in the container, so
   `persist.*` and runtime props never reach One UI.
5. **Own network namespace.** `unshare -n` plus a veth pair (or forward netd
   through the bridge), which removes the host ip rule and bpf map edits.
6. **Remove the save/restore guards** (lock_guard restore, launcher backup,
   batterystats reset) once phases 1–5 make them unnecessary. Keep the
   checksum checks as a regression test.

## Findings (S26 Ultra, SM-S948U, One UI 8.5)

- **Phase 1 probe passed.** A second binderfs instance mounts; guest
  servicemanager, hwservicemanager and vndservicemanager run on it and the
  private registry starts empty. Log: `logs/isolation/probe.log`.
- **The Lineage GSI has no software KeyMint or gatekeeper HAL.** It ships the
  framework daemons (`keystore2`, `gatekeeperd`, `credstore`) and the
  `libkeymint_fake_latest.so` library, but no HAL service binary. So phase 2
  cannot run on its own, and the order changes:
  - **KeyMint, secure clock, shared secret:** forward the host's TEE HALs
    through the bridge. They hold no per-device state that guest calls change.
    Key blobs live in the guest's own keystore2 database in the guest's
    `/data`, so One UI's `/data/misc/keystore` is never written.
  - **Gatekeeper:** forward the host HAL, with the guest's own `gatekeeperd`
    keeping its handles in the guest's `/data/misc/gatekeeper`.
  - **Weaver:** never forwarded. The guest gets a tiny stub `IWeaver` on its
    private registry that fails `getConfig()`, so LockSettings treats Weaver
    as unavailable instead of waiting for it (the 66 s watchdog deadlock).
    Buildable with the NDK (`libbinder_ndk`).
  - **vold:** the guest already runs its own `vold`; on the private registry
    it stops replacing One UI's `vold` registration.
- Revised order: **phase 3 (bridge) first**, then phase 2 is just "start the
  guest's keystore2/gatekeeperd/vold plus the Weaver stub on the private
  registry".

## Risks

- Phase 3 is the core of the work: the bridge has to translate binder objects
  and fds correctly for every forwarded interface, and some vendor HALs keep
  per-client state.
- Hardware that allows only one client (display, fingerprint, modem) still
  needs a handover, as the scripts already do for wificond.
- Each phase must be tested on a device; none of it can be checked from a PC.
