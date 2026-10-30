.class public final Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;
.super Ljava/lang/Object;
.source "Fold8HingeRelay.java"

# interfaces
.implements Ljava/lang/Runnable;


# static fields
.field private static final FRAME:Ljava/lang/String; = "/data/oneos_hinge/angle.bin"

.field private static final active:Ljava/util/IdentityHashMap;
    .annotation system Ldalvik/annotation/Signature;
        value = {
            "Ljava/util/IdentityHashMap<",
            "Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;",
            "Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;",
            ">;"
        }
    .end annotation
.end field


# instance fields
.field private final handler:Landroid/os/Handler;

.field private last:F

.field private final owner:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;


# direct methods
.method static constructor <clinit>()V
    .locals 1

    .line 11
    new-instance v0, Ljava/util/IdentityHashMap;

    invoke-direct {v0}, Ljava/util/IdentityHashMap;-><init>()V

    sput-object v0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->active:Ljava/util/IdentityHashMap;

    return-void
.end method

.method private constructor <init>(Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;Landroid/os/Handler;)V
    .locals 1

    .line 15
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    .line 14
    const/high16 v0, 0x7fc00000    # Float.NaN

    iput v0, p0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->last:F

    .line 15
    iput-object p1, p0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->owner:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    iput-object p2, p0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->handler:Landroid/os/Handler;

    return-void
.end method

.method private static angle()F
    .locals 7

    .line 17
    const/high16 v0, 0x7fc00000    # Float.NaN

    :try_start_0
    new-instance v1, Ljava/io/DataInputStream;

    new-instance v2, Ljava/io/FileInputStream;

    const-string v3, "/data/oneos_hinge/angle.bin"

    invoke-direct {v2, v3}, Ljava/io/FileInputStream;-><init>(Ljava/lang/String;)V

    invoke-direct {v1, v2}, Ljava/io/DataInputStream;-><init>(Ljava/io/InputStream;)V
    :try_end_0
    .catch Ljava/io/IOException; {:try_start_0 .. :try_end_0} :catch_0

    .line 18
    :try_start_1
    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J

    move-result-wide v2

    invoke-virtual {v1}, Ljava/io/DataInputStream;->readLong()J

    move-result-wide v4

    sub-long/2addr v2, v4

    invoke-virtual {v1}, Ljava/io/DataInputStream;->readFloat()F

    move-result v4

    .line 19
    const-wide/16 v5, 0x0

    cmp-long v5, v2, v5

    if-ltz v5, :cond_0

    const-wide/16 v5, 0x9c4

    cmp-long v2, v2, v5

    if-gtz v2, :cond_0

    invoke-static {v4}, Ljava/lang/Float;->isNaN(F)Z

    move-result v2
    :try_end_1
    .catchall {:try_start_1 .. :try_end_1} :catchall_0

    if-nez v2, :cond_0

    const/4 v2, 0x0

    cmpl-float v2, v4, v2

    if-ltz v2, :cond_0

    const/high16 v2, 0x43340000    # 180.0f

    cmpg-float v2, v4, v2

    if-gtz v2, :cond_0

    goto :goto_0

    :cond_0
    move v4, v0

    .line 20
    :goto_0
    :try_start_2
    invoke-virtual {v1}, Ljava/io/DataInputStream;->close()V
    :try_end_2
    .catch Ljava/io/IOException; {:try_start_2 .. :try_end_2} :catch_0

    .line 19
    return v4

    .line 17
    :catchall_0
    move-exception v2

    :try_start_3
    invoke-virtual {v1}, Ljava/io/DataInputStream;->close()V
    :try_end_3
    .catchall {:try_start_3 .. :try_end_3} :catchall_1

    goto :goto_1

    :catchall_1
    move-exception v1

    :try_start_4
    invoke-virtual {v2, v1}, Ljava/lang/Throwable;->addSuppressed(Ljava/lang/Throwable;)V

    :goto_1
    throw v2
    :try_end_4
    .catch Ljava/io/IOException; {:try_start_4 .. :try_end_4} :catch_0

    .line 20
    :catch_0
    move-exception v1

    return v0
.end method

.method public static declared-synchronized startIfFresh(Landroid/hardware/SensorEventListener;Landroid/os/Handler;)Z
    .locals 4

    const-class v0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;

    monitor-enter v0

    .line 23
    :try_start_0
    instance-of v1, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$HingeAngleSensorListener;

    if-eqz v1, :cond_2

    invoke-static {}, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->angle()F

    move-result v1

    invoke-static {v1}, Ljava/lang/Float;->isNaN(F)Z

    move-result v1

    if-eqz v1, :cond_0

    goto :goto_0

    .line 24
    :cond_0
    check-cast p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$HingeAngleSensorListener;

    iget-object p0, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$HingeAngleSensorListener;->this$0:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    .line 25
    sget-object v1, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->active:Ljava/util/IdentityHashMap;

    invoke-virtual {v1, p0}, Ljava/util/IdentityHashMap;->remove(Ljava/lang/Object;)Ljava/lang/Object;

    move-result-object v1

    check-cast v1, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;

    .line 26
    if-eqz v1, :cond_1

    iget-object v2, v1, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->handler:Landroid/os/Handler;

    invoke-virtual {v2, v1}, Landroid/os/Handler;->removeCallbacks(Ljava/lang/Runnable;)V

    .line 27
    :cond_1
    new-instance v1, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;

    invoke-direct {v1, p0, p1}, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;-><init>(Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;Landroid/os/Handler;)V

    .line 28
    sget-object v2, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->active:Ljava/util/IdentityHashMap;

    invoke-virtual {v2, p0, v1}, Ljava/util/IdentityHashMap;->put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;

    .line 29
    const-wide/16 v2, 0x14

    invoke-virtual {p1, v1, v2, v3}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    .line 30
    const-string p0, "OneOSFold8Hinge"

    const-string p1, "Using Samsung continuous angle via guest relay"

    invoke-static {p0, p1}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    monitor-exit v0

    const/4 p0, 0x1

    return p0

    .line 23
    :cond_2
    :goto_0
    monitor-exit v0

    const/4 p0, 0x0

    return p0

    .line 22
    :catchall_0
    move-exception p0

    :try_start_1
    monitor-exit v0
    :try_end_1
    .catchall {:try_start_1 .. :try_end_1} :catchall_0

    throw p0
.end method


# virtual methods
.method public run()V
    .locals 4

    .line 33
    const-class v0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;

    monitor-enter v0

    .line 34
    :try_start_0
    sget-object v1, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->active:Ljava/util/IdentityHashMap;

    iget-object v2, p0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->owner:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    invoke-virtual {v1, v2}, Ljava/util/IdentityHashMap;->get(Ljava/lang/Object;)Ljava/lang/Object;

    move-result-object v1

    if-eq v1, p0, :cond_0

    monitor-exit v0

    return-void

    .line 35
    :cond_0
    iget-object v1, p0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->owner:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    iget-boolean v1, v1, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->started:Z

    if-nez v1, :cond_1

    sget-object v1, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->active:Ljava/util/IdentityHashMap;

    iget-object v2, p0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->owner:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    invoke-virtual {v1, v2}, Ljava/util/IdentityHashMap;->remove(Ljava/lang/Object;)Ljava/lang/Object;

    monitor-exit v0

    return-void

    .line 36
    :cond_1
    monitor-exit v0
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    .line 37
    invoke-static {}, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->angle()F

    move-result v0

    .line 38
    invoke-static {v0}, Ljava/lang/Float;->isNaN(F)Z

    move-result v1

    if-nez v1, :cond_2

    iget v1, p0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->last:F

    invoke-static {v0, v1}, Ljava/lang/Float;->compare(FF)I

    move-result v1

    if-eqz v1, :cond_2

    .line 39
    iput v0, p0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->last:F

    .line 40
    iget-object v1, p0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->owner:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    invoke-static {v1}, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->access$getListeners$p(Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;)Ljava/util/List;

    move-result-object v1

    invoke-interface {v1}, Ljava/util/List;->iterator()Ljava/util/Iterator;

    move-result-object v1

    :goto_0
    invoke-interface {v1}, Ljava/util/Iterator;->hasNext()Z

    move-result v2

    if-eqz v2, :cond_2

    invoke-interface {v1}, Ljava/util/Iterator;->next()Ljava/lang/Object;

    move-result-object v2

    check-cast v2, Landroidx/core/util/Consumer;

    invoke-static {v0}, Ljava/lang/Float;->valueOf(F)Ljava/lang/Float;

    move-result-object v3

    invoke-interface {v2, v3}, Landroidx/core/util/Consumer;->accept(Ljava/lang/Object;)V

    goto :goto_0

    .line 42
    :cond_2
    iget-object v0, p0, Lcom/android/systemui/unfold/updates/hinge/Fold8HingeRelay;->handler:Landroid/os/Handler;

    const-wide/16 v1, 0x14

    invoke-virtual {v0, p0, v1, v2}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    .line 43
    return-void

    .line 36
    :catchall_0
    move-exception v1

    :try_start_1
    monitor-exit v0
    :try_end_1
    .catchall {:try_start_1 .. :try_end_1} :catchall_0

    throw v1
.end method
