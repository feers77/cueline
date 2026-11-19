/* SPDX-License-Identifier: Apache-2.0
 *
 * gr1meter_ring.inc -- GR1METER (DEV): the LINK phase meter's WAVEFORM view on the VDC4 layer GR1 (the ring
 * half; the register half is gr1meter_regs.inc). #included by v2.c right before master_mini under -DV2_GR1METER
 * (needs V2_HWBAND + V2_BDIRECT). Deck probes V4n45g1 / g2 (work/gr1/PROBE_READY): GR1 scans SDRAM through its
 * own window, K1 shows it through GR3, GR2 must blend (DISP_SEL 3) for GR1 to show outside the band's window.
 *
 *   GR1  window x 18..781 (- 0..3, the hwband AB3 trick), y 66..117, RGB565, scanning a RING in SDRAM
 *        0x0C960000..0x0C98D800 (896 columns stored twice, 3584 B a row, 52 rows; WWATCH-verified free).
 *        Ring column a = the master mini-wave's ABSOLUTE column a (master_mini's raw_col map, x 256 scale):
 *        rows 78..106 = the mirrored MMC colours (the same cache the CPU path copies), rows 68..77 / 107..116 =
 *        the master's grid tick of that column (bars red, beats #A6A6A6, as mm_tick), the rest black.
 *        Scroll = master_mini's own `first` (SMOOTHWAVE's smoothed position): FLM2 = ring + 2 * slot(first) & ~7
 *        and the window moved left by the remainder -- committed at the same vsync as the GR3 buffer that holds
 *        the CPU-drawn parts of the same frame (labels, the 38-px fade, the playhead), so they stay locked.
 *   GR3  the strip x (lx + MM_FADE)..rx, rows 66..117 holds the key 0x0001 under the playhead -- only in a frame
 *        whose ring holds every column it shows. Any other frame draws the strip on the CPU exactly as before
 *        (the same pixels): a zoom / data / look change or a jump rebuilds the ring over a few frames while the
 *        CPU meter shows, then the hole comes back. Columns the panel may still show from the previous frame
 *        are never written (a write that could alias them waits a frame, keyed off).
 * Only in METERDIRECT frames (md_on: player, own track, no pop-up / overlay) of the WAVEFORM view with a master
 * wave, UTILITY HW BAND LAYER ON, not UPD_STATE. PHASE / 4 BARS / grid-only stay CPU.
 */
#ifndef V2_HWBAND
#error "V2_GR1METER needs V2_HWBAND"
#endif
#ifndef V2_BDIRECT
#error "V2_GR1METER needs V2_BDIRECT"
#endif
#if defined(V2_GR1PROBE)
#error "V2_GR1METER replaces V2_GR1PROBE"
#endif
#define GR1 0xFFFF7600u
#ifdef V2_GR1PRECOMP
/* PRECOMP (V4n49s): the deck's GR1 read goes through scaler 0's UP-scaler (stock, can not be switched off: its
 * register writes never take): input line L shows on panel rows 25 + 2L and 26 + 2L, input column c on panel x 1 + c,
 * only x 1..640. So the ring holds what the panel must show, pre-compensated: stored row i = input line
 * G1P_L0 + i = panel row 65 + 2i (the meter rows 65..118 = lines 20..46, half vertical resolution), FLM2 at line 0
 * (G1P_L0 rows before the copy: never shown), input column 0 = absolute column first - 17. The deck ignores the
 * window shift (AB3) and STA_POS, so 1-px steps come from FOUR copies of the ring, copy k holding column a at slot
 * a + k: the base is 8-byte aligned in the copy that puts column first - 17 on a 4-px boundary. No half ring. */
#ifdef V2_GR1PC1
/* V4n55u: VERTICAL 1:1 (deck V4n54t: the wave half as tall, centred -- no line doubling active once scaler 0 is left
 * alone): input line L shows on panel row G1P_Y0 + L, G1P_Y0 = 58 from V4n54t's centred, 2:1-compressed wave (its
 * line 33.5 sat on the centre row 92). Lines 7..60 = panel rows 65..118. 54 rows x 4 copies need 556 KB: the ring
 * runs 0x0C960000..0x0C9E7D80 (Z3 + Z4, WWATCH-checked). Horizontal as V4n54t. */
#define G1_N 648			/* 640 read + 8 (V4n55u2: row pitch 4 x 648 = 2592 B = 81 x 32 -- u's 2576 was not a
					 * multiple of 32: the deck's diagonal hatch) */
#define G1P_Y0 58
#define G1P_VS 1
#define G1P_L0 7
#define G1P_ROWS 53			/* lines 7..59 = panel rows 65..117; 4 copies end at 0x0C9E6280 (WWATCH-checked) */
#else
#define G1_N 704			/* ring period (columns): 640 read + 64, a multiple of 4 (V4n54t; was 832) */
#define G1P_Y0 22			/* panel row of input line 0 (scaler 0's line doubling: 2 rows a line). V4n55t3:
					 * 22, measured on deck 3 with t2's line pattern (line 22 on the strip's top row 66,
					 * the white lines 30 / 40 on rows ~83 / ~102); t had 25 (from the scaler's P_VS) */
#define G1P_VS 2
#define G1P_L0 19			/* the first input line stored (panel row 60) */
#define G1P_ROWS 33			/* lines 17..49 (V4n54t; was 20..47: the deck showed white rows past them) */
#endif
#ifdef V2_SC0BYP
#define G1P_XR 782			/* V4n59s: scaler 0 at 1:1 / 800 px (test) */
#else
#define G1P_XR 641			/* the scaler's output ends at panel x 640 */
#endif
#define G1P_COPY (G1P_ROWS * 4 * G1_N)	/* bytes a copy (92,928; 4 copies end at 0x0C9BAC00) */
#else
#define G1_N 896			/* ring period (columns) */
#endif
#define G1_X WAVE_X0			/* 18 */
#define G1_WIN WAVE_N			/* 764: x 18..781 */
#define G1_WW (G1_WIN + 4)		/* 768 read from the aligned slot (window moved left by 0..3) */
#define G1_Y 66
#define G1_H 52				/* y 66..117 */
#define G1_S (4 * G1_N)			/* 3584 B a ring row */
#define G1_RS (2 * G1_N)		/* u16 a ring row */
#define G1_PHYS 0x0C960000u		/* .. 0x0C98D800 */
#define G1_CPU ((volatile u16 *)(G1_PHYS | 0x20000000u))	/* uncached: the VDC reads SDRAM */
#define G1_PHYS2 0x0C98E000u		/* MSUB: the half-phase ring .. 0x0C9BB800 (the rest of Z3, WWATCH-verified) */
#define G1_CPU2 ((volatile u16 *)(G1_PHYS2 | 0x20000000u))
#define G1_BUDGET 192			/* ring columns a frame at most */
#define G1_HOLD_MS 1000

static int md_on;		/* METERDIRECT (defined with BDIRECT further down; a tentative definition here) */
static int hb_on;		/* hwband.inc */
static u32 pf_t0;		/* paint_frame's start after wait_latch */
static int g1_on;		/* GR1 programmed */
static int g1_seen;		/* this frame wants GR1 (master_mini in a METERDIRECT WAVEFORM frame) */
static int g1_key_now;		/* this frame's strip holds the key (ring complete for it) */
static int g1_half;		/* MSUB: this frame shows the half-phase view (master_mini) */
static int g1_kprev;
#ifdef V2_GR1CAL
/* DEV-only flag, off by default (-DV2_GR1CAL). m3 calibration (deck m1 / m2 green): for G1_CAL_MS after every GR1 setup the ring holds 48-px colour bars
 * instead of the wave -- BLACK, RED, GREEN, BLUE, WHITE, YELLOW, CYAN, MAGENTA (repeating, scrolling with the
 * master) -- so the camera shows how GR1 renders known RGB565 values; then the wave (a normal rebuild) */
#ifdef V2_GR1PRECOMP
#ifdef V2_SC0BYP
#define G1_CAL_MS 600000	/* V4n59s: the pattern for 10 min (the PRECOMP wave constants assume the up-scaler) */
#else
#define G1_CAL_MS 5000		/* V4n55u2: 5 s of the mapping pattern after a setup / a local load */
#endif
#else
#define G1_CAL_MS 15000		/* m4: 15 s from the first keyed frame after a setup / a local load */
#endif
static u32 g1_cal_t0, g1_cal_ld;
static int g1_cal;
static const u16 G1_CALC[8] = { 0x0000, 0xF800, 0x07E0, 0x001F, 0xFFFF, 0xFFE0, 0x07FF, 0xF81F };
#endif		/* the last committed frame held the key: its columns [g1_pa0, g1_pa1) may be on the panel */
static s32 g1_lo, g1_hi;	/* columns [g1_lo, g1_hi) valid in the ring (hi - lo <= G1_N) */
static s32 g1_w0, g1_a0, g1_a1, g1_pa0, g1_pa1;
static u32 g1_rkey, g1_hold;
u32 v2_g1_on, v2_g1_setups, v2_g1_offs, v2_g1_why, v2_g1_frames, v2_g1_cols, v2_g1_gr3re, v2_g1_stuck, v2_g1_vbuf,
    v2_g1_keyed, v2_g1_rebuilds, v2_g1_waits, v2_g1_g2sel;

struct g1ctx { const volatile u16 *e; u32 n; int sc, w8, cy; s32 first; const volatile u8 *r0; u16 blk; };

static u32 g1_slot(s32 a)
{
	u32 u = (u32)a + (0x40000000u - 0x40000000u % G1_N);
	return u % G1_N;
}

/* the master's grid ticks of columns [a0, a1) -> mk (1 beat, 2 bar): master_mini's tick loops on columns */
/* BANDFLICK rule 3 (v2.c BARS_ONLY_SC256, work/bandflick/bandcol.h bf_tick_on): zoomed out only the bar heads,
 * as the CDJ-3000 and the CPU meter -- a 1-px beat comb every 3-6 px stepping whole px reads as flicker */
#define G1_TICK_ON(bar, sc) ((bar) || !BARS_ONLY_SC256((u32)(sc)))	/* = BANDFLICK bf_tick_on */
#define G1MK(c2, v) do {	/* whole view: column c2 >> 1; half view: (c2 - 1) >> 1 (MSUB, as master_mini) */ \
		s32 cw_ = (s32)((c2) >> 1), ch_ = ((s32)(c2) - 1) >> 1; \
		if (cw_ >= a0 && cw_ < a1) mk[cw_ - a0] = (u8)((mk[cw_ - a0] & 0xF0) | (v)); \
		if (ch_ >= a0 && ch_ < a1) mk[ch_ - a0] = (u8)((mk[ch_ - a0] & 0x0F) | (v) << 4); \
	} while (0)
static void g1_ticks(const struct g1ctx *c, s32 a0, s32 a1, u8 *mk)
{
	u32 ms0 = a0 > 0 ? udiv((u32)a0 * (u32)c->sc * 5, 192) : 0, j, t, gi, cnt;
	s32 col;
	for (j = 0; j < (u32)(a1 - a0); j++)
		mk[j] = 0;
	if (c->w8 && mm.ggn >= 2 && mm.gst16) {
		j = ms0 > mm.gt1 ? udiv((ms0 - mm.gt1) * 16, mm.gst16) : 0;
		for (; j < mm.ggn; j++) {
			u32 c2;
			t = mm.gt1 + ((j * mm.gst16) >> 4);
			c2 = udiv(udiv(t * 12, 5) * 32, (u32)c->sc);
			col = (s32)(c2 >> 1);
			if (((s32)c2 - 1) >> 1 >= a1)
				break;
			if (col >= a0 - 1 && G1_TICK_ON(((mm.gbib + 3 + j) & 3) == 0, c->sc))
				G1MK(c2, ((mm.gbib + 3 + j) & 3) == 0 ? 2 : 1);
		}
	} else if (!c->w8 && c->r0) {
		const volatile u8 *g0 = grid_at(ms0, &gi, &cnt);
		for (j = gi; g0 && j < cnt; j++) {
			u32 c2;
			t = gms(g0 + 20 * j);
			c2 = udiv(udiv(t * 12, 5) * 32, (u32)c->sc);
			col = (s32)(c2 >> 1);
			if (((s32)c2 - 1) >> 1 >= a1)
				break;
			if (col >= a0 - 1 && G1_TICK_ON(u16be(g0 + 20 * j) == 1, c->sc))
				G1MK(c2, u16be(g0 + 20 * j) == 1 ? 2 : 1);
		}
	}
}

static void g1_mmc(const struct g1ctx *c, s32 a)	/* MMC column a (as master_mini's cache loop) */
{
	u32 sl = (u32)a & (MMC_N - 1);
	int d;
	if (MMC_TAG[sl] != (u32)a) {
		u16 cb[HALF + 2];
		int top = col_prof((int)(a - c->first), c->e, c->n, c->first, c->sc, cb);
		for (d = 0; d <= 14; d++) {
			int dd = (d * WAVE_H) / 14;
			MMC[d * MMC_N + sl] = dd <= top ? cb[dd] : wc_bg;
		}
		MMC_TAG[sl] = (u32)a;
		v2_mm_cols++;
	}
}
/* ring column a, both copies, in the whole ring (MMC a, ticks) and the half ring (MMC a / a + 1 blended at 1/2,
 * the half view's ticks); mk: low nibble whole-view tick (1 beat, 2 bar), high nibble half-view tick */
#ifdef V2_GR1PRECOMP
static void g1_col(const struct g1ctx *c, s32 a, int mk)	/* PRECOMP: the 4 shifted copies, panel rows 65 + 2i */
{
	u32 sl = (u32)a & (MMC_N - 1);
	int mw = mk & 15, i, k;
	u16 tw = mw ? dm(mw == 2 ? C_RED : 0xA534) : c->blk, col[G1P_ROWS];
	g1_mmc(c, a);
	for (i = 0; i < G1P_ROWS; i++) {
		int dy = G1P_Y0 + G1P_VS * (G1P_L0 + i) - c->cy;	/* panel row of input line G1P_L0 + i */
#ifdef V2_GR1CAL
		if (g1_cal) {	/* V4n55u2 DEV mapping pattern: input line L = colour L % 4 (red, green, blue, yellow),
				 * every 10th line white; every 64th absolute column black, every 256th magenta */
			static const u16 LC[4] = { 0xF800, 0x07E0, 0x001F, 0xFFE0 };
			int L = G1P_L0 + i;
			col[i] = !(a & 255) ? 0xF81F : !(a & 63) ? 0x0000 : L % 10 == 0 ? 0xFFFF : LC[L & 3];
			continue;
		}
#endif
		if (dy >= -14 && dy <= 14)
			col[i] = MMC[(dy < 0 ? -dy : dy) * MMC_N + sl];
		else if ((dy >= -24 && dy < -14) || (dy >= 15 && dy < 25))
			col[i] = tw;
		else
			col[i] = c->blk;
	}
	for (k = 0; k < 4; k++) {
		volatile u16 *p = G1_CPU + k * (G1P_COPY / 2) + g1_slot(a + k);
		for (i = 0; i < G1P_ROWS; i++, p += G1_RS) {
			p[0] = col[i];
			p[G1_N] = col[i];
		}
	}
	v2_g1_cols++;
}
#else
static void g1_col(const struct g1ctx *c, s32 a, int mk)
{
	u32 sl = (u32)a & (MMC_N - 1), sl1 = (sl + 1) & (MMC_N - 1), s = g1_slot(a);
	volatile u16 *p = G1_CPU + s, *q = G1_CPU2 + s;
	int mw = mk & 15, mh = mk >> 4, y;
	u16 tw = mw ? dm(mw == 2 ? C_RED : 0xA534) : c->blk, th = mh ? dm(mh == 2 ? C_RED : 0xA534) : c->blk;
#ifdef V2_GR1CAL
	if (g1_cal) {
		u16 v = G1_CALC[udiv((u32)a, 48) & 7];
		for (y = 0; y < G1_H; y++, p += G1_RS, q += G1_RS)
			p[0] = p[G1_N] = q[0] = q[G1_N] = v;
		v2_g1_cols++;
		return;
	}
#endif
	g1_mmc(c, a);
	g1_mmc(c, a + 1);
	for (y = G1_Y; y < G1_Y + G1_H; y++, p += G1_RS, q += G1_RS) {
		int dy = y - c->cy;
		u16 v, h;
		if (dy >= -14 && dy <= 14) {
			int ad = dy < 0 ? -dy : dy;
			v = MMC[ad * MMC_N + sl];
			h = ph_blend(v, MMC[ad * MMC_N + sl1], 2);
		} else if ((dy >= -24 && dy < -14) || (dy >= 15 && dy < 25)) {
			v = tw;
			h = th;
		} else
			v = h = c->blk;
		p[0] = v;
		p[G1_N] = v;
		q[0] = h;
		q[G1_N] = h;
	}
	v2_g1_cols++;
}
#endif

/* master_mini, after its cache key: the ring for the strip x kx..rx (columns [first + kx - 18, first + rx - 18)).
 * 1 = complete: GR3 keys that part this frame (master_mini skips drawing it). */
static int g1_frame(const struct g1ctx *c, int kx, int rx, u32 rkey)
{
	s32 A0 = c->first + (kx - G1_X), A1 = c->first + (rx - G1_X), n, i;
	int budget = G1_BUDGET;
	u8 mk[G1_BUDGET];
	g1_key_now = 0;
	if (UPD_STATE || KILL_HB || !md_on || kx >= rx || A1 - A0 > G1_N - 64)
		return 0;
	if (!g1_on && (s32)(now_ms() - g1_hold) < 0)
		return 0;
	g1_seen = 1;			/* GR1 on (regs) from this frame; keyed only when the ring is complete */
#ifdef V2_GR1CAL
	if (!g1_on || ld_t0 != g1_cal_ld) {
		g1_cal_ld = ld_t0;
		g1_cal = 1;
		g1_cal_t0 = 0;
	} else if (g1_cal && g1_cal_t0 && now_ms() - g1_cal_t0 >= G1_CAL_MS)
		g1_cal = 0;
	rkey ^= (u32)g1_cal << 31;
#endif
	g1_w0 = c->first;
#ifdef V2_GR1PRECOMP
	{	/* V4n54t: the whole ring area black once (rows / columns the scaler may read that no column wrote) */
		static int clr;
		if (!clr) {
			volatile u32 *z = (volatile u32 *)(G1_PHYS | 0x20000000u);
			u32 j;
			for (j = 0; j < 4 * G1P_COPY / 4; j++)
				z[j] = 0;
			clr = 1;
		}
	}
#endif
	if (rkey != g1_rkey || !g1_on) {	/* new data / look / local load (ld_t0 in the key), or a (re)setup */
		g1_rkey = rkey;
		g1_lo = g1_hi = 0;
	}
	if (g1_hi <= g1_lo || A1 <= g1_lo || A0 >= g1_hi) {	/* nothing usable: a rebuild */
		if (g1_kprev) {		/* the panel may still show the last keyed frame: wait one frame, CPU strip */
			v2_g1_waits++;
			return 0;
		}
		g1_lo = g1_hi = A0;
		v2_g1_rebuilds++;
	} else if (g1_kprev && ((A1 > g1_hi && A1 > g1_pa0 + G1_N) || (A0 < g1_lo && A0 < g1_pa1 - G1_N))) {
		v2_g1_waits++;		/* an entering column would alias one the panel may show: next frame */
		return 0;
	}
	while (g1_hi < A1 && budget) {		/* entering on the right */
		n = A1 - g1_hi < budget ? A1 - g1_hi : budget;
		g1_ticks(c, g1_hi, g1_hi + n, mk);
		for (i = 0; i < n; i++)
			g1_col(c, g1_hi + i, mk[i]);
		g1_hi += n;
		budget -= (int)n;
		if (g1_hi - g1_lo > G1_N)
			g1_lo = g1_hi - G1_N;
	}
	if (g1_lo > A0 && budget) {		/* entering on the left (a step back / a rebuild's tail) */
		n = g1_lo - A0 < budget ? g1_lo - A0 : budget;
		g1_ticks(c, g1_lo - n, g1_lo, mk);
		for (i = n - 1; i >= 0; i--)
			g1_col(c, g1_lo - n + i, mk[i]);
		g1_lo -= n;
		if (g1_hi - g1_lo > G1_N)
			g1_hi = g1_lo + G1_N;
	}
	if (g1_lo > A0 || g1_hi < A1)
		return 0;
	g1_a0 = A0;
	g1_a1 = A1;
#ifdef V2_GR1CAL
	if (g1_cal && !g1_cal_t0)
		g1_cal_t0 = now_ms() | 1;
#endif
	v2_g1_keyed++;
	return g1_key_now = 1;
}
