#!/system/bin/sh
# m90b_peek.sh — quick state: session log tail, processes, wifi link
S=/data/local/tmp/nura_stage
tail -n 30 $S/m81.log
echo "--- ps: $(pidof m81_phosh_session.sh udhcpc phoc phosh wpa_supplicant system_server | tr '\n' ' ')"
ps -ef | grep -E "udhcpc|m81|m97|phoc" | grep -v grep
echo "--- link: $(wpa_cli -p /data/vendor/wifi/wpa/nura_ctrl -i wlan0 status 2>&1 | grep -E 'wpa_state|^ssid' | tr '\n' ' ')"
ip -4 addr show wlan0 | grep inet
logcat -d -s wpa_supplicant | grep -viE "psk|passphrase" | tail -n 15
