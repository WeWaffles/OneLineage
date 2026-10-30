"""Point the guest framework at the guest's own vold, registered as "gvld".

Up to run 43 the guest vold registered "vold" (and android.system.vold.IVold/
default) in the shared servicemanager, over One UI's. One UI's vold kept
running without its names and cannot be restarted (init.rc:
reboot_on_failure), so only a reboot gave One UI its storage back.
scripts/make-overlays.sh builds vold_patched, which registers "gvld" and skips
the vendor name, and a service.incremental.so that looks up "gvld"
(docs/inplace-return.md). This does the same for services.jar:

1. The three "vold" lookups become "gvld": StorageManagerService.connectVold,
   StorageManagerService$StorageManagerInternalImpl.prepareStorageDirs and
   StatsPullAtomService.getIVoldService. Fails unless those three change
   (plus, in some builds, the OPTIONAL ones below) and services.jar has no
   other "vold" string.
2. Fails if services.jar still calls RecoverySystem.rebootPromptAndWipeUserData.
   That framework.jar method (boot class path, not patched) runs
   checkService("vold") in the caller's process, which would now be One UI's
   vold: needsCheckpoint(), and during One UI's update checkpoint
   abortChanges(), which rolls the update back and reboots the phone. The only
   caller, UserDataPreparer's, is a log line since guest_storage_guards.py
   (run before this in make-overlays.sh). The only other caller the guest has,
   RescueParty's factory reset (crashrecovery APEX, pinned by make-overlays.sh),
   runs only while RescueParty is on; guest_start.sh refuses a gvld guest
   unless persist.sys.disable_rescue is true (oneos_switch.sh [1/6]).

3. With --oplus, the same for ColorOS's oplus-services.jar: its one "vold"
   lookup, OplusStorageManagerFeature.connectVold (OPPO's own IVold calls:
   DFS fuse, tmp storage, SD lock), becomes "gvld". Left as it was, those
   calls would reach One UI's vold, whose transaction codes are not OPPO's.

4. With --miui, the same for HyperOS's miui-services.jar: ExtendMImpl.connect
   (Xiaomi's memory extension, whose IVold calls - runExtMFlush and others -
   go by reflection with Xiaomi's transaction codes) and
   AppCacheOptimizer.connectVold. miui_guards.py runs first: its factory
   resets (RescuePartyXM) are the jar's only rebootPromptAndWipeUserData
   callers.

make-overlays.sh runs this only when it built vold_patched (Pixel 17 and
ColorOS 17 CP2A.260605.016); other images keep "vold".

Usage: guest_own_vold.py [--oplus | --miui] <smali root dir>
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import re
import sys

NAME = re.compile(r'^(\s*const-string(?:/jumbo)? ([vp]\d+), )"vold"\s*$')
LOOKUP = re.compile(r"^\s*invoke-static \{([vp]\d+)\}, Landroid/os/ServiceManager;->"
                    r"(getService|getServiceOrThrow|checkService|waitForService)\(Ljava/lang/String;\)Landroid/os/IBinder;\s*$")
WANT = {
    ("com/android/server/StorageManagerService", "connectVold"),
    ("com/android/server/StorageManagerService$StorageManagerInternalImpl", "prepareStorageDirs"),
    ("com/android/server/stats/pull/StatsPullAtomService", "getIVoldService"),
}
# Lookups some builds add (Infinity-X 4.1): a shell command's read
# (checkNonCeStorageKeys) and ExtendedWipeWithoutReboot.run, which
# guest_no_wipe_secrets.py (run before this) makes return at entry. Both may
# take "gvld" too; WANT must still be there.
OPTIONAL = {
    ("com/android/server/locksettings/LockSettingsShellCommand", "handleCheckNonCeStorageKeys"),
    ("com/android/server/recoverysystem/ExtendedWipeWithoutReboot", "run"),
}
WANT_OPLUS = {
    ("com/android/server/storage/OplusStorageManagerFeature", "connectVold"),
}
WANT_MIUI = {
    ("com/android/server/ExtendMImpl", "connect"),
    ("com/android/server/appcacheopt/AppCacheOptimizer", "connectVold"),
}
WIPE = "Landroid/os/RecoverySystem;->rebootPromptAndWipeUserData("


def main(root, want, jar, optional=frozenset()):
    # Written only once every file has passed (a failed run leaves the tree as it was).
    pending, sites = {}, set()
    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".smali"):
                continue
            path = os.path.join(dirpath, name)
            with open(path) as f:
                text = f.read()
            if '"vold"' not in text and WIPE not in text:
                continue
            rel = os.path.relpath(path, root)
            cls = rel.split(os.sep, 1)[1][:-len(".smali")].replace(os.sep, "/")
            lines = text.split("\n")
            method = None
            dirty = False
            for i, line in enumerate(lines):
                s = line.strip()
                if s.startswith(".method "):
                    method = s.split()[-1].split("(")[0]
                if s.startswith("#"):
                    continue
                if WIPE in line:
                    sys.exit(f"{cls}.{method}: RecoverySystem.rebootPromptAndWipeUserData is still called "
                             f'(its checkService("vold") is One UI\'s vold now; guest_storage_guards.py first), not patching')
                m = NAME.match(line)
                if not m:
                    # A local or parameter called vold is debug info, not a name.
                    if '"vold"' in line and not s.startswith((".local", ".end local", ".restart local", ".param")):
                        sys.exit(f'{cls}.{method}: "vold" used other than as a lookup name, not patching')
                    continue
                # The next instruction must be the lookup that takes this register.
                nxt = [l for l in lines[i + 1:i + 8] if l.strip() and not l.strip().startswith(".line")]
                lk = LOOKUP.match(nxt[0]) if nxt else None
                if not lk or lk.group(1) != m.group(2):
                    sys.exit(f'{cls}.{method}: "vold" not used for a ServiceManager lookup, not patching')
                if (cls, method) in sites:
                    sys.exit(f'{cls}.{method}: two "vold" lookups, not patching')
                sites.add((cls, method))
                lines[i] = (f'    # OneOS: the guest vold registers "gvld" (vold_patched); "vold" stays One UI\'s\n'
                            f'{m.group(1)}"gvld"')
                dirty = True
                print(f'{cls}.{method}: {lk.group(2)}("vold") -> "gvld"', file=sys.stderr)
            if dirty:
                pending[path] = "\n".join(lines)
    if not want <= sites or not sites - want <= optional:
        sys.exit(f'expected the "vold" lookups {sorted(want)}, found {sorted(sites)}')
    for path, text in pending.items():
        with open(path, "w") as f:
            f.write(text)
    print(f"{jar}: no RecoverySystem.rebootPromptAndWipeUserData call left", file=sys.stderr)
    for d in sorted({os.path.relpath(path, root).split(os.sep)[0] for path in pending}):
        print(d)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--oplus"]:
        main(sys.argv[2], WANT_OPLUS, "oplus-services.jar")
    elif sys.argv[1:2] == ["--miui"]:
        main(sys.argv[2], WANT_MIUI, "miui-services.jar")
    else:
        main(sys.argv[1], WANT, "services.jar", OPTIONAL)
