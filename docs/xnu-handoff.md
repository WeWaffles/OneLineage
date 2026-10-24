# Experimental XNU handoff goal

The optional OneLineage kexec work targets an **ARM64 XNU port for the
SM-S948U**, not a second Linux kernel and not an unmodified Apple kernelcache.
The loader and the operating-system port are separate projects:

1. The OneLineage handoff module validates a payload, reserves memory, builds a
   documented boot descriptor, quiesces the current Android kernel, and enters
   the payload at a known ARM64 exception level.
2. The XNU port consumes that descriptor and supplies Qualcomm/Samsung platform
   support. XNU must not assume Apple SoCs, Apple device trees, Apple interrupt
   controllers, or Apple firmware services.

## Safety contract

The initial module must expose **probe and validate operations only**. It must
not contain an execute ioctl, restart handler, automatic boot path, partition
writer, or persistent boot setting. Adding a transfer-of-control operation is a
separate milestone requiring exact Samsung kernel sources, a reviewed recovery
procedure, and an independently validated payload format.

Every payload must be authenticated by a user-supplied SHA-256 digest and
checked for architecture, size, alignment, non-overlap with reserved memory,
and a declared entry point before it can be pinned. Failure must leave Android
running and free every allocation.

## Proposed XNU boot descriptor

Use a versioned, project-owned descriptor rather than pretending the Samsung
device tree is an Apple boot environment. At minimum it should describe:

- descriptor version and total size;
- physical memory ranges and reserved regions;
- XNU image location, size, entry point, and SHA-256 digest;
- flattened device tree location and size;
- optional ramdisk location and size;
- UTF-8 boot arguments with an explicit maximum length;
- framebuffer address, dimensions, stride, and pixel format when available;
- entry exception level and MMU/cache state promised by the loader.

The descriptor format should remain usable by a small diagnostic payload before
XNU is involved. That payload can verify CPU entry, serial or memory logging,
the memory map, and watchdog behavior without trying to initialize storage.

## XNU porting milestones

1. Build an inert, exact-vermagic kernel module and load/unload it.
2. Implement read-only capability reporting and payload validation.
3. Boot a non-persistent diagnostic ARM64 payload on a sacrificial/test device.
4. Bring up XNU CPU, exception, timer, and interrupt-controller support.
5. Add Qualcomm/Samsung UART or a reserved-memory log buffer.
6. Add storage, USB, display, touch, power, and thermal support individually.

Cellular/baseband integration is a separate, later problem. The modem firmware,
IMS stack, and Samsung radio interfaces cannot be inherited simply by entering
XNU, and they must not be treated as part of the initial handoff milestone.

## When the exact Samsung kernel source is unavailable

The tested kernel is GKI-derived (`6.12.30-android16-5`) and permits module
loading, but it enables symbol CRC versioning, trims unused exports, uses Clang
CFI, and enforces strict executable permissions. A source-unavailable workflow
therefore starts from the matching Android common 6.12 branch and treats the
running device plus Samsung's shipped modules as the ABI authority.

The exact module identity currently observed is:

- release/vermagic prefix:
  `6.12.30-android16-5-pd30ff70-abogkiS948USQS3AZF1-4k`;
- `SMP preempt mod_unload modversions aarch64`;
- `module_layout` CRC: `0xe976b219`;
- `CONFIG_MODVERSIONS=y`, `CONFIG_TRIM_UNUSED_KSYMS=y`;
- `CONFIG_CFI_CLANG=y`, with LTO disabled;
- module signature checking enabled but not forced;
- runtime module loading enabled.

This is enough to attempt an **inert** module that imports only confirmed GKI
symbols. It is not enough to authorize a handoff implementation. Each imported
symbol must have a CRC taken from the running build or a shipped module, and the
module must load and unload cleanly before any payload memory is allocated.

The milestone-zero source is in `kernel/xnu_probe`. It has no externally
callable operation and is checked by `tools/verify_module_abi.py` against the
device record in `kernel/device-abi` before it may be copied to the phone. A
successful metadata check means only that the visible module ABI matches; a
load/unload test remains a separate, explicitly observed step.

### SM-S948U AZF1 probe result

An Android common `android16-6.12.30_r00` reconstruction was compiled with the
phone configuration, exact vermagic, and the `module_layout` CRC observed in a
Samsung module. The inert probe loaded, but `/proc/modules` marked it
`[permanent]` and `rmmod` returned `EPERM`, even though the candidate contained
an exit function and both configs advertised module unload. This is evidence
that copying a CRC can conceal a private ABI/layout mismatch. The reconstructed
module path is now blocked: never manufacture a `Module.symvers` entry from an
observed CRC, and do not load another candidate without exact Samsung build
inputs. The loaded probe has no operational hooks but requires a normal reboot
to clear it.

An official older SM-S948U source package is now available for
`S948USQU1AZAB`. It is the correct m3q/canoe device family and 6.12.30 base,
but its naturally generated `module_layout` CRC with the live phone config is
`0xce58de89`, not the running AZF1 value `0xe976b219`. It is therefore hardware
documentation, not a compatible module build tree. The ios-sweet adaptation
map and safe next milestones are in `docs/ios-sweet-adaptation.md`.

Private Samsung functions must not be called by guessed addresses. If a later
prototype uses kprobes for discovery, every target needs a typed wrapper that
is compatible with CFI, a build-specific allowlist, and a fail-closed result
when the symbol is absent. The final low-level transition should be implemented
self-contained where possible instead of depending on undocumented Samsung
internals.
