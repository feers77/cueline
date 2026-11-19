/* SPDX-License-Identifier: Apache-2.0
 *
 * tadec: MP3 and FLAC decoding for the touch_audio preview, on MAIN.
 *
 * The deck itself never decodes MP3 on the SH-4 (its DSP does) and its own
 * libFLAC carries global state, so the preview brings its own decoders:
 * dr_mp3 (minimp3 inside) and dr_flac, both public domain / MIT-0. This
 * blob is linked at a fixed address in the code cave (TADEC_BASE, see
 * build.sh) with an entry table first, so main_touchaudio.s calls it as
 *
 *   +0  int  tadec_open(const u16 *wide_path)      0 ok, <0 not MP3/FLAC/AIFF(/M4A)
 *            (+0/+4/+8/+16 are the TchDec client calls q_open / q_seek /
 *             q_read(out, n, live) -> -1 when the ring has nothing now /
 *             q_close; +24 TchDec entry, +28 q_quiet: see "TchDec" below)
 *   +4  int  tadec_seek(u32 col)                     col of 600 strip columns
 *   +8  int  tadec_read(s16 *out, int frames)        stereo s16, source rate
 *   +12 u32  tadec_rate(void)                        Hz
 *   +16 void tadec_close(void)
 *   +20 int  tadec_jpeg(const u8 *jpg, int len, u16 *dst, void *arena)
 *                                                 a JPEG -> 20x20 RGB565 at dst
 *                                                 (the browse rows' artwork);
 *                                                 arena: JPEG_ARENA bytes of
 *                                                 the caller's, 0 ok
 *
 * File access goes through the firmware's wide fopen / fread / fseek
 * thunks; memory comes from a static arena reset on every open. One stream
 * at a time (the preview's).
 */
#include <stddef.h>
#include <stdint.h>

typedef uint32_t u32;
typedef uint16_t u16;
typedef int16_t s16;

#ifndef FW_FOPEN
/* gcc -m4 code runs with FPSCR.PR = 1 (set by the entry stubs in crt.S);
 * the firmware expects PR = SZ = 0, so every call back into it switches. */
static inline u32 fpscr_get(void) { u32 v; __asm__ volatile("sts fpscr,%0" : "=r"(v)); return v; }
static inline void fpscr_set(u32 v) { __asm__ volatile("lds %0,fpscr" : : "r"(v)); }
#define FWCALL(T, e) ({ u32 _f = fpscr_get(); fpscr_set(_f & 0xFFE7FFFF); T _r = (e); fpscr_set(_f); _r; })
#define FW_FOPEN(p)          FWCALL(void *, ((void *(*)(const u16 *))0x082C0D2A)(p))
#define FW_FCLOSE(f)         FWCALL(int, ((int (*)(void *))0x082C0D56)(f))
#define FW_FSEEK(f, o, w)    FWCALL(int, ((int (*)(void *, long, int))0x082C0D3C)(f, o, w))
#define FW_FREAD(b, s, n, f) FWCALL(size_t, ((size_t (*)(void *, size_t, size_t, void *))0x082C0D44)(b, s, n, f))
#define FW_FTELL(f)          FWCALL(long, ((long (*)(void *))0x082C0D34)(f))
#endif

/* ---- freestanding libc bits the decoders need ---------------------------- */
#ifndef ARENA_KB
#define ARENA_KB 448
#endif
#define ARENA_SIZE (ARENA_KB * 1024)
static unsigned char arena[ARENA_SIZE] __attribute__((aligned(16)));
static size_t arena_used;

void *memcpy(void *d, const void *s, size_t n) { unsigned char *a = d; const unsigned char *b = s; while (n--) *a++ = *b++; return d; }
void *memmove(void *d, const void *s, size_t n)
{
	unsigned char *a = d; const unsigned char *b = s;
	if (a < b) while (n--) *a++ = *b++;
	else { a += n; b += n; while (n--) *--a = *--b; }
	return d;
}
void *memset(void *d, int c, size_t n) { unsigned char *a = d; while (n--) *a++ = (unsigned char)c; return d; }
int memcmp(const void *x, const void *y, size_t n) { const unsigned char *a = x, *b = y; for (; n; n--, a++, b++) if (*a != *b) return *a - *b; return 0; }

static void *a_malloc(size_t sz, void *u)
{
	(void)u;
	size_t *p;
	sz = (sz + 15) & ~(size_t)15;
	if (arena_used + sz + 16 > ARENA_SIZE) return 0;
	p = (size_t *)(arena + arena_used);
	*p = sz;
	arena_used += sz + 16;
	return (unsigned char *)p + 16;
}
static void a_free(void *p, void *u) { (void)p; (void)u; }      /* reset per open */
static void *a_realloc(void *p, size_t sz, void *u)
{
	void *q;
	size_t old;
	if (!p) return a_malloc(sz, u);
	old = *(size_t *)((unsigned char *)p - 16);
	if (sz <= old) return p;
	q = a_malloc(sz, u);
	if (q) memcpy(q, p, old);
	return q;
}
#ifdef TADEC_M4A
static void m4a_out_of_memory(void);       /* m4a/m4a.c: unwinds an armed FAAD2 call */
void *malloc(size_t n) { void *p = a_malloc(n, 0); if (!p) m4a_out_of_memory(); return p; }
#else
void *malloc(size_t n) { return a_malloc(n, 0); }
#endif
void *realloc(void *p, size_t n) { return a_realloc(p, n, 0); }
void free(void *p) { (void)p; }
void abort(void) { for (;;) ; }            /* never reached: no asserts, no stdio */

#define DRFLAC_ASSERT(x) ((void)0)
#define DRMP3_ASSERT(x)  ((void)0)
#define DR_FLAC_NO_STDIO
#define DR_FLAC_NO_OGG
#define DR_FLAC_NO_SIMD
#define DR_FLAC_NO_WCHAR
/* V3rc1 (MAIN room): no frame CRC-16 (the per-byte update sat in every bit-cache reload: -8.1 KB code,
 * -3.6 KB packed, and less CPU); the header CRC-8 stays, so a seek still rejects false sync codes */
#define DR_FLAC_NO_CRC
#define DR_FLAC_KEEP_CRC8
#define DR_MP3_NO_STDIO
#define DR_MP3_NO_SIMD
#define DR_MP3_ONLY_MP3
#define DR_FLAC_IMPLEMENTATION
#define DR_MP3_IMPLEMENTATION
#include "dr_flac.h"
#ifdef TADEC_MP3_O2      /* the -Os cap variant (m4a/build.sh OPT=Os): MP3 stays -O2 (-Os = +37 % CPU) */
#pragma GCC push_options
#pragma GCC optimize ("O2")
#endif
#include "dr_mp3.h"
#ifdef TADEC_MP3_O2
#pragma GCC pop_options
#endif

/* ---- the stream -------------------------------------------------------- */
enum { K_NONE, K_MP3, K_FLAC, K_M4A, K_AIFF };
static int kind;
static void *fp;
static long fbase;            /* MP3: byte offset the decoder sees as 0 */
static long fpos, fsize;
static drmp3 mp3;
static drflac *flac;
static u32 rate, chans;
static uint64_t frames_total; /* FLAC; 0 when unknown */
static s16 tmp[2 * 1152 * 2];

/* The firmware's fread returns short over NFS (a LINKed player's media: one
 * NFS READ, 8 KB, per call) while dr_mp3 / dr_flac ask for 64 KB chunks and
 * take anything short as the end of the file: keep reading until the request
 * is filled or a read returns nothing. */
/* While dr_mp3 looks for its first frame (open_mp3_at) it may only read
 * MP3_SCAN_CAP bytes: a file that is not MP3 (an AIFF row, a broken file)
 * used to be scanned byte by byte to its end with MAIN at 100 %
 * (re/PERF_BROWSE_PLAY.md H6). */
#define MP3_SCAN_CAP (64 * 1024)
static long scan_end;          /* 0: no cap */
static u32 io_seeks, io_reads;           /* diagnostics: file calls (TchDec's q_stat) */
static size_t on_read(void *u, void *buf, size_t n)
{
	(void)u;
	size_t got = 0;
	if (scan_end) {
		if (fpos >= scan_end) return 0;
		if ((long)n > scan_end - fpos) n = (size_t)(scan_end - fpos);
	}
	while (got < n) {
		size_t r = FW_FREAD((char *)buf + got, 1, n - got, fp);
		io_reads++;
		if (r == 0) break;
		got += r;
	}
	fpos += (long)got;
	return got;
}
static drmp3_bool32 mp3_seek(void *u, int off, drmp3_seek_origin o)
{
	(void)u;
	long to = o == DRMP3_SEEK_SET ? fbase + off : o == DRMP3_SEEK_CUR ? fpos + off : fsize + off;
	if (FW_FSEEK(fp, to, 0) != 0) return 0;
	fpos = to;
	return 1;
}
static drmp3_bool32 mp3_tell(void *u, drmp3_int64 *c) { (void)u; *c = fpos - fbase; return 1; }
static drflac_bool32 flac_tell(void *u, drflac_int64 *c) { (void)u; *c = fpos; return 1; }
static drflac_bool32 flac_seek(void *u, int off, drflac_seek_origin o)
{
	(void)u;
	long to = o == DRFLAC_SEEK_SET ? off : o == DRFLAC_SEEK_CUR ? fpos + off : fsize + off;
	io_seeks++;
	if (to > fsize) return 0;            /* past the end: dr_flac's binary search bounds by the PCM size */
	if (FW_FSEEK(fp, to, 0) != 0) return 0;
	fpos = to;
	return 1;
}
static const drmp3_allocation_callbacks mp3_alloc = { 0, a_malloc, a_realloc, a_free };
static const drflac_allocation_callbacks flac_alloc = { 0, a_malloc, a_realloc, a_free };

static long file_size(void)
{
	/* fseek(0, SEEK_END) + ftell when the file layer supports it; otherwise
	 * find the size by probing reads from a high-water mark (~30 seek+read
	 * pairs: long enough to be heard as a gap on the first touch). */
	unsigned char b[1];
	long lo = 0, hi = 1L << 30;
	if (FW_FSEEK(fp, 0, 2) == 0) {
		long n = FW_FTELL(fp);
		if (n > 0 && FW_FSEEK(fp, n - 1, 0) == 0 && FW_FREAD(b, 1, 1, fp) == 1
		    && FW_FREAD(b, 1, 1, fp) == 0)
			return n;
	}
	while (lo < hi) {                    /* largest offset with a readable byte */
		long mid = lo + (hi - lo + 1) / 2;
		if (FW_FSEEK(fp, mid - 1, 0) == 0 && FW_FREAD(b, 1, 1, fp) == 1) lo = mid;
		else hi = mid - 1;
	}
	return lo;
}

#ifdef TADEC_M4A
/* M4A (AAC-LC / ALAC): m4a/m4a.c, opt-in build m4a/build.sh (mod tadecm4a) */
static long m4a_io(void *buf, long off, long n)
{
	size_t got = 0;
	if (FW_FSEEK(fp, off, 0) != 0) return -1;
	while (got < (size_t)n) {           /* short reads over NFS: see on_read */
		size_t r = FW_FREAD((char *)buf + got, 1, (size_t)n - got, fp);
		if (r == 0) break;
		got += r;
	}
	return (long)got;
}
static void *m4a_alloc(size_t n) { return a_malloc(n, 0); }
#include "m4a/m4a.c"
/* FAAD2's float code runs with FPU exceptions off and denormals flushed
 * (FPSCR enable bits 7-11 = 0, DN = 1): the firmware's FPSCR is inherited
 * through the entry stubs, and a 0/0, x/0 or a denormal operand in a
 * decoder must not trap. Restored on the way out. */
#define M4A_FPU(T, e) ({ u32 _f = fpscr_get(); fpscr_set((_f & ~0x00000F80u) | 0x00040000u); T _r = (e); fpscr_set(_f); _r; })
#endif

void tadec_close(void)
{
#ifdef TADEC_M4A
	m4a_close();
#endif
	if (fp) FW_FCLOSE(fp);
	fp = 0;
	kind = K_NONE;
	flac = 0;
	arena_used = 0;
}

static int open_mp3_at(long base)
{
	arena_used = 0;
	fbase = base;
	if (FW_FSEEK(fp, base, 0) != 0) return -1;
	fpos = base;
	scan_end = base + MP3_SCAN_CAP;
	if (!drmp3_init(&mp3, on_read, mp3_seek, mp3_tell, 0, 0, &mp3_alloc)) { scan_end = 0; return -1; }
	scan_end = 0;
	return 0;
}

/* ---- AIFF / AIFC (uncompressed): big-endian PCM, as the deck plays ------- */
static long aif_data;          /* file offset of the first sample frame */
static u32 aif_bits, aif_bpf, aif_le;
static u32 be32(const unsigned char *b) { return (u32)b[0] << 24 | (u32)b[1] << 16 | (u32)b[2] << 8 | b[3]; }
static int rd_at(long off, void *b, size_t n)
{
	if (FW_FSEEK(fp, off, 0) != 0) return -1;
	fpos = off;
	return on_read(0, b, n) == n ? 0 : -1;
}
/* 0 ok: COMM + SSND found, rate/chans/frames_total/aif_* set */
static int open_aiff(const unsigned char *h)
{
	unsigned char c[26];
	int aifc = h[8] == 'A' && h[9] == 'I' && h[10] == 'F' && h[11] == 'C';
	long off = 12, end = fsize, form = 8 + (long)be32(h + 4);
	int comm = 0;
	if (form > 12 && form < end) end = form;
	aif_data = 0;
	aif_le = 0;
	for (int i = 0; i < 64 && off + 8 <= end; i++) {
		u32 id, sz;
		if (rd_at(off, c, 8)) return -1;
		id = be32(c); sz = be32(c + 4);
		if (id == 0x434F4D4D) {                         /* COMM */
			if (sz < 18 || rd_at(off + 8, c, sz >= 22 ? 22 : 18)) return -1;
			chans = (u32)c[0] << 8 | c[1];
			frames_total = be32(c + 2);
			aif_bits = (u32)c[6] << 8 | c[7];
			/* 80-bit extended rate: exponent c[8..9], mantissa c[10..] */
			int e = ((c[8] & 0x7F) << 8 | c[9]) - 16383 - 31;
			u32 m = be32(c + 10);
			rate = e <= 0 && e > -32 ? m >> -e : 0;
			if (aifc && sz >= 22) {
				u32 ct = be32(c + 18);
				if (ct == 0x736F7774) aif_le = 1;      /* 'sowt': little-endian */
				else if (ct != 0x4E4F4E45 && ct != 0x74776F73) return -1;  /* 'NONE' / 'twos' */
			}
			comm = 1;
		} else if (id == 0x53534E44) {                  /* SSND: offset, blocksize */
			if (rd_at(off + 8, c, 8)) return -1;
			aif_data = off + 16 + (long)be32(c);
		}
		if (comm && aif_data) break;
		off += 8 + (long)((sz + 1) & ~1u);
	}
	if (!comm || !aif_data || chans < 1 || chans > 8 || !rate) return -1;
	if (aif_bits != 8 && aif_bits != 16 && aif_bits != 24 && aif_bits != 32) return -1;
	aif_bpf = chans * (aif_bits / 8);
	return FW_FSEEK(fp, aif_data, 0) == 0 ? (fpos = aif_data, 0) : -1;
}
static int read_aiff(s16 *out, int frames)
{
	unsigned char *b = (unsigned char *)tmp;
	u32 bps = aif_bits / 8, maxf = sizeof(tmp) / aif_bpf;
	int got = 0;
	while (got < frames) {
		u32 want = (u32)(frames - got) < maxf ? (u32)(frames - got) : maxf;
		size_t n = on_read(0, b, want * aif_bpf) / aif_bpf;
		if (!n) break;
		for (size_t i = 0; i < n; i++) {
			const unsigned char *f = b + i * aif_bpf;
			s16 v[2];
			for (u32 k = 0; k < 2; k++) {
				const unsigned char *x = f + (k < chans ? k : 0) * bps;
				if (bps == 1) v[k] = (s16)((x[0] ^ (aif_le ? 0x80 : 0)) << 8);   /* AIFF 8-bit is signed */
				else v[k] = aif_le ? (s16)(x[bps - 1] << 8 | x[bps - 2]) : (s16)(x[0] << 8 | x[1]);
			}
			out[2 * (got + i)] = v[0]; out[2 * (got + i) + 1] = chans > 1 ? v[1] : v[0];
		}
		got += (int)n;
	}
	return got;
}


int tadec_open(const u16 *wpath)
{
	unsigned char h[10];
	tadec_close();
	fp = FW_FOPEN(wpath);
	if (!fp) return -1;
	fpos = 0;
	if (FW_FREAD(h, 1, 10, fp) != 10) { tadec_close(); return -2; }
	fpos = 10;
	fsize = file_size();
	if (h[0] == 'f' && h[1] == 'L' && h[2] == 'a' && h[3] == 'C') {
		FW_FSEEK(fp, 0, 0); fpos = 0;
		flac = drflac_open(on_read, flac_seek, flac_tell, 0, &flac_alloc);
		if (!flac) { tadec_close(); return -3; }
		flac->_noBruteForceSeek = DRFLAC_TRUE;   /* see tadec_seek */
		kind = K_FLAC;
		rate = flac->sampleRate;
		chans = flac->channels;
		frames_total = flac->totalPCMFrameCount;
		return 0;
	}
#ifdef TADEC_M4A
	if (h[4] == 'f' && h[5] == 't' && h[6] == 'y' && h[7] == 'p') {
		if (M4A_FPU(int, m4a_open(fsize)) != 0) { tadec_close(); return -5; }   /* not MP3 either */
		kind = K_M4A;
		rate = m4.rate;
		chans = 2;
		return 0;
	}
#endif
	if (h[0] == 'F' && h[1] == 'O' && h[2] == 'R' && h[3] == 'M') {
		unsigned char hh[12];
		if (rd_at(0, hh, 12) || open_aiff(hh)) { tadec_close(); return -6; }
		kind = K_AIFF;
		return 0;
	}
	if (h[0] == 'R' && h[1] == 'I' && h[2] == 'F' && h[3] == 'F') { tadec_close(); return -7; }  /* WAV: touch_audio's own */
	/* MP3: skip an ID3v2 tag, then let dr_mp3 find the first frame (capped scan) */
	long base = 0;
	if (h[0] == 'I' && h[1] == 'D' && h[2] == '3')
		base = 10 + ((long)(h[6] & 0x7F) << 21 | (long)(h[7] & 0x7F) << 14 | (long)(h[8] & 0x7F) << 7 | (h[9] & 0x7F));
	if (open_mp3_at(base) != 0) { tadec_close(); return -4; }
	fbase = base;
	kind = K_MP3;
	rate = mp3.sampleRate;
	chans = mp3.channels;
	return 0;
}

int tadec_seek(u32 col)
{
	if (col > 599) col = 599;
	if (kind == K_FLAC) {
		if (!frames_total) return -1;
		/* binary search only (brute force from frame 0 took 10 s in the
		 * emulator: _noBruteForceSeek set at open); where the search misses
		 * (~5 % of the columns of a test file), search 1..4 s earlier and
		 * decode forward to the target */
		uint64_t tg = frames_total * col / 600;
		if (drflac_seek_to_pcm_frame(flac, tg)) return 0;
		for (u32 k = 1; k <= 4; k++) {
			uint64_t back = (uint64_t)rate * k, t = tg > back ? tg - back : 0, left;
			if (!drflac_seek_to_pcm_frame(flac, t)) continue;
			for (left = tg - t; left; ) {
				drflac_uint64 n = drflac_read_pcm_frames_s16(flac, left > 1152 ? 1152 : left, tmp);
				if (!n) return -1;
				left -= n;
			}
			return 0;
		}
		return -1;
	}
#ifdef TADEC_M4A
	if (kind == K_M4A) return M4A_FPU(int, m4a_seek(col));
#endif
	if (kind == K_AIFF) {
		long to = aif_data + (long)(frames_total * col / 600) * (long)aif_bpf;
		if (FW_FSEEK(fp, to, 0) != 0) return -1;
		fpos = to;
		return 0;
	}
	if (kind == K_MP3) {
		/* byte-proportional: restart the decoder at that offset; it resyncs on
		 * the next frame header (the first frame may lack its bit reservoir) */
		long start = fbase + (long)((uint64_t)(fsize - fbase) * col / 600);
		long keep = fbase;
		if (open_mp3_at(start) != 0) return -1;
		fbase = keep;          /* seek-to-start still means the stream start */
		rate = mp3.sampleRate ? mp3.sampleRate : rate;
		return 0;
	}
	return -1;
}

int tadec_read(s16 *out, int frames)
{
	int got = 0;
	if (kind == K_FLAC) {
		while (got < frames) {
			int want = frames - got > 1152 ? 1152 : frames - got;
			drflac_uint64 n = drflac_read_pcm_frames_s16(flac, want, tmp);
			if (!n) break;
			for (drflac_uint64 i = 0; i < n; i++) {
				s16 l = tmp[i * chans], r = chans > 1 ? tmp[i * chans + 1] : l;
				out[2 * (got + i)] = l; out[2 * (got + i) + 1] = r;
			}
			got += (int)n;
		}
	} else if (kind == K_MP3) {
		while (got < frames) {
			int want = frames - got > 1152 ? 1152 : frames - got;
			drmp3_uint64 n = drmp3_read_pcm_frames_s16(&mp3, want, tmp);
			if (!n) break;
			for (drmp3_uint64 i = 0; i < n; i++) {
				s16 l = tmp[i * chans], r = chans > 1 ? tmp[i * chans + 1] : l;
				out[2 * (got + i)] = l; out[2 * (got + i) + 1] = r;
			}
			got += (int)n;
		}
	}
	else if (kind == K_AIFF) got = read_aiff(out, frames);
#ifdef TADEC_M4A
	else if (kind == K_M4A) got = M4A_FPU(int, m4a_read(out, frames));
#endif
	return got;
}

u32 tadec_rate(void) { return rate; }

/* ---- TchDec: the decoder task and its PCM ring (re/TANDA3_REPORT.md #24) --
 * Over NFS (a LINKed player's media) one decoder refill is ~8 sequential
 * 8 KB READs; decoding inline in TchAud's 7 ms packet slot made late packets.
 * So every decoder call runs in a task of its own, "TchDec" (priority 11:
 * below TchAud 9 and the DB tasks 8-10), created by TchAud on its first
 * MP3/FLAC open (TchAud only exists on a normal boot: the update gate is
 * inherited, nothing is spawned in update mode). TchDec keeps a 64 KB ring
 * of s16 stereo frames at the file rate ~200 ms ahead; TchAud takes 336+
 * frames a packet and, when the ring runs dry, holds the last frame and
 * fades (its 10 ms ramps) instead of stalling.
 *
 * The entry table's open/seek/read/close (TchAud, through the stubs on the
 * blob stack) are now the q_* client calls below; the decoder's own
 * tadec_open/seek/read/close run only in TchDec, on TchDec's stack.
 *
 * Commands (TchAud -> TchDec): cmd + arg, then gen++ ; TchDec answers with
 * ack = gen. OPEN and CLOSE wait for the answer (TchAud's open was inline
 * before: same latency); SEEK does not: TchAud plays the old position on
 * until TchDec has PREROLL frames of the new one behind it, then jumps
 * (a dry ring meanwhile: the fade). The ring: head written
 * only by TchDec, tail only by TchAud, aligned 32-bit words on one core.
 *
 * File layer: TchDec reads its file only while q_allow is set (by a SEEK or
 * an OPEN, and by q_read while a finger previews). q_quiet (TchAud, before
 * its own pdb / ANLZ / artwork reads: row_waves) clears it and waits for a
 * read in flight (q_io) to end, so the two tasks never sit in the file layer
 * together. CLOSE is synchronous, so a track change (close_cur, then the
 * lookup) has TchDec idle as well. */
#define FW_MALLOC(n)  FWCALL(void *, ((void *(*)(size_t))0x08344A9C)(n))
#define FW_DLY(ms)    FWCALL(int, ((int (*)(int))0x08518FD4)(ms))
#define FW_ACRE(c)    FWCALL(int, ((int (*)(int, void *))0x085142D8)(0, c))
#define FW_STA(id, a) FWCALL(int, ((int (*)(int, int))0x08514730)(id, a))
#define RING_N   16384u                 /* frames (64 KB), a power of two */
#define RING_HI  10240u                 /* fill to ~213 ms at 48 kHz */
#define PREROLL  1536u                  /* after a seek / an underrun: ~32 ms first */
#ifdef TADEC_M4A                        /* as the blob stack the decoders ran on (crt.S) */
#define DEC_STK  (112 * 1024)           /* FAAD2's PS path ~98 KB */
#else
#define DEC_STK  (48 * 1024)
#endif
#define DEC_PRI  11
enum { Q_OPEN = 1, Q_SEEK, Q_CLOSE };
static volatile u32 q_gen, q_ack, q_cmd, q_arg, q_head, q_tail, q_eof, q_allow, q_io;
static volatile u32 q_cut, q_cutn;      /* TchDec: a seek's new data starts at cut (cutn++) */
static u32 q_cutseen;                   /* TchAud: the last cutn applied */
static volatile int q_res;
static const u16 *volatile q_path;
static u32 *ring;
static int q_state;                     /* 0 no task yet, 1 running, 2 creation failed */
static int q_run;                       /* TchAud: the ring is playing (else: waiting for PREROLL) */
/* diagnostics (TchAud's view): underruns, frames read, commands, worst fill */
volatile u32 q_stat[8];
static struct { u32 atr, exinf; void *task; u32 pri, stksz; void *stk; const char *name; } q_ctsk;
static const char q_name[8] = "TchDec";
void tadec_task_entry(void);            /* crt.S: FPSCR PR=1, then tadec_task */

void tadec_task(void)
{
	for (;;) {
		u32 g = q_gen;
		if (g != q_ack) {
			u32 c = q_cmd, a = q_arg;
			if (g != q_gen) continue;
			q_io = 1;
			if (c == Q_SEEK && !q_allow) {  /* TchAud reads files now: later */
				q_io = 0;
				FW_DLY(2);
				continue;
			}
			q_eof = 0;
			if (c == Q_SEEK) {
				/* no flush: TchAud plays on from the old position while the
				 * new one is decoded behind it (from cut); once PREROLL
				 * frames are there, TchAud's tail jumps to cut -- a cut as
				 * the inline seek made, without its stall */
				u32 cut = q_head, t0 = *(volatile u32 *)0x0B0C5258;
				io_seeks = io_reads = 0;
				if (kind == K_NONE || tadec_seek(a) != 0) q_eof = 1;
				q_stat[4] = *(volatile u32 *)0x0B0C5258 - t0;   /* last seek: ms, fseeks, freads */
				q_stat[5] = io_seeks;
				q_stat[6] = io_reads;
				if (q_stat[4] > q_stat[7]) q_stat[7] = q_stat[4];
				else while (q_head - cut < PREROLL && q_gen == g && q_allow) {
					u32 h = q_head & (RING_N - 1), n = RING_N - h, fr = RING_N - (q_head - q_tail);
					int got;
					if (n > 1152) n = 1152;
					if (n > fr) n = fr;
					if (!n) break;
					got = tadec_read((s16 *)(ring + h), (int)n);
					if (got <= 0) { q_eof = 1; break; }
					q_head = q_head + (u32)got;
				}
				q_cut = cut;
				q_cutn = q_cutn + 1;
			} else {
				q_head = q_tail;
				if (c == Q_OPEN) q_res = tadec_open(q_path);
				else tadec_close();
				q_head = q_tail;
			}
			q_io = 0;
			q_ack = g;
			continue;
		}
		u32 used = q_head - q_tail;
		if (kind != K_NONE && !q_eof && q_allow && used < RING_HI) {
			u32 h = q_head & (RING_N - 1), n = RING_N - h;
			int got;
			if (n > 1152) n = 1152;
			q_io = 1;
			if (!q_allow) { q_io = 0; continue; }
			got = tadec_read((s16 *)(ring + h), (int)n);
			q_io = 0;
			if (got > 0) q_head = q_head + (u32)got;   /* (an OPEN / CLOSE flushes it) */
			else if (q_gen == g) q_eof = 1;
			if (used + (u32)got >= PREROLL) FW_DLY(1);   /* ahead: let lower tasks run */
			continue;
		}
		FW_DLY(2);
	}
}

static u32 q_post(u32 c, u32 a)
{
	q_cmd = c;
	q_arg = a;
	q_gen = q_gen + 1;
	return q_gen;
}

static int q_wait(u32 g)
{
	for (int t = 0; q_ack != g; t++) {
		if (t > 5000) return -1;
		FW_DLY(1);
	}
	return 0;
}

static int q_start(void)
{
	void *stk;
	int id;
	if (q_state) return q_state == 1 ? 0 : -1;
	q_state = 2;
	ring = FW_MALLOC(RING_N * 4);
	stk = ring ? FW_MALLOC(DEC_STK) : 0;
	if (!stk) return -1;
	q_gen = q_ack = 0;
	q_head = q_tail = 0;
	q_ctsk.atr = 0;
	q_ctsk.exinf = 0;
	q_ctsk.task = (void *)tadec_task_entry;
	q_ctsk.pri = DEC_PRI;
	q_ctsk.stksz = DEC_STK;
	q_ctsk.stk = stk;
	q_ctsk.name = q_name;
	id = FW_ACRE(&q_ctsk);
	if (id <= 0) return -1;
	if (FW_STA(id, 0) != 0) return -1;
	q_state = 1;
	return 0;
}

int q_open(const u16 *wpath)
{
	u32 g;
	if (q_start()) return -10;
	q_path = wpath;
	q_allow = 1;
	g = q_post(Q_OPEN, 0);
	q_stat[2]++;
	q_run = 0;
	if (q_wait(g)) { q_post(Q_CLOSE, 0); return -11; }
	q_cutseen = q_cutn;
	return q_res;
}

int q_seek(u32 col)
{
	if (q_state != 1) return -1;
	q_allow = 1;
	q_post(Q_SEEK, col);
	return 0;
}

void q_close(void)
{
	if (q_state != 1) return;
	q_wait(q_post(Q_CLOSE, 0));
	q_run = 0;
}

/* frames into out (s16 stereo); 0..n (fewer only at the stream end), or -1:
 * nothing to play now (a command pending, or the ring under its level).
 * live != 0: a finger previews (TchDec may read on). */
int q_read(s16 *out, int n, int live)
{
	u32 avail, t, *o = (u32 *)out;
	int eof;
	if (q_state != 1) return 0;
	if (live) q_allow = 1;
	if (q_ack != q_gen && q_cmd != Q_SEEK) return -1;     /* OPEN / CLOSE under way */
	if (q_cutn != q_cutseen) {          /* a seek's new data is there: jump to it */
		q_cutseen = q_cutn;
		if ((int)(q_cut - q_tail) > 0) q_tail = q_cut;
	}
	eof = (int)q_eof;                   /* before head: at eof the head is final */
	avail = q_head - q_tail;
	if (avail > q_stat[3]) q_stat[3] = avail;
	if (!q_run) {
		if (avail < PREROLL && !eof) return -1;
		q_run = 1;
	}
	if (avail < (u32)n) {
		if (!eof) { q_run = 0; q_stat[0]++; return -1; }
		n = (int)avail;
	}
	t = q_tail;
	for (int i = 0; i < n; i++) o[i] = ring[(t + (u32)i) & (RING_N - 1)];
	q_tail = t + (u32)n;
	q_stat[1] += (u32)n;
	return n;
}

/* TchAud, before its own file reads: TchDec stops reading and is out of the
 * file layer when this returns (bounded: 2 s). */
void q_quiet(void)
{
	if (q_state != 1) return;
	q_allow = 0;
	for (int t = 0; q_io && t < 2000; t++) FW_DLY(1);
}

/* ---- the browse rows' artwork: stb_image (public domain), JPEG only ----- */
#define JPEG_ARENA (96 * 1024)
static unsigned char *jarena;
static size_t jused;
static void *j_malloc(size_t sz)
{
	size_t *p;
	sz = (sz + 15) & ~(size_t)15;
	if (!jarena || jused + sz + 16 > JPEG_ARENA) return 0;
	p = (size_t *)(jarena + jused);
	*p = sz;
	jused += sz + 16;
	return (unsigned char *)p + 16;
}
static void *j_realloc(void *p, size_t sz)
{
	void *q;
	size_t old;
	if (!p) return j_malloc(sz);
	old = *(size_t *)((unsigned char *)p - 16);
	if (sz <= old) return p;
	q = j_malloc(sz);
	if (q) memcpy(q, p, old);
	return q;
}
static void j_free(void *p) { (void)p; }
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#define STBI_NO_SIMD
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_NO_THREAD_LOCALS
#define STBI_NO_FAILURE_STRINGS
#define STBI_ASSERT(x) ((void)0)
#define STBI_MALLOC(sz) j_malloc(sz)
#define STBI_REALLOC(p, sz) j_realloc(p, sz)
#define STBI_FREE(p) j_free(p)
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

int tadec_jpeg(const unsigned char *jpg, int len, u16 *dst, void *arena)
{
	int w, h, n, x, y;
	unsigned char *img;
	jarena = arena;
	jused = 0;
	img = stbi_load_from_memory(jpg, len, &w, &h, &n, 3);
	if (!img || w < 1 || h < 1) return -1;
	for (y = 0; y < 20; y++) {                /* box average onto 20x20 */
		int y0 = y * h / 20, y1 = (y + 1) * h / 20;
		if (y1 <= y0) y1 = y0 + 1;
		for (x = 0; x < 20; x++) {
			int x0 = x * w / 20, x1 = (x + 1) * w / 20, xx, yy;
			u32 r = 0, g = 0, b = 0, c = 0;
			if (x1 <= x0) x1 = x0 + 1;
			for (yy = y0; yy < y1; yy++)
				for (xx = x0; xx < x1; xx++) {
					const unsigned char *p = img + 3 * (yy * w + xx);
					r += p[0]; g += p[1]; b += p[2]; c++;
				}
			r /= c; g /= c; b /= c;
			dst[y * 20 + x] = (u16)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
		}
	}
	return 0;
}

/* The entry table (crt.S, first in the blob) calls these through stubs. */
