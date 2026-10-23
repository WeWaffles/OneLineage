#!/system/bin/sh
# m304_dds.sh — fix Android mobile data: defaultDataSubId=-1 makes Samsung's PhoneSwitcher refuse every
# INTERNET request (NOCARD). SubscriptionManagerService only reads multi_sim_data_call at init, so set it
# and restart com.android.phone. multi_sim_data_call_slot must point at the SIM's logical slot (0): Samsung
# applies it at phone start, and the stale value 1 (empty slot) logs "setDefaultDataSlotId Invalid slotid"
# and resets the default data sub to -1 on every framework restart.
SUB=${1:-1}
SLOT=${2:-0}
settings put global multi_sim_data_call_slot $SLOT
settings put global multi_sim_data_call $SUB
P=$(ps -A -o PID,NAME | awk '$2=="com.android.phone"{print $1}')
echo "phone pid: $P"
[ -n "$P" ] && kill "$P"
sleep 25
echo "new pid: $(ps -A -o PID,NAME | awk '$2=="com.android.phone"{print $1}')"
dumpsys isub | grep -E 'defaultDataSubId|Logical SIM slot 0'
dumpsys connectivity | grep -F 'ni{MOBILE' | cut -c1-220
