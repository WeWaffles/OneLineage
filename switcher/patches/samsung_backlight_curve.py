"""Drive Samsung's panel with the brightness ColorOS asks for.

ColorOS sends the composer level/10239 (OplusDisplayBrightnessLinearModel),
which on OPPO's composer means a fraction of the panel's DBV range. Samsung's
SDM composer maps the same float linearly onto panel0-backlight 0..13510, so in
run 28 the guest drove the panel at about 31 nits at its minimum and in the
high-brightness range for three quarters of the slider ("wonky and jumpy").
LocalDisplayDeviceExtImpl.getBacklightFromBrightness now asks ColorOS's own
table for the nits of a level and sends the float One UI itself uses for those
nits (OneOSPanelBacklight.smali, copied into the same package).

Usage: samsung_backlight_curve.py <smali root dir> <helper smali>
Prints the smali_* directory (dex) it changed.
"""
import os
import re
import shutil
import sys

HEADER = ".method private getBacklightFromBrightness(F)F"
INJECT = """
    # OneOS: Samsung's composer maps this float linearly onto 0..13510; send
    # One UI's float for the nits OPPO's brightness table asks for.
    const/4 v0, 0x0

    cmpl-float v1, p1, v0

    if-lez v1, :oneos_oplus_backlight

    invoke-direct {p0, p1}, Lcom/android/server/display/LocalDisplayDeviceExtImpl;->brightnessToNits(F)F

    move-result v1

    cmpl-float v2, v1, v0

    if-lez v2, :oneos_oplus_backlight

    invoke-static {v1}, Lcom/android/server/display/OneOSPanelBacklight;->fromNits(F)F

    move-result v0

    return v0

    :oneos_oplus_backlight
"""


def find(root, rel_suffix):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(rel_suffix)]
    if len(hits) != 1:
        sys.exit(f"expected exactly one {rel_suffix}, found {len(hits)}")
    return hits[0]


def check_helper(helper):
    """Run 29: a hand-written upper clamp in fromNits returned 1.0 for every
    level (panel at its maximum whatever the slider said). Keep the clamps as
    Math.max/min and the tables sane."""
    text = open(helper).read()
    body = text[text.index(".method public static fromNits(F)F"):]
    body = body[:body.index(".end method")]
    for call in ("Ljava/lang/Math;->max(FF)F", "Ljava/lang/Math;->min(FF)F"):
        if call not in body:
            sys.exit(f"OneOSPanelBacklight.fromNits: {call} clamp missing")
    for name in ("nits", "floats"):
        block = text[text.index(f"    :{name}\n"):]
        block = block[:block.index(".end array-data")]
        vals = [float(v.rstrip("f")) for v in re.findall(r"^\s+([0-9.]+f)$", block, re.M)]
        if len(vals) != 21 or any(b <= a for a, b in zip(vals, vals[1:])):
            sys.exit(f"OneOSPanelBacklight: :{name} must be 21 strictly increasing values")


def main(root, helper):
    check_helper(helper)
    path = find(root, os.path.join("com", "android", "server", "display", "LocalDisplayDeviceExtImpl.smali"))
    smali = open(path).read()
    if "OneOSPanelBacklight" in smali:
        sys.exit("LocalDisplayDeviceExtImpl already patched")
    lines = smali.split("\n")
    idx = [i for i, l in enumerate(lines) if l == HEADER]
    if len(idx) != 1 or lines[idx[0] + 1] != "    .locals 3":
        sys.exit("LocalDisplayDeviceExtImpl.getBacklightFromBrightness not found as expected")
    j = idx[0] + 2
    while j < len(lines) and (lines[j].strip() == "" or lines[j].lstrip().startswith(".param")):
        j += 1
    lines[j:j] = INJECT.split("\n")
    open(path, "w").write("\n".join(lines))
    shutil.copy(helper, os.path.join(os.path.dirname(path), "OneOSPanelBacklight.smali"))
    print("LocalDisplayDeviceExtImpl.getBacklightFromBrightness: Samsung nits curve", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
