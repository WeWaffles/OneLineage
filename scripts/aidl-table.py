#!/usr/bin/env python3
"""Print the binder interfaces of a framework jar as tables: for each AIDL
interface, every method's transaction code and Java signature, from the
interface's Stub (TRANSACTION_* constants) and Stub$Proxy (methods).

Usage: scripts/aidl-table.py <jar or dexdump text> <interface> [<interface> ...]
       interface: a class name such as android.hardware.ICameraService
       A .txt file is read as `dexdump` output already made (on the phone,
       /apex/com.android.art/bin/dexdump: scripts/camera-dump.sh).
Output, one line per method: <interface> <name> <code> <signature>
(the same shape as switcher/patches/host_installd.txt, with the interface
first). Methods the Proxy has but no TRANSACTION_ constant names (getMaxTransactionId,
asBinder, getInterfaceDescriptor, ...) are left out.
Needs dexdump from the Android SDK build-tools ($DEXDUMP or the newest one
under $ANDROID_HOME).
"""
import glob
import os
import re
import subprocess
import sys
import tempfile
import zipfile


def dexdump_path():
    if os.environ.get("DEXDUMP"):
        return os.environ["DEXDUMP"]
    home = os.environ.get("ANDROID_HOME", "/opt/android-sdk")
    found = sorted(glob.glob(os.path.join(home, "build-tools", "*", "dexdump")))
    if not found:
        sys.exit("aidl-table: no dexdump (set DEXDUMP or ANDROID_HOME)")
    return found[-1]


def blocks(out):
    for b in re.split(r"\n(?=Class #\d+)", out):
        m = re.search(r"Class descriptor  : '([^']+)'", b)
        if m:
            yield m.group(1), b


def classes(jar):
    """Yield (descriptor, block text) for every class in every dex of jar."""
    if jar.endswith(".txt"):
        yield from blocks(open(jar, errors="replace").read())
        return
    dd = dexdump_path()
    with zipfile.ZipFile(jar) as z, tempfile.TemporaryDirectory() as tmp:
        for n in sorted(x for x in z.namelist() if re.fullmatch(r"classes\d*\.dex", x)):
            p = z.extract(n, tmp)
            yield from blocks(subprocess.run([dd, p], capture_output=True, text=True, errors="replace").stdout)


def table(jar, names):
    want = {}
    for n in names:
        d = "L" + n.replace(".", "/")
        want[d + "$Stub;"] = (n, "stub")
        want[d + "$Stub$Proxy;"] = (n, "proxy")
    codes, sigs = {}, {}
    for desc, b in classes(jar):
        if desc not in want:
            continue
        n, kind = want[desc]
        if kind == "stub":
            for f, v in re.findall(r"name +: 'TRANSACTION_(\w+)'\n(?: +\w+ +:[^\n]*\n)*? +value +: (\d+)", b):
                codes.setdefault(n, {})[f] = int(v)
        else:
            for f, t in re.findall(r"name +: '(\w+)'\n +type +: '(\([^']*\)[^']*)'", b):
                sigs.setdefault(n, {}).setdefault(f, []).append(t)
    for n in names:
        if n not in codes:
            print(f"# {n}: no Stub in {os.path.basename(jar)}")
            continue
        for f, c in sorted(codes[n].items(), key=lambda kv: kv[1]):
            for t in sigs.get(n, {}).get(f, ["?"]):
                print(f"{n} {f} {c} {t}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    table(sys.argv[1], sys.argv[2:])
