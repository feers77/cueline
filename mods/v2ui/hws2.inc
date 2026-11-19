/* SPDX-License-Identifier: Apache-2.0
 *
 * hwscroll_proposal.c -- VDC4 hardware-scroll PROBE 2 (re/VDC4_PROBE2.md). PROPOSAL, not built.
 * Quotes firmware addresses (interoperability facts only, no firmware bytes).
 *
 * Meant to be #included by v2.c (after wait_latch()/now_ms()/fill()/text()/udiv() and the HUD
 * counters exist) under -DV2_HWS2, replacing the V2_HWPROBE block. Call sites (for the v2.c owner):
 *
 *   paint_frame():  if (!base || !owned()) {
 *                       if (!owned()) hws_off(HWS_OFF_NOTOWNED);   // NEVER on base == 0 (probe-1 bug)
 *                       ...
 *                   }
 *                   ... right after wait_latch() + read_flags():
 *                   hws_frame(screen_mode() == M_PLAYER);          // base != 0 here
 *                   ... in player(), after zoom_label():
 *                   hws_paint();
 *   v2_paint():     first line:  if (UPD_STATE) hws_off(HWS_OFF_UPD);
 *   HUD:            the "H" line below (hws_hud) in a free txt[] slot pair, or its own row at y 300.
 *   dirty_n:        do NOT force flips (probe 1 did: `if (hwp_on) dirty_n = 2`). Scroll is tested
 *                   with the track PLAYING (frames flip anyway); paused = the pattern stands still.
 *
 * What changed from probe 1 (V3rc8hw):
 *   - setup ONCE per PLAYER entry (and once per phase change); base == 0 frames never touch it
 *   - per frame only GR2 FLM2 + FLM6.STA_POS + GR2 UPDATE |= 0x01 (IBUS_VEN): 3 register writes
 *   - key fixed K1 (AB8 0x00000800, the deck proved it); GR3 AB1/AB7/AB8/AB9 written at setup only
 *   - pattern in SDRAM 0x0CA90000 (probe 1's 0x0CA40000 is INSIDE w8recv's PWV5 area
 *     0x0CA00040..0x0CA60040); phase 3 scans a 128x16 ring in on-chip RAM 0x1C1F8000 instead
 *   - hard limit 60 s, then off until the next PLAYER entry; watchdog
 *   - counters for the HUD (stuck commits, wait_latch timeouts, frame-gap max, VBUFERR status bits)
 *
 * Phases (label on screen "HS<p>"):
 *   P1  0-20 s   GR2 on (SDRAM), K1 hole, NO per-frame writes          -> setup alone
 *   P2 20-40 s   + 1 px/frame scroll (SDRAM)                            -> per-frame IBUS_VEN commits
 *   P3 40-60 s   GR2 reads a 64x16 window from ON-CHIP RAM, 1 px/frame  -> SDRAM traffic removed
 *   then off. If a freeze shows only in P2 -> per-frame commits; in P1 and P2 but not P3 -> SDRAM
 *   path; in all three -> GR2/GR3 config itself (key/blend) or not the probe at all.
 */
#ifdef V2_HWS2

#define HWR(a) (*(volatile u32 *)(a))
#define GR2 0xFFFF7700u
#define GR3 0xFFFF7780u
#define VDC_INT1 0xFFFF7A80u		/* read only here: INT_STA8 (VBUFERR4) bit 0 */
#define VDC_INT2 0xFFFF7A84u		/* read only here: INT_STA5..7 (VBUFERR1..3) bits 20/24/28 */

/* SDRAM pattern: 40 rows x 3072 B = 0x1E000 at 0x0CA90000 (free: after w8recv's 0x0CA90000 end,
 * before POP_BAK 0x0CB00000; inside MEMPROBE Z5, which the deck reported 0 = nobody writes) */
#define HWS_SD_PHYS 0x0CA90000u
#define HWS_SD_CPU ((volatile u16 *)0x2CA90000)
#define HWS_SD_S 3072u
#define HWS_SD_W 256
#define HWS_SD_H 40
#define HWS_SD_N 768			/* ring period (px) */
/* on-chip pattern: 16 rows x 256 B (128 px = 2 x 64) at 0x1C1F8000 (PERF_BROWSE_PLAY §7.2: 0x1C1F7000..
 * 0x1C200000 zero and untouched; re-check with CDJ_GUI_WWATCH=0x1C1F7000:36864 before the build) */
#define HWS_OC_PHYS 0x1C1F8000u
#define HWS_OC_CPU ((volatile u16 *)0x3C1F8000)	/* uncached mirror, as paint_frame's phys */
#define HWS_OC_S 256u
#define HWS_OC_W 64
#define HWS_OC_H 16
#define HWS_OC_N 64

#define HWS_X 520			/* window on the screen (as probe 1) */
#define HWS_Y 130
#define HWS_KEY 0x00000800u		/* K1: RGB565 0x0001 -> (G 00, B 08, R 00) -- proven on the deck */
#define HWS_LIMIT_MS 40000u	/* V3rc8v: P1 + P2 only (P3's on-chip RAM area not verified free) */
#define HWS_PHASE_MS 20000u

enum { HWS_OFF_NOTOWNED = 1, HWS_OFF_SCREEN, HWS_OFF_LIMIT, HWS_OFF_UPD, HWS_OFF_WDOG };

static int hws_on, hws_done, hws_phase;		/* phase 1..3 while on */
static u32 hws_t0, hws_h, hws_last_ms;
/* HUD counters (since boot; the HUD shows them as "HS p setups stuck lto gap vbuf why") */
u32 v2_hws_setups;		/* setups (expect 3 per player entry: one per phase) */
u32 v2_hws_stuck;		/* frames where GR2's IBUS_VEN from the previous frame was still set */
u32 v2_hws_lto0, v2_hws_lto;	/* wait_latch timeouts during the probe (v2_latch_stuck delta) */
u32 v2_hws_gap;			/* max ms between two hws_frame calls while on (a GUI stall shows here) */
u32 v2_hws_setup_ms;		/* max ms one setup took (pattern write + registers) */
u32 v2_hws_vbuf;		/* VBUFERR status bits seen (OR of INT2 >> 20 & 0x111, INT1 bit0 << 12) */
u32 v2_hws_why;			/* last off reason */
u32 v2_hws_gr3re;		/* frames where stock had put GR3 back to DISP_SEL 2 / CK off (its VDC Start
				 * 0x0E5265FC(2, &2) in the flip's init path 0x0E508AE2): re-asserted */
extern u32 v2_latch_stuck;

static void hws_pattern_sd(void)
{
	u32 x, y;
	for (y = 0; y < HWS_SD_H; y++)
		for (x = 0; x < HWS_SD_N; x++) {
			u16 c = (x >> 5) & 1 ? 0x001F : 0x07E0;
			if ((x & 7) == 0) c = 0xFFFF;
			if ((x & 63) == 0 && y < 12) c = 0xF800;
			if (y == 0 || y == HWS_SD_H - 1) c = 0xFFE0;
			HWS_SD_CPU[y * (HWS_SD_S / 2) + x] = c;
			HWS_SD_CPU[y * (HWS_SD_S / 2) + x + HWS_SD_N] = c;
		}
}
static void hws_pattern_oc(void)
{
	u32 x, y;
	for (y = 0; y < HWS_OC_H; y++)
		for (x = 0; x < HWS_OC_N; x++) {
			u16 c = (x >> 4) & 1 ? 0xF81F : 0xFFE0;	/* magenta / yellow 16-px stripes: tells P3 apart */
			if ((x & 7) == 0) c = 0xFFFF;
			HWS_OC_CPU[y * (HWS_OC_S / 2) + x] = c;
			HWS_OC_CPU[y * (HWS_OC_S / 2) + x + HWS_OC_N] = c;
		}
}

/* GR2 + GR3 key, once. The registers commit at the next vsync (IBUS_VEN / P_VEN). */
static void hws_setup(int phase)
{
	u32 t = now_ms();
	int oc = phase == 3;
	u32 w = oc ? HWS_OC_W : HWS_SD_W, h = oc ? HWS_OC_H : HWS_SD_H;
	if (oc)
		hws_pattern_oc();
	else if (phase == 1)
		hws_pattern_sd();	/* P2 reuses P1's pattern: no second write */
	HWR(GR2 + 0x08) = 0x00000100;				/* FLM1 = stock GR3's */
	HWR(GR2 + 0x0C) = oc ? HWS_OC_PHYS : HWS_SD_PHYS;	/* FLM2 */
	HWR(GR2 + 0x10) = (oc ? HWS_OC_S : HWS_SD_S) << 16;	/* FLM3 LN_OFF, FLM_NUM 0 */
	HWR(GR2 + 0x14) = 0;					/* FLM4 */
	HWR(GR2 + 0x18) = ((h - 1) << 16) | 0x3FF;		/* FLM5 */
	HWR(GR2 + 0x1C) = (w - 1) << 16;			/* FLM6: RGB565, STA_POS 0 */
	HWR(GR2 + 0x24) = ((10u + HWS_Y) << 16) | h;		/* AB2 */
	HWR(GR2 + 0x28) = ((143u + HWS_X) << 16) | w;		/* AB3 */
	HWR(GR2 + 0x38) = 0; HWR(GR2 + 0x3C) = 0; HWR(GR2 + 0x40) = 0;
	HWR(GR2 + 0x04) = 1;					/* FLM_RD R_ENB */
	HWR(GR2 + 0x20) = (HWR(GR2 + 0x20) & ~3u) | 2;		/* AB1 DISP_SEL 2 */
	HWR(GR2) |= 0x11;
	if (phase == 1) {					/* GR3's key once per entry */
		HWR(GR3 + 0x3C) = HWS_KEY;
		HWR(GR3 + 0x40) = 0;
		HWR(GR3 + 0x38) |= 1;				/* CK_ON */
		HWR(GR3 + 0x20) = (HWR(GR3 + 0x20) & ~3u) | 3;	/* DISP_SEL 3 */
		HWR(GR3) |= 0x10;				/* P_VEN */
	}
	hws_h = 0;
	v2_hws_setups++;
	t = now_ms() - t;
	if (t > v2_hws_setup_ms)
		v2_hws_setup_ms = t;
}

static void hws_off(int why)
{
	if (!hws_on)
		return;
	HWR(GR3 + 0x38) &= ~1u;					/* CK_ON off */
	HWR(GR3 + 0x20) = (HWR(GR3 + 0x20) & ~3u) | 2;		/* DISP_SEL 2 (stock) */
	HWR(GR3) |= 0x10;
	HWR(GR2 + 0x20) = (HWR(GR2 + 0x20) & ~3u) | 1;		/* GR2 pass-through (stock) */
	HWR(GR2 + 0x04) = 0;					/* reads off */
	HWR(GR2) |= 0x11;
	hws_on = 0;
	hws_phase = 0;
	v2_hws_why = (u32)why;
}

/* once per flipped frame (base != 0), after wait_latch */
static void hws_frame(int want)
{
	u32 t = now_ms(), a, ph;
	{	/* VBUFERR status: read only (writing INT2 would clear / re-arm stock's VLINE) */
		u32 s2 = HWR(VDC_INT2), s1 = HWR(VDC_INT1);
		v2_hws_vbuf |= ((s2 >> 20) & 0x111) | (s1 & 1) << 12;
	}
	if (!want || UPD_STATE) {
		hws_off(UPD_STATE ? HWS_OFF_UPD : HWS_OFF_SCREEN);
		if (!want)
			hws_done = 0;		/* re-armed on the next player entry (a real screen change) */
		return;
	}
	if (hws_done)
		return;
	if (!hws_on) {
		hws_on = 1;
		hws_phase = 1;
		hws_t0 = t;
		hws_last_ms = t;
		v2_hws_lto0 = v2_latch_stuck;
		hws_setup(1);
		return;
	}
	if (t - hws_last_ms > v2_hws_gap)
		v2_hws_gap = t - hws_last_ms;
	hws_last_ms = t;
	v2_hws_lto = v2_latch_stuck - v2_hws_lto0;
	if (t - hws_t0 >= HWS_LIMIT_MS) {
		hws_off(HWS_OFF_LIMIT);
		hws_done = 1;
		return;
	}
	ph = 1 + udiv(t - hws_t0, HWS_PHASE_MS);
	if (ph != (u32)hws_phase) {
		hws_phase = (int)ph;
		hws_setup(hws_phase);
		return;
	}
	if ((HWR(GR3 + 0x20) & 3) != 3 || !(HWR(GR3 + 0x38) & 1)) {
		v2_hws_gr3re++;				/* reads return the register file: cheap */
		HWR(GR3 + 0x3C) = HWS_KEY;
		HWR(GR3 + 0x38) |= 1;
		HWR(GR3 + 0x20) = (HWR(GR3 + 0x20) & ~3u) | 3;
		HWR(GR3) |= 0x10;
	}
	if (hws_phase == 1)
		return;					/* P1: no per-frame writes to GR2 */
	if (HWR(GR2) & 0x01)
		v2_hws_stuck++;				/* last frame's commit not taken by a vsync since */
	if (hws_phase == 2) {
		hws_h = hws_h + 1 >= HWS_SD_N ? 0 : hws_h + 1;
		a = HWS_SD_PHYS + 2 * hws_h;
	} else {
		hws_h = hws_h + 1 >= HWS_OC_N ? 0 : hws_h + 1;
		a = HWS_OC_PHYS + 2 * hws_h;
	}
	HWR(GR2 + 0x0C) = a & ~7u;
	HWR(GR2 + 0x1C) = (HWR(GR2 + 0x1C) & ~0x3Fu) | ((a & 7) >> 1);
	HWR(GR2) |= 0x01;				/* IBUS_VEN only: FLM group */
}

/* watchdog for paths that do not flip: call from v2_flip_sleep / the draw filter */
static void hws_watch(void)
{
	if (hws_on && now_ms() - hws_last_ms > 100)
		hws_off(HWS_OFF_WDOG);
}

static char *hws_u(char *p, u32 v)
{
	char b[10];
	int n = 0;
	do { b[n++] = '0' + v % 10; v = udiv(v, 10); } while (v && n < 10);
	while (n)
		*p++ = b[--n];
	return p;
}

/* the hole (both GR3 buffers get it: drawn every frame while on) + "HS<p> s<setups> u<stuck>
 * l<latch timeouts> g<gap max> t<setup ms> v<vbuf hex-ish> w<why>" under it */
static void hws_paint(void)
{
	char s[64], *p = s;
	int w = hws_phase == 3 ? HWS_OC_W : HWS_SD_W, h = hws_phase == 3 ? HWS_OC_H : HWS_SD_H;
	if (hws_on)
		fill(HWS_X, HWS_Y, w, h, 0x0001);
	if (!hws_on && !v2_hws_setups)
		return;
	*p++ = 'H'; *p++ = 'S'; p = hws_u(p, (u32)hws_phase);
	*p++ = ' '; *p++ = 'S'; p = hws_u(p, v2_hws_setups);
	*p++ = ' '; *p++ = 'U'; p = hws_u(p, v2_hws_stuck);
	*p++ = ' '; *p++ = 'L'; p = hws_u(p, v2_hws_lto);
	*p++ = ' '; *p++ = 'G'; p = hws_u(p, v2_hws_gap);
	*p++ = ' '; *p++ = 'T'; p = hws_u(p, v2_hws_setup_ms);
	*p++ = ' '; *p++ = 'V'; p = hws_u(p, v2_hws_vbuf);
	*p++ = ' '; *p++ = 'W'; p = hws_u(p, v2_hws_why);
	*p++ = ' '; *p++ = 'R'; p = hws_u(p, v2_hws_gr3re);
	*p = 0;
	fill(HWS_X, HWS_Y + HWS_SD_H, 260, 14, C_BLACK);
	text(&f_s, HWS_X, HWS_Y + HWS_SD_H, s, 0xFFE0, C_BLACK);
}

#endif /* V2_HWS2 */
