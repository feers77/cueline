/* SPDX-License-Identifier: Apache-2.0
 *
 * ks4mt: KEY SHIFT through the deck's own MASTER TEMPO engine (Cueline 2.3 study, PROTOTYPE -- emulator only).
 *
 * The CDJ-3000 has no separate pitch shifter in normal play: its tempo engine is run at tempo / pitch and its
 * output is resampled by the pitch ratio.  The same is done here with the stock NXS2 engine, which our hook
 * already wraps (ks_fill on the L2 trampoline calls the stock pipeline 0x800044A4 for every 16-frame block):
 *
 *   1. the stretch ratio.  The stock engine computes it in ONE place, 0x80046CC0, once per 512 output frames:
 *        ratio = (float)rate_q20 * 2^-20            (b14+892 -> b14+1032; x 512 -> input frames per block)
 *      The constant 2^-20 is loaded by `mvkh .S2 0x35800000,b7` at 0x80046CE0 (its low half is 0).  We rewrite
 *      that instruction's 16-bit field with the high half of 2^-20 / p, so the engine stretches at tempo / p.
 *      Only 7 mantissa bits fit there: p is therefore rounded to the nearest factor that is exact in that
 *      form (up to 0.39 % = 7 cents off the semitone), and the SAME rounded p drives the resampler, so the
 *      tempo stays exact.  (The product needs a 3-instruction load of a full float: boot-table patch, later.)
 *   2. the resampler.  Per interrupt we need 16 * p frames of the engine's output: the stock pipeline is
 *      called 0, 1 or 2 times (each call = one finished 16-frame block), the blocks go to a small FIFO and
 *      16 frames are read from it at ratio p with linear interpolation (the 3000's own post-resampler is
 *      linear too).  Added delay: the FIFO's slack, about 16 frames (0.4 ms).
 *
 * Active only while the stock engine runs (MASTER TEMPO on: b14+1032 != 0) and in the 44.1 kHz mode (0).
 * Everything else is the bit-exact bypass.  Measured on a DSP record of R22R1n (work/ks4proto/mt): the stock
 * engine is called once per interrupt and costs 16.5 k cycles median, 86 k at most, of ~308 k available.
 *
 * Since R23P8 the ratio is NOT rewritten in the engine: the rate manager is wrapped (ks_rate below), and since
 * R23P9 MASTER TEMPO off is covered by the hidden engine (ks_rate / ks_fill).  Deck run of R23K1n (2026-11-22):
 * position 999..1001 ms per second at +2 +7 0 -5 -12 +11 +3, no EMERGENCY LOOP.
 * NOT DONE (work/ks4proto/mt/NOTES.md): the 96 kHz mode (bypassed), a DSP time measurement on the deck.
 */
#include <stdint.h>

typedef void (*fill_fn)(int32_t *b0, int32_t *b1, int mode);

struct ks_ctl {
    uint32_t magic, init;           /* +0 'OWKS', +4 */
    volatile float ratio;           /* +8 written by MAIN: 2^(k/12), 1.0 = off */
    volatile uint32_t blocks;       /* +12 interrupts seen */
    volatile uint32_t active;       /* +16 1 while the resampler path is in use */
    volatile float cur;             /* +20 the factor in use (rounded, see above) */
    volatile uint32_t over;         /* +24 underruns: the FIFO could not give 16 frames */
    volatile uint32_t splices;      /* +28 here: stock pipeline calls made */
    volatile float lastr;           /* +32 here: the stock engine's ratio float (b14+1032) as last seen */
    volatile uint32_t ipos;         /* +36 here: the instruction word found at 0x80046CE0 */
    volatile uint32_t eng;          /* +40 here: 1 = the instruction was recognised and is ours to rewrite */
    volatile uint32_t version;      /* +44 */
};
__attribute__((section(".ksctl"))) struct ks_ctl ks_ctl = { 0x534B574Fu, 0, 1.0f, 0, 0, 1.0f, 0, 0, 0, 0, 0, 0x4B533301u };

#define B14        0x008BC670u
#define RATE_Q20   (*(volatile uint32_t *)(B14 + 892))
#define MT_RATIO   (*(volatile float *)(B14 + 1032))
#define MT_INBLK   (*(volatile int32_t *)(B14 + 1076))
#define MT_FRAC    (*(volatile float *)(B14 + 1080))
#define MT_ACC     (*(volatile float *)(B14 + 1084))
#define STOCK_DERIVE 0x8003DD38u         /* derives the engine's parameters from b14+1032 */
#define FIFO       128
#define SLACK      16

#define NOLOAD __attribute__((section(".ksnoload")))
NOLOAD static int32_t fl[FIFO], fr[FIFO];        /* the pipeline's first output buffer (b0) */
NOLOAD static int32_t gl[FIFO], gr[FIFO];        /* its second one (b1): audio too, same layout [M] */
static int nf;                           /* frames in the FIFO */
static float pos;                        /* read position in it */
static float p_req = 1.0f;               /* the factor asked for (ks_fill), 1.0 = leave the engine alone */
static int on;                           /* FIFO path in use */
static float p_glide = 1.0f;             /* the factor in use, gliding to the one asked for */
static int32_t hl, hr, kl, kr;           /* last outputs (held on an underrun) */

/* The rate word.  b14+892 is the deck's play rate (Q20 in the low 24 bits, flags above).  The stock "rate manager"
 * 0x8000D158 is called by the pipeline on every call (two sites, 0x80004C18 / 0x80004C34); at the first slice of
 * each 512-frame block it latches the rate MAIN asked for into the word, and it runs the start / brake ramps on it.
 * Everything per-call downstream is derived from the word: the engine's stretch ratio (0x80046CC0, once per block,
 * with its own fractional carry) and the play position the DSP keeps and reports to MAIN.
 * We call the pipeline p times per interrupt on average, so everything downstream must see rate / p: the boot table
 * retargets the two calls of the rate manager to a veneer (alignment gap 0x8005AFCC) that jumps to ks_rate, which
 * gives the manager its own value back, runs it, and then scales what it left in the word.
 * History [M, emulator]: scaling only the engine (R23P1n..P4n) left the position p times too fast -> EMERGENCY
 * LOOP; scaling the word around the whole pipeline call (R23P5n..P7n) never reached the engine (the manager
 * latched the true rate back at each block start: ratio 1.0, in 512 in every block) -> tempo (31 + p) / 32. */
#define STOCK_RATE_MGR 0x8000D158u
static uint32_t rate_true, rate_wr;
static int rate_on;
static volatile float p_now = 1.0f;      /* the factor in use (set by ks_fill) */
/* MASTER TEMPO off (owner 2026-11-22: as the CDJ-3000, KEY SHIFT works without touching the MT key).
 * The manager's SECOND argument is MASTER TEMPO: 1 on, 0 off [M: replay of R22R1n, tr_rm.txt]; with it the manager
 * sets bit 31 of b14+300 and the stock cross-fade into / out of the engine runs.  While a shift is wanted and the
 * user's MT is off we pass 1: the engine runs "hidden" (MAIN, the MT lamp and the status packet know nothing),
 * and ks_fill resamples by shift x rate instead of shift, so the tempo AND the pitch follow the fader as with MT
 * off, plus the shift.  The engine then stretches at 1 / shift whatever the fader does. */
static volatile int user_mt = 1;         /* the MT argument MAIN's state gave last */
static volatile int hid_want;            /* ks_fill: a shift is wanted or still gliding (mode 0) */
int ks_rate(int a, int b, int c, int d)
{
    int r;
    float p = p_now;
    user_mt = b;
    if (rate_on && RATE_Q20 == rate_wr)
        RATE_Q20 = rate_true;
    r = ((int (*)(int, int, int, int))STOCK_RATE_MGR)(a, hid_want ? 1 : b, c, d);
    ks_ctl.ipos++;
    rate_true = RATE_Q20;
    if (p != 1.0f) {
        uint32_t t = rate_true, lo;
        lo = (uint32_t)((float)(t & 0x00FFFFFFu) / p + 0.5f);
        if (lo > 0x00FFFFFFu) lo = 0x00FFFFFFu;
        rate_wr = (t & 0xFF000000u) | lo;
        RATE_Q20 = rate_wr;
        rate_on = 1;
    } else
        rate_on = 0;
    return r;
}

/* trace taps for the DSP replay (work/ks4proto/mt): a4 = a finished stock block / our output block */
__attribute__((noinline)) void ks_tapi(int32_t *b) { __asm__ volatile (""); (void)b; }
__attribute__((noinline)) void ks_tapo(int32_t *b) { __asm__ volatile (""); (void)b; }

void ks_fill(int32_t *b0, int32_t *b1, int mode)
{
    float t = ks_ctl.ratio, mt = MT_RATIO, p_use;
    int calls = 0, i;

    ks_ctl.blocks++;
    ks_ctl.lastr = mt;
    if (mode != 0) {                     /* the 96 kHz mode (32-frame blocks, its own engine routine): not ours.
                                          * The exact bypass, and the shifted path is dropped if it was in use. */
        on = 0; p_glide = 1.0f; p_now = 1.0f; hid_want = 0;
        ((fill_fn)KS_STOCK_FILL)(b0, b1, mode);
        ks_ctl.active = 0;
        return;
    }
    if (t < 0.49f || t > 2.01f)
        t = 1.0f;
    p_req = t;
    if (mt == 0.0f)
        t = 1.0f;                        /* the engine is not running (yet): no shift; hid_want starts it */
    /* The resampler follows the request at once: the engine keeps the pitch whatever its ratio, so the pitch
     * steps now; the engine's ratio follows at its next 512-frame boundary (<= 11.6 ms), a slip of at most
     * 11.6 ms x |1 - p_new / p_old| in time, once per change. */
    /* glide: 0.05 % per interrupt (the engine takes it in steps of at most 1.6 % per 512-frame block; +7 in
     * 0.3 s).  A jump of the engine's ratio in one step -- 0 -> +7, +7 -> -5 -- stopped the audio some seconds
     * later in the emulator (R23P5n); a constant shift ran for a minute. */
    if (p_glide < t) { p_glide *= 1.0005f; if (p_glide > t) p_glide = t; }
    else if (p_glide > t) { p_glide *= 0.9995f; if (p_glide < t) p_glide = t; }
    hid_want = (p_req != 1.0f || p_glide != 1.0f);
    p_use = p_glide;
    if (!user_mt && (hid_want || mt != 0.0f)) {
        /* hidden engine (or the engine fading out after one): the fader's rate goes through the resampler.
         * Not glided: the engine's ratio (rate / p_use) does not move when the fader does. */
        p_use *= (float)(rate_true & 0x00FFFFFFu) * (1.0f / 1048576.0f);
        if (p_use < 0.5f) p_use = 0.5f;  /* brake / pause / WIDE: the engine takes the rest, as with MT on */
        if (p_use > 2.0f) p_use = 2.0f;
    }
    p_now = p_use;
    ks_ctl.cur = p_use;

    if (!on && p_use == 1.0f) {          /* never used: the exact bypass */
        ((fill_fn)KS_STOCK_FILL)(b0, b1, mode);
        ks_tapi(b0); ks_tapo(b0);
        ks_ctl.splices++;
        ks_ctl.active = 0;
        return;
    }
    if (!on) { on = 1; nf = 0; pos = 0.0f; }
    ks_ctl.active = 1;

    /* blocks from the stock pipeline until 16 output frames (+ the slack) are there; at most 2 a call */
    while ((float)nf - pos < 16.0f * p_use + 2.0f + (float)SLACK && calls < 2 && nf + 16 <= FIFO) {
        ((fill_fn)KS_STOCK_FILL)(b0, b1, mode);
        ks_tapi(b0);
        for (i = 0; i < 16; i++) {
            fl[nf + i] = b0[i]; fr[nf + i] = b0[16 + i];
            gl[nf + i] = b1[i]; gr[nf + i] = b1[16 + i];
        }
        nf += 16; calls++;
    }
    ks_ctl.splices += (uint32_t)calls;

    /* REVIEW 1124 5.1: back at 1.0 after a shift the FIFO keeps a fractional read position, and the linear
     * interpolation at a fixed fraction is a low-pass (-3 dB at 11 kHz for f = 0.5) for as long as the deck runs.
     * At exactly 1.0 read whole samples (the FIFO's latency stays, the audio is bit-exact again). */
    if (p_use == 1.0f)
        pos = (float)(int)(pos + 0.5f);
    for (i = 0; i < 16; i++) {
        int ip = (int)pos;
        if (ip + 1 < nf) {
            float f = pos - (float)ip;
            hl = (int32_t)((float)fl[ip] + f * ((float)fl[ip + 1] - (float)fl[ip]));
            hr = (int32_t)((float)fr[ip] + f * ((float)fr[ip + 1] - (float)fr[ip]));
            kl = (int32_t)((float)gl[ip] + f * ((float)gl[ip + 1] - (float)gl[ip]));
            kr = (int32_t)((float)gr[ip] + f * ((float)gr[ip + 1] - (float)gr[ip]));
            pos += p_use;
        } else
            ks_ctl.over++;               /* hold the last sample */
        b0[i] = hl; b0[16 + i] = hr;
        b1[i] = kl; b1[16 + i] = kr;
    }
    ks_tapo(b0);
    {   /* drop what was read */
        int d = (int)pos;
        if (d > nf) d = nf;
        if (d > 0) {
            for (i = d; i < nf; i++) { fl[i - d] = fl[i]; fr[i - d] = fr[i]; gl[i - d] = gl[i]; gr[i - d] = gr[i]; }
            nf -= d; pos -= (float)d;
        }
    }
}
