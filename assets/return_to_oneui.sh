#!/system/bin/sh
# Return to One UI / Safe State Restoration
BACKUP_DIR="/data/local/tmp/lineage_backups"

echo "=== [1/5] Terminating Container Supervision & Zygote ==="
pkill -9 -f "ctl.stop zygote" 2>/dev/null || true
pkill -9 -f "kill -STOP" 2>/dev/null || true
pkill -9 -f "ui_activator" 2>/dev/null || true
pkill -9 -f "zygote_exec" 2>/dev/null || true
# Stop the adb watchdog started by switch_to_lineage.sh before One UI's own
# system_server comes back, so it cannot fight init over sys.usb.config.
pkill -9 -f "adb_watchdog.sh" 2>/dev/null || true
pkill -9 -f "ims_watchdog.sh" 2>/dev/null || true
# Stop the suppressors started by switch_to_lineage.sh so One UI's own
# media.codec and rescue_boot_count handling is restored.
pkill -9 -f "media_codec_suppress" 2>/dev/null || true
pkill -9 -f "rescue_boot_suppress" 2>/dev/null || true
pkill -9 -f "system_server" 2>/dev/null || true
pkill -9 -f org.lineageos 2>/dev/null || true
pkill -9 -x zygote64 2>/dev/null || true
kill -9 $(pidof surfaceflinger) 2>/dev/null || true

# Put the host's own /data trees back FIRST: master_prepare.sh bridges the
# staged app trees (installd/artd write there), and the One UI launcher restore
# below must read the host's real /data/user/0, not the guest's.
for d in app app-staging user user_de dalvik-cache misc/profiles; do
    umount "/data/$d" 2>/dev/null || true
done

echo "=== [2/5] Restoring One UI Home Screen Layout & Permissions ==="
LAUNCHER_PKG="com.sec.android.app.launcher"
LAUNCHER_DATA="/data/user/0/$LAUNCHER_PKG"
LAUNCHER_UID=$(stat -c %u "$LAUNCHER_DATA" 2>/dev/null || echo 10160)
LAUNCHER_GID=$(stat -c %g "$LAUNCHER_DATA" 2>/dev/null || echo 10160)

if [ -d "$BACKUP_DIR" ] && [ -d "$LAUNCHER_DATA/databases" ]; then
    cp -a "$BACKUP_DIR"/* "$LAUNCHER_DATA/databases/" 2>/dev/null || true
    chown -R ${LAUNCHER_UID}:${LAUNCHER_GID} "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 771 "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 660 "$LAUNCHER_DATA/databases"/* 2>/dev/null || true
    echo "One UI Home screen database restored with UID $LAUNCHER_UID:$LAUNCHER_GID"
fi

echo "=== [3/5] Unmounting Container Overlays ==="
umount -l /data/local/tmp/lineage_stage/rootfs/* 2>/dev/null || true
umount -l /data/local/tmp/lineage_stage/rootfs/apex/* 2>/dev/null || true
while mount | grep -q "/data/local/tmp/lineage_stage/rootfs"; do
    umount -l /data/local/tmp/lineage_stage/rootfs 2>/dev/null || true
    sleep 0.1
done
BB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox)
if [ -x "$BB" ]; then
    for l in $($BB losetup -a | grep "system.raw" | cut -d: -f1); do
        $BB losetup -d "$l" 2>/dev/null || true
    done
fi

echo "=== [4/5] Restoring Storage Mounts ==="
umount -l /storage/emulated 2>/dev/null || true
umount -l /mnt/user/0/emulated 2>/dev/null || true
mkdir -p /storage/emulated/0
mount --bind /data/media/0 /storage/emulated/0 2>/dev/null || true

echo "=== [5/5] Starting One UI Display & Host Services ==="

# Reset battery statistics. The guest system_server writes its own BatteryStats
# while it runs, and those values survive into One UI where they manifest as
# "1% battery" / "charging" false-positive on the first One UI boot after a
# Lineage session. Dumping and clearing before One UI starts avoids that.
dumpsys batterystats --reset 2>/dev/null || true
rm -f /data/system/batterystats.bin 2>/dev/null || true

# Reset biometric enrollment state. The Lineage FingerprintService writes to
# /data/system/users/0/fpdata and /data/vendor_de/0/fpdata during a session. If
# the guest enrolls or queries fingerprints those writes can corrupt the Samsung
# TrustZone biometric DB, and the fingerprint sensor stops responding in One UI.
# Force the fingerprint HAL to re-sync from TrustZone on next One UI boot.
setprop ctl.stop vendor.fingerprint-default-1_0 2>/dev/null || true
setprop ctl.stop vendor.biometrics.fingerprint.inscreen 2>/dev/null || true
sleep 1
setprop ctl.start vendor.fingerprint-default-1_0 2>/dev/null || true
setprop ctl.start vendor.biometrics.fingerprint.inscreen 2>/dev/null || true

setprop ctl.start surfaceflinger
setprop ctl.start zygote
setprop ctl.start audioserver
setprop ctl.start cameraserver
# switch_to_lineage.sh stops the host media codec stack (its IMediaCodecList AIDL
# hash does not match the GSI's, which spins the guest's MediaCodecList); bring it
# back for One UI.
for svc in media media.extractor media.codec media.metrics wificond; do
    setprop ctl.start $svc 2>/dev/null || true
done
am force-stop com.sec.android.app.launcher 2>/dev/null || true
am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null || true

# switch_to_lineage.sh drops SELinux to permissive for the takeover; restore it.
setenforce 1 2>/dev/null || true
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"
echo "One UI restored successfully."
