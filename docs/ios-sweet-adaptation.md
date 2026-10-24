# Adapting ios-sweet to the SM-S948U

`dipa-studio/ios-sweet` is the best available reference for the XNU side of
this project, but its boot path cannot be copied unchanged. It relies on an
unlocked Xiaomi bootloader and `fastboot boot` to start a bare-metal Linux-image
shim. The SM-S948U bootloader is locked, so OneLineage still needs a transition
from the already-running Samsung kernel.

## Reusable pieces

- `tools/mkpayload.py`: Mach-O parsing, chained-fixup resolution, segment table,
  ADT placement, and extraction of the XNU entry point.
- `shim/loader.c`: XNU `boot_args` revision 2 layout and the convention that
  physical `x0` points at `boot_args` with caches/MMU disabled.
- `tools/mkadt.py`: a practical model for generating an Apple Device Tree from
  Qualcomm hardware facts while retaining an iPhone product identity subtree.
- XNU patches for non-Apple ARM64, GICv3, PSCI, Qualcomm UFS, framebuffer,
  persistent logging, timers, SMP, and early userspace bring-up.

All physical addresses and device-specific drivers in ios-sweet are for the
SM7150 Redmi Note 10 Pro and must be replaced.

## Samsung source now available

The local Samsung package targets `m3q_usa_singlew` on Qualcomm `canoe`, uses
kernel 6.12.30, and identifies itself as `S948USQU1AZAB`. It contains the core
canoe device trees, Samsung m3q overlays, and separate display, camera, GPU,
radio-adjacent, NFC, Bluetooth, and other device-tree packages. These are useful
for building a device hardware manifest for an SM-S948U ADT generator.

The running phone is newer (`S948USQS3AZF1`). A natural `module_layout` symbol
version generated from the older Samsung source using the phone's live config
is `0xce58de89`; the running kernel requires `0xe976b219`. This hard mismatch
means the older source must not be used to load a module on the current kernel.
It remains suitable as hardware documentation and as a guide to Samsung's RKP
module-memory handling.

## Safe implementation order

1. Parse the live flattened device tree and compare it with the m3q/canoe DTS
   sources; generate a read-only hardware manifest containing CPU topology,
   RAM/reserved ranges, GIC, timer, PSCI, UFS, framebuffer, and watchdog data.
2. Adapt ios-sweet's payload and ADT tools to consume that manifest. Validate
   generated payloads entirely offline and boot XNU under QEMU first.
3. Obtain source/build artifacts whose naturally generated ABI matches the
   running `module_layout` CRC. Never substitute or patch a CRC.
4. Build a probe that naturally matches and proves clean load/unload.
5. Only then design payload reservation and a diagnostic handoff milestone.

No XNU execution operation should be present before steps 1–4 pass.

## First live hardware manifest

A sanitized initial manifest is stored at
`kernel/device-hardware/sm-s948u-azf1.json`. The live tree confirms eight CPUs
using PSCI/SMC, a 19.2 MHz ARM generic timer, GICv3 at `0x17000000`, and the
primary UFS controller at `0x01d84000`. It also exposes a GENI UART path at
`0x00a9c000`, although physical debug access and firmware ownership remain
unverified. No payload RAM range has been selected: the live memory map is
highly fragmented by secure and peripheral carve-outs and must be normalized
against every reserved-memory node first.

## Offline ADT milestone

`tools/xnu/mk_m3q_adt.py` now turns the sanitized manifest into a deterministic
Apple Device Tree for QEMU format and early-XNU validation. Its minimal tree
contains `/chosen`, a single QEMU CPU, QEMU GICv3, timer frequencies, and an
inert watchdog description. The serializer/parser is derived from ios-sweet's
MIT-licensed ADT tooling and carries its license alongside the code.

This is intentionally not a phone tree. The generator substitutes QEMU RAM,
GIC, and timer values and refuses `--mode phone`. Unlocking phone generation
requires all of the following to be represented and independently checked:

1. A normalized usable-RAM map with every secure/reserved carve-out removed.
2. A payload, boot-argument, ADT, stack, and persistent-log placement plan.
3. A verified framebuffer or a headless early-debug path.
4. Exact-source ABI validation for any transition module.
5. A separate reviewed decision to authorize execution.
