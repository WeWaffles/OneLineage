#!/usr/bin/env python3
# s26_mm_reuse.py — S26 Nura: make ModemManager REUSE the Android-owned rmnet_dataN link
# (name+mux id from /etc/s26-wds-link, e.g. "rmnet_data14 15") instead of creating its own
# qmapmux link. Android's ipacm knows these links; MM-created links with foreign mux ids are
# invisible to it and the IPA drops all traffic. On disconnect MM must not delete the link.

import sys

path = sys.argv[1]
src = open(path, encoding='utf-8').read()

SETUP_ANCHOR = """    ctx = g_slice_new0 (SetupLinkContext);
    ctx->main = g_object_ref (data);
    ctx->mux_id = QMI_DEVICE_MUX_ID_UNBOUND;
    g_task_set_task_data (task, ctx, (GDestroyNotify) setup_link_context_free);
"""

SETUP_INJECT = """    ctx = g_slice_new0 (SetupLinkContext);
    ctx->main = g_object_ref (data);
    ctx->mux_id = QMI_DEVICE_MUX_ID_UNBOUND;
    g_task_set_task_data (task, ctx, (GDestroyNotify) setup_link_context_free);

    /* S26 Nura: reuse an existing Android-owned rmnet link (name + mux id from
     * /etc/s26-wds-link, e.g. "rmnet_data14 15") instead of creating a new qmapmux link:
     * the vendor IPA data path (ipacm) only recognizes links it created at boot. */
    if (g_strcmp0 (self->priv->net_driver, "ipa") == 0) {
        g_autofree gchar *reuse_cfg = NULL;
        if (g_file_get_contents ("/etc/s26-wds-link", &reuse_cfg, NULL, NULL) && reuse_cfg) {
            g_strchomp (reuse_cfg);
            g_auto(GStrv) reuse_parts = g_strsplit (reuse_cfg, " ", 2);
            const gchar *reuse_link = (reuse_parts && reuse_parts[0] && reuse_parts[1]) ? reuse_parts[0] : NULL;
            guint reuse_mux = (reuse_parts && reuse_parts[0] && reuse_parts[1]) ? (guint) g_ascii_strtoull (reuse_parts[1], NULL, 10) : 0;
            if (reuse_link && (reuse_mux > 0) && (reuse_mux <= 254)) {
                g_autofree gchar *reuse_chk = g_build_filename ("/sys/class/net", reuse_link, "ifindex", NULL);
                if (g_file_test (reuse_chk, G_FILE_TEST_EXISTS)) {
                    mm_obj_dbg (self, "S26 Nura: reusing existing Android-owned link %s (mux id %u)", reuse_link, reuse_mux);
                    ctx->link_name = g_strdup (reuse_link);
                    ctx->mux_id = reuse_mux;
                    g_task_return_boolean (task, TRUE);
                    g_object_unref (task);
                    return;
                }
            }
        }
    }
"""

CLEANUP_ANCHOR = """mm_port_qmi_cleanup_link (MMPortQmi           *self,
                          const gchar         *link_name,
                          guint                mux_id,
                          GAsyncReadyCallback  callback,
                          gpointer             user_data)
{
    GTask  *task;
    GError *error = NULL;

    task = g_task_new (self, NULL, callback, user_data);
"""

CLEANUP_INJECT = """mm_port_qmi_cleanup_link (MMPortQmi           *self,
                          const gchar         *link_name,
                          guint                mux_id,
                          GAsyncReadyCallback  callback,
                          gpointer             user_data)
{
    GTask  *task;
    GError *error = NULL;

    task = g_task_new (self, NULL, callback, user_data);

    /* S26 Nura: never delete the Android-owned link we were told to reuse */
    if (g_strcmp0 (self->priv->net_driver, "ipa") == 0) {
        g_autofree gchar *keep_cfg = NULL;
        if (g_file_get_contents ("/etc/s26-wds-link", &keep_cfg, NULL, NULL) && keep_cfg) {
            g_strchomp (keep_cfg);
            g_auto(GStrv) keep_parts = g_strsplit (keep_cfg, " ", 2);
            if (keep_parts && keep_parts[0] && (g_strcmp0 (link_name, keep_parts[0]) == 0)) {
                mm_obj_dbg (self, "S26 Nura: NOT deleting Android-owned link %s", link_name);
                g_task_return_boolean (task, TRUE);
                g_object_unref (task);
                return;
            }
        }
    }
"""

for name, anchor, inject in (("setup", SETUP_ANCHOR, SETUP_INJECT),
                             ("cleanup", CLEANUP_ANCHOR, CLEANUP_INJECT)):
    assert src.count(anchor) == 1, f"anchor {name} found {src.count(anchor)} times"
    src = src.replace(anchor, inject)

open(path, 'w', encoding='utf-8').write(src)
print("s26_mm_reuse: patch applied to", path)
