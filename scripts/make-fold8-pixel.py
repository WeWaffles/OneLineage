#!/usr/bin/env python3
"""Build Fold8 Pixel payloads from a pinned base and the exact Pixel SystemUI donor.
No OEM binaries are committed. --review-pins explicitly accepts newly rebuilt hashes.
--variant f8 (Galaxy Z Fold8, set pixel-f8) or f8u (Z Fold8 Ultra, set pixel-f8u: the same
SystemUI and relay, its own unfold RRO without the Fold8's 48dp status bar).
"""
import argparse,hashlib,os,pathlib,shutil,subprocess,tempfile
R=pathlib.Path(__file__).resolve().parents[1]
def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def lines(p):return dict((n,h) for h,n in (s.split() for s in p.read_text().splitlines() if s and not s.startswith('#')))
def run(*a):subprocess.run([str(v) for v in a],check=True)
# variant: set id, unfold RRO source, its file name in the set
VARIANTS={'f8':('pixel-f8','pixel_fold8_unfold','Fold8PixelUnfold.apk'),'f8u':('pixel-f8u','pixel_f8u_unfold','OneOSPixelUnfold.apk')}
HINGE={'Fold8PixelSystemUI.apk','Fold8AngleRelay.dex','Fold8PixelUnfold.apk','OneOSPixelUnfold.apk'}
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--base',type=pathlib.Path,required=True)
 p.add_argument('--systemui',type=pathlib.Path,required=True)
 p.add_argument('--relay',type=pathlib.Path,required=True)
 p.add_argument('--out',type=pathlib.Path,required=True)
 p.add_argument('--sdk',type=pathlib.Path,default=pathlib.Path(os.environ.get('ANDROID_HOME','/opt/android-sdk')))
 p.add_argument('--platform',default='android-37.0');p.add_argument('--build-tools',default='36.1.0')
 p.add_argument('--keystore',type=pathlib.Path,default=pathlib.Path.home()/'.android/debug.keystore')
 p.add_argument('--review-pins',action='store_true')
 p.add_argument('--variant',choices=sorted(VARIANTS),default='f8')
 a=p.parse_args();setid,rro,rroname=VARIANTS[a.variant];bt=a.sdk/'build-tools'/a.build_tools;jar=a.sdk/'platforms'/a.platform/'android.jar'
 if a.out.exists():p.error('Output already exists')
 if sha(a.systemui)!='9934d2dac326f56290f459b9e649185cd5531e1b6ae1f5a72b11e88f865f8b03':p.error('Different Pixel donor')
 if sha(a.relay)!='ccf2fbddc462eca6d7cb7f112ca1b36620fe0ccd044ff6ba28bebe13cfe6b89e':p.error('Different OneOS relay')
 a.out.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.TemporaryDirectory(prefix='.pixel-fold8-',dir=a.out.parent) as tmp:
  w=pathlib.Path(tmp);out=w/'set';out.mkdir()
  for n,h in lines(R/'app-android/packages/pixel-f8u.sha256').items():
   if n in HINGE:continue
   f=a.base/n
   if sha(f)!=h:p.error('Base payload differs: '+n)
   shutil.copyfile(f,out/n)
  run('python3',R/'switcher/patches/fold8-pixel/build-systemui.py',a.systemui,'--zipalign',bt/'zipalign','--output',out/'Fold8PixelSystemUI.apk')
  shutil.copyfile(a.relay,out/'Fold8AngleRelay.dex')
  overlay=R/'switcher/overlays'/rro
  run(bt/'aapt2','compile','--dir',overlay/'res','-o',w/'resources.zip')
  run(bt/'aapt2','link','-o',w/'unsigned.apk','--manifest',overlay/'AndroidManifest.xml','-I',jar,'--min-sdk-version','31','--target-sdk-version','36','--auto-add-overlay',w/'resources.zip')
  run(bt/'zipalign','-f','4',w/'unsigned.apk',w/'aligned.apk')
  run(bt/'apksigner','sign','--v4-signing-enabled','false','--ks',a.keystore,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',out/rroname,w/'aligned.apk')
  have={f.name:sha(f) for f in out.iterdir()};pinfile=R/'app-android/packages'/(setid+'.sha256')
  if have!=lines(pinfile):
   if not a.review_pins:p.error('Rebuilt hashes differ (toolchain/ZIP timestamps): review, then use --review-pins to update explicitly')
   # keep the pin file's own header comments
   text=''.join(l+'\n' for l in pinfile.read_text().splitlines() if l.startswith('#'))+''.join(h+'  '+n+'\n' for n,h in sorted(have.items()))
   pinfile.write_text(text)
   (R/'app-android/core/model/src/test/resources/packages'/(setid+'.sha256')).write_text(text)
  run('python3',R/'scripts/check-dex.py',out/'Fold8PixelSystemUI.apk')
  out.rename(a.out)
 print('Built and verified',a.out)
if __name__=='__main__':main()
