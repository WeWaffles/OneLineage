"""Never let the guest's wipe paths delete the phone's secrets.

RecoverySystemService.deleteSecrets() (Android 17) runs before a factory
reset: it deletes every keystore key, calls ISecretkeeper.deleteAll() on the
phone's Secretkeeper HAL and, in Infinity-X's build, runs
ExtendedWipeWithoutReboot.run(), which sets sys.erase_secure_element (the
secure element's erase) and asks vold for destroyUserStorageKeys2 for every
user, destroySystemStorageKey() and destroyMetadataKey("/data"). The
Secretkeeper HAL and the secure element are One UI's, and the keys are what
open One UI's /data: the weaver problem again (guest_no_weaver.py), for the
whole phone.

AOSP calls deleteSecrets() only from rebootRecoveryWithCommand, after
setupOrClearBcb succeeded, which guest_power_guards.py refuses. Infinity-X's
DuressWipe.run() (a duress password wipe: DuressPasswordHelper, the lock
screen) calls it directly. So, at entry, each with a log line and nothing
else:

1. RecoverySystemService.deleteSecrets() returns.
2. ExtendedWipeWithoutReboot.run() returns (Infinity-X).
3. DuressWipe.run(Context) returns (Infinity-X): no recovery wipe request,
   no secrets deleted, no shutdown.

Each is left out when the build does not have it. Fail closed: afterwards,
every ISecretkeeper.deleteAll(), IVold.destroyMetadataKey,
destroySystemStorageKey and destroyUserStorageKeys2 call and every
"sys.erase_secure_element" must be in deleteSecrets() or in
ExtendedWipeWithoutReboot (IVold$Stub's dispatch is the server side, not a
call), and no other class may call into ExtendedWipeWithoutReboot except its
run().

Usage: guest_no_wipe_secrets.py <smali root dir>
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import re
import sys

RSS = "com/android/server/recoverysystem/RecoverySystemService"
EXT = "com/android/server/recoverysystem/ExtendedWipeWithoutReboot"
DURESS = "com/android/server/locksettings/DuressWipe"
TARGETS = (
    (RSS, "deleteSecrets()V", "deleteSecrets"),
    (EXT, "run()V", "ExtendedWipeWithoutReboot.run"),
    (DURESS, "run(Landroid/content/Context;)V", "DuressWipe.run"),
)
DANGER = re.compile(r"Landroid/hardware/security/secretkeeper/ISecretkeeper;->deleteAll\("
                    r"|Landroid/os/IVold;->(?:destroyMetadataKey|destroySystemStorageKey|destroyUserStorageKeys2)\("
                    r'|"sys\.erase_secure_element"')
STUB = "android/os/IVold$Stub"
LOCALS = re.compile(r"^(\s*)\.locals (\d+)$")


def classes(root):
    """{class name: path} of every smali file."""
    found = {}
    for d, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(".smali"):
                p = os.path.join(d, f)
                found[os.path.relpath(p, root).split(os.sep, 1)[1][:-len(".smali")].replace(os.sep, "/")] = p
    return found


def stub(lines, sig, label, path):
    heads = [i for i, l in enumerate(lines) if l.startswith(".method ") and " static " in f" {l} " and l.endswith(" " + sig)]
    if len(heads) != 1:
        sys.exit(f"{path}: static {sig} found {len(heads)} times, expected once")
    i = heads[0]
    m = LOCALS.match(lines[i + 1])
    if not m:
        sys.exit(f"{path}: {sig} has no .locals line")
    # Static, so raising .locals only moves the parameters up (smali renumbers them).
    if int(m.group(2)) < 2:
        lines[i + 1] = f"{m.group(1)}.locals 2"
    # After the parameters' debug info and any annotation, before the first instruction.
    j = i + 2
    while lines[j].strip() == "" or lines[j].lstrip().startswith((".param", ".end param", ".annotation")):
        if lines[j].lstrip().startswith(".annotation"):
            j = next(k for k in range(j, len(lines)) if lines[k].strip() == ".end annotation")
        j += 1
    lines[j:j] = [
        "    # OneOS: the phone's secrets and keys are One UI's; the guest never deletes them.",
        '    const-string v0, "OneOS"',
        "",
        f'    const-string v1, "OneOS: {label} refused in the guest (the phone\'s secrets and keys are One UI\'s)"',
        "",
        "    invoke-static {v0, v1}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I",
        "",
        "    return-void",
        "",
    ]
    print(f"{label}: returns at entry", file=sys.stderr)


def method_of(lines, i):
    for k in range(i, -1, -1):
        if lines[k].startswith(".method "):
            return lines[k].split()[-1]
    return None


def main(root):
    found = classes(root)
    changed = {}
    for cls, sig, label in TARGETS:
        path = found.get(cls)
        if path is None:
            continue
        lines = changed.get(path) or open(path).read().split("\n")
        if not any(l.startswith(".method ") and l.endswith(" " + sig) for l in lines):
            if cls == RSS:
                continue
            sys.exit(f"{path}: {sig} not found, unexpected build")
        stub(lines, sig, label, path)
        changed[path] = lines
    # Fail closed, on the patched text.
    for cls, path in found.items():
        lines = changed.get(path) or open(path).read().split("\n")
        text = "\n".join(lines)
        if cls != STUB and cls != EXT:
            for i, line in enumerate(lines):
                if DANGER.search(line) and not line.lstrip().startswith("#"):
                    if not (cls == RSS and method_of(lines, i) == "deleteSecrets()V"):
                        sys.exit(f"{cls}.{method_of(lines, i)}: {line.strip()} outside the methods made to return, not patching")
        if cls != EXT and f"L{EXT};->" in text:
            for line in lines:
                if f"L{EXT};->" in line and f"L{EXT};->run()V" not in line:
                    sys.exit(f"{cls}: calls {line.strip()} (only ExtendedWipeWithoutReboot.run is stopped), not patching")
    for path, lines in changed.items():
        with open(path, "w") as f:
            f.write("\n".join(lines))
    if not changed:
        print("no wipe-secrets path in this build, left as it is", file=sys.stderr)
    for d in sorted({os.path.relpath(p, root).split(os.sep)[0] for p in changed}):
        print(d)


if __name__ == "__main__":
    main(sys.argv[1])
