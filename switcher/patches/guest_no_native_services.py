"""Never start a native-only service in the guest: its start fails at once.

Android 17 starts an isolated service declared android:nativeService
(ServiceRecord.mIsNativeIsolated: FLAG_NATIVE_SERVICE and FLAG_ISOLATED_PROCESS)
through zygote_next, NativeZygoteProcess's socket. The guest runs no zygote_next
of its own (a test that started the image's own lost every child it forked), so
the socket is One UI's. S25 Ultra, Pixel 9 Pro XL, app 0.4.25,
28 Oct: Chrome 152 bound its renderer, NativeOnlySandboxedProcessService0
(isolatedProcess, useAppZygote, nativeService, entry
NativeChildProcessService_onCreate in libmonochrome_64.so), and no process
started in the guest after it: the start thread waits for that start's reply,
Chrome's privileged_process0 (its network service: no data in Chrome) and every
app opened after it stayed on their logo (pid 0) until the return. On a Z Fold8
Ultra One UI's zygote_next forked the renderer in One UI's mount namespace
instead, and it crashed in minikin reading the guest's fonts.

ActiveServices.bringUpServiceInnerLocked starts the service's process with
ActivityManagerService.startProcessLocked(..., HostingRecord, ...) and, when
that returns null, logs "Unable to launch app ...: process is bad", brings the
service down and returns the message: bindService then returns false to the
app. The patch takes that path for a native-only service without calling
startProcessLocked, after a Slog.w naming it. Chrome binds its Java renderer
(SandboxedProcessService<n>) when the native one cannot be bound
(ChildProcessConnection's fallback service), and that one starts through the
guest's own zygote like any isolated service. Every app with a native-only
service gets the same refusal instead of a stuck phone. Chrome's manifest has no
Java class for the native-only names, so starting them without zygote_next
(clearing the flag) would only crash them.

Pixel's services.jar (R8) and ColorOS's both have the call; the patch finds the
ServiceRecord register from the last ServiceRecord field read before the call,
and the call's result register (not one of its arguments) takes the test's
result, through a static helper that reads the flag and logs (invoke/range and
move-result take any register).
A build without mIsNativeIsolated (no native-only services) is left as it is.

Usage: guest_no_native_services.py <smali root dir>
Prints the smali_* directory (dex file) it changed; exits non-zero if the build
has native-only services but the call is not where the patch expects it.
"""
import os
import re
import sys

CLS = "Lcom/android/server/am/ActiveServices;"
SR = "Lcom/android/server/am/ServiceRecord;"
FIELD = f"{SR}->mIsNativeIsolated:Z"
HEADER = re.compile(r"^\.method .*\bbringUpServiceInnerLocked\(" + re.escape(SR) + r"[^)]*\)Ljava/lang/String;$")
START = re.compile(r"^\s*invoke-virtual(/range)? \{([^}]*)\}, Lcom/android/server/am/ActivityManagerService;->"
                   r"startProcessLocked\(Ljava/lang/String;Landroid/content/pm/ApplicationInfo;ZILcom/android/server/am/HostingRecord;[^)]*\)"
                   r"Lcom/android/server/am/ProcessRecord;\s*$")
RESULT = re.compile(r"^\s*move-result-object ([vp]\d+)\s*$")
SR_READ = re.compile(r"^\s*iget(?:-[a-z]+)? [vp]\d+, ([vp]\d+), " + re.escape(SR) + r"->")
WRITES = re.compile(r"^\s*(?!invoke|if-|goto|return|throw|check-cast|monitor|filled|fill-array|packed|sparse|\.|:|#)"
                    r"[a-z/0-9-]+ ([vp]\d+)\b")
HELPER = f"""
.method private static oneosNativeRefused({SR})Z
    .locals 2

    iget-boolean v0, p0, {FIELD}

    if-eqz v0, :oneos_not_native

    invoke-static {{p0}}, Ljava/lang/String;->valueOf(Ljava/lang/Object;)Ljava/lang/String;

    move-result-object v0

    const-string v1, "OneOS: not starting native-only service (zygote_next is One UI's): "

    invoke-virtual {{v1, v0}}, Ljava/lang/String;->concat(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0

    const-string v1, "ActivityManager"

    invoke-static {{v1, v0}}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I

    const/4 v0, 0x1

    :oneos_not_native
    return v0
.end method
"""


def find(root):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(os.path.join("com", "android", "server", "am", "ActiveServices.smali"))]
    if len(hits) != 1:
        sys.exit(f"ActiveServices.smali: {len(hits)} matches")
    return hits[0]


def regs(spec, ranged):
    """The registers an invoke passes, as names."""
    if ranged:
        a, b = [r.strip() for r in spec.split("..")]
        if a[0] != b[0]:
            sys.exit(f"startProcessLocked: mixed range {spec}")
        return {f"{a[0]}{i}" for i in range(int(a[1:]), int(b[1:]) + 1)}
    return {r.strip() for r in spec.split(",") if r.strip()}


def main():
    root = sys.argv[1]
    has_field = any(FIELD in open(os.path.join(d, f), errors="replace").read()
                    for d, _, fs in os.walk(root) for f in fs
                    if f == "ServiceRecord.smali")
    if not has_field:
        print("ActiveServices: no native-only services in this build, left as it is", file=sys.stderr)
        return
    path = find(root)
    lines = open(path).read().split("\n")
    if any("oneosNativeRefused" in l for l in lines):
        sys.exit("ActiveServices already patched")
    heads = [i for i, l in enumerate(lines) if HEADER.match(l)]
    if len(heads) != 1:
        sys.exit(f"ActiveServices.bringUpServiceInnerLocked: {len(heads)} matches")
    head = heads[0]
    end = next(i for i in range(head, len(lines)) if lines[i].startswith(".end method"))
    calls = [i for i in range(head, end) if START.match(lines[i])]
    if len(calls) != 1:
        sys.exit(f"bringUpServiceInnerLocked: {len(calls)} startProcessLocked(HostingRecord) calls, expected 1")
    call = calls[0]
    m = START.match(lines[call])
    args = regs(m.group(2), bool(m.group(1)))
    nxt = next(i for i in range(call + 1, end) if lines[i].strip())
    r = RESULT.match(lines[nxt])
    if not r:
        sys.exit("startProcessLocked's result is not taken by a move-result-object")
    res = r.group(1)
    if res in args:
        sys.exit(f"startProcessLocked's result register {res} is also an argument")
    reads = [i for i in range(head, call) if SR_READ.match(lines[i])]
    if not reads:
        sys.exit("no ServiceRecord field read before startProcessLocked")
    sr = SR_READ.match(lines[reads[-1]]).group(1)
    for i in range(reads[-1] + 1, call):
        w = WRITES.match(lines[i])
        if w and w.group(1) == sr:
            sys.exit(f"{sr} (the ServiceRecord) is written before startProcessLocked: {lines[i].strip()}")
        if lines[i].strip().startswith(":") or "goto" in lines[i] or lines[i].strip().startswith("if-"):
            sys.exit(f"a label or branch between the ServiceRecord read and startProcessLocked: {lines[i].strip()}")
    if sr in args and sr == res:
        sys.exit("the ServiceRecord and the result share a register")
    # invoke/range and move-result take any register; const/4 only v0-v15.
    num = int(res[1:])
    if res[0] == "p" or num > 255:
        sys.exit(f"startProcessLocked's result register {res} is not a local the patch can set")
    zero = "const/4" if num < 16 else "const/16"
    before = [
        "    # OneOS: a native-only service would start through zygote_next, which is One UI's:",
        "    # fail its start like a process that cannot launch (guest_no_native_services.py)",
        f"    invoke-static/range {{{sr} .. {sr}}}, {CLS}->oneosNativeRefused({SR})Z",
        "",
        f"    move-result {res}",
        "",
        f"    if-eqz {res}, :oneos_native_start",
        "",
        f"    {zero} {res}, 0x0",
        "",
        "    goto :oneos_native_refused",
        "",
        "    :oneos_native_start",
    ]
    after = ["", "    :oneos_native_refused"]
    lines = lines[:call] + before + lines[call:nxt + 1] + after + lines[nxt + 1:]
    text = "\n".join(lines).rstrip("\n") + "\n" + HELPER
    open(path, "w").write(text)
    print(f"ActiveServices.bringUpServiceInnerLocked: native-only services fail to start "
          f"(ServiceRecord {sr}, result {res})", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    main()
