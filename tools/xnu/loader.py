#!/usr/bin/env python3
"""Fill the loader's parameter block from a QEMU boot plan.

The loader is deliberately dumb: it copies segments where the plan says and
jumps where the plan says. This is the only place those numbers are written
into the image, so a layout change cannot leave a second copy behind in
assembly.

The block is validated on the way in and out. An image whose block was already
patched with different values is refused rather than silently rewritten,
because that means a stale image was picked up by mistake.
"""
from __future__ import annotations

import hashlib
from pathlib import Path
import struct

MAGIC = b"ONELPARM"
VERSION = 1
SIZE = 56
OFFSETS = {
    "magic": 0,
    "version": 8,
    "boot_args_phys": 16,
    "stack_top": 24,
    "entry_phys": 32,
    "payload_phys": 40,
    "kernel_phys": 48,
}
ALIGNMENT = {
    "boot_args_phys": 16,
    "stack_top": 16,
    "entry_phys": 4,
    "payload_phys": 0x4000,
    "kernel_phys": 0x4000,
}
ADDRESSES = ("boot_args_phys", "stack_top", "entry_phys", "payload_phys", "kernel_phys")


def read(image: bytes, params_offset: int) -> dict:
    """Decode the parameter block currently in ``image``."""
    if params_offset < 0:
        raise ValueError("parameter block offset is negative")
    if params_offset + SIZE > len(image):
        raise ValueError(
            f"parameter block at {params_offset:#x} does not fit a {len(image)}-byte image"
        )
    block = image[params_offset:params_offset + SIZE]
    magic = block[OFFSETS["magic"]:OFFSETS["magic"] + len(MAGIC)]
    version, _reserved = struct.unpack_from("<II", block, OFFSETS["version"])
    values = {
        "params_offset": params_offset,
        "patched": magic == MAGIC,
        "magic": magic.decode("ascii", "replace"),
        "version": version,
    }
    for name in ADDRESSES:
        values[name] = struct.unpack_from("<Q", block, OFFSETS[name])[0]
    return values


def patch(image: bytes, params_offset: int, *, boot_args_phys: int, stack_top: int,
          entry_phys: int, payload_phys: int, kernel_phys: int) -> bytes:
    """Return ``image`` with the parameter block set for one boot."""
    current = read(image, params_offset)
    wanted = {
        "boot_args_phys": boot_args_phys,
        "stack_top": stack_top,
        "entry_phys": entry_phys,
        "payload_phys": payload_phys,
        "kernel_phys": kernel_phys,
    }
    if current["patched"]:
        already = all(current[name] == value for name, value in wanted.items())
        if not already:
            raise ValueError(
                f"loader at {params_offset:#x} was already patched for another boot; "
                "rebuild the image instead of reusing it"
            )
        return bytes(image)
    blank = image[params_offset:params_offset + SIZE]
    if any(blank[OFFSETS["version"] + 8:]):
        raise ValueError(
            f"parameter block at {params_offset:#x} is not the loader's placeholder; "
            "check the symbol offset"
        )

    for name, value in wanted.items():
        if value <= 0:
            raise ValueError(f"{name} must be a physical address above zero")
        alignment = ALIGNMENT[name]
        if alignment and value % alignment:
            raise ValueError(f"{name} {value:#x} is not {alignment:#x}-aligned")

    output = bytearray(image)
    output[params_offset:params_offset + SIZE] = bytes(SIZE)
    with_magic = bytearray(output[params_offset:params_offset + SIZE])
    with_magic[OFFSETS["magic"]:OFFSETS["magic"] + len(MAGIC)] = MAGIC
    struct.pack_into("<II", with_magic, OFFSETS["version"], VERSION, 0)
    for name, value in wanted.items():
        struct.pack_into("<Q", with_magic, OFFSETS[name], value)
    output[params_offset:params_offset + SIZE] = with_magic
    return bytes(output)


def summarize(image: bytes, params_offset: int) -> dict:
    """Report-safe view of a patched image: no bytes, addresses as hex."""
    values = read(image, params_offset)
    report = {
        "params_offset": values["params_offset"],
        "patched": values["patched"],
        "magic": values["magic"],
        "version": values["version"],
        "sha256": hashlib.sha256(image).hexdigest(),
        "size": len(image),
        "phone_execution_authorized": False,
    }
    for name in ADDRESSES:
        report[name] = hex(values[name])
    return report


def main(argv: list[str] | None = None) -> int:
    import argparse
    import json
    import sys

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("image", type=Path, help="raw loader image from extract_elf.py")
    parser.add_argument("symbols", type=Path, help="JSON report from extract_elf.py")
    parser.add_argument("--boot-args", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--stack-top", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--entry", type=lambda value: int(value, 0), required=True,
                        help="kernel entry as a physical address")
    parser.add_argument("--payload", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--kernel", type=lambda value: int(value, 0), required=True,
                        help="physical address the kernel image is placed at")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)

    symbols = json.loads(args.symbols.read_text(encoding="utf-8")).get("symbols", {})
    if "loader_params" not in symbols:
        print("error: the symbol map has no loader_params entry", file=sys.stderr)
        return 1
    try:
        patched = patch(
            args.image.read_bytes(), symbols["loader_params"]["offset"],
            boot_args_phys=args.boot_args, stack_top=args.stack_top,
            entry_phys=args.entry, payload_phys=args.payload,
            kernel_phys=args.kernel,
        )
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(patched)
    for key, value in summarize(patched, symbols["loader_params"]["offset"]).items():
        print(f"{key}: {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
