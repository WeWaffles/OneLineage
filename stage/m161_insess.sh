#!/system/bin/sh
# m161_insess.sh — run a stage script as "user" inside the live Phosh session's mount namespace. usage: m161 <script>
S=/data/local/tmp/nura_stage
R=$S/rootfs
cp $S/$1 $R/tmp/insess.sh; chmod 644 $R/tmp/insess.sh
/data/adb/ksu/bin/busybox nsenter -t $(pidof phosh) -m chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin su -s /bin/sh user -c 'sh /tmp/insess.sh'
