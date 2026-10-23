/*
 * s26-pwcam — PipeWire camera node for Nura, fed with NV12 frames by Android-side s26_camd through a FIFO.
 *
 * Replaces "gst-launch ... ! pipewiresink mode=provide", which stalled after ~30 frames once Snapshot linked (the
 * preview froze, the shutter never fired). This is a plain driver stream like PipeWire's own video-src example:
 * every frame read from the FIFO is rotated to portrait and pushed with pw_stream_trigger_process().
 *
 * usage: s26-pwcam <node-name> <description> <cw|ccw> <fifo> <sensor-width> <sensor-height>
 * build: m182 (chroot gcc + pipewire-dev); run by s26-camfeed.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/buffers.h>
#include <spa/pod/builder.h>

struct cam {
	struct pw_thread_loop *loop;
	struct pw_stream *stream;
	int sw, sh;		/* sensor (FIFO) size, landscape */
	int ow, oh;		/* output size, portrait */
	uint8_t *frame;		/* latest frame, BGRx ow*oh*4 */
	int fresh;
	int nproc, nsent, nbusy, nread;	/* stats, logged every 150 frames read */
	uint64_t seq;
};

/* NV12 rotate by 90 degrees: cw (back camera) or ccw (front camera) */
static void rotate_nv12(const uint8_t *src, uint8_t *dst, int sw, int sh, int cw)
{
	const uint8_t *suv = src + sw * sh;
	uint8_t *duv = dst + sw * sh;
	int ow = sh, x, y;

	for (y = 0; y < sh; y++) {
		const uint8_t *row = src + y * sw;
		for (x = 0; x < sw; x++) {
			int dr = cw ? x : sw - 1 - x;
			int dc = cw ? sh - 1 - y : y;
			dst[dr * ow + dc] = row[x];
		}
	}
	/* chroma: half resolution, UV pairs move together */
	for (y = 0; y < sh / 2; y++) {
		const uint8_t *row = suv + y * sw;
		for (x = 0; x < sw / 2; x++) {
			int dr = cw ? x : sw / 2 - 1 - x;
			int dc = cw ? sh / 2 - 1 - y : y;
			duv[dr * ow + dc * 2] = row[x * 2];
			duv[dr * ow + dc * 2 + 1] = row[x * 2 + 1];
		}
	}
}

/*
 * NV12 -> BGRx (BT.601 limited range, fixed point). Apps get BGRx because GTK can't show NV12 on this GPU: its GL
 * import of YUV frames needs dmabuf export, which kgsl Mesa lacks -> Snapshot's preview stayed black.
 */
static inline uint8_t clamp8(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

static void nv12_to_bgrx(const uint8_t *src, uint8_t *dst, int w, int h)
{
	const uint8_t *uv = src + w * h;
	int x, y;

	for (y = 0; y < h; y++) {
		const uint8_t *yr = src + y * w, *uvr = uv + (y / 2) * w;
		uint8_t *o = dst + y * w * 4;
		for (x = 0; x < w; x++) {
			int c = 298 * (yr[x] - 16) + 128, d = uvr[x & ~1] - 128, e = uvr[x | 1] - 128;
			o[0] = clamp8((c + 516 * d) >> 8);
			o[1] = clamp8((c - 100 * d - 208 * e) >> 8);
			o[2] = clamp8((c + 409 * e) >> 8);
			o[3] = 255;
			o += 4;
		}
	}
}

static void on_process(void *userdata)
{
	struct cam *c = userdata;
	struct pw_buffer *b;
	struct spa_data *d;
	uint32_t n = c->ow * c->oh * 4;

	c->nproc++;
	if (!c->fresh)
		return;
	if (!(b = pw_stream_dequeue_buffer(c->stream))) {
		c->nbusy++;	/* consumer still holds every buffer */
		return;
	}
	c->nsent++;
	/* timestamp + sequence: without them the app's sink treats frames as late and keeps showing the first one */
	{
		struct spa_meta_header *h = spa_buffer_find_meta_data(b->buffer, SPA_META_Header, sizeof(*h));
		if (h) {
			struct timespec ts;
			clock_gettime(CLOCK_MONOTONIC, &ts);
			h->pts = SPA_TIMESPEC_TO_NSEC(&ts);
			h->flags = 0;
			h->seq = c->seq++;
			h->dts_offset = 0;
		}
	}
	d = &b->buffer->datas[0];
	if (d->data) {
		if (n > d->maxsize)
			n = d->maxsize;
		memcpy(d->data, c->frame, n);
		d->chunk->offset = 0;
		d->chunk->size = n;
		d->chunk->stride = c->ow * 4;
	}
	c->fresh = 0;
	pw_stream_queue_buffer(c->stream, b);
}

static void on_param_changed(void *userdata, uint32_t id, const struct spa_pod *param)
{
	struct cam *c = userdata;
	uint8_t buf[512];
	struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));
	const struct spa_pod *params[2];

	if (!param || id != SPA_PARAM_Format)
		return;
	params[1] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
		SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
		SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_header)));
	params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
		SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(4, 2, 8),
		SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1),
		SPA_PARAM_BUFFERS_size, SPA_POD_Int(c->ow * c->oh * 4),
		SPA_PARAM_BUFFERS_stride, SPA_POD_Int(c->ow * 4),
		SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr)));
	pw_stream_update_params(c->stream, params, 2);
}

static void on_state_changed(void *userdata, enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
	(void)userdata;
	(void)old;
	fprintf(stderr, "s26-pwcam: %s%s%s\n", pw_stream_state_as_string(state), error ? ": " : "", error ? error : "");
}

static const struct pw_stream_events events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = on_state_changed,
	.param_changed = on_param_changed,
	.process = on_process,
};

static int read_full(int fd, uint8_t *p, size_t n)
{
	while (n) {
		ssize_t r = read(fd, p, n);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		p += r;
		n -= r;
	}
	return 0;
}

int main(int argc, char *argv[])
{
	struct cam c = { 0 };
	uint8_t pbuf[1024];
	struct spa_pod_builder b = SPA_POD_BUILDER_INIT(pbuf, sizeof(pbuf));
	const struct spa_pod *params[1];
	uint8_t *raw, *rot;
	size_t fsz;
	int fd, cw;

	if (argc < 7) {
		fprintf(stderr, "usage: s26-pwcam <node-name> <description> <cw|ccw> <fifo> <width> <height>\n");
		return 1;
	}
	cw = strcmp(argv[3], "ccw") != 0;
	c.sw = atoi(argv[5]);
	c.sh = atoi(argv[6]);
	c.ow = c.sh;
	c.oh = c.sw;
	fsz = (size_t)c.sw * c.sh * 3 / 2;
	raw = malloc(fsz);
	rot = malloc(fsz);
	c.frame = malloc((size_t)c.ow * c.oh * 4);
	if ((fd = open(argv[4], O_RDONLY)) < 0) {
		perror(argv[4]);
		return 1;
	}

	pw_init(&argc, &argv);
	c.loop = pw_thread_loop_new("s26-pwcam", NULL);
	c.stream = pw_stream_new_simple(pw_thread_loop_get_loop(c.loop), argv[1],
		pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
				  PW_KEY_MEDIA_CLASS, "Video/Source", PW_KEY_MEDIA_ROLE, "Camera",
				  PW_KEY_NODE_NAME, argv[1], PW_KEY_NODE_DESCRIPTION, argv[2],
				  /* Snapshot reads this for its front/back switcher (back = rotated clockwise) */
				  "api.libcamera.location", cw ? "back" : "front", NULL),
		&events, &c);
	params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
		SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
		SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
		SPA_FORMAT_VIDEO_format, SPA_POD_Id(SPA_VIDEO_FORMAT_BGRx),
		SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE(c.ow, c.oh)),
		SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&SPA_FRACTION(30, 1)));
	pw_stream_connect(c.stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
			  PW_STREAM_FLAG_DRIVER | PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
	pw_thread_loop_start(c.loop);

	/* frames arrive whole from s26_camd (it never writes partial frames); idle keep-alives are black frames */
	while (read_full(fd, raw, fsz) == 0) {
		rotate_nv12(raw, rot, c.sw, c.sh, cw);
		pw_thread_loop_lock(c.loop);
		nv12_to_bgrx(rot, c.frame, c.ow, c.oh);
		c.fresh = 1;
		if (pw_stream_is_driving(c.stream))
			pw_stream_trigger_process(c.stream);
		if (++c.nread % 150 == 0) {
			fprintf(stderr, "s26-pwcam: %d read, %d process calls, %d sent, %d no-buffer, driving=%d\n",
				c.nread, c.nproc, c.nsent, c.nbusy, pw_stream_is_driving(c.stream));
			c.nproc = c.nsent = c.nbusy = 0;
		}
		pw_thread_loop_unlock(c.loop);
	}
	fprintf(stderr, "s26-pwcam: FIFO closed\n");
	pw_thread_loop_stop(c.loop);
	pw_stream_destroy(c.stream);
	pw_thread_loop_destroy(c.loop);
	pw_deinit();
	return 0;
}
