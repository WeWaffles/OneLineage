"""Stop binding PixelOS's synthetic password keys to a gatekeeper auth token.

Once a user has a PIN, SyntheticPasswordCrypto.createBlob(alias, data,
protectorSecret, sid) imports the protector key into keystore with
setUserAuthenticationRequired + setBoundToSpecificSecureUserId(sid). KeyMint
(the host's TEE, bridged) then only lets the key decrypt after it sees an auth
token MAC'd with its own HMAC key. The guest's gatekeeper is software
(native/ol_bridge/soft_gk.h) and cannot produce that MAC, so the correct PIN
was accepted and the unlock still failed with KEY_USER_NOT_AUTHENTICATED.

This patch zeroes sid at the top of createBlob, so the key is stored without
auth binding. The blob is still encrypted with the PIN-derived protector
secret, so the PIN still protects it.

Usage: sp_no_auth_bound.py <smali root dir>   (prints the changed file, relative)
"""
import os
import re
import sys

root = sys.argv[1]
NAME = os.path.join("com", "android", "server", "locksettings", "SyntheticPasswordCrypto.smali")
rel = next((os.path.join(d, NAME) for d in sorted(os.listdir(root))
            if os.path.isfile(os.path.join(root, d, NAME))), None)
if rel is None:
    sys.exit("SyntheticPasswordCrypto not found")
path = os.path.join(root, rel)
src = open(path, encoding="utf-8").read()

HEAD = ".method public static createBlob(Ljava/lang/String;[B[BJ)[B\n"
MARK = "    # ol: no auth binding\n"
if src.count(HEAD) != 1:
    sys.exit("createBlob not found exactly once")
if MARK not in src:
    start = src.index(HEAD)
    m = re.compile(r"    \.(?:registers|locals) \d+\n").search(src, start)
    src = src[:m.end()] + MARK + "    const-wide/16 p3, 0x0\n" + src[m.end():]
    open(path, "w", encoding="utf-8").write(src)
print(rel.replace(os.sep, "/"))
