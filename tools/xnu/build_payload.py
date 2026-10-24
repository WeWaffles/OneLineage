#!/usr/bin/env python3
"""Build an offline XNU segment/ADT payload for QEMU development only.

The v1 format and chained-fixup handling are adapted from dipa-studio's
MIT-licensed ios-sweet tools/mkpayload.py. See LICENSE.ios-sweet.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import struct

import adt
import inspect_macho

MAGIC = b"ONELXNU\0"
VERSION = 1
PAGE = 0x4000
BOOT_LINE_LENGTH = 608
CMDLINE_OFFSET = 0x48
SEGMENT_TABLE_OFFSET = CMDLINE_OFFSET + BOOT_LINE_LENGTH
LC_SEGMENT_64 = 0x19
LC_UNIXTHREAD = 0x5
LC_DYLD_CHAINED_FIXUPS = 0x80000034


def align(value: int, boundary: int) -> int:
    return (value + boundary - 1) & ~(boundary - 1)


def parse_commands(data: bytes) -> dict:
    checked = inspect_macho.inspect(data)
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    offset = 32
    segments, entry, fixups = [], None, None
    for index in range(ncmds):
        command, size = struct.unpack_from("<II", data, offset)
        if command == LC_SEGMENT_64:
            raw_name, vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<16s4Q", data, offset + 8)
            segments.append({
                "name": raw_name.split(b"\0", 1)[0].decode("ascii"),
                "vmaddr": vmaddr, "vmsize": vmsize,
                "fileoff": fileoff, "filesize": filesize,
            })
        elif command == LC_UNIXTHREAD:
            if size < 288:
                raise ValueError("ARM64 LC_UNIXTHREAD is too short")
            _flavor, count = struct.unpack_from("<II", data, offset + 8)
            if count < 68:
                raise ValueError("ARM64 thread state is incomplete")
            entry = struct.unpack_from("<Q", data, offset + 272)[0]
        elif command == LC_DYLD_CHAINED_FIXUPS:
            if size < 16:
                raise ValueError("LC_DYLD_CHAINED_FIXUPS is too short")
            fixups = struct.unpack_from("<II", data, offset + 8)
        offset += size
    if offset != 32 + sizeofcmds:
        raise ValueError("Mach-O load-command accounting mismatch")
    if not segments or segments[0]["name"] != "__TEXT" or segments[0]["fileoff"] != 0:
        raise ValueError("first Mach-O segment must be __TEXT at file offset zero")
    if entry is None:
        raise ValueError("XNU Mach-O has no ARM64 LC_UNIXTHREAD entry point")
    checked["entry_virtual_address"] = entry
    return {"segments": segments, "entry": entry, "fixups": fixups, "inspection": checked}


def decode_fixup(raw: int, pointer_format: int, image_base: int) -> tuple[int, int, int]:
    if pointer_format in (2, 6):
        if raw >> 63:
            raise ValueError("chained bind is unsupported")
        target = raw & ((1 << 36) - 1)
        target |= ((raw >> 36) & 0xFF) << 56
        if pointer_format == 6:
            target += image_base
        return target, (raw >> 51) & 0xFFF, 4
    if pointer_format == 8:
        return image_base + (raw & ((1 << 30) - 1)), (raw >> 51) & 0xFFF, 4
    raise ValueError(f"unsupported chained pointer format {pointer_format}")


def apply_chained_fixups(data: bytearray, macho: dict) -> int:
    if macho["fixups"] is None:
        return 0
    data_offset, data_size = macho["fixups"]
    if data_offset + data_size > len(data) or data_size < 28:
        raise ValueError("chained-fixup data is out of bounds")
    _version, starts_offset, _imports, _symbols, import_count, _format, _symbol_format = struct.unpack_from(
        "<7I", data, data_offset
    )
    if import_count:
        raise ValueError("kernel has chained binds; only rebases are supported")
    starts = data_offset + starts_offset
    if starts + 4 > data_offset + data_size:
        raise ValueError("chained-fixup starts table is out of bounds")
    segment_count = struct.unpack_from("<I", data, starts)[0]
    if segment_count > len(macho["segments"]) or starts + 4 + 4 * segment_count > data_offset + data_size:
        raise ValueError("invalid chained-fixup segment count")
    image_base = macho["segments"][0]["vmaddr"]
    fixed = 0
    for index in range(segment_count):
        relative = struct.unpack_from("<I", data, starts + 4 + 4 * index)[0]
        if not relative:
            continue
        base = starts + relative
        if base + 22 > data_offset + data_size:
            raise ValueError("chained-fixup segment table is out of bounds")
        _size, page_size, pointer_format, _segment_offset, _max_valid, page_count = struct.unpack_from(
            "<IHHQIH", data, base
        )
        if base + 22 + 2 * page_count > data_offset + data_size:
            raise ValueError("chained-fixup page table is out of bounds")
        segment = macho["segments"][index]
        for page in range(page_count):
            start = struct.unpack_from("<H", data, base + 22 + 2 * page)[0]
            if start == 0xFFFF:
                continue
            if start & 0x8000:
                raise ValueError("multi-start chained fixups are unsupported")
            location = segment["fileoff"] + page * page_size + start
            while True:
                if location + 8 > segment["fileoff"] + segment["filesize"]:
                    raise ValueError("chained fixup leaves its segment")
                raw = struct.unpack_from("<Q", data, location)[0]
                target, following, stride = decode_fixup(raw, pointer_format, image_base)
                struct.pack_into("<Q", data, location, target)
                fixed += 1
                if not following:
                    break
                location += following * stride
    return fixed


def adt_memory(blob: bytes) -> tuple[int, int]:
    root, end = adt.parse(blob)
    if end != len(blob):
        raise ValueError("ADT has trailing data")
    chosen = next((node for node in root.children if node.name == "chosen"), None)
    if chosen is None or chosen.prop("dram-base") is None or chosen.prop("dram-size") is None:
        raise ValueError("ADT lacks /chosen dram-base or dram-size")
    return struct.unpack("<Q", chosen.prop("dram-base"))[0], struct.unpack("<Q", chosen.prop("dram-size"))[0]


def build(kernel: bytes, tree: bytes, command_line: str) -> tuple[bytes, dict]:
    kernel_data = bytearray(kernel)
    macho = parse_commands(kernel_data)
    fixed = apply_chained_fixups(kernel_data, macho)
    segments = [item for item in macho["segments"] if item["vmsize"]]
    virtual_base = segments[0]["vmaddr"] & ~(0x2000000 - 1)
    kernel_end = align(max(item["vmaddr"] + item["vmsize"] for item in segments), PAGE)
    physical_base, memory_size = adt_memory(tree)
    if kernel_end - virtual_base >= memory_size:
        raise ValueError("kernel virtual span does not fit ADT memory")
    encoded_command = command_line.encode("utf-8")
    if len(encoded_command) >= BOOT_LINE_LENGTH:
        raise ValueError("XNU command line exceeds 607 bytes")

    output = bytearray(SEGMENT_TABLE_OFFSET + 32 * len(segments))
    table = []
    for segment in segments:
        file_offset = len(output)
        file_data = kernel_data[segment["fileoff"] : segment["fileoff"] + segment["filesize"]]
        output += file_data
        output += b"\0" * (-len(output) & 15)
        table.append((segment["vmaddr"], segment["vmsize"], file_offset, len(file_data)))
    tree_offset = len(output)
    output += tree
    output += b"\0" * (-len(output) & 15)
    struct.pack_into("<8sII", output, 0, MAGIC, VERSION, len(segments))
    struct.pack_into(
        "<7Q", output, 0x10, virtual_base, macho["entry"], tree_offset,
        len(tree), kernel_end, physical_base, memory_size,
    )
    output[CMDLINE_OFFSET : CMDLINE_OFFSET + len(encoded_command)] = encoded_command
    for index, values in enumerate(table):
        struct.pack_into("<4Q", output, SEGMENT_TABLE_OFFSET + 32 * index, *values)
    return bytes(output), {
        "segments": len(segments), "fixups_resolved": fixed,
        "entry_virtual_address": hex(macho["entry"]),
        "virtual_base": hex(virtual_base), "physical_base": hex(physical_base),
        "memory_size": hex(memory_size), "adt_size": len(tree),
        "payload_size": len(output), "phone_execution_authorized": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel", type=Path)
    parser.add_argument("adt", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--target", choices=("qemu",), default="qemu")
    parser.add_argument("--cmdline", default="debug=0xc serial=3 cpus=1 keepsyms=1")
    args = parser.parse_args()
    payload, report = build(args.kernel.read_bytes(), args.adt.read_bytes(), args.cmdline)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(payload)
    for key, value in report.items():
        print(f"{key}: {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
