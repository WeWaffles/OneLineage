#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import struct
import sys
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools" / "xnu"
sys.path.insert(0, str(TOOLS))
import adt  # noqa: E402
import boot_args  # noqa: E402
import mk_m3q_adt  # noqa: E402
import inspect_macho  # noqa: E402
import build_payload  # noqa: E402
import extract_elf  # noqa: E402
import loader  # noqa: E402
import qemu_run  # noqa: E402
import verify_xnu_series  # noqa: E402


def child(node: adt.Node, name: str) -> adt.Node:
    return next(item for item in node.children if item.name == name)


class XnuToolsTest(unittest.TestCase):
    def setUp(self):
        self.manifest_path = ROOT / "kernel" / "device-hardware" / "sm-s948u-azf1.json"
        self.manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))

    def test_deterministic_qemu_tree_round_trip(self):
        first = adt.serialize(mk_m3q_adt.build_qemu(self.manifest))
        second = adt.serialize(mk_m3q_adt.build_qemu(self.manifest))
        self.assertEqual(first, second)
        root, end = adt.parse(first)
        self.assertEqual(end, len(first))
        self.assertEqual(root.name, "device-tree")
        self.assertEqual(len(child(root, "cpus").children), 1)
        gic = child(child(root, "arm-io"), "gic")
        regs = struct.unpack("<4Q", gic.prop("reg"))
        self.assertEqual(regs[0], mk_m3q_adt.QEMU_GICD)
        self.assertNotEqual(regs[0], int(self.manifest["gic"]["distributor_base"], 0))

    def test_phone_mode_fails_closed(self):
        output = ROOT / "build" / f"test-phone-{uuid.uuid4().hex}.adt"
        result = subprocess.run(
            [sys.executable, str(TOOLS / "mk_m3q_adt.py"), str(self.manifest_path), str(output), "--mode", "phone"],
            text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing phone ADT", result.stderr)
        self.assertFalse(output.exists())

    def test_parser_rejects_truncation(self):
        with self.assertRaises(ValueError):
            adt.parse(b"\0" * 7)

    def test_arm64_macho_structure(self):
        command = struct.pack(
            "<II16s4Q4I", inspect_macho.LC_SEGMENT_64, 72, b"__TEXT\0",
            0x100000000, 0x1000, 0, 104, 7, 5, 0, 0,
        )
        header = struct.pack(
            "<8I", inspect_macho.MH_MAGIC_64, inspect_macho.CPU_TYPE_ARM64,
            0, inspect_macho.MH_EXECUTE, 1, len(command), 0, 0,
        )
        report = inspect_macho.inspect(header + command)
        self.assertEqual(report["architecture"], "arm64")
        self.assertFalse(report["safe_for_phone_execution"])

    def test_ctf_debug_overlay_is_accepted_but_flagged(self):
        # ctf_insert appends CTF into reserved header padding, so __CTF carries
        # file bytes but no VM bytes. A real kernel build hits this.
        text = struct.pack(
            "<II16s4Q4I", inspect_macho.LC_SEGMENT_64, 72, b"__TEXT\0",
            0x100000000, 0x1000, 0, 104, 7, 5, 0, 0,
        )
        ctf = struct.pack(
            "<II16s4Q4I", inspect_macho.LC_SEGMENT_64, 72, b"__CTF\0",
            0x100001000, 0, 104, 64, 1, 1, 0, 0,
        )
        header = struct.pack(
            "<8I", inspect_macho.MH_MAGIC_64, inspect_macho.CPU_TYPE_ARM64,
            0, inspect_macho.MH_EXECUTE, 2, len(text) + len(ctf), 0, 0,
        )
        report = inspect_macho.inspect(header + text + ctf + b"\0" * 64)
        self.assertEqual(report["debug_overlays"], ["__CTF"])

    def test_mapped_segment_larger_than_its_vm_size_is_rejected(self):
        text = struct.pack(
            "<II16s4Q4I", inspect_macho.LC_SEGMENT_64, 72, b"__TEXT\0",
            0x100000000, 0x1000, 0, 64, 7, 5, 0, 0,
        )
        data = struct.pack(
            "<II16s4Q4I", inspect_macho.LC_SEGMENT_64, 72, b"__DATA\0",
            0x100001000, 8, 64, 16, 3, 3, 0, 0,
        )
        header = struct.pack(
            "<8I", inspect_macho.MH_MAGIC_64, inspect_macho.CPU_TYPE_ARM64,
            0, inspect_macho.MH_EXECUTE, 2, len(text) + len(data), 0, 0,
        )
        with self.assertRaisesRegex(ValueError, "file size exceeds VM size"):
            inspect_macho.inspect(header + text + data + b"\0" * 64)

    def test_macho_wrong_architecture_is_rejected(self):
        header = struct.pack("<8I", inspect_macho.MH_MAGIC_64, 0x01000007, 0, 2, 0, 0, 0, 0)
        with self.assertRaisesRegex(ValueError, "ARM64"):
            inspect_macho.inspect(header)

    def test_qemu_payload_build(self):
        entry = 0x100000100
        command_size = 72 + 288
        file_size = 32 + command_size
        segment = struct.pack(
            "<II16s4Q4I", build_payload.LC_SEGMENT_64, 72, b"__TEXT\0",
            0x100000000, 0x4000, 0, file_size, 7, 5, 0, 0,
        )
        thread_state = bytearray(272)
        struct.pack_into("<Q", thread_state, 256, entry)
        thread = struct.pack("<IIII", build_payload.LC_UNIXTHREAD, 288, 6, 68) + thread_state
        header = struct.pack(
            "<8I", inspect_macho.MH_MAGIC_64, inspect_macho.CPU_TYPE_ARM64,
            0, inspect_macho.MH_EXECUTE, 2, command_size, 0, 0,
        )
        tree = adt.serialize(mk_m3q_adt.build_qemu(self.manifest))
        payload, report = build_payload.build(header + segment + thread, tree, "debug=0xc cpus=1")
        magic, version, segments = struct.unpack_from("<8sII", payload)
        self.assertEqual(magic, build_payload.MAGIC)
        self.assertEqual(version, 1)
        self.assertEqual(segments, 1)
        self.assertEqual(report["entry_virtual_address"], hex(entry))
        self.assertFalse(report["phone_execution_authorized"])



def series_manifest(patches: list[dict], **overrides) -> dict:
    manifest = {
        "schema": 1,
        "milestone": "test",
        "source": {
            "project": "xnu",
            "tag": "xnu-test-1.0",
            "url": "https://example.invalid/xnu.tar.gz",
            "sha256": "0" * 64,
        },
        "build": {
            "dxb_repo": "https://example.invalid/darwin-xnu-build",
            "dxb_sha": "0" * 40,
            "macos_version": "13.5",
            "kernel_config": "DEVELOPMENT",
            "machine_config": "SWEET",
            "arch_config": "ARM64",
        },
        "patches": patches,
    }
    manifest.update(overrides)
    return manifest


def entry(name: str, data: bytes) -> dict:
    return {"name": name, "sha256": verify_xnu_series.sha256_bytes(data), "purpose": "test"}


def elf_object(text: bytes, symbols: list[tuple[str, int, int]], *, machine: int = 183,
               relocations: int = 0) -> bytes:
    """Minimal AArch64 relocatable object: .text, .symtab, .strtab, .shstrtab."""
    text_off = 64
    sym_off = (text_off + len(text) + 7) & ~7
    strtab = bytearray(b"\0")
    name_offsets = {}
    for name, _value, _size in symbols:
        name_offsets[name] = len(strtab)
        strtab += name.encode() + b"\0"
    records = [bytes(24)]
    for name, value, size in symbols:
        records.append(struct.pack("<IBBHQQ", name_offsets[name], 0x12, 0, 1, value, size))
    symtab = b"".join(records)
    strtab = bytes(strtab)
    str_off = (sym_off + len(symtab) + 7) & ~7
    shstr = b"\0.text\0.symtab\0.strtab\0.shstrtab\0.rela.text\0"
    shstr_off = str_off + len(strtab)
    rela_off = shstr_off + len(shstr)
    rela = bytes(24 * relocations)
    sh_off = (rela_off + len(rela) + 7) & ~7
    headers = [bytes(64)]
    headers.append(struct.pack("<IIQQQQIIQQ", 1, 1, 0x6, 0, text_off, len(text), 0, 0, 16, 0))
    headers.append(struct.pack("<IIQQQQIIQQ", 7, 2, 0, 0, sym_off, len(symtab), 3, 1, 8, 24))
    headers.append(struct.pack("<IIQQQQIIQQ", 15, 3, 0, 0, str_off, len(strtab), 0, 0, 1, 0))
    headers.append(struct.pack("<IIQQQQIIQQ", 23, 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0))
    headers.append(struct.pack("<IIQQQQIIQQ", 36, 4, 0, 0, rela_off, len(rela), 2, 1, 8, 24))
    table = b"".join(headers)
    ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
    header = struct.pack("<16sHHIQQQIHHHHHH", ident, 1, machine, 1, 0, 0, sh_off, 0, 64, 0, 0, 64, 6, 4)
    blob = bytearray(sh_off + len(table))
    blob[0:64] = header
    blob[text_off:text_off + len(text)] = text
    blob[sym_off:sym_off + len(symtab)] = symtab
    blob[str_off:str_off + len(strtab)] = strtab
    blob[shstr_off:shstr_off + len(shstr)] = shstr
    blob[rela_off:rela_off + len(rela)] = rela
    blob[sh_off:sh_off + len(table)] = table
    return bytes(blob)


class XnuSeriesTest(unittest.TestCase):
    def setUp(self):
        self.series = verify_xnu_series.load_series()
        self.patches = verify_xnu_series.validate_series(self.series)

    def test_vendored_series_matches_manifest(self):
        self.assertEqual(self.series["source"]["tag"], "xnu-8796.141.3")
        self.assertEqual(len(self.patches), 18)
        self.assertEqual([item["name"][:4] for item in self.patches], [f"{index:04d}" for index in range(1, 19)])
        for item in self.patches:
            self.assertNotIn(b"\r\n", item["data"])
        self.assertFalse(self.series["constraints"]["phone_execution_authorized"])
        self.assertFalse(self.series["verified"]["compiled"])
        self.assertFalse(self.series["verified"]["qemu_console_reached"])

    def test_adaptations_manifest_matches_vendored_patches(self):
        all_entries = verify_xnu_series.verify_entries(
            self.series["adaptations"]["patches"], verify_xnu_series.ADAPTATION_DIR, "adaptations"
        )
        self.assertEqual([item["name"][:4] for item in all_entries], ["0001", "0002", "0003", "0004"])
        for item in all_entries:
            self.assertNotIn(b"\r\n", item["data"])
            self.assertIn("+++ b/", item["data"].decode())

    def test_profiles_select_different_adaptations(self):
        qemu = verify_xnu_series.validate_adaptations(self.series, "qemu")
        phone = verify_xnu_series.validate_adaptations(self.series, "phone")
        self.assertEqual([item["name"][:4] for item in qemu], ["0001", "0002", "0003", "0004"])
        self.assertEqual([item["name"][:4] for item in phone], ["0001", "0002", "0003"])
        self.assertNotIn(
            "0004-onelineage-sweet-profile-flags.patch", [item["name"] for item in phone]
        )

    def test_unknown_profile_in_manifest_is_rejected(self):
        broken = json.loads(json.dumps(self.series))
        broken["adaptations"]["patches"][0]["applies"] = "linux"
        with self.assertRaisesRegex(verify_xnu_series.SeriesError, "unknown profile"):
            verify_xnu_series.validate_adaptations(broken, "qemu")

    def test_adt_publishes_the_compatible_the_platform_expert_matches(self):
        manifest = json.loads(
            (ROOT / "kernel" / "device-hardware" / "sm-s948u-azf1.json").read_text(encoding="utf-8")
        )
        root, _ = adt.parse(adt.serialize(mk_m3q_adt.build_qemu(manifest)))
        compatibles = root.prop("compatible").split(b"\0")
        self.assertEqual(compatibles[0].decode(), mk_m3q_adt.PLATFORM_COMPATIBLE)

        patch = (verify_xnu_series.ADAPTATION_DIR /
                 "0003-onelineage-platform-expert-identity.patch").read_text(encoding="utf-8")
        self.assertIn(
            "'IONameMatch'     = '%s'" % mk_m3q_adt.PLATFORM_COMPATIBLE,
            patch,
            "the kernel's platform-expert match and the ADT compatible must agree",
        )

    def test_qemu_console_address_shares_the_bootstrap_l2_table(self):
        # start.s reaches the console through the first bootstrap L2 table, which
        # covers one 64GB L1 entry in 2048 32MB blocks.
        l1_shift, l2_shift, entries = 36, 25, 2048
        panel, uart = 0x9C000000, 0x09000000
        for address in (panel, uart):
            self.assertEqual(address >> l1_shift, 0)
            self.assertLess((address >> l2_shift) & (entries - 1), entries)

    def test_series_rejects_crlf_patch(self):
        data = b"--- a/value.txt\r\n+++ b/value.txt\r\n@@ -1 +1 @@\r\n-base\r\n+one\r\n"
        with tempfile.TemporaryDirectory() as directory:
            patch_dir = Path(directory)
            (patch_dir / "0001-test.patch").write_bytes(data)
            with self.assertRaisesRegex(verify_xnu_series.SeriesError, "CRLF"):
                verify_xnu_series.validate_series(
                    series_manifest([entry("0001-test.patch", data)]), patch_dir
                )

    def test_series_rejects_hash_mismatch(self):
        data = b"--- a/value.txt\n+++ b/value.txt\n@@ -1 +1 @@\n-base\n+one\n"
        with tempfile.TemporaryDirectory() as directory:
            patch_dir = Path(directory)
            (patch_dir / "0001-test.patch").write_bytes(data)
            with self.assertRaisesRegex(verify_xnu_series.SeriesError, "does not match the manifest"):
                verify_xnu_series.validate_series(
                    series_manifest([{"name": "0001-test.patch", "sha256": "1" * 64}]), patch_dir
                )

    def test_series_rejects_undeclared_and_unsorted_patches(self):
        data = b"--- a/value.txt\n+++ b/value.txt\n@@ -1 +1 @@\n-base\n+one\n"
        with tempfile.TemporaryDirectory() as directory:
            patch_dir = Path(directory)
            (patch_dir / "0001-test.patch").write_bytes(data)
            (patch_dir / "0002-extra.patch").write_bytes(data)
            with self.assertRaisesRegex(verify_xnu_series.SeriesError, "not declared"):
                verify_xnu_series.validate_series(
                    series_manifest([entry("0001-test.patch", data)]), patch_dir
                )
            (patch_dir / "0002-extra.patch").unlink()
            with self.assertRaisesRegex(verify_xnu_series.SeriesError, "duplicate patch"):
                verify_xnu_series.validate_series(
                    series_manifest([entry("0001-test.patch", data), entry("0001-test.patch", data)]),
                    patch_dir,
                )
            with self.assertRaisesRegex(verify_xnu_series.SeriesError, "ascending order"):
                verify_xnu_series.validate_series(
                    series_manifest([entry("0002-test.patch", data), entry("0001-test.patch", data)]),
                    patch_dir,
                )

    def test_apply_refuses_tree_without_provenance_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(verify_xnu_series.SeriesError, "provenance marker"):
                verify_xnu_series.apply_series(Path(directory), [])

    def test_apply_series_in_declared_order(self):
        if not shutil.which("git"):
            self.skipTest("git is required to apply patches")
        first = b"--- a/value.txt\n+++ b/value.txt\n@@ -1 +1 @@\n-base\n+one\n"
        second = b"--- a/value.txt\n+++ b/value.txt\n@@ -1 +1 @@\n-one\n+two\n"
        patches = [
            {"name": "0001-first.patch", "sha256": "0" * 64, "data": first},
            {"name": "0002-second.patch", "sha256": "0" * 64, "data": second},
        ]
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            (tree / "value.txt").write_bytes(b"base\n")
            applied = verify_xnu_series.apply_series(tree, patches, require_marker=False)
            self.assertEqual([item["status"] for item in applied], ["applied", "applied"])
            self.assertEqual((tree / "value.txt").read_text(encoding="utf-8"), "two\n")
            with self.assertRaises(verify_xnu_series.SeriesError):
                verify_xnu_series.apply_series(tree, patches, require_marker=False)

    def test_apply_series_inside_a_git_work_tree_reaches_the_subtree(self):
        """Regression: git used to resolve paths against the enclosing repository.

        With the scratch tree inside a work tree, git skipped every file and
        still exited 0, so the tool reported a clean apply of an unmodified
        tree. The ceiling directory keeps git in plain-files mode.
        """
        if not shutil.which("git"):
            self.skipTest("git is required to apply patches")
        patch = b"--- a/value.txt\n+++ b/value.txt\n@@ -1 +1 @@\n-base\n+one\n"
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "-q", str(repo)], check=True,
                           capture_output=True, text=True)
            tree = repo / "scratch" / "source"
            tree.mkdir(parents=True)
            (tree / "value.txt").write_bytes(b"base\n")
            verify_xnu_series.apply_series(
                tree, [{"name": "0001-first.patch", "sha256": "0" * 64, "data": patch}],
                require_marker=False,
            )
            self.assertEqual((tree / "value.txt").read_text(encoding="utf-8"), "one\n")


def sample_payload(manifest: dict) -> tuple[bytes, dict]:
    """One-segment Mach-O plus ADT, packed the way build_payload.py packs it."""
    entry = 0x100000100
    command_size = 72 + 288
    file_size = 32 + command_size
    segment = struct.pack(
        "<II16s4Q4I", build_payload.LC_SEGMENT_64, 72, b"__TEXT\0",
        0x100000000, 0x4000, 0, file_size, 7, 5, 0, 0,
    )
    thread_state = bytearray(272)
    struct.pack_into("<Q", thread_state, 256, entry)
    thread = struct.pack("<IIII", build_payload.LC_UNIXTHREAD, 288, 6, 68) + thread_state
    header = struct.pack(
        "<8I", inspect_macho.MH_MAGIC_64, inspect_macho.CPU_TYPE_ARM64,
        0, inspect_macho.MH_EXECUTE, 2, command_size, 0, 0,
    )
    tree = adt.serialize(mk_m3q_adt.build_qemu(manifest))
    return build_payload.build(header + segment + thread, tree, "debug=0xc serial=3 cpus=1")


class XnuBootArgsTest(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(
            (ROOT / "kernel" / "device-hardware" / "sm-s948u-azf1.json").read_text(encoding="utf-8")
        )

    def test_offsets_match_the_pinned_boot_h(self):
        header = (ROOT / "build" / "xnu-src" / "source" / "pexpert" / "pexpert" /
                  "arm64" / "boot.h")
        if not header.is_file():
            self.skipTest("pinned tree is not present; run verify_xnu_series.py --fetch")
        text = header.read_text(encoding="utf-8")
        self.assertIn("#define BOOT_LINE_LENGTH        608", text)
        fields = [name for name in ("Revision", "Version", "virtBase", "physBase",
                                    "memSize", "topOfKernelData", "Video",
                                    "machineType", "deviceTreeP", "deviceTreeLength",
                                    "CommandLine", "bootFlags", "memSizeActual")
                  if name in text]
        self.assertEqual(fields, list(boot_args.OFFSETS))
        # CommandLine[608] ends at 716, which bootFlags cannot start at: the
        # compiler pads to the next 8-byte boundary, and so does this builder.
        self.assertEqual(boot_args.OFFSETS["CommandLine"] + boot_args.BOOT_LINE_LENGTH, 716)
        self.assertEqual(boot_args.OFFSETS["bootFlags"], 720)
        self.assertEqual(boot_args.SIZE, 736)

    def test_round_trip(self):
        blob, report = boot_args.build(
            cmdline="debug=0xc serial=3", phys_base=0x40000000, mem_size=0x40000000,
            top_of_kernel_data=0x42000000, device_tree_phys=0x41000000,
            device_tree_length=0x1000,
        )
        self.assertEqual(len(blob), boot_args.SIZE)
        revision, version = struct.unpack_from("<HH", blob, 0)
        self.assertEqual((revision, version), (2, 2))
        virt, phys, size, top = struct.unpack_from("<4Q", blob, boot_args.OFFSETS["virtBase"])
        self.assertEqual((virt, phys, size, top), (0, 0x40000000, 0x40000000, 0x42000000))
        tree, tree_length = struct.unpack_from("<QI", blob, boot_args.OFFSETS["deviceTreeP"])
        self.assertEqual((tree, tree_length), (0x41000000, 0x1000))
        self.assertEqual(
            blob[boot_args.OFFSETS["CommandLine"]:].split(b"\0", 1)[0], b"debug=0xc serial=3"
        )
        self.assertFalse(report["phone_execution_authorized"])

    def test_rejects_values_the_kernel_cannot_use(self):
        common = dict(phys_base=0x40000000, mem_size=0x1000,
                      top_of_kernel_data=0x40000800, device_tree_phys=0x40000400,
                      device_tree_length=0x100)
        with self.assertRaisesRegex(ValueError, "allows 607"):
            boot_args.build(cmdline="x" * 608, **common)
        with self.assertRaisesRegex(ValueError, "aligned"):
            boot_args.build(cmdline="ok", **{**common, "phys_base": 0x40000008})
        with self.assertRaisesRegex(ValueError, "outside RAM"):
            boot_args.build(cmdline="ok", **{**common, "top_of_kernel_data": 0x50000000})


class XnuQemuPlanTest(unittest.TestCase):
    def setUp(self):
        manifest = json.loads(
            (ROOT / "kernel" / "device-hardware" / "sm-s948u-azf1.json").read_text(encoding="utf-8")
        )
        self.payload, _report = sample_payload(manifest)
        self.plan = qemu_run.plan(self.payload)

    def test_payload_header_is_decoded(self):
        info = qemu_run.parse_payload(self.payload)
        self.assertEqual(info["phys_base"], 0x40000000)
        self.assertEqual(info["segments"], 1)
        self.assertEqual(info["cmdline"], "debug=0xc serial=3 cpus=1")
        with self.assertRaisesRegex(ValueError, "magic"):
            qemu_run.parse_payload(b"NOTXNU\0" + self.payload[8:])

    def test_layout_regions_do_not_overlap(self):
        regions = [
            (self.plan["payload_phys"], self.plan["payload_size"], "payload"),
            (self.plan["loader_addr"], self.plan["loader_reserve"], "loader"),
            (self.plan["boot_args_phys"], self.plan["boot_args_size"], "boot_args"),
            (self.plan["stack_bottom"], self.plan["stack_top"] - self.plan["stack_bottom"], "stack"),
        ]
        for index, (start, size, name) in enumerate(regions):
            # Everything but the stack is page aligned; the stack only needs the
            # AArch64 16-byte alignment rule.
            alignment = 16 if name == "stack" else qemu_run.PAGE
            self.assertEqual(start % alignment, 0, f"{name} is not aligned")
            for other_start, other_size, other_name in regions[index + 1:]:
                self.assertLessEqual(start + size, other_start,
                                     f"{name} overlaps {other_name}")
        self.assertLessEqual(self.plan["top_of_kernel_data"],
                             self.plan["ram_base"] + self.plan["ram_size"])

    def test_boot_args_points_at_the_embedded_adt(self):
        self.assertEqual(self.plan["adt_phys"],
                         self.plan["payload_phys"] + qemu_run.parse_payload(self.payload)["tree_offset"])
        self.assertEqual(self.plan["boot_args_report"]["device_tree_phys"], hex(self.plan["adt_phys"]))
        self.assertEqual(self.plan["boot_args_report"]["top_of_kernel_data"],
                         hex(self.plan["top_of_kernel_data"]))

    def test_command_loads_loader_and_payload(self):
        argv = qemu_run.command(
            self.plan, payload_path=Path("payload.bin"), loader_path=Path("loader.bin")
        )
        joined = " ".join(argv)
        self.assertIn("qemu-system-aarch64", argv[0])
        self.assertIn("virt,gic-version=3", joined)
        self.assertIn(f"addr={self.plan['payload_phys']:#x}", joined)
        self.assertIn(f"addr={self.plan['loader_addr']:#x}", joined)
        self.assertIn("cpu-num=0", joined)
        self.assertIn("mon:stdio", joined)

    def test_plan_rejects_ram_qemu_cannot_express(self):
        patched = bytearray(self.payload)
        # mem_size is the seventh uint64 of the ONELXNU header (0x10 + 6 * 8).
        struct.pack_into("<Q", patched, 0x40, 0x1000)
        with self.assertRaisesRegex(ValueError, "whole number of MiB"):
            qemu_run.plan(bytes(patched))

    def test_public_plan_has_no_blobs_and_keeps_flags_boolean(self):
        public = qemu_run.public_plan(self.plan)
        self.assertNotIn("boot_args", public)
        self.assertIs(public["phone_execution_authorized"], False)
        self.assertEqual(public["payload_phys"], hex(self.plan["payload_phys"]))
        self.assertEqual(public["segments"], 1)
        json.dumps(public)  # must be serialisable as written

    def test_command_refuses_an_authorized_boot(self):
        with self.assertRaisesRegex(ValueError, "authorized"):
            qemu_run.command({**self.plan, "phone_execution_authorized": True},
                             payload_path=Path("payload.bin"), loader_path=Path("loader.bin"))


class XnuLoaderImageTest(unittest.TestCase):
    def setUp(self):
        self.text = bytes(range(64))
        self.object = elf_object(
            self.text, [("_start", 0, 4), ("uart_report", 8, 8), ("loader_params", 16, 48)]
        )

    def test_extracts_the_section_and_symbol_offsets(self):
        image, report = extract_elf.extract(self.object)
        self.assertEqual(image, self.text)
        self.assertEqual(report["machine"], "aarch64")
        self.assertEqual(report["symbols"]["loader_params"], {"offset": 16, "size": 48})
        self.assertEqual(report["size"], len(self.text))
        self.assertFalse(report["phone_execution_authorized"])

    def test_rejects_a_non_aarch64_object(self):
        with self.assertRaisesRegex(ValueError, "not AArch64"):
            extract_elf.extract(elf_object(self.text, [("_start", 0, 4)], machine=62))

    def test_rejects_a_missing_section(self):
        with self.assertRaisesRegex(ValueError, "no .data section"):
            extract_elf.extract(self.object, ".data")

    def test_cli_writes_the_image_and_enforces_its_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            obj = work / "loader.o"
            obj.write_bytes(self.object)
            out = work / "loader.bin"
            report = work / "loader.json"
            base = [sys.executable, str(TOOLS / "extract_elf.py"), str(obj),
                    "--output", str(out), "--json", str(report)]
            ok = subprocess.run(base + ["--max-size", "0x10000", "--require-symbol", "loader_params"],
                                text=True, capture_output=True)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            self.assertEqual(out.read_bytes(), self.text)
            self.assertIn("loader_params", json.loads(report.read_text(encoding="utf-8"))["symbols"])

            too_small = subprocess.run(base + ["--max-size", "8"], text=True, capture_output=True)
            self.assertEqual(too_small.returncode, 1)
            self.assertIn("more than the 8 bytes", too_small.stderr)

            missing = subprocess.run(base + ["--require-symbol", "nope"], text=True, capture_output=True)
            self.assertEqual(missing.returncode, 1)
            self.assertIn("does not define nope", missing.stderr)

    def test_rejects_unresolved_relocations(self):
        # A reference to a global symbol stays a relocation in an object file;
        # extracted raw, the instruction would carry a zero instead of an
        # address. The loader uses a local label to avoid that, and this guard
        # is what notices if it ever stops doing so.
        with self.assertRaisesRegex(ValueError, "unresolved relocation"):
            extract_elf.extract(elf_object(
                self.text, [("_start", 0, 4), ("loader_params", 16, 48)], relocations=1
            ))
        image, report = extract_elf.extract(elf_object(
            self.text, [("_start", 0, 4), ("loader_params", 16, 48)], relocations=0
        ))
        self.assertEqual(report["symbols"]["loader_params"]["offset"], 16)
        self.assertEqual(len(image), len(self.text))

    def test_requires_the_entry_point_at_offset_zero(self):
        moved = elf_object(self.text, [("_start", 4, 4), ("loader_params", 16, 48)])
        with self.assertRaisesRegex(ValueError, "first byte"):
            extract_elf.extract(moved)
        # without the check the image is still usable, e.g. for inspection
        image, _report = extract_elf.extract(moved, start=None)
        self.assertEqual(image, self.text)


class XnuLoaderParamsTest(unittest.TestCase):
    def setUp(self):
        self.image = bytes(16) + bytes(loader.SIZE) + bytes(16)
        self.offset = 16
        self.values = dict(boot_args_phys=0x40020000, stack_top=0x40030000,
                           entry_phys=0x40001000, payload_phys=0x40000000)

    def test_patch_round_trip_and_idempotence(self):
        patched = loader.patch(self.image, self.offset, **self.values)
        values = loader.read(patched, self.offset)
        self.assertTrue(values["patched"])
        self.assertEqual(values["magic"], "ONELPARM")
        self.assertEqual(values["version"], 1)
        for name, value in self.values.items():
            self.assertEqual(values[name], value)
        self.assertEqual(loader.patch(patched, self.offset, **self.values), patched)
        self.assertEqual(len(patched), len(self.image))
        # the placeholder magics in loader.S must match this tool
        source = (ROOT / "xnu" / "loader" / "loader.S").read_text(encoding="utf-8")
        self.assertIn('becomes "ONELPARM"', source)

    def test_rejects_reuse_for_a_different_boot(self):
        patched = loader.patch(self.image, self.offset, **self.values)
        with self.assertRaisesRegex(ValueError, "already patched"):
            loader.patch(patched, self.offset, **{**self.values, "stack_top": 0x40040000})

    def test_rejects_a_block_that_is_not_the_placeholder(self):
        dirty = bytearray(self.image)
        dirty[self.offset + 16] = 0xFF
        with self.assertRaisesRegex(ValueError, "not the loader's placeholder"):
            loader.patch(bytes(dirty), self.offset, **self.values)

    def test_rejects_bad_addresses_and_truncation(self):
        with self.assertRaisesRegex(ValueError, "must be a physical address above zero"):
            loader.patch(self.image, self.offset, **{**self.values, "entry_phys": 0})
        with self.assertRaisesRegex(ValueError, "not 0x4000-aligned"):
            loader.patch(self.image, self.offset, **{**self.values, "payload_phys": 0x40000008})
        with self.assertRaisesRegex(ValueError, "does not fit"):
            loader.patch(bytes(16), 16, **self.values)

    def test_summary_is_report_safe(self):
        report = loader.summarize(loader.patch(self.image, self.offset, **self.values), self.offset)
        self.assertEqual(report["boot_args_phys"], hex(self.values["boot_args_phys"]))
        self.assertIs(report["phone_execution_authorized"], False)
        json.dumps(report)


class XnuQemuLoaderRunTest(unittest.TestCase):
    def setUp(self):
        manifest = json.loads(
            (ROOT / "kernel" / "device-hardware" / "sm-s948u-azf1.json").read_text(encoding="utf-8")
        )
        self.payload, _report = sample_payload(manifest)
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)
        self.payload_path = self.dir / "payload.bin"
        self.payload_path.write_bytes(self.payload)
        self.loader_path = self.dir / "loader.bin"
        self.loader_path.write_bytes(bytes(8) + bytes(loader.SIZE) + bytes(8))
        self.symbols_path = self.dir / "loader.json"
        self.symbols_path.write_text(json.dumps({"symbols": {
            "_start": {"offset": 0, "size": 4},
            "loader_params": {"offset": 8, "size": loader.SIZE},
        }}), encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def test_run_fills_the_parameters_from_the_plan(self):
        out = self.dir / "loader.patched.bin"
        plan_path = self.dir / "plan.json"
        self.assertEqual(qemu_run.main([
            str(self.payload_path), "--loader", str(self.loader_path),
            "--loader-symbols", str(self.symbols_path), "--loader-out", str(out),
            "--boot-plan", str(plan_path),
        ]), 0)
        layout = qemu_run.plan(self.payload, loader_size=qemu_run.align(len(self.loader_path.read_bytes()), 0x1000))
        values = loader.read(out.read_bytes(), 8)
        self.assertTrue(values["patched"])
        self.assertEqual(values["boot_args_phys"], layout["boot_args_phys"])
        self.assertEqual(values["stack_top"], layout["stack_top"])
        self.assertEqual(values["payload_phys"], layout["payload_phys"])
        self.assertEqual(
            values["entry_phys"],
            layout["kernel_entry"] - layout["virtual_base"] + layout["ram_base"],
        )
        written = json.loads(plan_path.read_text(encoding="utf-8"))
        self.assertEqual(written["loader_params_offset"], 8)
        self.assertEqual(written["loader_entry_phys"], hex(values["entry_phys"]))

    def test_execute_refuses_an_unpatched_loader(self):
        with self.assertRaisesRegex(SystemExit, "needs --loader-symbols"):
            qemu_run.main([str(self.payload_path), "--loader", str(self.loader_path), "--execute"])

    def test_execute_still_refuses_a_missing_loader(self):
        with self.assertRaisesRegex(SystemExit, "needs a loader image"):
            qemu_run.main([str(self.payload_path), "--execute"])

    def test_symbol_map_without_the_parameter_block_is_rejected(self):
        empty = self.dir / "empty.json"
        empty.write_text(json.dumps({"symbols": {"_start": {"offset": 0, "size": 4}}}), encoding="utf-8")
        with self.assertRaisesRegex(SystemExit, "no loader_params"):
            qemu_run.main([
                str(self.payload_path), "--loader", str(self.loader_path),
                "--loader-symbols", str(empty),
            ])


if __name__ == "__main__":
    unittest.main()
