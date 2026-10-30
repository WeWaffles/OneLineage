"""Give a second built-in panel AOSP's flags, not Qualcomm's private ones.

LocalDisplayAdapter.LocalDisplayDevice.getDisplayDeviceInfoLocked
(services.jar) in images with Qualcomm's display additions (HyperOS) treats
every built-in panel after the first one as an extra screen: FLAG_PRESENTATION
with vendor.display.builtin_presentation, else FLAG_PRIVATE, and
FLAG_OWN_CONTENT_ONLY unless vendor.display.builtin_mirroring. On the Z Fold
the cover panel (port 148) is such a panel, and the device-state layout makes
it display 0 when the phone folds: a private display 0, which no app may use
(run 9: "Calling uid ... does not have access to display 0" for every app,
SystemUI's context display null, 444 SystemUI crashes in two folds, the cover
dark after a second). Samsung's vendor sets neither property, and setting them
would reach One UI's display HAL through the shared property area.

AOSP (and ColorOS) mark such a panel private only when its port is in
config_localPrivateDisplayPorts and own-content-only only without
config_localDisplaysMirrorContent (default true): neither for the cover. This
patch makes the Qualcomm branch do the same: its FLAG_PRIVATE becomes 0 and
builtin_mirroring reads as true. FLAG_PRESENTATION stays behind its property.

Usage: qti_builtin_display_public.py <smali root dir>
Prints the smali_* directory (dex file) it changed; nothing when the image has
no such branch (no "vendor.display.builtin_presentation" in the class). Exits
non-zero when the branch is there but not as expected (fail closed).
"""
import os
import re
import sys

CLS = os.path.join("com", "android", "server", "display", "LocalDisplayAdapter$LocalDisplayDevice.smali")
PRESENTATION = '"vendor.display.builtin_presentation"'
MIRRORING = '"vendor.display.builtin_mirroring"'
GETBOOL = "Landroid/os/SystemProperties;->getBoolean(Ljava/lang/String;Z)Z"
FLAGS = "Lcom/android/server/display/DisplayDeviceInfo;->flags:I"


def code(lines, i):
    """Index of the next instruction or label at or after i (no blanks, .line, .local)."""
    while i < len(lines) and (not lines[i].strip() or lines[i].strip().startswith((".line", ".local", ".end local"))):
        i += 1
    return i


def expect(lines, i, pattern, what):
    i = code(lines, i)
    m = re.match(pattern, lines[i].strip()) if i < len(lines) else None
    if not m:
        sys.exit(f"LocalDisplayDevice: {what} not found at line {i + 1} ({lines[i].strip() if i < len(lines) else 'end'!r})")
    return i, m


def main(root):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs if os.path.join(d, f).endswith(CLS)]
    if len(hits) != 1:
        sys.exit(f"{CLS}: {len(hits)} matches")
    path = hits[0]
    lines = open(path).read().split("\n")
    pres = [k for k, l in enumerate(lines) if PRESENTATION in l]
    if not pres:
        return
    if len(pres) != 1 or sum(MIRRORING in l for l in lines) != 1:
        sys.exit("LocalDisplayDevice: the builtin_presentation/builtin_mirroring checks are not there once each")
    if any("no FLAG_PRIVATE for a second built-in panel" in l for l in lines):
        sys.exit("LocalDisplayDevice: already patched")
    i, m = expect(lines, pres[0], rf'const-string(?:/jumbo)? (v\d+), {re.escape(PRESENTATION)}$', "builtin_presentation")
    r = m.group(1)
    i, _ = expect(lines, i + 1, rf'invoke-static \{{{r}, v\d+\}}, {re.escape(GETBOOL)}$', "its getBoolean")
    i, _ = expect(lines, i + 1, rf'move-result {r}$', "its result")
    i, m = expect(lines, i + 1, r'iget-object (v\d+), [vp]\d+, Lcom/android/server/display/LocalDisplayAdapter\$LocalDisplayDevice;->mInfo:Lcom/android/server/display/DisplayDeviceInfo;$', "mInfo")
    info = m.group(1)
    i, m = expect(lines, i + 1, rf'if-eqz {r}, (:\w+)$', "the presentation branch")
    private_label = m.group(1)
    i, _ = expect(lines, i + 1, rf'iget {r}, {info}, {re.escape(FLAGS)}$', "flags")
    i, _ = expect(lines, i + 1, rf'or-int/lit8 {r}, {r}, 0x40$', "FLAG_PRESENTATION")
    i, _ = expect(lines, i + 1, rf'iput {r}, {info}, {re.escape(FLAGS)}$', "flags")
    i, m = expect(lines, i + 1, r'goto (:\w+)$', "the jump past FLAG_PRIVATE")
    after = m.group(1)
    i, _ = expect(lines, i + 1, rf'{re.escape(private_label)}$', "the FLAG_PRIVATE label")
    i, _ = expect(lines, i + 1, rf'iget {r}, {info}, {re.escape(FLAGS)}$', "flags")
    i, _ = expect(lines, i + 1, rf'or-int/lit8 {r}, {r}, 0x10$', "FLAG_PRIVATE")
    private = i
    i, _ = expect(lines, i + 1, rf'iput {r}, {info}, {re.escape(FLAGS)}$', "flags")
    i, _ = expect(lines, i + 1, rf'{re.escape(after)}$', "the label after FLAG_PRIVATE")
    i, m = expect(lines, i + 1, rf'const-string(?:/jumbo)? (v\d+), {re.escape(MIRRORING)}$', "builtin_mirroring")
    r2 = m.group(1)
    i, _ = expect(lines, i + 1, rf'invoke-static \{{{r2}, v\d+\}}, {re.escape(GETBOOL)}$', "its getBoolean")
    i, m = expect(lines, i + 1, r'move-result (v\d+)$', "its result")
    res = m.group(1)
    result = i
    i, _ = expect(lines, i + 1, rf'if-nez {res}, :\w+$', "the mirroring branch")
    indent = lines[private][:len(lines[private]) - len(lines[private].lstrip())]
    lines[private] = f"{indent}or-int/lit8 {r}, {r}, 0x0"
    lines[result + 1:result + 1] = [
        "",
        f"{indent}# OneOS: builtin_mirroring as true: no FLAG_OWN_CONTENT_ONLY on the cover (AOSP's default)",
        f"{indent}const/4 {res}, 0x1",
    ]
    lines[private:private] = [f"{indent}# OneOS: no FLAG_PRIVATE for a second built-in panel (AOSP: only for config_localPrivateDisplayPorts)"]
    with open(path, "w") as f:
        f.write("\n".join(lines))
    print("LocalDisplayDevice: a second built-in panel is neither private nor own-content-only "
          "(Qualcomm's builtin_presentation/builtin_mirroring branch)", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit("usage: qti_builtin_display_public.py <smali root dir>")
    main(sys.argv[1])
