# Samsung IMS in the Lineage guest

LineageOS has no IMS stack for Samsung modems, so SMS over IMS (and VoLTE)
does not work there by default. OneLineage runs One UI's own IMS app,
`com.sec.imsservice`, inside the guest and makes it Lineage's IMS service.

The approach, and two of the patches, come from
[OneOS](https://github.com/fahadalijaved/OneOS) (Apache License 2.0).
`tools/patches/sec_ims_signature.py` and `tools/patches/sec_ims_members.py`
are adapted from OneOS's `guest_sec_ims_signature.py` and
`guest_secims_members.py`; each file's header says what was changed.
Everything else here was written for OneLineage.

## What master_prepare.sh stages

Nothing is installed into the guest image. At switch time the files are copied
from the host's One UI into `$STAGE/secims` and laid over the guest's
`/system/system_ext` with a tmpfs-backed overlay (overlayfs refuses /data
layers) plus bind mounts:

- `priv-app/OneLineageSecIms/` - the IMS APK and its native libraries
- `framework/` - `imsmanager`, `rcsopenapi`, `vsimmanager` (Gson) and
  One UI's `framework.jar` as `ol-secims-compat.jar` (Samsung classes the app
  expects), declared in `etc/permissions/ol-secims-libraries.xml` with
  `dependency="secimshttpclient"` so each library's class loader sees the
  compat jar
- `lib64/lib.engmodejni.samsung.so` and its `public.libraries` entry
- the privapp permissions XML
- `app/OneLineageKnoxStub/` - an empty provider for `com.sec.knox.provider`
  and `provider2`, which the app queries at startup (`tools/knox_stub/`)

Opt out with `touch $STAGE/data/local/tmp/ol_no_secims`.

## Framework patches

- `services.jar` (`tools/patch_services.sh`): signature check carve-out so a
  package signed with Samsung's key may install from exactly
  `/system_ext/priv-app/OneLineageSecIms`.
- `framework.jar` (`tools/patch_framework.sh`): the Samsung-only members the
  app calls on Android classes (`ServiceState.isPsOnlyReg`,
  `UserHandle.SEM_CURRENT`, ...), and `registerTelephonyCallback` made lenient
  so Samsung's own callback types do not throw.

`patch_framework.sh` disassembles with Android Studio's baksmali 3.x (2.5.x
cannot read every Android 16 class), reassembles only the changed classes, and
merges them back with `tools/dexmerge/DexReplace.java`, which restores each
member's hidden-API flags. The `test-api` domain bit is not restored.

## Binding it

On every guest boot master_prepare.sh runs

    cmd phone ims set-ims-service -s <slot> -d -f 0,1 com.sec.imsservice

`cmd phone cc` is refused on a user build. The `-f 0,1` feature list
(EMERGENCY_MMTEL, MMTEL) is required: without it Android 16 overrides no
features and nothing is bound, so Samsung's app registers with the carrier
while Lineage still sends SMS over the legacy path. Check with
`dumpsys phone` (ImsResolver, "Active controllers").
