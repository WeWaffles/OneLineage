.class public final Lcom/android/server/display/OneOSPanelBacklight;
.super Ljava/lang/Object;
.source "OneOSPanelBacklight.java"

# OneOS (switcher/patches/samsung_backlight_curve.py): the composer float for a
# brightness in nits, on the Samsung panel of the host. Samsung's composer maps
# the float linearly onto panel0-backlight 0..13510. The table is One UI's own
# nits -> float pairs from its SurfaceFlinger logs on this phone (e.g. 124.52
# nits -> 0.064486, run 28 boot.log.05); the points below 10.4 nits are fitted.
# Above 520 nits the panel takes 5.1 levels per nit (3.775e-4 of the float).

.field private static final FLOATS:[F

.field private static final NITS:[F


.method static constructor <clinit>()V
    .locals 1

    const/16 v0, 0x15

    new-array v0, v0, [F

    fill-array-data v0, :nits

    sput-object v0, Lcom/android/server/display/OneOSPanelBacklight;->NITS:[F

    const/16 v0, 0x15

    new-array v0, v0, [F

    fill-array-data v0, :floats

    sput-object v0, Lcom/android/server/display/OneOSPanelBacklight;->FLOATS:[F

    return-void

    :nits
    .array-data 4
        0.0f
        2.0f
        3.0f
        5.0f
        7.5f
        10.4f
        15.0f
        20.0f
        30.0f
        40.0f
        60.0f
        80.0f
        100.0f
        135.0f
        170.0f
        200.0f
        250.0f
        300.0f
        400.0f
        500.0f
        520.0f
    .end array-data

    :floats
    .array-data 4
        0.0f
        0.002406f
        0.00333f
        0.005015f
        0.00694f
        0.008891f
        0.012079f
        0.015279f
        0.021151f
        0.026566f
        0.03701f
        0.045723f
        0.054391f
        0.068653f
        0.082069f
        0.093062f
        0.110574f
        0.127287f
        0.158918f
        0.188764f
        0.196299f
    .end array-data
.end method


# nits > 0 -> composer float, at least 0.0026 (keeps the panel off its lowest,
# flickering levels), at most 1.0.
.method public static fromNits(F)F
    .locals 6
    .param p0, "nits"    # F

    sget-object v0, Lcom/android/server/display/OneOSPanelBacklight;->NITS:[F

    sget-object v1, Lcom/android/server/display/OneOSPanelBacklight;->FLOATS:[F

    array-length v2, v0

    add-int/lit8 v3, v2, -0x1

    aget v4, v0, v3

    cmpl-float v5, p0, v4

    if-gtz v5, :above

    const/4 v2, 0x1

    :loop
    aget v4, v0, v2

    cmpg-float v5, p0, v4

    if-lez v5, :interpolate

    add-int/lit8 v2, v2, 0x1

    goto :loop

    :interpolate
    add-int/lit8 v3, v2, -0x1

    aget v5, v0, v3

    sub-float v4, v4, v5

    sub-float v5, p0, v5

    div-float v5, v5, v4

    aget v4, v1, v3

    aget v0, v1, v2

    sub-float v0, v0, v4

    mul-float v0, v0, v5

    add-float v0, v0, v4

    goto :clamp

    :above
    sub-float v4, p0, v4

    const v5, 0x39c5eb31    # 3.775e-4f

    mul-float v4, v4, v5

    aget v0, v1, v3

    add-float v0, v0, v4

    :clamp
    const v1, 0x3b2a64c3    # 0.0026f

    invoke-static {v0, v1}, Ljava/lang/Math;->max(FF)F

    move-result v0

    const/high16 v1, 0x3f800000    # 1.0f

    invoke-static {v0, v1}, Ljava/lang/Math;->min(FF)F

    move-result v0

    return v0
.end method
