
/* S26 Nura: Qualcomm's vendor rmnet driver (Android kernel) creates no lower_<dev> sysfs links for its mux
 * links, so ModemManager could not tell that qmapmuxN.M sits on rmnet_ipa0 and probed it as a new device.
 * Fall back to iflink: the ifindex of the parent netdev. */
gchar *
mm_kernel_device_get_lower_device_name (const gchar *sysfs_path)
{
    g_autofree gchar *iflink_path = NULL;
    g_autofree gchar *ifindex_path = NULL;
    g_autofree gchar *iflink = NULL;
    g_autofree gchar *ifindex = NULL;
    g_autoptr(GDir)   dir = NULL;
    const gchar      *entry;
    gchar            *name;

    name = s26_lower_device_name_links (sysfs_path);
    if (name)
        return name;

    iflink_path = g_build_filename (sysfs_path, "iflink", NULL);
    ifindex_path = g_build_filename (sysfs_path, "ifindex", NULL);
    if (!g_file_get_contents (iflink_path, &iflink, NULL, NULL) ||
        !g_file_get_contents (ifindex_path, &ifindex, NULL, NULL))
        return NULL;
    g_strstrip (iflink);
    g_strstrip (ifindex);
    if (g_strcmp0 (iflink, ifindex) == 0)
        return NULL;

    dir = g_dir_open ("/sys/class/net", 0, NULL);
    while (dir && (entry = g_dir_read_name (dir))) {
        g_autofree gchar *path = g_build_filename ("/sys/class/net", entry, "ifindex", NULL);
        g_autofree gchar *value = NULL;

        if (g_file_get_contents (path, &value, NULL, NULL) && g_strcmp0 (g_strstrip (value), iflink) == 0)
            return g_strdup (entry);
    }
    return NULL;
}
