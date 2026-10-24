#!/usr/bin/env python3
"""Plan and launch the QEMU ``virt`` machine that boots OneLineage's XNU payload.

This is the VM side of the early-console milestone. It reads the ``ONELXNU``
payload produced by ``build_payload.py``, lays out RAM so nothing overlaps,
builds the ``boot_args`` the kernel expects in ``x0``, and emits the exact
``qemu-system-aarch64`` command line.

It will not pretend to boot anything it cannot: without a loader image and a
``qemu-system-aarch64`` binary it prints the plan and refuses. It never touches
a phone, and every report records ``phone_execution_authorized: false``.

The loader is deliberately not written here. Assembling an AArch64 image needs
a cross toolchain this project does not vendor; ``xnu/README.md`` records the
contract it has to satisfy. The payload is self-describing (magic, version,
segment table, entry, virtual base), so the loader reads its instruction from
the payload header rather than from a second, drifting copy.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import struct
import subprocess

import boot_args

MAGIC = b"ONELXNU\0"
VERSION = 1
HEADER_FIELDS = ("virtual_base", "entry", "tree_offset", "tree_size",
                 "kernel_end", "phys_base", "mem_size")
CMDLINE_OFFSET = 0x48
BOOT_LINE_LENGTH = 608
SEGMENT_TABLE_OFFSET = CMDLINE_OFFSET + BOOT_LINE_LENGTH

QEMU_MACHINE = "virt,gic-version=3"
QEMU_CPU = "cortex-a72"
PAGE = 0x4000
LOADER_RESERVE = 0x10000
STACK_SIZE = 0x10000


def align(value: int, boundary: int = PAGE) -> int:
    return (value + boundary - 1) & ~(boundary - 1)


def parse_payload(payload: bytes) -> dict:
    """Decode the v1 ``ONELXNU`` header written by build_payload.py."""
    if len(payload) < SEGMENT_TABLE_OFFSET:
        raise ValueError("payload is shorter than its header")
    magic, version, segments = struct.unpack_from("<8sII", payload, 0)
    if magic != MAGIC:
        raise ValueError(f"payload magic is {magic!r}, expected {MAGIC!r}")
    if version != VERSION:
        raise ValueError(f"unsupported payload version {version}")
    if segments <= 0:
        raise ValueError("payload declares no segments")
    values = dict(zip(HEADER_FIELDS, struct.unpack_from("<7Q", payload, 0x10)))
    table_size = SEGMENT_TABLE_OFFSET + 32 * segments
    if table_size > len(payload):
        raise ValueError("payload is shorter than its segment table")
    raw_cmdline = payload[CMDLINE_OFFSET:CMDLINE_OFFSET + BOOT_LINE_LENGTH]
    values["segments"] = segments
    values["segment_table"] = [
        dict(zip(("vmaddr", "vmsize", "fileoff", "filesize"),
                 struct.unpack_from("<4Q", payload, SEGMENT_TABLE_OFFSET + 32 * index)))
        for index in range(segments)
    ]
    values["cmdline"] = raw_cmdline.split(b"\0", 1)[0].decode("utf-8", "replace")
    values["size"] = len(payload)
    if values["tree_offset"] + values["tree_size"] > len(payload):
        raise ValueError("embedded device tree is out of bounds")
    return values


def plan(payload: bytes, *, loader_size: int = LOADER_RESERVE) -> dict:
    """Lay out RAM for one boot and build the matching boot_args block."""
    info = parse_payload(payload)
    phys_base = info["phys_base"]
    mem_end = phys_base + info["mem_size"]
    if phys_base % PAGE:
        raise ValueError(f"payload physical base {phys_base:#x} is not page aligned")
    if info["mem_size"] <= 0 or info["mem_size"] % (1 << 20):
        raise ValueError("QEMU -m takes a whole number of MiB of RAM")

    payload_end = phys_base + len(payload)
    loader_addr = align(payload_end)
    loader_end = loader_addr + loader_size
    boot_args_addr = align(loader_end)
    # The stack only has to satisfy the AArch64 16-byte alignment rule; making
    # it page aligned instead would waste RAM for no benefit.
    stack_bottom = align(boot_args_addr + boot_args.SIZE, 16)
    stack_top = align(stack_bottom + STACK_SIZE, 16)
    top_of_kernel_data = align(stack_top)
    if top_of_kernel_data > mem_end:
        raise ValueError(
            f"layout needs {top_of_kernel_data - phys_base:#x} bytes of RAM, "
            f"the payload declares {info['mem_size']:#x}"
        )

    device_tree_phys = phys_base + info["tree_offset"]
    blob, args_report = boot_args.build(
        cmdline=info["cmdline"],
        phys_base=phys_base,
        mem_size=info["mem_size"],
        top_of_kernel_data=top_of_kernel_data,
        device_tree_phys=device_tree_phys,
        device_tree_length=info["tree_size"],
    )
    return {
        "machine": QEMU_MACHINE,
        "cpu": QEMU_CPU,
        "ram_base": phys_base,
        "ram_size": info["mem_size"],
        "payload_phys": phys_base,
        "payload_size": len(payload),
        "loader_addr": loader_addr,
        "loader_reserve": loader_size,
        "boot_args_phys": boot_args_addr,
        "boot_args_size": boot_args.SIZE,
        "boot_args": blob,
        "boot_args_report": args_report,
        "stack_bottom": stack_bottom,
        "stack_top": stack_top,
        "top_of_kernel_data": top_of_kernel_data,
        "adt_phys": device_tree_phys,
        "adt_length": info["tree_size"],
        "kernel_entry": info["entry"],
        "virtual_base": info["virtual_base"],
        "segments": info["segments"],
        "phone_execution_authorized": False,
    }


def command(plan_: dict, *, payload_path: Path, loader_path: Path,
            qemu: str = "qemu-system-aarch64", console: str = "stdio") -> list[str]:
    """QEMU argument vector for a planned boot."""
    if plan_["phone_execution_authorized"]:
        raise ValueError("refusing to build a command for an authorized execution")
    argv = [
        qemu,
        "-M", plan_["machine"],
        "-cpu", plan_["cpu"],
        "-m", str(plan_["ram_size"] // (1024 * 1024)),
        "-smp", "1",
        "-device", f"loader,file={payload_path},addr={plan_['payload_phys']:#x},force-raw=on",
        "-device", f"loader,file={loader_path},addr={plan_['loader_addr']:#x},cpu-num=0,force-raw=on",
        # The kernel's bootstrap console is the PL011 at 0x09000000, so the
        # serial line carries the first visible output. "stdio" borrows QEMU's
        # monitor-on-stdio preset; anything else is a QEMU chardev spec such as
        # "file:console.log" and is passed through unchanged.
        "-serial", "mon:stdio" if console == "stdio" else console,
        "-display", "none",
        "-no-reboot",
    ]
    return argv


NUMERIC_KEYS = frozenset({"payload_size", "loader_reserve", "boot_args_size",
                         "adt_length", "segments"})


def public_plan(plan_: dict) -> dict:
    """Report-safe view: addresses as hex, no binary blobs."""
    out = {}
    for key, value in plan_.items():
        if key in ("boot_args", "boot_args_report"):
            continue
        if isinstance(value, bool) or not isinstance(value, int):
            out[key] = value
        else:
            out[key] = value if key in NUMERIC_KEYS else hex(value)
    out["boot_args_fields"] = plan_["boot_args_report"]
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("payload", type=Path)
    parser.add_argument("--loader", type=Path, help="assembled AArch64 loader image")
    parser.add_argument("--boot-args", type=Path, help="where to write the boot_args blob")
    parser.add_argument("--boot-plan", type=Path, help="where to write the boot plan JSON")
    parser.add_argument("--console", default="stdio", help="stdio or file:PATH")
    parser.add_argument("--execute", action="store_true", help="actually start QEMU")
    args = parser.parse_args(argv)

    payload = args.payload.read_bytes()
    loader_size = LOADER_RESERVE
    if args.loader:
        loader = args.loader.read_bytes()
        if not loader:
            raise SystemExit("loader image is empty")
        loader_size = align(len(loader), 0x1000)
    layout = plan(payload, loader_size=loader_size)

    if args.boot_args:
        args.boot_args.parent.mkdir(parents=True, exist_ok=True)
        args.boot_args.write_bytes(layout["boot_args"])
        print(f"wrote boot_args: {args.boot_args} ({layout['boot_args_size']} bytes)")
    if args.boot_plan:
        args.boot_plan.parent.mkdir(parents=True, exist_ok=True)
        args.boot_plan.write_text(json.dumps(public_plan(layout), indent=2) + "\n", encoding="utf-8")
        print(f"wrote boot plan: {args.boot_plan}")

    for label, key in (("payload", "payload_phys"), ("loader", "loader_addr"),
                       ("boot_args", "boot_args_phys"), ("adt", "adt_phys")):
        print(f"{label:>9}: {layout[key]:#0x}")
    print(f"{'kernel':>9}: {layout['kernel_entry']:#0x} (virtual), {layout['segments']} segments")

    if not args.execute and not args.loader:
        print("plan only: no loader image was supplied, so there is nothing to execute")
        return 0
    if not args.loader:
        raise SystemExit("--execute needs a loader image (--loader); the kernel expects boot_args in x0")
    if not args.execute:
        print("command: " + " ".join(command(layout, payload_path=args.payload,
                                            loader_path=args.loader, console=args.console)))
        return 0

    qemu = shutil.which("qemu-system-aarch64")
    if not qemu:
        raise SystemExit("qemu-system-aarch64 is not installed; nothing was started")
    argv = command(layout, payload_path=args.payload, loader_path=args.loader,
                   qemu=qemu, console=args.console)
    print("running: " + " ".join(argv))
    return subprocess.run(argv, text=True).returncode


if __name__ == "__main__":
    raise SystemExit(main())
