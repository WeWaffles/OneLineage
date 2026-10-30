.class public final Loneos/telephony/OneOSSignalPoll;
.super Ljava/lang/Object;
.source "OneOSSignalPoll.smali"

# implements Runnable

.implements Ljava/lang/Runnable;


# OneOS (run 43): OneOSSignalPoll.smali (ColorOS, run 34) made generic, for any
# AOSP-based guest; started by OneOSTelephonyComponentFactory, built into
# oneos-telephony.jar by scripts/make-overlays.sh. Samsung's RIL sends the
# guest no currentSignalStrength indication (run 34 ColorOS, run 43 Pixel), and
# AOSP's SignalStrengthController polls only for opportunistic subscriptions,
# so both SIMs kept the all-invalid SignalStrength read right after
# RADIO_POWER on (level 0 for the whole session). Every 20 s, with the screen
# and the radio on, send the controller its own EVENT_POLL_SIGNAL_STRENGTH (7):
# mCi.getSignalStrength(obtainMessage(9)), and the result takes the normal path
# (radio on -> onSignalStrengthResult -> TelephonyRegistry). A read-only RIL
# query: nothing in the modem or One UI changes. 20000 ms is the controller's
# own unused POLL_PERIOD_MILLIS.

.field private final mController:Lcom/android/internal/telephony/SignalStrengthController;

.field private final mPhone:Lcom/android/internal/telephony/Phone;


# direct methods
.method private constructor <init>(Lcom/android/internal/telephony/SignalStrengthController;Lcom/android/internal/telephony/Phone;)V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Loneos/telephony/OneOSSignalPoll;->mController:Lcom/android/internal/telephony/SignalStrengthController;

    iput-object p2, p0, Loneos/telephony/OneOSSignalPoll;->mPhone:Lcom/android/internal/telephony/Phone;

    return-void
.end method

.method public static start(Lcom/android/internal/telephony/SignalStrengthController;Lcom/android/internal/telephony/Phone;)V
    .locals 3

    if-eqz p0, :done

    if-eqz p1, :done

    new-instance v0, Loneos/telephony/OneOSSignalPoll;

    invoke-direct {v0, p0, p1}, Loneos/telephony/OneOSSignalPoll;-><init>(Lcom/android/internal/telephony/SignalStrengthController;Lcom/android/internal/telephony/Phone;)V

    const-wide/16 v1, 0x4e20

    invoke-virtual {p0, v0, v1, v2}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    # Once per phone: a hook that loaded but never polls must not look like
    # one that never loaded (run 43 review).
    const-string v0, "OneOSSignalPoll"

    const-string v1, "GET_SIGNAL_STRENGTH every 20 s while the screen and the radio are on"

    invoke-static {v0, v1}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    :done
    return-void
.end method


# virtual methods
.method public run()V
    .locals 4

    :try_start_0
    iget-object v0, p0, Loneos/telephony/OneOSSignalPoll;->mPhone:Lcom/android/internal/telephony/Phone;

    # A phone whose controller was replaced stops its poll.
    invoke-virtual {v0}, Lcom/android/internal/telephony/Phone;->getSignalStrengthController()Lcom/android/internal/telephony/SignalStrengthController;

    move-result-object v1

    iget-object v2, p0, Loneos/telephony/OneOSSignalPoll;->mController:Lcom/android/internal/telephony/SignalStrengthController;

    if-ne v1, v2, :stop

    invoke-virtual {v0}, Lcom/android/internal/telephony/Phone;->getContext()Landroid/content/Context;

    move-result-object v1

    const-class v2, Landroid/os/PowerManager;

    invoke-virtual {v1, v2}, Landroid/content/Context;->getSystemService(Ljava/lang/Class;)Ljava/lang/Object;

    move-result-object v1

    check-cast v1, Landroid/os/PowerManager;

    if-eqz v1, :skip

    invoke-virtual {v1}, Landroid/os/PowerManager;->isInteractive()Z

    move-result v1

    if-eqz v1, :skip

    iget-object v1, v0, Lcom/android/internal/telephony/Phone;->mCi:Lcom/android/internal/telephony/CommandsInterface;

    invoke-interface {v1}, Lcom/android/internal/telephony/CommandsInterface;->getRadioState()I

    move-result v1

    const/4 v2, 0x1

    if-ne v1, v2, :skip

    iget-object v1, p0, Loneos/telephony/OneOSSignalPoll;->mController:Lcom/android/internal/telephony/SignalStrengthController;

    const/4 v2, 0x7

    invoke-virtual {v1, v2}, Landroid/os/Handler;->sendEmptyMessage(I)Z
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    :skip
    :again
    iget-object v0, p0, Loneos/telephony/OneOSSignalPoll;->mController:Lcom/android/internal/telephony/SignalStrengthController;

    const-wide/16 v1, 0x4e20

    invoke-virtual {v0, p0, v1, v2}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    return-void

    # Once, when it stops: a poll that stopped must not look like one that
    # never started.
    :stop
    const-string v0, "OneOSSignalPoll"

    const-string v1, "stopped: the phone has another SignalStrengthController"

    invoke-static {v0, v1}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    return-void

    :catch_0
    move-exception v0

    goto :again
.end method
