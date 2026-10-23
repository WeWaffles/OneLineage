#!/system/bin/sh
# m199_build_mm.sh — build ModemManager (upstream main) in the chroot with the S26 patch and install it over
# Alpine's package. Patch: skip QMI LOC "XTRA assistance data" probing -- its indication handler outlives its GTask
# (no disconnect, 10 s timeout left armed) and ModemManager segfaulted ~5 s after start on this modem.
S=/data/local/tmp/nura_stage
R=$S/rootfs
mkdir -p $R/usr/src; rm -rf $R/usr/src/ModemManager-main
cp $S/mm-main.tar.gz $S/s26_mm_lowerdev.c $S/s26_mm_wdsbind.py $S/s26_mm_simslots.py $S/s26_mm_reuse.py $R/usr/src/
/data/adb/ksu/bin/busybox nsenter -t $(pidof phosh) -m chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root sh -c '
  set -e
  apk add -q build-base meson ninja glib-dev libgudev-dev libqmi-dev libmbim-dev libqrtr-glib-dev dbus-dev gettext-dev linux-headers 2>&1 | tail -n 3
  cd /usr/src; tar -xzf mm-main.tar.gz; cd ModemManager-main
  # Path 1 (cellular): bind each bearer WDS client to the SIM subscription (default: secondary,
  # the eSIM layout Android uses) instead of swapping provisioning to primary every boot.
  python3 /usr/src/s26_mm_wdsbind.py src/mm-bearer-qmi.c
  # The eUICC reports no active slot (card present/inactive, no ICCID) -> upstream asserts and aborts;
  # fall back to classic SIM detection from UIM Get Card Status instead.
  python3 /usr/src/s26_mm_simslots.py src/mm-iface-modem.c
  # S26 Nura: reuse the Android-owned rmnet_dataN link (ipacm-visible) for the data call
  python3 /usr/src/s26_mm_reuse.py src/mm-port-qmi.c
  grep -c "S26 Nura" src/mm-port-qmi.c
  sed -i "s#^    /\* If no LOC client, no assistance data right away \*/#    /* S26 Nura: skip XTRA probing, its indication handler outlives the task (use-after-free crash) */\n    if (TRUE) {\n        g_task_return_int (task, MM_MODEM_LOCATION_ASSISTANCE_DATA_TYPE_NONE);\n        g_object_unref (task);\n        return;\n    }\n    /* If no LOC client, no assistance data right away */#" src/mm-shared-qmi.c
  grep -c "S26 Nura" src/mm-shared-qmi.c
  # Android vendor kernel: rmnet_ipa0 is the IPA netdev but has no driver link in sysfs -> report "ipa" so the
  # qcom-soc plugin/bearer/port code take their IPA (QMAP mux over rmnet links) paths
  sed -i "s#^    self->priv->driver = g_strdup (g_udev_device_get_driver (self->priv->device));#&\n    if (!self->priv->driver \&\& g_strcmp0 (g_udev_device_get_name (self->priv->device), \"rmnet_ipa0\") == 0)\n        self->priv->driver = g_strdup (\"ipa\");  /* S26 Nura */#" src/kerneldevice/mm-kernel-device-udev.c
  grep -c "S26 Nura" src/kerneldevice/mm-kernel-device-udev.c
  # vendor rmnet links have no lower_<dev> sysfs entries: rename the sysfs-link lookup and wrap it with an iflink
  # fallback (s26_mm_lowerdev.c) so MM attaches its qmapmux links to the rmnet_ipa0 modem
  H=src/kerneldevice/mm-kernel-device-helpers.c
  sed -i "s/^mm_kernel_device_get_lower_device_name (const gchar \*sysfs_path)$/s26_lower_device_name_links (const gchar *sysfs_path)/" $H
  cat /usr/src/s26_mm_lowerdev.c >> $H
  grep -c s26_lower_device_name_links $H
  # upstream main is ahead of the libqmi in Alpine: drop call states it does not know yet (-> default branch)
  sed -i "/case QMI_VOICE_CALL_STATE_PRE_ALERTING:/d" src/mm-broadband-modem-qmi.c
  meson setup build --prefix=/usr --sysconfdir=/etc --localstatedir=/var --buildtype=release \
    -Dqrtr=true -Dmbim=true -Dqmi=true -Dpolkit=no -Dintrospection=false -Dvapi=false -Dbash_completion=false \
    -Dsystemdsystemunitdir=no -Dsystemd_suspend_resume=false -Dsystemd_journal=false -Dman=false -Dtests=false \
    -Dudevdir=/usr/lib/udev -Ddbus_policy_dir=/usr/share/dbus-1/system.d > /tmp/mm-meson.log 2>&1 || { tail -n 25 /tmp/mm-meson.log; exit 1; }
  ninja -C build > /tmp/mm-ninja.log 2>&1 || { tail -n 25 /tmp/mm-ninja.log; exit 1; }
  ninja -C build install > /tmp/mm-install.log 2>&1 || { tail -n 15 /tmp/mm-install.log; exit 1; }
  /usr/sbin/ModemManager --version | head -n 1'

# ninja install rewrites the D-Bus service file: keep debug logging to /var/log/mm.log
F=$R/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service
grep -q mm.log $F || sed -i 's#^Exec=.*#Exec=/bin/sh -c "exec /usr/sbin/ModemManager --debug >> /var/log/mm.log 2>\&1"#' $F
grep Exec $F
