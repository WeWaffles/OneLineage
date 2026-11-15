// Software gatekeeper for the guest (included by ol_bridge.c).
//
// The guest must never reach the host's TEE gatekeeper: it holds One UI's
// own lock screen enrollment for user 0, and the guest's gatekeeperd calls
// deleteAllUsers() on its first enroll/verify after a cold boot. So the
// bridge serves android.hardware.gatekeeper.IGatekeeper/default to the guest
// itself:
//   - password handles use AOSP's password_handle_t layout (gatekeeperd reads
//     the secure user id and hardware_backed flag out of it), signed with
//     HMAC-SHA256 under a random key kept in the guest's /data;
//   - no throttling (timeoutMs is always 0);
//   - verify returns an auth token whose MAC is not the TEE's, so keys that
//     need user authentication in KeyMint will not unlock. The lock screen
//     and credential-encrypted storage do not need that.

#define GK_KEY_FILE "/data/misc/gatekeeper/ol_softgk.key"
#define GK_IFACE "android.hardware.gatekeeper.IGatekeeper"
#define GK_DELETE_ALL 1
#define GK_DELETE_USER 2
#define GK_ENROLL 3
#define GK_VERIFY 4
#define GK_GET_VERSION 0x00fffffe
#define GK_GET_HASH 0x00fffffd
#define GK_STATUS_OK 0
#define GK_ERROR_GENERAL_FAILURE (-1)

// ---- SHA-256 / HMAC (FIPS 180-4) ----
typedef struct { uint32_t h[8]; uint64_t n; uint8_t b[64]; size_t bl; } sha256_t;
static const uint32_t SHA_K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
static void sha_block(sha256_t *s, const uint8_t *p) {
    uint32_t w[64], a, b, c, d, e, f, g, h;
    for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[4 * i] << 24 | p[4 * i + 1] << 16 | p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3]; e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + SHA_K[i] + w[i];
        uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}
static void sha_init(sha256_t *s) {
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(s->h, iv, sizeof iv);
    s->n = 0;
    s->bl = 0;
}
static void sha_update(sha256_t *s, const void *data, size_t len) {
    const uint8_t *p = data;
    s->n += len;
    while (len--) {
        s->b[s->bl++] = *p++;
        if (s->bl == 64) { sha_block(s, s->b); s->bl = 0; }
    }
}
static void sha_final(sha256_t *s, uint8_t out[32]) {
    uint64_t bits = s->n * 8;
    uint8_t pad = 0x80, z = 0;
    sha_update(s, &pad, 1);
    while (s->bl != 56) sha_update(s, &z, 1);
    for (int i = 7; i >= 0; i--) { uint8_t c = (uint8_t)(bits >> (8 * i)); sha_update(s, &c, 1); }
    for (int i = 0; i < 8; i++) {
        out[4 * i] = s->h[i] >> 24; out[4 * i + 1] = s->h[i] >> 16; out[4 * i + 2] = s->h[i] >> 8; out[4 * i + 3] = s->h[i];
    }
}
// HMAC-SHA256 over the concatenation of up to 4 parts.
static void hmac256(const uint8_t key[32], const void *p1, size_t l1, const void *p2, size_t l2,
                    const void *p3, size_t l3, const void *p4, size_t l4, uint8_t out[32]) {
    uint8_t k[64] = {0}, ipad[64], opad[64], inner[32];
    memcpy(k, key, 32);
    for (int i = 0; i < 64; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
    sha256_t s;
    sha_init(&s);
    sha_update(&s, ipad, 64);
    if (l1) sha_update(&s, p1, l1);
    if (l2) sha_update(&s, p2, l2);
    if (l3) sha_update(&s, p3, l3);
    if (l4) sha_update(&s, p4, l4);
    sha_final(&s, inner);
    sha_init(&s);
    sha_update(&s, opad, 64);
    sha_update(&s, inner, 32);
    sha_final(&s, out);
}

// ---- state ----
static pthread_mutex_t g_gk_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t g_gk_key[32];
static int g_gk_have_key;

static int gk_random(void *buf, size_t n) {
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, (uint8_t *)buf + got, n - got);
        if (r <= 0) { close(fd); return -1; }
        got += (size_t)r;
    }
    close(fd);
    return 0;
}
// Loads (or creates once) the signing key. Never replaced: a new key would
// invalidate every enrolled handle and lock the guest user out.
static int gk_key(void) {
    if (g_gk_have_key) return 0;
    int fd = open(GK_KEY_FILE, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t r = read(fd, g_gk_key, 32);
        close(fd);
        if (r == 32) { g_gk_have_key = 1; return 0; }
        LOG("softgk: %s is damaged; refusing to replace it", GK_KEY_FILE);
        return -1;
    }
    if (gk_random(g_gk_key, 32)) return -1;
    fd = open(GK_KEY_FILE ".tmp", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0 || write(fd, g_gk_key, 32) != 32 || fsync(fd)) {
        if (fd >= 0) close(fd);
        LOG("softgk: cannot write %s (errno %d)", GK_KEY_FILE, errno);
        return -1;
    }
    close(fd);
    if (rename(GK_KEY_FILE ".tmp", GK_KEY_FILE)) return -1;
    LOG("softgk: created a new signing key");
    g_gk_have_key = 1;
    return 0;
}

// AOSP gatekeeper password_handle_t (version 2).
typedef struct __attribute__((packed)) {
    uint8_t version;
    uint64_t user_id;  // secure user id
    uint64_t flags;
    uint64_t salt;
    uint8_t signature[32];
    uint8_t hardware_backed;
} gk_handle_t;

static void gk_sign(gk_handle_t *h, const uint8_t *pw, size_t pwlen) {
    // Covers everything before the signature, then the password.
    hmac256(g_gk_key, h, offsetof(gk_handle_t, signature), pw, pwlen, NULL, 0, NULL, 0, h->signature);
}
static int gk_check(const uint8_t *hd, size_t hlen, const uint8_t *pw, size_t pwlen, gk_handle_t *out) {
    if (hlen != sizeof(gk_handle_t)) return 0;
    gk_handle_t h;
    memcpy(&h, hd, sizeof h);
    if (h.version != 2) return 0;
    uint8_t want[32];
    hmac256(g_gk_key, &h, offsetof(gk_handle_t, signature), pw, pwlen, NULL, 0, NULL, 0, want);
    uint8_t diff = 0;
    for (int i = 0; i < 32; i++) diff |= want[i] ^ h.signature[i];
    if (out) *out = h;
    return diff == 0;
}

// ---- parcel io ----
static int rd_i64(rd_t *r, int64_t *v) {
    if (r->pos + 8 > r->len) return -1;
    memcpy(v, r->data + r->pos, 8);
    r->pos += 8;
    return 0;
}
// byte[]: length (-1 = null), bytes padded to 4. *out points into the parcel.
static int rd_bytes(rd_t *r, const uint8_t **out, size_t *len) {
    int32_t n;
    if (rd_i32(r, &n)) return -1;
    if (n < 0) { *out = NULL; *len = 0; return 0; }
    size_t padded = ((size_t)n + 3) & ~(size_t)3;
    if (r->pos + padded > r->len) return -1;
    *out = r->data + r->pos;
    *len = (size_t)n;
    r->pos += padded;
    return 0;
}
static void pb_i64(pbuf_t *p, int64_t v) {
    pb_reserve(p, 8);
    memcpy(p->data + p->len, &v, 8);
    p->len += 8;
}
static void pb_bytes(pbuf_t *p, const void *b, size_t n) {
    pb_i32(p, (int32_t)n);
    size_t padded = (n + 3) & ~(size_t)3;
    pb_reserve(p, padded);
    memset(p->data + p->len, 0, padded);
    if (n) memcpy(p->data + p->len, b, n);
    p->len += padded;
}
// Stable AIDL parcelable: non-null marker, then a size-prefixed body.
static size_t pb_parcelable_begin(pbuf_t *p) {
    pb_i32(p, 1);
    size_t at = p->len;
    pb_i32(p, 0);
    return at;
}
static void pb_parcelable_end(pbuf_t *p, size_t at) {
    int32_t sz = (int32_t)(p->len - at);
    memcpy(p->data + at, &sz, 4);
}

static void gk_enroll_reply(pbuf_t *p, int32_t status, int64_t sid, const void *data, size_t dlen) {
    pb_i32(p, 0);  // no exception
    size_t at = pb_parcelable_begin(p);
    pb_i32(p, status);
    pb_i32(p, 0);  // timeoutMs
    pb_i64(p, sid);
    pb_bytes(p, data, dlen);
    pb_parcelable_end(p, at);
}

static void gk_verify_reply(pbuf_t *p, int32_t status, int64_t challenge, int64_t sid) {
    pb_i32(p, 0);
    size_t at = pb_parcelable_begin(p);
    pb_i32(p, status);
    pb_i32(p, 0);  // timeoutMs
    size_t tok = pb_parcelable_begin(p);  // HardwareAuthToken
    int64_t ms = 0;
    uint8_t mac[32] = {0};
    if (status == GK_STATUS_OK) {
        struct timespec ts;
        clock_gettime(CLOCK_BOOTTIME, &ts);
        ms = (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
        hmac256(g_gk_key, &challenge, 8, &sid, 8, &ms, 8, NULL, 0, mac);
    }
    pb_i64(p, challenge);
    pb_i64(p, sid);       // userId
    pb_i64(p, 0);         // authenticatorId
    pb_i32(p, 1);         // HardwareAuthenticatorType.PASSWORD
    size_t t = pb_parcelable_begin(p);  // Timestamp
    pb_i64(p, ms);
    pb_parcelable_end(p, t);
    pb_bytes(p, mac, status == GK_STATUS_OK ? 32 : 0);
    pb_parcelable_end(p, tok);
    pb_parcelable_end(p, at);
}

// Handles one IGatekeeper call. Returns 0 if `out` holds the reply, or a
// binder status code to send instead.
static int32_t softgk_call(struct binder_transaction_data *tr, pbuf_t *out) {
    rd_t r = {(void *)(uintptr_t)tr->data.ptr.buffer, tr->data_size, 0, NULL, 0};
    int32_t skip, uid;
    char desc[96];
    if (tr->code == GK_GET_VERSION) { pb_i32(out, 0); pb_i32(out, 1); return 0; }
    if (tr->code == GK_GET_HASH) { pb_i32(out, 0); pb_str16(out, "notfrozen"); return 0; }
    if (rd_i32(&r, &skip) || rd_i32(&r, &skip) || rd_i32(&r, &skip) || rd_str16(&r, desc, sizeof desc) ||
        strcmp(desc, GK_IFACE))
        return ST_FAILED_TRANSACTION;
    pthread_mutex_lock(&g_gk_lock);
    int32_t ret = 0;
    if (tr->code == GK_DELETE_ALL || tr->code == GK_DELETE_USER) {
        // Handles live in gatekeeperd's files; nothing is stored here.
        LOG("softgk: %s", tr->code == GK_DELETE_ALL ? "deleteAllUsers" : "deleteUser");
        pb_i32(out, 0);
    } else if (tr->code == GK_ENROLL) {
        const uint8_t *cur_h, *cur_pw, *pw;
        size_t cur_hl, cur_pwl, pwl;
        if (rd_i32(&r, &uid) || rd_bytes(&r, &cur_h, &cur_hl) || rd_bytes(&r, &cur_pw, &cur_pwl) ||
            rd_bytes(&r, &pw, &pwl) || !pw) {
            ret = ST_FAILED_TRANSACTION;
        } else if (gk_key()) {
            gk_enroll_reply(out, GK_ERROR_GENERAL_FAILURE, 0, NULL, 0);
        } else {
            gk_handle_t h, old;
            memset(&h, 0, sizeof h);
            h.version = 2;
            h.hardware_backed = 1;
            int ok = 1;
            if (cur_h && cur_hl) {
                // Changing a password keeps the secure user id, but only with
                // the right current password.
                if (gk_check(cur_h, cur_hl, cur_pw, cur_pwl, &old)) h.user_id = old.user_id;
                else ok = 0;
            }
            if (ok && !h.user_id) {
                while (!h.user_id) if (gk_random(&h.user_id, 8)) { ok = 0; break; }
            }
            if (ok && gk_random(&h.salt, 8)) ok = 0;
            if (ok) {
                gk_sign(&h, pw, pwl);
                gk_enroll_reply(out, GK_STATUS_OK, (int64_t)h.user_id, &h, sizeof h);
            } else {
                gk_enroll_reply(out, GK_ERROR_GENERAL_FAILURE, 0, NULL, 0);
            }
            LOG("softgk: enroll uid %d -> %s", uid, ok ? "ok" : "failed");
        }
    } else if (tr->code == GK_VERIFY) {
        int64_t challenge;
        const uint8_t *hd, *pw;
        size_t hl, pwl;
        if (rd_i32(&r, &uid) || rd_i64(&r, &challenge) || rd_bytes(&r, &hd, &hl) || rd_bytes(&r, &pw, &pwl)) {
            ret = ST_FAILED_TRANSACTION;
        } else {
            gk_handle_t h;
            int ok = !gk_key() && gk_check(hd, hl, pw, pwl, &h);
            gk_verify_reply(out, ok ? GK_STATUS_OK : GK_ERROR_GENERAL_FAILURE, challenge, ok ? (int64_t)h.user_id : 0);
            LOG("softgk: verify uid %d -> %s", uid, ok ? "ok" : "wrong");
        }
    } else {
        ret = ST_UNKNOWN_TRANSACTION;
    }
    pthread_mutex_unlock(&g_gk_lock);
    return ret;
}
