#!/usr/bin/env python3
"""guest_google.sh: the shipped APK extraction and manifest checks against real
ZIP fixtures, and the cases where it adds nothing (it never stops a switch)."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'switcher/assets/guest_google.sh'
SOURCE = SCRIPT.read_text()
EXTRACT = SOURCE[SOURCE.index('    for apk in "$new"/*.apk; do'):SOURCE.index('    cp "$CACHE/.$name.stat" "$new/source.stat"')]
VERIFY = SOURCE[SOURCE.index('plain_tree() {'):SOURCE.index('# Copy <package>')]
GUARDS = '# framework overlays built by scripts/make-overlays.sh with the storage, installd, power, sysrq, weaver, biometric, gatekeeper, pdb, apexd, appid15000 and nousers guards\n'
COLOROS = GUARDS + '0' * 64 + '  oplus-services_patched.jar\n'


class Snapshot(unittest.TestCase):
    def run_fixture(self, libraries):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'lib/arm64').mkdir(parents=True)
            with zipfile.ZipFile(root / 'base.apk', 'w') as z:
                z.writestr('classes.dex', b'fixture')
                z.writestr('lib/armeabi-v7a/libwrong.so', b'wrong ABI')
            with zipfile.ZipFile(root / 'split_config.arm64_v8a.apk', 'w') as z:
                z.writestr('resources.arsc', b'fixture')
                for name, data in libraries.items(): z.writestr(name, data)
            bb = root / 'bb'
            bb.write_text('#!/bin/sh\nexec "$@"\n'); bb.chmod(0o755)
            env = dict(os.environ, new=t, BB=str(bb))
            body = VERIFY + 'run() {\n' + EXTRACT + '}\nrun || { echo "$WHY" >&2; exit 3; }\nverify "$new" || { echo invalid >&2; exit 3; }\n'
            # verify needs the APK list run() wrote; the libraries stay in lib/.
            result = subprocess.run(['/bin/sh', '-ec', body], env=env, capture_output=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertFalse((root / 'lib/libwrong.so').exists())
            return {p.relative_to(root).as_posix(): p.read_bytes() for p in (root / 'lib').rglob('*.so')}, (root / 'native.sha256').read_text()

    def test_libraries_in_split_apk_are_extracted_and_verified(self):
        files, manifest = self.run_fixture({'lib/arm64-v8a/libexample.so': b'arm64 fixture'})
        self.assertEqual({'lib/libexample.so': b'arm64 fixture', 'lib/arm64/libexample.so': b'arm64 fixture'}, files)
        self.assertEqual(2, len(manifest.splitlines()))

    def test_apks_without_native_libraries_have_valid_empty_manifest(self):
        self.assertEqual(({}, ''), self.run_fixture({}))

    def test_modified_native_library_is_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'base.apk').write_bytes(b'fixture')
            (root / 'native.so').write_bytes(b'original')
            subprocess.run(['/bin/sh', '-ec', 'sha256sum base.apk > apk.sha256; sha256sum native.so > native.sha256'], cwd=t, check=True)
            self.assertEqual(0, subprocess.run(['/bin/sh', '-ec', VERIFY + 'verify "$d"'], env=dict(os.environ, d=t)).returncode)
            (root / 'native.so').write_bytes(b'changed')
            self.assertNotEqual(0, subprocess.run(['/bin/sh', '-ec', VERIFY + 'verify "$d"'], env=dict(os.environ, d=t)).returncode)

    def test_link_below_copy_is_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'base.apk').write_bytes(b'fixture')
            subprocess.run(['/bin/sh', '-ec', 'sha256sum base.apk > apk.sha256; : > native.sha256'], cwd=t, check=True)
            (root / 'data').symlink_to('/data/data')
            self.assertNotEqual(0, subprocess.run(['/bin/sh', '-ec', VERIFY + 'verify "$d"'], env=dict(os.environ, d=t)).returncode)

    def test_archive_listing_failure_is_reported(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t); (root / 'broken.apk').write_bytes(b'not a zip')
            bb = root / 'bb'; bb.write_text('#!/bin/sh\nexec "$@"\n'); bb.chmod(0o755)
            body = 'run() {\n' + EXTRACT + '}\nrun || { echo "$WHY" >&2; exit 3; }\n'
            r = subprocess.run(['/bin/sh', '-ec', body], env=dict(os.environ, new=t, BB=str(bb)), capture_output=True)
            self.assertEqual(3, r.returncode)
            self.assertIn(b'cannot list APK', r.stderr)


class Selection(unittest.TestCase):
    """Never a refusal: every case exits 0 and leaves no copy and no active marker."""

    def run_script(self, mode, guards=COLOROS, packages='', env=None, pm_out=''):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        stage = Path(t.name) / 'stage'; (stage / 'data/system').mkdir(parents=True)
        (stage / 'guards.txt').write_text(guards)
        (stage / 'data/system/packages.list').write_text(packages)
        (stage / 'fold8_google/GmsCore').mkdir(parents=True)
        tools = Path(t.name) / 'tools'; tools.mkdir()
        (tools / 'pm').write_text('#!/bin/sh\nprintf "%s" "$PM_OUT"\n'); (tools / 'pm').chmod(0o755)
        e = dict(os.environ, STAGE=str(stage), BB='/does/not/exist', PM_OUT=pm_out, PATH=f'{tools}:{os.environ["PATH"]}')
        e.update(env or {})
        r = subprocess.run(['/bin/sh', str(SCRIPT), mode], env=e, capture_output=True)
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertFalse((stage / 'google_apps').exists() and mode == 'snapshot')
        self.assertFalse((stage / 'google_apps/active').exists())
        return stage, r.stdout.decode()

    def test_other_sets_do_nothing(self):
        for mode in ['snapshot', 'prepare']:
            stage, out = self.run_script(mode, guards=GUARDS + '0' * 64 + '  services_patched.jar\n')
            self.assertEqual('', out)
            self.assertTrue((stage / 'fold8_google').exists())

    def test_hidden_google_services_do_nothing(self):
        for mode in ['snapshot', 'prepare']:
            stage, out = self.run_script(mode, env={'ONEOS_GUEST_HIDE_GMS': '1'})
            self.assertEqual('', out)

    def test_missing_guard_skips(self):
        stage, out = self.run_script('snapshot', guards='# older storage guards only\n' + '0' * 64 + '  oplus-services_patched.jar\n')
        self.assertIn('lacks the gatekeeper guard', out)
        self.assertFalse((stage / 'fold8_google').exists())

    def test_old_app_ids_skip(self):
        stage, out = self.run_script('snapshot', packages='com.oplus.launcher 10123 0 /data/user/0/com.oplus.launcher\n')
        self.assertIn('app ids 10000-14999', out)

    def test_unexpected_or_missing_apk_skips(self):
        stage, out = self.run_script('snapshot', pm_out='')
        self.assertIn('com.google.android.gms is not installed in One UI', out)
        stage, out = self.run_script('snapshot', pm_out='package:/data/local/tmp/base.apk\n')
        self.assertIn('unexpected APK path /data/local/tmp/base.apk', out)

    def test_prepare_without_a_checked_copy_adds_nothing(self):
        stage, out = self.run_script('prepare')
        self.assertIn('no copy from One UI', out)



class RemoveInstalled(unittest.TestCase):
    """Only the package's APK folders in the guest's /data/app go; nothing else."""
    FUNC = SOURCE[SOURCE.index('remove_installed() {'):SOURCE.index('case "$1" in')]

    def test_only_the_packages_apk_folders_go(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t); stage = root / 'stage'; app = stage / 'data/app'
            gms = app / '~~abc' / 'com.google.android.gms-xyz'; gms.mkdir(parents=True); (gms / 'base.apk').write_bytes(b'apk')
            old = app / 'com.google.android.gms-1'; old.mkdir(parents=True); (old / 'base.apk').write_bytes(b'apk')
            other = app / '~~def' / 'com.android.vending-1'; other.mkdir(parents=True); (other / 'base.apk').write_bytes(b'apk')
            near = app / '~~ghi' / 'com.google.android.gmsx-1'; near.mkdir(parents=True)
            data = stage / 'data/data/com.google.android.gms'; data.mkdir(parents=True); (data / 'keep').write_bytes(b'data')
            outside = root / 'host/app/~~h/com.google.android.gms-host'; outside.mkdir(parents=True); (outside / 'base.apk').write_bytes(b'host')
            (app / '~~link').symlink_to(root / 'host/app/~~h')
            r = subprocess.run(['/bin/sh', '-ec', 'say() { echo "$*"; };\n' + self.FUNC + 'remove_installed com.google.android.gms'],
                               env=dict(os.environ, STAGE=str(stage)), capture_output=True, text=True)
            self.assertEqual(0, r.returncode, r.stderr)
            self.assertFalse(gms.exists()); self.assertFalse((app / '~~abc').exists()); self.assertFalse(old.exists())
            self.assertTrue(other.exists()); self.assertTrue(near.exists()); self.assertTrue((data / 'keep').exists())
            self.assertTrue((outside / 'base.apk').exists()); self.assertTrue(app.is_dir())
            self.assertEqual(2, r.stdout.count('removed the guest'))

    def test_no_app_folder_is_fine(self):
        with tempfile.TemporaryDirectory() as t:
            r = subprocess.run(['/bin/sh', '-ec', 'say() { echo "$*"; };\n' + self.FUNC + 'remove_installed com.google.android.gms'],
                               env=dict(os.environ, STAGE=t), capture_output=True, text=True)
            self.assertEqual(0, r.returncode, r.stderr)
            self.assertEqual('', r.stdout)


if __name__ == '__main__': unittest.main()
