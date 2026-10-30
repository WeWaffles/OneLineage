"""Make ColorOS's oplus-services stop waiting forever for OPPO-only services.

In the container on a Samsung vendor there are no OPPO HALs and none of the
OPPO daemons ColorOS's init would start. ServiceManager.waitForService() has no
timeout, so e.g. OplusEngineerFwService.onBootPhase() blocked system_server's
main thread until the watchdog killed it. Swap waitForService for
checkService (same signature, returns null at once when the service is
absent), except for services the host does provide. Most callers already
handle null; a caller that uses the binder unchecked (connectDefrag called
linkToDeath on it) gets a null check that returns from the method.

Usage: oplus_wait_for_service.py <smali root dir> [--only NAME,...]
With --only, only calls for those services are changed (services.jar: its
StorageManagerService waits for OPPO's DefragService too).
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import re
import sys

WAIT = "Landroid/os/ServiceManager;->waitForService(Ljava/lang/String;)Landroid/os/IBinder;"
CHECK = "Landroid/os/ServiceManager;->checkService(Ljava/lang/String;)Landroid/os/IBinder;"
# Services that do exist in the container: installd is the host's; cotaservice
# (cotad) is a ColorOS daemon guest_start.sh starts (with checkService,
# OplusOperatorManagerService got a null cotaservice and crashed on it).
# DefragService is not kept: oplus_defrag starts but its init fails in the
# container and it never registers.
KEEP = {"installd", "cotaservice"}


def guard_null(lines, i, label):
    """Unless the binder from the call at lines[i] is null-checked before its
    first use, make the (void) method return when it is null."""
    k = i + 1
    while not lines[k].strip().startswith("move-result-object"):
        k += 1
    reg = lines[k].split()[1]
    at = k + 1
    while lines[at].strip() == "" or lines[at].lstrip().startswith(".local"):
        at += 1
    for s in (l.strip() for l in lines[at:]):
        if not s or s.startswith(".") or s.startswith(":"):
            continue
        if re.match(rf"if-(eqz|nez) {re.escape(reg)},", s):
            return False
        if re.search(rf"[{{ ,]{re.escape(reg)}[,}} ]", s + " "):
            break
    m = next(l for l in reversed(lines[:i]) if l.startswith(".method "))
    if not m.endswith(")V"):
        sys.exit(f"unchecked binder in a non-void method: {m}")
    lines[at:at] = [f"    if-nez {reg}, :{label}", "", "    return-void", "", f"    :{label}", ""]
    return True


def main(root, only=None):
    changed_dirs = set()
    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".smali"):
                continue
            path = os.path.join(dirpath, name)
            with open(path) as f:
                lines = f.read().split("\n")
            dirty = False
            for i, line in enumerate(lines):
                if WAIT not in line:
                    continue
                # Name of the service: the nearest const-string above the call.
                target = None
                for j in range(i - 1, max(i - 15, -1), -1):
                    m = re.search(r'const-string(?:/jumbo)? \S+, "(.*)"', lines[j])
                    if m:
                        target = m.group(1)
                        break
                if target in KEEP or (only is not None and target not in only):
                    continue
                lines[i] = line.replace(WAIT, CHECK)
                dirty = True
                guarded = guard_null(lines, i, f"oneos_have_binder_{i}")
                print(f"{os.path.relpath(path, root)}: {target}"
                      + (" (null check added)" if guarded else ""), file=sys.stderr)
            if dirty:
                with open(path, "w") as f:
                    f.write("\n".join(lines))
                changed_dirs.add(os.path.relpath(path, root).split(os.sep)[0])
    for d in sorted(changed_dirs):
        print(d)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[2] == "--only":
        main(sys.argv[1], set(sys.argv[3].split(",")))
    else:
        main(sys.argv[1])
