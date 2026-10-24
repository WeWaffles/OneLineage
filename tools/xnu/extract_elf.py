#!/usr/bin/env python3
"""Turn an assembled AArch64 ELF object into the flat loader image QEMU loads.

The loader is assembled as a relocatable ELF object, which cannot be handed to
``-device loader,file=...``: QEMU loads raw bytes at an address, it does not
link. This extracts one section verbatim and reports the offset of every symbol
inside it, so ``tools/xnu/loader.py`` can find the parameter block to patch
without a second, drifting copy of the layout.

Only what is needed is implemented, with the standard library, because the
build runs where ``llvm-objcopy`` may not exist.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

ELF_MAGIC = b"\x7fELF"
ELFCLASS64 = 2
ELFDATA2LSB = 1
ET_REL = 1
EM_AARCH64 = 183
SHT_SYMTAB = 2
SHT_RELA = 4
SHF_EXECINSTR = 0x4
SHN_UNDEF = 0
HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
SECTION = struct.Struct("<IIQQQQIIQQ")
SYMBOL = struct.Struct("<IBBHQQ")


def _sections(data: bytes) -> tuple[dict, bytes]:
    if len(data) < HEADER.size:
        raise ValueError("file is shorter than an ELF64 header")
    (ident, e_type, e_machine, _version, _entry, _phoff, e_shoff, _flags,
     _ehsize, _phentsize, _phnum, e_shentsize, e_shnum,
     e_shstrndx) = HEADER.unpack_from(data)
    if ident[:4] != ELF_MAGIC:
        raise ValueError("not an ELF file")
    if ident[4] != ELFCLASS64 or ident[5] != ELFDATA2LSB:
        raise ValueError("only little-endian ELF64 is supported")
    if e_type != ET_REL:
        raise ValueError(f"ELF type {e_type} is not a relocatable object")
    if e_machine != EM_AARCH64:
        raise ValueError(f"ELF machine {e_machine} is not AArch64")
    if e_shentsize != SECTION.size or not e_shnum:
        raise ValueError("ELF has no usable section table")
    if e_shoff + e_shentsize * e_shnum > len(data):
        raise ValueError("section table extends past end of file")
    raw = [SECTION.unpack_from(data, e_shoff + e_shentsize * index) for index in range(e_shnum)]
    if e_shstrndx >= e_shnum:
        raise ValueError("section-name table index is out of range")
    names = raw[e_shstrndx]
    strings = data[names[4]:names[4] + names[5]]
    table = {}
    for index, (name_offset, sh_type, sh_flags, sh_addr, sh_offset, sh_size,
                sh_link, sh_info, _align, sh_entsize) in enumerate(raw):
        end = strings.find(b"\0", name_offset)
        name = strings[name_offset:end if end >= 0 else len(strings)].decode("ascii", "replace")
        table[name] = {"index": index, "type": sh_type, "flags": sh_flags,
                       "addr": sh_addr, "offset": sh_offset, "size": sh_size,
                       "link": sh_link, "info": sh_info, "entsize": sh_entsize}
    return table, data


def extract(data: bytes, section: str = ".text", start: str | None = "_start") -> tuple[bytes, dict]:
    """Return the raw bytes of ``section`` and a report of its symbols."""
    table, _ = _sections(data)
    if section not in table:
        raise ValueError(f"ELF has no {section} section")
    chosen = table[section]
    if not chosen["flags"] & SHF_EXECINSTR:
        raise ValueError(f"{section} is not an executable section")
    if chosen["offset"] + chosen["size"] > len(data):
        raise ValueError(f"{section} extends past end of file")
    image = data[chosen["offset"]:chosen["offset"] + chosen["size"]]
    if not image:
        raise ValueError(f"{section} is empty; the loader did not assemble")

    # A raw image cannot carry relocations. If one survives, the bytes in the
    # extracted section hold a zero where an address should be, so this must
    # fail loudly rather than produce an image that faults on first use.
    for name, item in table.items():
        if item["type"] == SHT_RELA and item["info"] == chosen["index"] and item["size"]:
            count = item["size"] // (item["entsize"] or 24)
            raise ValueError(
                f"{section} has {count} unresolved relocation(s) in {name}; "
                "the image would silently contain zeros where addresses belong"
            )

    symbols = {}
    symtab = next((item for item in table.values() if item["type"] == SHT_SYMTAB), None)
    if symtab is not None:
        strtab = table.get(next((name for name, item in table.items()
                                 if item["index"] == symtab["link"]), ""), None)
        if strtab is None:
            raise ValueError("symbol table has no string table")
        strings = data[strtab["offset"]:strtab["offset"] + strtab["size"]]
        stride = symtab["entsize"] or SYMBOL.size
        if stride != SYMBOL.size:
            raise ValueError(f"unexpected ELF64 symbol size {stride}")
        for offset in range(symtab["offset"], symtab["offset"] + symtab["size"], stride):
            if offset + SYMBOL.size > len(data):
                break
            name_offset, _info, _other, shndx, value, size = SYMBOL.unpack_from(data, offset)
            if shndx == SHN_UNDEF or shndx != chosen["index"]:
                continue
            end = strings.find(b"\0", name_offset)
            name = strings[name_offset:end if end >= 0 else len(strings)].decode("ascii", "replace")
            if not name:
                continue
            if value >= len(image) or value + size > len(image):
                raise ValueError(f"symbol {name} is outside {section}")
            symbols[name] = {"offset": value, "size": size}

    if start is not None:
        if start not in symbols:
            raise ValueError(f"{section} does not define {start}; the image has no entry point")
        if symbols[start]["offset"] != 0:
            raise ValueError(
                f"{start} sits at offset {symbols[start]['offset']} of {section}; "
                "QEMU enters the image at its first byte"
            )

    report = {
        "format": "elf64",
        "machine": "aarch64",
        "section": section,
        "size": len(image),
        "sha256": hashlib.sha256(image).hexdigest(),
        "symbols": symbols,
        "phone_execution_authorized": False,
    }
    return image, report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("object", type=Path)
    parser.add_argument("--section", default=".text")
    parser.add_argument("--start", default="_start",
                        help="symbol that must sit at offset 0 ('' to skip the check)")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--max-size", type=lambda value: int(value, 0),
                        help="fail if the image is larger than this many bytes")
    parser.add_argument("--require-symbol", action="append", default=[],
                        help="fail unless the image defines this symbol (repeatable)")
    args = parser.parse_args(argv)

    try:
        image, report = extract(args.object.read_bytes(), args.section, args.start or None)
        if args.max_size is not None and len(image) > args.max_size:
            raise ValueError(
                f"image is {len(image)} bytes, more than the {args.max_size} bytes reserved for it"
            )
        missing = [name for name in args.require_symbol if name not in report["symbols"]]
        if missing:
            raise ValueError("image does not define " + ", ".join(missing))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(image)}-byte {report['section']}: {args.output}")
    print(f"sha256: {report['sha256']}")
    for name, item in sorted(report["symbols"].items(), key=lambda pair: pair[1]["offset"]):
        print(f"  {item['offset']:#06x}  {name} ({item['size']} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
