#!/system/bin/sh
# m304_dds.sh — fix Android mobile data: defaultDataSubId=-1 makes Samsung's PhoneSwitcher refuse every
# INTERNET request (NOCARD). SubscriptionManagerService only reads multi_sim_data_call at init, so set it
# and restart com.android.phone. Runtime-only; re-run after reboot if defaultDataSubId is -1 again.
SUB=${1:-1}
settings put global multi_sim_data_call $SUB
P=$(ps -A -o PID,NAME | awk '$2=="com.android.phone"{print $1}')
echo "phone pid: $P"
[ -n "$P" ] && kill "$P"
sleep 25
echo "new pid: $(ps -A -o PID,NAME | awk '$2=="com.android.phone"{print $1}')"
dumpsys isub | grep -E 'defaultDataSubId|Logical SIM slot 0'
dumpsys connectivity | grep -F 'ni{MOBILE' | cut -c1-220
