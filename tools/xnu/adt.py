#!/usr/bin/env python3
"""Small Apple Device Tree encoder/decoder.

Format behavior is based on dipa-studio/ios-sweet's MIT-licensed tools/adt.py.
See LICENSE.ios-sweet in this directory.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import struct


@dataclass
class Node:
    props: list[tuple[str, int, bytes]] = field(default_factory=list)
    children: list["Node"] = field(default_factory=list)

    @property
    def name(self) -> str:
        value = self.prop("name")
        return value.split(b"\0", 1)[0].decode("ascii") if value else "?"

    def prop(self, name: str) -> bytes | None:
        return next((value for key, _flags, value in self.props if key == name), None)


def serialize(node: Node) -> bytes:
    out = bytearray(struct.pack("<II", len(node.props), len(node.children)))
    for name, flags, value in node.props:
        encoded = name.encode("ascii")
        if len(encoded) > 31:
            raise ValueError(f"ADT property name is too long: {name}")
        if flags not in (0, 1):
            raise ValueError(f"unsupported ADT property flags: {flags}")
        out += encoded.ljust(32, b"\0")
        out += struct.pack("<I", len(value) | (flags << 31))
        out += value + b"\0" * (-len(value) & 3)
    for child in node.children:
        out += serialize(child)
    return bytes(out)


def parse(data: bytes, offset: int = 0) -> tuple[Node, int]:
    if offset + 8 > len(data):
        raise ValueError("truncated ADT node header")
    property_count, child_count = struct.unpack_from("<II", data, offset)
    offset += 8
    node = Node()
    for _ in range(property_count):
        if offset + 36 > len(data):
            raise ValueError("truncated ADT property header")
        raw_name = data[offset : offset + 32].split(b"\0", 1)[0]
        try:
            name = raw_name.decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValueError("non-ASCII ADT property name") from exc
        raw_size = struct.unpack_from("<I", data, offset + 32)[0]
        flags, size = raw_size >> 31, raw_size & 0x7FFFFFFF
        start = offset + 36
        end = start + size
        if end > len(data):
            raise ValueError(f"truncated ADT property value: {name}")
        node.props.append((name, flags, data[start:end]))
        offset = start + ((size + 3) & ~3)
    for _ in range(child_count):
        child, offset = parse(data, offset)
        node.children.append(child)
    return node, offset

