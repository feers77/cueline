/* SPDX-License-Identifier: Apache-2.0
 *
 * hwband.inc -- V4 Fase 2: the waveform band on the VDC4 hardware layer GR2 (re/VDC4_SCROLL_LAYER.md,
 * re/VDC4_PROBE2.md §4, re/V3_PROGRESS.md "V4 HWBAND"). Quotes firmware addresses
 * (interoperability facts only, no firmware bytes). #included by v2.c under -DV2_HWBAND (needs V2_BDIRECT: the band rows already live in the
 * GR3 buffer, not the canvas).
 *
 * Layout:
 *   GR2  window x 16..783 (768 px), y 122..305 (184 rows), RGB565, scanning a RING in SDRAM:
 *        HB_N = 896 columns, every column stored twice (slot s and s + HB_N), line offset 3584 B.
 *        Everything that scrolls with the music is baked into the ring: waveform, beat ticks, cue / hot-cue /
 *        memory marks, the active loop's wash (and the loop's half-height layout).
 *        Scroll = the base: ring + 2 * slot(first visible column): FLM2 & ~7 (4-px steps) + the window moved
 *        left by the remainder (AB3 GRC_HS, 772 px wide; V4g -- the deck ignores FLM6.STA_POS), 1 px steps.
 *        The period is 128 columns longer than the window, so the columns entering on either side (up to 128
 *        a frame) are written into slots the panel is NOT scanning: no tearing, no ordering hazard.
 *   GR3  the band area x 18..781 holds the key colour 0x0001 (chroma key K1, AB8 0x00000800, proven on the
 *        deck) under the FIXED overlays: playhead, loop / jump pads, MASTER PLAYER, beat-distance numbers,
 *        loop length, ZOOM - GRID; x 0..17 / 782..799 black. Drawn into a GR3 buffer only when its inputs
 *        changed since that buffer last got it (a playing band costs ~nothing on GR3).
 *   Two rings: A 0x0CB38000..0x0CBD9000 (the V3rc8j phase-ring area), B 0x0CA94000..0x0CB35000 (after
 *   w8recv's used range 0x0CA00000..0x0CA90000; the old POP_BAK 0x0CB00000..0x0CB18000, unused since V3rc8w).
 *   A zoom / look / marks / loop change or a jump builds the hidden ring over a few frames (time budget) while
 *   the shown one keeps scrolling (or holds, on a jump), then GR2 switches to it at one vsync.
 *
 * On / off (glitch-free): live only on our PLAYER screen, track loaded with its analysis, no pop-up / stock
 * overlay (BDIRECT's bd_ok), not UPD_STATE, ring ready. Every register write happens at the end of
 * paint_frame (hb_commit), i.e. right before the stock base write of the same frame: GR2 base / setup / off
 * and GR3 key commit at the same vsync as that frame's GR3 buffer. A frame that does not keep it live
 * (hb_seen 0) turns it off in that same frame -- and that frame's band is the software one (BDIRECT into the
 * GR3 buffer, or the canvas), so the key never shows over a frame without the hole's content. After an off
 * the band stays software for HB_HOLD_MS (no on/off flapping under blinking stock banners). Off also on
 * not-owned frames, UPD_STATE (v2_paint / frame_check) and a watchdog. Re-asserts GR3's key if stock's VDC
 * Start (0x0E5265FC, flip init path) put DISP_SEL back to 2.
 */
#ifndef V2_BDIRECT
#error "V2_HWBAND needs V2_BDIRECT"
#endif
#if defined(V2_HWS2) || defined(V2_HWPROBE)
#error "V2_HWBAND excludes the VDC4 probes"
#endif

#define HWR(a) (*(volatile u32 *)(a))
#define GR2 0xFFFF7700u
#define GR3 0xFFFF7780u
#define VDC_INT1 0xFFFF7A80u		/* read only: INT_STA8 (VBUFERR4) bit 0 */
#define VDC_INT2 0xFFFF7A84u		/* read only: INT_STA5..7 (VBUFERR1..3) bits 20/24/28 */
#define HB_KEYREG 0x00000800u		/* K1: RGB565 0x0001 -> (G 00, B 08, R 00) -- proven on the deck */
#define HB_KEY 0x0001			/* the hole's colour on GR3 */
#define HB_N 896			/* ring period (columns) */
#define HB_WIN 768			/* GR2 window width */
#define HB_SLACK (HB_N - HB_WIN)	/* 128: columns that can enter a frame without touching scanned slots */
#define HB_X 16				/* window's screen x (2 px left of WAVE_X0: GR3 covers x 16, 17, 782, 783) */
/* V4g: the deck's VDC4 seems to ignore FLM6.STA_POS (V4f moved in 4-px jumps at zoom 1-3). The base stays
 * 8-byte aligned (4-px steps) and the remainder r = 0..3 moves the window LEFT instead (AB3 GRC_HS, 1-px
 * granularity): window x 16 - r .. 787 - r, 772 px read from the aligned slot. GR3 is opaque (black) at
 * x 0..17 / 782..799, so the extra columns (some not valid in the ring) never show; the scanned span is
 * 772 of 896 slots, the extra ones only ever land under GR3. -DV2_HWBAND_STAPOS: the V4f STA_POS path. */
#ifdef V2_HWBAND_STAPOS
#define HB_WW HB_WIN
#define HB_AB3(a) (((143u + HB_X) << 16) | HB_WW)
#else
#define HB_WW (HB_WIN + 4)
#define HB_AB3(a) ((((143u + HB_X) - (((a) & 7) >> 1)) << 16) | HB_WW)
#endif
#define HB_S (4 * HB_N)			/* 3584 B a ring row (2 x 896 px; 112 x 32) */
#ifdef V2_GR2METER
#define HB_FLM2(a) (((a) - (u32)GM_ROWS * HB_S) & ~7u)	/* GR2METER: the window starts GM_ROWS lines higher */
#else
#define HB_FLM2(a) ((a) & ~7u)
#endif
#define HB_RS (2 * HB_N)		/* u16 a ring row */
#define HB_HOLD_MS 1000
#define HB_MINCOLS 64			/* rebuild columns a frame at least ... */
#define HB_BUDGET_MS 10			/* ... and more while the paint is younger than this */
#define HB_FINISH 320			/* a rebuild this close to complete finishes in the frame */
/* v4.2 HBPOOL (work/v42cache/CACHE_DONE): a pool of ring buffers. Slots 0 / 1 are the two rings the logic below
 * has always used (shown + build target); slots 2.. are PARKED rings in free SDRAM (work/rammap/RAMMAP_DONE: 0x0DCAF900..
 * 0x0DF00000, no code reference, 0 accesses in any run) that keep the neighbouring zoom levels' views of the same
 * track / look / marks / loop / grid (the full ring key) warm, so a zoom step swaps a finished ring into the build
 * slot and GR2 shows it in the same frame (was: a rebuild over several frames while the old zoom kept scrolling).
 * A slot swap exchanges the buffers (hb_phys) with the ring state; the ring on the panel (hb_disp) is never swapped
 * or written outside its slack. A detail-data change (hb_ck) drops every parked ring. -DV2_NO_HBPOOL: off. */
#ifndef V2_NO_HBPOOL
#define V2_HBPOOL
#endif
#ifdef V2_HBPOOL
#ifdef V2_GR2METER
/* GR2METER: each ring needs GM_ROWS rows (0x31000 B) right before it (the meter prefix GR2 reads with it): 3 rings.
 * A keeps 0x0CB38000 (prefix 0x0CB07000.., old ring B's area); B, C in the rammap's truly free 0x0DCAF900..0x0DF00000
 * (B prefix 0x0DCB0000, ring 0x0DCE1000; C prefix 0x0DD82000, ring 0x0DDB3000 .. 0x0DE54000) */
#define HB_NR 3
static u32 hb_phys[HB_NR] = { 0x0CB38000u, 0x0DCE1000u, 0x0DDB3000u };
#else
#define HB_NR 5
static u32 hb_phys[HB_NR] = { 0x0CB38000u, 0x0CA94000u, 0x0DCB0000u, 0x0DD51000u, 0x0DDF2000u };	/* .. 0x0DE93000 */
#endif
#else
#define HB_NR 2
#ifdef V2_GR2METER
static u32 hb_phys[HB_NR] = { 0x0CB38000u, 0x0DCE1000u };
#else
static u32 hb_phys[HB_NR] = { 0x0CB38000u, 0x0CA94000u };
#endif
#endif
#define HB_CPU(r) ((volatile u16 *)(hb_phys[r] | 0x20000000u))	/* uncached: the VDC reads SDRAM */

enum { HB_OFF_PATH = 1, HB_OFF_NOTOWNED, HB_OFF_UPD, HB_OFF_WDOG };

struct hbr { u32 key; s32 lo, hi; int sh;	/* columns [lo, hi) valid (hi - lo <= HB_N) for key */
	u32 look;	/* V4m2 (log): 8 | wblue << 2 | wave_type the ring was built for */
#ifdef V2_HWSUB
	int ph;		/* V4s: 1 = the half-phase ring (column a holds a + 1/2) */
#endif
};
static struct hbr hbr[HB_NR];
static int hb_on;		/* GR2 + key programmed (live from the vsync after the commit) */
static int hb_seen;		/* this frame keeps it live (hb_frame), committed by hb_commit */
static int hb_cur = -1;		/* the ring GR2 shows (or will show at the commit) */
static int hb_disp = -1;	/* the ring the panel may be scanning right now (writes must avoid its window) */
static s32 hb_vis;		/* the window start (absolute column) of the base the panel scans */
static s32 hb_pend_w0;		/* this frame's window start for hb_cur */
static u32 hb_last_a, hb_gk[2], hb_hold, hb_nopaint;
static u32 hb_ck, hb_rf_left;
static s32 hb_rf_c;
/* HUD / bench counters */
u32 v2_hb_setups, v2_hb_offs, v2_hb_why, v2_hb_swaps, v2_hb_cols, v2_hb_rcols, v2_hb_stuck, v2_hb_gr3re,
    v2_hb_gr3d, v2_hb_vbuf, v2_hb_wait, v2_hb_live;
#ifdef V2_HWSUB
u32 v2_hb_half;		/* V4s: frames shown on the half-phase ring (bench) */
#endif

/* the frame's column context */
struct hbm { s32 c0; u16 col; u8 kind, k; };	/* kind 0 cue (bottom triangle), 1 memory, 2 hot cue */
static struct {
	const volatile u16 *e;
	u32 n;
	int sh, sc, shrink;
	s32 la, lb;			/* the active loop's columns (la > lb: none) */
	const volatile u8 *g;		/* beat grid records (20 B, ms at +4), 0 = none */
	u32 gn;
	int nm;
	struct hbm m[2 * N_MARKS];
} hc;

static u32 hb_slot(s32 a)	/* a mod HB_N, any sign */
{
	u32 u = (u32)a + (0x40000000u - 0x40000000u % HB_N);
	return u % HB_N;
}

/* first grid index whose beat column is >= a */
static u32 hb_grid_find(s32 a)
{
	u32 lo = 0, hi = hc.gn;
	while (lo < hi) {
		u32 m = (lo + hi) >> 1;
		s32 col = bcol((s32)udiv(gms(hc.g + 20 * m) * 3, 20), hc.sh);
		if (col < a)
			lo = m + 1;
		else
			hi = m;
	}
	return lo;
}

#ifdef V2_HWSUB
/* V4s: the waveform part of column a (col_prof + prof_col, the loop pads' half height) into dst; t = scratch */
static void hb_wave(s32 a, u16 *dst, u16 *t)
{
	u16 cb[HALF + 2], bg = wc_bg;
	int top = col_prof(a, hc.e, hc.n, 0, hc.sc, cb), y;
	if (!hc.shrink) {
		prof_col(dst, cb, top);
		return;
	}
	prof_col(t, cb, top);
	for (y = 0; y < RING_H; y++) {	/* band_copy's half height (loop pads): rows SH_Y0 .. SH_Y0 + 91 = even rows */
		int sy = y - SH_Y0;
		dst[y] = sy >= 0 && sy < RING_H / 2 ? t[2 * sy] : bg;
	}
}
/* the layers of column a over out (wave_band's order: loop wash on the background, beat ticks, marks), from
 * grid index gi; returns the grid index after column a. Applied after the half-phase blend, at the whole
 * column, as the software SUBPX band draws them over its phase ring (ticks / marks stay 1-px crisp). */
static u32 hb_over(s32 a, u16 *out, u32 gi)
{
	u16 bg = wc_bg, wash = in_wave ? 0xFF18 : 0x4208;
	int ty0 = (hc.shrink ? 127 : 141) - BAND_Y0, ty1 = (hc.shrink ? 232 : 279) - BAND_Y0, y, j;
	if (a >= hc.la && a <= hc.lb)
		for (y = 0; y < RING_H; y++)
			if (out[y] == bg)
				out[y] = wash;
#else
/* columns [a0, a1) of ring r into both copies (ascending). Mirrors band_copy (+ wash / half height),
 * the tick loop and the mark loop of wave_band for one column at a time. */
static void hb_cols(int r, s32 a0, s32 a1)
{
	volatile u16 *R = HB_CPU(r);
	u16 cb[HALF + 2], nb[RING_H], out[RING_H];
	u16 bg = wc_bg, wash = in_wave ? 0xFF18 : 0x4208;
	u32 s = hb_slot(a0), gi = hc.g ? hb_grid_find(a0) : 0;
	s32 a;
	int ty0 = (hc.shrink ? 127 : 141) - BAND_Y0, ty1 = (hc.shrink ? 232 : 279) - BAND_Y0;
	for (a = a0; a < a1; a++, s = s + 1 == HB_N ? 0 : s + 1) {
		int top = col_prof(a, hc.e, hc.n, 0, hc.sc, cb), y, j;
		const u16 *src = nb;
		prof_col(nb, cb, top);
		if (hc.shrink) {	/* band_copy's half height (loop pads): rows SH_Y0 .. SH_Y0 + 91 = even rows */
			for (y = 0; y < RING_H; y++) {
				int sy = y - SH_Y0;
				out[y] = sy >= 0 && sy < RING_H / 2 ? nb[2 * sy] : bg;
			}
			src = out;
		}
		if (a >= hc.la && a <= hc.lb) {
			for (y = 0; y < RING_H; y++)
				out[y] = src[y] == bg ? wash : src[y];
			src = out;
		}
		if (src != out)
			cp16(out, nb, RING_H);
#endif
		/* beat ticks: 1 px, 10 tall, bars red, the others #A6A6A6 (every beat in this column, in order) */
		while (gi < hc.gn) {
			const volatile u8 *g = hc.g + 20 * gi;
			s32 col = bcol((s32)udiv(gms(g) * 3, 20), hc.sh);
			u16 tc;
			if (col > a)
				break;
			gi++;
			if (col < a)
				continue;
			if (u16be(g) != 1 && BARS_ONLY_SH(hc.sh))	/* BANDFLICK: bar heads only when zoomed out (the 3000) */
				continue;
			tc = dm(u16be(g) == 1 ? C_RED : 0xA534);
			for (y = 0; y < 10; y++)
				out[ty0 + y] = out[ty1 + y] = tc;
		}
		/* marks, in wave_band's order (cue / memory, then hot cues on top) */
		for (j = 0; j < hc.nm; j++) {
			const struct hbm *m = &hc.m[j];
			s32 dx = a - m->c0;
			if (dx < -4 || dx > 9)
				continue;
			if (m->kind == 0) {		/* tri(x, BAND_Y1 - 6): rows 178.. widths 1..9 */
				int i;
				for (i = 0; i < 5; i++)
					if (dx >= -i && dx <= i)
						out[RING_H - 6 + i] = dm(0xFD06);
				continue;
			}
			if (dx == 0)			/* vrun(x, BAND_Y0 + 2, RING_H - 4) */
				for (y = 2; y < RING_H - 2; y++)
					out[y] = dm(m->col);
			if (m->kind == 1) {		/* tri_dn(x, BAND_Y0): rows 0..4, widths 9..1 */
				int i;
				for (i = 0; i < 5; i++)
					if (dx >= -4 + i && dx <= 4 - i)
						out[i] = dm(m->col);
			} else if (dx >= 0) {		/* cue_badge(x, BAND_Y0, k, col): 10 x 11 + its letter */
				const struct glyph *g = glyph(&f_t, 'A' + m->k);
				int gc, rr;
				for (y = 0; y < 11; y++)
					out[y] = dm(m->col);
				if (!g)
					g = glyph(&f_t, '?');
				if (!g)
					continue;
				gc = dx - (5 - g->adv / 2) - g->xoff;
				if (gc < 0 || gc >= g->w)
					continue;
				set_ramp(C_BLACK, m->col);
				for (rr = 0; rr < f_t.h; rr++) {
					const u8 *px = f_t.px + g->off + rr * ((g->w + 1) >> 1);
					int al = (gc & 1) ? (px[gc >> 1] & 15) : (px[gc >> 1] >> 4), yy = 9 - f_t.asc + rr;
					if (al && yy >= 0 && yy < RING_H)
						out[yy] = ramp[al];
				}
			}
		}
#ifdef V2_HWSUB
	return gi;
}
#ifdef V2_HBCHECK
/* DEV proof build only (-DV2_HBCHECK): hb_vmode 1 = hb_put COMPARES the column with both copies in the ring
 * instead of writing it (hb_verify: a ring re-rendered by the normal path, mismatching columns counted) */
static int hb_vmode;
u32 v2_hbk_runs, v2_hbk_cols, v2_hbk_bad, v2_hbk_badun, v2_hbk_last;
#endif
static void hb_put(int r, u32 s, const u16 *out)
{
	volatile u16 *p = HB_CPU(r) + s;
	int y;
#ifdef V2_HBCHECK
	if (hb_vmode) {
		int bad = 0;
		for (y = 0; y < RING_H; y++, p += HB_RS)
#ifdef V2_HBCHECK_MUT
			bad |= p[0] != (out[y] ^ 1) || p[HB_N] != out[y];	/* mutation: the checker must see every column */
#else
			bad |= p[0] != out[y] || p[HB_N] != out[y];
#endif
		v2_hbk_cols++;
		v2_hbk_bad += (u32)bad;
		return;
	}
#endif
	for (y = 0; y < RING_H; y++, p += HB_RS) {
		p[0] = out[y];
		p[HB_N] = out[y];
	}
}
/* columns [a0, a1) (ascending) of the whole-column ring ra and / or the half-phase ring rh (-1 = none), both
 * copies. Half-phase column a = ph_blend(a, a + 1, 2): the software SUBPX phase-2 weights (equal-power with the
 * max clamp between high-contrast neighbours; Z1: 174/174 at every zoom, no soft 220/220) -- shown at window w0 it
 * puts the waveform at w0 + 1/2 column. Joint (both rings): one waveform per column. */
/* V4n Q (deck V4n1: white peaks still blink at zooms 1-2) -> quarter phases (1/4, 3/4) + G1 {192,128}.
 * V4n24 (deck V4n23 video, zoom 1 playing: the band's frame-to-frame difference alternates high / low every
 * frame, 72/12/65/9..; paused 0): two phase rings cannot both keep a 1-px peak's brightness AND move it in
 * equal steps. {192,128} / {128,192} put the light centre at a + 0.4 / a + 0.6: the band moved 0.2 px (ring
 * swap) then 0.8 px (window step) -- two visibly different images taking turns, the shimmer; linear 1/4 / 3/4
 * would invert it (a peak's light is crisp in one phase, smeared in the other). Zooms 1-2 (sh >= 2, the band
 * moves <= ~0.6 px a frame; V4n27z 3000 time span: <= 0.39) now step in whole pixels like the CDJ-3000: both rings hold the SAME unblended
 * columns (q) and hb_frame never selects the half phase there, so every displayed image is an exact 1-px
 * shift of the previous one (no brightness / shape change). Zooms 3-4 (sh < 2): whole + half (174/174). */
static void hb_cols(int ra, int rh, s32 a0, s32 a1)
{
	u16 b0[RING_H], b1[RING_H], o[RING_H], *c = b0, *nx = b1;
	u32 s = hb_slot(a0), gi = hc.g ? hb_grid_find(a0) : 0, g2 = 0;
	/* V4n32z (deck V4n31a: white peaks flash at zoom keys 3-4 (sh 0-1) while playing; emu: the half-phase ring
	 * swaps every 1-2 vsyncs, white px 652 / 520 alternating, 3-5 % of the band repainted): every zoom now steps
	 * in whole pixels like the CDJ-3000 (its own renderer: x = ms x 0.15 x scale, whole px) -- both rings hold the
	 * same unblended columns; the half-phase blend is kept below but never selected */
	int q = 1;
	s32 a;
	hb_wave(a0, c, o);
	for (a = a0; a < a1; a++, s = s + 1 == HB_N ? 0 : s + 1) {
		int y;
		if (rh >= 0 && !q) {
			u16 *t;
			hb_wave(a + 1, nx, o);
			for (y = 0; y < RING_H; y++)
				o[y] = ph_blend(c[y], nx[y], 2);
			g2 = hb_over(a, o, gi);
			hb_put(rh, s, o);
			if (ra >= 0) {
				hb_over(a, c, gi);
				hb_put(ra, s, c);
			}
			t = c; c = nx; nx = t;
		} else {
			if (rh >= 0) {		/* q: the half ring = the same whole columns */
				cp16(o, c, RING_H);
				g2 = hb_over(a, o, gi);
				hb_put(rh, s, o);
			}
			if (ra >= 0) {
				g2 = hb_over(a, c, gi);
				hb_put(ra, s, c);
			}
			if (a + 1 < a1)
				hb_wave(a + 1, c, o);
		}
		gi = g2;
	}
	v2_hb_cols += (u32)(a1 - a0);
}
#else
		{
			volatile u16 *p = R + s;
			for (y = 0; y < RING_H; y++, p += HB_RS) {
				p[0] = out[y];
				p[HB_N] = out[y];
			}
		}
	}
	v2_hb_cols += (u32)(a1 - a0);
}
#endif

/* bring ring r toward window [w0, w0 + HB_WIN): render the missing columns (right side first), at most max.
 * guard: the ring is on the panel -- only columns within HB_SLACK of its scanned window hb_vis may be written
 * (their slots are not scanned; the scanned window itself is valid already).
 * Returns the columns still missing (0 = the window is complete). */
#ifdef V2_HWSUB
/* V4s: r2 = the half-phase partner of the whole-column ring r with the same valid range (joint: one waveform
 * per column for both), -1 = r alone (either phase) */
static int hb_extend(int r, s32 w0, int max, int guard, int r2)
#define HB_EXT_COLS(x0, x1) hb_cols(hbr[r].ph ? -1 : r, hbr[r].ph ? r : r2, x0, x1)
#else
static int hb_extend(int r, s32 w0, int max, int guard)
#define HB_EXT_COLS(x0, x1) hb_cols(r, x0, x1)
#endif
{
	struct hbr *R = &hbr[r];
	s32 w1 = w0 + HB_WIN, k;
	if (guard && (w0 - hb_vis > HB_SLACK || hb_vis - w0 > HB_SLACK))
		return HB_WIN;			/* a jump: not in place */
	if (R->hi <= w0 || R->lo >= w1)		/* nothing of the window: start at it */
		R->lo = R->hi = w0;
	if (w1 - R->lo > HB_N)			/* valid range + window within HB_N columns */
		R->lo = w1 - HB_N;
	if (R->hi - w0 > HB_N)
		R->hi = w0 + HB_N;
	k = w1 - R->hi;
	if (k > 0) {
		if (k > max) k = max;
		HB_EXT_COLS(R->hi, R->hi + k);
		R->hi += k;
		max -= k;
	}
	k = R->lo - w0;
	if (k > 0 && max > 0) {
		if (k > max) k = max;
		HB_EXT_COLS(R->lo - k, R->lo);
		R->lo -= k;
	}
#ifdef V2_HWSUB
	if (r2 >= 0) {
		hbr[r2].lo = R->lo;
		hbr[r2].hi = R->hi;
	}
#endif
	return (int)((w1 > R->hi ? w1 - R->hi : 0) + (R->lo > w0 ? R->lo - w0 : 0));
}

/* the frame's marks (wave_band's two passes) and loop, beat grid */
__attribute__((noinline)) static void hb_context(const volatile u16 *e, u32 n, int sh, u32 pos, u32 *lk)
{
	int i, k2;
	u32 cntg = u32be(GRID + 4), rp = u32be(GRID + 0x18);
	hc.e = e;
	hc.n = n;
	hc.sh = sh;
	hc.sc = BSC(sh);	/* V4n27z: 1.6 x 2^sh entries a column (the 3000's time span), absolute columns */
	lp_st = lp_en = -1;
	if (DECK[0xD3] == 3 || DECK[0xD3] == 5)
		for (i = 0; i < N_MARKS; i++) {
			const volatile u8 *r = MARKS + 16 * i;
			u32 st = u32be(r + 8), en = u32be(r + 12);
			if (st != 0xFFFFFFFF && en != 0xFFFFFFFF && en > st) {
				lp_st = (s32)st;
				lp_en = (s32)en;
				break;
			}
		}
	*lk = ((u32)lp_st ^ (u32)lp_en * 0x01000193) + DECK[0xD3];
	hc.la = 1; hc.lb = 0;
	if (lp_en > lp_st) {
		hc.la = bcol(lp_st, sh);
		hc.lb = bcol(lp_en, sh);
	}
	hc.shrink = b_shrink = DECK[0xD3] == 3 || DECK[0xD3] == 5;
	hc.g = 0;
	hc.gn = 0;
	if (cntg && cntg < 8192 && (rp & 0xFF000000) == 0x0F000000) {
		hc.g = (const volatile u8 *)((rp & 0x1FFFFFFF) | 0x20000000);
		hc.gn = cntg;
	}
	hc.nm = 0;
	for (k2 = 0; k2 < 2 * N_MARKS; k2++) {
		int pass = k2 >= N_MARKS;
		const volatile u8 *r;
		u32 st, en;
		i = pass ? k2 - N_MARKS : k2;
		r = MARKS + 16 * i;
		st = u32be(r + 8);
		en = u32be(r + 12);
		if (st == 0xFFFFFFFF || (i >= 1 && i <= N_HOT) != pass)
			continue;
		if (i == 0 && en != 0xFFFFFFFF && en > st)
			continue;		/* the active loop: its wash only */
		hc.m[hc.nm].c0 = bcol((s32)st, sh);
		hc.m[hc.nm].kind = i == 0 ? 0 : i <= N_HOT ? 2 : 1;
		hc.m[hc.nm].col = i == 0 ? 0xFD06 : i <= N_HOT ? hot_col(i, r) : mem_col(r);	/* V4b1: real cue colours */
		hc.m[hc.nm].k = (u8)(i - 1);
		hc.nm++;
	}
	(void)pos;	/* #16: band_numbers takes the beat length from the grid BPM now (no b_epb) */
}

static int hb_sgx = -1;		/* V4n32 (#21): the slip ghost's x this frame, -1 none (slip_gx) */
/* the GR3 band area: key + the fixed overlays (as the BDIRECT block draws them over the software band) */
__attribute__((noinline)) static void hb_gr3(int mlab)
{
	int y;
	wave_on();
	fill(0, BAND_Y0, WAVE_X0, RING_H, C_BLACK);
	fill(WAVE_X0 + WAVE_N, BAND_Y0, W - WAVE_X0 - WAVE_N, RING_H, C_BLACK);
	for (y = BAND_Y0; y < BAND_Y1; y++)
		fill16(fb + y * W + WAVE_X0, WAVE_N, HB_KEY);
	fill(WAVE_X0 + V2_PLAYHEAD - 1, BAND_Y0 + 2, 2, BAND_Y1 - BAND_Y0 - 4,
	     slip_on() ? 0xFF20 : deck_playing() ? C_RED : C_WHITE);
	if (hb_sgx >= 0)	/* V4n32 (#21): the slip ghost -- where the track really is (CDJ-3000 slip state) */
		fill(hb_sgx, BAND_Y0 + 2, 2, BAND_Y1 - BAND_Y0 - 4, C_SLIPG);
	loop_bar(u32be(DECK + 0x68));
	band_extras(mlab);
	wave_off();
	band_numbers_draw();
	zoom_label();
	v2_hb_gr3d++;
}

static void hb_regs_off(void)
{
#ifdef V2_GR1METER
	if (!g1_on)	/* GR1 (gr1meter) still needs GR3's key: it turns it off itself */
#endif
	{
	HWR(GR3 + 0x38) &= ~1u;					/* CK_ON off */
	HWR(GR3 + 0x20) = (HWR(GR3 + 0x20) & ~3u) | 2;		/* DISP_SEL 2 (stock) */
	HWR(GR3) |= 0x10;					/* P_VEN */
	}
	HWR(GR2 + 0x20) = (HWR(GR2 + 0x20) & ~3u) | 1;		/* GR2 pass-through (stock) */
	HWR(GR2 + 0x04) = 0;					/* reads off */
	HWR(GR2) |= 0x11;
}
static void hb_off(int why)
{
	if (!hb_on)
		return;
	hb_regs_off();
	hb_on = 0;
	hb_gk[0] = hb_gk[1] = 0;
	hb_hold = now_ms() + HB_HOLD_MS;
	v2_hb_offs++;
	v2_hb_why = (u32)why;
	/* hb_disp stays until the next frame's wait_latch: the panel scans the ring until that vsync */
}

#ifdef V2_HWSUB
#define HB_QMIN 32			/* the half-phase partner's progressive build: columns a frame at least, */
#define HB_QBUDGET_MS 6			/* and more while the paint is younger than this (not urgent) */
static int hb_miss(int r, s32 w0)	/* columns ring r lacks for window w0 (hb_extend's count, no writes) */
{
	s32 w1 = w0 + HB_WIN, lo = hbr[r].lo, hi = hbr[r].hi;
	if (hi <= w0 || lo >= w1)
		return HB_WIN;
	return (int)((w1 > hi ? w1 - hi : 0) + (lo > w0 ? lo - w0 : 0));
}
#endif
#ifdef V2_HWSUB
static int hb_pend_n;
/* extend ring r (+ its joint partner r2) toward window w0 by the time budget: at least min columns, more while
 * the paint is younger than ms; fin: also finish when <= HB_FINISH are missing or a rebuild has been
 * pending 3 frames; a ring on the panel always completes (its entering columns only). The columns missing. */
__attribute__((noinline)) static int hb_run(int r, s32 w0, int r2, int min, int fin, int ms)
{
	int miss, spent = 0, g = r == hb_disp || (r2 >= 0 && r2 == hb_disp);
	do {
		miss = hb_extend(r, w0, 32, g, r2);
		spent += 32;
	} while (miss && (g || (fin && (miss <= HB_FINISH || hb_pend_n >= 3)) || spent < min ||
			  (int)(now_ms() - pf_t0) < ms));
	return miss;
}
#endif
static u32 hb_addr(int r, s32 w0) { return hb_phys[r] + 2 * hb_slot(w0); }

/* bench (mem / HUD): view latency = frames from a view change (zoom / look / marks / loop) until GR2 shows a ring
 * of the new view, 1 = the same frame; histogram, the last one, the columns its build cost */
u32 v2_hb_vlat[16], v2_hb_vlast, v2_hb_vcols;
static u32 hb_vp, hb_vc0;
#ifdef V2_HBPOOL
#define HB_WARM_MS 5			/* warm the parked neighbours while the paint is younger than this ... */
#define HB_WARM_MIN 8			/* ... else at least these columns a neighbour a frame (play adds <= ~4) */
static u32 hb_age[HB_NR], hb_tick;
u32 v2_hb_unpark, v2_hb_park, v2_hb_wcols, v2_hb_wclaim, v2_hb_drop;
#ifdef V2_GR2METER
static void gm_swap(int a, int b);	/* gr2meter.inc: the prefix state travels with the buffer */
#endif
static void hb_swap(int a, int b)	/* slots a, b exchange buffers and ring state (neither on the panel) */
{
#ifdef V2_GR2METER
	gm_swap(a, b);
#endif
	struct hbr *A = &hbr[a], *B = &hbr[b];
	u32 t;
	s32 l, h;
	int i;
	t = A->key; A->key = B->key; B->key = t;
	l = A->lo; A->lo = B->lo; B->lo = l;
	h = A->hi; A->hi = B->hi; B->hi = h;
	i = A->sh; A->sh = B->sh; B->sh = i;
	t = A->look; A->look = B->look; B->look = t;
	i = A->ph; A->ph = B->ph; B->ph = i;
	t = hb_phys[a]; hb_phys[a] = hb_phys[b]; hb_phys[b] = t;
	t = hb_age[a]; hb_age[a] = hb_age[b]; hb_age[b] = t;
}
static int hb_has(int r, u32 key, int sh) { return hbr[r].key == key && hbr[r].sh == sh; }
/* the parked slot to give up: an empty one, else one not holding a wanted view, else the oldest; never kw0 / kw1 */
static int hb_victim(u32 kw0, int s0, u32 kw1, int s1)
{
	int p, v = -1, vs = -1;
	for (p = 2; p < HB_NR; p++) {
		int sc;
		if (hb_has(p, kw0, s0) || hb_has(p, kw1, s1))
			continue;
		sc = !hbr[p].key || hbr[p].hi <= hbr[p].lo ? 3 : 1;
		if (sc > vs || (sc == vs && (s32)(hb_age[p] - hb_age[v]) < 0)) {
			v = p;
			vs = sc;
		}
	}
	return v;
}
/* before the slot logic: (1) an active slot not on the panel whose ring is a wanted neighbour view (and complete
 * data, no refresh pending) is parked instead of being reclaimed; (2) when neither active slot has this view, a
 * parked ring with it moves into the active slot not on the panel */
static void hb_pool_in(u32 key, int sh, u32 kw0, int s0, u32 kw1, int s1)
{
	int r, p, t;
	if (hb_disp >= 0 && !hb_rf_left)
		for (r = 0; r < 2; r++) {
			if (r == hb_disp || hb_has(r, key, sh) || hbr[r].hi <= hbr[r].lo)
				continue;
			if (!hb_has(r, kw0, s0) && !hb_has(r, kw1, s1))
				continue;
			for (p = 2; p < HB_NR; p++)
				if (hb_has(p, hbr[r].key, hbr[r].sh))
					break;
			if (p < HB_NR) {	/* already parked: keep the copy with more valid columns (the parked one is
						 * often the empty build slot an unpark swapped out) */
				if (hbr[p].hi - hbr[p].lo < hbr[r].hi - hbr[r].lo) {
					hb_swap(r, p);
					v2_hb_park++;
				}
				continue;
			}
			p = hb_victim(hbr[r].key, hbr[r].sh, hb_has(r, kw0, s0) ? kw1 : kw0, hb_has(r, kw0, s0) ? s1 : s0);
			if (p < 0)
				continue;
			hb_swap(r, p);
			v2_hb_park++;
		}
	if (hb_has(0, key, sh) || hb_has(1, key, sh))
		return;
	for (p = 2; p < HB_NR; p++)
		if (hb_has(p, key, sh) && hbr[p].hi > hbr[p].lo)
			break;
	if (p == HB_NR)
		return;
	t = hb_disp == 0 ? 1 : hb_disp == 1 ? 0 : hb_cur == 0 ? 1 : 0;
	hb_swap(t, p);
	v2_hb_unpark++;
}
/* after the frame's ring is complete: extend the parked neighbour views toward their windows at this position */
static void hb_warm(const volatile u16 *e, u32 n, u32 pos, int sh, u32 kw0, int s0, u32 kw1, int s1)
{
	int j;
	u32 lk2;
	for (j = 0; j < 2; j++) {
		u32 kw = j ? kw1 : kw0;
		int sw = j ? s1 : s0, p, young;
		s32 w;
		if (!kw || hb_has(0, kw, sw) || hb_has(1, kw, sw))
			continue;	/* in an active slot (the ring just left the panel): hb_pool_in parks it next frame */
		for (p = 2; p < HB_NR; p++)
			if (hb_has(p, kw, sw))
				break;
		w = bcol((s32)pos, sw) - V2_PLAYHEAD - (WAVE_X0 - HB_X);
		if (p == HB_NR) {
			p = hb_victim(kw0, s0, kw1, s1);
			if (p < 0)
				continue;
			hbr[p].key = kw;
			hbr[p].sh = sw;
			hbr[p].look = 8 | (u32)wblue << 2 | (u32)wave_type;
			hbr[p].ph = 0;
			hbr[p].lo = hbr[p].hi = w;
			v2_hb_wclaim++;
		}
		hb_age[p] = ++hb_tick;
		hb_context(e, n, sw, pos, &lk2);
		young = (int)(now_ms() - pf_t0) < HB_WARM_MS;
		do {
			u32 c0 = v2_hb_cols;
			int m = hb_extend(p, w, young ? 32 : HB_WARM_MIN, 0, -1);
			v2_hb_wcols += v2_hb_cols - c0;
			if (!m)
				break;
		} while ((young = (int)(now_ms() - pf_t0) < HB_WARM_MS));
	}
	hb_context(e, n, sh, pos, &lk2);
}
#endif
#ifdef V2_HBCHECK
/* the window [w0, w0 + HB_WIN) of ring r re-rendered by hb_cols in compare mode (the current hc / look) */
static void hb_verify(int r, s32 w0, int un)
{
	u32 b0 = v2_hbk_bad, c0 = v2_hb_cols;
	hb_vmode = 1;
	hb_cols(r, -1, w0, w0 + HB_WIN);
	hb_vmode = 0;
	v2_hb_cols = c0;
	v2_hbk_runs++;
	v2_hbk_last = v2_hbk_bad - b0;
	if (un)
		v2_hbk_badun += v2_hbk_last;
}
#endif

/* the frame's band on the hardware layer, called in the BDIRECT block (fb = the GR3 buffer about to latch,
 * dm_off 1). 1 = live this frame (GR3 band area done); 0 = draw the software band (and it turns off). */
#ifndef V2_HWSUB
static u32 hb_t_ck;	/* the data checksum when the ring under construction started */
#endif
#ifndef V2_HWSUB
static int hb_pend_n;	/* frames a rebuild has been pending */
#endif
static int hb_frame(int mlab, u32 bpm10)
{
	static u32 r_n;
	u32 n = u32be(DECK + 0x74), pos = u32be(DECK + 0x70), z = zkey(), base = WENT, key, lk;
	const volatile u16 *e;
	int sh, tb, miss;
#ifdef V2_HBPOOL
	u32 kw0, kw1;
	int s0, s1;
#endif
#ifdef V2_HBCHECK
	u32 unp0 = 0;
#endif
#ifndef V2_HWSUB
	int T, spent;
#endif
	s32 w0;
	if (!hb_on)
		hb_disp = -1;			/* the off committed at the vsync wait_latch waited for */
	if (UPD_STATE || KILL_HB)		/* V4n36 trace: the HW BAND LAYER kill switch -> the software band */
		return 0;
	wblue = 0;
	if (det_blue && WBLUE) {
		base = WBLUE;
		wblue = 1;
	}
	if (det_holding && !n && r_n)
		n = r_n;
	if (!base || !n || n > 0x200000 || !wave_data_ok())
		return 0;
	r_n = n;
	if (present_mode == PM_PLUS)
		pos = band_pos(pos);
	if (pos > n)
		pos = n;
	e = (const volatile u16 *)((base & 0x1FFFFFFF) | 0x20000000);
	sh = ZSH(z);
	b_sh = sh;
	b_sc = BSC(sh);
	b_anim = 0;
	hb_context(e, n, sh, pos, &lk);
	{	/* the ring key of every view of this frame's data / look at scale s (HBPOOL: the neighbours' too) */
		/* LMKEY: day_full too -- hb_frame runs outside wave_on (day = the chrome's, in_wave 0), so LIGHT and FULL
		 * had the same key while the columns take FULL's palette (wc_*): a LIGHT ring stayed on GR2 / parked */
		u32 kv = (u32)day << 4 | (u32)wave_type << 5 | (u32)wblue << 8 | (u32)in_wave << 9 | (u32)hc.shrink << 10 |
			 (u32)day_full << 11;
		u32 k0 = hmix(base, n), mk = marks_ck(), gk = grid_ck() + (u32)G_OFF;
#define HB_KEYOF(s) (hmix(hmix(hmix(hmix(k0, (u32)((s) + 1) | kv), lk), mk), gk) | 1)
		key = HB_KEYOF(sh);
#ifdef V2_HBPOOL
		s0 = sh + 1;
		kw0 = s0 <= 4 ? HB_KEYOF(s0) : 0;
		s1 = sh - 1;
		kw1 = s1 >= -1 ? HB_KEYOF(s1) : 0;	/* -1: the sixth zoom (V32_Z6 = "at it", not "enabled") */
#endif
#undef HB_KEYOF
	}
	if (hb_disp >= 0 && hbr[hb_disp].key != key) {	/* bench: a view change waiting */
		if (!hb_vp)
			hb_vc0 = v2_hb_cols;
		hb_vp++;
	}
	{	/* MAIN rewrites the detail buffer now and then (and it streams in after a load): refresh the current
		 * ring in place, 24 columns a frame (a ring under construction is refreshed once it is complete) */
		u32 ck = 0, step = (n >> 5) | 1, j;
		for (j = 0; j < n; j += step)
			ck = ck * 33 + e[j];
		static u32 rs_t0, rs_stage;	/* LOADFIX: the scheduled re-read after a load (ld_reread) */
		if (ld_reread(&rs_t0, &rs_stage))
			hb_ck = ck + 1;
		if (ck != hb_ck) {
			hb_ck = ck;
#ifdef V2_HBPOOL
			{	/* the parked views were built from the old data */
				int p;
				for (p = 2; p < HB_NR; p++)
					if (hbr[p].key) {
						hbr[p].key = 0;
						v2_hb_drop++;
					}
			}
#endif
#ifdef V2_HWSUB
			hb_rf_left = HB_N;
#endif
			if (hb_cur >= 0) {
				hb_rf_left = HB_N;
				hb_rf_c = hbr[hb_cur].lo;
			}
		}
	}
	w0 = bcol((s32)pos, sh) - V2_PLAYHEAD - (WAVE_X0 - HB_X);
#ifdef V2_HWSUB
	/* V4s: both rings show this view, one at whole columns (ph 0), one half a column on (ph 1); the frame shows
	 * the one of the position's half (the fraction in Q8 of a column, SMOOTH+'s sub-entry part included, as
	 * the software SUBPX phase) at window w0 -- the band moves in half-pixel steps at the slow zooms. A view
	 * change (zoom / look / marks / loop / data pointer) or a jump the shown ring cannot follow in place is
	 * built in the ring NOT on the panel (time budget as before, the shown one keeps scrolling at its scale
	 * or holds), shown when complete; the other ring then becomes its half-phase partner (progressively, whole
	 * columns meanwhile). In steady play both get the entering columns together (joint: one waveform each). */
	{
		int r, U = -1, V = -1, us[2], joint, half, vok = 0, near, um = 0;
		half = 0;	/* V4n32z: whole pixels at every zoom (was: half phases at sh < 2 -- the white flashes) */
		{	/* Z1: never half a pixel back while moving forward (emu: W-H-W-H / H-W-H at zoom 1, ~1 in 1000
			 * frames): held at the last position until it catches up; reverse / scratch: the step after is shown */
			static s32 lp;
			static int fw;
			s32 P = 2 * w0 + half;
			if (P < lp && lp - P <= 2 && fw) {	/* V4n32z: also a whole pixel back (position jitter at a
								 * column edge: a peak stepping back and forth) */
				w0 = lp >> 1;
				half = lp & 1;
			} else {
				if (P != lp)
					fw = P > lp;	/* the last move's direction (frames without a step keep it) */
				lp = P;
			}
		}
#ifdef V2_HBPOOL
#ifdef V2_HBCHECK
		unp0 = v2_hb_unpark;
#endif
		hb_pool_in(key, sh, kw0, s0, kw1, s1);
#endif
		near = hb_disp < 0 || (w0 - hb_vis <= HB_SLACK && hb_vis - w0 <= HB_SLACK);
		for (r = 0; r < 2; r++)
			us[r] = hbr[r].key == key && hbr[r].sh == sh;
		for (r = 0; r < 2; r++)
			if (!us[r] && r != hb_disp) {	/* free: this view, the other phase than the other ring's */
				hbr[r].ph = us[1 - r] ? !hbr[1 - r].ph : 0;
				hbr[r].key = key;
				hbr[r].look = 8 | (u32)wblue << 2 | (u32)wave_type;
				hbr[r].sh = sh;
				hbr[r].lo = hbr[r].hi = w0;
				us[r] = 1;
			}
		for (r = 0; r < 2; r++) {	/* usable: this view and (on the panel) able to follow in place */
			us[r] = us[r] && (r != hb_disp || near);
			if (us[r]) {
				int m = hb_miss(r, w0);
				if (U < 0 || m < um || (m == um && hbr[r].ph == half)) {
					U = r;
					um = m;
				}
			}
		}
		if (U < 0)	/* F2 audit: cannot happen while hb_disp is -1 / 0 / 1 (the ring off the panel is always
				 * usable); if it ever is not, the software band this frame -- never hbr[-1] */
			return 0;
		V = us[1 - U] ? 1 - U : -1;
		joint = V >= 0 && hbr[U].lo == hbr[V].lo && hbr[U].hi == hbr[V].hi;
		if (joint && hbr[U].ph) {
			r = U; U = V; V = r;	/* joint: U the whole-column ring */
		}
		/* budget: a jump / loop wrap that needs <= HB_FINISH columns and a rebuild pending for 3 frames finish
		 * now -- one longer frame, as the software band's |d| columns -- else HB_MINCOLS, and more while the
		 * paint is younger than HB_BUDGET_MS; a ring on the panel always completes (entering columns only) */
		miss = hb_run(U, w0, joint ? V : -1, HB_MINCOLS, 1, HB_BUDGET_MS);
		hb_pend_n = miss ? hb_pend_n + 1 : 0;
		if (!miss) {
			int show;
			if (V >= 0) {
				vok = joint;
#ifdef V2_HBPOOL
				if (0) {	/* HBPOOL: no half-phase partner -- since V4n32z both rings hold the same whole
						 * columns and the half phase is never shown, so its build was pure cost */
#else
				if (!joint) {	/* the partner: progressively (at least HB_QMIN, more while young) */
#endif
					if (!hb_run(V, w0, -1, HB_QMIN, 0, HB_QBUDGET_MS)) {	/* complete: joint from now on (the common valid range) */
						if (hbr[V].lo > hbr[U].lo) hbr[U].lo = hbr[V].lo; else hbr[V].lo = hbr[U].lo;
						if (hbr[V].hi < hbr[U].hi) hbr[U].hi = hbr[V].hi; else hbr[V].hi = hbr[U].hi;
						if (hb_rf_left)
							hb_rf_left = HB_N;	/* it missed part of a data refresh */
						vok = 1;
						if (hbr[U].ph) {
							r = U; U = V; V = r;
						}
						joint = 1;
					}
				}
			}
			show = hbr[U].ph == half || !vok ? U : V;
			if (show != hb_cur && !(hb_cur >= 0 && hbr[hb_cur].key == key && hbr[hb_cur].sh == sh && near))
				v2_hb_swaps++;		/* a new view / a jump (not a phase step) */
			if (hb_rf_left) {	/* MAIN rewrote the detail buffer: 24 columns a frame, in place (both if joint) */
				int k = hb_rf_left < 24 ? (int)hb_rf_left : 24;
				if (hb_rf_c < hbr[U].lo || hb_rf_c + k > hbr[U].hi)
					hb_rf_c = hbr[U].lo;
				hb_cols(hbr[U].ph ? -1 : U, hbr[U].ph ? U : joint ? V : -1, hb_rf_c, hb_rf_c + k);
				hb_rf_c += k;
				hb_rf_left -= (u32)k;
				if (hb_rf_left)
					pend = 1;	/* LOADFIX: finish it on a paused deck too */
				v2_hb_rcols += (u32)k;
			}
			hb_cur = show;
			v2_hb_half += (u32)hbr[show].ph;
			hb_pend_w0 = w0;
			if (hb_vp) {	/* bench: the new view is on GR2 from this frame's commit */
				v2_hb_vlat[hb_vp > 15 ? 15 : hb_vp]++;
				v2_hb_vlast = hb_vp;
				v2_hb_vcols = v2_hb_cols - hb_vc0;
				hb_vp = 0;
			}
#ifdef V2_HBPOOL
			hb_age[show] = ++hb_tick;
#ifdef V2_HBCHECK
			if (!hb_rf_left && (unp0 != v2_hb_unpark || !(v2_frames & 63)))
				hb_verify(show, w0, unp0 != v2_hb_unpark);
#endif
			if (!hb_rf_left)
				hb_warm(e, n, pos, sh, kw0, s0, kw1, s1);
#endif
		} else {
			v2_hb_wait++;
			if (hb_disp < 0)
				return 0;		/* nothing on the panel yet: the software band meanwhile */
			{	/* the shown ring keeps scrolling at its own scale (zoom / look / marks change), or holds (jump);
				 * its entering columns in ITS scale (V4s: the marks / grid / loop columns too) */
				int d = hb_disp;
				s32 w0c = bcol((s32)pos, hbr[d].sh) - V2_PLAYHEAD - (WAVE_X0 - HB_X);
				if (hbr[d].sh != sh)
					hb_context(e, n, hbr[d].sh, pos, &lk);
				hb_pend_w0 = !hb_extend(d, w0c, HB_SLACK, 1, -1) ? w0c : hb_vis;
			}
		}
	}
#else
	/* the ring to work on: the current one when it has this key and can follow in place, else the other one
	 * (built in the background by a time budget, then GR2 switches to it at one vsync) */
	if (hb_cur >= 0 && hbr[hb_cur].key == key && hbr[hb_cur].sh == sh &&
	    (hb_disp != hb_cur || (w0 - hb_vis <= HB_SLACK && hb_vis - w0 <= HB_SLACK)))
		T = hb_cur;
	else {
		T = hb_cur < 0 ? 0 : 1 - hb_cur;
		if (hbr[T].key != key || hbr[T].sh != sh) {
			hbr[T].key = key;
			hbr[T].look = 8 | (u32)wblue << 2 | (u32)wave_type;
			hbr[T].sh = sh;
			hbr[T].lo = hbr[T].hi = w0;
			hb_t_ck = hb_ck;
		}
	}
	/* budget: a jump / loop wrap that needs <= HB_FINISH columns (the other ring often holds most of the window)
	 * and a rebuild pending for 3 frames finish now -- one longer frame, as the software band's |d| columns --
	 * else HB_MINCOLS, and more while the paint is younger than HB_BUDGET_MS */
	spent = 0;
	do {
		miss = hb_extend(T, w0, 32, hb_disp == T);
		spent += 32;
	} while (miss && (T == hb_disp || miss <= HB_FINISH || hb_pend_n >= 3 || spent < HB_MINCOLS ||
			  (int)(now_ms() - pf_t0) < HB_BUDGET_MS));
	hb_pend_n = miss ? hb_pend_n + 1 : 0;
	if (!miss) {
		if (T != hb_cur) {
			if (hb_cur < 0 || hb_t_ck != hb_ck) {	/* the data changed while it was built */
				hb_rf_left = HB_N;
				hb_rf_c = hbr[T].lo;
			}
			hb_cur = T;
			v2_hb_swaps++;
		}
		if (hb_rf_left) {
			int k = hb_rf_left < 24 ? (int)hb_rf_left : 24;
			if (hb_rf_c < hbr[T].lo || hb_rf_c + k > hbr[T].hi)
				hb_rf_c = hbr[T].lo;
			hb_cols(T, hb_rf_c, hb_rf_c + k);
			hb_rf_c += k;
			hb_rf_left -= (u32)k;
			v2_hb_rcols += (u32)k;
		}
		hb_pend_w0 = w0;
	} else {
		v2_hb_wait++;
		if (hb_disp < 0)
			return 0;		/* nothing on the panel yet: the software band meanwhile */
		{	/* the shown ring keeps scrolling at its own scale (zoom / look / marks change), or holds (jump) */
			s32 w0c = bcol((s32)pos, hbr[hb_disp].sh) - V2_PLAYHEAD - (WAVE_X0 - HB_X);
			hb_pend_w0 = !hb_extend(hb_disp, w0c, HB_SLACK, 1) ? w0c : hb_vis;
		}
	}
#endif
	if (!hb_on && (int)(now_ms() - hb_hold) < 0)
		return 0;			/* held off after an off (no flapping) */
	/* live: the GR3 band area of this buffer */
	tb = ((u32)bd_phys & 0x1FFFFFFF) >= 0x1C13B800;
	{
		u32 kf = band_numbers_calc(bpm10);
		hb_sgx = slip_gx((s32)u32be(DECK + 0x70), sh);
		kf = hmix(kf, (u32)(hb_sgx + 1));
		kf = hmix(hmix(hmix(band_xk, kf), (u32)(slip_on() | deck_playing() << 1 | ph_left << 2 | day << 3 |
							 day_full << 4)), u32be(DECK + 0x68)) | 1;
		if (hb_gk[tb] != kf) {
			hb_gr3(mlab);
			hb_gk[tb] = kf;
		}
	}
	hb_seen = 1;
	v2_hb_live++;
	return 1;
}

static void hb_key_on(void)	/* GR3: chroma key K1 + blend (P_VEN: at the next vsync) */
{
	HWR(GR3 + 0x3C) = HB_KEYREG;
	HWR(GR3 + 0x40) = 0;					/* replacement: alpha 0 */
	HWR(GR3 + 0x38) |= 1;					/* CK_ON */
	HWR(GR3 + 0x20) = (HWR(GR3 + 0x20) & ~3u) | 3;		/* DISP_SEL 3 */
	HWR(GR3) |= 0x10;					/* P_VEN */
}

/* end of paint_frame: every GR2 / GR3 write of the frame, just before the stock base write */
static void hb_commit(void)
{
	u32 a;
	{	/* VBUFERR status: read only */
		u32 s2 = HWR(VDC_INT2), s1 = HWR(VDC_INT1);
		v2_hb_vbuf |= ((s2 >> 20) & 0x111) | (s1 & 1) << 12;
	}
	if (!hb_seen) {
		hb_off(HB_OFF_PATH);
		return;
	}
	hb_seen = 0;
	hb_nopaint = 0;
	a = hb_addr(hb_cur, hb_pend_w0);
	if (!hb_on) {
		static const u32 SET[][2] = {	/* GR2 offset, value (as probe 2, the window of the band) */
			{ 0x08, 0x00000100 },				/* FLM1 = stock GR3's */
			{ 0x10, (u32)HB_S << 16 },			/* FLM3 LN_OFF, FLM_NUM 0 */
			{ 0x14, 0 },					/* FLM4 */
#ifdef V2_GR2METER
			{ 0x18, ((u32)(RING_H + GM_ROWS - 1) << 16) | 0x3FF },	/* FLM5: + the meter prefix */
			{ 0x24, ((10u + BAND_Y0 - GM_ROWS) << 16) | (RING_H + GM_ROWS) },	/* AB2: from y 66 */
#else
			{ 0x18, ((u32)(RING_H - 1) << 16) | 0x3FF },	/* FLM5 */
			{ 0x24, ((10u + BAND_Y0) << 16) | RING_H },	/* AB2 */
#endif
			{ 0x38, 0 }, { 0x3C, 0 }, { 0x40, 0 },		/* no key on GR2 */
			{ 0x04, 1 },					/* FLM_RD R_ENB */
		};
		unsigned i;
		HWR(GR2 + 0x0C) = HB_FLM2(a);				/* FLM2 */
#ifdef V2_HWBAND_STAPOS
		HWR(GR2 + 0x1C) = ((u32)(HB_WW - 1) << 16) | ((a & 7) >> 1);	/* FLM6: RGB565, STA_POS */
#else
		HWR(GR2 + 0x1C) = (u32)(HB_WW - 1) << 16;		/* FLM6: RGB565, STA_POS 0 */
#endif
		HWR(GR2 + 0x28) = HB_AB3(a);				/* AB3: window x 16 - r */
		for (i = 0; i < sizeof(SET) / sizeof(SET[0]); i++)
			HWR(GR2 + SET[i][0]) = SET[i][1];
		HWR(GR2 + 0x20) = (HWR(GR2 + 0x20) & ~3u) | 2;		/* AB1 DISP_SEL 2 */
		HWR(GR2) |= 0x11;
		hb_key_on();
		hb_on = 1;
		v2_hb_setups++;
	} else {
		if ((HWR(GR3 + 0x20) & 3) != 3 || !(HWR(GR3 + 0x38) & 1) || HWR(GR3 + 0x3C) != HB_KEYREG) {
			v2_hb_gr3re++;				/* stock's VDC Start put GR3 back: re-assert */
			hb_key_on();
		}
		if (a != hb_last_a) {
			if (HWR(GR2) & 0x01)			/* last commit not taken by a vsync since (counted only, */
				v2_hb_stuck++;			/* as probe 2: the newer base simply replaces it) */
			HWR(GR2 + 0x0C) = HB_FLM2(a);
#ifdef V2_HWBAND_STAPOS
			HWR(GR2 + 0x1C) = (HWR(GR2 + 0x1C) & ~0x3Fu) | ((a & 7) >> 1);
			HWR(GR2) |= 0x01;			/* IBUS_VEN: the FLM group at the next vsync */
#else
			HWR(GR2 + 0x28) = HB_AB3(a);
			HWR(GR2) |= 0x11;			/* IBUS_VEN (FLM2) + P_VEN (AB3): the same vsync */
#endif
		}
	}
	hb_last_a = a;
	hb_disp = hb_cur;
	hb_vis = hb_pend_w0;
}

/* watchdog (v2_paint, every flip): update mode, or flips without our commit */
static void hb_watch(void)
{
	if (!hb_on)
		return;
	if (UPD_STATE)
		hb_off(HB_OFF_UPD);
	else if (++hb_nopaint > 3)
		hb_off(HB_OFF_WDOG);
}
