#!/usr/bin/env python3
"""S26 Nura: make ModemManager bind its WDS client to the SIM's subscription.

The S26's eSIM sits in physical slot 2 and Android provisions it as the
secondary subscription ("Secondary GW").  With Android's provisioning left
untouched, the modem's default data subscription stays on subscription 2, so a
WDS client that Start Network on an unbound WDS client gets the firmware call
manager's "cm no-service" rejection.

This patch adds two connect steps that send "Bind Subscription" right after
each WDS client (IPv4/IPv6) is allocated and before the data port is bound.

Selection file: /etc/s26-wds-subscription
  primary | secondary (default: secondary) | none

Usage: s26_mm_wdsbind.py <path-to-mm-bearer-qmi.c>
"""
import sys

MARK = "S26 Nura"


def patch(src, old, new, what):
    n = src.count(old)
    if n != 1:
        sys.exit("%s: anchor %r found %d times (expected 1)" % (MARK, what, n))
    return src.replace(old, new)


HELPERS = r'''/* S26 Nura: the eSIM is provisioned as the secondary subscription (Android's
 * "Secondary GW" layout), so a WDS client must be bound to that subscription
 * before Start Network or the modem's call manager answers "cm no-service".
 * Selection file: /etc/s26-wds-subscription -> primary | secondary | none
 * (missing file => secondary; "none" disables the binding). */
static gboolean
s26_wds_subscription_to_bind (QmiSubscriptionType *out)
{
    g_autofree gchar *contents = NULL;
    g_autofree gchar *value = NULL;

    *out = QMI_SUBSCRIPTION_TYPE_SECONDARY;
    if (!g_file_get_contents ("/etc/s26-wds-subscription", &contents, NULL, NULL))
        return TRUE;
    value = g_strstrip (g_strdup (contents));
    if (g_ascii_strcasecmp (value, "none") == 0)
        return FALSE;
    if (g_ascii_strcasecmp (value, "primary") == 0)
        *out = QMI_SUBSCRIPTION_TYPE_PRIMARY;
    else if (g_ascii_strcasecmp (value, "secondary") == 0)
        *out = QMI_SUBSCRIPTION_TYPE_SECONDARY;
    return TRUE;
}

static void
bind_subscription_ready (QmiClientWds *client,
                         GAsyncResult *res,
                         GTask        *task)
{
    ConnectContext *ctx;
    GError         *error = NULL;
    g_autoptr(QmiMessageWdsBindSubscriptionOutput) output = NULL;

    ctx = g_task_get_task_data (task);

    output = qmi_client_wds_bind_subscription_finish (client, res, &error);
    if (!output || !qmi_message_wds_bind_subscription_output_get_result (output, &error)) {
        /* keep going: some firmwares do not implement Bind Subscription */
        mm_obj_warn (ctx->self, "couldn't bind WDS client to subscription: %s", error->message);
        g_error_free (error);
    } else {
        mm_obj_dbg (ctx->self, "WDS client bound to subscription");
    }

    ctx->step++;
    connect_context_step (task);
}

'''

CASE_IPV4 = r'''    case CONNECT_STEP_BIND_SUBSCRIPTION_IPV4: {
        QmiSubscriptionType subscription;

        if (s26_wds_subscription_to_bind (&subscription)) {
            g_autoptr(QmiMessageWdsBindSubscriptionInput) input = NULL;

            mm_obj_dbg (self, "binding IPv4 WDS client to subscription %u", (guint)subscription);
            input = qmi_message_wds_bind_subscription_input_new ();
            qmi_message_wds_bind_subscription_input_set_subscription_id (input, subscription, NULL);
            qmi_client_wds_bind_subscription (ctx->client_ipv4,
                                              input,
                                              10,
                                              g_task_get_cancellable (task),
                                              (GAsyncReadyCallback)bind_subscription_ready,
                                              task);
            return;
        }
        ctx->step++;
    } /* fall through */

'''

CASE_IPV6 = r'''    case CONNECT_STEP_BIND_SUBSCRIPTION_IPV6: {
        QmiSubscriptionType subscription;

        if (s26_wds_subscription_to_bind (&subscription)) {
            g_autoptr(QmiMessageWdsBindSubscriptionInput) input = NULL;

            mm_obj_dbg (self, "binding IPv6 WDS client to subscription %u", (guint)subscription);
            input = qmi_message_wds_bind_subscription_input_new ();
            qmi_message_wds_bind_subscription_input_set_subscription_id (input, subscription, NULL);
            qmi_client_wds_bind_subscription (ctx->client_ipv6,
                                              input,
                                              10,
                                              g_task_get_cancellable (task),
                                              (GAsyncReadyCallback)bind_subscription_ready,
                                              task);
            return;
        }
        ctx->step++;
    } /* fall through */

'''


def main():
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()

    # 1. state machine: one step per IP family, right after the WDS client is ready
    src = patch(src,
                "    CONNECT_STEP_WDS_CLIENT_IPV4,\n    CONNECT_STEP_BIND_DATA_PORT_IPV4,\n",
                "    CONNECT_STEP_WDS_CLIENT_IPV4,\n    CONNECT_STEP_BIND_SUBSCRIPTION_IPV4,\n"
                "    CONNECT_STEP_BIND_DATA_PORT_IPV4,\n",
                "enum ipv4")
    src = patch(src,
                "    CONNECT_STEP_WDS_CLIENT_IPV6,\n    CONNECT_STEP_BIND_DATA_PORT_IPV6,\n",
                "    CONNECT_STEP_WDS_CLIENT_IPV6,\n    CONNECT_STEP_BIND_SUBSCRIPTION_IPV6,\n"
                "    CONNECT_STEP_BIND_DATA_PORT_IPV6,\n",
                "enum ipv6")

    # 2. helpers + async completion
    src = patch(src,
                "static void\nbind_data_port_ready (",
                HELPERS + "static void\nbind_data_port_ready (",
                "helpers")

    # 3. the two new switch cases
    src = patch(src,
                "    case CONNECT_STEP_BIND_DATA_PORT_IPV4:\n",
                CASE_IPV4 + "    case CONNECT_STEP_BIND_DATA_PORT_IPV4:\n",
                "case ipv4")
    src = patch(src,
                "    case CONNECT_STEP_BIND_DATA_PORT_IPV6:\n",
                CASE_IPV6 + "    case CONNECT_STEP_BIND_DATA_PORT_IPV6:\n",
                "case ipv6")

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print("%s: WDS Bind Subscription patch applied (%d markers)" % (MARK, src.count(MARK)))


if __name__ == "__main__":
    main()
