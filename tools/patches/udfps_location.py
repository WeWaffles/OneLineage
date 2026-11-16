"""Tell PixelOS where the under-display fingerprint sensor is.

Samsung's fingerprint HAL reports no sensor location, so PixelOS put the
sensor at (0, 0) with radius 0, and the lock screen never drew the
fingerprint icon. AOSP already has an override for this:
FingerprintProvider.getWorkaroundSensorProps() returns locations from a
framework resource. This patch makes it return one location from the system
properties vendor.ol.udfps_x / _y / _r (pixels), which master_prepare.sh
computes from the driver's /sys/class/fingerprint/fingerprint/position and
master_inner.sh sets. Without the properties it falls back to the stock code.

Usage: udfps_location.py <smali root dir>   (prints the changed file, relative)
"""
import os
import re
import sys

root = sys.argv[1]
NAME = os.path.join("com", "android", "server", "biometrics", "sensors", "fingerprint", "aidl",
                    "FingerprintProvider.smali")
rel = next((os.path.join(d, NAME) for d in sorted(os.listdir(root))
            if os.path.isfile(os.path.join(root, d, NAME))), None)
if rel is None:
    sys.exit("FingerprintProvider not found")
path = os.path.join(root, rel)
src = open(path, encoding="utf-8").read()

HEAD = ".method public final getWorkaroundSensorProps(Landroid/content/Context;)Ljava/util/List;\n"
GETINT = "Landroid/os/SystemProperties;->getInt(Ljava/lang/String;I)I"
SLI = "Landroid/hardware/biometrics/SensorLocationInternal;"
HOOK = f"""    # ol: sensor location from vendor.ol.udfps_*
    const/4 v4, 0x0
    const-string v0, "vendor.ol.udfps_x"
    invoke-static {{v0, v4}}, {GETINT}
    move-result v1
    if-lez v1, :ol_no_udfps
    const-string v0, "vendor.ol.udfps_y"
    invoke-static {{v0, v4}}, {GETINT}
    move-result v2
    const-string v0, "vendor.ol.udfps_r"
    invoke-static {{v0, v4}}, {GETINT}
    move-result v3
    new-instance v4, {SLI}
    const-string v0, ""
    invoke-direct {{v4, v0, v1, v2, v3}}, {SLI}-><init>(Ljava/lang/String;III)V
    new-instance v0, Ljava/util/ArrayList;
    invoke-direct {{v0}}, Ljava/util/ArrayList;-><init>()V
    invoke-interface {{v0, v4}}, Ljava/util/List;->add(Ljava/lang/Object;)Z
    return-object v0
    :ol_no_udfps
"""
if src.count(HEAD) != 1:
    sys.exit("getWorkaroundSensorProps not found exactly once")
if "ol: sensor location" not in src:
    start = src.index(HEAD)
    m = re.compile(r"    \.(registers|locals) (\d+)\n").search(src, start)
    # v0-v4 are needed; .registers also counts p0 and p1.
    if m is None or int(m.group(2)) - (2 if m.group(1) == "registers" else 0) < 5:
        sys.exit("getWorkaroundSensorProps has fewer registers than expected")
    src = src[:m.end()] + HOOK + src[m.end():]
    open(path, "w", encoding="utf-8").write(src)
print(rel.replace(os.sep, "/"))
