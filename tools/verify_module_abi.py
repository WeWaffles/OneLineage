#!/usr/bin/env python3
"""Fail-closed ABI check for a candidate OneLineage kernel module."""

import argparse
import json
import struct
import sys
from pathlib import Path

from elftools.elf.elffile import ELFFile


def section_bytes(elf, name):
    section = elf.get_section_by_name(name)
    if section is None:
        raise ValueError(f"missing ELF section: {name}")
    return section.data()


def modinfo(elf):
    result = {}
    for item in section_bytes(elf, ".modinfo").split(b"\0"):
        if b"=" in item:
            key, value = item.split(b"=", 1)
            result[key.decode("ascii")] = value.decode("utf-8", "replace")
    return result


def versions(elf):
    data = section_bytes(elf, "__versions")
    # Android arm64 uses struct modversion_info { unsigned long crc; char name[56]; }.
    if len(data) % 64:
        raise ValueError(f"unexpected __versions size: {len(data)}")
    endian = "<" if elf.little_endian else ">"
    result = {}
    for offset in range(0, len(data), 64):
        crc = struct.unpack_from(endian + "Q", data, offset)[0] & 0xFFFFFFFF
        name = data[offset + 8 : offset + 64].split(b"\0", 1)[0].decode("ascii")
        if name:
            result[name] = crc
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("module", type=Path)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument(
        "--metadata-only",
        action="store_true",
        help="report matching metadata but never authorize a device load",
    )
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text(encoding="utf-8"))

    with args.module.open("rb") as stream:
        elf = ELFFile(stream)
        if elf["e_machine"] != "EM_AARCH64":
            raise ValueError(f"wrong architecture: {elf['e_machine']}")
        info = modinfo(elf)
        imported = versions(elf)

    errors = []
    if info.get("vermagic") != profile["vermagic"]:
        errors.append(f"vermagic mismatch: {info.get('vermagic')!r}")
    expected_layout = int(profile["module_layout_crc"], 16)
    if imported.get("module_layout") != expected_layout:
        errors.append(
            "module_layout CRC mismatch: "
            f"0x{imported.get('module_layout', 0):08x} != 0x{expected_layout:08x}"
        )
    unexpected = sorted(set(imported) - set(profile["allowed_imports"]))
    if unexpected:
        errors.append("unexpected imports: " + ", ".join(unexpected))
    if not profile.get("exact_source_available", False) and not args.metadata_only:
        errors.append("exact vendor source/Module.symvers is unavailable; device load blocked")

    print(f"module={args.module}")
    print(f"vermagic={info.get('vermagic', 'missing')}")
    print("imports=" + (", ".join(sorted(imported)) or "none"))
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    if not profile.get("exact_source_available", False):
        print("result=METADATA_MATCH_ONLY (device load remains blocked)")
    else:
        print("result=PASS (ABI metadata only; this does not prove runtime safety)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
