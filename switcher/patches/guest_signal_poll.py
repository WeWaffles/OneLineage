"""Poll the signal strength in the guest, since Samsung's RIL never pushes it.

Run 34 (all.log, guest phone pid 25004): SET_UNSOLICITED_RESPONSE_FILTER 127
and SET_SIGNAL_STRENGTH_REPORTING_CRITERIA succeeded on both SIMs (16:29:28),
network state, LCE, physical channel and cell info indications kept coming,
but no currentSignalStrength indication reached the guest in 15 minutes:
OplusSignalSmooth logs "mOrigSignalStrength:" for every signal strength
result, and its last one was 16:29:29.109, from the boot-time
GET_SIGNAL_STRENGTH right after RADIO_POWER on (all fields 2147483647). The
restarted rild (pid 17298, "RIL Restart for Phone Died" at 16:28:34) did not
even try to send one while no client was connected (it logged
"mRadioNetworkIndication == NULL" for PCC, LCE, network state and NITZ, never
for signal strength). AOSP's SignalStrengthController polls only for
opportunistic subscriptions (shouldRefreshSignalStrength), so the guest kept
the invalid value: no bars on either SIM, while One UI gets its bars from
Samsung's own SehSignalBar indication. A poll does return real values: the
first GET_SIGNAL_STRENGTH (16:29:22.320) had WCDMA -99 dBm, level 1.

OplusSignalSmooth's constructor now starts OneOSSignalPoll on its own worker
handler (OneOSSignalPoll.smali, copied into the same package): every 20 s,
with the screen and the radio on, it sends the phone's SignalStrengthController
its EVENT_POLL_SIGNAL_STRENGTH.

Usage: guest_signal_poll.py <smali root dir> <helper smali>
Prints the smali_* directory (dex) it changed.
"""
import os
import shutil
import sys

ANCHOR = "    iput-object p1, p0, Lcom/oplus/internal/telephony/OplusSignalSmooth;->mHandler:Landroid/os/Handler;"
INJECT = """
    # OneOS: Samsung's RIL sends the guest no signal strength indications
    # (run 34); poll every 20 s (OneOSSignalPoll).
    iget-object p2, p0, Lcom/oplus/internal/telephony/OplusSignalSmooth;->mPhone:Lcom/android/internal/telephony/GsmCdmaPhone;

    invoke-static {p1, p2}, Lcom/oplus/internal/telephony/OneOSSignalPoll;->start(Landroid/os/Handler;Lcom/android/internal/telephony/Phone;)V
"""


def find(root, rel_suffix):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(rel_suffix)]
    if len(hits) != 1:
        sys.exit(f"expected exactly one {rel_suffix}, found {len(hits)}")
    return hits[0]


def main(root, helper):
    path = find(root, os.path.join("com", "oplus", "internal", "telephony", "OplusSignalSmooth.smali"))
    smali = open(path).read()
    if "OneOSSignalPoll" in smali:
        sys.exit("OplusSignalSmooth already patched")
    ctor = ".method public constructor <init>(Lcom/android/internal/telephony/ServiceStateTracker;Lcom/android/internal/telephony/GsmCdmaPhone;Lcom/oplus/internal/telephony/OplusOosDelayHandler;)V"
    start = smali.find(ctor)
    if start < 0:
        sys.exit("OplusSignalSmooth constructor not found")
    end = smali.index(".end method", start)
    body = smali[start:end]
    if body.count(ANCHOR + "\n") != 1:
        sys.exit("OplusSignalSmooth constructor: mHandler store not found exactly once")
    # p1 = the new SignalStrengthHandler, p2 is reloaded with mPhone; the code
    # after the anchor overwrites both before reading them again.
    body = body.replace(ANCHOR + "\n", ANCHOR + "\n" + INJECT, 1)
    open(path, "w").write(smali[:start] + body + smali[end:])
    shutil.copy(helper, os.path.join(os.path.dirname(path), "OneOSSignalPoll.smali"))
    print("OplusSignalSmooth.<init>: OneOSSignalPoll every 20 s", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
