// SPDX-License-Identifier: GPL-2.0-only
/*
 * OneLineage XNU handoff ABI probe.
 *
 * This module intentionally has no device node, sysfs entry, ioctl, payload
 * loader, memory allocation, reboot hook, or transfer-of-control path.  Its
 * only purpose is to prove that an out-of-tree module can be accepted by the
 * exact running Samsung kernel and then removed cleanly.
 */
#include <linux/init.h>
#include <linux/module.h>

static int __init onelineage_xnu_probe_init(void)
{
	return 0;
}

static void __exit onelineage_xnu_probe_exit(void)
{
}

module_init(onelineage_xnu_probe_init);
module_exit(onelineage_xnu_probe_exit);

MODULE_DESCRIPTION("OneLineage inert XNU handoff ABI probe");
MODULE_AUTHOR("OneLineage contributors");
MODULE_LICENSE("GPL");
MODULE_VERSION("0.1");
