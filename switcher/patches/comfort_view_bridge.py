"""Make Pixel's Comfort View work in the guest, through a color matrix.

Run 43: Settings > Display > Comfort filters offered Comfort View (the yogi
product overlay sets config_cv_available=true), but switching it on changed
nothing (all.log 09:11:59.809 comfort_view_main_switch, then only a
Settings.System write: no ColorDisplayService or DisplayTransformManager line).
SettingsGoogle only writes Settings.System cv_enabled and
cv_preferred_intensity (slider / 1000, default 0.5). On a Pixel,
PixelDisplayService applies them through the Pixel display HAL
(com.google.hardware.pixel.display.IDisplay) and the Tensor display unit's
color LUT; MysticGSI removes PixelDisplayService, the Samsung vendor has no
such HAL, and nothing else in the image reads cv_*.

ColorDisplayService.setUp() now starts OneOSComfortView
(OneOSComfortView.smali, copied into the same package): a ContentObserver on
those two keys that sets a desaturation matrix at DisplayTransformManager
level 175, the path Night Light takes on this phone (run 43: "SetColorMatrix
level: 100"). See the helper for the matrix and the level.

The call goes at setUp()'s entry, where p0 is still the service: R8 reuses p0
for mHandler right before the method's final return-void, so a call there
would pass a Handler, fail verification and take system_server down in a
loop. It sits in its own try/catch Throwable (handler at the method's end,
v0 is unused at the entry): the helper catches everything it throws itself,
but not a NoClassDefFoundError or VerifyError of its own class, which would
come out of the call in setUp() on the display handler thread and kill
system_server. invoke-static/range takes p0 whatever the register count.
setUp() runs once user setup is complete (run 43: "setUp: currentUser=0" at
09:08:25.271) and again on a user switch; the helper starts only once.

An image without ColorDisplayService or without a setUp() that logs
"setUp: currentUser=" is left alone: a warning on stderr, nothing on stdout,
exit 0, so make-overlays.sh (set -e) still builds it. make-overlays.sh does
not run it for ColorOS images (oplus-services.jar), which have the anchor but
no Comfort View: nothing there writes cv_enabled.

Usage: comfort_view_bridge.py <smali root dir> <helper smali>
Prints the smali_* directory (dex) it changed.
"""
import os
import re
import shutil
import sys

CLS = os.path.join("com", "android", "server", "display", "color", "ColorDisplayService.smali")
CALL = """
    # OneOS (run 43): Comfort View through a color matrix (OneOSComfortView).
    # At the entry: p0 is overwritten with mHandler before the final return.
    :oneos_cv_try_start
    invoke-static/range {p0 .. p0}, Lcom/android/server/display/color/OneOSComfortView;->start(Lcom/android/server/display/color/ColorDisplayService;)V
    :oneos_cv_try_end
    .catch Ljava/lang/Throwable; {:oneos_cv_try_start .. :oneos_cv_try_end} :oneos_cv_catch

    :oneos_cv_done
"""
# At the method's end: a helper class that fails to load must not stop setUp().
HANDLER = """
    # OneOS: OneOSComfortView could not be loaded (see CALL).
    :oneos_cv_catch
    move-exception v0

    goto :oneos_cv_done
"""


def skip(why):
    print(f"comfort_view_bridge: {why}; Comfort View left alone", file=sys.stderr)
    sys.exit(0)


def main(root, helper):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(os.sep + CLS)]
    if not hits:
        skip("no ColorDisplayService in this services.jar")
    if len(hits) != 1:
        sys.exit(f"expected exactly one {CLS}, found {len(hits)}")
    path = hits[0]
    smali = open(path).read()
    if "OneOSComfortView" in smali:
        sys.exit("ColorDisplayService already patched")
    methods = list(re.finditer(r"^\.method [^\n]*\n.*?^\.end method\n", smali, re.M | re.S))
    found = [m for m in methods
             if re.search(r'^\s*const-string(/jumbo)? [vp]\d+, "setUp: currentUser="$', m.group(0), re.M)]
    if len(found) != 1:
        skip(f"{len(found)} methods log 'setUp: currentUser='")
    m = found[0]
    head = m.group(0).split("\n", 1)[0]
    # An instance setUp()V, so p0 is the service at the entry.
    if not re.fullmatch(r"\.method (?:public |private |protected )?(?:final )?setUp\(\)V", head):
        skip(f"unexpected method '{head}'")
    body = m.group(0)
    regs = re.search(r"^    \.locals (\d+)\n", body, re.M)
    if not regs:
        skip("setUp() has no .locals line")
    if "oneos_cv_" in body:
        sys.exit("setUp() already has oneos_cv_ labels")
    # The handler's move-exception needs one local (v0).
    locals_line = f"    .locals {max(1, int(regs.group(1)))}\n"
    end = body.rindex(".end method")
    body = body[:regs.start()] + locals_line + CALL + body[regs.end():end] + HANDLER + body[end:]
    open(path, "w").write(smali[:m.start()] + body + smali[m.end():])
    shutil.copy(helper, os.path.join(os.path.dirname(path), "OneOSComfortView.smali"))
    print("ColorDisplayService.setUp: OneOSComfortView (Comfort View, color matrix level 175)", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
