.class public final Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$stop$1;
.super Ljava/lang/Object;
.source "go/retraceme ac7dde816a3c1d8f735f4c343a00d31a244c2385e7ff6b149499cd51c717f70d"

# interfaces
.implements Ljava/lang/Runnable;


# instance fields
.field public final synthetic $r8$classId:I

.field public synthetic this$0:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;


# direct methods
.method public synthetic constructor <init>(I)V
    .locals 0

    iput p1, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$stop$1;->$r8$classId:I

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method


# virtual methods
.method public final run()V
    .locals 5

    iget v0, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$stop$1;->$r8$classId:I

    const/4 v1, 0x0

    packed-switch v0, :pswitch_data_0

    iget-object v0, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$stop$1;->this$0:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    iget-boolean v0, v0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->started:Z

    if-eqz v0, :cond_0

    goto :goto_0

    :cond_0
    const-string v0, "HingeSensorAngleProvider#start"

    invoke-static {v0}, Landroid/os/Trace;->beginSection(Ljava/lang/String;)V

    iget-object v0, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$stop$1;->this$0:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    iget-object v0, v0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->sensorManager:Landroid/hardware/SensorManager;

    const/16 v2, 0x24

    invoke-virtual {v0, v2}, Landroid/hardware/SensorManager;->getDefaultSensor(I)Landroid/hardware/Sensor;

    move-result-object v0

    iget-object v2, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$stop$1;->this$0:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    iget-object v3, v2, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->sensorManager:Landroid/hardware/SensorManager;

    iget-object v4, v2, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->sensorListener:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$HingeAngleSensorListener;

    iget-object v2, v2, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->listenerHandler:Landroid/os/Handler;

    invoke-virtual {v3, v4, v0, v1, v2}, Landroid/hardware/SensorManager;->registerListener(Landroid/hardware/SensorEventListener;Landroid/hardware/Sensor;ILandroid/os/Handler;)Z

    invoke-static {}, Landroid/os/Trace;->endSection()V

    iget-object p0, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$stop$1;->this$0:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    const/4 v0, 0x1

    iput-boolean v0, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->started:Z

    invoke-static {p0}, Lcom/android/systemui/unfold/updates/hinge/PixelFold8Hinge;->start(Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;)V

    :goto_0
    return-void

    :pswitch_0
    iget-object v0, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$stop$1;->this$0:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    iget-boolean v2, v0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->started:Z

    if-nez v2, :cond_1

    goto :goto_1

    :cond_1
    iget-object v2, v0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->sensorManager:Landroid/hardware/SensorManager;

    iget-object v0, v0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->sensorListener:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$HingeAngleSensorListener;

    invoke-virtual {v2, v0}, Landroid/hardware/SensorManager;->unregisterListener(Landroid/hardware/SensorEventListener;)V

    iget-object p0, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$stop$1;->this$0:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;

    iput-boolean v1, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;->started:Z

    invoke-static {p0}, Lcom/android/systemui/unfold/updates/hinge/PixelFold8Hinge;->stop(Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;)V

    :goto_1
    return-void

    nop

    :pswitch_data_0
    .packed-switch 0x0
        :pswitch_0
    .end packed-switch
.end method
