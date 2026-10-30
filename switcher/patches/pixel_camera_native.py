"""A guest's native camera client library with One UI's transaction codes.

The native twin of pixel_camera_abi.py (docs/pixel-guest.md, "What differs"):
the guest's legacy camera API (BpCameraService::connect) and the NDK camera2
path are marshalled by /system/lib64/libcamera_client.so, not by framework.jar.
It carries the same differences, which an aarch64 build exposes as immediates:

  - BpCameraService and BpCameraDeviceUser pass the transaction code to
    IBinder::transact as `mov w1, #N` (the last such mov in each Bp method).
    Each becomes One UI's number from the host table (host_camera.txt, the
    same file the Java patcher reads; Bp<Interface> = android.hardware.I<...>).
    A guest-only method (ColorOS's notifySmartWindowChange and
    notifyDisplayRotationChange, both void; 0.4.31: HyperOS's addFaceListener
    and removeFaceListener, which return a result) goes to UNUSED_CODE, which
    One UI answers with "unknown transaction". The C++ Bp code checks that
    status and returns the error without reading a reply (unlike Java's
    Proxy, where pixel_camera_abi.py throws instead); any other one stops
    the build.
  - BnCameraServiceListener / BnCameraDeviceCallbacks::onTransact: a case whose
    code is another method on the host (the Pixel 9 Pro XL's
    onStatusChangedBatched at 9, One UI's onCameraDeviceStateChanged) is
    skipped, so the host's call returns "unknown transaction" and is not
    misparsed. `cmp w1, #N; b.ne X` becomes `b X`, `cmp; b.eq` a nop.
  - libcameracompatbilityinfo.so (the native CameraCompatibilityInfo): a
    build that has shouldOverrideLensFacingFrontToBack (the Pixel 9 Pro XL)
    writes and reads a sixth field, which One UI reads as the next parcelable's
    null marker. The last write and the last read (the call after loading that
    field's offset) become nops.
Every pattern must match exactly once or the build stops (fail closed). An
already patched library gives "unchanged".

Usage: pixel_camera_native.py <host_camera.txt> <in.so> <out.so>
         patches libcamera_client.so or libcameracompatbilityinfo.so
         (told apart by its symbols); writes <out.so> only when it changed
         and prints "changed" on stdout.
       pixel_camera_native.py --dump <lib.so>
         prints "<class> <method> <code>" for every Bp method of the library,
         to diff a host's libcamera_client.so against the guest's.
No dependencies: the ELF symbol table and the encodings are read here.
"""
import re
import struct
import sys

UNUSED_CODE = 200
GUEST_ONLY_VOID = {"notifySmartWindowChange", "notifyDisplayRotationChange"}
# Guest-only methods with a result whose Bp returns transact's error status as it is (HyperOS).
GUEST_ONLY_STATUS = {"addFaceListener", "removeFaceListener"}
NOP = 0xD503201F
# (interface, mangled namespace, Bp class, Bn class)
AIDL = {
    "android.hardware.ICameraService": ("7android8hardware", "BpCameraService"),
    "android.hardware.camera2.ICameraDeviceUser": ("7android8hardware7camera2", "BpCameraDeviceUser"),
}
CALLBACKS = {
    "android.hardware.ICameraServiceListener": ("7android8hardware", "BpCameraServiceListener", "BnCameraServiceListener"),
    "android.hardware.camera2.ICameraDeviceCallbacks": ("7android8hardware7camera2", "BpCameraDeviceCallbacks", "BnCameraDeviceCallbacks"),
}


def die(msg):
    sys.exit(f"pixel_camera_native: {msg}")


def read_table(path):
    out = {}
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#"):
            iface, name, code, _ = line.split(None, 3)
            out.setdefault(iface, {})[name] = int(code)
    return out


class Elf:
    def __init__(self, path):
        self.buf = bytearray(open(path, "rb").read())
        b = self.buf
        if b[:4] != b"\x7fELF" or b[4] != 2 or b[5] != 1 or struct.unpack_from("<H", b, 0x12)[0] != 183:
            die(f"{path}: not an aarch64 ELF64")
        phoff, shoff = struct.unpack_from("<QQ", b, 0x20)
        phentsize, phnum, shentsize, shnum = struct.unpack_from("<HHHH", b, 0x36)
        self.loads = []
        for i in range(phnum):
            t, _, off, va, _, filesz, _, _ = struct.unpack_from("<IIQQQQQQ", b, phoff + i * phentsize)
            if t == 1:
                self.loads.append((va, off, filesz))
        secs = [struct.unpack_from("<IIQQQQIIQQ", b, shoff + i * shentsize) for i in range(shnum)]
        self.funcs = {}
        for s in secs:
            if s[1] != 11:  # SHT_DYNSYM
                continue
            stroff = secs[s[6]][4]
            for j in range(s[5] // 24):
                nm, info, _, shndx, val, size = struct.unpack_from("<IBBHQQ", b, s[4] + j * 24)
                if shndx and size and (info & 0xF) == 2:
                    e = b.index(b"\0", stroff + nm)
                    self.funcs.setdefault(bytes(b[stroff + nm:e]).decode(), []).append((val, size))

    def off(self, va):
        for v, o, n in self.loads:
            if v <= va < v + n:
                return va - v + o
        die(f"address {va:#x} is in no segment")

    def words(self, va, size):
        o = self.off(va)
        return [(va + 4 * i, o + 4 * i, struct.unpack_from("<I", self.buf, o + 4 * i)[0]) for i in range(size // 4)]

    def put(self, fileoff, word):
        struct.pack_into("<I", self.buf, fileoff, word)

    def find(self, rx):
        hits = [(n, v) for n, v in self.funcs.items() if re.match(rx, n)]
        return hits


def is_movz_w1(w):
    return (w & 0xFFE0001F) == 0x52800001


def bp_methods(elf, ns, cls):
    """{method: (file offset of its transact mov, code)} of a Bp class."""
    out = {}
    for name, fs in elf.find(rf"^_ZN{ns}{len(cls)}{cls}\d+\w+E"):
        m = re.match(rf"^_ZN{ns}{len(cls)}{cls}(\d+)(\w+)", name)
        n = int(m.group(1))
        meth = m.group(2)[:n]
        if m.group(2)[n:n + 1] != "E" or meth in (cls, "") or meth[0] in "CD" and meth[1:2].isdigit():
            continue
        if len(fs) != 1:
            die(f"{cls}::{meth}: {len(fs)} definitions")
        movs = [(o, w) for _, o, w in elf.words(*fs[0]) if is_movz_w1(w)]
        if not movs:
            die(f"{cls}::{meth}: no mov w1 before transact")
        o, w = movs[-1]
        if meth in out:
            die(f"{cls}::{meth}: overloaded, not handled")
        out[meth] = (o, (w >> 5) & 0xFFFF)
    if not out:
        die(f"no {cls} methods (stripped or another library)")
    codes = [c for _, c in out.values()]
    if len(set(codes)) != len(codes):
        die(f"{cls}: two methods with one code")
    return out


def patch_bp(elf, host, changed):
    n = 0
    for iface, (ns, cls) in AIDL.items():
        guest = bp_methods(elf, ns, cls)
        for meth, (o, gcode) in sorted(guest.items()):
            if meth in host[iface]:
                hcode = host[iface][meth]
            elif meth in GUEST_ONLY_VOID or meth in GUEST_ONLY_STATUS:
                hcode = UNUSED_CODE
            else:
                die(f"{iface}.{meth} ({gcode}) is not in the host table: the host would take it for another method")
            if hcode == gcode:
                continue
            elf.put(o, 0x52800001 | (hcode << 5))
            changed.append(f"{cls}::{meth}: {gcode} -> {hcode}")
            n += 1
    return n


def patch_bn(elf, host, changed):
    n = 0
    for iface, (ns, bp, bn) in CALLBACKS.items():
        guest = {m: c for m, (_, c) in bp_methods(elf, ns, bp).items()}
        by_host = {c: m for m, c in host[iface].items()}
        drop = {c: m for m, c in guest.items() if c in by_host and by_host[c] != m}
        if not drop:
            continue
        fs = elf.find(rf"^_ZN{ns}{len(bn)}{bn}10onTransactE")
        if len(fs) != 1 or len(fs[0][1]) != 1:
            die(f"{bn}::onTransact: {len(fs)} definitions (one expected)")
        ws = elf.words(*fs[0][1][0])
        for c, m in sorted(drop.items()):
            hits = [i for i, (_, _, w) in enumerate(ws[:-1]) if (w & ~(0xFFF << 10)) == 0x7100003F and (w >> 10) & 0xFFF == c]
            if len(hits) != 1:
                die(f"{bn}::onTransact: `cmp w1, #{c}` found {len(hits)} times (one expected; a jump table?)")
            _, _, cw = ws[hits[0]]
            va, o, bw = ws[hits[0] + 1]
            if (bw & 0xFC000000) == 0x14000000:
                continue  # already patched
            if (bw & 0xFF000010) != 0x54000000 or (bw & 0xF) not in (0, 1):
                die(f"{bn}::onTransact: `cmp w1, #{c}` is not followed by b.eq/b.ne ({bw:#x})")
            if bw & 0xF:  # b.ne default: always default
                imm = (bw >> 5) & 0x7FFFF
                imm -= 1 << 19 if imm >> 18 else 0
                elf.put(o, 0x14000000 | (imm & 0x3FFFFFF))
            else:  # b.eq case: never taken
                elf.put(o, NOP)
            changed.append(f"{bn}::onTransact: code {c} ({m}) ignored; the host's {by_host[c]}")
            n += 1
    return n


def patch_compat(elf, changed):
    gets = elf.find(r"^_ZNK7android7content3res23CameraCompatibilityInfo35shouldOverrideLensFacingFrontToBackEv$")
    if not gets:
        return 0
    off = None
    for _, _, w in elf.words(*gets[0][1][0]):
        if (w & 0xFFC003FF) == 0x39400000:  # ldrb w0, [x0, #imm]
            off = (w >> 10) & 0xFFF
    if off is None:
        die("shouldOverrideLensFacingFrontToBack: no ldrb")
    n = 0
    for rx, kind in ((r"^_ZNK7android7content3res23CameraCompatibilityInfo13writeToParcelEPNS_6ParcelE$", "write"),
                     (r"^_ZN7android7content3res23CameraCompatibilityInfo14readFromParcelEPKNS_6ParcelE$", "read")):
        fs = elf.find(rx)
        if len(fs) != 1:
            die(f"CameraCompatibilityInfo::{kind}ToParcel: {len(fs)} definitions")
        ws = elf.words(*fs[0][1][0])
        bls = [i for i, (_, _, w) in enumerate(ws) if (w & 0xFC000000) == 0x94000000]
        if kind == "write":
            at = [i for i, (_, _, w) in enumerate(ws) if (w & 0xFFC0001F) == 0x39400001 and (w >> 10) & 0xFFF == off]
        else:
            at = [i for i, (_, _, w) in enumerate(ws) if (w & 0xFFC0001F) == 0x91000001 and (w >> 10) & 0xFFF == off]
        if len(at) != 1:
            die(f"CameraCompatibilityInfo::{kind}FromParcel: the field at +{off:#x} is loaded {len(at)} times (one expected)")
        if any(ws[i][2] == NOP for i in range(at[0] + 1, min(at[0] + 4, len(ws)))) and not any(0 < i - at[0] <= 4 for i in bls):
            continue  # already patched
        nxt = [i for i in bls if i > at[0]]
        if not nxt or nxt[0] - at[0] > 4 or nxt[0] != bls[-1]:
            die(f"CameraCompatibilityInfo: the sixth field's {kind} is not the last call")
        elf.put(ws[nxt[0]][1], NOP)
        changed.append(f"CameraCompatibilityInfo: sixth field (+{off:#x}) not {kind}n"
                       .replace("writen", "written").replace("readn", "read"))
        n += 1
    return n


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--dump":
        elf = Elf(sys.argv[2])
        for iface, (ns, cls) in list(AIDL.items()) + [(i, v[:2]) for i, v in CALLBACKS.items()]:
            for m, (_, c) in sorted(bp_methods(elf, ns, cls).items(), key=lambda x: x[1][1]):
                print(cls, m, c)
        return
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    host = read_table(sys.argv[1])
    elf = Elf(sys.argv[2])
    changed = []
    if elf.find(r"^_ZN7android8hardware15BpCameraService"):
        n = patch_bp(elf, host, changed) + patch_bn(elf, host, changed)
    elif elf.find(r"^_ZNK?7android7content3res23CameraCompatibilityInfo"):
        n = patch_compat(elf, changed)
    else:
        die("neither libcamera_client.so nor libcameracompatbilityinfo.so")
    for c in changed:
        print(f"pixel_camera_native: {c}", file=sys.stderr)
    if not n:
        print("pixel_camera_native: unchanged", file=sys.stderr)
        return
    open(sys.argv[3], "wb").write(elf.buf)
    print("changed")


if __name__ == "__main__":
    main()
