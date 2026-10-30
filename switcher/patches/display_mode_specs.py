"""Patch LocalDisplayAdapter.tryConnectDisplayLocked (smali) for ColorOS guests.

ColorOS's SurfaceFlinger keeps its refresh rate policy in OPPO's own
RefreshRateSelector, which needs OPPO display HALs a Samsung vendor does not
have, so getDesiredDisplayModeSpecs() comes back null. Stock code then drops
the physical display, no default display is ever created and
DisplayManagerService aborts system_server with "Timeout waiting for default
display to be initialized". Instead, fall back to the display's active mode
with unrestricted refresh rate ranges.

Pixel's services.jar (R8) has the same check with the message in p0 and no
.line before return-void, so the check is matched by pattern; the registers it
relies on are checked first. Google's SurfaceFlinger is expected to return
specs, and the fallback is then never taken.

Usage: display_mode_specs.py <LocalDisplayAdapter.smali>
"""
import re
import sys

DS = "Landroid/view/SurfaceControl$DesiredDisplayModeSpecs;"
RS = "Landroid/view/SurfaceControl$RefreshRateRanges;"
R = "Landroid/view/SurfaceControl$RefreshRateRange;"

# v0 = TAG, v3 = display token, v7 = DynamicDisplayInfo, v8 = mode specs.
OLD = re.compile(r"""    const-string ([vp]\d+), "Desired display mode specs from SurfaceFlinger are null"

    invoke-static \{v0, \1\}, Landroid/util/Slog;->w\(Ljava/lang/String;Ljava/lang/String;\)I

(?:    \.line \d+\n)?    return-void
""")
# The specs come from the token in v3 into v8, and v7 is the DynamicDisplayInfo.
NEEDED = (
    re.compile(r"invoke-virtual \{v\d+, v3\}, \S+;->getDesiredDisplayModeSpecs\(Landroid/os/IBinder;\)"
               + re.escape(DS) + r"\n\n    move-result-object v8\n(?:\n|    \.(?:line|local) [^\n]*\n)*    if-nez v8, "),
    re.compile(r"iget v\d+, v7, Landroid/view/SurfaceControl\$DynamicDisplayInfo;->activeDisplayModeId:I"),
)


def ranges_to_infinity():
    out = []
    for ranges in ("primaryRanges", "appRequestRanges"):
        for kind in ("physical", "render"):
            out.append(f"""    iget-object v1, v8, {DS}->{ranges}:{RS}

    iget-object v1, v1, {RS}->{kind}:{R}

    iput v2, v1, {R}->max:F
""")
    return "\n".join(out)


NEW = f"""    # OneOS: no mode specs from ColorOS's SurfaceFlinger without the OPPO
    # display HALs; use the active mode with unrestricted ranges.
    const-string v1, "OneOS: desired display mode specs from SurfaceFlinger are null, using the active mode"

    invoke-static {{v0, v1}}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I

    new-instance v8, {DS}

    invoke-direct {{v8}}, {DS}-><init>()V

    iput-object v3, v8, {DS}->displayToken:Landroid/os/IBinder;

    iget v1, v7, Landroid/view/SurfaceControl$DynamicDisplayInfo;->activeDisplayModeId:I

    iput v1, v8, {DS}->defaultMode:I

    const v2, 0x7f800000    # +Infinity

{ranges_to_infinity()}"""


def main(path):
    with open(path) as f:
        smali = f.read()
    if len(OLD.findall(smali)) != 1:
        sys.exit(f"{path}: expected the null mode specs check exactly once")
    for n in NEEDED:
        if len(n.findall(smali)) != 1:
            sys.exit(f"{path}: registers differ ({n.pattern[:60]}...)")
    with open(path, "w") as f:
        f.write(OLD.sub(lambda m: NEW, smali))
    print(f"patched {path}")


if __name__ == "__main__":
    main(sys.argv[1])
