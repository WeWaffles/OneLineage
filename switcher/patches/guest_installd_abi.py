"""Make the guest's installd calls match the host installd's interface.

The guest framework talks to One UI's installd over the shared servicemanager,
and binder dispatches by transaction code. ColorOS's IInstalld differs from
Samsung's: it has clearAppDataWithPreservedCacheEntries at code 10 and two
OPPO methods at 51/52, so from code 10 on nearly every guest call reached a
different host method (the guest's destroyAppData arrived as destroyPccData,
rmPackageDir as freeCache). In run 25 most of them only failed because the
arguments did not parse.

In OneOS's copy of the guest's IInstalld$Stub$Proxy (services.jar):
- methods the host has with the same signature, and that only create, query,
  relabel or compile, are sent with the HOST's code;
- every other method throws RemoteException before transact(): all deleting,
  clearing, moving and snapshot calls, methods the host does not have, and
  anything new that is not listed below (fail closed). The callers already
  handle installd failures.

The copy is com.android.server.pm.OneOSInstalldProxy, and every
IInstalld.Stub.asInterface() call in services.jar (and, with --callers, in
oplus-services.jar) goes to its asInterface(). Patching
android.os.IInstalld$Stub$Proxy in place did nothing: ColorOS's framework.jar,
on the boot class path, has its own android.os.IInstalld, and system_server's
class loader asks the boot class path first. Runs 26-29 still sent ColorOS's
codes: invalidateMounts arrived as the host's isQuotaSupported ("error -61"),
isQuotaSupported as prepareAppProfile (NullPointerException), and Settings >
About crashed on the null storage size that followed.

(StorageStatsService.isQuotaSupported itself is made to return false by
guest_storage_guards.py, so free space comes from statfs.)

Usage: guest_installd_abi.py <smali root dir> <host table>   (services.jar)
       guest_installd_abi.py --callers <smali root dir>      (oplus-services.jar)
(the host table comes from scripts/host-installd-table.sh)
Prints the smali_* directories it changed, one per line.
"""
import os
import re
import sys

# Sent to the host when it has the same method with the same signature.
ALLOWED = {
    "createUserData", "setFirstBoot", "createAppData", "createAppDataBatched",
    "restoreconAppData", "fixupAppData", "getAppSize", "getUserSize",
    "getExternalSize", "getAppCrates", "getUserCrates",
    "controlDexOptBlocking", "mergeProfiles", "dumpProfiles", "copySystemProfile",
    "createProfileSnapshot", "linkNativeLibraryDirectory", "createOatDirs",
    "linkFile", "hashSecondaryDexFile", "invalidateMounts", "isQuotaSupported",
    "prepareAppProfile", "tryMountDataMirror", "getOdexVisibility",
    "createFsveritySetupAuthToken", "enableFsverity",
}
PROXY = os.path.join("android", "os", "IInstalld$Stub$Proxy.smali")
STUB = os.path.join("android", "os", "IInstalld$Stub.smali")
INSTALLER = os.path.join("com", "android", "server", "pm", "Installer.smali")
TRANSACT = re.compile(r"^\s*invoke-interface \{([vp]\d+), ([vp]\d+), ([vp]\d+), ([vp]\d+), ([vp]\d+)\}, "
                      r"Landroid/os/IBinder;->transact\(ILandroid/os/Parcel;Landroid/os/Parcel;I\)Z\s*$")

PROXY_DESC = "Landroid/os/IInstalld$Stub$Proxy;"
OWN = "Lcom/android/server/pm/OneOSInstalldProxy;"
AS_INTERFACE = "->asInterface(Landroid/os/IBinder;)Landroid/os/IInstalld;"
STUB_CALL = re.compile(r"^(\s*invoke-static(?:/range)? \{[^}]*\}, )Landroid/os/IInstalld\$Stub;"
                       + re.escape(AS_INTERFACE) + r"\s*$")
OWN_AS_INTERFACE = f""".method public static asInterface(Landroid/os/IBinder;)Landroid/os/IInstalld;
    .locals 1

    # OneOS: the host installd is only reached through this class.
    if-nez p0, :oneos_binder

    const/4 v0, 0x0

    return-object v0

    :oneos_binder
    new-instance v0, {OWN}

    invoke-direct {{v0, p0}}, {OWN}-><init>(Landroid/os/IBinder;)V

    return-object v0
.end method
"""


def find(root, suffix):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(os.sep + suffix)]
    if len(hits) != 1:
        sys.exit(f"expected exactly one {suffix}, found {len(hits)}")
    return hits[0]


def top_dir(root, path):
    return os.path.relpath(path, root).split(os.sep)[0]


def own_class(lines):
    """The patched proxy as a public top-level class that the boot class path does not have."""
    text = "\n".join(lines)
    text = re.sub(r"^\.annotation system Ldalvik/annotation/(?:EnclosingClass|InnerClass);\n.*?^\.end annotation\n",
                  "", text, flags=re.S | re.M)
    first = text.split("\n", 1)[0]
    if not re.match(r"^\.class (?:public )?(?:final )?" + re.escape(PROXY_DESC) + "$", first):
        sys.exit(f"IInstalld$Stub$Proxy: unexpected class line {first!r}")
    text = text.replace(first, f".class public final {OWN}", 1)
    text = text.replace(PROXY_DESC, OWN)
    if "Ldalvik/annotation/InnerClass;" in text or "IInstalld$Stub$Proxy" in text:
        sys.exit("IInstalld$Stub$Proxy: references left in OneOSInstalldProxy")
    return text.rstrip("\n") + "\n\n" + OWN_AS_INTERFACE


def redirect_callers(root):
    """Every IInstalld.Stub.asInterface() call goes to OneOSInstalldProxy.asInterface()."""
    dirs, total, files = set(), 0, []
    for dirpath, _, names in os.walk(root):
        for name in names:
            if not name.endswith(".smali"):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            if rel.split(os.sep, 1)[-1].startswith(os.path.join("android", "os", "IInstalld")):
                continue  # the AIDL classes themselves (shadowed by the boot class path)
            with open(path) as f:
                lines = f.read().split("\n")
            hits = 0
            for i, line in enumerate(lines):
                m = STUB_CALL.match(line)
                if m:
                    lines[i] = m.group(1) + OWN + AS_INTERFACE
                    hits += 1
            text = "\n".join(lines)
            # Fail closed: nothing may reach installd through the boot class path's proxy.
            if "Landroid/os/IInstalld$Stub;->asInterface" in text or PROXY_DESC + "-><init>" in text:
                sys.exit(f"{rel}: IInstalld proxy reference not redirected")
            if hits:
                with open(path, "w") as f:
                    f.write(text)
                dirs.add(top_dir(root, path))
                files.append(rel)
                total += hits
                print(f"{rel}: IInstalld.Stub.asInterface -> OneOSInstalldProxy ({hits})", file=sys.stderr)
    print(f"IInstalld: {total} asInterface calls redirected", file=sys.stderr)
    return dirs, files


def main(root, table):
    host = {}
    for line in open(table):
        if line.startswith("#") or not line.strip():
            continue
        name, code, sig = line.split()
        host[name] = (int(code), sig)
    guest_codes = {m.group(1): int(m.group(2), 16) for m in re.finditer(
        r"^\.field static final TRANSACTION_(\w+):I = 0x([0-9a-f]+)", open(find(root, STUB)).read(), re.M)}

    path = find(root, PROXY)
    lines = open(path).read().split("\n")
    remapped, blocked, kept = [], [], []
    i = 0
    while i < len(lines):
        m = re.match(r"^\.method public (?:final )?(\w+)(\([^)]*\)\S+)$", lines[i])
        if not m or m.group(1) not in guest_codes:
            i += 1
            continue
        name, sig = m.groups()
        end = next(j for j in range(i, len(lines)) if lines[j] == ".end method")
        h = host.get(name)
        if name in ALLOWED and h and h[1] == sig:
            # Rewrite the code register loaded just before transact().
            t = next(j for j in range(i, end) if TRANSACT.match(lines[j]))
            reg = TRANSACT.match(lines[t]).group(2)
            c = next(j for j in range(t - 1, i, -1)
                     if re.match(rf"^\s*const(?:/4|/16)? {reg}, ", lines[j]))
            if h[0] != guest_codes[name]:
                lines[c] = f"    const/16 {reg}, 0x{h[0]:x}"
                remapped.append(f"{name} 0x{guest_codes[name]:x}->0x{h[0]:x}")
            else:
                kept.append(name)
        else:
            # Throw before any code that could reach the host.
            k = i + 1
            in_annotation = False
            while True:
                s = lines[k].strip()
                if s.startswith(".annotation"):
                    in_annotation = True
                elif s.startswith(".end annotation"):
                    in_annotation = False
                elif s and not in_annotation and not s.startswith((".locals", ".param", ".end param", "#")):
                    break
                k += 1
            locals_ = int(next(re.match(r"\s*\.locals (\d+)", l).group(1) for l in lines[i:end] if l.strip().startswith(".locals")))
            if locals_ < 2:
                sys.exit(f"{name}: needs 2 locals, has {locals_}")
            lines[k:k] = [
                "    # OneOS: not sent to the host installd (different interface or not allowed).",
                "    new-instance v0, Landroid/os/RemoteException;",
                "",
                f'    const-string v1, "OneOS: installd.{name} blocked in the container"',
                "",
                "    invoke-direct {v0, v1}, Landroid/os/RemoteException;-><init>(Ljava/lang/String;)V",
                "",
                "    throw v0",
                "",
            ]
            blocked.append(name)
            end += 9
        i = end + 1

    missing = set(guest_codes) - set(remapped_names := [r.split()[0] for r in remapped]) - set(blocked) - set(kept)
    if missing:
        sys.exit(f"IInstalld methods without a proxy method: {sorted(missing)}")
    if "destroyUserData" not in blocked or "createAppData" not in kept + remapped_names:
        sys.exit("unexpected IInstalld classification")

    # The patched proxy goes next to Installer (classes.dex, where the original
    # lives, is at the 64K method limit), under a name the boot class path lacks.
    installer = find(root, INSTALLER)
    dst = os.path.join(os.path.dirname(installer), "OneOSInstalldProxy.smali")
    if os.path.exists(dst):
        sys.exit(f"{dst} exists already")
    with open(dst, "w") as f:
        f.write(own_class(lines))
    dirs, files = redirect_callers(root)
    if os.path.relpath(installer, root) not in files:
        sys.exit("Installer: IInstalld.Stub.asInterface call not found")
    dirs.add(top_dir(root, installer))
    print(f"IInstalld: {len(kept)} identical, {len(remapped)} remapped, {len(blocked)} blocked"
          f" (in {os.path.relpath(dst, root)})", file=sys.stderr)
    print("  remapped: " + ", ".join(remapped), file=sys.stderr)
    print("  blocked: " + ", ".join(blocked), file=sys.stderr)
    for d in sorted(dirs):
        print(d)


def callers_only(root):
    dirs, _ = redirect_callers(root)
    for d in sorted(dirs):
        print(d)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--callers":
        callers_only(sys.argv[2])
    elif len(sys.argv) == 3:
        main(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)
