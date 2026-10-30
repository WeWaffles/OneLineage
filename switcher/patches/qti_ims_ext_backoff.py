"""Slow down QtiImsExtConnector's bind retry (product/framework/ims-ext-common.jar).

Qualcomm's ims.apk (org.codeaurora.ims) is in the image, but its manifest
requires persist.oplus.qspa.modem=enabled, which only the Find N6's vendor
sets, so the guest PackageManager skips it (run 34 all.log, 16:29:12.674:
"Skipping target and overlay pair org.codeaurora.ims ... required system
property: persist.oplus.qspa.modem"). It also has to stay skipped: it is the
IMS service for a Qualcomm modem stack, and this phone's IMS is Samsung's.

oplus-telephony-common-ext.jar creates three QtiImsExtConnectors in
com.android.phone (OplusImsExtManager, ScbmHandler, OplusImsScreenShareManager).
bindQtiImsExtService() retries every 500 ms while bindService() returns false,
forever: in run 34 that was 3 failed bindService calls every 0.5 s on the phone
process's main thread for the whole session (5247 "Attempt to bind QtiImsExt
service returned with: false" lines, plus 5247 "Unable to start service ...
QtiImsExtService ... not found" from the guest ActivityManager, ~1.5% of all
log lines). bindService() only returns false when the service does not resolve,
and PackageManager has scanned every package before any app process starts, so
the fast retry can never succeed here. Retry every 60 s instead (the method and
its callers stay as they are; onNullBinding's retry is untouched).

Usage: qti_ims_ext_backoff.py <smali root dir>
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import re
import sys

HEADER = ".method private bindQtiImsExtService()V"
# The register pair is v4 in ColorOS's build and v1 in Infinity-X's.
OLD = re.compile(r"^    const-wide/16 (v\d+), 0x1f4$")
NEW = "    const-wide/32 {}, 0xea60"


def find(root, rel_suffix):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(rel_suffix)]
    if len(hits) != 1:
        sys.exit(f"expected exactly one {rel_suffix}, found {len(hits)}")
    return hits[0]


def main():
    root = sys.argv[1]
    path = find(root, os.path.join("org", "codeaurora", "ims", "QtiImsExtConnector.smali"))
    lines = open(path).read().split("\n")
    idx = [i for i, l in enumerate(lines) if l == HEADER]
    if len(idx) != 1:
        sys.exit("QtiImsExtConnector.bindQtiImsExtService not found")
    end = lines.index(".end method", idx[0])
    hits = [i for i in range(idx[0], end) if OLD.match(lines[i])]
    if len(hits) != 1:
        sys.exit(f"expected one 500 ms retry delay in bindQtiImsExtService, found {len(hits)}")
    reg = OLD.match(lines[hits[0]]).group(1)
    # The constant feeds only sendEmptyMessageDelayed(1, reg:reg+1) right below it.
    call = lines[hits[0] + 2]
    if "sendEmptyMessageDelayed(IJ)Z" not in call or not re.search(r", %s, v%d\}" % (reg, int(reg[1:]) + 1), call):
        sys.exit("retry delay is not followed by sendEmptyMessageDelayed")
    lines[hits[0]] = NEW.format(reg)
    lines[hits[0]:hits[0]] = ["    # OneOS: 60 s, not 500 ms; ims.apk is not installed in the guest (run 34)."]
    open(path, "w").write("\n".join(lines))
    print("QtiImsExtConnector.bindQtiImsExtService: retry 500 ms -> 60 s", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    main()
