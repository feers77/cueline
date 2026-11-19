/* SPDX-License-Identifier: Apache-2.0
 *
 * usblog.inc -- GUI side of the USB HUD log (TEST builds only: -DV2_HUD -DV2_USBLOG).
 * MAIN side: mods/usblog/main_usblog.s (EXTRA_MODS="usblog", with touch_audio's TESTHOOK variant).
 * Design: re/USB_LOG_DESIGN.md; this implementation and its emulator check: re/AUTOTEST_USBLOG.md.
 *
 * ---- CALL SITES the v2.c owner adds (nothing here is wired by itself) -------------------------------
 *   1. include, anywhere after screen_mode() / cpu_load / MODEL / UPD_STATE are defined (e.g. right
 *      after `static int owned(void) { ... }`):
 *          #if defined(V2_HUD) && defined(V2_USBLOG)
 *          #include "usblog.inc"
 *          #endif
 *   2. in the `#ifdef V2_HUD` block of the paint path, inside `if (t - w0 >= 1000) { ... }`, after the
 *      last txt[] store (txt[25] = v2_a60_over / the MEMPROBE loop) and before
 *      `w0 = t; nf = gmax = hbn = drw = 0; ...`:
 *          #ifdef V2_USBLOG
 *          usblog_push(txt, t);
 *          #endif
 *   (build: V2_CFLAGS="-DV2_HUD -DV2_USBLOG ..." and EXTRA_MODS="usblog [autotest]" for the MAIN side)
 * ------------------------------------------------------------------------------------------------------
 *
 * Channel: the GUI's link TX frame. Stock GUI 1.81 transmits the 4 KB frame at on-chip RAM 0x1C27C000
 * (uncached alias 0x3C27C000; DMA SAR literal 0x0E5009A0, destination RSPI1 SPDR). Boot code clears 16 KB
 * there once; the per-frame builder (0x0E500D68) zeroes only +0x00..+0x3F and copies its 52-byte status
 * message to +0x3C, so a block at +0x800 goes out unchanged in every frame and lands in MAIN's RX buffer
 * 0x09072B38 (+0x800). A u32 keeps its value across the link (GUI BE word == MAIN LE word).
 *
 * Block (512 words at +0x800):
 *   w0   'HUD1' (0x48554431)        w1  head seq (records written so far)
 *   w2   UL_NREC | UL_W << 16       w3  V4n24: ldart_diag() (the loaded track's cover)
 *   w4.. 15 records x 32 words, slot = seq % 15
 *   w511 tail seq (== head when consistent: a seqlock against a DMA mid-update)
 * Record: [0] seq [1] GUI ms [2..27] txt[0..25] [28] cpu % [29] screen | MODEL[7] << 8 | V4m2: wave_type << 16 |
 *         det_blue << 18 | wblue << 19 | HW ring look (8 | wblue << 2 | type, 0 none) << 20 | det flips (0..127) << 24
 *         [30] 0 (MAIN stamps the autotest step there) [31] checksum = (sum w0..w29 ^ 0x5A5A5A5A) & 0x7FFFFFFF
 * Every word < 0x80000000, so nothing in the block looks like a 0xFFFFFFFF message terminator.
 * Cost: ~45 stores a second. Never on the update screen (UPD_STATE).
 */
#define UL_TX	((volatile u32 *)0x3C27C800)
#define UL_NREC	15
#define UL_W	32
#define UL_MAGIC 0x48554431u

static u32 ul_seq, ul_slot;	/* ul_slot = ul_seq % UL_NREC (no division on the SH-2A) */
static u32 ul_x;	/* V4m2: w29 bits 16-30, set by v2.c's HUD block (wave_type / det_blue / wblue / HW ring look / det flips) */

static void usblog_push(const u32 *txt, u32 t)
{
	u32 w[UL_W], s = 0, i;
	volatile u32 *r;

	if (UPD_STATE)
		return;
	if ((v3e_b & 0x8000) && ((v3e_b >> 10) & 3) == 1)	/* V4n: UTILITY TEST LOG = OFF (MAIN publishes it + 1) */
		return;
	ul_seq++;
	if (++ul_slot >= UL_NREC)
		ul_slot = 0;
	w[0] = ul_seq;
	w[1] = t & 0x7FFFFFFF;
	for (i = 0; i < 26; i++)
		w[2 + i] = txt[i] & 0x7FFFFFFF;
	w[28] = cpu_load;
	w[29] = (((u32)screen_mode() & 0xFF) | (u32)MODEL[7] << 8 | ul_x << 16) & 0x7FFFFFFF;
	w[30] = 0;
	for (i = 0; i < 30; i++)
		s += w[i];
	w[31] = (s ^ 0x5A5A5A5Au) & 0x7FFFFFFF;

	UL_TX[511] = 0;				/* open the seqlock: head != tail while we write */
	r = UL_TX + 4 + ul_slot * UL_W;
	for (i = 0; i < UL_W; i++)
		r[i] = w[i];
	UL_TX[0] = UL_MAGIC;
	UL_TX[2] = UL_NREC | UL_W << 16;
	UL_TX[3] = ldart_diag() & 0x7FFFFFFF;	/* V4n24: the loaded-track cover's state (v2.c ldart_diag; MAIN V3US w26) */
	UL_TX[1] = ul_seq;
	UL_TX[511] = ul_seq;			/* close */
}
