#!/usr/bin/env python3
"""Rebuild a guest-only patched SystemUI from the exact tested Pixel donor.
The supplied adapter DEX is used; its Java and compilation-only stubs are in source/.
A rebuilt APK needs its SHA-256 pin updated in enable/undo scripts before use.
"""
import argparse, copy, hashlib, pathlib, shutil, struct, subprocess, tempfile, zipfile
ROOT=pathlib.Path(__file__).resolve().parent
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('donor',type=pathlib.Path)
p.add_argument('--zipalign',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
a=p.parse_args(); a.donor=a.donor.resolve();a.output=a.output.resolve()
assert hashlib.sha256(a.donor.read_bytes()).hexdigest()=='9934d2dac326f56290f459b9e649185cd5531e1b6ae1f5a72b11e88f865f8b03','Different donor'
with tempfile.TemporaryDirectory(prefix='oneos-pixel-hinge-') as tmp:
 w=pathlib.Path(tmp);decoded=w/'decoded'
 subprocess.run(['apktool','d','-f','-r','-o',str(decoded),str(a.donor)],check=True)
 for patch in (ROOT/'smali').glob('*.smali'):
  matches=list(decoded.glob('smali*/**/'+patch.name));assert len(matches)==1,patch.name
  shutil.copyfile(patch,matches[0])
 subprocess.run(['apktool','b','-o',str(w/'rebuilt.apk'),str(decoded)],check=True)
 replacement=(decoded/'build/apk/classes2.dex').read_bytes()
 with a.donor.open('rb') as raw,zipfile.ZipFile(a.donor) as src,zipfile.ZipFile(w/'raw.apk','w') as dst:
  assert 'classes4.dex' not in src.namelist()
  for info in src.infolist():
   if info.filename=='classes2.dex':dst.writestr(info.filename,replacement,compress_type=zipfile.ZIP_STORED);continue
   raw.seek(info.header_offset);header=raw.read(30);assert header[:4]==b'PK\x03\x04'
   nl,el=struct.unpack_from('<HH',header,26);body=raw.read(nl+el+info.compress_size);desc=b''
   if info.flag_bits&8:
    desc=raw.read(4);desc+=raw.read(12 if desc==b'PK\x07\x08' else 8)
   entry=copy.copy(info);entry.header_offset=dst.fp.tell();dst.fp.write(header+body+desc)
   dst.filelist.append(entry);dst.NameToInfo[entry.filename]=entry;dst.start_dir=dst.fp.tell();dst._didModify=True
  dst.writestr('classes4.dex',(ROOT/'PixelFold8Hinge.dex').read_bytes(),compress_type=zipfile.ZIP_STORED)
 subprocess.run([str(a.zipalign),'-f','-P','16','4',str(w/'raw.apk'),str(w/'aligned.apk')],check=True)
 # Preserve the donor's certificate metadata for a trusted system-directory
 # replacement. This does NOT create a content-valid OEM APK signature.
 original=a.donor.read_bytes();e=original.rfind(b'PK\x05\x06');cd=struct.unpack_from('<I',original,e+16)[0]
 assert original[cd-16:cd]==b'APK Sig Block 42'
 size=struct.unpack_from('<Q',original,cd-24)[0];block=original[cd-size-8:cd]
 assert struct.unpack_from('<Q',block)[0]==size
 result=(w/'aligned.apk').read_bytes();e=result.rfind(b'PK\x05\x06');cd=struct.unpack_from('<I',result,e+16)[0]
 result=bytearray(result[:cd]+block+result[cd:]);struct.pack_into('<I',result,e+len(block)+16,cd+len(block))
 a.output.write_bytes(result)
 with zipfile.ZipFile(a.donor) as src,zipfile.ZipFile(a.output) as dst:
  assert set(dst.namelist())-set(src.namelist())=={'classes4.dex'}
  for name in src.namelist():
   if name!='classes2.dex':assert src.read(name)==dst.read(name),name
 def classes(path):return subprocess.check_output(['python3',str(ROOT/'list_dex_classes.py'),str(path),'.']).decode().splitlines()
 before,after=classes(a.donor),classes(a.output)
 assert len(after)==len(set(after)) and set(before).issubset(after)
 assert set(after)-set(before)=={'com.android.systemui.unfold.updates.hinge.PixelFold8Hinge'}
print(hashlib.sha256(a.output.read_bytes()).hexdigest(),a.output)
