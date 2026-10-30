"""HyperOS's audioserver without an audio HAL adapter vendor extension.

AOSP's libaudiohal@aidl.so reads ro.audio.ihaladaptervendorextension_enabled
and, when it is true, waits with no time limit for
android.media.audio.IHalAdapterVendorExtension/default. The HyperOS image sets
it to true (on Xiaomi's phone Xiaomi's vendor serves the extension), and so does
One UI, whose value the guest reads from the shared property area. On One UI
the service lives in Samsung's own audioserver, which a session stops, and
nothing in HyperOS provides it. HyperOS's audioserver therefore never got past
its HAL setup (servicemanager kept asking init to start the interface); after
60 s OneOS's audio keeper handed the guest to One UI's audioserver, whose
permission controller HyperOS's framework could not fill
("NPC::checkPermission: controller never populated by system_server"), and the
guest had no sound (Z Fold8 Ultra, sixth HyperOS run, 2026-10-26).

The property name appears once in libaudiohal@aidl.so, as a string of its own
(NUL before and after). Its first letter becomes "n": "no.audio...." is not set
anywhere, property_get_bool gives false, and libaudiohal goes on without a
vendor extension, which AOSP supports (vendor parameters are then not
forwarded; OneOS's call keeper sends its key straight to the HAL). Only the
first byte changes, so a shorter string the linker may have merged into its
tail stays the same. One UI's property and every other reader are untouched.
The name must be found exactly once, or nothing is written.

Usage: hyperos_audio_ext.py <libaudiohal@aidl.so> <output>
"""
import sys

OLD = b"\x00ro.audio.ihaladaptervendorextension_enabled\x00"
NEW = b"\x00no.audio.ihaladaptervendorextension_enabled\x00"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    data = open(sys.argv[1], "rb").read()
    if data[:4] != b"\x7fELF":
        sys.exit("hyperos_audio_ext: not an ELF file")
    if data.count(NEW) != 0:
        sys.exit("hyperos_audio_ext: already patched")
    n = data.count(OLD)
    if n != 1:
        sys.exit(f"hyperos_audio_ext: the property name appears {n} times (one expected)")
    out = data.replace(OLD, NEW)
    assert len(out) == len(data)
    open(sys.argv[2], "wb").write(out)
    print("libaudiohal@aidl.so: ro.audio.ihaladaptervendorextension_enabled not read (no vendor extension wait)", file=sys.stderr)


if __name__ == "__main__":
    main()
