"""Stub out a method in a dex/jar by making its first instruction a return.

Used for HyperOS framework hooks that call Xiaomi vendor services which do not
exist (or reject the caller) on the host phone, e.g.
MiuiNetworkManagementService.setOemNetd -> Samsung netd's IOemNetd throws
SecurityException and takes NetworkManagementService (and everything after
it) down with it.

  python dexpatch.py IN.jar OUT.jar 'Lcom/foo/Bar;' methodName [methodName ...]

Every overload of each named method is patched: void methods get return-void,
int/boolean/etc. return 0, object returns null. The rest of the code item is
left in place (unreachable code is fine for the verifier), the dex checksum and
signature are recomputed, and the jar is rewritten with its original entry
compression.

Zipalign the result (zipalign -f -p 4): ART only maps 4-byte aligned dex
entries directly.
"""
import hashlib
import os
import struct
import sys
import zipfile
import zlib


def uleb(d, off):
    result = shift = 0
    while True:
        b = d[off]
        off += 1
        result |= (b & 0x7F) << shift
        if b < 0x80:
            return result, off
        shift += 7


def patch_dex(dex, class_desc, names):
    d = bytearray(dex)
    (string_ids_size, string_ids_off, type_ids_size, type_ids_off,
     proto_ids_size, proto_ids_off, _fs, _fo,
     method_ids_size, method_ids_off, class_defs_size, class_defs_off) = \
        struct.unpack_from("<12I", d, 0x38)

    def string(i):
        off = struct.unpack_from("<I", d, string_ids_off + 4 * i)[0]
        _, off = uleb(d, off)
        end = d.index(0, off)
        return d[off:end].decode("utf-8", "replace")

    def type_name(i):
        return string(struct.unpack_from("<I", d, type_ids_off + 4 * i)[0])

    target_type = None
    for i in range(type_ids_size):
        if type_name(i) == class_desc:
            target_type = i
            break
    if target_type is None:
        raise SystemExit("class not found: " + class_desc)

    patched = []
    defined = False
    for c in range(class_defs_size):
        base = class_defs_off + 32 * c
        if struct.unpack_from("<I", d, base)[0] != target_type:
            continue
        defined = True
        class_data_off = struct.unpack_from("<I", d, base + 24)[0]
        off = class_data_off
        sf, off = uleb(d, off)
        inf, off = uleb(d, off)
        dm, off = uleb(d, off)
        vm, off = uleb(d, off)
        for _ in range(sf + inf):
            _, off = uleb(d, off)
            _, off = uleb(d, off)
        for group in (dm, vm):
            midx = 0
            for _ in range(group):
                diff, off = uleb(d, off)
                midx += diff
                _flags, off = uleb(d, off)
                code_off, off = uleb(d, off)
                _cls, proto, name_idx = struct.unpack_from("<HHI", d, method_ids_off + 8 * midx)
                name = string(name_idx)
                if name not in names or code_off == 0:
                    continue
                ret = type_name(struct.unpack_from("<I", d, proto_ids_off + 12 * proto + 4)[0])
                regs, _ins, _outs, _tries, _dbg, insns = struct.unpack_from("<HHHHII", d, code_off)
                at = code_off + 16
                # Every code unit must stay a valid instruction: ART statically
                # verifies dead code too, so overwriting only the first unit of a
                # multi-unit instruction leaves garbage ("register index out of
                # range"). Fill the whole insns array with one-unit returns after
                # the stub. tries_size is left alone: the try/handler data still
                # follows insns, and zeroing it makes the dex verifier parse that
                # data as the next code item ("outs_size > registers_size") and
                # reject the whole jar. With one-unit returns everywhere, every
                # handler address still lands on a valid instruction.
                if ret == "V":
                    head, fill = [], 0x000E                 # return-void
                elif ret in ("J", "D"):
                    head, fill = [0x0016, 0x0000], 0x0010  # const-wide/16 v0,0 ; return-wide v0
                elif ret.startswith("L") or ret.startswith("["):
                    head, fill = [0x0012], 0x0011           # const/4 v0,0 ; return-object v0
                else:
                    head, fill = [0x0012], 0x000F           # const/4 v0,0 ; return v0
                if insns < len(head) + 1 or (ret != "V" and regs < (2 if ret in ("J", "D") else 1)):
                    raise SystemExit("method too small to stub: " + name)
                units = head + [fill] * (insns - len(head))
                d[at:at + 2 * insns] = struct.pack("<%dH" % insns, *units)
                patched.append("%s %s -> %d units, first %s (code @0x%x)"
                               % (name, ret, insns, " ".join("%04x" % u for u in units[:3]), code_off))
    if not defined:
        # Only referenced here (multidex): let main() try the next dex.
        raise SystemExit("class not found: " + class_desc)
    if not patched:
        raise SystemExit("no matching methods with code in " + class_desc)

    d[12:32] = hashlib.sha1(bytes(d[32:])).digest()
    struct.pack_into("<I", d, 8, zlib.adler32(bytes(d[12:])) & 0xFFFFFFFF)
    return bytes(d), patched


def main():
    src, dst, class_desc = sys.argv[1:4]
    names = set(sys.argv[4:])
    zin = zipfile.ZipFile(src)
    found = False
    # Write to a temp file and rename only on success, so a failed run never
    # leaves a plausible-looking (but unpatched or truncated) jar at dst.
    tmp = dst + ".tmp"
    try:
        with zipfile.ZipFile(tmp, "w") as zout:
            for info in zin.infolist():
                data = zin.read(info.filename)
                if info.filename.startswith("classes") and info.filename.endswith(".dex") and not found:
                    try:
                        data, patched = patch_dex(data, class_desc, names)
                        found = True
                        for p in patched:
                            print(info.filename + ": " + p)
                    except SystemExit as e:
                        if "class not found" not in str(e):
                            raise
                zout.writestr(info, data, compress_type=info.compress_type)
        if not found:
            raise SystemExit("class not found in any dex: " + class_desc)
        os.replace(tmp, dst)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


if __name__ == "__main__":
    main()
