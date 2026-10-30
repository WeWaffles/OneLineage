"""Fix two ColorOS (oplus-services.jar) boot-completion problems in the container.

1. GameGpuControlPanel.onBootCompleted preloads game GPU profiles through
   libupdateprof.qti.so, which waits (no timeout) for Qualcomm's QSPM HAL. The
   Samsung vendor has none, the wait runs on the android.display thread, and
   the watchdog killed system_server after 68 s right after the boot
   animation ended (run 24). Make it return at entry.
2. ActivityManagerServiceExtImpl.waitForDumpCondition starts the OPPO init
   service "dumpenvironment" while writing a watchdog report. The host's init
   has no such service, setprop ctl.start throws, and that exception itself
   took system_server down. Drop the ctl.start; the method then just waits
   for its own timeout.

3. AppErrorsExtImpl.notifyZygoteProcessAppCrashed moves an app that crashed
   three times to OPPO's zygote_ocomp. Nothing starts that zygote in the
   container, and system_server's process-start thread polled its socket for
   62 s: no app could start, the home screen stayed black (run 28). Make it
   return at entry (oneos_switch.sh also turns the controller off).

4. KeyGestureControllerExtlmpl.getTpInfo (PhoneWindowManagerExtImpl's in the
   ColorOS 16 jar Infinity-X carries; every Power + Volume Down screenshot)
   and StrategyBlackscreenshot.getTpInfo (Volume Up + Volume Down with the
   screen off) start the OPPO init service "gettpinfo". The host's init has
   none, setprop ctl.start threw on android.display and system_server killed
   itself 10 s later (run 33, 14:59:19.710 -> 14:59:29.749). Drop the set; the
   window dumps after it stay.

Usage: oplus_boot_hangs.py <smali root dir>
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import sys

GAME_HEADER = ".method public onBootCompleted(Landroid/content/Context;Landroid/os/Handler;)V"
DUMP_START = """    const-string v0, "ctl.start"

    const-string v2, "dumpenvironment"

    invoke-static {v0, v2}, Landroid/os/SystemProperties;->set(Ljava/lang/String;Ljava/lang/String;)V
"""


def find(root, rel_suffix):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(rel_suffix)]
    if len(hits) != 1:
        sys.exit(f"expected exactly one {rel_suffix}, found {len(hits)}")
    return hits[0]


def top_dir(root, path):
    return os.path.relpath(path, root).split(os.sep)[0]


def fix_game_gpu(root):
    path = find(root, os.path.join("com", "android", "server", "app", "features", "GameGpuControlPanel.smali"))
    lines = open(path).read().split("\n")
    idx = [i for i, l in enumerate(lines) if l == GAME_HEADER]
    if len(idx) != 1 or lines[idx[0] + 1] != "    .locals 2":
        sys.exit("GameGpuControlPanel.onBootCompleted not found as expected")
    j = idx[0] + 2
    while j < len(lines) and (lines[j].strip() == "" or lines[j].lstrip().startswith(".param")):
        j += 1
    lines[j:j] = [
        "",
        "    # OneOS: no QSPM HAL on this vendor; the wait for it hung android.display.",
        '    const-string v0, "OneOS"',
        "",
        '    const-string v1, "GameGpuControlPanel.onBootCompleted skipped"',
        "",
        "    invoke-static {v0, v1}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I",
        "",
        "    return-void",
        "",
    ]
    open(path, "w").write("\n".join(lines))
    print("GameGpuControlPanel.onBootCompleted: skipped", file=sys.stderr)
    return top_dir(root, path)


def fix_dump_environment(root):
    """Drop every ctl.start dumpenvironment (ActivityManagerServiceExtImpl,
    OplusAmsUtils, OplusAmsUtilsFeatrue, BootReceiverExtImpl): the same throw
    from any of them would take system_server down."""
    dirs = set()
    count = 0
    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".smali"):
                continue
            path = os.path.join(dirpath, name)
            smali = open(path).read()
            n = smali.count(DUMP_START)
            if not n:
                continue
            smali = smali.replace(DUMP_START, "    # OneOS: no dumpenvironment service in the host's init; ctl.start threw.\n")
            open(path, "w").write(smali)
            count += n
            dirs.add(top_dir(root, path))
            print(f"{name}: ctl.start dumpenvironment dropped ({n})", file=sys.stderr)
    if count != 4:
        sys.exit(f"expected 4 ctl.start dumpenvironment calls, found {count}")
    return dirs


def fix_alt_zygote(root):
    path = find(root, os.path.join("com", "android", "server", "am", "AppErrorsExtImpl.smali"))
    lines = open(path).read().split("\n")
    header = ".method private notifyZygoteProcessAppCrashed(Landroid/content/Context;Lcom/android/server/am/ProcessRecord;)V"
    idx = [i for i, l in enumerate(lines) if l == header]
    if len(idx) != 1 or not lines[idx[0] + 1].startswith("    .locals "):
        sys.exit("AppErrorsExtImpl.notifyZygoteProcessAppCrashed not found as expected")
    j = idx[0] + 2
    while j < len(lines) and (lines[j].strip() == "" or lines[j].lstrip().startswith(".param")):
        j += 1
    lines[j:j] = ["", "    # OneOS: no zygote_ocomp in the container; its fallback stalled app starts.",
                  "    return-void", ""]
    open(path, "w").write("\n".join(lines))
    print("AppErrorsExtImpl.notifyZygoteProcessAppCrashed: alt zygote fallback skipped", file=sys.stderr)
    return top_dir(root, path)


TP_SET = "    invoke-static {p1, p2}, Landroid/os/SystemProperties;->set(Ljava/lang/String;Ljava/lang/String;)V"


def fix_tp_info(root):
    """Drop the setprop in both getTpInfo(key, val) methods; their only callers
    pass ctl.start gettpinfo."""
    dirs = set()
    # The key gesture one is KeyGestureControllerExtlmpl's in ColorOS 17 and
    # PhoneWindowManagerExtImpl's in the ColorOS 16 jar Infinity-X carries.
    key_gesture = [os.path.join("com", "android", "server", d, c + ".smali") for d, c in
                   (("input", "KeyGestureControllerExtlmpl"), ("policy", "PhoneWindowManagerExtImpl"))]
    public = ".method public getTpInfo(Ljava/lang/String;Ljava/lang/String;)V"
    has = [rel for rel in key_gesture if public in open(find(root, rel)).read().split("\n")]
    if not has:
        sys.exit(f"getTpInfo not found in any of {key_gesture}")
    # Both files may carry getTpInfo (X9 Ultra IN build has it in each).
    to_patch = [(rel, public) for rel in has]
    to_patch.append((os.path.join("com", "android", "server", "policy", "StrategyBlackscreenshot.smali"),
                     ".method private getTpInfo(Ljava/lang/String;Ljava/lang/String;)V"))
    for rel, header in to_patch:
        path = find(root, rel)
        lines = open(path).read().split("\n")
        idx = [i for i, l in enumerate(lines) if l == header]
        if len(idx) != 1:
            sys.exit(f"{rel}: getTpInfo not found as expected")
        end = lines.index(".end method", idx[0])
        hits = [i for i in range(idx[0], end) if lines[i] == TP_SET]
        if len(hits) != 1:
            sys.exit(f"{rel}: expected one SystemProperties.set in getTpInfo, found {len(hits)}")
        lines[hits[0]] = "    # OneOS: no gettpinfo service in the host's init; ctl.start threw (run 33)."
        open(path, "w").write("\n".join(lines))
        print(f"{os.path.basename(path)}: ctl.start gettpinfo dropped", file=sys.stderr)
        dirs.add(top_dir(root, path))
    return dirs


def main(root):
    for d in sorted({fix_game_gpu(root), fix_alt_zygote(root)} | fix_dump_environment(root) | fix_tp_info(root)):
        print(d)


if __name__ == "__main__":
    main(sys.argv[1])
