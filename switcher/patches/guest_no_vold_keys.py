"""Keep the guest's StorageManagerService away from the host vold's user keys.

The container shares the host's binder services, so the guest framework's
"vold" is the host's: the one holding the keys of One UI's real users. When
ColorOS's LockSettingsService set up its synthetic password it called
setCeStorageProtection() for user 0 (it failed; had it succeeded, One UI's
user 0 CE key would have been protected with a secret One UI does not know).
The guest's users live in its own staged /data and need no vold keys, so
drop every key-management call; the surrounding Java code carries on as if
they succeeded. Pixel's services.jar also has the AIDL classes themselves
(IVold$Stub.onTransact dispatches to a local implementation, which the guest
never is); they are left alone.

Usage: guest_no_vold_keys.py <smali root dir>
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import re
import sys

CALLS = re.compile(
    r"^\s*invoke-interface \{[^}]*\}, Landroid/os/IVold;->"
    r"(createUserStorageKeys|destroyUserStorageKeys|setCeStorageProtection|"
    r"unlockCeStorage|lockCeStorage)\([^)]*\)V\s*$"
)


def main(root):
    changed_dirs = set()
    removed = 0
    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".smali"):
                continue
            path = os.path.join(dirpath, name)
            if os.path.relpath(path, root).split(os.sep, 1)[-1].startswith(os.path.join("android", "os", "IVold")):
                continue  # the AIDL classes themselves
            with open(path) as f:
                lines = f.read().split("\n")
            out = []
            dirty = False
            for line in lines:
                m = CALLS.match(line)
                if m:
                    out.append(f"    # OneOS: IVold.{m.group(1)} dropped (host vold holds One UI's keys)")
                    dirty = True
                    removed += 1
                    print(f"{os.path.relpath(path, root)}: {m.group(1)}", file=sys.stderr)
                else:
                    out.append(line)
            if dirty:
                with open(path, "w") as f:
                    f.write("\n".join(out))
                changed_dirs.add(os.path.relpath(path, root).split(os.sep)[0])
    if removed != 5:
        sys.exit(f"expected 5 IVold key calls, found {removed}")
    for d in sorted(changed_dirs):
        print(d)


if __name__ == "__main__":
    main(sys.argv[1])
