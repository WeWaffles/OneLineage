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


if __name__ == "__main__":
    unittest.main()
