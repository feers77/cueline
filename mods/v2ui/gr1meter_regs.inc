/* SPDX-License-Identifier: Apache-2.0
 *
 * gr1meter_regs.inc -- GR1METER (DEV): the register half (see gr1meter_ring.inc). #included after hwband.inc.
 * Proven on the deck by the probes V4n45g1 / g2: setup / scroll / off exactly as there.
 *   on    GR1 own window + ring (setup once), GR3 K1 key + blend (shared with the band), GR2 DISP_SEL 3 while
 *         the band is live (the deck's VDC4 shows the background outside GR2's window at DISP_SEL 2).
 *   frame FLM2 + AB3 (+ IBUS_VEN | P_VEN) when the column changes, at the end of paint_frame after hb_commit:
 *         the same vsync as the frame's GR3 buffer.
 *   off   (a frame that does not want GR1, not owned, UPD_STATE, a 3-flip watchdog, the kill switch):
 *         GR1 DISP_SEL 0 + reads off, GR2 back to the band's DISP_SEL 2, GR3's key off unless the band is live;
 *         then 1 s of CPU meter (no re-setup storm). Register pokes only.
 */
enum { G1_OFF_PATH = 1, G1_OFF_NOTOWNED, G1_OFF_UPD, G1_OFF_WDOG, G1_OFF_KILL };
static u32 g1_last_a, g1_nopaint;
#define G1_LINGER 4
static int g1_idle;
u32 v2_g1_linger;

#ifdef V2_GR1PRECOMP
#define G1_AB3(a) (((143u + G1_X) << 16) | G1_WW)	/* PRECOMP: fixed (the deck ignores the shift) */
#else
#define G1_AB3(a) ((((143u + G1_X) - (((a) & 7) >> 1)) << 16) | G1_WW)
#endif

static void g1_gr2sel(int on)
{
	u32 ab1 = HWR(GR2 + 0x20);
	if (!hb_on)
		return;		/* band off: GR2 is at pass-through (1), GR1 shows */
	if (on && (ab1 & 3) == 2) {
		HWR(GR2 + 0x20) = (ab1 & ~3u) | 3;
		HWR(GR2) |= 0x10;
		v2_g1_g2sel++;
	} else if (!on && (ab1 & 3) == 3) {
		HWR(GR2 + 0x20) = (ab1 & ~3u) | 2;
		HWR(GR2) |= 0x10;
	}
}
static void g1_adj_restore(void);
#ifdef V2_SC0BYP
static u32 sc0_boot[7];
static int sc0_saved, sc0_done;
#endif
/* REVIEW 1124 4.3: every off path (screen not ours, watchdog, view gone) used to give scaler 0 and the matrix back
 * to stock in the SAME commit that turned GR1's read off; scaler registers latch in their own groups (DS at the input
 * vsync, manual 33.1.2), so the panel could show GR1 one frame through stock's line-doubling scaler = two tick rows.
 * Now the layer goes off first and the scaler / matrix come back G1_LINGER flips later (g1_watch); update mode and the
 * kill switch restore at once. */
static int g1_rs_left;
static void g1_regs_off_now(int now)
{
	if (now) {
		g1_rs_left = 0;
		g1_adj_restore();
	} else
		g1_rs_left = G1_LINGER;
	HWR(GR1 + 0x20) &= ~3u;					/* AB1 DISP_SEL 0 (stock: background colour) */
	HWR(GR1 + 0x04) = 0;					/* reads off */
	HWR(GR1) |= 0x11;
	if (!hb_on) {
		HWR(GR3 + 0x38) &= ~1u;				/* CK_ON off */
		HWR(GR3 + 0x20) = (HWR(GR3 + 0x20) & ~3u) | 2;	/* DISP_SEL 2 (stock) */
		HWR(GR3) |= 0x10;
	}
}
static void g1_off(int why)
{
	g1_kprev = 0;
	if (!g1_on)
		return;
	g1_gr2sel(0);
	g1_regs_off_now(why == G1_OFF_UPD || why == G1_OFF_KILL || UPD_STATE);
	g1_on = 0;
	g1_hold = now_ms() + G1_HOLD_MS;
	v2_g1_offs++;
	v2_g1_why = (u32)why;
	v2_g1_on = 0;
}

/* m3 (deck m1 / m2: the ring came out GREEN with light wave after a local load, right with HW BAND LAYER OFF;
 * the g2 probe's bars were right). Every live frame: each GR1 register we own is compared with what we set and
 * rewritten if something else changed it (counted, which register and its foreign value logged), so a writer
 * outside v2 (stock's VDC driver on a load) cannot leave GR1 in another format / mode. */
static const u8 G1_OWN[] = { 0x04, 0x08, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x38, 0x3C, 0x40, 0x44, 0x48, 0x4C, 0x50 };
u32 v2_g1_ext, v2_g1_extmask, v2_g1_extoff, v2_g1_extval;
static u32 g1_own(unsigned off)
{
	switch (off) {
	case 0x04: return 1;					/* FLM_RD R_ENB */
	case 0x08: return 0;					/* FLM1 (m2) */
	case 0x10: return (u32)G1_S << 16;			/* FLM3 */
#ifdef V2_GR1PRECOMP
	case 0x18: return ((u32)(G1P_L0 + G1P_ROWS - 1) << 16) | 0x3FF;	/* FLM5: input lines 0..47 */
#else
	case 0x18: return ((u32)(G1_H - 1) << 16) | 0x3FF;	/* FLM5 */
#endif
	case 0x1C: return (u32)(G1_WW - 1) << 16;		/* FLM6: RGB565, STA_POS 0 */
	case 0x20: return 2;					/* AB1: DISP_SEL 2, every other bit 0 */
	case 0x24: return ((10u + G1_Y) << 16) | G1_H;		/* AB2 */
	default: return 0;					/* FLM4, AB7..AB11, BASE, CLUT */
	}
}
static int g1_assert(void)
{
	unsigned i;
	int n = 0;
	for (i = 0; i < sizeof(G1_OWN); i++) {
		u32 v = HWR(GR1 + G1_OWN[i]), w = g1_own(G1_OWN[i]);
		if (v != w) {
			HWR(GR1 + G1_OWN[i]) = w;
			v2_g1_extmask |= 1u << (G1_OWN[i] >> 2);
			v2_g1_extoff = G1_OWN[i];
			v2_g1_extval = v;
			n++;
		}
	}
	if (n)
		v2_g1_ext++;
	return n;
}

/* m4 (deck m3 calibration bars: BLACK -> green, RED -> ochre, WHITE -> grey, BLUE -> sky ... = our RGB565 read
 * through a YCbCr -> GBR matrix: G taken as Y, B as Cb, R as Cr). GR1 + 0x80.. is the VDC5 ADJ block (image
 * quality / colour matrix of the video-capable bottom layer; the stock driver's 0x7694..76A8 pairs = its ENH_SHP
 * registers): +0x80 UPDATE (bit 0 VEN), +0xB4 MTX_MODE ([1:0]: 0 GBR->GBR, 2 YCbCr->GBR), +0xB8/BC YG_ADJ0/1,
 * +0xC0/C4 CBB_ADJ0/1, +0xC8/CC CRR_ADJ0/1. m5 (deck m4: cyan -> purple, red -> black, white -> dim = R_out from B_in,
 * G_out 0, B_out from G_in): the VDC5 field layout -- YG_ADJ0 [23:16] offset G, [10:0] GG; YG_ADJ1 [26:16] GB,
 * [10:0] GR; CBB_ADJ0 [23:16] offset B, [10:0] BG; CBB_ADJ1 [26:16] BB, [10:0] BR; CRR_ADJ0 [23:16] offset R,
 * [10:0] RG; CRR_ADJ1 [26:16] RB, [10:0] RR (m4 had put 1.0 into GB / BG / RB). Stock leaves it at
 * YCbCr -> GBR from boot (nz mask 0x07C0E000), unused because GR1 is stock-off. While GR1 is live: GBR -> GBR with
 * an identity matrix (1.0 = 0x200, deck m5); every off path restores the stock values (the boot snapshot) at the
 * same vsync. */
#define G1_ADJ0 0x80
#define G1_ADJN 20			/* +0x80 .. +0xCC */
static u32 g1_adj_boot[G1_ADJN];
/* V4n49j (deck V4n49h register dump): GR1 sits where the VDC5 GR0 sits, behind SCALER 0 -- and stock leaves its
 * UP-scaler on (SCL0_US1 0x7548 = 0x11: H / V enable; US2 0x754C = 35 / 480 out V, US3 0x7550 = 144 / 640 out H,
 * US4 0x7554 = 240 / 640 in): GR1's read was line-doubled (240 -> 480: the "bigger / taller, pixelated" wave) and
 * cut to a 640-px output window (the strip's plain right part). While GR1 is live: the up-scaler off (1:1) with
 * in = out = the panel (480 x 800 at 10 / 143, stock's FRC6 / FRC7); the stock values come back on every off path.
 * SCL0_UPDATE (0x7500): VEN_A / VEN_B / UPDATE / VEN_C / VEN_D, set together. */
#define G1_SC0 0xFFFF7500u
#define G1_US1 (G1_SC0 + 0x48)
static u32 g1_us_boot[4];
static const u32 g1_us_1to1[4] = { 0, 0x000A01E0, 0x008F0320, 0x01E00320 };
/* V4n49q (deck V4n49j video: the strip WASHED OUT -- a light lavender sheet, the wave faint): scaler 0's background
 * colour (0x756C, stock 0x00800080 = Y 0 / Cb 128 / Cr 128 = black in YCbCr) came through the now pass-through
 * matrix as G 0 / B 0x80 / R 0x80 = lavender. While live: 0 (black in RGB); stock on the off paths. */
#define G1_SCBK (G1_SC0 + 0x6C)
static u32 g1_scbk_boot;
u32 v2_g1_usfix;
static int g1_adj_ok, g1_adj_set;
u32 v2_g1_adjfix;
static void g1_adj_snap(void)	/* first normal-boot flip: the stock values (GR1 never ours yet) */
{
	unsigned i;
	if (g1_adj_ok || UPD_STATE || g1_on)
		return;
	for (i = 0; i < G1_ADJN; i++)
		g1_adj_boot[i] = HWR(GR1 + G1_ADJ0 + 4 * i);
	for (i = 0; i < 4; i++)
		g1_us_boot[i] = HWR(G1_US1 + 4 * i);
	g1_scbk_boot = HWR(G1_SCBK);
	g1_adj_ok = 1;
}
/* GBR -> GBR identity, as Renesas' own VDC5 driver (r_vdc5_user.h / r_vdc5_register.c, SetImgQaImproverColorMtx):
 * coefficients are 11-bit two's complement with 1.0 = 256 (VDC5_COLORCONV_1TIMES_GAIN; stock's own YCbCr -> GBR
 * 0x00800100 / 0x07A80749 is that driver's table to the bit), and the DC offset fields are 128 = NO offset in every
 * mode (VDC5_COLORCONV_DC_OFFSET, GBR -> GBR included). V4n59k (work/gr1col): the old 0x200 / offset 0 setup was
 * out = 2 x in - 128 per channel -- whites and saturated bars right (deck m5, hence "1.0 = 0x200"), every
 * mid / dark value wrong (the deck's violet meter blue: dark G / R crushed to 0). */
#define G1_ONE 0x100u
#define G1_OFS (0x80u << 16)
static const u32 g1_adj_id[6] = {
	G1_OFS | G1_ONE,	/* YG_ADJ0: offset 0 (128), GG 1 */
	0,			/* YG_ADJ1: GB 0, GR 0 */
	G1_OFS,			/* CBB_ADJ0: offset 0 (128), BG 0 */
	G1_ONE << 16,		/* CBB_ADJ1: BB 1, BR 0 */
	G1_OFS,			/* CRR_ADJ0: offset 0 (128), RG 0 */
	G1_ONE,			/* CRR_ADJ1: RB 0, RR 1 */
};
/* V4n49g (deck V4n48g1: flat calibration bars right, but the real wave's mid greens lost -- deep blue body, red
 * centre band, whitish dots -- against the CPU strip): the block's ENHANCER (VDC5 ADJ: +0x84 BKSTR_SET black
 * stretch, +0x88..0x90 ENH_TIM1..3, +0x94..0xA8 ENH_SHP1..6 sharpness, +0xAC/B0 ENH_LTI1/2 transient improvement)
 * works on Y = G in GBR mode: it sharpens / steps the G channel at every 1-px wave edge (flat bars untouched).
 * Stock leaves TIM and LTI non-zero. While GR1 is live the whole enhancer is 0 (off); the off paths restore it. */
#define G1_ENH0 0x84
#define G1_ENH1 0xB4		/* exclusive */
static void g1_adj_live(void)	/* GBR -> GBR identity, enhancer off; re-asserted every live frame */
{
	unsigned i;
	int n = 0;
	u32 m = (g1_adj_boot[(0xB4 - G1_ADJ0) >> 2] & ~3u);
	if (!g1_adj_ok)
		return;
	for (i = G1_ENH0; i < G1_ENH1; i += 4)
		if (HWR(GR1 + i)) {
			HWR(GR1 + i) = 0;
			n++;
		}
	if (HWR(GR1 + 0xB4) != m) {
		HWR(GR1 + 0xB4) = m;
		n++;
	}
	for (i = 0; i < 6; i++)
		if (HWR(GR1 + 0xB8 + 4 * i) != g1_adj_id[i]) {
			HWR(GR1 + 0xB8 + 4 * i) = g1_adj_id[i];
			n++;
		}
	if (n) {
		HWR(GR1 + G1_ADJ0) |= 1;	/* ADJ VEN: at the next vsync */
		v2_g1_adjfix++;
	}
#ifdef V2_SC0BYP
	/* V4n59s (DEV test): scaler 0 as Renesas' vdc5fb plain-graphics setup (rza_linux-4.9 vdc5fb_init_scalers):
	 * down- / up-scaler off, black background, output window = the panel (US2 V start 9 / 480 lines, US3 H start
	 * 144 / 800 px), DS7 = 480 x 800, US8 IBUS_SYNC_SEL (the bus-read sync -- never set before), then every
	 * update enable. Once a setup; the stock values back on off (g1_adj_restore) */
	{
		static const u16 R[] = { 0x2C, 0x48, 0x4C, 0x50, 0x44, 0x64, 0x6C };	/* DS1 US1 US2 US3 DS7 US8 OVR1 */
		static const u32 V[] = { 0, 0, 0x000901E0u, 0x008F0320u, 0x01E00320u, 0x10, 0 };
		unsigned j;
		if (sc0_done)
			goto sc0_out;
		sc0_done = 1;
		if (!sc0_saved) {
			for (j = 0; j < 7; j++)
				sc0_boot[j] = HWR(G1_SC0 + R[j]);
			sc0_saved = 1;
		}
		for (j = 0; j < 7; j++)
			HWR(G1_SC0 + R[j]) = j == 5 ? (sc0_boot[5] | 0x10) : V[j];
		HWR(G1_SC0) |= 0x3111;
		v2_g1_usfix++;
	}
sc0_out:
#endif
#if defined(V2_GR1PRECOMP) || defined(V2_SC0BYP)
	/* V4n54t (deck V4n54s: whole-region lavender sheets in some frames): with the pre-compensated ring scaler 0 is
	 * left exactly as stock -- the per-frame up-scaler / background / SCL0_UPDATE writes (which never took) glitched
	 * the scaler's output */
	g1_adj_set = 1;
	return;
#endif
	n = 0;
	for (i = 0; i < 4; i++) {
		u32 w = i ? g1_us_1to1[i] : g1_us_boot[0] & ~0x11u;	/* US1: only the H / V enables off */
		if (HWR(G1_US1 + 4 * i) != w) {
			HWR(G1_US1 + 4 * i) = w;
			n++;
		}
	}
	if (HWR(G1_SCBK) != 0) {
		HWR(G1_SCBK) = 0;
		n++;
	}
	if (n) {
		HWR(G1_SC0) |= 0x3111;		/* scaler 0: every register group at the next vsync */
		v2_g1_usfix++;
	}
	g1_adj_set = 1;
}
static void g1_adj_restore(void)
{
	unsigned i;
	if (!g1_adj_set)
		return;
#ifdef V2_SC0BYP
	if (sc0_saved) {
		static const u16 R[] = { 0x2C, 0x48, 0x4C, 0x50, 0x44, 0x64, 0x6C };
		for (i = 0; i < 7; i++)
			HWR(G1_SC0 + R[i]) = sc0_boot[i];
		HWR(G1_SC0) |= 0x3111;
		sc0_done = 0;
	}
#endif
	for (i = (G1_ENH0 - G1_ADJ0) >> 2; i < G1_ADJN; i++)	/* enhancer + matrix: the stock values */
		HWR(GR1 + G1_ADJ0 + 4 * i) = g1_adj_boot[i];
	HWR(GR1 + G1_ADJ0) |= 1;
#if !defined(V2_GR1PRECOMP) && !defined(V2_SC0BYP)
	for (i = 0; i < 4; i++)					/* scaler 0's up-scaler: the stock values */
		HWR(G1_US1 + 4 * i) = g1_us_boot[i];
	HWR(G1_SCBK) = g1_scbk_boot;
	HWR(G1_SC0) |= 0x3111;
#endif
	g1_adj_set = 0;
}

/* end of paint_frame, after hb_commit */
static void g1_commit(void)
{
	u32 a;
	if (!g1_seen) {
		/* GR1LINGER (owner, decks 2026-11-23: for a moment the master row showed two rows of ticks after changing
		 * the meter's style by touch): leaving the WAVEFORM view switched GR1 off and gave scaler 0 back to stock
		 * (its line-doubling up-scaler) in the SAME commit as the first frame without the key. If the panel shows
		 * the last keyed GR3 buffer one vsync longer than the registers take, GR1 is seen through the stock
		 * scaler for that frame: every line twice. Now the layer and its scaler setup stay as they are for
		 * G1_LINGER frames without the key (both GR3 buffers repainted, several vsyncs passed) and only then go
		 * off; a view that comes back meanwhile just keys again (no re-setup, no 1 s of CPU strip). */
		if (g1_on && !KILL_HB && !UPD_STATE && g1_idle < G1_LINGER) {
			g1_idle++;
			g1_nopaint = 0;
			if (g1_idle > 1)	/* REVIEW 1124 m.A: the last keyed buffer may still be on the panel one frame */
				g1_kprev = 0;
			g1_key_now = 0;
			v2_g1_linger++;
			return;
		}
		g1_off(KILL_HB ? G1_OFF_KILL : G1_OFF_PATH);
		g1_key_now = 0;
		return;
	}
	g1_idle = 0;
	g1_seen = 0;
	g1_nopaint = 0;
#ifdef V2_GR1PRECOMP
	{	/* input column 0 = absolute column first - 17, from the copy that puts it on a 4-px boundary; line 0 = the
		 * copy's start - G1P_L0 rows */
		u32 s0 = g1_slot(g1_w0 - 17), k = (4 - (s0 & 3)) & 3, s1 = s0 + k;
		if (s1 >= G1_N)
			s1 -= G1_N;
		a = G1_PHYS + k * G1P_COPY + 2 * s1 - G1P_L0 * G1_S;
	}
#else
	a = (g1_half ? G1_PHYS2 : G1_PHYS) + 2 * g1_slot(g1_w0);	/* MSUB: the half ring on odd halves */
#endif
	if (!g1_on) {
		unsigned i;
		HWR(GR1 + 0x0C) = a & ~7u;				/* FLM2 */
		HWR(GR1 + 0x28) = G1_AB3(a);				/* AB3: window x 18 - r */
		for (i = 0; i < sizeof(G1_OWN); i++)		/* m3: every register we own, AB1 whole (not RMW) */
			HWR(GR1 + G1_OWN[i]) = g1_own(G1_OWN[i]);
		HWR(GR1) |= 0x11;
		g1_on = 1;
		g1_age = 0;
		v2_g1_setups++;
		v2_g1_on = 1;
	} else {
		int ext = g1_assert();
		if (a != g1_last_a || ext) {
			if (HWR(GR1) & 0x01)
				v2_g1_stuck++;	/* last commit not taken by a vsync since (counted only) */
			HWR(GR1 + 0x0C) = a & ~7u;
			HWR(GR1 + 0x28) = G1_AB3(a);
			HWR(GR1) |= 0x11;	/* FLM2 + AB3 (+ any re-asserted register) at the same vsync */
		}
	}
	if ((HWR(GR3 + 0x20) & 3) != 3 || !(HWR(GR3 + 0x38) & 1) || HWR(GR3 + 0x3C) != HB_KEYREG) {
		v2_g1_gr3re++;
		hb_key_on();
	}
	g1_adj_live();		/* m4: GR1's colour matrix GBR -> GBR identity (stock: YCbCr -> GBR) */
	g1_gr2sel(1);		/* after hb_commit: its setup / re-assert may have written DISP_SEL 2 this frame */
	g1_last_a = a;
	if (g1_age < 100)
		g1_age++;
	g1_kprev = g1_key_now;
	g1_pa0 = g1_a0;
	g1_pa1 = g1_a1;
	g1_key_now = 0;
	v2_g1_frames++;
	v2_g1_vbuf |= ((HWR(VDC_INT2) >> 20) & 0x111) | (HWR(VDC_INT1) & 1) << 12;
}

/* watchdog (v2_paint, every flip): update mode, or flips without our commit */
static void g1_watch(void)
{
	g1_adj_snap();
	if (!g1_on) {
		if (g1_rs_left && (UPD_STATE || --g1_rs_left == 0)) {	/* REVIEW 1124 4.3: the deferred restore */
			g1_rs_left = 0;
			g1_adj_restore();
		}
		return;
	}
	if (UPD_STATE)
		g1_off(G1_OFF_UPD);
	else if (++g1_nopaint > 3)
		g1_off(G1_OFF_WDOG);
}
