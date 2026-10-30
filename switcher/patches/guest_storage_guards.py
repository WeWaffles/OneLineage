"""Keep the guest framework from deleting or rewriting the phone's data.

The container shares the host's binder services. installd, keystore2 and (until
the guest's own vold registers) vold are One UI's, and they act on One UI's
real /data. In run 25 ColorOS could not prepare storage for user 0 (its vold
has no keys), so UserDataPreparer did what Android does on a broken first boot:
destroyUserData(0) through the host installd, which deleted One UI's app data
and shared storage, then rebootPromptAndWipeUserData(), which the power guards
refused (and system_server crashed on the refusal).

The guest's data is a staged tree that guest_prepare.sh builds and bridges,
so none of these operations is needed in the container:

1. Drop every void IVold / IInstalld call that destroys, wipes, moves or
   formats data, or that prepares user storage (the staged tree has it).
2. Drop the keystore2 maintenance calls that clear or re-key whole users or
   uid namespaces (guest and host uids overlap); callers see success (0).
3. UserDataPreparer (services.jar): destroyUserDataLI returns at entry, and the
   "wipe after a failed first boot" call becomes a log line.
5. StorageStatsService.isQuotaSupported (services.jar) returns false: run 29's
   "Settings > About" crash came from a misrouted installd quota query, and
   quota stats on the host count One UI's files anyway.
4. StorageManagerService.isCeStorageUnlocked (services.jar) returns true. The
   guest's user data is a plain staged directory with nothing to unlock, and
   its vold (which has no keys, by design) never reports it unlocked, so
   UserController stopped at finishUserUnlocking and user 0 stayed
   RUNNING_LOCKED (run 27: no BOOT_COMPLETED, most apps unable to start).

Pixel's services.jar (R8): destroyUserDataLI is public and the wipe call takes
p registers; it also carries the IVold/IInstalld AIDL classes, whose
Stub.onTransact dispatches to a local implementation (never the guest) and is
left alone.

Usage: guest_storage_guards.py <smali root dir>
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import re
import sys

VOLD = ("destroyUserStorage", "prepareUserStorage", "format", "partition",
        "forgetPartition", "moveStorage", "onUserRemoved", "abortChanges",
        "startCheckpoint", "shutdown", "sdlockErase")
INSTALLD = ("destroyUserData", "destroyAppData", "clearAppData",
            "clearAppDataWithPreservedCacheEntries", "destroyAppDataSnapshot",
            "destroyCeSnapshotsNotSpecified", "destroyPccData", "rmPackageDir",
            "cleanupInvalidPackageDirs", "moveCompleteApp", "moveAppDataPath",
            "copyAppDataPath", "migrateAppData", "restoreAppDataSnapshot",
            "onPrivateVolumeRemoved", "freeCache", "reconcileSdkData")
KEYSTORE = ("clearNamespace", "onUserRemoved", "onUserLskfRemoved", "onUserAdded",
            "migrateKeyNamespace", "initUserSuperKeys", "deleteAllKeys")

VOID_CALL = re.compile(
    r"^\s*invoke-interface(?:/range)? \{[^}]*\}, Landroid/os/(IVold|IInstalld);->(\w+)\([^)]*\)V\s*$")
KEYSTORE_CALL = re.compile(
    r"^\s*invoke-static(?:/range)? \{[^}]*\}, Landroid/security/AndroidKeyStoreMaintenance;->(\w+)\([^)]*\)([IV])\s*$")

PREPARER = os.path.join("com", "android", "server", "pm", "UserDataPreparer.smali")
SMS = os.path.join("com", "android", "server", "StorageManagerService.smali")
SSS = os.path.join("com", "android", "server", "usage", "StorageStatsService.smali")
QUOTA = ".method public isQuotaSupported(Ljava/lang/String;Ljava/lang/String;)Z"
CE_UNLOCKED = ".method public isCeStorageUnlocked(I)Z"
DESTROY_LI = re.compile(r"^\.method (?:public |final )*destroyUserDataLI\(Ljava/lang/String;II\)V$")
WIPE = re.compile(
    r"^(\s*)invoke-static \{([vp]\d+), ([vp]\d+)\}, Landroid/os/RecoverySystem;->"
    r"rebootPromptAndWipeUserData\(Landroid/content/Context;Ljava/lang/String;\)V\s*$")


def guard_calls(lines, rel, counts):
    dirty = False
    for i, line in enumerate(lines):
        m = VOID_CALL.match(line)
        if m and m.group(2) in (VOLD if m.group(1) == "IVold" else INSTALLD):
            # A nop, not nothing: a dropped call can be the only instruction of a
            # try block, and ART rejects an empty try range (VerifyError, run 26).
            lines[i] = f"    # OneOS: {m.group(1)}.{m.group(2)} dropped (would act on the phone's data)\n    nop"
            key = f"{m.group(1)}.{m.group(2)}"
        else:
            m = KEYSTORE_CALL.match(line)
            if not m or m.group(1) not in KEYSTORE:
                continue
            lines[i] = f"    # OneOS: AndroidKeyStoreMaintenance.{m.group(1)} dropped (shared keystore2)\n    nop"
            if m.group(2) == "I":
                # The result, if used, reads as success. Any register: Pixel's
                # R8 code takes it in p3 (run 40: a move-result left without its
                # call, VerifyError, LockSettingsService never started).
                for j in range(i + 1, len(lines)):
                    s = lines[j].strip()
                    if not s or s.startswith("."):
                        continue
                    r = re.match(r"move-result ([vp]\d+)$", s)
                    if r:
                        lines[j] = f"    const/4 {r.group(1)}, 0x0"
                    elif s.startswith("move-result"):
                        sys.exit(f"{rel}: AndroidKeyStoreMaintenance.{m.group(1)}: unexpected {s!r} after the dropped call")
                    break
            key = f"AndroidKeyStoreMaintenance.{m.group(1)}"
        counts[key] = counts.get(key, 0) + 1
        dirty = True
        print(f"{rel}: {key} dropped", file=sys.stderr)
    return dirty


def guard_preparer(lines):
    idx = [i for i, l in enumerate(lines) if DESTROY_LI.match(l)]
    if len(idx) != 1:
        sys.exit("UserDataPreparer.destroyUserDataLI not found exactly once")
    j = idx[0] + 1
    while lines[j].strip() == "" or lines[j].lstrip().startswith((".locals", ".param")):
        j += 1
    lines[j:j] = ["", "    # OneOS: never destroy user data from the container.", "    return-void", ""]
    wipes = 0
    for i, line in enumerate(lines):
        m = WIPE.match(line)
        if not m:
            continue
        ind, ctx, msg = m.groups()
        lines[i] = (f'{ind}const-string {ctx}, "OneOS"\n\n'
                    f"{ind}invoke-static {{{ctx}, {msg}}}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I")
        wipes += 1
    if wipes != 1:
        sys.exit(f"UserDataPreparer: expected one rebootPromptAndWipeUserData call, found {wipes}")
    print("UserDataPreparer: destroyUserDataLI disabled, wipe request logged instead", file=sys.stderr)


def guard_ce_unlocked(lines):
    idx = [i for i, l in enumerate(lines) if l == CE_UNLOCKED]
    if len(idx) != 1:
        sys.exit("StorageManagerService.isCeStorageUnlocked not found exactly once")
    j = idx[0] + 1
    while lines[j].strip() == "" or lines[j].lstrip().startswith((".locals", ".param")):
        j += 1
    lines[j:j] = ["", "    # OneOS: the staged user data has no encryption to unlock.",
                  "    const/4 v0, 0x1", "", "    return v0", ""]
    print("StorageManagerService.isCeStorageUnlocked: always true", file=sys.stderr)


def guard_no_quota(lines):
    idx = [i for i, l in enumerate(lines) if l == QUOTA]
    if len(idx) != 1:
        sys.exit("StorageStatsService.isQuotaSupported not found exactly once")
    j = idx[0] + 1
    while lines[j].strip() == "" or lines[j].lstrip().startswith((".locals", ".param")):
        j += 1
    lines[j:j] = ["", "    # OneOS: no quota stats in the container: the host installd's quotas count One UI's",
                  "    # files, and the guest's freeCache is dropped, so getFreeBytes uses statfs only.",
                  "    const/4 v0, 0x0", "", "    return v0", ""]
    print("StorageStatsService.isQuotaSupported: always false", file=sys.stderr)


def main(root):
    changed_dirs = set()
    counts = {}
    preparer_done = False
    quota_done = False
    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".smali"):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            if rel.split(os.sep, 1)[-1].startswith((os.path.join("android", "os", "IVold"),
                                                    os.path.join("android", "os", "IInstalld"))):
                continue  # the AIDL classes themselves
            with open(path) as f:
                lines = f.read().split("\n")
            dirty = guard_calls(lines, rel, counts)
            if rel.endswith(PREPARER):
                guard_preparer(lines)
                preparer_done = dirty = True
            if rel.endswith(os.sep + SMS) or rel == SMS:
                guard_ce_unlocked(lines)
                dirty = True
            if rel.endswith(os.sep + SSS):
                guard_no_quota(lines)
                quota_done = dirty = True
            if dirty:
                with open(path, "w") as f:
                    f.write("\n".join(lines))
                changed_dirs.add(rel.split(os.sep)[0])
    if preparer_done and not quota_done:
        sys.exit("services.jar: StorageStatsService.isQuotaSupported not found")
    if preparer_done:
        # services.jar: the calls that did the damage in run 25 must be gone.
        for key in ("IInstalld.destroyUserData", "IVold.destroyUserStorage",
                    "IVold.prepareUserStorage", "AndroidKeyStoreMaintenance.clearNamespace"):
            if key not in counts:
                sys.exit(f"services.jar: {key} not found")
    print(f"dropped {sum(counts.values())} calls: "
          + ", ".join(f"{k} x{v}" for k, v in sorted(counts.items())), file=sys.stderr)
    for d in sorted(changed_dirs):
        print(d)


if __name__ == "__main__":
    main(sys.argv[1])
