"""Let Samsung's IMS app keep android.uid.system in the guest, from the staged path only.

VoLTE on a Samsung phone is the system app com.sec.imsservice
(/system/priv-app/imsservice, the SIP stack is its libsec-ims.so). It declares
sharedUserId=android.uid.system and is signed with Samsung's platform key.
guest_prepare.sh (ONEOS_GUEST_SEC_IMS=1) copies THIS phone's One UI copy into a
read-only lower layer of the guest's system_ext, so the guest sees it as the
priv-app /system_ext/priv-app/OneOSSecIms (docs/samsung-ims-in-guest.md).

The guest image's android.uid.system is signed with the guest's own platform key,
not Samsung's, so when the guest's package manager scans the staged APK,
PackageManagerServiceUtils.verifySignatures throws PackageManagerException
"Package com.sec.imsservice has no signatures that match those in shared user
android.uid.system; ignoring!" and the package never exists in the guest: no
ImsService, calls stay on 3G.

This patch adds one carve-out at that throw site: when the package being scanned
is com.sec.imsservice AND its code path is the staged /system_ext/priv-app/
OneOSSecIms, return normally (compatMatch = false) instead of throwing, so it
keeps its sharedUserId. The path gate is the point of the carve-out, not the
name: a user-installed app named com.sec.imsservice lands under /data/app and
never matches that read-only system_ext path, so it cannot gain system rights
this way. /system_ext is assembled by guest_prepare.sh (image + its lower
layers) and is not writable by apps.

The edit is register-safe by construction: it decides at the top of the method,
where p0 still holds the PackageSetting (it is reused as a scratch boolean before
the sharedUserId check) and the low locals are free, and keeps the answer in one
fresh local that the throw site reads. That is one added register, so it also fits
HyperOS's .locals 8, where two would push p6 to v16, past a 4-bit invoke operand.
It refuses to patch a build whose layout differs (a parameter would be pushed past
v15, or the anchors are not found exactly once) rather than produce a miscompile.

Usage: guest_sec_ims_signature.py <smali root dir>
Prints the smali_* directory (dex file) it changed.
"""
import os
import re
import sys

REL = os.path.join("com", "android", "server", "pm", "PackageManagerServiceUtils.smali")
METHOD = (".method public static verifySignatures("
          "Lcom/android/server/pm/PackageSetting;"
          "Lcom/android/server/pm/SharedUserSetting;"
          "Lcom/android/server/pm/PackageSetting;"
          "Landroid/content/pm/SigningDetails;ZZZ)Z")
NPARAMS = 7  # the descriptor above; a static method, so p0..p6 are these params
PME = "Lcom/android/server/pm/PackageManagerException;"
MSG = " has no signatures that match those in shared user "
PKGNAME = "com.sec.imsservice"
STAGED = "/system_ext/priv-app/OneOSSecIms"
GETNAME = "invoke-virtual {p0}, Lcom/android/server/pm/PackageSetting;->getPackageName()Ljava/lang/String;"


def find(root, rel):
    hits = []
    for dirpath, _, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            if path.endswith(rel):
                hits.append(path)
    if len(hits) != 1:
        sys.exit(f"expected exactly one {rel}, found {len(hits)}")
    return hits[0]


def main(root):
    path = find(root, REL)
    lines = open(path).read().split("\n")
    if any(STAGED in line for line in lines):
        sys.exit(f"{path}: already carries the com.sec.imsservice carve-out")

    starts = [i for i, l in enumerate(lines) if l == METHOD]
    if len(starts) != 1:
        sys.exit(f"{path}: verifySignatures(PackageSetting, SharedUserSetting, ...) not found exactly once")
    start = starts[0]
    end = next((i for i in range(start + 1, len(lines)) if lines[i] == ".end method"), None)
    if end is None:
        sys.exit(f"{path}: no .end method after verifySignatures")
    body = range(start + 1, end)

    loc_idx = next((i for i in body if re.match(r"\s*\.locals \d+\s*$", lines[i])), None)
    if loc_idx is None:
        sys.exit(f"{path}: no .locals in verifySignatures")
    locals_count = int(re.match(r"\s*\.locals (\d+)\s*$", lines[loc_idx]).group(1))
    # One more local only. The decision is made at the top of the method, where p0
    # is still the PackageSetting and the low registers are free, and kept as a
    # flag that the throw site reads; stashing the PackageSetting instead would
    # need a second register, and on HyperOS (.locals 8) that pushed p6 to v16,
    # past a 4-bit invoke operand (verifySignatures calls invoke-virtual {p6, p3}).
    if locals_count + 1 + NPARAMS - 1 > 15:
        sys.exit(f"{path}: verifySignatures has .locals {locals_count}; one more would push a parameter past v15")
    flag = f"v{locals_count}"

    # The register the package name lives in (getPackageName() -> move-result-object).
    gp = [i for i in body if lines[i].strip() == GETNAME]
    if len(gp) != 1:
        sys.exit(f"{path}: getPackageName() on p0 not found exactly once in verifySignatures")
    j = gp[0] + 1
    while j < end and lines[j].strip() == "":
        j += 1
    name_m = re.match(r"\s*move-result-object (v\d+)\s*$", lines[j]) if j < end else None
    if not name_m:
        sys.exit(f"{path}: getPackageName() result not captured as expected")
    name_reg = name_m.group(1)

    # The single shared-user throw: new-instance ... PackageManagerException,
    # whose message is the "has no signatures that match" one.
    # Anchor on the shared-user message, not on the exception being built once:
    # HyperOS's services.jar builds PackageManagerException more than once in this
    # method. The throw this patch guards is the one that reports that message, so
    # take the nearest exception built before it.
    msg_lines = [k for k in body if MSG in lines[k]]
    if len(msg_lines) != 1:
        sys.exit(f"{path}: '{MSG.strip()}' is in verifySignatures {len(msg_lines)} times, expected once")
    msg_line = msg_lines[0]
    ni = [i for i in body if i < msg_line
          and re.match(r"\s*new-instance (?:p|v)\d+, " + re.escape(PME) + r"\s*$", lines[i])]
    if not ni:
        sys.exit(f"{path}: no PackageManagerException is built before the shared-user message")
    throw_idx = ni[-1]
    # Cross-check that name_reg really is the package name appended into that message,
    # so it is still live at the throw and the carve-out compares the right value.
    appended = any(re.match(r"\s*invoke-virtual \{[vp]\d+, " + name_reg + r"\}, Ljava/lang/StringBuilder;->append\(",
                           lines[k]) for k in range(throw_idx, msg_line))
    if not appended:
        sys.exit(f"{path}: {name_reg} is not the package name appended in the throw message; register layout differs")

    # Two low locals as scratch for the check at the top. They are free there:
    # the method assigns its own registers before it reads them (dex verifies
    # that), so writing them ahead of its first instruction cannot disturb it.
    scratch = [f"v{n}" for n in range(locals_count) if f"v{n}" != name_reg][:2]
    if len(scratch) < 2:
        sys.exit(f"{path}: verifySignatures has too few locals ({locals_count}) for the check")
    a, b = scratch

    carve = [
        "",
        f"    if-eqz {flag}, :cond_oneos_secims_throw",
        "",
        f"    const/4 {flag}, 0x0",
        "",
        f"    return {flag}",
        "",
        "    :cond_oneos_secims_throw",
    ]
    # The decision, at the top: this is Samsung's VoLTE app com.sec.imsservice,
    # staged from THIS phone's One UI into the guest's read-only
    # /system_ext/priv-app/OneOSSecIms (guest_prepare.sh, ONEOS_GUEST_SEC_IMS=1).
    # It is signed with Samsung's platform key, not the guest image's, so it
    # cannot join android.uid.system and the scan drops it. Admit that one
    # package -- and only from that staged system_ext path, which a user-installed
    # app (it lands under /data/app) can never match.
    stash_set = [
        "",
        "    # OneOS: is this the Samsung IMS app staged into the guest's system_ext?",
        "    # Decided here, where p0 is still the PackageSetting (it is reused as a",
        "    # scratch boolean further down) and the low locals are still free; the",
        "    # sharedUserId throw below only reads the flag, so one register is enough.",
        f"    const/4 {flag}, 0x0",
        "",
        f'    const-string {a}, "{PKGNAME}"',
        "",
        f"    invoke-virtual {{{a}, {name_reg}}}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z",
        "",
        f"    move-result {a}",
        "",
        f"    if-eqz {a}, :cond_oneos_secims_done",
        "",
        "    invoke-virtual {p0}, Lcom/android/server/pm/PackageSetting;->getPathString()Ljava/lang/String;",
        "",
        f"    move-result-object {b}",
        "",
        f"    if-eqz {b}, :cond_oneos_secims_done",
        "",
        f'    const-string {a}, "{STAGED}"',
        "",
        f"    invoke-virtual {{{b}, {a}}}, Ljava/lang/String;->startsWith(Ljava/lang/String;)Z",
        "",
        f"    move-result {a}",
        "",
        f"    if-eqz {a}, :cond_oneos_secims_done",
        "",
        f'    const-string {a}, "OneOS"',
        "",
        f'    const-string {b}, "verifySignatures: com.sec.imsservice from the staged {STAGED} kept in android.uid.system despite its Samsung platform signature"',
        "",
        f"    invoke-static {{{a}, {b}}}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I",
        "",
        f"    const/4 {flag}, 0x1",
        "",
        "    :cond_oneos_secims_done",
    ]

    # Insert from the later point first so the earlier indices stay valid.
    lines[throw_idx:throw_idx] = carve
    lines[j + 1:j + 1] = stash_set
    lines[loc_idx] = re.sub(r"\.locals \d+", f".locals {locals_count + 1}", lines[loc_idx])

    with open(path, "w") as f:
        f.write("\n".join(lines))
    print(f"verifySignatures: com.sec.imsservice from {STAGED} kept in android.uid.system "
          f"(.locals {locals_count} -> {locals_count + 1}, flag {flag}, scratch {a}/{b}, name {name_reg})",
          file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    main(sys.argv[1])
