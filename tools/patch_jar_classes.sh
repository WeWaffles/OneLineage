#!/usr/bin/env bash
# Applies one smali patch script to a jar's classes without a whole-dex round
# trip: baksmali 3.x reads every dex, the patch script edits the smali and
# prints the changed files (smali_classesN/...), only those classes are
# reassembled with smali 2.5.2, and tools/dexmerge/DexReplace swaps them back
# in with their hidden-API flags. Needs Java 17, Python 3, smali 2.5.2 in
# $SMALI_TOOLS and Android Studio's smali/dexlib2 3.x under $AS_HOME.
#
#   tools/patch_jar_classes.sh <patch.py> <in.jar> <out.jar>
set -euo pipefail
PATCH=$1
IN=$2
OUT=$3
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=${SMALI_TOOLS:-$HOME/Documents/smali-tools}
AS=${AS_HOME:-"/c/Program Files/Android/Android Studio"}
API=${API:-36}
export PYTHONUTF8=1
SEP=':'
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) SEP=';'; T=$(cygpath -m "$T"); AS=$(cygpath -m "$AS") ;; esac
cp_of() { local IFS="$SEP"; echo "$*"; }
SMALI_CP=$(cp_of "$T/baksmali-2.5.2.jar" "$T/smali-2.5.2.jar" "$T/dexlib2-2.5.2.jar" "$T/util-2.5.2.jar" \
    "$T/guava-27.1-android.jar" "$T/failureaccess-1.0.1.jar" "$T/jcommander-1.64.jar" \
    "$T/antlr-runtime-3.5.2.jar" "$T/antlr-2.7.7.jar" "$T/stringtemplate-3.2.1.jar")
BAKSMALI3_CP=$(cp_of "$AS/plugins/android/lib/smali-baksmali-3.0.9.jar" "$AS/plugins/android/lib/smali-dexlib2-3.0.9.jar" \
    "$AS/plugins/android/lib/smali-util-3.0.9.jar" "$AS/lib/intellij.libraries.guava.jar" "$T/failureaccess-1.0.1.jar" "$T/jcommander-1.64.jar")
DEXLIB_CP=$(cp_of "$AS/plugins/android/lib/smali-dexlib2-3.0.9.jar" "$AS/plugins/android/lib/smali-util-3.0.9.jar" \
    "$AS/lib/intellij.libraries.guava.jar" "$T/failureaccess-1.0.1.jar")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
W=$WORK
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) W=$(cygpath -m "$WORK") ;; esac

javac -cp "$DEXLIB_CP" -d "$W/dexmerge" "$ROOT/tools/dexmerge/DexReplace.java"
python -I -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); z.extractall(sys.argv[2], [n for n in z.namelist() if n.endswith(".dex")])' "$IN" "$W/dex"
for d in "$W"/dex/classes*.dex; do
    n=$(basename "$d" .dex)
    # baksmali 3.x (Android Studio's) reads every class; 2.5.x does not.
    java -cp "$BAKSMALI3_CP" com.android.tools.smali.baksmali.Main d -l -a "$API" "$d" -o "$W/smali/smali_$n"
done

changed=$(python -I "$PATCH" "$W/smali")
[ -n "$changed" ] || { echo "nothing to change"; cp "$IN" "$OUT"; exit 0; }

replaced=""
for dir in $(echo "$changed" | cut -d/ -f1 | sort -u); do
    n=${dir#smali_}
    mkdir -p "$WORK/mini/$dir"
    for f in $(echo "$changed" | grep "^$dir/"); do
        mkdir -p "$WORK/mini/$(dirname "$f")"
        # smali 2.5 does not know the newer hidden-API flags; drop them all
        # here, DexReplace puts each member's original flags back.
        sed -E 's/^(\.(method|field) .*) (whitelist|greylist|blacklist|greylist-max-[a-z]|core-platform-api|test-api)( (whitelist|greylist|blacklist|greylist-max-[a-z]|core-platform-api|test-api))* /\1 /' \
            "$WORK/smali/$f" > "$WORK/mini/$f"
    done
    java -cp "$SMALI_CP" org.jf.smali.Main a -a "$API" "$W/mini/$dir" -o "$W/mini_$n.dex"
    java -cp "$(cp_of "$W/dexmerge" "$DEXLIB_CP")" DexReplace "$API" "$W/dex/$n.dex" "$W/mini_$n.dex" "$W/new_$n.dex"
    replaced="$replaced $n"
done

python -I - "$IN" "$W/members.jar" "$W" $replaced <<'PY'
import sys, zipfile
src, dst, work, *names = sys.argv[1:]
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
    for info in zin.infolist():
        stem = info.filename[:-4] if info.filename.endswith(".dex") else None
        data = open(f"{work}/new_{stem}.dex", "rb").read() if stem in names else zin.read(info.filename)
        zout.writestr(info, data, compress_type=info.compress_type)
print(f"classes replaced in: {' '.join(names)}", file=sys.stderr)
PY
cp "$W/members.jar" "$OUT"
echo "wrote $OUT"
