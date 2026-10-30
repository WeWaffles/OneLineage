#!/usr/bin/env python3
"""Build out/overlays/oneos_bootanimation.zip: the OneOS boot splash.

ColorOS's bootanimation (ro.commonsoft.bootanimation=oplus) looks for
/data/local/bootanimation.zip before its own
/my_product/media/bootanimation/bootanimation.zip (run 30 logcat, pid 24605:
"Unable to open '/data/local/bootanimation.zip'" then "got animation resource
as designed:/my_product/..."). oneos_switch.sh copies this zip into the
staged /data, so the guest's boot animation shows OneOS instead of "Find N".

The zip copies the layout of ColorOS's own file, the only one known to play on
this panel: STORE entries, a desc.txt in OPPO's format
("g width height offsetx offsety fps", then "p count pause part"), 8-bit
palette PNGs, part0 played once, part1 looped until the boot ends.

Stdlib only (no PIL on the build server). The wordmark is drawn from strokes
(signed distance, anti-aliased), and every frame shares the same pixels: only
the PNG palette changes, which is how the fade-in and the loading dots move.

Usage: scripts/make-bootsplash.py [out.zip] [--preview preview.png] [--static]

--static: one still frame (the wordmark, no dots) in the plain AOSP desc.txt
format ("width height fps", "p 0 0 part0"). For the black gap before the guest
draws anything, switcher/build_apk.sh takes its --preview PNG for the
switcher's SplashActivity, on which oneos_switch.sh freezes the panel
(ColorOS's own animation stays). Nothing plays the zip itself: Samsung's
bootanimation only plays QMG files, and ColorOS's only shows desc.txt parse
strings for OPPO's "g w h offx offy fps" / "p" / "c" lines.
"""
import math, os, struct, sys, zipfile, zlib

W, H = 2248, 718            # the band ColorOS's own animation uses (desc.txt "g 2248 718 0 533 60")
OFFY = (2504 - H) // 2      # centred on the 2256x2504 inner panel
FPS = 60
INTRO, LOOP = 40, 90        # part0: fade-in (0.67 s), part1: loading dots (1.5 s), looped

CAP = 300                   # cap height of the wordmark (px)
STROKE = 36
HALF = STROKE / 2
XH = round(CAP * 0.68)      # x-height for "ne"
GAP = 26                    # letter spacing
BASE = 470                  # baseline inside the band
DOTS_Y = 556                # loading dots under the wordmark
DOT_R = 11

WHITE = (250, 250, 250)
ACCENT = (90, 169, 255)     # "OS" and the dots

# Palette groups: index = group base + coverage level. Level 0 of every group
# is black, so index 0 is the background.
GROUPS = {"one": (0, 64), "os": (64, 64), "d0": (128, 42), "d1": (170, 43), "d2": (213, 43)}


def cov(d, half):
    return min(1.0, max(0.0, half - d + 0.5))


def seg(ax, ay, bx, by):
    def dist(x, y):
        dx, dy = bx - ax, by - ay
        t = ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)
        t = min(1.0, max(0.0, t))
        return math.hypot(x - ax - t * dx, y - ay - t * dy)
    return dist, (min(ax, bx), min(ay, by), max(ax, bx), max(ay, by))


def arc(cx, cy, r, a0, a1):
    """Arc from a0 to a1 degrees, counter-clockwise, y pointing up; round ends."""
    e0 = (cx + r * math.cos(math.radians(a0)), cy - r * math.sin(math.radians(a0)))
    e1 = (cx + r * math.cos(math.radians(a1)), cy - r * math.sin(math.radians(a1)))
    span = (a1 - a0) % 360 or 360

    def dist(x, y):
        a = math.degrees(math.atan2(cy - y, x - cx))
        if (a - a0) % 360 <= span:
            return abs(math.hypot(x - cx, y - cy) - r)
        return min(math.hypot(x - e0[0], y - e0[1]), math.hypot(x - e1[0], y - e1[1]))
    return dist, (cx - r, cy - r, cx + r, cy + r)


def wordmark():
    """'OneOS' as strokes: [(group, distance function, bbox, half width)]."""
    prims = []
    x = (W - (CAP + 176 + XH + CAP + 168 + 4 * GAP)) / 2

    def add(group, p, half=HALF):
        prims.append((group, p[0], p[1], half))

    r_o = (CAP - STROKE) / 2
    add("one", arc(x + CAP / 2, BASE - CAP / 2, r_o, 0, 360))          # O
    x += CAP + GAP
    a = 70                                                             # n: two stems and an arch
    top = BASE - XH + HALF + a
    add("one", seg(x + HALF, BASE - HALF, x + HALF, top))
    add("one", arc(x + HALF + a, top, a, 0, 180))
    add("one", seg(x + HALF + 2 * a, top, x + HALF + 2 * a, BASE - HALF))
    x += 2 * a + STROKE + GAP
    r_e = (XH - STROKE) / 2                                            # e: ring open lower right, bar
    cx, cy = x + XH / 2, BASE - XH / 2
    add("one", arc(cx, cy, r_e, 0, 318))
    add("one", seg(cx - r_e, cy, cx + r_e, cy))
    x += XH + GAP
    add("os", arc(x + CAP / 2, BASE - CAP / 2, r_o, 0, 360))           # O
    x += CAP + GAP
    r_s = (CAP - STROKE) / 4                                           # S: two bowls
    cx = x + HALF + r_s
    add("os", arc(cx, BASE - CAP + HALF + r_s, r_s, 30, 270))
    add("os", arc(cx, BASE - CAP + HALF + 3 * r_s, r_s, 210, 90))
    for i in range(3):                                                 # loading dots
        dx = W / 2 + (i - 1) * 52
        add("d%d" % i, seg(dx, DOTS_Y, dx + 0.001, DOTS_Y), DOT_R)
    return prims


def render():
    """One byte per pixel: the palette index."""
    covs = {g: bytearray(W * H) for g in GROUPS}       # coverage 0..255 per group
    for group, dist, (x0, y0, x1, y1), half in wordmark():
        buf = covs[group]
        pad = half + 2
        for y in range(max(0, int(y0 - pad)), min(H, int(y1 + pad) + 1)):
            row = y * W
            for x in range(max(0, int(x0 - pad)), min(W, int(x1 + pad) + 1)):
                c = cov(dist(x + 0.5, y + 0.5), half)
                if c > 0:
                    v = int(c * 255 + 0.5)
                    if v > buf[row + x]:
                        buf[row + x] = v
    idx = bytearray(W * H)
    for g, (base, levels) in GROUPS.items():
        buf = covs[g]
        for i, v in enumerate(buf):
            if v:
                lv = round(v / 255 * (levels - 1))
                if lv and base + lv > idx[i]:
                    idx[i] = base + lv
    return bytes(idx)


def palette(bright):
    """bright: group -> 0..1."""
    pal = bytearray(256 * 3)
    for g, (base, levels) in GROUPS.items():
        col = WHITE if g == "one" else ACCENT
        for lv in range(levels):
            k = lv / (levels - 1) * bright.get(g, 0.0)
            pal[(base + lv) * 3:(base + lv) * 3 + 3] = bytes(int(c * k + 0.5) for c in col)
    return bytes(pal)


def chunk(t, data):
    return struct.pack(">I", len(data)) + t + data + struct.pack(">I", zlib.crc32(t + data) & 0xffffffff)


def png(idat, pal):
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 3, 0, 0, 0))
            + chunk(b"PLTE", pal) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


def frames():
    ease = lambda t: 1 - (1 - t) ** 3
    for i in range(INTRO):
        k = ease((i + 1) / INTRO)
        yield "part0", i, {"one": k, "os": k}
    for i in range(LOOP):
        b = {"one": 1.0, "os": 1.0}
        for d in range(3):
            ph = 2 * math.pi * (i / LOOP - d / 6)
            b["d%d" % d] = 0.22 + 0.78 * max(0.0, math.cos(ph)) ** 2
        yield "part1", i, b


def main():
    args = sys.argv[1:]
    preview = None
    static = "--static" in args
    if static:
        args.remove("--static")
    if "--preview" in args:
        j = args.index("--preview")
        preview = args[j + 1]
        del args[j:j + 2]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = args[0] if args else os.path.join(root, "out", "overlays", "oneos_bootanimation.zip")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)

    idx = render()
    idat = zlib.compress(b"".join(b"\x00" + idx[y * W:(y + 1) * W] for y in range(H)), 9)
    if static:
        desc = "%d %d 1\np 0 0 part0\n" % (W, H)
        seq = [("part0", 0, {"one": 1.0, "os": 1.0})]
    else:
        desc = ("# global width height offsetx offsety fps\n#\n"
                "g %d %d 0 %d %d \n\np 1 0 part0\np 0 0 part1\n" % (W, H, OFFY, FPS))
        seq = frames()
    tmp = out + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED) as z:
        z.writestr(zipfile.ZipInfo("desc.txt", (2026, 1, 1, 0, 0, 0)), desc)
        done = set()
        for part, i, bright in seq:
            if part not in done:
                zi = zipfile.ZipInfo(part + "/", (2026, 1, 1, 0, 0, 0))
                zi.external_attr = 0o40755 << 16
                z.writestr(zi, b"")
                done.add(part)
            data = png(idat, palette(bright))
            z.writestr(zipfile.ZipInfo("%s/ONEOS_%03d.png" % (part, i), (2026, 1, 1, 0, 0, 0)), data)
            if preview and part == ("part0" if static else "part1") and i == 0:
                with open(preview, "wb") as f:
                    f.write(data)
    with zipfile.ZipFile(tmp) as z:
        bad = [n.filename for n in z.infolist() if n.compress_type != zipfile.ZIP_STORED]
        if bad:
            sys.exit("compressed entries: %s" % bad)
    os.replace(tmp, out)
    if static:
        print("%s: %d bytes, 1 still frame %dx%d" % (out, os.path.getsize(out), W, H))
    else:
        print("%s: %d bytes, %d+%d frames %dx%d at y %d, %d fps" % (out, os.path.getsize(out), INTRO, LOOP, W, H, OFFY, FPS))


if __name__ == "__main__":
    main()
