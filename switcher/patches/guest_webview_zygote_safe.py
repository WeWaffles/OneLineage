"""Keep the guest's system_server up when the WebView zygote cannot start.

SystemImpl.ensureZygoteStarted (services.jar) calls WebViewZygote.getProcess(),
which dereferences its child zygote right after a failed start. ColorOS runs it
on OPPO's dispatch thread, and the NullPointerException took system_server down
60 s into boot (S24 Ultra, Find X9 Ultra IN build, app 0.4.13, session
77e7789e: "Starting child-zygote through Zygote failed ... No such file or
directory", then "Attempt to invoke virtual method ... getZygoteProcessAsManaged()
on a null object reference"); OneOS returned to One UI. The global build's Google
WebView uses the WebView zygote; the CN builds' WebView does not.

Pixel 17 CP3A (the Pixel 9 Pro XL's komodo build) declares getProcess() as
returning android.os.IZygoteProcess; the call is kept as the build has it.

The call is wrapped in a catch of RuntimeException that logs a warning and
returns: WebView then has no zygote (pages may fail to render), and the system
keeps running.

Usage: guest_webview_zygote_safe.py <smali root dir>
Prints the smali_* directory (dex file) it changed.
"""
import os
import sys

HEADER = ".method public ensureZygoteStarted()V"
ORIGINAL = """    .locals 0

    .line 255
    invoke-static {}, Landroid/webkit/WebViewZygote;->getProcess()Landroid/os/ZygoteProcess;

    .line 256
    return-void
.end method"""
# getProcess() returning ZygoteProcess, or IZygoteProcess (Pixel 17 CP3A).
CALLS = (
    "invoke-static {}, Landroid/webkit/WebViewZygote;->getProcess()Landroid/os/ZygoteProcess;",
    "invoke-static {}, Landroid/webkit/WebViewZygote;->getProcess()Landroid/os/IZygoteProcess;",
)
PATCHED = """    .locals 2

    :oneos_webview_try_start
    {call}
    :oneos_webview_try_end
    .catch Ljava/lang/RuntimeException; {:oneos_webview_try_start .. :oneos_webview_try_end} :oneos_webview_catch

    return-void

    :oneos_webview_catch
    move-exception v0

    const-string v1, "OneOS: the WebView zygote did not start; WebView runs without it"

    invoke-static {v1, v0}, Lcom/android/server/webkit/SystemImpl;->oneosWarn(Ljava/lang/String;Ljava/lang/Throwable;)V

    return-void
.end method

.method private static oneosWarn(Ljava/lang/String;Ljava/lang/Throwable;)V
    .locals 1

    const-string v0, "WebViewUpdateService"

    invoke-static {v0, p0, p1}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    return-void
.end method"""


def find(root):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(os.path.join("com", "android", "server", "webkit", "SystemImpl.smali"))]
    if len(hits) != 1:
        sys.exit(f"SystemImpl.smali: {len(hits)} matches")
    return hits[0]


def main():
    root = sys.argv[1]
    path = find(root)
    smali = open(path).read()
    if "oneos_webview_try_start" in smali:
        sys.exit("SystemImpl already patched")
    start = smali.find(HEADER)
    if start < 0 or smali.count(HEADER) != 1:
        sys.exit("SystemImpl.ensureZygoteStarted not found")
    body_start = start + len(HEADER) + 1
    end = smali.index(".end method", body_start) + len(".end method")
    body = smali[body_start:end]
    # Any .line numbers: only the one call and a return in between.
    lines = [l.strip() for l in body.splitlines() if l.strip() and not l.strip().startswith((".line", ".locals"))]
    if len(lines) != 3 or lines[0] not in CALLS or lines[1:] != ["return-void", ".end method"]:
        sys.exit("SystemImpl.ensureZygoteStarted is not the expected single call")
    smali = smali[:body_start] + PATCHED.replace("{call}", lines[0]) + smali[end:]
    open(path, "w").write(smali)
    print("SystemImpl.ensureZygoteStarted: a failed WebView zygote start is logged, not fatal", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    main()
