"""Never let the guest write to or wipe the phone's persistent data block (FRP).

The container shares the host's block devices. The persistent data block
partition (ro.frp.pst, e.g. /dev/block/by-name/frp) is One UI's: it holds the
host's factory-reset-protection state and OEM-unlock flag. The guest has its
own system_server, so it also has its own PersistentDataBlockService, and that
service resolves mDataBlockFile from the same ro.frp.pst property and opens the
same real partition. Left alone the guest would write One UI's FRP block
(the OEM-unlock flag in doSetOemUnlockEnabledLocked, the FRP magic/secret in
writeFrpMagicAndDefaultSecret, the digest in computeAndWriteDigestLocked, the
zero-fill in formatPartitionLocked, byte ranges through InternalService.write)
and could wipe it outright (wipe() -> nativeWipe / a TRUNCATE_EXISTING write of
0x19000 zero bytes). That would replace One UI's FRP record with the guest's.
The guest never needs the real partition: its FRP state is part of the staged
tree.

What this changes (reads are left exactly as they are -- readDataBlock,
computeDigestLocked and doGetOemUnlockEnabled read mDataBlockFile through
FileInputStream and are untouched):

1. getBlockOutputChannelIgnoringFrp() is the single writable-open site: every
   write in the class funnels through it (getBlockOutputChannel() delegates to
   it, and InternalService.write / the Stub's digest write reach it through the
   -$$Nest$mgetBlockOutputChannel accessor). It opens
   `new RandomAccessFile(mDataBlockFile, "rw")`. We replace the field load that
   feeds the path with const-string "/dev/null", so the writable channel is a
   handle on /dev/null: writes go nowhere, and the force() that follows each
   of them throws an IOException, which every caller already catches (the
   guest sees the write fail; run-time logs show its Slog.e). The host
   partition is never opened for writing. A Slog.w records the redirect.

2. PersistentDataBlockService$1.wipe() (the IPersistentDataBlockService stub,
   the only caller of nativeWipe) returns at entry with a Slog.w, before the
   native wipe and before the file-backed TRUNCATE_EXISTING path, so the host
   partition is never wiped and the service does not flip itself to unwritable
   (it behaves as a refused/failed wipe). nativeWipe is then unreachable.

Fail closed: if the one write-open site, its "rw" mode, its mDataBlockFile load,
the single wipe() method, or the expectation that nativeWipe is reached only
through wipe() does not hold exactly, the patcher exits non-zero and changes
nothing (a half-patch could leave a real writable handle on the host's FRP).

Works on both smali flavours. Pixel (R8): public final methods, the path in
getBlockOutputChannelIgnoringFrp loaded into p0, wipe() with p registers.
ColorOS (non-R8): private methods with a Throws annotation and .line/.local
debug info, the path loaded into v1. Method headers are matched allowing any
modifier order; the path register is read from the RandomAccessFile <init> call
rather than assumed; the log uses v0/v1 at method entry, both methods having
.locals >= 2, inserted before any parameter is moved and before any try range.

Usage: guest_pdb_readonly.py <smali root dir>
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import re
import sys

CLS = "Lcom/android/server/pdb/PersistentDataBlockService;"
SVC = "PersistentDataBlockService.smali"
STUB = "PersistentDataBlockService$1.smali"
TAG = "PersistentDataBlockService"

CHANNEL_HDR = re.compile(
    r"^\.method (?:private |public |protected |final |static |synchronized )*"
    r"getBlockOutputChannelIgnoringFrp\(\)Ljava/nio/channels/FileChannel;$")
WIPE_HDR = re.compile(
    r"^\.method (?:private |public |protected |final |static |synchronized )*"
    r"wipe\(\)V$")
RAF_INIT = re.compile(
    r"^\s*invoke-direct \{([vp]\d+), ([vp]\d+), ([vp]\d+)\}, "
    r"Ljava/io/RandomAccessFile;-><init>\(Ljava/lang/String;Ljava/lang/String;\)V\s*$")
# "rw"/"rws"/"rwd": any RandomAccessFile mode that permits writing.
RW_MODE = re.compile(r'^\s*const-string(?:/jumbo)? ([vp]\d+), "(rw[sd]?)"\s*$')


def method_bounds(lines, header_re, path):
    heads = [i for i, l in enumerate(lines) if header_re.match(l)]
    if len(heads) != 1:
        sys.exit(f"{path}: {header_re.pattern[:40]}... found {len(heads)} times, expected once")
    start = heads[0]
    end = next((j for j in range(start + 1, len(lines)) if lines[j].strip() == ".end method"), None)
    if end is None:
        sys.exit(f"{path}: no .end method for the method at line {start + 1}")
    return start, end


def entry_index(lines, start, end, path):
    """First instruction index in [start, end), after .locals and header pseudo-ops.

    Requires .locals >= 2 so v0/v1 are free at entry (before any param is moved),
    which is where the log is inserted."""
    m = re.match(r"\s*\.locals (\d+)$", lines[start + 1])
    if not m or int(m.group(1)) < 2:
        sys.exit(f"{path}: unexpected header (need '.locals >= 2') at line {start + 2}")
    i = start + 2
    while i < end:
        s = lines[i].strip()
        if s == "" or s.startswith((".param", ".end param", ".line", ".prologue",
                                    ".local ", ".restart local", ".end local")):
            i += 1
        elif s.startswith(".annotation"):
            while i < end and not lines[i].strip().startswith(".end annotation"):
                i += 1
            i += 1
        else:
            return i
    sys.exit(f"{path}: no instruction found in the method body")


def patch_write_open(path):
    """Redirect the one writable RandomAccessFile open to /dev/null, and log."""
    lines = open(path).read().split("\n")
    if not any(l.startswith(".class ") and l.rstrip().endswith(CLS) for l in lines):
        sys.exit(f"{path}: not {CLS}")
    start, end = method_bounds(lines, CHANNEL_HDR, path)

    inits = [i for i in range(start, end) if RAF_INIT.match(lines[i])]
    if len(inits) != 1:
        sys.exit(f"{path}: getBlockOutputChannelIgnoringFrp has {len(inits)} "
                 f"RandomAccessFile(<init>) calls, expected one")
    _, path_reg, mode_reg = RAF_INIT.match(lines[inits[0]]).groups()

    modes = [RW_MODE.match(lines[i]) for i in range(start, end)]
    modes = [m for m in modes if m and m.group(1) == mode_reg]
    if len(modes) != 1:
        sys.exit(f"{path}: RandomAccessFile mode register {mode_reg} is not a single "
                 f'write mode ("rw"/"rws"/"rwd"); refusing (it may be a read open)')

    field = re.compile(rf"^\s*iget-object {re.escape(path_reg)}, p0, "
                       rf"L[\w/$]+;->mDataBlockFile:Ljava/lang/String;\s*$")
    loads = [i for i in range(start, end) if field.match(lines[i])]
    if len(loads) != 1:
        sys.exit(f"{path}: expected one mDataBlockFile load into {path_reg} in "
                 f"getBlockOutputChannelIgnoringFrp, found {len(loads)}")
    lines[loads[0]] = (
        "    # OneOS: the FRP partition is One UI's; the guest opens /dev/null instead.\n"
        f'    const-string {path_reg}, "/dev/null"')

    i = entry_index(lines, start, end, path)
    lines[i:i] = [
        "    # OneOS: every write to the host's FRP partition is discarded.",
        f'    const-string v0, "{TAG}"',
        "",
        '    const-string v1, "OneOS: FRP partition write discarded"',
        "",
        "    invoke-static {v0, v1}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I",
        "",
    ]
    open(path, "w").write("\n".join(lines))
    print(f"{os.path.relpath(path)}: getBlockOutputChannelIgnoringFrp writes to /dev/null "
          f"(path reg {path_reg})", file=sys.stderr)


def patch_wipe(path):
    """Make wipe() refuse at entry: no native wipe, no truncate, host untouched."""
    lines = open(path).read().split("\n")
    start, end = method_bounds(lines, WIPE_HDR, path)
    i = entry_index(lines, start, end, path)
    lines[i:i] = [
        "    # OneOS: never wipe the host's FRP partition; refuse before the native wipe.",
        f'    const-string v0, "{TAG}"',
        "",
        '    const-string v1, "OneOS: FRP partition wipe refused (host partition)"',
        "",
        "    invoke-static {v0, v1}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I",
        "",
        "    return-void",
        "",
    ]
    open(path, "w").write("\n".join(lines))
    print(f"{os.path.relpath(path)}: wipe() refused at entry (nativeWipe not called)",
          file=sys.stderr)


def check_native_wipe_only_from_wipe(root):
    """Fail closed if nativeWipe can be reached other than through wipe()."""
    nest = re.compile(r"^\s*invoke-\w+(?:/range)? \{[^}]*\}, "
                      r"L[\w/$]+;->-\$\$Nest\$mnativeWipe\(")
    direct = re.compile(r"^\s*invoke-\w+(?:/range)? \{[^}]*\}, "
                        r"L[\w/$]+;->nativeWipe\(")
    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".smali") or os.sep + os.path.join("com", "android",
                                                                    "server", "pdb") not in dirpath + os.sep:
                continue
            path = os.path.join(dirpath, name)
            lines = open(path).read().split("\n")
            # Direct nativeWipe calls must only be the -$$Nest$mnativeWipe bridge.
            method = None
            for l in lines:
                hm = re.match(r"^\.method .*?(\S+)\(", l)
                if hm:
                    method = hm.group(1)
                if direct.match(l) and method != "-$$Nest$mnativeWipe":
                    sys.exit(f"{path}: nativeWipe called from {method}, not just the bridge")
            # The bridge itself must only be invoked from wipe() (which we neutralise).
            method = None
            for l in lines:
                hm = re.match(r"^\.method .*?(\S+)\(", l)
                if hm:
                    method = hm.group(1)
                if nest.match(l) and method != "wipe":
                    sys.exit(f"{path}: -$$Nest$mnativeWipe invoked from {method}, not wipe()")


def main(root):
    svc = [os.path.join(d, SVC) for d, _, fs in os.walk(root) if SVC in fs
           and os.path.join(d, "").endswith(os.path.join("com", "android", "server", "pdb", ""))]
    stub = [os.path.join(d, STUB) for d, _, fs in os.walk(root) if STUB in fs
            and os.path.join(d, "").endswith(os.path.join("com", "android", "server", "pdb", ""))]
    if len(svc) != 1:
        sys.exit(f"expected one {SVC}, found {len(svc)}")
    if len(stub) != 1:
        sys.exit(f"expected one {STUB}, found {len(stub)}")

    check_native_wipe_only_from_wipe(root)
    patch_write_open(svc[0])
    patch_wipe(stub[0])

    dirs = {os.path.relpath(p, root).split(os.sep)[0] for p in (svc[0], stub[0])}
    if len(dirs) != 1:
        sys.exit(f"service and stub in different dex dirs: {sorted(dirs)}")
    print("FRP partition: 1 write-open redirected to /dev/null, 1 wipe() refused",
          file=sys.stderr)
    for d in sorted(dirs):
        print(d)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: guest_pdb_readonly.py <smali root dir>")
    main(sys.argv[1])
