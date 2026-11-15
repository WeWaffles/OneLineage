"""Patch a guest audio AIDL conversion lib so Samsung-only values don't fail
the whole audio port list.

- AudioDeviceDescription type 15 (Samsung IN_MICROPHONE_MULTI, "Built-In 2 Mic")
  -> AUDIO_DEVICE_IN_BUILTIN_MIC instead of BAD_VALUE.
- AIDL output flag bits Android doesn't define (Samsung SUBDEVICE) are dropped.

Hooks the first instruction of each function body (found through the exported
thunk) and appends small code caves to the end of the R+X segment.
usage: patch_audio.py <in.so> <out.so>
"""
import struct, sys, subprocess, os

src, dst = sys.argv[1], sys.argv[2]
b = bytearray(open(src, 'rb').read())
def find_nm():
    import glob, shutil
    sdk = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME') or         os.path.join(os.environ.get('LOCALAPPDATA', os.path.expanduser('~')), 'Android', 'Sdk')
    hits = sorted(glob.glob(os.path.join(sdk, 'ndk', '*', 'toolchains', 'llvm', 'prebuilt', '*', 'bin', 'llvm-nm*')))
    return hits[-1] if hits else shutil.which('llvm-nm') or sys.exit('llvm-nm not found (install an NDK)')
NM = find_nm()
syms = {}
for line in subprocess.run([NM, '-D', '--defined-only', src], capture_output=True, text=True).stdout.splitlines():
    a, _, n = line.split()
    syms[n] = int(a, 16)

def w(o): return struct.unpack_from('<I', b, o)[0]
def put(o, v): struct.pack_into('<I', b, o, v)
def br(f, t): return 0x14000000 | (((t - f) >> 2) & 0x3ffffff)
def bcond(f, t, c): return 0x54000000 | ((((t - f) >> 2) & 0x7ffff) << 5) | c

def body(sym):
    t = syms[sym]
    ins = w(t)
    assert ins >> 26 == 0b000101, f'{sym}: thunk is not a branch'
    off = ins & 0x3ffffff
    if off & 0x2000000: off -= 0x4000000
    return t + off * 4

# R+X PT_LOAD end = cave start
phoff = struct.unpack_from('<Q', b, 0x20)[0]
for i in range(struct.unpack_from('<H', b, 0x38)[0]):
    ph = phoff + i * 56
    if struct.unpack_from('<II', b, ph) == (1, 5):
        _, _, p_off, p_vaddr, _, p_filesz, p_memsz = struct.unpack_from('<IIQQQQQ', b, ph)
        assert p_off == p_vaddr and p_filesz == p_memsz
        cave = p_vaddr + p_filesz
        break
start = cave
# caves go into the zero padding between this segment and the next one
next_off = min(struct.unpack_from('<Q', b, phoff + j * 56 + 8)[0]
               for j in range(struct.unpack_from('<H', b, 0x38)[0])
               if struct.unpack_from('<I', b, phoff + j * 56)[0] == 1
               and struct.unpack_from('<Q', b, phoff + j * 56 + 8)[0] > start)
assert next_off - start >= 64 and b[start:start + 64] == bytes(64), 'no padding for caves'

def emit(v):
    global cave
    put(cave, v); cave += 4

def safe_first(insn):
    # sub sp, sp, #imm  (64-bit SUB immediate, Rd=Rn=sp)
    return (insn & 0xffc003ff) == 0xd10003ff

# 1) device type 15 -> AUDIO_DEVICE_IN_BUILTIN_MIC
DEV = '_ZN7android50aidl2legacy_AudioDeviceDescription_audio_devices_tERKNS_5media5audio6common22AudioDeviceDescriptionE'
d = body(DEV); first = w(d); assert safe_first(first), hex(first)
hook = cave
emit(0xb9400810)                 # ldr  w16, [x0, #8]     (type)
emit(0x71003e1f)                 # cmp  w16, #15
emit(bcond(cave, cave + 16, 1))  # b.ne +16
emit(0x52800080)                 # mov  w0, #4
emit(0x72b00000)                 # movk w0, #0x8000, lsl #16  -> 0x80000004, no error
emit(0xd65f03c0)                 # ret
emit(first)                      # displaced sub sp, sp, #N
emit(br(cave, d + 4))
put(d, br(d, hook))

# 2) drop unknown AIDL output flag bits (Android defines bits 0..18)
FLG = '_ZN7android45aidl2legacy_int32_t_audio_output_flags_t_maskEi'
f = body(FLG); first = w(f); assert safe_first(first), hex(first)
hook = cave
emit(0x12004800)                 # and w0, w0, #0x7ffff
emit(first)
emit(br(cave, f + 4))
put(f, br(f, hook))

assert b[start:cave] != bytes(cave - start)
grow = cave - start
struct.pack_into('<QQ', b, ph + 0x20, p_filesz + grow, p_memsz + grow)
# the bytes we used must have been zero padding before the next segment
open(dst, 'wb').write(b)
print(f'{os.path.basename(src)}: device body {d:#x}, flags body {f:#x}, cave {start:#x}+{grow}')
