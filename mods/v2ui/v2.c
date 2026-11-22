/* SPDX-License-Identifier: Apache-2.0 */
/*
 * V2 UI for the CDJ-2000NXS2 display (SH7269, SH-2A, big-endian): our own
 * renderer and a CDJ-3000-style PLAYER screen (re/V2_UI_DESIGN.md, phases
 * P1/P2; data: re/V2_PROTOCOL.md; look: re/CDJ3000X_EMU_MINING.md and the real
 * CDJ-3000 frames in re/cdj3k_refs/).
 *
 * v2_paint(plane, base) runs from entry.S in front of the stock VDC base write
 * 0x0E526626 -- the moment the flip hands the VDC5 a finished frame that is
 * not on the panel yet (the stock flip, or gr3direct's early write). For the
 * player screen it paints our chrome, texts, boxes and overview over that
 * frame; the stock scrolling waveform band (y BAND_Y0..BAND_Y1) is kept.
 * Every other screen -- browse, INFO, UTILITY, SHORT CUT, TAG LIST over the
 * player, boot and the update screen -- is left to stock untouched.
 */
#include "v2.h"
/* V3f: the blob is built -Os (GUI room); the per-pixel / per-glyph / per-column paths stay -O2 */
#define HOT __attribute__((optimize("O2")))
#if defined(V2_HWBAND) && defined(V2_SUBPX)
/* V4: the hardware band's rings sit in the phase-ring area and the GUI section has no room for both: HWBAND
 * builds leave SUBPX out (its software fallback steps whole columns, as V3rc8o) */
#undef V2_SUBPX
#endif
#if defined(V2_HWBAND) && !defined(V2_HWBAND_NOSUB)
#define V2_HWSUB	/* V4s: the hardware band's half-pixel phase ring (hwband.inc), ph_blend shared with SUBPX */
#endif
#ifdef V2_HWBAND
#define HOTSW		/* V4: the software band is the fallback only -- -Os (GUI room) */
#else
#define HOTSW HOT
#endif
#include "../v2ui_assets/v2ui_atlas.h"

#define W 800
#define BAND_Y0 122		/* stock centre waveform + its beat ticks */
#define BAND_Y1 306

/* MAIN's models in GUI RAM (re/V2_PROTOCOL.md) */
/* every model below is filled by other code or by DMA (which does not keep the CPU's D-cache coherent):
 * read through the uncached mirror (+0x20000000) so we never draw a stale cached copy (re/V2_P4.md) */
#define MODEL ((const volatile u8 *)0x2E5B829C)	/* UI model (0x39) */
#define DECK ((const volatile u8 *)0xFFF88000)	/* heartbeat (0x03), wire offset - 4 */
#define OV_REC ((const volatile u8 *)0x2E5B748C)	/* overview: 600 x 6 B records */
#define OV_HDR ((const volatile u8 *)0x2E5B747C)	/* 0x35 copy: +4 u32 == 1 when valid (records at +0x10) */
#define OV_HIDE (*(const volatile u32 *)0x2E592D7C)
/* V3a (re/V3_PROGRESS.md): 0x35 sets 1, 0x34 (mono overview) sets 0 */
#define OV_COLOUR (*(const volatile u32 *)0x2E592D80)
/* HALFBLUE (V4n41): UTILITY WAVEFORM FULL / HALF (modsmenu wh_v, heartbeat +0x18 'K' word bit 2 = HALF) picks the
 * CDJ-3000's two player-overview shapes (: the column drawn up from the centre row and mirrored, or
 * bottom-anchored); only the overview strip and the browse rows' mini waveforms follow it -- the detail band and
 * the master mini-wave are always the mirrored (3000) band.
 * OVSHAPE4 (user, deck V4n52, 2026-11-18): ov_full = 1 is the MIRRORED look and is now selected by the HALF label;
 * the FULL label (default, wh_v 0) = bottom-anchored, full height. The polarity is decided ONLY at the 'K' word
 * below (ov_full = bit 2); every consumer (overview, browse rows, UTILITY / SHORT CUT strip) follows ov_full.
 * Bottom-anchored until a 'K' word says HALF */
static int ov_full = 0;
#define OV_FULL ov_full
/* V3a: the detail waveform's size in bytes (0x37 / 0x36 header +16; 0x1EA60 for a 62,768-entry track).
 * 0x2F zeroes it at every load; a track without rekordbox analysis gets a 0x36 header with size 0 and an
 * empty beat grid (0x2B count 0), and its overview only from the deck's own analysis (0x34, as it plays).
 * Spec (user): such a track shows NOTHING analysis-derived (no band, overview, grid, phase ticks). */
#define DET_LEN (*(const volatile u32 *)0x2E5BC26C)
static int ana;		/* the loaded track has its rekordbox analysis (DET_LEN != 0), per frame */
#define UPD_STATE (*(const volatile u32 *)0x2E5B6B40)	/* 3 in update mode (tupdate), 0 otherwise */
#define MARKS ((const volatile u8 *)0x2E604F10)	/* 0x32 marker model: 16-B records */
#define N_MARKS 19		/* 0 = loop / cue, 1..18 = cues (RX3: 18 cue slots); later records are other data (re/V2_P4.md) */
#define ART_BIG ((const volatile u16 *)0x2E619170)	/* side 0 slot 0: 113 x 121, stride 120 */
#define WPOOL ((volatile u8 *)0x2F6C0690)	/* window pool: 256 x 160 B */
#define LAYER0 0x0F6A6964
#define SIDE1 0x132C		/* model: side 1 = side 0 + 0x132C; slots 0x220 apart */
#define SLOT(side, k) (MODEL + 0x54 + (side) * SIDE1 + (k) * 0x220)
#define SMALL_ART(k) ((const volatile u16 *)(0x2E605660 + (k) * 0x1180))	/* side 0 row images */

/* RGB565, measured on CDJ-3000 3.2x frames */
#define C_BLACK 0x0000
#define C_WHITE 0xFFFF
#define C_BAR 0x18C3		/* #191919 */
#define C_NAVY 0x098B		/* #0F325F source tile */
#define C_FRAME 0xCE59		/* #C8C8C8 */
#define C_RED 0xF800
#define C_OR 0xFA23		/* #FF4619 ±range, MT */
#define C_MASTER 0xFB84		/* #FF7323 (V3rc8t claims audit: skin master BPM frame / BEAT LOOP pads; was #FF6700) */
#define C_SEL 0x03FC		/* #007DE1 */
#define C_PANEL 0x2104		/* #202020 overlay panel */
#define C_GREY 0x7BEF		/* #7D7D7D */
#define C_CK1 0x3186		/* #323232 */
#define C_CK2 0x2124		/* #232323 */
#define C_PHO 0xFB80		/* #FF7300 phase meter, master row */
#define C_PHB 0x03FF		/* #007DFF phase meter, own row */
#define C_ART 0x4A69		/* artwork frame */
#define C_ROW2 0x2945		/* #282828 alternate row */
#define C_UNF 0x632D		/* #64646E selection without focus */
#define C_PANE 0x10A2		/* #141414 right pane */
#define C_HDR 0x39E7		/* #3C3C3C column header */
#define C_LBL 0xBDF7		/* #BEBEBE */
#define C_DIM 0x8410		/* informational item */
#define C_GREEN 0x07E0		/* #00FF00 loaded row / default hot cue (V3rc8t claims audit: NT_ColorList c013; was #00C800) */
#define C_KEYB 0x2125		/* #21242A keyboard key */
#define C_KEYB2 0x3A08		/* #394142 function key */
#define C_TILE 0x2945		/* #282828 */
#define C_UTF 0x2230		/* #254580 UTILITY focus (3000) */
#define C_UTL 0x94B2		/* #969696 UTILITY tile label (3000 skin) */
#define C_SCOFF 0x39E7		/* #3C3C3C SHORTCUT button off (3000 skin img_btn*Sc_#off) */
#define C_FRAME_D 0x4A69	/* #4A4D4A loop bar button frame */
/* overview (unplayed / played) */
#define C_LO 0x02BD
#define C_MI 0xFD00
#define C_HI 0xFFFF
#define C_LOP 0x0215
#define C_MIP 0xCBC0
#define C_HIP 0xBDF7

static u16 *fb;
/* V3rc5 (re/V3_PROGRESS.md "V3rc5"): SMOOTH copies only the 16-row bands of the canvas that changed. Every
 * primitive that writes fb marks its rows here (30 bands, bit b = rows 16b..16b+15); paint_frame keeps a
 * per-GR3-buffer pending mask (sm_pend) and copies those bands into the buffer about to latch. */
static u32 dmask;
static u32 now_ms(void);
static u32 cpu_load;	/* V3rc8: GUI busy % (draw + copy) over the last second; > 80 shows on the player */
#ifdef V2_HUD
u32 v2_pf[4];	/* V3rc8 TEST: ms per second in band / overlays scan / deck area / meter */
u32 v2_pstall;	/* V3rc8 TEST: the longest heartbeat-position stall (ms) since the HUD last read it */
u32 v2_qmax;	/* V3rc8 TEST: the longest frame (draw + copy, ms) since the HUD last read it */
u32 v2_pfx[4], v2_pff[4];	/* this frame's section ms, and the max a frame within the HUD's second */
#define PF0(i) u32 pf_t##i = now_ms()
#define PF1(i) do { u32 pd = now_ms() - pf_t##i; v2_pf[i] += pd; v2_pff[i] += pd; } while (0)
#else
#define PF0(i)
#define PF1(i)
#endif
#define SM_ALL 0x3FFFFFFFu
static int dm_off;	/* V3rc8r: drawing straight into a GR3 buffer (band direct): no canvas marks */
static void dmark(int y, int h)
{
	if (dm_off)
		return;
	if (y < 0) { h += y; y = 0; }
	if (y + h > 480) h = 480 - y;
	if (h > 0)
		dmask |= (2u << ((y + h - 1) >> 4)) - (1u << (y >> 4));
}
static int v2_chg, pend, spread_id = -1;	/* V3f frame-on-change (see need, paint_frame) */

/* V3rc4 (re/V3_PROGRESS.md "V3rc4"): SCREEN MODE -- the display present strategy, published by MAIN
 * (modsmenu present_v) in heartbeat +0x14 bits 0-1, toggled by a SHORT CUT tile (sm_cycle). The user's
 * real deck shows a PERIODIC flicker (every few seconds, on load and on the playing waveform, all three
 * waveform types) that the emu never shows (the real panel's latch timing is the unmodelled 3rd display
 * model). SMOOTH fixes it: compose the whole frame into an off-screen SDRAM canvas, then copy the COMPLETE
 * frame to the GR3 buffer the VDC is about to latch -- one whole-frame blit, so the panel never scans a
 * partial / mid-draw buffer, and both GR3 buffers converge to the same finished frame. */
#define PM_SMOOTH 0	/* offscreen compose + whole-frame copy (default: the flicker fix) */
#define PM_FAST 1	/* V3f frame-on-change, per-region direct paint into the shown buffer (the reference) */
#define PM_PLUS 2	/* V3rc5: SMOOTH + the band scrolled from a time-smoothed position (SMOOTH+); was STEADY in V3rc4 */
#if defined(V2_HWBAND) && !defined(V2_PM_FORCE)
#define present_mode PM_PLUS	/* V4: the only present mode since V3rc8q -- a constant (GUI room) */
#else
static int present_mode = PM_PLUS;	/* V3rc8: SMOOTH+ by default */
#endif
u32 v2_sm_frames, v2_sm_rows, v2_sm_miss, v2_sm_miss_y, v2_cp_ms, v2_heal, v2_heal_y;
#ifdef V2_SM_CHECK
u32 v2_dh[8], v2_ft[16], v2_pe[16];
u32 v2_band_hits[30];	/* gate-only scroll cadence: column step, frame ms, entries per frame */
#endif	/* V3rc5: SMOOTH band-copy stats (bench / gate) */
/* the off-screen canvas: 800 x 480 x 2 = 768,000 B (0xBB800) in proven-free SDRAM (re/PERF_BROWSE_PLAY.md
 * §7), clear of the ring (0x0C780000..0x0C7C4A40), the overview cache (0x0C800000..~0x0C81B000), SNAP
 * (0x0C840000), ART_C (0x0C880000), the phase scratch (0x0C900000..0x0C9BB800), w8fetch (0x0C A00000) and
 * POP_BAK (0x0CB00000..0x0CB18000): 0x0CC00000..0x0CCBB800 is unused (ends before the 0x0CD00000 top of
 * the window). A fixed address (no malloc, so nothing is allocated in update mode). Uncached mirror. */
#ifdef V2_CANVAS_CACHED
#define CANVAS ((u16 *)0x0CC00000)	/* V3rc8 TEST: the cached alias (only our CPU reads the canvas: no coherency
					 * issue; FAST never touches it, so no alias mixing) */
#else
#define CANVAS ((u16 *)0x2CC00000)
#endif

/* Day Mode = UTILITY > LIGHT MODE (the one non-3000 feature): a light theme for every screen we
 * draw, one remap of the night palette applied in the primitives (see read_flags). */
static int day;
static int day_full;	/* LIGHT MODE = FULL: the waveforms light too (LIGHT keeps them on black) */
static int bpm_dec;	/* UTILITY > BPM DECIMALS: two decimals with the pitch applied */

/* UTILITY > LIGHT MODE / BPM DECIMALS: MAIN's modsmenu saves them (settings byte 7 bits 4/5) and
 * publishes them in the heartbeat's unused word +0x54 as 0x4C47 ("LG") << 16 | flags (bit 0 LIGHT
 * MODE, bit 1 BPM DECIMALS). Without the magic the last valid flags stay (OFF before the first). */
static int hb_valid;	/* MAIN's heartbeat carries our flags: MAIN is up, the boot animation is over */
/* V3d: the LINK master's status, published by MAIN's mm_publish (modsmenu) from its status table in two
 * slots of heartbeat +0x54 that alternate: cue countdown in beats (0x1FF none), flags (bit 0 valid, bit 1
 * playing, bit 2 the master plays THIS deck's track) and its beat number (low byte + (n + 128) >> 8) */
static u32 ms_cd = 0x1FF, ms_flags, ms_blo, ms_bhi;
static u32 master_beatnum(void)
{
	u32 base = (ms_bhi << 8) - 128;
	return base + ((ms_blo - base) & 0xFF);
}
static int wave_type;		/* V3b: 0 3BAND, 1 RGB, 2 BLUE (published by MAIN, see wave_col) */
/* V3e1: the phase meter's style, cycled by a tap on the meter (MAIN modsmenu pm_tap, saved, published in
 * slot 1 bits 10-11 = ms_flags bits 3-4): 0 PHASE (3000), 1 WAVEFORM (3000), 2 4 BARS (the NXS2 classic) */
static int pm_style;
#ifdef V3E2
#define V3E2_TX (RAIL_W + 150)
#else
#define V3E2_TX (RAIL_W + 150)
#endif
static u32 v3e_w;		/* V3e2: heartbeat +0xE8 -- bits 16-23 rows 1..8 loaded on another deck, bits 0-14 the
				 * row preview (bit 14 playing, bits 10-13 row 1..8, bits 0-9 column 0..599) */
#define W8BUF ((const volatile u8 *)0x2CA00000)	/* V3e2: mods/w8fetch's buffer (uncached mirror) */
#define V3E_ELSE(k) ((v3e_w >> (16 + (k))) & 1)
#define V3E_PV_ROW (((v3e_w >> 14) & 1) ? (int)((v3e_w >> 10) & 15) : 0)
#define V3E_PV_COL (v3e_w & 0x3FF)
/* V3e3: MAIN's second word, heartbeat +0x14 (modsmenu v3e_pub2), two pages that alternate (bit 28), magic
 * bits 29-31 = 5. Page 0 (deck): bit 0 PLAY MODE SINGLE, bit 1 AUTO CUE on, bits 2-4 BEAT JUMP value index
 * (0 none, 1..7 = 1/2 1 2 4 8 16 32), bit 5 REV, bit 6 jog mode VINYL, bit 7 page 0 valid, bits 8-12 the
 * LINK master's key (key_code: Camelot n * 2 + B, 0 unknown), bits 16-19 the medium's background colour
 * (0 none, 1..8 PINK..PURPLE). Page 1 (browse): bits 0-15 the first visible row's list index + 1 (0 none). */
static u32 v3e_d, v3e_b;
/* V4n36 trace: MAIN's kill switches for the display (modsmenu sl_pub: heartbeat +0x18 = 0x4B << 24 | bit 0 MASTER
 * WAVEFORM ON | bit 1 HW BAND LAYER ON, while SLIP does not use the word); kept from the last one seen (0x100 set),
 * an older MAIN / none seen = every feature ON */
static u32 g_kill;
static int g_kcents;	/* KSAMT (V4n43): KEY SYNC cents (-50..+49) from the 0x4B word bits 8-15 (bit 16 valid; kept over SLIP) */
#define KILL_MW ((g_kill & 0x101) == 0x100)
#define KILL_HB ((g_kill & 0x102) == 0x100)
#define V3E_SINGLE (v3e_d & 1)
#define V3E_ACUE ((v3e_d >> 1) & 1)
#define V3E_BJ ((int)((v3e_d >> 2) & 7))
#define V3E_REV ((v3e_d >> 5) & 1)
#define V3E_VINYL ((v3e_d >> 6) & 1)
#define V3E_MKEY ((int)((v3e_d >> 8) & 31))
#define V3E_MCOL ((int)((v3e_d >> 16) & 15))
#define V3E_LJT ((int)((v3e_d >> 20) & 31))	/* V3rc2: the letter jump's target letter (1..26 A..Z), 0 none */
#define V3E_KBH ((int)((v3e_d >> 25) & 1))
/* V4n6: a list row pressed (touch, a tap not yet released or dragged): its row 0..7, -1 none (modsmenu v3e_pub2) */
#define V3E_PROW (((v3e_d >> 26) & 1) ? (int)((v3e_d >> 13) & 7) : -1)
/* TOUCH (V4n41, modsmenu v3e_pub2 page 0 bit 27): the browse header's PREVIEW tile is OFF (a tap toggles it; set = OFF,
 * an older MAIN reads ON) -- touch_audio row_touch then previews nothing */
#define V3E_PVOFF ((v3e_d & 0x08000080) == 0x08000080)
/* TOUCH (V4n41): stock's GRID ADJUST mode (MAIN 0x0A35F3E0, hold PUSH or the ZOOM - GRID tap) reaches the display as
 * heartbeat +0xD8 = 1 (emu keysweep: the only word that changes) */
#define GA_MODE (u32be(DECK + 0xD8) == 1)
static int ga_tch;	/* TOUCH (V4n41): MAIN (sl_pub, heartbeat +0x18 bit 3): a GRID ADJUST tile drives stock's GRID ADJUST pop-up */
#ifdef V2_KITLOG	/* R21 deck kit (DEV only, with V2_HUD + V2_USBLOG): a second record a second, 'KIT1' (kit_push) */
#define KIT(x) x
static u32 kit_gr, kit_gcur, kit_cursor = 0xFFFFFFFF, kit_ink, kit_inkreq, kit_zgeo, kit_zhide, kit_zown, kit_sdraw, kit_pblit;
#else
#define KIT(x)
#endif
#define C_PRESS 0x632C		/* #646464: the 3000's pressed state */	/* V3rc3: SEARCH's keyboard hidden (a knob move): the 3000's results view */
#define V3E_ROW0 ((int)(v3e_b & 0xFFFF))
#ifdef V2_KEYSHIFT
/* V4k: KEY SHIFT (MAIN modsmenu ks_pub, heartbeat +0x14 page 1): bit 0 KEY SHIFT ON, bits 1-5 semitones + 12,
 * bit 6 panel open, bit 7 REKORDBOX BUTTON = KEY SHIFT, bit 15 valid */
#define KS_ON ((v3e_b & 0x8001) == 0x8001)
#define KS_SEMI (KS_ON ? (int)((v3e_b >> 1) & 31) - 12 : 0)
#define KS_PANEL (KS_ON && ((v3e_b >> 6) & 1))
#define KS_RBM ((v3e_b & 0x8080) == 0x8080)
#define KS_KSYNC (KS_ON && ((v3e_b >> 8) & 1))	/* V4n: KEY SYNC on (mods/keyshift ksy_on) */
#define KS_KREF (KS_ON && ((v3e_b >> 9) & 1))	/* V4n: a K.SYNC press refused (no key / no master) */
#define KS_AMT_H() ((u32)KS_SEMI * 1000u + (u32)(KS_KSYNC ? g_kcents + 500 : 0))	/* KSAMT (V4n43): the amount's hash */
/* V4n27b: UTILITY BEAT NUMBERS / GRID ADJUST OFF (modsmenu ks_pub bits 12 / 13,
 * set = OFF; an older MAIN without them leaves both 0 = ON) */
#define BN_OFF ((v3e_b & 0x9000) == 0x9000)
#define GA_OFF ((v3e_b & 0xA000) == 0xA000)
/* V4n32 (modsmenu v32_pub, +0x14 page 1): bit 14 HOT CUE COLOR OFF (the stock UTILITY item; set = OFF, an older
 * MAIN reads ON), bits 16-18 this deck's player number as MAIN keeps it (1..6, 0 none: players 5/6), bits 19 / 20
 * this deck's own SD / USB mounted */
#define HCC_OFF ((v3e_b & 0xC000) == 0xC000)
#define V32_PN ((v3e_b & 0x8000) ? (u32)((v3e_b >> 16) & 7) : 0u)
#define V32_OWN_SD ((v3e_b & 0x8000) ? (int)((v3e_b >> 19) & 1) : 0)
#define V32_OWN_USB ((v3e_b & 0x8000) ? (int)((v3e_b >> 20) & 1) : 0)
#define V32_Z6 ((v3e_b & 0x8000) ? (int)((v3e_b >> 21) & 1) : 0)	/* V4n32: the sixth zoom (zm_knob) */
#define V32_LPL ((v3e_b & 0x8000) ? (u32)((v3e_b >> 22) & 7) : 0u)	/* the loaded track's source player / slot */
#define V32_LSL ((v3e_b & 0x8000) ? (u32)((v3e_b >> 25) & 3) : 0u)
/* V4n36 (modsmenu v32_pub, +0x14 page 1 bit 27): UTILITY KEY FORMAT = CLASSIC (set = CLASSIC; an older MAIN
 * reads ALPHANUMERIC, the default) */
#define KF_CLASSIC ((v3e_b & 0x08008000) == 0x08008000)
#else
#define KF_CLASSIC 0
#define BN_OFF 0
#define GA_OFF 0
#define HCC_OFF 0
#define V32_PN 0u
#define V32_OWN_SD 0
#define V32_OWN_USB 0
#define V32_Z6 0
#define V32_LPL 0u
#define V32_LSL 0u
#endif
static int ph_left;		/* V3c: WAVEFORM CURRENT POSITION = LEFT (published by MAIN, bit 5) */
static void read_flags(void)
{
	static int valid, f_light, f_dec, f_full, f_wave, f_left;
	u32 f = (u32)DECK[0x54] << 24 | (u32)DECK[0x55] << 16 | (u32)DECK[0x56] << 8 | DECK[0x57];
	if ((f >> 24) == 0x4C) {	/* V3d: magic 0x4C; bits 6-23 the LINK master's status slots */
		if (f & 0x40) {
			ms_flags = (f >> 7) & 0x1FF;
			ms_bhi = (f >> 16) & 0xFF;
			pm_style = (ms_flags >> 3) & 3;
			if (pm_style > 2)
				pm_style = 0;
		} else {
			ms_cd = (f >> 7) & 0x1FF;
			ms_blo = (f >> 16) & 0xFF;
		}
		valid = 1;
		hb_valid = 1;
		f_light = f & 1;
		f_dec = (f >> 1) & 1;
		f_full = (f >> 2) & 1;
		f_wave = (f >> 3) & 3;		/* V3b: WAVEFORM COLOR 0 3BAND, 1 RGB, 2 BLUE */
		f_left = (f >> 5) & 1;		/* V3c: WAVEFORM CURRENT POSITION 0 CENTER, 1 LEFT */
	}
	ga_tch = 0;
	if (DECK[0x18] == 0x4B) {	/* V4n36 trace: the kill switches (g_kill) */
		g_kill = 0x100u | (DECK[0x1B] & 3);
		g_kcents = (DECK[0x19] & 1) ? (int)(signed char)DECK[0x1A] : 0;	/* KSAMT (V4n43) */
		ga_tch = (DECK[0x1B] >> 3) & 1;	/* TOUCH (V4n41) */
		ov_full = (DECK[0x1B] >> 2) & 1;	/* OVSHAPE4: bit 2 = HALF label = mirrored; FULL = bottom */
	}
#ifdef V3E2
	{	/* V3e2: MAIN's word +0xE8 (modsmenu v3e_pub): rows on another deck, the row preview */
		u32 w = (u32)DECK[0xE8] << 24 | (u32)DECK[0xE9] << 16 | (u32)DECK[0xEA] << 8 | DECK[0xEB];
		v3e_w = (w >> 29) == 7 ? w : 0;	/* magic: bits 29-31 = 7 */
		w = (u32)DECK[0x14] << 24 | (u32)DECK[0x15] << 16 | (u32)DECK[0x16] << 8 | DECK[0x17];
		if ((w >> 29) == 5) {		/* V3e3: +0x14, two alternating pages */
			if ((w >> 28) & 1)
				v3e_b = w & 0x0FFFFFFF;
			else
				v3e_d = w & 0x0FFFFFFF;
#if !defined(V2_HWBAND) || defined(V2_PM_FORCE)
			present_mode = PM_PLUS;	/* V3rc8q: the only present mode (SCREEN MODE removed; MAIN bits 0-1 ignored) */
#endif
		} else
			v3e_d = v3e_b = 0;
	}
#endif
#ifdef V2_PM_FORCE
	present_mode = V2_PM_FORCE;	/* gate-only: force a SCREEN MODE for emu A/B (the deck uses the tile) */
#endif
	ph_left = valid && f_left;
	wave_type = valid && f_wave < 3 ? f_wave : 0;
	day = valid && f_light;
	day_full = day && f_full;
	bpm_dec = valid && f_dec;
}

static int in_wave;	/* drawing a waveform with LIGHT MODE = FULL: the light-background palette */
HOT static u16 dm(u16 c)
{
	if (!day)
		return c;
	if (in_wave)	/* FULL (re/RB7_WAVEFORM_MINING.md §10): contrast-tuned on #F2F3F5 */
		switch (c) {
		case 0x0000: return 0xF79E;	/* panel #F2F3F5 */
		case 0x02BD: return 0x0218;	/* low #0040C0 */
		case 0xC320: return 0xD300;	/* centre mid #D06000 */
		case 0xFD00: return 0xDB40;	/* overview mid #D86A00 */
		case 0xF75A: return 0x2125;	/* centre high #23262E */
		case 0xFFFF: return 0x2966;	/* overview high #2A2D35 */
		case 0x0215: case 0xCBC0: case 0xBDF7: return 0x9D15;	/* played #9AA0A8 */
		}
	switch (c) {
	case 0x0000: return 0xF79E;	/* black bg -> #F0F0F0 */
	case 0xFFFF: return 0x1082;	/* white text / overview high -> #101010 */
	case 0x18C3: return 0xDEFB;	/* bars */
	case 0x2945: return 0xE73C;	/* alternate row, tiles */
	case 0x10A2: return 0xF7BE;	/* panes */
	case 0x39E7: return 0xCE79;	/* column header */
	case 0xCE59: return 0x528A;	/* box frames */
	case 0xBDF7: return 0x528A;	/* labels, played high */
	case 0x7BEF: return 0x6B4D;
	case 0x8410: return 0x7BCF;
	case 0x3186: return 0xD69A;	/* checker */
	case 0x2124: return 0xE71C;
	case 0x4208: return 0xB5B6;	/* dividers */
	case 0x2125: return 0xD6DC;	/* keyboard keys */
	case 0x3A08: return 0xBE39;
	case 0x4A69: return 0xA534;	/* artwork frame */
	case 0x632D: return 0xA515;	/* unfocused selection */
	case 0x2230: return 0xB65C;	/* V3rc6: UTILITY focus -> light blue */
	case 0x94B2: return 0x528A;
	case 0xF75A: return 0x39E7;	/* 3-band high (cream) -> dark grey on the light band */
	}
	return c;
}

static void icon_scaled(int a, int x0, int y0, int dw, int dh, u16 fg, u16 bg);
static int slip_on(void);
static int deck_playing(void);
/* NSFIX (deck 2 V4n55L, paused, CUE / needle search with Link Cue on: a black box with stale ".mmm" digits,
 * overview and a green needle marker stayed over the bottom): ns_force = this frame sends the bottom rows of the
 * canvas to both GR3 buffers (and redraws the bottom regions in FAST); ns_live = the needle marker may show */
static int ns_force, ns_live;
#define NS_BANDS (SM_ALL & ~((1u << 19) - 1))	/* canvas bands 19..29 = rows 304..479 */

HOT static u32 udiv(u32 n, u32 d)
{
	u32 q = 0, r = 0;
	int i;
	for (i = 31; i >= 0; i--) {
		r = (r << 1) | ((n >> i) & 1);
		if (r >= d) {
			r -= d;
			q |= 1u << i;
		}
	}
	return q;
}

static u32 u16be(const volatile u8 *p) { return (u32)p[0] << 8 | p[1]; }
static u32 u32be(const volatile u8 *p)
{
	return (u32)p[0] << 24 | (u32)p[1] << 16 | (u32)p[2] << 8 | p[3];
}

/* ---- primitives ---- */

HOT static void fill(int x, int y, int w, int h, u16 c)
{
	u32 c2;
	int j;
	c = dm(c);
	c2 = (u32)c << 16 | c;
	if (x < 0) { w += x; x = 0; }
	if (y < 0) { h += y; y = 0; }
	if (x + w > W) w = W - x;
	if (y + h > 480) h = 480 - y;
	if (w <= 0 || h <= 0)
		return;
	dmark(y, h);
	for (j = 0; j < h; j++) {
		u16 *p = fb + (y + j) * W + x;
		int n = w;
		if ((u32)p & 2) { *p++ = c; n--; }
		while (n >= 2) { *(u32 *)p = c2; p += 2; n -= 2; }
		if (n) *p = c;
	}
}

/* V3rc1: n pixels of c (no day-mode mapping: the band's own colours), 32-bit stores */
HOT static void fill16(u16 *p, int n, u16 c)
{
	u32 c2 = (u32)c << 16 | c;
	if (n > 0 && ((u32)p & 2)) { *p++ = c; n--; }
	while (n >= 2) { *(u32 *)p = c2; p += 2; n -= 2; }
	if (n > 0) *p = c;
}
/* P9: n pixels, src -> dst (the band's ring copy, 140 k pixels a frame): 32-bit stores, unrolled */
typedef u32 __attribute__((may_alias)) u32a;
HOT static void cp16(u16 *dst, const u16 *src, int n)
{
	if (n > 0 && ((u32)dst & 2)) { *dst++ = *src++; n--; }
	if (!((u32)src & 2)) {
		u32a *d = (u32a *)dst;
		const u32a *q = (const u32a *)src;
		while (n >= 8) { d[0] = q[0]; d[1] = q[1]; d[2] = q[2]; d[3] = q[3]; d += 4; q += 4; n -= 8; }
		while (n >= 2) { *d++ = *q++; n -= 2; }
		dst = (u16 *)d; src = (const u16 *)q;
	} else {
		/* V3rc8r: src odd, dst even -- aligned 32-bit loads, pixels re-paired by shifts (was 4 u16 loads per 2
		 * words: the band copy took this path whenever ring_head was odd, half the time) */
		u32a *d = (u32a *)dst;
		if (n >= 4) {
			const u32a *q = (const u32a *)(src - 1);	/* big-endian: low half of q[0] = src[0] */
			u32 w0 = *q++;
			while (n >= 4) {
				u32 w1 = q[0], w2 = q[1];
				d[0] = w0 << 16 | w1 >> 16;
				d[1] = w1 << 16 | w2 >> 16;
				w0 = w2;
				d += 2; q += 2; n -= 4;
			}
			src = (const u16 *)q - 1;
		}
		dst = (u16 *)d;
	}
	while (n-- > 0)
		*dst++ = *src++;
}

HOT static void frame(int x, int y, int w, int h, int t, u16 c)
{
	fill(x, y, w, t, c);
	fill(x, y + h - t, w, t, c);
	fill(x, y, t, h, c);
	fill(x + w - t, y, t, h, c);
}

HOT static void checker(int x, int y, int w, int h)
{
	int i, j;
	for (j = 0; j < h; j += 4)
		for (i = 0; i < w; i += 4)
			fill(x + i, y + j, 4, 4, ((i ^ j) & 4) ? C_CK1 : C_CK2);
}

/* V4n: the 3000 skin's 2-colour pad checker (4-px squares) */
static void checker2(int x, int y, int w, int h, u16 a, u16 b)
{
	int i, j;
	for (j = 0; j < h; j += 4)
		for (i = 0; i < w; i += 4)
			fill(x + i, y + j, i + 4 > w ? w - i : 4, j + 4 > h ? h - j : 4, ((i ^ j) & 4) ? a : b);
}

/* a 16-step ramp from bg to fg, per RGB565 channel */
static u16 ramp[16];
static u16 ramp_fg = 1, ramp_bg = 1;

HOT static void set_ramp(u16 fg, u16 bg)
{
	int a;
	/* on an accent background (source tile, selection, red/orange chips) the ink stays as is */
	if (bg != C_NAVY && bg != C_SEL && bg != C_RED && bg != C_OR && bg != C_MASTER)
		fg = dm(fg);
	bg = dm(bg);
	if (fg == ramp_fg && bg == ramp_bg)
		return;
	for (a = 0; a < 16; a++) {
		int r = ((bg >> 11) * (15 - a) + (fg >> 11) * a) / 15;
		int g = (((bg >> 5) & 63) * (15 - a) + ((fg >> 5) & 63) * a) / 15;
		int b = ((bg & 31) * (15 - a) + (fg & 31) * a) / 15;
		ramp[a] = r << 11 | g << 5 | b;
	}
	ramp_fg = fg;
	ramp_bg = bg;
}

HOT static const struct glyph *glyph(const struct font *f, u32 code)
{
	int lo = 0, hi = f->n - 1;
	while (lo <= hi) {		/* the atlas is sorted by code */
		int m = (lo + hi) >> 1;
		if (f->g[m].code == code)
			return &f->g[m];
		if (f->g[m].code < code)
			lo = m + 1;
		else
			hi = m - 1;
	}
	return 0;
}

static int clip_x0;	/* V3rc8: left clip for the marquee (0 = none) */
/* draw one glyph with its cell top at y; returns the advance */
HOT static int draw_glyph(const struct font *f, int x, int y, u32 code, int xmax)
{
	const struct glyph *g = glyph(f, code);
	int r, c, stride;
	if (!g)
		g = glyph(f, '?');
	if (!g)
		return 0;
	stride = (g->w + 1) >> 1;
	dmark(y, f->h);
	for (r = 0; r < f->h; r++) {
		const u8 *src = f->px + g->off + r * stride;
		int yy = y + r;
		u16 *row;
		if (yy < 0 || yy >= 480)
			continue;
		row = fb + yy * W;
		for (c = 0; c < g->w; c++) {
			int xx = x + g->xoff + c;
			int a = (c & 1) ? (src[c >> 1] & 15) : (src[c >> 1] >> 4);
			if (a && xx >= clip_x0 && xx < xmax)
				row[xx] = ramp[a];
		}
	}
	return g->adv;
}

HOT static int text_w(const struct font *f, const char *s)
{
	int w = 0;
	for (; *s; s++) {
		const struct glyph *g = glyph(f, (u8)*s);
		w += g ? g->adv : 0;
	}
	return w;
}

HOT static int text(const struct font *f, int x, int y, const char *s, u16 fg, u16 bg)
{
	set_ramp(fg, bg);
	for (; *s; s++)
		x += draw_glyph(f, x, y, (u8)*s, W);
	return x;
}

static void text_c(const struct font *f, int cx, int y, const char *s, u16 fg, u16 bg)
{
	text(f, cx - text_w(f, s) / 2, y, s, fg, bg);
}

static void text_r(const struct font *f, int rx, int y, const char *s, u16 fg, u16 bg)
{
	text(f, rx - text_w(f, s), y, s, fg, bg);
}

/* UTF-16BE from the UI model, clipped at xmax */
HOT static void text_u16(const struct font *f, int x, int y, const volatile u8 *s, int n,
		     int xmax, u16 fg, u16 bg)
{
	int i;
	set_ramp(fg, bg);
	for (i = 0; i < n; i++) {
		u32 ch = u16be(s + 2 * i);
		if (!ch)
			break;
		if (ch == 0xFFFA || ch == 0xFFFB)
			continue;
		if (x >= xmax)
			break;
		if ((ch == 0x2606 || ch == 0x2605) && x + 18 <= xmax) {
			/* rating stars (the UI font has none): our star pictograms, 17 x 16 1:1 */
			icon_scaled(ch == 0x2605 ? V2A_RATING_STAR_FULL : V2A_RATING_STAR_EMPTY, x, y + 3, 17, 16,
				    fg, bg);
			set_ramp(fg, bg);
			x += 19;
			continue;
		}
		x += draw_glyph(f, x, y, ch, xmax);
	}
}

/* ---- icons (our own Cueline icon set, mods/v2ui_assets/icons.py, rendered at build time) ---- */

/* draw atlas asset a with its top-left at x, y: a 4-bit mask tinted fg over bg, or RGB565 with a
 * transparent key; returns its width */
HOT static int icon(int a, int x, int y, u16 fg, u16 bg)
{
	const struct v2a_rect *r;
	int i, j;
	if (a < 0 || a >= V2A_COUNT)
		return 0;
	r = &v2a_rects[a];
	dmark(y, r->h);
	if (r->kind == V2A_MASK4) {
		set_ramp(fg, bg);
		for (j = 0; j < r->h; j++) {
			const u8 *src = v2a_mask + (r->y + j) * (V2A_W / 2);
			int yy = y + j;
			if (yy < 0 || yy >= 480)
				continue;
			for (i = 0; i < r->w; i++) {
				int sx = r->x + i, xx = x + i;
				int v = (sx & 1) ? (src[sx >> 1] & 15) : (src[sx >> 1] >> 4);
				if (v && xx >= 0 && xx < W)
					fb[yy * W + xx] = ramp[v];
			}
		}
	} else {
		for (j = 0; j < r->h; j++) {
			const u8 *src = v2a_rgb + ((r->y + j) * V2A_W + r->x) * 2;
			int yy = y + j;
			if (yy < 0 || yy >= 480)
				continue;
			for (i = 0; i < r->w; i++) {
				u16 c = (u16)(src[2 * i] << 8 | src[2 * i + 1]);
				int xx = x + i;
				if (c != V2A_TRANSP && xx >= 0 && xx < W)
					fb[yy * W + xx] = c ? c : dm(0);	/* badge black -> the theme's bg */
			}
		}
	}
	return r->w;
}

/* a mask asset scaled to dw x dh */
/* V3e1: source steps by accumulation (no division per pixel: the rail / INFO placeholders cost ms) */
HOT static void icon_scaled(int a, int x0, int y0, int dw, int dh, u16 fg, u16 bg)
{
	const struct v2a_rect *r = &v2a_rects[a];
	int x, y, sy = 0, ay = 0;
	u16 b = dm(bg);
	set_ramp(fg, bg);
	dmark(y0, dh);
	for (y = 0; y < dh; y++) {
		const u8 *src = v2a_mask + (r->y + sy) * (V2A_W / 2);
		u16 *d = fb + (y0 + y) * W + x0;
		int sx = r->x, ax = 0;
		for (x = 0; x < dw; x++) {
			int v = (sx & 1) ? (src[sx >> 1] & 15) : (src[sx >> 1] >> 4);
			d[x] = v ? ramp[v] : b;
			for (ax += r->w; ax >= dw; ax -= dw)
				sx++;
		}
		for (ay += r->h; ay >= dh; ay -= dh)
			sy++;
	}
}

/* ICONS: a source pictogram (USB 21 px tall) vertically centred in the 21-px band the tiles reserve */
#define SRC_DY(a) ((21 - (int)v2a_rects[a].h) / 2)

/* the icon of a model icon id, vertically centred on cy */
static int icon_id(u32 id, int x, int cy, u16 fg, u16 bg)
{
	int a = id ? v2a_for_icon(id) : -1;
	if (a < 0)
		return 0;
	return icon(a, x, cy - v2a_rects[a].h / 2, fg, bg);
}

/* RGB565 image (native big-endian halfwords), w x h with the given stride, scaled to dw x dh */
HOT static void image(const volatile u16 *src, int w, int h, int stride, int x0, int y0, int dw, int dh)
{
	int x, y, sy = 0, ay = 0;
	dmark(y0, dh);
	for (y = 0; y < dh; y++) {
		const volatile u16 *s = src + sy * stride;
		u16 *d = fb + (y0 + y) * W + x0;
		for (ay += h; ay >= dh; ay -= dh)
			sy++;
		if (y0 + y < 0 || y0 + y >= 480)
			continue;
		if (w == dw) {		/* 1:1 (the rowwave cells) */
			for (x = 0; x < dw; x++)
				d[x] = s[x];
			continue;
		}
		{
			int sx = 0, ax = 0;
			for (x = 0; x < dw; x++) {
				d[x] = s[sx];
				for (ax += w; ax >= dw; ax -= dw)
					sx++;
			}
		}
	}
}

/* UTF-16 length of a model text without the trailing zeros */
static int u16len(const volatile u8 *slot) { return (int)u16be(slot + 0x28); }
/* V3rc5 (user: MENU bugs): stock's MENU pop-up (+0x0F set, side 1 = title + items) also opens on the player
 * (0x02: LOAD PREVIOUS TRACK) and over INFO (0x06: SORT), not only on lists (0x04); side 1 then holds the
 * pop-up instead of the key / the INFO fields */
static int pop_on(void)
{
	int s = MODEL[7];
	if (s == 0x02 && ga_tch)	/* TOUCH: that pop-up is not drawn (the tile's own action; no menu flash) */
		return 0;
	return MODEL[0x0F] && (s == 0x02 || s == 0x04 || s == 0x06);
}
/* 2.01-a displayer (re/V2_OVERLAYS.md "z 128"): every stock MENU pop-up lives in ONE window, z 128 (429,12
 * 353x277), and stock copies it onto the frame after our paint while it is up.
 * R21D5 (owner, deck: a big WHITE box with coloured dots -- stock's never-drawn SDRAM -- over UTILITY's value pane
 * in R21D3, which handed z 128 to stock for any +0x0F it did not render): default = 1.92. z 128 stays ours
 * (O_OWN, popup() + popup_sync draw our pane there) unless the pop-up is one we VERIFIED stock draws (stock_title:
 * REMOVE ALL TRACKS, emu R21D2..D4; MY SETTINGS, deck-confirmed 1.92). Even then stock's surface is shown only once
 * stock has really drawn it this time (pst_undrawn, see pop_stock_blit); until then our own pane is drawn as 1.92.
 * Titles come from one English-only table in MAIN (main_unpacked 0xA8xxx), so matching them is language-safe. */
static int ustr_eq(const char *a, int an, const volatile u8 *t, int n);
static int pst_undrawn = 1;	/* the stock pop-up's surface does not hold stock's drawing (yet): ours instead */
static void pst_stamp(void);
static int stock_title(void)
{
	const volatile u8 *t = SLOT(1, 0);
	if (ustr_eq("MY SETTINGS", 11, t + 0x2A, u16len(t)))	/* any screen, as the 1.92 fix */
		return 1;
	return pop_on() && ustr_eq("REMOVE ALL TRACKS", 17, t + 0x2A, u16len(t));
}
static int pop_ours(void)	/* we draw the MENU pop-up (popup() + popup_sync) */
{
	return pop_on() && (!stock_title() || pst_undrawn);
}

/* ---- number formatting ---- */

static char *put2(char *p, u32 v) { *p++ = '0' + udiv(v, 10) % 10; *p++ = '0' + v % 10; return p; }

static void fmt_mmss(char *p, u32 ms)
{
	u32 s = udiv(ms, 1000), m = udiv(s, 60);
	if (m > 99) m = 99;
	p = put2(p, m);
	*p++ = ':';
	p = put2(p, s - m * 60);
	*p = 0;
}

static void fmt_ms3(char *p, u32 ms)
{
	u32 r = ms - udiv(ms, 1000) * 1000;
	*p++ = '.';
	*p++ = '0' + udiv(r, 100);
	*p++ = '0' + udiv(r, 10) % 10;
	*p++ = '0' + r % 10;
	*p = 0;
}

/* ---- the player screen ---- */

/* V3e3 (audit P6): the loaded track's artwork, kept from the player screen's header (model slot 0) for the
 * player INFO sheet, where MAIN sends none (free SDRAM, re/V2_P4.md) */
#define ART_C ((u16 *)0x0C880000)
static u32 art_tag;
static u32 art_tid(void) { return (u32be(DECK + 0x60) * 0x01000193 ^ u32be(DECK + 0x7C)) | 1; }
static void art_keep(void)
{
	cp16(ART_C, (const u16 *)ART_BIG, 120 * 121);
	art_tag = art_tid();
}
/* track artwork: the big image of model slot 0 (113 x 121 RGB565, stride 120), scaled */
static void artwork(int x0, int y0, int w, int h)
{
	int x, y;
	dmark(y0, h);
	for (y = 0; y < h; y++) {
		const volatile u16 *src = ART_BIG + udiv(y * 121, h) * 120;
		u16 *dst = fb + (y0 + y) * W + x0;
		for (x = 0; x < w; x++)
			dst[x] = src[udiv(x * 113, w)];
	}
}

/* G2: the loaded track's artwork from MAIN (touch_audio ar_load: the stock JPU path, 109 x 117 RGB565 stride 112
 * halfwords) over w8send (kind 3, chunks 0x21..0x24) at 0x0CA70000: header 'PART', seq, rbid, length (26208, 0 =
 * none), the pixels, the seq again as the trailer (the block is complete only when it matches). The header's 35 x 38
 * box and INFO's 164 x 164 square box-average from it; the stock slot-0 image stays the fallback. */
#define LDART ((const volatile u8 *)0x2CA70000)
static u32 ldart_seq(void)
{
	u32 seq;
	if (LDART[0] != 'P' || LDART[1] != 'A' || LDART[2] != 'R' || LDART[3] != 'T' || u32be(LDART + 12) != 26208)
		return 0;
	seq = u32be(LDART + 4);
	return u32be(LDART + 16 + 26208) == seq ? seq | 1 : 0;
}
/* V4n24 diag (usblog: HUD block w3 -> MAIN V3US w26): seq & 0xFFF | trailer & 0xFFF << 12 | magic ok << 24 |
 * length ok << 25 | complete << 26 | the header drew it << 27 | the stock slot-0 image there << 28 (< 2^31) */
static u32 ldart_hdr;
static u32 ldart_diag(void)
{
	int mg = LDART[0] == 'P' && LDART[1] == 'A' && LDART[2] == 'R' && LDART[3] == 'T';
	u32 len = u32be(LDART + 12), seq = u32be(LDART + 4);
	u32 tr = len == 26208 ? u32be(LDART + 16 + 26208) : 0;
	return (seq & 0xFFF) | (tr & 0xFFF) << 12 | (u32)mg << 24 | (u32)(len == 26208) << 25 |
		(u32)(ldart_seq() != 0) << 26 | (ldart_hdr & 3) << 27;
}
static void ldart_draw(int x0, int y0, int dw, int dh)
{
	const volatile u16 *src = (const volatile u16 *)(LDART + 16);
	int x, y;
	/* D1 (emu: INFO at 4 fps, 54 M instructions a frame in udiv): the box-filter bounds of every column once a
	 * call, and the averages by a reciprocal -- ceil(65536 / n) is exact for n <= 16 (sums <= 63 n), the
	 * same pixels as the per-pixel division (n > 16: udiv as before) */
	u8 xs[176], xn[176];
	u32 rc[17];
	if (dw > 176)
		dw = 176;
	for (x = 0; x < dw; x++) {
		int sx0 = udiv(x * 109, dw), sx1 = udiv((x + 1) * 109, dw);
		xs[x] = (u8)sx0;
		xn[x] = (u8)(sx1 <= sx0 ? 1 : sx1 - sx0);
	}
	for (x = 0; x < 17; x++)
		rc[x] = 0;
	dmark(y0, dh);
	for (y = 0; y < dh; y++) {
		int sy0 = udiv(y * 117, dh), sy1 = udiv((y + 1) * 117, dh), ny;
		u16 *dst = fb + (y0 + y) * W + x0;
		if (sy1 <= sy0)
			sy1 = sy0 + 1;
		ny = sy1 - sy0;
		for (x = 0; x < dw; x++) {
			int sx0 = xs[x], nx = xn[x], yy, xx;
			u32 r = 0, g = 0, b = 0, n = (u32)(ny * nx);
			for (yy = sy0; yy < sy1; yy++) {
				const volatile u16 *s = src + yy * 112 + sx0;
				for (xx = 0; xx < nx; xx++) {
					u32 p = s[xx];
					r += p >> 11;
					g += (p >> 5) & 63;
					b += p & 31;
				}
			}
			if (n == 1)
				dst[x] = (u16)(r << 11 | g << 5 | b);
			else if (n <= 16) {
				u32 c = rc[n];
				if (!c)
					c = rc[n] = udiv(65536 + n - 1, n);
				dst[x] = (u16)((r * c) >> 16 << 11 | (g * c) >> 16 << 5 | (b * c) >> 16);
			} else
				dst[x] = (u16)(udiv(r, n) << 11 | udiv(g, n) << 5 | udiv(b, n));
		}
	}
}

/* markers of the 0x32 model: {u32 ?, u32 kind, u32 start, u32 end}, 1/150 s, FF = none.
 * V3c (W4, the CDJ-3000 overview, re/CDJ3000_VIDEO_NOTES.md §1): record 0 = the cue point (orange
 * triangle under the overview, on the ruler line) or the active loop; records 1..8 = hot cues A..H
 * (a coloured letter badge above the overview), 9..18 = memory cues (red triangle pointing down onto the
 * overview) [G: slot split from rekordbox's 8 hot + 10 memory; usb_pruned only has one memory point, in
 * record 9]. A record with an end is a loop: an orange bar over its span just above the overview. */
#define OV_X 79
/* V4n9 (CDJ-3000 emu, side by side): the 3000's overview sits higher, its minute labels fully visible above the
 * screen edge -- the whole block 12 px up (was OV_TOP 407 / OV_Y 421 / OV_BAR 465 / OV_RUL 467) */
#define OV_Y 409		/* overview rows 409..451 (OVH 43) */
#define OV_BAR 453		/* the progress line under it (red played, white ahead), 2 rows */
#define OV_RUL 455		/* the minute ruler: ticks 455..458, labels under them (to ~466) */
#define OV_TOP 395		/* hot-cue badges 395..405, memory triangles 401..405, loop bars 407..408 */
#define N_HOT 8
static const u16 HC[] = { 0xF800, 0xFD20, 0xFFE0, 0x07E0, 0x07FF, 0x001F, 0xF81F, 0xFFFF };
static u16 hc_col(const volatile u8 *r) { return r[1] == 0xFF ? C_GREEN : HC[r[1] & 7]; }
static void tri(int x, int y, u16 c)		/* pointing up, apex at y */
{
	int i;
	for (i = 0; i < 5; i++)
		fill(x - i, y + i, 2 * i + 1, 1, c);
}
static void tri_dn(int x, int y, u16 c)		/* pointing down, apex at y + 4 */
{
	int i;
	for (i = 0; i < 5; i++)
		fill(x - 4 + i, y + i, 9 - 2 * i, 1, c);
}
/* a hot-cue letter badge (the 3000's coloured square with A..H), its left edge at x */
static void cue_badge(int x, int y, int k, u16 c)
{
	char l[2];
	l[0] = 'A' + k; l[1] = 0;
	fill(x, y, 10, 11, c);
	text_c(&f_t, x + 5, y + 9 - f_t.asc, l, C_BLACK, c);
}


/* V4b1: the loaded track's extended cues (rekordbox PCO2 / PCP2 tags of the .EXT: memory-cue colours, the real
 * hot-cue RGB, comments). MAIN's touch_audio reads both PCO2 tags when the deck's track changes and w8send
 * streams them (kind 3) to 0x0CA90000: header 'PCO2', seq, rbid, tag bytes, then the raw tags. MAIN publishes an
 * empty block (length 0) the moment the track changes, so the previous track's cues never outlive the load.
 * Parsed once per new seq into a small table. */
#define CUEBUF ((const volatile u8 *)0x2CA90000)
#define CUE_N 24
#define CUE_CM_Y (BAND_Y0 + 1)	/* the comment row: the band's top margin, right of the cue marker (beat ticks start ~19 px lower) */
#define CUE_CM 30
struct cue_e { u32 ms; u16 col; u8 hot; u8 has_col; char cm[CUE_CM]; };
static struct cue_e cue_t[CUE_N];
static int cue_n;
static u32 cue_seq;
static u32 cue_ver;	/* bumped on every new table (band / overview cache keys) */
static u16 rgb565(u32 r, u32 g, u32 b) { return (u16)((r & 0xF8) << 8 | (g & 0xFC) << 3 | b >> 3); }
static void cue_parse(void)
{
	u32 len = u32be(CUEBUF + 12), p = 16, end;
	cue_n = 0;
	if (len > 4096)
		len = 4096;
	end = 16 + len;
	while (p + 20 <= end && cue_n < CUE_N) {
		u32 hl = u32be(CUEBUF + p + 4), tl = u32be(CUEBUF + p + 8), tend, cnt, q, k;
		if (CUEBUF[p] != 'P' || CUEBUF[p + 1] != 'C' || CUEBUF[p + 2] != 'O' || CUEBUF[p + 3] != '2'
		    || hl < 20 || tl < hl || tl > 0x10000)
			break;
		tend = p + tl > end ? end : p + tl;
		cnt = u16be(CUEBUF + p + 16);
		q = p + hl;
		for (k = 0; k < cnt && q + 0x2C <= tend && cue_n < CUE_N; k++) {
			u32 el = u32be(CUEBUF + q + 8), lc = u32be(CUEBUF + q + 0x28), j, n;
			struct cue_e *e = &cue_t[cue_n];
			if (CUEBUF[q] != 'P' || CUEBUF[q + 1] != 'C' || CUEBUF[q + 2] != 'P' || CUEBUF[q + 3] != '2'
			    || el < 0x2C + 4 || lc > 0x400)
				break;
			if (CUEBUF[q + 0x10] == 1 || CUEBUF[q + 0x10] == 2) {	/* cue point / loop */
				u32 hotn = u32be(CUEBUF + q + 12);
				e->hot = hotn > N_HOT ? 0xFF : (u8)hotn;
				e->ms = u32be(CUEBUF + q + 0x14);
				if (u16be(CUEBUF + q + 0x12) == 150)	/* V4n27m: a 1/150 s time base (deck-written) */
					e->ms = udiv(e->ms * 20, 3);
				e->has_col = 0;
				e->col = 0;
				n = 0;
				for (j = 0; j + 1 < lc && n < CUE_CM - 1 && q + 0x2C + j + 2 <= tend; j += 2) {
					u32 ch = u16be(CUEBUF + q + 0x2C + j);
					if (!ch)
						break;
					e->cm[n++] = ch < 0x20 ? ' ' : ch < 0x7F ? (char)ch : '?';
				}
				e->cm[n] = 0;
				if (q + 0x2C + lc + 4 <= tend && lc <= el - 0x30) {
					const volatile u8 *c = CUEBUF + q + 0x2C + lc;
					/* V4n27m (memory cues not drawn on HW): the deck writes its cues with the colour bytes left
					 * uninitialised -- a non-zero code with a black / near-black RGB painted the memory triangle
					 * black on black. Take the colour only for a valid rekordbox code (1..0x3E) and a visible RGB. */
					if (c[0] >= 1 && c[0] <= 0x3E && (c[1] >= 0x40 || c[2] >= 0x40 || c[3] >= 0x40)) {
						e->col = rgb565(c[1], c[2], c[3]);
						e->has_col = 1;
					}
				}
				cue_n++;
			}
			q += el;
		}
		if (!tl)
			break;
		p += tl;
	}
	cue_ver++;
}
/* V4n31a (#41): MAIN publishes a cue block only for a track that has one (emu: a track without PCO2 cues left
 * the previous track's block -- its rbid, TITL title, cue colours / comments -- on the new track: "Demo Track 1"
 * over track 3). A load (lg_poll's trigger) marks the block STALE unless it changed within the last second (MAIN
 * may publish a frame before the heartbeat names the new track); a stale block counts as none (cue_rbid 0, no
 * cue table) until MAIN publishes the next one. */
static int cue_stale;
static u32 cue_t_chg;	/* now_ms() of the last block change */
static u32 now_ms(void);
static void cue_mark_load(void)
{
	if (now_ms() - cue_t_chg > 1000)
		cue_stale = 1;
}
/* once a frame (cheap: one word compared) */
static void cue_poll(void)
{
	u32 seq;
	if (CUEBUF[0] != 'P' || CUEBUF[1] != 'C' || CUEBUF[2] != 'O' || CUEBUF[3] != '2') {
		if (cue_n) { cue_n = 0; cue_ver++; }
		return;
	}
	seq = u32be(CUEBUF + 4);
	if (seq != cue_seq) {
		cue_seq = seq;
		cue_t_chg = now_ms();
		cue_stale = 0;
		cue_parse();
	} else if (cue_stale && cue_n) {
		cue_n = 0;
		cue_ver++;
	}
}
/* hot cue n (1..8) / the memory cue at record time st (1/150 s) */
static const struct cue_e *cue_hot(int n)
{
	int i;
	for (i = 0; i < cue_n; i++)
		if (cue_t[i].hot == n)
			return &cue_t[i];
	return 0;
}
static const struct cue_e *cue_mem(u32 st)
{
	u32 ms = udiv(st * 20, 3);
	int i;
	for (i = 0; i < cue_n; i++) {
		u32 d = cue_t[i].ms > ms ? cue_t[i].ms - ms : ms - cue_t[i].ms;
		if (cue_t[i].hot == 0 && d <= 20)
			return &cue_t[i];
	}
	return 0;
}
static u16 hot_col(int i, const volatile u8 *r)	/* record i (1..8): the real RGB when the track has one */
{
	const struct cue_e *e = cue_hot(i);
	if (HCC_OFF)	/* V4n32 (#50): UTILITY HOT CUE COLOR OFF -- every hot cue in the default green (CDJ-3000) */
		return C_GREEN;
	return e && e->has_col ? e->col : hc_col(r);
}
static u16 mem_col(const volatile u8 *r)	/* a memory cue record: its colour, else red */
{
	const struct cue_e *e = cue_mem(u32be(r + 8));
	return e && e->has_col ? e->col : C_RED;
}

/* the comment to show: the next cue (memory or hot) with a comment at or after the playhead -- or one passed less
 * than 1.5 s ago -- index + 1, 0 = none. A fixed spot in the band's top margin (band_extras), so it is part of the
 * band key (band_xk) like the other overlays. */
static int cue_next_cm(void)
{
	u32 pms = udiv(u32be(DECK + 0x70) * 20, 3);
	int k, b = -1;
	for (k = 0; k < cue_n; k++)
		if (cue_t[k].cm[0] && cue_t[k].ms + 1500 >= pms && (b < 0 || cue_t[k].ms < cue_t[b].ms))
			b = k;
	return b + 1;
}

/* V3d: drawn in two passes -- cue, loops and memory cues first, the hot-cue badges last, so a memory cue
 * at a hot cue's position never covers its letter (the CDJ-3000 / rekordbox keep the hot-cue badge on top) */
static void markers(int x0, int w, u32 len_ms)
{
	int i, pass;
	if (!len_ms)
		return;
	for (pass = 0; pass < 2; pass++)
	for (i = 0; i < N_MARKS; i++) {
		const volatile u8 *r = MARKS + 16 * i;
		u32 st = u32be(r + 8), en = u32be(r + 12);
		u32 sx, ex;
		if (st == 0xFFFFFFFF || (i >= 1 && i <= N_HOT) != pass)
			continue;
		sx = udiv(udiv(st * 20, 3) * (u32)w, len_ms);	/* 1/150 s -> ms -> px */
		if (sx >= (u32)w)
			continue;
		if (en != 0xFFFFFFFF && en > st) {
			ex = udiv(udiv(en * 20, 3) * (u32)w, len_ms);
			if (ex >= (u32)w) ex = w - 1;
			fill(x0 + sx, OV_TOP + 12, ex - sx + 1, 2, C_MASTER);
		}
		if (i == 0) {
			if (en == 0xFFFFFFFF || en <= st)
				tri(x0 + sx, OV_RUL, 0xFD06);		/* cue: #F8A030 under the overview (V3rc6: 3000 skin img_currentCue) */
		} else if (i <= N_HOT) {
			u16 c = hot_col(i, r);
			fill(x0 + sx, OV_TOP + 11, 1, OV_Y - OV_TOP - 11, c);
			cue_badge(x0 + sx, OV_TOP, i - 1, c);
		} else {
			tri_dn(x0 + sx, OV_TOP + 6, mem_col(r));	/* memory cue: its colour (V4b1; red by default), above */
		}
	}
}

/* R21 parity (c): the browse strip's mini overview carries the cue marks like the 3000's. The 3000's deck strip
 * (PlayingTrackInfoWidget) is built in the same unit as HotCueMarker / MainCueMarker /
 * PreviewableWaveform (its RTTI) and its skin
 * (its layout skin) puts img_memoryCue (21x15) above the overview and
 * img_currentCue under it. The 0x32 marker model belongs to the player screen, so -- like the overview pixels
 * (strip_snap) -- the marks are snapshotted there, with their colours resolved (hot_col / mem_col need the loaded
 * track's PCO2 table), whenever the player's overview region redraws (it is keyed on marks_ck); the strip only
 * reads the copy. Sizes: our own player overview's (cue_badge 10 x 11, the 9 x 5 triangles), not re-scaled. */
static u32 hmix(u32 h, u32 v);
static u8 smk[N_MARKS * 16];		/* the marker records at the snapshot */
static u16 smk_c[N_MARKS];		/* their colours then */
static u32 smk_tid, smk_ck;
static void strip_marks_snap(u32 tid)
{
	u32 c = tid;
	int i;
	for (i = 0; i < N_MARKS * 16; i++) {
		smk[i] = MARKS[i];
		c = hmix(c, smk[i]);
	}
	for (i = 0; i < N_MARKS; i++) {
		const volatile u8 *r = MARKS + 16 * i;
		smk_c[i] = i == 0 ? 0xFD06 : i <= N_HOT ? hot_col(i, r) : mem_col(r);
		c = hmix(c, smk_c[i]);
	}
	smk_tid = tid;
	smk_ck = c;
}
/* x0 / w: the strip overview (176, 344); top: the badge row (421..431, the strip's free line above the snapshot);
 * ovy: the snapshot's first row; cy: the cue triangle's apex under the red progress line. Every mark is clamped
 * inside the strip's own cleared box (region 4: 176..521), so nothing is left on the time / KEY regions. */
static void strip_marks(int x0, int w, u32 len_ms, int top, int ovy, int cy)
{
	int i, pass;
	if (!len_ms)
		return;
	KIT(kit_sdraw++;)
	for (pass = 0; pass < 2; pass++)
	for (i = 0; i < N_MARKS; i++) {
		const u8 *r = smk + 16 * i;
		u32 st = (u32)r[8] << 24 | (u32)r[9] << 16 | (u32)r[10] << 8 | r[11];
		u32 en = (u32)r[12] << 24 | (u32)r[13] << 16 | (u32)r[14] << 8 | r[15];
		u32 sx, ex;
		int x;
		if (st == 0xFFFFFFFF || (i >= 1 && i <= N_HOT) != pass)
			continue;
		sx = udiv(udiv(st * 20, 3) * (u32)w, len_ms);	/* 1/150 s -> ms -> px */
		if (sx >= (u32)w)
			continue;
		if (en != 0xFFFFFFFF && en > st) {
			ex = udiv(udiv(en * 20, 3) * (u32)w, len_ms);
			if (ex >= (u32)w) ex = w - 1;
			fill(x0 + sx, ovy - 2, ex - sx + 1, 2, C_MASTER);
		}
		x = x0 + (int)sx;
		if (i == 0) {
			if (en == 0xFFFFFFFF || en <= st)
				tri(x < x0 + 4 ? x0 + 4 : x > x0 + w - 5 ? x0 + w - 5 : x, cy, smk_c[0]);
		} else if (i <= N_HOT)
			cue_badge(x > x0 + w - 10 ? x0 + w - 10 : x, top, i - 1, smk_c[i]);
		else
			tri_dn(x < x0 + 4 ? x0 + 4 : x > x0 + w - 5 ? x0 + w - 5 : x, top + 6, smk_c[i]);
	}
}

/* V3c: the minute ruler under the overview (the 3000: "-5:00 ... -1:00" in REMAIN, "1:00 ..." in
 * ELAPSED; a label every 1/2/5/10/20 minutes so they stay ~48 px apart, small ticks every minute) */
static void ruler(int x0, int w, u32 len_ms, int remain)
{
	static const u8 STEP[] = { 1, 2, 5, 10, 20 };
	u32 mins = udiv(len_ms, 60000), ppm, m, step = 1;
	int k, last_l = -1000, last_r = -1000;
	char buf[8];
	if (!len_ms || !mins)
		return;
	ppm = udiv(60000u * (u32)w, len_ms);		/* px per minute */
	for (k = 0; k < 5; k++) {
		step = STEP[k];
		if (ppm * step >= 48)
			break;
	}
	for (m = 1; m <= mins; m++) {
		u32 t = remain ? len_ms - m * 60000 : m * 60000, x = udiv(udiv(t, 16) * (u32)w, udiv(len_ms, 16) ? udiv(len_ms, 16) : 1);
		int lab = udiv(m, step) * step == m, xx = x0 + (int)x;
		if (x >= (u32)w)
			continue;
		if (ppm >= 6 || lab)
			fill(xx, OV_RUL, 1, lab ? 4 : 2, C_GREY);
		if (lab) {
			char *q = buf;
			int tw;
			if (remain) *q++ = '-';
			if (m >= 10) *q++ = '0' + udiv(m, 10) % 10;
			*q++ = '0' + m % 10;
			*q++ = ':'; *q++ = '0'; *q++ = '0'; *q = 0;
			tw = text_w(&f_t, buf);
			if (xx + 2 + tw > x0 + w || (xx + 2 < last_r + 4 && xx + 2 + tw + 4 > last_l))
				continue;
			text(&f_t, xx + 2, OV_RUL + 1, buf, C_LBL, C_BLACK);
			last_l = xx + 2;
			last_r = xx + 2 + tw;
		}
	}
}

/* ---- our centre waveform (P5): the GUI's own detail entries, the 3000 look ----
 * Entries: *0x0E5EB088 -> u16 words, 150 a second (the same unit as the deck position and the
 * markers): stock RGB words (R low 15..13, G mid 12..10, B high 9..7, height 6..2) or the
 * three_band rewrite (high5 << 11 | mid5 << 6 | low5 << 1 | 1). Deck +0x70 position, +0x74
 * entries, +0xE0 zoom (2^(4 - zoom) entries a column, as the stock renderer 0x1C009AB4).
 * Beat grid 0x0F5EF97C: +4 count, +0x18 -> 20-byte records {u16 beat in bar, u16 bpm*100,
 * u32 ms, ...}. Everything filled by DMA is read through the uncached mirror. */
#define WAVE_X0 18
#define WAVE_N 764
/* V3c: the playhead's band column -- UTILITY > WAVEFORM CURRENT POSITION (MAIN modsmenu, heartbeat
 * +0x54 bit 5): CENTER 382 (the CDJ-3000 default), LEFT 191 (1/4); the phase meter's centre line
 * follows it */
#define V2_PLAYHEAD (ph_left ? 209 : 382)	/* V3rc8t: LEFT at 27.4 % as the 3000 (was 191 = 25 %) */
#define WAVE_CY ((BAND_Y0 + BAND_Y1) / 2)	/* 214 */
#define WAVE_H 48	/* V4n30a (scaling audit): the 3000's peak = 67 % of the tick-row half height (73 of 108 px) */
#define WENT (*(const volatile u32 *)0x2E5EB088)
/* the BLUE detail waveform (u16 per entry: height << 8 | whiteness 0..7): what a LINK-loaded track
 * brings when the colour detail stays empty (re/V2_DEBUG.md D3) */
#define WBLUE (*(const volatile u32 *)0x2E5EB084)
static int wblue;
#define GRID ((const volatile u8 *)0x2F5EF97C)
#define C_W3L 0x02BD		/* #0057EA */
#define C_W3M 0xC320		/* #C06400 */
#define C_W3H 0xF75A		/* #F7EBD5 */

u32 v2_wave_cols, v2_skip_wave;

HOT static void vrun(int x, int y, int h, u16 c)
{
	u16 *p;
	if (x < 0 || x >= W || h <= 0)
		return;
	if (y < BAND_Y0) { h -= BAND_Y0 - y; y = BAND_Y0; }
	if (y + h > BAND_Y1) h = BAND_Y1 - y;
	c = dm(c);
	dmark(y, h);
	for (p = fb + y * W + x; h > 0; h--, p += W)
		*p = c;
}

/* ---- V3b: waveform looks (re/V3_PROGRESS.md) ----
 * WAVEFORM COLOR (UTILITY, MAIN modsmenu, heartbeat +0x54 bits 3-4): 3BAND / RGB / BLUE as the CDJ-3000
 * and rekordbox 7 (re/RB7_WAVEFORM_MINING.md §7-10, re/CDJ3000X_EMU_MINING.md §2.4, RX3 weights).
 * Data per detail entry: our 3-band word (bit 0: low 5..1, mid 10..6, high 15..11), the stock PWV5 word
 * (red 15-13, green 12-10, blue 9-7, height 6-2) or the BLUE detail (height << 8 | whiteness 0..7).
 * 3BAND without 3-band data falls back to the RGB look; BLUE data is always drawn BLUE. */

static u16 rgb8(u32 r, u32 g, u32 b) { return (u16)((r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)); }
/* a + (b - a) * t / 16 per channel */
HOT static u16 mix(u16 a, u16 b, u32 t)
{
	u32 ra = a >> 11, ga = (a >> 5) & 63, ba = a & 31, rb_ = b >> 11, gb = (b >> 5) & 63, bb = b & 31;
	return (u16)(((ra * (16 - t) + rb_ * t) >> 4) << 11 | ((ga * (16 - t) + gb * t) >> 4) << 5 |
		     ((ba * (16 - t) + bb * t) >> 4));
}
HOT static u16 grey_of(u16 c, u32 k)	/* desaturated, luminance x k / 16 */
{
	u32 l = (((c >> 11) << 3) * 5 + (((c >> 5) & 63) << 2) * 9 + ((c & 31) << 3) * 2) >> 4;
	l = (l * k) >> 4;
	if (l > 255) l = 255;
	return rgb8(l, l, l);
}

static int bandh(u32 f)
{
	int h = (int)((f * 99) >> 6);	/* 0..31 -> 0..47 rows (x 1.55: the old 0..62 scaled to WAVE_H) */
	return h > WAVE_H ? WAVE_H : h;
}

static u16 wc_h, wc_m, wc_l, wc_bg;	/* the band's colours this frame (Day Mode resolved once) */
static u16 wc_m2;			/* 3BAND mid where it reaches beyond low (light orange) */
/* waveform areas: LIGHT MODE = LIGHT draws them as the dark theme (black background, normal colours),
 * FULL as the light chrome; wave_on() / wave_off() bracket every waveform area */
static int wave_saved_day;
static void wave_pal(void)
{
	if (in_wave) {		/* FULL (RB7 §10): on #F2F3F5 */
		wc_l = 0x0218;	/* #0040C0 */
		wc_m = 0x89E0;	/* #8A3E00 mid inside low */
		wc_m2 = 0xD300;	/* #D06000 mid beyond low */
		wc_h = 0x2125;	/* #23262E */
		wc_bg = 0xF79E;
	} else {		/* the CDJ-3000 frame: #0057EA / #C06400 / #F7EBD5; light mid as rekordbox */
		wc_l = C_W3L;
		wc_m = C_W3M;
		wc_m2 = 0xFCC5;	/* #FE9B28 */
		wc_h = C_W3H;
		wc_bg = 0;
	}
}
static void wave_on(void)
{
	wave_saved_day = day;
	day = day_full;
	in_wave = day_full;
	wave_pal();
}
static void wave_off(void)
{
	day = wave_saved_day;
	in_wave = 0;
}

/* The band's waveform lives in a ring of WAVE_N columns in free SDRAM (0x0C680000..0x0CD00000 is
 * unused by the firmware, re/V2_P4.md; the read-only data sits at 0x0C700000..0x0C71B000): scrolling
 * moves the head, only the new columns are computed, and every frame the ring is copied to the frame
 * buffer before the ticks, marks and playhead go on top (re/V2_P7.md). */
#define RING ((u16 *)0x0C780000)
#define RING_H (BAND_Y1 - BAND_Y0)
#define HALF (RING_H / 2)		/* 92: rows WAVE_CY-92 .. WAVE_CY+91 */
static int ring_head;

/* one ring column from its half profile cb[0..HALF] (d = distance from the centre line), mirrored;
 * every colour change outward gets a 1-px blend (the 3000 / rekordbox soft outline) */
#ifdef V2_HWBAND
/* V4: the column from its half profile (mirrored, 1-px blends) into nb[RING_H]; shared with the hardware band */
static void prof_col(u16 *nb, const u16 *cb, int top)
{
	u16 prev = wc_bg, c, bg = wc_bg;
	int d;
	for (d = 0; d <= HALF; d++) {
		u16 raw = d <= top ? cb[d] : bg;
		c = d && raw != prev ? mix(prev, raw, 8) : raw;
		prev = raw;
		if (d < HALF)
			nb[HALF + d] = c;
		if (d)
			nb[HALF - d] = c;
		if (d > top + 1) {
			for (d++; d <= HALF; d++) {
				if (d < HALF)
					nb[HALF + d] = bg;
				nb[HALF - d] = bg;
			}
			break;
		}
	}
}
static void put_col(int k, const u16 *cb, int top)
{
	u16 nb[RING_H], *p = RING + k;
	int y;
	prof_col(nb, cb, top);
	for (y = 0; y < RING_H; y++, p += WAVE_N)
		*p = nb[y];
}
#else
HOTSW static void put_col(int k, const u16 *cb, int top)
{
	u16 *p = RING + k, prev = wc_bg, c;
	int d;
	for (d = 0; d <= HALF; d++) {
		u16 raw = d <= top ? cb[d] : wc_bg;
		c = d && raw != prev ? mix(prev, raw, 8) : raw;
		prev = raw;
		if (d < HALF)
			p[(HALF + d) * WAVE_N] = c;		/* row WAVE_CY + d */
		if (d)
			p[(HALF - d) * WAVE_N] = c;		/* row WAVE_CY - d */
		if (d > top + 1) {			/* the rest is background */
			for (d++; d <= HALF; d++) {
				if (d < HALF)
					p[(HALF + d) * WAVE_N] = wc_bg;
				p[(HALF - d) * WAVE_N] = wc_bg;
			}
			break;
		}
	}
}
#endif

/* raw values of screen column c: kind 0 none, 1 3-band (a = low, b = mid, c = high), 2 PWV5
 * (a = red, b = green, c = blue 0..7, h height), 3 BLUE (h height, a whiteness) */
struct wraw { int kind; u32 a, b, c, h; };
/* V4n27z (user: the CDJ-3000's TIME SPAN per zoom, scaled to our band): our band is 0.625 x the 3000's 1280 px,
 * so a column holds 1.6 x 2^sh PWV5 entries (zoom key 4..0: 1.6 / 3.2 / 6.4 / 12.8 / 25.6; was 2^sh = the 3000's
 * px / s, 37 % less time). Exact rational, on ABSOLUTE columns (the ring keys / slots stay consistent): column
 * a = entries [bent(a), bent(a + 1)), bent(a) = ceil(a x 2^(sh+3) / 5); bcol(e) = floor(e x 5 / 2^(sh+3)). */
static s32 bcol(s32 e, int sh) { return (e * 5) >> (sh + 3); }
/* V4n32 (#zoom6): the 3000's sixth zoom (0.5 entries / px -> 0.8 entries a column, sh = -1): every "x << sh" goes
 * through SHL (sh >= -1), the zoom key 0..5 through ZSH */
#define SHL(x, sh) (((x) << ((sh) + 1)) >> 1)
#define ZSH(z) ((z) <= 5 ? (int)(4 - (int)(z)) : 0)
/* the zoom key 0..5: stock's +0xE0 (0..4) plus MAIN's sixth level (modsmenu zm_knob: the knob turned further in at
 * 4 -- +0x14 page 1 bit 21; stock never sees a 5) */
static u32 zkey(void)
{
	u32 z = u32be(DECK + 0xE0);
	return z == 4 && V32_Z6 ? 5 : z;
}
static s32 bent(s32 a, int sh)
{
	u32 x = ((u32)a << (sh + 3)) + 4;		/* a >= 0; / 5 by multiply (no division) */
	return a <= 0 ? a << (sh + 3) : (s32)(u32)(((unsigned long long)x * 0xCCCCCCCDu) >> 34);
}
/* BANDFLICK (deck V4n47: the band flickers at zoom keys 0-1, worst at 0, gone from 2): the beat ticks are a
 * 1-px comb every 2.9 / 5.9 columns there (12.8 / 25.6 entries a column, 75 entries a beat at 120 BPM) moving in
 * whole-px steps 6 / 12 times a second -- a 1-px step is 1/3 (1/6) of the comb's period, read as flicker, not
 * motion (temporal aliasing; the ring itself is a pure shift, emu work/bandflick). The CDJ-3000 draws only the
 * bar heads there: scale <= 0.24 px an entry (s9 @). Our column = 1 / 0.625 of its px,
 * so bars only from 6.67 entries a column: band sh >= 3; the master mini (sc = entries x 256) sc >= 1707.
 * The LINK meter (master_mini) applies the same rule at its own sc. Shared rule: work/bandflick/bandcol.h. */
#define BARS_ONLY_SH(sh) ((sh) >= 3)
#define BARS_ONLY_SC256(sc) ((sc) >= 1707)
#define BSC(sh) (~((sh) + 1))	/* V4n32: sh -1 -> -1 (still < 0) */		/* raw_col / col_prof sc < 0: this band scale, e_first = the column of c 0 */
HOT static void raw_col(struct wraw *r, int c, const volatile u16 *e, u32 n, s32 e_first, int sc)
{
	u32 sr = 0, sg = 0, sb = 0, sw = 0;	/* PWV5: height-weighted colour sums over the column (V3c) */
	s32 e0;
	int cnt, i;
	r->kind = 0; r->a = r->b = r->c = r->h = 0;
	if (sc < 0) {		/* the band: absolute column e_first + c (V4n27z) */
		s32 a = e_first + c;
		if (a < 0)
			return;
		e0 = bent(a, ~sc - 1);
		cnt = bent(a + 1, ~sc - 1) - e0;
		if (cnt < 1) {	/* V4n32: sh -1 (1.25 px an entry): a column inside one entry shows that entry */
			e0--;
			cnt = 1;
		}
	} else {		/* sc = entries per column x 256 (METERALIGN; was x 16) (the phase meter's master mini-waveform); V4n31a (#59):
				 * e_first = the ABSOLUTE column of c 0, so a column always covers the same entries while
				 * the view scrolls (a per-frame resampling phase made every column's peak shimmer) */
		s32 a = e_first + c;
		if (a < 0)
			return;
		e0 = (s32)(((u32)a * (u32)sc) >> 8);
		cnt = (s32)((((u32)a + 1) * (u32)sc) >> 8) - e0;
		if (cnt < 1)	/* V4n32: < 1 entry a column (zoom 6) */
			cnt = 1;
	}
	if (e0 < 0 || (u32)e0 >= n)
		return;
	if ((u32)e0 + cnt > n)
		cnt = n - e0;
	for (i = 0; i < cnt; i++) {
		u32 w = e[e0 + i];
		if (wblue) {
			u32 h = (w >> 8) & 31;
			r->kind = 3;
			if (h >= r->h) { r->h = h; r->a = w & 7; }
		} else if (w & 1) {
			u32 lo = (w >> 1) & 31, mi = (w >> 6) & 31, hi = (w >> 11) & 31;
			r->kind = 1;
			if (lo > r->a) r->a = lo;
			if (mi > r->b) r->b = mi;
			if (hi > r->c) r->c = hi;
		} else {
			u32 h = (w >> 2) & 31;
			if (r->kind != 1) {
				r->kind = 2;
				if (h > r->h)
					r->h = h;
				sr += ((w >> 13) & 7) * (h + 1);
				sg += ((w >> 10) & 7) * (h + 1);
				sb += ((w >> 7) & 7) * (h + 1);
				sw += h + 1;
			}
		}
	}
	if (r->kind == 2) {	/* V3c: the column's hue = the height-weighted mean of its entries (0..28), as
				 * rekordbox mixes kick (red) and hat (violet) entries when zoomed out; before, the
				 * tallest entry's hue (the kick) painted bass-heavy tracks all red */
		r->a = udiv(sr * 4, sw); r->b = udiv(sg * 4, sw); r->c = udiv(sb * 4, sw);
	}
	if (r->kind == 1)
		r->h = r->a > r->b ? (r->a > r->c ? r->a : r->c) : (r->b > r->c ? r->b : r->c);
}

HOT static u32 sm3(u32 a, u32 b, u32 c) { return (a + 2 * b + c + 2) >> 2; }	/* [1 2 1] / 4 */

/* the RGB look: one hue per column, bright at the centre line, 0.48 of it at the envelope (dark);
 * FULL: core at 0.8, the edge mixed 45 % toward the panel */
/* rekordbox RGB (re/RB7_WAVEFORM_MINING.md §8): the strongest channel at 0.86 (#DB), the weaker ones
 * normalised with a mild gamma ~1.2 (t * (0.75 + 0.25 t)): bass 7/1/1 -> #DB121B (V3c) */
HOT static u16 rb_hue(u32 r, u32 g, u32 b, u32 m)
{
	u32 tr = udiv(r * 256, m), tg = udiv(g * 256, m), tb = udiv(b * 256, m);
	tr = (tr * (192 + (tr >> 2))) >> 8;
	tg = (tg * (192 + (tg >> 2))) >> 8;
	tb = (tb * (192 + (tb >> 2))) >> 8;
	return rgb8((tr * 219) >> 8, (tg * 219) >> 8, (tb * 219) >> 8);
}
HOT static void look_rgb(u16 *cb, int h, u32 r, u32 g, u32 b)
{
	u32 m = r > g ? (r > b ? r : b) : (g > b ? g : b), inv;
	u16 core;
	int d;
	if (h < 0 || !m) { cb[0] = wc_bg; return; }
	core = rb_hue(r, g, b, m);
	if (in_wave)
		core = mix(0, core, 13);
	inv = udiv(1 << 16, (u32)h + 1);
	for (d = 0; d <= h; d++) {
		u32 t = (u32)d * inv >> 12;	/* 0..16 */
		cb[d] = in_wave ? mix(core, wc_bg, (t * 7) >> 4) : mix(0, core, 16 - ((t * 8 + 8) >> 4));
	}
	cb[h + 1] = wc_bg;
}

/* the BLUE look: per column a ramp from the edge colour to the core, both picked by the whiteness */
HOT static void look_blue(u16 *cb, int h, u32 w)
{
	u16 core, edge;
	u32 inv;
	int d;
	if (h < 0) { cb[0] = wc_bg; return; }
	if (w > 7) w = 7;
	if (in_wave) {
		core = mix(0x2B7A, 0x2C39, (w * 16) / 7);	/* #2F6FD2 -> #2C86C8 */
		edge = 0x1A54;				/* #1E4BA6 */
	} else {
		/* HALFBLUE (B2/B3, work/blue3000/BLUE_AUDIT.md §1.2): the CDJ-3000's Blue drawer -- 's 8 static
		 * colours (0x6785848, init 0x523EF4, picked by the whiteness through 0x22A43B4), each column FLAT and
		 * opaque, mirrored about the centre line, no tip / edge darkening (renderWaveform_new) */
		static const u16 B3K[8] = {
			0x09F1,	/* #083C8C */
			0x0AF7,	/* #085DBD */
			0x037F,	/* #006DFF */
			0x0D5E,	/* #08AAF7 */
			0x55BE,	/* #52B6F7 */
			0x757F,	/* #73AEFF */
			0x757F,	/* #73AEFF */
			0xCF3F,	/* #CEE7FF */
		};
		core = B3K[w];
		for (d = 0; d <= h; d++)
			cb[d] = core;
		cb[h + 1] = wc_bg;
		return;
	}
	inv = udiv(1 << 16, (u32)h + 1);
	for (d = 0; d <= h; d++)
		cb[d] = mix(core, edge, (u32)d * inv >> 12);
	cb[h + 1] = wc_bg;
}

/* the 3BAND look (RX3 weights low x1.2, mid x0.6, high x1.2; rekordbox overlap rule: mid dark orange
 * inside the low envelope, light orange beyond it, high cream on top) */
/* V3e1 (user: "no 3-band look"; 3000 frames 01/03): the RX3 weights (mid x0.6, high x1.2) left the orange
 * a thin line inside the blue and the highs a 1-2 px core on real PWV7 data (A Better World: low p90 24,
 * mid p90 16, high p50 1 / p99 11 of 31 -- MAIN's high curve is compressed). The 3000 shows the orange
 * body about as wide as the blue on kicks and the highs as big white spikes: mid x0.75, high (h - 2) x 3 (offline sweep: work/v3e1/sim/band3.py). */
#define B3_MI(v) udiv((v) * 3, 4)
#define B3_HI(v) ((v) > 2 ? ((v) - 2) * 3 : 0)	/* the 1..2 floor (most columns) would be a constant cream line */
HOT static void look_3band(u16 *cb, u32 lo, u32 mi, u32 hi)
{
	int hl = bandh(udiv(lo * 6, 5)), hm = bandh(B3_MI(mi)), hh = bandh(B3_HI(hi)), d, top;
	if (!lo) hl = -1;
	if (!mi) hm = -1;
	if (!B3_HI(hi)) hh = -1;
	top = hl > hm ? hl : hm;
	if (hh > top) top = hh;
	for (d = 0; d <= top + 1 && d <= HALF; d++)
		cb[d] = d <= hh ? wc_h : d <= hm ? (d <= hl ? wc_m : wc_m2) : d <= hl ? wc_l : wc_bg;
}

/* the whole 3600-byte overview (it lands in pieces after a load and is re-sent on INFO open /
 * close): a change repaints the overview in both buffers (re/V2_WAVEFORM_PLAN.md W1) */
static u32 ov_ck(void)
{
	const volatile u32 *p = (const volatile u32 *)OV_REC;
	u32 c = 0;
	int i;
	for (i = 0; i < 900; i++)
		c = (c << 3 | c >> 29) ^ p[i];
	return c;
}

static u32 marks_ck(void)
{
	u32 c = 0;
	int i;
	static int hcc_k;
	cue_poll();			/* V4b1: called once a frame by the band / overview keys */
	if (HCC_OFF != hcc_k) {		/* V4n32 (#50): HOT CUE COLOR repaints every cue mark (band ring, overview) */
		hcc_k = HCC_OFF;
		cue_ver++;
	}
	for (i = 0; i < N_MARKS * 4; i++)
		c = (c << 1 | c >> 31) ^ ((const volatile u32 *)MARKS)[i];
	return c ^ (cue_ver * 0x9E3779B1u);	/* V4b1: a new cue table repaints the band / overview */
}

/* P10: a track without ANLZ is analysed by the deck as it plays; meanwhile the detail entries and the
 * overview record still hold the PREVIOUS track's data (valid flags set) and stock shows an empty band.
 * Heartbeat +0x60 (also +0x08): 1 for a track loaded with its rekordbox analysis, 5 for one the deck
 * analyses itself (stock emu dumps: Aaiko / Emotional Sync = 1, un-analysed WAV = 5) -- band + overview
 * stay empty then, as stock. (+0x120.. are cue flags, not this: P10 first try, wrong.) */
u32 v2_wave_stale;
static int load_failed(void);
static int wave_data_ok(void)
{
	/* V3a: the rekordbox detail arrived for THIS load (0x2F zeroes DET_LEN first; P10's +0x60 and
	 * +0x120 tries were wrong signals) */
	return ana;
}

/* V3a: which detail the load brought -- colour (0x37, PWV5 / our 3-band words at WENT) or blue (0x36,
 * PWV3 at WBLUE). Both buffers keep the previous track's data, so: a 32-spot checksum of each is taken
 * when DET_LEN drops to 0 (0x2F, the start of a load) and compared when it comes back; the buffer
 * that changed is this track's. Called every painted frame (loads happen from the browse screens). */
static int det_blue;
static u32 buf_ck(u32 base)
{
	const volatile u16 *e;
	u32 n = u32be(DECK + 0x74), step, j, ck = 0;
	if (!base || !n || n > 0x200000)
		return 0;
	e = (const volatile u16 *)((base & 0x1FFFFFFF) | 0x20000000);
	step = (n >> 5) | 1;
	for (j = 0; j < n; j += step)
		ck = ck * 33 + e[j] + 1;
	return ck;
}
static int buf_any(u32 base)
{
	const volatile u16 *e;
	u32 n = u32be(DECK + 0x74), step, j;
	if (!base || !n || n > 0x200000)
		return 0;
	e = (const volatile u16 *)((base & 0x1FFFFFFF) | 0x20000000);
	step = (n >> 4) | 1;
	for (j = 0; j < n; j += step)
		if (e[j])
			return 1;
	return 0;
}
u32 v2_det_flips;	/* V4m2: a load's blue/colour decision changed after DET_LEN came back (was v2_det_loads / v2_det_blue) */
static int det_settled;	/* V4m2: the colour buffer changed for this load: decision final */
/* V3e1 (debug agent, <shots>*): the overview (0x35) and the grid (0x2B) come before the
 * detail (0x37, its size = DET_LEN, up to ~18 s after the load) and alone on a partial load; stock draws
 * them as soon as they arrive. ov_new / grid_new: the colour overview / a grid arrived for THIS load
 * (content changed since the load started; 0x0F5EF980's count is stale across partial loads, so the
 * grid is hashed). Un-analysed tracks (0x34 -> OV_COLOUR 0, grid count 0) still show nothing. */
static u32 hmix(u32 h, u32 v);
static int ov_new, grid_new;
static u32 grid_ck(void)
{
	u32 cnt = u32be(GRID + 4), rp = u32be(GRID + 0x18);
	const volatile u8 *r;
	if (!cnt || cnt >= 8192 || (rp & 0xFF000000) != 0x0F000000)
		return 0;
	r = (const volatile u8 *)((rp & 0x1FFFFFFF) | 0x20000000);
	return hmix(hmix(hmix(cnt, u32be(r + 4)), u32be(r + 20 * (cnt >> 1) + 4)), u32be(r + 20 * (cnt - 1) + 4));
}
#define GRID_OK (ana || grid_new)
/* #22a (TANDA3): stock GRID ADJUST moves the grid by an offset in ms (MAIN s16 0x0A35F7AC, +-5 a rotary detent)
 * that reaches the GUI as heartbeat +0xE4 (s32, sign-extended; verified in the emu: +4 detents 0x14, -8 0xFFFFFFD8).
 * The records stay as analysed: every grid time we use is record + offset (the engine's beat phase follows it) */
#define G_OFF (GA_OFF ? 0 : (s32)u32be(DECK + 0xE4))
static u32 gms(const volatile u8 *r)
{
	s32 o = G_OFF, v;
	if (o < -2000 || o > 2000)
		o = 0;
	v = (s32)u32be(r + 4) + o;
	return v > 0 ? (u32)v : 0;
}
u32 v2_det_hold;
static int det_holding;	/* V3rc8: a short detail-length drop on the same track is being bridged */
static u32 ld_t0;	/* LOADFIX: the last change of the track identity (paint_frame; 0 none yet) */
/* LOADFIX (deck: an occasional half-drawn / stale band after a load): the band's data checks sample 32 spots of
 * the whole track, so a late chunk of the detail landing between them in the visible window left columns built
 * from the old / half-written data (paused: until a zoom). After any load the band is re-read from the buffer,
 * progressively, at 1.5 / 3 / 6 / 12 / 20 s: 1 when a re-read is due (one per caller state) */
static int ld_reread(u32 *t0, u32 *stage)
{
	static const u16 at[5] = { 1500, 3000, 6000, 12000, 20000 };
	u32 age = now_ms() - ld_t0;
	if (*t0 != ld_t0) {
		*t0 = ld_t0;
		*stage = 0;
	}
	if (!ld_t0 || *stage >= 5 || age < at[*stage])
		return 0;
	while (*stage < 5 && age >= at[*stage])
		(*stage)++;
	return 1;
}
static void det_track(void)
{
	static u32 was, ck_c, ck_b, have;
	u32 l = DET_LEN;
	{	/* V3rc8 (deck HUD: every full band rebuild came from "not ok"; the white "destello"): while a track plays
		 * MAIN zeroes the detail length for a moment (it rewrites the buffer). That read as a new load: the band
		 * blanked for a frame, then rebuilt all columns. A zero on the SAME track (number + length) lasting
		 * < 800 ms keeps the last length; a real load changes the track or stays at zero longer. */
		static u32 last_l, z_t, h_id;
		u32 id = hmix(u32be(DECK + 0x60), u32be(DECK + 0x7C)), t = now_ms();
		/* V4n31a (#41): h_id = the track of the last frame WITH a detail (was: the previous frame's), so a
		 * load (the track number / length changes while the detail is zero) is never bridged with the old
		 * track's length -- that made `ana` read "detail in" 1-2 frames into a load and opened the gate */
		if (!l && last_l && id == h_id) {
			if (!z_t)
				z_t = t | 1;
			if (t - z_t < 800) {
				l = last_l;
				v2_det_hold++;
			}
		} else
			z_t = 0;
		det_holding = z_t && l;
		if (DET_LEN) {
			last_l = DET_LEN;
			h_id = id;
		}
	}
	ana = l != 0 && l <= 0x200000 && !load_failed();
	{
		static u32 ov0, g0, lid;
		u32 id = hmix(u32be(DECK + 0x60), u32be(DECK + 0x7C));
		if ((!l && was) || (!l && id != lid)) {
			ov0 = ov_ck();
			g0 = grid_ck();
			ov_new = grid_new = 0;
		}
		lid = id;
		if (!ov_new && OV_COLOUR == 1 && u32be(OV_HDR + 4) == 1 && ov_ck() != ov0)
			ov_new = 1;
		if (!grid_new) {	/* the grid streams in chunks (Mac QA: ticks blinking during a load): only
					 * once it has been the same for 15 frames */
			static u32 g_last, g_stable;
			u32 g = grid_ck();
			if (g && g != g0) {
				g_stable = g == g_last ? g_stable + 1 : 0;
				g_last = g;
				pend = 1;
				if (g_stable >= 15)
					grid_new = 1;
			} else
				g_stable = 0;
		}
		if (load_failed())
			ov_new = grid_new = 0;
	}
	if (!l) {
		if (was || !have) {	/* a load starts: the buffers as they are now = the old track */
			ck_c = buf_ck(WENT);
			ck_b = buf_ck(WBLUE);
			have = 1;
			det_settled = 0;
		}
	} else if (!was || !det_settled) {	/* the detail is in: which buffer changed */
		/* V4m2 (deck V4k3, rekordbox 7.2.19 export: the band BLUE in every WAVEFORM COLOR while the overview
		 * followed): the decision was taken ONCE, the frame DET_LEN came back. On the deck the blue detail
		 * (0x36) can be complete at that moment while the colour one (0x37) is still streaming into WENT --
		 * "only the blue buffer changed" latched BLUE for the whole track (the emulator's slower load never
		 * hit that order). Now re-evaluated every frame until the colour buffer has changed for this load:
		 * colour data present = colour (any look can be drawn from it), else blue when only WBLUE changed */
		int cc = buf_ck(WENT) != ck_c, cb = buf_ck(WBLUE) != ck_b, nb;
		if (cc && buf_any(WENT))
			nb = 0;
		else if (cc != cb)
			nb = cb;
		else if (!buf_any(WENT))	/* neither / both changed: the old rule (colour empty -> blue) */
			nb = WBLUE && buf_any(WBLUE);
		else
			nb = 0;
		if (was && nb != det_blue)
			v2_det_flips++;
		det_blue = nb;
		if (cc && buf_any(WENT))
			det_settled = 1;
	}
	was = l;
}

u32 v2_wave_same, v2_wave_full, v2_wave_rf, v2_wf_why, v2_wf_hist[8];

/* V3c: the active loop's span in entries (1/150 s, the markers' unit): its columns get the 3000's
 * orange shading as their background (baked into the ring; the ring is rebuilt when the loop changes) */
static s32 lp_st = -1, lp_en = -1;
/* the waveform of screen column c (its stored slot k), smoothed over its neighbours */
static void wave_col_(int c, int k, const volatile u16 *e, u32 n, s32 e_first, int sc);
/* V3f: the active loop's wash is no longer baked into the ring (a loop edge rebuilt all 764 columns):
 * the copy to the frame paints it over the background pixels of the loop's columns (band_copy) */
static u32 ring_gen;		/* bumped whenever ring columns change (the band's key) */
#ifdef V2_SUBPX
/* V3rc8 (CDJ-3000 waveform renderer, re/CDJ3000 wave agent): the 3000 scrolls by a SUB-PIXEL
 * position, every pixel a blend of columns i and i+1 by the fraction -- linear between similar-brightness
 * neighbours, equal-power weights clamped to max(a, b) between high-contrast ones (thin white peaks keep their
 * brightness while they move). Here: three phase rings (the ring shifted 1/4, 1/2, 3/4 column) kept beside the
 * ring in free SDRAM (0x0CB18000.., 3 x 281,152 B, ends before the canvas 0x0CC00000); band_copy picks one by the
 * position's fraction -- no per-frame blending cost. A column write refreshes its own and its left neighbour's
 * phases; bulk rebuilds revalidate them progressively (PH_STEP slots a frame; phase 0 meanwhile). */
#define PRING(p) ((u16 *)(0x0CB18000 + (p) * (WAVE_N * RING_H * 2)))
static int ph_bulk, phr_left = WAVE_N, ph_c, b_phase, ph_soft;	/* V3rc8 audit B1: was ph_left = the CURRENT POSITION flag! */
#endif
#if defined(V2_SUBPX) || defined(V2_HWSUB)
int ph_zs;
HOTSW static u16 ph_blend(u16 a, u16 b, int p)
{
	static const u8 EP[3][2] = { { 215, 111 }, { 174, 174 }, { 111, 215 } };	/* equal-power (Q8) */
#ifdef V2_SUBPX
	/* V3rc8t (deck: zoom 1 "flicker de blancos"): at sh >= 3 a column takes ~4 frames to cross, so each phase
	 * is on screen ~1 frame and a thin white peak's brightness walking 100 -> 84 -> 68 -> 84 % reads as a slow
	 * 8 Hz blink. There the bright side keeps >= 86 % (255/220/140 weights, still clamped to max(a, b)) */
	static const u8 EPS[3][2] = { { 255, 140 }, { 220, 220 }, { 140, 255 } };
	const u8 (*T)[2] = ph_soft ? EPS : EP;
#else
	/* G1: hb_cols at b_sh >= 2 (ph_zs): softer {192,128}/{128,192} for the zoom 1-2 white blink */
	static const u8 EPZ[3][2] = { { 192, 128 }, { 174, 174 }, { 128, 192 } };
	/* Z1 (deck V4m2: white peaks blink at the slowest zooms): the HW half ring keeps equal-power at every zoom.
	 * The soft 220/220 spread a 1-px white line over 2 px at ~86 % (per channel clamp: ~white on blue): +48 % of
	 * its light in every half-phase frame, on / off at 9 Hz (zoom 0) / 19 Hz (zoom 1) -- the blink. 174/174:
	 * +10 % (emu, work/zoom1), tip max luma 84 % -- the weights zoom 2-4 always had (they looked fine) */
	const u8 (*T)[2] = ph_zs ? EPZ : EP;
#endif
	u32 ra = a >> 11, ga = (a >> 5) & 63, ba = a & 31, rb = b >> 11, gb = (b >> 5) & 63, bb = b & 31;
	u32 ya = 154 * ra + 150 * ga + 58 * ba, yb = 154 * rb + 150 * gb + 58 * bb, wa, wb, r, g, bl;
	int sim;
	if (a == b)
		return a;
	sim = yb ? (ya * 100 > yb * 44 && ya * 1000 <= yb * 2222) : !ya;
	if (sim) {
		wb = (u32)p * 64;
		wa = 256 - wb;
	} else {
		wa = T[p - 1][0];
		wb = T[p - 1][1];
	}
	r = (ra * wa + rb * wb) >> 8; g = (ga * wa + gb * wb) >> 8; bl = (ba * wa + bb * wb) >> 8;
	if (!sim) {
		u32 m;
		m = ra > rb ? ra : rb; if (r > m) r = m;
		m = ga > gb ? ga : gb; if (g > m) g = m;
		m = ba > bb ? ba : bb; if (bl > m) bl = m;
	}
	return (u16)(r << 11 | g << 5 | bl);
}
#endif
#ifdef V2_SUBPX
HOTSW static void phase_col(int k)
{
	int k1 = k + 1 == WAVE_N ? 0 : k + 1, y, p;
	for (y = 0; y < RING_H; y++) {
		u16 a = RING[y * WAVE_N + k], b = RING[y * WAVE_N + k1];
		for (p = 0; p < 3; p++)
			PRING(p)[y * WAVE_N + k] = ph_blend(a, b, p + 1);
	}
}
#endif
static void wave_col(int c, int k, const volatile u16 *e, u32 n, s32 e_first, int sc)
{
	wave_col_(c, k, e, n, e_first, sc);
#ifdef V2_SUBPX
	if (!ph_bulk) {
		phase_col(k);
		phase_col(k ? k - 1 : WAVE_N - 1);
	}
#endif
}
/* the half profile cb[0..top+1] of screen column c in the current look; -1 = empty column (V3d: shared
 * by the band's ring and the phase meter's master mini-waveform) */
HOT static int col_prof(int c, const volatile u16 *e, u32 n, s32 e_first, int sc, u16 *cb)
{
	struct wraw p, q, r;
	int top = -1, look;
	raw_col(&q, c, e, n, e_first, sc);
	if (!q.kind) {
		cb[0] = wc_bg;
		return -1;
	}
	raw_col(&p, c - 1, e, n, e_first, sc);
	raw_col(&r, c + 1, e, n, e_first, sc);
	if (p.kind != q.kind) p = q;
	if (r.kind != q.kind) r = q;
	look = q.kind == 3 ? 2 : wave_type;
	if (look == 0 && q.kind == 2) {
		/* V3c: 3BAND on a PWV5-only track (no .2EX / PWV7): its low / mid / high fields (red / green /
		 * blue, 0..28 here) x the height, drawn in the 3-band look -- as MAIN's wave3ovrgb already does
		 * for the overview from the same analysis; the RGB look made bass-heavy tracks a red band under
		 * a blue/orange/white overview (Aaiko: 72 % of its PWV5 entries are pure 7/0/0 red) */
		struct wraw *v[3] = { &p, &q, &r };
		int j;
		for (j = 0; j < 3; j++) {
			u32 h = v[j]->h;
			v[j]->a = udiv(h * v[j]->a, 28);
			v[j]->b = udiv(h * v[j]->b * 3, 28 * 4);	/* PWV5's fields are a normalised hue, not band */
			v[j]->c = udiv(h * v[j]->c, 28 * 5);	/* energies: mid x3/4, high x1/5 (x2.4 in the look) keep
								 * the cream core inside the blue / orange body as in real
								 * PWV7 data (V3e1: mid x1.0 in the look -> orange shows) */
		}
	} else if (look == 0 && q.kind != 1)
		look = 1;			/* 3BAND without band data (BLUE detail): the RGB look */
	if (look == 0) {
		u32 lo = sm3(p.a, q.a, r.a), mi = sm3(p.b, q.b, r.b), hi = sm3(p.c, q.c, r.c);
		look_3band(cb, lo, mi, hi);
		top = bandh(udiv(lo * 6, 5));
		if (bandh(B3_HI(hi)) > top) top = bandh(B3_HI(hi));
		if (bandh(B3_MI(mi)) > top) top = bandh(B3_MI(mi));
	} else {
		u32 h = sm3(p.h, q.h, r.h);
		/* PHASEWAVE: the master mini (sc > 0) in BLUE / RGB as the CDJ-3000's DetailedWaveformDrawer
		 * (renderWaveform_new: channel 0's height forced >= 1 at) -- every column with
		 * data inside the track shows at least its centre row: a 1-px centre line through silence / quiet
		 * parts in the column's colour (user: BLUE had no centre line) */
		top = h ? bandh(h) : sc > 0 ? 0 : -1;
		if (look == 2) {
			/* V3rc8s (user: BLUE unchanged on a real track -- the high band alone put most columns near white):
			 * whiteness = the high band's SHARE of the column (the 3000: blue body, white only where hats
			 * dominate): 14 x hi / (lo + mi + hi), 0..7 */
			u32 w = q.kind == 3 ? q.a : q.kind == 1 ? udiv(q.c * 14, q.a + q.b + q.c + 1) :
				udiv(q.c * 14, q.a + q.b + q.c + 1);
			look_blue(cb, top, w);
		} else if (q.kind == 1) {	/* hue from the bands, squared (as PWV5's saturated colours); V3e1
						 * (audit X1/X5: a green band where rekordbox is red / violet): the mid
						 * band weighs 2/5 in the hue -- on real PWV7 data mid ~ low, and mid ->
						 * green made the band green */
			u32 g = udiv(q.b * 2, 5);
			look_rgb(cb, top, q.a * q.a, g * g, q.c * q.c);
		} else {
			look_rgb(cb, top, q.a, q.b, q.c);
		}
	}
	return top;
}
HOTSW static void wave_col_(int c, int k, const volatile u16 *e, u32 n, s32 e_first, int sc)
{
	u16 cb[HALF + 2];
	put_col(k, cb, col_prof(c, e, n, e_first, sc, cb));
	v2_wave_cols++;
}
/* signed a / b for b > 0 (no libgcc) */
static s32 sdiv(s32 a, s32 b) { return a >= 0 ? (s32)udiv((u32)a, (u32)b) : -(s32)udiv((u32)-a + (u32)b - 1, (u32)b); }
extern u32 v2_frames;
static int b_sh, b_sc, b_anim;		/* this frame's band scale: entries per column = 2^b_sh (b_sc / 16 while zooming) */
static u32 b_epb;			/* entries per beat near the playhead (from the grid), 0 = none */
static s32 b_F;			/* V4n27z: the software band's first column (absolute); wave_band's first = it */
static s32 e2c(s32 d) { return bcol(d + b_F, b_sh) - b_F; }	/* (entries - first) -> screen columns */
#define ZOOM_FR 1			/* METERALIGN: must stay 1 -- the glide below passes a positive x 16 sc that raw_col now reads as the master mini's x 256; V3rc8: instant zoom as the CDJ-3000 (zoomIn/Out only set the scale); the 9-frame glide recomputed all columns each frame = the zoom flicker */
u32 v2_zoom_anims;
static int need(int id, u32 key);
static u32 band_xk;		/* V3f: the inputs of the band's other layers (loop pads, labels, numbers) */
#define R_BAND 26		/* V3f: the band (ring copy + ticks + marks + playhead + pads / labels) */
/* the ring to the frame buffer, two runs a row (head .. end, 0 .. head); the loop's columns [la, lb]
 * (screen columns) get the wash over their background pixels */
/* V3e3 (audit L1): with the loop pads open the 3000 shrinks the waveform to half height, centred at y 185
 * (rows SH_Y0 .. SH_Y0 + RING_H / 2 of the band), the pads below it */
static int b_shrink;
#define SH_Y0 17
HOTSW static void band_copy(int la, int lb)
{
	int y;
	u16 bg = wc_bg, wash = in_wave ? 0xFF18 : 0x4208;	/* #FFE0C0 / V3e1 (audit W7): #424242 */
	dmark(BAND_Y0, RING_H);
#ifdef V2_SUBPX
	u16 *rb0 = b_phase && !b_anim ? PRING(b_phase - 1) : RING;
#else
	u16 *rb0 = RING;
#endif
	for (y = 0; y < RING_H; y++) {
		const u16 *src = rb0 + y * WAVE_N;
		u16 *dst = fb + (BAND_Y0 + y) * W + WAVE_X0;
		int a = WAVE_N - ring_head, x;
		if (b_shrink) {
			int sy = y - SH_Y0;
			if (sy < 0 || sy >= RING_H / 2) {	/* V3rc1: runs, not a test per pixel (loop in: 190 ms) */
				if (la <= lb) {
					fill16(dst, la, bg);
					fill16(dst + la, lb - la + 1, wash);
					fill16(dst + lb + 1, WAVE_N - lb - 1, bg);
				} else
					fill16(dst, WAVE_N, bg);
				continue;
			}
			src = rb0 + 2 * sy * WAVE_N;
		}
		cp16(dst, src + ring_head, a);
		cp16(dst + a, src, ring_head);
		for (x = la; x <= lb; x++)
			if (dst[x] == bg)
				dst[x] = wash;
	}
}
/* V3rc5 SMOOTH+ (re/V3_PROGRESS.md "V3rc5"): the band's position from a time-smoothed clock instead of the raw
 * heartbeat sample. The heartbeat position (1/150 s entries) arrives at MAIN's cadence, sampled at ours: the
 * per-frame advance jitters (2..7 entries a frame in the emu) and the whole-column steps land unevenly. Like
 * the 3000 (one vsync-phased timer, display update timer): advance at the measured play rate per elapsed ms,
 * pull softly (1/8 per frame) toward the sample, snap on a jump (cue, search, loop) and when not playing
 * forward (pause, reverse, scratch: the raw sample, exact). Never steps back while playing forward. */
static u32 b_frac8;	/* V3rc8: the smoothed position's sub-entry fraction (Q8), 0 when raw */
/* LOCALMETER2 (deck V4n55t: feeding the band from a per-frame cache moved the band): READ-ONLY copies of the band's
 * last result -- position Q8 (1/150 s << 8), its time and play rate (entries << 8 per ms); the band is unchanged */
static u32 bp_q8, bp_t;
static s32 bp_rate;
static u32 band_pos_pub(u32 pos, u32 t, s32 rate)
{
	bp_q8 = (pos << 8) + b_frac8;
	bp_t = t;
	bp_rate = rate;
	return pos;
}
static u32 band_pos(u32 pos)
{
	static s32 d, rate, last_pred;
	static u32 last_t, last_s, last_st, last_chg, last_raw;
	u32 t = now_ms(), dt = t - last_t;
	s32 err, pred;
	last_t = t;
	if (dt > 100)
		dt = 100;
	int fresh = pos != last_raw;
	if (fresh) {
#ifdef V2_HUD
		if (t - last_chg > v2_pstall)
			v2_pstall = t - last_chg;
#endif
		last_raw = pos;
		last_chg = t;
	}
	if (t - last_st >= 100) {	/* the play rate over >= 100 ms windows, entries << 8 per ms */
		s32 dp = (s32)(pos - last_s);
		u32 w = t - last_st;
		if (dp > 0 && w < 400 && dp < (s32)w) {
			s32 r = (s32)udiv((u32)dp << 8, w);
			rate = rate ? (rate * 3 + r) >> 2 : r;
		} else
			rate = 0;
		last_s = pos;
		last_st = t;
	}
	if (t - last_chg > 120)		/* paused / held */
		rate = 0;
	if (!rate) {
		d = (s32)(pos << 8);
		last_pred = (s32)pos;
		b_frac8 = 0;
		return band_pos_pub(pos, t, 0);
	}
	d += rate * (s32)dt;
	err = (s32)(pos << 8) - d;
	/* V3rc8 (deck: a hitch every 2-3 s): the heartbeat position can sit still for tens of ms while MAIN is
	 * busy -- a stale sample says nothing: no pull toward it and no backward snap (that was the hitch: the
	 * prediction ran ahead, then snapped back to the stale value, then jumped forward). Correct / snap only on
	 * a fresh sample (pos changed this frame); a stall longer than 120 ms still stops the clock (rate 0). */
	if (fresh) {
		if (err > (40 << 8) || err < -(6 << 8)) {	/* a jump (loop, cue, search): follow it, both ways */
			d = (s32)(pos << 8);
			last_pred = (s32)pos;
		} else
			d += err >> 3;
	} else if (err > (40 << 8))
		d = (s32)(pos << 8);
	pred = d >> 8;
	b_frac8 = (u32)d & 255;
	if (pred < last_pred) {
		pred = last_pred;
		b_frac8 = 255;	/* held at the last whole entry: keep the highest phase, never step back */
	}
	last_pred = pred;
	return band_pos_pub(pred < 0 ? 0 : (u32)pred, t, rate);
}
static int wave_band(void)
{
	static u32 r_base, r_n, r_sh = 99, r_day, r_ok, r_type;
	static int rf_left, rf_c;	/* V3rc8: progressive refresh after a data change (columns left, next column) */
	static s32 r_first;
	static int z_sh = -9, z_from, z_to;	/* V4n32: -9 = none (sh -1 is a zoom now) */
	static u32 z_t0;
	u32 n = u32be(DECK + 0x74), pos = u32be(DECK + 0x70), z = zkey();
	u32 base = WENT, lk;
	if (present_mode == PM_PLUS)
		pos = band_pos(pos);
	const volatile u16 *e;
	int sh, sc, c, i, k2;
	s32 first, d;

	wblue = 0;
	b_epb = 0;
	if (det_blue && WBLUE) {	/* V3a: this load brought the BLUE detail (0x36), e.g. a LINK load */
		base = WBLUE;
		wblue = 1;
	}

	if (det_holding && !n && r_ok)	/* V3rc8: the entry count drops with the length: keep the last one */
		n = r_n;
	if (!base || !n || n > 0x200000 || !wave_data_ok()) {
		r_ok = 0;
		z_sh = -9;
		if (!need(R_BAND, hmix(0xB0, band_xk)))
			return 0;
		fill(0, BAND_Y0, W, BAND_Y1 - BAND_Y0, C_BLACK);
		return 1;
	}
	if (pos > n)
		pos = n;
	e = (const volatile u16 *)((base & 0x1FFFFFFF) | 0x20000000);
	sh = ZSH(z);
	/* V3c (W7): smooth zoom -- a zoom step glides from the old scale to the new one over ZOOM_FR frames
	 * (every column recomputed at the in-between scale; the ring takes over at the end) */
	if (z_sh < -1)
		z_sh = sh;
	if (sh != z_sh) {
		z_from = b_anim ? b_sc : SHL(16, z_sh);
		z_to = SHL(16, sh);
		z_t0 = v2_frames;
		z_sh = sh;
		v2_zoom_anims++;
	}
	sc = BSC(sh);		/* V4n27z: the 3000's time span (raw_col's band scale) */
	b_anim = 0;
	if (z_from && v2_frames - z_t0 + 1 < ZOOM_FR) {
		/* V3f: the first frame already moves (stock steps at once): ease-out from t = 1 */
		s32 u = ZOOM_FR - (s32)(v2_frames - z_t0 + 1);
		sc = z_from + (int)sdiv((z_to - z_from) * (ZOOM_FR * ZOOM_FR - u * u), ZOOM_FR * ZOOM_FR);
		if (sc < 16) sc = 16;
		b_anim = 1;
	} else
		z_from = 0;
	b_sh = sh;
	b_sc = sc;
	/* the active loop (shaded in the band, as the 3000) */
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
	lk = ((u32)lp_st ^ (u32)lp_en * 0x01000193) + DECK[0xD3];
	if (b_anim) {
		/* the playhead's entry stays under the playhead at every in-between scale */
		first = (s32)pos - ((V2_PLAYHEAD * sc) >> 4);
#ifdef V2_SUBPX
		ph_bulk = 1; phr_left = WAVE_N; ph_c = 0;
#endif
		for (c = 0; c < WAVE_N; c++)
			wave_col(c, c, e, n, first, sc);
#ifdef V2_SUBPX
		ph_bulk = 0;
#endif
		ring_head = 0;
		r_ok = 0;		/* the ring is rebuilt at the target scale when the glide ends */
		ring_gen++;
		v2_wave_full++;
	} else {
	/* column grid aligned to the zoom: whole-column shifts, the playhead within its column */
	first = bcol((s32)pos, sh) - V2_PLAYHEAD;	/* V4n27z: a COLUMN (absolute) now, wave_col's e_first */
	b_F = first;
	d = first - r_first;
	{	/* the detail waveform arrives in chunks after the load: a sample of the visible entries */
		static u32 r_ck;
		u32 ck = 0;
		u32 step = (n >> 5) | 1, j;
		for (j = 0; j < n; j += step)		/* 32 fixed spots over the whole track */
			ck = ck * 33 + e[j];
		/* V3rc8 (deck HUD: a second with B +9, WX 23 ms, Q 43 ms = the hitch): MAIN rewrites the detail buffer now
		 * and then while playing; a full rebuild of all 680 columns in one frame overran the 33 ms budget. A data
		 * change alone (same track / scale / look) now refreshes the ring progressively, RF_STEP columns a
		 * frame, in the normal scroll path below */
		if (ck != r_ck && r_ok) {
			rf_left = WAVE_N;
			v2_wave_rf++;
		}
		r_ck = ck;
		{	/* LOADFIX: the scheduled re-read after a load (ld_reread) */
			static u32 rs_t0, rs_stage;
			if (ld_reread(&rs_t0, &rs_stage) && r_ok)
				rf_left = WAVE_N;
		}
	}
#ifdef V2_SUBPX
	ph_soft = sh >= 3;	/* V3rc8t: a zoom change rebuilds the ring and the phase rings with the new weights */
#endif
	if (!r_ok || base != r_base || n != r_n || (u32)sh != r_sh || (u32)day != r_day || (u32)wave_type != r_type ||
	    d >= WAVE_N || d <= -WAVE_N) {
		/* V3rc8 TEST: why (HUD R): 1 not ok, 2 data pointer, 3 length, 4 zoom, 5 day, 6 look, 7 jump */
		v2_wf_why = !r_ok ? 1 : base != r_base ? 2 : n != r_n ? 3 : (u32)sh != r_sh ? 4 : (u32)day != r_day ? 5 :
			    (u32)wave_type != r_type ? 6 : 7;
		v2_wf_hist[v2_wf_why]++;
#ifdef V2_SUBPX
		ph_bulk = 1; phr_left = WAVE_N; ph_c = 0;
#endif
		for (c = 0; c < WAVE_N; c++)
			wave_col(c, c, e, n, first, sc);
#ifdef V2_SUBPX
		ph_bulk = 0;
#endif
		ring_head = 0;
		r_ok = 1;
		rf_left = 0;
		r_base = base; r_n = n; r_sh = sh; r_day = day; r_type = wave_type;
		ring_gen++;
		v2_wave_full++;
	} else if (d > 0) {			/* forward: the head moves right, new columns at the end */
#ifdef V2_SM_CHECK
		v2_dh[d < 7 ? d : 7]++;
		{	/* gate-only: frame interval (ms) and entries moved, while scrolling forward */
			static u32 lt, lp;
			u32 t = now_ms(), dt = t - lt;
			v2_ft[dt < 15 ? dt : 15]++;
			v2_pe[pos - lp < 15 ? pos - lp : 15]++;
			lt = t; lp = pos;
		}
#endif
		ring_head = (ring_head + d) % WAVE_N;
		for (c = WAVE_N - d; c < WAVE_N; c++)
			wave_col(c, (ring_head + c) % WAVE_N, e, n, first, sc);
		ring_gen++;
	} else if (d < 0) {			/* reverse / back cue: new columns at the start */
		ring_head = (ring_head + d + WAVE_N) % WAVE_N;
		for (c = 0; c < -d; c++)
			wave_col(c, (ring_head + c) % WAVE_N, e, n, first, sc);
		ring_gen++;
	} else {
		v2_wave_same++;
	}
	if (rf_left > 0 && r_ok) {	/* V3rc8: the progressive refresh (columns in ring order from the left edge) */
/* V3rc8s (deck: zoom 1 "blink", zoom 4 "lag" every few seconds): MAIN rewrites the detail buffer every few
 * seconds while playing; the refresh ran 96 columns a frame as a BULK write and restarted the phase-ring
 * revalidation each time -- sub-pixel OFF (b_phase 0) for ~25 frames: the band snapped to whole columns and
 * back (zoom 1) and those frames ran long (zoom 4). Now 24 columns a frame, each refreshing its own and its
 * left neighbour's phases as it is written (wave_col, ph_bulk 0): the phase rings never go stale, sub-pixel
 * never switches off, and the per-frame cost stays flat. */
#define RF_STEP 24
		int k = rf_left < RF_STEP ? rf_left : RF_STEP;
		for (c = 0; c < k; c++, rf_c = rf_c + 1 >= WAVE_N ? 0 : rf_c + 1)
			wave_col(rf_c, (ring_head + rf_c) % WAVE_N, e, n, first, sc);
		rf_left -= k;
		ring_gen++;
		if (rf_left > 0)
			pend = 1;	/* LOADFIX: finish the refresh on a paused deck too (frames flip on change only) */
	}
#ifdef V2_SUBPX
	if (phr_left > 0) {	/* revalidate the phase rings progressively */
#define PH_STEP 48
		int k = phr_left < PH_STEP ? phr_left : PH_STEP;
		for (c = 0; c < k; c++, ph_c = ph_c + 1 >= WAVE_N ? 0 : ph_c + 1)
			phase_col(ph_c);
		phr_left -= k;
	}
	{	/* this frame's sub-column phase (quarters of a column) from the position's fraction */
		/* the position within the column in Q8 of a column: whole entries past the column start plus the smoothed
		 * sub-entry fraction (SMOOTH+), divided by the entries per column -- quarters of a column, every zoom */
		u32 sub = pos - (u32)bent(bcol((s32)pos, sh), sh), q8 = (((sub << 8) + (present_mode == PM_PLUS ? b_frac8 : 0)) * 5) >> (sh + 3);
		b_phase = phr_left ? 0 : (int)(q8 >> 6);
	}
#endif
	r_first = first;
	}
	/* V3f: the band is keyed per buffer like a region -- nothing is copied when the scroll position, the
	 * ring, the marks, the grid, the playhead state and the layers on top (band_xk) are as this buffer
	 * last got them (a paused player: no 140 KB copy a frame) */
	{
		u32 bk = hmix(hmix(hmix(hmix((u32)first, ring_gen), (u32)sc | (u32)b_anim << 16), lk), marks_ck());
#ifdef V2_SUBPX
		bk = hmix(bk, (u32)b_phase);
#endif
		bk = hmix(hmix(hmix(bk, grid_ck() + (u32)G_OFF), (u32)(slip_on() * 2 + deck_playing())),
			  (u32)(ph_left | day << 1 | wave_type << 2 | wblue << 4 | GRID_OK << 5));
		if (!need(R_BAND, hmix(bk, band_xk)))
			return 0;
	}
	fill(0, BAND_Y0, WAVE_X0, BAND_Y1 - BAND_Y0, C_BLACK);
	fill(WAVE_X0 + WAVE_N, BAND_Y0, W - WAVE_X0 - WAVE_N, BAND_Y1 - BAND_Y0, C_BLACK);
	{
		s32 la = 1, lb = 0;
		if (lp_en > lp_st) {
			la = e2c(lp_st - first);
			lb = e2c(lp_en - first);
			if (la < 0) la = 0;
			if (lb >= WAVE_N) lb = WAVE_N - 1;
		}
		b_shrink = DECK[0xD3] == 3 || DECK[0xD3] == 5;	/* (band_xk carries +0xD3) */
		band_copy(la, lb);
	}
	/* beat ticks above and below: downbeats red and long, the other beats white */
	{
		u32 cntg = u32be(GRID + 4), rp = u32be(GRID + 0x18);
		const volatile u8 *r;
		static u32 t0;		/* first beat at or left of the band, kept between frames */
		if (cntg && cntg < 8192 && (rp & 0xFF000000) == 0x0F000000) {
			const volatile u8 *r0 = (const volatile u8 *)((rp & 0x1FFFFFFF) | 0x20000000);
			u32 first_ms = first > 0 ? udiv((u32)bent(first, sh) * 20, 3) : 0, pos_ms = udiv(pos * 20, 3);
			s32 prev = -1;
			if (t0 >= cntg || gms(r0 + 20 * t0) > first_ms)
				t0 = 0;
			while (t0 + 1 < cntg && gms(r0 + 20 * (t0 + 1)) < first_ms)
				t0++;
			r = r0 + 20 * t0;
			for (i = (int)t0; i < (int)cntg; i++, r += 20) {
				u32 ms = gms(r);
				s32 ent = (s32)udiv(ms * 3, 20), d = ent - first;
				int col, down = u16be(r) == 1, len = down ? 9 : 5;
				/* the beat length at the playhead (for the beat-distance numbers) */
				if (prev >= 0 && !b_epb && ms > pos_ms)
					b_epb = (u32)(ent - prev);
				prev = ent;
				col = e2c(d);
				if (col < 0 || (!down && BARS_ONLY_SH(sh)))	/* BANDFLICK: bar heads only when zoomed out */
					continue;
				if (col >= WAVE_N) {
					if (b_epb)
						break;
					continue;
				}
				/* V3e1 (audit Q8): 1 px, 10 tall, beats #A6A6A6, bars red, at the 3000's rows */
				(void)len;
				fill(WAVE_X0 + col, b_shrink ? 127 : 141, 1, 10, down ? C_RED : 0xA534);
				fill(WAVE_X0 + col, b_shrink ? 232 : 279, 1, 10, down ? C_RED : 0xA534);
			}
		}
	}
	/* cue / hot cue / memory / loop marks in the band (V3c: the 3000's letter badges for hot cues, a red
	 * triangle for memory cues; the active loop is shaded in the ring, a stored one gets orange bars;
	 * V3d: hot cues in a second pass, on top of a memory cue at the same place) */
	for (k2 = 0; k2 < 2 * N_MARKS; k2++) {
		int pass = k2 >= N_MARKS;
		const volatile u8 *r;
		u32 st, en;
		s32 c0, c1;
		i = pass ? k2 - N_MARKS : k2;
		r = MARKS + 16 * i;
		st = u32be(r + 8);
		en = u32be(r + 12);
		if (st == 0xFFFFFFFF || (i >= 1 && i <= N_HOT) != pass)
			continue;
		c0 = e2c((s32)st - first);
		if (en != 0xFFFFFFFF && en > st) {
			/* V3rc8t (3000 gap sweep #4): no orange bars / edges on stored loops -- the 3000 shows the
			 * ACTIVE loop as a light wash (band_copy) and a stored loop only by its start marker */
			(void)c1;
			if (i == 0)
				continue;
		}
		if (c0 < 0 || c0 >= WAVE_N)
			continue;
		if (i == 0) {	/* V3rc8t (3000 gap sweep #3): the current cue = an orange triangle under the band
				 * (#F8A030, skin img_currentCue), no full-height red line */
			tri(WAVE_X0 + c0, BAND_Y1 - 6, 0xFD06);
		} else if (i <= N_HOT) {
			u16 col = hot_col(i, r);
			vrun(WAVE_X0 + c0, BAND_Y0 + 2, BAND_Y1 - BAND_Y0 - 4, col);
			if (WAVE_X0 + c0 + 10 <= W)
				cue_badge(WAVE_X0 + c0, BAND_Y0, i - 1, col);
		} else {
			u16 mc = mem_col(r);
			vrun(WAVE_X0 + c0, BAND_Y0 + 2, BAND_Y1 - BAND_Y0 - 4, mc);
			tri_dn(WAVE_X0 + c0, BAND_Y0, mc);
		}
	}
	/* playhead: V3e1 (audit W1/Q3) red while playing, white when paused / at the cue, yellow with SLIP on */
	fill(WAVE_X0 + V2_PLAYHEAD - 1, BAND_Y0 + 2, 2, BAND_Y1 - BAND_Y0 - 4,
	     slip_on() ? 0xFF20 : deck_playing() ? C_RED : C_WHITE);
	return 1;
}

/* Deck-state sanity (re/V2_DEBUG.md D2/D4): +0x6C = 2 after a failed load (E-8302 / E-8305: BPM
 * 0xFFFFFFFF, times 0xFF..), the GUI's composed error line in on-chip RAM 0x1C04A570 (UTF-16BE).
 * The pitch +0x64 is in 0.01 % for ±6/10/16 but in 0.1 % in WIDE (range index 4). */
#define ERR_TXT ((const volatile u8 *)0x1C04A570)
/* the deck's own player number: DECK+0x5C (1..4; two-deck LINK run, re/V2_DEBUG.md D5) */
/* players 5/6 (re/PLAYER56_RE.md §11): the display path may carry them as codes 7/8 */
static u32 pno56(u32 p) { return p == 7 || p == 8 ? p - 2 : p; }
/* V4n17 (RE_NEXT_FINDINGS Q3): heartbeat +0x58 == 0 = the number is not confirmed (Pro DJ Link negotiation, or no
 * network): stock BLINKS its own number then (250 ms) instead of showing the numbers being tried -- keep the last
 * confirmed one and blink it (pn_blank() = the off phase) */
static u32 pn_last, pn_t0, pn_neg, pn_raw, pn_rawt;
/* V4n28 (deck, network commander): +0x58 is 0 also in normal AUTO numbering (LNKH 0x0A35F740 == 1 path), so
 * it is not "unconfirmed" by itself. Confirmed = +0x58 == 1, OR MAIN publishes the same non-zero number in
 * +0x5C for >= 600 ms. Unconfirmed (stock blinks its own number / cycles candidates): blink while it
 * negotiates (first 6 s, or whenever a different candidate shows up), grey afterwards; white when confirmed. */
static int pn_stable(void) { return pn_raw && now_ms() - pn_rawt >= 600; }
static int pn_unconf(void) { return u32be(DECK + 0x58) == 0 && !pn_stable(); }
static void pn_track(u32 raw)
{
	u32 t = now_ms();
	if (raw != pn_raw) {
		if (raw && pn_raw && raw != pn_raw)
			pn_neg = t | 1;		/* a different candidate: MAIN (re)negotiates */
		pn_raw = raw;
		pn_rawt = t;
	}
	if (!pn_unconf()) {
		pn_t0 = 0;
		return;
	}
	if (!pn_t0)
		pn_t0 = t | 1;
}
static int pn_blinking(void)
{
	u32 t = now_ms();
	return pn_unconf() && ((pn_t0 && t - pn_t0 < 6000) || (pn_neg && t - pn_neg < 2500));
}
static int pn_blank(void) { return pn_blinking() && ((now_ms() / 250) & 1); }
static int pn_grey(void) { return pn_unconf() && !pn_blinking(); }
static u32 player_num(void)
{
	u32 raw = pno56(u32be(DECK + 0x5C)), ok = raw >= 1 && raw <= 6;
	if (!ok && V32_PN >= 5) {	/* V4n32 (#6): a deck at 5 / 6 (mods/player56) -- +0x5C says 0xFF there; MAIN's own */
		raw = V32_PN;		/* number (modsmenu v32_pub) */
		ok = 1;
	}
	pn_track(ok ? raw : 0);
	if (ok && (!pn_unconf() || !pn_last))
		pn_last = raw;
	return pn_last ? pn_last : 1;
}
static int load_failed(void) { return u32be(DECK + 0x6C) == 2; }
static s32 pitch100(s32 raw, u32 range) { return range == 4 ? raw * 10 : raw; }
/* V3e1 (re/AV_SYNC_COMPARE.md): heartbeat +0x24 = 2 is BPM mode (synced, or the tempo held after SYNC
 * off); 1 = % mode. V4n34 (stock heartbeat builder 0x084E34C4..0x084E3554, two-deck emu work/tempo): in BPM mode
 * +0x64 is the TEMPO FADER's position as a BPM x 10 = track BPM (0x083FBE94) x (10000 + fader pitch, 0x0B056C50
 * via 0x08446AC8) / 10000 -- not the track's BPM -- and +0x68 the playing BPM. The playing pitch (in +0x64's %
 * units: 0.01 %, 0.1 % in WIDE) is +0x68 over the track's own BPM (the grid at the playhead); no grid: over +0x64
 * (exact only with the fader at 0). Never format +0x64 as a pitch there. */
static int bpm_mode(void) { return u32be(DECK + 0x24) == 2; }
static u32 grid_bpm100(u32 el_ms);
static s32 pitch_raw(void)
{
	s32 raw = (s32)u32be(DECK + 0x64);
	if (bpm_mode()) {
		u32 tb = (u32)raw * 10, b = u32be(DECK + 0x68), g = grid_bpm100(u32be(DECK + 0x78));
		s32 p;
		if (g)
			tb = g;
		if (tb < 2000 || tb >= 100000 || b >= 10000)
			return 0;
		p = (s32)udiv(b * 100000 + tb / 2, tb) - 10000;
		return u32be(DECK + 0x44) == 4 ? sdiv(p + 5, 10) : p;
	}
	return raw;
}
/* V4n34: the TEMPO fader's position as a BPM x 10 in BPM mode (+0x64; stock draws it grey), 0 otherwise */
static u32 fader_bpm10(void) { return bpm_mode() && u32be(DECK + 0x64) < 10000 ? u32be(DECK + 0x64) : 0; }
/* V4n34: SYNC turned off with the fader away from the playing tempo: stock keeps that tempo (+0x24 stays 2, the
 * flag 0x0B056854) until the fader crosses it (0x08449C94 / 0x0844A744 clear the flag; +0x24 -> 1, % again).
 * The way to move the fader: +1 = faster (the playing BPM is above the fader's), -1 = slower, 0 = none */
static int fader_dir(u32 fb10, u32 sync, u32 bpm10)
{
	if (sync || !fb10 || !bpm_mode() || !bpm10 || bpm10 >= 10000 || fb10 == bpm10)
		return 0;
	return bpm10 > fb10 ? 1 : -1;
}
/* the takeover arrow: the way the TEMPO slider has to go, h rows; faster = toward the DJ (+ at the bottom): down */
static void tko_arrow(int cx, int y, int dir, int h, u16 c)
{
	int i;
	for (i = 0; i < h; i++) {
		int hw = dir > 0 ? h - 1 - i : i;
		fill(cx - hw, y + i, 2 * hw + 1, 1, c);
	}
}
/* V3e1: this deck is the tempo master -- +0xA0 = 1, but not while +0xA4 names another player (a SYNC
 * follower read +0xA0 = 1 in ~1 of 40 samples: the MASTER box flashed); a change needs 3 frames */
static int is_master(void)
{
	static int st, cnt;
	static u32 fr = 0xFFFFFFFF;
	u32 a4 = pno56(u32be(DECK + 0xA4));
	int raw;
	if (fr == v2_frames)
		return st;
	fr = v2_frames;
	raw = u32be(DECK + 0xA0) == 1 && !(a4 >= 1 && a4 <= 6 && a4 != player_num());
	if (raw != st) {
		if (++cnt >= 3) { st = raw; cnt = 0; }
		pend = 1;
	} else
		cnt = 0;
	return st;
}
/* "+1.25" / "-22.0" (WIDE: one decimal), into p */
static void fmt_pitch(char *p, s32 raw, u32 range)
{
	u32 a = raw < 0 ? -raw : raw;
	if (raw > 0) *p++ = '+';
	if (raw < 0) *p++ = '-';
	if (range == 4) {
		if (a >= 1000) *p++ = '0' + udiv(a, 1000) % 10;
		if (a >= 100) *p++ = '0' + udiv(a, 100) % 10;
		*p++ = '0' + udiv(a, 10) % 10;
		*p++ = '.';
		*p++ = '0' + a % 10;
	} else {
		if (a >= 1000) *p++ = '0' + udiv(a, 1000) % 10;
		*p++ = '0' + udiv(a, 100) % 10;
		*p++ = '.';
		*p++ = '0' + udiv(a, 10) % 10;
		*p++ = '0' + a % 10;
	}
	*p = 0;
}

/* BPM with two decimals and the pitch applied (UTILITY > BPM DECIMALS, as rekordbox / the CDJ-3000):
 * the beat grid's BPM x 100 at the play position (record {u16 beat, u16 bpm x 100, u32 ms, ...})
 * times (10000 + pitch) / 10000, the pitch in 0.01 % (every TEMPO RANGE). 0 when there is no grid or
 * the result disagrees with stock's own BPM x 10 by more than 0.1 (then one decimal, as before). */
static u32 bpm100_at1(u32 bpm10, s32 tempo, u32 el_ms);
/* never 0 for a known BPM: before the grid is in (or when it disagrees) stock's BPM x 10, so the
 * BPM DECIMALS layout is final from the first frame */
static u32 bpm100_at(u32 bpm10, s32 tempo, u32 el_ms)
{
	u32 v = bpm100_at1(bpm10, tempo, el_ms);
	return v ? v : (bpm10 && bpm10 < 10000 ? bpm10 * 10 : 0);
}
static u32 bpm100_at1(u32 bpm10, s32 tempo, u32 el_ms)
{
	static u32 last_i;
	u32 cnt = u32be(GRID + 4), rp = u32be(GRID + 0x18), i, base, v, t10;
	const volatile u8 *r;
	if (!GRID_OK)		/* V3a: no rekordbox grid on this track */
		return 0;
	if (!bpm10 || !cnt || cnt >= 8192 || (rp & 0xFF000000) != 0x0F000000 || tempo <= -10000)
		return 0;
	r = (const volatile u8 *)((rp & 0x1FFFFFFF) | 0x20000000);
	i = last_i < cnt ? last_i : 0;
	if (gms(r + 20 * i) > el_ms)
		i = 0;
	while (i + 1 < cnt && gms(r + 20 * (i + 1)) <= el_ms)
		i++;
	last_i = i;
	base = u16be(r + 20 * i + 2);
	if (!base || base > 30000)
		return 0;
	v = udiv(base * (u32)(10000 + tempo) + 5000, 10000);
	t10 = udiv(v + 5, 10);
	if (t10 + 1 < bpm10 || t10 > bpm10 + 1)
		return 0;
	return v;
}

/* the track's own BPM x 100 at el_ms from the beat grid (no pitch): SYNC shows it grey (as stock) */
static u32 grid_bpm100(u32 el_ms)
{
	static u32 last_i;	/* V4n34: a cursor, as bpm100_at1 (pitch_raw() asks every frame in BPM mode) */
	u32 cnt = u32be(GRID + 4), rp = u32be(GRID + 0x18), i, base;
	const volatile u8 *r;
	if (!GRID_OK)		/* V3a: no rekordbox grid on this track */
		return 0;
	if (!cnt || cnt >= 8192 || (rp & 0xFF000000) != 0x0F000000)
		return 0;
	r = (const volatile u8 *)((rp & 0x1FFFFFFF) | 0x20000000);
	i = last_i < cnt ? last_i : 0;
	if (gms(r + 20 * i) > el_ms)
		i = 0;
	while (i + 1 < cnt && gms(r + 20 * (i + 1)) <= el_ms)
		i++;
	last_i = i;
	base = u16be(r + 20 * i + 2);
	return base && base <= 30000 ? base : 0;
}
static int deck_free;	/* no track on the deck (or a failed load): the overview area is empty */
static int row_text_w(const struct font *f, const volatile u8 *t, int n);
/* V3e1: the loaded track's title / key as last seen on the player (the browse strip shows them) */
static u8 g_title[128], g_key[16];
static int g_tn, g_kn;
static u32 g_tid, g_kid;
static void memcpy_title(const u8 *t, int n, u32 tag)
{
	int i;
	for (i = 0; i < 2 * n && i < 128; i++)
		g_title[i] = t[i];
	g_tn = n;
	g_tid = tag;
}
/* V4m2 (deck + emu, rekordbox 7.2.19 export: red "Not Loaded." over a loaded, playing track): with that
 * export MAIN leaves the player model's title slot empty (stock 1.87 then shows an empty header bar and a blank
 * INFO page) while the browse rows still carry the titles. The header's title when the slot is empty: the
 * cursor track row of a list seen within 5 s before the load (PUSH on it), else nothing -- "Not Loaded." only
 * when nothing is loaded */
static u32 now_ms(void);
static u8 fb_ctc[128], fb_tc[128];
static int fb_ctn, fb_tn;
static u32 fb_ct, fb_load;
/* V4m3 (deck + emu, same export): the player model's KEY slot stays empty too, so the KEY box and the KEY
 * SHIFT panel showed nothing; the browse row's rowmeta (touch_audio, from export.pdb) has the key: kept with
 * the title and used when the model gives none */
static u8 fb_ckc[16], fb_kc[16];
static int fb_ckn, fb_kn;
static void meta_split(const volatile u8 *m, int mn, int *b0, int *bn, int *k0, int *kn);
static void fb_browse_row(const volatile u8 *sl)	/* browse(): every visible row; keeps the cursor track row's title + key */
{
	u32 id = u16be(sl + 0x14), i, n = u16be(sl + 0x28);
	if (n && (u32be(sl + 0x0C) & 8) && (id == 0x2F || id == 0x5A)) {	/* a track row (0x5A: loaded here) */
		const volatile u8 *m = sl + 0x2A + 0x1A0;
		int mn = 0, b0, bn, k0, kn;
		if (n > 64)
			n = 64;
		for (i = 0; i < 2 * n; i++)
			fb_ctc[i] = sl[0x2A + i];
		fb_ctn = (int)n;
		fb_ct = now_ms() | 1;
		while (mn < 40 && u16be(m + 2 * mn))
			mn++;
		meta_split(m, mn, &b0, &bn, &k0, &kn);
		if (kn > 8)
			kn = 0;
		for (i = 0; i < 2 * (u32)kn; i++)
			fb_ckc[i] = m[2 * k0 + i];
		fb_ckn = kn;
	}
}
/* V4n24: the loaded track's rbid as MAIN's cue block names it (touch_audio publishes a block the moment the
 * deck's track changes, also for loads the browse did not start: CONTINUE, track search) and its export.pdb
 * title (the 'TITL' record at +0xF80: magic, rbid, n, n UTF-16BE chars), 0 = none for this rbid */
#define CUE_TITL 0xF80
static u32 cue_rbid(void)
{
	if (cue_stale || CUEBUF[0] != 'P' || CUEBUF[1] != 'C' || CUEBUF[2] != 'O' || CUEBUF[3] != '2')
		return 0;
	return u32be(CUEBUF + 8);
}
static int main_title(u8 *dst)
{
	const volatile u8 *r = CUEBUF + CUE_TITL;
	u32 rb = cue_rbid(), n, i;
	if (!rb || r[0] != 'T' || r[1] != 'I' || r[2] != 'T' || r[3] != 'L' || u32be(r + 4) != rb)
		return 0;
	n = u32be(r + 8);
	if (n > 64)
		n = 64;
	for (i = 0; i < 2 * n; i++)
		dst[i] = r[12 + i];
	return (int)n;
}
/* V4n30a (task #41: on a load the player showed partial / stale data for ~1.4 s, then "adapted"): the LOAD GATE.
 * A load starts when the deck's track number changes or the detail length drops (det_track's bridged `ana`,
 * so the short drops while a track plays never count). Within 5 s of a gate's start a further trigger gates again
 * only once MAIN's cue block names another rbid than the one the last gate ended with (a new load), so the
 * late pieces of the same load after a timeout never blank the screen a second time. From then the player
 * shows a clean empty state (header "Loading...", band / overview / deck area as with no track: the 3000's Loading) until
 * EVERYTHING of the new track is in -- detail (DET_LEN back), overview (colour 0x35 for this load), MAIN's
 * 'TITL' record (title + the PCO2 cues, one block) for the cue block's rbid, and the artwork block of that
 * rbid (the image, or none: MAIN sends the art before the title, a "none" counts 250 ms after the title) --
 * or 1.5 s passed. Then the whole new track draws at once: no half states. */
/* V4n31a (#41, deck V4n30: "PUSH: no Loading, half-updated screen, then it adapts"; emu trace: the gate closed
 * 300 ms into the load with every ready bit satisfied by the OLD track -- `ana` bridged by det_track's hold, the
 * cue block / TITL / art of the previous rbid (MAIN publishes none for a track without cues) -- and the band then
 * drew the old detail under "Demo Track 1", 00:00). Now:
 * - trigger: the heartbeat's track identity (+0x60 number, +0x7C length) changes -- the deck's own load marker
 *   0xBBBBBBBB in +0x60 (seen ~150 ms after PUSH) included -- or a detail zero outlasts the hold; within 5 s of a
 *   gate only a new track number re-gates (the length is refined after a load);
 * - ready = evidence of the NEW track only: the raw detail length back after it was zero in this gate (bit 0), its
 *   overview (bit 1, ov_new, or the detail), a cue block MAIN published for this load with its TITL (bit 2), its
 *   artwork block (bit 3); a track MAIN sends no cue block for: bits 2-3 count 400 ms after the detail. A valid
 *   track number + length are required too. Max 1.5 s from the trigger. */
static int lg_on;		/* the gate is closed: the player draws "no track" */
u32 v2_lg_n, v2_lg_to, v2_lg_ms, v2_lg_why;	/* gates, timeouts, the last one's ms, its ready bits (HUD / mem) */
#define LG_TIMEOUT 1500
#define LG_HARD 5000	/* NAVART: from the trigger */
#define LG_NAMED 3000	/* NAVART: from the heartbeat naming the new track (emu: the detail 2.5 s after it) */
#define LG_TN_LOADING 0xBBBBBBBB
static u32 lg_t_det;	/* the time the new detail came in (0 none yet) */
static u32 lg_ready(u32 now, u32 det0)
{
	static u32 t_titl, rb_titl;
	u32 rb = cue_rbid(), why = 0, tn = u32be(DECK + 0x60);
	const volatile u8 *r = CUEBUF + CUE_TITL;
	if (det0 && DET_LEN && DET_LEN <= 0x200000) {
		why |= 1;
		if (!lg_t_det)
			lg_t_det = now | 1;
	}
	if (ov_new || (why & 1))	/* as deck_area's overview (0x35 comes before the detail) */
		why |= 2;
	if (rb && r[0] == 'T' && r[1] == 'I' && r[2] == 'T' && r[3] == 'L' && u32be(r + 4) == rb) {
		why |= 4;
		if (rb_titl != rb) {
			rb_titl = rb;
			t_titl = now;
		}
	} else
		rb_titl = 0;
	if (rb && LDART[0] == 'P' && LDART[1] == 'A' && LDART[2] == 'R' && LDART[3] == 'T' && u32be(LDART + 8) == rb &&
	    (ldart_seq() || (!u32be(LDART + 12) && (why & 4) && now - t_titl >= 250)))
		why |= 8;
	if (!rb && lg_t_det && (s32)(now - lg_t_det) >= 400)	/* NAVART: signed (lg_t_det = now | 1 this frame: -1) */
		why |= 12;		/* no cue block for this track (yet): the model's / browse row's title, no art */
	if (!tn || tn == LG_TN_LOADING || tn > 9999 || !u32be(DECK + 0x7C))
		why &= ~1u;		/* the heartbeat does not name the new track yet */
	return why;
}
static void lg_poll(void)
{
	static u32 tid, tlen, t0, was_ana, init, det0, g_tn, pend, hard, det_seen, t_named;
	u32 tn = u32be(DECK + 0x60), len = u32be(DECK + 0x7C), now = now_ms(), why;
	int start;
	if (!init) {
		init = 1;
		tid = tn;
		tlen = len;
		was_ana = (u32)ana;
		return;
	}
	if (tn && !load_failed() && !pend) {
		if (tn != tid || (len != tlen && !DET_LEN)) {
			pend = now | 1;	/* the track identity changed: a load */
			hard = tn != tid;
		} else if (was_ana && !ana) {
			pend = now | 1;	/* a detail zero longer than det_track's hold */
			hard = 0;
		}
		if (pend && !hard && !det_seen)
			pend = 0;	/* a soft trigger (length refined, detail zero) with no detail seen since the last
					 * gate: the same load still coming in after a timeout (emu: the detail > 5 s), not
					 * a new one -- never a second "Loading..." */
	}
	if (!lg_on && DET_LEN)
		det_seen = 1;
	tid = tn;
	tlen = len;
	was_ana = (u32)ana;
	if (!tn || load_failed() || UPD_STATE) {
		lg_on = 0;
		pend = 0;
		return;
	}
	start = 0;
	if (pend && lg_on)
		pend = 0;	/* absorbed by the open gate */
	if (pend) {
		if (v2_lg_n == 0 || now - t0 >= 5000 || tn == LG_TN_LOADING || (hard && tn != g_tn))
			start = 1;	/* a new load */
		else
			pend = 0;	/* the same load's late pieces (length refined, detail after a timeout) */
	}
	if (start) {
		pend = 0;
		if (!lg_on) {
			lg_on = 1;
			t0 = now;
			det0 = 0;
			det_seen = 0;
			lg_t_det = 0;
			t_named = 0;
			v2_lg_n++;
			cue_mark_load();
		}
	}
	if (!lg_on)
		return;
	if (!DET_LEN)
		det0 = 1;		/* the detail dropped for this load: its return is the new track's */
	why = lg_ready(now, det0);
	/* NAVART (user: artifacts while loading; emu: all 6 loads of a run timed out at 1.5 s with no ready bit --
	 * the gate opened on an empty heartbeat, then the header, the deck numbers, the BPM, the band and the
	 * overview each came in over ~2 s): the timeout now counts from the moment the heartbeat names the new track
	 * (number + length; nothing of it can be drawn before): LG_NAMED, at most LG_HARD from the trigger */
	if (u32be(DECK + 0x60) == LG_TN_LOADING || tn > 9999 || !len)
		t_named = 0;
	else if (!t_named)
		t_named = now | 1;
	if ((why & 15) == 15 || (t_named && (s32)(now - t_named) >= LG_NAMED) || now - t0 >= LG_HARD) {
		if ((why & 15) != 15)
			v2_lg_to++;
		v2_lg_ms = now - t0;
		v2_lg_why = why;
		g_tn = tn;
		lg_on = 0;
	}
}

/* the header: the title for loaded track `loaded` when its model slot has none (0 = none) */
static int fb_title(u32 loaded)
{
	u32 id = loaded ? hmix(loaded, cue_rbid()) | 1 : 0;	/* V4n24: a new rbid = a new load (CONTINUE kept
								 * loaded == 1 and the previous track's row title) */
	if (id != fb_load) {	/* a new load: the list row PUSHed just before it */
		fb_load = id;
		fb_tn = fb_kn = 0;
		if (loaded && fb_ct && now_ms() - fb_ct < 5000) {
			int i;
			for (i = 0; i < 2 * fb_ctn; i++)
				fb_tc[i] = fb_ctc[i];
			fb_tn = fb_ctn;
			for (i = 0; i < 16; i++)
				fb_kc[i] = fb_ckc[i];
			fb_kn = fb_ckn;
		}
	}
	return loaded ? fb_tn : 0;
}
/* V3e1: this deck is playing -- its time moved within the last 150 ms (the heartbeat has no plain flag) */
static int deck_playing(void)
{
	static u32 last_el, t_chg;
	u32 el = u32be(DECK + 0x78), now = now_ms();
	if (el != last_el) {
		last_el = el;
		t_chg = now;
	}
	if (now - t_chg < 150) {
		pend = 1;	/* V3f: the frame at +150 ms shows the paused state */
		return 1;
	}
	return 0;
}
/* V3e1: on air = heartbeat +0x50 (the DJM's channel flags, re/V3E_DESIGN.md F5) */
static int on_air(void) { return u32be(DECK + 0x50) == 1; }
/* "((" / "))" arcs around a player number centred at (cx, cy), two each side */
static void air_arcs(int cx, int cy, u16 c)
{
	int d, k;
	for (k = 0; k < 2; k++) {
		int r = 13 + 5 * k;
		for (d = -r + 4; d <= r - 4; d++) {
			int dx = r - (d * d) / (2 * r);	/* ~circle, parabolic */
			fill(cx - dx, cy + d, 2, 1, c);
			fill(cx + dx - 1, cy + d, 2, 1, c);
		}
	}
}
/* V3e1 (audit Q16): +0xDF stays 3 after a needle release while paused, so the green marker stayed; draw
 * it only while the finger's position (+0x70) is away from the deck's (after a release they agree) */
static int needle_away(u32 pos_x)
{
	u32 fp = u32be(DECK + 0x70), fn = u32be(DECK + 0x74), fx;
	if (!fn) return 0;
	if (fp > fn) fp = fn;
	fx = udiv((fp >> 4) * 640, (fn >> 4) ? fn >> 4 : 1);
	return fx + 3 < pos_x || fx > pos_x + 3;
}

/* "125.25" in a BPM box: the integer part in fi, the decimals in fd, baselines shared, the whole
 * right-aligned at rx (the 3000 / rekordbox look) */
/* the player's BPM box (672..787 x 325..384, MASTER tab under it): digit baseline 9 px above the
 * frame's bottom, as the browse deck area and the 3000 frame (re/cdj3k_refs play-a440) */
#define BPM_BASE 378
static void bpm_split(int rx, int y, const struct font *fi, const struct font *fd, char *buf, u16 fg)
{
	char *dot;
	int wd;
	for (dot = buf; *dot && *dot != '.'; dot++)
		;
	wd = text_w(fd, dot);
	text(fd, rx - wd, y + fi->asc - fd->asc, dot, fg, C_BLACK);
	*dot = 0;
	text_r(fi, rx - wd, y, buf, fg, C_BLACK);
	*dot = '.';
}

/* "125.3" (bpm10) or "125.25" (v100 != 0) into p; returns the end */
static char *fmt_bpm(char *p, u32 bpm10, u32 v100)
{
	u32 b = v100 ? udiv(v100, 100) : udiv(bpm10, 10);
	if (b >= 100) *p++ = '0' + udiv(b, 100) % 10;
	if (b >= 10) *p++ = '0' + udiv(b, 10) % 10;
	*p++ = '0' + b % 10;
	*p++ = '.';
	if (v100) {
		*p++ = '0' + udiv(v100, 10) % 10;
		*p++ = '0' + v100 % 10;
	} else {
		*p++ = '0' + bpm10 % 10;
	}
	*p = 0;
	return p;
}

/* SLIP on: deck +0xDF = 1 [G, emu diff]; the real (slip) position runs on in +0x84 (seconds) */
static int slip_on(void) { return DECK[0xDF] == 1; }
/* V4n32 (#21): MAIN (modsmenu sl_pub) publishes the background (slip) position while SLIP is on: heartbeat +0x18
 * = 0x53 << 24 | ms (the engine pair 0x0994754C +8). (+0x84 is a beat counter, not the slip position.) */
static int slip_ms_ok(void) { return slip_on() && DECK[0x18] == 0x53; }
static u32 slip_pos_ms(void) { return u32be(DECK + 0x18) & 0x7FFFFF; }
#define C_SLIPG 0x2D1F		/* the ghost: the 3000's slip blue #28A0FF (skin slip pads / loop icon) */
/* the ghost's x in the detail band for a band at entries / column scale sh with the playhead at entry pos, -1
 * none: the shadow's distance from the real playhead (both from this heartbeat: +0x18 ms vs +0x78 ms) */
static int slip_gx(s32 pos, int sh)
{
	static int last = -1;
	s32 d, gx;
	if (!slip_ms_ok())
		return last = -1;
	d = sdiv(((s32)slip_pos_ms() - (s32)u32be(DECK + 0x78)) * 3, 20);	/* ms -> entries (150 / s) */
	gx = WAVE_X0 + V2_PLAYHEAD + bcol(pos + d, sh) - bcol(pos, sh);
	if (gx < WAVE_X0 || gx > WAVE_X0 + WAVE_N - 2 || (gx >= WAVE_X0 + V2_PLAYHEAD - 3 && gx <= WAVE_X0 + V2_PLAYHEAD + 3))
		return last = -1;
	if (last >= 0 && gx >= last - 1 && gx <= last + 1)
		return last;		/* +-1 px of jitter between the two samples: keep it (no GR3 repaint) */
	return last = gx;
}

/* the defined loop's length as an index of "1/8".."32" (0..8), or -1 */
static int loop_len_k(u32 bpm10)
{
	u32 st = 0xFFFFFFFF, en = 0xFFFFFFFF, e8, v = 1;
	int i, k = 0;
	for (i = 0; i < N_MARKS; i++) {
		const volatile u8 *r = MARKS + 16 * i;
		if (u32be(r + 8) != 0xFFFFFFFF && u32be(r + 12) != 0xFFFFFFFF) {
			st = u32be(r + 8);
			en = u32be(r + 12);
			break;
		}
	}
	if (st == 0xFFFFFFFF || en <= st || !bpm10)
		return -1;
	e8 = udiv((en - st) * bpm10 * 8, 150 * 600);
	while (k < 8 && v * 2 <= e8 + (v >> 1)) { v <<= 1; k++; }
	return k;
}

/* BEAT LOOP bar while looping (stock / 3000: 8 buttons 1/4..32 under the waveform, the active one lit) */
/* V3rc7: the BEAT JUMP pads on the same 8 slots (MAIN zones 7..14 moved there by v2needle): stock's
 * jump codes 2..9 = <2 >2 <4 >4 <8 >8 <16 >16 beats, blue outline as the 3000's beat-jump page */
static void jump_bar(void)
{
	static const char *const N[4] = { "2", "4", "8", "16" };
	int k, y = 258;
	fill(WAVE_X0, y - 3, WAVE_N, 48, dm(C_BLACK));
	for (k = 0; k < 8; k++) {
		int px = 58 + 80 * k, cx = px + 20, cy = y + 22, i, right = k & 1;
		checker2(px, y, 72, 44, dm(C_CK1), dm(C_BAR));	/* V4n: skin img_btnBeatJump = #191919/#323232 checker */
		frame(px, y, 72, 44, 2, 0x7BEF);	/* V3rc8t (claims audit #8): BEAT JUMP pads #7D7D7D outline (skin), not blue */
		for (i = 0; i < 6; i++)		/* the arrow: a 6-px triangle pointing left / right */
			fill(right ? cx + i - 3 : cx - i + 3, cy - (5 - i), 1, 2 * (5 - i) + 1, dm(C_WHITE));
		text_c(&f_m, px + 46, y + 11, N[k >> 1], dm(C_WHITE), dm(C_BAR));
	}
}
static int key_txt(u8 *out, const volatile u8 *t, int n, int semi);
static const volatile u8 *kf_key(const volatile u8 *t, int *n);
#ifdef V2_KEYSHIFT
static const volatile u8 *ks_key(const volatile u8 *t, int *n, u16 *col);
static int ks_amt(char *s1, char *s2);	/* KSAMT (V4n43) */
static u8 ks_kb[16];
/* V4k: the CDJ-3000 KEY SHIFT panel (skin WaveForm_KeyShift.csv x 0.625: -1 288,384 153x84 / RESET 565,384 /
 * +1 839,384) on the pad row: -1 / +1 name the key a semitone down / up, RESET shows the shift. MAIN zones
 * (modsmenu, class 1, action 12) take these rects while the panel is open. */
static void ks_bar(void)
{
	static const int X[3] = { 180, 353, 524 };
	int k, y = 258, sh = KS_SEMI;
	fill(WAVE_X0, y - 3, WAVE_N, 48, dm(C_BLACK));
	{	/* V4n: KEY SYNC (the 3000's K.SYNC; MAIN zone action 12 arg 7 at 652..756): lit #007DE1 while on */
		int on = KS_KSYNC;
		u16 bg = on ? C_SEL : dm(C_BLACK);
		fill(656, y, 96, 44, bg);
		frame(656, y, 96, 44, 2, on ? C_SEL : KS_KREF ? C_WHITE : 0x7BEF);
		text_c(&f_t, 704, y + 3, "KEY", dm(C_WHITE), bg);
		text_c(&f_m, 704, y + 17, "SYNC", dm(C_WHITE), bg);
	}
	for (k = 0; k < 3; k++) {
		int px = X[k], d = k == 0 ? -1 : k == 2 ? 1 : 0, kn = g_kn, m = 0;
		u16 bg = k == 1 && sh ? C_SEL : dm(C_BLACK);
		char b[4], *q = b;
		fill(px, y, 96, 44, bg);
		frame(px, y, 96, 44, 2, k == 1 ? C_SEL : 0x7BEF);
		if (k == 1) {
			int a = sh < 0 ? -sh : sh;
			if (sh)
				*q++ = sh < 0 ? '-' : '+';
			if (a >= 10)
				*q++ = '1';
			*q++ = '0' + a % 10;
			*q = 0;
			text_c(&f_t, px + 48, y + 3, "RESET", dm(C_WHITE), bg);
			text_c(&f_m, px + 48, y + 17, b, dm(C_WHITE), bg);
			continue;
		}
		text_c(&f_t, px + 48, y + 3, d < 0 ? "-1" : "+1", dm(C_WHITE), bg);
		if (kn && sh + d >= -12 && sh + d <= 12)
			m = key_txt(ks_kb, g_key, kn, sh + d);
		if (m)
			text_u16(&f_m, px + 48 - 6 * m, y + 17, ks_kb, m, px + 94, dm(C_WHITE), bg);
	}
}
#endif
/* TOUCH (V4n41): the CDJ-3000 GRID ADJUST panel (skin WaveForm_GridAdjust.csv x 0.625: SNAP GRID 315 / SHIFT GRID 451 /
 * 1/2 back 587 / 1/2 next 713 / RESET 849, y 384, 116 x 84 -> x 197 / 282 / 367 / 446 / 531, y 258, 72 x 44 on the pad
 * row) while stock's GRID ADJUST mode is on. MAIN zones (modsmenu action 15) take these rects in that mode. */
static void grid_bar(void)
{
	static const short X[5] = { 197, 282, 367, 446, 531 };
	static const char *const L1[5] = { "SNAP", "SHIFT", "", "", "RESET" }, *const L2[5] = { "GRID", "GRID", "1/2", "1/2", "" };
	int k, y = 258;
	fill(WAVE_X0, y - 3, WAVE_N, 48, dm(C_BLACK));
	for (k = 0; k < 5; k++) {
		int px = X[k], i;
		fill(px, y, 72, 44, dm(C_BLACK));
		frame(px, y, 72, 44, 2, 0x7BEF);
		if (k == 2 || k == 3) {	/* the 3000's double arrows: two 6-px triangles, then 1/2 */
			int cx = px + (k == 2 ? 22 : 50), cy = y + 12, r = k == 3;
			for (i = 0; i < 6; i++) {
				fill(r ? cx - 8 + i : cx - i + 2, cy - (5 - i), 1, 2 * (5 - i) + 1, dm(C_WHITE));
				fill(r ? cx + i : cx - i + 10, cy - (5 - i), 1, 2 * (5 - i) + 1, dm(C_WHITE));
			}
			text_c(&f_m, px + 36, y + 19, L2[k], dm(C_WHITE), dm(C_BLACK));
			continue;
		}
		if (L2[k][0]) {
			text_c(&f_t, px + 36, y + 6, L1[k], dm(C_WHITE), dm(C_BLACK));
			text_c(&f_t, px + 36, y + 22, L2[k], dm(C_WHITE), dm(C_BLACK));
		} else
			text_c(&f_t, px + 36, y + 14, L1[k], dm(C_WHITE), dm(C_BLACK));
	}
}
static void loop_bar(u32 bpm10)
{
	if (GA_MODE) {	/* TOUCH: over the pads / KEY SHIFT panel while GRID ADJUST is on */
		grid_bar();
		return;
	}
	static const char *const LB[] = { "1/4", "1/2", "1", "2", "4", "8", "16", "32" };
	static const char *const LS[] = { "1/16", "1/8", "1/4", "1/2", "1", "2", "1/3", "3/4" };
	int k, x, y = BAND_Y1 - 66, lk = loop_len_k(bpm10), active = lk - 1, slip = slip_on();
	const char *const *L = slip ? LS : LB;
#ifdef V2_KEYSHIFT
	if (KS_PANEL) {
		ks_bar();
		return;
	}
#endif
	/* V3rc7 (re/TOUCH_AUDIT.md #1/#2): the pads are up when stock's pad MODE is open (heartbeat +0xF3 == 2,
	 * MAIN 0x0B568C70 -- zone 4 then takes the touches), not when a loop plays; the lit pad = the playing
	 * loop's length (none when not looping or not a pad value). BEAT JUMP pads (+0x11B == 1, zones 7..14). */
	if (DECK[0xF3] != 2) {
		if (DECK[0x11B] == 1)
			jump_bar();
		return;
	}
	if (DECK[0xD3] != 3 && DECK[0xD3] != 5)	/* 3 looping, 5 looping in slip */
		active = -1;
	if (slip)	/* slip's set 1/16..2 (+1/3, 3/4): 1/8..2 map onto it, longer loops light nothing */
		active = lk >= 0 && lk <= 4 ? lk + 1 : -1;
	/* V3e1 (audit L2/L3): the 3000's pads -- 8 x 72 x 44 at x 58.., black with a 2-px outline (orange in
	 * the loop page, blue in slip's 1/16.. page), the current one filled orange; the "1 | 2" page toggle
	 * at the right (page 1 lit; display only) */
	(void)x;
	y = 258;
	fill(WAVE_X0, y - 3, WAVE_N, 48, dm(C_BLACK));
	for (k = 0; k < 8; k++) {
		/* V4n (claims audit #101, skin img_btnBeatLoop): off = #191919/#323232 checker in a #FF7323 frame
		 * (slip #28A0FF), on = #FF7323/#E15A0F checker (slip #28A0FF/#197DD2), white text */
		int px = 58 + 80 * k, lit = k == active;
		u16 oc = slip ? 0x2D1F : C_MASTER, ob = slip ? 0x1BFA : 0xE2C1;
		if (lit)
			checker2(px, y, 72, 44, oc, ob);
		else
			checker2(px, y, 72, 44, dm(C_CK1), dm(C_BAR));
		frame(px, y, 72, 44, 2, oc);
		text_c(&f_m, px + 36, y + 11, L[k], C_WHITE, lit ? ob : dm(C_BAR));
	}
	/* V3rc7: no "1 | 2" page toggle (it was display only and its top strip set a 32-beat loop) */
}

/* LOOP badge under the tempo range, as the stock and the 3000: defined loop -> its length */
static void __attribute__((unused)) loop_badge(u32 bpm10)
{
	u32 st = 0xFFFFFFFF, en = 0xFFFFFFFF;
	int i;
	for (i = 0; i < N_MARKS; i++) {
		const volatile u8 *r = MARKS + 16 * i;
		if (u32be(r + 8) != 0xFFFFFFFF && u32be(r + 12) != 0xFFFFFFFF) {
			st = u32be(r + 8);
			en = u32be(r + 12);
			break;
		}
	}
	if (st == 0xFFFFFFFF || en <= st || !bpm10)
		return;
	{
		/* beats = (en - st) / 150 s * bpm / 60, in 1/8 beats, snapped to a power of two */
		static const char *const L[] = { "1/8", "1/4", "1/2", "1", "2", "4", "8", "16", "32" };
		u32 e8 = udiv((en - st) * bpm10 * 8, 150 * 600);
		int k = 0;
		u32 v = 1;
		while (k < 8 && v * 2 <= e8 + (v >> 1)) { v <<= 1; k++; }
		u16 c = DECK[0xD3] == 3 ? C_MASTER : C_GREY;	/* looping / loop kept */
		frame(560, 382, 82, 18, 1, c);
		text(&f_s, 566, 384, "LOOP", c, C_BLACK);
		text_r(&f_s, 637, 384, L[k], C_WHITE, C_BLACK);
	}
}

/* P10: the beat in the bar at time el (ms) from the track's beat grid -- as stock's phase meter and our
 * own beat ticks. (The heartbeat's +0x84 is NOT the grid beat: it counted beats since play started, so the
 * meter was out of phase with the waveform grid.) Grid record: 20 B, +0 u16 beat in bar, +4 u32 ms. */
static u32 grid_beat(u32 el, u32 *pos8)
{
	static u32 gi, gi0, gcnt;
	u32 cnt = u32be(GRID + 4), rp = u32be(GRID + 0x18);
	const volatile u8 *r0;
	*pos8 = 0;
	if (!cnt || cnt >= 8192 || (rp & 0xFF000000) != 0x0F000000)
		return 0;
	if (!GRID_OK)			/* V3a: no rekordbox grid on this track */
		return 0;
	r0 = (const volatile u8 *)((rp & 0x1FFFFFFF) | 0x20000000);
	if (cnt != gcnt || gi >= cnt) {		/* a new grid: its first downbeat */
		gcnt = cnt;
		gi = 0;
		for (gi0 = 0; gi0 < cnt && gi0 < 8 && u16be(r0 + 20 * gi0) != 1; gi0++)
			;
		if (gi0 >= cnt || gi0 >= 8)
			gi0 = 0;
	}
	if (gms(r0 + 20 * gi) > el)
		gi = 0;
	while (gi + 1 < cnt && gms(r0 + 20 * (gi + 1)) <= el)
		gi++;
	if (gms(r0 + 20 * gi) > el)
		return 0;			/* before the first beat */
	*pos8 = (gi + 8 - gi0) & 7;
	return u16be(r0 + 20 * gi);
}

static const char *const RANGE[] = { "\xB1" "6", "\xB1" "6", "\xB1" "10", "\xB1" "16", "WIDE" };

/* Per-buffer region cache: the panel scans two frame buffers in turn; each region of a screen is
 * redrawn into a buffer only when its key (a hash of everything it shows) differs from the key that
 * buffer got last time. Windows stock would compose over a cached region are hidden (manage);
 * every 64 frames, a theme change or a screen change forces a full repaint. */
#define NREG 32
static u32 rk[2][NREG];
static int rb, rforce;
static u32 hmix(u32 h, u32 v) { return (h ^ v) * 0x01000193; }

/* V3b (W4/W6): the overview is drawn once per content / type / theme into two 640 x 43 images in free
 * SDRAM (unplayed and played), and each repaint is two blits per row split at the playhead.
 * Sources: the colour records (0x35: 600 x 6 B, 3-band ones flagged 0x3B FF Fx by our MAIN mod) or,
 * for an analysed track whose MAIN sent the mono overview (0x34, BLUE setting / old analysis), the
 * scaled pairs at 0x0E5BB0D8 (400 x [height 0..25, whiteness]; GUI 0x0E50218C). */
#define OVW 640
#define OVH 43
#define OVC_U ((u16 *)0x0C800000)
#define OVC_P ((u16 *)0x0C800000 + OVW * OVH)
#define MONO_HDR ((const volatile u8 *)0x2E5B70E8)
#define OV_MONO ((const volatile u8 *)0x2E5BB0D8)
u32 v2_ov_builds;
static u32 mono_ck(void)
{
	const volatile u32 *p = (const volatile u32 *)OV_MONO;
	u32 c = 0;
	int i;
	for (i = 0; i < 200; i++)
		c = (c << 3 | c >> 29) ^ p[i];
	return c;
}
HOTSW static u16 norm565(u32 r, u32 g, u32 b)		/* the hue, rekordbox brightness (rb_hue) */
{
	u32 m = r > g ? (r > b ? r : b) : (g > b ? g : b);
	if (!m)
		return 0;
	return rb_hue(r, g, b, m);
}
/* HALFBLUE (B9): ONE played rule for every look -- the CDJ-3000 layout's 40 % black mask over the played part
 * (CSV `wave_drw_#000000_40%_msk`: x 0.6; 's overview widgets only paint the cached image, so the mask
 * is the layout's). Was: x 0.56 on the colour looks and an own x 0.75 ramp in BLUE. LIGHT MODE = FULL keeps its
 * light-panel rule (an extra: the 3000 has no light waveforms) */
HOTSW static u16 ov_played(u16 c)
{
	u32 r, g, b;
	if (in_wave)
		return mix(grey_of(c, 16), wc_bg, 6);
	r = ((c >> 11) * 154) >> 8; g = (((c >> 5) & 63) * 154) >> 8; b = ((c & 31) * 154) >> 8;
	return (u16)(r << 11 | g << 5 | b);
}
/* HALFBLUE: the overview's rows for a column. HALF: row OVH - 1 - y (bottom-anchored, OVH rows); FULL: rows
 * OV_C -+ y (centred: OV_C + 1 rows up from the centre row, mirrored down -- copies each row to
 * centre + y) */
#define OV_C (OVH / 2)
static int ov_hs;		/* this build's shape: 1 bottom-anchored (FULL label), 0 mirrored (HALF label) */
HOTSW static void ov_px(int x, int y, u16 c)
{
	if (ov_hs) {
		int o = (OVH - 1 - y) * OVW + x;
		OVC_U[o] = c;
		OVC_P[o] = ov_played(c);
	} else {
		u16 p = ov_played(c);
		OVC_U[(OV_C - y) * OVW + x] = c;
		OVC_P[(OV_C - y) * OVW + x] = p;
		OVC_U[(OV_C + y) * OVW + x] = c;
		OVC_P[(OV_C + y) * OVW + x] = p;
	}
}
/* the shape's height in rows above the base for a record height h of 40 (the NXS2 record's full scale; 
 * scales PWV4's 0..128 the same linear way, x rows / 128) */
static int ov_rows(int h)
{
	int n = ov_hs ? OVH - 1 : OV_C;
	if (h > 40) h = 40;
	return (int)udiv((u32)(h * n + 20), 40);
}
/* one column from the bottom: n0 rows c0, then up to n1 rows c1, up to n2 rows c2 (cumulative), flat (3BAND:
 * 's 3-band overview stacks flat layers, bottom-anchored only) */
HOTSW static void ov_stack(int x, int n0, u16 c0, int n1, u16 c1, int n2, u16 c2)
{
	int j;
	for (j = 0; j < n2 && j < OVH; j++)
		ov_px(x, j, j < n0 ? c0 : j < n1 ? c1 : c2);
}
/* HALFBLUE (B6): the CDJ-3000 player overview column (raster, columns): colour c (BLUE:
 * the 8-entry table by PWV4's whiteness index, RGB: the record's colour), rows 0..a drawn (the base row always),
 * each row y darkened toward black by t = y / 2a (factor table 0x4000 / a: the top at half brightness); rows
 * 0..b (PWV4's second height) blended toward grey #7F7F7F by the same t instead; nothing above a */
HOTSW static void ov_col3k(int x, u16 c, int a, int b)
{
	int y;
	u16 to = in_wave ? wc_bg : 0;
	for (y = 0; y <= a; y++) {
		u32 t = a ? udiv((u32)y * 8, (u32)a) : 0;	/* 16 x y / 2a */
		ov_px(x, y, mix(c, y <= b && !in_wave ? 0x7BEF : to, t));
	}
}
/* 's player overview BLUE table (static, init: Colour(r, g, b) x 8; the same values as
 * db_access_proxy's 0x30A2B20) */
static const u16 OV3K[8] = { 0x1313, 0x1417, 0x0C9F, 0x15DD, 0x7E1C, 0x961F, 0x961F, 0xD75F };	/* #106098 #1080B8
	#0890F8 #10B8E8 #78C0E0 #90C0F8 #90C0F8 #D0E8F8 */
static u16 ov_bluec(u32 w)
{
	if (w > 7) w = 7;
	if (in_wave)	/* LIGHT MODE = FULL (ours): the light-panel blues */
		return mix(0x1A54, 0x2B7A, (w * 16) / 7);
	return OV3K[w];
}
HOTSW static void ov_build(int mono)
{
	int x, i;
	u16 bg = wc_bg;
	v2_ov_builds++;
	ov_hs = !OV_FULL;
	for (i = 0; i < OVW * OVH; i++)
		OVC_U[i] = OVC_P[i] = bg;
	for (x = 0; x < OVW; x++) {
		if (mono) {	/* 400 records over 640 columns: the highest one the column covers. HALFBLUE (B8): the
				 * 3000's PWAV fallback (table; db_access_proxy) --
				 * flat, two colours: whiteness <= 3 #42599C, > 3 #6BA2F7 */
			u32 k = (u32)(x * 5) >> 3, k1 = (u32)((x + 1) * 5 - 1) >> 3, h, w, j, n;
			if (k1 != k && k1 < 400 && OV_MONO[2 * k1] > OV_MONO[2 * k])
				k = k1;
			h = OV_MONO[2 * k];
			w = OV_MONO[2 * k + 1] & 7;
			n = (u32)ov_rows((int)udiv(h * 40, 25));
			for (j = 0; h && j <= n; j++)
				ov_px(x, (int)j, in_wave ? (w > 3 ? 0x2B7A : 0x1A54) : w > 3 ? 0x6D1E : 0x42D3);
			continue;
		}
		{
			/* V3c (W1/W4): 600 records over 640 columns -- a column covers [x * 15/16, (x + 1) * 15/16):
			 * one record, or two where it straddles a boundary; take the taller (max, not nearest -- 
			 * 0x1866300 keeps the tallest entry too) */
			u32 k0 = (u32)(x * 15) >> 4, k1 = (u32)((x + 1) * 15 - 1) >> 4;
			const volatile u8 *r = OV_REC + 6 * k0;
			if (k1 != k0 && k1 < 600) {
				const volatile u8 *q = OV_REC + 6 * k1;
				u32 hr = r[3] == 0x3B ? r[0] : (r[4] >> 2 > ((u16be(r + 4) >> 4) & 63) ? r[4] >> 2 : (u16be(r + 4) >> 4) & 63);
				u32 hq = q[3] == 0x3B ? q[0] : (q[4] >> 2 > ((u16be(q + 4) >> 4) & 63) ? q[4] >> 2 : (u16be(q + 4) >> 4) & 63);
				if (hq > hr)
					r = q;
			}
			if (r[3] == 0x3B && r[4] == 0xFF && (r[5] | 15) == 0xFF) {
				int t = r[0], ab = r[1], a = r[2];
				if (t > 40) t = 40;
				if (ab > t) ab = t;
				if (a > ab) a = ab;
				if (wave_type == 2) {		/* BLUE: whiteness = the high band's share (as the band) */
					ov_col3k(x, ov_bluec(udiv((u32)(t - ab) * 14, (u32)t + 1)), ov_rows(t), ov_rows(ab));
				} else if (wave_type == 1) {	/* RGB: hue low/mid/high, the 3000 shading */
					u16 c = norm565(a * a, (ab - a) * (ab - a), (t - ab) * (t - ab));
					if (in_wave) c = mix(0, c, 13);
					ov_col3k(x, c, ov_rows(t), ov_rows(ab));
				} else {		/* OVSHAPE2 (user, deck 2026-11-17): 3BAND follows UTILITY WAVEFORM
							 * FULL / HALF like RGB and BLUE (ov_hs) */
					t = ov_rows(t); ab = ov_rows(ab); a = ov_rows(a);
					if (in_wave)
						ov_stack(x, a, 0x0239, ab, 0xDB40, t, 0x2966);
					else
						ov_stack(x, a, C_LO, ab, C_MI, t, C_HI);
				}
			} else {
				u32 c1 = u16be(r), hw = u16be(r + 4);
				int h1 = r[4] >> 2, h2 = (hw >> 4) & 63, hi, lo;
				if (h1 > 40) h1 = 40;
				if (h2 > 40) h2 = 40;
				hi = h1 > h2 ? h1 : h2;
				lo = h1 > h2 ? h2 : h1;
				if (!lo) lo = (hi * 2) / 3;
				if (wave_type == 2) {	/* BLUE: whiteness from the record's colour (r low, g mid, b high:
							 * the NXS2's 0x35 record has no PWV4 index -- B1-like synthesis) */
					u32 cr = c1 >> 11, cg = (c1 >> 6) & 31, cb = c1 & 31;
					ov_col3k(x, ov_bluec(udiv(cb * 14, cr + cg + cb + 1)), ov_rows(hi), ov_rows(lo));
				} else {	/* RGB (also 3BAND without 3-band data) */
					u16 c = norm565(c1 >> 11, (c1 >> 6) & 31, c1 & 31);
					if (in_wave) c = mix(0, c, 13);
					ov_col3k(x, c, ov_rows(hi), ov_rows(lo));
				}
			}
		}
	}
}
/* the overview cache holds the current overview (built when it changed); 0 = nothing to show */
static u32 ov_src;		/* OVSHAPE3: the last ov_ready's record key (no look) */
static int ov_ready(int allow_mono)
{
	static u32 key, have;
	int mono = 0;
	u32 k;
	if (OV_HIDE)
		return 0;
	if (u32be(OV_HDR + 4) == 1 && OV_COLOUR == 1)
		k = ov_ck();
	else if (allow_mono && !OV_COLOUR && u32be(MONO_HDR + 4) == 1) {
		mono = 1;
		k = mono_ck();
	} else
		return 0;	/* V3a: the records still hold another track's overview */
	ov_src = hmix(k, mono);		/* OVSHAPE3: the records alone (strip_snap's source check) */
	k = hmix(hmix(hmix(k, mono), wave_type), in_wave + 2 * (OV_FULL == 1));	/* HALFBLUE: the shape */
	if (!have || k != key) {
		ov_build(mono);
		key = k;
		have = 1;
	}
	return 1;
}
/* V3e1: the browse strip's mini overview is a snapshot of the LOADED track's overview taken on the player
 * screen (the overview records are re-used for the browsed track in INFO / Link Cue), 344 x 36, unplayed
 * and played, in free SDRAM after the overview cache */
#define SNAP_W 344
#define SNAP_H 36
#define SNAP_U ((u16 *)0x0C840000)
#define SNAP_P (SNAP_U + SNAP_W * SNAP_H)
static u32 snap_tid, snap_builds = 0xFFFFFFFF;
/* OVSHAPE3 (user, deck V4n47: UTILITY WAVEFORM looked inverted = the strip under UTILITY / SHORT CUT kept the
 * previous shape / colour until the player screen): the snapshot remembers its look (WAVEFORM COLOR, LIGHT FULL,
 * WAVEFORM FULL / HALF), its records' key and its mono choice, so strip() rebuilds it off the player when only
 * the look changed and the records are still the loaded track's (once per change, never per frame) */
static u32 snap_look = 0xFFFFFFFF, snap_src;
static int snap_mono;
static u32 ov_look(void) { return (u32)wave_type | (u32)day_full << 2 | (u32)(OV_FULL == 1) << 3; }
static void strip_snap(u32 tid, int allow_mono)
{
	int x, y;
	snap_look = ov_look();
	snap_src = ov_src;
	snap_mono = allow_mono;
	if (snap_tid == tid && snap_builds == v2_ov_builds)
		return;
	for (y = 0; y < SNAP_H; y++) {
		u32 sy = udiv(y * OVH, SNAP_H);
		for (x = 0; x < SNAP_W; x++) {
			u32 sx = udiv(x * OVW, SNAP_W);
			SNAP_U[y * SNAP_W + x] = OVC_U[sy * OVW + sx];
			SNAP_P[y * SNAP_W + x] = OVC_P[sy * OVW + sx];
		}
	}
	snap_tid = tid;
	snap_builds = v2_ov_builds;
}
HOT static void overview(int x0, int y0, int w, int h, u32 pos_x, int allow_mono)
{
	int y;
	(void)w; (void)h;
	if (!ov_ready(allow_mono))
		return;
	if (pos_x > OVW)
		pos_x = OVW;
	dmark(y0, OVH);
	for (y = 0; y < OVH; y++) {
		u16 *d = fb + (y0 + y) * W + x0;
		cp16(d, OVC_P + y * OVW, (int)pos_x);
		cp16(d + pos_x, OVC_U + y * OVW + pos_x, OVW - (int)pos_x);
	}
}

static u32 hslot(u32 h, const volatile u8 *slot)
{
	int i, n = u16len(slot);
	if (n > 64) n = 64;
	h = hmix(h, n);
	for (i = 0; i < 2 * n; i++)
		h = hmix(h, slot[0x2A + i]);
	return h;
}
u32 v2_nh[NREG];		/* redraws per region (bench counters) */
/* V3f frame-on-change: v2_chg = this paint changed what a region shows (its key differed from the one this
 * buffer had; a forced repaint of the same content does not count), pend = a timer / debounce of ours needs
 * more frames; paint_frame keeps the flush flipping (keep_dirty) only for 2 frames after either */
static int need(int id, u32 key)
{
	key |= 1;			/* never 0: a cleared slot always redraws */
	if (rk[rb][id] != key)
		v2_chg = 1;
	else if (!rforce && id != spread_id)
		return 0;
	rk[rb][id] = key;
	v2_nh[id]++;
	return 1;
}
u32 v2_reg_draws, v2_b4_keyed, v2_md_frames;	/* BARS4KEY: frames keyed in 4 BARS (mem; with v2_reg_draws: draws per frame) */

/* the stock blue toast in the waveform area for ~3 s after a failed load (P3b.4) */
/* The deck area (y 287..480): ONE layout for every screen we own -- player, lists, INFO, UTILITY,
 * player INFO, SHORT CUT -- so switching never moves anything (as the 3000's fixed deck strip).
 * Regions cached per frame buffer (need()); info = the browse INFO screen (overview = the browsed
 * track's, Link Cue). */
static int deck_key_green(void);
static void deck_area(int info, int on_player)
{
	char buf[16];
	u32 trackno = u32be(DECK + 0x60);
	int failed = load_failed();
	u32 loaded = failed || (lg_on && on_player) ? 0 : trackno;	/* V4n30a: the load gate */
	s32 tempo_raw = pitch_raw();
	u32 range = u32be(DECK + 0x44);
	s32 tempo = pitch100(tempo_raw, range);
	u32 bpm10 = u32be(DECK + 0x68);
	u32 el = u32be(DECK + 0x78), len = u32be(DECK + 0x7C);
	u32 mt = u32be(DECK + 0x20), remain_mode = u32be(DECK + 0x40);
	int bpm_unknown = bpm10 >= 10000;
	u32 player_no = player_num();
	u32 pos_x = 0;
	if (bpm_unknown)
		bpm10 = 0;
	if (!loaded)
		el = len = bpm10 = 0;
	if ((!loaded && !failed) || trackno > 999)	/* nothing on the deck (media pulled): no track number; a failed load keeps it, as stock */
		trackno = 0;
	deck_free = !loaded || failed;
	if (len >= 100 * 60 * 1000)
		len = 0;
	if (el > len)
		el = len;
	/* --- bottom: regions, each redrawn into a buffer only when what it shows changed --- */
	{
	u32 master = loaded && is_master();	/* [G] 1 on the LINK master (Mac rig) */
	u32 sync = u32be(DECK + 0x28) == 1;		/* SYNC on (toggled on the Mac rig) */
	u32 v100 = bpm_dec ? bpm100_at(bpm10, tempo, el) : 0;
	u32 t = remain_mode ? len - el : el;
	int all;
	static const char *const QV[] = { "1/8", "1/4", "1/2", "1" };
	int q = 3, k;
	for (k = 0; k < 4; k++)
		if (DECK[0x16B + 4 * k])
			q = k;
	if (loaded && len)
		pos_x = udiv(udiv(el, 16) * 640, udiv(len, 16) ? udiv(len, 16) : 1);
	if (range > 4) range = 2;

	/* rows BAND_Y1..316 every frame; 287..BAND_Y1 under a list (the band's bottom on the player) */
	if (!on_player)
		fill(0, 287, W, BAND_Y1 - 287, C_BLACK);
	fill(0, BAND_Y1, W, 317 - BAND_Y1, C_BLACK);
	if (info)
		text(&f_s, 18, 299, "LINK CUE", C_GREY, C_BLACK);
	/* V4s (deck3 log, 5 s right after play: 8 frames a second over budget, deck area 14 ms): this key also held
	 * the DJM on-air flag, MASTER and MT -- a flag flickering (a channel fader at the on-air threshold, a master
	 * hand-over) repainted the WHOLE deck area (rforce) each time. On-air is region 28 (the PLAYER tile),
	 * the master-coloured BPM frame goes with region 6, MT is region 10's. */
	/* V4n (claims audit #111): A.HOT CUE per HOT CUE AUTO LOAD (SHORTCUT bytes +0x15F ON / +0x163 rekordbox
	 * SETTING / +0x167 OFF): ON red, rekordbox SETTING white, OFF hidden; none set (not published) = red */
	int ahc = DECK[0x15F] ? 1 : DECK[0x163] ? 2 : DECK[0x167] ? 3 : 1;
	all = need(2, hmix(hmix(hmix(remain_mode, player_no), loaded), sync + 2 * ahc));
	if (all) {
		v2_reg_draws++;
		fill(0, 317, W, 480 - 317, C_BLACK);
		fill(0, 317, W, 1, C_BAR);
		frame(12, 325, 64, 59, 2, C_FRAME);
		text_c(&f_t, 44, 330, "PLAYER", C_WHITE, C_BLACK);	/* V3e1 (audit D9): the 3000's small labels */
		text(&f_t, 106, 330, "TRACK", C_WHITE, C_BLACK);
		if (ahc != 3) {
			frame(177, 331, 64, 19, 1, ahc == 1 ? C_RED : C_WHITE);
			text_c(&f_s, 209, 334, "A.HOT CUE", ahc == 1 ? C_RED : C_WHITE, C_BLACK);
		}
		text(&f_t, 275, 323, remain_mode ? "REMAIN" : "ELAPSED", C_WHITE, C_BLACK);
		text(&f_t, 528, 323, "TEMPO", C_WHITE, C_BLACK);
		/* V3e1 (audit D8): BEAT SYNC inside the BPM box while synced, as the 3000 */
		text(&f_t, 679, 329, sync ? "BEAT SYNC" : "BPM", C_WHITE, C_BLACK);	/* V3rc8z (claims audit #11): white */
		/* the bottom row is bottom-aligned with the overview's under-bar (y 474), as the 3000 */
		frame(12, 434, 64, 40, 2, C_WHITE);
		text_c(&f_s, 44, 435, "BEAT JUMP", C_WHITE, C_BLACK);
		text_c(&f_t, 759, 433, "KEY", C_WHITE, C_BLACK);
	}
	rforce |= all;		/* the background was cleared: every region below draws again */
	if (need(28, hmix(hmix(player_no, on_air()), (u32)pn_blank() + 2 * (u32)pn_grey()))) {	/* V4s: the PLAYER tile's number and on-air arcs */
		fill(14, 341, 60, 41, C_BLACK);
		buf[0] = '0' + player_no % 10; buf[1] = 0;
		if (!pn_blank())	/* V4n17: blinks while negotiating; V4n22: grey when not confirmed */
			text_c(&f_l, 44, 343, buf, pn_grey() ? C_GREY : C_WHITE, C_BLACK);
		if (on_air())		/* V3e1 (audit D1): the 3000's red ((n)) while the mixer has it on air */
			air_arcs(44, 361, C_RED);
	}

	if (need(3, trackno)) {
		fill(100, 343, 70, 32, C_BLACK);
		buf[0] = '0' + udiv(trackno, 10) % 10;
		buf[1] = '0' + trackno % 10;
		buf[2] = 0;
		text(&f_l, 102, 343, buf, C_WHITE, C_BLACK);
	}
	/* HWBOTTOM (work/hwbottom/AUDIT.md): the time in two regions -- region 4 the big "mm:ss" (once a second:
	 * 61-row f_xl glyphs, rows 330..390 = 5 canvas bands to copy), region 29 the ".mmm" (every painted frame:
	 * f_md, rows 352..381 = 2 bands). Same pixels: f_xl digits are tabular with no ink past their advance, so the
	 * ".mmm" box [x, 528) x [352, 379) never holds "mm:ss" ink; region 4 clears the whole box and redraws both. */
	if (need(4, hmix(hmix(failed ? 0 : udiv(t, 1000), remain_mode), failed))) {
		fill(268, 337, 260, 42, C_BLACK);
		text(&f_xl, 270, 330, failed ? "--:--" : (fmt_mmss(buf, t), buf), C_WHITE, C_BLACK);
		rk[rb][29] = 0;		/* the box was cleared: the ".mmm" draws again */
	}
	if (need(29, hmix(hmix(failed ? 0 : t, remain_mode), failed))) {
		int x;
		if (failed)	/* as stock: "--:--.---" */
			x = 270 + text_w(&f_xl, "--:--");
		else {
			fmt_mmss(buf, t);
			x = 270 + text_w(&f_xl, buf);
		}
		fill(x, 352, 528 - x, 27, C_BLACK);
		if (failed)
			text(&f_md, x, 352, ".---", C_WHITE, C_BLACK);
		else {
			fmt_ms3(buf, t);
			text(&f_md, x, 352, buf, C_WHITE, C_BLACK);
		}
	}
	{
	int bmode = sync || bpm_mode();	/* stock: the FADER's BPM, grey, in BPM mode (V4n34) */
	u32 fb10 = bmode && loaded && !failed ? fader_bpm10() : 0;
	int tko = fader_dir(fb10, sync, bpm10);
	if (need(5, hmix(hmix(hmix(bmode ? 0 : (u32)tempo_raw, range), bmode + 2 * failed + 4 * (u32)(tko + 1)), fb10))) {
		{	/* the range badge as stock: +-6 green, +-10 red, +-16 white (black text), WIDE red
			 * text without a box; hardware semantics, the same in LIGHT / FULL (day off here) */
			/* V3e1 (audit Q7): +-6 the 3000 green, +-10 / +-16 #FF4619 */
			static const u16 RC[] = { C_GREEN, C_GREEN, C_OR, C_OR, 0 };
			int sd = day;
			u16 pbg = dm(C_BLACK);
			fill(592, 324, 50, 16, C_BLACK);
			day = 0;
			if (range == 3) {	/* V3rc8z (claims audit #10): +-16 = white fill, black text (skin) */
				fill(592, 324, 50, 16, sd ? 0x1082 : 0xFFFF);
				text_c(&f_s, 617, 326, RANGE[range], sd ? 0xFFFF : C_BLACK, sd ? 0x1082 : 0xFFFF);
			} else if (range < 4) {
				fill(592, 324, 50, 16, RC[range]);
				text_c(&f_s, 617, 326, RANGE[range], C_BLACK, RC[range]);
			} else
				text_c(&f_s, 617, 326, RANGE[range], 0xF800, pbg);
			day = sd;
		}
		fill(528, 342, 134, 38, C_BLACK);
		if (bmode && fb10) {	/* as stock: the fader's own position as a BPM, grey, where the % was (synced, or
					 * the tempo held after SYNC off); the box keeps the playing BPM */
			fmt_bpm(buf, fb10, 0);
			text(&f_s, 530, 344, "BPM", C_GREY, C_BLACK);
			text_r(&f_l, 656, 344, buf, C_GREY, C_BLACK);
			if (tko)	/* V4n34: takeover pending -- the way to move the fader to the playing tempo */
				tko_arrow(538, 362, tko, 7, C_WHITE);
		} else if (failed) {	/* as stock after a failed load */
			text_r(&f_l, 636, 344, "0.00", C_WHITE, C_BLACK);
			text(&f_s, 638, 366, "%", C_WHITE, C_BLACK);
		} else if (!bmode) {
			fmt_pitch(buf, tempo_raw, range);
			text_r(&f_l, 636, 344, buf, C_WHITE, C_BLACK);
			text(&f_s, 638, 366, "%", C_WHITE, C_BLACK);
		}
	}
	}
	if (need(6, hmix(hmix(hmix(bpm10, v100), bpm_unknown), loaded * 2 + sync + 4 * master))) {
		u16 bc = master ? C_MASTER : C_WHITE;	/* V3e3 (audit): the 3000's BPM digits are orange on the master */
		/* DISPFIX (deck 3 photo 2026-11-17): the MASTER tab's cell is cleared here too -- the frame and the digit
		 * fill below leave rows 327..339 alone, so after a master hand-off the orange tab stayed on the new
		 * follower (white frame, white digits, MASTER tab) until region 2 repainted (BEAT SYNC / BPM label at
		 * x 679.., left of the cell) */
		fill(745, 325, 42, 15, C_BLACK);
		frame(672, 325, 115, 59, 2, master ? C_MASTER : C_FRAME);	/* V4s: here, not in region 2 */
		if (master) {	/* V4n (claims audit #128): the MASTER tab inside the box's top-right (skin 68x19 at
				 * 1192,488 -> 42x13 at 745,325), not above the frame */
			fill(745, 325, 42, 13, C_MASTER);
			text_c(&f_t, 766, 326, "MASTER", C_BLACK, C_MASTER);
		}
		fill(674, 340, 111, 42, C_BLACK);
		if (loaded && !bpm_unknown) {
			char *dot;
			fmt_bpm(buf, bpm10, v100);
			for (dot = buf; *dot && *dot != '.'; dot++)
				;
			*dot = 0;		/* integer part big, the decimals small (as the 3000) */
			if (v100) {	/* two decimals, small, inside the box (box 672..787, 5 px pad) */
				int wi = text_w(&f_bpm, buf), wd;
				*dot = '.';
				wd = text_w(&f_sd, dot);
				if (wi + wd <= 106)
					bpm_split(782, BPM_BASE - f_bpm.asc, &f_bpm, &f_sd, buf, bc);
				else
					bpm_split(782, BPM_BASE - f_l.asc, &f_l, &f_sd, buf, bc);
			} else {
				*dot = '.';
				bpm_split(782, BPM_BASE - f_bpm.asc, &f_bpm, &f_md, buf, bc);
			}
		} else if (loaded && bpm_unknown) {
			buf[0] = '-'; buf[1] = '-'; buf[2] = '.'; buf[3] = '-'; buf[4] = 0;
			bpm_split(782, BPM_BASE - f_bpm.asc, &f_bpm, &f_md, buf, bc);
		}
	}
	if (need(7, q + 8 * (u32be(DECK + 0x48) != 0))) {	/* V3e3: QUANTIZE on = red (re_deck: +0x48) */
		u16 qc = C_RED;
		fill(12, 390, 64, 40, C_BLACK);
		if (u32be(DECK + 0x48)) {	/* V3rc8z (claims audit #11): the 3000 hides QUANTIZE when it is off */
			text_c(&f_m, 44, 404, QV[q], qc, C_BLACK);
			frame(12, 390, 64, 40, 2, qc);
			text_c(&f_s, 44, 391, "QUANTIZE", qc, C_BLACK);
		}
	}
#ifdef V3E2
	/* V3e3 (audit D2 / D3 / D7, V3E_DESIGN §7.1): MAIN's +0x14 page 0 -- BEAT JUMP value under its label,
	 * the AUTO CUE box under A.HOT CUE, SINGLE above the time (3000 places); REV / VINYL beside it (the
	 * NXS2 has no jog LCD: the 3000 shows the jog mode there) */
	if (need(27, hmix(hmix(v3e_d & 0xFF, loaded), u32be(DECK + 0x3C) * 4 + (u32be(DECK + 0x2C) != 0)))) {
		static const char *const BJV[8] = { "", "1", "2", "4", "8", "16", "32", "64" };
		int x;
		fill(14, 448, 60, 24, C_BLACK);
		if ((v3e_d & 0x80) && V3E_BJ)
			text_c(&f_m, 44, 450, BJV[V3E_BJ], C_WHITE, C_BLACK);
		fill(177, 353, 64, 20, C_BLACK);
		if (u32be(DECK + 0x2C)) {	/* re_deck: stock AUTO CUE, 2 on / 0 off */
			frame(177, 354, 64, 19, 1, C_WHITE);	/* V3rc8z (claims audit #11): AUTO CUE is white on the 3000 */
			text_c(&f_s, 209, 357, "AUTO CUE", C_WHITE, C_BLACK);
		}
		fill(380, 322, 147, 13, C_BLACK);
		x = 516;	/* (TEMPO starts at 528) */
		if ((v3e_d & 0x80) && V3E_VINYL)
		{
			text_r(&f_t, x, 323, "VINYL", C_GREY, C_BLACK);
			x -= text_w(&f_t, "VINYL") + 8;
		}
		if ((v3e_d & 0x80) && V3E_REV)
		{
			text_r(&f_t, x, 323, "REV", C_RED, C_BLACK);
			x -= text_w(&f_t, "REV") + 8;
		}
		if (u32be(DECK + 0x3C) == 2)	/* re_deck: stock PLAY MODE, 1 CONTINUE / 2 SINGLE */
			text_r(&f_t, x, 323, "SINGLE", C_GREY, C_BLACK);
	}
#endif
	{
		/* KEY: the model carries it (side 1 slot 0) only on the player screen; it is kept per track
		 * so the deck area under a list shows it too */
#define kbuf g_key
#define kn g_kn
#define kid g_kid
		u32 tid = hmix(trackno, len);
		int i2;
		if (on_player && !MODEL[0x0F] && loaded && u16len(SLOT(1, 0)) && u16len(SLOT(1, 0)) <= 8) {
			const volatile u8 *kk = SLOT(1, 0);
			kn = u16len(kk);
			for (i2 = 0; i2 < 2 * kn; i2++)
				kbuf[i2] = kk[0x2A + i2];
			kid = tid;
		}
		/* LASTFIX #83 (deck + emu k83: RE-loading the SAME track over LINK lost the KEY): the gate clears kn
		 * while the track loads, but kid kept the same tid, so once the track was back nothing ran again,
		 * and MAIN does not fill the model's KEY slot again for a reload (emu: slot empty). Now an empty
		 * kn retries the fallbacks, and the last key shown is kept with its tid + MAIN's rbid (lk_*):
		 * a reload of that very track (same tid and rbid) gets it back */
		static u8 lk_key[16];
		static int lk_kn;
		static u32 lk_tid, lk_rb;
		if (kid != tid || !loaded || !kn) {
			kn = 0;
			fb_title(loaded);	/* V4m3: no model key for this track -> the browse row's (fb_kc) */
			if (loaded && fb_kn) {
				for (i2 = 0; i2 < 16; i2++)
					kbuf[i2] = fb_kc[i2];
				kn = fb_kn;
				kid = tid;
			} else if (loaded && lk_kn && lk_tid == tid && lk_rb && lk_rb == cue_rbid()) {
				for (i2 = 0; i2 < 16; i2++)
					kbuf[i2] = lk_key[i2];
				kn = lk_kn;
				kid = tid;
			}
		}
		if (loaded && kn && kid == tid && cue_rbid()) {
			for (i2 = 0; i2 < 16; i2++)
				lk_key[i2] = kbuf[i2];
			lk_kn = kn;
			lk_tid = tid;
			lk_rb = cue_rbid();
		}
		{
			u32 hk = hmix(kn, kid);
			u16 kcol;
			for (i2 = 0; i2 < 2 * kn; i2++)
				hk = hmix(hk, kbuf[i2]);
			kcol = kn && deck_key_green() && !(loaded && is_master()) ? C_GREEN : C_WHITE;	/* V3e3 (Q14 / D11); V3rc8z (claims audit #5): white on the master deck */
			hk = hmix(hk, kcol);
#ifdef V2_KEYSHIFT
			/* V4n9 (CDJ-3000 emu): MASTER TEMPO off and the fader moving the key -> the 3000 shows the SOUNDING
			 * key in grey #969696. Semitones = round(12 log2(1 + tempo)): half-semitone bounds in 1/100 % */
			int fsem = 0;
			if (!mt && kn) {
				static const short UP[6] = { 293, 905, 1554, 2240, 2968, 3740 };
				static const short DN[6] = { -285, -830, -1343, -1830, -2287, -2716 };
				while (fsem < 6 && tempo >= UP[fsem]) fsem++;
				if (!fsem)
					while (fsem > -6 && tempo <= DN[-fsem]) fsem--;
			}
			hk = hmix(hk, (u32)KS_SEMI + ((u32)fsem << 8));
			hk = hmix(hk, KS_AMT_H());	/* KSAMT (V4n43) */
#endif
			hk = hmix(hk, (u32)KF_CLASSIC);	/* V4n36 */
			if (need(8, hk)) {
				const volatile u8 *kd = kbuf;
				int kdn = kn;
				kd = kf_key(kbuf, &kdn);	/* V4n36: the KEY FORMAT */
#ifdef V2_KEYSHIFT
				kdn = kn;	/* V4n41 KEYFIX: kf_key set kdn to the FORMATTED length ("3A" = 2); ks_key re-parses kbuf
						 * ("Bbm") with it -> "Bb" -> 6B on the player (every key whose source text is longer
						 * than its shown form). The browse strip already reset it (kdn = g_kn) */
				kd = ks_key(kbuf, &kdn, &kcol);
				if (fsem) {
					int m = key_txt(ks_kb, kbuf, kn, KS_SEMI + fsem);
					if (m) {
						kd = ks_kb;
						kdn = m;
						kcol = 0x94B2;	/* #969696 */
					}
				}
#endif
				fill(726, 446, 66, 30, C_BLACK);
				if (kdn) {
					int wsum = 0, kx;
#ifdef V2_KEYSHIFT
					char a1[8], a2[8];
					int amt = ks_amt(a1, a2);
#endif
					set_ramp(C_WHITE, C_BLACK);
					for (i2 = 0; i2 < kdn; i2++) {
						const struct glyph *g = glyph(&f_m, (u32)kd[2 * i2] << 8 | kd[2 * i2 + 1]);
						wsum += g ? g->adv : 0;
					}
					kx = 759 - wsum / 2;
#ifdef V2_KEYSHIFT
					if (amt) {	/* KSAMT (V4n43): the key to the left, the amount in two small rows at
							 * the right edge (semitones over the KEY SYNC cents), orange */
						int aw = text_w(&f_s, a1), bw = text_w(&f_s, a2);
						int rw = (aw > bw ? aw : bw) + 3;
						kx = 728;
						if (kx + wsum > 791 - rw)
							kx = 791 - rw - wsum;
						if (kx < 726)
							kx = 726;
						if (a1[0])
							text_r(&f_s, 791, a2[0] ? 445 : 453, a1, C_OR, C_BLACK);
						if (a2[0])
							text_r(&f_s, 791, a1[0] ? 460 : 453, a2, C_OR, C_BLACK);
					}
#endif
					text_u16(&f_m, kx, 448, kd, kdn, W, kcol, C_BLACK);
				}
			}
		}
#undef kbuf
#undef kn
#undef kid
	}
	/* overview 640 x 21 at (79, 427), under-bar, playhead, cue/loop marks; then the badges over it */
	{
		int ovs = !(ana || ov_new);	/* V3e1: the overview as soon as its 0x35 is in */
		u32 ko = hmix(hmix(hmix(hmix(loaded + 2 * info, pos_x), u32be(OV_HDR + 4)), OV_HIDE), len) + ovs + 4 * OV_COLOUR;
		ko = hmix(hmix(ko, marks_ck()), bpm10 + failed);
		ko = hmix(hmix(ko, ov_ck()), wave_type + 4 * (u32)ov_full);	/* OVSHAPE3: + WAVEFORM FULL / HALF */
		if (ana && !OV_COLOUR)
			ko = hmix(ko, mono_ck());
		ko = hmix(ko, slip_ms_ok() && len ? udiv(udiv(slip_pos_ms(), 16) * 640, udiv(len, 16) ? udiv(len, 16) : 1) + 1 : 0);
		ko = hmix(hmix(ko, remain_mode), DECK[0xDF] == 3 && ns_live ? 1 + (u32be(DECK + 0x70) >> 4) : 0);
		if (need(9, ko)) {
			fill(79, 400, 642, 80, C_BLACK);
			fill(556, 380, 90, 22, C_BLACK);
			wave_on();
			fill(OV_X, OV_Y, 640, OVH, C_BLACK);	/* the overview's own background */
			if (info) {		/* INFO: the browsed track's overview (Link Cue), no playhead */
				overview(OV_X, OV_Y, 640, OVH, 0, 0);
				wave_off();
			} else if (loaded) {
				/* V3c (W4): the 3000 overview -- markers above, the overview (played part grey), the red
				 * progress line, the minute ruler with the cue triangle under it */
				if (!ovs) {
					overview(OV_X, OV_Y, 640, OVH, pos_x, ana);
					if (on_player && ov_ready(ana))
						strip_snap(hmix(trackno, len), ana);
				}
				if (on_player)		/* R21 parity (c): the strip's cue marks (this region is keyed on marks_ck) */
					strip_marks_snap(hmix(trackno, len));
				/* V3e1 (audit Q13): the 3000 under-bar -- a white rule ahead, #555555 under the played
				 * part with the red progress line below it */
				fill(OV_X, OV_BAR, pos_x, 1, 0x52AA);
				fill(OV_X + pos_x, OV_BAR, 640 - pos_x, 1, C_WHITE);
				fill(OV_X, OV_BAR + 1, 640, 1, C_RED);	/* V3rc8t (claims audit #4): the red line runs the full width (3.20 refs) */
				ruler(OV_X, 640, len, remain_mode);
				markers(OV_X, 640, len);
				if (pos_x)	/* V3rc8t (3000 gap sweep #8): the overview playhead has a black edge */
					fill(OV_X + pos_x - 1, OV_Y - 2, 1, OV_BAR + 2 - OV_Y + 2, C_BLACK);
				if (pos_x + 2 < 640)
					fill(OV_X + pos_x + 2, OV_Y - 2, 1, OV_BAR + 2 - OV_Y + 2, C_BLACK);
				fill(OV_X + pos_x, OV_Y - 2, 2, OV_BAR + 2 - OV_Y + 2, C_WHITE);
				if (slip_ms_ok() && len) {	/* the slip ghost: where the track really is (V4n32: MAIN's ms) */
					u32 sp = slip_pos_ms(), gx;
					if (sp > len) sp = len;
					gx = udiv(udiv(sp, 16) * 640, udiv(len, 16) ? udiv(len, 16) : 1);
					if (gx > 638) gx = 638;
					if (gx + 3 < pos_x || gx > pos_x + 3)
						fill(OV_X + gx, OV_Y - 2, 2, OV_BAR + 2 - OV_Y + 2, C_SLIPG);
				}
				if (DECK[0xDF] == 3 && ns_live && u32be(DECK + 0x74) && needle_away(pos_x)) {
					/* V3c (W7) needle-drag preview: a finger on the strip while playing (Touch Cue / needle
					 * preview, heartbeat +0xDF = 3): the band already follows the finger (+0x70, the
					 * position in entries, moves to it while +0x78 keeps the deck's time); a marker and the
					 * finger's time on the overview, as the 3000 */
					u32 fp = u32be(DECK + 0x70), fn = u32be(DECK + 0x74), fx;
					int nx;
					if (fp > fn) fp = fn;
					fx = udiv((fp >> 4) * 640, (fn >> 4) ? fn >> 4 : 1);
					if (fx > 639) fx = 639;
					fill(OV_X + fx, OV_Y - 2, 2, OV_BAR + 2 - OV_Y + 2, C_GREEN);
					nx = OV_X + (int)fx - 22;
					if (nx < OV_X) nx = OV_X;
					if (nx > OV_X + 640 - 44) nx = OV_X + 640 - 44;
					fmt_mmss(buf, udiv(fp * 20, 3));
					fill(nx, OV_TOP - 2, 44, 14, C_WHITE);
					text_c(&f_s, nx + 22, OV_TOP - 3, buf, C_BLACK, C_WHITE);
				}
				wave_off();	/* V3e1 (audit Q5): no NXS2 LOOP badge (the 3000 shows the loop length
						 * under the playhead) */
			} else {
				wave_off();
			}
			rk[rb][10] = 0;		/* the badges sit over the overview's right end */
		}
	}
#ifdef V2_KEYSHIFT
	int ksy = KS_KSYNC ? 1 : KS_KREF ? 2 : 0;
#else
	int ksy = 0;
#endif
	if (need(10, hmix(hmix(hmix(master, sync), (mt != 0) + 2 * ksy), cpu_load >= 80 ? 4 + 8 * (cpu_load >= 90) : 0))) {
		/* V3e1 (video 02, audit D8): the MASTER tab sits on the BPM box's top-right corner, as the 3000 */
		fill(672, 384, 115, 13, C_BLACK);
		fill(730, 318, 57, 7, C_BLACK);	/* V4n: the MASTER tab moved into the BPM box (region 6) */
		fill(672, 402, 120, 20, C_BLACK);
		if (ksy) {	/* V4n: the CDJ-3000's K.SYNC badge (skin img_syncKeyShift_#on: #007DE1 frame + text on
				 * black, the MT badge's slot); a refusal shows it white for ~0.6 s */
			u16 kc = ksy == 1 ? C_SEL : C_WHITE;
			frame(724, 403, 63, 17, 1, kc);
			text_c(&f_s, 755, 405, "K.SYNC", kc, C_BLACK);
			if (mt) {	/* KSAMT (V4n43, user): MT stays beside K.SYNC (it used to be replaced) */
				frame(678, 403, 42, 17, 1, C_OR);
				text_c(&f_s, 699, 405, "MT", C_OR, C_BLACK);
			}
		} else if (mt) {
			frame(732, 403, 55, 17, 1, C_OR);
			text_c(&f_s, 759, 405, "MT", C_OR, C_BLACK);
		}
		/* V3rc8 (user): the GUI CPU load only when high (yellow >= 80 %, red >= 90 %), above the small KEY label
		 * (left of the MT box when MT is on) */
		if (cpu_load >= 80) {
			char cb[8];
			cb[0] = 'C'; cb[1] = 'P'; cb[2] = 'U'; cb[3] = ' ';
			cb[4] = (char)('0' + udiv(cpu_load, 10)); cb[5] = (char)('0' + cpu_load % 10); cb[6] = '%'; cb[7] = 0;
			if (!(ksy && mt))	/* KSAMT: no room beside both badges */
				text_c(&f_t, mt ? 700 : 758, 406, cb, cpu_load >= 90 ? C_RED : 0xFFE0, C_BLACK);
		}
	}
	}
}

extern u32 v2_frames;
static u32 toast_t0, toast_was;
static int toast_on(void)
{
	u32 now = now_ms();	/* V3f: time, not painted frames (frames stop on a static screen) */
	if (!toast_was) {
		toast_was = 1;
		toast_t0 = now;
	}
	if (now - toast_t0 > 5000)	/* V3rc8: 5 s, as the CDJ-3000 cautions (caution table 0x1388 ms) */
		return 0;
	return pend = 1;
}
static void error_toast(void)
{
	const char *m;
	m = u16be(ERR_TXT + 10) == '5' ? "Unsupported file format." :
	    "Media or File is collapsed or unavailable.";
	fill(150, 165, 500, 44, C_SEL);
	text_c(&f_m, 400, 175, m, C_WHITE, C_SEL);
}

/* V3c (W3/W7) overlays on the band, every frame (the band is):
 * - MASTER PLAYER: an orange label at the playhead for ~2 s when this deck becomes the tempo master
 *   (the 3000, video 95:30). */
u32 v2_master_shows;
static int master_label(void)
{
	static u32 was_master, t_master, tid, t_load;
	/* DISPFIX (emu two-deck hand-off): is_master(), not raw +0xA0 -- a SYNC follower reads +0xA0 = 1 in ~1 of 40
	 * samples (re/AV_SYNC_COMPARE.md) and that blip flashed MASTER PLAYER on the follower */
	u32 m = (u32)is_master(), id = hmix(u32be(DECK + 0x60), u32be(DECK + 0x7C)), now = now_ms();
	if (id != tid) {		/* a load: a lone deck becomes master with it -- no label for that */
		tid = id;
		t_load = now;
	}
	if (m && !was_master && now - t_load > 3000) {
		t_master = now;
		v2_master_shows++;
	}
	was_master = m;
	if (m && now - t_master < 2000)
		return pend = 1;
	return 0;
}
static void band_extras(int lab)
{
	int ck = cue_next_cm();
	if (ck) {	/* V4b1: the next cue's comment, small white text in the band's top margin (the 3000 shows it by the cue) */
		const char *cm = cue_t[ck - 1].cm;
		int w = text_w(&f_s, cm) + 8;
		fill(WAVE_X0 + 4, CUE_CM_Y, w, 14, C_BLACK);
		text(&f_s, WAVE_X0 + 8, CUE_CM_Y + 1, cm, C_WHITE, C_BLACK);
	}
	if (lab) {
		int w = text_w(&f_s, "MASTER PLAYER") + 10, x = WAVE_X0 + V2_PLAYHEAD - w / 2;
		fill(x, BAND_Y0 + 17, w, 16, C_MASTER);
		text_c(&f_s, WAVE_X0 + V2_PLAYHEAD, BAND_Y0 + 18, "MASTER PLAYER", C_BLACK, C_MASTER);
	}
}

/* under the band (row BAND_Y1..316, after deck_area cleared it):
 * - the beat-distance numbers: FIXED marks N beats ahead of the playhead (2 / 4 zoomed in, 4 / 8 zoomed
 *   out: the larger pair whose 8 / 4 beats still fit the band), as the 3000 (video §1, burst 87:40);
 * - "<loop> n": the active loop's length in beats at the playhead (the 3000's loop arrow + 1/2, 4 ...). */
static void loop_icon(int x, int y, u16 c)	/* a 9 x 9 circular arrow */
{
	static const u16 M[9] = { 0x07C, 0x082, 0x101, 0x101, 0x101, 0x101, 0x082, 0x07C, 0x000 };
	int i, j;
	for (j = 0; j < 8; j++)
		for (i = 0; i < 9; i++)
			if (M[j] >> (8 - i) & 1)
				fill(x + i, y + j, 1, 1, c);
	fill(x + 6, y - 1, 3, 1, c);	/* the arrow head, top right */
	fill(x + 7, y, 1, 1, c);
	fill(x + 1, y + 7, 2, 1, C_BLACK);	/* the gap at the bottom left */
}
/* V4 (HWBAND): split into calc (updates the smoothing statics, records what to draw, returns its hash) and draw,
 * so the hardware band can key the GR3 overlay on it; band_numbers() = calc + draw, as before */
static struct { int nb, k, x[2], lab, lk, lx, ly; u16 lc; } bnr;
static const volatile u8 *grid_at(u32 el, u32 *idx, u32 *cnt);
static u32 band_numbers_calc(u32 bpm10)
{
	int looping = DECK[0xD3] == 3 || DECK[0xD3] == 5;	/* V3e1 (audit Q9): the 3000's row */
	/* V3rc7: the rows under the band belong to the pad row whenever a pad mode is open (loop or jump) */
	int pads = DECK[0xF3] == 2 || DECK[0x11B] == 1;
	bnr.nb = 0;
	bnr.lab = 0;
	{	/* #16 (TANDA3): the 3000's beat-distance numbers, n / 2n beats right of the playhead (they do not scroll).
		 * px per beat from the grid BPM at the playhead (constant: the GR3 key changes only on a zoom or a tempo
		 * change in the grid), the band is in track time (pitch does not matter): 150 entries / s, 2^sh a column */
		u32 gi, cnt, bp, ppb16;
		const volatile u8 *r0 = pads ? 0 : grid_at(u32be(DECK + 0x78), &gi, &cnt);
		bp = r0 ? u16be(r0 + 20 * gi + 2) : 0;
		if (bp >= 2000 && bp <= 30000 && !BN_OFF) {
			/* the largest pair (n, 2n) from 2/4 up whose 2n beats still fit right of the playhead; #16b (3000
			 * screenshots, re/WAVE3000_SPEC.md §BN): the 3000's rule is 2n x px/beat <= its half width (4/8 at
			 * 70-76 px/beat, 16/32 at 19 px/beat on 1280); here the band's right edge less half a label */
			/* V4n27z: the band now spans the 3000's time window, so its rule scales exactly: 2n x px/beat <= 640 x
			 * 0.625 = 400 (centre playhead; LEFT: the band's right part) -- the 3000's pair at every zoom */
			int room = ph_left ? WAVE_N - V2_PLAYHEAD - 6 : 400, k = 0, j;
			ppb16 = udiv(udiv(144000000u, (u32)SHL(16, b_sh)), bp);	/* 900,000 x 16 / (bpm100 x 1.6 x 2^sh) */
			while (k < 5 && (int)((ppb16 << (k + 3)) >> 4) <= room)
				k++;
			bnr.nb = 1;
			bnr.k = k;
			for (j = 0; j < 2; j++)
				bnr.x[j] = WAVE_X0 + V2_PLAYHEAD + (int)((ppb16 << (k + j + 1)) >> 4);
		}
	}
	{	/* V3e1 (audit Q4/W6): the loop length is always shown under the playhead -- orange while looping,
		 * grey otherwise (the stored loop's length, else the 4-BEAT LOOP key's 4); above the pads when
		 * they are up */
		int lk = loop_len_k(bpm10);
		bnr.ly = pads ? 244 : 293;
		bnr.lc = looping ? (slip_on() ? 0x0C9F : C_MASTER) : C_LBL;	/* V3rc8t: slip loop = #0F91FF (3000) */
		if (lk >= 0 || looping) {	/* V3rc8t (claims audit #12): the 3000 shows "<loop> n" only with a loop */
			bnr.lab = 1;
			bnr.lk = lk < 0 ? 5 : lk;
		}
	}
	return hmix(hmix(hmix((u32)bnr.nb | (u32)bnr.k << 4 | (u32)bnr.lab << 8 | (u32)bnr.lk << 12 | (u32)bnr.ly << 16,
			      (u32)bnr.x[0] | (u32)bnr.x[1] << 16), bnr.lc), 0xB7);
}
static void band_numbers_draw(void)
{
	static const char *const L[] = { "1/8", "1/4", "1/2", "1", "2", "4", "8", "16", "32" };
	wave_on();
	{
	static const char *const NB[] = { "2", "4", "8", "16", "32", "64", "128" };
	int j;
#ifdef V2_KEYSHIFT
	if (bnr.nb && !KS_PANEL && !GA_MODE)	/* V4k: not over the KEY SHIFT panel's tiles (TOUCH: nor GRID ADJUST's) */
#else
	if (bnr.nb)
#endif
		for (j = 0; j < 2; j++) {
			/* #16b (3000 screenshots clean3k / c / a, re/WAVE3000_SPEC.md §BN): each number CENTRED on its
			 * n-beat distance from the playhead (+-1 px on 1280), white digits whose cap height spans
			 * 0.6 .. 1.35 of the lower tick row (418..432 -> 427..438 on 720): f_t cap rows 286..292 here
			 * under ticks 279..288; drawn over the ticks (the 3000 does not clear them) */
			int w = text_w(&f_t, NB[bnr.k + j]), x = bnr.x[j] - w / 2;
			if (x + w > WAVE_X0 + WAVE_N)	/* V4n27z: room 400 > the band's right half: keep it inside */
				x = WAVE_X0 + WAVE_N - w;
			text(&f_t, x, 283, NB[bnr.k + j], C_WHITE, C_BLACK);
		}
	}
	if (bnr.lab) {
		int w = 12 + text_w(&f_t, L[bnr.lk]), x = WAVE_X0 + V2_PLAYHEAD - w / 2;
		loop_icon(x, bnr.ly + 2, bnr.lc);	/* (no clear: the band's ring copy repaints these rows) */
		text(&f_t, x + 12, bnr.ly, L[bnr.lk], bnr.lc, C_BLACK);
	}
	wave_off();
}
static void band_numbers(u32 bpm10)
{
	band_numbers_calc(bpm10);
	band_numbers_draw();
}

/* ---- V3d: the LINK phase meter (re/V3_PROGRESS.md V3d; the 3000: video §0/§1, frames 01/02/03/05/06) ----
 * Two rows on one time axis at 100 px per second of REAL time (V4n30a, scaling rule: the 3000's constant
 * 160 px/s x 0.625 -- the beat pitch follows the BPM), the centre line at the band's playhead x:
 * - PHASE: the orange (master) line carries the master's beats from its bar position over LINK (heartbeat
 *   +0xB8 ms in a bar of +0xB4 ms, real time), the blue (own) line this deck's grid beats; both scroll
 *   smoothly, downbeats red. With this deck the master (or alone) the orange line stays plain (3000).
 * - WAVEFORM: the master's track as a thin waveform on the same time scale with its beat ticks; the data is
 *   the master's waveform when it plays THIS deck's track (MAIN flags it); otherwise (no LINK waveform
 *   fetch without the MAIN room, T1) the master's beat grid alone.
 * - Left labels: orange = the master's bars.beats to its next cue (MAIN's status table, 0x1FF none),
 *   blue = this deck's to its next hot / memory cue (cue table 0x0E604F10 records 1..), from the grid. */
static u32 now_ms(void);
u32 v2_pm_same, v2_pm_grid;
/* the grid record at or before el (cached index); 0 = no grid */
static const volatile u8 *grid_at(u32 el, u32 *idx, u32 *cnt)
{
	static u32 gi;
	u32 n = u32be(GRID + 4), rp = u32be(GRID + 0x18);
	const volatile u8 *r0;
	if (!GRID_OK || !n || n >= 8192 || (rp & 0xFF000000) != 0x0F000000)
		return 0;
	r0 = (const volatile u8 *)((rp & 0x1FFFFFFF) | 0x20000000);
	if (gi >= n || gms(r0 + 20 * gi) > el)
		gi = 0;
	while (gi + 1 < n && gms(r0 + 20 * (gi + 1)) <= el)
		gi++;
	*idx = gi;
	*cnt = n;
	return r0;
}
/* the master's position in its bar (ms, real time) this frame: +0xB8, carried on from its last change by
 * the time since while it keeps changing (stopped / paused master, or no change for 100 ms: as is).
 * V4n31a (#59, deck video: the WAVEFORM view fell back to the PHASE lines for single frames): at a bar wrap the
 * heartbeat can carry +0xB8 >= the bar length (+0xB4) for a frame -- that read as "no master" (-1). Now a value
 * past the bar wraps, and a missing / implausible one holds the last good phase, carried on in real time, for up
 * to 500 ms (MP_HOLD) before the meter gives up on the master. */
#define MP_HOLD 500
static u32 mp_t_good, mp_bar_good;
static s32 mp_good;
/* LINKLAT (v4.2, work/linklat/REPORT.txt items 1 + 2; work/linklat/LATFIX_DONE): the master's bar phase is
 * predicted for the moment the frame is SEEN, not for "now", and each sample is aged from MAIN's own time stamp.
 *  #2 sample age: MAIN (modsmenu sl_pub, the heartbeat's 'K' word +0x18, normal boot only) stamps every heartbeat
 *     copy with its 1-ms tick & 127 (bits 17-23 = DECK[0x19] >> 1). d = (now - stamp) & 127 is the clock offset +
 *     the copy's age; the offset is the minimum d over 2 s (lk_base), so age = d - lk_base. A changed +0xB8 is
 *     stamped t_chg = now - age (was: now, "fresh" = the frame-sampling + SPI delay was pure lag).
 *  #1 display time: lk_vs3 tracks the vsync the paint started on (pf_t0 after wait_latch, phase-corrected when
 *     wait_latch ended on the vsync flag, 1/3-ms units); the frame is seen 1 vsync later (2 on the 30-fps pace
 *     path, lk_2vs) plus the scan-out to the meter rows. LINK OFFSET (UTILITY row, both profiles, modsmenu lo_v,
 *     published in the 'K' word bits 4-7: 1 OFF = default (the CDJ-3000 / v4.1 behaviour exactly; 0 = no word: the last
 *     value seen, OFF before one), 2..15 = -10..+55 ms in
 *     5-ms steps) = the lead from that start vsync to the moment the meter rows are seen: one field 16.7 + scan
 *     ~3 + upstream ~5 = +25 (report section 3). The PHASE view (master_ticks), the WAVEFORM view (master_mini,
 *     SMOOTHWAVE, the GR1 ring's scroll = SMOOTHWAVE's `first`) all take mph from here. With a 0x0b master
 *     (LINK0B) master_mini carries l0b_pos's position on by the same lead (lk_lead) x the master's speed. */
extern u32 v2_epoch;
static u32 pf_t0;		/* paint_frame's start after wait_latch (defined with METERDIRECT further down) */
static int lk_wl;		/* wait_latch ended on the vsync flag this frame (pf_t0 = that vsync, <= 1 ms late) */
static int lk_2vs;		/* the frame goes out on the 2nd vsync (V2_VSPACE 30-fps pace path, v2_paint) */
static u32 lk_ep, lk_vs3, lk_base, lk_wt, lk_wmin = 255;
static int lk_vok, lk_bok;
u32 v2_lk_off = 0, v2_lk_on = 0, v2_lk_age, v2_lk_lead, v2_lk_stamp;	/* mem / HUD */
static u32 lk_sa, lk_sl, lk_n, lk_amax;	/* HUD: sums over the second */
/* the display-time lead (ms, signed) from `now` to the moment this frame's meter rows are seen (0 when OFF or before
 * the first frame's anchor); also for the 0x0b position (LINK0B) in master_mini */
static s32 lk_lead(u32 now)
{
	if (!v2_lk_on || !lk_vok)
		return 0;
	return (s32)(lk_vs3 + (lk_2vs ? 50 : 0) - now * 3) / 3 + (s32)v2_lk_off;
}
/* the master phase's display-time lead (ms, signed, from now) and the current sample's age (ms) */
static s32 lk_prep(u32 now, u32 *age)
{
	static u32 lk_nib = 1;	/* LINKOFF: the last LINK OFFSET seen (OFF until then; kept while SLIP uses the word) */
	u32 nib, p3;
	s32 d, lead;
	if (DECK[0x18] == 0x4B && (DECK[0x1B] >> 4))
		lk_nib = (u32)(DECK[0x1B] >> 4);
	nib = lk_nib;
	*age = 0;
	v2_lk_on = nib != 1;
	v2_lk_off = nib >= 2 ? (nib - 2) * 5 - 10 : 0;	/* (u32) -10 = 0xFFFFFFF6: used signed below */
	if (!v2_lk_on)
		return 0;
	if (DECK[0x18] == 0x4B) {	/* #2: the sample's age from MAIN's stamp */
		u32 dd = (now - (u32)(DECK[0x19] >> 1)) & 127, a;
		v2_lk_stamp++;
		if (!lk_bok) {
			lk_base = dd;
			lk_bok = 1;
			lk_wt = now;
			lk_wmin = 255;
		}
		a = (dd - lk_base) & 127;
		if (a >= 104) {		/* up to 24 ms younger than the base: a new minimum */
			lk_base = dd;
			a = 0;
		} else if (a > 60)	/* stale or ambiguous (the stamp is mod 128 ms): not aged (as before) */
			a = 0;
		else if (a < lk_wmin)
			lk_wmin = a;
		if (now - lk_wt >= 2000) {	/* the clocks drift: the base follows the 2-s minimum */
			if (lk_wmin <= 60)
				lk_base = (lk_base + lk_wmin) & 127;
			lk_wmin = 255;
			lk_wt = now;
		}
		*age = a > 40 ? 40 : a;	/* bounded: a late heartbeat moves the meter by at most 40 ms */
	} else
		lk_bok = 0;		/* SLIP uses the word (or an older MAIN): no stamp, "fresh" as before */
	if (lk_ep != v2_epoch) {	/* #1: the paint's start vsync, once a frame */
		lk_ep = v2_epoch;
		p3 = pf_t0 * 3;
		d = (s32)(p3 - lk_vs3);
		if (!lk_vok || d < -60 || d > 600)
			lk_vs3 = p3 - (lk_wl ? 2 : 25);	/* (re)start: on the flag's vsync, else mid-field */
		else {
			if (d > 0)
				lk_vs3 += udiv((u32)d, 50) * 50;	/* whole vsyncs up to the paint start */
			if (lk_wl) {	/* the vsync was <= 1 ms before pf_t0: pull the phase (1/4 of the error) */
				s32 e = (s32)(p3 - 2 - lk_vs3);
				if (e >= 25)
					e -= 50;
				lk_vs3 += e / 4;
			}
		}
		lk_vok = 1;
	}
	lead = lk_lead(now);
	return lead;
}
static s32 master_phase(u32 *bar)
{
	static u32 last_v = 0xFFFFFFFF, t_chg;
	u32 v = u32be(DECK + 0xB8), b = u32be(DECK + 0xB4), now = now_ms(), dt, age;
	s32 lead = lk_prep(now, &age), p;
	int playing = !((ms_flags & 1) && !(ms_flags & 2));
	if (b >= 600 && b <= 12000 && v < 2 * b) {	/* 20..400 BPM */
		if (v >= b)
			v -= b;
		*bar = b;
		if (v != last_v) {
			last_v = v;
			t_chg = now - age;		/* LINKLAT #2: when MAIN sent it (OFF / no stamp: age 0) */
		}
		dt = now - t_chg;
		if (dt > 100 || !playing) {
			dt = 0;
			lead = 0;
		} else if (!v2_lk_on && dt > 50)
			dt = 50;
		p = (s32)(v + dt) + lead;	/* LINKLAT #1: at the display time (lead 0 when OFF) */
		if (v2_lk_on) {
			lk_sa += now - t_chg;
			lk_sl += (u32)(lead + 64);
			lk_n++;
			if (age > lk_amax)
				lk_amax = age;
			v2_lk_age = age;
			v2_lk_lead = (u32)lead;
		}
		while (p < 0)
			p += (s32)b;
		while (p >= (s32)b)
			p -= (s32)b;
		mp_good = p;
		mp_bar_good = b;
		mp_t_good = now;
		return mp_good;
	}
	if (mp_t_good && now - mp_t_good < MP_HOLD && mp_bar_good) {	/* a gap: the last good phase, carried on */
		u32 q = (u32)mp_good + (playing ? now - mp_t_good : 0);
		*bar = mp_bar_good;
		return (s32)(q - udiv(q, mp_bar_good) * mp_bar_good);
	}
	*bar = b;
	return -1;
}
static void fmt_bars(char *q, u32 beats)	/* "07.3": beats 1..256 (64 bars) -> bars.beat, else "--.-" */
{
	if (!beats || beats > 256) {
		q[0] = q[1] = '-'; q[2] = '.'; q[3] = '-';
	} else {
		u32 b = beats - 1, bars = b >> 2;
		q[0] = '0' + udiv(bars, 10); q[1] = '0' + bars % 10; q[2] = '.'; q[3] = '1' + (b & 3);
	}
	q[4] = 0;
}
/* beats from el to this deck's next hot / memory cue (records 1..), 0 = none.
 * V4n31a (#57): the next cue is the earliest ahead in EITHER list -- the marker model (0x32, 18 records: 8 hot +
 * 10 memory) or MAIN's PCO2 cue table (cue_t: every hot / memory cue the export has, also past the model's 10
 * memory slots) -- and the label takes the CDJ-3000's countdown colours (DetailedWaveform/CueCountdown:
 * img_phaseGreenNum / img_phaseSlavePlayerGreenBars #00BE00 = a hot cue next, img_phaseRedNum /
 * ...RedBars #FF0000 = a memory cue next, img_phaseSlaveNum #41A6F5 = none), not the cue's own colour (a dark
 * rekordbox colour / the deck's uninitialised colour bytes made the digits unreadable on black). */
#define C_CD_HOT 0x05E0		/* #00BE00 */
#define C_CD_MEM 0xF800		/* #FF0000 */
#define C_CD_NONE 0x453E	/* #41A6F5 */
static u16 cd_col;	/* the colour of the next cue's countdown */
static u32 own_countdown(u32 el, u32 bpm10, s32 tempo)
{
	u32 best = 0xFFFFFFFF, el150 = udiv(el * 3, 20), gi, cnt, n = 0;
	const volatile u8 *r0;
	int i, hot = 0;
	cd_col = C_CD_NONE;
	for (i = 1; i < N_MARKS; i++) {
		u32 st = u32be(MARKS + 16 * i + 8);
		if (st != 0xFFFFFFFF && st > el150 && st < best) {
			best = st;
			hot = i <= N_HOT;
		}
	}
	if (best != 0xFFFFFFFF)
		best = udiv(best * 20, 3);		/* 1/150 s -> ms */
	for (i = 0; i < cue_n; i++) {			/* MAIN's PCO2 table (ms) */
		u32 ms = cue_t[i].ms;
		if (ms > el + 6 && ms < best) {
			best = ms;
			hot = cue_t[i].hot >= 1 && cue_t[i].hot <= N_HOT;
		}
	}
	if (best == 0xFFFFFFFF)
		return 0;
	r0 = grid_at(el, &gi, &cnt);
	if (r0 && gms(r0 + 20 * (cnt - 1)) >= best) {	/* grid beats in (el, cue] */
		u32 k;
		for (k = gi + 1; k < cnt && gms(r0 + 20 * k) <= best + 5 && n < 300; k++)
			n++;
		n = n ? n : 1;
	} else if (bpm10) {			/* no grid there: the original BPM */
		u32 bo10 = udiv(bpm10 * 10000, (u32)(10000 + tempo));
		n = udiv(udiv(best - el, 10) * bo10, 6000) + 1;
	}
	if (n && n <= 256)
		cd_col = hot ? C_CD_HOT : C_CD_MEM;
	return n;
}
/* one tick column on a meter line: downbeats red and long */
HOT static void pm_tick(int x, int y, int down, int lx)
{
	if (x < lx || x > 780)
		return;
	if (down)
		fill(x, y - 8, 2, 14, C_RED);
	else
		fill(x, y - 5, 2, 8, C_WHITE);
}
static struct { u32 t; const volatile u16 *e; u32 n; int wb, sc; u32 pos16, rate; s32 B; u32 k, mis, bt;
	u32 key, sbt, gt1, gst16, ggn, gbib, b16; } mm;
/* PHASEWAVE (work/phasewave/REVIEW.md): the CDJ-3000 draws the master's grid from its beat-grid entries only
 * (: beats first_visible () .. count - 1, no extrapolation) -- nothing before the first
 * beat / track start, nothing after the last beat. With the master's wave on screen master_mini draws that grid
 * itself, from the entries, on the wave's own column map (mm_tick); master_ticks' mini row is only the no-data
 * fallback (its beats from the bar phase). */
HOT static void mm_tick(int x, int y, int down)
{	/* the 3000's grid image (0x185edf0) under the wave with the widget's 15-px margins (ctor 0x167fc3c): ticks of
	 * 15 px (x 0.667 = 10) above and below the wave, touching it, the same length for every beat; bars red, beats
	 * white at 65 % (0x185f640 = #A6A6A6, as our own band) */
	fill(x, y - 24, 1, 10, down ? C_RED : 0xA534);
	fill(x, y + 15, 1, 10, down ? C_RED : 0xA534);
}
/* the master's beats (k = 0 its current bar's downbeat) as ticks on a line at y, or mini-wave grid ticks */
HOT static void master_ticks(int cx, int lx, int rx, s32 mph, u32 mbar, u32 bl_real, u32 ppb16, int y, int mini)
{
	u32 mbl = mbar >> 2;
	s32 tmin, tmax, k, kmin, kmax;
	if (mph < 0 || !mbl || !bl_real || !ppb16)
		return;
	tmin = -(s32)udiv((u32)(cx - lx) * bl_real * 16, ppb16);
	tmax = (s32)udiv((u32)(rx - cx) * bl_real * 16, ppb16);
	kmin = sdiv(mph + tmin, (s32)mbl);
	kmax = sdiv(mph + tmax, (s32)mbl) + 1;
	for (k = kmin; k <= kmax; k++) {
		s32 t = k * (s32)mbl - mph;
		int x = cx + (int)sdiv(t * (s32)ppb16, (s32)bl_real * 16), down = (k & 3) == 0;
		if (x < lx || x >= rx)
			continue;
		if (mini) {
			/* PHASEWAVE (the 3000's grid image, + the widget's 15-px margins): full
			 * -height 1-px lines under the wave = ticks of 15 px (x 0.667 = 10) above and below it, the same
			 * length for every beat; bars red, beats white at 65 % (#A6A6A6); only the grid's own beats.
			 * (The 3000 drops the beats, bars only, below 0.24 px an entry -- in both rows; our own band
			 * draws every beat, so the master row does too: REVIEW.md D8, later for both rows.) */
			mm_tick(x, y, down);
		} else
			pm_tick(x, y, down, lx);
	}
}
/* WAVEFORM type, the master playing this deck's track: its waveform from our own detail at the master's
 * position (its beat number on our grid + its place in the beat), half height 14 at y cy.
 * V4n31a (#59, deck: the view flickered / dropped to the PHASE lines for single frames; emu trace: around every
 * beat the three inputs -- the bar phase +0xB8, the beat in bar +0xA8 and MAIN's beat number (a slot every 4th
 * publish) -- disagree for 1-3 frames, so the position jumped a beat back and forth, and the per-frame scale
 * (t1 - t0 of that beat's grid records) re-sampled every column):
 * - the beat comes from the bar phase alone (beat in bar = phase / beat length) and is carried on from the last
 *   frame's beat by its change; MAIN's beat number only re-syncs it (a disagreement of > 1 beat, or one that
 *   lasts 30 frames: a seek);
 * - the position never steps back by less than two columns while the master plays;
 * - the scale has a 3 % hysteresis; columns are anchored to the track (raw_col);
 * - an input gap (no beat number, no grid, the w8 buffer being rewritten...) keeps drawing the last good
 *   state carried on in real time for up to 500 ms (MP_HOLD) instead of giving up for a frame. */
/* LINK0B (v4.2, mods/link0b link0btx): with a CDJ-3000 / Cueline master that sends the 0x0b precise position, MAIN
 * stamps each one on arrival and publishes the master's position, extrapolated to its pass as the CDJ-3000 does
 * (: pos + dt x pitch, held once the packet is > 64 ms old), in heartbeat +0x104 (1/8 ms), +0x108
 * (0x0B << 24 | flags << 20 | master << 16 | MAIN ms tick low 16; flags 1 valid, 2 moving, 4 held, 8 stopped) and
 * +0x10C (check << 24 | speed 16.16). The GUI-MAIN clock offset is a min filter over (now - MAIN tick) (leaks 1 ms
 * every 2 s), so a sample's age is known and the position is carried to this frame. NXS2 masters (no 0x0b): flags 0,
 * the beat / heartbeat path below stays as it was. */
static u32 l0b_w1, l0b_w2, l0b_w3, l0b_off, l0b_offt;
static int l0b_offok;
u32 v2_l0b_frames, v2_l0b_bad;	/* frames drawn from the 0x0b position, torn / bad heartbeat samples (mem) */
static int l0b_pos(u32 now, u32 mplayer, u32 *pos8, u32 *sp16)
{
	u32 w1 = u32be(DECK + 0x104), w2 = u32be(DECK + 0x108), w3 = u32be(DECK + 0x10C), d, age, fl, sp;
	if ((w2 >> 24) == 0x0B && ((w1 ^ w2 ^ 0xA5) & 0xFF) == (w3 >> 24)) {
		l0b_w1 = w1;
		l0b_w2 = w2;
		l0b_w3 = w3;
	} else
		v2_l0b_bad++;
	if ((l0b_w2 >> 24) != 0x0B)
		return 0;
	d = (now - l0b_w2) & 0xFFFF;		/* GUI - MAIN, mod 2^16: the clock difference + this sample's delay */
	if (!l0b_offok || ((d - l0b_off) & 0x8000)) {
		l0b_off = d;
		l0b_offok = 1;
		l0b_offt = now;
	} else if (now - l0b_offt > 2000) {
		l0b_off = (l0b_off + 1) & 0xFFFF;
		l0b_offt = now;
	}
	fl = (l0b_w2 >> 20) & 15;
	if (!(fl & 1) || ((l0b_w2 >> 16) & 15) != mplayer)
		return 0;
	age = (d - l0b_off) & 0xFFFF;		/* ms since MAIN's pass */
	if (age > 300)
		return 0;
	sp = l0b_w3 & 0xFFFFFF;
	if (!(fl & 2))
		sp = 0;
	*pos8 = l0b_w1 + ((age * 8 * sp) >> 16);
	*sp16 = sp;
	return 1;
}
u32 v2_mm_hold, v2_mm_resync;	/* frames drawn from the held state, beat re-syncs (mem / HUD) */
u32 v2_sm_t, v2_sm_snap;	/* SMOOTHWAVE: last frame's time, snaps (mem / HUD) */
u32 v2_mm_back, v2_mm_sbl;	/* GRIDBLINK: frames whose position stepped back; the step-back hold's release (ms, 0 off) */
/* V4n32z: master mini-wave column cache in the phase scratch's free rows (Z3 0x0C930000..0x0C9BB800, MEMPROBE: 0
 * writes; the scratch path draws only rows 60..BAND_Y0 = up to 0x0C92FA80): 15 rows x 1024 columns + tags */
#define MMC_N 1024
#define MMC ((u16 *)0x0C940000)
#define MMC_TAG ((u32 *)0x0C950000)
static u32 mmc_key;
#define MM_FADE 38		/* HALFBLUE (B11): the master wave's left-edge fade (60 px on the 3000) */
u32 v2_mm_cols;			/* columns rendered into the cache (mem: the per-frame cost) */
#ifdef V2_GR1METER
#include "gr1meter_ring.inc"	/* DEV: the meter's WAVEFORM on the VDC4 layer GR1 (work/gr1/GR1METER_DONE) */
#endif
#if defined(V2_MSUB) && !defined(V2_GR1METER)
static int g1_half;		/* MSUB: this frame shows the half-column view (master_mini) */
static u32 pf_t0;		/* paint_frame's start after wait_latch (a tentative definition; defined further down) */
#endif
#ifdef V2_GR2METER
/* GR2METER (gr2meter.inc): master_mini's frame context for the GR2 meter prefix, used after hb_frame */
#define GM_ROWS 56			/* screen rows 66..121 above the band */
#if !defined(V2_BDIRECT) || !defined(V2_HWBAND) || defined(V2_GR1METER)
#error "V2_GR2METER needs V2_BDIRECT + V2_HWBAND, without V2_GR1METER"
#endif
static int md_on;		/* METERDIRECT (defined further down) */
/* V4n58j (deck V4n58h: small jumps while OUR deck is paused / cued and the master plays): the GR2 meter (and its
 * whole-column CPU strip) only while this deck plays forward (the band scrolling: its rate > 0); otherwise the CPU
 * strip with MSUB's half-column steps as before V4n58h */
#define GM_ELIG (md_on && !KILL_HB && !UPD_STATE && bp_rate > 0)
static struct {
	int want, w8, cy, sc, kx, rx, cx;
	s32 first, fq4;		/* fq4: the unfloored first column (Q4) */
	const volatile u16 *e;
	u32 n, rkey;
	const volatile u8 *r0;
	u16 blk, tred, tgrey, white;
} gm;
#endif
HOT static int master_mini(int cx, int lx, int rx, s32 mph, u32 mbar, u32 bl_real, u32 bl, int cy)
{
	u32 n = u32be(DECK + 0x74), base = WENT, gi, cnt, b = master_beatnum(), mbl = mbar >> 2, z = zkey();
	const volatile u8 *r0 = grid_at(u32be(DECK + 0x78), &gi, &cnt);
	const volatile u16 *e = 0;
	u32 t0 = 0, t1 = 0, mms, frac, k = 0, now = now_ms(), pos16, w8 = 0, gn = 0, t1f = 0, st16 = 0, dkey;
	s32 first, B;
	int x, sc, sh = ZSH(z), ok = 1, pin = 0;
	int wb = wblue, playing = !((ms_flags & 1) && !(ms_flags & 2));
	u32 l0b8 = 0, l0b_sp = 0, beat16 = 0;	/* LINK0B: the master's 0x0b position (1/8 ms) / speed, the beat path's pos16 */
	int l0b_on = 0;
	if (mph < 0 || !mbl || !(ms_flags & 1))	/* PHASEWAVE: beat 0 = the lead-in before the first beat */
		ok = 0;
#ifdef V3E2
	else if (!(ms_flags & 4)) {	/* V3e2 (W8): another track -- MAIN's w8fetch put the master's PWV5 + PQT2 grid at
				 * 0x0CA00000 (mods/w8fetch/README.md); its key names the master player */
		const volatile u8 *g = W8BUF + 0x80000;
		u32 tnl;
		w8 = 1;
		if (u32be(W8BUF) != 0x57384D31 || u32be(W8BUF + 4) != 1 || (u32be(W8BUF + 8) >> 24) != u32be(DECK + 0xA4))
			ok = 0;
		else {
			n = u32be(W8BUF + 0x10) >> 1;
			t1f = u32be(g + 28);
			tnl = u32be(g + 36);
			gn = u32be(g + 40);
			if (!n || n > 0x40000 || gn < 2 || gn > 8192 || tnl <= t1f)
				ok = 0;
			else {
				st16 = udiv((tnl - t1f) * 16, gn - 1);	/* beat length x 16 (constant-tempo grids exact) */
				e = (const volatile u16 *)(W8BUF + 0x40);
			}
		}
	}
#endif
	else {
#ifndef V3D_FORCE_SAME
		if (!(ms_flags & 4))
			ok = 0;
#endif
		if (det_blue && WBLUE)
			base = WBLUE;
		if (!r0 || !base || !n || n > 0x200000)
			ok = 0;
		else
			e = (const volatile u16 *)((base & 0x1FFFFFFF) | 0x20000000);
	}
	/* PHASEWAVE: the data's identity (master player, w8 key + rbid + valid, or this deck's track) */
	dkey = w8 ? (u32be(W8BUF) == 0x57384D31 && u32be(W8BUF + 4) == 1 ? u32be(W8BUF + 8) ^ u32be(W8BUF + 0x0C) : 0) :
		    0x80000000u ^ u32be(DECK + 0xA4) << 24 ^ u32be(DECK + 0x60);
	if (!dkey || (mm.key && mm.key != dkey)) {
		mm.bt = 0;			/* another master / track: no beat carry, no kept scale / position */
		mm.sc = 0;
		mm.sbt = 0;
	}
	if (ok) {	/* the beat: carried on by the bar phase, MAIN's number re-syncs */
		k = udiv((u32)mph, mbl);
		if (k > 3)
			k = 3;
		B = (s32)b;
		if (mm.bt && now - mm.bt < MP_HOLD) {
			u32 dk = (k - mm.k) & 3;
			s32 pred = mm.B + (dk == 3 ? -1 : (s32)dk), d = (s32)b - pred;
			if (d == 0)
				mm.mis = 0;
			else if (d >= -1 && d <= 1 && ++mm.mis < 30)
				B = pred;
			else {
				mm.mis = 0;
				v2_mm_resync++;
			}
		}
		mm.B = B;
		mm.k = k;
		mm.bt = now;
		/* PHASEWAVE: the lead-in (beat 0) and the last beat (B = count) are drawn too -- before, they dropped
		 * the wave (500 ms later the grid-only view, its ticks extrapolated past the track's ends) */
		if (B < 0)
			ok = 0;
		else if (w8 ? (u32)B > gn : (u32)B > cnt) {	/* past the grid (a master still counting at its end,
								 * e.g. a CDJ-3000): pinned to the end, not dropped */
			B = (s32)(w8 ? gn : cnt);
			pin = 1;
		}
	}
	if (ok) {
		if (w8) {
			u32 bl16 = st16 >> 4;
			t0 = B ? t1f + (((u32)(B - 1) * st16) >> 4) : (t1f > bl16 ? t1f - bl16 : 0);
			t1 = B ? t0 + bl16 : t1f;
		} else if (!B) {			/* the lead-in: a beat before the first */
			u32 g0 = gms(r0), g1 = cnt > 1 ? gms(r0 + 20) : g0;
			t1 = g0;
			t0 = g0 > g1 - g0 ? g0 - (g1 - g0) : 0;
		} else if ((u32)B == cnt) {		/* past the last beat: its length again */
			t0 = gms(r0 + 20 * (B - 1));
			t1 = t0 + (cnt > 1 ? t0 - gms(r0 + 20 * (B - 2)) : 500);
		} else {
			t0 = gms(r0 + 20 * (B - 1));
			t1 = gms(r0 + 20 * B);
		}
		if (w8) {	/* the grid for mm's ticks (kept for a held frame) */
			mm.gt1 = t1f;
			mm.gst16 = st16;
			mm.ggn = gn;
			mm.gbib = u16be(W8BUF + 0x80000 + 24);
		}
		frac = (u32)mph - k * mbl;
		frac = frac >= mbl || pin ? 255 : udiv(frac * 256, mbl);
		mms = t0 + (((t1 > t0 ? t1 - t0 : 0) * frac) >> 8);
		pos16 = udiv(mms * 12, 5);		/* track ms -> entries (150 / s) x 16 */
		if (pos16 > n * 16)			/* PHASEWAVE: the master never scrolls past its track's end (the
							 * user's rig: a CDJ-3000 master at its END kept scrolling) */
			pos16 = n * 16;
		beat16 = pos16;
		if (l0b_pos(now, u32be(DECK + 0xA4), &l0b8, &l0b_sp)) {	/* LINK0B: the master's own position */
			s32 ld = lk_lead(now);	/* LINKLAT #1: carried on from now to the display time (0 when OFF), x its
						 * speed (0 when held / stopped) -- the 0x0b sample's own age is l0b_pos's */
			if (ld > 0)
				l0b8 += ((u32)ld * 8 * l0b_sp) >> 16;
			else if (ld < 0) {
				u32 bk = ((u32)-ld * 8 * l0b_sp) >> 16;
				l0b8 = l0b8 > bk ? l0b8 - bk : 0;
			}
			pos16 = udiv(l0b8 * 3, 10);	/* 1/8 ms -> entries (150 / s) x 16 */
			if (pos16 > n * 16)
				pos16 = n * 16;
			l0b_on = 1;
			v2_l0b_frames++;
		}
		/* V4n32z: the CDJ-3000's master waveform widget (): the local zoom x the BPM ratio
		 * r (clamped 0.2..5), so a master beat spans as many px as one of our beats: entries per column x 16 =
		 * 16 x 1.6 x 2^sh x (its track beat / our track beat) (was: real-time scale, beats apart off sync) */
		{
			u32 T = t1 > t0 && t1 - t0 < 3000 ? t1 - t0 : mbl;
			if (T * 5 < bl)
				T = udiv(bl, 5);
			if (T > 5 * bl)
				T = 5 * bl;
			sc = (int)udiv((u32)SHL(2048, sh) * T * 2 + 5 * bl, 10 * bl);	/* V4n58h: ROUNDED (deck V4n58g: the
						 * closest zoom drifted: 204.8 truncated to 204 = 0.4 %, ~1.5 px at the strip's
						 * ends; rounded 205 = 0.1 %). METERALIGN: x 256 -- the integer x 16
						 * scale was up to 7 % off at the deepest zoom (12.8 = 13): the master's beats
						 * drifted off ours across the meter (deck V4n45, SYNC, max zoom) */
		}
		(void)bl_real;
		if (sc < 128)	/* V4n32: zoom 6 = 12.8 (x 16) */
			sc = 128;
		if (mm.sc && mm.e == e && (u32)(sc > mm.sc ? sc - mm.sc : mm.sc - sc) * 256 <= (u32)mm.sc)
			sc = mm.sc;			/* within 0.4 % (METERALIGN; was 3 %): the kept scale */
		if (!l0b_on && playing && mm.t && mm.e == e && now - mm.t < MP_HOLD && pos16 < mm.pos16 &&
		    mm.pos16 - pos16 < ((u32)sc >> 3) + (t1 > t0 && t1 - t0 < 3000 ? udiv((t1 - t0) * 3, 5) : 0) &&
		    (!v2_mm_sbl || !mm.sbt || now - mm.sbt < v2_mm_sbl)) {
			pos16 = mm.pos16;		/* no step back of up to 1/4 beat (+2 columns) while it plays: a
							 * late +0xB8 snaps the phase back; the master only moves on.
							 * GRIDBLINK (deck V4r7: the grey ticks blinked): PHASEWAVE's 150-ms
							 * release of this hold let the view step back and forth by a column
							 * -- invisible in the wave, a blink on the 1-px ticks that now ride
							 * the wave's position. Held again for as long as it lasts (V4n41 and
							 * before); v2_mm_sbl (ms, 0 = off) keeps the release for an A/B */
			if (!mm.sbt)
				mm.sbt = now | 1;
		} else
			mm.sbt = 0;
		mm.t = now;
		mm.key = dkey;
		mm.e = e;
		mm.n = n;
		mm.wb = w8 ? 0 : base == WBLUE;
		mm.sc = sc;
		if (playing && mm.pos16 && pos16 < mm.pos16 && mm.pos16 - pos16 < 0x10000)
			v2_mm_back++;		/* GRIDBLINK: drawn position stepped back while playing (mem / HUD) */
		mm.pos16 = pos16;
		{	/* entries x 16 per real ms, 16.16: its track beat over its real beat */
			u32 tb = t1 > t0 && t1 - t0 < 3000 ? t1 - t0 : mbl;
			mm.rate = udiv(udiv(tb * 12 << 12, 5), mbl) << 4;
			mm.b16 = udiv(tb * 12, 5);	/* SMOOTHWAVE: one beat, entries x 16 */
			if (l0b_on)
				mm.rate = udiv(l0b_sp * 12, 5);	/* LINK0B: speed 16.16 x 2.4 */
		}
	} else {
		/* PHASEWAVE: no hold over another master / track or a w8 buffer being refilled (the held columns
		 * would be re-read from the new stream at the old position) */
		if (!mm.t || now - mm.t >= MP_HOLD || !mm.e || mm.key != dkey)
			return 0;
		e = mm.e;
		n = mm.n;
		sc = mm.sc;
		pos16 = mm.pos16 + (playing ? ((now - mm.t) * mm.rate) >> 16 : 0);	/* < 500 ms x < 2^20 */
		if (pos16 > n * 16)		/* PHASEWAVE: never past the track's end */
			pos16 = n * 16;
		v2_mm_hold++;
	}
	{	/* SMOOTHWAVE (deck V4n44: "smoother, as the main band before"): the view is dead-reckoned every frame
		 * from the master's rate (its track beat over its real beat = BPM x pitch, mm.rate) and pulled toward
		 * the LINK position (beat number + bar phase, pos16 above) by a gentle PLL (1/16 of the error a frame),
		 * never stepping back while the master plays (x 16 fixed point); it snaps on a real jump (> 1 beat off: cue, seek, load),
		 * another master / track (mm.key), a paused master or the first frame. Wave and ticks both use it
		 * (first below), so they move together. */
		static u32 sb8, slast, skey;
		static int son;
		u32 tgt8 = pos16 << 4, b8 = (mm.b16 ? mm.b16 : 1200) << 4;
		if (l0b_on)
			sb8 = tgt8;		/* LINK0B: the CDJ-3000 draws its getter's value as is (no PLL) */
		else if (son && skey == mm.key && playing) {
#if defined(V2_GR1METER) || defined(V2_MSUB)	/* MSUB: also without the GR1 layer (CPU strip) */
			/* GR1METER (deck probe g2: "a few jumps"): the step from the paint's own clock (pf_t0, just after
			 * wait_latch = vsync-aligned) counted in whole vsyncs (t3 = ms x 3, a vsync = 50), so the per-frame
			 * step no longer jitters with where in the frame master_mini happens to run */
			static u32 t3;
			u32 vs, est;
			if (pf_t0 * 3 - t3 > 300 && t3 - pf_t0 * 3 > 300)
				t3 = pf_t0 * 3 - 50;	/* lost lock (> 100 ms): restart */
			vs = (s32)(pf_t0 * 3 - t3) > 25 ? udiv(pf_t0 * 3 - t3 + 25, 50) : 0;
			if (vs > 6)
				vs = 6;
			t3 += vs * 50;
			est = sb8 + ((vs * udiv(mm.rate * 50, 3)) >> 12);
#else
			u32 dt = now - v2_sm_t > 100 ? 100 : now - v2_sm_t;	/* ms; x rate (< 2^20) fits */
			u32 est = sb8 + ((dt * mm.rate) >> 12);
#endif
			s32 err = (s32)(tgt8 - est);
			if (err > (s32)b8 || err < -(s32)b8) {
				est = tgt8;
				v2_sm_snap++;
			} else
				est = (u32)((s32)est + (err >> 4));
			if (est < slast && slast - est < b8)
				est = slast;		/* never back while it plays (a correction only slows it) */
			sb8 = est;
		} else {
			sb8 = tgt8;
			v2_sm_snap++;
		}
		if (sb8 > (n * 16) << 4)
			sb8 = (n * 16) << 4;
		slast = sb8;
		skey = mm.key;
		son = 1;
		v2_sm_t = now;
		pos16 = sb8 >> 4;
	}
#ifdef V2_USBLOG
	if ((v3e_b & 0x8000) && ((v3e_b >> 10) & 3) == 3) {	/* LINK0B DEV (TEST LOG = RED): the meter's drawn position
								 * for the emulator's error measurement (work/link0b), TX
								 * frame +0xFC0 -> MAIN link0btx -> UDP 50097 */
		static u32 mtr_seq;
		volatile u32 *t = (volatile u32 *)0x3C27CFC0;
		mtr_seq = (mtr_seq + 1) & 0x7FFFFFFF;
		t[1] = mtr_seq;
		t[2] = udiv(pos16 * 10, 3);
		t[3] = now & 0x7FFFFFFF;
		t[4] = l0b_off | (u32)l0b_on << 16 | (u32)(l0b_offok != 0) << 17;
		t[5] = udiv(beat16 * 10, 3);
		t[6] = l0b_on ? l0b8 & 0x7FFFFFFF : 0;
		t[0] = 0x4D545231;		/* 'MTR1' */
		t[7] = mtr_seq;
	}
#endif
	wblue = mm.wb;
#if defined(V2_GR1METER) || defined(V2_MSUB)	/* MSUB: also without the GR1 layer (CPU strip) */
	/* MSUB (deck m1: the residual tick / white blink at the small zooms, which the band fixed with its phase
	 * rings): the position in HALF columns; an odd half shows every column as the blend of columns a and a + 1
	 * (ph_blend at 1/2, the band's weights) and each tick at its own half-column place -- on GR1 the half ring,
	 * on the CPU strip the same blend */
	{
		u32 q = udiv(pos16 * 32, (u32)sc);
#ifdef V2_GR1PRECOMP
		g1_half = 0;
#else
		g1_half = (int)(q & 1);
		if (BARS_ONLY_SC256((u32)sc))
			g1_half = 0;	/* V4n59h (deck V4n59g: zooms 1-2 "the waveform flickers a little"): zoomed out the
					 * half-phase view (a 1/2 blend of columns a, a + 1) alternated with whole columns
					 * at the slow step rate -- whole columns there, as the band (whole pixels, V4n32z) */
#endif
#ifdef V2_GR2METER
		if (GM_ELIG)
			g1_half = 0;	/* V4n58h: whole columns as the GR2 prefix (and the band), so a GR2 <-> CPU switch
					 * is pixel-identical (emu: only the half-blend frames differed) */
#endif
		first = (s32)(q >> 1) - (cx - WAVE_X0);
	}
#else
	first = (s32)udiv(pos16 * 16, (u32)sc) - (cx - WAVE_X0);	/* the absolute column at x WAVE_X0 */
#endif
	dmark(cy - 14, 29);
	{	/* V4n32z (deck V4n31a: CPU 87 % with the WAVEFORM meter + a LINK master): since V4n31a a column is an
		 * ABSOLUTE column of the master's track (raw_col), so its 15 half-height colours are cached by column
		 * (MMC, 1024 columns, free SDRAM Z3 of the phase scratch) -- only the columns entering per frame run
		 * col_prof (3 x raw_col + the look); the rows are block-copied from the cache. The key drops the
		 * cache on any change of data / scale / look (a sampled checksum catches MAIN rewriting the buffer). */
		u32 key, ck = 0, j, st = (n >> 5) | 1;
		int d, x0;
		for (j = 0; j < n; j += st)
			ck = ck * 33 + e[j];
		key = hmix(hmix(hmix(hmix((u32)e, n), (u32)sc), (u32)wblue | (u32)wave_type << 1 | (u32)day << 4 |
				 (u32)day_full << 5 | (u32)wc_bg << 8), ck) | 1;
		if (key != mmc_key) {
			for (j = 0; j < MMC_N; j++)
				MMC_TAG[j] = 0x80000000u;
			mmc_key = key;
		}
#ifdef V2_GR2METER
		if (GM_ELIG && lx + MM_FADE < rx) {	/* the GR2 prefix (gm_after, after hb_frame) */
			int iw = in_wave;
			gm.e = e; gm.n = n; gm.sc = sc; gm.w8 = (int)w8; gm.cy = cy; gm.first = first; gm.r0 = r0;
			gm.fq4 = (s32)udiv(pos16 * 256, (u32)sc) - (cx - WAVE_X0) * 16;
			gm.kx = lx + MM_FADE; gm.rx = rx; gm.cx = cx;
			gm.tred = dm(C_RED); gm.tgrey = dm(0xA534);
			in_wave = 0;
			gm.blk = dm(C_BLACK); gm.white = dm(C_WHITE);
			in_wave = iw;
			gm.rkey = hmix(hmix(hmix(hmix(hmix(mmc_key, w8), mm.gt1 ^ mm.gst16 << 8), mm.ggn ^ mm.gbib << 16),
					    (u32)r0) ^ (u32)cy << 24, ld_t0 ^ (u32)day << 1 ^ (u32)day_full << 2);
			gm.want = 1;
		}
#endif
#ifdef V2_GR1METER
		int g1x = rx;		/* the CPU draws x lx..g1x; GR1 shows g1x..rx through the key */
#ifdef V2_GR1PRECOMP
		int g1rx = rx < G1P_XR ? rx : G1P_XR;
#else
		int g1rx = rx;
#endif
		{
			struct g1ctx c;
			c.e = e; c.n = n; c.sc = sc; c.w8 = (int)w8; c.cy = cy; c.first = first; c.r0 = r0;
			{ int iw = in_wave; in_wave = 0; c.blk = dm(C_BLACK); in_wave = iw; }
			if (g1_frame(&c, lx + MM_FADE, g1rx, hmix(hmix(hmix(hmix(hmix(mmc_key, w8), mm.gt1 ^ mm.gst16 << 8),
						mm.ggn ^ mm.gbib << 16), (u32)r0) ^ (u32)cy << 24, ld_t0)))
				g1x = lx + MM_FADE;
		}
#ifdef V2_GR1PRECOMP
#define MM_RX rx
#else
#define MM_RX g1x
#endif
#else
#define MM_RX rx
#endif
		for (x = lx; x < MM_RX + 1; x++) {	/* MSUB: + the column right of the last (the half blend) */
			s32 a = first + (x - WAVE_X0);
			u32 sl = (u32)a & (MMC_N - 1);
			if (MMC_TAG[sl] != (u32)a) {
				u16 cb[HALF + 2];
				int top = col_prof(x - WAVE_X0, e, n, first, sc, cb);
				for (d = 0; d <= 14; d++) {
					int dd = (d * WAVE_H) / 14;
					MMC[d * MMC_N + sl] = dd <= top ? cb[dd] : wc_bg;
				}
				MMC_TAG[sl] = (u32)a;
				v2_mm_cols++;
			}
		}
#if defined(V2_GR1METER) || defined(V2_MSUB)	/* MSUB: also without the GR1 layer (CPU strip) */
		if (g1_half)		/* MSUB: the half-column view, blended per pixel (15 rows, mirrored) */
			for (x = lx; x < MM_RX; x++) {
				u32 sl = (u32)(first + (x - WAVE_X0)) & (MMC_N - 1), sl1 = (sl + 1) & (MMC_N - 1);
				for (d = 0; d <= 14; d++) {
					u16 v = ph_blend(MMC[d * MMC_N + sl], MMC[d * MMC_N + sl1], 2);
					fb[(cy + d) * W + x] = v;
					fb[(cy - d) * W + x] = v;
				}
			}
		else
#endif
		for (x0 = lx; x0 < MM_RX;) {	/* runs that do not wrap in the cache */
			u32 sl = (u32)(first + (x0 - WAVE_X0)) & (MMC_N - 1);
			int k = MM_RX - x0;
			if ((int)(MMC_N - sl) < k)
				k = (int)(MMC_N - sl);
			for (d = 0; d <= 14; d++) {
				cp16(fb + (cy + d) * W + x0, MMC + d * MMC_N + sl, k);
				if (d)
					cp16(fb + (cy - d) * W + x0, MMC + d * MMC_N + sl, k);
			}
			x0 += k;
		}
		{	/* A14 (owner's deck photo, LIGHT MODE): the tick lanes of the CPU-drawn part get the colour the GR1
			 * layer gives them (g1_col's c->blk). Only the wave's 29 rows were painted here, so in LIGHT the
			 * lanes showed the light panel for the first MM_FADE px and black from there on. Rows as mm_tick /
			 * g1_col: cy - 26 .. cy - 15 and cy + 15 .. cy + 25. Normal and FULL: the colour already there. */
			int iw = in_wave;
			u16 lane;
			in_wave = 0; lane = dm(C_BLACK); in_wave = iw;
			if (MM_RX > lx) {
				fill(lx, cy - 26, MM_RX - lx, 12, lane);
				fill(lx, cy + 15, MM_RX - lx, 11, lane);
			}
		}
		/* HALFBLUE (B11): the CDJ-3000's master waveform widget::GradationShader (: a 60-px
		 * wide child at the widget's left, ColourGradient::horizontal(0x67C2950 @0 -> 0x67C29F0 @60) 0x1D17070):
		 * the master wave fades in over its first 60 px -- x 0.625 here (the UI scaling rule) = 38 px */
		{	/* PHASEWAVE: the master's grid from its entries on the wave's column map (the 3000: 
			 * 0x185edf0 -- first beat >= the window's start .. the last beat, nothing extrapolated): no tick
			 * before the track's first beat or after its last, and the ticks never drift off the wave */
			s32 c0 = first + (lx - WAVE_X0);
#if defined(V2_GR1METER) || defined(V2_MSUB)	/* MSUB: also without the GR1 layer (CPU strip) */
#define G1TCOL(c2) (g1_half ? ((int)(c2) - 1) >> 1 : (int)((c2) >> 1))	/* MSUB: the tick's column in this view */
#else
#define G1TCOL(c2) (int)((c2) >> 1)
#endif
			u32 ms0 = c0 > 0 ? udiv((u32)c0 * (u32)sc * 5, 192) : 0, j, t;
			if (w8 && mm.ggn >= 2 && mm.gst16) {
				j = ms0 > mm.gt1 ? udiv((ms0 - mm.gt1) * 16, mm.gst16) : 0;
				for (; j < mm.ggn; j++) {
					t = mm.gt1 + ((j * mm.gst16) >> 4);
					x = WAVE_X0 + G1TCOL(udiv(udiv(t * 12, 5) * 32, (u32)sc)) - first;
					if (x >= MM_RX)
						break;
					if (x >= lx && (((mm.gbib + 3 + j) & 3) == 0 || !BARS_ONLY_SC256((u32)sc)))	/* BANDFLICK */
						mm_tick(x, cy, ((mm.gbib + 3 + j) & 3) == 0);
				}
			} else if (!w8 && r0) {
				const volatile u8 *g0 = grid_at(ms0, &gi, &cnt);
				for (j = gi; g0 && j < cnt; j++) {
					t = gms(g0 + 20 * j);
					x = WAVE_X0 + G1TCOL(udiv(udiv(t * 12, 5) * 32, (u32)sc)) - first;
					if (x >= MM_RX)
						break;
					if (x >= lx && (u16be(g0 + 20 * j) == 1 || !BARS_ONLY_SC256((u32)sc)))	/* BANDFLICK */
						mm_tick(x, cy, u16be(g0 + 20 * j) == 1);
				}
			}
		}
		for (x = lx; x < lx + MM_FADE && x < rx; x++) {
			u32 f = udiv((u32)(x - lx) * 16 + 8, MM_FADE);
			u16 *p = fb + (cy - 14) * W + x;
			for (d = 0; d < 29; d++, p += W)
				*p = mix(wc_bg, *p, f);
		}
#ifdef V2_GR1METER
#ifdef V2_GR1PRECOMP
		if (g1x < rx)
			for (d = G1_Y; d < G1_Y + G1_H; d++)
				fill16(fb + d * W + g1x, (rx < G1P_XR ? rx : G1P_XR) - g1x, 0x0001);
#else
		if (g1x < rx)		/* the key hole over GR1 (the playhead is drawn over it by phase_meter) */
			for (d = G1_Y; d < G1_Y + G1_H; d++)
				fill16(fb + d * W + g1x, rx - g1x, 0x0001);
#endif
#endif
#undef MM_RX
	}
	wblue = wb;
	return 1;
}
static void phase_meter(u32 loaded, u32 el, s32 tempo, u32 own_master, u32 mplayer, s32 mph, u32 mbar, int wtype,
			u32 beat, u32 mbeat)
{
	char buf[8];
	int cx = WAVE_X0 + V2_PLAYHEAD, lx = loaded && mplayer ? 230 : 168;
	u32 bl = 0, gi = 0, cnt = 0, bl_real, own_cd;
	const volatile u8 *r0 = loaded ? grid_at(el, &gi, &cnt) : 0;
	fill(0, 60, W, BAND_Y0 - 60, C_BLACK);
	if (r0) {				/* this deck's beat length at el (track ms), real-time length */
		u32 k = gi + 1 < cnt ? gi : gi - (gi > 0);
		if (k + 1 < cnt)
			bl = gms(r0 + 20 * (k + 1)) - gms(r0 + 20 * k);
		if (bl < 150 || bl > 3000)
			bl = 0;
	}
	{	/* our real beat: the BPM on screen (+0x68, x10, pitch / sync applied; +0x64 is not the pitch
		 * under SYNC -- it holds the original BPM then) */
		u32 b10 = u32be(DECK + 0x68);
		bl_real = loaded && b10 >= 200 && b10 < 10000 ? udiv(600000, b10) :
			  bl ? udiv(bl * 10000, (u32)(10000 + tempo)) : mph >= 0 ? mbar >> 2 : 500;
	}
	if (!bl_real)
		bl_real = 500;
	/* labels: the master's countdown (this deck's own when it is the master) and this deck's */
	cd_col = C_CD_NONE;
	own_cd = loaded ? own_countdown(el, u32be(DECK + 0x68) < 10000 ? u32be(DECK + 0x68) : 0, tempo) : 0;
	/* V3e1 (audit M3): orange = the master's countdown when another deck is master, else "--.-"; blue =
	 * this deck's own, in the colour of its next cue (hot cue colour / memory red / blue) */
	fmt_bars(buf, mplayer ? ((ms_flags & 1) && ms_cd && ms_cd < 0x1FF ? ms_cd : 0) : 0);
	(void)own_master;
	text_r(&f_s, 108, 77, buf, C_PHO, C_BLACK);
	text(&f_s, 112, 77, "Bars", C_PHO, C_BLACK);
	fmt_bars(buf, own_cd);
	text_r(&f_s, 108, 97, buf, cd_col, C_BLACK);
	text(&f_s, 112, 97, "Bars", cd_col, C_BLACK);	/* 3000: img_phaseSlavePlayer{,Green,Red}Bars */
	if (loaded && mplayer) {	/* as stock: MASTER PLAYER n left of the master row */
		buf[0] = '0' + mplayer; buf[1] = 0;
		text_r(&f_s, 204, 64, "MASTER", C_PHO, C_BLACK);
		text_r(&f_s, 204, 78, "PLAYER", C_PHO, C_BLACK);
		fill(207, 68, 17, 22, C_PHO);
		text_c(&f_s, 215, 72, buf, C_BLACK, C_PHO);
	}
	if (wtype == 2) {	/* V3e1: 4 BARS, the NXS2's classic meter (user): two rows of four boxes, the
				 * master's beat outlined in the orange row, this deck's beat filled in the blue
				 * row (red on the downbeat, orange while this deck is the master) */
		int i;
		for (i = 0; i < 4; i++) {
			int bx = 230 + i * 86;
			frame(bx, 79, 80, 11, 1, C_PHO);
			frame(bx, 99, 80, 11, 1, C_PHB);
			if (loaded && mbeat == (u32)i + 1)
				frame(bx - 1, 78, 82, 13, 2, i == 0 ? 0xF800 : 0xFD20);
			if (loaded && beat && ((beat - 1) & 3) == (u32)i)
				fill(bx + 1, 100, 78, 9, i == 0 ? 0xB800 : own_master ? 0xCA60 : C_PHB);
		}
		return;
	}
	if (wtype == 1 && !(mplayer && mph >= 0))
		wtype = 0;	/* V3e1 (user: "the meter is gone"): WAVEFORM needs a master's waveform; without
				 * another deck as master it shows the PHASE rows (own grid ticks) instead of nothing */
	if (!wtype) {		/* PHASE: two lines, the master's beats on the orange one, ours on the blue one */
		/* PHASESCALE (user, gig 2026-11-18): the band's scale, following the zoom, as the WAVEFORM view (METER_FULL:
		 * a beat spans as many px as the band's) -- was a fixed 100 px/s, so the ticks met the band's only at the
		 * centre. ppb16 = px per beat x 16 = 1500 x beat / (1000 << sh) (150 entries / s, 1.6 x 2^sh a column) */
		u32 bt = bl ? bl : bl_real, ppb16 = udiv(1500 * bt, SHL(1000u, ZSH(zkey())));
		fill(lx, 84, 632 - lx, 2, C_PHO);
		fill(lx, 104, 632 - lx, 2, C_PHB);
		if (r0 && bl && ppb16) {
			u32 k = gi > 40 ? gi - 40 : 0;
#if 1	/* V4n58i: unconditional (safe without GR2METER) */
			/* V4n58i (deck V4n58h: small jumps when this deck is the master): with no remote master, our ticks
			 * at the band's own columns (bcol of the beat's entry, as the band's grid) minus the band's column
			 * at the playhead (its position carried to now, as el_m) -- locked to the band, no ms / px rounding */
			s32 lb = -1;
			int lsh = ZSH(zkey());
			if (!mplayer && bp_rate > 0 && now_ms() - bp_t < 100)
				lb = bcol((s32)((bp_q8 + (u32)bp_rate * (now_ms() - bp_t)) >> 8), lsh);
#endif
			for (; k < cnt && k < gi + 42; k++) {
				s32 dt = (s32)(gms(r0 + 20 * k) - el);
				int x = cx + (int)sdiv(dt * (s32)ppb16, (s32)bl * 16);	/* track ms -> the band's px */
#if 1	/* V4n58i: unconditional */
				if (lb >= 0)
					x = cx + (int)(bcol((s32)udiv(gms(r0 + 20 * k) * 3, 20), lsh) - lb);
#endif
				if (x > 630)
					break;
				if (x >= lx)
					pm_tick(x, 104, u16be(r0 + 20 * k) == 1, lx);
			}
		}
		if (mplayer)
			master_ticks(cx, lx, 632, mph, mbar, bl_real, ppb16, 84, 0);	/* a master beat = one of ours */
		fill(cx - 1, 76, 2, 34, C_WHITE);
		return;
	}
	/* WAVEFORM: the master's mini-waveform (or its grid) from lx to the band's right end */
	if (mplayer && mph >= 0) {
		int rx = WAVE_X0 + WAVE_N, cy = 92;
		wave_on();
		u32 bt = bl ? bl : bl_real, z = zkey();
		int sh = ZSH(z);
		u32 ppb16 = udiv(1500 * bt, SHL(1000u, sh));	/* the band: 150 entries / s, 1.6 x 2^sh a column (V4n27z) */
		if (!KILL_MW && master_mini(cx, lx, rx, mph, mbar, bl_real, bt, cy))	/* V4n36 trace: kill switch */
			v2_pm_same++;		/* PHASEWAVE: with its grid ticks (from the grid's entries) */
		else {
			fill(lx, cy, rx - lx, 1, 0x4208);	/* no master waveform here: its beat grid alone */
			v2_pm_grid++;
			master_ticks(cx, lx, rx, mph, mbar, mbar >> 2, ppb16, cy, 1);	/* V4n32z: a master beat = one of ours */
		}
		wave_off();
	}
	fill(cx - 1, 66, 2, 52, C_WHITE);
}

static void popup(int force);
static void popup_sync(void);
static int pace_on;	/* V3rc8: fixed cadence while SMOOTH+ composes the player (set by paint_frame) */
u32 v2_a60_drop, v2_a60_over;	/* V3rc8t: 60-fps frames over budget (HUD A) */
static u32 pf_t0;	/* V3rc8t: this paint's start after wait_latch (its busy time, AUTO60) */
#define MD_Y0 60	/* METERDIRECT: the meter strip's first row */
#ifdef V2_BDIRECT
/* V3rc8r (re/PANEL_FW_MINING.md idea 1, user OK): the waveform band changes every frame while playing, so
 * composing it into the canvas and then DMA-copying 184 rows into the GR3 buffer did the work twice. With
 * BDIRECT the band and its layers (pads, MASTER label, beat numbers, ZOOM label) are drawn straight into the
 * GR3 buffer about to latch (safe: paint_frame's wait_latch ran first -- the same window the canvas copy
 * uses), and the canvas copy / self-heal skip the band rows. Only on the player, playing a loaded track,
 * with no pop-up and no stock overlay; otherwise (and on the way back) the canvas path as before. */
static int bd_ok, bd_on, bd_was;
/* METERDIRECT: with bd_on the meter strip (rows MD_Y0..BAND_Y0) is drawn straight into the same GR3 buffer every
 * frame (no canvas clear + DMA copy of its 62 rows); the canvas copy / self-heal / late-window rectangle skip it */
static int md_on;
static u16 *bd_phys;
#else
#define bd_on 0
#define md_on 0
#endif
#if defined(V2_SPLIT60) || defined(V2_AUTO60)
/* V3rc8 TEST: the band every frame at 60 Hz, the phase meter and the deck area on alternate frames (30 Hz each);
 * the SMOOTH+ canvas keeps what a frame does not redraw */
static int sp_par;
#ifdef V2_AUTO60
static int fps60;	/* V3rc8t: 60 fps while the frames fit one vsync (v2_paint) */
#define SPLIT_ON fps60
#else
#define SPLIT_ON pace_on
#endif
#else
#define SPLIT_ON 0
#define sp_par 0
#endif
#ifdef V2_HWPROBE
static void hwp_paint(void);
#endif
#ifdef V2_HWS2
static void hws_paint(void);
#endif
static void zoom_label(void)
{
	int g = GA_MODE;	/* TOUCH: the 3000's img_zoomGrid -- the active one boxed blue (a tap toggles, MAIN zone 15/5) */
	fill(708, 296, 86, 18, C_BLACK);
	frame(g ? 762 : 712, 297, g ? 32 : 40, 15, 1, C_SEL);
	text_c(&f_s, 732, 297, "ZOOM", g ? C_GREY : C_SEL, C_BLACK);
	text(&f_s, 754, 297, "-", C_GREY, C_BLACK);
	text_c(&f_s, 778, 297, "GRID", g ? C_SEL : C_GREY, C_BLACK);
}
#ifdef V2_HWBAND
#include "hwband.inc"	/* V4 Fase 2: the band on the VDC4 layer GR2 (re/V3_PROGRESS.md "V4 HWBAND") */
#ifdef V2_GR2METER
#include "gr2meter.inc"	/* the LINK meter WAVEFORM baked into GR2 (prefix rows above the band) */
#endif
#ifdef V2_GR1METER
#include "gr1meter_regs.inc"	/* DEV: GR1 meter registers (on / scroll / off) */
#endif
#endif
static void player(void)
{
	char buf[16];
	const volatile u8 *slot0 = MODEL + 0x54;
#if defined(V2_SPLIT60) || defined(V2_AUTO60)
	sp_par ^= 1;
#endif
	{	/* V3rc5: the MENU pop-up (LOAD PREVIOUS TRACK) opened / closed: everything under it redraws */
		static int last_pop = -1;
		int pn = pop_on() | pop_ours() << 1;	/* (TOUCH: not the GRID ADJUST pop-up a tile drives; 2.01-a: also
							 * our pane <-> a stock pop-up: our pane's pixels go) */
		if (pn != last_pop) {
			int i;
			for (i = 0; i < NREG; i++)
				rk[0][i] = rk[1][i] = 0;
			last_pop = pn;
		}
	}
	u32 trackno = u32be(DECK + 0x60);	/* 0 = nothing loaded */
	int failed = load_failed();
	u32 loaded = failed || lg_on ? 0 : trackno;	/* V4n30a: the load gate (no half-loaded track) */
	s32 tempo_raw = pitch_raw();
	u32 range = u32be(DECK + 0x44);
	s32 tempo = pitch100(tempo_raw, range);
	u32 bpm10 = u32be(DECK + 0x68);
	u32 el = u32be(DECK + 0x78), len = u32be(DECK + 0x7C);
	int bpm_unknown = bpm10 >= 10000;	/* MAIN sends 0xFFFFFFFF when it has no BPM */
	u32 player_no = player_num();
	u32 slot = DECK[1];
	u32 beat;	/* P10: the beat at the playhead from the beat grid (1..4 in the bar; 0 = before the first) */
	u32 beat8;	/* and its place in two bars (0..7) for PHASE METER TYPE 2 */
	int i;

	if (bpm_unknown)
		bpm10 = 0;
	int band = 0, mlab = 0;
#ifdef V2_BDIRECT
	bd_was = bd_on;
	bd_on = 0;
	md_on = 0;
	if (bd_was && !loaded)
		rk[0][R_BAND] = 0;
#endif
	if (!loaded) {
		int ta = failed && toast_on();
		el = 0;
		len = 0;
		bpm10 = 0;
		if (!failed)
			toast_was = 0;
		wave_on();
		if (need(R_BAND, 0xE0 + ta)) {
			fill(0, BAND_Y0, W, BAND_Y1 - BAND_Y0, C_BLACK);	/* the 3000 shows an empty band */
			wave_off();
			if (ta)
				error_toast();
		}
		wave_off();
	} else {
		u32 b10 = u32be(DECK + 0x68);
		toast_was = 0;
		mlab = master_label();
		/* V3f: the band's other layers -- loop pads (loop state, slip, length), MASTER PLAYER, the
		 * beat-distance numbers / loop length (grid at the playhead: in the band key) */
		band_xk = hmix(hmix(hmix(b10, DECK[0xD3] | slip_on() << 8 | mlab << 9 | DECK[0xF3] << 12 |
				(u32)DECK[0x11B] << 20), (u32)loop_len_k(b10)), (u32)ana);
#ifdef V2_KEYSHIFT
		band_xk = hmix(hmix(band_xk, (v3e_b & 0x807F) + 0x10000u), (u32)g_kn);
		band_xk = hmix(band_xk, (u32)GA_MODE);	/* TOUCH (V4n41): the GRID ADJUST panel / ZOOM - GRID label */
#endif
		band_xk = hmix(band_xk, (u32)cue_next_cm() | cue_ver << 8);	/* V4b1: the cue comment (and a new cue table) */
#ifdef V2_BDIRECT
		bd_on = bd_ok;
		if (bd_was && !bd_on)
			rk[0][R_BAND] = 0;	/* back to the canvas: its band rows are stale */
		if (bd_on)
			band = 1;		/* drawn straight into the GR3 buffer after deck_area (bd_draw) */
		else
#endif
		{
		wave_on();
		{ PF0(0); band = wave_band(); PF1(0); }		/* ours: the stock renderer is skipped */
		if (band)
			loop_bar(b10);
		wave_off();
		}
	}
	if (len >= 100 * 60 * 1000)
		len = 0;
	if (el > len)
		el = len;

	/* --- top: header bar, source tile, artwork, title, sub-line, tiles --- */
	{
	u32 kh = hmix(hmix(hmix(hmix(loaded, player_no), slot), u32be(slot0 + 0x1C) != 0), len);
	kh = hmix(hmix(hmix(kh, bpm10), bpm_dec), (DECK[0xF3] == 2) + 2 * (DECK[0x11B] == 1));
#ifdef V2_KEYSHIFT
	kh = hmix(kh, (v3e_b & 0x080080FF) + 0x10000u);	/* V4n36: + KEY FORMAT */
#endif
	kh = hslot(kh, slot0);
	kh = hmix(hmix(kh, ldart_seq()), (u32)lg_on);	/* G2; V4n30a gate */
	kh = hmix(hmix(kh, cue_rbid()), u32be(CUEBUF + CUE_TITL + 4));	/* V4n24: a new load / its MAIN title */
	if (!MODEL[0x0F])
		kh = hslot(kh, SLOT(1, 0));
	if (bpm_dec)
		kh = hmix(kh, bpm100_at(bpm10, tempo, el));
	if (need(0, kh)) {
	v2_reg_draws++;
	fill(0, 0, W, 60, C_BAR);
	fill(0, 0, 56, 60, C_NAVY);
	fill(0, 0, 13, 14, C_WHITE);
	buf[0] = '0' + player_no % 10; buf[1] = 0;
	text_c(&f_s, 6, 0, buf, C_BLACK, C_WHITE);
	{	/* V3e1 (audit Q11): the source pictogram above its name, as the 3000 */
		int a = v2a_for_icon(slot == 2 ? 0x63 : slot == 3 ? 0x54 : slot ? 0x51 : 0);
		if (a >= 0)
			icon(a, 28 - v2a_rects[a].w / 2, 16 + SRC_DY(a), C_WHITE, C_NAVY);
	}
	text_c(&f_s, 28, 40, slot == 2 ? "SD" : slot == 3 ? "USB" : slot ? "LINK" : "", C_WHITE, C_NAVY);
	fill(69, 10, 37, 40, C_BAR);
	ldart_hdr = 0;
	if (loaded && ldart_seq()) {
		ldart_draw(70, 11, 35, 38);	/* G2: MAIN's own decode of the loaded track's cover */
		ldart_hdr = 1;
	} else if (loaded && u32be(slot0 + 0x1C)) {
		artwork(70, 11, 35, 38);
		art_keep();
		ldart_hdr = 2;
	} else	/* V3e1 (audit Q10): the 3000's grey vinyl-disc placeholder on the header grey */
		icon_scaled(V2A_NOART_HDR, 70, 11, 35, 38, 0x4A49, C_BAR);
	{	/* P10: the model's title / key slots are rebuilt on every screen change (empty for a frame
		 * or two): keep the loaded track's last ones instead of flashing "Not Loaded." */
		static u8 tc[128], kc[64];
		static int tn, kn;
		static u32 tag;
		u32 t = hmix(hmix(loaded, len), cue_rbid());	/* V4n24: + the rbid (CONTINUE: same `loaded`) */
		int i2, mn;
		if (!loaded || t != tag)
			tn = kn = 0;
		tag = t;
		mn = loaded ? main_title(tc) : 0;	/* V4n24: MAIN's export.pdb title of THIS rbid first: the model's
							 * slot is empty (7.2.19 export) or still the previous track's
							 * after a load the browse did not start (CONTINUE) */
		if (mn)
			tn = mn;
		else if (loaded && u16be(slot0 + 0x28)) {
			tn = u16be(slot0 + 0x28) > 64 ? 64 : u16be(slot0 + 0x28);
			for (i2 = 0; i2 < 2 * tn; i2++)
				tc[i2] = slot0[0x2A + i2];
		}
		if (loaded && !MODEL[0x0F] && u16len(SLOT(1, 0))) {
			kn = u16len(SLOT(1, 0)) > 32 ? 32 : u16len(SLOT(1, 0));
			for (i2 = 0; i2 < 2 * kn; i2++)
				kc[i2] = SLOT(1, 0)[0x2A + i2];
		}
		{	/* V4m2: an empty title slot on a loaded track -> the browse row's title (fb_title) */
			int fn = fb_title(loaded);
			if (!tn && fn) {
				for (i2 = 0; i2 < 2 * fn; i2++)
					tc[i2] = fb_tc[i2];
				tn = fn;
			}
		}
		if (loaded && tn) {	/* V3e1 (audit Q2): the 3000's note before the title */
			icon_scaled(V2A_TITLE_TRACK, 118, 6, 12, 18, C_LBL, C_BAR);	/* ICONS: 3000 img_icnTrack is #AFAFAF (C_LBL: day-mode safe) */
			text_u16(&f_m, 136, 4, tc, tn, 552, C_WHITE, C_BAR);
			memcpy_title(tc, tn, t);
		} else if (!loaded && lg_on)	/* V4n30a: the load gate (3000: Loading) */
			text(&f_m, 116, 4, "Loading...", C_LBL, C_BAR);
		else if (!loaded)	/* V4m2: a loaded track without any title: an empty bar, as stock */
			text(&f_m, 116, 4, "Not Loaded.", C_RED, C_BAR);
		if (loaded && kn) {
			int kfn = kn, kx, cy = 43, d;
			const volatile u8 *kft = kf_key(kc, &kfn);	/* V4n36: the KEY FORMAT */
			kx = 276 + row_text_w(&f_m, kft, kfn) + 12;
			text_u16(&f_m, 276, 32, kft, kfn, 552, C_WHITE, C_BAR);
			/* the 3000's (i) after the sub-line: a white disc, a dark "i" */
			for (d = -6; d <= 6; d++) {
				int hw = d < 0 ? -d : d;
				hw = hw >= 6 ? 3 : hw >= 5 ? 4 : hw >= 4 ? 5 : 6;
				fill(kx + 6 - hw, cy + d, 2 * hw + 1, 1, C_WHITE);
			}
			fill(kx + 5, cy - 4, 3, 2, C_BAR);
			fill(kx + 5, cy - 1, 3, 6, C_BAR);
		}
	}
	if (loaded) {
		/* V3e1 (audit Q1): the sub-line shows the track's LENGTH (static), as the 3000 */
		fmt_mmss(buf, len);
		text(&f_m, 116, 32, buf, C_WHITE, C_BAR);
		fmt_bpm(buf, bpm10, bpm_dec ? bpm100_at(bpm10, tempo, el) : 0);
		text(&f_m, 196, 32, bpm_unknown ? "--.-" : buf, C_WHITE, C_BAR);
		/* musical key: drawn above from the kept copy (model side 1 slot 0, icon 0x0F) */
	}
	/* status tiles (the 3000's touch buttons; here labels only) */
	for (i = 0; i < 3; i++) {
		static const char *const t1[] = { "BEAT", "KEY", "BEAT" };
		static const char *const t2[] = { "LOOP", "SHIFT", "JUMP" };
		int tx = 561 + i * 80, c = i == 1 ? C_GREY : C_WHITE;
		/* V3e1 (audit Q6/Q12): a lit tile = blue fill while its pads are up (BEAT LOOP: looping, our
		 * pad bar shows), smaller two-line labels as the 3000 */
		int lit = (i == 0 && DECK[0xF3] == 2) || (i == 2 && DECK[0x11B] == 1);	/* V3rc7: the pad modes */
#ifdef V2_KEYSHIFT
		if (i == 1 && KS_ON) {	/* V4k: live with UTILITY KEY SHIFT ON; lit while its panel is open or shifted */
			c = C_WHITE;
			lit = KS_PANEL || KS_SEMI;
		}
#endif
		u16 tb = lit ? C_SEL : C_CK2;
		if (lit)
			fill(tx, 0, 76, 60, C_SEL);
		else
			checker(tx, 0, 76, 60);
		text_c(&f_s, tx + 38, 13, t1[i], lit ? C_WHITE : c, tb);
		text_c(&f_s, tx + 38, 29, t2[i], lit ? C_WHITE : c, tb);
		fill(tx + 26, 52, 24, 2, lit ? C_WHITE : C_GREY);
	}
	}	/* need(0) */
	}
	/* phase meter (V3d): WAVEFORM / PHASE as the CDJ-3000 (PHASE METER TYPE 1 / 2: the SHORT CUT tile, or a
	 * tap on the meter -- MAIN's touch zone 2, v2needle) */
	beat = grid_beat(u32be(DECK + 0x78), &beat8);
	/* P10 (stock emu, two LINKed decks): +0xA0 = 1 when this deck is the tempo master (also alone),
	 * +0xA4 = the master's player number when another deck is master, +0xA8 = that master's beat 1..4 */
	u32 own_master = is_master(), mplayer = pno56(u32be(DECK + 0xA4)), mbeat = u32be(DECK + 0xA8);
	if (own_master || mplayer > 6 || mbeat > 4)
		mplayer = mbeat = 0;
	{	/* V4n31a (#59): a master that vanishes for a frame or two (+0xA4 / +0xA8 rewritten) is held 500 ms,
		 * so the WAVEFORM view does not drop to the PHASE lines; this deck becoming master drops it at once */
		static u32 h_mp, h_mb, h_t;
		u32 now = now_ms();
		if (mplayer) {
			h_mp = mplayer;
			h_mb = mbeat;
			h_t = now;
		} else if (!own_master && h_mp && now - h_t < MP_HOLD) {
			mplayer = h_mp;
			mbeat = h_mb;
		} else
			h_mp = 0;
	}
	u32 el_m = el;	/* LOCALMETER2: with no remote master (alone, or this deck the master) the meter's own line
			 * follows the band: the band's last published position carried to now at its rate (read-only) */
	if (!mplayer && loaded && present_mode == PM_PLUS && bp_rate > 0) {
		u32 dt = now_ms() - bp_t;
		if (dt < 100)
			el_m = udiv((bp_q8 + (u32)bp_rate * dt) * 5, 192);	/* 1/150 s (Q8) -> ms */
	}
	{
		u32 mbar = 0, kh;
		s32 mph = mplayer ? master_phase(&mbar) : -1;
		int wtype = pm_style;		/* V3e1: 0 PHASE, 1 WAVEFORM, 2 4 BARS (tap cycles) */
		kh = hmix(hmix(hmix(hmix(loaded, beat), pm_style), wtype == 2 ? beat : el), u32be(MARKS + 8));
		/* BARS4KEY: 4 BARS shows boxes that change once per beat (mbeat / beat / the countdowns, all in the key)
		 * -- the master's bar phase only says whether there is one; before, it redrew the meter every frame */
		kh = hmix(hmix(kh, own_master | mplayer << 4 | mbeat << 8 | V2_PLAYHEAD << 12),
			  wtype == 2 ? (u32)(mph >= 0) : (u32)mph);
		if (wtype == 2)
			v2_b4_keyed++;
		kh = hmix(hmix(kh, ms_cd | ms_flags << 9), wtype && mplayer ? master_beatnum() : 0);
		kh = hmix(hmix(kh, (u32)tempo), cue_ver);	/* V4n31a: the countdown's cue list (cue_t) */
#ifdef V3E2
		kh = hmix(kh, u32be(W8BUF + 4) ^ u32be(W8BUF + 8) ^ u32be(W8BUF + 0x0C));
#endif
		/* V3rc8y (deck HUD at 60 fps, zoom 4: F54 Q20): at 60 the meter and the deck area alternate (meter on
		 * even, deck on odd frames: 30 Hz each, the rate they had at 30 fps) so no frame carries both */
#ifdef V2_BDIRECT
		{	/* METERDIRECT: the strip straight into the GR3 buffer about to latch (as the band; paint_frame's
			 * wait_latch ran first). Every frame (each GR3 buffer holds its own copy); the canvas keys are
			 * cleared so leaving direct mode redraws the canvas strip and its copy */
			static int md_was;
			if (bd_on) {
				u16 *sv = fb;
				md_on = 1;
				fb = bd_phys;
				dm_off = 1;
				v2_reg_draws++;
				v2_md_frames++;
				{ PF0(3); phase_meter(loaded, el_m, tempo, own_master, mplayer, mph, mbar, wtype, beat, mbeat); PF1(3); }
				dm_off = 0;
				fb = sv;
				rk[0][1] = rk[1][1] = 0;
			} else if (md_was)
				rk[0][1] = rk[1][1] = 0;
			md_was = md_on;
		}
#endif
		if (!md_on && need(1, kh)) {	/* V3rc8i: the meter every frame (V3rc8y2: the 60-fps alternation reverted -- deck: flicker in every zoom) */
			/* V3e1 (Mac QA: 26 blink events on the meter row with PHASE): the meter is cleared and
			 * redrawn every frame; on a display that scans the buffer while we draw (the Mac's, no
			 * VDC latch) the black clear showed. Draw it off-screen (a full-frame scratch in proven-free
			 * SDRAM, same coordinates) and copy its rows in one pass. */
			u16 *on = fb;
			int y;
			v2_reg_draws++;
			if (fb == (u16 *)CANVAS) {
				/* V3rc8 (audit): SMOOTH composes into the canvas, never shown mid-draw -- draw the meter
				 * straight in (the scratch + ~99 KB copy a frame was only for the direct-paint modes) */
				PF0(3); phase_meter(loaded, el_m, tempo, own_master, mplayer, mph, mbar, wtype, beat, mbeat); PF1(3);
			} else {
				fb = (u16 *)0x0C900000;
				{ PF0(3); phase_meter(loaded, el_m, tempo, own_master, mplayer, mph, mbar, wtype, beat, mbeat); PF1(3); }
				dmark(60, BAND_Y0 - 60);
				for (y = 60; y < BAND_Y0; y++)
					cp16(on + y * W, fb + y * W, W);
				fb = on;
			}
		}
	}


	wave_on();
	if (band && !bd_on)
		band_extras(mlab);
	wave_off();
	/* NAVART: also on the first frame after a key reset (MENU pop-up closed, any switch to the player): at 60 fps
	 * an even frame skipped it and the canvas went out with the pop-up's rows / black in the deck area (1 frame) */
	{
		static int dk_lg = -1;	/* NAVART (emu, LINK load): the gate opened on an even frame -- 2 frames of the new
					 * header + band over the empty deck area; the deck area now follows the gate at once */
		int dforce = lg_on != dk_lg;
		dk_lg = lg_on;
		if (!SPLIT_ON || sp_par == 1 || !rk[rb][2] || dforce)
			{ PF0(2); deck_area(0, 1); PF1(2); }
	}
	if (band && !bd_on)
		band_numbers(bpm10);
	/* ZOOM - GRID in the band's bottom-right corner, as the 3000 (every frame: the band is); V3e1 (audit
	 * W9): 10 px lower, below the beat numbers */
	zoom_label();
#ifdef V2_HWPROBE
	hwp_paint();
#endif
#ifdef V2_HWS2
	hws_paint();
#endif
#ifdef V2_BDIRECT
	if (bd_on) {	/* the band + its layers straight into the GR3 buffer (after the canvas parts above) */
		u16 *sv = fb;
		fb = bd_phys;
		dm_off = 1;
		rk[rb][R_BAND] = 0;	/* every frame: the key tracks the canvas, this is a GR3 buffer */
#ifdef V2_HWBAND
		int hw;
		{ PF0(0); hw = hb_frame(mlab, bpm10); PF1(0); }
		if (!hw) {	/* the software band (and, if it was live, GR2 + key go off with this frame) */
#endif
		wave_on();
		{ PF0(0); band = wave_band(); PF1(0); }
		if (band) {
			loop_bar(u32be(DECK + 0x68));
			band_extras(mlab);
		}
		wave_off();
		band_numbers(bpm10);
		zoom_label();
#ifdef V2_HWBAND
		}
#endif
#ifdef V2_HWPROBE
		hwp_paint();
#endif
#ifdef V2_HWS2
		hws_paint();
#endif
		dm_off = 0;
		fb = sv;
	}
#endif
	if (pop_ours()) {	/* V3rc5: over the band / deck area, redrawn every frame (they are); 2.01-a: only the
				 * pop-ups we render -- stock draws the others in place (pop_ours) */
		popup(1);
		popup_sync();
	}
}


/* ---- browse family: the CDJ-3000 browser (V3e1, re/V3E_DESIGN.md §2-§6, frames 20-27, cdj3k-3.20) ----
 * Every non-player screen we own: a left icon rail (source tile + categories), a 60-px header, full-width
 * list columns, and the thin one-line deck strip at the bottom (y 420..479). Rows: 8 x 40 px from y 90
 * (the UI model carries 8 rows a page); the SEARCH keyboard keeps its stock keys (y 294..), its results
 * 8 x 28 from y 64. Touch (MAIN): the rows' PREVIEW column = Link Cue (touch_audio rt_geo, v2needle);
 * the SEARCH keys, SHORT CUT tiles and the stock zones as stock. */

#define RAIL_W 56
#define V3_ROW_Y0 90
#define V3_ROW_H 40
#define V3_SROW_Y0 64
#define V3_SROW_H 28
#define STRIP_Y 420
#define PANE2_X 452	/* second pane of a two-pane level */
#define C_RAIL 0x39E7	/* #3C3C3C */
#define C_POP 0x18C3	/* #191919 pop-up */
#define C_POPF 0xAD75	/* #AFAFAF pop-up frame */
#define C_CYAN 0x05BC	/* #00B4E6 */
#define C_KEYG 0x07E0	/* #00FF00 harmonic key cell (V3rc8t audit: c017) */

enum { M_NONE, M_PLAYER, M_BROWSE, M_SHORTCUT, M_PINFO };
extern u32 v2_epoch;

/* P10: a rowwave cell with (almost) nothing but black and one flat line: at most 3 of its 20 rows lit */
static int cell_blank(const volatile u16 *c)
{
	int y, x, rows = 0;
	for (y = 0; y < 20; y++) {
		int lit = 0;
		for (x = 0; x < 112 && !lit; x += 3) {
			u16 p = c[y * 112 + x];
			lit = (p >> 11) > 6 || ((p >> 5) & 63) > 12 || (p & 31) > 6;
		}
		rows += lit;
	}
	return rows <= 3;
}


HOT static int row_text_w(const struct font *f, const volatile u8 *t, int n)
{
	int i, w = 0;
	for (i = 0; i < n; i++) {
		u32 ch = u16be(t + 2 * i);
		const struct glyph *g;
		if (!ch)
			break;
		if (ch == 0xFFFA || ch == 0xFFFB)
			continue;
		g = glyph(f, ch);
		w += g ? g->adv : 0;
	}
	return w;
}

static int is_search(void) { return u16be(SLOT(0, 0) + 0x14) == 0x25; }
static int is_src_icon(u32 id) { return id == 0x54 || id == 0x55 || id == 0x51 || id == 0x58 || id == 0x63; }

/* a new layout on the browse family: everything above the strip cleared once (per buffer), every region
 * above it redrawn (the previous screen's pixels would show in the gaps between our regions) */
static void layout(u32 key)
{
	if (need(25, key)) {
		int i;
		fill(0, 0, W, STRIP_Y, C_BLACK);
		for (i = 11; i <= 24; i++)
			rk[rb][i] = 0;
	}
}

/* ---- keys: Camelot number (1..12) x 2 + (B ? 1 : 0); 0 = none. Tokens "4A" / "12B" or "F#m" / "Eb" ---- */
static int key_code(const volatile u8 *t, int n)
{
	u32 c0, c1;
	int i = 0;
	while (i < n && u16be(t + 2 * i) == ' ')
		i++;
	if (i >= n)
		return 0;
	c0 = u16be(t + 2 * i);
	c1 = i + 1 < n ? u16be(t + 2 * i + 2) : 0;
	if (c0 >= '0' && c0 <= '9') {		/* Camelot */
		u32 num = c0 - '0', l;
		int j = i + 1;
		if (c1 >= '0' && c1 <= '9') { num = num * 10 + c1 - '0'; j++; }
		l = j < n ? u16be(t + 2 * j) : 0;
		if (num < 1 || num > 12 || (l != 'A' && l != 'B'))
			return 0;
		return (int)(num * 2 + (l == 'B'));
	}
	if (c0 >= 'A' && c0 <= 'G') {		/* classic: pitch class, # / b, m */
		static const u8 PC[7] = { 9, 11, 0, 2, 4, 5, 7 };	/* A..G */
		int pc = PC[c0 - 'A'], j = i + 1, minor = 0, num;
		if (c1 == '#') { pc++; j++; } else if (c1 == 'b') { pc += 11; j++; }
		if (j < n && u16be(t + 2 * j) == 'm') { minor = 1; j++; }
		if (j < n && u16be(t + 2 * j) != ' ' && u16be(t + 2 * j) != 0)
			return 0;	/* a longer word ("FLAC", "AIFF"): not a key */
		pc %= 12;
		num = ((pc + 3 * minor) * 7 + 8) % 12;
		if (!num) num = 12;
		return num * 2 + !minor;
	}
	return 0;
}
/* V4n36 UTILITY KEY FORMAT (the CDJ-3000's key display format setting): a key code as text in the chosen notation --
 * ALPHANUMERIC "8A" / "12B" (rekordbox's numbering = Camelot) or CLASSIC "Am" / "F#" in rekordbox's spelling
 * (flats except F# / F#m: Db Eb Ab Bb, Dbm Ebm Abm Bbm). Every key on our screens goes through it, whatever
 * notation the export / the LINK metadata carried. Returns the length (b NUL-terminated). */
static int key_name(char *b, int c)
{
	static const char *const PN[12] = { "C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B" };
	int k = 0, minor = !(c & 1);
	u32 num = (u32)(c >> 1);
	const char *q;
	if (!KF_CLASSIC) {
		if (num >= 10)
			b[k++] = '1';
		b[k++] = '0' + num % 10;
		b[k++] = minor ? 'A' : 'B';
	} else {
		for (q = PN[(((num + 4) * 7) + 3u * 12 - 3u * minor) % 12]; *q; q++)
			b[k++] = *q;
		if (minor)
			b[k++] = 'm';
	}
	b[k] = 0;
	return k;
}
/* V4k: the key `semi` semitones away from the key text t (n UTF-16BE chars), into out (UTF-16BE) in the KEY
 * FORMAT notation (V4n36; was the text's own); returns its length, 0 when t is not a key. +1 semitone = +7 on
 * the wheel. */
static int key_txt(u8 *out, const volatile u8 *t, int n, int semi)
{
	int c = key_code(t, n), k, i;
	char b[6];
	if (!c)
		return 0;
	c = (int)((((u32)(c >> 1) - 1 + 7u * (u32)(semi + 24)) % 12 + 1) * 2 + (u32)(c & 1));
	k = key_name(b, c);
	for (i = 0; i < k; i++) {
		out[2 * i] = 0;
		out[2 * i + 1] = (u8)b[i];
	}
	return k;
}
/* V4n36: a key text as shown (KEY FORMAT), t itself when it is not a key; the buffer is reused per call */
static u8 kf_b[16];
static const volatile u8 *kf_key(const volatile u8 *t, int *n)
{
	int m = *n ? key_txt(kf_b, t, *n, 0) : 0;
	if (!m)
		return t;
	*n = m;
	return kf_b;
}
/* V4n36: a text of keys ("Abm", "Abm, B, Dbm": MAIN's KEY list rows, icon 0x0F / 0x34) with every key token
 * in the KEY FORMAT; other characters kept. Into kf_l (<= 48 chars); n updated. */
static u8 kf_l[96];
static const volatile u8 *kf_list(const volatile u8 *t, int *n)
{
	int i = 0, o = 0, nn = *n;
	while (i < nn && o < 48) {
		int j = i, m;
		while (j < nn && u16be(t + 2 * j) != ' ' && u16be(t + 2 * j) != ',')
			j++;
		m = j > i ? key_txt(kf_b, t + 2 * i, j - i, 0) : 0;
		if (m && o + m <= 48) {
			int q;
			for (q = 0; q < 2 * m; q++)
				kf_l[2 * o + q] = kf_b[q];
			o += m;
		} else
			for (; i < j && o < 48; i++, o++) {
				kf_l[2 * o] = t[2 * i];
				kf_l[2 * o + 1] = t[2 * i + 1];
			}
		i = j;
		if (i < nn && o < 48) {	/* the separator */
			kf_l[2 * o] = t[2 * i];
			kf_l[2 * o + 1] = t[2 * i + 1];
			o++;
			i++;
		}
	}
	*n = o;
	return kf_l;
}
#ifdef V2_KEYSHIFT
/* V4n KEY SYNC (the CDJ-3000's rule, re/KEY_SHIFT_PLAN.md K1): the own key's shift onto the master's key or
 * its +-1 Camelot neighbour in the own mode letter (the relative key when the modes differ), the nearest
 * (ties: the master's own, then +1, then -1); |shift| <= 2. Published every frame in the GUI's link TX frame
 * (+0xFF0, after usblog's ring) as "KY" << 16 | valid << 7 | (shift + 12); MAIN (mods/keyshift ksy_tap /
 * ksy_tick) applies it on the K.SYNC tile and follows it while synced. Valid: both keys known, a track loaded
 * and another deck the master. */
static void ks_publish(void)
{
	static const int D[3] = { 0, 1, -1 };
	int o = u32be(DECK + 0x60) && !load_failed() && g_kn ? key_code(g_key, g_kn) : 0, m = V3E_MKEY, i, best = 99;
	u32 w = 0x4B590000u;
	if (o && m && !is_master()) {
		for (i = 0; i < 3; i++) {
			int tn = ((m >> 1) - 1 + D[i] + 12) % 12 + 1, d = (7 * (tn - (o >> 1)) % 12 + 12) % 12;
			if (d > 5)
				d -= 12;
			if ((d < 0 ? -d : d) < (best < 0 ? -best : best))
				best = d;
		}
		w |= 0x80u | (u32)(best + 12);
	}
	*(volatile u32 *)0x3C27CFF0 = w;
}
/* the shown key: the shifted one while KEY SHIFT is on with a shift (orange, the 3000's MT colour) */
static u8 ks_kb[16];
static const volatile u8 *ks_key(const volatile u8 *t, int *n, u16 *col)
{
	int m = *n ? key_txt(ks_kb, t, *n, KS_SEMI) : 0;	/* V4n36: in the KEY FORMAT also unshifted */
	if (!m)
		return t;
	*n = m;
	if (KS_SEMI)
		*col = C_OR;
	return ks_kb;
}
/* KSAMT (V4n43, user): the KEY SHIFT amount next to the key, orange as the shifted key: s1 = "+2" / "-3" (empty at
 * 0), s2 = the KEY SYNC cents "+42c" / "-42c" while KEY SYNC is on and they are not 0 (else empty). 0 = nothing */
static void ks_num(char *p, int v, char suf)
{
	int a = v < 0 ? -v : v;
	*p++ = v < 0 ? '-' : '+';
	if (a >= 10)
		*p++ = (char)('0' + a / 10);
	*p++ = (char)('0' + a % 10);
	if (suf)
		*p++ = suf;
	*p = 0;
}
static int ks_amt(char *s1, char *s2)
{
	int c = KS_KSYNC ? g_kcents : 0;
	s1[0] = s2[0] = 0;
	if (KS_SEMI)
		ks_num(s1, KS_SEMI, 0);
	if (c > -100 && c < 100 && c)
		ks_num(s2, c, 'c');
	return s1[0] || s2[0];
}
#endif
/* harmonic with the reference key (the 3000's green KEY cell): same key, +-1 on the wheel, or relative */
static int key_compat(int a, int b)
{
	int na = a >> 1, nb = b >> 1, d;
	if (!a || !b)
		return 0;
	if (na == nb)
		return 1;
	if ((a & 1) != (b & 1))
		return 0;
	d = na - nb;
	return d == 1 || d == -1 || d == 11 || d == -11;
}
static int own_key(void)
{
	return u32be(DECK + 0x60) && !load_failed() && g_kn ? key_code(g_key, g_kn) : 0;
}
/* V3e3: the reference is the LINK master's key (MAIN +0x14 page 0) when another deck is master and its key
 * is known; else this deck's own track (V3e1/2) */
static int ref_key(void)
{
#ifdef V3E2
	if (!is_master() && V3E_MKEY)
		return V3E_MKEY;
#endif
	return own_key();
}
/* the deck bar's KEY in the 3000 green: harmonic with the master's key (this deck master: its own key) */
static int deck_key_green(void)
{
	int k = own_key();
	if (!k)
		return 0;
	if (is_master())
		return 1;
#ifdef V3E2
	return key_compat(k, V3E_MKEY);
#else
	return 0;
#endif
}

/* rowmeta (slot text + 0x1A0, MAIN rowwave): "FLAC 120.0 4A 6:58" -> the BPM and KEY tokens */
static void meta_split(const volatile u8 *m, int mn, int *b0, int *bn, int *k0, int *kn)
{
	int i = 0;
	*b0 = *bn = *k0 = *kn = 0;
	while (i < mn) {
		int j = i, dot = 0, col = 0;
		while (j < mn && u16be(m + 2 * j) != ' ') {
			u32 c = u16be(m + 2 * j);
			dot |= c == '.';
			col |= c == ':';
			j++;
		}
		if (j > i && !col) {
			u32 c = u16be(m + 2 * i);
			if (dot && c >= '0' && c <= '9') { *b0 = i; *bn = j - i; }
			else if (key_code(m + 2 * i, j - i)) { *k0 = i; *kn = j - i; }
		}
		i = j + 1;
	}
}

/* ---- the rail: source tile + 9 category tiles (3000 frame 21/22) ---- */
static const u8 RAIL_ID[9] = { 0x81, 0x82, 0x83, 0x8B, 0x84, 0x95, 0x91, 0xAA, 0x90 };
static const char *const RAIL_T[9] = { "ARTIST", "ALBUM", "TRACK", "KEY", "PLAYLIST", "HISTORY", "SEARCH",
				       "MATCHING", "FOLDER" };
static u32 cur_cat = 0x83;	/* the last category opened (a latch: deeper levels keep it) */

static u32 src_icon(void)
{
	u32 tid = u16be(SLOT(0, 0) + 0x14), s = DECK[1];
	if (is_src_icon(tid))
		return tid;
	return s == 2 ? 0x63 : s == 3 ? 0x54 : 0x54;
}
/* V3e3 (audit P5): the medium's rekordbox BACKGROUND COLOR (MAIN +0x14 bits 16-19), navy by default */
static u16 med_col(void)
{
#ifdef V3E2
	static const u16 MC[9] = { C_NAVY, 0xF8D3, 0xE145, 0xFC60, 0xFF20, 0x1E47, 0x069A, 0x029F, 0x901F };
	int c = V3E_MCOL;
	return c > 0 && c < 9 ? MC[c] : C_NAVY;
#else
	return C_NAVY;
#endif
}
static void source_tile(u32 icon_id)
{
	char b[2];
	u32 pno = player_num();
	int a;
	u16 nv = med_col();
	fill(0, 0, RAIL_W, 60, nv);
	fill(0, 0, 13, 14, C_WHITE);
	b[0] = '0' + pno % 10; b[1] = 0;
	text_c(&f_s, 6, 0, b, C_BLACK, C_WHITE);
	if (!icon_id || v2a_for_icon(icon_id) < 0)
		icon_id = 0x54;
	a = v2a_for_icon(icon_id);
	if (a >= 0)
		icon(a, 28 - v2a_rects[a].w / 2, 16 + SRC_DY(a), C_WHITE, nv);
	text_c(&f_s, 28, 40, icon_id == 0x51 ? "LINK" : icon_id == 0x63 ? "SD" : icon_id == 0x58 ? "DISC" : "USB",
	       C_WHITE, nv);
}
static void rail(int ymax, u32 hl, int focus)
{
	int k;
	source_tile(src_icon());
	fill(0, 60, RAIL_W, ymax - 60, C_RAIL);
	fill(RAIL_W - 1, 60, 1, ymax - 60, C_BLACK);
	for (k = 0; k < 9; k++) {
		int y = 60 + 40 * k, a = v2a_for_icon(RAIL_ID[k]), on = RAIL_ID[k] == hl;
		u16 bg = on ? (focus ? C_SEL : C_UNF) : C_RAIL;
		if (y + 40 > ymax)
			break;
		if (on)
			fill(0, y, RAIL_W - 1, 40, bg);
		if (a >= 0) {	/* ICONS: the rail's own 20-px pictograms (3000 category icons x 0.625), 1:1 */
			int ra = v2a_for_rail(RAIL_ID[k]);
			icon(ra, 28 - v2a_rects[ra].w / 2, y + 13 - v2a_rects[ra].h / 2, on ? C_WHITE : C_LBL, bg);
		}
		text_c(&f_t, 28, y + 25, RAIL_T[k], on ? C_WHITE : C_LBL, bg);
	}
}

/* ---- header (y 0..59): back box, list icon, title; the 3000's PREVIEW box and the INFO arrow at the right ---- */
static void header(const volatile u8 *t, u32 hid, const char *title, int back, int info, int pv)
{
	int x = RAIL_W + 18;
	fill(RAIL_W, 0, W - RAIL_W, 60, C_BAR);
	fill(RAIL_W, 59, W - RAIL_W, 1, C_BLACK);
	frame(x, 14, 32, 32, 1, 0x4A69);
	text_c(&f_m, x + 16, 17, "<", back ? 0xAD55 : 0x39C7, C_BAR);
	x += 44;
	if (hid && v2a_for_icon(hid) >= 0 && !is_src_icon(hid))
		x += icon_id(hid, x, 30, C_WHITE, C_BAR) + 8;
	if (title)
		text(&f_m, x, 17, title, C_WHITE, C_BAR);
	else if (t)
		text_u16(&f_m, x, 17, t + 0x2A, u16len(t), 560, C_WHITE, C_BAR);
	/* PREVIEW (Link Cue on the rows' mini waveforms, as the 3000's touch preview) */
	if (pv) {	/* V3rc2: track lists only (3000 frame 22: none on the category / playlist tree) */
		/* V4n (claims audit #144, BrowseLayout img_btnPreview 114x90 at 1018): a header tile, solid #007DE1
		 * while a row's preview plays, the #191919/#323232 checker otherwise; white label */
		int lit = V3E_PV_ROW != 0, off = V3E_PVOFF;
		if (lit && !off)
			fill(562, 6, 72, 48, C_SEL);
		else if (off) {	/* TOUCH (V4n41): PREVIEW off -- the 3000's released toggle: a plain outlined tile, grey label */
			fill(562, 6, 72, 48, C_BAR);
			frame(562, 6, 72, 48, 1, 0x4A69);
		} else
			checker2(562, 6, 72, 48, C_CK1, C_BAR);
		text_c(&f_s, 598, 22, "PREVIEW", off ? C_GREY : C_WHITE, lit && !off ? C_SEL : C_BAR);
	}
#ifdef V3E2
	/* V3e2: TRACK FILTER (the 3000's key; a tap opens stock's filter, MAIN v3e_touch) */
	frame(640, 16, 64, 28, 1, 0x4A69);
	text_c(&f_s, 672, 22, "FILTER", C_LBL, C_BAR);
#endif
	/* INFO */
	fill(712, 12, 80, 36, info ? C_SEL : C_BAR);
	frame(712, 12, 80, 36, 1, 0x4A69);
	text_c(&f_s, 752, 22, "< INFO", C_WHITE, info ? C_SEL : C_BAR);
}

/* the column header bar (y 60..87) */
static void colhdr(int x0, int x1, const char *a, int ax, const char *b, int bx, const char *c, int cx,
		   const char *d, int dx)
{
	fill(x0, 60, x1 - x0, 28, C_HDR);
	fill(x0, 88, x1 - x0, 2, C_BLACK);
	if (a) text(&f_s, ax, 67, a, C_LBL, C_HDR);
	if (b) text(&f_s, bx, 67, b, C_LBL, C_HDR);
	if (c) text(&f_s, cx, 67, c, C_LBL, C_HDR);
	if (d) text(&f_s, dx, 67, d, C_LBL, C_HDR);
}

/* V3rc2 (frames 21/23/25): the 3000's track column bar -- PREVIEW | # ^ | TRACK ^ [0077] | sort box | BPM ^ |
 * KEY ^, the active sort column in blue (DEFAULT = #, ALPHABET = TRACK); defined after sort_id() */
static void trk_hdr(int x1, const char *cnt, u32 sid1);
/* the sort field from side 1 slot 0's icon in a track list (stock SORT, re/V3E_DESIGN.md F2) */
static u32 sort_id(int sid)
{
	if (sid != 0x03 && sid != 0x04)
		return 0;
	if (MODEL[0x0F])		/* the SORT / LIST MENU pop-up uses side 1 */
		return 0;
	if (u16be(SLOT(1, 0) + 0x14) == 0x63)	/* V3rc2: TRACK FILTER's count "[  77]", not a sort column */
		return 0;
	return u16be(SLOT(1, 0) + 0x14);
}
static int sort_extra(u32 id) { return id && id != 0x83 && id != 0x85 && id != 0x8B && id != 0xA1 && id != 0xA2; }
#define C_SORTB 0x453E		/* #41A6F5 the active sort column */
static void hdr_lbl(int x, const char *s, int on, int arrow)
{
	u16 c = on ? C_SORTB : C_LBL;
	x = text(&f_s, x, 67, s, c, C_HDR);
	if (arrow)
		tri(x + 7, 70, c);
}
static void trk_hdr(int x1, const char *cnt, u32 sid1)
{
	int def = !sid1 || sid1 == 0xA1 || sid1 == 0x83, x;
	fill(RAIL_W, 60, x1 - RAIL_W, 28, C_HDR);
	fill(RAIL_W, 88, x1 - RAIL_W, 2, C_BLACK);
	text(&f_s, RAIL_W + 8, 67, "PREVIEW", C_LBL, C_HDR);
	hdr_lbl(RAIL_W + 130, "#", def, 1);
	x = text(&f_s, RAIL_W + 180, 67, "TRACK", sid1 == 0xA2 ? C_SORTB : C_LBL, C_HDR);
	tri(x + 7, 70, sid1 == 0xA2 ? C_SORTB : C_LBL);
	if (cnt[5])
		text(&f_s, x + 18, 67, cnt + 6, C_LBL, C_HDR);
	/* the sort button (a tap opens SORT: MAIN zone) */
	/* V4n30a (scaling audit, 3000 x 0.625): sort box 631..668, BPM 675..743, KEY 744..799 */
	fill(x1 - 169, 62, 1, 24, C_BLACK);
	tri(x1 - 151, 66, C_LBL);
	tri_dn(x1 - 151, 78, C_LBL);
	fill(x1 - 132, 62, 1, 24, C_BLACK);
	hdr_lbl(x1 - 118, "BPM", sid1 == 0x85, 1);
	hdr_lbl(x1 - 50, "KEY", sid1 == 0x8B, 1);
}

/* one track row (full width): PREVIEW mini waveform | note + title | (sort column) | BPM | KEY */
/* V3e2 (audit B4): the model's slot 0 carries the list position -- +0 the cursor's row on the page (0..7),
 * +4 the list's count, +8 the page's first row number (1-based): row k's number = +8 + k */
static u32 row_no(int k)
{
	const volatile u8 *s0 = SLOT(0, 0);
	u32 rp = u32be(s0), cnt = u32be(s0 + 4), f = u32be(s0 + 8);
	(void)rp;
	/* V3e3 (re_browse Q3): +8 is the page's FIRST visible row, 0-based (MAIN 0x0B5434F4), right across
	 * scrolling, paging, BACK, sort and re-entry; +0 holds dirty flags, not the cursor */
	return cnt && f < cnt ? f + (u32)k + 1 : 0;
}
static void __attribute__((unused)) fmt_u(char *p, u32 v)	/* up to 4 digits */
{
	char t[6];
	int n = 0;
	do { t[n++] = '0' + v % 10; v = udiv(v, 10); } while (v && n < 4);
	while (n)
		*p++ = t[--n];
	*p = 0;
}
/* V3rc8 (CDJ-3000 scroll label + one label scroller timer): a text wider than its box (text + 20 >
 * box) scrolls only on the SELECTED row -- wait 800 ms, then 0.11 px/ms (time based), drawn twice with a 6-space gap
 * and wrapping seamlessly; every pass waits 800 ms again; after 5 passes it stops until the selection changes. Hard
 * clip, no ellipsis, no fade. One marquee (the 3000 scrolls one selected label at a time). */
static struct { u32 key, t0; int st, passes; } mq;	/* st 0 off / stopped, 1 waiting, 2 scrolling */
static int mq_xmax = 800;
#ifdef V2_HUD
u32 v2_mq_dbg[4];
#endif	/* the visible right edge of list rows (the INFO pane covers them from PANE2_X) */
static int mq_peek(void)	/* for the row's region key: changes whenever the marquee must redraw */
{
	u32 t = now_ms();
	if (mq.st == 1) {
		pend = 1;
		return t - mq.t0 >= 800 ? 2 : 1;
	}
	if (mq.st == 2) {
		pend = 1;
		return 3 + (int)udiv((t - mq.t0) * 11, 100);
	}
	return 0;
}
static int mq_step(u32 key, int tw, int bw, int gap)
{
	u32 t = now_ms();
	int off;
	if (tw + 20 <= bw)	/* fits: no scroll, and it leaves the marquee alone (another selected label may own it) */
		return 0;
	if (key != mq.key) {
		mq.key = key;
		mq.t0 = t;
		mq.st = 1;
		mq.passes = 0;
		pend = 1;
		return 0;
	}
	if (mq.st == 1) {
		if (t - mq.t0 < 800) {
			pend = 1;
			return 0;
		}
		mq.st = 2;
		mq.t0 = t;
	}
	if (mq.st != 2)
		return 0;
	off = (int)udiv((t - mq.t0) * 11, 100);
	if (off >= tw + gap) {
		mq.t0 = t;
		mq.st = ++mq.passes > 4 ? 0 : 1;
		pend = 1;
		return 0;
	}
	pend = 1;
	return off;
}
static int row_text_w(const struct font *f, const volatile u8 *s, int n);
static void text_u16_mq(const struct font *f, int x, int y, const volatile u8 *s, int n, int xmax, u16 fg, u16 bg,
			u32 key)
{
	int tw, gap, off;
	if (xmax > mq_xmax)
		xmax = mq_xmax;
	tw = row_text_w(f, s, n); gap = text_w(f, "      "); off = mq_step(key, tw, xmax - x, gap);
#ifdef V2_HUD
	v2_mq_dbg[0] = (u32)tw; v2_mq_dbg[1] = (u32)(xmax - x); v2_mq_dbg[2] = (u32)x; v2_mq_dbg[3] = (u32)n;
#endif
	if (!off) {
		text_u16(f, x, y, s, n, xmax, fg, bg);
		return;
	}
	clip_x0 = x;
	text_u16(f, x - off, y, s, n, xmax, fg, bg);
	text_u16(f, x - off + tw + gap, y, s, n, xmax, fg, bg);
	clip_x0 = 0;
}
/* V4n10: the tracks previewed this session. NOT shown any more: the 3000's skin has no "previewed" colour (the
 * dark green these rows had is its PLAYED colour); kept for the row hash only */
static u32 pv_ids[64], pv_n;
static int pv_seen(u32 id)
{
	u32 i;
	if (!id)
		return 0;
	for (i = 0; i < pv_n && i < 64; i++)
		if (pv_ids[i] == id)
			return 1;
	return 0;
}
static void pv_note(u32 id)
{
	if (id && !pv_seen(id))
		pv_ids[pv_n++ & 63] = id;
}
/* Row colours as the CDJ-3000's skin has them (re/LINKCUE_3000_COMPARE.md): "playing" #00FF00 and
 * "played" #168B16 (#3EB33E on the cursor row); there is NO colour for a row that was only previewed. A track is
 * "played" once it was loaded on this deck AND played (owner: a preview alone must not mark it; V4n26 registered
 * every LOAD, and the previewed rows took the played colour's dark green). */
#define C_PLAYED 0x1462		/* #168B16 */
#define C_PLAYED_CUR 0x3D87	/* #3EB33E */
static u32 pl_ids[64], pl_n;
static int pl_seen(u32 id)
{
	u32 i;
	if (!id)
		return 0;
	for (i = 0; i < pl_n && i < 64; i++)
		if (pl_ids[i] == id)
			return 1;
	return 0;
}
/* V4n27: the rows carry no track id (+0x1C is 1 on every row) -- a played track is known by its TITLE: the
 * hash of MAIN's 'TITL' record (export.pdb title) == the hash of the row's text, same formula as hslot() */
static u32 pl_last_rb;
static u32 th_hash(const u8 *t, int n)
{
	u32 h = hmix(0, (u32)n);
	int i;
	for (i = 0; i < 2 * n; i++)
		h = hmix(h, t[i]);
	return h | 1;
}
static void pl_track(void)
{
	u8 t[128];
	u32 rb = cue_rbid(), h;
	int n;
	if (!rb || rb == pl_last_rb)
		return;
	if (!deck_playing())		/* loaded is not played: asked again every frame until it plays */
		return;
	n = main_title(t);
	if (n <= 0)
		return;
	pl_last_rb = rb;
	h = th_hash(t, n);
	if (!pl_seen(h))
		pl_ids[pl_n++ & 63] = h;
}
static u32 row_th(const volatile u8 *sl)
{
	u8 t[128];
	int i, n = u16len(sl);
	if (n > 64) n = 64;
	for (i = 0; i < 2 * n; i++)
		t[i] = sl[0x2A + i];
	return n ? th_hash(t, n) : 0;
}
/* HALFBLUE: a rowwave cell (112 x 20, stride 112: MAIN's bottom-anchored wave in columns 0..85, the 20x20 artwork
 * at 92..111). UTILITY WAVEFORM = HALF (OVSHAPE4; ov_full = 1): the wave columns mirrored around the centre row as the overview (row y
 * shows the bottom-up row 2 |y - 9.5| - 0.5 -> the base colours at the centre, the tips at both edges). Runs only
 * when the row is redrawn (its hash changed), never per frame */
static void cell_img(const volatile u16 *src, int x0, int y0)
{
	int y, x;
	if (!ov_full) {
		image(src, 112, 20, 112, x0, y0, 112, 20);
		return;
	}
	dmark(y0, 20);
	for (y = 0; y < 20; y++) {
		int j = y < 10 ? 2 * (9 - y) : 2 * (y - 10);	/* rows above the bottom */
		const volatile u16 *sr = src + (19 - j) * 112, *a = src + y * 112;
		u16 *d = fb + (y0 + y) * W + x0;
		if (y0 + y < 0 || y0 + y >= 480)
			continue;
		for (x = 0; x < 86; x++)
			d[x] = sr[x];
		for (; x < 112; x++)
			d[x] = a[x];
	}
}

static void track_row(int sid, int k, int y, int h, int x1, u32 sid1, int unfocus)
{
	const volatile u8 *sl = SLOT(0, k + 1);
	u32 flags = u32be(sl + 0x0C), id = u16be(sl + 0x14);
	int n = u16len(sl), cursor = flags & 8, ty = y + (h - 25) / 2, x = RAIL_W + 132, tmax = x1 - 132;
	u32 num = row_no(k);
	u16 bg = V3E_PROW == k && !cursor ? C_PRESS : cursor ? (unfocus ? C_UNF : C_SEL) : (k & 1) ? C_ROW2 : C_BLACK;
	u16 fg = (flags & 1) && !cursor ? C_DIM : C_WHITE;
	/* the row being previewed keeps its WHITE text on the 3000 (seen running, re/LINKCUE_3000_LIVE_1121.md: its
	 * small waveform is greyed with a green line at the playing point; R22D1 still had bright green text here) */
	if (pl_seen(row_th(sl)))
		fg = cursor ? C_PLAYED_CUR : C_PLAYED;	/* loaded and played on this deck this session */
	fill(RAIL_W, y, x1 - RAIL_W, h, bg);
	if (!n && !id)
		return;
	if (id == 0x5A)
		fg = cursor ? C_WHITE : C_GREEN;	/* the track loaded on this player */
	else if (V3E_ELSE(k) && !cursor)
		fg = 0x3C67;		/* V3e2 (audit B8): loaded on another deck -- the 3000's dim green #3C8C3C */
	if (flags & 0x10) {
		if (u32be(sl + 0x1C)) {		/* the rowwave cell: 112 x 20 */
			int cy = y + (h - 20) / 2;
			if (cell_blank(SMALL_ART(k + 1)))
				;	/* V3rc2: no preview data (no analysis): nothing, as the 3000 (was a black bar) */
			else
				cell_img(SMALL_ART(k + 1), RAIL_W + 8, cy);
			if (V3E_PV_ROW == k + 1) {	/* V4n10 (3000 emu): the preview's playing point = a GREEN line,
							 * nothing dimmed */
				int px = (int)udiv(V3E_PV_COL * 86, 600);	/* V4n28 (audit): the wave is 86 columns, not 112 */
				fill(RAIL_W + 8 + px, cy - 2, 2, 24, 0x07E0);
			}
		}
#ifdef V3E2
		if (num && x1 >= 600) {	/* V3e2 (audit B4): the 3000's # column */
			char b[6];	/* V3rc2: the 3000's "001" in the title's size and colour */
			if (num < 1000) {
				b[0] = '0' + udiv(num, 100); b[1] = '0' + udiv(num, 10) % 10; b[2] = '0' + num % 10; b[3] = 0;
				text_r(&f_m, RAIL_W + 166, ty, b, cursor ? C_WHITE : fg, bg);
			} else {
				fmt_u(b, num);
				text_r(&f_s, RAIL_W + 166, ty + 4, b, cursor ? C_WHITE : fg, bg);
			}
			x = RAIL_W + 174;
		}
#else
		(void)num;
#endif
	} else
		x = RAIL_W + 12;
	if (id == 0x34)
		x += icon_id(0x0F, x, y + h / 2, C_GREEN, bg) + 6;
	else if (id == 0x2F || id == 0x5A || id == 0x31 || id == 0x3C) {
		icon_scaled(V2A_TITLE_TRACK, x, y + h / 2 - 9, 12, 18,
			    id == 0x5A ? C_GREEN : pl_seen(row_th(sl)) ? (cursor ? C_PLAYED_CUR : C_PLAYED) : C_WHITE, bg);
		x += 18;
	} else if (id)
		x += icon_id(id, x, y + h / 2, C_WHITE, bg) + 6;
	if ((flags & 0x10) && x1 >= 600) {	/* (INFO's narrow list: the title only) */
		const volatile u8 *m = sl + 0x2A + 0x1A0;
		int mn = 0, b0, bn, k0, kn;
		while (mn < 40 && u16be(m + 2 * mn))
			mn++;
		meta_split(m, mn, &b0, &bn, &k0, &kn);
		if (bn == 3 && u16be(m + 2 * b0) == '0' && u16be(m + 2 * b0 + 4) == '0')
			bn = 0;		/* V3rc2: "0.0" (no BPM) left blank, as the 3000 */
		if (bn) {
			int bw = row_text_w(&f_m, m + 2 * b0, bn);
			text_u16(&f_m, x1 - 64 - bw, ty, m + 2 * b0, bn, x1, cursor ? C_WHITE : fg, bg);
		}
		/* V4n30a (scaling audit): the 3000's dividers at 1079 / 1189 x 0.625 -- title | BPM 674, BPM | KEY 743 */
		fill(x1 - 126, y, 1, h, C_BLACK);
		fill(x1 - 57, y, 2, h, C_BLACK);	/* V3rc2: the 3000's BPM | KEY cell divider */
		if (kn) {
			int kc = key_code(m + 2 * k0, kn), kfn = kn, kw;
			const volatile u8 *kft = kf_key(m + 2 * k0, &kfn);	/* V4n36: the KEY FORMAT */
			/* R21 parity (b): the cursor row keeps its green KEY cell too -- the real 3000 (re/cdj3k_refs/video/
			 * 24_search_results.jpg: the selected blue row "Saccharine 374" shows 5A on the green c017 cell;
			 * skin NT_ColorList c016/c017 = KEY match text 0 / bg 0,255,0, no selected-row variant) */
			int g = key_compat(kc, ref_key());
			kw = row_text_w(&f_m, kft, kfn);
			if (g)
				fill(x1 - 54, y + 6, 52, h - 12, C_KEYG);	/* V4n30a: the 56-px KEY cell */
			KIT(if (g) kit_gr++; if (cursor) kit_gcur = 2u | (g ? 1u : 0u);)
			text_u16(&f_m, x1 - 28 - kw / 2, ty, kft, kfn, x1, g ? C_BLACK : fg, g ? C_KEYG : bg);
		}
	} else
		tmax = x1 - 8;
	if (sort_extra(sid1)) {		/* the stock sort column (ARTIST, ALBUM, RATING ...) */
		const volatile u8 *f = SLOT(1, k + 1);
		if (u16len(f))
			text_u16(&f_m, x1 - 290, ty, f + 0x2A, u16len(f), x1 - 172, C_LBL, bg);
		tmax = x1 - 298;
	}
	if (u32be(sl + 0x0C) & 8)	/* V3rc8: the selected row's title scrolls (3000 ScrollLabel) */
		text_u16_mq(&f_m, x, ty, sl + 0x2A, n, tmax, fg, bg, hslot(0x51A, sl) ^ (u32)k);
	else
		text_u16(&f_m, x, ty, sl + 0x2A, n, tmax, fg, bg);
}

/* V4n11 (CDJ-3000 browse): the cursor's track row shows a LOAD button over its BPM / KEY columns (light grey,
 * dark text); MAIN (modsmenu va_rows0) loads on a tap there */
/* V4n30 (user, CDJ-3000): LOAD shows only on a row selected by TOUCH; moving the cursor with the rotary
 * (cursor changes without a pressed row) hides it -- the row keeps its BPM / KEY */
/* R21 parity (d): emu R21P02, a preview lifted on row 3 with the cursor on row 7 ended with row 3 selected but no
 * LOAD (a 1-row title tap showed it) -- most likely MAIN's seek passes the rows between and the first cursor change
 * dropped the tap (inferred, not traced). Cursor moves within 800 ms of the press keep it; after that the cursor anywhere else drops it as before. */
static int lb_tap_k = -1;
static u32 lb_t;
static void lb_update(int cursor_k)
{
	if (V3E_PROW >= 0) {
		lb_tap_k = V3E_PROW;
		lb_t = now_ms();
	}
	if (lb_tap_k >= 0 && cursor_k != lb_tap_k && now_ms() - lb_t > 800)
		lb_tap_k = -1;	/* (the cursor settled elsewhere: as before, a move off the row drops the tap) */
}
static void load_btn(int k, int y, int h, int x1)
{
	const volatile u8 *sl = SLOT(0, k + 1);
	if (!(u32be(sl + 0x0C) & 8) || x1 < 760 || k != lb_tap_k)
		return;
	fill(x1 - 125, y + 2, 123, h - 4, 0xDEDB);	/* V4n30a (scaling audit): the 3000's 200 px over BPM + KEY, x 0.625 */
	text_c(&f_m, x1 - 63, y + (h - 25) / 2, "LOAD", 0x2945, 0xDEDB);
}
/* a plain row (categories, folders, playlists, side-1 preview rows): icon + text */
static void plain_row(const volatile u8 *sl, int k, int x0, int x1, int y, int h, int unfocus, int dim)
{
	u32 flags = u32be(sl + 0x0C), id = u16be(sl + 0x14);
	int n = u16len(sl), cursor = !dim && (flags & 8), x = x0 + 12;
	u16 bg = !dim && V3E_PROW == k && !cursor ? C_PRESS : cursor ? (unfocus ? C_UNF : C_SEL) : (k & 1) ? C_ROW2 : C_BLACK;
	u16 fg = dim ? C_LBL : (flags & 1) && !cursor ? C_DIM : C_WHITE;
	fill(x0, y, x1 - x0, h, bg);
	if (!n && !id)
		return;
	const volatile u8 *pt = sl + 0x2A;
	if (id)
		x += icon_id(id, x, y + h / 2, dim ? C_LBL : id == 0x5A ? C_GREEN : C_WHITE, bg) + 6;
	if (id == 0x0F || id == 0x34)	/* V4n36: MAIN's KEY list rows (classic names) in the KEY FORMAT */
		pt = kf_list(pt, &n);
	if (cursor)	/* V3rc8: the selected row scrolls (3000 ScrollLabel) */
		text_u16_mq(&f_m, x, y + (h - 25) / 2, pt, n, x1 - 8, fg, bg, hslot(0x51B, sl) ^ (u32)k);
	else
		text_u16(&f_m, x, y + (h - 25) / 2, pt, n, x1 - 8, id == 0x5A ? C_GREEN : fg, bg);
}

/* ---- the thin deck strip (y 420..479; 3000 frames 20-27, cdj3k-3.20 browse-root) ---- */
static int ov_ready(int allow_mono);
static void strip(int info_title)
{
	char buf[16];
	u32 trackno = u32be(DECK + 0x60);
	int failed = load_failed();
	u32 loaded = failed ? 0 : trackno;
	/* NAVART (emu, PUSH on a list row: the strip went old track -> 00:00 / --.- (MAIN's 0xBBBBBBBB) -> the new
	 * track's half-filled values over ~6 frames, then the player's Loading): the browse strip, while a load is in
	 * (load marker / the gate) the strip keeps what it shows -- unless it was never drawn on this screen */
	{
		static u32 fz_t;	/* (emu, LINK reload: the heartbeat's length drops to 0 a frame before the marker) */
		if ((lg_on || trackno == LG_TN_LOADING || (trackno && !u32be(DECK + 0x7C) && !failed))) {
			u32 t = now_ms();
			if (!fz_t)
				fz_t = t | 1;
			if (rk[rb][2] && (s32)(t - fz_t) < 3000)
				return;
		} else
			fz_t = 0;
	}
	s32 tempo_raw = pitch_raw();
	u32 range = u32be(DECK + 0x44);
	u32 bpm10 = u32be(DECK + 0x68);
	u32 el = u32be(DECK + 0x78), len = u32be(DECK + 0x7C);
	u32 mt = u32be(DECK + 0x20), remain_mode = u32be(DECK + 0x40);
	u32 master = loaded && is_master(), sync = u32be(DECK + 0x28) == 1;
	int air = on_air(), bpm_unknown = bpm10 >= 10000;
	u32 t, pos;
	if (!loaded)
		el = len = bpm10 = 0;
	if (len >= 100 * 60 * 1000)
		len = 0;
	if (el > len)
		el = len;
	if (range > 4)
		range = 2;
	t = remain_mode ? len - el : el;
	deck_free = !loaded;
	if (need(2, hmix(hmix(player_num(), air), remain_mode))) {
		fill(0, STRIP_Y, W, 480 - STRIP_Y, C_BLACK);
		fill(0, STRIP_Y, W, 1, C_BAR);
		frame(8, 425, 44, 50, 1, C_FRAME);
		text_c(&f_t, 30, 428, "PLAYER", C_WHITE, C_BLACK);
		buf[0] = '0' + player_num() % 10; buf[1] = 0;
		text_c(&f_m, 30, 445, buf, C_WHITE, C_BLACK);
		if (air) {	/* the 3000's red ((n)) */
			fill(16, 450, 2, 12, C_RED); fill(14, 452, 2, 8, C_RED);
			fill(42, 450, 2, 12, C_RED); fill(44, 452, 2, 8, C_RED);
		}
		text(&f_t, 62, 424, remain_mode ? "REMAIN" : "ELAPSED", C_WHITE, C_BLACK);
		rforce |= 1;
	}
	if (need(3, hmix(udiv(t, 1000), failed))) {
		fill(60, 437, 112, 42, C_BLACK);
		if (failed)
			text(&f_l, 60, 437, "--:--", C_WHITE, C_BLACK);
		else {
			fmt_mmss(buf, t);
			text(&f_l, 60, 437, buf, C_WHITE, C_BLACK);
		}
	}
	/* the loaded track's mini overview (176..520) with its playhead, or its title, or red "Not Loaded." */
	pos = loaded && len ? udiv(udiv(el, 16) * 344, udiv(len, 16) ? udiv(len, 16) : 1) : 0;
	if (loaded && snap_tid == hmix(trackno, u32be(DECK + 0x7C)) && snap_look != ov_look()) {
		int ok;		/* OVSHAPE3: the look changed off the player -- rebuild the snapshot now */
		wave_on();
		ok = ov_ready(snap_mono) && ov_src == snap_src;
		wave_off();
		if (ok)
			strip_snap(snap_tid, snap_mono);
		else
			snap_look = ov_look();	/* the records hold another track: keep it, no retry */
	}
	{
		int ovok = loaded && !info_title && snap_tid == hmix(trackno, u32be(DECK + 0x7C));
		u32 kt = hmix(hmix(hmix(loaded, failed), ovok ? pos + 1 : 0), info_title);
		kt = hmix(hmix(kt, g_tid), g_tn);
		if (ovok)
			kt = hmix(hmix(kt, snap_builds), wave_type);
		if (ovok && smk_tid == snap_tid)
			kt = hmix(kt, smk_ck);	/* R21 parity (c) */
		if (need(4, kt)) {
			fill(176, 421, 346, 57, C_BLACK);	/* R21 parity (c): from 421, the hot-cue badge row */
			if (failed)
				text_c(&f_m, 348, 436, u16be(ERR_TXT + 10) == '5' ? "Unsupported file format." :
				       "Media or File is collapsed.", C_RED, C_BLACK);
			else if (!loaded)
				text_c(&f_m, 348, 436, "Not Loaded.", C_RED, C_BLACK);
			else if (ovok) {	/* the player's snapshot, played part from the played image */
				int y;
				wave_on();
				if (pos > SNAP_W) pos = SNAP_W;
				dmark(432, SNAP_H);
				for (y = 0; y < SNAP_H; y++) {
					u16 *d = fb + (432 + y) * W + 176;
					cp16(d, SNAP_P + y * SNAP_W, (int)pos);
					cp16(d + pos, SNAP_U + y * SNAP_W + pos, SNAP_W - (int)pos);
				}
				fill(176, 469, pos, 1, C_RED);
				if (smk_tid == snap_tid)	/* R21 parity (c): hot cues / memory cues above, the cue under */
					strip_marks(176, SNAP_W, len, 421, 432, 470);
				fill(176 + pos, 430, 1, 40, C_WHITE);
				wave_off();
			} else if (g_tn && g_tid == hmix(trackno, u32be(DECK + 0x7C))) {
				icon_scaled(V2A_TITLE_TRACK, 180, 440, 12, 18, C_LBL, C_BLACK);
				text_u16(&f_m, 198, 437, g_title, g_tn, 520, C_WHITE, C_BLACK);
			}
		}
	}
	{	/* KEY | MT | range | tempo % */
		u32 fb10 = loaded && (sync || bpm_mode()) ? fader_bpm10() : 0;	/* V4n34: the fader's BPM, grey */
		int tko = fader_dir(fb10, sync, bpm10);
		u32 hk = hmix(hmix(hmix(hmix(g_kn, g_kid), mt != 0), range), (u32)tempo_raw + 7 * sync + 3 * loaded);
		hk = hmix(hk, fb10 + ((u32)(tko + 1) << 16));
#ifdef V2_KEYSHIFT
		hk = hmix(hk, (u32)KS_SEMI);
		hk = hmix(hk, KS_AMT_H());	/* KSAMT (V4n43) */
#endif
		hk = hmix(hk, (u32)KF_CLASSIC);	/* V4n36 */
		if (need(5, hk)) {
			static const u16 RC[] = { C_GREEN, C_GREEN, C_OR, C_OR, C_OR };
			int sd = day;
			fill(524, 421, 190, 58, C_BLACK);
			if (loaded && g_kn && g_kid == hmix(trackno, u32be(DECK + 0x7C))) {
				int kdn = g_kn;
				u16 kc = C_WHITE;
				const volatile u8 *kd = kf_key(g_key, &kdn);	/* V4n36: the KEY FORMAT */
#ifdef V2_KEYSHIFT
				kdn = g_kn;
				kd = ks_key(g_key, &kdn, &kc);
#endif
				text_u16(&f_m, 528, 448, kd, kdn, 586, kc, C_BLACK);
#ifdef V2_KEYSHIFT
				{	/* KSAMT (V4n43): the amount right of the key, two small orange rows (up to the MT box) */
					char a1[8], a2[8];
					if (ks_amt(a1, a2)) {
						int ax = 528 + row_text_w(&f_m, kd, kdn) + 4;
						if (ax > 594 - text_w(&f_s, a2[0] ? a2 : a1))
							ax = 594 - text_w(&f_s, a2[0] ? a2 : a1);
						if (a1[0])
							text(&f_s, ax, a2[0] ? 445 : 453, a1, C_OR, C_BLACK);
						if (a2[0])
							text(&f_s, ax, a1[0] ? 460 : 453, a2, C_OR, C_BLACK);
					}
				}
#endif
			}
			day = 0;	/* hardware semantics: the same chips in LIGHT / FULL */
			/* V3rc2: the 3000 strip shows the MT box always, lit when MASTER TEMPO is on */
			frame(596, 426, 40, 16, 1, mt ? C_OR : 0x4A69);
			text_c(&f_s, 616, 427, "MT", mt ? C_OR : 0x4A69, dm(C_BLACK));
			if (range == 3) {	/* +-16: white outline, no fill */
				frame(642, 426, 46, 16, 1, sd ? 0x1082 : 0xFFFF);
				text_c(&f_s, 665, 427, RANGE[range], sd ? 0x1082 : 0xFFFF, sd ? 0xF79E : 0);
			} else if (range == 4)	/* WIDE: red text, no box */
				text_c(&f_s, 665, 427, RANGE[range], 0xF800, sd ? 0xF79E : 0);
			else {
				fill(642, 426, 46, 16, RC[range]);
				text_c(&f_s, 665, 427, RANGE[range], C_BLACK, RC[range]);
			}
			day = sd;
			if (failed)
				text_r(&f_m, 700, 450, "0.00", C_WHITE, C_BLACK);
			else if (fb10) {	/* V4n34: SYNC / held tempo: the fader's BPM, grey (no %) */
				fmt_bpm(buf, fb10, 0);
				text_r(&f_m, 712, 450, buf, C_GREY, C_BLACK);
				if (tko)
					tko_arrow(712 - text_w(&f_m, buf) - 9, 453, tko, 5, C_WHITE);
			} else {
				fmt_pitch(buf, tempo_raw, range);
				text_r(&f_m, 700, 450, buf, C_WHITE, C_BLACK);
			}
			if (failed || !fb10)
				text(&f_s, 702, 456, "%", C_WHITE, C_BLACK);
		}
	}
	if (need(6, hmix(hmix(hmix(bpm10, master), sync), loaded + 2 * bpm_unknown))) {
		fill(716, 421, 84, 58, C_BLACK);
		frame(718, 425, 78, 50, 1, master ? C_MASTER : C_FRAME);
		if (master) {
			fill(756, 421, 40, 9, C_MASTER);
			text_c(&f_t, 776, 420, "MASTER", C_BLACK, C_MASTER);
		}
		text(&f_t, 722, 428, sync ? "BEAT SYNC" : "BPM", sync ? C_SEL : C_WHITE, C_BLACK);
		if (loaded && !bpm_unknown) {
			fmt_bpm(buf, bpm10, 0);
			text_r(&f_m, 792, 446, buf, master ? C_MASTER : C_WHITE, C_BLACK);
		} else if (loaded)
			text_r(&f_m, 792, 446, "--.-", C_WHITE, C_BLACK);
	}
}

/* the INFO screen's Link Cue band (the browsed track's overview, its play column in white), y 376..418 */
static void __attribute__((unused)) lc_band(void)
{
	u32 k = hmix(hmix(hmix(ov_ck(), u32be(OV_HDR + 4)), OV_HIDE), wave_type + 4 * OV_COLOUR + 8 * (u32)ov_full);
	if (need(9, k)) {
		fill(RAIL_W, 372, W - RAIL_W, 48, C_BLACK);
		fill(RAIL_W, 372, W - RAIL_W, 1, C_BAR);
		text(&f_s, RAIL_W + 4, 376, "LINK", C_GREY, C_BLACK);
		text(&f_s, RAIL_W + 4, 390, "CUE", C_GREY, C_BLACK);
		wave_on();
		fill(OV_X, 376, 640, OVH, C_BLACK);
		overview(OV_X, 376, 640, OVH, 0, 0);
		wave_off();
	}
}

/* SHORT CUT (screen 0x1E) in the CDJ-3000 layout (frame 04, re/V3E_DESIGN.md §6.2): the stock tiles' touch
 * zones (MAIN class 10) are moved to these rects by the v2ui MAIN pseudo-mod (v2needle). States: heartbeat
 * one-hots -- hot cue auto load +0x15F/+0x163/+0x167, quantize +0x16B..+0x177; the phase meter style and
 * WAVEFORM COLOR / CURRENT POSITION from our +0x54 word. LCD / JOG BRIGHTNESS and BEAT JUMP BEAT VALUE have
 * no touch yet (V3e2): drawn dimmed. */
#define C_TILED 0x10A2		/* #141414 disabled */
#define C_SECT 0x4208		/* #424242 dividers */
#define C_SCBG 0x0000		/* V3rc6: black page (3000 shortCut.csv; was #323232) */

static void sc_tile(int x, int y, int w, int h, const char *t, int sel, int dis)
{
	u16 bg = sel ? C_SEL : C_SCOFF;
	/* V3rc6 (3000 skin img_btn*Sc, shortCut.csv Bg01Sc): flat #3C3C3C / #007DE1 inside a solid 1-px white frame */
	fill(x, y, w, h, bg);
	frame(x, y, w, h, 1, dis ? 0x4208 : C_WHITE);
	if (t)
		text_c(&f_s, x + w / 2, y + (h - 15) / 2, t, dis ? C_UNF : C_WHITE, bg);
}
static int on(int off) { return DECK[off] != 0; }

static void shortcut(void)
{
	static const char *const QV[] = { "1/8", "1/4", "1/2", "1" };
	static const char *const BJ[] = { "1/2", "1", "2", "4", "8", "16", "32", "64" };
	int i;
	u32 h = hmix(hmix(hmix(pm_style, wave_type), ph_left), day | day_full << 1);
	for (i = 0x15F; i <= 0x177; i += 4)
		h = hmix(h, DECK[i]);
	h = hslot(h, SLOT(0, 0));
	/* D1 (deck: SHORTCUT 25 fps): stock's SHORT CUT windows are ours now (orules: neither drawn nor composed)
	 * and the page goes through the canvas (SMOOTH) -- drawn only when its inputs change (region 11: an
	 * overlay over it resets it, ovl_blit's browse-family mask) */
	h = hmix(hmix(hmix(h, u16be(SLOT(0, 0) + 0x14)), player_num()), wave_type << 4 | pm_style);
#ifdef V3E2
	h = hmix(hmix(h, v3e_w), v3e_d);
#endif
#ifdef V2_KEYSHIFT
	h = hmix(h, KS_RBM);
#endif
	if (need(11, h)) {
		fill(0, 0, W, STRIP_Y, C_SCBG);
		fill(0, 0, W, 60, C_BAR);	/* V3rc6: the 3000's #191919 header over a black page */
		text(&f_m, 16, 14, "SHORTCUT", C_WHITE, C_BAR);
		text(&f_t, 19, 90, "WAVEFORM / PHASE METER", C_UTL, C_SCBG);
		sc_tile(19, 103, 62, 42, 0, pm_style == 1, 0);
		sc_tile(82, 103, 64, 42, 0, pm_style == 0, 0);
		sc_tile(148, 103, 64, 42, 0, pm_style == 2, 0);
		{	/* pictograms: a mini waveform, ticks on two lines, the classic boxes */
			u16 b0 = pm_style == 1 ? C_SEL : C_SCOFF, b1 = pm_style == 0 ? C_SEL : C_SCOFF, b2 = pm_style == 2 ? C_SEL : C_SCOFF;
			for (i = 0; i < 9; i++) {
				int hh = (i * 5) % 7 + 2;
				fill(26 + 5 * i, 116 - hh / 2, 3, hh, C_WHITE);
			}
			(void)b0;
			fill(90, 110, 48, 1, C_PHO);
			fill(90, 120, 48, 1, C_PHB);
			for (i = 0; i < 5; i++)
				fill(90 + 12 * i, 117, 1, 6, C_WHITE);
			(void)b1;
			for (i = 0; i < 4; i++) {
				frame(154 + 13 * i, 109, 11, 5, 1, C_PHO);
				frame(154 + 13 * i, 118, 11, 5, 1, C_PHB);
			}
			(void)b2;
			text_c(&f_t, 50, 131, "WAVEFORM", C_WHITE, b0);
			text_c(&f_t, 114, 131, "PHASE", C_WHITE, b1);
			text_c(&f_t, 180, 131, "4 BARS", C_WHITE, b2);
		}
		text(&f_t, 224, 90, "HOT CUE AUTO LOAD", C_UTL, C_SCBG);
		sc_tile(224, 103, 62, 42, "ON", on(0x15F), 0);
		sc_tile(287, 103, 62, 42, 0, on(0x163), 0);
		icon(V2A_SETTINGS, 309, 110, C_WHITE, on(0x163) ? C_SEL : C_SCOFF);
		text_c(&f_t, 318, 129, "SETTING", C_WHITE, on(0x163) ? C_SEL : C_SCOFF);
		sc_tile(350, 103, 62, 42, "OFF", on(0x167), 0);
		text(&f_t, 19, 164, "LCD BRIGHTNESS", C_UTL, C_SCBG);
#ifdef V3E2
		{	/* V3e2: live (MAIN v3e_touch steps them; values in heartbeat +0xE8 bits 24-26 / 27-28) */
			static const char *const JG[] = { "OFF", "1", "2", "-" };
			char b[2];
			int on3 = v3e_w != 0;
			u16 fc = on3 ? C_WHITE : C_UNF;
			b[0] = '1' + ((v3e_w >> 24) & 7); b[1] = 0;
			sc_tile(17, 177, 187, 40, 0, 0, !on3);
			text_c(&f_m, 48, 184, "<", fc, C_SCOFF);
			text_c(&f_m, 110, 184, on3 ? b : "", fc, C_SCOFF);
			text_c(&f_m, 172, 184, ">", fc, C_SCOFF);
			text(&f_t, 221, 164, "JOG BRIGHTNESS", C_UTL, C_SCBG);
			sc_tile(221, 177, 187, 40, 0, 0, !on3);
			text_c(&f_m, 252, 184, "<", fc, C_SCOFF);
			text_c(&f_m, 314, 184, on3 ? JG[(v3e_w >> 27) & 3] : "", fc, C_SCOFF);
			text_c(&f_m, 376, 184, ">", fc, C_SCOFF);
		}
#else
		sc_tile(17, 177, 187, 40, 0, 0, 1);
		text_c(&f_m, 48, 184, "<", C_UNF, C_SCOFF);
		text_c(&f_m, 172, 184, ">", C_UNF, C_SCOFF);
		text(&f_t, 221, 164, "JOG BRIGHTNESS", C_UTL, C_SCBG);
		sc_tile(221, 177, 187, 40, 0, 0, 1);
		text_c(&f_m, 252, 184, "<", C_UNF, C_SCOFF);
		text_c(&f_m, 376, 184, ">", C_UNF, C_SCOFF);
#endif
		text(&f_t, 17, 238, "QUANTIZE BEAT VALUE", C_UTL, C_SCBG);
		for (i = 0; i < 4; i++)
			sc_tile(17 + 62 * i, 251, 61, 42, QV[i], on(0x16B + 4 * i), 0);
		text(&f_t, 15, 311, "BEAT JUMP BEAT VALUE", C_UTL, C_SCBG);
		for (i = 0; i < 8; i++)
#ifdef V3E2
			sc_tile(15 + 62 * (i & 3), 325 + 40 * (i >> 2), 61, 39, BJ[i], (v3e_d & 0x80) && i == V3E_BJ,
				!(v3e_d & 0x80) || !i);	/* V3e3: MAIN bj_v (1/2: whole beats only) */
#else
			sc_tile(15 + 62 * (i & 3), 325 + 40 * (i >> 2), 61, 39, BJ[i], 0, 1);
#endif
		/* source */
		{
			u32 id = u16be(SLOT(0, 0) + 0x14);
			int a = v2a_for_icon(id == 0x50 || !id ? 0x54 : id);
			char b[2];
			fill(436, 85, 334, 66, C_CK2);	/* V3rc6: #232323 media name panel (3000) */
			fill(436, 85, 58, 66, C_NAVY);
			fill(436, 85, 13, 14, C_WHITE);
			b[0] = '0' + player_num() % 10; b[1] = 0;
			text_c(&f_s, 442, 85, b, C_BLACK, C_WHITE);
			if (a >= 0)
				icon(a, 465 - v2a_rects[a].w / 2, 99 + SRC_DY(a), C_WHITE, C_NAVY);
			/* V3rc6: the real source (the NXS2 keeps DISC, which the 3000 has not) */
			text_c(&f_s, 465, 128, id == 0x51 ? "LINK" : id == 0x63 ? "SD" : id == 0x58 ? "DISC" : "USB",
			       C_WHITE, C_NAVY);
			text_u16(&f_m, 508, 105, SLOT(0, 0) + 0x2A, u16len(SLOT(0, 0)), 764, C_WHITE, C_CK2);
		}
		/* V3rc6 (shortCut.csv BgMediaNameSc): the media column on #232323, MY SETTINGS on #191919 */
		fill(436, 156, 238, 212, C_CK2);
		fill(676, 156, 94, 212, C_BAR);
		text(&f_t, 451, 168, "WAVEFORM COLOR", C_UTL, C_CK2);
		sc_tile(452, 181, 63, 42, 0, wave_type == 2, 0);
		sc_tile(516, 181, 62, 42, 0, wave_type == 1, 0);
		sc_tile(579, 181, 62, 42, 0, wave_type == 0, 0);
		fill(466, 190, 36, 8, 0x02BD);
		fill(529, 190, 12, 8, C_RED); fill(541, 190, 12, 8, 0x07E0); fill(553, 190, 12, 8, 0x001F);
		fill(592, 190, 12, 8, C_LO); fill(604, 190, 12, 8, C_MI); fill(616, 190, 12, 8, C_HI);
		text_c(&f_t, 484, 206, "BLUE", C_WHITE, wave_type == 2 ? C_SEL : C_SCOFF);
		text_c(&f_t, 547, 206, "RGB", C_WHITE, wave_type == 1 ? C_SEL : C_SCOFF);
		text_c(&f_t, 610, 206, "3BAND", C_WHITE, wave_type == 0 ? C_SEL : C_SCOFF);
		text(&f_t, 449, 243, "WAVEFORM CURRENT POSITION", C_UTL, C_CK2);
		sc_tile(449, 257, 62, 40, "LEFT", ph_left, 0);
		sc_tile(512, 257, 62, 40, "CENTER", !ph_left, 0);
		text(&f_t, 687, 168, "MY SETTINGS", C_UTL, C_BAR);
		sc_tile(683, 181, 68, 42, "LOAD", 0, 0);
		sc_tile(683, 234, 68, 42, "SAVE", 0, 0);
#ifdef V2_KEYSHIFT
		if (KS_RBM)	/* V4k: the rekordbox key works KEY SHIFT; its stock function by touch (MAIN rbk_set) */
			sc_tile(683, 287, 68, 42, "rekordbox", 0, 0);
#endif
		/* V3rc8q: SCREEN MODE tile removed -- SMOOTH+ (+ sub-pixel) is the only present mode */
	}
	strip(0);
}

/* player-screen INFO (screen 0x08, INFO pressed on the player): the loaded track's sheet, 3000-style.
 * Side 0: slot 0 source title ("USB@PLAYER1"), slot 1 the title (icon 0x04), slots 2..8 artist (0x07),
 * album (0x02), time (0x0B), BPM (0x0D), key (0x0F), rating (0x0A), comment (0x13); side 1 slot 0
 * "TRACK 001/003" (re/V2_P4.md). The loaded track's artwork is not sent: the 3000 disc placeholder. */
static void player_info(void)
{
	int k, y;
	u32 h = 0;
	for (k = 0; k < 9; k++)
		h = hmix(hslot(hslot(h, SLOT(0, k)), SLOT(1, k)), u16be(SLOT(0, k) + 0x14));
	/* D1: stock's INFO windows are ours now (orules) and the page goes through the canvas (SMOOTH): drawn only
	 * when its inputs change (region 11, as SHORTCUT). Was every frame (V3e1h: stock drew its own panels into
	 * the GR3 buffers -- the canvas never holds them; the self-heal / change copy re-send any it composes) */
	h = hmix(hmix(hmix(h, ldart_seq()), u32be(DECK + 0x60)), load_failed() | (art_tag == art_tid()) << 1 | KF_CLASSIC << 2);
	h = hmix(hmix(h, (u32)g_tn), (u32)g_kn);
	for (k = 0; k < 2 * g_tn && k < 128; k++)
		h = hmix(h, g_title[k]);
	for (k = 0; k < 2 * g_kn && k < 16; k++)
		h = hmix(h, g_key[k]);
	if (need(11, h)) {
		fill(0, 0, W, STRIP_Y, C_BLACK);
		fill(0, 0, W, 60, C_BAR);
		source_tile(u16be(SLOT(0, 0) + 0x14));
		text_u16(&f_m, 70, 17, SLOT(0, 0) + 0x2A, u16len(SLOT(0, 0)), 520, C_WHITE, C_BAR);
		{
			const volatile u8 *t = SLOT(1, 0);
			int n = u16len(t), w = row_text_w(&f_m, t + 0x2A, n);
			text_u16(&f_m, 786 - w, 17, t + 0x2A, n, 790, C_LBL, C_BAR);
		}
		frame(18, 76, 166, 166, 1, C_ART);
		if (ldart_seq() && u32be(DECK + 0x60) && !load_failed())	/* G2 */
			ldart_draw(19, 77, 164, 164);
		else if (art_tag == art_tid() && u32be(DECK + 0x60) && !load_failed())	/* V3e3: the kept artwork */
			image((const volatile u16 *)ART_C, 113, 121, 120, 19, 77, 164, 164);
		else
			icon_scaled(V2A_NOART_INFO, 19, 77, 164, 164, C_GREY, C_BLACK);
		if (u16len(SLOT(0, 1)))
			text_u16(&f_m, 204, 78, SLOT(0, 1) + 0x2A, u16len(SLOT(0, 1)), 786, C_WHITE, C_BLACK);
		else if (g_tn) {	/* V4n: rows not there yet (or never, 7.2.19 exports): the loaded track's own */
			text_u16(&f_m, 204, 78, g_title, g_tn, 786, C_WHITE, C_BLACK);
			if (g_kn) {
				text(&f_t, 238, 122, "KEY", C_LBL, C_BLACK);
				int kfn = g_kn;
				const volatile u8 *kft = kf_key(g_key, &kfn);	/* V4n36: the KEY FORMAT */
				text_u16(&f_m, 300, 117, kft, kfn, 786, C_WHITE, C_BLACK);
			}
		}
		fill(204, 106, 582, 1, C_SECT);
		{	/* G2: the 3000's order: artist, album, BPM, key, time, then rating / comment (the model's own is
			 * artist, album, time, BPM, key, ...); the key row stays the white one */
			static const u8 ord[] = { 0x07, 0x02, 0x0D, 0x0F, 0x0B, 0x0A, 0x13 };
			int r, pass = 0;
			for (r = 0, y = 114; r < 8; r++) {
				for (k = 2; k <= 8; k++) {
					const volatile u8 *sl = SLOT(0, k);
					u32 id = u16be(sl + 0x14), rk0 = 7, i;
					int n = u16len(sl);
					for (i = 0; i < 7; i++)
						if (ord[i] == id)
							rk0 = i;
					if ((u32)r != rk0 || (!id && !n))
						continue;
					if (id == 0x02) id = 0x06;
					if (id == 0x13) id = 0x23;
					const volatile u8 *vt = sl + 0x2A;
					{	/* ICONS: the INFO page's 20-px field pictograms */
						int ba = v2a_for_big(id);
						if (ba >= 0)
							icon(ba, 206, y + 14 - v2a_rects[ba].h / 2, 0x632C, C_BLACK);	/* 3000 Info icons #646464 */
					}
					if (id == 0x0F)
						vt = kf_key(vt, &n);	/* V4n36: the key in the KEY FORMAT */
					text_u16(&f_m, 238, y + 3, vt, n, 786, id == 0x0F ? C_WHITE : C_LBL, C_BLACK);
					fill(204, y + 32, 582, 1, C_ROW2);
					y += 36;
				}
			}
			(void)pass;
		}
	}
	strip(0);
}

/* ---- UTILITY (3000 frames 07-14): category column, rows, the radio list of the cursor row ---- */
/* label -> category (1 DJ SETTING, 2 DISPLAY (LCD), 3 DISPLAY (INDICATOR), 4 PRO DJ LINK, 5 SYSTEM, 6 INFO)
 * and its options ('|'-separated, as MAIN's item table: re/UTILITY_ITEMS.md; ours from mods/modsmenu) */
static const char UT_TAB[] =
	"\1PLAY MODE\0CONTINUE|SINGLE\0"
	"\1EJECT/LOAD LOCK\0UNLOCK|LOCK\0"
	"\1QUANTIZE BEAT VALUE\0" "1/8 Beat|1/4 Beat|1/2 Beat|1 Beat\0"
	"\1HOT CUE AUTO LOAD\0OFF|rekordbox SETTING|ON\0"
	"\1HOT CUE COLOR\0OFF|ON\0"
	"\1AUTO CUE LEVEL\0-78dB|-72dB|-66dB|-60dB|-54dB|-48dB|-42dB|-36dB|MEMORY\0"
	"\1KEY SHIFT\0OFF|ON\0"	/* V4n23: ours (mods/keyshift), was missing its radio list */
	"\1KEY SYNC BUTTON\0OFF|ON\0"	/* V4n24: ours (mods/keyshift hc_set / hc_lamp) */
	"\2LANGUAGE\0ENGLISH|ESPA\xD1OL\0"
	"\2LCD BRIGHTNESS\0" "1|2|3|4|5\0"
	"\2TOUCH DISPLAY CALIBRATION\0\0"
	"\2SCREEN SAVER\0OFF|ON\0"
	"\2LIGHT MODE\0OFF|LIGHT|FULL\0"
	"\2BPM DECIMALS\0OFF|ON\0"
	"\2WAVEFORM COLOR\0" "3BAND|RGB|BLUE\0"
	"\2WAVEFORM CURRENT POSITION\0CENTER|LEFT\0"
	"\2WAVEFORM\0FULL|HALF\0"	/* HALFBLUE: ours (modsmenu wh_v) */
	"\2KEY FORMAT\0CLASSIC|ALPHANUMERIC\0"	/* V4n36: ours (modsmenu kf_v) */
	"\2BEAT NUMBERS\0OFF|ON\0"	/* V4n27b (modsmenu bn_v) */
	"\2GRID ADJUST\0OFF|ON\0"	/* V4n27b: OFF = the stock GRID ADJUST offset ignored */
	"\3SLIP FLASHING\0OFF|ON\0"
	"\3ON AIR DISPLAY\0OFF|ON\0"
	"\3JOG BRIGHTNESS\0OFF|1|2\0"
	"\3JOG INDICATOR\0OFF|ON\0"
	"\3DISC SLOT ILLUMINATION\0OFF|1|2\0"
#ifdef V2_P56	/* players 5/6 builds (MAIN patch a4: AUTO, 1..6); build with V2_CFLAGS=-DV2_P56 */
	"\4PLAYER No.\0" "AUTO|1|2|3|4|5|6\0"
#else
	"\4PLAYER No.\0" "AUTO|1|2|3|4\0"
#endif
	"\4LINK STATUS\0\0"
	"\4MIDI CHANNEL\0" "1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16\0"
	"\4DUPLICATION\0DEFAULT|ALL|PLAYER 1|PLAYER 2|PLAYER 3\0"
	"\4LINK CUE\0OFF|PREVIEW|CUE|BOTH\0"
	"\4LINK OFFSET\0OFF|-10|-5|0|+5|+10|+15|+20|+25|+30|+35|+40|+45|+50|+55\0"	/* LINKLAT: modsmenu lo_v (both profiles) */
	"\5HISTORY NAME\0\0"
	"\5DIGITAL OUT\0" "16bit|24bit\0"
	"\5AUTO STANDBY\0OFF|ON\0"
	"\5MODS\0OFF|ON\0"
	"\5WAV 32-BIT\0OFF|ON\0"
	"\6LINK CUE DIAG\0\0"
#ifdef V2_USBLOG	/* V4n37r: DEV profile only (RELEASE has no UTILITY TEST LOG) */
	"\6TEST LOG\0OFF|USB|RED\0"
#endif
	"\6BUILD\0\0"	/* V4n36 trace: read-only, the build tag + source hash (modsmenu bld_u16) */
	"\6VERSION No.\0\0"
	/* V4n36 trace: the kill switches (after VERSION No.; DEV: shown while TEST LOG is not OFF, RELEASE: always;
	 * LINK CUE above) */
#ifdef V2_USBLOG	/* RELAUDIT: kill switches are DEV-only (RELEASE never shows them) */
	"\6LINK KEY STATUS\0OFF|ON\0"
	"\6KEY SYNC\0OFF|ON\0"
	"\6MASTER WAVE NFS\0OFF|ON\0"
	"\6MASTER WAVEFORM\0OFF|ON\0"
	"\6HW BAND LAYER\0OFF|ON\0"
	"\6LINK ROW PREVIEW\0OFF|ON\0"
	"\6BLACK BOX\0OFF|ON\0"	/* V4n37r: modsmenu kill_v+20 (builds with mods/bbox) */
#endif
	"\0";
static const char *const UT_CAT[6] = { "DJ", "DISPLAY", "DISPLAY", "PRO DJ", "SYSTEM", "INFO" };
static const char *const UT_CAT2[6] = { "SETTING", "(LCD)", "(INDICATOR)", "LINK", "", "" };
/* the entry of a model label (UTF-16BE), 0 = unknown */
static const char *ut_find(const volatile u8 *t, int n)
{
	const char *p = UT_TAB;
	/* players 5/6 builds: MAIN's PLAYER No. item offers 7 options (published in heartbeat +0xE8 bit 15) */
	static const char P56E[] = "\4PLAYER No.\0AUTO|1|2|3|4|5|6";
	if (((v3e_w >> 15) & 1) && n == 10 && u16be(t) == 'P' && u16be(t + 14) == 'N')
		return P56E;
	while (*p) {
		const char *l = p + 1;
		int i = 0;
		while (l[i] && i < n && (u8)l[i] == u16be(t + 2 * i))
			i++;
		if (!l[i] && i == n)
			return p;
		p = l + i;
		while (*p) p++;
		p++;		/* the label's end */
		while (*p) p++;
		p++;		/* the options' end */
	}
	return 0;
}
static int ut_cat(int k)	/* the category of row k (1..6): its own, else the nearest known one above */
{
	for (; k >= 0; k--) {
		const volatile u8 *l = SLOT(0, k + 1);
		const char *e = ut_find(l + 0x2A, u16len(l));
		if (e)
			return e[0];
	}
	return 1;
}
static u16 g_ver[12];
static int g_vn;
static int ustr_eq(const char *a, int an, const volatile u8 *t, int n)
{
	int i;
	if (an != n)
		return 0;
	for (i = 0; i < n; i++)
		if ((u8)a[i] != u16be(t + 2 * i))
			return 0;
	return 1;
}
static void radio_list(int cur_k, int edit)
{
	const volatile u8 *l = SLOT(0, cur_k + 1), *v = SLOT(1, cur_k + 1);
	const char *e = cur_k >= 0 ? ut_find(l + 0x2A, u16len(l)) : 0, *o;
	int vn = u16len(v), n = 0, cur = -1, first = 0, i, y;
	fill(530, 64, W - 530, STRIP_Y - 64, C_BLACK);
	if (!e)
		return;
	o = e + 1;
	while (*o) o++;
	o++;
	if (!*o)
		return;
	{	/* count and find the current one */
		const char *q = o;
		while (*q) {
			const char *s = q;
			while (*q && *q != '|') q++;
			if (ustr_eq(s, (int)(q - s), v + 0x2A, vn))
				cur = n;
			n++;
			if (*q) q++;
		}
	}
	if (n > 10 && cur > 4)
		first = cur - 4 > n - 10 ? n - 10 : cur - 4;
	for (i = 0, y = 70; *o; i++) {
		char b[24];
		int j = 0;
		while (*o && *o != '|') {
			if (j < 23) b[j++] = *o;
			o++;
		}
		b[j] = 0;
		if (*o) o++;
		if (i < first || i >= first + 10)
			continue;
		{	/* V3rc6 (re/CDJ3000_UI_MINING.md §1.7, skin img_btnToggle): option rows #191919 / #000000,
			 * the edited value's row #007DE1; radio = white ring, #007DE1 dot (white on the blue row) */
			int on = i == cur, cx = 552, cy = y + 13, d;
			u16 rbg = edit && on ? C_SEL : (i - first) & 1 ? C_BLACK : C_BAR;
			fill(530, y - 3, W - 534, 32, rbg);
			for (d = -6; d <= 6; d++) {	/* ring */
				int hw = d < 0 ? -d : d;
				hw = hw >= 6 ? 3 : hw >= 5 ? 4 : hw >= 4 ? 5 : 6;
				fill(cx - hw, cy + d, 2 * hw + 1, 1, C_WHITE);
			}
			fill(cx - 4, cy - 3, 9, 7, rbg);
			fill(cx - 3, cy - 4, 7, 9, rbg);
			if (on)
				fill(cx - 2, cy - 2, 5, 5, rbg == C_SEL ? C_WHITE : C_SEL);
			text(&f_m, 566, y, b, C_WHITE, rbg);
		}
		y += 33;
	}
}
/* V4n32: the UTILITY help texts (label, then up to 3 lines; under the rows when the item is selected) */
static const char UT_HELP[] =
	"HOT CUE COLOR\0On: hot cues in their rekordbox colours.\0Off: every hot cue in the default green (CDJ-3000 style).\0\0"
	"KEY SHIFT\0Shifts the key in semitones without changing the tempo.\0Set it with the KEY SHIFT tile on the player screen.\0\0"
	"KEY SYNC BUTTON\0Uses the HOT CUE D/H pad as KEY SYNC (CDJ-3000 style).\0Off: no key match - Blue: keys match - White: KEY SYNC on.\0Hot cues: pads 1-3 = A/D, B/E, C/F.\0\0"
	"LIGHT MODE\0Light: dark waveforms on a light band.\0Full: the whole screen in light colours (daylight).\0\0"
	"BPM DECIMALS\0On: the BPM shows two decimals (128.00).\0Off: one decimal, as the CDJ-3000.\0\0"
	"WAVEFORM COLOR\0The detail and overview waveform colours:\0" "3BAND (low / mid / high), RGB or BLUE.\0\0"
	"WAVEFORM CURRENT POSITION\0Where the playhead sits in the detail waveform:\0CENTER, or LEFT to see more of what comes next.\0\0"
	"WAVEFORM\0The overview and browse mini waveforms' shape:\0Full: drawn up from the bottom, full height.\0Half: mirrored around the centre line.\0\0"
	"KEY FORMAT\0How every key is shown (player, browse, INFO, KEY SHIFT):\0Alphanumeric: 8A, 12B - Classic: Am, F#, Eb (as rekordbox).\0\0"
	"BEAT NUMBERS\0On: beat numbers over the detail waveform's grid,\0counting to the next bar (CDJ-3000 style).\0\0"
	"GRID ADJUST\0On: the waveform grid follows the beat grid offset\0set with GRID ADJUST (hold PUSH or tap ZOOM - GRID).\0The offset is saved per track, as the knob's.\0\0"
	"LINK OFFSET\0Moves the LINK phase meter's master line\0earlier by this many ms. OFF (default) = like the CDJ-3000.\0\0"
#ifdef V2_USBLOG
	"TEST LOG\0Writes a diagnostic log (USB) or sends it over LINK.\0Leave it OFF while playing.\0\0"
#endif
	"BUILD\0Build id of the installed firmware.\0Quote it with every bug report.\0\0"
	/* V4n36 trace: the kill switches (live, not saved: ON again at the next boot) */
#ifdef V2_USBLOG	/* RELAUDIT: kill switches DEV-only */
	"LINK KEY STATUS\0Kill switch. On: our status packet carries the\0CDJ-3000 key fields (KEY SYNC between our decks).\0Off: the stock packet.\0\0"
	"KEY SYNC\0Kill switch. Off: no new KEY SYNC (tile or pad);\0one running ends. The KEY SYNC BUTTON pads are stock.\0\0"
	"LINK CUE\0Kill switch. Off: no Link Cue preview / Touch Cue\0stream to the mixer. Both: everything on.\0\0"
	"MASTER WAVE NFS\0Kill switch. Off: the master's waveform is not read\0over LINK (NFS) when its database has none.\0\0"
	"MASTER WAVEFORM\0Kill switch. Off: the phase meter WAVEFORM view\0shows the master's beat grid only.\0\0"
	"HW BAND LAYER\0Kill switch. Off: the waveform band is drawn in\0software (no hardware scroll layer).\0\0"
	"LINK ROW PREVIEW\0Kill switch. Off: no touch preview of the rows\0of another player's media (own media still works).\0\0"
	"BLACK BOX\0Kill switch. Off: no deck events recorded, no\0C:/BLACKBOX.BIN dump (MENU + BACK held 3 s).\0\0"
#endif
	"PLAYER No.\0The player number on Pro DJ Link (AUTO, 1-6).\0Players 5 and 6 need another deck that supports them.\0\0";
static void utility(int sid)
{
	int k, cur_k = -1, cat;
	const char *hp = "";
	u32 h;
	for (k = 0; k < 8; k++)
		if (u32be(SLOT(0, k + 1) + 0x0C) & 8)
			cur_k = k;
	cat = ut_cat(cur_k >= 0 ? cur_k : 0);
	layout(0x7101 + (day | day_full << 1));
	/* "Ver." = the VERSION No. row's value, kept once seen */
	for (k = 0; k < 8; k++) {
		const volatile u8 *l = SLOT(0, k + 1), *v = SLOT(1, k + 1);
		if (ustr_eq("VERSION No.", 11, l + 0x2A, u16len(l)) && u16len(v) && u16len(v) < 12) {
			int i;
			g_vn = u16len(v);
			for (i = 0; i < g_vn; i++)
				g_ver[i] = (u16)u16be(v + 0x2A + 2 * i);
		}
	}
	if (need(11, hmix(cat, g_vn ? g_ver[g_vn - 1] + g_vn : 0))) {
		fill(0, 0, W, 64, C_BAR);
		text(&f_m, 16, 18, "UTILITY", C_WHITE, C_BAR);
		text_r(&f_m, 786, 18, "Cueline", C_GREY, C_BAR);	/* RELAUDIT (user, v4.1): the project name (was "by feers") */
		if (g_vn) {	/* the value is "Ver 1.87+": shown as the 3000's "Ver.1.87+" */
			char b[20];
			int i, j = 0;
			b[j++] = 'V'; b[j++] = 'e'; b[j++] = 'r'; b[j++] = '.';
			for (i = 0; i < g_vn && j < 18; i++) {
				if (i < 4 && (g_ver[i] == 'V' || g_ver[i] == 'e' || g_ver[i] == 'r' || g_ver[i] == ' ' ||
					      g_ver[i] == '.'))
					continue;
				b[j++] = (char)g_ver[i];
			}
			b[j] = 0;
			text_r(&f_m, 786 - text_w(&f_m, "Cueline") - 12, 18, b, C_LBL, C_BAR);
		}
		fill(0, 64, 64, STRIP_Y - 64, C_BLACK);
		for (k = 0; k < 6; k++) {	/* V3rc6: the 3000's tiles -- #232323, focused #254580, label #969696 / white */
			int y = 70 + 48 * k, on = k + 1 == cat;
			u16 bg = on ? C_UTF : C_CK2;
			fill(0, y, 64, 46, bg);
			text_c(&f_t, 32, y + (UT_CAT2[k][0] ? 10 : 16), UT_CAT[k], on ? C_WHITE : C_UTL, bg);
			if (UT_CAT2[k][0])
				text_c(&f_t, 32, y + 23, UT_CAT2[k], on ? C_WHITE : C_UTL, bg);
		}
	}
	for (k = 0; k < 8; k++) {
		const volatile u8 *l = SLOT(0, k + 1), *v = SLOT(1, k + 1);
		u32 fl = u32be(l + 0x0C);
		int y = 70 + 33 * k, cur = fl & 8, info = (fl & 1) != 0;
		h = hslot(hslot(hmix(fl, sid), l), v);
		if (!need(12 + k, h))
			continue;
		{
			u16 bg = cur ? (sid == 0x09 ? 0x9CD3 : C_UTF) : C_BAR;	/* V3rc6: #191919, focus #254580 */
			fill(68, y, 458, 32, C_BLACK);
			fill(68, y, 458, 31, bg);
			if (!u16len(l))
				continue;
			text_u16(&f_m, 76, y + 3, l + 0x2A, u16len(l), 340, info && !cur ? C_DIM : C_WHITE, bg);
			if (u16len(v)) {
				int vw = row_text_w(&f_m, v + 0x2A, u16len(v));
				int vx = 518 - vw < 344 ? 344 : 518 - vw;
				text_u16(&f_m, vx, y + 3, v + 0x2A, u16len(v), 522, cur ? C_WHITE : C_GREY, bg);
			}
		}
	}
	/* V4n24: the KEY SYNC BUTTON row selected -> its help text under the rows (drawn with the radio list);
	 * V4n32: every item the mods add (or newly honour) has one (UT_HELP: label, then up to 3 lines) */
	k = 0;
	if (cur_k >= 0) {
		const volatile u8 *l = SLOT(0, cur_k + 1);
		const char *p = UT_HELP;
		while (*p) {
			int n = 0;
			while (p[n]) n++;
			if (ustr_eq(p, n, l + 0x2A, u16len(l))) {
				k = 1;
				hp = p + n + 1;
				break;
			}
			p += n + 1;
			while (*p) { while (*p) p++; p++; }
			p++;
		}
	}
	if (!k)
		fill(68, 70 + 33 * 8, 458, STRIP_Y - 70 - 33 * 8, C_BLACK);
	h = hmix(cur_k, sid);
	if (cur_k >= 0)
		h = hslot(hslot(h, SLOT(0, cur_k + 1)), SLOT(1, cur_k + 1));
	if (need(20, h)) {
		if (k) {
			fill(68, 70 + 33 * 8, 458, STRIP_Y - 70 - 33 * 8, C_BLACK);
			const char *q = hp;
			int yy = 342;
			while (*q) {
				text(&f_s, 76, yy, q, C_GREY, C_BLACK);
				while (*q) q++;
				q++;
				yy += 20;
			}
		}
		radio_list(cur_k, sid == 0x09);
	}
	strip(0);
}

/* ---- SOURCE (frame 20 / cdj3k-3.20 source-usb): device rows + the info pane ---- */
static int num_x100(const volatile u8 *t, int n)	/* "5.81 GB used" -> 581 (x100) */
{
	int i = 0, v = 0, frac = -1;
	for (; i < n; i++) {
		u32 c = u16be(t + 2 * i);
		if (c >= '0' && c <= '9') {
			if (frac >= 0) {
				if (frac < 2) { v = v * 10 + (int)(c - '0'); frac++; }
			} else
				v = v * 10 + (int)(c - '0');
		} else if (c == '.' && frac < 0)
			frac = 0;
		else if (v || frac >= 0)
			break;
	}
	if (frac < 0) frac = 0;
	while (frac++ < 2) v *= 10;
	return v;
}
/* V4n31a (#58, deck: LINK showed one linked medium as a plain list page, "each press cycles"): stock's LINK list
 * is model screen 0x00 with slot 0 "LINK" (icon 0x63) and one row per linked medium -- text "USB" / "SD" only,
 * icons 0x50.. -- and side 1 = the cursor medium's info (songs, playlists, date, used, free). It is drawn as the
 * CDJ-3000's SOURCE list (browse/SOURCE: player-number box + LINK tag + medium pictogram, "USB LINK2: ..."
 * rows, right info pane). (The heartbeat tail +0x1B8.. is NOT in the display's copy: the GUI's block ends ~+0x1AC.) */
static int link_list(void)
{
	const volatile u8 *s0 = SLOT(0, 0), *s1 = SLOT(0, 1);
	return MODEL[7] == 0x00 && ustr_eq("LINK", 4, s0 + 0x2A, u16len(s0)) &&
	       (ustr_eq("USB", 3, s1 + 0x2A, u16len(s1)) || ustr_eq("SD", 2, s1 + 0x2A, u16len(s1)));
}
/* the player of a LINK list row: its icon is 0x4F + the player (emu, players 1+2 -> 0x50 / 0x51, 2+4 -> 0x51 /
 * 0x53); 0 = unknown */
static u32 link_row_player(const volatile u8 *sl)
{
	u32 ic = u16be(sl + 0x14);
	return ic >= 0x50 && ic <= 0x55 ? ic - 0x4F : 0;
}
/* V4n32 (#58b): a SOURCE row's tile (the 3000's 90 x 90 medium tile, x 0.625 / 0.667): player box, LINK tag over a
 * linked medium, pictogram (+ label when the row is tall) */
static void src_tile(int y, int h, int sd, u32 pn, int link)
{
	int a = v2a_for_icon(sd ? 0x63 : 0x54);
	fill(4, y, h, h, C_NAVY);
	if (pn) {
		char nb[2] = { (char)('0' + pn % 10), 0 };
		fill(4, y, 13, 14, C_WHITE);
		text_c(&f_s, 10, y, nb, C_BLACK, C_WHITE);
	}
	if (link) {
		fill(18, y, h - 14, 14, 0xD69A);
		text_c(&f_s, 18 + (h - 14) / 2, y, "LINK", C_BLACK, 0xD69A);
	}
	if (a >= 0)
		icon(a, 4 + h / 2 - v2a_rects[a].w / 2, y + (h >= 56 ? 18 : 16) + SRC_DY(a), C_WHITE, C_NAVY);
	if (h >= 56)
		text_c(&f_s, 4 + h / 2, y + 40, sd ? "SD" : "USB", C_WHITE, C_NAVY);
}
/* the 3000's "Loaded" tag (loaded.png 141 x 50: green text, #4B4B4B corner ticks) at the row's right */
static void src_loaded(int y, u16 bg)
{
	const int x = 456, w = 88, h = 28;
	fill(x, y, 6, 1, 0x4A49); fill(x, y, 1, 6, 0x4A49);
	fill(x + w - 6, y, 6, 1, 0x4A49); fill(x + w - 1, y, 1, 6, 0x4A49);
	fill(x, y + h - 1, 6, 1, 0x4A49); fill(x, y + h - 6, 1, 6, 0x4A49);
	fill(x + w - 6, y + h - 1, 6, 1, 0x4A49); fill(x + w - 1, y + h - 6, 1, 6, 0x4A49);
	text_c(&f_s, x + w / 2, y + 6, "Loaded", C_GREEN, bg);
}
/* the LINKed media's names: the info pane's first row (side 1 slot 1) names the cursor's medium -- cached per
 * player / SD-USB as the cursor visits them (UTF-16BE, up to 16 chars) */
static u8 src_nm[7][2][32], src_nl[7][2];
static void src_name_cache(void)
{
	int k, i, n;
	for (k = 1; k <= 8; k++) {
		const volatile u8 *sl = SLOT(0, k), *s1 = SLOT(1, 1);
		u32 pn;
		int sd;
		if (!u16len(sl))
			break;
		if (!(u32be(sl + 0x0C) & 8))
			continue;
		pn = link_row_player(sl);
		sd = ustr_eq("SD", 2, sl + 0x2A, u16len(sl));
		n = u16len(s1);
		if (!pn || pn > 6 || ustr_eq("USB", 3, s1 + 0x2A, n) || ustr_eq("SD", 2, s1 + 0x2A, n) ||
		    ustr_eq("LINK", 4, s1 + 0x2A, n))
			break;
		if (n > 16)
			n = 16;
		for (i = 0; i < 2 * n; i++)
			src_nm[pn][sd][i] = s1[0x2A + i];
		src_nl[pn][sd] = (u8)n;
		break;
	}
}
static void source_screen(void)
{
	int k, lnk = link_list();
	u32 h = 0;
	layout(0x7102 + (day | day_full << 1));
	for (k = 0; k < 9; k++)
		h = hslot(hslot(hmix(h, u32be(SLOT(0, k) + 0x0C)), SLOT(0, k)), SLOT(1, k));
	h = hmix(hmix(h, (u32)(V32_OWN_SD | V32_OWN_USB << 1) | player_num() << 2), V32_LSL << 8 | V32_LPL |
		 (u32)(u32be(DECK + 0x60) != 0) << 16);	/* V4n32: own media, the loaded medium */
	if (need(11, h)) {
		int y;
		fill(0, 0, W, STRIP_Y, C_BLACK);
		fill(0, 0, W, 60, C_BAR);
		text(&f_m, 16, 17, "SOURCE", C_WHITE, C_BAR);
		{	/* V4n32 (#58b, the CDJ-3000 SOURCE): in the LINK list this deck's own SD / USB first (when mounted,
			 * MAIN v32_pub), then the model's rows (contiguous from slot 1, as MAIN's va_src counts them); up to
			 * 8 rows, pitch 64 for <= 5 else 44 (va_src finds the row from y the same way). "USB LINK4: <name>"
			 * (the name: the info pane's first row as the cursor visits that medium, cached), and the 3000's
			 * green "Loaded" tag on the medium the loaded track comes from (MAIN's own status +0x28 player / +0x29 slot, v32_pub). */
			int nm = 0, no = 0, nr, r, own_sd = 0, h4;
			u32 me = player_num(), lsl = V32_LSL, lpl = V32_LPL, ld = u32be(DECK + 0x60) != 0;
			while (nm < 8 && u16len(SLOT(0, nm + 1)))
				nm++;
			if (lnk) {
				own_sd = V32_OWN_SD;
				no = own_sd + V32_OWN_USB;
			}
			nr = nm + no > 8 ? 8 : nm + no;
			int pitch = nr <= 5 ? 64 : 44;
			h4 = pitch - 4;
			if (lnk)
				src_name_cache();
			for (r = 0; r < nr; r++) {
				const volatile u8 *sl = r < no ? 0 : SLOT(0, r - no + 1);
				u32 id = sl ? u16be(sl + 0x14) : 0, cur = sl ? u32be(sl + 0x0C) & 8 : 0, pn = me, ms;
				int sd, x;
				u16 bg = cur ? C_SEL : 0x2124;
				y = 66 + pitch * r;
				if (!sl)
					sd = r == 0 && own_sd;
				else if (lnk) {
					sd = ustr_eq("SD", 2, sl + 0x2A, u16len(sl));
					pn = link_row_player(sl);
				} else
					sd = id == 0x63;
				ms = !sl || lnk ? (sd ? 2u : 3u) : id == 0x58 ? 1u : id == 0x63 ? 2u : 3u;
				fill(4, y, 572, h4, bg);
				if (sl && !lnk) {	/* stock's own device list: its icon, label and text */
					int a = v2a_for_icon(id);
					fill(4, y, h4, h4, C_NAVY);
					if (a >= 0)
						icon(a, 4 + h4 / 2 - v2a_rects[a].w / 2, y + (h4 >= 56 ? 10 : 6) + SRC_DY(a), C_WHITE, C_NAVY);
					if (h4 >= 56)
						text_c(&f_s, 4 + h4 / 2, y + 38, id == 0x51 ? "LINK" : id == 0x63 ? "SD" : id == 0x58 ? "DISC" : "USB",
						       C_WHITE, C_NAVY);
					text_u16(&f_m, 76, y + (h4 - 26) / 2, sl + 0x2A, u16len(sl), 450, C_WHITE, bg);
				} else {
					src_tile(y, h4, sd, pn, sl != 0);
					x = text(&f_m, 76, y + (h4 - 26) / 2, sd ? "SD" : "USB", C_WHITE, bg);
					if (sl && pn) {
						char b[8];
						const volatile u8 *nmp = src_nm[pn][sd];
						b[0] = ' '; b[1] = 'L'; b[2] = 'I'; b[3] = 'N'; b[4] = 'K'; b[5] = (char)('0' + pn); b[6] = 0;
						x = text(&f_m, x, y + (h4 - 26) / 2, b, C_WHITE, bg);
						if (src_nl[pn][sd]) {
							x = text(&f_m, x, y + (h4 - 26) / 2, ": ", C_WHITE, bg);
							text_u16(&f_m, x, y + (h4 - 26) / 2, nmp, src_nl[pn][sd], 450, C_WHITE, bg);
						}
					}
				}
				if (ld && lsl == ms && lpl == pn)
					src_loaded(y + (h4 - 28) / 2, bg);
				if (sl)
					text(&f_m, 552, y + (h4 - 28) / 2, ">", cur ? C_WHITE : C_LBL, bg);
			}
		}
		/* info pane: Songs / Playlists / Date / Total / Available from side 1 (songs, playlists, date,
		 * "x GB used", "y GB free") */
		fill(580, 66, 216, 300, 0x2124);
		{
			static const char *const LB[5] = { "Songs", "Playlists", "Date", "Total", "Available" };
			const volatile u8 *s1 = SLOT(1, 2), *s2 = SLOT(1, 3), *s3 = SLOT(1, 4), *s4 = SLOT(1, 5), *s5 = SLOT(1, 6);
			for (k = 0; k < 5; k++) {
				y = 74 + 34 * k;
				text(&f_s, 588, y + 6, LB[k], C_LBL, 0x2124);
				fill(588, y + 30, 200, 1, 0x4208);
			}
			if (u16len(s1)) {
				int n = 0; while (n < u16len(s1) && u16be(s1 + 0x2A + 2 * n) != ' ') n++;
				text_u16(&f_m, 680, 76, s1 + 0x2A, n, 792, C_WHITE, 0x2124);
			}
			if (u16len(s2)) {
				int n = 0; while (n < u16len(s2) && u16be(s2 + 0x2A + 2 * n) != ' ') n++;
				text_u16(&f_m, 680, 110, s2 + 0x2A, n, 792, C_WHITE, 0x2124);
			}
			if (u16len(s3))
				text_u16(&f_m, 680, 144, s3 + 0x2A, u16len(s3), 792, C_WHITE, 0x2124);
			if (u16len(s4) && u16len(s5)) {
				char b[16], *p = b;
				int u = num_x100(s4 + 0x2A, u16len(s4)), f = num_x100(s5 + 0x2A, u16len(s5)), t = u + f;
				if (t >= 100000) t = 99999;
				if (t >= 10000) *p++ = '0' + udiv(t, 10000) % 10;
				if (t >= 1000) *p++ = '0' + udiv(t, 1000) % 10;
				*p++ = '0' + udiv(t, 100) % 10;
				*p++ = '.';
				*p++ = '0' + udiv(t, 10) % 10;
				*p++ = '0' + t % 10;
				*p++ = ' '; *p++ = 'G'; *p++ = 'B'; *p = 0;
				text(&f_m, 680, 178, b, C_WHITE, 0x2124);
				{
					int n = 0; while (n < u16len(s5) && !(u16be(s5 + 0x2A + 2 * n) == 'B' && n > 1)) n++;
					text_u16(&f_m, 680, 212, s5 + 0x2A, n + 1, 792, C_WHITE, 0x2124);
				}
			}
			text(&f_s, 588, 250, "Background Color", C_LBL, 0x2124);
			fill(700, 252, 88, 14, C_NAVY);
		}
	}
	strip(0);
}

/* ---- the SORT / LIST MENU / TAG LIST MENU pop-up (screen 0x04 with +0x0F set; 3000 frame 27 style) ---- */
static void popup(int force)
{
	int k, n = 0;
	u32 h = hslot(0, SLOT(1, 0));
	for (k = 1; k < 9; k++) {
		h = hslot(hmix(h, u32be(SLOT(1, k) + 0x0C)), SLOT(1, k));
		if (u16len(SLOT(1, k)))
			n = k;
	}
	if (!need(23, h) && !force)
		return;
	if (MODEL[7] == 0x02) {
		/* V3rc5 (re/CDJ3000_UI_MINING.md §4): LOAD PREVIOUS TRACK = the 3000's right pane (548x540 at x 732 ->
		 * 343 x 360 at x 457): #4B4B4B header, #C8C8C8 title, rows #191919 / selected #007DE1, 1-px dividers */
		int x0 = 457, w = W - 457, y = 60;
		fill(x0, y, w, 30, 0x4A49);
		text_u16(&f_m, x0 + 13, y + 3, SLOT(1, 0) + 0x2A, u16len(SLOT(1, 0)), W - 8, 0xCE59, 0x4A49);
		y += 30;
		for (k = 1; k <= 8; k++, y += 40) {
			const volatile u8 *sl = SLOT(1, k);
			u16 bg = (u32be(sl + 0x0C) & 8) && k <= n ? C_SEL : 0x18C3;
			fill(x0, y, w, 39, bg);
			fill(x0, y + 39, w, 1, C_BLACK);
			if (k <= n)
				text_u16(&f_m, x0 + 10, y + 8, sl + 0x2A, u16len(sl), W - 10, C_WHITE, bg);
		}
		if (!n)
			text_c(&f_m, x0 + w / 2, 104, "EMPTY", C_LBL, 0x18C3);
		fill(x0 - 1, 60, 1, 360, C_BLACK);
		return;
	}
	{
		/* V3rc1 (frame 27): the TAG LIST MENU modal -- the 3000's title and OK / CANCEL (= PUSH / BACK) */
		int tl = ustr_eq("TAGLIST MENU", 12, SLOT(1, 0) + 0x2A, u16len(SLOT(1, 0)));
		int bh = 52 + 34 * (n ? n : 1) + 8 + (tl ? 50 : 0), y0 = 236 - bh / 2;
		if (y0 < 66) y0 = 66;
		fill(230, y0, 340, bh, C_POP);
		frame(230, y0, 340, bh, 2, C_POPF);
		fill(232, y0 + 2, 336, 38, 0xB5B6);
		if (tl) {
			text_c(&f_m, 400, y0 + 8, "TAG LIST MENU", C_BLACK, 0xB5B6);
			fill(290, y0 + bh - 46, 100, 34, 0x630C);
			text_c(&f_m, 340, y0 + bh - 42, "OK", C_WHITE, 0x630C);
			fill(410, y0 + bh - 46, 100, 34, 0x630C);
			text_c(&f_m, 460, y0 + bh - 42, "CANCEL", C_WHITE, 0x630C);
		} else
			text_u16(&f_m, 246, y0 + 8, SLOT(1, 0) + 0x2A, u16len(SLOT(1, 0)), 560, C_BLACK, 0xB5B6);
		if (!n && !tl)		/* V3rc5: nothing to list (LOAD PREVIOUS TRACK with no history) */
			text_c(&f_m, 400, y0 + 50, "EMPTY", C_LBL, C_POP);
		for (k = 1; k <= n; k++) {
			const volatile u8 *sl = SLOT(1, k);
			int y = y0 + 46 + 34 * (k - 1), cur = u32be(sl + 0x0C) & 8, cx = 258, cy = y + 15, d;
			u16 bg = cur ? C_SEL : C_POP;
			fill(236, y, 328, 32, bg);
			if (MODEL[7] == 0x02) {	/* V3rc5: a track (LOAD PREVIOUS TRACK), not an option */
				text_u16(&f_m, 246, y + 4, sl + 0x2A, u16len(sl), 556, C_WHITE, bg);
				continue;
			}
			for (d = -6; d <= 6; d++) {
				int hw = d < 0 ? -d : d;
				hw = hw >= 6 ? 3 : hw >= 5 ? 4 : hw >= 4 ? 5 : 6;
				fill(cx - hw, cy + d, 2 * hw + 1, 1, cur ? C_WHITE : C_LBL);
			}
			fill(cx - 4, cy - 3, 9, 7, bg);
			fill(cx - 3, cy - 4, 7, 9, bg);
			if (cur)
				fill(cx - 2, cy - 2, 5, 5, C_WHITE);
			text_u16(&f_m, 274, y + 4, sl + 0x2A, u16len(sl), 556, C_WHITE, bg);
		}
	}
}

static void popup_sync(void);

/* ---- letter jump (3000 video 36:48): a fast knob shows the cursor row's first letter, big ---- */
static u32 lj_t[3], lj_until;
static int lj_cur = -1, lj_on, lj_tgt;
/* V3rc1: a glyph drawn s times larger (pixel blocks; the letter-jump box only) */
static void draw_glyph_s(const struct font *f, int x, int y, u32 code, int s)
{
	const struct glyph *g = glyph(f, code);
	int r, c, stride;
	if (!g)
		return;
	stride = (g->w + 1) >> 1;
	dmark(y, s * f->h + 3);
	for (r = 0; r < f->h; r++) {
		const u8 *src = f->px + g->off + r * stride;
		for (c = 0; c < g->w; c++) {
			int a = (c & 1) ? (src[c >> 1] & 15) : (src[c >> 1] >> 4);
			if (a)
				fill16(fb + (y + s * r) * W + x + s * c, s, ramp[a]),
				fill16(fb + (y + s * r + 1) * W + x + s * c, s, ramp[a]),
				fill16(fb + (y + s * r + 2) * W + x + s * c, s, ramp[a]);
		}
	}
}
static void letter_jump(int cursor_k, int y0, int rh)
{
	u32 now = now_ms();
	(void)y0; (void)rh;
	/* V3rc1: the list position, not the row on the page: MAIN's letter jump pages with the cursor kept
	 * at the page's end */
	if (cursor_k >= 0)
		cursor_k += 8 * (int)(u32be(SLOT(0, 0) + 8) & 0xFFFF);
	if (cursor_k != lj_cur) {
		if (lj_cur >= 0) {
			lj_t[0] = lj_t[1]; lj_t[1] = lj_t[2]; lj_t[2] = now;
			if (lj_t[0] && now - lj_t[0] < 500)
				lj_until = now + 600;
		}
		lj_cur = cursor_k;
	}
	if (cursor_k >= 0 && (s32)(lj_until - now) > 0) {
		const volatile u8 *sl = SLOT(0, (cursor_k & 7) + 1);
		u32 c = u16len(sl) ? u16be(sl + 0x2A) : ' ';
		if (c >= 'a' && c <= 'z') c -= 32;
		if (c == 0xFFFA && u16len(sl) > 1) c = u16be(sl + 0x2C);
#ifdef V3E2
		if (V3E_LJT >= 1 && V3E_LJT <= 26)	/* V3rc2: MAIN's target letter (latched while the box shows) */
			lj_tgt = V3E_LJT;
		if (lj_tgt)
			c = 'A' - 1 + (u32)lj_tgt;
#endif
		fill(370, 186, 120, 110, C_POP);
		frame(370, 186, 120, 110, 2, C_WHITE);
		set_ramp(C_WHITE, C_POP);
		{	/* V3rc1: the 3000's big letter -- f_m at 3x (f_xl has digits only) */
			const struct glyph *g = glyph(&f_m, c);
			int gw = g ? g->w : 10;
			draw_glyph_s(&f_m, 430 - 3 * gw / 2, 241 - 3 * f_m.h / 2, c, 3);
		}
		lj_on = pend = 1;
	} else if (lj_on) {
		int i;
		lj_on = 0;
		lj_tgt = 0;
		for (i = 12; i < 20; i++)
			rk[0][i] = rk[1][i] = 0;
		rk[0][20] = rk[1][20] = 0;
	}
}

static void keyboard(void)
{
	static const char *const R1 = "QWERTYUIOP", *const R2 = "ASDFGHJKL", *const R3 = "ZXCVBNM";
	int i;
	char b[2] = { 0, 0 };
	/* the 3000's keys (audit F2): dark tiles with a 1-px light frame, at the stock touch rects */
	fill(0, 294, W, 186, C_CK1);
	for (i = 0; i < 10; i++) {
		fill(40 + 66 * i, 302, 60, 46, C_KEYB);
		frame(40 + 66 * i, 302, 60, 46, 1, C_GREY);
		b[0] = R1[i];
		text_c(&f_m, 70 + 66 * i, 314, b, C_WHITE, C_KEYB);
	}
	fill(717, 302, 65, 46, C_KEYB2);
	icon(V2A_KEY_BACKSPACE, 749 - v2a_rects[V2A_KEY_BACKSPACE].w / 2, 325 - v2a_rects[V2A_KEY_BACKSPACE].h / 2, C_WHITE, C_KEYB2);
	for (i = 0; i < 9; i++) {
		fill(73 + 66 * i, 357, 60, 46, C_KEYB);
		frame(73 + 66 * i, 357, 60, 46, 1, C_GREY);
		b[0] = R2[i];
		text_c(&f_m, 103 + 66 * i, 369, b, C_WHITE, C_KEYB);
	}
	fill(693, 357, 89, 46, C_KEYB2);
	text_c(&f_s, 737, 374, "CLEAR", C_WHITE, C_KEYB2);
	fill(18, 410, 65, 46, C_KEYB2);
	text_c(&f_s, 50, 427, "123", C_WHITE, C_KEYB2);
	for (i = 0; i < 7; i++) {
		fill(106 + 66 * i, 410, 60, 46, C_KEYB);
		frame(106 + 66 * i, 410, 60, 46, 1, C_GREY);
		b[0] = R3[i];
		text_c(&f_m, 136 + 66 * i, 422, b, C_WHITE, C_KEYB);
	}
	fill(693, 410, 89, 46, C_KEYB2);
	text_c(&f_s, 737, 427, "SPACE", C_WHITE, C_KEYB2);
}

/* the INFO pane (screen 0x06): the cursor track's fields + its artwork */
static void info_pane(int cursor_k)
{
	int k;
	const volatile u8 *cs = cursor_k >= 0 ? SLOT(0, cursor_k + 1) : 0;
	u32 big = cs ? u32be(cs + 0x24) : 0;
	if (big)
		big = (big & 0x1FFFFFFF) | 0x20000000;
	fill(PANE2_X, 60, W - PANE2_X, 312, C_PANE);
	fill(PANE2_X, 60, 1, 312, 0x3186);
	for (k = 0; k < 8; k++) {
		const volatile u8 *f = SLOT(1, k + 1);
		int y = 64 + 38 * k, x = PANE2_X + 8, xm = k < 4 ? 680 : W - 6;
		u32 id = u16be(f + 0x14);
		if (id)
			x += icon_id(id, x, y + 15, 0xCE59, C_PANE) + 6;
		else
			x += 28;
		if (u16len(f)) {
			int fn = u16len(f);
			const volatile u8 *ft = id == 0x0F ? kf_key(f + 0x2A, &fn) : f + 0x2A;	/* V4n36: KEY FORMAT */
			text_u16(&f_m, x, y + 4, ft, fn, xm, C_WHITE, C_PANE);
		}
		if (k < 7)
			fill(PANE2_X + 6, y + 33, xm - PANE2_X - 6, 1, 0x3186);
	}
	fill(688, 64, 106, 114, C_BLACK);
	/* V3rc8 (deck: no artwork in INFO): the range check was made on the uncached alias (| 0x20000000), so it
	 * never matched -- check the physical address */
	/* V3rc8 (deck: no artwork in INFO): the range check was made on the uncached alias (| 0x20000000) and never
	 * matched; a row's big image is 113 x 113, stride 113 (emu dump; rows 0x7100 apart) */
	if ((big & 0x1FFFFFFF) >= 0x0E600000 && (big & 0x1FFFFFFF) < 0x0E700000)
		image((const volatile u16 *)big, 113, 113, 113, 691, 67, 100, 108);
	else
		icon_scaled(V2A_NOART_PANE, 691, 67, 100, 108, 0x4A49, C_BLACK);
	frame(688, 64, 106, 114, 1, C_ART);
#ifdef V3E2
	/* V3e2 (audit B10): the 3000's light LOAD button (a tap = the rotary push: MAIN v3e_touch) */
	fill(604, 372, 184, 36, 0xE73C);
	text_c(&f_m, 696, 378, "LOAD", C_BLACK, 0xE73C);
#endif
}

/* the whole browse family */
/* ---- V3rc1: TRACK FILTER (stock's BPM / KEY page, model screen 0x18; MAIN opens it from the header button)
 * in the CDJ-3000's look (video frame 26), on stock's touch geometry (MAIN zones 20..40, only zone 30 = the
 * key grid moved, mods/v2ui/v2ui.py v2needle). The model's filter block (MODEL + 0x26B0, re/V3_PROGRESS.md
 * V3rc1): +0 the checked rows (0x10 BPM, 0x08 KEY, 0x04 RATING, 0x02 COLOR), +2 BPM (u16), +4 the +-%, +5
 * the rating, +6 the key (UTF-16, 4 characters), +0xE the colours (bit k = PINK .. PURPLE), +0x13 the field
 * being edited (1 BPM, 2 range, 3 key). Side 1 slot 0 = the matching count "[  77]". ---- */
#define FB (MODEL + 0x26B0)
static void disc(int cx, int cy, int r, u16 c)
{
	int dy, dx;
	for (dy = -r; dy <= r; dy++) {
		for (dx = r; dx * dx + dy * dy > r * r; dx--)
			;
		fill(cx - dx, cy + dy, 2 * dx + 1, 1, c);
	}
}
static void fp_check(int y, const char *l, int on)
{
	fill(113, y, 110, 36, 0x2124);
	frame(113, y, 110, 36, 1, 0x4A69);
	if (on) {
		fill(121, y + 9, 18, 18, C_SEL);
		text_c(&f_s, 130, y + 9, "v", C_WHITE, C_SEL);
	} else
		frame(121, y + 9, 18, 18, 2, C_LBL);
	text(&f_s, 147, y + 9, l, C_WHITE, 0x2124);
}
static void fp_box(int x, int y, int w, const char *v, const char *u, int edit)
{
	fill(x, y, w, 36, 0x2124);
	frame(x, y, w, 36, edit ? 2 : 1, edit ? C_CYAN : 0x4A69);
	{
		int tx = x + w / 2 - (text_w(&f_m, v) + (u ? text_w(&f_t, u) + 4 : 0)) / 2;
		tx = text(&f_m, tx, y + 5, v, C_WHITE, 0x2124);
		if (u)
			text(&f_t, tx + 4, y + 18, u, C_LBL, 0x2124);
	}
}
static const u16 FCOL[8] = { 0xFB9A, 0xF800, 0xFC40, 0xFFE0, 0x07E0, 0x07FF, 0x033F, 0x901F };
/* the page header of both TRACK FILTER pages (frame 26): medium tile, title, count, the lit FILTER button,
 * the tabs -RESET | BPM/KEY | MY TAG (mt = the MY TAG page) */
static void fp_header(int on, int mt)
{
	if (need(11, hslot(hmix(on | mt << 8, med_col()), SLOT(1, 0)))) {
		u16 nv = med_col();
		fill(0, 0, W, 44, C_BAR);
		fill(0, 0, 56, 44, nv);
		{	/* the medium from the title "USB@PLAYER1" / "SD@PLAYER2": the part before '@' */
			char m[6];
			int i;
			for (i = 0; i < 5 && i < u16len(SLOT(0, 0)); i++) {
				u32 c = u16be(SLOT(0, 0) + 0x2A + 2 * i);
				if (c == '@' || c < 32 || c > 126)
					break;
				m[i] = (char)c;
			}
			m[i] = 0;
			text_c(&f_s, 28, 14, i ? m : "USB", C_WHITE, nv);
		}
		text(&f_m, 70, 10, "TRACK FILTER", C_WHITE, C_BAR);
		if (u16len(SLOT(1, 0)))
			text_u16(&f_s, 300, 14, SLOT(1, 0) + 0x2A, u16len(SLOT(1, 0)), 480, C_LBL, C_BAR);
		/* the button that opened it (lit, closes; MAIN zone 484..556) */
		fill(488, 8, 64, 28, on ? C_CYAN : C_BAR);
		frame(488, 8, 64, 28, 1, C_CYAN);
		text_c(&f_s, 520, 14, "FILTER", on ? C_BLACK : C_CYAN, on ? C_CYAN : C_BAR);
		/* V3rc2 (frame 26): the tabs at the top right -- -RESET | BPM/KEY (this page, lit) | MY TAG (MAIN
		 * action 11 hands each press to stock's own button, zones 23 / 20 / 21) */
		fill(568, 4, 76, 36, 0x2945);
		frame(568, 4, 76, 36, 1, 0x4A69);
		text_c(&f_s, 606, 14, "- RESET", C_WHITE, 0x2945);
		fill(648, 4, 76, 36, mt ? 0x2945 : 0xA534);
		text_c(&f_s, 686, 14, "BPM/KEY", mt ? C_WHITE : C_BLACK, mt ? 0x2945 : 0xA534);
		fill(728, 4, 68, 36, mt ? 0xA534 : 0x2945);
		text_c(&f_s, 762, 14, "MY TAG", mt ? C_BLACK : C_WHITE, mt ? 0xA534 : 0x2945);
		fill(0, 44, 100, STRIP_Y - 44, C_BLACK);
	}
}
static void filter_page(void)
{
	u32 on = FB[0], ed = FB[0x13];
	int kc = key_code(FB + 6, 4), k;
	char b[8];
	layout(0x7118 + (day | day_full << 1));
	fp_header(on & 0x1E, 0);
	/* BPM row (zones 24 / 28 / 29) + MASTER PLAYER (zone 40) */
	if (need(12, hmix(hmix(u16be(FB + 2), FB[4]), (on & 0x10) | ed << 8))) {
		fill(101, 46, W - 101, 50, C_BLACK);
		fill(706, 46, W - 706, 110, C_BLACK);
		fp_check(53, "BPM", on & 0x10);
		fmt_u(b, u16be(FB + 2));
		fp_box(255, 53, 126, b, "BPM", ed == 1);
		text(&f_m, 400, 58, "<=", C_LBL, C_BLACK);
		text(&f_m, 460, 58, "\xB1", C_WHITE, C_BLACK);
		fmt_u(b, FB[4]);
		fp_box(519, 53, 126, b, "%", ed == 2);
		/* the 3000's range slider */
		fill(655, 69, 46, 4, 0x4208);
		fill(655, 69, FB[4] > 16 ? 46 : FB[4] * 46 / 16, 4, C_SEL);
		fill(714, 53, 68, 99, 0x2945);
		frame(714, 53, 68, 99, 1, 0x4A69);
		text_c(&f_s, 748, 88, "MASTER", C_WHITE, 0x2945);
		text_c(&f_s, 748, 106, "PLAYER", C_WHITE, 0x2945);
	}
	/* KEY row (zone 25) + the 3000's key grid 1B..12B / 1A..12A (zone 30, moved onto it) */
	if (need(13, hmix(hmix(kc, on & 8), (ed == 3) + 2 * KF_CLASSIC))) {	/* V4n36: + KEY FORMAT */
		fill(101, 96, 605, 80, C_BLACK);
		fp_check(117, "KEY", on & 8);
		for (k = 0; k < 24; k++) {
			int n = k % 12 + 1, bb = k < 12, code = n * 2 + bb, x = 255 + 37 * (k % 12), y = bb ? 100 : 138;
			int sel = kc == code, rel = !sel && key_compat(kc, code);
			u16 bg = sel ? C_SEL : 0x2124;
			fill(x, y, 35, 32, bg);
			frame(x, y, 35, 32, 1, rel ? C_CYAN : 0x4A69);
			key_name(b, code);	/* V4n36: "8A" or "Am" (KEY FORMAT) */
			text_c(&f_t, x + 17, y + 11, b, sel || rel ? C_WHITE : C_LBL, bg);
		}
		if (ed == 3)
			frame(252, 97, 448, 76, 2, C_CYAN);
	}
	/* RATING (zones 26 / 31: the stock's star thresholds x 317 / 383 / 449 / 515 / 581) */
	if (need(14, hmix(FB[5], on & 4))) {
		fill(101, 176, W - 101, 64, C_BLACK);
		fp_check(181, "RATING", on & 4);
		fill(255, 181, 352, 36, 0x2124);
		frame(255, 181, 352, 36, 1, 0x4A69);
		for (k = 0; k < 5; k++)
			icon_scaled(k < FB[5] ? V2A_STAR20_FULL : V2A_STAR20_EMPTY, 276 + 66 * k, 189, 20, 20,
				    C_WHITE, 0x2124);
	}
	/* COLOR (zones 27 / 32..39) */
	if (need(15, hmix(FB[0x0E], on & 2))) {
		fill(101, 240, W - 101, 50, C_BLACK);
		fp_check(245, "COLOR", on & 2);
		for (k = 0; k < 8; k++) {
			int x = 255 + 66 * k, s = (FB[0x0E] >> k) & 1;
			fill(x, 245, 60, 36, s ? 0x4A69 : 0x2124);
			frame(x, 245, 60, 36, s ? 2 : 1, s ? C_CYAN : 0x4A69);
			disc(x + 30, 263, 8, FCOL[k]);
		}
	}
	if (need(16, 0x1F))
		fill(0, 290, W, STRIP_Y - 290, C_BLACK);
	strip(0);
}

/* ---- V3rc3: TRACK FILTER's MY TAG page (model screens 0x19 + category tab 0..3), the 3000's look on stock's
 * touch geometry (class 9 zones 41..44 tabs, 45 / 46 AND / OR, 47..52 items; MAIN v3e_touch adds the header's
 * FILTER / -RESET / BPM/KEY / MY TAG). Model (re/V3_PROGRESS.md V3rc3): FB + 0x10 + 0x1DC k = category k
 * (+0xD flags: bit 3 checked, bit 2 AND; +0xE length, +0x10 the name, UTF-16), its 6 item slots at + 0x44 (i + 1)
 * (+0xD bit 1 selected), filled for the shown category only; FB[0x19] = the shown category's item count. ---- */
#define MT_CAT(k) (FB + 0x10 + 0x1DC * (k))
#define MT_ITEM(k, i) (MT_CAT(k) + 0x44 * ((i) + 1))
static void mytag_page(int cur)
{
	u32 on = FB[0] & 0x1E, h = 0;
	int k, i, n = FB[0x19];
	for (k = 0; k < 4; k++)
		if (MT_CAT(k)[0xD] & 8)
			on |= 1;
	layout(0x7120 + (day | day_full << 1));
	fp_header(on, 1);
	/* the category tabs (zones 41..44: x 100 + 172.7 k, y 46..90): check box + name; the shown one lit */
	for (k = 0; k < 4; k++)
		h = hmix(hslot(h, MT_CAT(k) - 0x1A), MT_CAT(k)[0xD]);
	if (need(12, hmix(h, cur))) {
		fill(100, 44, W - 100, 50, C_BLACK);
		for (k = 0; k < 4; k++) {
			const volatile u8 *c = MT_CAT(k);
			int x = k == 0 ? 102 : k == 1 ? 274 : k == 2 ? 447 : 620, sel = k == cur, ln = (int)u16be(c + 0xE);
			u16 bg = sel ? 0x3186 : 0x2124;
			if (!ln)
				continue;
			fill(x, 48, 161, 40, bg);
			frame(x, 48, 161, 40, 1, sel ? C_LBL : 0x4A69);
			if (sel)
				fill(x, 85, 161, 3, C_SEL);
			if (c[0xD] & 8) {
				fill(x + 8, 59, 18, 18, C_SEL);
				text_c(&f_s, x + 17, 59, "v", C_WHITE, C_SEL);
			} else
				frame(x + 8, 59, 18, 18, 2, C_LBL);
			text_u16(&f_s, x + 34, 59, c + 0x10, ln > 24 ? 24 : ln, x + 157, sel ? C_WHITE : C_LBL, bg);
		}
	}
	/* CRITERIA AND / OR (zones 45 / 46) of the shown category, the items (2 x 3, zones 47..52) */
	h = hmix(MT_CAT(cur)[0xD], n);
	for (i = 0; i < 6; i++)
		h = hmix(hslot(h, MT_ITEM(cur, i) - 0x1A), MT_ITEM(cur, i)[0xD]);
	if (need(13, h)) {
		int and = (MT_CAT(cur)[0xD] & 4) != 0;
		fill(100, 94, W - 100, STRIP_Y - 94, C_BLACK);
		text_c(&f_t, 176, 196, "CRITERIA", C_LBL, C_BLACK);
		fill(111, 213, 64, 52, and ? C_SEL : 0x2124);
		fill(176, 213, 64, 52, and ? 0x2124 : C_SEL);
		frame(111, 213, 129, 52, 1, 0x4A69);
		text_c(&f_m, 143, 228, "AND", and ? C_WHITE : C_LBL, and ? C_SEL : 0x2124);
		text_c(&f_m, 208, 228, "OR", and ? C_LBL : C_WHITE, and ? 0x2124 : C_SEL);
		for (i = 0; i < 6; i++) {
			const volatile u8 *it = MT_ITEM(cur, i);
			int x = i & 1 ? 527 : 272, y = 110 + 60 * (i >> 1), ln = (int)u16be(it + 0xE), sel = (it[0xD] & 2) != 0;
			u16 bg = sel ? C_SEL : 0x2124;
			if (!ln)
				continue;
			fill(x, y, 244, 36, bg);
			frame(x, y, 244, 36, sel ? 2 : 1, sel ? C_CYAN : 0x4A69);
			text_u16(&f_m, x + 10, y + 5, it + 0x10, ln > 32 ? 32 : ln, x + 236, C_WHITE, bg);
		}
		if (n > 6) {	/* more items than the page: the 3000's thin scroll bar */
			fill(258, 110, 4, 156, 0x4208);
			fill(258, 110, 4, (int)udiv(156 * 6, (u32)n), C_LBL);
		}
	}
	if (need(14, 0x1F))
		fill(0, 290, W, STRIP_Y - 290, C_BLACK);
	strip(0);
}

static u32 wait_e0;	/* V3rc2: when the list went empty (the spinner's delay) */
static void browse(void)
{
	int sid = MODEL[7], k, cursor_k = -1, rows = 0, search = is_search(), pop = pop_on();
	int kbh = search && V3E_KBH, skb = search && !kbh;	/* V3rc3: SEARCH with / without its keyboard */
	u32 tid = u16be(SLOT(0, 0) + 0x14), sid1 = sort_id(sid);
	int src = sid == 0x00 && (is_src_icon(u16be(SLOT(0, 1) + 0x14)) || link_list());	/* V4n31a: + the LINK list */
	int root = sid == 0x00 && !src && is_src_icon(tid);
	int tracks, two, info = sid == 0x06, x1, y0 = skb ? V3_SROW_Y0 : V3_ROW_Y0, rh = skb ? V3_SROW_H : V3_ROW_H;
	mq_xmax = info ? PANE2_X - 8 : W;	/* V3rc8: the marquee's visible edge */
	int rows_drawn = 0, ymax = skb ? 294 : STRIP_Y;
	u32 base, nh0 = 0, nh_now = 0;
	for (k = 11; k <= 24; k++)
		nh0 += v2_nh[k];
	if (sid == 0x0A || sid == 0x09) {
		utility(sid);
		return;
	}
	if (sid == 0x18) {	/* V3rc1: TRACK FILTER, BPM / KEY page */
		filter_page();
		return;
	}
	if (sid >= 0x19 && sid <= 0x1C) {	/* V3rc3: its MY TAG page, category tab sid - 0x19 */
		mytag_page(sid - 0x19);
		return;
	}
	if (src) {
		source_screen();
		return;
	}
	for (k = 0; k < 8; k++) {
		const volatile u8 *sl = SLOT(0, k + 1);
		if (u32be(sl + 0x0C) & 8)
			cursor_k = k;
		if (u16len(sl) || u16be(sl + 0x14))
			rows++;
		fb_browse_row(sl);	/* V4m2 */
	}
	lb_update(cursor_k);	/* V4n30: LOAD only after a touch */
	KIT(kit_cursor = (u32)cursor_k;)
	/* the category on the rail */
	if (root && cursor_k >= 0)
		cur_cat = u16be(SLOT(0, cursor_k + 1) + 0x14);
	else
		for (k = 0; k < 9; k++)
			if (tid == RAIL_ID[k])
				cur_cat = tid;
	tracks = !root && (sid == 0x03 || sid == 0x04 || search || info ||
			   (rows && (u32be(SLOT(0, cursor_k >= 0 ? cursor_k + 1 : 1) + 0x0C) & 0x10)));
	two = !tracks && !root && !search;
	if (two) {
		two = 0;
		for (k = 0; k < 8; k++)
			if (u16len(SLOT(1, k + 1)))
				two = 1;
	}
	x1 = info ? PANE2_X : two ? PANE2_X : W;
	/* 2.01-a: + our pane <-> a stock pop-up (pop_ours): everything under our pane repaints when it goes */
	base = hmix(hmix(hmix(sid, tracks + 2 * two + 4 * root + 8 * info + 16 * pop + 32 * (pop && pop_ours())),
		search + 2 * kbh), day | day_full << 1);
	base = hmix(hmix(base, sid1), ref_key());
	layout(base);
	if (need(21, hmix(hmix(hmix(base, cur_cat), cursor_k < 0), med_col())))
		rail(ymax, cur_cat, root);
	if (need(11, hslot(search ? hslot(base, SLOT(1, 0)) : base, SLOT(0, 0)) ^ tid ^
		    (cursor_k >= 0 && root ? u16be(SLOT(0, cursor_k + 1) + 0x14) << 8 : 0) ^ (u32)(V3E_PV_ROW != 0) << 31 ^ (u32)V3E_PVOFF << 30)) {	/* V3rc2: SEARCH's count too; TOUCH: PREVIEW off */
		if (search) {
			int x = RAIL_W + 12;
			fill(RAIL_W, 0, W - RAIL_W, 60, C_BAR);
			x += icon(V2A_SEARCH, x, 30 - v2a_rects[V2A_SEARCH].h / 2, 0x94B2, C_BAR) + 8;	/* 3000 img_icnSearch #969696 */
			fill(x, 14, 460, 32, C_BLACK);
			frame(x, 14, 460, 32, 1, C_SEL);
			text_u16(&f_m, x + 6, 17, SLOT(0, 0) + 0x2A, u16len(SLOT(0, 0)), x + 454, C_WHITE, C_BLACK);
			if (u16len(SLOT(1, 0)))
				text_u16(&f_m, 700, 17, SLOT(1, 0) + 0x2A, u16len(SLOT(1, 0)), W, C_LBL, C_BAR);
		} else if (root)
			header(0, 0, "BROWSE", 1, 0, 0);
		else if (tid == 0x50)	/* V3rc2: TAG LIST (slot 0 = the medium, icon 0x50): the 3000's title */
			header(0, 0, "TAG LIST", 1, info, tracks);
		else
			header(SLOT(0, 0), tid, 0, 1, info, tracks);
	}
	if (!skb && need(22, hmix(hmix(base, root ? u16be(SLOT(0, cursor_k >= 0 ? cursor_k + 1 : 1) + 0x14) : tid),
				    u32be(SLOT(0, 0) + 4)))) {
		if (tracks && !info) {
#ifdef V3E2
			static char cnt[16] = "TRACK [";
			char *q = cnt + 7;
			u32 c = u32be(SLOT(0, 0) + 4);
			cnt[5] = ' ';
			if (c && c <= 9999 && !search) {
				*q++ = '0' + udiv(c, 1000) % 10; *q++ = '0' + udiv(c, 100) % 10;
				*q++ = '0' + udiv(c, 10) % 10; *q++ = '0' + c % 10; *q++ = ']'; *q = 0;
			} else
				cnt[5] = 0;
#else
			const char *cnt = "TRACK";
#endif
			trk_hdr(x1, cnt, sid1);
			if (sort_extra(sid1)) {
				const volatile u8 *s0 = SLOT(1, 0);
				int a = v2a_for_icon(sid1);
				fill(x1 - 292, 60, 122, 28, C_HDR);	/* V4n30a: up to the sort box (631) */
				if (a >= 0)	/* ICONS: the 16-px list pictogram, 1:1, centred in the 28-px strip */
					icon(a, x1 - 290, 74 - v2a_rects[a].h / 2, C_LBL, C_HDR);
				text_u16(&f_s, x1 - 268, 67, s0 + 0x2A, u16len(s0), x1 - 172, 0x453E, C_HDR);
			}
		} else if (info) {
			colhdr(RAIL_W, x1, "TRACK", RAIL_W + 12, 0, 0, 0, 0, 0, 0);
		} else {
			const volatile u8 *t = root ? SLOT(0, cursor_k >= 0 ? cursor_k + 1 : 1) : SLOT(0, 0);
			fill(RAIL_W, 60, x1 - RAIL_W, 28, C_HDR);
			fill(RAIL_W, 88, W - RAIL_W, 2, C_BLACK);
			text_u16(&f_s, RAIL_W + 12, 67, t + 0x2A, u16len(t), x1 - 8, C_LBL, C_HDR);
			if (two) {
				fill(x1, 60, W - x1, 28, C_HDR);
				fill(x1, 60, 1, 28, C_BLACK);
				text_u16(&f_s, x1 + 12, 67, SLOT(1, 0) + 0x2A, u16len(SLOT(1, 0)), W - 8, C_LBL, C_HDR);
			}
		}
	}
	if (skb)
		fill(RAIL_W, 60, W - RAIL_W, 4, C_BLACK);
	/* rows */
	if (root) {	/* the 3000 has no root list (the rail is the root): the cursor category's preview */
		for (k = 0; k < 8; k++) {
			const volatile u8 *f = SLOT(1, k + 1);
			u32 h = hmix(hslot(base, f), u16be(f + 0x14));
			if (need(12 + k, h)) {
				plain_row(f, k, RAIL_W, W, y0 + rh * k, rh, 1, 1);
				rows_drawn = 1;
			}
		}
	} else {
		for (k = 0; k < 8; k++) {
			const volatile u8 *sl = SLOT(0, k + 1);
			u32 h = hslot(base, sl);
			h = hmix(hmix(hmix(h, u32be(sl + 0x0C)), u16be(sl + 0x14)), u32be(sl + 0x1C));
			h = hmix(h, (u32)(V3E_PROW == k) + 2 * (u32)KF_CLASSIC);	/* V4n6: the pressed row; V4n36 KEY FORMAT */
			if (V3E_PV_ROW == k + 1)
				pv_note(row_th(sl));
			h = hmix(h, (u32)pl_seen(row_th(sl)));	/* redraw when the row becomes "played" */
			if (u32be(sl + 0x1C)) {
				const volatile u16 *a = SMALL_ART(k + 1);
				h = hmix(h, a[0] ^ a[561] << 16);
				h = hmix(h, a[1120] ^ a[2239] << 16);
			}
			{	/* the rowmeta text (BPM / KEY): hashed itself -- hslot(sl + 0x1A0) read a length that is
				 * not the meta's (0): a buffer painted before the KEY arrived stayed stale (Mac QA) */
				const volatile u8 *mt = sl + 0x2A + 0x1A0;
				int i;
				for (i = 0; i < 40 && u16be(mt + 2 * i); i++)
					h = hmix(h, u16be(mt + 2 * i));
			}
			if (sort_extra(sid1))
				h = hslot(h, SLOT(1, k + 1));
			h = hmix(hmix(h, V3E_ELSE(k) | (V3E_PV_ROW == k + 1 ? V3E_PV_COL << 1 | 0x800 : 0)), row_no(k));
			if (u32be(sl + 0x0C) & 8)
				h = hmix(h, (u32)mq_peek());	/* V3rc8: the selected row's marquee */
			h = hmix(h, (u32)(k == lb_tap_k) + 2 * (u32)ov_full);	/* V4n30: LOAD shown / hidden; HALFBLUE WAVEFORM */
			if (need(12 + k, h)) {
				if (tracks) {
					track_row(sid, k, y0 + rh * k, rh, x1, sid1, pop);
					if (!pop)
						load_btn(k, y0 + rh * k, rh, x1);	/* V4n11 */
				} else	/* V4n23: braces -- the else bound to if (!pop): plain rows (PLAYLIST left pane) never drew */
					plain_row(sl, k, RAIL_W, x1, y0 + rh * k, rh, pop, 0);
				rows_drawn = 1;
			}
		}
	}
	if (rows || search || root)
		wait_e0 = 0;
	if (need(24, hmix(base, rows)))
		fill(RAIL_W, y0 + 8 * rh, x1 - RAIL_W, ymax - y0 - 8 * rh, C_BLACK);
	if (!rows && !search && !root) {
		if (!u16len(SLOT(0, 0)))
		{
			/* V3rc2: the spinner only once the list has stayed empty 300 ms (a list change empties the
			 * model for a few frames: no "Wait" flash on every enter / back) */
			u32 nw = now_ms();
			if (!wait_e0)
				wait_e0 = nw | 1;
			if (nw - wait_e0 >= 300)
				icon(V2A_WAIT0 + (udiv(v2_epoch, 3) & 7), 412, 224, C_WHITE, C_BLACK);
			pend = 1;	/* V3f: the spinner turns with the frames */
		}
		else if (!two)
			text_c(&f_m, 428, 220, "EMPTY", C_LBL, C_BLACK);
	}
	if (info && !pop) {	/* V3rc5: under SORT side 1 is the pop-up's: the pane keeps what it showed */
		u32 h = hmix(hmix(sid, cursor_k), day | day_full << 1);
		for (k = 0; k < 9; k++)
			h = hmix(hslot(h, SLOT(1, k)), u16be(SLOT(1, k) + 0x14));
		h = hmix(h, ART_BIG[0] ^ ART_BIG[7000] << 16);
		if (need(20, h))
			info_pane(cursor_k);
	} else if (two) {
		u32 h = base;
		for (k = 0; k < 9; k++)
			h = hmix(hslot(h, SLOT(1, k)), u16be(SLOT(1, k) + 0x14));
		if (need(20, h)) {
			for (k = 0; k < 8; k++)
				plain_row(SLOT(1, k + 1), k, x1, W, y0 + rh * k, rh, 1, 1);
			fill(x1, y0, 1, 8 * rh, 0x3186);
			fill(x1, y0 + 8 * rh, W - x1, ymax - y0 - 8 * rh, C_BLACK);
		}
	}
	for (k = 11; k <= 24; k++)	/* anything under the pop-up / band redrawn this frame? */
		nh_now += v2_nh[k];
	if (nh_now != nh0)
		rows_drawn = 1;
	if (!search && !root)
		letter_jump(cursor_k, y0, rh);
	if (pop && pop_ours()) {	/* 2.01-a: a stock-drawn pop-up (pop_ours) is left to stock */
		popup(rows_drawn);
		popup_sync();
	}
	if (skb) {
		keyboard();
		rk[0][2] = rk[1][2] = 0;	/* the keyboard covers the strip: redraw it after */
		return;
	}
	(void)lc_band;	/* V3e1 (user): INFO's Link Cue band is gone -- Link Cue = the rows' PREVIEW column */
	strip(0);
}

/* which screen is ours: the player (no list over it) or the browse family -- lists, INFO, UTILITY
 * (+ value edit) and SEARCH; never in update mode (tupdate sets 0x0E5B6B40 = 3; the model's screen byte
 * stays 0 there and at boot, where the model is empty). SHORT CUT (0x1E) stays stock: its panel is
 * GUI-built and touch-driven. */
/* the read-only image (fonts, icon atlas) lives in flash with NO load record (the GUI bootloader, never
 * dumped, is not asked to write SDRAM): at the first paint -- long after boot -- it is copied from the
 * memory-mapped NOR (CS0, read-array mode; a one-time read) to its link address V2_RO in SDRAM (a range proven untouched by the
 * stock GUI, re/V2_P4.md) and checked against the sum v2ui.py stores behind the "V2RS" marker. A bad
 * copy means we never take a screen: the stock UI stays. */
extern u32 __v2ro_start[], __v2ro_end[];
volatile u32 v2_rosum[4] = { 0x56325253, 0, 0, 0 };	/* "V2RS", word sum, flash address, bytes */
static int ro_state;				/* 0 not copied yet, 1 good, 2 bad */

static int ro_ok(void)
{
	if (!ro_state) {
		const volatile u32 *src = (const volatile u32 *)(v2_rosum[2] & 0x1FFFFFFF);	/* CS0 NOR, read once */
		u32 *dst = __v2ro_start, s = 0;
		u32 n = (u32)((u8 *)__v2ro_end - (u8 *)__v2ro_start) >> 2;
		ro_state = 2;
		if (v2_rosum[2] && v2_rosum[3] >= (n << 2)) {
			while (n--) {
				u32 w = *src++;
				*dst++ = w;
				s += w;
			}
			if (s == v2_rosum[1])
				ro_state = 1;
		}
	}
	return ro_state == 1;
}

static int trans_from = M_NONE;	/* P10: the mode of the last frame we painted (see screen_mode) */
static int trans_frames;
static u32 trans_t0;	/* D1: now_ms() of the first held frame (the hold is timed, not counted) */
static u32 now_ms(void);
u32 v2_trans_held;
u32 v2_trans_curms, v2_trans_maxms;	/* R22F1: ms the browse list has been empty on a screen we hold; the longest since boot */
static int screen_mode(void)
{
	int sid;
	if (UPD_STATE || !ro_ok())
		return M_NONE;
	sid = MODEL[7];
	if (sid == 0x1E)
		return M_SHORTCUT;
	if (sid >= 0x18 && sid <= 0x1C)	/* TRACK FILTER: BPM / KEY page (V3rc1), MY TAG page 0x19..0x1C (V3rc3) */
		return M_BROWSE;
	if (sid == 0x08)	/* V4n (deck: INFO while playing = stock's empty screen, garbled): ours whenever a
				 * track is loaded, even before MAIN fills the rows (title / key from our own copy) */
		return u16len(SLOT(0, 1)) || u32be(DECK + 0x60) ? M_PINFO : M_NONE;
	if (sid == 0x02)
		return u16be(SLOT(0, 1) + 0x28) ? M_BROWSE : M_PLAYER;
	/* NAVART (emu, every transition captured per vsync): 0x01 = TAG LIST's medium level ("TAG LIST", rows =
	 * the media; stock passes through it opening TAG LIST and lands on it after BACK from the tagged tracks):
	 * not owned, it showed stock's deck screen over black -- 1 frame on TAG LIST, held after BACK */
	if (sid == 0x00 || sid == 0x01 || sid == 0x03 || sid == 0x04 || sid == 0x06 || sid == 0x09 || sid == 0x0A) {
		if (u16be(SLOT(0, 0) + 0x14) || u16be(SLOT(0, 0) + 0x28) || u16be(SLOT(0, 1) + 0x28))
			return M_BROWSE;
		/* P10: a browse screen whose list is still being built (slots empty: every change of
		 * list, player <-> browse): stock would show its own empty browse frame with ITS deck
		 * area for a frame or more -- a flash between two of our frames. Coming from a screen
		 * we own, stay ours (empty rows) for up to ~2 s; after that it's stock's (e.g. "Wait"). */
		/* D1 (emu stress, Mac display model: stock's own empty browse frame for ~0.5 s, 2.25 s after closing
		 * SHORT CUT over a browse whose list was slow to come): the 120-frame hold ran out at 60 fps -- it is
		 * timed now, 4 s (the MAIN-busy one below 15 s, was 900 frames) */
		/* R22F1 (kit dry run, poisoned emulator: 45 s of never-drawn surface over a stale pop-up, the track
		 * playing -- the owner's "stuck screen"): the hold used to run out (4 s; 15 s with MAIN busy) and the
		 * screen went to stock. But for stock nothing had changed -- same screen id, its windows "drawn" (we had
		 * skipped every draw) -- so it redrew nothing and composed surfaces nobody ever painted, until the next
		 * screen change. A browse screen we were painting is never handed back: empty rows, the rail and the
		 * spinner stay ours for as long as the list takes. (v2_trans_held still counts the held frames.) */
		if (trans_from != M_NONE)
			return M_BROWSE;
	}
	return M_NONE;
}

static int owned(void) { return screen_mode() != M_NONE; }
#if defined(V2_HUD) && defined(V2_USBLOG)
#include "usblog.inc"	/* V4 Fase 1: HUD records -> SPI frame -> MAIN usblog (TEST) */
#endif

u32 v2_frames, v2_epoch, v2_skip_draw, v2_skip_fill;
static u32 seen_epoch = 0xFFFFFFFF;
static int own_now, own_mode;

/* the bottom window (z 135) and its composited children (z 54..62: overview frame, overview,
 * under-bar, playhead...) are wholly ours while we own the screen: their "composited" bit (+7
 * bit 3, tested by the flush) is cleared so the flush neither copies nor composes them, and
 * restored on leaving -- except z 54/57/59 while INFO (screen 6) is up, which ui3000x hides. */
#define N_HIDDEN 64	/* F2 audit: was 32. Full = a window is not taken over this frame (it stays out of the panel: the
			 * compose gate asks per window, not this list), counted in v2_hid_full */
static volatile u8 *hidden[N_HIDDEN];
static int hidden_z[N_HIDDEN];
static int n_hidden;
u32 v2_hid_full;
static int hidden_has(volatile u8 *w)
{
	int k;
	for (k = 0; k < n_hidden; k++)
		if (hidden[k] == w)
			return 1;
	return 0;
}

static int wz(volatile u8 *w) { return (int)u32be(w + 12); }
/* windows wholly ours: the bottom window and its children on every owned screen; on the player
 * screen (where we repaint all 800 x 480 every frame) also the top windows z 133/134 -- incl. the
 * stock centre-waveform canvas -- and their button children z 70..72 */
/* ---- stock windows on our screens: one table (re/V2_OVERLAYS.md) ----
 * Every in-use window of layer 0 is classified by the screen we own and its z:
 *   O_OWN    ours: stock neither draws, clears nor composes it (we draw that part)
 *   O_HIDE   stock draws it, the flush does not compose it (we draw the equivalent)
 *   O_KEEP   composed as stock, under a part we repaint every frame (the top window z 133 on the
 *            player must stay composed: with nothing composed the flush stops flipping)
 *   O_OVL    anything else -- pop-ups, banners, warnings (z 7 "PAUSE the player...", SYNC / MASTER
 *            toasts, EMERGENCY LOOP): never composed over us; ovl_paint() copies its own pixels
 *            (without its black background) onto our frame, on a 3000-style panel at its place, or
 *            on the player's deck area (cached regions) into the strip y 295..316. Its blinking
 *            (stock drawing / clearing the surface) comes through as is.
 * Composition is cut at two points: manage() at the frame's first draw, and again in v2_paint()
 * after the flush composed (ovl_scan): a window found composed there was composed into THIS buffer,
 * so every cached region of the buffer is repainted before it is shown. */
enum { O_OVL, O_OWN, O_HIDE, O_KEEP };
#define MB(m) (1 << (m))
#define M_ALL (MB(M_PLAYER) | MB(M_BROWSE) | MB(M_SHORTCUT) | MB(M_PINFO))
static const struct orule { u8 modes, zlo, zhi, act; } orules[] = {
	{ M_ALL, 135, 135, O_OWN },		/* bottom window: the deck area */
	{ M_ALL, 53, 62, O_OWN },		/* its children: overview, needle, playhead, slip ghost */
	{ MB(M_PLAYER), 63, 63, O_HIDE },	/* stock centre-waveform canvas */
	{ MB(M_PLAYER), 50, 50, O_HIDE },	/* loop shading over the waveform */
	{ MB(M_PLAYER), 64, 65, O_HIDE },	/* PHASE METER TYPE 2: stock's two 216x25 meters (ours drawn) */
#ifndef V2_OWN_TOP
#define V2_OWN_TOP (MB(M_BROWSE) | MB(M_PLAYER) | MB(M_SHORTCUT) | MB(M_PINFO))	/* D1: + SHORTCUT, INFO (pages all ours) */
#endif
	/* P8: with keep_dirty() the flush flips even when nothing is composed, so the top windows and the
	 * list windows are ours too where we draw everything (stock no longer draws / clears / composes
	 * them: the lists' double work). z 129..134 = the screens' 800x294 top windows; z 128 = stock's pop-up
	 * window, O_OWN here only when no stock-drawn pop-up is up (2.01-a, see oclass) */
	{ V2_OWN_TOP, 128, 134, O_OWN },
	{ V2_OWN_TOP, 136, 137, O_OWN },
	{ MB(M_BROWSE) | MB(M_SHORTCUT) | MB(M_PINFO), 64, 79, O_OWN },	/* list rows, title marquee, INFO artwork
										 * (F2 audit: two O_KEEP rules for the same modes
										 * and z stood below this one, never reached) */
	{ M_ALL, 128, 134, O_KEEP },		/* the top windows (one per screen) */
	{ M_ALL, 136, 137, O_KEEP },
};
static int oclass(volatile u8 *w)
{
	int z = (int)u32be(w + 12), k;
	/* 2.01-a displayer (R21D5): z 128 = stock's pop-up window. O_HIDE (stock draws it, pop_stock_blit shows it)
	 * ONLY for the pop-ups verified to be stock-drawn (stock_title: REMOVE ALL TRACKS, MY SETTINGS -- the latter
	 * by title on any screen, as the deck-confirmed 1.92 fix). Everything else = the table below = 1.92: idle,
	 * our MENU panes (SORT / LIST MENU / TAGLIST MENU / LOAD PREVIOUS TRACK and any other popup() draws), UTILITY's
	 * value edit (+0x0F on sid 0x0A: R21D3 showed stock's undrawn surface there, white on the deck), the TOUCH
	 * GRID ADJUST pop-up, TRACK FILTER / MY TAG pages. Replaces the V3rc1 TAGLIST MENU O_HIDE (now ours, synced:
	 * no stock menu flashing over our pane) and the 1.92 MY SETTINGS special case. */
	if (z == 128) {
		if (stock_title()) {	/* R21D5: only the verified stock-drawn pop-ups */
			KIT(kit_zhide++;)
			return O_HIDE;
		}
		KIT(kit_zown++;)
	}
	for (k = 0; k < (int)(sizeof(orules) / sizeof(orules[0])); k++)
		if ((orules[k].modes & MB(own_mode)) && z >= orules[k].zlo && z <= orules[k].zhi)
			return orules[k].act;
	return O_OVL;
}
/* V3rc2: the black box beside SORT / LIST MENU (open since V3e1). With the pop-up opened by a touch (the column
 * bar) stock copies its menu window z 128 (429,12 353x277; O_OWN here, so never drawn: black) straight into the
 * frame AFTER our paint (the GR3 blit 0x0E530D8E, write-watch work/v3rc2/bb.sh). Its surface gets our painted
 * pixels of that rectangle, so the copy puts back what we drew. */
/* V3rc8w (re/LPT_WHITE_BAR.md): the menu window is 353 x 277 = 195,562 B. The V3rc8o B2 check (bytes vs the old
 * 0x18000-B POP_BAK, which overlapped the phase ring PRING(0) at 0x0CB18000) made popup_sync a no-op for it, so
 * stock's per-frame copy of z 128 showed ITS surface (the white list cursor) over our LOAD PREVIOUS TRACK pane
 * (and SORT / LIST MENU). POP_BAK now lives after the canvas: 0x0CCBB800..0x0CD00000 = 0x44800 B (MEMPROBE Z2). */
#define POP_BAK ((u16 *)0x0CCBB800)
#define POP_BAK_SZ 0x44800	/* bytes */
static u16 *pop_surf;		/* the menu window's surface while we write into it, else 0 */
static int pop_n;
static void pop_restore(void)	/* the pop-up gone: stock's own pixels back (the MY TAG page reuses it) */
{
	if (pop_surf) {
		cp16(pop_surf, POP_BAK, pop_n);
		pop_surf = 0;
	}
}
/* 2.01-a (review C2): every z 128 window is looked at (no return on the first one that is not ours), and a pane
 * that cannot be mirrored (no usable surface, or bigger than POP_BAK) no longer fails silently into a black box:
 * pop_nosync hands the window back to stock (oclass -> O_HIDE, stock's own menu in place) until the pop-up closes.
 * Not expected with the one stock window (353 x 277 = 195,562 B < POP_BAK_SZ); a guard. */
static void popup_sync(void)
{
	int i, y;
	for (i = 0; i < 256; i++) {
		volatile u8 *w = WPOOL + 160 * i;
		int ww, hh, wx, wy;
		u32 d, base;
		if (!(u32be(w) & 0x40000000) || u32be(w + 28) != LAYER0 || wz(w) != 128 ||
		    (oclass(w) != O_OWN && !(pst_undrawn && oclass(w) == O_HIDE)))	/* R21D5: ours until stock drew */
			continue;
		ww = (int)u16be(w + 8); hh = (int)u16be(w + 10);
		wx = (int)u32be(w + 84); wy = (int)u32be(w + 88);
		d = u32be(w + 152);
		base = (d & 0xFF000000) == 0x0F000000 ?
			u32be((const volatile u8 *)((d & 0x1FFFFFFF) | 0x20000000) + 12) : 0;
		if (ww <= 0 || hh <= 0 || wx < 0 || wy < 0 || wx + ww > W || wy + hh > 480 || (base >> 24) != 0x0C ||
		    ww * hh * 2 > POP_BAK_SZ	/* bytes (V3rc8 audit B2) */ || (pop_surf && pop_surf != (u16 *)base)) {
			continue;	/* R21D5: stays ours (1.92), no hand-over to stock */
		}
		if (!pop_surf) {
			pop_surf = (u16 *)base;
			pop_n = ww * hh;
			cp16(POP_BAK, pop_surf, pop_n);
		}
		for (y = 0; y < hh; y++)
			cp16((u16 *)base + y * ww, fb + (wy + y) * W + wx, ww);
		pst_stamp();	/* R21D5: keep the sentinel for pst_check */
	}
}

static int ours_w(volatile u8 *w)	/* stock neither draws, clears nor composes these */
{
	int z = wz(w);
	if (own_mode == M_NONE)
		return z == 135 || (z >= 54 && z <= 62);
	return oclass(w) == O_OWN;
}
static int hide_win(volatile u8 *w)	/* kept out of the composition on the screen we own */
{
	return own_mode != M_NONE && u32be(w + 28) == LAYER0 && oclass(w) != O_KEEP;
}
/* F2 the compose gate (entry.S comp_e, from the flush's window loop 0x0E509A1C): 1 = this window is not composed.
 * manage() / ovl_scan() take a window out of the composition by clearing its "composited" bit, but only once they
 * have SEEN it: a window stock creates and composes in the same pass reached the frame buffer first -- and where
 * it is ours (O_OWN: stock never draws it) that is a surface nobody ever drew. Black in the emulator (QEMU RAM is
 * zeros), white or coloured garbage on the deck: the INFO white panel and the corrupted bands (emu, CDJ_GUI_POISON:
 * one field of 800 x 294 / 800 x 430 / the 600 x 40 preview strip / the needle marker). The screen we own is read
 * NOW, not from the frame's cached own_mode, so the first flush of a screen change is covered too. Not owned (stock
 * screens, update mode: screen_mode() = M_NONE) = stock, untouched. The bit itself is left alone: ovl_scan still
 * finds the window "composed", takes it over and repaints as before. */
u32 v2_comp_hid, v2_comp_n;
static void frame_tick_late(void);
int v2_compose_hide(u32 win)
{
	volatile u8 *w = (volatile u8 *)win;
	int keep = own_mode, r;
	v2_comp_n++;
	own_mode = screen_mode();
	frame_tick_late();		/* A10: the tick that does not depend on stock drawing a window */
	r = !w || !(w[7] & 8) || hide_win(w);	/* stock's own test first: not "composited" = not composed */
	if (w && (w[7] & 8) && r)
		v2_comp_hid++;
	own_mode = keep;
	return r;
}
static int info_z(int z) { return z == 54 || z == 57 || z == 59; }
/* 2.01-a (R21D3, coordinator: REMOVE ALL TRACKS' selected option was light text on the white cursor bar): the
 * text colours are ours, not stock's -- patch_gui's ui3000xtext poke turns font styles 1 (selected row) and 3
 * (selected row, dimmed while playing) from stock's dark ink into a light ramp, for ui3000x's navy / cyan
 * cursors. Stock's pop-up keeps its WHITE cursor bar (its art is not recoloured), so the selected item came out
 * #CED7DE / #FFFFFF on #FFFFFF. While a stock-drawn pop-up is up on a screen we own, nothing else stock renders
 * uses those styles (every other window is ours and its text is skipped), so put stock's dark ramps back for
 * that time and the light ones after. Data only (the style table is RAM), written cached + uncached as ui3000x
 * does; only when the table holds exactly the ui3000xtext values (no ui3000x = nothing to undo). */
#define STY(a) (*(volatile u32 *)(a))
static const u32 sty_addr[6] = { 0x0E5958E8, 0x0E5958EC, 0x0E5958F0, 0x0E595908, 0x0E59590C, 0x0E595910 };
static const u32 sty_ours[6] = { 0x0090A4B0, 0x00C8D4DC, 0x00FFFFFF, 0x0090A4B0, 0x00C8D4DC, 0x00FFFFFF };
static const u32 sty_stock[6] = { 0x00B5B6BD, 0x005A595A, 0x00000000, 0x00C6C7CE, 0x00ADAEB5, 0x009C9A9C };
static int sty_dark;
static void sty_set(const u32 *v)
{
	int k;
	for (k = 0; k < 6; k++) {
		STY(sty_addr[k]) = v[k];
		STY(sty_addr[k] | 0x20000000) = v[k];
	}
}
/* R21D5 safety net (owner: no white / garbage box, ever): stock's z 128 surface is shown only after stock has
 * drawn into it THIS time. When a verified stock pop-up comes up (manage, before stock draws the frame) five probe
 * pixels of its surface (corners + centre; the stock dialog is opaque over the whole window) get a sentinel; at
 * our paint (after stock drew) all five overwritten = drawn -> pst_undrawn 0, pop_stock_blit shows it. Until then
 * pop_ours() keeps our own pane (popup() + popup_sync, which re-stamps the probes) = the 1.92 behaviour, so the
 * worst case is our pane, never stock's uninitialised SDRAM. */
#define PST_SENT 0x0841u
static volatile u16 *pst_px;	/* the armed surface (uncached), 0 = none */
static int pst_w, pst_h;
static volatile u16 *pst_find(int *ww, int *hh)	/* the O_HIDE z 128 window's surface (uncached) or 0 */
{
	int i;
	for (i = 0; i < 256 && own_now; i++) {
		volatile u8 *w = WPOOL + 160 * i;
		u32 d, base;
		if (!(u32be(w) & 0x40000000) || u32be(w + 28) != LAYER0 || wz(w) != 128 || oclass(w) != O_HIDE)
			continue;
		*ww = (int)u16be(w + 8); *hh = (int)u16be(w + 10);
		d = u32be(w + 152);
		if (*ww < 8 || *hh < 8 || *ww > W || *hh > 480 || (d & 0xFF000000) != 0x0F000000)
			return 0;
		base = u32be((const volatile u8 *)((d & 0x1FFFFFFF) | 0x20000000) + 12);
		return (base >> 24) == 0x0C ? (volatile u16 *)((base & 0x1FFFFFFF) | 0x20000000) : 0;
	}
	return 0;
}
static int pst_probe(int k) { return k == 0 ? 2 * pst_w + 2 : k == 1 ? 3 * pst_w - 3 : k == 2 ? (pst_h - 3) * pst_w + 2 :
	k == 3 ? (pst_h - 2) * pst_w - 3 : (pst_h / 2) * pst_w + pst_w / 2; }
static void pst_stamp(void)
{
	int k;
	if (pst_px && pst_undrawn)
		for (k = 0; k < 5; k++)
			pst_px[pst_probe(k)] = PST_SENT;
}
static void pst_arm(void)	/* manage(): frame start */
{
	int ww = 0, hh = 0;
	volatile u16 *px = pst_find(&ww, &hh);
	if (px != pst_px || (px && (ww != pst_w || hh != pst_h))) {
		pst_px = px; pst_w = ww; pst_h = hh;
		pst_undrawn = 1;
		pst_stamp();
	}
}
static void pst_check(void)	/* paint start: stock has drawn this frame's windows */
{
	int k, n = 0;
	if (!pst_px || !pst_undrawn)
		return;
	for (k = 0; k < 5; k++)
		n += pst_px[pst_probe(k)] != PST_SENT;
	if (n == 5) {
		pst_undrawn = 0;
		/* our pane's backup of this surface (popup_sync) must not be put back over stock's fresh drawing */
		if (pop_surf && ((u32)pop_surf & 0x1FFFFFFF) == ((u32)pst_px & 0x1FFFFFFF))
			pop_surf = 0;
	}
}
static void stock_pop_ink(void)
{
	int i, up = 0, k;
	pst_arm();
	for (i = 0; i < 256 && own_now && !up; i++) {
		volatile u8 *w = WPOOL + 160 * i;
		up = (u32be(w) & 0x40000000) && u32be(w + 28) == LAYER0 && wz(w) == 128 && oclass(w) == O_HIDE;
	}
	if (up && !sty_dark) {
		for (k = 0; k < 6; k++)
			if (STY(sty_addr[k] | 0x20000000) != sty_ours[k])
				return;
		sty_set(sty_stock);
		sty_dark = 1;
	} else if (!up && sty_dark) {
		sty_set(sty_ours);
		sty_dark = 0;
	}
}
static void manage(void)
{
	int i, j;
	own_mode = screen_mode();
	own_now = own_mode != M_NONE;
	if (!(own_mode != M_NONE && pop_ours())) {	/* 2.01-a: also when a stock pop-up replaces ours */
		pop_restore();
	}
	stock_pop_ink();	/* 2.01-a R21D3: before stock renders this frame's pop-up */
	for (i = j = 0; i < n_hidden; i++) {
		volatile u8 *w = hidden[i];
		int z = hidden_z[i];
		int keep = (own_now && hide_win(w)) || (MODEL[7] == 0x06 && info_z(z));
		if (!(u32be(w) & 0x40000000) || wz(w) != z)
			continue;		/* freed or reused since: forget it */
		if (keep) {
			hidden[j] = w;
			hidden_z[j++] = z;
			continue;
		}
		w[7] |= 8;
	}
	n_hidden = j;
	if (!own_now)
		return;
	for (i = 0; i < 256; i++) {
		volatile u8 *w = WPOOL + 160 * i;
		if (!(u32be(w) & 0x40000000) || u32be(w + 28) != LAYER0)
			continue;
		if (!hide_win(w))
			continue;
		if (!(w[7] & 8))
			continue;
		if (n_hidden >= N_HIDDEN) {
			v2_hid_full++;
			break;
		}
		w[7] &= ~8;
		hidden[n_hidden] = w;
		hidden_z[n_hidden++] = wz(w);
	}
}

/* after the flush composed, before our paint (see the table above) */
static volatile u8 *ovl[4];
static int n_ovl;
/* V4f (deck V4e log: the stock "NO DISC" status line of an empty deck kept every frame a full repaint + full
 * copy -- D 19 ms, C 7.7 ms, 24 fps): ovl_blit no longer resets the regions it covers every frame. It hashes
 * the overlays' content and place into ovl_sig; paint_frame repaints everything once (cache_stale) only when
 * that changes (a blink, a new text, an overlay gone), and copies only the dirty bands otherwise. */
static u32 ovl_sig, ovl_lsig, v2_ovl_chg;
/* V4k (deck V4g: an empty player's bottom flickered -- the NO DISC line blinks, every blink changed ovl_sig and
 * repainted + copied the whole screen): ovl_gsig = the overlays' place only (window, x, y, size); when it is
 * unchanged and only the pixels changed (a blink, a new text at the same place), only the regions that
 * overlay touches (ovl_rmask: region-key bits, kept from the last frame it drew) are redrawn, and only their
 * rows copied. A window that comes / goes / moves still repaints everything once. */
static u32 ovl_gsig, ovl_lgsig, ovl_rmask, ovl_lmask;
u32 v2_ovl_part, v2_ovl_rect;
u32 v2_ovl_late, v2_ovl_band, v2_ovl_dbg[4];		/* frames where a hidden window had been composed (repainted over) */
static u32 ovl_lband;	/* V4k: canvas bands to re-send after stock composed a status-line overlay (see ovl_scan) */
/* D1 (emu: MENU on the player at 30 fps, every frame a full repaint + a full copy): the pop-up's stock window
 * z 128 is composed into the GR3 buffer every frame. In SMOOTH the canvas never holds stock's pixels, so only
 * the window's rectangle is sent again from the canvas (lr_*: the late windows' union this frame, lr_ok 0 =
 * a window without a usable place -> the full repaint as before) */
static int lr_x0, lr_y0, lr_x1, lr_y1, lr_ok;
static int ovl_scan(void)
{
	int i, late = 0;
	n_ovl = 0;
	ovl_lband = 0;
	lr_ok = 1;
	lr_x0 = lr_y0 = 9999;
	lr_x1 = lr_y1 = 0;
	for (i = 0; i < 256; i++) {
		volatile u8 *w = WPOOL + 160 * i;
		if (!(u32be(w) & 0x40000000) || !hide_win(w))
			continue;
		if (w[7] & 8) {
			int k, known = 0;
			int z = wz(w);
			w[7] &= ~8;
			/* P9: the deck area's children (z 53..62: overview, needle, playhead, slip ghost) lie in
			 * the overview region (need(9), y 400..480) only. During needle search stock re-composes
			 * its needle marker (z 56) every frame, which used to repaint every cached region of the
			 * buffer (scrub 30 fps): now only that region. */
			int wx = (int)u32be(w + 84), wy = (int)u32be(w + 88);
			int ww = (int)u16be(w + 8), wh = (int)u16be(w + 10);
			if (z >= 53 && z <= 62 && ww <= 8) {	/* the needle / playhead markers only: a wide
								 * one (the 600x40 preview strip at 100,381
								 * during loads) covers the time digits too */
				/* P10: they also reach above the overview region (INFO: the browsed track's
				 * overview strip at y ~390, Mac captures): clear the gap y 386..399 between the
				 * time row and the overview, and redraw the regions that touch it (6, 9, 10) */
				/* V3f: only the window's own columns of the gap, and only the regions it touches
				 * (a paused deck re-composes its playhead / needle child every frame: clearing the
				 * whole gap and three regions each frame cost a full deck-area repaint) */
				int gx = wx - 2 < 79 ? 79 : wx - 2, gw = wx + ww + 2 > 672 ? 672 - gx : wx + ww + 2 - gx;
				if (gw > 0)
					fill(gx, 386, gw, 14, C_BLACK);	/* not above 386: the big time / track
									 * digits reach down to ~384 */
				rk[rb][9] = 0;
				if (wx + ww >= 660)
					rk[rb][6] = rk[rb][10] = 0;
				v2_ovl_band++;
			} else if (z == 52 && wx >= 0 && ww > 0 && wx + ww <= W && wy >= 380 && wh > 0 &&
				   wy + wh <= 480) {
				/* ... and its needle-search marker z 52 (3 x 49 at y 382, over the overview): back
				 * to the deck background there, the overview region redraws its own part */
				fill(wx, wy, ww, wh, C_BLACK);
				rk[rb][9] = 0;
				v2_ovl_band++;
			} else if (oclass(w) == O_OVL && wy >= 360 && wh > 0 && wy + wh <= 480 && wx >= 0 && ww > 0 &&
				   wx + ww <= W) {
				/* V4k (deck V4g: an empty player's bottom flickered): the status line (NO DISC ...)
				 * blinks by being composed again into the GR3 buffer on every phase; the canvas never
				 * holds stock's pixels, so only its rows are sent again from the canvas (SMOOTH) --
				 * not a repaint of every region + a whole-frame copy in both buffers */
				ovl_lband |= (2u << ((wy + wh - 1) >> 4)) - (1u << (wy >> 4));
				v2_ovl_part++;
			} else {
				late = 1;
				if (ww > 0 && wh > 0 && wx < W && wy < 480 && wx + ww > 0 && wy + wh > 0) {
					int ax = wx < 0 ? 0 : wx, ay = wy < 0 ? 0 : wy;
					int bx = wx + ww > W ? W : wx + ww, by = wy + wh > 480 ? 480 : wy + wh;
					if (ax < lr_x0) lr_x0 = ax;
					if (ay < lr_y0) lr_y0 = ay;
					if (bx > lr_x1) lr_x1 = bx;
					if (by > lr_y1) lr_y1 = by;
				} else
					lr_ok = 0;
				v2_ovl_dbg[0] = (u32)z;
				v2_ovl_dbg[1] = (u32)wx << 16 | (u32)(wy & 0xFFFF);
				v2_ovl_dbg[2] = (u32)ww << 16 | (u32)wh;
				v2_ovl_dbg[3]++;
			}
			for (k = 0; k < n_hidden; k++)
				known |= hidden[k] == w;
			if (!known && n_hidden < N_HIDDEN) {
				hidden[n_hidden] = w;
				hidden_z[n_hidden++] = wz(w);
			} else if (!known)
				v2_hid_full++;
		}
		if (oclass(w) == O_OVL && n_ovl < 4 && hidden_has(w))
			ovl[n_ovl++] = w;
	}
	v2_ovl_late += late;
	return late;
}

/* one overlay window's own pixels (black = transparent) onto our frame */
HOTSW static void ovl_blit(volatile u8 *w)
{
	const volatile u16 *px;
	u32 d, base;
	int ww = (int)u16be(w + 8), hh = (int)u16be(w + 10);
	int wx = (int)u32be(w + 84), wy = (int)u32be(w + 88);
	int x, y, x0 = 9999, x1 = -1, y0 = 9999, y1 = -1, dx, dy = 0, strip, own = 0;
	d = u32be(w + 152);
	if ((d & 0xFF000000) != 0x0F000000 || ww <= 0 || hh <= 0 || ww > W || hh > 480)
		return;
	base = u32be((const volatile u8 *)((d & 0x1FFFFFFF) | 0x20000000) + 12);
	if ((base >> 24) != 0x0C)
		return;
	px = (const volatile u16 *)((base & 0x1FFFFFFF) | 0x20000000);
	{	/* V4f: the window's content signature (pixels + place), see ovl_sig. Two pixels a read (uncached
		 * SDRAM: the reads are the cost on the deck) when rows are word aligned, else one. */
		u32 s = ovl_sig * 31 + (u32)w + (u32)wx + ((u32)wy << 12);
		int two = !(base & 3) && !(ww & 1);
		for (y = 0; y < hh; y++) {
			const volatile u16 *r = px + y * ww;
			for (x = 0; x < ww; x += 1 + two) {
				u32 c = two ? *(const volatile u32 *)(r + x) : r[x];
				if (c) {
					int xa = x, xb = x;
					s = s * 31 + c + (u32)x + ((u32)y << 10);
					if (two) {
						if (!(c >> 16)) xa++;
						if (c & 0xFFFF) xb++;
					}
					if (xa < x0) x0 = xa;
					if (xb > x1) x1 = xb;
					if (y < y0) y0 = y;
					y1 = y;
				}
			}
		}
		ovl_sig = s;
		ovl_gsig = ovl_gsig * 31 + (u32)w + (u32)wx + ((u32)wy << 12) + ((u32)ww << 20) + (u32)hh;
	}
	if (x1 < 0)
		return;				/* nothing drawn (a blink's 'off' phase) */
	/* the deck area (cached on every screen) never takes an overlay: the strip y 295..316 does */
	strip = wy + y1 >= 287;		/* the deck area is cached on every screen */
	if (own_mode != M_PLAYER) {
		/* V3e1: the browse family has the thin strip (y 420..): the stock status line (NOW LOADING, E-8302,
		 * NO DISC ...) goes into the strip's title cell (176..520 x 422..478), red text on black; anything
		 * else (SYNC / MASTER toasts, "PAUSE the player...", EMERGENCY LOOP, TRACK FILTER unavailable)
		 * into a 3000 pop-up box centred over the list (#191919, 2-px #AFAFAF frame) */
		int bw = x1 - x0 + 1, bh = y1 - y0 + 1;
		ovl_rmask |= strip && wy + y0 >= 371 ? 1u << 4 : 0x1FFF800u;	/* V4k: region 4 / 11..24 */
		if (strip && wy + y0 >= 371) {
			if (bw > 340) x1 = x0 + 339, bw = 340;
			if (bh > 52) y1 = y0 + 51, bh = 52;
			fill(176, 422, 346, 56, C_BLACK);
			dx = 348 - bw / 2 - x0;
			dy = 450 - bh / 2 - y0;
		} else {
			if (bw > 560) x1 = x0 + 559, bw = 560;
			if (bh > 200) y1 = y0 + 199, bh = 200;
			fill(400 - bw / 2 - 20, 230 - bh / 2 - 16, bw + 40, bh + 32, C_POP);
			frame(400 - bw / 2 - 20, 230 - bh / 2 - 16, bw + 40, bh + 32, 2, C_POPF);
			dx = 400 - bw / 2 - x0;
			dy = 230 - bh / 2 - y0;
		}
		dmark(y0 + dy, y1 - y0 + 1);
		for (y = y0; y <= y1; y++) {
			int yy = y + dy;
			if (yy < 0 || yy >= 480)
				continue;
			for (x = x0; x <= x1; x++) {
				u16 c = px[y * ww + x];
				int xx = x + dx;
				if (c && xx >= 0 && xx < W)
					fb[yy * W + xx] = c;
			}
		}
		return;
	}
	/* V3f: the header, the phase meter and the band are keyed now -- whatever this overlay covers there is
	 * repainted in both buffers once it blinks off or goes away (V4f: by ovl_sig, not every frame) */
	ovl_rmask |= 3u | 1u << R_BAND | (strip ? 0x7FCu : 0);	/* V4k: header, meter, band (+ deck 2..10) */
	if (strip && wy + y0 >= 371) {
		/* the stock status line of the deck area (E-8302 / E-8305, NOW LOADING, NO DISC...): at its
		 * own place as stock shows it -- under REMAIN, red text, no panel -- also with a track
		 * playing (P10, user: it was put on a grey panel over the band's tick row). Black behind
		 * the text (it may cross the overview); the deck regions under it are repainted next
		 * frame (it blinks / goes away). */
		strip = 0;
		own = 1;
		dy = wy;
		if (!deck_free)
			fill(wx + x0 - 4, wy + y0 - 2, x1 - x0 + 9, y1 - y0 + 5, C_BLACK);
	} else if (strip) {
		/* the strip: rows 287..305 (the band's bottom on the player, under a list elsewhere),
		 * on a panel; both are repainted every frame */
		if (y1 - y0 + 1 > 17)
			y1 = y0 + 16;
		dy = 288 + (17 - (y1 - y0 + 1)) / 2 - y0;
		fill(wx + x0 - 8, 287, x1 - x0 + 17, 19, C_POP);
		frame(wx + x0 - 8, 287, x1 - x0 + 17, 19, 1, C_POPF);
	} else if (!own) {	/* V3e1 (audit K1): the 3000 pop-up -- #191919, 2-px #AFAFAF frame */
		dy = wy;
		fill(wx + x0 - 8, wy + y0 - 6, x1 - x0 + 17, y1 - y0 + 13, C_POP);
		frame(wx + x0 - 8, wy + y0 - 6, x1 - x0 + 17, y1 - y0 + 13, 2, C_POPF);
	}
	dx = wx;
	dmark(y0 + dy, y1 - y0 + 1);
	for (y = y0; y <= y1; y++) {
		int yy = y + dy;
		if (yy < 0 || yy >= 480)
			continue;
		for (x = x0; x <= x1; x++) {
			u16 c = px[y * ww + x];
			int xx = x + dx;
			if (c && xx >= 0 && xx < W)
				fb[yy * W + xx] = c;
		}
	}
}

/* D1 (re/V2_DEBUG.md): the flush 0x0E509886 copies and flips only when the layer's dirty union is not
 * empty; with stock's windows skipped on our screens a static list leaves it empty and nothing flips,
 * so our paint (chained on the VDC base write) stops. While we own a screen the layer's own dirty
 * rectangle (+52: x0, y0, x1, y1) gets one pixel each frame: enough to flip, nothing to repaint. */
static void keep_dirty(void)
{
	volatile u32 *r = (volatile u32 *)((u32)LAYER0 + 52);
	if (r[0] >= r[2] || r[1] >= r[3]) {
		r[0] = 0;
		r[1] = 0;
		r[2] = 1;
		r[3] = 1;
	}
}

/* Tearing guard: GR3_UPDATE (0xFFFF7780) keeps IBUS_VEN / P_VEN (0x11) set from the base write until
 * the VDC5 takes the new base at the next vsync. Until then the panel still scans the OTHER buffer --
 * the one this frame is about to compose and paint into. So the frame's drawing and our paint wait
 * for the latch (bounded: a model that never clears the bits, as an old emulator build, turns the
 * guard off after three timeouts). */
#define GR3_UPDATE (*(volatile u32 *)0xFFFF7780)
u32 v2_latch_waits, v2_latch_stuck, v2_latch_ms, v2_latch_aged, v2_pace_ms;
#ifdef V2_VSPACE
static int vs_armed;	/* V3rc8: the previous base latched and the ISR flag was cleared: its next set = one vsync later */
#endif
/* P9: the latch wait is about OUR last base write only. GR3_UPDATE's bits are also re-armed by other GR3
 * register writes stock makes (e.g. every frame during needle search), so the bits alone over-waited a
 * whole field per frame. A base we wrote one field (17 ms) ago or more has been taken whatever the bits
 * say; otherwise wait for the bits, at most until 17 ms after our write. Time = the RTOS clock the GUI
 * loop itself uses (0x0E52E9FC(t): ms in t[1]); sleep(1) polls yield the CPU as the stock flip does. */
static u32 last_write_ms, have_write;
static u32 now_ms(void)
{
	u32 t[4];
	((void (*)(u32 *))0x0E52E9FC)(t);
	return t[1];
}
#define VSYNC_FLAG (*(volatile u32 *)0x0F6A6960)	/* set by the GUI's vsync ISR; the stock flip clears it, then polls */
static void note_write(void)
{
	last_write_ms = now_ms();
	have_write = 1;
	VSYNC_FLAG = 0;		/* set again at the next vsync = the one that takes this base */
}
#ifdef V2_G3PURGE
/* CACHECOH (work/cachecoh/REPORT.txt, PROTOTYPE): stock writes the GR3 frame buffers through the CACHED on-chip
 * alias 0x1C08.. (desc[12]; its narrow-rect CPU copies in the flush and its windows blitted straight into the
 * frame, 0x0E530D8E). The GUI's operand cache is write-back (CCR1 = 0x0909: OCE, WT = 0), so those pixels can
 * sit dirty in the 8 KB D-cache and reach RAM -- the panel -- whenever the line is evicted, i.e. AFTER our
 * uncached (0x3C..) paint / DMA copy of the same rows: a brief patch of stock pixels until the self-heal finds it.
 * Stock's DMA copy 0x0E50FFDC purges its destination only for a cached-form address; we pass 0x3C.., so it
 * skips it. Before we write the buffer: sweep the operand-cache address array (4 ways x 128 entries) and
 * write back + invalidate every valid line that belongs to the GR3 buffers (associative write, exactly as
 * stock's purge helper 0x0E51C5A0 does). Runs from the uncached mirror (+0x20000000), as the SH-2A requires
 * of code that touches the cache arrays. ~512 array reads a frame (~10-20 us). */
u32 v2_g3p_calls, v2_g3p_lines;
__attribute__((noinline, used)) static u32 g3_purge_body(void)
{
	u32 w, e, n = 0;
	for (w = 0; w < 4; w++)
		for (e = 0; e < 128; e++) {
			u32 t = *(volatile u32 *)(0xF0800000u | w << 11 | e << 4);
			u32 la = (t & 0x1FFFF800u) | e << 4;	/* the line's address (tag 28..11 + entry) */
			if ((t & 1) && la - 0x1C080000u < 0x177000u) {
				*(volatile u32 *)(0xF0800008u | e << 4) = t & 0x1FFFF800u;	/* A = 1, V = U = 0 */
				n++;
			}
		}
	return n;
}
static void g3_purge(void)
{
	u32 (*f)(void) = (u32 (*)(void))((u32)g3_purge_body | 0x20000000u);
	v2_g3p_lines += f();
	v2_g3p_calls++;
}
#endif
static void wait_latch(void)
{
	u32 since;
#ifdef V2_NO_LATCHWAIT
	return;
#endif
	lk_wl = 0;		/* LINKLAT: set below when the wait ends on the vsync flag */
	if (!(GR3_UPDATE & 0x11) || !have_write || VSYNC_FLAG) {
		v2_latch_aged++;
#ifdef V2_VSPACE
		VSYNC_FLAG = 0;		/* V3rc8: arm the next-vsync edge for the 2-vsync pacing (v2_paint) */
		vs_armed = 1;
#endif
		return;
	}
	v2_latch_waits++;
	/* fallback bound (2 fields; the RTOS clock may tick coarsely) if the ISR flag never comes */
	since = now_ms() - last_write_ms;
	while ((GR3_UPDATE & 0x11) && !VSYNC_FLAG && since < 34) {
		((void (*)(u32))0x0E52EA70)(1);
		v2_latch_ms++;
		since = now_ms() - last_write_ms;
	}
	if (!VSYNC_FLAG && since >= 34)
		v2_latch_stuck++;
	else if (VSYNC_FLAG)
		lk_wl = 1;	/* LINKLAT: this paint starts on that vsync */
#ifdef V2_VSPACE
	VSYNC_FLAG = 0;
	vs_armed = 1;
#endif
}

/* V3f frame-on-change: what our screens show comes from MAIN's models (written by the GUI's receive path /
 * DMA), the heartbeat, and our own timers (pend). Once per GUI loop pass (frame_check runs from the stock
 * draw / clear callbacks) the inputs are hashed; a difference -- or a timer of ours, or the last change not
 * yet in both buffers -- keeps the flush flipping, so our paint runs. A static screen stops flipping.
 * Sampled, not whole: the row cells (0x1180 B each) by their middle row, the artwork / overview / detail
 * by spots (every load or row change also moves the model or the heartbeat). */
static int dirty_n = 2;
static u32 det_ms, det_h, det_w54[2], det_idle;
u32 v2_det_runs, v2_det_hits, v2_probes;
static u32 hrot(u32 h, u32 v) { return (h << 5 | h >> 27) ^ v; }
HOT static u32 spots(u32 h, const volatile u32 *p, int n, int step)
{
	int i;
	for (i = 0; i < n; i++, p += step)
		h = hrot(h, *p);
	return h;
}
static int inputs_changed(void)
{
	const volatile u32 *d = (const volatile u32 *)DECK;
	u32 h = 0x811C9DC5, w54 = d[0x54 / 4], t = now_ms();
	int i, k;
	if (t - det_ms < 8)
		return 0;		/* once per loop pass */
	det_ms = t;
	v2_det_runs++;
	for (i = 0; i < 0x1A8 / 4; i++)
		if (i != 0x54 / 4 && i != 0x14 / 4)
			h = hrot(h, d[i]);
	/* heartbeat +0x54 alternates two slots (V3d): a change is a change of the slot it carries */
	k = (w54 >> 24) == 0x4C ? (w54 >> 6) & 1 : 0;
	if (w54 != det_w54[k]) {
		det_w54[k] = w54;
		h = ~h;
	}
	{	/* V3e3: +0x14 alternates two pages too (bit 28) */
		static u32 det_w14[2];
		u32 w14 = d[0x14 / 4];
		k = (w14 >> 28) & 1;
		if (w14 != det_w14[k]) {
			det_w14[k] = w14;
			h = hmix(h, 0x14 + k);	/* (not ~h: +0x54 may flip in the same pass) */
		}
	}
	h = spots(h, (const volatile u32 *)MODEL, 0x2E3C / 4, 1);	/* the GUI's whole model copy */
	for (k = 0; k < 9; k++) {	/* row cells (112 x 20): rows 4, 10, 15, every 8th pixel pair */
		h = spots(h, (const volatile u32 *)((u32)SMALL_ART(k) + 4 * 224), 14, 4);
		h = spots(h, (const volatile u32 *)((u32)SMALL_ART(k) + 10 * 224), 14, 4);
		h = spots(h, (const volatile u32 *)((u32)SMALL_ART(k) + 15 * 224 + 4), 14, 4);
	}
	h = spots(h, (const volatile u32 *)ART_BIG, 32, 211);
	h = spots(h, (const volatile u32 *)OV_HDR, 4, 1);
	h = spots(h, (const volatile u32 *)OV_REC, 32, 28);
	h = spots(h, (const volatile u32 *)MONO_HDR, 4, 1);
	h = spots(h, (const volatile u32 *)OV_MONO, 25, 8);
	h = spots(h, (const volatile u32 *)MARKS, N_MARKS * 4, 1);
	h = hmix(hmix(hmix(hmix(h, OV_COLOUR), DET_LEN), grid_ck()), UPD_STATE);
	cue_poll();
	h = hmix(h, cue_ver);			/* V4b1 (cue_poll: the block can arrive while nothing else changes) */
	h = hmix(hmix(h, buf_ck(WENT)), buf_ck(WBLUE));
	h = spots(h, (const volatile u32 *)ERR_TXT, 8, 1);
	if (h != det_h) {
		det_h = h;
		v2_det_hits++;
		det_idle = 0;
		return 1;
	}
	if (++det_idle >= 90) {		/* a slow probe (~1 a second, one frame): anything the sampling missed */
		det_idle = 0;
		v2_probes++;
		return 2;
	}
	return 0;
}

static void frame_inputs(void);
static void frame_check(void)
{
#ifdef V2_HWBAND
	if (UPD_STATE)
		hb_off(HB_OFF_UPD);
#endif
#ifdef V2_GR1METER
	if (UPD_STATE)
		g1_off(G1_OFF_UPD);
#endif
	/* P9: only where stock may still compose windows into the frame buffer during the flush must the frame
	 * wait for the last base to be taken first; on the player and browse screens nothing touches GR3 before
	 * our paint, which waits for the latch itself. D1: SHORT CUT / player INFO are ours (canvas) now, but on
	 * entering / leaving them stock composes a just-created window (its surface never drawn: black) into
	 * the buffer -- kept, or it lands in the one still on the panel (emu stress: a black frame at INFO) */
	if (own_mode == M_SHORTCUT || own_mode == M_PINFO)
		wait_latch();
	if (seen_epoch != v2_epoch) {
		seen_epoch = v2_epoch;
		manage();
	}
	frame_inputs();
}
/* the screen's inputs, sampled (at most every 8 ms): a change keeps the flush flipping, so our paint runs.
 * F2 audit (A10, owner: the whole screen stuck under a playing deck, updating only now and then): this used to
 * run from stock's draw / clear callbacks alone -- a pass in which stock drew none of its windows sampled nothing,
 * and a screen that had stopped flipping stayed asleep whatever MAIN sent. It is now also called from the flush's
 * window loop (v2_compose_hide), which every flush runs through. */
/* ... but only as the FALLBACK, when the callbacks have not sampled for 100 ms. R22C4 sampled from both places
 * every pass. In normal use it never acts, so the paint pacing is exactly what it was. (Measured, work/r22/base.sh,
 * 4 x 6 s a state, DEV builds: R22C3n before and R22C5n after show the same two rates, ~60 and ~95 flips a second,
 * in every state -- the emulator's own bimodal pacing, which is also all that play3's 59.0 vs 76.6 was.) */
static void frame_tick_late(void)
{
	if (now_ms() - det_ms >= 100)
		frame_inputs();
}
static void frame_inputs(void)
{
	if (own_mode != M_NONE) {
		int c = inputs_changed();
		static u32 chg_t;
		if (c == 1)
			chg_t = now_ms() | 1;
		/* LOADFIX (deck: occasional missed updates -- half-drawn / stale elements after a load, the
		 * band / time until PLAY): the inputs are SAMPLED, so the last part of a multi-piece write (the
		 * overview, detail, models) can land between the spots after the change that started it, and
		 * the screen stopped flipping with a region drawn from half-written data. Keep painting 300 ms
		 * after every detected change: the regions' own full keys (ov_ck, need) then see the rest */
		if (chg_t && now_ms() - chg_t < 300)
			dirty_n = 2;
		else
			chg_t = 0;
		if (c == 1)
			dirty_n = 2;
		else if (c && !dirty_n)
			dirty_n = 1;
		if (dirty_n)
			keep_dirty();
	}
}

/* draw-callback dispatcher: r4 = window */
/* the frame's direct call of the stock centre-waveform renderer (entry +12) */
int v2_wave_skip(void)
{
	frame_check();
	if (own_mode == M_PLAYER && u32be(DECK + 0x60)) {
		v2_skip_wave++;
		return 1;
	}
	return 0;
}

u32 v2_ndraw, v2_nrect;
int v2_draw_skip(u32 win)
{
	volatile u8 *w = (volatile u8 *)win;
	v2_ndraw++;
	frame_check();
	if (!own_now || !w || u32be(w + 28) != LAYER0 || !ours_w(w))
		return 0;
	v2_skip_draw++;
	return 1;
}

/* the per-frame clear's rect fill: r4 = surface descriptor of the window being cleared */
static int v2_rect_skip_q(u32 desc);
static int desc_ours(u32 desc);
int v2_rect_skip(u32 desc)
{
	v2_nrect++;
	if (!v2_rect_skip_q(desc))
		return 0;
	v2_skip_fill++;
	return 1;
}
static int v2_rect_skip_q(u32 desc)
{
	frame_check();
	return desc_ours(desc);
}
static int desc_ours(u32 desc)
{
	int i;
	if (!own_now)
		return 0;
	for (i = 0; i < 256; i++) {
		volatile u8 *w = WPOOL + 160 * i;
		if (u32be(w + 152) == desc && (u32be(w) & 0x40000000)) {
			if (u32be(w + 28) == LAYER0 && ours_w(w))
				return 1;
			return 0;
		}
	}
	return 0;
}

/* P9: the CPU image blit (r4 = surface descriptor) and the two text renderers (r4 = window): stock
 * blitted list backgrounds / icons and rendered text into surfaces of windows we own every frame --
 * work nobody sees that made a frame miss its vsync */
u32 v2_nblit, v2_skip_blit, v2_ntext, v2_skip_text;
int v2_blit_skip(u32 desc)
{
	v2_nblit++;
	if (!desc_ours(desc))
		return 0;
	v2_skip_blit++;
	return 1;
}
int v2_text_skip(u32 win)
{
	volatile u8 *w = (volatile u8 *)win;
	v2_ntext++;
	if (!own_now || !w || u32be(w + 28) != LAYER0 || !ours_w(w))
		return 0;
	*(volatile u32 *)(w + 116) = 0;
	*(volatile u32 *)(w + 120) = 0;
	v2_skip_text++;
	return 1;
}

/* P9 early present. The stock flip waits for a fresh vsync (sleep(1) polls) and only then writes the
 * frame base, which the VDC5 takes at the vsync AFTER that: every frame drawn into the buffer the panel
 * still shows had to wait (wait_latch) one more field -> two vsyncs per frame (~30 fps) as soon as a
 * frame was a little over one field. On a screen we own, the flip's first sleep(1) of that wait paints
 * our screen into the buffer it is about to show and programs the base right away (the vsync flag is
 * cleared again so the wait ends at the vsync that takes it); the flip's own write after the wait
 * repeats the same base and is skipped (it would only re-arm the latch for another field). */
static u32 early_base;
u32 v2_early, v2_early_skip;
static int paint_frame(u32 base);
u32 v2_fs_calls, v2_fs_ms1, v2_fs_long, v2_fs_lastms;
void v2_flip_sleep(u32 ms, u32 desc)
{
	u32 base;
	v2_fs_calls++;
	v2_fs_lastms = ms;
	if (ms == 1)
		v2_fs_ms1++;
	else
		v2_fs_long += ms;
#ifndef V2_EARLY
	/* P10: off. Under a display that takes the base at once (the Mac emulator) it showed
	 * half-painted frames at track loads; the stock wait + base write is kept as is. */
	return;
#endif
	if (ms != 1 || !desc || !owned() || *(volatile u32 *)0x0E5B6B40)
		return;
	base = *(volatile u32 *)(desc + 12) & 0x1FFFFFFF;
	if (base != 0x1C080000 && base != 0x1C13B800)
		return;
	if (early_base == base)
		return;		/* this flip's base is out already (later polls of the same wait) */
	v2_epoch++;
	if (!paint_frame(base))
		return;
	((void (*)(u32, u32))0x0E526626)(2, base);
	note_write();
	early_base = base;
	*(volatile u32 *)0x0F6A6960 = 0;	/* the wait ends at the vsync that takes this base */
	v2_early++;
}

#ifdef V2_HWS2
#include "hws2.inc"	/* V3rc8v: VDC4 hardware-scroll PROBE 2 (re/VDC4_PROBE2.md) */
#endif
int v2_paint(u32 plane, u32 base)
{
	if (plane != 2)
		return 0;
#ifdef V2_HWBAND
	hb_watch();
#endif
#ifdef V2_GR1METER
	g1_watch();
#endif
#ifdef V2_HWS2
	if (UPD_STATE)
		hws_off(HWS_OFF_UPD);
	hws_watch();
#endif
	if (base && (base & 0x1FFFFFFF) == early_base) {
		early_base = 0;			/* the flip's repeat of the base we wrote early */
		v2_early_skip++;
		return 1;
	}
	early_base = 0;
	v2_epoch++;
	paint_frame(base);
#ifdef V2_AUTO60
	{	/* V3rc8t (user: "stuck at 30 fps" / "the best stable fps, not changing"): FIXED 60 on the playing player --
		 * no 2nd-vsync hold; the deck area redraws on alternate frames, band + meter every frame. A paint over
		 * 15 ms (after the latch wait) misses its vsync: counted (HUD A) to judge whether 60 holds on the deck */
		u32 busy = now_ms() - pf_t0;
		fps60 = base && pace_on;
		if (fps60 && busy > 15)
			v2_a60_over++;
	}
	lk_2vs = base && pace_on && vs_armed && !fps60;	/* LINKLAT: this frame goes out on the 2nd vsync */
	if (base && pace_on && vs_armed && !fps60) {
#else
#ifdef V2_VSPACE
	if (base && pace_on && vs_armed) {
#endif
#endif
#ifdef V2_VSPACE
		/* V3rc8 (audit: a 30 ms busy-pace drifts against the 33.3 ms grid -> a 1-vsync frame every ~5th): hand the
		 * new base out only after ONE vsync has passed since the previous base latched -- it then latches on the
		 * 2nd vsync, always (the CDJ-3000 presents in a fixed vsync phase too). Bounded (a vsync is 16.7 ms). */
		u32 t0 = now_ms();
		while (!VSYNC_FLAG && now_ms() - t0 < 20) {
			((void (*)(u32))0x0E52EA70)(1);
			v2_pace_ms++;
		}
		vs_armed = 0;
	}
	if (0) {
#else
	if (base && pace_on && have_write) {
#endif
		/* V3rc8 (deck HUD: F alternating 30 / 31 = some frames out after 1 vsync, a light judder; the 3000 presents
		 * in a fixed vsync phase): never hand a new base out less than PACE_MS after the last one -- it then
		 * always latches on the 2nd vsync, an even 30 fps, equal scroll steps */
#ifdef V2_SPLIT60
#define PACE_MS 15	/* 1 vsync */
#else
#define PACE_MS 30
#endif
		while (now_ms() - last_write_ms < PACE_MS) {
			((void (*)(u32))0x0E52EA70)(1);
			v2_pace_ms++;
		}
	}
	if (base)
		note_write();		/* the entry writes this base right after we return */
	return 0;
}

static int cache_stale;	/* P10: a frame went out without our paint: stock drew into the buffers */
u32 v2_stale_resets, v2_trans_n, v2_trans_sid;
#ifdef V2_HWPROBE
/* V3rc8 HW PROBE (re/VDC4_SCROLL_LAYER.md §6; user: "la prueba lo mas segura posible" of the hardware-scroll
 * path). TEST builds only. On the PLAYER screen we own, GR2 (0xFFFF7700, unused by stock) scans a test pattern
 * from free SDRAM (0x0CA40000, MEMPROBE Z5 = unused on the deck) in a 256 x 40 window at x 520, y 130 and
 * scrolls it 1 px a frame through its base + STA_POS; GR3 gets chroma key RGB565 0x0001 + blend, and only that
 * window's rectangle is painted 0x0001 (the hole). The key's field order is not known: K1/K2/K3 rotate every
 * 10 s with a label. Off (stock values: GR3 DISP_SEL 2 + CK off, GR2 pass-through + reads off) whenever the
 * screen is not our PLAYER (incl. update mode: never on), after 120 s, and on every not-owned frame. Register
 * pokes only -- a power cycle restores stock. Questions: SDRAM scan? 1-px steps (STA_POS)? key order? */
#define HWR(a) (*(volatile u32 *)(a))
#define HWP_PHYS 0x0CA40000u
#define HWP_CPU ((volatile u16 *)0x2CA40000)
#define HWP_S 3072u		/* bytes a ring row: 1536 px */
#define HWP_X 520
#define HWP_Y 130
#define HWP_W 256
#define HWP_H 40
static int hwp_on, hwp_done, hwp_k;
static u32 hwp_t0, hwp_h;
static void hwp_off(void)
{
	if (!hwp_on)
		return;
	HWR(0xFFFF77B8) &= ~1u;					/* GR3 CK_ON off */
	HWR(0xFFFF77A0) = (HWR(0xFFFF77A0) & ~3u) | 2;		/* GR3 DISP_SEL 2 (stock) */
	HWR(0xFFFF7780) |= 0x10;				/* P_VEN */
	HWR(0xFFFF7720) = (HWR(0xFFFF7720) & ~3u) | 1;		/* GR2 pass-through (stock) */
	HWR(0xFFFF7704) = 0;					/* GR2 reads off */
	HWR(0xFFFF7700) |= 0x11;
	hwp_on = 0;
}
static const u32 HWP_KEY[3] = { 0x00000800u, 0x00000008u, 0x00080000u };
static void hwp_frame(int want)
{
	u32 t = now_ms(), a;
	if (!want) {
		hwp_off();
		hwp_done = 0;	/* re-armed on the next player entry */
		return;
	}
	if (hwp_done)
		return;
	if (!hwp_on) {
		u32 x, y;
		for (y = 0; y < HWP_H; y++)		/* stripes 32 px, white line every 8 px, red tick every 64 */
			for (x = 0; x < 768; x++) {
				u16 c = (x >> 5) & 1 ? 0x001F : 0x07E0;
				if ((x & 7) == 0) c = 0xFFFF;
				if ((x & 63) == 0 && y < 12) c = 0xF800;
				if (y == 0 || y == HWP_H - 1) c = 0xFFE0;
				HWP_CPU[y * (HWP_S / 2) + x] = c;
				HWP_CPU[y * (HWP_S / 2) + x + 768] = c;
			}
		HWR(0xFFFF7708) = 0x00000100;
		HWR(0xFFFF770C) = HWP_PHYS;
		HWR(0xFFFF7710) = HWP_S << 16;
		HWR(0xFFFF7714) = 0;
		HWR(0xFFFF7718) = ((u32)(HWP_H - 1) << 16) | 0x3FF;
		HWR(0xFFFF771C) = (u32)(HWP_W - 1) << 16;
		HWR(0xFFFF7724) = ((10u + HWP_Y) << 16) | HWP_H;
		HWR(0xFFFF7728) = ((143u + HWP_X) << 16) | HWP_W;
		HWR(0xFFFF7738) = 0; HWR(0xFFFF773C) = 0; HWR(0xFFFF7740) = 0;
		HWR(0xFFFF7704) = 1;
		HWR(0xFFFF7720) = (HWR(0xFFFF7720) & ~3u) | 2;
		HWR(0xFFFF7700) |= 0x11;
		hwp_k = -1;
		hwp_t0 = t;
		hwp_h = 0;
		hwp_on = 1;
	}
	if (t - hwp_t0 > 120000) {	/* 2 minutes, then off until the player is entered again */
		hwp_off();
		hwp_done = 1;
		return;
	}
	{
		int k = (int)(udiv(t - hwp_t0, 10000) % 3);
		if (k != hwp_k) {
			hwp_k = k;
			HWR(0xFFFF77BC) = HWP_KEY[k];
			HWR(0xFFFF77C0) = 0;
			HWR(0xFFFF77B8) |= 1;
			HWR(0xFFFF77A0) = (HWR(0xFFFF77A0) & ~3u) | 3;
			HWR(0xFFFF7780) |= 0x10;
		}
	}
	hwp_h = hwp_h + 1 >= 768 ? 0 : hwp_h + 1;	/* 1 px a frame */
	a = HWP_PHYS + 2 * hwp_h;
	HWR(0xFFFF770C) = a & ~7u;
	HWR(0xFFFF771C) = (HWR(0xFFFF771C) & ~0x3Fu) | ((a & 7) >> 1);
	HWR(0xFFFF7700) |= 0x11;	/* as the setup (that one took effect) */
}
static void hwp_paint(void)	/* the hole + its label, into whatever fb is (canvas or GR3 buffer) */
{
	static const char *const KL[3] = { "HW K1", "HW K2", "HW K3" };
	if (!hwp_on)
		return;
	fill(HWP_X, HWP_Y, HWP_W, HWP_H, 0x0001);
	fill(HWP_X, HWP_Y + HWP_H, 60, 14, C_BLACK);
	text(&f_s, HWP_X, HWP_Y + HWP_H, KL[hwp_k < 0 ? 0 : hwp_k], 0xFFE0, C_BLACK);
}
#endif
/* 2.01-a displayer: a stock-drawn pop-up (z 128 O_HIDE, oclass) shown by US, at its place, every frame. Stock's
 * own copy of z 128 onto the frame after our paint is a race with the VDC latch (re/LPT_WHITE_BAR.md): alone it
 * lands on some frames only (emu R21D1: REMOVE ALL TRACKS on every other shot). Copying the window's surface into
 * our canvas makes every frame carry it, and stock's late copy then writes the same pixels. Opaque, as stock's
 * copy. Its coming / going repaints everything once (cache_stale): the rows under it are cached regions. */
static int pst_on;	/* a stock pop-up was shown last frame */
static void pop_stock_blit(void)
{
	int i, y, on = 0;
	for (i = 0; i < 256 && own_now; i++) {
		volatile u8 *w = WPOOL + 160 * i;
		int ww, hh, wx, wy;
		u32 d, base;
		if (!(u32be(w) & 0x40000000) || u32be(w + 28) != LAYER0 || wz(w) != 128 || oclass(w) != O_HIDE)
			continue;
		if (pst_undrawn) {	/* R21D5: never stock's surface before stock drew it -- our finished frame goes
					 * into it instead (stock's late copy then shows our screen), also on screens
					 * where popup() does not run (MY SETTINGS: MENU on the browse root, sid 0x00) */
			popup_sync();
			continue;
		}
		ww = (int)u16be(w + 8); hh = (int)u16be(w + 10);
		wx = (int)u32be(w + 84); wy = (int)u32be(w + 88);
		d = u32be(w + 152);
		if (ww <= 0 || hh <= 0 || wx < 0 || wy < 0 || wx + ww > W || wy + hh > 480 || (d & 0xFF000000) != 0x0F000000)
			continue;
		base = u32be((const volatile u8 *)((d & 0x1FFFFFFF) | 0x20000000) + 12);
		if ((base >> 24) != 0x0C)
			continue;
		dmark(wy, hh);
		for (y = 0; y < hh; y++)	/* uncached: stock's latest pixels (as ovl_blit) */
			cp16(fb + (wy + y) * W + wx, (const u16 *)((base & 0x1FFFFFFF) | 0x20000000) + y * ww, ww);
		on = 1;
#ifdef V2_KITLOG
		kit_zgeo = (u32)ww | (u32)hh << 10 | ((u32)wx & 0x3FF) << 20;
		if (kit_inkreq) {	/* once a second: dark / light pixel counts of what we copied (text readable?) */
			u32 dk = 0, lt = 0, n;
			const u16 *p = fb + wy * W + wx;
			for (y = 0; y < hh; y++, p += W)
				for (n = 0; n < (u32)ww; n++) {
					u32 c = p[n], l = ((c >> 11) & 31) * 2 + ((c >> 5) & 63) + (c & 31) * 2;
					if (l < 40) dk++;
					else if (l > 150) lt++;
				}
			kit_ink = (dk > 0x7FFF ? 0x7FFF : dk) | (lt > 0x7FFF ? 0x7FFF : lt) << 15;
			kit_inkreq = 0;
		}
#endif
	}
	KIT(if (on) kit_pblit++;)
	if (on != pst_on) {
		pst_on = on;
		cache_stale = 1;
	}
}

#ifdef V2_KITLOG
/* R21 deck kit (work/r21/deckkit, DEV only): the 'KIT1' record, half a second after each HUD record -- what the deck
 * kit's parser checks without a camera: pop-up class / title / stock ink, browse cursor + LOAD tap, green KEY cells,
 * strip cue marks, w8 (master waveform), deck key. Every word < 0x80000000 (usblog_push masks bit 31). */
static void kit_push(u32 t)
{
	u32 k[26], i;
	const volatile u8 *tt = SLOT(1, 0);
	int n = u16len(tt), nh = 0, nm = 0;
	for (i = 0; i < 26; i++)
		k[i] = 0;
	k[0] = 0x4B495431u;	/* 'KIT1' */
	k[1] = (u32)MODEL[7] | (u32)(screen_mode() & 0xFF) << 8 | (u32)pop_on() << 16 | (u32)pop_ours() << 17 |
	       (u32)pst_on << 18 | 0u << 19 /* pop_nosync: the variable went with R21D5 (the bit stays 0) */ | (MODEL[0x0F] ? 1u : 0u) << 20 | (ga_tch ? 1u : 0u) << 21 |
	       (own_now ? 1u : 0u) << 22 | (V3E_PROW >= 0 ? 1u : 0u) << 23;
	for (i = 0; i < 16; i++) {	/* side-1 slot 0 = the pop-up's title (ASCII, 16 chars) */
		u32 c = (int)i < n ? u16be(tt + 0x2A + 2 * i) : 0;
		if (c > 0x7E) c = '?';
		k[2 + (i >> 2)] |= c << (24 - 8 * (i & 3));
	}
	k[6] = kit_ink; kit_ink = 0; kit_inkreq = 1;
	k[7] = kit_zgeo; kit_zgeo = 0;
	k[8] = ((kit_cursor + 1) & 15) | ((u32)(lb_tap_k + 1) & 15) << 4 | ((u32)(V3E_PROW + 1) & 15) << 8;
	{	/* the first list row's text (16-bit hash): a list scroll changes it */
		const volatile u8 *f1 = SLOT(0, 1);
		u32 h = 0, m = (u32)u16len(f1);
		for (i = 0; i < m && i < 24; i++)
			h = h * 31 + u16be(f1 + 0x2A + 2 * i);
		k[8] |= (h & 0xFFFF) << 12;
	}
	k[9] = (kit_gr > 0xFFFF ? 0xFFFF : kit_gr) | (kit_gcur & 3) << 16 | ((u32)ref_key() & 0x3F) << 20;
	kit_gr = 0; kit_gcur = 0;
	for (i = 0; i < N_MARKS; i++) {
		const u8 *r = smk + 16 * i;
		u32 st = (u32)r[8] << 24 | (u32)r[9] << 16 | (u32)r[10] << 8 | r[11];
		if (st == 0xFFFFFFFF || i == 0)
			continue;
		if (i <= N_HOT) {
			if (nh < 3)
				k[11 + nh] = st & 0x7FFFFFFF;
			nh++;
		} else
			nm++;
	}
	k[10] = (u32)nh | (u32)nm << 8 | (smk_tid & 0x7FFF) << 16;
	k[14] = (kit_zhide > 0x7FFF ? 0x7FFF : kit_zhide) | (kit_zown > 0x7FFF ? 0x7FFF : kit_zown) << 15;
	kit_zhide = kit_zown = 0;
	k[15] = v2_frames;
	k[16] = u32be(DECK + 0x70);
	k[17] = u32be(DECK + 0x60);
	k[18] = (u32be(W8BUF) == 0x57384D31 ? 1u : 0u) | (u32be(W8BUF + 4) & 1) << 1;
	k[19] = u32be(W8BUF + 8);
	k[20] = u32be(W8BUF + 0x0C);
	k[21] = (u32)deck_key_green() | ((u32)own_key() & 0x3F) << 1 | (u32)is_master() << 8 |
		(u32be(DECK + 0x28) == 1 ? 1u : 0u) << 9 | (pno56(u32be(DECK + 0xA4)) & 15) << 10 |
		((u32)player_num() & 15) << 14 | (u32)(KS_ON ? 1 : 0) << 18 | (u32)(KS_KSYNC ? 1 : 0) << 19;
	k[22] = smk_ck;
	k[23] = kit_sdraw; kit_sdraw = 0;
	k[24] = kit_pblit; kit_pblit = 0;
	/* KIT record version (bits 0..7); R22F1: a list of ours standing empty -- bits 8..19 the longest since boot
	 * (16 ms units, 65 s cap), bits 20..30 now (64 ms units, 131 s cap) */
	k[25] = 1 | ((v2_trans_maxms >> 4) > 0xFFF ? 0xFFF : (v2_trans_maxms >> 4)) << 8 |
	        ((v2_trans_curms >> 6) > 0x7FF ? 0x7FF : (v2_trans_curms >> 6)) << 20;
	usblog_push(k, t);
}
#endif

static int paint_frame(u32 base)
{
	if (!base || !owned()) {
#ifdef V2_HWBAND
		if (!owned())
			hb_off(HB_OFF_NOTOWNED);	/* never on base == 0 (no flip: nothing to commit with) */
#endif
#ifdef V2_GR1METER
		if (!owned())
			g1_off(G1_OFF_NOTOWNED);
#endif
#ifdef V2_HWS2
		if (!owned())
			hws_off(HWS_OFF_NOTOWNED);	/* never on base == 0 (probe-1 bug) */
#endif
#ifdef V2_HWPROBE
		if (!owned())	/* deck HW probe 1: base 0 frames (no flip) re-armed it every frame -- only a screen we
				 * do not own turns it off */
			hwp_frame(0);
#endif
		if (base && !cache_stale) {
			v2_trans_n++;
			v2_trans_sid = MODEL[7] | (u32)u16be(SLOT(0, 0) + 0x14) << 8 | (u32)UPD_STATE << 24;
		}
		cache_stale = 1;
		trans_from = M_NONE;
		return 0;
	}
#ifdef V2_DBG_NOPAINT
	v2_frames++;
	return 1;
#endif
	u16 *phys = (u16 *)((base & 0x1FFFFFFF) | 0x20000000);	/* the GR3 buffer about to latch (uncached: the VDC reads RAM) */
	int smooth = 0;			/* V3rc4: compose off-screen and copy the whole frame into phys */
	static u32 sm_pend[2];		/* V3rc5: canvas bands each GR3 buffer has not received yet */
	static int sr_x0[2], sr_y0[2], sr_x1[2], sr_y1[2];	/* D1: a canvas rectangle each GR3 buffer has not received */
	static int last_smooth;
	int tb = (base & 0x1FFFFFFF) >= 0x1C13B800;	/* which GR3 buffer phys is */
	fb = phys;
	v2_chg = pend = 0;
	dmask = 0;
	wait_latch();	/* phys may still be scanned (the last base not taken yet); also guards the whole-copy below */
#ifdef V2_G3PURGE
	g3_purge();	/* CACHECOH: no stock dirty line of the GR3 buffers may land after our writes */
#endif
	u32 ld_t0 = now_ms();
	pf_t0 = ld_t0;
#ifdef V2_HWS2
	hws_frame(screen_mode() == M_PLAYER);
#endif
#ifdef V2_HUD
	u32 hud_t0 = ld_t0;
#endif
	read_flags();
	det_track();
	pl_track();	/* "played" is registered while the deck plays, whatever screen is up (was: when a row was drawn) */
	lg_poll();		/* V4n30a: the load gate */
	{	/* LOADFIX (deck V4n44: TRACK SEARCH on a paused deck -- no band / overview / time until PLAY): the
		 * gate opens on TIMED conditions (art "none" 250 ms after the title, no cue block 400 ms after the
		 * detail, LG_NAMED) but frames only flip on input changes; on a paused deck the last piece of the
		 * load could arrive before those timers ran out and nothing painted again until the heartbeat moved
		 * (PLAY). Keep painting while the gate is closed and 1.5 s after any change of the track identity
		 * (number, length, detail length, MAIN's rbid), every load path: browse, TRACK SEARCH, LINK, LOAD
		 * PREVIOUS, auto-load */
		static u32 ld_id;
		u32 id = hmix(hmix(u32be(DECK + 0x60), u32be(DECK + 0x7C)), hmix(DET_LEN != 0, cue_rbid())), t = now_ms();
		if (id != ld_id) {
			ld_id = id;
			ld_t0 = t | 1;
		}
		if (lg_on || (ld_t0 && t - ld_t0 < 1500))
			pend = 1;
	}
	{	/* NSFIX: around a needle search / CUE on a paused deck stock writes into the GR3 buffers and no frame
		 * painted again (frames flip on changes only), so its pixels stayed. For 2 s after any change of the
		 * needle state (+0xDF), the finger (+0x70) or the position (+0x78) on a paused player: keep painting
		 * and send the bottom rows to both buffers every frame; while +0xDF stays 3 (needle, paused) keep
		 * painting so the self-heal catches a later write. The green marker only while playing or within
		 * 2 s of a finger move (+0xDF stays 3 after a release / CUE: the marker stuck) */
		static u32 ns_k, ns_t, ns_f, ns_ft;
		u32 t = now_ms(), k = hmix(hmix(DECK[0xDF], u32be(DECK + 0x70)), u32be(DECK + 0x78));
		int play = deck_playing();
		ns_force = 0;
		if (k != ns_k) {
			ns_k = k;
			ns_t = t | 1;
		}
		if (u32be(DECK + 0x70) != ns_f) {
			ns_f = u32be(DECK + 0x70);
			ns_ft = t | 1;
		}
		ns_live = play || (ns_ft && t - ns_ft < 2000);
		if (ns_ft && t - ns_ft >= 2000)
			ns_ft = 0;
		if (screen_mode() == M_PLAYER && !play) {
			if (ns_t && t - ns_t < 2000)
				pend = ns_force = 1;
			else if (DECK[0xDF] == 3 || ns_live)
				pend = 1;
		}
		if (ns_t && t - ns_t >= 2000)
			ns_t = 0;
	}
	{
		static int last_mode = -1, last_day = -1, last_pm = -1;
		int m = screen_mode();
		{	/* P10: count the frames held over a list being built (screen_mode) */
			int sid = MODEL[7];
			int building = m == M_BROWSE && sid != 0x02 && sid != 0x1E && sid != 0x08 && sid != 0x04 &&
				!u16be(SLOT(0, 0) + 0x14) && !u16be(SLOT(0, 0) + 0x28) && !u16be(SLOT(0, 1) + 0x28);
			if (building) {
				if (!trans_frames++)
					trans_t0 = now_ms();
				else {	/* R22F1: how long a list of ours has stood empty (the kit's report reads the max) */
					v2_trans_curms = now_ms() - trans_t0;
					if (v2_trans_curms > v2_trans_maxms)
						v2_trans_maxms = v2_trans_curms;
				}
				v2_trans_held++;
				pend = 1;
			} else {
				trans_frames = 0;
				v2_trans_curms = 0;
				trans_from = m;
			}
		}
		/* V3rc4: SMOOTH composes the frame off-screen (canvas) then copies it whole into the buffer about
		 * to latch, so the panel never scans a partial draw. Only for the modes we own completely: on
		 * SHORT CUT / player INFO stock also composes its own panel into the shown buffer, which the canvas
		 * cannot capture, so those keep the direct per-region paint (FAST). */
		smooth = (present_mode == PM_SMOOTH || present_mode == PM_PLUS) && (m == M_PLAYER || m == M_BROWSE ||
									    m == M_SHORTCUT || m == M_PINFO);	/* D1: + SHORTCUT, INFO */
		pace_on = present_mode == PM_PLUS && m == M_PLAYER;	/* V3rc8: the even cadence on the player */
		if (smooth) {
			fb = (u16 *)CANVAS;	/* one key set (rb 0) tracks the single canvas */
			rb = 0;
		} else {
			fb = phys;
			rb = (base & 0x1FFFFFFF) >= 0x1C13B800;
		}
		if (m != last_mode || (day | day_full << 1) != last_day || cache_stale || present_mode != last_pm) {
			int i;
			/* P10: also after any frame we did not paint (UTILITY, a screen we don't own, the
			 * frames of a screen change): stock composed its own deck area etc. into both buffers,
			 * and a returning screen of the same mode kept the region keys -- one buffer stayed
			 * stock's and the panel alternated between the two (Mac: ~2 s of flashing stock
			 * deck area after closing UTILITY). V3rc4: also on a SCREEN MODE switch (the canvas / the
			 * physical buffers must be redrawn in full for the new target). */
			v2_stale_resets += cache_stale;
			cache_stale = 0;
			if (present_mode != last_pm)
				pend = 1;
			for (i = 0; i < NREG; i++)
				rk[0][i] = rk[1][i] = 0;
			last_mode = m;
			last_day = day | day_full << 1;
			last_pm = present_mode;
			/* V3rc4: on a full reset in SMOOTH, black the canvas once so any pixel no region owns is black
			 * rather than stale SDRAM (the region draws tile the screen -- FAST proves this across mode
			 * changes -- this is insurance for the default mode on the real panel). The zeroed keys above
			 * then redraw every region into the cleared canvas this frame. */
			if (smooth) {
				fill16((u16 *)CANVAS, W * 480, C_BLACK);
				sm_pend[0] = sm_pend[1] = SM_ALL;
			}
		}
		/* V3rc5: entering SMOOTH, the GR3 buffers hold whatever FAST / stock put there: send them all */
		if (smooth && !last_smooth)
			sm_pend[0] = sm_pend[1] = SM_ALL;
		last_smooth = smooth;
		/* V3f safety net: one region of this buffer redrawn a frame, round robin, against a stale buffer.
		 * STEADY turns it off -- it is the prime suspect for the PERIODIC HW blip (a region's fill+content
		 * redraw caught mid-scan, marching through the regions ~1 s a cycle). SMOOTH keeps it (the redraw
		 * lands in the canvas, never on the panel). */
		rforce = 0;
		/* V3rc8 (deck 240 fps video: a 2-frame hitch every 2.19 s = 64 frames at 30 fps = one spread cycle, when the
		 * round robin reaches an expensive region): with the canvas (SMOOTH / SMOOTH+) nothing goes stale -- stock
		 * cannot draw into it and the self-heal re-sends anything written into a GR3 buffer -- so the safety net is
		 * FAST-only */
		spread_id = smooth ? -1 : (int)(v2_frames >> 1) % NREG;
		{	/* boot: the boot animation (spinner, "Ver" / "Cueline") keeps drawing into
			 * the frame buffers until MAIN is up -- repaint everything every frame until then */
			static u32 ok_frames;
			if (!hb_valid)
				ok_frames = 0;
			else if (ok_frames < 16)
				ok_frames++;
			if (ok_frames < 16)
				rforce = pend = 1;
		}
		/* V3f: the header and the phase meter (regions 0 / 1) are keyed like every other region: z 133 is
		 * ours on the player since P8 (an overlay over them resets them, ovl_blit) */
		own_mode = m;
		/* (D1: no more pend every frame on SHORTCUT / player INFO -- their pages are keyed, stock's windows ours) */
		int ovh;
		{ PF0(1); ovh = ovl_scan(); PF1(1); }
		if (ovl_lband) {	/* V4k: only the status line's rows (FAST draws into the buffers: all, as before) */
			if (smooth) {
				sm_pend[0] |= ovl_lband;
				sm_pend[1] |= ovl_lband;
			} else
				ovh = 1;
		}
		if (ovh && smooth && lr_ok && lr_x1 > lr_x0 && lr_y1 > lr_y0) {
			/* D1: the canvas is intact -- only the late windows' rectangle goes to the GR3 buffers again */
			int q;
			for (q = 0; q < 2; q++) {
				if (sr_x1[q] <= sr_x0[q]) {
					sr_x0[q] = lr_x0; sr_y0[q] = lr_y0; sr_x1[q] = lr_x1; sr_y1[q] = lr_y1;
				} else {
					if (lr_x0 < sr_x0[q]) sr_x0[q] = lr_x0;
					if (lr_y0 < sr_y0[q]) sr_y0[q] = lr_y0;
					if (lr_x1 > sr_x1[q]) sr_x1[q] = lr_x1;
					if (lr_y1 > sr_y1[q]) sr_y1[q] = lr_y1;
				}
			}
			v2_ovl_rect++;
#ifdef V2_HWBAND
			hb_gk[0] = hb_gk[1] = 0;	/* ... maybe over the band area too */
#endif
		} else if (ovh) {	/* something got composed into this buffer: repaint it all */
			int i;
			for (i = 0; i < NREG; i++)
				rk[rb][i] = 0;
			sm_pend[0] = sm_pend[1] = SM_ALL;	/* V3rc5: stock composed into a GR3 buffer */
#ifdef V2_HWBAND
			hb_gk[0] = hb_gk[1] = 0;	/* ... maybe over the band area too */
#endif
		}
	}
	wave_pal();
#ifdef V2_KEYSHIFT
	ks_publish();	/* V4n: KEY SYNC's shift for MAIN (every owned frame) */
#endif
#ifdef V2_BDIRECT
	bd_ok = smooth && screen_mode() == M_PLAYER && !pop_on() && !pst_on && !n_ovl;	/* 2.01-a: + pst_on */
	bd_phys = phys;
	if (screen_mode() != M_PLAYER)
		bd_on = md_on = 0;
#endif
	if (ns_force && !smooth) {	/* NSFIX: FAST draws into the buffers -- the bottom regions again */
		static const u8 NSR[] = { 3, 4, 5, 6, 9, 10, 28, 29 };
		int i;
		for (i = 0; i < (int)sizeof(NSR); i++)
			rk[0][NSR[i]] = rk[1][NSR[i]] = 0;
	}
	pst_check();	/* R21D5: did stock draw its pop-up this frame? (before popup_sync overwrites it) */
	switch (screen_mode()) {
	case M_PLAYER: player(); break;
	case M_SHORTCUT: shortcut(); break;
	case M_PINFO: player_info(); break;
	default: browse(); break;
	}
	pop_stock_blit();	/* 2.01-a: over our screen, under the overlays (as stock: z 128 under z 7) */
	{
		int i;
		ovl_sig = ovl_gsig = ovl_rmask = 0;
		for (i = 0; i < n_ovl; i++)
			ovl_blit(ovl[i]);
		if (ovl_rmask)
			ovl_lmask = ovl_rmask;
		if (ovl_sig != ovl_lsig) {	/* V4f: an overlay changed / came / went: everything again */
			ovl_lsig = ovl_sig;
			v2_ovl_chg++;
			if (ovl_gsig == ovl_lgsig && n_ovl && ovl_lmask) {	/* V4k: same place, new pixels */
				u32 m = ovl_rmask | ovl_lmask;
				for (i = 0; i < 27; i++)
					if (m >> i & 1)
						rk[0][i] = rk[1][i] = 0;
#ifdef V2_HWBAND
				if (m >> R_BAND & 1)
					hb_gk[0] = hb_gk[1] = 0;
#endif
				v2_ovl_part++;
			} else
				cache_stale = 1;
			ovl_lgsig = ovl_gsig;
		}
	}
	/* V3rc4 SMOOTH: the canvas now holds the complete frame; copy it whole into the buffer the VDC is about
	 * to latch (wait_latch above ensured the panel is not scanning it). One contiguous blit, so no partial /
	 * mid-draw frame is ever shown; the alternate buffer gets the same finished frame on its next present. */
	/* V3rc5: only the bands that changed since this buffer last got the canvas (dmask = this frame's
	 * writes, accumulated per buffer), as contiguous runs; an overlay / forced frame sends it whole. The
	 * copy still lands only in the buffer about to latch, after wait_latch, so it stays tear-free. */
#ifdef V2_HUD
	{	/* TEST-only HUD (V3rc6 deck timing): per second -- painted frames, worst gap between paints, heartbeat
		 * position updates, average draw ms, latch-wait ms, copied rows a frame; drawn last, top right */
		static u32 w0, nf, gmax, lastp, hbn, lastpos, drw, lat0, rows0, cp0, pf0[4], heal0, stk0, txt[31];
#ifdef V2_KITLOG
		static int kit_due;
#endif
		u32 t = now_ms(), pos = u32be(DECK + 0x70);
#ifdef V2_HWBAND
		char b[100];
		int row2 = 0;
#else
		char b[72];
#endif
		int i;
		if (lastp && t - lastp > gmax) gmax = t - lastp;
		lastp = t;
		nf++;
		drw += t - hud_t0;
		if (pos != lastpos) { hbn++; lastpos = pos; }
#ifdef V2_KITLOG
		if (kit_due && t - w0 >= 500) {
			kit_due = 0;
			kit_push(t);
		}
#endif
		if (t - w0 >= 1000) {
			txt[0] = nf; txt[1] = gmax; txt[2] = hbn; txt[3] = nf ? udiv(drw, nf) : 0;
			txt[4] = v2_latch_ms - lat0; txt[5] = nf ? udiv(v2_sm_rows - rows0, nf) : 0;
			{	/* LINKLAT (replaces LAT, the latch-wait ms): the LINK meter's prediction this second --
				 * bits 0-6 LINK OFFSET + 16 (0 = OFF), 7-14 mean age of the drawn +0xB8 sample at the paint
				 * (ms, MAIN-stamped), 15-22 mean lead (paint -> seen, ms) + 64, 23-29 max stamp age (ms),
				 * bit 30 MAIN stamps seen. All 0 without a LINK master. */
				static u32 lk_ns;
				u32 n = lk_n ? lk_n : 1, sa = udiv(lk_sa, n), sl = udiv(lk_sl, n);
				txt[4] = lk_n ? ((v2_lk_on ? ((u32)((s32)v2_lk_off + 16) & 127) : 0u) |
						 (sa > 255 ? 255 : sa) << 7 | (sl > 255 ? 255 : sl) << 15 |
						 (lk_amax > 127 ? 127 : lk_amax) << 23 | (lk_ns != v2_lk_stamp ? 1u : 0u) << 30) : 0;
				lk_ns = v2_lk_stamp;
				lk_sa = lk_sl = lk_n = lk_amax = 0;
			}
			txt[6] = nf ? udiv((v2_cp_ms - cp0) * 10, nf) : 0;	/* copy ms x10 a frame */
			for (i = 0; i < 4; i++) {	/* section ms x10 a frame: band, overlays, deck, meter */
				txt[7 + i] = nf ? udiv((v2_pf[i] - pf0[i]) * 10, nf) : 0;
				pf0[i] = v2_pf[i];
			}
			txt[8] = v2_heal;		/* X: heals since boot (replaces O) */
			txt[11] = v2_heal_y;		/* Y: the last healed row */
			txt[12] = v2_latch_stuck;	/* S: latch waits that timed out, since boot */
			txt[13] = v2_pstall; v2_pstall = 0;	/* P: the longest position stall this second (ms) */
			txt[14] = v2_qmax; v2_qmax = 0;		/* Q: the longest frame this second (ms) */
			txt[15] = v2_pfx[0]; txt[16] = v2_pfx[2]; txt[17] = v2_pfx[3];	/* WX KX MX: section maxima (ms) */
			v2_pfx[0] = v2_pfx[1] = v2_pfx[2] = v2_pfx[3] = 0;
#ifndef V2_HWBAND
			txt[18] = v2_wave_full;	/* B: full band rebuilds since boot */
			txt[19] = v2_wave_rf;	/* V: progressive refreshes (data changes) since boot */
			txt[20] = v2_wf_hist[2]; txt[21] = v2_wf_hist[3]; txt[22] = v2_wf_hist[7];	/* rebuilds: pointer / length / jump */
			txt[23] = v2_wf_hist[1]; txt[24] = v2_det_hold;	/* RO not-ok rebuilds / RZ -> frames bridged (detail drops) */
#endif
#ifdef V2_MEMPROBE
			{	/* V3rc8 TEST: READ-ONLY probe of candidate free SDRAM (no writes: a region stock uses would
				 * break if we wrote it). One word every 1 KB, compared each second with its previous value;
				 * Z1..Z6 = words that changed since boot (0 = nobody writes there) */
				static const u32 RG[6][2] = {
					{ 0x0CB18000, 0x0CC00000 },	/* Z1 the V3rc8j phase rings (deck: garbage) */
					{ 0x0CCBB800, 0x0CD00000 },	/* Z2 after the canvas */
					{ 0x0C930000, 0x0C9BB800 },	/* Z3 phase scratch below the meter rows */
					{ 0x0C9C0000, 0x0CA00000 },	/* Z4 before w8fetch */
					{ 0x0CA40000, 0x0CB00000 },	/* Z5 after w8fetch (if it is small) */
					{ 0x0CD00000, 0x0CE00000 },	/* Z6 above the "free" window */
				};
				static u32 prev[6], chg[6], init;	/* a hash per region: Zn = seconds in which it changed */
				int r;
				for (r = 0; r < 6; r++) {
					u32 a, h = 0;
					for (a = RG[r][0]; a < RG[r][1]; a += 1024)
						h = h * 31 + *(volatile u32 *)((a & 0x1FFFFFFF) | 0x20000000);
					if (init && h != prev[r])
						chg[r]++;
					prev[r] = h;
				}
				init = 1;
				for (r = 0; r < 6; r++)
					txt[25 + r] = chg[r];
			}
#endif
#ifndef V2_MEMPROBE
			txt[25] = v2_a60_over;
#endif
#ifdef V2_HWBAND
			{
				static u32 c0;
				txt[18] = (u32)hb_on; txt[19] = (u32)(hb_cur + 1); txt[20] = v2_hb_setups; txt[21] = v2_hb_offs;
				txt[22] = v2_hb_why; txt[23] = v2_hb_swaps; txt[24] = v2_hb_wait;
#ifdef V2_USBLOG	/* V4f: the log keeps txt[0..25] only -- columns/s replace S, Y = the overlay (z * 10000 + changes) */
				txt[12] = v2_hb_cols - c0 > 9999 ? 9999 : v2_hb_cols - c0;
				txt[11] = (n_ovl ? (u32)wz(ovl[0]) * 10000 : 0) + (v2_ovl_chg > 9999 ? 9999 : v2_ovl_chg);
#else
				txt[26] = v2_hb_cols - c0 > 9999 ? 9999 : v2_hb_cols - c0;	/* ring columns rendered this second */
#endif
				c0 = v2_hb_cols;
				txt[27] = v2_hb_stuck; txt[28] = v2_hb_gr3re; txt[29] = v2_hb_gr3d; txt[30] = v2_hb_vbuf;
			}
#endif
#ifdef V2_GR1METER
			{	/* GR1METER log words (replace heartbeat updates / rows copied / band waits):
				 * txt[2] = on | setups (7 b) << 1 | offs (7 b) << 8 | why (3 b) << 15 | rebuilds (6 b) << 18 | waits (7 b) << 24
				 * txt[5] = keyed frames this second (10 b) | GR1 frames this second (10 b) << 10 | ring columns this
				 *          second (11 b) << 20
				 * txt[24] = VBUFERR (GR1 | GR2) | DISP_SEL read-back GR2 << 16, GR1 << 18, GR3 << 20 | GR2 blend switches << 22 */
				static u32 f0, k0, c0g;
				u32 fr = v2_g1_frames - f0, kf = v2_g1_keyed - k0, cc = v2_g1_cols - c0g;
				f0 = v2_g1_frames; k0 = v2_g1_keyed; c0g = v2_g1_cols;
				txt[2] = (u32)g1_on | (v2_g1_setups > 127 ? 127 : v2_g1_setups) << 1 |
					 (v2_g1_offs > 127 ? 127 : v2_g1_offs) << 8 | (v2_g1_why & 7) << 15 |
					 (v2_g1_rebuilds > 63 ? 63 : v2_g1_rebuilds) << 18 | (v2_g1_waits > 127 ? 127 : v2_g1_waits) << 24;
				txt[5] = (kf > 1023 ? 1023 : kf) | (fr > 1023 ? 1023 : fr) << 10 | (cc > 2047 ? 2047 : cc) << 20;
				/* m3 read-backs (replace P / Q / WX / KX / MX): txt[13] = foreign-change mask (bit = GR1 offset / 4)
				 * | changes (10 b) << 21; txt[14] = the last foreign value; txt[15] = its offset | GR1 AB1 << 8;
				 * txt[16] = GR1 FLM6; txt[17] = non-zero mask of GR1 + 0x54..0xBC (bit = (off - 0x54) / 4) */
				{
					u32 nz = 0, o;
					for (o = 0x54; o <= 0xBC; o += 4)
						if (HWR(GR1 + o))
							nz |= 1u << ((o - 0x54) >> 2);
					/* V4n59s: txt[13] = scaler-0 US1 (8 b) | US8 (8 b) << 8 | SCL0_UPDATE (16 b) << 16 */
					txt[13] = (HWR(0xFFFF7548) & 0xFF) | (HWR(0xFFFF7564) & 0xFF) << 8 | (HWR(0xFFFF7500) & 0xFFFF) << 16;
					/* txt[14]: see below (m4) */
					/* V4n49q: the written registers read back each second: txt[15] = US1 (8 b) | SCL0_UPDATE (16 b) << 8 */
					txt[15] = (HWR(G1_US1) & 0xFF) | (HWR(G1_SC0) & 0xFFFF) << 8;
					/* txt[17] (below) = BK colour 0x756C & 0xFFFF | MTX_MODE << 16 | ADJ re-asserts << 27 */
					/* m4: a rotating dump of the ADJ block's STOCK values (boot snapshot, +0x80..+0xCC, 20 s a
					 * round): txt[14] = value, txt[16] = its offset | ADJ re-asserts << 8; txt[17] = nz | re-asserts << 27 */
					/* V4n49 DEV: a rotating LIVE dump of the whole VDC4 block 0xFFFF7400..0xFFFF76FC (input / scaler 0 /
					 * GR1 / ADJ; 192 regs, one a second): txt[14] = value bits 0..30, txt[16] = offset from 0xFFFF7400
					 * (10 b) | value bit 31 << 10 | GR1 live << 11 | ADJ re-asserts (16 b) << 12 */
					static u32 ri;
					u32 rv;
					ri = ri + 1 >= 192 ? 0 : ri + 1;
					rv = HWR(0xFFFF7400u + 4 * ri);
					txt[14] = rv & 0x7FFFFFFF;
					txt[16] = 4 * ri | (rv >> 31) << 10 | (u32)g1_on << 11 |
						  (v2_g1_adjfix > 0xFFFF ? 0xFFFF : v2_g1_adjfix) << 12;
					/* V4n59s: txt[17] = scaler-0 US3 width (11 b) | US3 H start (8 b) << 11 | US2 V start (6 b) << 20 | FRC3 b0 << 31 */
					txt[17] = (HWR(0xFFFF7550) & 0x7FF) | ((HWR(0xFFFF7550) >> 16) & 0xFF) << 11 | ((HWR(0xFFFF754C) >> 16) & 0x3F) << 20 | (HWR(0xFFFF750C) & 1) << 30;	/* V4n59h: bit 31 broke every USB-log record */
				}
				txt[24] = ((v2_g1_vbuf | v2_hb_vbuf) & 0xFFFF) | (HWR(GR2 + 0x20) & 3) << 16 |
					  (HWR(GR1 + 0x20) & 3) << 18 | (HWR(GR3 + 0x20) & 3) << 20 |
					  (v2_g1_g2sel > 127 ? 127 : v2_g1_g2sel) << 22;
			}
#endif
#if defined(V2_G3PURGE) && defined(V2_USBLOG)
			{	/* G3BADGE (#110): txt[12] (S / HB cols/s, <= 9999) keeps bits 0..13; bits 14..30 = GR3 cache
				 * lines purged this second (v2_g3p_lines delta, capped; > 0 = the stock dirty-line hazard is live) */
				static u32 g3l0;
				u32 dl = v2_g3p_lines - g3l0;
				g3l0 = v2_g3p_lines;
				txt[12] = (txt[12] > 0x3FFF ? 0x3FFF : txt[12]) | (dl > 0x1FFFF ? 0x1FFFF : dl) << 14;
			}
#endif
#ifdef V2_USBLOG
			ul_x = (u32)wave_type | (u32)det_blue << 2 | (u32)wblue << 3 | (v2_det_flips & 127) << 8;
#ifdef V2_HWBAND
			if (hb_on && hb_cur >= 0)
				ul_x |= (hbr[hb_cur].look & 15) << 4;
#endif
			usblog_push(txt, t);
#endif
#ifdef V2_KITLOG
			kit_due = 1;
#endif
			(void)heal0; (void)stk0;
			w0 = t; nf = gmax = hbn = drw = 0; lat0 = v2_latch_ms; rows0 = v2_sm_rows; cp0 = v2_cp_ms;
		}
#ifndef V2_USBLOG	/* V4: with the USB log the HUD goes to the stick, not the screen (GUI section room) */
		{
			static const char *const L[31] = { "F", " G", "", " D", "", "", " C", " W", "", "", "", "", " S", "",
							   " Q", " WX", "", "",
#ifdef V2_HWBAND	/* V4 second row: HB live, ring, setups, offs, why, swaps, waits, A, cols/s, stuck, re-asserts, GR3 draws, VBUFERR */
							   "H", " R", " S", " O", " Y", " X", " M", " A", " C", " U", " E", " G", " V" };
#else
							   "", "", "", "", "", "", "",
#ifdef V2_MEMPROBE
							   " Z1", " Z2", " Z3", " Z4", " Z5", " Z6" };
#else
							   " A", "", "", "", "", "" };	/* A: 60-fps frames over budget (V3rc8t) */
#endif
#endif
			int j = 0;
			for (i = 0; i < 31; i++) {
#ifdef V2_HWBAND
				if (i == 18) {
					b[j++] = 0;
					row2 = j;
				}
#endif
				if (!L[i][0])
					continue;	/* L, R, Y dropped (room) */
				const char *q = L[i];
				u32 v = txt[i], d = 1000;
				while (*q) b[j++] = *q++;
				while (d > 1 && v < d) d = udiv(d, 10);
				for (; d; d = udiv(d, 10)) { b[j++] = (char)('0' + udiv(v, d) % 10); }
			}
			b[j] = 0;
		}
		fill(400, 61, 400, 14, C_BLACK);
		text(&f_t, 404, 61, b, 0xFFE0, C_BLACK);
#ifdef V2_HWBAND
		fill(400, 75, 400, 14, C_BLACK);
		text(&f_t, 404, 75, b + row2, 0x07FF, C_BLACK);
#endif
#else
		(void)b;
#ifdef V2_HWBAND
		(void)row2;
#endif
#endif
	}
#endif
	if (smooth) {
		u32 m = dmask, pm;
		int b = 0;
		if (rforce || cache_stale)	/* V4f: an overlay alone no longer sends the whole frame */
			m = SM_ALL;
		{	/* V3rc8q (deck stream: MENU then INFO showed 3 frames of a half-drawn SHORT CUT with a white box and
			 * then a stray SHORT CUT icon on INFO for ~1 s): during a screen / pop-up change stock still composes
			 * its own windows straight into the GR3 buffers for a few frames, after our copy; the self-heal found
			 * them only row by row. For 1 s after any change both buffers get the whole canvas every frame
			 * (the CDJ-3000 repaints its whole display on a component change, display update timer). */
			static u32 tr_key, tr_left;
			u32 k = (u32)screen_mode() | (u32)pop_on() << 8 | (u32)MODEL[7] << 16 | (u32)MODEL[0x0F] << 24;
			if (k != tr_key) {
				tr_key = k;
				tr_left = 30;
			}
			if (tr_left) {
				tr_left--;
				m = SM_ALL;
			}
		}
		if (ns_force)	/* NSFIX */
			m |= NS_BANDS;
		sm_pend[0] |= m;
		sm_pend[1] |= m;
#ifdef V2_SM_CHECK
		{	/* gate-only: how often each 16-row band is dirty (this frame's marks) */
			int q;
			for (q = 0; q < 30; q++)
				if (m & (1u << q))
					v2_band_hits[q]++;
		}
#endif
		{	/* V3rc8: self-heal -- one row a frame (stepping through the screen) of this buffer that is NOT going
			 * to be copied is compared with the canvas; a difference (something else wrote the GR3 buffer, e.g.
			 * stock on the deck) re-sends its band to both buffers and is counted (HUD X / Y) */
			static u32 sh_row;
			int y = (int)sh_row, q = y >> 4, hr;
			for (hr = 0; hr < 4; hr++, y = y + 120 >= 480 ? y + 120 - 480 : y + 120) {	/* V3rc8q: 4 rows a frame (a full pass ~0.6 s) */
			q = y >> 4;
			if (bd_on && y >= (md_on ? MD_Y0 : BAND_Y0) && y < BAND_Y1 + 8)
				continue;	/* V3rc8r: band rows (+ the ZOOM label; METERDIRECT: + the meter) live in the GR3 buffer */
			if (y >= sr_y0[tb] && y < sr_y1[tb] && sr_x1[tb] > sr_x0[tb])
				continue;	/* D1: re-sent below anyway */
			if (!(sm_pend[tb] & (1u << q))) {
				const u32 *a = (const u32 *)(phys + y * W), *c = (const u32 *)((const u16 *)CANVAS + y * W);
				int x;
				for (x = 0; x < W / 2; x++)
					if (a[x] != c[x]) {
						/* F2 audit: something else wrote this GR3 buffer. One foreign row means
						 * the buffer is not what we painted -- the whole canvas again to both
						 * buffers and keep painting, not this one band (4 rows a frame at one
						 * frame a second took minutes to clear a stuck artifact) */
						sm_pend[0] = sm_pend[1] = SM_ALL;
						pend = 1;
						v2_heal++;
						v2_heal_y = (u32)y;
						break;
					}
			}
			}
			sh_row = sh_row + 7 >= 120 ? sh_row + 7 - 120 : sh_row + 7;
		}
		pm = sm_pend[tb] & SM_ALL;	/* F2 audit: bands 0..29 only -- a stray bit 30 / 31 would spin the loop below
						 * for ever (b stops at 30, nothing clears it): a dead GUI under a live MAIN */
#ifdef V2_SM_CHECK
		{	/* gate-only: every band NOT pending must already match the canvas in this buffer (a miss
			 * = a primitive that wrote the canvas without dmark, or stock writing a GR3 buffer) */
			int y, x;
			for (y = 0; y < 480; y++) {
				const u16 *a = phys + y * W, *c = (const u16 *)CANVAS + y * W;
				if (pm & (1u << (y >> 4)))
					continue;
				for (x = 0; x < W; x++)
					if (a[x] != c[x] && !(y >= sr_y0[tb] && y < sr_y1[tb] && x >= sr_x0[tb] && x < sr_x1[tb])) {
						v2_sm_miss++;
						v2_sm_miss_y = y | (u32)screen_mode() << 16;
						break;
					}
			}
		}
#endif
#ifdef V2_HUD
		u32 cpt0 = now_ms();
#endif
		while (pm) {
			int e;
			while (!(pm & (1u << b)))
				b++;
			for (e = b; e < 30 && (pm & (1u << e)); e++)
				pm &= ~(1u << e);
			{
				int y0 = b << 4, y1 = e << 4;
				if (y1 > 480)
					y1 = 480;
				int part, a0, a1;
				for (part = 0; part < 2; part++) {
					a0 = y0; a1 = y1;
					if (bd_on) {	/* V3rc8r: the band rows are in the GR3 buffer already */
						if (part == 0 && a1 > (md_on ? MD_Y0 : BAND_Y0)) a1 = md_on ? MD_Y0 : BAND_Y0;
						if (part == 1 && a0 < BAND_Y1) a0 = BAND_Y1;
					} else if (part == 1)
						break;
					if (a1 <= a0)
						continue;
#ifdef V2_DMACPY
				/* V3rc8 TEST (work/dmablit): stock's sync DMA copy 0x0E50FFDC(sync, dst, src, bytes, src_inc) --
				 * ch6, 16-byte units, polled; it writes back a cached source itself. CPU copy on a timeout. */
				if (((int (*)(int, void *, const void *, u32, int))0x0E50FFDC)(1, phys + a0 * W,
				    (const u16 *)CANVAS + a0 * W, (u32)(a1 - a0) * W * 2, 1))
#endif
				cp16(phys + a0 * W, (const u16 *)CANVAS + a0 * W, (a1 - a0) * W);
				v2_sm_rows += a1 - a0;
				}
			}
			b = e;
		}
		sm_pend[tb] = 0;
		if (sr_x1[tb] > sr_x0[tb]) {	/* D1: the late windows' rectangle (band rows: in the GR3 buffer with bd_on) */
			int y;
			for (y = sr_y0[tb]; y < sr_y1[tb]; y++)
				if (!(bd_on && y >= (md_on ? MD_Y0 : BAND_Y0) && y < BAND_Y1))
					cp16(phys + y * W + sr_x0[tb], (const u16 *)CANVAS + y * W + sr_x0[tb], sr_x1[tb] - sr_x0[tb]);
			v2_sm_rows += (u32)(sr_y1[tb] - sr_y0[tb]);
			sr_x0[tb] = sr_x1[tb] = 0;
		}
		v2_sm_frames++;
#ifdef V2_HUD
		v2_cp_ms += now_ms() - cpt0;
#endif
	}
	{	/* V3rc8: the GUI's busy share (this paint's draw + copy) over ~1 s windows */
		static u32 ld_w0, ld_busy;
		u32 t = now_ms();
		ld_busy += t - ld_t0;
		if (t - ld_w0 >= 1000) {
			cpu_load = udiv(ld_busy * 100, t - ld_w0);
			if (cpu_load > 99) cpu_load = 99;
			ld_w0 = t;
			ld_busy = 0;
		}
	}
#ifdef V2_HUD
	{	/* per-frame maxima for the HUD (Q = whole frame, WX/KX/MX = sections) */
		int q;
		u32 fr = now_ms() - hud_t0;
		if (fr > v2_qmax) v2_qmax = fr;
		for (q = 0; q < 4; q++) {
			if (v2_pff[q] > v2_pfx[q]) v2_pfx[q] = v2_pff[q];
			v2_pff[q] = 0;
		}
	}
#endif
	v2_frames++;
	/* V3f: flip on change only -- the next two frames (both buffers) after a change, an overlay or a
	 * pending timer; a static screen stops flipping (frame_check restarts it on new input). D1's rule
	 * stays: while flips are wanted the dirty rect is kept non-empty. */
	if (v2_chg || n_ovl || pend)
		dirty_n = 2;
	else if (dirty_n)
		dirty_n--;
	if (dirty_n)
		keep_dirty();
#ifdef V2_HWPROBE
	hwp_frame(screen_mode() == M_PLAYER);
	if (hwp_on)
		dirty_n = 2;	/* keep flipping: the base write commits the GR2 step */
#endif
#ifdef V2_GR2METER
	gm_after();	/* the meter prefix of the ring this frame shows + the GR3 key (needs hb_cur / hb_pend_w0) */
#endif
#ifdef V2_HWBAND
	hb_commit();	/* GR2 base / setup / off + GR3 key: last, right before the stock base write */
#endif
#ifdef V2_GR1METER
	g1_commit();	/* GR1 meter base / setup / off (+ GR2 blend, GR3 key): the same vsync */
#endif
	return 1;
}
