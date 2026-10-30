"""HyperOS's framework.jar against One UI's camera service.

The guest's camera calls go to One UI's cameraserver. Xiaomi added two fields
to android.hardware.CameraStatus (isAuxExported, roleIdList) and reads and
writes them after AOSP's five. One UI's cameraserver writes AOSP's five only,
so every status after the first in ICameraService.addListener's array was read
from the wrong offset and came out null. BiometricService's camera manager
registers an availability callback at boot, CameraManager read cameraId from
a null entry, and system_server died (Z Fold8 Ultra, first HyperOS run,
2026-10-25: "Attempt to read from field 'java.lang.String
android.hardware.CameraStatus.cameraId' on a null object reference").

readFromParcel and writeToParcel go back to AOSP's five fields; the two stay
false and null, for which Xiaomi's only reader (CameraInjector.
updateMiCameraSDKCloud, miui-framework.jar) returns at once. Every target must
match exactly once, or nothing is written (fail closed).

Usage: hyperos_framework.py <apktool decoded framework.jar directory>
Prints the smali_* directory (dex file) it changed.
"""
import glob
import os
import sys

CLASS = "android/hardware/CameraStatus.smali"
READ = """    invoke-virtual {p1}, Landroid/os/Parcel;->readBoolean()Z

    move-result v0

    iput-boolean v0, p0, Landroid/hardware/CameraStatus;->isAuxExported:Z
"""
READ_ROLE = """    invoke-virtual {p1}, Landroid/os/Parcel;->readString()Ljava/lang/String;

    move-result-object v0

    iput-object v0, p0, Landroid/hardware/CameraStatus;->roleIdList:Ljava/lang/String;
"""
WRITE = """    iget-boolean v0, p0, Landroid/hardware/CameraStatus;->isAuxExported:Z

    invoke-virtual {p1, v0}, Landroid/os/Parcel;->writeBoolean(Z)V
"""
WRITE_ROLE = """    iget-object v0, p0, Landroid/hardware/CameraStatus;->roleIdList:Ljava/lang/String;

    invoke-virtual {p1, v0}, Landroid/os/Parcel;->writeString(Ljava/lang/String;)V
"""


def method(text, header):
    start = text.find(header)
    if start < 0 or text.find(header, start + 1) >= 0:
        sys.exit(f"hyperos_framework: {header} not found exactly once")
    end = text.find(".end method", start)
    if end < 0:
        sys.exit(f"hyperos_framework: no end for {header}")
    return start, end


def drop(body, what, name):
    if body.count(what) != 1:
        sys.exit(f"hyperos_framework: {name} found {body.count(what)} times in CameraStatus (one expected)")
    return body.replace(what, "")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    hits = glob.glob(os.path.join(sys.argv[1], "smali*", CLASS))
    if len(hits) != 1:
        sys.exit(f"hyperos_framework: {CLASS} found {len(hits)} times (one expected)")
    path = hits[0]
    text = open(path).read()
    s, e = method(text, ".method public greylist-max-o readFromParcel(Landroid/os/Parcel;)V")
    body = drop(drop(text[s:e], READ, "readBoolean isAuxExported"), READ_ROLE, "readString roleIdList")
    text = text[:s] + body + text[e:]
    s, e = method(text, ".method public whitelist writeToParcel(Landroid/os/Parcel;I)V")
    body = drop(drop(text[s:e], WRITE, "writeBoolean isAuxExported"), WRITE_ROLE, "writeString roleIdList")
    text = text[:s] + body + text[e:]
    for field in ("isAuxExported", "roleIdList"):
        for m in ("readFromParcel", "writeToParcel"):
            ms, me = method(text, next(h for h in (
                ".method public greylist-max-o readFromParcel(Landroid/os/Parcel;)V",
                ".method public whitelist writeToParcel(Landroid/os/Parcel;I)V") if m in h))
            if field in text[ms:me]:
                sys.exit(f"hyperos_framework: {field} still in {m}")
    open(path, "w").write(text)
    print(os.path.relpath(path, sys.argv[1]).split(os.sep)[0])


if __name__ == "__main__":
    main()
