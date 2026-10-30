"""Stop the guest framework from rebooting or shutting down the real phone.

The container shares the host's property area, so a guest reboot is a host
reboot. In run 23 ColorOS's ActivityManagerService.finishBooting asked the
container's vold to commit the boot checkpoint; that vold was started by hand
and never got needsCheckpoint/prepareCheckpoint, so commitChanges() threw and
finishBooting called PowerManager.reboot("Checkpoint commit failed").
ShutdownThread then shut down the modem subsystem and PowerManagerService
wrote sys.powerctl: the whole phone rebooted about 26 s after system_server
started. Three guards, all inside the guest's services.jar:

1. ActivityManagerService: drop the IStorageManager.commitChanges() call, so
   the try succeeds and the reboot in its catch is never reached.
2. ShutdownThread: the public entry points (reboot, shutdown, rebootSafeMode,
   rebootOrShutdown) log and return, so no shutdown sequence (and no modem
   teardown) runs for the guest.
3. PowerManagerService: the two writes of "sys.powerctl" go to
   "oneos.guest.powerctl" instead, so even a path missed above cannot reach
   init; the value records what the guest asked for.

Returning to One UI is unaffected: return_to_oneui.sh runs on the host.

Usage: guest_power_guards.py <smali root dir>
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import re
import sys

AMS_CALL = "    invoke-interface {v1}, Landroid/os/storage/IStorageManager;->commitChanges()V\n"
ENTRY_POINTS = [
    "reboot(Landroid/content/Context;Ljava/lang/String;Z)V",
    "rebootOrShutdown(Landroid/content/Context;ZLjava/lang/String;)V",
    "rebootSafeMode(Landroid/content/Context;Z)V",
    "shutdown(Landroid/content/Context;Ljava/lang/String;Z)V",
]
POWERCTL = 'const-string/jumbo {reg}, "sys.powerctl"'


def find(root, rel_suffix):
    hits = []
    for dirpath, _, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            if path.endswith(rel_suffix):
                hits.append(path)
    if len(hits) != 1:
        sys.exit(f"expected exactly one {rel_suffix}, found {len(hits)}")
    return hits[0]


def top_dir(root, path):
    return os.path.relpath(path, root).split(os.sep)[0]


def guard_ams(root):
    path = find(root, os.path.join("com", "android", "server", "am", "ActivityManagerService.smali"))
    smali = open(path).read()
    if smali.count(AMS_CALL) != 1:
        sys.exit("ActivityManagerService: expected one commitChanges() call")
    smali = smali.replace(AMS_CALL, "    # OneOS: IStorageManager.commitChanges() dropped (its failure reboots the shared phone)\n")
    open(path, "w").write(smali)
    print("ActivityManagerService: commitChanges dropped", file=sys.stderr)
    return top_dir(root, path)


def guard_shutdown_thread(root):
    path = find(root, os.path.join("com", "android", "server", "power", "ShutdownThread.smali"))
    lines = open(path).read().split("\n")
    for sig in ENTRY_POINTS:
        header = f".method public static {sig}"
        idx = [i for i, l in enumerate(lines) if l == header]
        if len(idx) != 1:
            sys.exit(f"ShutdownThread: {sig} not found exactly once")
        i = idx[0] + 1
        m = re.match(r"^    \.locals (\d+)$", lines[i])
        if not m:
            sys.exit(f"ShutdownThread: no .locals after {sig}")
        lines[i] = f"    .locals {max(int(m.group(1)), 2)}"
        # Insert after the .locals line and any .param/.annotation directives.
        j = i + 1
        while j < len(lines) and (lines[j].strip() == "" or lines[j].lstrip().startswith((".param", ".end param", ".annotation", ".end annotation", "value", "accessFlags", "names"))):
            if lines[j].lstrip().startswith(".param") or lines[j].lstrip().startswith(".annotation"):
                # skip whole directive blocks
                pass
            j += 1
        name = sig.split("(")[0]
        guard = [
            "",
            "    # OneOS: the guest must not reboot or shut down the shared phone. Record",
            "    # the request instead; the host watcher ends the session (and powers the",
            "    # phone off for a shutdown request).",
            '    const-string v0, "oneos.guest.powerctl"',
            "",
            f'    const-string v1, "{name}"',
            "",
            "    invoke-static {v0, v1}, Landroid/os/SystemProperties;->set(Ljava/lang/String;Ljava/lang/String;)V",
            "",
            '    const-string v0, "OneOS"',
            "",
            f'    const-string v1, "guest ShutdownThread.{name} blocked"',
            "",
            "    invoke-static {v0, v1}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I",
            "",
            "    return-void",
            "",
        ]
        lines[j:j] = guard
        print(f"ShutdownThread.{name}: guarded", file=sys.stderr)
    open(path, "w").write("\n".join(lines))
    return top_dir(root, path)


def guard_powerctl(root):
    path = find(root, os.path.join("com", "android", "server", "power", "PowerManagerService.smali"))
    smali = open(path).read()
    pattern = re.compile(r'const-string/jumbo (v\d+), "sys\.powerctl"')
    count = len(pattern.findall(smali))
    if count != 2:
        sys.exit(f"PowerManagerService: expected 2 sys.powerctl writes, found {count}")
    smali = pattern.sub(r'const-string/jumbo \1, "oneos.guest.powerctl"', smali)
    open(path, "w").write(smali)
    print("PowerManagerService: sys.powerctl -> oneos.guest.powerctl (2)", file=sys.stderr)
    return top_dir(root, path)


RECOVERY_METHODS = [
    "setupOrClearBcb(ZLjava/lang/String;)Z",
    "uncrypt(Ljava/lang/String;Landroid/os/IRecoverySystemProgressListener;)Z",
]


def guard_recovery(root):
    """No guest writes to the host's bootloader control block (misc).

    rebootRecoveryWithCommand() arms the BCB through ctl.start setup-bcb (the
    HOST's init service and /dev/socket/uncrypt) before rebooting, so with the
    reboot blocked the next host reboot would still boot recovery with the
    guest's command (--wipe_data from a guest factory reset). It also deletes
    keystore/secretkeeper secrets after a successful setup, on the host's
    shared services. Failing setupOrClearBcb/uncrypt stops both; the callers
    already handle false ("failed to setup BCB").
    """
    path = find(root, os.path.join("com", "android", "server", "recoverysystem", "RecoverySystemService.smali"))
    lines = open(path).read().split("\n")
    for sig in RECOVERY_METHODS:
        idx = [i for i, l in enumerate(lines) if l.startswith(".method ") and l.endswith(sig)]
        if len(idx) != 1:
            sys.exit(f"RecoverySystemService: {sig} not found exactly once")
        i = idx[0] + 1
        m = re.match(r"^    \.locals (\d+)$", lines[i])
        if not m or int(m.group(1)) < 2:
            sys.exit(f"RecoverySystemService: unexpected .locals after {sig}")
        j = i + 1
        while j < len(lines) and (lines[j].strip() == "" or lines[j].lstrip().startswith(".param")):
            j += 1
        name = sig.split("(")[0]
        lines[j:j] = [
            "",
            "    # OneOS: never arm the host's bootloader control block from the guest.",
            '    const-string v0, "OneOS"',
            "",
            f'    const-string v1, "guest RecoverySystemService.{name} blocked"',
            "",
            "    invoke-static {v0, v1}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I",
            "",
            "    const/4 v0, 0x0",
            "",
            "    return v0",
            "",
        ]
        print(f"RecoverySystemService.{name}: guarded", file=sys.stderr)
    open(path, "w").write("\n".join(lines))
    return top_dir(root, path)


def main(root):
    dirs = {guard_ams(root), guard_shutdown_thread(root), guard_powerctl(root), guard_recovery(root)}
    for d in sorted(dirs):
        print(d)


if __name__ == "__main__":
    main(sys.argv[1])
