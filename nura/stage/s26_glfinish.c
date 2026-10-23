/*
 * s26_glfinish.so — LD_PRELOAD for phoc on the Adreno/kgsl Mesa build.
 *
 * kgsl buffers carry no implicit-sync fences, so the display engine (msm DRM) scans out a frame
 * the GPU is still drawing -> chunks flicker / show the background. wlroots' gles2 renderer ends
 * each frame with glFlush(); turn that into glFinish() so the frame is complete before KMS gets it.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>

typedef void (*gl_void_fn)(void);
typedef void *(*get_proc_fn)(const char *);

static gl_void_fn real_finish;

static void ensure_finish(void)
{
	if (!real_finish)
		real_finish = (gl_void_fn)dlsym(RTLD_NEXT, "glFinish");
}

void glFlush(void)
{
	ensure_finish();
	real_finish();
}

/* wlroots may also look GL entry points up through EGL */
void *eglGetProcAddress(const char *name)
{
	static get_proc_fn real_gpa;
	if (!real_gpa)
		real_gpa = (get_proc_fn)dlsym(RTLD_NEXT, "eglGetProcAddress");
	if (name && strcmp(name, "glFlush") == 0)
		return (void *)glFlush;
	return real_gpa(name);
}
