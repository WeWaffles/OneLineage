// s26_dogsteal.c — pet Samsung's softdog through a frozen holder's fd.
// softdog allows one opener; under Plan C the frozen system_server keeps /dev/watchdog open and never pets
// it -> "Software Watchdog Timer expired" panic. pidfd_getfd() duplicates the holder's open file, and a
// write to the duplicate pets the same watchdog. SIGTERM/SIGINT: magic close ('V') and exit.
// usage: s26_dogsteal <pid> <fd>      build (chroot): gcc -static -O2 -o s26_dogsteal s26_dogsteal.c
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif
#ifndef SYS_pidfd_getfd
#define SYS_pidfd_getfd 438
#endif

static volatile sig_atomic_t stop;
static void on_sig(int s) { (void)s; stop = 1; }

static void stamp(const char *msg) {
    time_t t = time(NULL);
    char b[16];
    strftime(b, sizeof b, "%H:%M:%S", localtime(&t));
    printf("%s %s\n", b, msg);
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s <pid> <fd>\n", argv[0]); return 2; }
    int pidfd = syscall(SYS_pidfd_open, atoi(argv[1]), 0);
    if (pidfd < 0) { perror("pidfd_open"); return 1; }
    int wd = syscall(SYS_pidfd_getfd, pidfd, atoi(argv[2]), 0);
    if (wd < 0) { perror("pidfd_getfd"); return 1; }
    close(pidfd);

    struct sigaction sa = { .sa_handler = on_sig };
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    stamp("petting via stolen fd");
    while (!stop) {
        if (write(wd, ".", 1) != 1) { perror("write"); return 1; }
        sleep(3);
    }
    write(wd, "V", 1);
    close(wd);
    stamp("released (magic close)");
    return 0;
}
