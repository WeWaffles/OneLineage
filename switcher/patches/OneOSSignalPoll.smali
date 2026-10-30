.class public final Lcom/oplus/internal/telephony/OneOSSignalPoll;
.super Ljava/lang/Object;
.source "OneOSSignalPoll.smali"

# implements Runnable

.implements Ljava/lang/Runnable;


# OneOS (run 34): Samsung's RIL sends the guest no currentSignalStrength
# indications, and AOSP's SignalStrengthController polls only for opportunistic
# subscriptions, so the guest kept the all-invalid SignalStrength it got right
# after RADIO_POWER on (no bars on either SIM for the whole session). Every 20 s
# while the screen is on and the radio is on, send the controller its own
# EVENT_POLL_SIGNAL_STRENGTH (7): getSignalStrength(obtainMessage(9)), and the
# result takes the normal path (onSignalStrengthResult -> OplusSignalSmooth).
# 20000 ms is the controller's own unused POLL_PERIOD_MILLIS.

.field private final mHandler:Landroid/os/Handler;

.field private final mPhone:Lcom/android/internal/telephony/Phone;


.method private constructor <init>(Landroid/os/Handler;Lcom/android/internal/telephony/Phone;)V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lcom/oplus/internal/telephony/OneOSSignalPoll;->mHandler:Landroid/os/Handler;

    iput-object p2, p0, Lcom/oplus/internal/telephony/OneOSSignalPoll;->mPhone:Lcom/android/internal/telephony/Phone;

    return-void
.end method

.method public static start(Landroid/os/Handler;Lcom/android/internal/telephony/Phone;)V
    .locals 3

    if-eqz p0, :done

    if-eqz p1, :done

    new-instance v0, Lcom/oplus/internal/telephony/OneOSSignalPoll;

    invoke-direct {v0, p0, p1}, Lcom/oplus/internal/telephony/OneOSSignalPoll;-><init>(Landroid/os/Handler;Lcom/android/internal/telephony/Phone;)V

    const-wide/16 v1, 0x4e20

    invoke-virtual {p0, v0, v1, v2}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    :done
    return-void
.end method


# virtual methods
.method public run()V
    .locals 4

    :try_start_0
    invoke-static {}, Lcom/oplus/internal/telephony/OplusTelephonyController;->getInstance()Lcom/oplus/internal/telephony/OplusTelephonyController;

    move-result-object v0

    invoke-virtual {v0}, Lcom/oplus/internal/telephony/OplusTelephonyController;->isScreenOn()Z

    move-result v0

    if-eqz v0, :skip

    iget-object v0, p0, Lcom/oplus/internal/telephony/OneOSSignalPoll;->mPhone:Lcom/android/internal/telephony/Phone;

    iget-object v1, v0, Lcom/android/internal/telephony/Phone;->mCi:Lcom/android/internal/telephony/CommandsInterface;

    invoke-interface {v1}, Lcom/android/internal/telephony/CommandsInterface;->getRadioState()I

    move-result v1

    const/4 v2, 0x1

    if-ne v1, v2, :skip

    invoke-virtual {v0}, Lcom/android/internal/telephony/Phone;->getSignalStrengthController()Lcom/android/internal/telephony/SignalStrengthController;

    move-result-object v0

    if-eqz v0, :skip

    const/4 v1, 0x7

    invoke-virtual {v0, v1}, Landroid/os/Handler;->sendEmptyMessage(I)Z
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    :skip
    :again
    iget-object v0, p0, Lcom/oplus/internal/telephony/OneOSSignalPoll;->mHandler:Landroid/os/Handler;

    const-wide/16 v1, 0x4e20

    invoke-virtual {v0, p0, v1, v2}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    return-void

    :catch_0
    move-exception v0

    goto :again
.end method
