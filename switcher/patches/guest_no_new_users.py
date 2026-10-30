"""Never let the guest create secondary users, work profiles or Private Space.

The container shares the host's keystore2, and the guest's system_server runs
as the same system uid as One UI's. For every user or profile it adds, the
framework keeps keys there under fixed aliases built from the user id
(LockSettingsService's profile_key_name_encrypt_<userId> and
profile_key_name_decrypt_<userId>, UnifiedProfilePasswordCache's
com.android.server.locksettings.unified_profile_cache_v2_<userId>, ...). The
guest numbers its users like One UI does (first free id from 10), so a guest
work profile, Private Space or second user would be user 10, 11, ... and its
keys would create, overwrite or delete the keys of One UI's own user or profile
with that id (a work profile, Secure Folder, Dual Messenger): One UI could no
longer unlock that profile. A new user would also get storage keys, app data
and lock enrolments, which all live on the phone's shared vold, installd,
gatekeeper and weaver. The guest is a single-user system and needs none of it.

Every way to add a user ends in UserManagerService's
createUserInternalUncheckedNoTracing(): the binder calls (createUserWithThrow,
createProfileForUserWithThrow, createProfileForUserEvenWhenDisallowedWithThrow,
createRestrictedProfileWithThrow, preCreateUserWithThrow,
createUserWithAttributes: Settings' "Add user" and Private Space, "pm
create-user", managed profile provisioning) and the in-process
UserManagerInternal.createUserEvenWhenDisallowed (DevicePolicyManager's
createAndManageUser, the communal profile) all go through
createUserInternalUnchecked() into it; so does HsumBootUserInitializer, which
only runs in headless system user mode (not on phones). Make the method throw
UserManager.CheckedUserOperationException("OneOS: no users or profiles in the
guest", USER_OPERATION_ERROR_UNKNOWN = 1) at entry, with a Slog.w naming the
refused user type. The method already throws that type for its own refusals
(unknown user type, too many users), so every caller already handles it: binder
callers get a ServiceSpecificException (UserManager.createProfile and friends
return null, Settings shows its "couldn't create" path), DevicePolicyManager and
the communal profile log it. Nothing is done: no user id is taken, no keys,
storage or user files are made.

User 0 never goes through that method. On a first boot readUserListLP() finds
no user list and fallbackToSingleUserLP() builds the system user's UserInfo
(id 0, android.os.usertype.full.SYSTEM) itself and adds it with putUserInfo();
later boots read it back from the user list. The patcher checks this on every
build and fails if it no longer holds: the method's only caller is
createUserInternalUnchecked(); the only method that writes mUsers is
addUserDataLU(), called only from the method itself, putUserInfo() and
readUserListLP(); putUserInfo() is called only from fallbackToSingleUserLP(),
which is called only from readUserListLP(); and neither the constructor nor
that system user path reaches the patched method. Every user/profile entry
point listed above must reach it.

Pixel 17 CP3A (the Pixel 9 Pro XL's komodo build) adds a trailing String[] to
createUserInternalUnchecked() and the method, and a second in-process entry,
UserManagerInternal.createProfileForUserEvenWhenDisallowed; the patcher takes
whichever of the two signatures the build has (exactly one) and checks every
create*User/Profile method as before.

Pixel's services.jar (R8) has the method as public final with p registers and
no debug info; ColorOS's as private, with .param/.line/.local and a Throws
annotation, and an OPPO hook (ensureCanCreateStudyUserOrThrowIfNeeded) first.
Both get the same entry code (v0-v2; the method has far more locals).

Usage: guest_no_new_users.py <smali root dir>
Prints the smali_* directory (dex file) it changed. Diagnostics (the call path
of each entry point, the system user's path) go to stderr; exits non-zero if
any expected method, caller or anchor is missing or differs (fail closed).
"""
import os
import re
import sys

CLS = "Lcom/android/server/pm/UserManagerService;"
LOCAL = "Lcom/android/server/pm/UserManagerService$LocalService;"
UI = "Landroid/content/pm/UserInfo;"
SA = "Ljava/lang/String;"
# (createUserInternalUncheckedNoTracing, createUserInternalUnchecked): Pixel 17
# CD1A and ColorOS 17 CP2A, then Pixel 17 CP3A with a trailing String[].
SIGNATURES = (
    (f"{CLS}->createUserInternalUncheckedNoTracing({SA}{SA}IIZ[{SA}Lcom/android/server/utils/TimingsTraceAndSlog;Ljava/lang/Object;){UI}",
     f"{CLS}->createUserInternalUnchecked({SA}{SA}IIZ[{SA}Ljava/lang/Object;){UI}"),
    (f"{CLS}->createUserInternalUncheckedNoTracing({SA}{SA}IIZ[{SA}Lcom/android/server/utils/TimingsTraceAndSlog;Ljava/lang/Object;[{SA}){UI}",
     f"{CLS}->createUserInternalUnchecked({SA}{SA}IIZ[{SA}Ljava/lang/Object;[{SA}){UI}"),
)
SYSTEM_USER_INFO = f"{UI}-><init>(I{SA}{SA}I{SA})V"
EXC = "Landroid/os/UserManager$CheckedUserOperationException;"
EXC_INIT = f"{EXC}-><init>({SA}I)V"
THROW_HELPER = f"{CLS}->throwCheckedUserOperationException({SA}I)V"
USER_OPERATION_ERROR_UNKNOWN = 1
MESSAGE = "OneOS: no users or profiles in the guest"

# Every user/profile creation entry point (IUserManager's six, UserManagerInternal's one).
ENTRIES = (
    f"{CLS}->createUserWithThrow({SA}{SA}I){UI}",
    f"{CLS}->createProfileForUserWithThrow({SA}{SA}II[{SA}){UI}",
    f"{CLS}->createProfileForUserEvenWhenDisallowedWithThrow({SA}{SA}II[{SA}){UI}",
    f"{CLS}->createRestrictedProfileWithThrow({SA}I){UI}",
    f"{CLS}->preCreateUserWithThrow({SA}){UI}",
    f"{CLS}->createUserWithAttributes({SA}{SA}ILandroid/graphics/Bitmap;{SA}{SA}Landroid/os/PersistableBundle;)Landroid/os/UserHandle;",
    f"{LOCAL}->createUserEvenWhenDisallowed({SA}{SA}I[{SA}Ljava/lang/Object;){UI}",
)
# Any other user/profile creation-looking method of UserManagerService (or its
# inner classes) must reach the patched method too.
CREATE_NAME = re.compile(r"^(?:create|preCreate)\w*(?:User|Profile)\w*$")

MODS = r"(?:private |public |protected |final |static |synchronized )*"
INVOKE = re.compile(r"^\s*invoke-[a-z-]+(?:/range)? \{([^}]*)\}, (L[^;\s]+;->\S+)$")
# mUsers itself, or the accessor inner classes use to reach it.
USERS_REFS = (f"{CLS}->mUsers:Landroid/util/SparseArray;", f"{CLS}->-$$Nest$fgetmUsers(")
SPARSE_WRITE = re.compile(r"Landroid/util/SparseArray;->(?:put|append|set|setValueAt|putAll)\(")
# A SparseArray write and the register it writes to (invoke's first register).
SPARSE_WRITE_RECV = re.compile(r"^\s*invoke-\S+ \{(v\d+|p\d+)[,}].*Landroid/util/SparseArray;->(?:put|append|set|setValueAt|putAll)\(")
# What last went into a register: a fresh SparseArray, or anything else.
NEW_SPARSE = re.compile(r"^\s*new-instance (v\d+), Landroid/util/SparseArray;")
ASSIGN = re.compile(r"^\s*(?:const\S*|move\S*|new-\S+|[ais]get\S*|check-cast|instance-of|array-length) (v\d+|p\d+)(?:,|$)")


def writes_only_fresh_arrays(body):
    """Every SparseArray write in body goes to an array made with new-instance in it.

    A linear scan of the most recent assignment of each register (fail closed:
    a register last loaded from anything else, or never assigned here, counts
    as possibly mUsers). HyperOS's repairProfileGroupIdIfNecessaryLP copies the
    users into a new SparseArray this way, for XSpace's repair, and only saves
    existing users (writeUserLP): no user is added.
    """
    fresh = {}
    for line in body:
        m = SPARSE_WRITE_RECV.search(line)
        if m and not fresh.get(m.group(1), False):
            return False
        m = NEW_SPARSE.search(line)
        if m:
            fresh[m.group(1)] = True
            continue
        m = ASSIGN.search(line)
        if m:
            fresh[m.group(1)] = False
    return True
# An instruction whose first register is a destination.
WRITES = r"^\s*(?:const\S*|move\S*|new-\S+|[ais]get\S*|instance-of|array-length|neg-\S+|not-\S+|\S+-to-\S+|(?:add|sub|rsub|mul|div|rem|and|or|xor|shl|shr|ushr)-\S+|cmp\S*) {r}(?:,|$)"


def name_of(key):
    return key.split("->", 1)[1].split("(", 1)[0]


def label(key):
    """UserManagerService$LocalService.createUserEvenWhenDisallowed for a method key."""
    return f"{key.split('->', 1)[0].rsplit('/', 1)[-1][:-1]}.{name_of(key)}"


def regs_of(line):
    """The argument registers of an invoke line, /range expanded."""
    regs = INVOKE.match(line).group(1).strip()
    m = re.match(r"^([vp])(\d+) \.\. \1(\d+)$", regs)
    if m:
        return [f"{m.group(1)}{n}" for n in range(int(m.group(2)), int(m.group(3)) + 1)]
    return [r.strip() for r in regs.split(",") if r.strip()]


def last_write(lines, reg, call, start):
    """The last instruction before lines[call] (scanning back to start) that writes reg."""
    writes = re.compile(WRITES.format(r=re.escape(reg)))
    return next((lines[k].strip() for k in range(call - 1, start, -1) if writes.match(lines[k])), None)


def scan(root):
    """Methods and invoke edges of every class that references UserManagerService."""
    defs = {}      # method key -> (path, header index, end index)
    edges = {}     # caller key -> [callee keys]
    callers = {}   # callee key -> [caller keys], one per call site
    files = {}     # path -> lines
    ref = CLS[:-1] + ";->"
    for dirpath, _, names in os.walk(root):
        for name in names:
            if not name.endswith(".smali"):
                continue
            path = os.path.join(dirpath, name)
            with open(path) as f:
                text = f.read()
            if ref not in text:
                continue
            lines = text.split("\n")
            cls = next((l.split()[-1] for l in lines if l.startswith(".class ")), None)
            if cls is None:
                sys.exit(f"{path}: no .class line")
            files[path] = lines
            key = None
            for i, line in enumerate(lines):
                if line.startswith(".method "):
                    key = f"{cls}->{line.split()[-1]}"
                    if key in defs:
                        sys.exit(f"{path}: {key} defined twice")
                    defs[key] = [path, i, None]
                    edges[key] = []
                elif line.startswith(".end method"):
                    if key is None:
                        sys.exit(f"{path}:{i + 1}: .end method outside a method")
                    defs[key][2] = i
                    key = None
                elif key is not None:
                    m = INVOKE.match(line)
                    if m:
                        edges[key].append(m.group(2))
                        callers.setdefault(m.group(2), []).append(key)
    return defs, edges, callers, files


def path_to(edges, start, target):
    """The call path from start to target through the scanned methods, or None."""
    parent = {start: None}
    todo = [start]
    while todo:
        k = todo.pop(0)
        if k == target:
            out = []
            while k is not None:
                out.append(name_of(k))
                k = parent[k]
            return out[::-1]
        for c in edges.get(k, ()):
            if c not in parent and c in edges:
                parent[c] = k
                todo.append(c)
    return None


def only_called_from(callers, callee, allowed, what):
    sites = callers.get(callee, [])
    names = sorted({name_of(c) if c.startswith(CLS + "->") else c for c in sites})
    if not sites or any(not c.startswith(CLS + "->") or name_of(c) not in allowed for c in sites):
        sys.exit(f"UserManagerService.{name_of(callee)} called from {names or 'nowhere'}, expected only {sorted(allowed)}: {what}")
    return names


def check_system_user_path(defs, edges, callers, files, funnel):
    """Prove that adding user 0 (first boot or later boots) never reaches the patched method."""
    def key(name):
        found = [k for k in defs if k.startswith(f"{CLS}->{name}(")]
        if not found:
            sys.exit(f"UserManagerService.{name} not found")
        return found
    writers = []
    for k, (path, i, j) in defs.items():
        body = files[path][i:j]
        if any(r in l for l in body for r in USERS_REFS) and any(SPARSE_WRITE.search(l) for l in body):
            if writes_only_fresh_arrays(body):
                print(f"{label(k)} reads mUsers and writes only a SparseArray of its own: not a writer", file=sys.stderr)
                continue
            writers.append(label(k))
    if writers != ["UserManagerService.addUserDataLU"]:
        sys.exit(f"methods writing UserManagerService.mUsers are {writers}, expected only addUserDataLU")
    adders = set()
    for add in key("addUserDataLU"):
        adders |= set(only_called_from(callers, add, {"createUserInternalUncheckedNoTracing", "putUserInfo", "readUserListLP"},
                                       "a user could be added outside the patched method"))
    if "createUserInternalUncheckedNoTracing" not in adders:
        sys.exit("UserManagerService: createUserInternalUncheckedNoTracing does not call addUserDataLU, unexpected build")
    for put in key("putUserInfo"):
        only_called_from(callers, put, {"fallbackToSingleUserLP"}, "a user could be added outside the patched method")
    for fb in key("fallbackToSingleUserLP"):
        only_called_from(callers, fb, {"readUserListLP"}, "unexpected system user path")
        path, i, j = defs[fb]
        lines = files[path]
        ctor = [k for k in range(i, j) if INVOKE.match(lines[k]) and INVOKE.match(lines[k]).group(2) == SYSTEM_USER_INFO]
        if len(ctor) != 1 or not any('"android.os.usertype.full.SYSTEM"' in l for l in lines[i:j]) \
                or not any("->putUserInfo(" in l for l in lines[ctor[0]:j]):
            sys.exit("UserManagerService.fallbackToSingleUserLP does not build the system user itself, unexpected build")
        # new UserInfo(id, name, iconPath, flags, userType): id is the first argument after the object.
        regs = regs_of(lines[ctor[0]])
        first = last_write(lines, regs[1], ctor[0], i) if len(regs) == 6 else None
        if first != f"const/4 {regs[1]}, 0x0":
            sys.exit(f"UserManagerService.fallbackToSingleUserLP: UserInfo id set by {first!r}, expected user 0")
    starts = key("<init>") + key("readUserListLP") + key("fallbackToSingleUserLP") + key("putUserInfo") + key("addUserDataLU")
    for s in starts:
        p = path_to(edges, s, funnel)
        if p:
            sys.exit(f"the system user path reaches the patched method: {' -> '.join(p)}")
    shown = {" -> ".join(p) for p in (path_to(edges, k, key("putUserInfo")[0]) for k in key("<init>")) if p}
    if not shown:
        sys.exit("UserManagerService: the constructor does not reach putUserInfo, unexpected build")
    for p in sorted(shown, key=len)[:1]:
        print(f"system user (first boot): {p} -> addUserDataLU, new UserInfo(0, ...) built in "
              "fallbackToSingleUserLP; later boots: readUserListLP -> addUserDataLU", file=sys.stderr)
    print(f"none of {sorted({name_of(s) for s in starts})} reaches createUserInternalUncheckedNoTracing", file=sys.stderr)


def check_entries(defs, edges, callers, funnel, unchecked):
    if callers.get(funnel, []) != [unchecked]:
        sys.exit(f"createUserInternalUncheckedNoTracing called from {callers.get(funnel, [])}, expected once from createUserInternalUnchecked")
    entries = list(ENTRIES)
    for k in defs:
        cls = k.split("->", 1)[0]
        if (cls == CLS or cls.startswith(CLS[:-1] + "$")) and CREATE_NAME.match(name_of(k)) \
                and k not in entries and k not in (funnel, unchecked):
            entries.append(k)
    for k in entries:
        if k not in defs:
            sys.exit(f"entry point {k} not found, unexpected build")
        p = path_to(edges, k, funnel)
        if not p:
            sys.exit(f"entry point {k} does not reach createUserInternalUncheckedNoTracing: a user could be created around the guard")
        print(f"entry {label(k)}: {' -> '.join(p[1:])}", file=sys.stderr)
    return len(entries)


def body_start(lines, i, end):
    """First line after the method's .locals/.param/.annotation block."""
    j, ann = i + 1, False
    while j < end:
        s = lines[j].strip()
        if ann:
            ann = s != ".end annotation"
        elif s.startswith(".annotation"):
            ann = True
        elif not (s == "" or s.startswith((".locals", ".registers", ".param", ".end param", ".prologue"))):
            return j
        j += 1
    sys.exit("createUserInternalUncheckedNoTracing has no code")


def check_error_unknown(lines, i, end):
    """The method's own refusal of an invalid user type uses USER_OPERATION_ERROR_UNKNOWN = 1."""
    anchor = [k for k in range(i, end) if '"Cannot create user of invalid user type: "' in lines[k]]
    if len(anchor) != 1:
        sys.exit("createUserInternalUncheckedNoTracing: invalid user type message not found exactly once")
    call = next((k for k in range(anchor[0], end) if lines[k].strip().endswith(THROW_HELPER)), None)
    if call is None:
        sys.exit("createUserInternalUncheckedNoTracing: no throwCheckedUserOperationException after the invalid user type message")
    regs = regs_of(lines[call])
    if len(regs) != 3:
        sys.exit("createUserInternalUncheckedNoTracing: unexpected throwCheckedUserOperationException call")
    last = last_write(lines, regs[2], call, i)
    if last != f"const/4 {regs[2]}, {hex(USER_OPERATION_ERROR_UNKNOWN)}":
        sys.exit(f"createUserInternalUncheckedNoTracing: invalid user type refused with {last!r}, expected USER_OPERATION_ERROR_UNKNOWN = 1")


def main(root):
    defs, edges, callers, files = scan(root)
    ums = [p for p, ls in files.items() if any(l.startswith(".class ") and l.split()[-1] == CLS for l in ls)]
    if len(ums) != 1:
        sys.exit(f"expected one UserManagerService.smali, found {len(ums)}")
    path = ums[0]
    lines = files[path]
    if any(MESSAGE in l for l in lines):
        sys.exit(f"{path}: already patched")
    found = [(f, u) for f, u in SIGNATURES if f in defs]
    if len(found) != 1:
        have = sorted(k.split("->", 1)[1] for k in defs if k.startswith(f"{CLS}->createUserInternalUncheckedNoTracing("))
        sys.exit(f"{path}: createUserInternalUncheckedNoTracing with a known signature found {len(found)} times, expected once (have {have})")
    funnel, unchecked = found[0]
    header = re.compile(rf"^\.method {MODS}" + re.escape(funnel.split("->", 1)[1]) + "$")
    heads = [k for k, l in enumerate(lines) if header.match(l)]
    if len(heads) != 1:
        sys.exit(f"{path}: createUserInternalUncheckedNoTracing found {len(heads)} times, expected once")
    i = heads[0]
    end = defs[funnel][2]
    n = check_entries(defs, edges, callers, funnel, unchecked)
    check_system_user_path(defs, edges, callers, files, funnel)
    if not any(l.strip().endswith(EXC_INIT) for l in lines):
        sys.exit(f"{path}: CheckedUserOperationException(String, int) not used, unexpected build")
    if not any(l.strip().endswith(THROW_HELPER) for l in lines[i:end]):
        sys.exit(f"{path}: createUserInternalUncheckedNoTracing does not throw CheckedUserOperationException, unexpected build")
    check_error_unknown(lines, i, end)
    locals_ = [re.match(r"\s*\.locals (\d+)$", l) for l in lines[i + 1:end]]
    locals_ = [int(m.group(1)) for m in locals_ if m]
    if len(locals_) != 1 or locals_[0] < 3:
        sys.exit(f"{path}: unexpected createUserInternalUncheckedNoTracing header (.locals {locals_})")
    j = body_start(lines, i, end)
    lines[j:j] = [
        "    # OneOS: no secondary users or profiles in the guest: their keys would land in the",
        "    # phone's keystore2 under the aliases of One UI's own users with the same ids.",
        '    const-string v0, "UserManagerService"',
        "",
        "    move-object/from16 v1, p2",
        "",
        "    invoke-static {v1}, Ljava/lang/String;->valueOf(Ljava/lang/Object;)Ljava/lang/String;",
        "",
        "    move-result-object v1",
        "",
        f'    const-string v2, "{MESSAGE}; refused a user of type "',
        "",
        "    invoke-virtual {v2, v1}, Ljava/lang/String;->concat(Ljava/lang/String;)Ljava/lang/String;",
        "",
        "    move-result-object v1",
        "",
        "    invoke-static {v0, v1}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I",
        "",
        f"    new-instance v0, {EXC}",
        "",
        f'    const-string v1, "{MESSAGE}"',
        "",
        f"    const/4 v2, {hex(USER_OPERATION_ERROR_UNKNOWN)}",
        "",
        f"    invoke-direct {{v0, v1, v2}}, {EXC_INIT}",
        "",
        "    throw v0",
        "",
    ]
    with open(path, "w") as f:
        f.write("\n".join(lines))
    print(f"{os.path.relpath(path, root)}: createUserInternalUncheckedNoTracing throws at entry "
          f"({n} entry points checked)", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit("usage: guest_no_new_users.py <smali root dir>")
    main(sys.argv[1])
