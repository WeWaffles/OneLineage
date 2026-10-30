"""A Pixel guest's camera binder calls with One UI's transaction codes.

The guest's camera clients talk to One UI's cameraserver, and Samsung's
camera interfaces are not AOSP's (docs/pixel-guest.md, "What differs"):
ICameraService has notifyDeviceStateChangeSync at 23, so createDefaultRequest,
isSessionConfigurationWithParametersSupported, getSessionCharacteristics and
warmUp are 24-27 on Samsung (23-26 on the Pixels); ICameraDeviceUser has
setParameters at 13, so every Pixel method from getInputSurface (13) to
updateOutputConfigurations (28) is one higher. A Pixel session's
createDefaultRequest reached Samsung's getInputSurface. ICameraServiceListener's
9 is Samsung's onCameraDeviceStateChanged; the Pixel 9 Pro XL has
onStatusChangedBatched there and misparsed it ("Allocation of size 7209057").
Its CameraCompatibilityInfo also writes a sixth field, which Samsung read as the
next parcelable's null marker (NullPointerException in getCameraCharacteristics
and connect; "Failed to load metadata for CameraId-2").

Table-driven, like guest_installd_abi.py: the host table is
scripts/aidl-table.py's output for One UI's framework.jar (patches/host_camera.txt:
<interface> <method> <code> <signature>). For every interface in it:
  - the guest's Stub$Proxy: each method the host also has gets the host's code
    (the const feeding IBinder.transact), only when the signatures are equal;
    a host method the guest lacks is left to it (never called); a guest method
    the host lacks goes to UNUSED_CODE when it returns void (ColorOS's
    notifySmartWindowChange, notifyDisplayRotationChange), and when it has a
    result (HyperOS's ICameraService.addFaceListener, 23 on Xiaomi, where One
    UI has notifyDeviceStateChangeSync) the Proxy method throws
    RemoteException at entry: nothing reaches One UI's cameraserver, and the
    caller handles it like a dead service.
  - the guest's Stub.onTransact, for the interfaces the host calls into the
    guest (ICameraServiceListener, ICameraDeviceCallbacks): a guest case whose
    code is a different method on the host is dropped from the packed switch,
    so the host's call is ignored (returns false) instead of misparsed.
  - android.content.res.CameraCompatibilityInfo: a sixth field
    (mShouldOverrideLensFacingFrontToBack) is no longer written or read; the
    five Samsung reads stay as they are.
Every target must match exactly once, or the build stops (fail closed).

Usage: pixel_camera_abi.py <apktool decoded framework.jar dir> <host_camera.txt>
Prints the smali_* directories (dex files) it changed, one per line; prints
"unchanged" to stderr and nothing to stdout when the tables already agree.
"""
import os
import re
import sys

CALLBACK_IFACES = ("android.hardware.ICameraServiceListener", "android.hardware.camera2.ICameraDeviceCallbacks")
# A transaction code none of One UI's camera interfaces uses (the highest is 38).
UNUSED_CODE = 200
COMPAT = "android/content/res/CameraCompatibilityInfo.smali"
TRANSACT = "Landroid/os/IBinder;->transact(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z"
# v registers in R8 builds (Pixel, ColorOS); p registers too in a build with
# debug info (Infinity-X's framework.jar: "const/16 p3, 0x17").
CONST = re.compile(r"^(\s*)const(/4|/16|)\s+([vp]\d+),\s*(-?0x[0-9a-f]+|-?\d+)\s*$")


LOCALS_RE = re.compile(r"^(\s*)\.locals (\d+)$")


def die(msg):
    sys.exit(f"pixel_camera_abi: {msg}")


def read_table(path):
    """{interface: {method: (code, signature)}}"""
    out = {}
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 3)
        if len(parts) != 4:
            die(f"{path}: malformed line '{line}'")
        iface, name, code, sig = parts
        out.setdefault(iface, {})[name] = (int(code), sig)
    return out


def find_smali(root, cls):
    hits = []
    for d in sorted(os.listdir(root)):
        if d.startswith("smali"):
            p = os.path.join(root, d, cls)
            if os.path.isfile(p):
                hits.append(p)
    if len(hits) != 1:
        die(f"{cls} found {len(hits)} times under {root} (one expected)")
    return hits[0]


def method_bodies(text):
    """[(start, end, header_line)] of every method, in file order."""
    out = []
    for m in re.finditer(r"^\.method .*$", text, re.M):
        end = text.find("\n.end method", m.end())
        if end < 0:
            die("method without .end method")
        out.append((m.start(), end, m.group(0)))
    return out


def sig_of(header):
    """The AIDL table's signature shape from a smali method header: name(args)ret."""
    m = re.search(r" ([A-Za-z_$][A-Za-z0-9_$]*)(\([^)]*\)\S+)$", header)
    return (m.group(1), m.group(2)) if m else (None, None)


def refuse_at_entry(body, iface, name):
    """The method body with a RemoteException thrown before anything else (an instance Proxy method)."""
    lines = body.split("\n")
    li = next((i for i, l in enumerate(lines) if LOCALS_RE.match(l)), None)
    if li is None:
        die(f"{iface}.{name}: no .locals line")
    if int(LOCALS_RE.match(lines[li]).group(2)) < 2:
        lines[li] = f"{LOCALS_RE.match(lines[li]).group(1)}.locals 2"
    j = li + 1
    while j < len(lines) and (lines[j].strip() == "" or lines[j].lstrip().startswith((".param", ".end param", ".annotation"))):
        if lines[j].lstrip().startswith(".annotation"):
            j = next(k for k in range(j, len(lines)) if lines[k].strip() == ".end annotation")
        j += 1
    lines[j:j] = [
        "    # OneOS: One UI's camera service has no such method (pixel_camera_abi.py).",
        "    new-instance v0, Landroid/os/RemoteException;",
        f'    const-string v1, "OneOS: {iface}.{name} is not on this phone"',
        "    invoke-direct {v0, v1}, Landroid/os/RemoteException;-><init>(Ljava/lang/String;)V",
        "    throw v0",
        "",
    ]
    return "\n".join(lines)


def patch_proxy(text, iface, host, guest, changed):
    """Renumber the const that feeds transact in each Proxy method."""
    pieces, pos, n = [], 0, 0
    for s, e, header in method_bodies(text):
        name, sig = sig_of(header)
        body = text[s:e]
        if name is None or TRANSACT not in body or name not in guest:
            continue
        gcode, gsig = guest[name]
        if name not in host:
            # ColorOS adds notifySmartWindowChange and notifyDisplayRotationChange. A void
            # call goes to a code One UI does not have: its Binder answers "unknown
            # transaction" (transact() returns false) and the Proxy goes on. A call with
            # a result would read garbage, so it throws before transact instead (fail closed).
            if not gsig.endswith(")V"):
                pieces.append(text[pos:s]); pieces.append(refuse_at_entry(body, iface, name)); pos = e
                n += 1
                changed.append(f"{iface}.{name}: {gcode} -> RemoteException at entry")
                continue
            hcode, hsig = UNUSED_CODE, gsig
        else:
            hcode, hsig = host[name]
        if hsig == "?":
            die(f"{iface}.{name}: the host table has no signature for it")
        if hsig != gsig:
            die(f"{iface}.{name}: signature differs (host {hsig}, guest {gsig})")
        if hcode == gcode:
            continue
        lines = body.split("\n")
        ti = [i for i, l in enumerate(lines) if TRANSACT in l]
        if len(ti) != 1:
            die(f"{iface}.{name}: {len(ti)} transact calls (one expected)")
        regs = re.search(r"invoke-interface \{([^}]*)\}", lines[ti[0]]).group(1).split(", ")
        code_reg = regs[1]
        ci = None
        for i in range(ti[0] - 1, -1, -1):
            m = CONST.match(lines[i])
            if m and m.group(3) == code_reg:
                ci = i
                break
        if ci is None:
            die(f"{iface}.{name}: no const for {code_reg} before transact")
        val = int(lines[ci].split(",")[-1].strip(), 0)
        if val != gcode:
            die(f"{iface}.{name}: const {val} before transact, table says {gcode}")
        # const/4 only reaches v0-v15; a p register may sit higher, so it keeps const/16.
        width = "/4" if hcode < 8 and (code_reg.startswith("v") or CONST.match(lines[ci]).group(2) == "/4") else "/16"
        lines[ci] = f"{CONST.match(lines[ci]).group(1)}const{width} {code_reg}, {hex(hcode)}"
        pieces.append(text[pos:s]); pieces.append("\n".join(lines)); pos = e
        n += 1
        changed.append(f"{iface}.{name}: {gcode} -> {hcode}")
    pieces.append(text[pos:])
    return "".join(pieces), n


def patch_stub_switch(text, iface, host, guest, changed):
    """Drop a guest onTransact case whose code is another method on the host."""
    by_code_host = {c: n for n, (c, _) in host.items()}
    drop = {c for n, (c, _) in guest.items() if c in by_code_host and by_code_host[c] != n}
    if not drop:
        return text, 0
    bodies = [(s, e, h) for s, e, h in method_bodies(text) if " onTransact(" in h]
    if len(bodies) != 1:
        die(f"{iface}: {len(bodies)} onTransact methods (one expected)")
    s, e, _ = bodies[0]
    body = text[s:e]
    m = re.search(r"\.packed-switch (0x[0-9a-f]+|\d+)\n((?:\s*:pswitch_\d+\n)+)\s*\.end packed-switch", body)
    if not m:
        die(f"{iface}.onTransact: no packed switch")
    first = int(m.group(1), 0)
    labels = m.group(2).split()
    codes = {first + i: lab for i, lab in enumerate(labels)}
    for c in sorted(drop):
        if c not in codes:
            die(f"{iface}.onTransact: code {c} not in its switch")
    keep = [(c, lab) for c, lab in sorted(codes.items()) if c not in drop]
    # A packed switch must stay contiguous: dropped codes above the last kept one fall off the end;
    # a dropped code in the middle keeps its slot, pointed at the switch's own fall-through.
    last_kept = max(c for c, _ in keep)
    new = []
    for c in range(first, last_kept + 1):
        new.append(codes[c] if c not in drop else ":oneos_ignored")
    table = f".packed-switch {m.group(1)}\n" + "".join(f"        {lab}\n" for lab in new) + "    .end packed-switch"
    body = body[:m.start()] + table + body[m.end():]
    if ":oneos_ignored" in table:
        # The fall-through label right after the switch instruction (the default path).
        sw = re.search(r"^(\s*)packed-switch p1, :pswitch_data_0\n", body, re.M)
        if not sw:
            die(f"{iface}.onTransact: switch instruction not found")
        body = body[:sw.end()] + f"{sw.group(1)}:oneos_ignored\n" + body[sw.end():]
    for c in sorted(drop):
        changed.append(f"{iface}.onTransact: code {c} ({[n for n, (cc, _) in guest.items() if cc == c][0]}) ignored; the host's {by_code_host[c]}")
    return text[:s] + body + text[e:], len(drop)


WRITE6 = """    iget-boolean v0, p0, Landroid/content/res/CameraCompatibilityInfo;->mShouldOverrideLensFacingFrontToBack:Z

    invoke-virtual {p1, v0}, Landroid/os/Parcel;->writeBoolean(Z)V
"""
READ6 = re.compile(
    r"    invoke-virtual \{p1\}, Landroid/os/Parcel;->readByte\(\)B\n\n    move-result v0\n\n    if-eqz v0, :cond_(\d+)\n\n    goto :goto_(\d+)\n\n"
    r"    :cond_\1\n    move v1, v2\n\n    :goto_\2\n    iput-boolean v1, p0, Landroid/content/res/CameraCompatibilityInfo;->mShouldOverrideLensFacingFrontToBack:Z\n")


def patch_compat(root, changed):
    path = find_smali(root, COMPAT)
    text = open(path).read()
    if "mShouldOverrideLensFacingFrontToBack" not in text:
        return None
    if text.count(WRITE6) != 1:
        die(f"CameraCompatibilityInfo: the sixth field's write found {text.count(WRITE6)} times (one expected)")
    text = text.replace(WRITE6, "")
    text, n = READ6.subn("", text)
    if n != 1:
        die(f"CameraCompatibilityInfo: the sixth field's read found {n} times (one expected)")
    open(path, "w").write(text)
    changed.append("CameraCompatibilityInfo: sixth field (mShouldOverrideLensFacingFrontToBack) not written or read")
    return path


TRANS_FIELD = re.compile(r"^\.field static final (?:[a-z-]+ )*TRANSACTION_(\w+):I = (0x[0-9a-f]+|\d+)\s*$", re.M)


def guest_table(stub_text, proxy_text):
    """{method: (code, signature)} from the guest's Stub constants and Proxy headers."""
    codes = {n: int(v, 0) for n, v in TRANS_FIELD.findall(stub_text)}
    sigs = {}
    for _, _, header in method_bodies(proxy_text):
        name, sig = sig_of(header)
        if name in codes:
            sigs[name] = sig
    missing = sorted(set(codes) - set(sigs))
    if missing:
        die(f"Proxy lacks methods the Stub names: {missing}")
    return {n: (codes[n], sigs[n]) for n in codes}


def main(root, table_path):
    host = read_table(table_path)
    changed, dirs = [], set()
    for iface, hmethods in host.items():
        cls = iface.replace(".", "/")
        proxy = find_smali(root, cls + "$Stub$Proxy.smali")
        stub = find_smali(root, cls + "$Stub.smali")
        stub_text, proxy_text = open(stub).read(), open(proxy).read()
        guest = guest_table(stub_text, proxy_text)
        if iface in CALLBACK_IFACES:
            # The host calls these into the guest; the guest's own Proxy for
            # them is never used against One UI, so only the Stub's switch matters.
            pass
        else:
            text, n = patch_proxy(proxy_text, iface, hmethods, guest, changed)
            if n:
                open(proxy, "w").write(text)
                dirs.add(os.path.relpath(proxy, root).split(os.sep)[0])
        if iface in CALLBACK_IFACES:
            text, n = patch_stub_switch(stub_text, iface, hmethods, guest, changed)
            if n:
                open(stub, "w").write(text)
                dirs.add(os.path.relpath(stub, root).split(os.sep)[0])
    p = patch_compat(root, changed)
    if p:
        dirs.add(os.path.relpath(p, root).split(os.sep)[0])
    for c in changed:
        print(f"pixel_camera_abi: {c}", file=sys.stderr)
    if not dirs:
        print("pixel_camera_abi: unchanged (the guest's camera tables are the host's)", file=sys.stderr)
    for d in sorted(dirs):
        print(d)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
