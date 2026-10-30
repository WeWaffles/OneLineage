"""Never let the guest's watchdog crash the phone's kernel.

The guest shares the host kernel. AOSP Watchdog and ColorOS's WatchdogExtImpl
(e.g. after three watchdog kills in five minutes, "Theia triggering panic to
reboot device") write 'c' to /proc/sysrq-trigger, which panics the kernel and
reboots the phone. Make every doSysRq(C) return for 'c'; the 'w' and 'l'
(stack dump) requests still go through. guest_prepare.sh also hides
sysrq-trigger in the guest's /proc. Pixel's Watchdog has it as public final.

Usage: guest_no_sysrq_crash.py <smali root dir>
Prints the smali_* directories (dex files) it changed, one per line.
"""
import os
import re
import sys

HEADER = re.compile(r"^\.method (?:private |public |final )*doSysRq\(C\)V$")


def main(root):
    changed = set()
    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".smali"):
                continue
            path = os.path.join(dirpath, name)
            lines = open(path).read().split("\n")
            heads = [k for k, l in enumerate(lines) if HEADER.match(l)]
            if not heads:
                continue
            if len(heads) != 1:
                sys.exit(f"{name}: doSysRq(C) found more than once")
            i = heads[0]
            m = re.match(r"\s*\.locals (\d+)$", lines[i + 1])
            if not m or int(m.group(1)) < 1:
                sys.exit(f"{name}: unexpected doSysRq header")
            j = i + 2
            while lines[j].strip() == "" or lines[j].lstrip().startswith((".param", ".end param")):
                j += 1
            lines[j:j] = [
                "    # OneOS: no kernel crash ('c') from the container; the phone's kernel is shared.",
                "    const/16 v0, 0x63",
                "",
                "    if-ne p1, v0, :oneos_not_crash",
                "",
                "    return-void",
                "",
                "    :oneos_not_crash",
                "",
            ]
            open(path, "w").write("\n".join(lines))
            changed.add(os.path.relpath(path, root).split(os.sep)[0])
            print(f"{os.path.relpath(path, root)}: doSysRq('c') disabled", file=sys.stderr)
    if not changed:
        sys.exit("no doSysRq(C) found")
    for d in sorted(changed):
        print(d)


if __name__ == "__main__":
    main(sys.argv[1])
