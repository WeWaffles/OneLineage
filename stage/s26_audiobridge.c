/*
 * s26_audiobridge — Android-side half of Nura audio.
 *
 * Nura's PulseAudio has a pipe sink (module-pipe-sink) writing s16le/48k/stereo into a FIFO; this Android binary
 * reads it and plays it with AAudio through audioserver -> Qualcomm audio HAL (raw ALSA is unusable on AGM).
 * No NDK here: built in the Alpine chroot with gcc -nostdlib, linked against the device's own libc.so/libaaudio.so,
 * with a hand-rolled _start that calls bionic's __libc_init (what crtbegin_dynamic.o does). Hence no headers.
 */
typedef unsigned long size_t;
typedef long ssize_t;
typedef int int32_t;
typedef long long int64_t;

struct pollfd { int fd; short events; short revents; };
struct structors { void (**preinit)(void); void (**init)(void); void (**fini)(void); size_t n1, n2, n3; };

extern void __libc_init(void *raw_args, void (*onexit)(void), int (*main)(int, char **, char **),
			const struct structors *s);
extern int open(const char *, int, ...);
extern ssize_t read(int, void *, size_t);
extern ssize_t write(int, const void *, size_t);
extern int poll(struct pollfd *, unsigned long, int);
extern int fcntl(int, int, ...);
extern int mkfifo(const char *, unsigned);
extern int chmod(const char *, unsigned);
extern int mkdir(const char *, unsigned);
extern int dprintf(int, const char *, ...);
extern unsigned sleep(unsigned);

typedef struct AAudioStreamBuilder AAudioStreamBuilder;
typedef struct AAudioStream AAudioStream;
extern int32_t AAudio_createStreamBuilder(AAudioStreamBuilder **);
extern void AAudioStreamBuilder_setFormat(AAudioStreamBuilder *, int32_t);
extern void AAudioStreamBuilder_setChannelCount(AAudioStreamBuilder *, int32_t);
extern void AAudioStreamBuilder_setSampleRate(AAudioStreamBuilder *, int32_t);
extern void AAudioStreamBuilder_setPerformanceMode(AAudioStreamBuilder *, int32_t);
extern void AAudioStreamBuilder_setUsage(AAudioStreamBuilder *, int32_t);
extern void AAudioStreamBuilder_setBufferCapacityInFrames(AAudioStreamBuilder *, int32_t);
extern int32_t AAudioStreamBuilder_openStream(AAudioStreamBuilder *, AAudioStream **);
extern int32_t AAudioStreamBuilder_delete(AAudioStreamBuilder *);
extern int32_t AAudioStream_requestStart(AAudioStream *);
extern int32_t AAudioStream_requestStop(AAudioStream *);
extern int32_t AAudioStream_close(AAudioStream *);
extern int32_t AAudioStream_write(AAudioStream *, const void *, int32_t, int64_t);

/* libaudioclient (C++, but plain-C-compatible arguments) — called by their mangled names */
extern int as_init_stream_volume(int stream, int min, int max)
	__asm__("_ZN7android11AudioSystem16initStreamVolumeE19audio_stream_type_tii");
extern int as_set_stream_volume_index(int stream, int index, _Bool muted, unsigned device)
	__asm__("_ZN7android11AudioSystem20setStreamVolumeIndexE19audio_stream_type_tib15audio_devices_t");
extern int as_set_master_volume(float v) __asm__("_ZN7android11AudioSystem15setMasterVolumeEf");
extern int as_set_master_mute(_Bool m) __asm__("_ZN7android11AudioSystem13setMasterMuteEb");

#define O_RDWR 2
#define POLLIN 1
#define F_SETPIPE_SZ 1031
#define FRAME 4			/* s16 stereo */
#define CHUNK 480		/* 10 ms at 48 kHz */
#define IDLE_MS 3000		/* close the stream after this much silence (lets the DSP sleep) */

/*
 * system_server's AudioService normally initialises every stream's volume index at boot; with it stopped they stay
 * unset and audioserver computes the music volume as NaN = silence. Pin everything at full scale: the real volume
 * control is PulseAudio's sink (Phosh's slider and the volume keys).
 */
static void init_volumes(void)
{
	static const unsigned devices[] = { 0x40000000 /* DEFAULT_FOR_VOLUME */, 0x2 /* SPEAKER */, 0x4 /* WIRED_HEADSET */,
					    0x8 /* WIRED_HEADPHONE */, 0x80 /* BT_A2DP */, 0x4000000 /* USB_HEADSET */ };
	int st, d, err = 0;

	for (st = 0; st <= 13; st++) {
		err |= as_init_stream_volume(st, 0, 15);
		for (d = 0; d < (int)(sizeof devices / sizeof devices[0]); d++)
			err |= as_set_stream_volume_index(st, 15, 0, devices[d]);
	}
	as_set_master_volume(1.0f);
	as_set_master_mute(0);
	dprintf(2, "audiobridge: stream volumes initialised%s\n", err ? " (some calls failed)" : "");
}

static AAudioStream *open_stream(void)
{
	AAudioStreamBuilder *b;
	AAudioStream *s = 0;
	if (AAudio_createStreamBuilder(&b))
		return 0;
	AAudioStreamBuilder_setFormat(b, 1);		/* AAUDIO_FORMAT_PCM_I16 */
	AAudioStreamBuilder_setChannelCount(b, 2);
	AAudioStreamBuilder_setSampleRate(b, 48000);
	AAudioStreamBuilder_setPerformanceMode(b, 10);	/* NONE: normal mixer path, deep buffer is fine */
	AAudioStreamBuilder_setUsage(b, 1);		/* MEDIA */
	if (AAudioStreamBuilder_openStream(b, &s) || AAudioStream_requestStart(s)) {
		if (s)
			AAudioStream_close(s);
		s = 0;
	}
	AAudioStreamBuilder_delete(b);
	return s;
}

static int bridge(int argc, char **argv, char **envp)
{
	const char *fifo = argc > 1 ? argv[1] : "/data/local/tmp/nura_stage/rootfs/var/lib/s26audio/fifo";
	static char buf[CHUNK * FRAME];
	AAudioStream *s = 0;
	int fd, idle = 0;

	(void)envp;
	mkfifo(fifo, 0666);
	chmod(fifo, 0666);
	fd = open(fifo, O_RDWR);	/* RDWR: never sees EOF when PulseAudio restarts */
	if (fd < 0) {
		dprintf(2, "audiobridge: can't open %s\n", fifo);
		return 1;
	}
	fcntl(fd, F_SETPIPE_SZ, 16384);	/* ~85 ms of latency in the pipe */
	dprintf(2, "audiobridge: reading %s\n", fifo);
	for (;;) {
		struct pollfd p = { fd, POLLIN, 0 };
		if (poll(&p, 1, 100) <= 0) {
			if (s && (idle += 100) >= IDLE_MS) {
				AAudioStream_requestStop(s);
				AAudioStream_close(s);
				s = 0;
				dprintf(2, "audiobridge: idle, stream closed\n");
			}
			continue;
		}
		ssize_t n = read(fd, buf, sizeof buf);
		if (n <= 0)
			continue;
		idle = 0;
		if (!s) {
			init_volumes();	/* cheap; also covers an audioserver restart */
			s = open_stream();
			if (!s) {
				dprintf(2, "audiobridge: AAudio open failed (audioserver up?)\n");
				sleep(1);
				continue;
			}
			dprintf(2, "audiobridge: stream open\n");
		}
		/* PulseAudio writes whole frames; 1 s timeout */
		if (AAudioStream_write(s, buf, (int32_t)(n / FRAME), 1000000000LL) < 0) {
			AAudioStream_close(s);	/* disconnected (route change, audioserver restart): reopen on next data */
			s = 0;
		}
	}
}

void s26_start(void *raw)
{
	static const struct structors st;
	__libc_init(raw, 0, bridge, &st);
}

__asm__(".text\n.globl _start\n_start:\n  mov x0, sp\n  b s26_start\n");
