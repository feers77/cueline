/* SPDX-License-Identifier: Apache-2.0
 *
 * gr2meter.inc -- GR2METER: the LINK phase meter's WAVEFORM baked into the band layer GR2 (no scaler, the deck's
 * proven pixel-perfect path; work/v4n/GR1METER_DONE "option (c)"). #included by v2.c after hwband.inc under
 * -DV2_GR2METER (needs V2_HWBAND + V2_BDIRECT; HBPOOL of 3 rings, each with its prefix).
 *
 * GR2's window grows up by GM_ROWS (screen rows 66..121) and its base moves up by GM_ROWS lines, so those rows
 * read a PREFIX of GM_ROWS ring rows placed right before each band ring (same 3584-B pitch, same slots): the
 * band's rows, base slot and scroll are untouched. Prefix column c (a band column) holds the MASTER's mini-wave
 * column c + gm_d (master_mini's absolute column map, MMC colours, its grid ticks), gm_d = master - band position
 * in columns, re-laid only when it drifts by >= 2 px (synced: rarely; unsynced: tempo-difference px a second) --
 * otherwise only the columns entering the band's window are written, so the meter scrolls with the band in HW.
 * GR3 keys x (lx + 38) .. 781, rows 66..117 (the fade, labels and playhead stay CPU) only in frames whose prefix
 * of the ring shown holds every visible column; any other frame keeps today's CPU strip (identical look).
 * Only METERDIRECT frames of the WAVEFORM view with a master wave; the band live; HW BAND LAYER ON.
 */
#define GM_PRE ((u32)GM_ROWS * HB_S)	/* prefix bytes before each band ring */
#define GM_BUDGET 256			/* prefix columns written a frame at most */
static int gm_pv[HB_NR];
static s32 gm_lo[HB_NR], gm_hi[HB_NR], gm_pd[HB_NR];
static u32 gm_pk[HB_NR];
static s32 gm_d;
static int gm_dv, gm_kprev, gm_clr;
static s32 gm_pa0, gm_pa1;
u32 v2_gm_keyed, v2_gm_relays, v2_gm_cols, v2_gm_waits, v2_gm_dch, v2_gm_sw;
/* V4n58h (deck V4n58g: a little flicker on load / without SYNC = GR2 <-> CPU switches): GR2 only once the prefix
 * is complete AND delta / look have been stable GM_STABLE_MS; any re-lay or gap restarts the wait, so a drifting
 * (unsynced) master stays on the CPU strip instead of toggling, and a load switches once */
#define GM_STABLE_MS 500
static u32 gm_st, gm_vk;
#ifdef V2_HUD
volatile u32 v2_gm_nokey;
u32 v2_gm_err[4];	/* DEV (emu A/B): 1 = never key (the CPU strip), the prefix still written */
#endif

static void gm_swap(int a, int b)
{
	s32 t;
	u32 k;
	int v;
	v = gm_pv[a]; gm_pv[a] = gm_pv[b]; gm_pv[b] = v;
	t = gm_lo[a]; gm_lo[a] = gm_lo[b]; gm_lo[b] = t;
	t = gm_hi[a]; gm_hi[a] = gm_hi[b]; gm_hi[b] = t;
	t = gm_pd[a]; gm_pd[a] = gm_pd[b]; gm_pd[b] = t;
	k = gm_pk[a]; gm_pk[a] = gm_pk[b]; gm_pk[b] = k;
}
static volatile u16 *gm_pre(int r) { return (volatile u16 *)((hb_phys[r] - GM_PRE) | 0x20000000u); }

static void gm_mmc(s32 m)	/* master column m into MMC (as master_mini's cache loop) */
{
	u32 sl = (u32)m & (MMC_N - 1);
	int d;
	if (MMC_TAG[sl] != (u32)m) {
		u16 cb[HALF + 2];
		int top = col_prof((int)(m - gm.first), gm.e, gm.n, gm.first, gm.sc, cb);
		for (d = 0; d <= 14; d++) {
			int dd = (d * WAVE_H) / 14;
			MMC[d * MMC_N + sl] = dd <= top ? cb[dd] : wc_bg;
		}
		MMC_TAG[sl] = (u32)m;
		v2_mm_cols++;
	}
}

/* the master's grid ticks of master columns [m0, m1) -> mk (1 beat, 2 bar): master_mini's tick loops, BANDFLICK rule */
static void gm_ticks(s32 m0, s32 m1, u8 *mk)
{
	u32 ms0 = m0 > 0 ? udiv((u32)m0 * (u32)gm.sc * 5, 192) : 0, j, t, gi, cnt;
	s32 col;
	for (j = 0; j < (u32)(m1 - m0); j++)
		mk[j] = 0;
	if (gm.w8 && mm.ggn >= 2 && mm.gst16) {
		j = ms0 > mm.gt1 ? udiv((ms0 - mm.gt1) * 16, mm.gst16) : 0;
		for (; j < mm.ggn; j++) {
			int bar = ((mm.gbib + 3 + j) & 3) == 0;
			t = mm.gt1 + ((j * mm.gst16) >> 4);
			col = (s32)udiv(udiv(t * 12, 5) * 16, (u32)gm.sc);
			if (col >= m1)
				break;
			if (col >= m0 && (bar || !BARS_ONLY_SC256((u32)gm.sc)))
				mk[col - m0] = bar ? 2 : 1;
		}
	} else if (!gm.w8 && gm.r0) {
		const volatile u8 *g0 = grid_at(ms0, &gi, &cnt);
		for (j = gi; g0 && j < cnt; j++) {
			int bar = u16be(g0 + 20 * j) == 1;
			t = gms(g0 + 20 * j);
			col = (s32)udiv(udiv(t * 12, 5) * 16, (u32)gm.sc);
			if (col >= m1)
				break;
			if (col >= m0 && (bar || !BARS_ONLY_SC256((u32)gm.sc)))
				mk[col - m0] = bar ? 2 : 1;
		}
	}
}

/* prefix column c (band column) of ring r, both copies: master column c + gm_d */
static void gm_col(int r, s32 c, int mk)
{
	s32 m = c + gm_d;
	u32 sl = (u32)m & (MMC_N - 1);
	volatile u16 *p = gm_pre(r) + hb_slot(c);
	u16 tc = mk == 2 ? gm.tred : mk ? gm.tgrey : gm.blk;
	int i;
	gm_mmc(m);
	for (i = 0; i < GM_ROWS; i++, p += HB_RS) {
		int dy = BAND_Y0 - GM_ROWS + i - gm.cy;
		u16 v;
		if (dy >= -14 && dy <= 14)
			v = MMC[(dy < 0 ? -dy : dy) * MMC_N + sl];
		else if ((dy >= -24 && dy < -14) || (dy >= 15 && dy < 25))
			v = tc;
		else
			v = gm.blk;
		p[0] = v;
		p[HB_N] = v;
	}
	v2_gm_cols++;
}

/* end of paint_frame, right before hb_commit: the prefix of the ring this frame shows + the GR3 key */
static void gm_after(void)
{
	int r = hb_cur, keyed = 0, budget = GM_BUDGET;
	s32 w0 = hb_pend_w0, A0, A1, d0, n, i;
	u8 mk[GM_BUDGET];
	if (!gm.want || !hb_seen || r < 0 || r >= HB_NR || UPD_STATE || KILL_HB) {
		gm_st = now_ms();
		goto out;
	}
	if (!gm_clr) {		/* the prefixes black once (rows / columns no column wrote) */
		int k;
		for (k = 0; k < HB_NR; k++) {
			volatile u32 *z = (volatile u32 *)gm_pre(k);
			u32 j;
			for (j = 0; j < GM_PRE / 4; j++)
				z[j] = 0;
		}
		gm_clr = 1;
	}
	if (gm.rkey != gm_vk) {		/* a new view (load / zoom / look): GR2 after GM_STABLE_MS */
		gm_vk = gm.rkey;
		gm_st = now_ms();
	}
	/* delta from the shown (floored) columns: |shown - CPU strip column| <= 1 by construction (re-lay at 2).
	 * (V4n58h tries: unfloored / low-passed delta -- the emu master really drifts ~4 columns a second, and a
	 * 1-s stability gate then kept the meter on the CPU all the time.) A re-lay's CPU frames look the same now
	 * (whole columns both ways), so they need no extra wait */
	d0 = gm.first - w0 - 2;		/* master column at x = band column at x + d0 (master x 18, band x 16) */
	if (!gm_dv || d0 - gm_d >= 2 || gm_d - d0 >= 2) {
		if (gm_dv)
			v2_gm_dch++;
		gm_d = d0;
		gm_dv = 1;
	}
	A0 = w0 + (gm.kx - HB_X);
	A1 = w0 + (gm.rx - HB_X);
	if (A1 <= A0 || A1 - A0 > HB_N - 64)
		goto out;
	{
		int guard = r == hb_disp && gm_kprev;	/* the panel may still show this ring's prefix (last frame) */
		if (!gm_pv[r] || gm_pk[r] != gm.rkey || gm_pd[r] != gm_d || A1 <= gm_lo[r] || A0 >= gm_hi[r]) {
			if (guard) {
				v2_gm_waits++;
				goto out;
			}
			gm_lo[r] = gm_hi[r] = A0;
			gm_pk[r] = gm.rkey;
			gm_pd[r] = gm_d;
			gm_pv[r] = 1;
			v2_gm_relays++;
		} else if (guard && ((A1 > gm_hi[r] && A1 > gm_pa0 + HB_N) || (A0 < gm_lo[r] && A0 < gm_pa1 - HB_N))) {
			v2_gm_waits++;
			goto out;
		}
	}
	while (gm_hi[r] < A1 && budget) {
		n = A1 - gm_hi[r] < budget ? A1 - gm_hi[r] : budget;
		gm_ticks(gm_hi[r] + gm_d, gm_hi[r] + gm_d + n, mk);
		for (i = 0; i < n; i++)
			gm_col(r, gm_hi[r] + i, mk[i]);
		gm_hi[r] += n;
		budget -= (int)n;
		if (gm_hi[r] - gm_lo[r] > HB_N)
			gm_lo[r] = gm_hi[r] - HB_N;
	}
	if (gm_lo[r] > A0 && budget) {
		n = gm_lo[r] - A0 < budget ? gm_lo[r] - A0 : budget;
		gm_ticks(gm_lo[r] - n + gm_d, gm_lo[r] + gm_d, mk);
		for (i = n - 1; i >= 0; i--)
			gm_col(r, gm_lo[r] - n + i, mk[i]);
		gm_lo[r] -= n;
		if (gm_hi[r] - gm_lo[r] > HB_N)
			gm_hi[r] = gm_lo[r] + HB_N;
	}
	if (gm_lo[r] > A0 || gm_hi[r] < A1)
		goto out;
	if (now_ms() - gm_st < GM_STABLE_MS)
		goto out;
#ifdef V2_HUD
	if (v2_gm_nokey)
		goto out;
#endif
	{	/* the hole: rows 66..117, x kx..rx of the GR3 buffer about to latch (the meter strip drawn there this
		 * frame by METERDIRECT), then the fixed playhead over it */
		u16 *g = bd_phys;
		int y;
		for (y = BAND_Y0 - GM_ROWS; y < BAND_Y0 - GM_ROWS + 52; y++)
			fill16(g + y * W + gm.kx, gm.rx - gm.kx, HB_KEY);
		if (gm.cx - 1 >= gm.kx && gm.cx + 1 <= gm.rx)
			for (y = BAND_Y0 - GM_ROWS; y < BAND_Y0 - GM_ROWS + 52; y++) {
				g[y * W + gm.cx - 1] = gm.white;
				g[y * W + gm.cx] = gm.white;
			}
	}
	keyed = 1;
#ifdef V2_HUD
	{	/* DEV: the shown offset vs the CPU strip's (floored) column: |err| 0, 1, 2, >= 3 */
		s32 er = w0 + gm_d + 2 - gm.first;
		if (er < 0)
			er = -er;
		v2_gm_err[er > 3 ? 3 : er]++;
	}
#endif
	gm_pa0 = A0;
	gm_pa1 = A1;
	v2_gm_keyed++;
out:
	if (keyed != gm_kprev)
		v2_gm_sw++;
	gm_kprev = keyed;
	gm.want = 0;
}
