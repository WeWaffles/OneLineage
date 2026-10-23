#!/usr/bin/env python3
"""S26 Nura: let ModemManager survive a modem that reports no active SIM slot.

The S26's eUICC answers UIM Get Slot Status with "card present, slot inactive,
ICCID unknown" (and no slot flagged active), while UIM Get Card Status reports
the USIM application as ready and provisioned as Primary GW.  Upstream
load_sim_slots_ready() asserts that at least one slot is active and aborts the
whole daemon; on this device that produced an endless D-Bus activation loop
("ERROR: mm-iface-modem.c: load_sim_slots_ready: assertion failed").

Instead of aborting, skip exposing SIM slots and continue with the classic
create_sim path, which builds the SIM object from Get Card Status.

Usage: s26_mm_simslots.py <path-to-mm-iface-modem.c>
"""
import sys

MARK = "S26 Nura"

OLD = """        g_assert (primary_sim_slot);
        g_assert_cmpuint (primary_sim_slot, <=, sim_slots->len);
"""

NEW = """        /* S26 Nura: this eUICC reports "card present / slot inactive" with no
         * ICCID in UIM Get Slot Status, so no slot is flagged active.  Aborting
         * here killed the daemon; instead leave the slot list unset and let the
         * classic create_sim path (UIM Get Card Status) build the SIM object. */
        if (!primary_sim_slot) {
            mm_obj_info (self, "no active SIM slot reported by the modem; using classic SIM detection");
            ctx->step++;
            interface_initialization_step (task);
            return;
        }
        g_assert_cmpuint (primary_sim_slot, <=, sim_slots->len);
"""


def main():
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()

    n = src.count(OLD)
    if n != 1:
        sys.exit("%s: SIM-slot assert anchor found %d times (expected 1)" % (MARK, n))

    with open(path, "w", encoding="utf-8") as f:
        f.write(src.replace(OLD, NEW))
    print("%s: SIM slot fallback patch applied" % MARK)


if __name__ == "__main__":
    main()
