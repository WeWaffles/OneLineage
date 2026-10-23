/*
 * s26_bwrap_wrap — /usr/bin/bwrap in the Nura guest (replaces m145_bwrap_wrap.sh).
 *
 * The Android kernel has no PID/IPC/user namespaces, so Flatpak's bwrap calls fail with
 * "Creating new namespace failed". Drop those requests and exec the setuid bubblewrap 0.10
 * (/usr/libexec/bwrap-suid). Flatpak passes most arguments NUL-separated through `--args FD`,
 * so those are read and filtered too, then passed inline.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define REAL_BWRAP "/usr/libexec/bwrap-suid"

static const char *dropped[] = {
	"--unshare-pid", "--unshare-ipc", "--unshare-user", "--unshare-user-try",
	"--unshare-cgroup", "--unshare-cgroup-try",
	/* only valid with --unshare-user; moot anyway: the kernel has no user namespaces at all */
	"--disable-userns", "--assert-userns-disabled", NULL,
};

static char **out;
static size_t n_out, cap_out;

static void push(char *arg)
{
	if (n_out + 1 >= cap_out) {
		cap_out = cap_out ? cap_out * 2 : 256;
		out = realloc(out, cap_out * sizeof(*out));
		if (!out) {
			perror("s26_bwrap_wrap");
			exit(1);
		}
	}
	out[n_out++] = arg;
	out[n_out] = NULL;
}

static int is_dropped(const char *arg)
{
	for (int i = 0; dropped[i]; i++)
		if (strcmp(arg, dropped[i]) == 0)
			return 1;
	return 0;
}

/*
 * Setuid bwrap does its mounts from a separate privileged process, where /proc/self is that process,
 * not the one holding flatpak's fds. Point /proc/self/... at this pid instead (execv keeps the pid).
 */
static void add(char *arg)
{
	static char self[32];

	if (is_dropped(arg))
		return;
	if (strncmp(arg, "/proc/self/", 11) == 0) {
		char *fixed;

		if (!self[0])
			snprintf(self, sizeof(self), "/proc/%d/", (int)getpid());
		if (asprintf(&fixed, "%s%s", self, arg + 11) < 0) {
			perror("s26_bwrap_wrap");
			exit(1);
		}
		arg = fixed;
	}
	push(arg);
}

/*
 * --ro-bind-fd N / --bind-fd N: bwrap turns N into /proc/self/fd/N, which its setuid helper can't
 * resolve. Flatpak's fds point at real files/dirs, so bind the path the fd refers to instead.
 */
static int pending_fd_bind;

static void add_arg(char *arg)
{
	if (pending_fd_bind) {
		char link[64], *target = malloc(4096);
		ssize_t n;

		pending_fd_bind = 0;
		snprintf(link, sizeof(link), "/proc/self/fd/%s", arg);
		n = target ? readlink(link, target, 4095) : -1;
		if (n > 0 && target[0] == '/') {
			target[n] = '\0';
			push(target);
		} else {
			fprintf(stderr, "s26_bwrap_wrap: fd %s has no path, passing %s\n", arg, link);
			add(link);
		}
		return;
	}
	if (strcmp(arg, "--ro-bind-fd") == 0 || strcmp(arg, "--bind-fd") == 0) {
		push(arg[2] == 'r' ? "--ro-bind" : "--bind");
		pending_fd_bind = 1;
		return;
	}
	add(arg);
}

/* read a NUL-separated argument list from fd */
static void add_from_fd(int fd)
{
	size_t len = 0, cap = 65536;
	char *buf = malloc(cap);
	ssize_t r;

	while (buf && (r = read(fd, buf + len, cap - len)) > 0) {
		len += r;
		if (len == cap)
			buf = realloc(buf, cap *= 2);
	}
	if (!buf) {
		perror("s26_bwrap_wrap");
		exit(1);
	}
	/* fd stays open: flatpak may also reference it as /proc/self/fd/N */
	for (size_t i = 0; i < len;) {
		size_t l = strnlen(buf + i, len - i);
		buf[i + l < len ? i + l : len - 1] = '\0';
		add_arg(buf + i);
		i += l + 1;
	}
}

int main(int argc, char **argv)
{
	push(REAL_BWRAP);
	/*
	 * Without --unshare-pid the sandbox shares the caller's process group: a sandboxed helper that kills its
	 * group (glycin image loaders, when Snapshot saves a photo) SIGKILLed the app itself. Own session/group.
	 */
	push("--new-session");
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--args") == 0 && i + 1 < argc) {
			add_from_fd(atoi(argv[++i]));
			continue;
		}
		add_arg(argv[i]);
	}
	execv(REAL_BWRAP, out);
	perror("s26_bwrap_wrap: exec " REAL_BWRAP);
	return 127;
}
