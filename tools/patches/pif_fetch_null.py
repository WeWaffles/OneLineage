"""Let PixelOS's AttestationService save the certified props it fetches.

PixelOS keeps Play Integrity working by spoofing certified-device props for
Play services. AttestationService$FetchGmsCertifiedProps downloads them and
stores them in Settings.Secure "fetched_pif", which the spoofing hooks read:

    String old = Settings.Secure.getString(cr, "fetched_pif");
    String props = fetchProps();
    if (props != null && !old.equals(props)) putString(cr, "fetched_pif", props);

On a device where the setting was never written, old is null, so the job dies
with a NullPointerException every run and the props are never saved. This
patch swaps the receiver and argument of that equals() call
(props.equals(old)); props is already known to be non-null there.

Usage: pif_fetch_null.py <smali root dir>   (prints the changed file, relative)
"""
import os
import sys

root = sys.argv[1]
NAME = os.path.join("com", "android", "server", "custom", "AttestationService$FetchGmsCertifiedProps.smali")
rel = next((os.path.join(d, NAME) for d in sorted(os.listdir(root))
            if os.path.isfile(os.path.join(root, d, NAME))), None)
if rel is None:
    sys.exit("AttestationService$FetchGmsCertifiedProps not found")
path = os.path.join(root, rel)
src = open(path, encoding="utf-8").read()

# The only equals() in run(): {old, props} -> {props, old}.
OLD = "invoke-virtual {v1, v2}, Ljava/lang/Object;->equals(Ljava/lang/Object;)Z"
NEW = "invoke-virtual {v2, v1}, Ljava/lang/Object;->equals(Ljava/lang/Object;)Z"
if src.count(OLD) != 1:
    sys.exit(f"expected one equals() call, found {src.count(OLD)}")
open(path, "w", encoding="utf-8").write(src.replace(OLD, NEW))
print(rel.replace(os.sep, "/"))
