#!/system/bin/sh
# m314_imscap.sh — run in One UI: capture a fresh IMS registration (airplane toggle) as pcap + logcat.
# Output holds SIM identifiers (IMSI/IMPI): keep it local. -> $S/imscap/{ims.pcap,logcat.txt}
S=/data/local/tmp/nura_stage
R=$S/rootfs
BB=/data/adb/ksu/bin/busybox
O=$S/imscap; rm -rf $O; mkdir -p $O
for d in dev proc sys; do grep -q " $R/$d " /proc/mounts || $BB mount --bind /$d $R/$d; done
logcat -c
chroot $R /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin tcpdump -i any -s 0 -U -w /tmp/ims.pcap \
  'port 5060 or port 5061 or esp or udp port 4500 or (udp and portrange 5000-65535 and net fd00:976a::/32)' >/dev/null 2>&1 &
T=$!
sleep 3
echo "$(date +%T) airplane on"; cmd connectivity airplane-mode enable; sleep 8
echo "$(date +%T) airplane off"; cmd connectivity airplane-mode disable
sleep 75
kill $T; sleep 1
cp $R/tmp/ims.pcap $O/ims.pcap
logcat -d -b all > $O/logcat.txt
ls -l $O
echo "SIP-ish logcat lines: $(grep -ciE 'REGISTER sip|SIP/2.0|P-CSCF|Security-Client' $O/logcat.txt)"
