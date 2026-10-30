"""Never let the guest change the phone's shared gatekeeper (screen-lock) state.

The container shares the host's gatekeeper HAL: the guest's LockSettingsService
talks to the same IGateKeeperService that holds One UI's own screen-lock secure
user IDs (SIDs) and enrolments. The guest's /data is a staged tree that lists no
protectors, so when the guest framework sets or resets a credential it would
enroll user 0 on the phone's gatekeeper, clear the phone's SID, or report device
setup complete to it: the weaver story again (guest_no_weaver.py), but for the
gatekeeper. A guest-enrolled gatekeeper SID, or a cleared one, would leave One
UI's lock state no longer One UI's own.

The guest never needs to set a lock: its own credential flows run against the
staged data, and OneOS does not expose a guest lock UI. So, in
com.android.server.locksettings:

1. LockSettingsService.setLockCredentialInternal(...) and
   setLockCredentialWithTokenInternalLocked(...) return false at entry (with a
   Slog.w): the guest declines to set or reset a credential at all, so none of
   the gatekeeper/weaver/keystore work inside them runs.

2. Every IGateKeeperService.clearSecureUserId(I)V and reportDeviceSetupComplete()V
   invoke becomes a nop (a nop, not nothing: a dropped call can be the only
   instruction of a try block, and ART rejects an empty try range). Neither
   returns a value, so nothing downstream needs rewriting.

3. Every IGateKeeperService.enroll(I[B[B[B)GateKeeperResponse invoke is dropped
   (nop) and the move-result-object that captured its response is rewritten to
   const/4 <reg>, 0x0. If such a path were ever reached despite (1), it yields a
   null response (the framework then treats enrolment as failed) instead of
   enrolling user 0 on the phone's gatekeeper.

verifyChallenge(...) and getSecureUserId(I)J are read-only (they prove or read a
credential, they do not change the phone's state) and are left alone.

Both flavours (Pixel R8: public final methods, p registers, .locals with no
debug info; ColorOS non-R8: private methods, .param/.line/.local debug info)
have the same four enroll, three clearSecureUserId and one
reportDeviceSetupComplete call sites across SyntheticPasswordManager,
LockSettingsService and its DeviceProvisionedObserver. All live under
smali_classes2; getSecureUserId and verifyChallenge are matched by exact
descriptor so they are never touched.

Usage: guest_no_gatekeeper.py <smali root dir>
Prints the smali_* directories (dex files) it changed, one per line.
Diagnostics (per-site, per-method, totals) go to stderr; exits non-zero if an
expected method or any expected kind of call site is missing (fail closed).
"""
import os
import re
import sys

GK = "Landroid/service/gatekeeper/IGateKeeperService;"
PKG = os.path.join("com", "android", "server", "locksettings")
LSS = "LockSettingsService.smali"

# Method headers, modifiers in any order/number (R8 public final; ColorOS private).
MODS = r"(?:private |public |protected |final |static |synchronized )*"
SLCI = re.compile(
    r"^\.method " + MODS +
    r"setLockCredentialInternal\(Lcom/android/internal/widget/LockscreenCredential;"
    r"Lcom/android/internal/widget/LockscreenCredential;IZ\)Z$")
SLCWTIL = re.compile(
    r"^\.method " + MODS +
    r"setLockCredentialWithTokenInternalLocked\(Lcom/android/internal/widget/LockscreenCredential;J\[BI\)Z$")

# Gatekeeper call sites (allow /range and any register list; we rewrite the line).
ENROLL = re.compile(
    r"^\s*invoke-interface(?:/range)? \{[^}]*\}, " + re.escape(GK) +
    r"->enroll\(I\[B\[B\[B\)Landroid/service/gatekeeper/GateKeeperResponse;\s*$")
CLEAR = re.compile(
    r"^\s*invoke-interface(?:/range)? \{[^}]*\}, " + re.escape(GK) +
    r"->clearSecureUserId\(I\)V\s*$")
REPORT = re.compile(
    r"^\s*invoke-interface(?:/range)? \{[^}]*\}, " + re.escape(GK) +
    r"->reportDeviceSetupComplete\(\)V\s*$")

LOCALS = re.compile(r"\s*\.locals (\d+)$")
MOVE_OBJ = re.compile(r"move-result-object ([vp]\d+)$")

SLOG_MSG = "OneOS: the screen lock is the phone's gatekeeper; not set in the guest"


def entry(lines, i):
    """First index inside the method body (after .locals/.param/.end param/blank)."""
    j = i + 1
    while lines[j].strip() == "" or lines[j].lstrip().startswith((".locals", ".param", ".end param")):
        j += 1
    return j


def guard_method(lines, header_re, name, rel):
    """Make the matched method return false at entry; returns True once done."""
    heads = [k for k, l in enumerate(lines) if header_re.match(l)]
    if len(heads) != 1:
        sys.exit(f"{rel}: {name} found {len(heads)} times, expected once")
    i = heads[0]
    m = LOCALS.match(lines[i + 1])
    if not m or int(m.group(1)) < 2:
        sys.exit(f"{rel}: unexpected {name} header (need .locals >= 2 for v0/v1)")
    j = entry(lines, i)
    # v0/v1 are free at method entry (no parameter has been moved yet); return Z.
    lines[j:j] = [
        "    # OneOS: the guest never sets or resets the phone's shared screen lock.",
        '    const-string v0, "LockSettingsService"',
        "",
        f'    const-string v1, "{SLOG_MSG}"',
        "",
        "    invoke-static {v0, v1}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return v0",
        "",
    ]
    print(f"{rel}: {name} returns false at entry", file=sys.stderr)


def nop_void(lines, i, what):
    lines[i] = f"    # OneOS: {GK}->{what} dropped (shared gatekeeper is the phone's)\n    nop"


def drop_enroll(lines, i, rel):
    """nop the enroll call and turn its move-result-object into a null const."""
    lines[i] = (f"    # OneOS: {GK}->enroll dropped (would enroll user 0 on the phone's "
                "gatekeeper)\n    nop")
    j = i + 1
    while lines[j].strip() == "" or lines[j].lstrip().startswith("."):
        j += 1
    m = MOVE_OBJ.match(lines[j].strip())
    if not m:
        sys.exit(f"{rel}: enroll at line {i + 1} not followed by move-result-object "
                 f"(found {lines[j].strip()!r}); cannot drop fail-closed")
    lines[j] = f"    const/4 {m.group(1)}, 0x0"


def main(root):
    changed = set()
    enroll_n = clear_n = report_n = 0
    methods_done = {"setLockCredentialInternal": 0,
                    "setLockCredentialWithTokenInternalLocked": 0}
    seen_pkg = False
    for dirpath, _, files in os.walk(root):
        if PKG not in os.path.join(dirpath, ""):
            continue
        for name in files:
            if not name.endswith(".smali"):
                continue
            path = os.path.join(dirpath, name)
            # Only touch the locksettings package itself (not a path that merely
            # contains the folder name elsewhere).
            rel = os.path.relpath(path, root)
            if PKG + os.sep not in rel:
                continue
            seen_pkg = True
            lines = open(path).read().split("\n")
            dirty = False

            if name == LSS:
                guard_method(lines, SLCI, "setLockCredentialInternal", rel)
                methods_done["setLockCredentialInternal"] += 1
                guard_method(lines, SLCWTIL, "setLockCredentialWithTokenInternalLocked", rel)
                methods_done["setLockCredentialWithTokenInternalLocked"] += 1
                dirty = True

            # Rewrite gatekeeper call sites. enroll shifts line text but not the
            # following move-result-object's index, so iterate over a stable copy.
            for i in range(len(lines)):
                line = lines[i]
                if ENROLL.match(line):
                    drop_enroll(lines, i, rel)
                    enroll_n += 1
                    dirty = True
                elif CLEAR.match(line):
                    nop_void(lines, i, "clearSecureUserId(I)V")
                    clear_n += 1
                    dirty = True
                elif REPORT.match(line):
                    nop_void(lines, i, "reportDeviceSetupComplete()V")
                    report_n += 1
                    dirty = True

            if dirty:
                open(path, "w").write("\n".join(lines))
                changed.add(rel.split(os.sep)[0])

    if not seen_pkg:
        sys.exit("com/android/server/locksettings not found")
    for name, n in methods_done.items():
        if n != 1:
            sys.exit(f"LockSettingsService.{name} patched {n} times, expected once")
    # Fail closed if an expected kind of call site is entirely missing: a build
    # that enrolls or clears on the phone's gatekeeper must not pass unpatched.
    if enroll_n == 0:
        sys.exit("no IGateKeeperService->enroll(I[B[B[B) call sites found")
    if clear_n == 0:
        sys.exit("no IGateKeeperService->clearSecureUserId(I)V call sites found")
    if report_n == 0:
        sys.exit("no IGateKeeperService->reportDeviceSetupComplete()V call sites found")
    print(f"gatekeeper sites: enroll x{enroll_n}, clearSecureUserId x{clear_n}, "
          f"reportDeviceSetupComplete x{report_n}; both setLock* methods return false",
          file=sys.stderr)
    for d in sorted(changed):
        print(d)


if __name__ == "__main__":
    main(sys.argv[1])
