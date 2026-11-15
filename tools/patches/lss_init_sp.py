"""Let PixelOS create the synthetic password for an unsecured user.

Every screen lock credential is wrapped around a synthetic password (SP)
that LockSettingsService creates for each user. For user 0 that happens in
migrateUserToSpWithBoundKeysLocked(), called from onThirdPartyAppsStarted()
until the "migrated_all_users_to_sp_and_bound_keys" flag is saved.

That method was stubbed to return-void back when the guest shared One UI's
gatekeeper and Weaver: creating an SP there could touch One UI's lock state.
Isolated mode now gives the guest its own software gatekeeper and a failing
Weaver stub (native/ol_bridge), so the SP stays inside the guest's /data.
With the stub, the guest had no SP and "Synthetic password not found for
user 0" failed every attempt to set a PIN.

This patch restores the part that matters: if the user has no credential and
no SP yet, call initializeSyntheticPassword(userId). Any failure is swallowed
so system_server can never crash here. Guests that already booted with the
stub saved the "done" flag, so onThirdPartyAppsStarted() reads and writes a
new flag name instead, which makes the migration run once more on them.

Usage: lss_init_sp.py <smali root dir>   (prints the changed file, relative)
"""
import os
import re
import sys

root = sys.argv[1]
NAME = os.path.join("com", "android", "server", "locksettings", "LockSettingsService.smali")
rel = next((os.path.join(d, NAME) for d in sorted(os.listdir(root))
            if os.path.isfile(os.path.join(root, d, NAME))), None)
if rel is None:
    sys.exit("LockSettingsService not found")
path = os.path.join(root, rel)
src = open(path, encoding="utf-8").read()

LSS = "Lcom/android/server/locksettings/LockSettingsService;"
HEAD = ".method public final migrateUserToSpWithBoundKeysLocked(I)V\n"
BODY = f"""{HEAD}    .registers 6

    :try_start
    invoke-virtual {{p0, p1}}, {LSS}->isUserSecure(I)Z
    move-result v0
    if-nez v0, :done
    invoke-virtual {{p0, p1}}, {LSS}->getCurrentLskfBasedProtectorId(I)J
    move-result-wide v0
    const-wide/16 v2, 0x0
    cmp-long v0, v0, v2
    if-nez v0, :done
    invoke-virtual {{p0, p1}}, {LSS}->initializeSyntheticPassword(I)Lcom/android/server/locksettings/SyntheticPasswordManager$SyntheticPassword;
    :try_end
    .catch Ljava/lang/Throwable; {{:try_start .. :try_end}} :done

    :done
    return-void
"""
if src.count(HEAD) != 1:
    sys.exit("migrateUserToSpWithBoundKeysLocked not found exactly once")
start = src.index(HEAD)
end = src.index(".end method", start)
if "initializeSyntheticPassword" not in src[start:end]:
    src = src[:start] + BODY + src[end:]
    OLD_FLAG = '"migrated_all_users_to_sp_and_bound_keys"'
    if src.count(OLD_FLAG) != 2:
        sys.exit(f"expected the migration flag twice, found {src.count(OLD_FLAG)}")
    src = src.replace(OLD_FLAG, '"ol_migrated_all_users_to_sp_v1"')
    open(path, "w", encoding="utf-8").write(src)
print(rel.replace(os.sep, "/"))
