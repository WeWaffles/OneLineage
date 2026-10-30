"""Keep window-level blur on when the phone is warm (owner's choice, run 45).

Android 17's BlurController turns cross-window blur off at THERMAL_STATUS_SEVERE
(mDisabledByThermal, status >= 3). On this phone the guest reached SEVERE and
CRITICAL within a minute of booting (run 45 diag_series.txt: skin 42.6-50.1 C),
so blur stayed off even with "Allow window-level blurs" on in Developer options.
The owner wants it on and turns it off himself when he wants. This removes only
the thermal term from updateBlurEnabled(): the Developer options setting
(mBlurDisabledSetting), battery saver (mInPowerSaveMode), tunnel mode and
CROSS_WINDOW_BLUR_SUPPORTED still decide as before; mDisabledByThermal is still
kept up to date, it is just no longer read there.

Usage: guest_blur_no_thermal.py <smali root dir>
Prints the smali_* directory (dex file) it changed. Exits with a message and
changes nothing unless exactly one such check is found.
"""
import os
import re
import sys

CLASS = re.compile(r"^\.class (?:public |final )*Lcom/android/server/wm/BlurController;$")
METHOD = re.compile(r"^\.method (?:public |private |final )*updateBlurEnabled\(\)V$")
IGET = re.compile(r"^\s*iget-boolean (v\d+|p\d+), p0, Lcom/android/server/wm/BlurController;->mDisabledByThermal:Z$")


def main(root):
    found = []
    for dirpath, _, files in os.walk(root):
        if "BlurController.smali" in files:
            path = os.path.join(dirpath, "BlurController.smali")
            if CLASS.match(open(path).readline().strip()):
                found.append(path)
    if len(found) != 1:
        sys.exit(f"guest_blur_no_thermal: BlurController found {len(found)} times")
    path = found[0]
    lines = open(path).read().split("\n")
    heads = [k for k, l in enumerate(lines) if METHOD.match(l)]
    if len(heads) != 1:
        sys.exit("guest_blur_no_thermal: updateBlurEnabled() not found exactly once")
    end = next(k for k in range(heads[0], len(lines)) if lines[k] == ".end method")
    hits = []
    for k in range(heads[0], end):
        m = IGET.match(lines[k])
        if not m:
            continue
        j = k + 1
        while lines[j].strip() == "":
            j += 1
        if re.match(rf"^\s*if-nez {m.group(1)}, :cond_\w+$", lines[j]):
            hits.append((k, j))
    if len(hits) != 1:
        sys.exit(f"guest_blur_no_thermal: thermal check in updateBlurEnabled() found {len(hits)} times")
    k, j = hits[0]
    del lines[k:j + 1]
    open(path, "w").write("\n".join(lines))
    rel = os.path.relpath(path, root).split(os.sep)[0]
    print(rel)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
