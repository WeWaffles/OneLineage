/*
 * s26_fakeam — stand-in "activity" binder service while Nura has system_server stopped.
 *
 * Native services (cameraserver above all) block forever in waitForService("activity") when system_server is gone.
 * This registers a binder under that name that fails every transaction: callers get an error back and carry on
 * (non-app UIDs count as active anyway). Must exit before system_server comes back (m77 kills it first).
 * Built like s26_audiobridge: chroot gcc + device libbinder_ndk.so, no NDK (m174).
 */
typedef unsigned long size_t;
typedef unsigned int uint32_t;

struct structors { void (**preinit)(void); void (**init)(void); void (**fini)(void); size_t n1, n2, n3; };
extern void __libc_init(void *, void (*)(void), int (*)(int, char **, char **), const struct structors *);
extern int dprintf(int, const char *, ...);

typedef struct AIBinder AIBinder;
typedef struct AIBinder_Class AIBinder_Class;
typedef struct AParcel AParcel;
typedef int (*on_transact_fn)(AIBinder *, uint32_t, const AParcel *, AParcel *);
extern AIBinder_Class *AIBinder_Class_define(const char *, void *(*)(void *), void (*)(void *), on_transact_fn);
extern AIBinder *AIBinder_new(const AIBinder_Class *, void *);
extern int AServiceManager_addService(AIBinder *, const char *);
extern _Bool ABinderProcess_setThreadPoolMaxThreadCount(uint32_t);
extern void ABinderProcess_startThreadPool(void);
extern void ABinderProcess_joinThreadPool(void);

extern int AParcel_writeInt32(AParcel *, int);

#define STATUS_UNKNOWN_TRANSACTION (-74)

static void *on_create(void *args) { return args; }
static void on_destroy(void *data) { (void)data; }
static int on_transact_fail(AIBinder *b, uint32_t code, const AParcel *in, AParcel *out)
{
	(void)b; (void)in; (void)out;
	dprintf(2, "fakeam: call %u -> fail\n", code);
	return STATUS_UNKNOWN_TRANSACTION;
}

/* AIDL reply "no exception" + a zero int/bool: cameraserver treats a missing media.camera.proxy as "camera disabled
 * by device policy"; zero answers isCameraDisabled = false and getRotateAndCrop/AutoframingOverride = none. */
static int on_transact_zero(AIBinder *b, uint32_t code, const AParcel *in, AParcel *out)
{
	(void)b; (void)in;
	dprintf(2, "fakeam: call %u -> 0\n", code);
	AParcel_writeInt32(out, 0);
	AParcel_writeInt32(out, 0);
	return 0;
}

/* IPermissionController: checkPermission (1) -> granted; noteOp (2) -> MODE_ALLOWED (0); the rest -> 0.
 * Without it libbinder's checkPermission waits 10 s for the service on every call, then denies. */
static int on_transact_perm(AIBinder *b, uint32_t code, const AParcel *in, AParcel *out)
{
	(void)b; (void)in;
	dprintf(2, "fakeam: call %u -> %d\n", code, code == 1);
	AParcel_writeInt32(out, 0);
	AParcel_writeInt32(out, code == 1);
	return 0;
}

/* IProcessInfoService: getProcessStatesFromPids (1) / ...AndOomScoresFromPids (2) take pids[] and the out arrays'
 * sizes; answer one (or two) all-zero arrays of the same length = every process top priority. CameraService
 * needs this for its eviction logic and fails the connect with ETIMEDOUT when it can't get it. */
extern int AParcel_readInt32(const AParcel *, int *);

static int on_transact_procinfo(AIBinder *b, uint32_t code, const AParcel *in, AParcel *out)
{
	int n = 0, i, a;

	(void)b;
	AParcel_readInt32(in, &n);
	if (n < 0 || n > 4096)
		n = 0;
	dprintf(2, "fakeam: call %u (%d pids)\n", code, n);
	AParcel_writeInt32(out, 0);
	for (a = 0; a < (code == 2 ? 2 : 1); a++) {
		AParcel_writeInt32(out, n);
		for (i = 0; i < n; i++)
			AParcel_writeInt32(out, 0);
	}
	return 0;
}

/* usage: s26_fakeam [service-name [interface-descriptor zero|perm|procinfo]] */
static int fakeam(int argc, char **argv, char **envp)
{
	const char *name = argc > 1 ? argv[1] : "activity";
	const char *desc = argc > 2 ? argv[2] : "android.app.IActivityManager";
	const char *mode = argc > 3 ? argv[3] : "fail";
	on_transact_fn fn = mode[0] == 'z' ? on_transact_zero : mode[0] == 'p' && mode[1] == 'e' ? on_transact_perm :
			    mode[0] == 'p' ? on_transact_procinfo : on_transact_fail;
	AIBinder_Class *cls = AIBinder_Class_define(desc, on_create, on_destroy, fn);
	AIBinder *b = AIBinder_new(cls, 0);
	int rc;

	(void)envp;
	ABinderProcess_setThreadPoolMaxThreadCount(2);
	ABinderProcess_startThreadPool();
	if ((rc = AServiceManager_addService(b, name))) {
		dprintf(2, "fakeam: addService(%s) failed: %d\n", name, rc);
		return 1;
	}
	dprintf(2, "fakeam: \"%s\" registered\n", name);
	ABinderProcess_joinThreadPool();
	return 0;
}

void s26_start(void *raw)
{
	static const struct structors st;
	__libc_init(raw, 0, fakeam, &st);
}

__asm__(".text\n.globl _start\n_start:\n  mov x0, sp\n  b s26_start\n");
