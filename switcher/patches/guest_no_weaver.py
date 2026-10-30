"""Keep the guest's lock settings away from the phone's weaver hardware.

The container shares the host's HALs, so the guest framework's weaver (the
secure element / TEE slots that protect every user's synthetic password) is
the one One UI's own protectors live in. ColorOS's SyntheticPasswordManager
knows no protectors (its /data is the stage's), picks the first weaver slot it
considers free and enrolls user 0's synthetic password there: slot 0, which
on a phone that was never reset is One UI's live slot. The friend's S25 Ultra
(session f075d93a, 2026-10-23) then came back from ColorOS unable to unlock
user 0's credential-encrypted storage ("Phone restarted - unlock your phone",
Direct Boot state, nothing to enter: no lock was set), and had to be reset.
The owner's Fold was spared only because its live protector sits in slot 2.

Make getWeaverServiceLocked() return null: the framework then takes the
"device has no weaver" paths (gatekeeper or software-only protectors, as on
phones without weaver) and never enrolls, reads or writes a slot.
guest_prepare.sh clears a guest lock state that still has weaver records.

Pixel's services.jar (R8) has the same method as public final. Every weaver
lookup there goes through it as well: getWeaverService() calls it, and
getWeaverServiceInternal() (AIDL, then HIDL) is called only from it.

Usage: guest_no_weaver.py <smali root dir>
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import re
import sys

HEADER = re.compile(r"^\.method (?:private |public |final )*getWeaverServiceLocked\(\)Landroid/hardware/weaver/IWeaver;$")


def main(root):
    changed = set()
    for dirpath, _, files in os.walk(root):
        if "SyntheticPasswordManager.smali" not in files:
            continue
        path = os.path.join(dirpath, "SyntheticPasswordManager.smali")
        lines = open(path).read().split("\n")
        if not any(l.startswith(".class ") and l.endswith("Lcom/android/server/locksettings/SyntheticPasswordManager;") for l in lines):
            continue
        heads = [k for k, l in enumerate(lines) if HEADER.match(l)]
        if len(heads) != 1:
            sys.exit(f"{path}: getWeaverServiceLocked() found {len(heads)} times, expected once")
        i = heads[0]
        m = re.match(r"\s*\.locals (\d+)$", lines[i + 1])
        if not m or int(m.group(1)) < 2:
            sys.exit(f"{path}: unexpected getWeaverServiceLocked header")
        j = i + 2
        while lines[j].strip() == "" or lines[j].lstrip().startswith((".param", ".end param")):
            j += 1
        lines[j:j] = [
            "    # OneOS: the weaver slots belong to One UI's protectors; the guest never gets the service.",
            '    const-string v0, "SyntheticPasswordManager"',
            "",
            '    const-string v1, "OneOS: weaver is the host\'s; the guest keeps software protectors"',
            "",
            "    invoke-static {v0, v1}, Landroid/util/Slog;->i(Ljava/lang/String;Ljava/lang/String;)I",
            "",
            "    const/4 v0, 0x0",
            "",
            "    return-object v0",
            "",
        ]
        open(path, "w").write("\n".join(lines))
        changed.add(os.path.relpath(path, root).split(os.sep)[0])
        print(f"{os.path.relpath(path, root)}: getWeaverServiceLocked() returns null", file=sys.stderr)
    if not changed:
        sys.exit("SyntheticPasswordManager not found")
    for d in sorted(changed):
        print(d)


if __name__ == "__main__":
    main(sys.argv[1])
