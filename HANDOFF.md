# S26 Nura — handoff (2026-10-22)

Galaxy S26 (SM-S942U, Snapdragon "canoe", Adreno 840, KernelSU). Alpine 3.24 chroot at
`/data/local/tmp/nura_stage/rootfs`, Phosh UI taking over the display from Android. Guest user `user`
(uid 1000 — same as Android `system`: never `pkill -u user`; kill by `/proc/PID/root`).

- Boot Nura: `adb shell su 0 sh /data/local/tmp/nura_stage/m99_run81.sh`
- Back to One UI: `adb shell su 0 sh /data/local/tmp/nura_stage/m77_back.sh`
- Script quoting through `adb shell su 0 sh -c` breaks easily → push a script file and run it.
- Run as `user` in the live session's mount namespace: `m161_insess.sh <script>` (script pushed to the stage dir).
- Root in the session ns: `busybox nsenter -t $(pidof phosh) -m chroot $R ...`.
- PowerShell `Set-Content` adds a BOM / mangles UTF-8. Write files with the Write tool or `[IO.File]::WriteAllText` with UTF8 (no BOM).

## Working (verified)

### Display and session
- **Wi-Fi:** NetworkManager in the guest; `ip rule pref 31999`.
- **GPU:** lfdevs Mesa (kgsl). There is a glFlush→glFinish shim against tearing.
- **Screen and power:**
  - Screen off/on: softdog petter (m126) plus the gdbus unblank (m131/m132).
  - Real suspend (m113) works only while unplugged from the PC.

### Apps
- **Flathub in Software:**
  - setuid bwrap 0.10 plus the wrapper `s26_bwrap_wrap.c`, which always adds `--new-session`.
  - setuid fusermount3 from suid.img (m146).
  - The app-grid filter is off.
- **Flathub on the GPU:** unmanaged extension `org.freedesktop.Platform.GL.kgsl` (branches 24.08/25.08/26.08) — m157/m159/m160/m162.
- **PipeWire RT module is off** (m106 writes `module.rt=false`). Otherwise RLIMIT_RTTIME=0 and the kernel SIGKILLs apps.

### Audio
- PulseAudio pipe sink → FIFO → `s26_audiobridge` (bionic, AAudio).
- The bridge also initialises the AudioSystem stream volumes; system_server is gone, so they would otherwise be NaN.
- Volume keys go through `gsd-media-keys`.

### Camera (user confirmed photos work)
- **Android side:**
  - `s26_fakeam` stand-in binder services (m175) replace the system_server/surfaceflinger services cameraserver needs.
  - `s26_camd` (bionic NDK camera → NV12 FIFO).
- **Nura side:** `s26-pwcam`, a PipeWire driver node that rotates and converts to BGRx with timestamps; started by `s26-camfeed`.
- **Settings and folders:**
  - Resolution is in `rootfs/var/lib/s26cam/res` (1920 1440).
  - XDG user dirs (m186).

### Building Android-side tools without the NDK
Chroot gcc `-nostdlib`, linked against the device's `/system/lib64/*.so`, with a hand-written `_start` → `__libc_init`. Templates: m164, m173, m174, m179.

Memory notes with details: `guest-ui-phosh`, `nura-audio`, `nura-camera`, `s26-touch-wake`.

## In progress: cellular (user wants data + SMS first; calls later)

### Findings
- **Modem access:** QMI over QRTR works from the guest (`qmicli -d qrtr://0`, packages `libqmi qmi-utils qrtr`).
- **SIM layout:** the SIM is the **eSIM in physical slot 2**, provisioned by Android as the *Secondary GW* subscription. Slot 1 (the tray) is empty. T-Mobile; 5G SA available.
- **Provisioning swap (m191):** `m191_qmi_provision.sh primary|secondary` moves the eSIM USIM between the primary and secondary provisioning session.
  - The user approved **runtime-only** modem changes.
  - With primary, the modem registered within 5 s.
  - **It is currently set back to `secondary` (Android's layout).**
- **ModemManager:** upstream main is built in the chroot by **m199** and installed over Alpine's. It has three patches:
  1. Skip QMI LOC XTRA probing (use-after-free crash ~5 s after start).
  2. `rmnet_ipa0` (no sysfs driver) reports driver `ipa`.
  3. Lower-device lookup falls back to `iflink` (`s26_mm_lowerdev.c`): vendor rmnet has no `lower_*` links.

  Plus a compat sed for `QMI_VOICE_CALL_STATE_PRE_ALERTING`.
- **udev rule** `rootfs/etc/udev/rules.d/77-s26-modem.rules` (m194), for `rmnet_ipa0|qmapmux*`:
  - `ID_MM_CANDIDATE`
  - `ID_MM_DEVICE_PROCESS`
  - `ID_MM_PHYSDEV_UID=qcom-soc`
  - `ID_MM_INITIAL_QMAP_MUX_ID=20` (Android owns mux 1–15 via rmnet_data0..14 — don't delete those)
- **Debug logging:** the ModemManager D-Bus service file `Exec` was changed to log debug output to `/var/log/mm.log` (m195). Revert it when done.
- **ModemManager result:** with primary provisioning it shows the modem registered on 5G with the phone number. `mmcli --simple-connect` (m200) creates the qmapmux link and binds mux 20/21. **The modem then returns `CallFailed: cm no-service`.**

### Likely cause and next steps
**Likely cause:** the default data subscription (DDS) is still on subscription 2 (Android's layout), so data on the primary-provisioned SIM is refused.

**Next options:**
1. Keep Android's layout (SIM = secondary) and make ModemManager use subscription 2. libqmi has `QMI_MESSAGE_WDS_BIND_SUBSCRIPTION` (also QOS). Patch MM's bearer to call WDS Bind Subscription (secondary) after allocating its WDS clients. NAS/WMS for SMS may also need subscription binding (UIM uses session types).
2. Or find and send the QMI DSD/NAS DDS-switch message (not in libqmi) with a raw QMI message.

**Then:**
- T-Mobile is IPv6-only, so 464XLAT (clat) is needed for IPv4.
- SMS via MM's Messaging interface or chatty.

### Not yet wired into boot
ModemManager only runs when D-Bus activates it (NetworkManager does). Provisioning is manual (m191). Nothing cellular runs in m81.

## Cellular data - 2026-10-22 evening findings (Plan B work, data NOT working yet)

- **Plan A (MM reuses Android's rmnet_data14/mux 15) is mechanically done but data-plane dead** — bearer
  connects over QMI, IPA still drops traffic (no DPM endpoint sysfs on this phone; MM skips DPM open).
  Scripts kept: s26_mm_reuse.py, m199_build_mm.sh, udev rule `77-s26-modem.rules` (+.bak20 on device).
- **Plan B (pivot v2)**: m290_planB.sh + m291_pivotv2.sh — Android brings up the data call, pivot with
  **targeted stops only** (zygote/sf/composer/cameraserver/wificond — NO blanket `stop`, which kills
  rild/ipacm/netd: they are all `class main`). NM gets `unmanaged-devices=...rmnet_data*` first
  (`99-s26-rmnet.conf`). Blocked on Android holding a call — see below.
- **SIM wedge ritual (fixes CARD_IO_ERROR-only state)**: after some boots, `gsm.sim.state` stuck
  `READY,CARD_IO_ERROR`, `dumpsys isub` shows NO "Logical SIM slot sub id" binding (subId=-1) and
  framework NEVER attempts data calls. Plain reboots/airplane cycles do NOT fix. **m296_unwedge.sh**
  (QMI provisioning toggle via chroot qmicli, NO phosh needed: sec-activate → primary → back →
  secondary) gets it to `LOADED,CARD_IO_ERROR` and the sub binds (slot 0 -> subId=1, defaultSubId=1).
  The "could not power off SIM: NoEffect/Internal" qmicli errors are benign. Remaining
  `CARD_IO_ERROR` = the empty second eSIM port, benign.
- **The real blocker for plan B** (why Android never holds an internet call): telephony only ever
  creates the **IMS** DataNetwork (from com.sec.imsservice request; ifname rmnet_data1, works). Every
  default/INTERNET NetworkRequest is refused by TNP (`onNetworkNeeded: Not applied`), while
  CELLULAR-transport requests go through. Gate is Samsung `PhoneSwitcherForMultiSim` (system_server):
  `mPrimaryDataSubId(-1) is not valid` -> `updatePreferredDataPhoneId: mPreferredDataPhoneId = -1(NOCARD)`.
- Samsung MSIM settings tried: `settings put global multi_sim_data_call 1 / multi_sim_data_call_slot 0`
  (values seen: -1/1 pre-existing; no effect on NOCARD; reverted at end of session).
  `cmd phone restart-modem` exists but was not actually verified (PowerShell `head` error killed it).
- 22:07 capture: once a DN connects briefly (`DN-100-C ConnectedState` ~30 s) it drops again;
  `mDataConnectionState=0`. Teardown/validation reason not yet captured cleanly (main buffer is BLE/
  Nearby noise; filter on `DNC-0|DN-100|TNP|TelephonyRegistry` in `-b main,radio`, and capture while
  `svc data disable/enable`).
- Also seen good earlier: SST-0 Voice AND Data IN_SERVICE NR_SA once the sub is bound; standard
  PhoneSwitcher "Found an active enabled subscription" is healthy — the Samsung MSIM switcher is the
  suspect. Next session: deduce where `mPrimaryDataSubId` comes from (decompile
  PhoneSwitcherForMultiSim in /system/framework/telephony-common.jar?), or restart-modem properly,
  or run plan B pivot anyway (rild/ipacm/netd survive; a live IMS+default call set could still give
  usable v6 internet via rmnet_data1 if the framework ever holds it 2–3 min).
- Phone left in: One UI, airplane off, Wi-Fi on, `multi_sim_*` settings reverted, sub bound. mmcli
  syntax note: `mmcli -b 0` (not `-b any`). `su 0 sh <script>` for root cmds. `muxdump` in chroot.
  Chroot without phosh: busybox `mount --bind /dev,/proc,/sys` into $CHROOT then `chroot` directly (m296).

## Cellular data FIXED on Android side - 2026-10-23
- Root cause of NOCARD / INTERNET refusals: `dumpsys isub` showed `defaultDataSubId=-1`.
- Fix: `settings put global multi_sim_data_call 1` **then kill com.android.phone** (SubscriptionManagerService
  only reads it at init; setting it alone, as on 10-22, does nothing). Script: scratchpad dds.sh logic —
  `su 0 sh`, ps/awk for the pid (pidof quoting breaks via PowerShell; push scripts instead).
- Result: `defaultDataSubId=1`, internet DN `fast.t-mobile.com` comes up next to IMS, wifi off → ping6 and
  IPv4 (Android clat) both work. Unblocks Plan B pivot (m290/m291). Needs re-check after reboot.

## Cellular data WORKING IN NURA - 2026-10-23 (Plan C: freeze, don't kill)
Run: `adb shell su 0 sh /data/local/tmp/nura_stage/m306_planC.sh` (from a booted One UI). Back: m77 as usual.
Verified: Phosh up, Wi-Fi (NM) connected, HTTPS on Wi-Fi; Wi-Fi disconnected -> HTTPS over LTE (v6) via
rmnet_data0; Wi-Fi reconnects; m77 returns to One UI without a reboot. 14+ min stable.
- **Why Plan B died:** stopping zygote kills com.android.phone; Samsung rild + multiclientd restart within
  ~0.3 s of losing their client and every rmnet_data link is torn down (proven step by step, exp.sh).
- **m305_pivotv3.sh** (from m291): SIGSTOPs zygotes, all zygote children except com.android.phone /
  com.sec.imsservice, and surfaceflinger; kills only the composer (DRM master). Frozen pids -> frozen.pids.
- **Softdog:** the frozen system_server keeps /dev/watchdog open (single opener) but stops petting ->
  "Software Watchdog Timer expired" panic (2 reboots). **s26_dogsteal.c** (m307 builds it) uses
  pidfd_getfd to pet through system_server's own fd. m126 checks for a holder BEFORE `exec 3>` (a failed
  exec redirection exits sh, so the old `|| fallback` never ran). m305 starts m126 right after the freeze.
- **Wi-Fi:** the live vendor Wi-Fi HAL rfkill-blocks the chip when wificond/supplicant go -> m305 clears
  rfkill soft, NM `radio wifi on`.
- **IPv6:** `ip -6 rule add pref 31999 from all lookup main` was missing (v4 only before) -> this is also the
  old "no IPv6 route on Wi-Fi" item. resolv.conf static (1.1.1.1 + Cloudflare/Google v6), NM dns=none.
- **DDS:** `multi_sim_data_call_slot` must be 0 (was 1 = empty slot). Survives cold boot and phone restart;
  a full framework restart races the SIM and resets it -> m77 re-runs m304 in the background.
- **m77:** thaws + kills only still-stopped frozen pids (stale file after reboot is safe), stops s26_dogsteal.
- **Open:** no IPv4 on LTE (Android clat doesn't survive; need tayga/clatd in Nura: github.com fails on LTE
  only). Camera/audio under Plan C not re-verified (audioserver/cameraserver may block on the frozen
  system_server). SMS next. m81 (kill path) still the default session; m306 is the data-capable one.

## Smaller open items
- `vendor.usbudev` crash-loops every ~10 s under Nura (init restarts it).
- USB/adb doesn't recover after suspend while plugged in.
- No IPv6 route on Wi-Fi.
- 12 MP stills would need a still-capture path in Snapshot/aperture.

## 2026-10-22 late-night session: NOCARD root-cause hunt (data still broken in One UI)
Timeline: phosh session, normal reboot -> sub wedge -> m296 unwedge fixed binding (persists across
reboots: `LOADED,CARD_IO_ERROR`, `Logical SIM slot 0: subId=1`, `defaultSubId=1`). Data in One UI
STILL broken: PhoneGlobals `mDefaultDataSubId=-1`, `Active default network: none`, only the IMS
DataNetwork connects (rmnet_data1, v6). Verified post-reboot once more - persistent.

### Decompiled code findings (baksmali 3.0.10) - READ CAREFULLY, this is the morning roadmap
- Tooling: java 27 on PC; `baksmali.jar` = baksmali-3.0.10-fat.jar from
  `https://github.com/baksmali/smali/releases/download/3.0.10/baksmali-3.0.10-fat.jar` (tag has NO `v`!;
  JesusFreke repo has no releases; org/smali 2.5.2 fat jar does not exist). Usage:
  `java -jar $env:TEMP\opencode\baksmali.jar d -o <outdir> <classes.dex>`.
- Jars pulled+disassembled into $env:TEMP\opencode\:
  - telephony-common.jar -> tcx/classes.dex -> **smali_out** (Samsung PhoneSwitcher code HERE)
  - framework.jar (7 dex) -> fwsmali..fwsmali7
  - services.jar -> svx/svsmali; framework-telephony.jar (apex telephonycore) -> ftcx/ftcsmali
  - TeleService.apk (/system/priv-app/TeleService) -> telex/telesmali
- **PhoneSwitcher.onEvaluate()** copies `mSubscriptionManagerService.getDefaultDataSubId()` into
  `mPrimaryDataSubId` (every re-eval). `getDefaultDataSubId()` returns an in-memory WatchedInt that
  dumpsys prints as `defaultSubId=1` - so the value SHOULD be 1, yet mPrimaryDataSubId stays -1 at
  runtime while NOCARD logs continue. Either onEvaluate is not re-running with the bound sub, or a
  Samsung path overrides it ( suspect: `PhoneSwitcherForMultiSm`... check `setCommandReasonAndAutoDataSubId()`).
- `getFallbackDataPhoneIdForInternetRequests()` (PhoneSwitcher.smali line ~3822):
  `subId = isActiveSubId(mAutoSelectedDataSubId) ? mAutoSelectedDataSubId : mPrimaryDataSubId`
  then for MultiSim switcher: `setFallbackSubIdWithRequestSubId(subId)` (routes through
  `mModemDependency.processRequestOverride`); then scans `mPhoneSubscriptions[i]` - unusable -> -1 NOCARD.
- `SubscriptionManagerService.setDefaultDataSubId(I)` exists, gated by
  `MODIFY_PHONE_STATE`; also `PhoneSwitcherForMultiSim.recoverDds(I)` internally recalls it.
  MultiSimSettingController and `com.samsung.telephonyui.callsettings.SamsungTuiCallFunctions
  .setDefaultDataSubId(Bundle)` (in TeleService!) also call it - the TUI path is a possible user-free opener.
- **KEY WORTH ITS WEIGHT: the binder interface is the legacy `com.android.internal.telephony.ISub`
  (SubscriptionManagerService `extends ISub$Stub`). Its Stub is in framework.jar fwsmali6 (.../telephony/ISub$Stub.smali),
  and `TRANSACTION_setDefaultDataSubId:I = 0x1f` (= 31).**
- `com.android.shell` HAS `android.permission.MODIFY_PHONE_STATE: granted=true` (dumpsys package
  com.android.shell). So plain adb shell (uid 2000, no su) can call it:
  `adb shell "service call isub 31 i32 1"` (1 = our T-Mobile subId). Verify dispatcher case 31 ->
  setDefaultDataSubId first (morning step 1), then: check `dumpsys phone|isub`, run
  `svc data disable; svc data enable`, watch for TNP applying the INTERNET request + DN created.
  If it throws SecurityException, try `adb shell` w/o su verbatim, or root variant, or the TUI path.
- Also worth trying in parallel: Samsung SIM Manager UI route (Settings -> Connections -> SIM manager
  / `am start` the correct SIM preference activity - earlier `android.settings.SIM_PREFERENCE_SETTINGS`
  did not resolve; find the real component: `adb shell cmd package query-intent-activities ...`, or
  `pm resolve-activity`; `com.samsung.android.simagemanager`?) - a manual default-data-SIM selection
  would run Samsung's own code path end to end.

### Blocked / disproven tonight
- Provisioning-session flips (test the 'wrong slot' hypothesis): qmicli change-provisioning-session
  ABORTS before committing on activate because the modem refuses SIM power-off
  (`QMI protocol error 3: 'Internal'`) - even in airplane mode (m303). Deactivate attempt reported
  success but left layout unchanged. Layout STUCK: `Primary GW: slot '1', application '1'`,
  Secondary GW nonexistent. Hmm note: with primary active the sub lands on logical slot 0, while
  Samsung's MSIM settings (`multi_sim_existing_data_call=1`, `multi_sim_*_slot=1`) keep pointing at
  slot 1 - possible mismatch the switcher drowns on; could not be altered at runtime.
- `cmd phone restart-modem` -> Permission denied (shell AND su).
- Device was unplugged at session end; phone left in One UI, airplane off, Wi-Fi on. mobile data toggle ON.

### Morning plan
1. Re-plug; run m299_finalstate.sh to confirm unchanged state.
2. Verify ISub$Stub dispatcher case 31, then `service call isub 31 i32 1` (+ fallback attempts),
   then svc data enable and verify: TNP applies request, DN created + holds, `Active default network: <id>`,
   `mDataConnectionState=1`, ping v6 over the rmnet iface (busybox in chroot).
3. If NOCARD clears but call still dies after ~30 s, capture teardown reason (filter
   `DNC-0|DN-100|TNP|TelephonyRegistry|DataNetwork`, buffers main,radio) while data enable cycles.
4. Then resume plan B decision (pivot now vs sign off) with actual data knowledge.
