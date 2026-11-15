"""Tell Samsung's IMS app that telephony is listening to a call session.

Samsung's IMS app (com.sec.imsservice, see docs/SAMSUNG_IMS.md) holds back a
call session's onEnded/onError callbacks ("Telephony not ready to handle ims
callbacks. Postpone onEnded()") until its ImsCallSessionImpl gets
notifyReadyToHandleImsCallbacks(), a method One UI adds to the IImsCallSession
AIDL and calls from its own telephony. AOSP's IImsCallSession has no such
transaction, so in the guest a remote hang-up (SIP BYE) never reached the
dialer and the call stayed on screen until ended locally.

This patch makes IImsCallSession$Stub.onTransact, right after it dispatches
setListener (telephony attaching to the session), call
notifyReadyToHandleImsCallbacks() on the session object if it has one. The
Stub runs inside the IMS app's process (it is the app's binder base class), so
this reaches Samsung's implementation directly; a session without the method
is left alone.

Usage: sec_ims_ready.py <smali root dir>   (prints the changed file, relative)
"""
import os
import sys

root = sys.argv[1]
REL = None
for d in sorted(os.listdir(root)):
    p = os.path.join(d, "com", "android", "ims", "internal", "IImsCallSession$Stub.smali")
    if os.path.isfile(os.path.join(root, p)):
        REL = p
        break
if REL is None:
    sys.exit("IImsCallSession$Stub not found")
path = os.path.join(root, REL)
src = open(path, encoding="utf-8").read()

CALL = ("    invoke-virtual {p0, p1}, Lcom/android/ims/internal/IImsCallSession$Stub;"
        "->setListener(Landroid/telephony/ims/aidl/IImsCallSessionListener;)V\n")
HOOK = "    invoke-static {p0}, Lcom/android/ims/internal/IImsCallSession$Stub;->olNotifyReady(Ljava/lang/Object;)V\n"
if HOOK in src:
    sys.exit("already patched")
if src.count(CALL) != 1:
    sys.exit(f"setListener dispatch found {src.count(CALL)} times, expected 1")
src = src.replace(CALL, CALL + "\n" + HOOK)

HELPER = """
.method private static olNotifyReady(Ljava/lang/Object;)V
    .registers 4

    :try_start
    invoke-virtual {p0}, Ljava/lang/Object;->getClass()Ljava/lang/Class;
    move-result-object v0
    const-string v1, "notifyReadyToHandleImsCallbacks"
    const/4 v2, 0x0
    new-array v2, v2, [Ljava/lang/Class;
    invoke-virtual {v0, v1, v2}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;
    move-result-object v0
    const/4 v2, 0x0
    new-array v2, v2, [Ljava/lang/Object;
    invoke-virtual {v0, p0, v2}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;
    :try_end
    .catch Ljava/lang/Throwable; {:try_start .. :try_end} :catch_all

    :catch_all
    return-void
.end method
"""
open(path, "w", encoding="utf-8").write(src.rstrip("\n") + "\n" + HELPER)
print(REL.replace(os.sep, "/"))
