package com.onelineage.payload;

import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Pulls partition images out of an A/B full OTA zip (payload.bin) without
 * downloading the whole zip: the zip is read with HTTP range requests (or from
 * a local file), only the wanted partitions' data is fetched, decompressed and
 * written at the right offsets, then each image is checked against the SHA-256
 * in the payload manifest.
 *
 *   CLASSPATH=ol_payload.dex app_process /system/bin com.onelineage.payload.Extract \
 *       <url-or-path> <outdir> <7zz> <partition:outfile>...
 *
 * Only REPLACE, REPLACE_BZ, REPLACE_XZ, ZERO and DISCARD operations are
 * handled (that is all a full OTA has). xz and bzip2 streams are piped
 * through the 7zz binary the app already ships, so no codec lives here.
 *
 * Output is line based for the app: "OLP|STAGE|text", "OLP|PROG|done|total"
 * (bytes of image written), "OLP|DONE" or "OLP|ERROR|text". A finished
 * image gets a "<outfile>.ok" marker, and is skipped on the next run.
 */
public final class Extract {
    // The mirror caps each connection at roughly 100-200 KB/s, so windows are fetched
    // by many workers at once (each worker then decodes its own window).
    private static final int WINDOW_MAX = 8 << 20;
    private static final int WINDOW_GAP = 1 << 20;
    private static final int WORKERS = 16;

    private interface Source {
        long size();
        void read(long off, byte[] dst, int dstOff, int len) throws IOException;
    }

    private static final class FileSource implements Source {
        private final RandomAccessFile f;
        FileSource(String path) throws IOException { f = new RandomAccessFile(path, "r"); }
        public long size() { try { return f.length(); } catch (IOException e) { return -1; } }
        public synchronized void read(long off, byte[] dst, int dstOff, int len) throws IOException {
            f.seek(off);
            f.readFully(dst, dstOff, len);
        }
    }

    private static final class HttpSource implements Source {
        private final String orig;
        private volatile String cur;
        private long size;

        HttpSource(String url) throws IOException {
            orig = url;
            resolve();
        }

        public long size() { return size; }

        private HttpURLConnection open(String url, long from, long to) throws IOException {
            HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
            c.setInstanceFollowRedirects(true);
            c.setConnectTimeout(20000);
            c.setReadTimeout(60000);
            c.setRequestProperty("User-Agent", "OnePixel");
            c.setRequestProperty("Range", "bytes=" + from + "-" + to);
            return c;
        }

        // Follows the redirect chain once; ranged reads then go straight to the mirror.
        private void resolve() throws IOException {
            HttpURLConnection c = open(orig, 0, 0);
            try {
                int code = c.getResponseCode();
                if (code != 206) throw new IOException("server does not support range requests (HTTP " + code + ")");
                String cr = c.getHeaderField("Content-Range");
                size = Long.parseLong(cr.substring(cr.lastIndexOf('/') + 1).trim());
                cur = c.getURL().toString();
            } finally {
                c.disconnect();
            }
        }

        public void read(long off, byte[] dst, int dstOff, int len) throws IOException {
            IOException last = null;
            for (int attempt = 1; attempt <= 8; attempt++) {
                HttpURLConnection c = null;
                try {
                    c = open(cur, off, off + len - 1);
                    int code = c.getResponseCode();
                    if (code != 206) throw new IOException("HTTP " + code);
                    DataInputStream in = new DataInputStream(c.getInputStream());
                    in.readFully(dst, dstOff, len);
                    return;
                } catch (IOException e) {
                    last = e;
                    System.out.println("OLP|STAGE|network hiccup (" + e.getMessage() + "), retry " + attempt);
                    try { Thread.sleep(1500L * attempt); } catch (InterruptedException ie) { throw new IOException(ie); }
                    if (attempt >= 2) {
                        try { resolve(); } catch (IOException ignored) {}
                    }
                } finally {
                    if (c != null) c.disconnect();
                }
            }
            throw last;
        }
    }

    // ---- protobuf bits (just what the payload manifest needs) ----

    private static final class Pb {
        final byte[] b;
        int p;
        final int end;
        Pb(byte[] b, int start, int end) { this.b = b; this.p = start; this.end = end; }
        boolean more() { return p < end; }
        long varint() {
            long r = 0;
            int s = 0;
            while (true) {
                int c = b[p++] & 0xff;
                r |= (long) (c & 0x7f) << s;
                if (c < 0x80) return r;
                s += 7;
            }
        }
        // Skips an unwanted field's value; returns nothing.
        void skip(int wt) {
            if (wt == 0) varint();
            else if (wt == 1) p += 8;
            else if (wt == 2) { int l = (int) varint(); p += l; }
            else if (wt == 5) p += 4;
            else throw new IllegalStateException("bad wire type " + wt);
        }
    }

    private static final class Op {
        int type;
        long dataOff, dataLen;
        final List<long[]> dst = new ArrayList<>(); // {startBlock, numBlocks}
        long blocks() { long n = 0; for (long[] e : dst) n += e[1]; return n; }
    }

    private static final class Part {
        String name;
        long size;
        byte[] sha;
        final List<Op> ops = new ArrayList<>();
    }

    private static Part parsePartition(byte[] m, int s, int e) {
        Part part = new Part();
        Pb r = new Pb(m, s, e);
        while (r.more()) {
            int t = (int) r.varint();
            int fn = t >>> 3, wt = t & 7;
            if (fn == 1 && wt == 2) {
                int l = (int) r.varint();
                part.name = new String(m, r.p, l);
                r.p += l;
            } else if (fn == 7 && wt == 2) {
                int l = (int) r.varint();
                Pb q = new Pb(m, r.p, r.p + l);
                r.p += l;
                while (q.more()) {
                    int t2 = (int) q.varint();
                    int f2 = t2 >>> 3, w2 = t2 & 7;
                    if (f2 == 1 && w2 == 0) part.size = q.varint();
                    else if (f2 == 2 && w2 == 2) {
                        int hl = (int) q.varint();
                        part.sha = Arrays.copyOfRange(m, q.p, q.p + hl);
                        q.p += hl;
                    } else q.skip(w2);
                }
            } else if (fn == 8 && wt == 2) {
                int l = (int) r.varint();
                part.ops.add(parseOp(m, r.p, r.p + l));
                r.p += l;
            } else r.skip(wt);
        }
        return part;
    }

    private static Op parseOp(byte[] m, int s, int e) {
        Op op = new Op();
        Pb r = new Pb(m, s, e);
        while (r.more()) {
            int t = (int) r.varint();
            int fn = t >>> 3, wt = t & 7;
            if (fn == 1 && wt == 0) op.type = (int) r.varint();
            else if (fn == 2 && wt == 0) op.dataOff = r.varint();
            else if (fn == 3 && wt == 0) op.dataLen = r.varint();
            else if (fn == 6 && wt == 2) {
                int l = (int) r.varint();
                Pb q = new Pb(m, r.p, r.p + l);
                r.p += l;
                long start = 0, num = 0;
                while (q.more()) {
                    int t2 = (int) q.varint();
                    int f2 = t2 >>> 3, w2 = t2 & 7;
                    if (f2 == 1 && w2 == 0) start = q.varint();
                    else if (f2 == 2 && w2 == 0) num = q.varint();
                    else q.skip(w2);
                }
                op.dst.add(new long[]{start, num});
            } else r.skip(wt);
        }
        return op;
    }

    // ---- zip ----

    private static int u16(byte[] b, int o) { return (b[o] & 0xff) | ((b[o + 1] & 0xff) << 8); }
    private static long u32(byte[] b, int o) { return (u16(b, o) | ((long) u16(b, o + 2) << 16)) & 0xffffffffL; }

    private static void readFully(Source s, long off, byte[] dst) throws IOException {
        s.read(off, dst, 0, dst.length);
    }

    /** Returns {dataOffset, size} of the stored payload.bin entry. */
    private static long[] findPayload(Source src) throws IOException {
        long total = src.size();
        int tailLen = (int) Math.min(total, 70000);
        byte[] tail = new byte[tailLen];
        readFully(src, total - tailLen, tail);
        int eocd = -1;
        for (int i = tailLen - 22; i >= 0; i--) {
            if (u32(tail, i) == 0x06054b50L) { eocd = i; break; }
        }
        if (eocd < 0) throw new IOException("not a zip file");
        long cdSize = u32(tail, eocd + 12), cdOff = u32(tail, eocd + 16);
        if (cdOff == 0xffffffffL || cdSize == 0xffffffffL) throw new IOException("zip64 zips are not supported");
        byte[] cd = new byte[(int) cdSize];
        readFully(src, cdOff, cd);
        int p = 0;
        while (p + 46 <= cd.length && u32(cd, p) == 0x02014b50L) {
            int method = u16(cd, p + 10);
            long csize = u32(cd, p + 20), usize = u32(cd, p + 24);
            int nl = u16(cd, p + 28), el = u16(cd, p + 30), cl = u16(cd, p + 32);
            long lo = u32(cd, p + 42);
            String name = new String(cd, p + 46, nl);
            if (name.equals("payload.bin")) {
                if (method != 0 || csize != usize) throw new IOException("payload.bin is compressed in the zip");
                byte[] lh = new byte[30];
                readFully(src, lo, lh);
                if (u32(lh, 0) != 0x04034b50L) throw new IOException("bad zip local header");
                return new long[]{lo + 30 + u16(lh, 26) + u16(lh, 28), usize};
            }
            p += 46 + nl + el + cl;
        }
        throw new IOException("payload.bin not found in the zip");
    }

    // ---- extraction ----

    private static String sevenZip;

    private static byte[] decode(String fmt, byte[] src, int off, int len, long expected) throws Exception {
        ProcessBuilder pb = new ProcessBuilder(sevenZip, "e", "-t" + fmt, "-si", "-so",
                "-bso0", "-bsp0", "-bse0", "-mmt=1");
        pb.redirectError(ProcessBuilder.Redirect.to(new File("/dev/null")));
        final Process p = pb.start();
        Thread feeder = new Thread(() -> {
            try (OutputStream o = p.getOutputStream()) {
                o.write(src, off, len);
            } catch (IOException ignored) {}
        });
        feeder.start();
        ByteArrayOutputStream bos = new ByteArrayOutputStream((int) Math.min(expected, 1 << 28));
        byte[] buf = new byte[1 << 16];
        try (InputStream in = p.getInputStream()) {
            int n;
            while ((n = in.read(buf)) > 0) bos.write(buf, 0, n);
        }
        int rc = p.waitFor();
        feeder.join();
        if (rc != 0) throw new IOException("7zz failed (" + fmt + ", rc=" + rc + ")");
        return bos.toByteArray();
    }

    private static final class Window {
        long start, end;
        final List<Op> ops = new ArrayList<>();
    }

    private static List<Window> windows(List<Op> ops) {
        List<Op> sorted = new ArrayList<>();
        for (Op o : ops) if (o.type == 0 || o.type == 1 || o.type == 8) sorted.add(o);
        Collections.sort(sorted, new Comparator<Op>() {
            public int compare(Op a, Op b) { return Long.compare(a.dataOff, b.dataOff); }
        });
        List<Window> out = new ArrayList<>();
        Window w = null;
        for (Op o : sorted) {
            long oEnd = o.dataOff + o.dataLen;
            if (w == null || o.dataOff > w.end + WINDOW_GAP || oEnd - w.start > WINDOW_MAX) {
                w = new Window();
                w.start = o.dataOff;
                w.end = oEnd;
                out.add(w);
            }
            w.end = Math.max(w.end, oEnd);
            w.ops.add(o);
        }
        return out;
    }

    private static void writeExtents(FileChannel ch, Op op, byte[] data, int blockSize) throws IOException {
        int pos = 0;
        for (long[] e : op.dst) {
            long bytes = e[1] * blockSize;
            ByteBuffer bb = ByteBuffer.wrap(data, pos, (int) bytes);
            long at = e[0] * blockSize;
            while (bb.hasRemaining()) at += ch.write(bb, at);
            pos += (int) bytes;
        }
    }

    private static void extractPartition(final Source src, final long base, final Part part, File out,
                                         final int blockSize, final AtomicLong done, final long grandTotal) throws Exception {
        final File tmp = new File(out.getPath() + ".part");
        tmp.delete();
        try (RandomAccessFile raf = new RandomAccessFile(tmp, "rw")) {
            raf.setLength(part.size);
            final FileChannel ch = raf.getChannel();
            final AtomicReference<Throwable> fail = new AtomicReference<>();
            final AtomicLong lastPrint = new AtomicLong();
            ExecutorService pool = Executors.newFixedThreadPool(WORKERS);
            // zero/discard ops need no write (the file starts out sparse and zeroed).
            for (Op o : part.ops) if (o.type == 6 || o.type == 7) done.addAndGet(o.blocks() * blockSize);
            List<Future<?>> futures = new ArrayList<>();
            try {
                for (final Window w : windows(part.ops)) {
                    futures.add(pool.submit(new Runnable() {
                        public void run() {
                            try {
                                if (fail.get() != null) return;
                                byte[] data = new byte[(int) (w.end - w.start)];
                                src.read(base + w.start, data, 0, data.length);
                                for (Op op : w.ops) {
                                    if (fail.get() != null) return;
                                    int off = (int) (op.dataOff - w.start);
                                    long expected = op.blocks() * blockSize;
                                    byte[] raw;
                                    if (op.type == 0) {
                                        raw = Arrays.copyOfRange(data, off, off + (int) op.dataLen);
                                    } else {
                                        raw = decode(op.type == 8 ? "xz" : "bzip2", data, off, (int) op.dataLen, expected);
                                    }
                                    if (raw.length > expected) throw new IOException("op larger than its extents");
                                    if (raw.length < expected) raw = Arrays.copyOf(raw, (int) expected);
                                    writeExtents(ch, op, raw, blockSize);
                                    done.addAndGet(expected);
                                }
                                long now = System.currentTimeMillis();
                                long last = lastPrint.get();
                                if (now - last > 1000 && lastPrint.compareAndSet(last, now)) {
                                    System.out.println("OLP|PROG|" + done.get() + "|" + grandTotal);
                                }
                            } catch (Throwable t) {
                                fail.compareAndSet(null, t);
                            }
                        }
                    }));
                }
                for (Future<?> f : futures) f.get();
            } finally {
                pool.shutdownNow();
            }
            if (fail.get() != null) throw new IOException("extract " + part.name + ": " + fail.get(), fail.get());
            ch.force(false);
        }
        System.out.println("OLP|STAGE|checking " + part.name);
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        try (RandomAccessFile raf = new RandomAccessFile(tmp, "r")) {
            byte[] buf = new byte[4 << 20];
            int n;
            while ((n = raf.read(buf)) > 0) md.update(buf, 0, n);
        }
        if (part.sha != null && !Arrays.equals(md.digest(), part.sha)) {
            tmp.delete();
            throw new IOException(part.name + ": checksum mismatch");
        }
        out.delete();
        if (!tmp.renameTo(out)) throw new IOException("rename failed for " + out);
        new File(out.getPath() + ".ok").createNewFile();
    }

    private static void run(String[] a) throws Exception {
        if (a.length < 4) {
            System.out.println("usage: Extract <url-or-path> <outdir> <7zz> <partition:outfile>...");
            System.exit(2);
        }
        sevenZip = a[2];
        File outDir = new File(a[1]);
        outDir.mkdirs();
        System.out.println("OLP|STAGE|opening the ROM");
        Source src = a[0].startsWith("http") ? new HttpSource(a[0]) : new FileSource(a[0]);
        long[] pl = findPayload(src);
        long base = pl[0];
        byte[] hdr = new byte[24];
        readFully(src, base, hdr);
        if (hdr[0] != 'C' || hdr[1] != 'r' || hdr[2] != 'A' || hdr[3] != 'U') throw new IOException("bad payload magic");
        long ver = 0, msize = 0;
        for (int i = 0; i < 8; i++) { ver = (ver << 8) | (hdr[4 + i] & 0xff); msize = (msize << 8) | (hdr[12 + i] & 0xff); }
        long sigSize = 0;
        for (int i = 0; i < 4; i++) sigSize = (sigSize << 8) | (hdr[20 + i] & 0xff);
        if (ver != 2) throw new IOException("unsupported payload version " + ver);
        byte[] manifest = new byte[(int) msize];
        readFully(src, base + 24, manifest);
        long dataBase = base + 24 + msize + sigSize;

        int blockSize = 4096;
        List<Part> parts = new ArrayList<>();
        Pb r = new Pb(manifest, 0, manifest.length);
        while (r.more()) {
            int t = (int) r.varint();
            int fn = t >>> 3, wt = t & 7;
            if (fn == 3 && wt == 0) blockSize = (int) r.varint();
            else if (fn == 13 && wt == 2) {
                int l = (int) r.varint();
                parts.add(parsePartition(manifest, r.p, r.p + l));
                r.p += l;
            } else r.skip(wt);
        }

        List<Part> wanted = new ArrayList<>();
        List<File> outs = new ArrayList<>();
        long grand = 0;
        for (int i = 3; i < a.length; i++) {
            String[] kv = a[i].split(":", 2);
            Part found = null;
            for (Part p : parts) if (p.name.equals(kv[0])) found = p;
            if (found == null) throw new IOException("partition " + kv[0] + " is not in this OTA");
            wanted.add(found);
            outs.add(new File(outDir, kv[1]));
            grand += found.size;
        }
        AtomicLong done = new AtomicLong();
        for (int i = 0; i < wanted.size(); i++) {
            Part p = wanted.get(i);
            File out = outs.get(i);
            if (out.exists() && new File(out.getPath() + ".ok").exists() && out.length() >= p.size) {
                System.out.println("OLP|STAGE|" + p.name + " already extracted");
                done.addAndGet(p.size);
                System.out.println("OLP|PROG|" + done.get() + "|" + grand);
                continue;
            }
            System.out.println("OLP|STAGE|extracting " + p.name);
            extractPartition(src, dataBase, p, out, blockSize, done, grand);
            System.out.println("OLP|PROG|" + done.get() + "|" + grand);
        }
        System.out.println("OLP|DONE");
        System.exit(0);
    }

    public static void main(String[] a) {
        try {
            run(a);
        } catch (Throwable t) {
            System.out.println("OLP|ERROR|" + t);
            t.printStackTrace(System.out);
            System.exit(1);
        }
    }
}
