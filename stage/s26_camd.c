/*
 * s26_camd — Android-side half of the Nura camera (like s26_audiobridge for audio).
 *
 * Opens an Android camera through the NDK camera API only while Nura wants it (WANT file contains '1', written by
 * the Nura-side watcher when an app is consuming the PipeWire camera node) and writes whole NV12 frames into a FIFO
 * that GStreamer (rawvideoparse ! pipewiresink) turns into a PipeWire camera. cameraserver needs the system_server
 * stand-ins from m175 while Nura runs. Built like s26_audiobridge (chroot gcc + device libs, no NDK; m179).
 *
 * usage: s26_camd <camera-id> <fifo> <want-file> <width> <height>
 */
typedef unsigned long size_t;
typedef long ssize_t;
typedef int int32_t;
typedef unsigned char uint8_t;

struct structors { void (**preinit)(void); void (**init)(void); void (**fini)(void); size_t n1, n2, n3; };
extern void __libc_init(void *, void (*)(void), int (*)(int, char **, char **), const struct structors *);
extern int dprintf(int, const char *, ...);
extern int open(const char *, int, ...);
extern ssize_t read(int, void *, size_t);
extern ssize_t write(int, const void *, size_t);
extern int close(int);
extern int fcntl(int, int, ...);
extern int mkfifo(const char *, unsigned);
extern int chmod(const char *, unsigned);
extern int usleep(unsigned);
extern int atoi(const char *);
extern void *malloc(size_t);

typedef struct ACameraManager ACameraManager;
typedef struct ACameraDevice ACameraDevice;
typedef struct ACaptureRequest ACaptureRequest;
typedef struct ACameraOutputTarget ACameraOutputTarget;
typedef struct ACaptureSessionOutput ACaptureSessionOutput;
typedef struct ACaptureSessionOutputContainer ACaptureSessionOutputContainer;
typedef struct ACameraCaptureSession ACameraCaptureSession;
typedef struct ANativeWindow ANativeWindow;
typedef struct AImageReader AImageReader;
typedef struct AImage AImage;
typedef struct {
	void *context;
	void (*onDisconnected)(void *, ACameraDevice *);
	void (*onError)(void *, ACameraDevice *, int);
} ACameraDevice_StateCallbacks;
typedef struct {
	void *context;
	void (*onClosed)(void *, ACameraCaptureSession *);
	void (*onReady)(void *, ACameraCaptureSession *);
	void (*onActive)(void *, ACameraCaptureSession *);
} ACameraCaptureSession_stateCallbacks;

/* cameraserver queues our ImageReader buffers by calling back into this process -> needs binder threads */
extern _Bool ABinderProcess_setThreadPoolMaxThreadCount(unsigned);
extern void ABinderProcess_startThreadPool(void);

extern ACameraManager *ACameraManager_create(void);
extern int ACameraManager_openCamera(ACameraManager *, const char *, ACameraDevice_StateCallbacks *, ACameraDevice **);
extern int ACameraDevice_createCaptureRequest(ACameraDevice *, int, ACaptureRequest **);
extern int ACameraDevice_createCaptureSession(ACameraDevice *, ACaptureSessionOutputContainer *,
					      ACameraCaptureSession_stateCallbacks *, ACameraCaptureSession **);
extern int ACameraDevice_close(ACameraDevice *);
extern int ACaptureSessionOutputContainer_create(ACaptureSessionOutputContainer **);
extern void ACaptureSessionOutputContainer_free(ACaptureSessionOutputContainer *);
extern int ACaptureSessionOutput_create(ANativeWindow *, ACaptureSessionOutput **);
extern void ACaptureSessionOutput_free(ACaptureSessionOutput *);
extern int ACaptureSessionOutputContainer_add(ACaptureSessionOutputContainer *, ACaptureSessionOutput *);
extern int ACameraOutputTarget_create(ANativeWindow *, ACameraOutputTarget **);
extern void ACameraOutputTarget_free(ACameraOutputTarget *);
extern int ACaptureRequest_addTarget(ACaptureRequest *, ACameraOutputTarget *);
extern void ACaptureRequest_free(ACaptureRequest *);
extern int ACameraCaptureSession_setRepeatingRequest(ACameraCaptureSession *, void *, int, ACaptureRequest **, int *);
extern int ACameraCaptureSession_stopRepeating(ACameraCaptureSession *);
extern void ACameraCaptureSession_close(ACameraCaptureSession *);
extern int AImageReader_newWithUsage(int32_t, int32_t, int32_t, unsigned long long, int32_t, AImageReader **);
extern void AImageReader_delete(AImageReader *);
extern int AImageReader_getWindow(AImageReader *, ANativeWindow **);
extern int AImageReader_acquireNextImage(AImageReader *, AImage **);
extern int AImage_getPlaneData(AImage *, int, uint8_t **, int *);
extern int AImage_getPlaneRowStride(AImage *, int, int32_t *);
extern int AImage_getPlanePixelStride(AImage *, int, int32_t *);
extern void AImage_delete(AImage *);

#define O_RDWR 2
#define F_SETPIPE_SZ 1031

static int W, H;
static volatile int dead;	/* device disconnected/errored: reopen */

struct cam {
	ACameraDevice *dev;
	AImageReader *rd;
	ACaptureSessionOutputContainer *cont;
	ACaptureSessionOutput *so;
	ACameraOutputTarget *tgt;
	ACaptureRequest *req;
	ACameraCaptureSession *sess;
};

static void on_disc(void *c, ACameraDevice *d) { (void)c; (void)d; dead = 1; dprintf(2, "camd: disconnected\n"); }
static void on_err(void *c, ACameraDevice *d, int e) { (void)c; (void)d; dead = 1; dprintf(2, "camd: device error %d\n", e); }
static void on_sess(void *c, ACameraCaptureSession *s) { (void)c; (void)s; }

static int wanted(const char *path)
{
	char c = '0';
	int fd = open(path, 0);

	if (fd >= 0) {
		read(fd, &c, 1);
		close(fd);
	}
	return c == '1';
}

static void cam_close(struct cam *k)
{
	if (k->sess) {
		ACameraCaptureSession_stopRepeating(k->sess);
		ACameraCaptureSession_close(k->sess);
	}
	if (k->dev)
		ACameraDevice_close(k->dev);
	if (k->req)
		ACaptureRequest_free(k->req);
	if (k->tgt)
		ACameraOutputTarget_free(k->tgt);
	if (k->so)
		ACaptureSessionOutput_free(k->so);
	if (k->cont)
		ACaptureSessionOutputContainer_free(k->cont);
	if (k->rd)
		AImageReader_delete(k->rd);
	*k = (struct cam){ 0 };
}

static int cam_open(struct cam *k, ACameraManager *m, const char *id)
{
	static ACameraDevice_StateCallbacks dcb = { 0, on_disc, on_err };
	static ACameraCaptureSession_stateCallbacks scb = { 0, on_sess, on_sess, on_sess };
	ANativeWindow *win;
	int rc;

	dead = 0;
	if ((rc = ACameraManager_openCamera(m, id, &dcb, &k->dev)))
		goto fail;
	/* CPU_READ_OFTEN: Samsung's HAL errors out on buffers allocated without a usage */
	if ((rc = AImageReader_newWithUsage(W, H, 0x23 /* YUV_420_888 */, 0x3, 4, &k->rd)))
		goto fail;
	AImageReader_getWindow(k->rd, &win);
	ACaptureSessionOutputContainer_create(&k->cont);
	ACaptureSessionOutput_create(win, &k->so);
	ACaptureSessionOutputContainer_add(k->cont, k->so);
	ACameraOutputTarget_create(win, &k->tgt);
	if ((rc = ACameraDevice_createCaptureRequest(k->dev, 1 /* TEMPLATE_PREVIEW */, &k->req)))
		goto fail;
	ACaptureRequest_addTarget(k->req, k->tgt);
	if ((rc = ACameraDevice_createCaptureSession(k->dev, k->cont, &scb, &k->sess)))
		goto fail;
	if ((rc = ACameraCaptureSession_setRepeatingRequest(k->sess, 0, 1, &k->req, 0)))
		goto fail;
	dprintf(2, "camd: camera %s streaming %dx%d\n", id, W, H);
	return 0;
fail:
	dprintf(2, "camd: open camera %s failed: %d\n", id, rc);
	cam_close(k);
	return -1;
}

extern int ioctl(int, int, ...);
#define FIONREAD 0x541B
#define F_GETPIPE_SZ 1032

/*
 * Never block on the FIFO: with no app linked, pipewiresink stops pulling and the pipe fills up -- a blocked write
 * would also stop us noticing the camera should go off. Only write a frame that fits entirely; otherwise drop it.
 */
static int pipe_room(int fd, int n)
{
	int queued = 0, cap = fcntl(fd, F_GETPIPE_SZ);

	return !ioctl(fd, FIONREAD, &queued) && queued + n <= cap;
}

static void write_all(int fd, const uint8_t *p, size_t n)
{
	while (n) {
		ssize_t w = write(fd, p, n);
		if (w <= 0)
			return;
		p += w;
		n -= w;
	}
}

static int sent, dropped;	/* per streaming session, logged every ~5 s */

/* YUV_420_888 -> NV12 (Y plane, then interleaved UV), dropping row padding */
static void send_frame(int fd, AImage *img, uint8_t *nv12)
{
	uint8_t *y, *u, *v, *o = nv12;
	int len, r, c;
	int32_t ys, us, ups;

	if (!pipe_room(fd, W * H * 3 / 2)) {
		dropped++;
		return;
	}
	sent++;
	AImage_getPlaneData(img, 0, &y, &len);
	AImage_getPlaneData(img, 1, &u, &len);
	AImage_getPlaneData(img, 2, &v, &len);
	AImage_getPlaneRowStride(img, 0, &ys);
	AImage_getPlaneRowStride(img, 1, &us);
	AImage_getPlanePixelStride(img, 1, &ups);
	for (r = 0; r < H; r++, o += W)
		__builtin_memcpy(o, y + r * ys, W);
	for (r = 0; r < H / 2; r++) {
		if (ups == 2 && v == u + 1) {	/* already NV12 in memory */
			__builtin_memcpy(o, u + r * us, W);
			o += W;
			continue;
		}
		for (c = 0; c < W / 2; c++) {
			*o++ = u[r * us + c * ups];
			*o++ = v[r * us + c * ups];
		}
	}
	write_all(fd, nv12, W * H * 3 / 2);
}

/*
 * Idle keep-alive: GStreamer's pipewiresink only publishes the camera node once a first frame has negotiated caps,
 * but the camera only starts once an app links to that node. So while idle, push a black frame every ~2 s -- only
 * when the pipe is empty, so nothing piles up if the reader isn't draining.
 */
static void send_black(int fd, uint8_t *nv12)
{
	int queued = 0;

	if (ioctl(fd, FIONREAD, &queued) || queued || !pipe_room(fd, W * H * 3 / 2))
		return;
	__builtin_memset(nv12, 16, W * H);			/* Y: video black */
	__builtin_memset(nv12 + W * H, 128, W * H / 2);	/* UV: neutral */
	write_all(fd, nv12, W * H * 3 / 2);
}

static int camd(int argc, char **argv, char **envp)
{
	struct cam k = { 0 };
	ACameraManager *m;
	uint8_t *nv12;
	int fd, idle = 0;

	(void)envp;
	if (argc < 6) {
		dprintf(2, "usage: s26_camd <camera-id> <fifo> <want-file> <width> <height>\n");
		return 1;
	}
	W = atoi(argv[4]);
	H = atoi(argv[5]);
	nv12 = malloc(W * H * 3 / 2);
	mkfifo(argv[2], 0666);
	chmod(argv[2], 0666);
	fd = open(argv[2], O_RDWR);	/* RDWR: never blocks/EOFs when the GStreamer reader restarts */
	if (fd < 0) {
		dprintf(2, "camd: can't open %s\n", argv[2]);
		return 1;
	}
	fcntl(fd, F_SETPIPE_SZ, 8 << 20);	/* a few whole frames; root may exceed pipe-max-size */
	{
		/* a previous camd killed mid-frame leaves a partial frame queued, which would shift every following
		 * frame for the reader (green/grey bands): drop whatever is queued. (The reader must restart too.) */
		int queued = 0;
		while (!ioctl(fd, FIONREAD, &queued) && queued > 0)
			read(fd, nv12, queued < W * H * 3 / 2 ? queued : W * H * 3 / 2);
	}
	ABinderProcess_setThreadPoolMaxThreadCount(4);
	ABinderProcess_startThreadPool();
	m = ACameraManager_create();
	dprintf(2, "camd: camera %s -> %s, waiting for %s\n", argv[1], argv[2], argv[3]);
	for (;;) {
		AImage *img;

		if (!k.dev) {
			/* idle: check the want file 5x/s */
			usleep(200000);
			if (++idle % 10 == 0)
				send_black(fd, nv12);
			if (wanted(argv[3]) && cam_open(&k, m, argv[1]))
				usleep(1000000);
			continue;
		}
		if (++idle >= 40) {	/* every ~200 ms while streaming */
			static int ticks;
			idle = 0;
			if (++ticks % 25 == 0) {
				dprintf(2, "camd: camera %s: %d frames sent, %d dropped (reader not keeping up)\n",
					argv[1], sent, dropped);
				sent = dropped = 0;
			}
			if (!wanted(argv[3]) || dead) {
				dprintf(2, "camd: camera %s off\n", argv[1]);
				cam_close(&k);
				continue;
			}
		}
		if (AImageReader_acquireNextImage(k.rd, &img)) {
			usleep(5000);
			continue;
		}
		send_frame(fd, img, nv12);
		AImage_delete(img);
	}
}

void s26_start(void *raw)
{
	static const struct structors st;
	__libc_init(raw, 0, camd, &st);
}

__asm__(".text\n.globl _start\n_start:\n  mov x0, sp\n  b s26_start\n");
