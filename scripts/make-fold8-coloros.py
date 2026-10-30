#!/usr/bin/env python3
"""Build the Fold8-only Find N6 package set; no OEM binaries are checked in.

Supply the pinned N6 baseline, original SystemUI and the three
unmodified APKs extracted from PLP120_17.0.0.109(CN01). See docs/fold8-coloros.md.
"""
import argparse
import copy
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
ORIGINAL_UI = 'e6bf0e49649dc82117e7b9584c13dbcf737183d17c461cd6edcedcc127165f7e'
DONORS = {
    'Aod.apk': ('Fold8Aod.apk', '87bfba25e06a5081f5feef73aef15a90dbc9b9f39b1fe756c68fd9975ac38638'),
    'UMS.apk': ('Fold8UMS.apk', '511af17427dad4f204a7317511957027d4230ba86c178e0b5645cfb42e0e06ca'),
    'Instant.apk': ('Fold8Instant.apk', '712d7a85c8b047aef1de4d8db6d227b4b5ebe7806973fd795b532de032ef77fa'),
}


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def repack(original, rebuilt, output, zipalign, geometry_dex):
    """Replace only touched dex entries; leave OEM resources and signer identity.

    The retained signer block supplies system-partition certificate metadata;
    its content digest is NOT valid for changed code. This is a root-only
    system overlay, never a normally installable or OEM-signed APK.
    """
    dex = {'classes.dex', 'classes2.dex', 'classes3.dex', 'classes4.dex', 'classes7.dex'}
    rawzip, aligned = output.with_suffix('.zip'), output.with_suffix('.aligned')
    with original.open('rb') as raw, zipfile.ZipFile(original) as src, zipfile.ZipFile(rebuilt) as new, zipfile.ZipFile(rawzip, 'w') as dst:
        for info in src.infolist():
            if info.filename in dex:
                # Keep timestamps deterministic across builds.
                entry = zipfile.ZipInfo(info.filename, info.date_time)
                dst.writestr(entry, new.read(info.filename), compress_type=zipfile.ZIP_STORED)
                continue
            raw.seek(info.header_offset)
            header = raw.read(30)
            assert header[:4] == b'PK\x03\x04'
            nl, el = struct.unpack_from('<HH', header, 26)
            body = raw.read(nl + el + info.compress_size)
            desc = b''
            if info.flag_bits & 8:
                desc = raw.read(4)
                desc += raw.read(12 if desc == b'PK\x07\x08' else 8)
            entry = copy.copy(info)
            entry.header_offset = dst.fp.tell()
            dst.fp.write(header + body + desc)
            dst.filelist.append(entry); dst.NameToInfo[entry.filename] = entry
            dst.start_dir = dst.fp.tell(); dst._didModify = True
        assert 'classes10.dex' not in src.namelist()
        entry = zipfile.ZipInfo('classes10.dex', src.getinfo('classes7.dex').date_time)
        dst.writestr(entry, geometry_dex.read_bytes(), compress_type=zipfile.ZIP_STORED)
    run(zipalign, '-f', '-P', '16', '4', rawzip, aligned)
    rawzip.unlink()
    a = original.read_bytes()
    e = a.rfind(b'PK\x05\x06'); cd = struct.unpack_from('<I', a, e + 16)[0]
    if a[cd - 16:cd] != b'APK Sig Block 42':
        raise ValueError('Original SystemUI has no APK signer block')
    size = struct.unpack_from('<Q', a, cd - 24)[0]
    block = a[cd - size - 8:cd]
    if struct.unpack_from('<Q', block)[0] != size:
        raise ValueError('Malformed APK signer block')
    b = aligned.read_bytes()
    aligned.unlink()
    e = b.rfind(b'PK\x05\x06'); cd = struct.unpack_from('<I', b, e + 16)[0]
    result = bytearray(b[:cd] + block + b[cd:])
    struct.pack_into('<I', result, e + len(block) + 16, cd + len(block))
    output.write_bytes(result)
    with zipfile.ZipFile(original) as src, zipfile.ZipFile(output) as dst:
        assert src.namelist() + ['classes10.dex'] == dst.namelist()
        assert dst.testzip() is None
        for n in src.namelist():
            if n not in dex:
                assert src.read(n) == dst.read(n), n


GUARDS = ('storage', 'installd', 'power', 'sysrq', 'weaver', 'biometric', 'gatekeeper', 'pdb', 'apexd', 'appid15000', 'nousers')


def check_guards(out):
    """The base set (OneOS's own N6 set, r50 and later) already carries every guard.

    Ported from PR #1: its 0.4.7 base needed six patchers applied again; ours has
    them since the 2026-10-25 rebuild, so they are checked, not re-applied.
    """
    header = (out / 'guards.txt').read_text().splitlines()[0]
    missing = [g for g in GUARDS if g not in header]
    if missing:
        raise ValueError(f'base set lacks guards: {missing}')
    for line in (out / 'guards.txt').read_text().splitlines():
        if line and not line.startswith('#'):
            pin, name = line.split()
            if sha(out / name) != pin:
                raise ValueError(f'{name} is not the jar guards.txt vouches for')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', type=Path, required=True)
    p.add_argument('--systemui', type=Path, required=True)
    p.add_argument('--donor', type=Path, required=True)
    p.add_argument('--out', type=Path, default=ROOT / 'out/overlays_n6_fold8')
    p.add_argument('--write-pins', action='store_true',
                   help='write app-android/packages/n6-f8.sha256 from this build (an explicit, reviewed pin update)')
    a = p.parse_args()
    if sha(a.systemui) != ORIGINAL_UI:
        p.error('SystemUI is not the supported Find N6 build')
    for name, (_, pin) in DONORS.items():
        if sha(a.donor / name) != pin:
            p.error(f'{name} is not the exact stock donor APK')
    sdk = Path(os.environ.get('ANDROID_HOME', '/opt/android-sdk'))
    bt = sdk / 'build-tools' / os.environ.get('ONEOS_BUILD_TOOLS', '36.1.0')
    android = sdk / 'platforms' / os.environ.get('ONEOS_ANDROID_PLATFORM', 'android-37') / 'android.jar'
    apktool = os.environ.get('APKTOOL', 'apktool')
    def apk(*args):
        run(*(['java', '-jar', apktool] if apktool.endswith('.jar') else [apktool]), *args)
    # Publish only after all checks/builds succeed.
    a.out.parent.mkdir(parents=True, exist_ok=True)
    if a.out.exists():
        p.error(f'{a.out} exists; choose a new output directory')
    with tempfile.TemporaryDirectory(dir=a.out.parent, prefix='.fold8-') as tmp:
        w = Path(tmp); out = w / 'set'; out.mkdir()
        for line in (ROOT / 'app-android/packages/n6-f8u.sha256').read_text().splitlines():
            if not line or line.startswith('#'):
                continue
            pin, name = line.split()
            source = a.base / name
            if sha(source) != pin:
                p.error(f'{source} differs from the existing N6 set')
            shutil.copyfile(source, out / name)
        check_guards(out)
        geometry_classes = w / 'geometry-classes'; geometry_classes.mkdir()
        geometry_dex = w / 'geometry-dex'; geometry_dex.mkdir()
        run('javac', '--release', '8', '-classpath', android, '-d', geometry_classes,
            ROOT / 'switcher/patches/fold8-coloros/Fold8RevealGeometry.java')
        run(bt / 'd8', '--min-api', '31', '--lib', android, '--output', geometry_dex,
            *sorted(geometry_classes.rglob('*.class')))
        # Decode only the dex entries we replace. On macOS the complete
        # 73k-class tree consumes over a GiB; other dex entries are copied
        # directly from the original APK by repack(), never rebuilt.
        filtered = w / 'systemui-input.apk'
        touched = {'classes.dex', 'classes2.dex', 'classes3.dex', 'classes4.dex', 'classes7.dex'}
        with zipfile.ZipFile(a.systemui) as src, zipfile.ZipFile(filtered, 'w') as dst:
            for info in src.infolist():
                if info.filename.startswith('classes') and info.filename.endswith('.dex') and info.filename not in touched:
                    continue
                dst.writestr(info, src.read(info.filename))
        decoded = w / 'systemui'
        apk('d', '-f', '-r', '-o', decoded, filtered)
        filtered.unlink()
        run('python3', '-I', ROOT / 'switcher/patches/fold8_coloros_systemui.py', decoded)
        rebuilt = w / 'rebuilt.apk'
        apk('b', '-q', '-o', rebuilt, decoded)
        shutil.rmtree(decoded)
        repack(a.systemui, rebuilt, out / 'Fold8SystemUI.apk', bt / 'zipalign', geometry_dex / 'classes.dex')
        rebuilt.unlink()
        run('python3', '-I', ROOT / 'scripts/check-dex.py', out / 'Fold8SystemUI.apk')
        classes = w / 'classes'; classes.mkdir()
        run('javac', '--release', '8', '-classpath', android, '-d', classes,
            ROOT / 'switcher/patches/fold8-coloros/OneOSAngleRelay.java')
        dexdir = w / 'dex'; dexdir.mkdir()
        run(bt / 'd8', '--min-api', '28', '--lib', android, '--output', dexdir, *sorted(classes.glob('*.class')))
        shutil.copyfile(dexdir / 'classes.dex', out / 'Fold8AngleRelay.dex')
        for name, (dest, _) in DONORS.items():
            shutil.copyfile(a.donor / name, out / dest)
        pins = ROOT / 'app-android/packages/n6-f8.sha256'
        if a.write_pins:
            omitted = {'tethering_payload.img'}
            names = sorted((f.name for f in out.iterdir() if f.name not in omitted), key=lambda n: n.encode())
            pins.write_text(
                '# OneOS package set n6-f8: sha256sum of out/overlays_n6_fold8 '
                '(scripts/make-fold8-coloros.py), minus tethering_payload.img.\n'
                f'# app/build.gradle.kts packs exactly these files into the APK and fails the build when it differs.\n'
                + ''.join(f'{sha(out / n)}  {n}\n' for n in names)
            )
        expected = pins.read_text()
        have = {n: h for h, n in (line.split() for line in expected.splitlines() if line and not line.startswith('#'))}
        for f in out.iterdir():
            if have.get(f.name) != sha(f):
                p.error(f'{f.name} differs from n6-f8.sha256; review the rebuild and update its pin explicitly')
        for f in list(out.iterdir()):
            if f.name not in have and f.name == 'tethering_payload.img':
                f.unlink()
        if set(have) != {f.name for f in out.iterdir()}:
            p.error('Incomplete Fold8 package set')
        out.rename(a.out)
    print(f'Built and verified {a.out}')


if __name__ == '__main__':
    main()
