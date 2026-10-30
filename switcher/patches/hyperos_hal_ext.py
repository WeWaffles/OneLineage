"""HyperOS's casts of HAL extension binders, against One UI's HALs.

Xiaomi's framework asks AOSP HAL binders for their vendor extension and casts
it to a Xiaomi interface without checking it:

    IBinder ext = supplicant.asBinder().getExtension();
    mISupplicantXm = ISupplicantXm.Stub.asInterface(ext);

asInterface does not check the remote descriptor. In a session those HALs are
One UI's, whose extension carries Samsung's interface, so every Xiaomi call on
it was rejected (BAD_TYPE, IllegalArgumentException), and an uncaught one took
system_server down (Z Fold8 Ultra, 2026-10-25: MiuiWifiService,
ISupplicantXm.registerCallback). A Xiaomi transaction could also land on one
of Samsung's methods.

Each such cast now goes through a helper that passes the extension on only
when its descriptor is the target interface's DESCRIPTOR (read at run time),
and null otherwise; Xiaomi's code already handles a null interface (for
example "mISupplicantXm is null"). The helper class is added to the jar.

Every getExtension() call in the jar must be such a cast, and their number
must be the expected one, or nothing is written (fail closed).

Usage: hyperos_hal_ext.py --expect N <apktool decoded jar directory> <helper class name>
Prints the smali_* directories (dex files) it changed.
"""
import os
import re
import sys

CAST = re.compile(
    r"(    invoke-interface \{(v\d+)\}, Landroid/os/IBinder;->getExtension\(\)Landroid/os/IBinder;\n"
    r"\n    move-result-object \2\n)"
    r"(\n    invoke-static \{\2\}, L([\w/$]+)\$Stub;->asInterface\(Landroid/os/IBinder;\)L\4;\n)")
CALL = "invoke-interface {"
EXT = "Landroid/os/IBinder;->getExtension()Landroid/os/IBinder;"

HELPER_METHOD = """
.method public static {name}(Landroid/os/IBinder;)Landroid/os/IBinder;
    .locals 2
    .param p0, "ext"    # Landroid/os/IBinder;

    if-eqz p0, :cond_none

    :try_start_0
    invoke-interface {{p0}}, Landroid/os/IBinder;->getInterfaceDescriptor()Ljava/lang/String;

    move-result-object v0
    :try_end_0
    .catch Ljava/lang/Exception; {{:try_start_0 .. :try_end_0}} :cond_none

    sget-object v1, L{iface};->DESCRIPTOR:Ljava/lang/String;

    invoke-virtual {{v1, v0}}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v1

    if-eqz v1, :cond_other

    return-object p0

    :cond_other
    const-string v1, "OneOSHalExt"

    invoke-static {{v1, v0}}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    :cond_none
    const/4 v0, 0x0

    return-object v0
.end method
"""


def main(argv):
    if len(argv) != 4 or argv[0] != "--expect" or not argv[1].isdigit():
        sys.exit(__doc__)
    expect, root, helper = int(argv[1]), argv[2], argv[3]
    if not re.fullmatch(r"[A-Z]\w*", helper):
        sys.exit(f"hyperos_hal_ext: bad helper class name {helper}")
    helper_cls = f"com/oneos/guest/{helper}"
    files = {}
    for d, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(".smali"):
                p = os.path.join(d, f)
                s = open(p).read()
                if EXT in s:
                    files[p] = s
    ifaces, total, out = {}, 0, {}
    for p, s in sorted(files.items()):
        calls = s.count(EXT)
        casts = CAST.findall(s)
        if calls != len(casts):
            sys.exit(f"hyperos_hal_ext: {os.path.relpath(p, root)}: {calls} getExtension() calls, {len(casts)} of them casts")
        def sub(m):
            iface = m.group(4)
            name = ifaces.setdefault(iface, f"ext{len(ifaces)}")
            reg = m.group(2)
            check = (f"\n    invoke-static {{{reg}}}, L{helper_cls};->{name}(Landroid/os/IBinder;)Landroid/os/IBinder;\n"
                     f"\n    move-result-object {reg}\n")
            return m.group(1) + check + m.group(3)
        out[p] = CAST.sub(sub, s)
        total += calls
    if total != expect:
        sys.exit(f"hyperos_hal_ext: {total} extension casts, expected {expect}")
    helper_path = os.path.join(root, "smali", *helper_cls.split("/")) + ".smali"
    if os.path.exists(helper_path):
        sys.exit(f"hyperos_hal_ext: {helper_cls} already exists")
    for p, s in out.items():
        open(p, "w").write(s)
    os.makedirs(os.path.dirname(helper_path), exist_ok=True)
    body = [f".class public final L{helper_cls};", ".super Ljava/lang/Object;", '.source "hyperos_hal_ext.py"', ""]
    for iface, name in ifaces.items():
        body.append(HELPER_METHOD.format(name=name, iface=iface))
        print(f"{helper}.{name}: {iface.replace('/', '.')} extensions only", file=sys.stderr)
    open(helper_path, "w").write("\n".join(body))
    for d in sorted({os.path.relpath(p, root).split(os.sep)[0] for p in list(out) + [helper_path]}):
        print(d)


if __name__ == "__main__":
    main(sys.argv[1:])
