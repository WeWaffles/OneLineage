#!/usr/bin/env python3
"""Boot the loader against a stub kernel on real QEMU.

The built XNU image is 30 MB, needs macOS to produce, and needs a boot that
works; the loader does not. This drives the whole path -- assemble, extract,
plan, patch, run -- against ``xnu/loader/stub.S``, a payload whose only job is
to print one line if ``x0`` held usable ``boot_args``. It is the difference
between "the loader was reviewed" and "the loader ran".

Needs ``clang`` with an AArch64 ELF target and ``qemu-system-aarch64``. It is a
manual integration check, not part of the offline unit tests:

    python3 tools/xnu/smoke_test.py
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import adt  # noqa: E402
import build_payload  # noqa: E402
import loader  # noqa: E402
import mk_m3q_adt  # noqa: E402
import qemu_run  # noqa: E402

EXPECTED = b"ONELXNU stub: loader placed the segment and passed boot_args"
MANIFEST = ROOT / "kernel" / "device-hardware" / "sm-s948u-azf1.json"
CLANG_TARGETS = ("aarch64-none-elf", "aarch64-elf", "aarch64-linux-gnu")
VIRTUAL_BASE = 0x100000000


def assemble(source: Path, output: Path) -> None:
    clang = shutil.which("clang")
    if not clang:
        raise SystemExit("clang is required to assemble the loader")
    errors = []
    for target in CLANG_TARGETS:
        result = subprocess.run(
            [clang, f"--target={target}", "-c", str(source), "-o", str(output)],
            text=True, capture_output=True,
        )
        if result.returncode == 0:
            print(f"assembled {source.name} with --target={target}")
            return
        errors.append(f"{target}: {result.stderr.strip().splitlines()[:2]}")
    raise SystemExit("no clang target produced an AArch64 ELF object:\n" + "\n".join(errors))


def extract(obj: Path, image: Path, symbols: Path, require: tuple[str, ...]) -> bytes:
    command = [sys.executable, str(HERE / "extract_elf.py"), str(obj),
               "--output", str(image), "--json", str(symbols), "--max-size", "0x10000"]
    for symbol in require:
        command += ["--require-symbol", symbol]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode != 0:
        raise SystemExit(f"extract_elf failed:\n{result.stdout}{result.stderr}")
    return image.read_bytes()


def stub_payload(code: bytes, tree: bytes) -> bytes:
    """Wrap the stub in an ONELXNU payload, using the real packer's layout."""
    physical_base, memory_size = build_payload.adt_memory(tree)
    vmsize = build_payload.align(len(code), 0x4000)
    kernel_end = build_payload.align(VIRTUAL_BASE + vmsize, 0x4000)
    payload = bytearray(build_payload.SEGMENT_TABLE_OFFSET + 32)
    fileoff = len(payload)
    payload += code
    payload += b"\0" * (-len(payload) & 15)
    tree_offset = len(payload)
    payload += tree
    payload += b"\0" * (-len(payload) & 15)
    struct.pack_into("<8sII", payload, 0, build_payload.MAGIC, 1, 1)
    struct.pack_into("<7Q", payload, 0x10, VIRTUAL_BASE, VIRTUAL_BASE, tree_offset,
                     len(tree), kernel_end, physical_base, memory_size)
    command_line = b"debug=0xc serial=3 cpus=1"
    payload[build_payload.CMDLINE_OFFSET:build_payload.CMDLINE_OFFSET + len(command_line)] = command_line
    struct.pack_into("<4Q", payload, build_payload.SEGMENT_TABLE_OFFSET,
                     VIRTUAL_BASE, vmsize, fileoff, len(code))
    return bytes(payload)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--work", type=Path, default=ROOT / "build" / "xnu-smoke")
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args(argv)
    work = args.work
    work.mkdir(parents=True, exist_ok=True)

    qemu = shutil.which("qemu-system-aarch64")
    if not qemu:
        raise SystemExit("qemu-system-aarch64 is not installed; nothing was started")

    assemble(ROOT / "xnu" / "loader" / "loader.S", work / "loader.o")
    image = extract(work / "loader.o", work / "loader.bin", work / "loader.json",
                    ("_start", "loader_params"))
    assemble(ROOT / "xnu" / "loader" / "stub.S", work / "stub.o")
    code = extract(work / "stub.o", work / "stub.bin", work / "stub.json", ("_start",))

    tree = adt.serialize(mk_m3q_adt.build_qemu(json.loads(MANIFEST.read_text(encoding="utf-8"))))
    payload_path = work / "stub.payload"
    payload_path.write_bytes(stub_payload(code, tree))

    layout = qemu_run.plan(payload_path.read_bytes(),
                           loader_size=qemu_run.align(len(image), 0x1000))
    offset = json.loads((work / "loader.json").read_text(encoding="utf-8"))["symbols"][
        "loader_params"]["offset"]
    entry_phys = layout["kernel_entry"] - layout["virtual_base"] + layout["kernel_phys"]
    patched = loader.patch(
        image, offset, boot_args_phys=layout["boot_args_phys"],
        stack_top=layout["stack_top"], entry_phys=entry_phys,
        payload_phys=layout["payload_phys"], kernel_phys=layout["kernel_phys"],
    )
    loader_path = work / "loader.patched.bin"
    loader_path.write_bytes(patched)
    boot_args_path = work / "bootargs.bin"
    boot_args_path.write_bytes(layout["boot_args"])
    console_path = work / "console.log"
    console_path.unlink(missing_ok=True)

    for label, key in (("kernel", "kernel_phys"), ("payload", "payload_phys"),
                       ("loader", "loader_addr"), ("boot_args", "boot_args_phys"),
                       ("adt", "adt_phys"), ("stack", "stack_top")):
        print(f"{label:>9}: {layout[key]:#x}")
    print(f"{'entry':>9}: {entry_phys:#x} physical")

    argv_qemu = qemu_run.command(
        layout, payload_path=payload_path, loader_path=loader_path,
        boot_args_path=boot_args_path, qemu=qemu, console=f"file:{console_path}",
    )
    print("running: " + " ".join(argv_qemu))
    try:
        subprocess.run(argv_qemu, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        pass  # the stub halts in wfi; the timeout is how a boot ends

    console = console_path.read_bytes() if console_path.exists() else b""
    print("--- console ---")
    print(console.decode("utf-8", "replace") or "(no output)")
    print("--- end ---")
    if EXPECTED not in console:
        print("FAILED: the stub did not report a usable boot_args", file=sys.stderr)
        return 1
    print("loader verified: segments placed, x0 = boot_args, entry reached")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
