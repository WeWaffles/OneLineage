#!/usr/bin/env python3
"""Generate a deterministic, QEMU-only ADT from the sanitized m3q manifest."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct

import adt

# The kernel's platform expert matches this value (KernelConfigTables.cpp).
# tests/test_xnu_tools.py keeps it equal to whatever the vendored adaptation
# patch declares, so the ADT and the kernel cannot drift apart silently.
PLATFORM_COMPATIBLE = "onelineage,platform"

U32 = lambda *values: struct.pack("<%dI" % len(values), *values)
U64 = lambda *values: struct.pack("<%dQ" % len(values), *values)
CSTR = lambda value: value.encode("ascii") + b"\0"

QEMU_PHYS_BASE = 0x40000000
QEMU_MEMORY_SIZE = 0x40000000
QEMU_GICD = 0x08000000
QEMU_GICR = 0x080A0000
QEMU_GICD_SIZE = 0x10000
QEMU_GICR_SIZE = 0x200000
QEMU_TIMER_HZ = 62500000


def make_node(name: str, props=(), children=()) -> adt.Node:
    return adt.Node([("name", 0, CSTR(name)), *[(key, 0, value) for key, value in props]], list(children))


def validate_manifest(manifest: dict) -> None:
    required = ("device", "board", "soc", "cpu", "timer", "gic", "handoff_status")
    missing = [name for name in required if name not in manifest]
    if missing:
        raise ValueError("hardware manifest is missing: " + ", ".join(missing))
    if manifest["handoff_status"].get("execution_authorized") is not False:
        raise ValueError("manifest must explicitly keep execution_authorized=false")
    if int(manifest["cpu"].get("count", 0)) < 1:
        raise ValueError("manifest has no CPUs")


def build_qemu(manifest: dict) -> adt.Node:
    validate_manifest(manifest)
    phandles = iter(range(1, 128))
    ph = lambda: ("AAPL,phandle", U32(next(phandles)))
    seed = hashlib.sha512(json.dumps(manifest, sort_keys=True).encode()).digest()

    chosen = make_node("chosen", [
        ph(),
        ("dram-base", U64(QEMU_PHYS_BASE)),
        ("dram-size", U64(QEMU_MEMORY_SIZE)),
        ("random-seed", seed),
        ("debug-enabled", U32(1)),
        ("firmware-version", CSTR("OneLineage-m3q-qemu")),
        ("system-firmware-version", CSTR("OneLineage-m3q-qemu")),
        ("source-device", CSTR(manifest["device"])),
    ], [make_node("memory-map", [ph()])])

    cpu = make_node("cpu0", [
        ph(),
        ("device_type", CSTR("cpu")),
        ("compatible", CSTR("ARM,v8")),
        ("reg", U32(0)),
        ("cpu-id", U32(0)),
        ("state", CSTR("running")),
        ("timebase-frequency", U32(QEMU_TIMER_HZ)),
        ("fixed-frequency", U32(QEMU_TIMER_HZ)),
    ])
    cpus = make_node("cpus", [ph(), ("#address-cells", U32(1)), ("#size-cells", U32(0))], [cpu])

    gic = make_node("gic", [
        ph(),
        ("compatible", CSTR("arm,gic-v3")),
        ("interrupt-controller", b""),
        ("virtual-timer-intid", U32(27)),
        ("reg", U64(QEMU_GICD, QEMU_GICD_SIZE, QEMU_GICR, QEMU_GICR_SIZE)),
    ])
    arm_io = make_node("arm-io", [
        ph(),
        ("device_type", CSTR("onelineage-io")),
        ("compatible", CSTR("onelineage,qemu-virt") + CSTR("arm-io")),
        ("#address-cells", U32(2)),
        ("#size-cells", U32(2)),
    ], [gic, make_node("wdt", [ph(), ("no-pmu", U32(1))])])

    return make_node("device-tree", [
        ph(),
        ("model", CSTR("OneLineage m3q XNU QEMU validation")),
        ("compatible", CSTR(PLATFORM_COMPATIBLE) + CSTR("samsung,m3q") +
         CSTR(manifest["soc"]) + CSTR("AppleARM")),
        ("#address-cells", U32(2)),
        ("#size-cells", U32(2)),
        ("platform-name", CSTR("OneLineage-m3q-qemu")),
        ("clock-frequency", U32(QEMU_TIMER_HZ)),
    ], [chosen, cpus, arm_io])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--mode", choices=("qemu", "phone"), default="qemu")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    validate_manifest(manifest)
    if args.mode == "phone":
        status = manifest["handoff_status"]
        raise SystemExit(
            "refusing phone ADT: execution is not authorized; "
            f"safe payload region is {status.get('safe_payload_region', 'unknown')}; "
            f"framebuffer is {status.get('framebuffer', 'unknown')}"
        )
    encoded = adt.serialize(build_qemu(manifest))
    parsed, end = adt.parse(encoded)
    if end != len(encoded) or adt.serialize(parsed) != encoded:
        raise SystemExit("internal ADT round-trip validation failed")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encoded)
    print(f"wrote validated QEMU ADT: {args.output} ({len(encoded)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

