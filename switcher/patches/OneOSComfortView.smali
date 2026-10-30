.class public final Lcom/android/server/display/color/OneOSComfortView;
.super Landroid/database/ContentObserver;
.source "OneOSComfortView.smali"


# OneOS (run 43): Pixel's Comfort View only writes Settings.System cv_enabled
# and cv_preferred_intensity (slider / 1000, default 0.5); on a Pixel,
# PixelDisplayService applies them through the Pixel display HAL, which the
# guest does not have (MysticGSI removes the service, the Samsung vendor has no
# such HAL), so the switch did nothing. This observer, started once by
# ColorDisplayService.setUp() (patches/comfort_view_bridge.py), turns them into
# a desaturation matrix at DisplayTransformManager level 175, the path Night
# Light takes: saturation s = 1 - 0.6 x intensity, luma weights 0.231, 0.715,
# 0.072 as GlobalSaturationTintController, column-major 4x4, no offsets (they
# would lift OLED black). Level 175 is unused by AOSP (night display 100, white
# balance 125, saturation 150, grayscale 200, reduce bright colors 250,
# inversion 300), so it stacks with Night Light and leaves Digital Wellbeing's
# bedtime grayscale alone. cv_dynamic_enabled (ambient) is not used. Everything
# runs on ColorDisplayService's handler thread in system_server, so every path
# catches Throwable and only logs.

.field private static sStarted:Z

.field private final mCr:Landroid/content/ContentResolver;


.method private constructor <init>(Landroid/os/Handler;Landroid/content/ContentResolver;)V
    .locals 0

    invoke-direct {p0, p1}, Landroid/database/ContentObserver;-><init>(Landroid/os/Handler;)V

    iput-object p2, p0, Lcom/android/server/display/color/OneOSComfortView;->mCr:Landroid/content/ContentResolver;

    return-void
.end method

# Once per system_server: setUp() runs again on a user switch.
.method public static start(Lcom/android/server/display/color/ColorDisplayService;)V
    .locals 4

    :try_start_0
    sget-boolean v0, Lcom/android/server/display/color/OneOSComfortView;->sStarted:Z

    if-nez v0, :done

    const/4 v0, 0x1

    sput-boolean v0, Lcom/android/server/display/color/OneOSComfortView;->sStarted:Z

    invoke-virtual {p0}, Lcom/android/server/SystemService;->getContext()Landroid/content/Context;

    move-result-object v0

    invoke-virtual {v0}, Landroid/content/Context;->getContentResolver()Landroid/content/ContentResolver;

    move-result-object v0

    iget-object v1, p0, Lcom/android/server/display/color/ColorDisplayService;->mHandler:Landroid/os/Handler;

    new-instance v2, Lcom/android/server/display/color/OneOSComfortView;

    invoke-direct {v2, v1, v0}, Lcom/android/server/display/color/OneOSComfortView;-><init>(Landroid/os/Handler;Landroid/content/ContentResolver;)V

    # User 0: the guest makes no other users (guest_no_new_users.py).
    const/4 v3, 0x0

    const-string v1, "cv_enabled"

    invoke-static {v1}, Landroid/provider/Settings$System;->getUriFor(Ljava/lang/String;)Landroid/net/Uri;

    move-result-object v1

    invoke-virtual {v0, v1, v3, v2, v3}, Landroid/content/ContentResolver;->registerContentObserver(Landroid/net/Uri;ZLandroid/database/ContentObserver;I)V

    const-string v1, "cv_preferred_intensity"

    invoke-static {v1}, Landroid/provider/Settings$System;->getUriFor(Ljava/lang/String;)Landroid/net/Uri;

    move-result-object v1

    invoke-virtual {v0, v1, v3, v2, v3}, Landroid/content/ContentResolver;->registerContentObserver(Landroid/net/Uri;ZLandroid/database/ContentObserver;I)V

    # The saved state, at boot.
    invoke-virtual {v2, v3}, Lcom/android/server/display/color/OneOSComfortView;->onChange(Z)V
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    :done
    return-void

    :catch_0
    move-exception v0

    const-string v1, "OneOSComfortView"

    const-string v2, "not started"

    invoke-static {v1, v2, v0}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    return-void
.end method


# virtual methods
.method public onChange(Z)V
    .locals 9

    :try_start_0
    iget-object v0, p0, Lcom/android/server/display/color/OneOSComfortView;->mCr:Landroid/content/ContentResolver;

    const/4 v4, 0x0

    const-string v1, "cv_enabled"

    invoke-static {v0, v1, v4, v4}, Landroid/provider/Settings$System;->getIntForUser(Landroid/content/ContentResolver;Ljava/lang/String;II)I

    move-result v1

    # intensity f, default 0.5, kept in 0..1 (NaN gives 0)
    const-string v2, "cv_preferred_intensity"

    const/high16 v3, 0x3f000000    # 0.5f

    invoke-static {v0, v2, v3, v4}, Landroid/provider/Settings$System;->getFloatForUser(Landroid/content/ContentResolver;Ljava/lang/String;FI)F

    move-result v2

    const/4 v3, 0x0

    cmpl-float v4, v2, v3

    if-gez v4, :not_below

    move v2, v3

    :not_below
    const/high16 v3, 0x3f800000    # 1.0f

    cmpg-float v4, v2, v3

    if-lez v4, :not_above

    move v2, v3

    :not_above
    # s = 1 - 0.6 f (v3), d = 1 - s (v4)
    const v4, 0x3f19999a    # 0.6f

    mul-float v4, v4, v2

    sub-float v3, v3, v4

    const/high16 v4, 0x3f800000    # 1.0f

    sub-float v4, v4, v3

    # m = null (level 175 removed) while Comfort View is off
    const/4 v5, 0x0

    if-eqz v1, :apply

    const/16 v5, 0x10

    new-array v5, v5, [F

    # red column: k = 0.231 d
    const v6, 0x3e6c8b44    # 0.231f

    mul-float v6, v6, v4

    add-float v7, v6, v3

    const/4 v8, 0x0

    aput v7, v5, v8

    const/4 v8, 0x1

    aput v6, v5, v8

    const/4 v8, 0x2

    aput v6, v5, v8

    # green column: k = 0.715 d
    const v6, 0x3f370a3d    # 0.715f

    mul-float v6, v6, v4

    add-float v7, v6, v3

    const/4 v8, 0x4

    aput v6, v5, v8

    const/4 v8, 0x5

    aput v7, v5, v8

    const/4 v8, 0x6

    aput v6, v5, v8

    # blue column: k = 0.072 d
    const v6, 0x3d9374bc    # 0.072f

    mul-float v6, v6, v4

    add-float v7, v6, v3

    const/16 v8, 0x8

    aput v6, v5, v8

    const/16 v8, 0x9

    aput v6, v5, v8

    const/16 v8, 0xa

    aput v7, v5, v8

    const/high16 v6, 0x3f800000    # 1.0f

    const/16 v8, 0xf

    aput v6, v5, v8

    :apply
    # DisplayTransformManager is published by ColorDisplayService.onStart.
    const-class v6, Lcom/android/server/display/color/DisplayTransformManager;

    invoke-static {v6}, Lcom/android/server/LocalServices;->getService(Ljava/lang/Class;)Ljava/lang/Object;

    move-result-object v6

    check-cast v6, Lcom/android/server/display/color/DisplayTransformManager;

    if-eqz v6, :log

    const/16 v7, 0xaf

    invoke-virtual {v6, v7, v5}, Lcom/android/server/display/color/DisplayTransformManager;->setColorMatrix(I[F)V

    :log
    new-instance v6, Ljava/lang/StringBuilder;

    const-string v7, "cv_enabled="

    invoke-direct {v6, v7}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V

    invoke-virtual {v6, v1}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    const-string v7, " intensity="

    invoke-virtual {v6, v7}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v6, v2}, Ljava/lang/StringBuilder;->append(F)Ljava/lang/StringBuilder;

    const-string v7, " sat="

    invoke-virtual {v6, v7}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v6, v3}, Ljava/lang/StringBuilder;->append(F)Ljava/lang/StringBuilder;

    invoke-virtual {v6}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v6

    const-string v7, "OneOSComfortView"

    invoke-static {v7, v6}, Landroid/util/Slog;->i(Ljava/lang/String;Ljava/lang/String;)I
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    return-void

    :catch_0
    move-exception v0

    const-string v1, "OneOSComfortView"

    const-string v2, "not applied"

    invoke-static {v1, v2, v0}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    return-void
.end method
