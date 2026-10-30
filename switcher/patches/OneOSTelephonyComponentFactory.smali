.class public Loneos/telephony/OneOSTelephonyComponentFactory;
.super Lcom/android/internal/telephony/TelephonyComponentFactory;
.source "OneOSTelephonyComponentFactory.smali"

# OneOS (run 43): loaded by TeleService's own TelephonyComponentFactory
# injection (res/xml/telephony_injection.xml, overlaid by OneOSPhoneInjection.apk
# from switcher/overlays/phone_injection) for the one component
# com.android.internal.telephony.SignalStrengthController; every other component
# keeps the image's default factory. Built into oneos-telephony.jar by
# scripts/make-overlays.sh, which guest_prepare.sh puts in the guest's
# /system_ext/framework (a read-only overlay layer). No Google dex is changed,
# so telephony-common.jar keeps its place in the boot image.
#
# Nothing may escape into GsmCdmaPhone.<init>: a Throwable there would crash
# the persistent com.android.phone in a loop, and every crash restarts
# Samsung's shared rild (run 43: "RIL Restart for Phone Died"). So the poll is
# started inside a catch-all; the controller is returned either way.


# direct methods
.method public constructor <init>()V
    .locals 0

    invoke-direct {p0}, Lcom/android/internal/telephony/TelephonyComponentFactory;-><init>()V

    return-void
.end method


# virtual methods
.method public makeSignalStrengthController(Lcom/android/internal/telephony/GsmCdmaPhone;)Lcom/android/internal/telephony/SignalStrengthController;
    .locals 2

    invoke-super {p0, p1}, Lcom/android/internal/telephony/TelephonyComponentFactory;->makeSignalStrengthController(Lcom/android/internal/telephony/GsmCdmaPhone;)Lcom/android/internal/telephony/SignalStrengthController;

    move-result-object v0

    :try_start_0
    invoke-static {v0, p1}, Loneos/telephony/OneOSSignalPoll;->start(Lcom/android/internal/telephony/SignalStrengthController;Lcom/android/internal/telephony/Phone;)V
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    :done
    return-object v0

    :catch_0
    move-exception v1

    goto :done
.end method
