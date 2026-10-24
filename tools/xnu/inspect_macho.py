#!/usr/bin/env python3
"""Fail-closed structural inspection for an uncompressed ARM64 XNU Mach-O."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
LC_SEGMENT_64 = 0x19
LC_MAIN = 0x80000028

# Debug data that the XNU link inserts into the image but never maps. Apple's
# ctf_insert appends CTF to the reserved header padding, so these segments
# legitimately carry more file bytes than VM bytes. Everything else must fit.
NON_LOADED_SEGMENTS = frozenset({"__CTF", "__DWARF"})


def inspect(data: bytes) -> dict:
    if len(data) < 32:
        raise ValueError("file is shorter than a Mach-O 64 header")
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<8I", data)
    if magic != MH_MAGIC_64:
        raise ValueError("not a little-endian 64-bit Mach-O")
    if cpu != CPU_TYPE_ARM64:
        raise ValueError(f"wrong CPU type 0x{cpu:08x}; ARM64 is required")
    if filetype != MH_EXECUTE:
        raise ValueError(f"wrong Mach-O file type {filetype}; executable is required")
    command_end = 32 + sizeofcmds
    if command_end > len(data):
        raise ValueError("load-command table extends past end of file")

    offset = 32
    segments = []
    overlays: list[str] = []
    entry_file_offset = None
    for index in range(ncmds):
        if offset + 8 > command_end:
            raise ValueError(f"load command {index} is truncated")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or size % 4 or offset + size > command_end:
            raise ValueError(f"load command {index} has invalid size {size}")
        if command == LC_SEGMENT_64:
            if size < 72:
                raise ValueError(f"segment command {index} is too short")
            raw_name, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, sections, segflags = struct.unpack_from(
                "<16s4Q4I", data, offset + 8
            )
            name = raw_name.split(b"\0", 1)[0].decode("ascii", errors="strict")
            if filesize > vmsize and name not in NON_LOADED_SEGMENTS:
                raise ValueError(f"segment {name} file size exceeds VM size")
            if filesize > vmsize:
                overlays.append(name)
            if filesize and (fileoff + filesize > len(data)):
                raise ValueError(f"segment {name} extends past end of file")
            segments.append({
                "name": name, "vmaddr": vmaddr, "vmsize": vmsize,
                "fileoff": fileoff, "filesize": filesize,
                "maxprot": maxprot, "initprot": initprot,
            })
        elif command == LC_MAIN:
            if size < 24:
                raise ValueError("LC_MAIN is too short")
            entry_file_offset = struct.unpack_from("<Q", data, offset + 8)[0]
        offset += size
    if offset != command_end:
        raise ValueError("load-command count does not match sizeofcmds")
    if not segments:
        raise ValueError("Mach-O contains no LC_SEGMENT_64 commands")

    occupied = sorted(
        (segment["vmaddr"], segment["vmaddr"] + segment["vmsize"], segment["name"])
        for segment in segments if segment["vmsize"]
    )
    for left, right in zip(occupied, occupied[1:]):
        if left[1] > right[0]:
            raise ValueError(f"VM segments overlap: {left[2]} and {right[2]}")
    if entry_file_offset is not None and entry_file_offset >= len(data):
        raise ValueError("LC_MAIN entry offset extends past end of file")
    return {
        "format": "mach-o-64",
        "architecture": "arm64",
        "filetype": "execute",
        "load_commands": ncmds,
        "entry_file_offset": entry_file_offset,
        "segments": segments,
        # Reported rather than hidden: these are debug overlays, not mapped
        # memory, and the packer drops them because their VM size is zero.
        "debug_overlays": overlays,
        "safe_for_phone_execution": False,
        "note": "Structural validation only; this does not establish SM-S948U compatibility.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    report = inspect(args.input.read_bytes())
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"valid ARM64 Mach-O structure: {len(report['segments'])} segments")
        print("phone execution authorization: false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
