"""Give PixelOS signal bars from the modem's cell info.

Samsung's RIL never sends AOSP signal strength: the RIL_UNSOL signal
indication never arrives (even with the indication filter fully open) and the
SIGNAL_STRENGTH poll answers with every field invalid. Samsung's own stack
gets signal through its vendor ISehRadioNetwork indication, which nothing in
the guest registers for. So the status bar always showed zero bars, though
the modem was registered and data and calls worked.

The modem does send UNSOL_CELL_INFO_LIST every few seconds, and the registered
cell in it carries real RSRP/RSRQ/SINR. This patch adds
SignalStrengthController.olFromCellInfo(List), which builds a SignalStrength
from the registered cell's CellSignalStrength (LTE, NR, GSM or WCDMA) and feeds
it through the normal updateSignalStrength path (levels from carrier config,
notify listeners). ServiceStateTracker.updateOperatorNameForCellInfo, which
runs for every cell info list, calls it first. Any failure is swallowed.

Usage: signal_from_cellinfo.py <smali root dir>   (prints changed files, relative)
"""
import os
import re
import sys

root = sys.argv[1]
PKG = os.path.join("com", "android", "internal", "telephony")


def find(name):
    for d in sorted(os.listdir(root)):
        p = os.path.join(d, PKG, name)
        if os.path.isfile(os.path.join(root, p)):
            return p
    sys.exit(f"{name} not found")


SSC = "Lcom/android/internal/telephony/SignalStrengthController;"
OL_WHAT = "0x4f4c5353"  # 'OLSS', far from the controller's own message ids
TYPES = ["Cdma", "Gsm", "Wcdma", "Tdscdma", "Lte", "Nr"]
CSS = {t: f"Landroid/telephony/CellSignalStrength{t};" for t in TYPES}

# v3 = SignalStrength, v4..v9 = cdma gsm wcdma tdscdma lte nr (contiguous for /range)
REG = dict(zip(TYPES, ["v4", "v5", "v6", "v7", "v8", "v9"]))
lines = []
for t in TYPES:
    lines += [f"    new-instance {REG[t]}, {CSS[t]}",
              f"    invoke-direct {{{REG[t]}}}, {CSS[t]}-><init>()V"]
pick = []
for t in ["Lte", "Nr", "Gsm", "Wcdma"]:
    pick += [f"    instance-of v2, v1, {CSS[t]}",
             f"    if-eqz v2, :not_{t}",
             f"    move-object {REG[t]}, v1",
             f"    check-cast {REG[t]}, {CSS[t]}",
             "    goto :build",
             f"    :not_{t}"]
METHOD = f"""
.method public olFromCellInfo(Ljava/util/List;)V
    .registers 12

    :try_start
    if-eqz p1, :done
    invoke-interface {{p1}}, Ljava/util/List;->iterator()Ljava/util/Iterator;
    move-result-object v0

    :loop
    invoke-interface {{v0}}, Ljava/util/Iterator;->hasNext()Z
    move-result v1
    if-eqz v1, :done
    invoke-interface {{v0}}, Ljava/util/Iterator;->next()Ljava/lang/Object;
    move-result-object v1
    check-cast v1, Landroid/telephony/CellInfo;
    invoke-virtual {{v1}}, Landroid/telephony/CellInfo;->isRegistered()Z
    move-result v2
    if-eqz v2, :loop
    invoke-virtual {{v1}}, Landroid/telephony/CellInfo;->getCellSignalStrength()Landroid/telephony/CellSignalStrength;
    move-result-object v1
    if-eqz v1, :loop
{chr(10).join(lines)}
{chr(10).join(pick)}
    goto :loop

    :build
    new-instance v3, Landroid/telephony/SignalStrength;
    invoke-direct/range {{v3 .. v9}}, Landroid/telephony/SignalStrength;-><init>({''.join(CSS[t] for t in TYPES)})V
    iput-object v3, p0, {SSC}->olLast:Landroid/telephony/SignalStrength;
    invoke-virtual {{p0}}, {SSC}->olRenotify()V
    :try_end
    .catch Ljava/lang/Throwable; {{:try_start .. :try_end}} :done

    :done
    return-void
.end method

# Pushes olLast through updateSignalStrength even when it equals the last
# notified value, then repeats every 30 s. Listeners that registered before
# their subscription had a phone id (SystemUI's, at boot) never get the
# registry's initial value, and the modem sends cell info only on change, so
# without this the status bar can stay at its empty default. It also puts the
# cell-info value back if an all-invalid modem poll overwrote it.
.method public olRenotify()V
    .registers 5

    :try_start
    const v0, {OL_WHAT}
    invoke-virtual {{p0, v0}}, {SSC}->removeMessages(I)V
    iget-object v1, p0, {SSC}->olLast:Landroid/telephony/SignalStrength;
    if-eqz v1, :done
    const/4 v2, 0x0
    iput-object v2, p0, {SSC}->mLastSignalStrength:Landroid/telephony/SignalStrength;
    new-instance v2, Landroid/telephony/SignalStrength;
    invoke-direct {{v2, v1}}, Landroid/telephony/SignalStrength;-><init>(Landroid/telephony/SignalStrength;)V
    invoke-direct {{p0, v2}}, {SSC}->updateSignalStrength(Landroid/telephony/SignalStrength;)V
    const-wide/16 v2, 0x7530
    invoke-virtual {{p0, v0, v2, v3}}, {SSC}->sendEmptyMessageDelayed(IJ)Z
    :try_end
    .catch Ljava/lang/Throwable; {{:try_start .. :try_end}} :done

    :done
    return-void
.end method
"""
FIELD = ".field public olLast:Landroid/telephony/SignalStrength;\n"
HM_HEAD = ".method public whitelist handleMessage(Landroid/os/Message;)V\n"
HM_HOOK = ("    iget v0, p1, Landroid/os/Message;->what:I\n"
           f"    const v1, {OL_WHAT}\n"
           "    if-ne v0, v1, :ol_not_renotify\n"
           f"    invoke-virtual {{p0}}, {SSC}->olRenotify()V\n"
           "    return-void\n"
           "    :ol_not_renotify\n")

changed = []
rel = find("SignalStrengthController.smali")
path = os.path.join(root, rel)
src = open(path, encoding="utf-8").read()
if "olFromCellInfo" not in src:
    if src.count(HM_HEAD) != 1:
        sys.exit("SignalStrengthController.handleMessage not found exactly once")
    start = src.index(HM_HEAD)
    m = re.compile(r"    \.(?:registers|locals) \d+\n").search(src, start)
    src = src[:m.end()] + HM_HOOK + src[m.end():]
    # first field declaration is a safe place for the new field
    f = src.index("\n.field ") + 1
    src = src[:f] + FIELD + src[f:]
    open(path, "w", encoding="utf-8").write(src.rstrip("\n") + "\n" + METHOD)
changed.append(rel)

rel = find("ServiceStateTracker.smali")
path = os.path.join(root, rel)
src = open(path, encoding="utf-8").read()
HEAD = ".method public blacklist updateOperatorNameForCellInfo(Ljava/util/List;)V\n"
if src.count(HEAD) != 1:
    sys.exit("updateOperatorNameForCellInfo not found exactly once")
if "olFromCellInfo" not in src:
    start = src.index(HEAD)
    end = src.index(".end method", start)
    body = src[start:end]
    # insert after .registers and any annotation blocks
    m = re.search(r"    \.(?:registers|locals) \d+\n(?:\s*\n|    \.annotation[\s\S]*?    \.end annotation\n)*", body)
    hook = ("    iget-object v0, p0, Lcom/android/internal/telephony/ServiceStateTracker;->mPhone:Lcom/android/internal/telephony/GsmCdmaPhone;\n"
            "    invoke-virtual {v0}, Lcom/android/internal/telephony/Phone;->getSignalStrengthController()" + SSC + "\n"
            "    move-result-object v0\n"
            "    if-eqz v0, :ol_no_ssc\n"
            "    invoke-virtual {v0, p1}, " + SSC + "->olFromCellInfo(Ljava/util/List;)V\n"
            "    :ol_no_ssc\n")
    body = body[:m.end()] + hook + body[m.end():]
    src = src[:start] + body + src[end:]
    open(path, "w", encoding="utf-8").write(src)
changed.append(rel)
print("\n".join(c.replace(os.sep, "/") for c in changed))
