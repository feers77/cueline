/* SPDX-License-Identifier: Apache-2.0
 *
 * ownks: KEY SHIFT for the CDJ-2000NXS2 DSP (C66x), written from scratch.
 *
 * The stock DSP runs the whole deck audio pipeline from the McBSP0 transmit
 * ISR: per 64-frame half buffer it calls the pipeline through an L2
 * trampoline. The trampoline is pointed at ks_fill(), which calls the stock
 * pipeline and then pitch-shifts the finished stereo block in place with a
 * two-tap crossfaded delay line (the same family of algorithm as the
 * CDJ-3000's "simple crossfade" key control). Tempo is untouched, so:
 *   MASTER TEMPO on  -> key = original + shift
 *   MASTER TEMPO off -> key = original + tempo fader + shift
 * Factor 1.0 fades back to the dry signal and then bypasses exactly.
 *
 * MAIN writes ks_ctl.ratio (float bits of 2^(k/12)) with the stock "write
 * words" request. A half buffer is 16 frames, planar: 16 left words then 16
 * right words (the McBSP0 EDMA: ACNT 4, BCNT 2 at BIDX 64, CCNT 16 at CIDX
 * -60), samples 24-bit left-justified in 32-bit words.
 */
#include <stdint.h>

#ifdef KS_AB_OLD
/* KS3 A/B (ks3.c -DKS_AB): this engine rides along under other names; ks3.c's ks_fill drives it */
#define ks_ctl oks_ctl
#define ks_process oks_process_
#endif

#define RING     4096u              /* frames, power of two */
#define WIN      2048               /* tap window (46 ms at 44.1 kHz) */
#define FADE     1024               /* dry <-> wet crossfade length (frames) */
#define GTAB     512                /* gain table resolution over one window */

typedef void (*fill_fn)(int32_t *b0, int32_t *b1, int mode);

struct ks_ctl {
    uint32_t magic;                 /* 'OWKS' */
    uint32_t init;                  /* KS_INIT once the state below is set up */
    volatile float ratio;           /* written by MAIN: 2^(k/12), 1.0 = off */
    volatile uint32_t blocks;       /* processed blocks (diagnostic) */
    volatile uint32_t active;       /* 1 while the wet path is in use */
    volatile float cur;             /* ratio in use */
    volatile uint32_t over;         /* blocks whose length was unexpected */
};

extern const float ks_gain[GTAB + 2];     /* sin^2(pi x), x = 0..1 (ks_tab.c) */

#ifdef KS_AB_OLD
struct ks_ctl ks_ctl = { 0x534B574Fu, 0, 1.0f, 0, 0, 1.0f, 0 };
#else
__attribute__((section(".ksctl"))) struct ks_ctl ks_ctl = { 0x534B574Fu, 0, 1.0f, 0, 0, 1.0f, 0 };
#endif
#define KS_INIT 0x54494E49u

/* Not in the boot table (NOLOAD): set up on the first call. */
#define NOLOAD __attribute__((section(".ksnoload")))
NOLOAD static float ring_l[RING], ring_r[RING];
NOLOAD static uint32_t wpos;
NOLOAD static float dly;            /* tap 1 delay in frames, 0..WIN */
NOLOAD static int fade;             /* 0 = dry .. FADE = wet */

static void ks_init(void)
{
    for (uint32_t i = 0; i < RING; i++)
        ring_l[i] = ring_r[i] = 0.0f;
    wpos = 0;
    dly = (float)(WIN / 2);
    fade = 0;
    ks_ctl.init = KS_INIT;
}

static inline float rd(const float *r, float d)
{
    /* sample at (wpos - d), linear interpolation; d >= 0 */
    float p = (float)wpos - d + (float)RING;
    int i = (int)p;
    float f = p - (float)i;
    float a = r[(uint32_t)i & (RING - 1)];
    float b = r[(uint32_t)(i + 1) & (RING - 1)];
    return a + (b - a) * f;
}

static inline float gain(float d)
{
    float x = d * ((float)GTAB / (float)WIN);
    int i = (int)x;
    float f = x - (float)i;
    /* LASTFIX guard: d is in [0, WIN] (block-start check + the wrap), so i <= GTAB; ks_gain has a pad
     * entry at GTAB + 1 for i == GTAB (a delay that rounded to WIN) */
    return ks_gain[i] + (ks_gain[i + 1] - ks_gain[i]) * f;
}

void ks_process(int32_t *buf, int frames)
{
    float s = ks_ctl.ratio;
    if (!(s > 0.49f && s < 2.01f))
        s = 1.0f;
    int want = s != 1.0f;
    ks_ctl.cur = s;
    if (!want && fade <= 0) {
        fade = 0;
        ks_ctl.active = 0;
        /* keep the ring fed so a later start has history */
        for (int n = 0; n < frames; n++) {
            ring_l[wpos] = (float)(buf[n] >> 8);
            ring_r[wpos] = (float)(buf[frames + n] >> 8);
            wpos = (wpos + 1) & (RING - 1);
        }
        return;
    }
    ks_ctl.active = 1;
    float step = 1.0f - s;          /* delay change per frame */
    float d = dly;
    /* LASTFIX tap guard: the delay, the write index and the fade are re-checked at every block start
     * (a corrupted or never-set state -- NaN included -- restarts from the window centre) */
    if (!(d >= 0.0f && d < (float)WIN))
        d = (float)(WIN / 2);
    wpos &= RING - 1;
    if (fade < 0)
        fade = 0;
    else if (fade > FADE)
        fade = FADE;
    for (int n = 0; n < frames; n++) {
        float xl = (float)(buf[n] >> 8), xr = (float)(buf[frames + n] >> 8);
        ring_l[wpos] = xl;
        ring_r[wpos] = xr;
        float d2 = d + (float)(WIN / 2);
        if (d2 >= (float)WIN)
            d2 -= (float)WIN;
        float g1 = gain(d), g2 = 1.0f - g1;
        float yl = g1 * rd(ring_l, d) + g2 * rd(ring_l, d2);
        float yr = g1 * rd(ring_r, d) + g2 * rd(ring_r, d2);
        if (want ? fade < FADE : fade > 0)
            fade += want ? 1 : -1;
        if (fade < FADE) {
            float w = (float)fade * (1.0f / (float)FADE);
            yl = xl + (yl - xl) * w;
            yr = xr + (yr - xr) * w;
        }
        if (yl > 8388607.0f) yl = 8388607.0f;
        if (yl < -8388608.0f) yl = -8388608.0f;
        if (yr > 8388607.0f) yr = 8388607.0f;
        if (yr < -8388608.0f) yr = -8388608.0f;
        buf[n] = (int32_t)yl << 8;
        buf[frames + n] = (int32_t)yr << 8;
        d += step;
        if (d < 0.0f)
            d += (float)WIN;
        else if (d >= (float)WIN)
            d -= (float)WIN;
        /* (-tiny + WIN can round to WIN in float: harmless, gain() clamps its index, the reads stay in the ring) */
        wpos = (wpos + 1) & (RING - 1);
    }
    dly = d;
}

#ifdef KS_AB_OLD
void oks_process(int32_t *buf, int frames)
{
    if (ks_ctl.init != KS_INIT)
        ks_init();
    ks_process(buf, frames);
}

/* A/B switch away from this engine: straight to its exact bypass (no fade-out writes) */
void oks_quiesce(void)
{
    fade = 0;
}
#else
/* The trampoline lands here with the stock pipeline's arguments. */
void ks_fill(int32_t *b0, int32_t *b1, int mode)
{
    ((fill_fn)KS_STOCK_FILL)(b0, b1, mode);
    if (ks_ctl.init != KS_INIT)
        ks_init();
    ks_process(b0, 16);
    ks_ctl.blocks++;
}
#endif
