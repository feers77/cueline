/* SPDX-License-Identifier: Apache-2.0
 *
 * ks3: KEY SHIFT for the CDJ-2000NXS2 DSP (C66x), written from scratch (v4.1; replaces the two-tap ownks.c
 * engine, research41 topic A). Same interface as before, so MAIN (mods/ownks/main_ownks.s) is unchanged:
 * struct ks_ctl at the section start (ratio float at +8), ks_fill() on the L2 trampoline, which calls the
 * stock pipeline and then ks_process() on the finished planar 16-frame block (16 left words then 16 right
 * words, 24-bit samples left-justified in 32-bit words). Tempo is untouched: MASTER TEMPO on -> key =
 * original + shift; off -> key = original + tempo fader + shift.
 *
 * Algorithm (the CDJ-3000 PitchSimpleCrossFade shape + a splice search the 3000 does not have):
 *   - ONE read tap at gain 1 most of the time (no permanent two-tap comb filter); its delay d moves by
 *     (1 - s) per frame, s = the factor; 4-point cubic (Catmull-Rom) interpolation;
 *   - when d nears its bound, the tap is spliced G frames back (up-shift) / forward (down-shift); the
 *     exact jump is chosen within +-K frames by normalised cross-correlation of the past 512 frames
 *     (decimated-by-8 mono), refined +-4 frames at full rate.  The search is AMORTISED over the
 *     blocks before the deadline (<= 16 lags per block), so no block carries a spike;
 *   - X-frame crossfade, shape blended by the measured correlation r between equal-power (r = 0)
 *     and amplitude-complementary sin^2 (r = 1);
 *   - the factor glides to its target (one-pole per block, ~12 ms) instead of stepping;
 *   - entry from the exact bypass is a correlated splice from the dry signal; exit = correlated splice
 *     to a small delay (<= 2K), hold (one tap, clean), then splice to dry when tap and dry agree
 *     (r > 0.8) or after EXITW blocks; after that the output is the input bit for bit.  The VINYL
 *     jog-touch bypass (MAIN sends 1.0) and KEY SHIFT 0 take this exit.
 *
 * Integration (KS3): the state (70 KB) is NOLOAD and set up in CHUNKS over the first ~18 blocks (ks_ctl.ipos
 * counts; the boot table zeroes it), the audio passing through untouched meanwhile and the rings already
 * being fed, so no block pays the ~0.5M-cycle one-shot clear.  Built with -DKS_AB (the DEV A/B test build,
 * work/v4n/KS3_DONE), the image also carries the previous engine (ownks.c -DKS_AB_OLD): a ratio word with
 * the sign bit set selects it (MAIN's UTILITY "KS3 ENGINE" OFF), |ratio| being the factor.
 */
#include <stdint.h>

#ifndef KS_G
#define KS_G     1024               /* nominal splice jump (frames) */
#endif
#ifndef KS_X
#define KS_X     256                /* crossfade (frames) */
#endif
#ifndef KS_K
#define KS_K     384                /* search half range (frames) */
#endif
#ifndef INTERP
#define INTERP   3
#endif
#ifndef EXITW
#define EXITW    2756               /* hold blocks before a forced exit (1 s) */
#endif
#define RING     8192u
#define DEC      8
#define DRING    (RING / DEC)
#define LWD      64                 /* correlation window, decimated samples (512 frames) */
#define KD       (KS_K / DEC)
#define NLAG     (2 * KD + 1)
#ifndef LPB
#define LPB      8
#endif
#define RPB      2                  /* refine candidates per block */
#define LA       24                 /* blocks of look-ahead for the search */
#define DMIN     8.0f
#define DMAX     ((float)(RING - 1024))
#define GLIDE    0.03f
#ifndef ICH
#define ICH      512                /* init: ring words cleared per ring per block */
#endif

typedef void (*fill_fn)(int32_t *b0, int32_t *b1, int mode);

struct ks_ctl {
    uint32_t magic, init;           /* +0 'OWKS', +4 KS_INIT once the state is set up */
    volatile float ratio;           /* +8 written by MAIN: 2^((100k+c)/1200), 1.0 = off (KS_AB: sign = old engine) */
    volatile uint32_t blocks;       /* +12 processed blocks (diagnostic) */
    volatile uint32_t active;       /* +16 1 while the wet path is in use */
    volatile float cur;             /* +20 factor in use (after the glide) */
    volatile uint32_t over;         /* +24 (unused, kept from ownks) */
    volatile uint32_t splices;      /* +28 diag: splices done */
    volatile float lastr;           /* +32 diag: correlation of the last splice */
    volatile uint32_t ipos;         /* +36 KS3 chunked init: words of each ring cleared from the top (0 at load) */
    volatile uint32_t eng;          /* +40 KS_AB: 1 = the old engine is the one in use */
    volatile uint32_t version;      /* +44 'KS3' + engine image flavour (1 = ks3, 2 = ks3 + old A/B) */
};
#ifdef KS_AB
#define KS_VER 0x4B533302u
#else
#define KS_VER 0x4B533301u
#endif
__attribute__((section(".ksctl"))) struct ks_ctl ks_ctl = { 0x534B574Fu, 0, 1.0f, 0, 0, 1.0f, 0, 0, 0, 0, 0, KS_VER };
#define KS_INIT 0x54494E49u

#define NOLOAD __attribute__((section(".ksnoload")))
NOLOAD static float rl[RING], rr[RING], rd[DRING];
NOLOAD static float sint[KS_X + 1];          /* sin(pi/2 * i/X) */
NOLOAD static uint32_t wpos, dpos;
NOLOAD static float dacc;
NOLOAD static int dn;
NOLOAD static float s_cur;
NOLOAD static int wet;                       /* 0 = exact bypass */
NOLOAD static float da, db;                  /* main tap / incoming tap delay */
NOLOAD static int a_dry, b_dry;
NOLOAD static int xf;                        /* crossfade position, 0 = none */
NOLOAD static float alpha;
NOLOAD static int exitwait;
/* amortised search job */
NOLOAD static int sj, sj_kind, sj_dir, sj_k, sj_bk, sj_j, sj_rd;
NOLOAD static float sj_rb;
NOLOAD static int sj_k0, sj_k1;
NOLOAD static uint32_t sj_w0;                /* wpos at start */
NOLOAD static float sj_d0, sj_best, sj_bc, sj_be, sj_eref, sj_off, sj_r;
NOLOAD static float ref[LWD], cand[LWD + NLAG + 8];
enum { SJ_IDLE, SJ_RUN, SJ_DONE };
enum { K_SPLICE = 1, K_ENTER, K_EXIT1 };

/* feed the rings with one block (the bypass path's work) */
static inline void feed(const int32_t *buf, int frames)
{
    for (int n = 0; n < frames; n++) {
        float xl = (float)(buf[n] >> 8), xr = (float)(buf[frames + n] >> 8);
        rl[wpos] = xl; rr[wpos] = xr;
        dacc += xl + xr;
        if (++dn == DEC) { rd[dpos] = dacc; dpos = (dpos + 1) & (DRING - 1); dacc = 0; dn = 0; }
        wpos = (wpos + 1) & (RING - 1);
    }
}

/* KS3: one step of the chunked set-up (the block passes through untouched).  Step 0 starts the write
 * indices; every step feeds the block into the rings from index 0 up and clears ICH more words of each
 * ring from the top down, never below what has been written, so when the two meet the rings hold exactly
 * what the one-shot clear + the same blocks would have left (zeros + those samples).  The last step
 * computes the crossfade table and the engine's initial (bypass) state.  ~18 blocks. */
static void ks_init_step(const int32_t *buf, int frames)
{
    uint32_t ip = ks_ctl.ipos;
    if (ip >= RING) ip = 0;         /* init word cleared after a finished set-up (or garbage): start over */
    if (ip == 0) { wpos = dpos = 0; dacc = 0; dn = 0; }
    feed(buf, frames);
    uint32_t hi = RING - ip, lo = hi > ICH ? hi - ICH : 0;
    if (lo < wpos) lo = wpos;
    for (uint32_t i = lo; i < hi; i++) rl[i] = rr[i] = 0.0f;
    uint32_t dhi = (RING - ip) / DEC, dlo = lo / DEC;
    if (dlo < dpos + (dn ? 1u : 0u)) dlo = dpos + (dn ? 1u : 0u);
    for (uint32_t i = dlo; i < dhi; i++) rd[i] = 0.0f;
    if (lo > wpos) {
        ks_ctl.ipos = RING - lo;
        return;
    }
    const double th = 3.14159265358979323846 / (2.0 * KS_X);
    double c = 1.0 - th * th / 2 + th * th * th * th / 24 - th * th * th * th * th * th / 720;
    double s0 = 0.0, s1 = th - th * th * th / 6 + th * th * th * th * th / 120;
    sint[0] = 0.0f; sint[1] = (float)s1;
    for (int i = 2; i <= KS_X; i++) { double s2 = 2 * c * s1 - s0; s0 = s1; s1 = s2; sint[i] = (float)s2; }
    sint[KS_X] = 1.0f;
    s_cur = 1.0f; wet = 0; xf = 0; exitwait = 0;
    da = db = 0; a_dry = b_dry = 1; sj = SJ_IDLE;
    ks_ctl.ipos = RING;
    ks_ctl.init = KS_INIT;
}

static inline float rdf(const float *r, uint32_t w, float d)
{
    float p = (float)w - d + (float)RING;
    int i = (int)p;
    float f = p - (float)i;
#if INTERP == 1
    float a = r[(uint32_t)i & (RING - 1)], b = r[(uint32_t)(i + 1) & (RING - 1)];
    return a + (b - a) * f;
#else
    float xm = r[(uint32_t)(i - 1) & (RING - 1)], x0 = r[(uint32_t)i & (RING - 1)];
    float x1 = r[(uint32_t)(i + 1) & (RING - 1)], x2 = r[(uint32_t)(i + 2) & (RING - 1)];
    float c1 = 0.5f * (x1 - xm), c2 = xm - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
    float c3 = 0.5f * (x2 - xm) + 1.5f * (x0 - x1);
    return ((c3 * f + c2) * f + c1) * f + x0;
#endif
}

static inline float rsq(float x)
{
    union { float f; uint32_t u; } v = { x };
    v.u = 0x5F3759DFu - (v.u >> 1);
    float y = v.f;
    y = y * (1.5f - 0.5f * x * y * y);
    y = y * (1.5f - 0.5f * x * y * y);
    return y;
}

/* start a search: the past of delay d0 against delays [lo, hi] (all at the current wpos) */
static void sj_start(int kind, int dir, float d0, float lo, float hi)
{
    if (lo < DMIN) lo = DMIN;
    if (hi > DMAX) hi = DMAX;
    int k0 = (int)(lo * (1.0f / DEC)) + 1, k1 = (int)(hi * (1.0f / DEC));
    if (k1 < k0) k1 = k0;
    if (k1 - k0 + 1 > NLAG) k1 = k0 + NLAG - 1;
    uint32_t e0 = ((uint32_t)((float)(wpos + RING) - d0) >> 3) - 1u;
    float e = 0;
    for (int m = 0; m < LWD; m++) { float v = rd[(e0 - (LWD - 1) + (uint32_t)m) & (DRING - 1)]; ref[m] = v; e += v * v; }
    /* candidate k (delay 8k) ends at decimated index dpos-1-k; cand[] holds them oldest first */
    uint32_t c0 = dpos - 1u - (uint32_t)k1 - (LWD - 1);
    for (int j = 0; j < LWD + (k1 - k0); j++) cand[j] = rd[(c0 + (uint32_t)j) & (DRING - 1)];
    sj = SJ_RUN; sj_kind = kind; sj_dir = dir; sj_d0 = d0; sj_w0 = wpos;
    sj_k0 = k0; sj_k1 = k1; sj_k = k0; sj_best = -1e30f; sj_bk = k0; sj_bc = 0; sj_be = 1; sj_eref = e;
}

static void sj_step(int nlag)
{
    for (; nlag > 0 && sj_k <= sj_k1; nlag--, sj_k++) {
        const float *c = cand + (sj_k1 - sj_k);
        float c0 = 0, c1 = 0, c2 = 0, c3 = 0, e0 = 0, e1 = 0, e2 = 0, e3 = 0;
        for (int m = 0; m < LWD; m += 4) {        /* 4 accumulators: lets the C66x pipeline the loop */
            c0 += ref[m] * c[m]; c1 += ref[m + 1] * c[m + 1]; c2 += ref[m + 2] * c[m + 2]; c3 += ref[m + 3] * c[m + 3];
            e0 += c[m] * c[m]; e1 += c[m + 1] * c[m + 1]; e2 += c[m + 2] * c[m + 2]; e3 += c[m + 3] * c[m + 3];
        }
        float cc = (c0 + c1) + (c2 + c3), ee = (e0 + e1) + (e2 + e3);
        float sc = ee > 0 ? (cc > 0 ? cc * cc : -cc * cc) / ee : -1e30f;
        if (sc > sj_best) { sj_best = sc; sj_bk = sj_k; sj_bc = cc; sj_be = ee; }
    }
    if (sj_k <= sj_k1)
        return;
    /* full-rate refine +-4 frames on mono, integer positions in input time (frozen at the start);
     * amortised: RPB candidates per block (nlag == NLAG: all at once) */
    if (sj_k == sj_k1 + 1) { sj_j = -4; sj_rb = -1e30f; sj_rd = sj_bk * DEC; sj_k++; }
    uint32_t p0 = sj_w0 - 1u - (uint32_t)(sj_d0 + 0.5f);
    int dbest = sj_bk * DEC, nr = nlag > NLAG ? 9 : RPB;
    for (; nr > 0 && sj_j <= 4; nr--, sj_j++) {
        uint32_t pc = sj_w0 - 1u - (uint32_t)(dbest + sj_j);
        float cc = 0, ee = 0;
        for (int m = 0; m < 64; m++) {
            uint32_t i0 = (p0 - (uint32_t)m) & (RING - 1), i1 = (pc - (uint32_t)m) & (RING - 1);
            float x = rl[i0] + rr[i0], y = rl[i1] + rr[i1];
            cc += x * y; ee += y * y;
        }
        float sc = ee > 0 ? (cc > 0 ? cc * cc : -cc * cc) / ee : -1e30f;
        if (sc > sj_rb) { sj_rb = sc; sj_rd = dbest + sj_j; }
    }
    if (sj_j <= 4)
        return;
    int bd = sj_rd;
    sj_off = (float)bd - sj_d0;
    sj_r = (sj_eref > 0 && sj_be > 0) ? sj_bc * rsq(sj_eref * sj_be) : 0.0f;
    sj = SJ_DONE;
}

static void start_xf(float dnew, int newdry, float r)
{
    db = dnew; b_dry = newdry; xf = 1;
    alpha = r < 0 ? 0 : (r > 1 ? 1 : r);
    ks_ctl.splices++;
    ks_ctl.lastr = r;
}

/* t = the target factor (ks_ctl.ratio as MAIN wrote it) */
void ks_process(int32_t *buf, int frames, float t)
{
    if (!(t > 0.49f && t < 2.01f)) t = 1.0f;
    if (!(s_cur > 0.49f && s_cur < 2.01f)) s_cur = 1.0f;     /* KS3 guard: a corrupt glide state */
    float ds = t - s_cur;
    if (ds > 1e-5f || ds < -1e-5f) s_cur += ds * GLIDE; else s_cur = t;
    float s = s_cur;
    ks_ctl.cur = s;
    if (!(da >= 0.0f && da <= (float)RING) || !(db >= 0.0f && db <= (float)RING) || (unsigned)xf > KS_X) {
        wet = 0; xf = 0; a_dry = 1; da = 0; sj = SJ_IDLE;     /* corrupt state: back to bypass */
    }
    wpos &= RING - 1; dpos &= DRING - 1;
    int dir = s > 1.0f ? 1 : (s < 1.0f ? -1 : 0);

    if (!xf) {
        float span = (float)frames * (s > 1 ? s - 1 : 1 - s);
        float tail = (float)KS_X * (s > 1 ? s - 1 : 1 - s) + span;
        if (sj == SJ_RUN || sj == SJ_DONE) {
            if (sj_kind == K_SPLICE && sj_dir != dir) sj = SJ_IDLE;              /* direction changed */
            if (sj_kind == K_ENTER && t == 1.0f) sj = SJ_IDLE;
            if (sj_kind == K_EXIT1 && (t != 1.0f || s != 1.0f)) sj = SJ_IDLE;
        } else if (sj != SJ_IDLE)
            sj = SJ_IDLE;                                       /* KS3: an out-of-range job state */
        if (!wet) {
            if (t != 1.0f && sj == SJ_IDLE)
                sj_start(K_ENTER, 0, 0.0f, t > 1.0f ? KS_G * 0.5f : DMIN + 16, (t > 1.0f ? KS_G * 0.5f : DMIN + 16) + 2 * KS_K);
        } else if (t == 1.0f && s == 1.0f) {
            if (da > (float)(2 * KS_K) + DMIN) {
                if (sj == SJ_IDLE) sj_start(K_EXIT1, 0, da, DMIN, (float)(2 * KS_K) + DMIN);
            } else if (sj == SJ_IDLE) {
                /* hold: corr(dry, tap) over the last 512 frames, decimated */
                uint32_t e0 = dpos - 1u, e1 = dpos - 1u - (uint32_t)(da * (1.0f / DEC));
                float cc = 0, a = 0, b = 0;
                for (int m = 0; m < LWD; m++) {
                    float x = rd[(e0 - (uint32_t)m) & (DRING - 1)], y = rd[(e1 - (uint32_t)m) & (DRING - 1)];
                    cc += x * y; a += x * x; b += y * y;
                }
                float r = (a > 0 && b > 0) ? cc * rsq(a * b) : 0.0f;
                if (r > 0.8f || ++exitwait > EXITW || da < 1.0f) { start_xf(0.0f, 1, r); exitwait = 0; }
            }
        } else if (sj == SJ_IDLE) {
            exitwait = 0;
            if (dir > 0 && da - tail - (float)LA * span <= DMIN + 4)
                sj_start(K_SPLICE, 1, da, da + KS_G - KS_K, da + KS_G + KS_K);
            else if (dir < 0 && da + tail + (float)LA * span >= (float)(KS_G + KS_K) + DMIN + 16)
                sj_start(K_SPLICE, -1, da, da - KS_G - KS_K, da - KS_G + KS_K);
        }
        if (sj == SJ_RUN) {
            int urgent = sj_kind == K_SPLICE && (dir > 0 ? da - tail <= DMIN + 4
                                                         : da + tail >= (float)(KS_G + KS_K) + DMIN + 16);
            sj_step(urgent ? NLAG + 16 : LPB);
        }
        if (sj == SJ_DONE) {
            float nd = (sj_kind == K_ENTER ? 0.0f : da) + sj_off;
            if (nd < DMIN) nd = DMIN;
            if (sj_kind == K_ENTER) { wet = 1; a_dry = 1; da = 0; }
            start_xf(nd, 0, sj_r);
            sj = SJ_IDLE;
        }
    }
    ks_ctl.active = wet;

    if (!wet) {                     /* exact bypass: only feed the rings */
        feed(buf, frames);
        return;
    }
    float step = 1.0f - s;
    for (int n = 0; n < frames; n++) {
        float xl = (float)(buf[n] >> 8), xr = (float)(buf[frames + n] >> 8);
        rl[wpos] = xl; rr[wpos] = xr;
        dacc += xl + xr;
        if (++dn == DEC) { rd[dpos] = dacc; dpos = (dpos + 1) & (DRING - 1); dacc = 0; dn = 0; }
        if (wet) {
            float al = a_dry ? xl : rdf(rl, wpos, da), ar = a_dry ? xr : rdf(rr, wpos, da);
            float yl = al, yr = ar;
            if (xf) {
                float bl = b_dry ? xl : rdf(rl, wpos, db), br = b_dry ? xr : rdf(rr, wpos, db);
                float gi = sint[xf], go = sint[KS_X - xf];
                gi = gi + alpha * (gi * gi - gi);   /* r = 1: sin^2 (sum 1); r = 0: sin (power 1) */
                go = go + alpha * (go * go - go);
                yl = go * al + gi * bl;
                yr = go * ar + gi * br;
                if (!b_dry) db += step;
                if (++xf > KS_X) {
                    xf = 0; da = db; a_dry = b_dry;
                    if (a_dry) wet = 0;
                } else if (!a_dry) da += step;
            } else if (!a_dry) da += step;
            if (da < 2.0f && !a_dry) da = 2.0f;
            if (yl > 8388607.0f) yl = 8388607.0f;
            if (yl < -8388608.0f) yl = -8388608.0f;
            if (yr > 8388607.0f) yr = 8388607.0f;
            if (yr < -8388608.0f) yr = -8388608.0f;
            buf[n] = (int32_t)yl << 8;
            buf[frames + n] = (int32_t)yr << 8;
        }
        wpos = (wpos + 1) & (RING - 1);
    }
}

#ifdef KS_AB
/* the previous engine (ownks.c built -DKS_AB_OLD): its own ks_ctl copy, state and process */
struct oks_ctl { uint32_t magic, init; volatile float ratio; };
extern struct oks_ctl oks_ctl;
void oks_process(int32_t *buf, int frames);
void oks_quiesce(void);

/* ks3 -> bypass at once (A/B switch to the old engine): no writes to the block from now on */
static void ks3_quiesce(void)
{
    wet = 0; xf = 0; a_dry = b_dry = 1; da = db = 0; sj = SJ_IDLE; s_cur = 1.0f; exitwait = 0;
}
#endif

/* The trampoline lands here with the stock pipeline's arguments. */
void ks_fill(int32_t *b0, int32_t *b1, int mode)
{
#ifdef KS_STOCK_FILL
    ((fill_fn)KS_STOCK_FILL)(b0, b1, mode);
#endif
    float t = ks_ctl.ratio;
#ifdef KS_AB
    /* A/B: sign bit = the old engine.  The engine not in use is quiesced to its bypass at the switch and keeps
     * running in bypass (feeds its ring, writes nothing) so a later switch has history. */
    union { float f; uint32_t u; } v = { t };
    uint32_t old = v.u >> 31;
    v.u &= 0x7FFFFFFFu;
    t = v.f;
    if (old != ks_ctl.eng) {
        if (old) ks3_quiesce(); else oks_quiesce();
        ks_ctl.eng = old;
    }
    oks_ctl.ratio = old ? t : 1.0f;
    if (old) {
        if (ks_ctl.init == KS_INIT) ks_process(b0, 16, 1.0f);
        else ks_init_step(b0, 16);
        oks_process(b0, 16);
        ks_ctl.blocks++;
        return;
    }
    oks_process(b0, 16);            /* ratio 1.0, quiesced: ring feed only */
#endif
    if (ks_ctl.init != KS_INIT)
        ks_init_step(b0, 16);
    else
        ks_process(b0, 16, t);
    ks_ctl.blocks++;
}
