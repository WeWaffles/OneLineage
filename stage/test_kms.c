/* test_kms.c — M2 display-handover probe for the S26 Nura container project.
 *
 * Runs INSIDE the Alpine chroot. Must be root.
 * 1. open /dev/dri/card0
 * 2. drmSetMaster  — the key experiment: fails if the QTI composer HAL still holds master
 * 3. enumerate connectors/CRTCs (report DSI-1 etc.)
 * 4. create a dumb buffer sized to the panel mode, fill it solid orange
 * 5. legacy drmModeSetCrtc to clueless-commit the frame — screen should turn solid orange
 *    until test exits / composer restarts.
 *
 * Safe: single solid frame, no panel power change, exits cleanly (exit 0 = success).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

int main(void)
{
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open(/dev/dri/card0)"); return 1; }

    /* --- the experiment --- */
    if (drmSetMaster(fd) != 0) {
        printf("FAIL: drmSetMaster: errno=%d (%s)\n", errno, strerror(errno));
        if (errno == EPERM) printf("  => a DRM master still exists (QTI composer alive?)\n");
        if (errno == EBUSY) printf("  => kernel refuses second master\n");
        close(fd);
        return 2;
    }
    printf("PASS: we are DRM master\n");

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("drmModeGetResources"); return 3; }
    printf("connectors=%d crtc=%d encoder=%d\n", res->count_connectors,
           res->count_crtcs, res->count_encoders);

    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (!c) continue;
        printf("  conn %3d type=%d status=%d nenc=%d nmode=%d name=conn-%02d-%d\n",
               c->connector_id, c->connector_type, c->connection,
               c->count_encoders, c->count_modes, c->connector_type, c->connector_type_id);
        if (c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) conn = c;
        else drmModeFreeConnector(c);
    }
    if (!conn) { printf("FAIL: no connected connector with modes\n"); return 4; }
    drmModeModeInfo *mode = &conn->modes[0];
    printf("  chosen mode: %dx%d@%dHz (h%d hs%d hb%d hp%d)\n",
           mode->hdisplay, mode->vdisplay, mode->vrefresh,
           mode->hdisplay, mode->hsync_start, mode->htotal, mode->hsync_end);

    /* encoder + crtc */
    drmModeEncoder *enc = NULL;
    if (conn->encoder_id) enc = drmModeGetEncoder(fd, conn->encoder_id);
    if (!enc) {
        for (int i = 0; i < conn->count_encoders && !enc; i++) {
            drmModeEncoder *e = drmModeGetEncoder(fd, conn->encoders[i]);
            if (e) enc = e;
        }
    }
    if (!enc) { printf("FAIL: no encoder for connector %d\n", conn->connector_id); return 5; }
    uint32_t crtc_id = 0;
    for (int i = 0; i < res->count_crtcs; i++)
        if (enc->possible_crtcs & (1u << i)) { crtc_id = res->crtcs[i]; break; }
    printf("  using encoder=%d crtc=%d\n", enc->encoder_id, crtc_id);

    /* dumb buffer, fill solid orange (RGBA8888, little endian) */
    struct drm_mode_create_dumb cr = { 0 };
    cr.width = mode->hdisplay; cr.height = mode->vdisplay; cr.bpp = 32;
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cr)) { perror("create dumb"); return 6; }
    printf("  dumb buffer: %ux%u stride=%u handle=%u\n", cr.width, cr.height, cr.pitch, cr.handle);

    uint32_t fb = 0;
    if (drmModeAddFB(fd, mode->hdisplay, mode->vdisplay, 24, 32, cr.pitch, cr.handle, &fb)) {
        perror("drmModeAddFB"); return 7;
    }

    struct drm_mode_map_dumb mr = { 0 };
    mr.handle = cr.handle;
    drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mr);
    unsigned char *map = mmap(NULL, (size_t)cr.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, mr.offset);
    if (map == MAP_FAILED) { perror("mmap dumb"); return 8; }
    for (uint32_t y = 0; y < cr.height; y++) {
        uint32_t *row = (uint32_t *)(map + (size_t)y * cr.pitch);
        for (uint32_t x = 0; x < cr.width; x++)
            row[x] = 0xFF0080FF; /* A=FF R=80 G=00 B=FF -> purple */
    }

    int rc = drmModeSetCrtc(fd, crtc_id, fb, 0, 0, &conn->connector_id, 1, mode);
    if (rc) printf("SET-CRTC rc=%d errno=%d (%s) — kernel rejected the flip\n", rc, errno, strerror(errno));
    else    printf("PASS: solid color committed to the panel\n");

    sleep(10); /* watch the screen; compositor/composer restart restores normal rendering */

    munmap(map, (size_t)cr.size);
    drmModeFreeEncoder(enc);
    drmModeFreeConnector(conn);
    drmModeFreeResources(res);
    close(fd);
    printf("done (screen may stay on last frame until the panel HAL takes over again)\n");
    return 0;
}
