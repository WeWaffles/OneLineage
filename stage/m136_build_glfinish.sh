#!/system/bin/sh
# m136_build_glfinish.sh — build s26_glfinish.so inside the guest -> /usr/local/lib
S=/data/local/tmp/nura_stage
cp $S/s26_glfinish.c $S/rootfs/tmp/
chroot $S/rootfs /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -c '
  command -v gcc >/dev/null || apk add gcc musl-dev 2>&1 | tail -n 1
  gcc -O2 -shared -fPIC -o /usr/local/lib/s26_glfinish.so /tmp/s26_glfinish.c -ldl && echo "built: $(ls -l /usr/local/lib/s26_glfinish.so)"'
