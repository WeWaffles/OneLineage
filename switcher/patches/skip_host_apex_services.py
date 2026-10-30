"""Skip the host vendor's APEX system services in the guest's SystemServer.

The host apexd reports Samsung's own APEXes to the guest too, and one of them
(com.samsung.android.lifeguard) declares an apex-system-service. The guest's
SystemServer.startApexServices() then aborted system_server with "Creating a
ClassLoader from /apex/com.samsung.android.lifeguard/javalib/service-lifeguard.jar
is not allowed": that jar is not on the guest's class path, and the service is
Samsung's anyway. Skip services whose jar lives in a com.samsung.* APEX.

Pixel's SystemServer (R8) has the same loop with other registers and a public
final method, so the registers are read from the code: the jar path is the
call's third register, and the scratch register is the isEmpty(jarPath) result
that branched to the call (dead after the branch; v5 on ColorOS, v3 on Pixel).

Usage: skip_host_apex_services.py <smali root dir>
Prints the smali_* directory (dex file) it changed.
"""
import os
import re
import sys

METHOD = re.compile(r"^\.method (?:private |public |final )*startApexServices\(Lcom/android/server/utils/TimingsTraceAndSlog;\)V$", re.M)
CALL = re.compile(r"^\s*invoke-virtual \{(v\d+), (v\d+), (v\d+)\}, Lcom/android/server/SystemServiceManager;->"
                  r"startServiceFromJar\(Ljava/lang/String;Ljava/lang/String;\)Lcom/android/server/SystemService;$")


def code(lines, i, step):
    """Index of the next line from i (step +1/-1) that is not blank or a .line."""
    while lines[i].strip() == "" or lines[i].strip().startswith(".line"):
        i += step
    return i


def main(root):
    for dirpath, _, files in os.walk(root):
        if "SystemServer.smali" not in files or not dirpath.endswith(os.path.join("com", "android", "server")):
            continue
        path = os.path.join(dirpath, "SystemServer.smali")
        with open(path) as f:
            smali = f.read()
        found = list(METHOD.finditer(smali))
        if not found:
            continue
        if len(found) != 1:
            sys.exit("startApexServices: found more than once")
        start = found[0].start()
        end = smali.index(".end method", start)
        lines = smali[start:end].split("\n")
        calls = [i for i, l in enumerate(lines) if CALL.match(l)]
        if len(calls) != 1:
            sys.exit("startApexServices: startServiceFromJar call not found as expected")
        idx = calls[0]
        jar = CALL.match(lines[idx]).group(3)
        label = code(lines, idx - 1, -1)
        after = code(lines, idx + 1, 1)
        if not re.match(r"^\s*:cond_\d+$", lines[label]) or not re.match(r"^\s*:goto_\d+$", lines[after]):
            sys.exit("startApexServices: startServiceFromJar call not between a branch label and a goto label")
        branch = [re.match(rf"^\s*if-eqz (v\d+), {lines[label].strip()}$", l) for l in lines]
        branch = [m.group(1) for m in branch if m]
        if len(branch) != 1:
            sys.exit("startApexServices: the isEmpty branch to the call not found")
        s = branch[0]
        if s == jar:
            sys.exit("startApexServices: scratch register is the jar path")
        insert = [
            f"    # OneOS: skip the host vendor's APEX system services ({jar} = jarPath).",
            f'    const-string {s}, "/apex/com.samsung."',
            "",
            f"    invoke-virtual {{{jar}, {s}}}, Ljava/lang/String;->startsWith(Ljava/lang/String;)Z",
            "",
            f"    move-result {s}",
            "",
            f"    if-nez {s}, {lines[after].strip()}",
            "",
        ]
        lines[label + 1:label + 1] = insert
        smali = smali[:start] + "\n".join(lines) + smali[end:]
        with open(path, "w") as f:
            f.write(smali)
        print(os.path.relpath(path, root).split(os.sep)[0])
        return
    sys.exit("SystemServer.startApexServices not found")


if __name__ == "__main__":
    main(sys.argv[1])
