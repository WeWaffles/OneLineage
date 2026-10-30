"""Start the guest's new app ids at 15000, above every One UI app's uid.

The container shares the host's keystore2, and keystore2 files each app's keys
under the app's uid. The guest's package manager numbers its apps from 10000
up, as One UI did for its own (10000..~10700 on the Z Fold tested), so a guest
app with uid 10123 would share a key namespace with whichever One UI app holds
10123: it could list, use, overwrite or delete that app's keys (a banking
app's, Samsung Pass's, Google's), and the One UI app would find the guest
app's keys among its own.

AppIdSettingMap.acquireAndRegisterNewAppId() is where every new app id comes
from: packages (Settings.registerAppIdLPw) and shared users
(Settings.getSharedUserLPw, e.g. com.google.uid.shared). It scans
mNonSystemSettings from index mFirstAvailableAppId - 10000 for a null slot and
returns index + 10000; with no free slot it appends (index = size), unless the
list already has 10000 entries (LAST_APPLICATION_UID 19999), and then returns
-1. At its entry the patch pads the list with null slots up to index 5000, as
registerExistingAppId pads for an id read from packages.xml, and raises
mFirstAvailableAppId to 15000. The original code then runs unchanged: both the
scan and the append can only hand out 15000 and up, and the 19999 bound and
its -1 failure are untouched. SDK sandbox uids (app uid + 10000) follow, from
25000. System shared users (android.uid.system, phone, ...) keep their fixed
ids below 10000, which are One UI's too. Ids a stage's packages.xml already
lists are kept: only a fresh stage gets 15000 and up throughout. Isolated
processes (uids 90000..99999) are not app ids and still overlap One UI's, but
they get no keystore2 access.

Pixel's services.jar (R8) has the same method with public fields and p0 reused
for the list; ColorOS's has private fields and debug info. The whole loop is
matched with any registers, so a build that allocates differently fails here
instead of being half-patched; the inserted code uses only v0 and v1 before the
method's first instruction, where neither holds anything yet.

Usage: guest_app_id_offset.py <smali root dir>
Prints the smali_* directory (dex file) it changed.
"""
import os
import re
import sys

SUFFIX = os.path.join("com", "android", "server", "pm", "AppIdSettingMap.smali")
CLS = "Lcom/android/server/pm/AppIdSettingMap;"
WAL = "Lcom/android/server/utils/WatchedArrayList;"
HEADER = re.compile(r"^\.method (?:private |public |protected |final |static |synchronized )*"
                    r"acquireAndRegisterNewAppId\(Lcom/android/server/pm/SettingBase;\)I$")
FIRST_INDEX = 5000  # app id 15000

R = r"[vp]\d+"
L = re.escape(f"{CLS}->mNonSystemSettings:{WAL}")
F = re.escape(f"{CLS}->mFirstAvailableAppId:I")
W = re.escape(WAL)
# The stock method, one instruction or label per line (debug info dropped):
#   size = list.size(); for (i = mFirstAvailableAppId - 10000; i < size; i++)
#   if (list.get(i) == null) { list.set(i, obj); return i + 10000; }
#   if (size > 9999) return -1; list.add(obj); return size + 10000;
LOOP = re.compile("\n".join([
    rf"iget-object (?P<l0>{R}), p0, {L}",
    rf"invoke-virtual \{{(?P=l0)\}}, {W}->size\(\)I",
    rf"move-result (?P<size>{R})",
    rf"iget (?P<first>{R}), p0, {F}",
    rf"add-int/lit16 (?P<i>{R}), (?P=first), -0x2710",
    r"(?P<loop>:\w+)",
    r"if-ge (?P=i), (?P=size), (?P<full>:\w+)",
    rf"iget-object (?P<l1>{R}), p0, {L}",
    rf"invoke-virtual \{{(?P=l1), (?P=i)\}}, {W}->get\(I\)Ljava/lang/Object;",
    rf"move-result-object (?P<o>{R})",
    r"if-nez (?P=o), (?P<next>:\w+)",
    rf"iget-object (?P<l2>{R}), p0, {L}",
    rf"invoke-virtual \{{(?P=l2), (?P=i), p1\}}, {W}->set\(ILjava/lang/Object;\)Ljava/lang/Object;",
    rf"add-int/lit16 (?P<r1>{R}), (?P=i), 0x2710",
    r"return (?P=r1)",
    r"(?P=next)",
    r"add-int/lit8 (?P=i), (?P=i), 0x1",
    r"goto(?:/16|/32)? (?P=loop)",
    r"(?P=full)",
    rf"const/16 (?P<k>{R}), 0x270f",
    r"if-le (?P=size), (?P=k), (?P<append>:\w+)",
    rf"const/4 (?P<m>{R}), -0x1",
    r"return (?P=m)",
    r"(?P=append)",
    rf"iget-object (?P<l3>{R}), p0, {L}",
    rf"invoke-virtual \{{(?P=l3), p1\}}, {W}->add\(Ljava/lang/Object;\)Z",
    rf"add-int/lit16 (?P<r2>{R}), (?P=size), 0x2710",
    r"return (?P=r2)",
]))
DEBUG = (".line ", ".local ", ".end local ", ".restart local ", ".param ", ".end param", ".prologue")


def instructions(body):
    """The method's instructions and labels, without debug info and annotations."""
    out, in_annotation = [], False
    for line in body:
        s = line.strip()
        if in_annotation:
            in_annotation = not s.startswith(".end annotation")
            continue
        if s.startswith(".annotation"):
            in_annotation = True
            continue
        if not s or s.startswith("#") or s.startswith(DEBUG):
            continue
        out.append(s)
    return out


def entry(lines, i):
    """Index of the first line after the header, .locals and the .param blocks."""
    j, in_param = i + 2, False
    while True:
        s = lines[j].strip()
        if in_param:
            in_param = not s.startswith(".end param")
        elif s.startswith(".param ") and j + 1 < len(lines) and lines[j + 1].strip().startswith(".annotation"):
            in_param = True
        elif not (s == "" or s.startswith((".param ", ".prologue"))):
            return j
        j += 1


def main(root):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(os.sep + SUFFIX)]
    if len(hits) != 1:
        sys.exit(f"expected one AppIdSettingMap.smali, found {len(hits)}")
    path = hits[0]
    rel = os.path.relpath(path, root)
    with open(path) as f:
        lines = f.read().split("\n")
    if not any(l.startswith(".class ") and l.endswith(CLS) for l in lines):
        sys.exit(f"{rel}: not {CLS}")
    if any("oneos_appid" in l for l in lines):
        sys.exit(f"{rel}: already patched")
    heads = [k for k, l in enumerate(lines) if HEADER.match(l)]
    if len(heads) != 1:
        sys.exit(f"{rel}: acquireAndRegisterNewAppId(SettingBase) found {len(heads)} times, expected once")
    i = heads[0]
    m = re.match(r"\s*\.locals (\d+)$", lines[i + 1])
    if not m or int(m.group(1)) < 2:
        sys.exit(f"{rel}: acquireAndRegisterNewAppId: expected .locals >= 2 after the header")
    end = lines.index(".end method", i)
    code = LOOP.fullmatch("\n".join(instructions(lines[i + 2:end])))
    if not code:
        sys.exit(f"{rel}: acquireAndRegisterNewAppId is not the expected scan-then-append loop "
                 "(index = mFirstAvailableAppId - 10000, bound 9999, -1 when full); not patched")
    print(f"{rel}: loop index {code['i']} from mFirstAvailableAppId, size {code['size']}, "
          f"returns {code['r1']} / {code['r2']} / -1 in {code['m']}", file=sys.stderr)
    j = entry(lines, i)
    lines[j:j] = [
        "    # OneOS: keystore2 is One UI's and keys live under the app's uid; One UI's apps",
        "    # hold 10000 and up, so the guest's new app ids start at 15000 (index 5000).",
        f"    iget v0, p0, {CLS}->mFirstAvailableAppId:I",
        "",
        f"    const/16 v1, {hex(10000 + FIRST_INDEX)}",
        "",
        "    if-ge v0, v1, :oneos_appid_first_ok",
        "",
        f"    iput v1, p0, {CLS}->mFirstAvailableAppId:I",
        "",
        "    :oneos_appid_first_ok",
        f"    iget-object v0, p0, {CLS}->mNonSystemSettings:{WAL}",
        "",
        f"    invoke-virtual {{v0}}, {WAL}->size()I",
        "",
        "    move-result v1",
        "",
        f"    add-int/lit16 v1, v1, -{hex(FIRST_INDEX)}",
        "",
        "    if-gez v1, :oneos_appid_padded",
        "",
        '    const-string v0, "PackageManager"',
        "",
        '    const-string v1, "OneOS: new app ids start at 15000, above One UI\'s apps (shared keystore2)"',
        "",
        "    invoke-static {v0, v1}, Landroid/util/Slog;->i(Ljava/lang/String;Ljava/lang/String;)I",
        "",
        "    # Null slots up to index 5000, as registerExistingAppId pads.",
        "    :oneos_appid_pad",
        f"    iget-object v0, p0, {CLS}->mNonSystemSettings:{WAL}",
        "",
        f"    invoke-virtual {{v0}}, {WAL}->size()I",
        "",
        "    move-result v1",
        "",
        f"    add-int/lit16 v1, v1, -{hex(FIRST_INDEX)}",
        "",
        "    if-gez v1, :oneos_appid_padded",
        "",
        "    const/4 v1, 0x0",
        "",
        f"    invoke-virtual {{v0, v1}}, {WAL}->add(Ljava/lang/Object;)Z",
        "",
        "    goto :oneos_appid_pad",
        "",
        "    :oneos_appid_padded",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines))
    print(f"{rel}: acquireAndRegisterNewAppId hands out app ids from 15000", file=sys.stderr)
    print(rel.split(os.sep)[0])


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: guest_app_id_offset.py <smali root dir>")
    main(sys.argv[1])
