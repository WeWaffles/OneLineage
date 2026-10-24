# XNU port progress log

This file is the continuing engineering handoff for the SM-S948U XNU target.
Update it whenever a milestone, blocker, test result, or next action changes.

## Safety state

- Phone execution: **not authorized and not implemented**.
- Bootloader: locked; Android Verified Boot remains intact.
- Running kernel: `6.12.30-android16-5-pd30ff70-abogkiS948USQS3AZF1-4k`.
- Normal kexec: unavailable (`CONFIG_KEXEC=n`, `CONFIG_KEXEC_FILE=n`).
- Exact module ABI: unavailable. Older `S948USQU1AZAB` source produces
  `module_layout=0xce58de89`; the phone requires `0xe976b219`.
- No payload RAM region or framebuffer has been approved.

## Current progress — 2026-10-24

- Preserved the Android 16 container-switching path and added fail-closed
  Android-version compatibility profiles and HAL/APEX/framework diagnostics.
- Added a probe-only kexec capability report. It cannot load or execute code.
- Audited `dipa-studio/ios-sweet` as the XNU reference. Its unlocked-Xiaomi
  `fastboot boot` route cannot be used on this locked Samsung.
- Extracted sanitized live hardware facts: eight CPUs, PSCI/SMC, 19.2 MHz
  timer, GICv3, UFS, and a candidate GENI UART.
- Added a deterministic QEMU-only Apple Device Tree generator. Phone mode
  refuses output while placement and execution gates are unresolved.
- Added an ARM64 Mach-O structural inspector. It never authorizes execution.
- Added an offline payload packer with strict Mach-O/ADT bounds checks,
  ARM64 thread-entry extraction, supported chained-rebase resolution, segment
  flattening, and a versioned `ONELXNU` header. It only accepts `--target qemu`.
- Pinned the kernel source: `xnu-8796.141.3` by archive SHA-256, plus the
  `blacktop/darwin-xnu-build` commit, macOS release, and kernel/machine/arch
  configurations, all recorded in `xnu/series.json`.
- Vendored ios-sweet patches `0001`-`0018` as the minimal QEMU-milestone series
  and proved they apply in declared order to a pristine pinned tree. An upstream
  Windows checkout carries CRLF in those files; the verifier rejects that.
- Added `xnu/build_xnu.sh` and a `macos-14` workflow that build exactly this
  series, fail closed when any pinned patch is skipped, and inspect the kernel.
- Found and fixed a false-positive in the verifier: inside OneLineage's own work
  tree, `git apply` resolved the patch against that repository root, skipped
  every file and still exited 0, so an untouched tree was reported as a clean
  apply. The tool now runs git with a ceiling directory above the scratch tree
  and proves each patch landed by re-checking it in reverse. The earlier
  "applies cleanly" result was re-run and holds; it now actually means that.
- Added the OneLineage adaptation series (`xnu/patches-onelineage/`, four
  patches) on top of the pinned prefix: parameterised bootstrap console, PL011
  backend behind `SWEET_QEMU_PROFILE`, platform-expert match on
  `onelineage,platform`, and the `SWEET_PROFILE_FLAGS` make hook. The ADT
  generator publishes that compatible, and a test fails if kernel and ADT drift.
- Corrected an earlier gap: the virtual-timer INTID was never hardcoded against
  QEMU. `0017` reads `virtual-timer-intid` from the device tree (QEMU profile:
  27) and uses 19 only as the phone fallback.
- Added the VM side: `tools/xnu/boot_args.py` builds the AArch64 `boot_args`
  block from the pinned `boot.h` layout, and `tools/xnu/qemu_run.py` lays out
  `virt` RAM, rejects overlaps, and emits the `qemu-system-aarch64` command. It
  refuses to execute without a loader image and without QEMU installed.
- Documented the loader contract (payload header, segment placement, `x0`,
  entry) in `xnu/README.md`. The loader image itself still needs an AArch64
  cross toolchain, which this host does not have.
- Offline XNU tool tests: 30 passing after the VM harness.
- **The macOS 14 VM built the kernel.** Run `40083156740` on `macos-14` (Xcode
  15.x, Kernel Debug Kit 13.5 downloaded by `build.sh`) finished green in about
  six minutes. The harness applied all 18 pinned patches and all 4 adaptations,
  linked `kernel.Development.SWEET`, and the structure check accepted the
  result; `xnu-kernel-qemu` (8.7 MiB) holds the kernel, both logs and the
  series report for seven days. So the series compiles, not just applies.
- That run also exposed a real bug in my inspector: it rejected the kernel's
  `__CTF` segment with "file size exceeds VM size". That overlay is normal —
  Apple's `ctf_insert` appends CTF to the reserved header padding, so the
  segment carries more file bytes than VM bytes. `inspect_macho.py` now allows
  a non-loaded debug overlay (`__CTF`, `__DWARF`) and reports it in
  `debug_overlays` instead of failing; the packer skips zero-VM segments, so
  the overlay never reaches the payload.
- Audited the macOS 14 CI VM against the real `darwin-xnu-build` build.sh at the
  pinned commit, and fixed what would have made a run fail or look broken:
  - the preflight required an SDK `mig` and SDK `Kernel.framework` headers.
    Neither is how this harness works: build.sh builds `mig`/`migcom` from
    `bootstrap_cmds` and rewrites `makedefs`, and the private headers come from
    a Kernel Debug Kit that build.sh downloads with sudo. Both checks now warn
    instead of aborting, and an SDK `clang` check was added.
  - the kernel was looked up only in `fakeroot/System/Library/Kernels`; the
    object-tree copy at `build/xnu.obj/kernel.<type>` is now a fallback.
  - the workflow picked the *oldest* installed Xcode. It now pins the newest
    15.x, because Xcode 16's `iig` cannot generate headers for the XNU-8796
    IORPC ABI, and fails loudly if the image has no 15.x at all.
  - added `build_xnu.sh --check`, and the workflow runs it before the build so
    an environment problem is reported in seconds instead of after an hour.
  - confirmed build.sh applies `patches/*.patch` with `git apply` and prints
    `Applying patch: <path>` (so the fail-closed check matches), selects
    `patches/` for macOS 13.5, and needs jq/gum/xcodes/cmake/ninja.
  - fixed a silent early exit: `find` on a missing `/Library/Developer/KDKs`
    returns 1, and under `set -o pipefail` that killed the script with no
    message. The lookup is now guarded, and an `ERR` trap names the failing line
    and command. A second trap was needed because the build itself tolerates
    failure so it can report `build.sh`'s status.
  - widened `libfirehose_kernel` to plain arm64 in `build.sh`; that target is
    arm64e-only upstream and the `SWEET` kernel is not arm64e.

## Current task

The kernel now exists as a build artifact, and the macOS 14 VM is proven to
produce it. What is missing is the other half of a QEMU boot: the loader that
consumes the `ONELXNU` payload, and a local copy of the kernel to pack.

Nothing has booted. `qemu_run.py` has only planned layouts against a synthetic
payload, and the phone remains untouched.

## Next tasks, in order

1. Fetch the `xnu-kernel-qemu` artifact (needs an authenticated GitHub session)
   or run `bash xnu/build_xnu.sh` on a Mac, then pack it with
   `tools/xnu/build_payload.py` against the generated ADT.
2. Assemble the loader described in `xnu/README.md` with an AArch64 cross
   toolchain, then run `tools/xnu/qemu_run.py --loader ... --execute` for the
   first identifiable early-console line. Keeping the loader in a `macos-14` job
   is the cheap route, since that runner has a toolchain but no QEMU.
4. Normalize the complete phone RAM and reserved-memory map from sanitized
   facts; do not choose a payload range before this passes overlap checks.
5. Confirm a usable phone debug route and watchdog behavior.
6. Obtain exact `S948USQS3AZF1` source/build symbols, or move only through an
   independently verified official upgrade/downgrade path to a matching build.
7. Only after an exact ABI probe loads *and unloads cleanly*, design and review
   a non-executing transition-module skeleton.

## Known QEMU gaps

Details are in `xnu/README.md`.

Settled by the adaptation series:

- Platform-expert match: adaptation `0003` matches `onelineage,platform`, and
  `mk_m3q_adt.py` publishes it; a test keeps the two in agreement.
- Early console: adaptation `0002` writes to the PL011 at `0x09000000` under
  `SWEET_QEMU_PROFILE`, mapped Device-nGnRnE, with the panel band compiled out.
- Virtual-timer INTID: never a gap. `0017` takes it from the ADT property, and
  the QEMU profile already publishes 27.

Still open:

- The kernel compiles and links; the adaptations are proven to build, not yet
  to boot. Nothing has been executed.
- The loader that consumes the `ONELXNU` payload is specified but not written;
  it needs an AArch64 cross toolchain. Until it exists, `qemu_run.py` only
  plans and prints a command.

## Host limits observed on 2026-10-24

- This Windows host has no clang, gcc, docker, or `qemu-system-aarch64`, and the
  WSL optional component is not enabled, so the WSL test path used earlier is
  unavailable.
- Offline verification of the pinned series runs here; the kernel build has to
  run on macOS or the `macos-14` workflow.

## Definition of the next visible success

An XNU kernel built from source reaches an identifiable early boot message in
QEMU using OneLineage's generated ADT and payload. This does not imply the
phone can safely execute it.

## Known long-term gaps

- Phone CPU/device shutdown and DMA quiescence.
- MMU/cache teardown and physical `boot_args` handoff.
- Samsung/Qualcomm framebuffer and persistent logging.
- UFS safety, SMP, USB, input, GPU, Wi-Fi, modem, camera, SEP substitutes,
  and any iOS userland work.

