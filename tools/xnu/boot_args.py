#!/usr/bin/env python3
"""Build the ARM64 ``boot_args`` blob XNU expects in ``x0`` at entry.

The layout is taken from the pinned tree, ``pexpert/pexpert/arm64/boot.h``
(xnu-8796.141.3), not from memory: field order, the padding after ``Version``,
after ``machineType`` and after ``CommandLine`` all matter, because the kernel
casts the pointer straight onto that struct. tests/test_xnu_tools.py checks the
offsets in this file against the same header text.

Nothing here allocates, loads or executes anything. It produces bytes and a
report, and the report always records that phone execution is not authorized.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct

# #define kBootArgsRevision2 2 / #define kBootArgsVersion2 2
REVISION = 2
VERSION = 2
BOOT_LINE_LENGTH = 608

# Offsets for a 64-bit AArch64 target, in bytes. Padding is explicit because it
# is part of the ABI: uint64 fields force 4 bytes after Version, after
# machineType and after CommandLine.
OFFSETS = {
    "Revision": 0,
    "Version": 2,
    "virtBase": 8,
    "physBase": 16,
    "memSize": 24,
    "topOfKernelData": 32,
    "Video": 40,  # Boot_Video: 6 x unsigned long
    "machineType": 88,
    "deviceTreeP": 96,
    "deviceTreeLength": 104,
    "CommandLine": 108,
    "bootFlags": 720,
    "memSizeActual": 728,
}
SIZE = 736
PAGE = 0x4000


def build(*, cmdline: str, phys_base: int, mem_size: int, top_of_kernel_data: int,
          device_tree_phys: int, device_tree_length: int,
          mem_size_actual: int | None = None, boot_flags: int = 0) -> tuple[bytes, dict]:
    """Serialise one ``boot_args`` block."""
    encoded = cmdline.encode("utf-8")
    if len(encoded) >= BOOT_LINE_LENGTH:
        raise ValueError(
            f"command line is {len(encoded)} bytes; boot_args allows {BOOT_LINE_LENGTH - 1}"
        )
    if phys_base % PAGE:
        raise ValueError(f"physical base {phys_base:#x} is not {PAGE:#x}-aligned")
    if mem_size <= 0:
        raise ValueError("memory size must be positive")
    if device_tree_length <= 0:
        raise ValueError("device tree length must be positive")
    memory_end = phys_base + mem_size
    for label, address in (
        ("top_of_kernel_data", top_of_kernel_data),
        ("device tree", device_tree_phys),
        ("device tree end", device_tree_phys + device_tree_length),
    ):
        if not phys_base <= address <= memory_end:
            raise ValueError(f"{label} {address:#x} is outside RAM [{phys_base:#x}, {memory_end:#x}]")
    if top_of_kernel_data < device_tree_phys + device_tree_length:
        raise ValueError("top_of_kernel_data is below the device tree")

    blob = bytearray(SIZE)
    struct.pack_into("<HH", blob, OFFSETS["Revision"], REVISION, VERSION)
    struct.pack_into(
        "<QQQQ", blob, OFFSETS["virtBase"],
        0,  # arm64 XNU runs at a fixed kernel VA; virtBase is unused
        phys_base,
        mem_size,
        top_of_kernel_data,
    )
    # Boot_Video stays zeroed on purpose: the QEMU profile has no framebuffer,
    # and pe_serial's framebuffer console is described by the ADT "sweet-fbcon"
    # node instead of by boot_args.
    struct.pack_into("<I", blob, OFFSETS["machineType"], 0)
    struct.pack_into("<Q", blob, OFFSETS["deviceTreeP"], device_tree_phys)
    struct.pack_into("<I", blob, OFFSETS["deviceTreeLength"], device_tree_length)
    blob[OFFSETS["CommandLine"]:OFFSETS["CommandLine"] + len(encoded)] = encoded
    struct.pack_into(
        "<QQ", blob, OFFSETS["bootFlags"],
        boot_flags,
        mem_size if mem_size_actual is None else mem_size_actual,
    )

    report = {
        "revision": REVISION,
        "version": VERSION,
        "size": SIZE,
        "physical_base": hex(phys_base),
        "memory_size": hex(mem_size),
        "top_of_kernel_data": hex(top_of_kernel_data),
        "device_tree_phys": hex(device_tree_phys),
        "device_tree_length": device_tree_length,
        "command_line": cmdline,
        "phone_execution_authorized": False,
    }
    return bytes(blob), report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("output", type=Path)
    parser.add_argument("--cmdline", default="debug=0xc serial=3 cpus=1 keepsyms=1")
    parser.add_argument("--phys-base", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--mem-size", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--top-of-kernel-data", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--device-tree-phys", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--device-tree-length", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args(argv)

    blob, report = build(
        cmdline=args.cmdline,
        phys_base=args.phys_base,
        mem_size=args.mem_size,
        top_of_kernel_data=args.top_of_kernel_data,
        device_tree_phys=args.device_tree_phys,
        device_tree_length=args.device_tree_length,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(blob)
    print(f"wrote {len(blob)}-byte boot_args: {args.output}")
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
