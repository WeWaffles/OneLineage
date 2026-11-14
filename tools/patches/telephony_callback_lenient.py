"""Let Samsung's IMS app register telephony callbacks Lineage does not know.

Samsung's IMS app (com.sec.imsservice, see docs/SAMSUNG_IMS.md) registers a
TelephonyCallback in LogCatcherEventManager that implements only Samsung's own
listener interfaces. Lineage's TelephonyRegistryManager.registerTelephonyCallback
finds no AOSP listener on it and throws IllegalArgumentException("callback must
implement at least one listener"), which kills the app in Application.onCreate
before IMS starts. This patch turns that throw into a plain return: a callback
with nothing Lineage can deliver is simply not registered.

It is a byte patch of framework.jar's dex, not a smali round trip: baksmali
2.5.x cannot read every class of an Android 16 framework dex (it skips
android.window.TaskSnapshot), so reassembling would drop classes. The patch
finds the message's string id, then the only

    return-void
    new-instance vX, Ljava/lang/IllegalArgumentException;
    const-string/jumbo vY, "registerTelephonyCallback(): callback must ..."

sequence, and replaces the 4-byte new-instance with return-void + nop. The
throw after it becomes unreachable (ART only verifies reachable code). Then it
recomputes the dex SHA-1 signature and Adler-32 checksum and rewrites the jar
entry with its original compression. Refuses unless it matches exactly once.

Usage: telephony_callback_lenient.py <in framework.jar> <out framework.jar>
"""
import hashlib
import struct
import sys
import zipfile
import zlib

MSG = b"registerTelephonyCallback(): callback must implement at least one listener."
IAE = b"Ljava/lang/IllegalArgumentException;"


def uleb(data, pos):
    val = shift = 0
    while True:
        b = data[pos]
        pos += 1
        val |= (b & 0x7F) << shift
        if b < 0x80:
            return val, pos
        shift += 7


def string_index(dex, want):
    size, off = struct.unpack_from("<II", dex, 0x38)
    for i in range(size):
        (data_off,) = struct.unpack_from("<I", dex, off + 4 * i)
        _, p = uleb(dex, data_off)
        end = dex.index(b"\0", p)
        if dex[p:end] == want:
            return i
    return None


def type_index(dex, string_idx):
    size, off = struct.unpack_from("<II", dex, 0x40)
    for i in range(size):
        if struct.unpack_from("<I", dex, off + 4 * i)[0] == string_idx:
            return i
    return None


def patch_dex(dex):
    s_msg = string_index(dex, MSG)
    if s_msg is None:
        return None
    s_iae = string_index(dex, IAE)
    t_iae = type_index(dex, s_iae) if s_iae is not None else None
    if t_iae is None or t_iae > 0xFFFF:
        sys.exit("IllegalArgumentException type not found")
    # return-void; new-instance vX, type@t_iae; const-string/jumbo vY, string@s_msg
    hits = []
    needle_type = struct.pack("<H", t_iae)
    needle_str = struct.pack("<I", s_msg)
    start = 0
    while True:
        i = dex.find(needle_str, start)
        if i < 0:
            break
        start = i + 1
        cs = i - 2  # const-string/jumbo: 1b vY lo hi
        ni = cs - 4  # new-instance: 22 vX type
        if cs < 6 or dex[cs] != 0x1B or dex[ni] != 0x22 or dex[ni + 2:ni + 4] != needle_type:
            continue
        if dex[ni - 2:ni] != b"\x0e\x00":
            continue
        hits.append(ni)
    if len(hits) != 1:
        sys.exit(f"expected the throw sequence once, found {len(hits)}")
    out = bytearray(dex)
    out[hits[0]:hits[0] + 4] = b"\x0e\x00\x00\x00"  # return-void; nop
    out[12:32] = hashlib.sha1(bytes(out[32:])).digest()
    struct.pack_into("<I", out, 8, zlib.adler32(bytes(out[12:])) & 0xFFFFFFFF)
    print(f"patched at dex offset {hits[0]:#x}", file=sys.stderr)
    return bytes(out)


def main(src, dst):
    with zipfile.ZipFile(src) as zin:
        infos = zin.infolist()
        patched = {}
        for info in infos:
            if info.filename.startswith("classes") and info.filename.endswith(".dex"):
                res = patch_dex(zin.read(info.filename))
                if res is not None:
                    patched[info.filename] = res
        if len(patched) != 1:
            sys.exit(f"expected the message in one dex, found {len(patched)}")
        with zipfile.ZipFile(dst, "w") as zout:
            for info in infos:
                data = patched.get(info.filename) or zin.read(info.filename)
                zout.writestr(info, data, compress_type=info.compress_type)
    print(f"registerTelephonyCallback made lenient in {next(iter(patched))}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
