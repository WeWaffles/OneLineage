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
- Offline XNU tool tests: 50 passing after the loader.
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
- Wrote the missing half of a boot: `xnu/loader/loader.S`, the AArch64 image
  QEMU enters. It checks its own patched parameter block, verifies the payload
  header and that the payload sits where the plan loaded it, copies each segment
  to `phys_base + (vmaddr - virtual_base)`, zeroes `vmsize - filesize` for
  `.bss`, then puts `boot_args` in `x0`, the stack top in `sp`, and branches to
  the entry's physical address because the MMU is still off. Rejections print one
  line to the same PL011 the kernel uses, so a loader failure is not mistaken for
  a silent kernel.
- The loader computes no layout: `tools/xnu/loader.py` fills its 48-byte
  parameter block from the boot plan, and `tools/xnu/extract_elf.py` turns the
  assembled object into raw bytes plus symbol offsets with the standard library
  (no linker, no `llvm-objcopy`, no cross toolchain).
- The extractor refuses an image with relocations, and that is not theoretical:
  the first version reached the parameter block through `adrp`/`add`, leaving two
  relocations, so the unlinked image would have branched through zero. The CI run
  failed on exactly that annotation; one `adr` resolves in place.
- `xnu/build_xnu.sh`'s macOS-only assumption no longer blocks this: Xcode's
  clang cross-assembles AArch64 with plain `-c`, so
  `.github/workflows/xnu-loader.yml` builds the loader on `macos-14` in seconds
  and uploads `xnu-loader`. First green run: 2026-10-24, image under the 64 KiB
  reserve, `_start` at offset 0 and `loader_params` present.
- **Ran the loader on real QEMU**, against `xnu/loader/stub.S` via
  `tools/xnu/smoke_test.py` (WSL Ubuntu, `qemu-system-aarch64`, clang cross). It
  now copies the payload's segment, puts `boot_args` in `x0` and reaches the
  entry with the planned `physBase`. Five defects only running found:
  - the parameter magic was assembled as `"ONELAPRM"` (the 16-bit immediate for
    `"PA"` was byte-swapped), so a correctly patched image rejected itself. A
    test now rebuilds both magics from the assembler text.
  - the `.bss` zero loop stored 8 bytes from `destination + filesize`, which is
    almost never aligned; with the MMU off that is Device memory, so it was an
    alignment fault (data abort at `FAR 0x400000b5`). Both loops now fall back
    to bytes when unaligned.
  - the kernel's first segment lands at the RAM base, which is exactly where the
    payload sat: the loader would have copied over the bytes it was reading. The
    payload now starts above the kernel's span.
  - `-M virt` keeps its own device tree in the first MiB of RAM and refuses to
    start when a `-device loader` region overlaps it, so the plan keeps clear.
  - the harness never loaded `boot_args` into guest memory, so `x0` pointed at
    zeros even though the plan had the right values.
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

- **The built kernel now boots, in the job that builds it.** Run `40088041226`
  assembles the loader, generates the ADT, packs the 10-segment kernel and runs
  QEMU twice, at EL1 and at EL2. Results:
  - the loader places all 10 segments and prints `segments placed, entering
    kernel`, so the handover works with the real image (16 MB payload at
    `0x41ffc000`, kernel at `0x40000000`, entry at physical `0x4146f488`);
  - **EL2**: `Undefined Instruction` (ESR `0x0`), so XNU is not an EL2 guest;
  - **EL1**: about 8 KB of XNU code runs, then `Prefetch Abort` with ESR
    `0x86000005` (instruction abort, translation fault level 1) at
    ELR = FAR = `0x41471368`, i.e. it faults fetching its own physical address
    immediately after translation is enabled.
- Cause, from `osfmk/arm64/start.s`: `common_start` loads `x22` from
  `boot_args->virtBase` and uses it to turn physical addresses into kernel
  virtual ones (`x0 + x22 - x23`), and `arm_vm_init.c` keeps the same pair as
  `gVirtBase`/`gPhysBase` for every `pa <-> va` conversion. `boot_args.py`
  writes `virtBase = 0` under a comment claiming arm64 ignores it. It does not:
  virtBase and physBase together define the kernel's slide, so a zero virtBase
  makes every converted address wrong and the kernel dies at the first KVA
  fetch. That comment is the bug, and it is not yet fixed.

## Current task

The loader is proven both with a stub on this host and with the real kernel in
CI. The next defect is in the boot arguments: `virtBase` must be the kernel's
virtual base, and `physBase` must be the kernel's physical base, because their
difference is the slide that `start.s` and `arm_vm_init.c` apply everywhere.
`build_payload` currently masks the kernel's virtual base down to a 32 MB
boundary, which would corrupt that difference, so the fix spans the packer
header, `boot_args.py` and the plan.

XNU does run now, briefly: about 8 KB of `start.s` executes before the fault.
The phone remains untouched.

## Next tasks, in order

1. Fix the slide: carry the kernel's true virtual base through the payload
   header and into `boot_args.virtBase`, set `physBase` to the kernel's
   physical base (not the RAM base), and keep segment placement exact so
   `PA = VA - (virtBase - physBase)` holds for every segment. A test should
   assert that identity for each segment rather than trusting the two sides.
2. Re-run the EL1 boot and read the console. With the slide correct, the next
   failures should be per-subsystem (ADT platform expert, timers, pmap), which
   is where the adaptation series expects to need work.
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
- The loader runs and hands over correctly with a stub payload; what remains
  unproven is whether XNU's `start.s` accepts the state it is given (exception
  level, stack, `boot_args` contents).

## Host limits observed on 2026-10-24

- This Windows host has no clang, gcc, docker, or `qemu-system-aarch64`, but
  WSL2 (Ubuntu 26.04) is available and has clang; `qemu-system-arm` was
  installed there, which is what ran the smoke test.
- GitHub artifact downloads need an authenticated session (metadata is public,
  the zip is 401 without a token), so the built kernel could not be fetched here.
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

