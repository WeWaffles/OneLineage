// zygote_exec: launches the guest zygote inside the pivoted container.
//
// Stands in for init's "service zygote" stanza: creates the zygote and
// usap_pool_primary sockets the way init would (bound, handed over as fds 3
// and 4 through ANDROID_SOCKET_*), points stdio at /dev/null and
// /data/zygote_stderr.log, then execs app_process64 as zygote64.
//
// The environment is INHERITED from the caller (master_inner.sh), with the
// Android basics filled in only when missing. The original binary hardcoded
// the LineageOS 23.2 BOOTCLASSPATH/SYSTEMSERVERCLASSPATH, which made every
// other GSI unbootable (HyperOS needs its miui/xiaomi/mediatek boot jars);
// master_inner.sh now derives the classpaths from the guest's own fragments.
//
// Build (NDK, static so it needs nothing from the guest or the host):
//   aarch64-linux-android35-clang -static -O2 -s -o assets/zygote_exec native/zygote_exec.c

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define AID_SYSTEM 1000

static int make_socket(const char *path, int target_fd) {
    struct sockaddr_un addr;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }
    unlink(path);
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "bind %s: ", path);
        perror("");
        close(fd);
        return -1;
    }
    // init's defaults for these sockets: 0660 root:system. ZygoteServer calls
    // listen() itself when it wraps the inherited fd.
    chown(path, 0, AID_SYSTEM);
    chmod(path, 0660);
    if (fd != target_fd) {
        if (dup2(fd, target_fd) < 0) {
            perror("dup2");
            return -1;
        }
        close(fd);
    }
    // dup2 clears FD_CLOEXEC on the new fd, so it survives the exec below.
    return 0;
}

int main(void) {
    int devnull = open("/dev/null", O_RDWR);
    int errlog = open("/data/zygote_stderr.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (devnull >= 0) {
        dup2(devnull, 0);
        dup2(devnull, 1);
    }
    if (errlog >= 0) dup2(errlog, 2);
    if (devnull > 2) close(devnull);
    if (errlog > 2) close(errlog);

    mkdir("/dev/socket", 0755);
    if (make_socket("/dev/socket/zygote", 3) < 0) return 1;
    if (make_socket("/dev/socket/usap_pool_primary", 4) < 0) return 1;

    setenv("ANDROID_SOCKET_zygote", "3", 1);
    setenv("ANDROID_SOCKET_usap_pool_primary", "4", 1);

    // Defaults only: anything the caller exported wins.
    setenv("PATH", "/system/bin:/system/xbin", 0);
    setenv("ANDROID_ROOT", "/system", 0);
    setenv("ANDROID_DATA", "/data", 0);
    setenv("ANDROID_STORAGE", "/storage", 0);
    setenv("ANDROID_ART_ROOT", "/apex/com.android.art", 0);
    setenv("ANDROID_I18N_ROOT", "/apex/com.android.i18n", 0);
    setenv("ANDROID_TZDATA_ROOT", "/apex/com.android.tzdata", 0);
    setenv("EXTERNAL_STORAGE", "/sdcard", 0);
    setenv("ASEC_MOUNTPOINT", "/mnt/asec", 0);
    setenv("ANDROID_ASSETS", "/system/app", 0);

    char *argv[] = {
        "zygote64", "-Xzygote", "-Xforcejitzygote", "/system/bin",
        "--zygote", "--start-system-server", "--socket-name=zygote", NULL,
    };
    execv("/system/bin/app_process64", argv);
    perror("execv /system/bin/app_process64");
    return 1;
}
