"""Never let the guest remove biometric templates from the phone's sensors.

The container shares the host's biometric HALs (Samsung's IFingerprint and
IFace). At every start of a sensor, the framework's InternalCleanupClient
enumerates the HAL's templates for the user and removes each one its own
settings do not list ("unknown HAL templates"). The guest's settings live in
the staged /data and list none of One UI's, so a guest FingerprintService would
remove every One UI fingerprint of user 0 from the sensor: the weaver problem
again (guest_no_weaver.py), for fingerprints and face. Runs 36a (ColorOS),
f075d93a (S25U) and 41 (Pixel) only escaped because the guest's
FingerprintService never started ("Fingerprint configuration exists, but
FingerprintService is null") and the face HAL listed nothing.

Make InternalCleanupClient.startCleanupUnknownHalTemplates() drop the list and
finish the client as a successful cleanup: nothing is removed, the scheduler
moves on, enumeration and the guest's own enrolments are unchanged.

Usage: guest_no_biometric_cleanup.py <smali root dir>
Prints the smali_* directory (dex file) it changed.
"""
import os
import re
import sys

SUFFIX = os.path.join("com", "android", "server", "biometrics", "sensors", "InternalCleanupClient.smali")
CLS = "Lcom/android/server/biometrics/sensors/InternalCleanupClient;"
BASE = "Lcom/android/server/biometrics/sensors/BaseClientMonitor;"
CB = "Lcom/android/server/biometrics/sensors/ClientMonitorCallback;"
HEADER = re.compile(r"^\.method (?:private |public |final )*startCleanupUnknownHalTemplates\(\)V$")


def main(root):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(os.sep + SUFFIX)]
    if len(hits) != 1:
        sys.exit(f"expected one InternalCleanupClient.smali, found {len(hits)}")
    path = hits[0]
    lines = open(path).read().split("\n")
    heads = [i for i, l in enumerate(lines) if HEADER.match(l)]
    if len(heads) != 1:
        sys.exit(f"{path}: startCleanupUnknownHalTemplates() found {len(heads)} times, expected once")
    # The fields used below must be the ones this build has. mCallback is
    # BaseClientMonitor's; R8 code (Pixel) names it through BaseClientMonitor,
    # ColorOS's through InternalCleanupClient: reuse the form the build uses.
    family = "\n".join(open(os.path.join(os.path.dirname(path), f)).read()
                        for f in os.listdir(os.path.dirname(path)) if f.startswith("InternalCleanupClient"))
    if f"{CLS}->mUnknownHALTemplates:Ljava/util/ArrayList;" not in family:
        sys.exit(f"{path}: mUnknownHALTemplates not referenced, unexpected build")
    owner = next((c for c in (BASE, CLS) if f"{c}->mCallback:{CB}" in family), None)
    if owner is None:
        sys.exit(f"{path}: mCallback not referenced, unexpected build")
    i = heads[0]
    m = re.match(r"\s*\.locals (\d+)$", lines[i + 1])
    if not m or int(m.group(1)) < 2:
        sys.exit(f"{path}: unexpected startCleanupUnknownHalTemplates header")
    j = i + 2
    while lines[j].strip() == "" or lines[j].lstrip().startswith((".param", ".end param")):
        j += 1
    lines[j:j] = [
        "    # OneOS: the sensors are the phone's; templates the guest does not know are One UI's.",
        f"    iget-object v0, p0, {CLS}->mUnknownHALTemplates:Ljava/util/ArrayList;",
        "",
        "    invoke-virtual {v0}, Ljava/util/ArrayList;->clear()V",
        "",
        '    const-string v0, "InternalCleanupClient"',
        "",
        '    const-string v1, "OneOS: unknown HAL templates are the phone\'s (One UI\'s); none removed"',
        "",
        "    invoke-static {v0, v1}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I",
        "",
        f"    iget-object v0, p0, {owner}->mCallback:{CB}",
        "",
        "    const/4 v1, 0x1",
        "",
        f"    invoke-interface {{v0, p0, v1}}, {CB}->onClientFinished({BASE}Z)V",
        "",
        "    return-void",
        "",
    ]
    open(path, "w").write("\n".join(lines))
    print("InternalCleanupClient.startCleanupUnknownHalTemplates: removes nothing", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    main(sys.argv[1])
