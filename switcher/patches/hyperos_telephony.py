"""HyperOS's miui-telephony-common.jar without an IMS phone.

MiuiImsControllerImpl gets its phone in init(), which runs when the IMS phone
is made. The guest has none (no IMS service in a session), but
ServiceStateTracker.pollStateDone still calls sendIMSRegistedStateBroadcast,
whose log() reads mPhone.getPhoneId(): com.android.phone died on every
service state poll and the signal bars kept dropping (Z Fold8 Ultra, fourth
HyperOS run, 2026-10-25). log() prints -1 without a phone, and
isPseudoDsdaCall, which reads mPhone at once, answers false. Every target
must match exactly once, or nothing is written (fail closed).

Usage: hyperos_telephony.py <apktool decoded miui-telephony-common.jar directory>
Prints the smali_* directory (dex file) it changed.
"""
import glob
import os
import sys

CLASS = "com/android/internal/telephony/imsphone/MiuiImsControllerImpl.smali"
PHONE = "Lcom/android/internal/telephony/imsphone/MiuiImsControllerImpl;->mPhone:Lcom/android/internal/telephony/Phone;"
LOG_OLD = f"""    iget-object v1, p0, {PHONE}

    invoke-virtual {{v1}}, Lcom/android/internal/telephony/Phone;->getPhoneId()I

    move-result v1
"""
LOG_NEW = f"""    iget-object v1, p0, {PHONE}

    if-eqz v1, :oneos_no_phone

    invoke-virtual {{v1}}, Lcom/android/internal/telephony/Phone;->getPhoneId()I

    move-result v1

    goto :oneos_phone_id

    :oneos_no_phone
    const/4 v1, -0x1

    :oneos_phone_id
"""
DSDA = ".method public blacklist isPseudoDsdaCall(I)Z"
DSDA_PARAM = '    .param p1, "phoneId"    # I\n'
DSDA_GUARD = f"""
    # oneos: no IMS phone in the guest (hyperos_telephony.py)
    iget-object v0, p0, {PHONE}

    if-nez v0, :oneos_has_phone

    const/4 v0, 0x0

    return v0

    :oneos_has_phone
"""


def method(text, header):
    if text.count(header + "\n") != 1:
        sys.exit(f"hyperos_telephony: {header} not found exactly once")
    start = text.index(header + "\n")
    return start, text.index(".end method", start)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    hits = glob.glob(os.path.join(sys.argv[1], "smali*", CLASS))
    if len(hits) != 1:
        sys.exit(f"hyperos_telephony: {CLASS} found {len(hits)} times (one expected)")
    path = hits[0]
    text = open(path).read()
    s, e = method(text, ".method protected blacklist log(Ljava/lang/String;)V")
    body = text[s:e]
    if body.count(LOG_OLD) != 1 or "oneos_" in body:
        sys.exit("hyperos_telephony: log() does not read mPhone.getPhoneId() as expected")
    text = text[:s] + body.replace(LOG_OLD, LOG_NEW) + text[e:]
    s, e = method(text, DSDA)
    body = text[s:e]
    if body.count(DSDA_PARAM) != 1 or "oneos_" in body or ".locals 9\n" not in body:
        sys.exit("hyperos_telephony: isPseudoDsdaCall is not the expected method")
    text = text[:s] + body.replace(DSDA_PARAM, DSDA_PARAM + DSDA_GUARD) + text[e:]
    open(path, "w").write(text)
    print("MiuiImsControllerImpl: log() and isPseudoDsdaCall without a phone", file=sys.stderr)
    print(os.path.relpath(path, sys.argv[1]).split(os.sep)[0])


if __name__ == "__main__":
    main()
