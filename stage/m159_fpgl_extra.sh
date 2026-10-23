#!/system/bin/sh
# m159_fpgl_extra.sh — extra Debian libs for the GL.kgsl extension (libz3/libedit/libxml2 + deps) and a glibc build
# of the glFlush->glFinish shim (no glibc toolchain here: link with -nostdlib against a stub libc.so.6), then redo m157.
S=/data/local/tmp/nura_stage
R=$S/rootfs
rm -rf $R/tmp/debs2; cp -r $S/debs2 $R/tmp/debs2
chroot $R /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin sh -c '
  set -e
  rm -rf /tmp/debextra /tmp/dx; mkdir -p /tmp/debextra /tmp/dx
  for d in /tmp/debs2/*.deb; do
    mkdir /tmp/dbx; cd /tmp/dbx; ar x $d; tar -xf data.tar.* -C /tmp/dx; cd /; rm -rf /tmp/dbx
  done
  cp -a /tmp/dx/usr/lib/aarch64-linux-gnu/lib*.so.* /tmp/debextra/ 2>/dev/null || true
  cp -a /tmp/dx/lib/aarch64-linux-gnu/lib*.so.* /tmp/debextra/ 2>/dev/null || true
  ls /tmp/debextra
  # glibc shim: stub libc only provides the symbol names + soname; the real glibc resolves them at run time
  mkdir -p /tmp/stub; cd /tmp/stub
  printf "void *dlsym(void *h, const char *s){return 0;}\nint strcmp(const char *a, const char *b){return 0;}\n" > stub.c
  gcc -shared -nostdlib -fPIC -o libc.so.6 -Wl,-soname,libc.so.6 stub.c
  gcc -shared -nostdlib -fPIC -O2 -fno-builtin -o /usr/local/lib/s26_glfinish_glibc.so /tmp/debs2/s26_glfinish.c -L/tmp/stub -l:libc.so.6
  scanelf -n /usr/local/lib/s26_glfinish_glibc.so'
sh $S/m157_fpgl_ext.sh 2>&1 | grep -v boot_id
