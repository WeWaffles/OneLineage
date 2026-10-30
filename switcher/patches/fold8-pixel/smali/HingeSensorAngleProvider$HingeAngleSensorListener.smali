.class public final Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$HingeAngleSensorListener;
.super Ljava/lang/Object;
.source "go/retraceme ac7dde816a3c1d8f735f4c343a00d31a244c2385e7ff6b149499cd51c717f70d"

# interfaces
.implements Landroid/hardware/SensorEventListener;


# instance fields
.field public synthetic this$0:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;


# virtual methods
.method public final onAccuracyChanged(Landroid/hardware/Sensor;I)V
    .locals 0

    return-void
.end method

.method public final onSensorChanged(Landroid/hardware/SensorEvent;)V
    .locals 2
    iget-object v0, p0, Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider$HingeAngleSensorListener;->this$0:Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;
    iget-object v1, p1, Landroid/hardware/SensorEvent;->values:[F
    array-length p0, v1
    if-eqz p0, :done
    const/4 p0, 0x0
    aget p0, v1, p0
    invoke-static {v0, p0}, Lcom/android/systemui/unfold/updates/hinge/PixelFold8Hinge;->onPublicAngle(Lcom/android/systemui/unfold/updates/hinge/HingeSensorAngleProvider;F)V
    :done
    return-void
.end method
