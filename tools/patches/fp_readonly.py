"""Let PixelOS use One UI's fingerprints, read-only.

The guest reaches the host's fingerprint HAL through ol_bridge, and that HAL's
templates for user 0 are One UI's. Stock FingerprintService treats templates
it doesn't know as junk: InternalCleanupClient removes them from the HAL on
every start, which would delete One UI's fingerprints. Enrolling from the
guest can't work either (the TEE wants a hardware auth token from the real
gatekeeper, and the guest has a software one).

This patch:
  - makes the cleanup adopt unknown HAL templates into the guest's own
    fingerprint list (AOSP's "favor HAL enrollments" path, which is normally
    only for debuggable builds), so the guest sees One UI's fingers;
  - makes every client that would change the HAL fail before the call:
    removeEnrollments, invalidateAuthenticatorId and enroll throw a
    RemoteException inside their existing try blocks, so they end through
    their normal error path instead.

Usage: fp_readonly.py <smali root dir>   (prints changed files, relative)
"""
import os
import re
import sys

root = sys.argv[1]
SENS = os.path.join("com", "android", "server", "biometrics", "sensors")
FP = os.path.join(SENS, "fingerprint", "aidl")


def find(rel_name):
    for d in sorted(os.listdir(root)):
        p = os.path.join(d, rel_name)
        if os.path.isfile(os.path.join(root, p)):
            return p
    sys.exit(f"{rel_name} not found")


changed = []


def edit(rel_name, fn):
    rel = find(rel_name)
    path = os.path.join(root, rel)
    src = open(path, encoding="utf-8").read()
    new = fn(src)
    if new != src:
        open(path, "w", encoding="utf-8").write(new)
    changed.append(rel)


def once(src, old, new, what):
    if src.count(old) != 1:
        sys.exit(f"{what}: expected 1 match, found {src.count(old)}")
    return src.replace(old, new)


ICC = "Lcom/android/server/biometrics/sensors/InternalCleanupClient;"


def favor_accessor(src):
    head = (".method public static bridge synthetic -$$Nest$fgetmFavorHalEnrollments("
            + ICC + ")Z\n")
    if src.count(head) != 1:
        sys.exit("mFavorHalEnrollments accessor not found")
    start = src.index(head)
    end = src.index(".end method", start)
    body = head + "    .registers 1\n\n    const/4 p0, 0x1\n\n    return p0\n"
    return src[:start] + body + src[end:]


def favor_debuggable(src):
    m = re.search(r"    invoke-static \{\}, Landroid/os/Build;->isDebuggable\(\)Z\n\n?    move-result (\w+)\n", src)
    if not m:
        if "ol: favor HAL" in src:
            return src
        sys.exit("isDebuggable() check not found in InternalCleanupClient$1")
    return src[:m.start()] + f"    # ol: favor HAL enrollments on user builds too\n    const/4 {m.group(1)}, 0x1\n" + src[m.end():]


THROW = ("    # ol: never change One UI's fingerprint HAL state\n"
         "    new-instance v0, Landroid/os/RemoteException;\n"
         "    invoke-direct {v0}, Landroid/os/RemoteException;-><init>()V\n"
         "    throw v0\n")


def block_call(call_re, what):
    def fn(src):
        if "ol: never change" in src:
            return src
        m = re.search(r"\.method public startHalOperation\(\)V\n", src)
        if not m:
            sys.exit(f"{what}: startHalOperation not found")
        end = src.index(".end method", m.end())
        body = src[m.end():end]
        c = re.search(call_re, body)
        if not c:
            sys.exit(f"{what}: HAL call not found")
        # The call sits inside :try_start; v0 is free to clobber there since
        # the catch handler only uses the exception.
        line_start = body.rfind("\n", 0, c.start()) + 1
        body = body[:line_start] + THROW + body[line_start:]
        return src[:m.end()] + body + src[end:]
    return fn


edit(os.path.join(SENS, "InternalCleanupClient.smali"), favor_accessor)
edit(os.path.join(SENS, "InternalCleanupClient$1.smali"), favor_debuggable)
edit(os.path.join(FP, "FingerprintRemovalClient.smali"),
     block_call(r"invoke-interface \{[^}]*\}, Landroid/hardware/biometrics/fingerprint/ISession;->removeEnrollments", "removal"))
edit(os.path.join(FP, "FingerprintInvalidationClient.smali"),
     block_call(r"invoke-interface \{[^}]*\}, Landroid/hardware/biometrics/fingerprint/ISession;->invalidateAuthenticatorId", "invalidation"))
edit(os.path.join(FP, "FingerprintEnrollClient.smali"),
     block_call(r"invoke-virtual \{p0\}, Lcom/android/server/biometrics/sensors/fingerprint/aidl/FingerprintEnrollClient;->doEnroll\(\)V", "enroll"))
print("\n".join(c.replace(os.sep, "/") for c in changed))
