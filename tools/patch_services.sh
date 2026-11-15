#!/usr/bin/env bash
# Applies the smali patches in tools/patches/ to a services.jar and writes the
# result. Today that is one patch: sec_ims_signature.py, which lets Samsung's
# IMS app (com.sec.imsservice, VoLTE and SMS over IMS) keep android.uid.system
# when it is staged into the guest (docs/SAMSUNG_IMS.md).
#
#   tools/patch_services.sh <in services.jar> <out services.jar>
#
# Needs Java and Python 3, plus smali/baksmali 2.5.x with their dependencies
# in $SMALI_TOOLS (default: ~/Documents/smali-tools). Only the dex the patch
# changes is reassembled; the jar's other entries are copied as they are.
set -euo pipefail
IN=$1
OUT=$2
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=${SMALI_TOOLS:-$HOME/Documents/smali-tools}
API=${API:-36}
export PYTHONUTF8=1  # smali sources are UTF-8; Windows' default code page is not
SEP=':'
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) SEP=';'; T=$(cygpath -m "$T") ;; esac
CP=""
for j in baksmali-2.5.2 smali-2.5.2 dexlib2-2.5.2 util-2.5.2 guava-27.1-android failureaccess-1.0.1 \
         jcommander-1.64 antlr-runtime-3.5.2 antlr-2.7.7 stringtemplate-3.2.1; do
    [ -f "$T/$j.jar" ] || { echo "missing $T/$j.jar (set SMALI_TOOLS)" >&2; exit 1; }
    CP="${CP:+$CP$SEP}$T/$j.jar"
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
python -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2], [n for n in zipfile.ZipFile(sys.argv[1]).namelist() if n.endswith(".dex")])' "$IN" "$WORK/dex"
for d in "$WORK"/dex/classes*.dex; do
    n=$(basename "$d" .dex)
    # -l: .locals instead of .registers, which the patches count with.
    java -cp "$CP" org.jf.baksmali.Main d -l -a "$API" "$d" -o "$WORK/smali/smali_$n"
done

changed=$(python -I "$ROOT/tools/patches/sec_ims_signature.py" "$WORK/smali")
dex=${changed#smali_}.dex
echo "reassembling $dex"
java -cp "$CP" org.jf.smali.Main a -a "$API" "$WORK/smali/$changed" -o "$WORK/$dex"

python -I - "$IN" "$OUT" "$dex" "$WORK/$dex" <<'PY'
import sys, zipfile
src, dst, name, new = sys.argv[1:5]
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
    for info in zin.infolist():
        data = open(new, "rb").read() if info.filename == name else zin.read(info.filename)
        zout.writestr(info, data, compress_type=info.compress_type)
print(f"wrote {dst} ({name} replaced)")
PY
