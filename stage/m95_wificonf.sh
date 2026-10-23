#!/system/bin/sh
# m95_wificonf.sh — build a wpa_supplicant.conf for Nura from Android's saved networks (PSK never echoed)
OUT=/data/local/tmp/nura_stage/nura_wpa.conf
X=$(ls /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml /data/misc/wifi/WifiConfigStore.xml 2>/dev/null | head -n 1)
echo "store: $X"
printf "ctrl_interface=/data/local/tmp/nura_stage/wpa_ctrl\nupdate_config=0\n\n" > $OUT
# each saved network: <string name="SSID">&quot;name&quot;</string> ... <string name="PreSharedKey">&quot;psk&quot;</string>
sed -n 's/.*name="\(SSID\|PreSharedKey\)">&quot;\(.*\)&quot;<.*/\1 \2/p' "$X" | while read k v; do
  if [ "$k" = SSID ]; then S="$v"; else
    printf 'network={\n  ssid="%s"\n  psk="%s"\n  key_mgmt=WPA-PSK SAE\n  ieee80211w=1\n}\n' "$S" "$v" >> $OUT
    echo "network: $S"
  fi
done
chmod 600 $OUT
echo "networks written: $(grep -c network= $OUT)"
