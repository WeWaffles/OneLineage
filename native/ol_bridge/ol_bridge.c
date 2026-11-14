// OneLineage binder bridge (docs/ISOLATION.md, phase 3).
//
// Connects two binder contexts that otherwise cannot see each other:
//   HOST  - One UI's /dev/binderfs/binder (its servicemanager is handle 0)
//   GUEST - Lineage's private binderfs instance (Lineage's own servicemanager)
//
// It talks to the kernel driver directly (no libbinder: one libbinder process
// can only use one binder context). Every remote object that crosses is
// replaced by a local proxy node on the other side; calls on a proxy node are
// re-issued on the original handle, and the reply is translated back. File
// descriptors are passed through.
//
// Services are mirrored both ways by name, except a denylist of security
// services that hold One UI state (keystore, gatekeeper service, vold, Weaver,
// authsecret, ...). The guest gets local stubs for Weaver and AuthSecret that
// fail every call, so its LockSettings treats them as unavailable instead of
// blocking on them, and never reaches the host's.
//
// Limits (v1): AIDL only (no HIDL scatter-gather objects; this device has no
// HIDL services). Host services see the bridge (root) as the caller.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/android/binder.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define HOST 0
#define GUEST 1
#define OTHER(c) (1 - (c))
#define VM_SIZE ((1 * 1024 * 1024) - sysconf(_SC_PAGE_SIZE) * 2)

#define PACK(a, b, c, d) ((uint32_t)(((a) << 24) | ((b) << 16) | ((c) << 8) | (d)))
#define PING_TRANSACTION PACK('_', 'P', 'N', 'G')
#define INTERFACE_TRANSACTION PACK('_', 'N', 'T', 'F')
#define SM_HEADER PACK('S', 'Y', 'S', 'T')
#define SM_GET 1
#define SM_CHECK 3
#define SM_ADD 5
#define SM_LIST 6
#define SM_REGISTER_NOTIFICATIONS 7
#define CB_ON_REGISTRATION 1  // IServiceCallback.onRegistration(String, IBinder), oneway
#define STAB_VINTF 0x3f
#define ST_UNKNOWN_TRANSACTION (-74)
#define ST_DEAD_OBJECT (-32)
#define ST_FAILED_TRANSACTION ((int32_t)0x80000002)

static const char *CTX_NAME[2] = {"host", "guest"};
static int g_fd[2] = {-1, -1};
static volatile int g_verbose = 0;

static void logf_(const char *fmt, ...) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "%02d:%02d:%02d [ol_bridge] %s\n", tm.tm_hour, tm.tm_min, tm.tm_sec, buf);
    fflush(stderr);
}
#define LOG(...) logf_(__VA_ARGS__)
#define VLOG(...) do { if (g_verbose) logf_(__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- nodes ---
// A node is an object WE own in context OTHER(ctx) that stands for `handle`
// in context `ctx`. Stubs are local objects with no remote behind them.
typedef struct node {
    int ctx;          // context the real object lives in (-1 for stubs)
    uint32_t handle;  // handle in that context
    const char *stub; // interface descriptor for stubs, else NULL
    const char *lazy; // on-demand host service name, resolved on first call
    volatile int resolved;
    int callback;     // our IServiceCallback for on-demand starts (host side)
} node_t;

static pthread_mutex_t g_nodes_lock = PTHREAD_MUTEX_INITIALIZER;
static node_t **g_nodes;
static size_t g_nnodes, g_capnodes;

static int write_cmds(int ctx, const void *buf, size_t len);

static node_t *get_node(int ctx, uint32_t handle) {
    pthread_mutex_lock(&g_nodes_lock);
    for (size_t i = 0; i < g_nnodes; i++) {
        if (g_nodes[i]->ctx == ctx && g_nodes[i]->handle == handle && !g_nodes[i]->stub && !g_nodes[i]->lazy) {
            node_t *n = g_nodes[i];
            pthread_mutex_unlock(&g_nodes_lock);
            return n;
        }
    }
    node_t *n = calloc(1, sizeof *n);
    n->ctx = ctx;
    n->handle = handle;
    if (g_nnodes == g_capnodes) {
        g_capnodes = g_capnodes ? g_capnodes * 2 : 256;
        g_nodes = realloc(g_nodes, g_capnodes * sizeof *g_nodes);
    }
    g_nodes[g_nnodes++] = n;
    pthread_mutex_unlock(&g_nodes_lock);
    // Keep the remote alive for as long as the bridge runs (nodes are never
    // freed in v1; the session ends with a reboot anyway).
    struct { uint32_t c1; uint32_t h1; uint32_t c2; uint32_t h2; } __attribute__((packed)) cmd = {
        BC_INCREFS, handle, BC_ACQUIRE, handle};
    write_cmds(ctx, &cmd, sizeof cmd);
    return n;
}

static node_t *make_stub(const char *descriptor) {
    node_t *n = calloc(1, sizeof *n);
    n->ctx = -1;
    n->stub = descriptor;
    pthread_mutex_lock(&g_nodes_lock);
    if (g_nnodes == g_capnodes) {
        g_capnodes = g_capnodes ? g_capnodes * 2 : 256;
        g_nodes = realloc(g_nodes, g_capnodes * sizeof *g_nodes);
    }
    g_nodes[g_nnodes++] = n;
    pthread_mutex_unlock(&g_nodes_lock);
    return n;
}

// --------------------------------------------------------------- parcel ---
typedef struct {
    uint8_t *data;
    size_t len, cap;
    binder_size_t *offs;
    size_t noffs, capoffs;
} pbuf_t;

static void pb_reserve(pbuf_t *p, size_t n) {
    if (p->len + n > p->cap) {
        size_t c = p->cap ? p->cap : 256;
        while (c < p->len + n) c *= 2;
        p->data = realloc(p->data, c);
        p->cap = c;
    }
}
static void pb_i32(pbuf_t *p, int32_t v) {
    pb_reserve(p, 4);
    memcpy(p->data + p->len, &v, 4);
    p->len += 4;
}
static void pb_str16(pbuf_t *p, const char *s) {
    size_t n = strlen(s);
    pb_i32(p, (int32_t)n);
    size_t bytes = (n + 1) * 2, padded = (bytes + 3) & ~(size_t)3;
    pb_reserve(p, padded);
    uint16_t *u = (uint16_t *)(p->data + p->len);
    for (size_t i = 0; i < n; i++) u[i] = (uint8_t)s[i];
    memset((uint8_t *)u + n * 2, 0, padded - n * 2);
    p->len += padded;
}
static void pb_add_off(pbuf_t *p, binder_size_t off) {
    if (p->noffs == p->capoffs) {
        p->capoffs = p->capoffs ? p->capoffs * 2 : 8;
        p->offs = realloc(p->offs, p->capoffs * sizeof *p->offs);
    }
    p->offs[p->noffs++] = off;
}
static void pb_binder(pbuf_t *p, node_t *n, int32_t stability) {
    pb_reserve(p, sizeof(struct flat_binder_object));
    struct flat_binder_object *o = (void *)(p->data + p->len);
    memset(o, 0, sizeof *o);
    o->hdr.type = BINDER_TYPE_BINDER;
    o->flags = FLAT_BINDER_FLAG_ACCEPTS_FDS | 0x13;  // same as libbinder
    o->binder = (binder_uintptr_t)(uintptr_t)n;
    o->cookie = (binder_uintptr_t)(uintptr_t)n;
    pb_add_off(p, p->len);
    p->len += sizeof *o;
    pb_i32(p, stability);
}
static void pb_iface(pbuf_t *p, const char *iface) {
    pb_i32(p, 0);       // strict mode policy
    pb_i32(p, -1);      // work source: unset
    pb_i32(p, SM_HEADER);
    pb_str16(p, iface);
}
static void pb_free(pbuf_t *p) {
    free(p->data);
    free(p->offs);
    memset(p, 0, sizeof *p);
}

typedef struct {
    const uint8_t *data;
    size_t len, pos;
    const binder_size_t *offs;
    size_t noffs;
} rd_t;
static int rd_i32(rd_t *r, int32_t *v) {
    if (r->pos + 4 > r->len) return -1;
    memcpy(v, r->data + r->pos, 4);
    r->pos += 4;
    return 0;
}
static int rd_str16(rd_t *r, char *out, size_t outsz) {
    int32_t n;
    if (rd_i32(r, &n)) return -1;
    if (n < 0) { out[0] = 0; return 0; }
    size_t bytes = ((size_t)n + 1) * 2, padded = (bytes + 3) & ~(size_t)3;
    if (r->pos + padded > r->len) return -1;
    const uint16_t *u = (const uint16_t *)(r->data + r->pos);
    size_t i;
    for (i = 0; i < (size_t)n && i + 1 < outsz; i++) out[i] = u[i] < 128 ? (char)u[i] : '?';
    out[i] = 0;
    r->pos += padded;
    return 0;
}

// ------------------------------------------------------------- driver io ---
static int bwr(int ctx, const void *w, size_t wl, void *rbuf, size_t rl, size_t *rc) {
    struct binder_write_read b = {0};
    b.write_buffer = (binder_uintptr_t)(uintptr_t)w;
    b.write_size = wl;
    b.read_buffer = (binder_uintptr_t)(uintptr_t)rbuf;
    b.read_size = rl;
    int r;
    do {
        r = ioctl(g_fd[ctx], BINDER_WRITE_READ, &b);
    } while (r < 0 && errno == EINTR);
    if (r < 0) return -errno;
    if (rc) *rc = b.read_consumed;
    return 0;
}
static int write_cmds(int ctx, const void *buf, size_t len) { return bwr(ctx, buf, len, NULL, 0, NULL); }

static void free_buffer(int ctx, binder_uintptr_t buf) {
    struct { uint32_t cmd; binder_uintptr_t p; } __attribute__((packed)) c = {BC_FREE_BUFFER, buf};
    write_cmds(ctx, &c, sizeof c);
}

typedef struct {
    int ok;  // 1 = BR_REPLY received
    int32_t status;
    struct binder_transaction_data tr;
} reply_t;

static void spawn_looper(int ctx, int enter);
static int sm_lookup(int ctx, uint32_t code, const char *name, int *kind, uint32_t *handle, struct node **own, int32_t *stab);
static pthread_mutex_t g_lazy_lock = PTHREAD_MUTEX_INITIALIZER;
static node_t *get_node(int ctx, uint32_t handle);
// One pending on-demand start at a time (serialised by g_lazy_lock); the
// host servicemanager reports the registration to our callback node.
static struct {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    char name[256];
    uint32_t handle;
    int got;
} g_pending = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, "", 0, 0};
static struct node *g_cb_node;
static void handle_incoming(int ctx, struct binder_transaction_data *tr);

enum { WAIT_REPLY, WAIT_COMPLETE, LOOP };

// Reads and processes driver commands on `ctx` until the wait condition.
// Returns 0, or a negative binder status for failed transactions.
static int run(int ctx, int mode, reply_t *rep) {
    uint8_t rbuf[512];
    for (;;) {
        size_t got = 0;
        int e = bwr(ctx, NULL, 0, rbuf, sizeof rbuf, &got);
        if (e) {
            if (mode == LOOP) { usleep(10000); continue; }
            return ST_FAILED_TRANSACTION;
        }
        size_t pos = 0;
        while (pos + 4 <= got) {
            uint32_t cmd;
            memcpy(&cmd, rbuf + pos, 4);
            pos += 4;
            size_t sz = _IOC_SIZE(cmd);
            uint8_t *arg = rbuf + pos;
            if (pos + sz > got) break;
            pos += sz;
            switch (cmd) {
            case BR_NOOP:
            case BR_OK:
            case BR_RELEASE:
            case BR_DECREFS:
                break;
            case BR_INCREFS:
            case BR_ACQUIRE: {
                struct binder_ptr_cookie pc;
                memcpy(&pc, arg, sizeof pc);
                struct { uint32_t c; struct binder_ptr_cookie pc; } __attribute__((packed)) a = {
                    cmd == BR_INCREFS ? BC_INCREFS_DONE : BC_ACQUIRE_DONE, pc};
                write_cmds(ctx, &a, sizeof a);
                break;
            }
            case BR_SPAWN_LOOPER:
                spawn_looper(ctx, 0);
                break;
            case BR_TRANSACTION_COMPLETE:
                if (mode == WAIT_COMPLETE) return 0;
                break;
            case BR_TRANSACTION: {
                struct binder_transaction_data tr;
                memcpy(&tr, arg, sizeof tr);
                handle_incoming(ctx, &tr);
                break;
            }
            case BR_REPLY:
                if (rep) {
                    memcpy(&rep->tr, arg, sizeof rep->tr);
                    rep->ok = 1;
                    if (rep->tr.flags & TF_STATUS_CODE) {
                        int32_t st = 0;
                        if (rep->tr.data_size >= 4) memcpy(&st, (void *)(uintptr_t)rep->tr.data.ptr.buffer, 4);
                        free_buffer(ctx, rep->tr.data.ptr.buffer);
                        rep->ok = 0;
                        return st ? st : ST_FAILED_TRANSACTION;
                    }
                }
                if (mode == WAIT_REPLY) return 0;
                break;
            case BR_DEAD_REPLY:
                if (mode != LOOP) return ST_DEAD_OBJECT;
                break;
            case BR_FAILED_REPLY:
            case BR_FROZEN_REPLY:
                if (mode != LOOP) return ST_FAILED_TRANSACTION;
                break;
            case BR_ERROR: {
                int32_t e2;
                memcpy(&e2, arg, 4);
                LOG("%s: BR_ERROR %d", CTX_NAME[ctx], e2);
                if (mode != LOOP) return e2 ? e2 : ST_FAILED_TRANSACTION;
                break;
            }
            default:
                VLOG("%s: ignoring BR cmd 0x%x", CTX_NAME[ctx], cmd);
                break;
            }
        }
    }
}

// Sends a transaction on ctx. For two-way calls, *rep receives the reply
// buffer (caller must free_buffer it).
static int transact(int ctx, uint32_t handle, uint32_t code, uint32_t flags, pbuf_t *p, reply_t *rep) {
    struct { uint32_t cmd; struct binder_transaction_data tr; } __attribute__((packed)) w;
    memset(&w, 0, sizeof w);
    w.cmd = BC_TRANSACTION;
    w.tr.target.handle = handle;
    w.tr.code = code;
    w.tr.flags = flags;
    w.tr.data_size = p ? p->len : 0;
    w.tr.offsets_size = p ? p->noffs * sizeof(binder_size_t) : 0;
    w.tr.data.ptr.buffer = p ? (binder_uintptr_t)(uintptr_t)p->data : 0;
    w.tr.data.ptr.offsets = p ? (binder_uintptr_t)(uintptr_t)p->offs : 0;
    if (write_cmds(ctx, &w, sizeof w)) return ST_FAILED_TRANSACTION;
    if (flags & TF_ONE_WAY) return run(ctx, WAIT_COMPLETE, NULL);
    reply_t local = {0};
    if (!rep) rep = &local;
    int st = run(ctx, WAIT_REPLY, rep);
    if (rep == &local && local.ok) free_buffer(ctx, local.tr.data.ptr.buffer);
    return st;
}

static void send_reply(int ctx, pbuf_t *p, uint32_t flags, int32_t status) {
    pbuf_t tmp = {0};
    if (status) {
        pb_i32(&tmp, status);
        p = &tmp;
        flags = TF_STATUS_CODE;
    }
    struct { uint32_t cmd; struct binder_transaction_data tr; } __attribute__((packed)) w;
    memset(&w, 0, sizeof w);
    w.cmd = BC_REPLY;
    w.tr.flags = flags & ~TF_ONE_WAY;
    w.tr.data_size = p ? p->len : 0;
    w.tr.offsets_size = p ? p->noffs * sizeof(binder_size_t) : 0;
    w.tr.data.ptr.buffer = p ? (binder_uintptr_t)(uintptr_t)p->data : 0;
    w.tr.data.ptr.offsets = p ? (binder_uintptr_t)(uintptr_t)p->offs : 0;
    if (write_cmds(ctx, &w, sizeof w) == 0) run(ctx, WAIT_COMPLETE, NULL);
    pb_free(&tmp);
}

// ----------------------------------------------------------- translation ---
typedef struct { int fds[64]; int n; } fdlist_t;
static void close_fds(fdlist_t *f) {
    for (int i = 0; i < f->n; i++) close(f->fds[i]);
    f->n = 0;
}

// Copies a parcel received on `src` into `out`, rewriting objects so it can
// be sent on OTHER(src).
static int translate(int src, const struct binder_transaction_data *tr, pbuf_t *out, fdlist_t *fds) {
    int dst = OTHER(src);
    pb_reserve(out, tr->data_size);
    memcpy(out->data, (void *)(uintptr_t)tr->data.ptr.buffer, tr->data_size);
    out->len = tr->data_size;
    size_t n = tr->offsets_size / sizeof(binder_size_t);
    const binder_size_t *offs = (const void *)(uintptr_t)tr->data.ptr.offsets;
    for (size_t i = 0; i < n; i++) {
        binder_size_t o = offs[i];
        if (o + sizeof(struct binder_object_header) > out->len) return -1;
        struct binder_object_header *h = (void *)(out->data + o);
        switch (h->type) {
        case BINDER_TYPE_HANDLE:
        case BINDER_TYPE_WEAK_HANDLE: {
            struct flat_binder_object *f = (void *)h;
            node_t *nd = get_node(src, f->handle);
            f->hdr.type = h->type == BINDER_TYPE_HANDLE ? BINDER_TYPE_BINDER : BINDER_TYPE_WEAK_BINDER;
            // Our proxy node must accept fds (graphics buffers, shared memory)
            // and must not ask for security contexts we do not parse.
            f->flags = (f->flags & ~FLAT_BINDER_FLAG_TXN_SECURITY_CTX) | FLAT_BINDER_FLAG_ACCEPTS_FDS;
            f->binder = (binder_uintptr_t)(uintptr_t)nd;
            f->cookie = (binder_uintptr_t)(uintptr_t)nd;
            break;
        }
        case BINDER_TYPE_BINDER:
        case BINDER_TYPE_WEAK_BINDER: {
            struct flat_binder_object *f = (void *)h;
            node_t *nd = (node_t *)(uintptr_t)f->cookie;
            if (!nd) break;  // null binder
            if (nd->stub || nd->ctx != dst || (nd->lazy && !nd->resolved)) {
                LOG("refusing to pass %s object to %s", nd->stub ? nd->stub : "foreign", CTX_NAME[dst]);
                return -1;
            }
            uint32_t hd = nd->handle;
            f->hdr.type = h->type == BINDER_TYPE_BINDER ? BINDER_TYPE_HANDLE : BINDER_TYPE_WEAK_HANDLE;
            f->binder = 0;
            f->handle = hd;
            f->cookie = 0;
            break;
        }
        case BINDER_TYPE_FD: {
            struct binder_fd_object *f = (void *)h;
            if (fds->n < 64) fds->fds[fds->n++] = (int)f->fd;
            break;
        }
        default:
            LOG("unsupported binder object type 0x%x (HIDL?)", h->type);
            return -1;
        }
        pb_add_off(out, o);
    }
    return 0;
}

static void stub_reply(int ctx, node_t *nd, struct binder_transaction_data *tr) {
    if (tr->flags & TF_ONE_WAY) return;
    pbuf_t p = {0};
    if (tr->code == PING_TRANSACTION) {
        send_reply(ctx, &p, 0, 0);
    } else if (tr->code == INTERFACE_TRANSACTION) {
        pb_str16(&p, nd->stub);
        send_reply(ctx, &p, 0, 0);
    } else {
        VLOG("stub %s: refusing code %u", nd->stub, tr->code);
        send_reply(ctx, NULL, 0, ST_UNKNOWN_TRANSACTION);
    }
    pb_free(&p);
}

static void handle_incoming(int ctx, struct binder_transaction_data *tr) {
    node_t *nd = (node_t *)(uintptr_t)tr->cookie;
    int oneway = tr->flags & TF_ONE_WAY;
    if (!nd) {
        if (!oneway) send_reply(ctx, NULL, 0, ST_UNKNOWN_TRANSACTION);
        free_buffer(ctx, tr->data.ptr.buffer);
        return;
    }
    if (nd->callback) {
        // onRegistration(name, binder) from the host servicemanager.
        if (tr->code == CB_ON_REGISTRATION) {
            rd_t r = {(void *)(uintptr_t)tr->data.ptr.buffer, tr->data_size, 0, NULL, 0};
            int32_t skip;
            char desc[128], name[256];
            if (!rd_i32(&r, &skip) && !rd_i32(&r, &skip) && !rd_i32(&r, &skip) && !rd_str16(&r, desc, sizeof desc) &&
                !rd_str16(&r, name, sizeof name) && r.pos + sizeof(struct flat_binder_object) <= r.len) {
                struct flat_binder_object f;
                memcpy(&f, r.data + r.pos, sizeof f);
                pthread_mutex_lock(&g_pending.mu);
                if (f.hdr.type == BINDER_TYPE_HANDLE && !g_pending.got && !strcmp(name, g_pending.name)) {
                    get_node(HOST, f.handle);  // our strong ref keeps it running
                    g_pending.handle = f.handle;
                    g_pending.got = 1;
                    pthread_cond_broadcast(&g_pending.cv);
                }
                pthread_mutex_unlock(&g_pending.mu);
            }
        }
        if (!oneway) send_reply(ctx, NULL, 0, 0);
        free_buffer(ctx, tr->data.ptr.buffer);
        return;
    }
    if (nd->stub) {
        stub_reply(ctx, nd, tr);
        free_buffer(ctx, tr->data.ptr.buffer);
        return;
    }
    if (nd->lazy && !nd->resolved) {
        // First call to an on-demand host service: getService() makes the
        // host servicemanager start it and wait for it. Our reference then
        // keeps it alive (lazy services exit when they have no clients).
        pthread_mutex_lock(&g_lazy_lock);
        if (!nd->resolved) {
            int kind;
            uint32_t h = 0;
            struct node *own = NULL;
            int32_t stab = 0;
            // Same as libbinder's waitForService(): ask for notification,
            // trigger the start with getService(), then wait up to 10 s.
            pthread_mutex_lock(&g_pending.mu);
            snprintf(g_pending.name, sizeof g_pending.name, "%s", nd->lazy);
            g_pending.got = 0;
            pthread_mutex_unlock(&g_pending.mu);
            {
                pbuf_t p = {0};
                pb_iface(&p, "android.os.IServiceManager");
                pb_str16(&p, nd->lazy);
                pb_binder(&p, g_cb_node, 0x0c);
                transact(HOST, 0, SM_REGISTER_NOTIFICATIONS, TF_ACCEPT_FDS, &p, NULL);
                pb_free(&p);
            }
            int got = !sm_lookup(HOST, SM_GET, nd->lazy, &kind, &h, &own, &stab) && kind == 1;
            if (!got) {
                struct timespec dl;
                clock_gettime(CLOCK_REALTIME, &dl);
                dl.tv_sec += 10;
                pthread_mutex_lock(&g_pending.mu);
                while (!g_pending.got && pthread_cond_timedwait(&g_pending.cv, &g_pending.mu, &dl) == 0) {}
                if (g_pending.got) { h = g_pending.handle; got = 1; kind = 1; }
                pthread_mutex_unlock(&g_pending.mu);
            }
            pthread_mutex_lock(&g_pending.mu);
            g_pending.name[0] = 0;
            pthread_mutex_unlock(&g_pending.mu);
            if (got) {
                nd->handle = h;
                nd->resolved = 1;
                LOG("started on-demand host service %s", nd->lazy);
            } else {
                LOG("on-demand host service %s could not be started", nd->lazy);
            }
        }
        pthread_mutex_unlock(&g_lazy_lock);
        if (!nd->resolved) {
            if (!oneway) send_reply(ctx, NULL, 0, ST_DEAD_OBJECT);
            free_buffer(ctx, tr->data.ptr.buffer);
            return;
        }
    }
    int dst = nd->ctx;
    pbuf_t out = {0};
    fdlist_t fds = {0};
    if (translate(ctx, tr, &out, &fds)) {
        if (!oneway) send_reply(ctx, NULL, 0, ST_FAILED_TRANSACTION);
        free_buffer(ctx, tr->data.ptr.buffer);
        close_fds(&fds);
        pb_free(&out);
        return;
    }
    uint32_t flags = tr->flags & (TF_ONE_WAY | TF_ACCEPT_FDS | TF_CLEAR_BUF);
    if (fds.n) flags |= TF_ACCEPT_FDS;
    reply_t rep = {0};
    int st = transact(dst, nd->handle, tr->code, flags, &out, oneway ? NULL : &rep);
    close_fds(&fds);
    pb_free(&out);
    free_buffer(ctx, tr->data.ptr.buffer);
    if (oneway) return;
    if (st || !rep.ok) {
        send_reply(ctx, NULL, 0, st ? st : ST_FAILED_TRANSACTION);
        return;
    }
    pbuf_t back = {0};
    fdlist_t fds2 = {0};
    if (translate(dst, &rep.tr, &back, &fds2)) {
        send_reply(ctx, NULL, 0, ST_FAILED_TRANSACTION);
    } else {
        send_reply(ctx, &back, rep.tr.flags & (TF_CLEAR_BUF), 0);
    }
    free_buffer(dst, rep.tr.data.ptr.buffer);
    close_fds(&fds2);
    pb_free(&back);
}

// ---------------------------------------------------------------- threads ---
typedef struct { int ctx; int enter; } loop_arg_t;
static void *looper(void *a) {
    loop_arg_t la = *(loop_arg_t *)a;
    free(a);
    uint32_t c = la.enter ? BC_ENTER_LOOPER : BC_REGISTER_LOOPER;
    write_cmds(la.ctx, &c, sizeof c);
    run(la.ctx, LOOP, NULL);
    return NULL;
}
static void spawn_looper(int ctx, int enter) {
    loop_arg_t *a = malloc(sizeof *a);
    a->ctx = ctx;
    a->enter = enter;
    pthread_t t;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&at, 1024 * 1024);
    if (pthread_create(&t, &at, looper, a)) free(a);
    pthread_attr_destroy(&at);
}

// --------------------------------------------------------- servicemanager ---
typedef struct { char **v; size_t n; } names_t;
static void names_free(names_t *s) {
    for (size_t i = 0; i < s->n; i++) free(s->v[i]);
    free(s->v);
    s->v = NULL;
    s->n = 0;
}
static int names_has(const names_t *s, const char *x) {
    for (size_t i = 0; i < s->n; i++)
        if (!strcmp(s->v[i], x)) return 1;
    return 0;
}
static void names_add(names_t *s, const char *x) {
    if (names_has(s, x)) return;
    s->v = realloc(s->v, (s->n + 1) * sizeof *s->v);
    s->v[s->n++] = strdup(x);
}
static int sm_list(int ctx, names_t *out) {
    pbuf_t p = {0};
    pb_iface(&p, "android.os.IServiceManager");
    pb_i32(&p, 0xf);  // DUMP_FLAG_PRIORITY_ALL
    reply_t rep = {0};
    int st = transact(ctx, 0, SM_LIST, TF_ACCEPT_FDS, &p, &rep);
    pb_free(&p);
    if (st || !rep.ok) return st ? st : -1;
    rd_t r = {(void *)(uintptr_t)rep.tr.data.ptr.buffer, rep.tr.data_size, 0, NULL, 0};
    int32_t ex, count;
    int ret = -1;
    if (!rd_i32(&r, &ex) && ex == 0 && !rd_i32(&r, &count) && count >= 0) {
        char name[512];
        ret = 0;
        for (int32_t i = 0; i < count; i++) {
            if (rd_str16(&r, name, sizeof name)) { ret = -1; break; }
            names_add(out, name);
        }
    }
    free_buffer(ctx, rep.tr.data.ptr.buffer);
    return ret;
}

// Looks a service up. *kind: 0 = not found, 1 = remote handle, 2 = our own node.
static int sm_lookup(int ctx, uint32_t code, const char *name, int *kind, uint32_t *handle, node_t **own, int32_t *stab) {
    pbuf_t p = {0};
    pb_iface(&p, "android.os.IServiceManager");
    pb_str16(&p, name);
    reply_t rep = {0};
    int st = transact(ctx, 0, code, TF_ACCEPT_FDS, &p, &rep);
    pb_free(&p);
    *kind = 0;
    if (st || !rep.ok) return st ? st : -1;
    rd_t r = {(void *)(uintptr_t)rep.tr.data.ptr.buffer, rep.tr.data_size, 0, NULL, 0};
    int32_t ex;
    if (!rd_i32(&r, &ex) && ex == 0 && r.pos + sizeof(struct flat_binder_object) <= r.len) {
        struct flat_binder_object f;
        memcpy(&f, r.data + r.pos, sizeof f);
        r.pos += sizeof f;
        int32_t s = 0;
        rd_i32(&r, &s);
        *stab = s;
        if (f.hdr.type == BINDER_TYPE_HANDLE) {
            *kind = 1;
            *handle = f.handle;
            // Take our own reference before the reply buffer (and the
            // kernel's temporary one) is freed.
            get_node(ctx, f.handle);
        } else if (f.hdr.type == BINDER_TYPE_BINDER && f.cookie) {
            *kind = 2;
            *own = (node_t *)(uintptr_t)f.cookie;
        }
    }
    free_buffer(ctx, rep.tr.data.ptr.buffer);
    return 0;
}

static int sm_check(int ctx, const char *name, int *kind, uint32_t *handle, node_t **own, int32_t *stab) {
    return sm_lookup(ctx, SM_CHECK, name, kind, handle, own, stab);
}

static int sm_add(int ctx, const char *name, node_t *nd, int32_t stab) {
    pbuf_t p = {0};
    pb_iface(&p, "android.os.IServiceManager");
    pb_str16(&p, name);
    pb_binder(&p, nd, stab);
    pb_i32(&p, 1);  // allowIsolated
    pb_i32(&p, 0xf);
    reply_t rep = {0};
    int st = transact(ctx, 0, SM_ADD, TF_ACCEPT_FDS, &p, &rep);
    pb_free(&p);
    if (st || !rep.ok) return st ? st : -1;
    rd_t r = {(void *)(uintptr_t)rep.tr.data.ptr.buffer, rep.tr.data_size, 0, NULL, 0};
    int32_t ex = -1;
    rd_i32(&r, &ex);
    free_buffer(ctx, rep.tr.data.ptr.buffer);
    return ex;
}

// Services that hold One UI state. Never mirrored in either direction.
static const char *DENY[] = {
    "manager",
    "android.hardware.weaver.",
    "android.hardware.authsecret.",
    "android.system.keystore2.",
    "android.security.",
    "android.service.gatekeeper.",
    "vold",
    "credstore",
    "gsiservice",
    "lock_settings",
    NULL,
};
static int denied(const char *name) {
    for (int i = 0; DENY[i]; i++) {
        size_t n = strlen(DENY[i]);
        if (DENY[i][n - 1] == '.' ? !strncmp(name, DENY[i], n) : !strcmp(name, DENY[i])) return 1;
    }
    return 0;
}

static struct { const char *name; const char *iface; } STUBS[] = {
    {"android.hardware.weaver.IWeaver/default", "android.hardware.weaver.IWeaver"},
    {"android.hardware.authsecret.IAuthSecret/default", "android.hardware.authsecret.IAuthSecret"},
};

typedef struct { names_t names; uint32_t *handles; } mirror_t;
static mirror_t g_to_guest;  // names we put in the guest registry, with host handles
static names_t g_to_host;    // names we put in the host registry
static names_t g_guest_owned; // names the guest took over from us
static names_t g_failed;      // names a registry refused; not retried
static names_t g_lazy;        // on-demand host services (from init .rc files)

static void mirror_set(mirror_t *m, const char *name, uint32_t h) {
    for (size_t i = 0; i < m->names.n; i++)
        if (!strcmp(m->names.v[i], name)) { m->handles[i] = h; return; }
    names_add(&m->names, name);
    m->handles = realloc(m->handles, m->names.n * sizeof *m->handles);
    m->handles[m->names.n - 1] = h;
}
static int mirror_get(mirror_t *m, const char *name, uint32_t *h) {
    for (size_t i = 0; i < m->names.n; i++)
        if (!strcmp(m->names.v[i], name)) { *h = m->handles[i]; return 1; }
    return 0;
}

static void sync_once(int initial) {
    names_t hn = {0}, gn = {0};
    if (sm_list(HOST, &hn) || sm_list(GUEST, &gn)) {
        LOG("sync: could not list services");
        names_free(&hn);
        names_free(&gn);
        return;
    }
    int added = 0;
    // host -> guest
    for (size_t i = 0; i < hn.n; i++) {
        const char *n = hn.v[i];
        if (denied(n) || names_has(&g_to_host, n) || names_has(&g_guest_owned, n) || names_has(&g_failed, n)) continue;
        uint32_t prev;
        int mirrored = mirror_get(&g_to_guest, n, &prev);
        if (!mirrored && names_has(&gn, n)) continue;  // the guest provides its own
        int kind;
        uint32_t h = 0;
        node_t *own = NULL;
        int32_t stab = 0;
        if (sm_check(HOST, n, &kind, &h, &own, &stab) || kind != 1) {
            VLOG("host->guest %s: host lookup gave kind %d, skipped", n, kind);
            continue;
        }
        // Still mirrored and still present in the guest registry: nothing to do.
        // (If it vanished from the guest registry, add it again.)
        if (mirrored && prev == h && names_has(&gn, n)) continue;
        if (mirrored && prev == h) LOG("host->guest %s: missing from guest registry, re-adding", n);
        if (mirrored) {
            // Host service restarted. Re-point the guest name, unless the
            // guest registered its own under it meanwhile.
            int gk;
            uint32_t gh;
            node_t *gown = NULL;
            int32_t gs;
            if (!sm_check(GUEST, n, &gk, &gh, &gown, &gs) && gk == 1) {
                names_add(&g_guest_owned, n);
                continue;
            }
        }
        node_t *nd = get_node(HOST, h);
        int ex = sm_add(GUEST, n, nd, stab);
        if (ex == 0) {
            mirror_set(&g_to_guest, n, h);
            added++;
            VLOG("host->guest %s (stability 0x%x)", n, stab);
        } else {
            LOG("host->guest %s: addService failed (%d), not retrying", n, ex);
            names_add(&g_failed, n);
        }
    }
    // On-demand host services that are not running right now: give the guest
    // a placeholder that starts the real one on first use.
    for (size_t i = 0; i < g_lazy.n; i++) {
        const char *n = g_lazy.v[i];
        uint32_t tmp;
        if (denied(n) || names_has(&hn, n) || names_has(&gn, n) || mirror_get(&g_to_guest, n, &tmp) ||
            names_has(&g_failed, n) || names_has(&g_guest_owned, n))
            continue;
        node_t *nd = calloc(1, sizeof *nd);
        nd->ctx = HOST;
        nd->lazy = strdup(n);
        pthread_mutex_lock(&g_nodes_lock);
        if (g_nnodes == g_capnodes) {
            g_capnodes = g_capnodes ? g_capnodes * 2 : 256;
            g_nodes = realloc(g_nodes, g_capnodes * sizeof *g_nodes);
        }
        g_nodes[g_nnodes++] = nd;
        pthread_mutex_unlock(&g_nodes_lock);
        int ex = sm_add(GUEST, n, nd, strchr(n, '/') ? STAB_VINTF : 0x0c);
        if (ex == 0) {
            mirror_set(&g_to_guest, n, 0xffffffffu);
            added++;
            VLOG("host->guest %s (on demand)", n);
        } else {
            names_add(&g_failed, n);
            VLOG("host->guest %s (on demand): addService failed (%d)", n, ex);
        }
    }
    // guest -> host (Lineage's framework services, needed by host daemons
    // such as audioserver, cameraserver and imsd)
    for (size_t i = 0; i < gn.n; i++) {
        const char *n = gn.v[i];
        uint32_t tmp;
        if (denied(n) || mirror_get(&g_to_guest, n, &tmp) || names_has(&g_to_host, n) || names_has(&g_failed, n)) continue;
        if (names_has(&hn, n)) continue;
        int kind;
        uint32_t h = 0;
        node_t *own = NULL;
        int32_t stab = 0;
        if (sm_check(GUEST, n, &kind, &h, &own, &stab) || kind != 1) continue;
        node_t *nd = get_node(GUEST, h);
        int ex = sm_add(HOST, n, nd, stab);
        if (ex == 0) {
            names_add(&g_to_host, n);
            added++;
            VLOG("guest->host %s", n);
        } else {
            LOG("guest->host %s: addService failed (%d), not retrying", n, ex);
            names_add(&g_failed, n);
        }
    }
    if (initial || added)
        LOG("sync: host %zu, guest %zu services; mirrored %zu to guest, %zu to host (+%d)", hn.n, gn.n,
            g_to_guest.names.n, g_to_host.n, added);
    names_free(&hn);
    names_free(&gn);
}

static int open_ctx(int ctx, const char *path) {
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) { LOG("open %s: %s", path, strerror(errno)); return -1; }
    struct binder_version v = {0};
    if (ioctl(fd, BINDER_VERSION, &v) || v.protocol_version != BINDER_CURRENT_PROTOCOL_VERSION) {
        LOG("%s: bad binder version", path);
        return -1;
    }
    if (mmap(NULL, VM_SIZE, PROT_READ, MAP_PRIVATE | MAP_NORESERVE, fd, 0) == MAP_FAILED) {
        LOG("mmap %s: %s", path, strerror(errno));
        return -1;
    }
    uint32_t maxt = 15;
    ioctl(fd, BINDER_SET_MAX_THREADS, &maxt);
    g_fd[ctx] = fd;
    LOG("%s context: %s", CTX_NAME[ctx], path);
    return 0;
}

static int wait_for_sm(int ctx, int seconds) {
    for (int i = 0; i < seconds * 10; i++) {
        if (transact(ctx, 0, PING_TRANSACTION, 0, NULL, NULL) == 0) return 0;
        usleep(100000);
    }
    return -1;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <host binder dev> <guest binder dev> <ready file> [-v]\n", argv[0]);
        return 2;
    }
    for (int a = 4; a < argc; a++) {
        if (!strcmp(argv[a], "-v")) {
            g_verbose = 1;
        } else {
            // File with one on-demand host service name per line.
            FILE *lf = fopen(argv[a], "r");
            char line[512];
            while (lf && fgets(line, sizeof line, lf)) {
                line[strcspn(line, "\r\n")] = 0;
                if (line[0]) names_add(&g_lazy, line);
            }
            if (lf) fclose(lf);
            LOG("%zu on-demand host services listed", g_lazy.n);
        }
    }
    signal(SIGPIPE, SIG_IGN);
    // Lineage's system_server watchdog asks debuggerd for backtraces of the
    // HAL processes it talks to - through the bridge, that is us. A static
    // binary has no debuggerd handler, so its signal (BIONIC_SIGNAL_DEBUGGER,
    // SIGRTMIN+3) would silently kill the bridge and every mirrored service.
    signal(__SIGRTMIN + 3, SIG_IGN);
    signal(SIGQUIT, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
    if (open_ctx(HOST, argv[1]) || open_ctx(GUEST, argv[2])) return 1;
    if (wait_for_sm(HOST, 5)) { LOG("host servicemanager not reachable"); return 1; }
    LOG("waiting for the guest servicemanager...");
    if (wait_for_sm(GUEST, 60)) { LOG("guest servicemanager did not start"); return 1; }
    for (int c = 0; c < 2; c++) {
        spawn_looper(c, 1);
        spawn_looper(c, 0);
    }
    g_cb_node = make_stub("android.os.IServiceCallback");
    g_cb_node->stub = NULL;
    g_cb_node->callback = 1;
    for (size_t i = 0; i < sizeof STUBS / sizeof *STUBS; i++) {
        int ex = sm_add(GUEST, STUBS[i].name, make_stub(STUBS[i].iface), STAB_VINTF);
        // Fails when the device does not declare the HAL; then the guest
        // never waits for it and no stub is needed.
        LOG("guest stub %s: %s", STUBS[i].name, ex == 0 ? "registered" : "not declared on this device, skipped");
        names_add(&g_guest_owned, STUBS[i].name);
    }
    sync_once(1);
    FILE *f = fopen(argv[3], "w");
    if (f) { fputs("ready\n", f); fclose(f); }
    LOG("READY");
    for (;;) {
        sleep(2);
        sync_once(0);
    }
}
