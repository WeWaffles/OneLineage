"""Give ColorOS's own default runtime permission grants back to OPPO apps.

OplusRuntimePermGrantPolicyManager (oplus-services.jar) grants OPPO's system
apps their runtime permissions on every boot (AppOpsServiceExtImpl
.hookInitializeUidStates -> grantDefaultRuntimePermission; run 34 all.log
16:29:20.325 "PMS start grant runtime and ops for user 0"). It reads the lists
(<packages><default-grant-permissions package=...>) from the my_* partitions
only, through OplusCfgFilePolicy.getCfgLevelList("etc/permissions"), which is
empty without the CUST_LEVEL_LIST environment variable that OPPO's init
exports and the container never has. Run 34: "OplusRuntimePermGrantPolicyManager:
default xmls not found" (16:29:11.463), so nothing was granted. The network
location provider com.oplus.location (my_product/etc/permissions/
oplus_connectivity_default_grant_permissions_list.xml) had no location or
phone permission and its Wi-Fi scans were refused 27 times ("UID 10163 has
no location permission"); Weather asks the network provider first and
timed out after 60 s every time. com.coloros.weather.service had no
background location ("Unauthorized location permission-410005"). 108
permission grants of 35 installed OPPO apps were missing in the guest's
staged access.abx after run 34.

When getCfgLevelList returns nothing and /data/oneos_oplus_grants
exists (guest_prepare.sh creates it in the guest's staged /data unless
ONEOS_GUEST_OPLUS_GRANTS=0), getDefaultPermissionFiles() reads
/my_product/etc/permissions and /my_stock/etc/permissions, the only my_*
permission dirs of this image with grant lists. Everything else is OPPO's own
code, as on the Find N6: system apps (or a matching certificate) only, only
permissions the app requests, nothing the user set or fixed. Setting
CUST_LEVEL_LIST itself would change every OplusCfgFilePolicy user (feature
files, region and carrier configs) at once.

Usage: oplus_default_grants.py <smali root dir>
Prints the smali_* directory (dex file) it changed.
"""
import os
import sys

CLASS = "Lcom/android/server/pm/OplusRuntimePermGrantPolicyManager;"
HEADER = ".method public static getDefaultPermissionFiles()[Ljava/io/File;"
CALL = """    const-string v1, "etc/permissions"

    const/4 v2, -0x1

    invoke-static {v1, v2}, Lcom/oplus/cust/OplusCfgFilePolicy;->getCfgLevelList(Ljava/lang/String;I)Ljava/util/List;

    move-result-object v1
"""
HOOK = f"""
    # OneOS: no CUST_LEVEL_LIST in the container; read my_product and my_stock.
    invoke-static {{v1}}, {CLASS}->oneosGrantDirs(Ljava/util/List;)Ljava/util/List;

    move-result-object v1
"""
HELPER = f"""
.method private static oneosGrantDirs(Ljava/util/List;)Ljava/util/List;
    .locals 3
    .param p0, "dirs"    # Ljava/util/List;

    if-eqz p0, :oneos_check

    invoke-interface {{p0}}, Ljava/util/List;->isEmpty()Z

    move-result v0

    if-nez v0, :oneos_check

    return-object p0

    :oneos_check
    new-instance v0, Ljava/io/File;

    const-string v1, "/data/oneos_oplus_grants"

    invoke-direct {{v0, v1}}, Ljava/io/File;-><init>(Ljava/lang/String;)V

    invoke-virtual {{v0}}, Ljava/io/File;->exists()Z

    move-result v0

    if-nez v0, :oneos_dirs

    return-object p0

    :oneos_dirs
    const/4 v0, 0x2

    new-array v0, v0, [Ljava/lang/String;

    const/4 v1, 0x0

    const-string v2, "/my_product/etc/permissions"

    aput-object v2, v0, v1

    const/4 v1, 0x1

    const-string v2, "/my_stock/etc/permissions"

    aput-object v2, v0, v1

    invoke-static {{v0}}, Ljava/util/Arrays;->asList([Ljava/lang/Object;)Ljava/util/List;

    move-result-object v0

    const-string v1, "OneOS"

    const-string v2, "OPPO default grants: no CUST_LEVEL_LIST, reading /my_product and /my_stock etc/permissions"

    invoke-static {{v1, v2}}, Landroid/util/Slog;->i(Ljava/lang/String;Ljava/lang/String;)I

    return-object v0
.end method
"""


def find(root, rel_suffix):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(rel_suffix)]
    if len(hits) != 1:
        sys.exit(f"expected exactly one {rel_suffix}, found {len(hits)}")
    return hits[0]


def main():
    root = sys.argv[1]
    path = find(root, os.path.join("com", "android", "server", "pm", "OplusRuntimePermGrantPolicyManager.smali"))
    smali = open(path).read()
    start = smali.find(HEADER)
    if start < 0 or smali.count(HEADER) != 1:
        sys.exit("OplusRuntimePermGrantPolicyManager.getDefaultPermissionFiles not found as expected")
    end = smali.index(".end method", start)
    body = smali[start:end]
    if body.count(CALL) != 1:
        sys.exit("getCfgLevelList(\"etc/permissions\") call not found as expected")
    if "oneosGrantDirs" in smali:
        sys.exit("OplusRuntimePermGrantPolicyManager already patched")
    body = body.replace(CALL, CALL + HOOK)
    smali = smali[:start] + body + smali[end:]
    smali = smali.rstrip("\n") + "\n" + HELPER
    open(path, "w").write(smali)
    print("OplusRuntimePermGrantPolicyManager.getDefaultPermissionFiles: my_product/my_stock fallback", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    main()
