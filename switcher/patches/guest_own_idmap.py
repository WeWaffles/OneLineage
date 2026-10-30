"""Let the guest's overlay manager use the guest's own idmap2d.

IdmapDaemon starts and stops the "idmap2d" init service through
SystemService.start/stop. In the container that is the HOST init, which
starts One UI's idmap2d in One UI's mount namespace: it cannot see the
guest's /my_product, /my_stock or /system/system_ext overlays, so no overlay
ever applied (9241 "failed to read IDMAP" in run 25), and it wrote into One
UI's /data/resource-cache. guest_start.sh now runs the guest's
/system/bin/idmap2d for the whole session; drop the start/stop calls so the
overlay manager just uses that one. (Pixel's IdmapDaemon passes the name in p0.)

Usage: guest_own_idmap.py <smali root dir>
Prints the smali_* directory it changed.
"""
import os
import re
import sys

SUFFIX = os.path.join("com", "android", "server", "om", "IdmapDaemon.smali")
CALL = re.compile(r"^\s*invoke-static \{[vp]\d+\}, Landroid/os/SystemService;->(start|stop)\(Ljava/lang/String;\)V\s*$")


def main(root):
    hits = [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs
            if os.path.join(d, f).endswith(os.sep + SUFFIX)]
    if len(hits) != 1:
        sys.exit(f"expected one IdmapDaemon.smali, found {len(hits)}")
    path = hits[0]
    lines = open(path).read().split("\n")
    n = 0
    for i, line in enumerate(lines):
        m = CALL.match(line)
        if m:
            lines[i] = f"    # OneOS: SystemService.{m.group(1)}(idmap2d) dropped (host init; the guest runs its own)"
            n += 1
    if n != 2:
        sys.exit(f"IdmapDaemon: expected 2 SystemService start/stop calls, found {n}")
    open(path, "w").write("\n".join(lines))
    print("IdmapDaemon: idmap2d start/stop dropped", file=sys.stderr)
    print(os.path.relpath(path, root).split(os.sep)[0])


if __name__ == "__main__":
    main(sys.argv[1])
