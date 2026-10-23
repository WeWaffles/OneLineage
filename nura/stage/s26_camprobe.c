/*
 * s26_camprobe — can a root bionic process get frames from cameraserver while system_server is down?
 * Lists cameras, opens one (argv[1], default "0"), runs a 640x480 YUV preview for ~3 s and writes the luma of the
 * last frame as a grayscale BMP (argv[2]). Built like s26_audiobridge (no NDK; m173).
 */
typedef unsigned long size_t;
typedef long ssize_t;
typedef int int32_t;
typedef unsigned char uint8_t;

struct structors { void (**preinit)(void); void (**init)(void); void (**fini)(void); size_t n1, n2, n3; };
extern void __libc_init(void *, void (*)(void), int (*)(int, char **, char **), const struct structors *);
extern int dprintf(int, const char *, ...);
extern int open(const char *, int, ...);
extern ssize_t write(int, const void *, size_t);
extern int close(int);
extern int usleep(unsigned);

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
typedef struct { int numCameras; const char **cameraIds; } ACameraIdList;
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

/* cameraserver dequeues/queues our ImageReader buffers by calling back into this process -> needs binder threads */
extern _Bool ABinderProcess_setThreadPoolMaxThreadCount(unsigned);
extern void ABinderProcess_startThreadPool(void);

extern ACameraManager *ACameraManager_create(void);
extern int ACameraManager_getCameraIdList(ACameraManager *, ACameraIdList **);
extern int ACameraManager_openCamera(ACameraManager *, const char *, ACameraDevice_StateCallbacks *, ACameraDevice **);
extern int ACameraDevice_createCaptureRequest(ACameraDevice *, int, ACaptureRequest **);
extern int ACameraDevice_createCaptureSession(ACameraDevice *, ACaptureSessionOutputContainer *,
					      ACameraCaptureSession_stateCallbacks *, ACameraCaptureSession **);
extern int ACameraDevice_close(ACameraDevice *);
extern int ACaptureSessionOutputContainer_create(ACaptureSessionOutputContainer **);
extern int ACaptureSessionOutput_create(ANativeWindow *, ACaptureSessionOutput **);
extern int ACaptureSessionOutputContainer_add(ACaptureSessionOutputContainer *, ACaptureSessionOutput *);
extern int ACameraOutputTarget_create(ANativeWindow *, ACameraOutputTarget **);
extern int ACaptureRequest_addTarget(ACaptureRequest *, ACameraOutputTarget *);
extern int ACameraCaptureSession_setRepeatingRequest(ACameraCaptureSession *, void *, int, ACaptureRequest **, int *);
extern int ACameraCaptureSession_stopRepeating(ACameraCaptureSession *);
extern int AImageReader_newWithUsage(int32_t, int32_t, int32_t, unsigned long long, int32_t, AImageReader **);
extern int atoi(const char *);
extern int AImageReader_getWindow(AImageReader *, ANativeWindow **);
extern int AImageReader_acquireLatestImage(AImageReader *, AImage **);
extern int AImage_getPlaneData(AImage *, int, uint8_t **, int *);
extern int AImage_getPlaneRowStride(AImage *, int, int32_t *);
extern void AImage_delete(AImage *);

static int W = 640, H = 480;

static void on_disc(void *c, ACameraDevice *d) { (void)c; (void)d; dprintf(2, "camprobe: device disconnected\n"); }
static void on_err(void *c, ACameraDevice *d, int e) { (void)c; (void)d; dprintf(2, "camprobe: device error %d\n", e); }
static void on_sess(void *c, ACameraCaptureSession *s) { (void)c; (void)s; }

static void put32(uint8_t *p, unsigned v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

/* 8-bit grayscale BMP, top-down */
static void save_bmp(const char *path, const uint8_t *y, int stride)
{
	static uint8_t hdr[54 + 1024];
	int fd, i, r;

	hdr[0] = 'B'; hdr[1] = 'M';
	put32(hdr + 2, 54 + 1024 + W * H);
	put32(hdr + 10, 54 + 1024);
	put32(hdr + 14, 40); put32(hdr + 18, W); put32(hdr + 22, -H);
	hdr[26] = 1; hdr[28] = 8;
	put32(hdr + 46, 256);
	for (i = 0; i < 256; i++)
		hdr[54 + i * 4] = hdr[55 + i * 4] = hdr[56 + i * 4] = i;
	fd = open(path, 0x241, 0644);	/* O_WRONLY|O_CREAT|O_TRUNC */
	write(fd, hdr, sizeof hdr);
	for (r = 0; r < H; r++)
		write(fd, y + r * stride, W);
	close(fd);
}

static int probe(int argc, char **argv, char **envp)
{
	const char *id = argc > 1 ? argv[1] : "0", *out = argc > 2 && argv[2][0] ? argv[2] : "/data/local/tmp/nura_stage/cam.bmp";
	static ACameraDevice_StateCallbacks dcb = { 0, on_disc, on_err };
	static ACameraCaptureSession_stateCallbacks scb = { 0, on_sess, on_sess, on_sess };
	ACameraManager *m;
	ACameraIdList *ids;
	ACameraDevice *dev = 0;
	AImageReader *rd;
	ANativeWindow *win;
	ACaptureSessionOutputContainer *cont;
	ACaptureSessionOutput *so;
	ACameraOutputTarget *tgt;
	ACaptureRequest *req;
	ACameraCaptureSession *sess;
	int i, rc, frames = 0;

	(void)envp;
	ABinderProcess_setThreadPoolMaxThreadCount(4);
	ABinderProcess_startThreadPool();
	m = ACameraManager_create();
	if ((rc = ACameraManager_getCameraIdList(m, &ids))) {
		dprintf(2, "camprobe: getCameraIdList failed %d\n", rc);
		return 1;
	}
	dprintf(2, "camprobe: %d cameras:", ids->numCameras);
	for (i = 0; i < ids->numCameras; i++)
		dprintf(2, " %s", ids->cameraIds[i]);
	dprintf(2, "\n");
	if ((rc = ACameraManager_openCamera(m, id, &dcb, &dev))) {
		dprintf(2, "camprobe: openCamera(%s) failed %d\n", id, rc);
		return 1;
	}
	if (argc > 4) {
		W = atoi(argv[3]);
		H = atoi(argv[4]);
	}
	/* CPU_READ_OFTEN: Samsung's HAL errors out on buffers allocated without a usage */
	if ((rc = AImageReader_newWithUsage(W, H, 0x23 /* YUV_420_888 */, 0x3, 4, &rd))) {
		dprintf(2, "camprobe: AImageReader_new failed %d\n", rc);
		return 1;
	}
	AImageReader_getWindow(rd, &win);
	ACaptureSessionOutputContainer_create(&cont);
	ACaptureSessionOutput_create(win, &so);
	ACaptureSessionOutputContainer_add(cont, so);
	ACameraOutputTarget_create(win, &tgt);
	ACameraDevice_createCaptureRequest(dev, 1 /* TEMPLATE_PREVIEW */, &req);
	ACaptureRequest_addTarget(req, tgt);
	if ((rc = ACameraDevice_createCaptureSession(dev, cont, &scb, &sess))) {
		dprintf(2, "camprobe: createCaptureSession failed %d\n", rc);
		return 1;
	}
	if ((rc = ACameraCaptureSession_setRepeatingRequest(sess, 0, 1, &req, 0))) {
		dprintf(2, "camprobe: setRepeatingRequest failed %d\n", rc);
		return 1;
	}
	/* let auto-exposure settle for ~30 frames, then keep one */
	for (i = 0; i < 80; i++) {
		AImage *img;

		usleep(50000);
		if (AImageReader_acquireLatestImage(rd, &img))
			continue;
		if (++frames >= 30 || i > 60) {
			uint8_t *y;
			int len;
			int32_t stride;

			AImage_getPlaneData(img, 0, &y, &len);
			AImage_getPlaneRowStride(img, 0, &stride);
			save_bmp(out, y, stride);
			AImage_delete(img);
			break;
		}
		AImage_delete(img);
	}
	dprintf(2, "camprobe: %d frames%s\n", frames, frames ? ", saved last luma" : "");
	ACameraCaptureSession_stopRepeating(sess);
	ACameraDevice_close(dev);
	return frames ? 0 : 1;
}

void s26_start(void *raw)
{
	static const struct structors st;
	__libc_init(raw, 0, probe, &st);
}

__asm__(".text\n.globl _start\n_start:\n  mov x0, sp\n  b s26_start\n");
