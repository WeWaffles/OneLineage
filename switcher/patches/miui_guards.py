"""Keep HyperOS's own framework (miui-services.jar) away from the phone.

services.jar carries OneOS's guards for the AOSP paths; Xiaomi's
miui-services.jar runs in the same system_server and has copies and helpers
that reach the phone without going through them (audit of the Xiaomi 18 Fold
build OS4.0.26.0.XPNCNXM, 2026-10-25; docs/hyperos.md):

- recovery: SystemServerImpl.rebootIntoRecovery writes a recovery command with
  BcbUtil.setupBcb and sets sys.powerctl reboot,recovery; BcbUtil is a copy of
  RecoverySystemService's boot control block code (ctl.start setup-bcb /
  clear-bcb and the uncrypt socket) talking to the phone's init directly.
- factory resets: RescuePartyXM.executeFactoryReset and its Runnable
  (RecoverySystem.rebootPromptAndWipeUserData), MiuiInitServer.doFactoryReset,
  LiteFactoryResetImpl.startLiteFactoryReset.
- reboots: RescuePartyImpl sets sys.powerctl itself ("Config Reset").
- init: ShutdownThreadImpl.showShutdownAnimOrDialog sets service.bootanim.exit
  0 and ctl.start bootanim; the guest shares One UI's init, which would start
  One UI's boot animation (over One UI after the return).
- packages: MiuiInitServer.deletePackagesByRegion (from its constructor), the
  preinstall copiers and installers (PreinstallApp, MiuiPreinstallHelper),
  which install, rename, delete and uninstall in /data/app, One UI's in a
  session, and MiuiPreinstallHelper's background job, which removes native
  libraries there.
- vold: ExtendMImpl's memory extension and MiuiGcImproveImpl's
  IVold.setDiscardIoAwareGran (a Xiaomi vold method).
- netd: MiuiNetworkManagementService sends Xiaomi's own IOemNetd methods
  (firewall rules, QoS, Wi-Fi limits, setPidForPackage for every new process)
  to the phone's netd, which is One UI's and implements AOSP's IOemNetd only.
  Its replies stopped app processes from starting and took system_server down
  (Z Fold8 Ultra, 2026-10-25: IllegalArgumentException in enableWmmer from
  MiuiNetworkPolicyManagerService.systemReady), and a Xiaomi transaction code
  could match a Samsung method. Every method of the class that uses IOemNetd,
  directly or by reflection, returns at entry (0 or false); setOemNetd keeps
  no binder, so nothing Xiaomi-specific reaches One UI's netd.

Each method becomes a bare return (false or 0 for the ones with a result); RescuePartyImpl's
sys.powerctl becomes oneos.guest.powerctl like PowerManagerService's
(guest_power_guards.py); the IVold call and the two bootanim setprops are dropped. Every target must be
found exactly once, or nothing is written (fail closed).

apprecovery.proinstaller.jar (also on system_server's class path): its
InstallService installs apps by itself (auto_install) into /data/app; with
--proinstaller its onStart and installApks return at entry (installApks is
reached from onBootPhase, not from onStart, and it is what crashed the guest's
system_server on the S25 Ultra and S25 -- see the PROINSTALLER table).

Usage: miui_guards.py [--proinstaller] <apktool decoded jar directory>
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import re
import sys

# (class, method header, what the method returns)
RETURN_AT_ENTRY = [
    ("com/android/server/SystemServerImpl", ".method private static rebootIntoRecovery()V", "V"),
    ("com/android/server/BcbUtil", ".method private static setupOrClearBcb(ZLjava/lang/String;)Z", "Z"),
    ("com/android/server/RescuePartyXM", ".method private static executeFactoryReset(Landroid/content/Context;ILjava/lang/String;)V", "V"),
    # The same reset from the Runnable RescuePartyXM posts.
    ("com/android/server/RescuePartyXM$2", ".method public run()V", "V"),
    ("com/miui/server/MiuiInitServer", ".method public doFactoryReset(Z)V", "V"),
    ("com/miui/server/MiuiInitServer", ".method private deletePackagesByRegion()V", "V"),
    ("com/android/server/LiteFactoryResetImpl", ".method public startLiteFactoryReset()V", "V"),
    # Both copiers, for boot and first boot (PackageManagerServiceImpl.performPreinstallApp).
    ("com/android/server/pm/PreinstallApp", ".method public static copyPreinstallApps(Lcom/android/server/pm/PackageManagerService;Lcom/android/server/pm/Settings;)V", "V"),
    ("com/android/server/pm/PreinstallApp", ".method public static installCustApps(Landroid/content/Context;)V", "V"),
    ("com/android/server/pm/PreinstallApp", ".method public static installVanwardCustApps(Landroid/content/Context;)V", "V"),
    ("com/android/server/pm/MiuiPreinstallHelper", ".method public performLegacyCopyPreinstall()V", "V"),
    ("com/android/server/pm/MiuiPreinstallHelper", ".method public installCustApps()V", "V"),
    ("com/android/server/pm/MiuiPreinstallHelper", ".method public installVanwardApps()V", "V"),
    # BackgroundPreinstalloptService's job: removes native libraries under /data/app.
    ("com/android/server/pm/MiuiPreinstallHelper", ".method public onStartJob(Lcom/android/server/pm/BackgroundPreinstalloptService;Landroid/app/job/JobParameters;)Z", "Z"),
    ("com/android/server/pm/MiuiPreinstallHelper", ".method private batchInstallApps(Ljava/util/List;)V", "V"),
    ("com/android/server/pm/MiuiPreinstallHelper", ".method private copyLegacyPreisntallApp(Ljava/lang/String;Lcom/android/server/pm/pkg/PackageStateInternal;Landroid/content/pm/parsing/PackageLite;)V", "V"),
    ("com/android/server/pm/MiuiPreinstallHelper", ".method private copyMiuiPreinstallApp(Ljava/lang/String;Lcom/android/server/pm/pkg/PackageStateInternal;Lcom/android/internal/pm/parsing/pkg/ParsedPackage;)V", "V"),
    ("com/android/server/pm/MiuiPreinstallHelper", ".method public deleteArtifactsForPreinstall(Lcom/android/server/pm/PackageSetting;ZI)V", "V"),
    ("com/android/server/ExtendMImpl", ".method private startExtM()V", "V"),
]
# HyperOS's "rust" packages (the launcher, Weather) start through hyos_spawner,
# which guest_start.sh starts itself (One UI's init has no such service). The
# fourth run's guard here (RustProcessManagerImpl at entry, so they started
# through zygote) could not work: their APKs have no dex, only a Flutter
# library the spawner runs, and the launcher died 1008 times (sixth run).
POWERCTL_CLASS = "com/android/server/RescuePartyImpl"
POWERCTL = '    const-string/jumbo v1, "sys.powerctl"'
POWERCTL_NEW = '    const-string/jumbo v1, "oneos.guest.powerctl"'
VOLD_CLASS = "com/android/server/MiuiGcImproveImpl"
VOLD_CALL = re.compile(r"^\s*invoke-interface \{v\d+, p\d+\}, Landroid/os/IVold;->setDiscardIoAwareGran\(I\)V\n", re.M)
BOOTANIM_CLASS = "com/android/server/power/ShutdownThreadImpl"
BOOTANIM = re.compile(r'^\s*const-string(?:/jumbo)? (v\d+), "service\.bootanim\.exit"\n\n?'
                      r'\s*const-string (v\d+), "0"\n\n?'
                      r'\s*invoke-static \{\1, \2\}, Landroid/os/SystemProperties;->set\(Ljava/lang/String;Ljava/lang/String;\)V\n\n?'
                      r'(?:\s*\.line \d+\n)?'
                      r'\s*const-string(?:/jumbo)? (v\d+), "ctl\.start"\n\n?'
                      r'\s*const-string (v\d+), "bootanim"\n\n?'
                      r'\s*invoke-static \{\3, \4\}, Landroid/os/SystemProperties;->set\(Ljava/lang/String;Ljava/lang/String;\)V\n', re.M)
LOCALS = re.compile(r"^(\s*)\.locals (\d+)$", re.M)


def find(root, cls):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(cls + ".smali")]
    if len(hits) != 1:
        sys.exit(f"{cls}: {len(hits)} classes found, expected one")
    return hits[0]


def return_at_entry(smali, header, kind, cls):
    """The method's code becomes a bare return; its annotations and .param
    lines stay. No dead code is left behind (guest_own_vold.py fails on any
    rebootPromptAndWipeUserData call it finds)."""
    if smali.count(header + "\n") != 1:
        sys.exit(f"{cls}: {header} not found exactly once")
    start = smali.index(header + "\n") + len(header) + 1
    end = smali.index(".end method", start)
    body = smali[start:end]
    if "oneos: returns at entry" in body:
        sys.exit(f"{cls}: {header} already patched")
    if not LOCALS.search(body):
        sys.exit(f"{cls}: {header} has no .locals")
    keep, block = [], None
    for line in body.split("\n"):
        s = line.strip()
        if block is not None:
            block.append(line)
            if s == ".end annotation":
                keep.append("\n".join(block))
                block = None
        elif s.startswith(".annotation "):
            block = [line]
        elif s.startswith(".param "):
            keep.append(line)
        elif s.startswith(".end param"):
            sys.exit(f"{cls}: {header} has a .param block, not patching")
    if block is not None:
        sys.exit(f"{cls}: {header} has an unterminated annotation")
    if kind == "V":
        code = ["    .locals 0", "    # oneos: returns at entry (miui_guards.py)", "    return-void"]
    elif kind in ("Z", "I"):
        code = ["    .locals 1", "    # oneos: returns at entry (miui_guards.py)", "    const/4 v0, 0x0", "", "    return v0"]
    elif kind == "J":
        code = ["    .locals 2", "    # oneos: returns at entry (miui_guards.py)", "    const-wide/16 v0, 0x0", "", "    return-wide v0"]
    elif kind == "throw":
        code = ["    .locals 2", "    # oneos: Xiaomi's IOemNetd method, never sent to One UI's netd (miui_guards.py)",
                "    new-instance v0, Landroid/os/RemoteException;", "",
                '    const-string v1, "OneOS: not sent to the phone\'s netd"', "",
                "    invoke-direct {v0, v1}, Landroid/os/RemoteException;-><init>(Ljava/lang/String;)V", "",
                "    throw v0"]
    else:
        sys.exit(f"unknown return kind {kind}")
    return smali[:start] + "\n".join(code[:1] + keep + [""] + code[1:]) + "\n" + smali[end:]


# The client every Xiaomi caller uses (MiuiNetworkManagementService here,
# MiuiOnelinkNetManagerService and MiuiNetPathOptimizerService in
# miui-wifi-service.jar): Xiaomi numbers its IOemNetd transactions its own way
# (enableWmmer is 2, AOSP's registerOemUnsolicitedEventListener; Xiaomi's
# register is 45), and One UI's netd ran a Samsung method for
# enableOnelinkNetSyncDrop (a NullPointerException came back and took
# system_server down, fourth run). Only isAlive (1) is the same. Every other
# transaction method throws RemoteException before anything is sent; AIDL
# callers must handle it.
OEMNETD_PROXY = "com/android/internal/net/IOemNetd$Stub$Proxy"
OEMNETD_PROXY_KEEP = ("<init>(", "asBinder(", "getInterfaceDescriptor(", "isAlive(")
OEMNETD_PROXY_METHODS = 54
OEMNETD_CLASS = "com/android/server/net/MiuiNetworkManagementService"
# The methods that use IOemNetd (25 calls on mNetd, 3 by reflection on
# IOemNetd$Stub), Xiaomi 18 Fold OS4.0.26.0.XPNCNXM. Another count stops the
# build: a new call would otherwise go to One UI's netd unnoticed.
OEMNETD_METHODS = 28
METHOD = re.compile(r"^\.method [^\n]*\)(\S+)\n.*?^\.end method\n", re.M | re.S)


def oemnetd_methods(smali):
    """(header, return kind) of every method that uses IOemNetd."""
    out = []
    for m in METHOD.finditer(smali):
        if "Lcom/android/internal/net/IOemNetd" not in m.group(0) and "com.android.internal.net.IOemNetd" not in m.group(0):
            continue
        header = m.group(0).split("\n", 1)[0]
        if " abstract " in header or " native " in header:
            sys.exit(f"{OEMNETD_CLASS}: {header} has no code")
        out.append((header, m.group(1)))
    return out


PROINSTALLER = [
    ("com/miui/me/server/auto_install/InstallService", ".method public onStart()V", "V"),
    # onStart was not the only way in: onBootPhase(520) posts InstallService$2 on
    # an AsyncTask, which calls installApks() whatever onStart did. That method is
    # the installer itself, so it belongs here -- and it also takes the guest's
    # system_server down. Its first act is
    #     if (listAutoAPkFile().isEmpty()) { install_status = -1;
    #                                        mInstallFinishListener.updateEvent(true); }
    # and mInstallFinishListener is assigned nowhere in the jar, so the empty case
    # is an NPE. On a Xiaomi phone /data/miui/app/auto holds the preinstall APKs
    # and the branch never runs; in the guest that directory does not exist, the
    # list is always empty, and the uncaught exception reaches
    # RuntimeInit$KillApplicationHandler, which kills system_server at boot phase
    # 520 -- about 50 s in, every time (S25 Ultra and S25 reports, 2026-10-30).
    ("com/miui/me/server/auto_install/InstallService", ".method private installApks()V", "V"),
]


def main(root, proinstaller=False):
    pending = {}
    def load(cls):
        path = find(root, cls)
        return path, pending.get(path, open(path).read())
    for cls, header, kind in (PROINSTALLER if proinstaller else RETURN_AT_ENTRY):
        path, smali = load(cls)
        pending[path] = return_at_entry(smali, header, kind, cls)
        print(f"{cls.rsplit('/', 1)[1]}.{header.split('(')[0].split()[-1]}: returns at entry", file=sys.stderr)
    if proinstaller:
        for path, smali in pending.items():
            open(path, "w").write(smali)
        for d in sorted({os.path.relpath(p, root).split(os.sep)[0] for p in pending}):
            print(d)
        return
    path, smali = load(POWERCTL_CLASS)
    if smali.count(POWERCTL) != 1:
        sys.exit(f"{POWERCTL_CLASS}: sys.powerctl set {smali.count(POWERCTL)} times, expected once")
    pending[path] = smali.replace(POWERCTL, POWERCTL_NEW)
    print("RescuePartyImpl: sys.powerctl -> oneos.guest.powerctl", file=sys.stderr)
    path, smali = load(VOLD_CLASS)
    if len(VOLD_CALL.findall(smali)) != 1:
        sys.exit(f"{VOLD_CLASS}: IVold.setDiscardIoAwareGran called {len(VOLD_CALL.findall(smali))} times, expected once")
    pending[path] = VOLD_CALL.sub("", smali)
    print("MiuiGcImproveImpl: IVold.setDiscardIoAwareGran dropped", file=sys.stderr)
    path, smali = load(OEMNETD_CLASS)
    found = oemnetd_methods(smali)
    if len(found) != OEMNETD_METHODS:
        sys.exit(f"{OEMNETD_CLASS}: {len(found)} methods use IOemNetd, expected {OEMNETD_METHODS}")
    for header, kind in found:
        if kind not in ("V", "Z", "I", "J"):
            sys.exit(f"{OEMNETD_CLASS}: {header} returns {kind}, not patched")
        smali = return_at_entry(smali, header, kind, OEMNETD_CLASS)
    if "Lcom/android/internal/net/IOemNetd;->" in smali or "IOemNetd$Stub;->asInterface" in smali:
        sys.exit(f"{OEMNETD_CLASS}: an IOemNetd call is left")
    pending[path] = smali
    print(f"MiuiNetworkManagementService: {len(found)} IOemNetd methods return at entry", file=sys.stderr)
    path, smali = load(OEMNETD_PROXY)
    headers = [l for l in smali.split("\n") if l.startswith(".method ")]
    if not any("isAlive()Z" in h for h in headers):
        sys.exit(f"{OEMNETD_PROXY}: no isAlive()")
    headers = [h for h in headers if not any(k in h for k in OEMNETD_PROXY_KEEP)]
    if len(headers) != OEMNETD_PROXY_METHODS:
        sys.exit(f"{OEMNETD_PROXY}: {len(headers)} methods to block, expected {OEMNETD_PROXY_METHODS}")
    for h in headers:
        if " abstract " in h or " native " in h:
            sys.exit(f"{OEMNETD_PROXY}: {h} has no code")
        smali = return_at_entry(smali, h, "throw", OEMNETD_PROXY)
    if smali.count("IBinder;->transact(") != 1:
        sys.exit(f"{OEMNETD_PROXY}: {smali.count('IBinder;->transact(')} transactions left, expected isAlive's")
    pending[path] = smali
    print(f"IOemNetd$Stub$Proxy: {len(headers)} Xiaomi methods throw RemoteException, isAlive kept", file=sys.stderr)
    path, smali = load(BOOTANIM_CLASS)
    if len(BOOTANIM.findall(smali)) != 1 or smali.count('"ctl.start"') != 1:
        sys.exit(f"{BOOTANIM_CLASS}: the bootanim setprops not found exactly once")
    pending[path] = BOOTANIM.sub("    # oneos: no service.bootanim.exit / ctl.start bootanim (One UI's init; miui_guards.py)\n", smali)
    print("ShutdownThreadImpl: ctl.start bootanim dropped", file=sys.stderr)
    # Everything checked: write.
    for path, smali in pending.items():
        open(path, "w").write(smali)
    for d in sorted({os.path.relpath(p, root).split(os.sep)[0] for p in pending}):
        print(d)


if __name__ == "__main__":
    args = sys.argv[1:]
    pro = "--proinstaller" in args
    args = [a for a in args if a != "--proinstaller"]
    if len(args) != 1:
        sys.exit("usage: miui_guards.py [--proinstaller] <decoded jar directory>")
    main(args[0], pro)
