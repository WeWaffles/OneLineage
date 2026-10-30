"""No charging error warnings from an OPPO charger HAL the phone does not have.

OplusBatteryService (oplus-services.jar) reads the battery notify code through
OplusBatteryServiceFeature.getPsyBatteryNotify(), which asks OPPO's ICharger
HAL. Samsung's vendor has none ("failed to get ICharger service", hundreds of
times a session), the call returns -1, and the service broadcasts it as the
battery intent's "notifycode". ColorOS's SystemUI (OplusPowerUI ->
OplusPowerNotificationWarnings.updateBattery) tests that code bit by bit, and
-1 has every bit set: plugged in, it showed the charge error warnings (owner,
0.4.10 on the Fold over USB to a PC: "charging keeps showing voltage error";
logcat "updateBattery : event code is -1 mPlugged is 2").

A negative code is no code: each store of mBatteryNotifyCode keeps a value of
0 or more and stores 0 for a negative one, so a real code from a HAL that
answers still gets through.

Usage: oplus_battery_notify.py <smali root dir>
Prints the smali_* directory (dex file) it changed.
"""
import os
import re
import sys

STORE = re.compile(r"^(    iput (v\d+), p0, Lcom/android/server/OplusBatteryService;->mBatteryNotifyCode:I)$", re.M)


def find(root, rel_suffix):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(rel_suffix)]
    if len(hits) != 1:
        sys.exit(f"{rel_suffix}: {len(hits)} matches")
    return hits[0]


def main():
    root = sys.argv[1]
    path = find(root, os.path.join("com", "android", "server", "OplusBatteryService.smali"))
    smali = open(path).read()
    if ":oneos_notify_" in smali:
        sys.exit("OplusBatteryService already patched")
    stores = STORE.findall(smali)
    if not stores:
        sys.exit("OplusBatteryService: no store of mBatteryNotifyCode found")
    n = 0

    def clamp(m):
        nonlocal n
        reg = m.group(2)
        if int(reg[1:]) > 15:
            sys.exit(f"OplusBatteryService: mBatteryNotifyCode stored from {reg}, not a 4-bit register")
        label = f":oneos_notify_{n}"
        n += 1
        return (f"    if-gez {reg}, {label}\n\n"
                f"    const/4 {reg}, 0x0\n\n"
                f"    {label}\n"
                f"{m.group(1)}")

    smali = STORE.sub(clamp, smali)
    open(path, "w").write(smali)
    print(f"OplusBatteryService: negative battery notify code stored as 0 ({n} stores)", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    main()
