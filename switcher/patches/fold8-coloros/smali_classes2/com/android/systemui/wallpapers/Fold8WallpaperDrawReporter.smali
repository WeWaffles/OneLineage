.class public final Lcom/android/systemui/wallpapers/Fold8WallpaperDrawReporter;
.super Ljava/lang/Object;
.source "Fold8WallpaperDrawReporter.java"


# static fields
.field private static lastDp:I

.field private static warned:Z


# direct methods
.method static constructor <clinit>()V
    .locals 1

    .line 7
    const/4 v0, -0x1

    sput v0, Lcom/android/systemui/wallpapers/Fold8WallpaperDrawReporter;->lastDp:I

    return-void
.end method

.method public constructor <init>()V
    .locals 0

    .line 6
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method private static field(Landroid/service/wallpaper/WallpaperService$Engine;Ljava/lang/String;)Ljava/lang/Object;
    .locals 1
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Ljava/lang/Exception;
        }
    .end annotation

    .line 10
    const-class v0, Landroid/service/wallpaper/WallpaperService$Engine;

    invoke-virtual {v0, p1}, Ljava/lang/Class;->getDeclaredField(Ljava/lang/String;)Ljava/lang/reflect/Field;

    move-result-object p1

    const/4 v0, 0x1

    invoke-virtual {p1, v0}, Ljava/lang/reflect/Field;->setAccessible(Z)V

    invoke-virtual {p1, p0}, Ljava/lang/reflect/Field;->get(Ljava/lang/Object;)Ljava/lang/Object;

    move-result-object p0

    return-object p0
.end method

.method public static report(Landroid/service/wallpaper/WallpaperService$Engine;)V
    .locals 10

    .line 14
    const-string v0, "OneOSWallpaperDraw"

    invoke-virtual {p0}, Landroid/service/wallpaper/WallpaperService$Engine;->getSurfaceHolder()Landroid/view/SurfaceHolder;

    move-result-object v1

    invoke-interface {v1}, Landroid/view/SurfaceHolder;->getSurface()Landroid/view/Surface;

    move-result-object v1

    invoke-virtual {v1}, Landroid/view/Surface;->isValid()Z

    move-result v1

    if-nez v1, :cond_0

    return-void

    .line 15
    :cond_0
    const/4 v1, 0x1

    :try_start_0
    new-instance v2, Landroid/view/SurfaceControl$Transaction;

    invoke-direct {v2}, Landroid/view/SurfaceControl$Transaction;-><init>()V
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0

    .line 18
    :try_start_1
    const-string v3, "mMergedConfiguration"

    invoke-static {p0, v3}, Lcom/android/systemui/wallpapers/Fold8WallpaperDrawReporter;->field(Landroid/service/wallpaper/WallpaperService$Engine;Ljava/lang/String;)Ljava/lang/Object;

    move-result-object v3

    .line 19
    invoke-virtual {v3}, Ljava/lang/Object;->getClass()Ljava/lang/Class;

    move-result-object v4

    const-string v5, "getMergedConfiguration"

    const/4 v6, 0x0

    new-array v7, v6, [Ljava/lang/Class;

    invoke-virtual {v4, v5, v7}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;

    move-result-object v4

    new-array v5, v6, [Ljava/lang/Object;

    invoke-virtual {v4, v3, v5}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;

    move-result-object v3

    check-cast v3, Landroid/content/res/Configuration;

    .line 20
    iget v3, v3, Landroid/content/res/Configuration;->smallestScreenWidthDp:I
    :try_end_1
    .catchall {:try_start_1 .. :try_end_1} :catchall_0

    .line 21
    if-gtz v3, :cond_1

    .line 29
    :try_start_2
    invoke-virtual {v2}, Landroid/view/SurfaceControl$Transaction;->close()V
    :try_end_2
    .catch Ljava/lang/Exception; {:try_start_2 .. :try_end_2} :catch_0

    .line 21
    return-void

    .line 22
    :cond_1
    :try_start_3
    const-class v4, Landroid/view/SurfaceControl$Transaction;

    const-string v5, "getWrapper"

    new-array v7, v6, [Ljava/lang/Class;

    invoke-virtual {v4, v5, v7}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;

    move-result-object v4

    new-array v5, v6, [Ljava/lang/Object;

    invoke-virtual {v4, v2, v5}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;

    move-result-object v4

    .line 23
    const-string v5, "android.view.ITransactionWrapper"

    invoke-static {v5}, Ljava/lang/Class;->forName(Ljava/lang/String;)Ljava/lang/Class;

    move-result-object v5

    const-string v7, "getExtImpl"

    new-array v8, v6, [Ljava/lang/Class;

    invoke-virtual {v5, v7, v8}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;

    move-result-object v5

    new-array v7, v6, [Ljava/lang/Object;

    invoke-virtual {v5, v4, v7}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;

    move-result-object v4

    .line 24
    const-string v5, "android.view.ITransactionExt"

    invoke-static {v5}, Ljava/lang/Class;->forName(Ljava/lang/String;)Ljava/lang/Class;

    move-result-object v5

    const-string v7, "setExtraSummary"

    new-array v8, v1, [Ljava/lang/Class;

    sget-object v9, Ljava/lang/Integer;->TYPE:Ljava/lang/Class;

    aput-object v9, v8, v6

    invoke-virtual {v5, v7, v8}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;

    move-result-object v5

    invoke-static {v3}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;

    move-result-object v7

    filled-new-array {v7}, [Ljava/lang/Object;

    move-result-object v7

    invoke-virtual {v5, v4, v7}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;

    .line 25
    const-string v4, "mSession"

    invoke-static {p0, v4}, Lcom/android/systemui/wallpapers/Fold8WallpaperDrawReporter;->field(Landroid/service/wallpaper/WallpaperService$Engine;Ljava/lang/String;)Ljava/lang/Object;

    move-result-object v4

    const-string v5, "mWindow"

    invoke-static {p0, v5}, Lcom/android/systemui/wallpapers/Fold8WallpaperDrawReporter;->field(Landroid/service/wallpaper/WallpaperService$Engine;Ljava/lang/String;)Ljava/lang/Object;

    move-result-object p0

    .line 26
    if-eqz v4, :cond_4

    if-nez p0, :cond_2

    goto :goto_0

    .line 27
    :cond_2
    const-string v5, "android.view.IWindowSession"

    invoke-static {v5}, Ljava/lang/Class;->forName(Ljava/lang/String;)Ljava/lang/Class;

    move-result-object v5

    const-string v7, "finishDrawing"

    const/4 v8, 0x3

    new-array v8, v8, [Ljava/lang/Class;

    const-string v9, "android.view.IWindow"

    invoke-static {v9}, Ljava/lang/Class;->forName(Ljava/lang/String;)Ljava/lang/Class;

    move-result-object v9

    aput-object v9, v8, v6

    const-class v6, Landroid/view/SurfaceControl$Transaction;

    aput-object v6, v8, v1

    sget-object v6, Ljava/lang/Integer;->TYPE:Ljava/lang/Class;

    const/4 v9, 0x2

    aput-object v6, v8, v9

    invoke-virtual {v5, v7, v8}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;

    move-result-object v5

    const v6, 0x7fffffff

    invoke-static {v6}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;

    move-result-object v6

    filled-new-array {p0, v2, v6}, [Ljava/lang/Object;

    move-result-object p0

    invoke-virtual {v5, v4, p0}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;

    .line 28
    sget p0, Lcom/android/systemui/wallpapers/Fold8WallpaperDrawReporter;->lastDp:I

    if-eq p0, v3, :cond_3

    sput v3, Lcom/android/systemui/wallpapers/Fold8WallpaperDrawReporter;->lastDp:I

    new-instance p0, Ljava/lang/StringBuilder;

    invoke-direct {p0}, Ljava/lang/StringBuilder;-><init>()V

    const-string v4, "Reported posted wallpaper frame, smallestWidthDp="

    invoke-virtual {p0, v4}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object p0

    invoke-virtual {p0, v3}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    move-result-object p0

    invoke-virtual {p0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object p0

    invoke-static {v0, p0}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I
    :try_end_3
    .catchall {:try_start_3 .. :try_end_3} :catchall_0

    .line 29
    :cond_3
    :try_start_4
    invoke-virtual {v2}, Landroid/view/SurfaceControl$Transaction;->close()V

    goto :goto_2

    :cond_4
    :goto_0
    invoke-virtual {v2}, Landroid/view/SurfaceControl$Transaction;->close()V
    :try_end_4
    .catch Ljava/lang/Exception; {:try_start_4 .. :try_end_4} :catch_0

    .line 26
    return-void

    .line 15
    :catchall_0
    move-exception p0

    :try_start_5
    invoke-virtual {v2}, Landroid/view/SurfaceControl$Transaction;->close()V
    :try_end_5
    .catchall {:try_start_5 .. :try_end_5} :catchall_1

    goto :goto_1

    :catchall_1
    move-exception v2

    :try_start_6
    invoke-virtual {p0, v2}, Ljava/lang/Throwable;->addSuppressed(Ljava/lang/Throwable;)V

    :goto_1
    throw p0
    :try_end_6
    .catch Ljava/lang/Exception; {:try_start_6 .. :try_end_6} :catch_0

    .line 29
    :catch_0
    move-exception p0

    sget-boolean v2, Lcom/android/systemui/wallpapers/Fold8WallpaperDrawReporter;->warned:Z

    if-nez v2, :cond_5

    sput-boolean v1, Lcom/android/systemui/wallpapers/Fold8WallpaperDrawReporter;->warned:Z

    const-string v1, "Wallpaper draw metadata unavailable"

    invoke-static {v0, v1, p0}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    .line 30
    :cond_5
    :goto_2
    return-void
.end method
