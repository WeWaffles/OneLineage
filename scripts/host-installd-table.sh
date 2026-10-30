#!/bin/sh
# Print the host (One UI) installd interface: one "name code signature" line
# per IInstalld method, from the host's services.jar. switcher/patches/
# guest_installd_abi.py uses it to send the guest's installd calls with the
# host's transaction codes.
#
# Usage: scripts/host-installd-table.sh <host services.jar> > switcher/patches/host_installd.txt
#   (adb pull /system/framework/services.jar from One UI first)
set -e
JAR="$1"
[ -f "$JAR" ] || { echo "usage: $0 <host services.jar>" >&2; exit 2; }
DEXDUMP=$(ls "${ANDROID_HOME:-/opt/android-sdk}"/build-tools/*/dexdump | tail -1)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
unzip -q -o "$JAR" 'classes*.dex' -d "$WORK"
for d in "$WORK"/classes*.dex; do "$DEXDUMP" -f "$d" 2>/dev/null; done > "$WORK/dump.txt"
python3 -I - "$WORK/dump.txt" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
def section(cls):
    m = re.search(r"Class descriptor\s*: 'L" + re.escape(cls) + r";'(.*?)(?=Class descriptor|\Z)", text, re.S)
    if not m:
        sys.exit(f"{cls} not found")
    return m.group(1)
codes = {m.group(1): int(m.group(2)) for m in re.finditer(
    r"name\s*: 'TRANSACTION_(\w+)'\s*\n\s*type\s*: 'I'\s*\n\s*access[^\n]*\n\s*value\s*: (\d+)",
    section("android/os/IInstalld$Stub"))}
sigs = {}
for m in re.finditer(r"name\s*: '(\w+)'\s*\n\s*type\s*: '(\([^']*\)[^']*)'", section("android/os/IInstalld$Stub$Proxy")):
    sigs.setdefault(m.group(1), m.group(2))
print("# host IInstalld: name code signature (from the host's services.jar)")
for name, code in sorted(codes.items(), key=lambda x: x[1]):
    print(name, code, sigs.get(name, "-"))
PYEOF
