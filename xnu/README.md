# Pinned XNU build for the QEMU early-console milestone

This directory makes the first XNU milestone reproducible: obtain one exact XNU
tree, apply one exact patch series, and build one exact kernel configuration.
Nothing here is a phone operation. No boot partition, running kernel, or payload
is touched, and none of this authorizes execution on the SM-S948U.

The milestone is the one recorded in `XNU_PROGRESS.md`: an XNU kernel built from
source that reaches an identifiable early boot message in QEMU. Phone support is
explicitly out of scope for this series.

## What is pinned

| Item | Value |
| --- | --- |
| Kernel source | `apple-oss-distributions/xnu` tag `xnu-8796.141.3` |
| Source archive | tarball SHA-256 `f08bfe045a1fb552a6cbf7450feae6a35dd003e9979edf71ea77d1a836c8dc99` |
| Tag source | `distribution-macOS` `macos-135/release.json` (macOS 13.5, XNU-8796 generation) |
| Build harness | `blacktop/darwin-xnu-build` at `663906528d1cd5ea8fde7de6f16de73db9511549` |
| Configuration | `KERNEL_CONFIG=DEVELOPMENT`, `ARCH_CONFIG=ARM64`, `MACHINE_CONFIG=SWEET` |
| Host | macOS with Xcode and the `Kernel.framework` private headers |

All of it lives in [series.json](series.json), including a SHA-256 per patch.
The build harness reads its pins from that file instead of repeating them.

## The series

`patches/` vendors patches `0001`–`0018` of `dipa-studio/ios-sweet` at commit
`45263bee51df4a0f55cdf9c649af886399488ddb` (MIT, see
[LICENSE.ios-sweet](../tools/xnu/LICENSE.ios-sweet)). They are byte-identical to
the upstream git blobs. The upstream working tree on a Windows checkout has CRLF
in these files, which makes every patch fail to apply; the vendored copies are
LF-only, and the verifier enforces that.

The selection is the contiguous prefix that covers this milestone:

- `0001`, `0002`, `0005`, `0007`, `0008`, `0009` — build and link against an open
  source tree with a current clang, no closed `lib<SoC>.os.a`, and no Apple-only
  exports.
- `0004`, `0006` — a non-Apple arm64 machine configuration (`SWEET`) built from
  the open-source assembly and pmap.
- `0003`, `0010`, `0012` — early serial output: a framebuffer-backed `pe_serial`
  and an early debug console that survives the TTBR0 switch.
- `0011`, `0013`, `0014`, `0015` — vm/prng/security adjustments so the kernel
  does not depend on Apple memory layout, CoreCrypto, or the trust-cache runtime.
- `0016`, `0017`, `0018` — device-tree platform expert, virtual-timer IRQ through
  `pe_fiq`, and single-CPU `IOCPU` bring-up.

Left out on purpose: everything from `0019` on (filesystem, AMFI, HFS/mockfs,
UFS, USB, HID/touch, display, keystore, SMP). Those belong to later milestones,
and several of them need `*.sh` staging scripts that vendor third-party sources.
The series stops before any of that, so it has no staging scripts.

## The OneLineage adaptations

`patches-onelineage/` holds this project's own four patches, applied after the
pinned prefix. They are derived from the patched source rather than guessed, and
each one exists because a constant in the upstream series was hardcoded for the
phone panel:

| Patch | What it changes |
| --- | --- |
| `0001` | Moves the bootstrap console address, panel geometry and block attributes into `SWEET.h`, so `start.s`, `arm_vm_init` and `sweet_early.c` cannot disagree about them. Behaviour is unchanged. |
| `0002` | Adds a PL011 backend for `SWEET_QEMU_PROFILE`: console at `0x09000000`, Device-nGnRnE mapping, panel band and pixel drawing compiled out. |
| `0003` | Makes the platform expert match `onelineage,platform`, which is what `mk_m3q_adt.py` publishes, instead of one board's vendor strings. A test keeps the two equal. |
| `0004` | Adds the `SWEET_PROFILE_FLAGS` hook to `makedefs/MakeInc.def`, so a QEMU build adds `-DSWEET_QEMU_PROFILE` without a second machine configuration and its duplicate `MASTER` file. Only the `qemu` profile applies it. |

The console block is reached through the first bootstrap L2 table: with 16K
granules one L1 entry covers 64GB in 2048 32MB blocks, so the panel address
(block 78) and the QEMU UART (block 4) both fit the single descriptor that
`start.s` installs.

## Verify the series offline

```sh
python3 tools/xnu/verify_xnu_series.py --verify-only              # manifest, hashes, line endings
python3 tools/xnu/verify_xnu_series.py --fetch                    # pinned series + qemu adaptations
python3 tools/xnu/verify_xnu_series.py --fetch --profile phone    # pinned series + phone adaptations
```

`--fetch` downloads the pinned tarball into `build/xnu-src/`, verifies its
SHA-256, extracts a fresh tree, writes a provenance marker, then applies the
pinned series and the adaptations the profile selects, in declared order, with
text conversion disabled. Each patch is checked three ways: it must apply
cleanly, git must not skip any file, and it must apply cleanly in reverse
afterwards. It refuses to patch a tree that lacks the marker, so it will never
modify an unidentified XNU checkout. `--json PATH` writes a report that
explicitly records `compiled: false`, `linked: false`,
`qemu_console_reached: false` and `phone_execution_authorized: false`.

A clean run means the patch text composes against the pinned tag. It does not
mean the kernel builds, links, boots, or runs — that is what the next two
commands are for.

## Build it

Local macOS host:

```sh
bash xnu/build_xnu.sh --check   # environment preflight only
bash xnu/build_xnu.sh
```

The preflight verifies the series, the adaptations, Xcode, the SDK and clang.
It deliberately does **not** require an SDK `mig` or an SDK
`Kernel.framework`: `darwin-xnu-build` builds `mig`/`migcom` from
`bootstrap_cmds` and rewrites `makedefs` to use its own copies, and the private
headers the kernel compiles against come from a Kernel Debug Kit, which
`build.sh` downloads (via `sudo`) when it is missing. Requiring either in the
SDK made a healthy machine look broken.

The script verifies the series, fetches the pinned harness, installs the pinned
patches and the adaptations, widens `libfirehose_kernel` to plain arm64
(ios-sweet does the same; the `SWEET` kernel is not arm64e), builds, then fails
closed unless *every* patch shows up as applied in the build log.
`darwin-xnu-build` skips a patch it cannot apply, so a kernel can otherwise be
produced with part of the series missing. The kernel lands in `build/xnu/`, is
checked with `tools/xnu/inspect_macho.py`, and is hashed.

`build.sh` writes the image to `fakeroot/System/Library/Kernels/kernel.<config>.<machine>`
and keeps a copy in `build/xnu.obj/`; this script looks in both.

The build profile defaults to `qemu`, which passes
`SWEET_PROFILE_FLAGS=-DSWEET_QEMU_PROFILE` so the kernel talks to the PL011:

```sh
ONELINEAGE_XNU_PROFILE=qemu  bash xnu/build_xnu.sh   # default
ONELINEAGE_XNU_PROFILE=phone bash xnu/build_xnu.sh   # panel console, still non-executing
```

`darwin-xnu-build` applies patches in sorted filename order, so the adaptations
are copied in as `zz-<name>.patch`. The prefix exists only inside the build
harness; the vendored names and hashes remain authoritative.

Without a Mac, [.github/workflows/xnu-build.yml](../.github/workflows/xnu-build.yml)
runs the same script on a `macos-14` runner and uploads the kernel, build log
and series report as artifacts. It needs `workflow_dispatch` or a push that
touches `xnu/**` or `tools/xnu/**`.

The first complete run (2026-10-24, run `40083156740`) finished green in about
six minutes: the whole series applied, the kernel linked, and the structure
check accepted it. `xnu-kernel-qemu` (8.7 MiB) holds `build/xnu/`, both logs and
the series report for seven days. Downloading it needs an authenticated GitHub
session, so the image has not been inspected on this host — the checks it passed
are the ones that ran inside the job.

The runner setup matters more than it looks:

- The job pins **Xcode 15.x** (newest installed). Xcode 16's `iig` emits
  `IORPC.kernelContent` for an IORPC ABI XNU-8796 does not have, so the `iig`
  from a 16.x toolchain cannot generate matching headers. If an image ever ships
  only 16.x, the job fails with that message instead of producing a kernel that
  cannot link.
- `jq`, `gum`, `cmake`, `ninja` and `bash` come from Homebrew; `xcodes` is a
  two-line stub because `build.sh` only tests for its presence and the real tool
  would try to manage Xcode.
- The matching Kernel Debug Kit (13.5) is downloaded and installed by
  `build.sh` on first run, which is why the job needs `sudo` and allows 150
  minutes.

## Status

| Check | Result |
| --- | --- |
| Pinned source downloads and matches its SHA-256 | verified |
| All 18 pinned patches hash-match and are LF-only | verified |
| All 4 adaptations hash-match and are LF-only | verified |
| Pinned series applies in order to pristine `xnu-8796.141.3` | verified (2026-10-24) |
| Adaptations apply on top, in order, for each profile | verified (2026-10-24) |
| `boot_args` offsets match the pinned `boot.h` | verified |
| Harness plans a non-overlapping `virt` layout | verified (synthetic payload) |
| Compiles and links (`DEVELOPMENT`/`ARM64`/`SWEET`, qemu profile) | verified on `macos-14` (2026-10-24) |
| Reaches an early console line in QEMU | **not run** — needs the loader |
| Anything on the SM-S948U | not implemented, not authorized |

## What the adaptations settled, and what is left

Settled while writing the adaptations, against the real patched source:

- **Timer INTID.** It was wrong to list this as a kernel gap. `0017` reads the
  `virtual-timer-intid` property from the device tree and only uses
  `SWEET_VTIMER_INTID = 19` as the phone fallback, and `mk_m3q_adt.py` already
  publishes `27`. No patch was needed; a malformed value panics instead of being
  ignored.
- **GIC addresses.** `pe_fiq.c` takes the distributor and redistributor bases
  from the ADT `reg` property, so the QEMU values come from the same generator.
- **Platform expert match.** `0003` matches `onelineage,platform`, and the ADT
  publishes it first in the root `compatible` list.
- **Console target.** `0002` gives the QEMU profile a PL011 console; the phone
  profile keeps the panel framebuffer byte-for-byte.

## The QEMU side

`tools/xnu/qemu_run.py` is the VM harness. It reads an `ONELXNU` payload, lays
out `virt` RAM (payload, loader, `boot_args`, stack), rejects overlapping or
oversized layouts, builds the AArch64 `boot_args` block with
`tools/xnu/boot_args.py` (offsets taken from the pinned
`pexpert/pexpert/arm64/boot.h`), and emits the `qemu-system-aarch64` command:

```sh
python tools/xnu/qemu_run.py build/m3q-qemu.payload \
  --boot-args build/m3q-qemu.bootargs --boot-plan build/m3q-qemu.plan.json
```

Without `--loader` it prints the plan and stops. With `--loader` it prints the
command. With `--execute` it starts QEMU, and only if `qemu-system-aarch64` is
installed. `--console file:console.log` captures the PL011 output instead of
using stdio; `-display none` means there is no framebuffer to inspect.

### Loader contract

QEMU enters the loader at `loader_addr` with `cpu-num=0`; the address comes from
the boot plan. The loader must:

1. Read the `ONELXNU` header at `payload_phys`: magic `ONELXNU\0`, version 1,
   segment count, then `virtual_base`, `entry`, `tree_offset`, `tree_size`,
   `kernel_end`, `phys_base`, `mem_size`, the command line and the segment
   table of `(vmaddr, vmsize, fileoff, filesize)` entries.
2. Place each segment at `vmaddr - virtual_base + phys_base`.
3. Put `boot_args_phys` (from the boot plan, or the `--boot-args` file) in `x0`,
   set up the stack the way `osfmk/arm64/start.s` expects, and branch to
   `entry`.

That image has to be assembled with an AArch64 cross toolchain, which this
project does not vendor and this host does not have. It is the one piece between
the harness and a first console line.

Still open before a QEMU run can show kernel output:

1. **The kernel image, locally.** It exists only as the `xnu-kernel-qemu`
   artifact from the `macos-14` run; fetching it needs an authenticated GitHub
   session and none has been used here. `xnu/build_xnu.sh` reproduces it from a
   Mac in one command.
2. **The loader image.** Contract above; needs a cross toolchain.
3. **A real payload.** `qemu_run.py` is exercised here against a synthetic
   one-segment payload and the generated ADT, not against a built kernel. Note
   that a real kernel carries a `__CTF` debug overlay whose file size exceeds
   its (zero) VM size; the packer drops zero-VM segments, which is why that
   overlay does not reach the payload.
