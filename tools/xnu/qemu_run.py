#!/usr/bin/env python3
"""Plan and launch the QEMU ``virt`` machine that boots OneLineage's XNU payload.

This is the VM side of the early-console milestone. It reads the ``ONELXNU``
payload produced by ``build_payload.py``, lays out RAM so nothing overlaps,
builds the ``boot_args`` the kernel expects in ``x0``, and emits the exact
``qemu-system-aarch64`` command line.

It will not pretend to boot anything it cannot: without a loader image and a
``qemu-system-aarch64`` binary it prints the plan and refuses. It never touches
a phone, and every report records ``phone_execution_authorized: false``.

The loader itself is ``xnu/loader/loader.S``: it copies the payload's segments
and hands ``boot_args`` to the kernel in ``x0``. Its parameter block (boot_args,
stack top, physical entry, payload address) is written here, from this plan, by
``loader.py`` -- the assembly never computes a layout of its own.

The image must be assembled for an AArch64 ELF target and reduced to raw bytes
with ``extract_elf.py``; ``xnu/README.md`` shows the commands.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess

import boot_args
import loader

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
                         "adt_length", "segments", "loader_params_offset",
                         "loader_patched_size"})


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


def loader_symbols(path: Path) -> dict:
    """Read the symbol map ``extract_elf.py`` wrote for a loader image."""
    report = json.loads(path.read_text(encoding="utf-8"))
    symbols = report.get("symbols") or {}
    if "loader_params" not in symbols:
        raise SystemExit(
            f"{path} has no loader_params symbol; the image was not built from xnu/loader/loader.S"
        )
    return symbols


def prepare_loader(image: bytes, layout: dict, offset: int, output: Path) -> Path:
    """Patch the parameter block and write the image QEMU should load."""
    # The kernel entry is a virtual address, and the loader runs with the MMU
    # off, so it has to branch to the same byte through its physical alias.
    entry_phys = layout["kernel_entry"] - layout["virtual_base"] + layout["ram_base"]
    patched = loader.patch(
        image, offset,
        boot_args_phys=layout["boot_args_phys"],
        stack_top=layout["stack_top"],
        entry_phys=entry_phys,
        payload_phys=layout["payload_phys"],
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(patched)
    layout.update({
        "loader_params_offset": offset,
        "loader_patched_size": len(patched),
        "loader_entry_phys": entry_phys,
        "loader_sha256": hashlib.sha256(patched).hexdigest(),
    })
    print(f"wrote patched loader: {output} ({len(patched)} bytes, params at {offset:#x})")
    print(f"loader jumps to {entry_phys:#x} (kernel entry {layout['kernel_entry']:#x} physical)")
    return output


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("payload", type=Path)
    parser.add_argument("--loader", type=Path, help="raw AArch64 loader image")
    parser.add_argument("--loader-symbols", type=Path,
                        help="JSON from extract_elf.py; needed to patch the loader's parameters")
    parser.add_argument("--loader-out", type=Path,
                        help="where to write the patched loader (default: payload path + .loader.bin)")
    parser.add_argument("--boot-args", type=Path, help="where to write the boot_args blob")
    parser.add_argument("--boot-plan", type=Path, help="where to write the boot plan JSON")
    parser.add_argument("--console", default="stdio", help="stdio or file:PATH")
    parser.add_argument("--execute", action="store_true", help="actually start QEMU")
    args = parser.parse_args(argv)

    payload = args.payload.read_bytes()
    loader_size = LOADER_RESERVE
    image = None
    if args.loader:
        image = args.loader.read_bytes()
        if not image:
            raise SystemExit("loader image is empty")
        loader_size = align(len(image), 0x1000)
    layout = plan(payload, loader_size=loader_size)

    boot_path = args.loader
    if image is not None and args.loader_symbols:
        offset = loader_symbols(args.loader_symbols)["loader_params"]["offset"]
        boot_path = prepare_loader(
            image, layout, offset,
            args.loader_out or args.payload.with_suffix(".loader.bin"),
        )
    elif image is not None:
        print("loader parameter block left blank: pass --loader-symbols to fill it for this boot")

    if args.boot_args:
        args.boot_args.parent.mkdir(parents=True, exist_ok=True)
        args.boot_args.write_bytes(layout["boot_args"])
        print(f"wrote boot_args: {args.boot_args} ({layout['boot_args_size']} bytes)")

    for label, key in (("payload", "payload_phys"), ("loader", "loader_addr"),
                       ("boot_args", "boot_args_phys"), ("adt", "adt_phys")):
        print(f"{label:>9}: {layout[key]:#0x}")
    print(f"{'kernel':>9}: {layout['kernel_entry']:#0x} (virtual), {layout['segments']} segments")

    # Written after loader preparation so the plan records what was patched.
    if args.boot_plan:
        args.boot_plan.parent.mkdir(parents=True, exist_ok=True)
        args.boot_plan.write_text(json.dumps(public_plan(layout), indent=2) + "\n", encoding="utf-8")
        print(f"wrote boot plan: {args.boot_plan}")

    if not args.execute and image is None:
        print("plan only: no loader image was supplied, so there is nothing to execute")
        return 0
    if image is None:
        raise SystemExit("--execute needs a loader image (--loader); the kernel expects boot_args in x0")
    if args.execute and not args.loader_symbols:
        raise SystemExit(
            "--execute needs --loader-symbols: an unpatched loader has no boot_args, stack or entry"
        )
    if not args.execute:
        print("command: " + " ".join(command(layout, payload_path=args.payload,
                                            loader_path=boot_path, console=args.console)))
        return 0

    qemu = shutil.which("qemu-system-aarch64")
    if not qemu:
        raise SystemExit("qemu-system-aarch64 is not installed; nothing was started")
    argv = command(layout, payload_path=args.payload, loader_path=boot_path,
                   qemu=qemu, console=args.console)
    print("running: " + " ".join(argv))
    return subprocess.run(argv, text=True).returncode


if __name__ == "__main__":
    raise SystemExit(main())
