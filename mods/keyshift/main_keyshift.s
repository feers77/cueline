! SPDX-License-Identifier: Apache-2.0
!
! keyshift, MAIN side: our front end of the KEY SHIFT engine (mods/keyshift/keyshift.py).
! The engine itself (DSP program with the pitch shifter, the DSP loader patch and the
! DJcont-path routine at 0x08122000 that sends the shift to the DSP) is mods/ownks;
! nothing of it is in this file.
! Its interface (re/KEY_SHIFT_PLAN.md, V4k notes in re/V3_PROGRESS.md):
!   0x08122800 +0  1 = KEY SHIFT on (the DSP path goes through the shifter)
!              +4  semitones, -12..+12 (signed word)
!              +16 a generation counter (a change re-sends the parameter)
! Linked at KSB (patch: 0x08123000).
!
! KSB +0  ks_rbm   REKORDBOX BUTTON (UTILITY): 0 REKORDBOX (stock), 1 KEY SHIFT
!     +4  ks_panel the KEY SHIFT panel (-1 / RESET / +1) is open
!     +8  rb_syn   tick until which a touch-made rekordbox key press is held (SHORT CUT tile)
!     +12 rb_t0    tick of the physical key's press
!     +16 rb_st    0 up, 1 down, 2 down and the long press already fired
!     +20 ks_onv   UTILITY KEY SHIFT word (0 OFF, 1 ON); mirrored into the engine's +0
!     +32 ks_dj    the DJcont call literal 0x082D8970 points here (boot gate)
!     +36 rbk_set  the panel decoder's rekordbox-key setter literals point here
!     +40 rb_lamp  the lamp pass call literal 0x0844F64C points here
!     +44 "KSFT"
!     V4n KEY SYNC (the CDJ-3000's, re/KEY_SHIFT_PLAN.md K1/K3; touch only):
!     +48 ksy_on   KEY SYNC on
!     +52 ksy_pre  the shift before it (restored when it ends)
!     +56 ksy_mt0  MASTER TEMPO before it (0 off: turned on by KEY SYNC, off again at the end)
!     +60 mt_syn   tick until which a KEY SYNC-made MASTER TEMPO press is held
!     +64 ksy_ref  tick until which the K.SYNC box shows a refusal
!     +24 ksy_ld   the own loaded track when it began (status +0x28 ^ +0x2C): a load ends it
!     +28 ksy_gw   the GUI's last KEY SYNC word ("KY" << 16 | valid << 7 | shift + 12; GUI TX +0xFF0)
!     +76 mt_set   the panel decoder's MASTER TEMPO setter literals point here
!     +80 ksy_tap  modsmenu va_ks (action 12, arg 7: the K.SYNC tile) calls this
!     +84 ksy_tick modsmenu ks_pub (every 128 ms) calls this
!     +68 tl_v     UTILITY TEST LOG (TEST builds; touch_audio test_hooks / usblog / the GUI's records)
!     V4n24 KEY SYNC BUTTON (re/KEYSYNC_PAD_RE.md): the HOT CUE D/H pad as the CDJ-3000's KEY SYNC key
!     +72 ksy_btn  UTILITY KEY SYNC BUTTON (0 OFF: the 4 pads stock; 1 ON: D/H = KEY SYNC, hot cues
!                  A..F on pads 1-3 of the two banks)
!     +88 hc_prev  the D/H pad's last level (press edge)
!     +92 hc_set   the panel decoder's hot-cue setter literals point here
!     +96 hc_lamp  the panel frame builder's pad-RGB getter literal points here
!     V4n33 KEY SYNC with a CDJ-2000NXS2 master (ours or stock; re/KEY_SHIFT_PLAN.md K7):
!     +100 kx_on   1 = our status packet (type 0x0A) is sent as 0x180 bytes with the CDJ-3000's key
!                  fields (0x154 original key, 0x158 MASTER TEMPO, 0x15C sounding key, 0x168 KEY
!                  SHIFT cents), read back by ks3k on our decks; 0 = stock 0x124 bytes
!     +104 kc_mst  r0 = the LINK master's key code (Camelot n * 2 + B) from w8cap's DB key cache
!                  (KC = RAMB+0x1E0C0, 8 x {tid word, rbid, "DK" << 16 | code, fail tick}, mods/w8fetch/w8.inc)
!     +108 kx_send the status sender's literal 0x084B8FA0 (stock 0x085117CA, the UDP send) points here
!     +112 kx_cnt, +116 kx_last  debug
!
! Update safety (main-update-safety): every entry tests *0x0A35DF3C == 1 first and is exactly
! the stock path otherwise. No malloc, spawn or task; only word stores into this block, the
! engine's block and the source-key lamp table.

	.ifndef	KILLB			! V4n36 trace: modsmenu's kill switches (ks layout menu 0x08014000 + 0x1E0;
	.equ	KILLB, 0x080141E0	!   layout.inc KILLB, patch_main place_modsmenu asserts it)
	.endif

	.text
	.global	ks_base
ks_base:
ks_rbm:	.long	0
ks_panel: .long	0
rb_syn:	.long	0
rb_t0:	.long	0
rb_st:	.long	0
ks_onv:	.long	0
	.long	0, 0
	bra	ks_dj			! +32
	nop
	bra	rbk_set			! +36
	nop
	bra	rb_lamp			! +40
	nop
	.long	0x4B534654		! "KSFT"
ksy_on:	.long	0			! +48
	.long	0, 0, 0, 0		! +52 .. +64
tl_v:	.long	2			! +68 V4n: UTILITY TEST LOG (0 OFF, 1 USB, 2 RED; default RED while
					!     developing; not saved: back to the default each boot)
ksy_btn: .long	0			! +72 UTILITY KEY SYNC BUTTON (0 OFF = stock pads, 1 ON); saved:
					!     HISTORY tail bit 6 (modsmenu)
	bra	mt_set			! +76
	nop
	bra	ksy_tap			! +80
	nop
	bra	ksy_tick		! +84
	nop
hc_prev: .long	0			! +88 the D/H pad's last level
	bra	hc_set			! +92
	nop
	bra	hc_lamp			! +96
	nop
kx_on:	.long	1			! +100 V4n33 KEY SYNC over LINK: our status packet carries the CDJ-3000's
					!      key fields (0 = the stock 0x124-byte packet; poke for A/B on the rig)
	bra	kc_mst			! +104 modsmenu v3e_pub2: r0 = the LINK master's key code from the DB cache
	nop
	bra	kx_send			! +108 the status sender's send literal 0x084B8FA0 points here
	nop
kx_cnt:	.long	0			! +112 extended packets sent (debug)
kx_last: .long	0			! +116 the last 0x154 / 0x15C key words sent (debug: 0x154 << 16 | 0x15C b0 b3)

	.equ	RB_LONG, 600		! ms: a longer press resets the shift
	.equ	RB_SYN, 120		! ms a touch-made rekordbox press is held

! The DJcont loop's DSP-output step (0x082DBC2E) through the engine's wrapper (0x08122000,
! which calls the step and then sends the shift) on a normal boot; the step alone otherwise.
! Uses r1 and T only (the call's own arguments r4-r7 untouched).
ks_dj:
	mov.l	L_boot,r1
	mov.l	@r1,r1
	dt	r1			! T = (boot == 1)
	bf	1f
	mov.l	L_eng,r1
	jmp	@r1
	nop
1:	mov.l	L_step,r1
	jmp	@r1
	nop

! rbk_set(r4 deck, r5 level): the panel decoder's setter for the rekordbox key (stock 0x084E10F8
! stores the level word 0x0B54C99C). Stock unless boot == 1, KEY SHIFT on and REKORDBOX BUTTON =
! KEY SHIFT; then the physical level never reaches stock (0 is stored) and the key works the
! KEY SHIFT panel: a short press (< RB_LONG) opens / closes it, a long press resets the shift to 0
! and closes it. A touch-made press (rb_syn, the SHORT CUT tile) is passed on as level 1 for
! RB_SYN ms in every mode, so the stock rekordbox function stays reachable.
rbk_set:
	mov.l	L_boot,r0
	mov.l	@r0,r0
	cmp/eq	#1,r0
	bf	rb_stock
	mov.l	L_base,r7		! r7 = the block
	mov.l	L_tick,r1
	mov.l	@r1,r2			! r2 = now (ms)
	mov.l	@(8,r7),r0		! a touch-made press still held?
	sub	r2,r0
	cmp/pl	r0
	bf	1f
	bra	rb_stock
	mov	#1,r5
1:	mov.l	@(20,r7),r0		! KEY SHIFT on and the key is KEY SHIFT?
	tst	r0,r0
	bt	rb_stock
	mov.l	@r7,r0
	tst	r0,r0
	bt	rb_stock
	mov.l	@(16,r7),r0		! r0 = state
	tst	r5,r5
	bt	3f
	tst	r0,r0			! down
	bf	2f
	mov	#1,r0
	mov.l	r0,@(16,r7)
	bra	rb_zero
	mov.l	r2,@(12,r7)
2:	cmp/eq	#1,r0
	bf	rb_zero
	mov.l	@(12,r7),r1
	mov	r2,r0
	sub	r1,r0
	mov.w	W_long,r1
	cmp/hs	r1,r0
	bf	rb_zero
	mov	#2,r0			! long press: reset to 0, panel closed
	mov.l	r0,@(16,r7)
	mov	#0,r0
	mov.l	r0,@(4,r7)
	mov.l	L_eng_st,r1
	bra	rb_zero
	mov.l	r0,@(4,r1)
3:	cmp/eq	#1,r0			! up: a short press toggles the panel
	bf	4f
	mov.l	@(4,r7),r1
	tst	r1,r1
	movt	r1
	mov.l	r1,@(4,r7)
4:	mov	#0,r0
	mov.l	r0,@(16,r7)
rb_zero:
	mov	#0,r5
rb_stock:
	mov.l	L_rbset,r0
	jmp	@r0
	nop
	.p2align 1
W_long:	.short	RB_LONG

! The lamp pass (0x084DC768, rebuilds the source-key table 0x0B54C030[0..4]: 3 lit, 1 dim; [4] =
! the rekordbox key) and, on a normal boot with KEY SHIFT on and REKORDBOX BUTTON = KEY SHIFT,
! the rekordbox key lit while the shift is not 0, dim otherwise. r0 of the pass is kept.
rb_lamp:
	sts.l	pr,@-r15
	mov.l	L_lamp,r1
	jsr	@r1
	nop
	lds.l	@r15+,pr
	mov	r0,r7			! the pass's r0, kept
	mov.l	L_boot,r1
	mov.l	@r1,r1
	dt	r1
	bf	9f
	mov.l	L_base,r2
	mov.l	@(20,r2),r1
	tst	r1,r1
	bt	9f
	mov.l	@r2,r1
	tst	r1,r1
	bt	9f
	mov.l	L_eng_st,r1
	mov.l	@(4,r1),r1
	mov	#1,r3
	tst	r1,r1
	bt	1f
	mov	#3,r3
1:	mov.l	L_keys,r1
	mov.l	r3,@(16,r1)
9:	rts
	mov	r7,r0

! mt_set(r4 deck, r5 level): the panel decoder's MASTER TEMPO setter (stock 0x084E171C stores the
! level word 0x0B54CB0C). A KEY SYNC-made press (mt_syn) is passed on as level 1 for RB_SYN ms on a
! normal boot; otherwise exactly stock.
mt_set:
	mov.l	L_boot,r0
	mov.l	@r0,r0
	cmp/eq	#1,r0
	bf	1f
	mov.l	L_base,r1
	mov.l	@(60,r1),r0
	mov.l	L_tick,r1
	mov.l	@r1,r1
	sub	r1,r0
	cmp/pl	r0
	bf	1f
	mov	#1,r5
1:	mov.l	L_mtset,r0
	jmp	@r0
	nop

! gw_get: r0 = the KEY SYNC word ("KY" << 16 | valid << 7 | shift + 12) into +28: V4n33 MAIN's own (kx_word:
! both keys known to MAIN -- the master's from its status or dbserver, ours from the DB --) else the GUI's.
! Clobbers r0-r3.
! V4n35: no MAIN word (this deck the master, no master, a key unknown) first stores "KY" not valid, so a
! stale valid word from an earlier master no longer survives in +28: ksy_tap (which falls back to +28)
! engaged KEY SYNC on the master itself on the real rig (deck 3, GUI word absent from the RX slots).
gw_get:
	sts.l	pr,@-r15
	bsr	kx_word
	nop
	mov.l	L_base,r1
	tst	r0,r0
	bf/s	2f
	mov.l	r0,@(28,r1)		! (no word: overwritten just below)
	mov.w	W_ky,r0
	shll16	r0
	mov.l	r0,@(28,r1)		! "KY", not valid
	bsr	gw_gui			! the GUI's word, when it has one, replaces it
	nop
2:	lds.l	@r15+,pr
	rts
	nop

! gw_gui: r0 = the GUI's KEY SYNC word from MAIN's 3 RX slots (0 none), into +28 when found.
! Clobbers r0-r3.
gw_gui:
	mov.l	L_rx,r1
	mov	#3,r3
1:	mov.l	@r1,r0
	mov	r0,r2
	shlr16	r2
	mov.w	W_ky,r0
	cmp/eq	r0,r2
	bt	2f
	mov	#64,r0			! next slot: + 16 KB
	shll8	r0
	dt	r3
	bf/s	1b
	add	r0,r1
	rts
	mov	#0,r0
2:	mov.l	@r1,r0
	mov.l	L_base,r1
	rts
	mov.l	r0,@(28,r1)

! own_ld: r0 = the own loaded track (status +0x28 ^ +0x2C). Clobbers r1, r2.
own_ld:
	mov.l	L_stat,r1
	mov.l	@(0x28,r1),r0
	mov.l	@(0x2C,r1),r2
	rts
	xor	r2,r0

! mt_now: T = MASTER TEMPO off (heartbeat +0x20, V4n33: was +0x23 = the word's top byte, always 0). Clobbers r0, r1.
mt_now:
	mov.l	L_mt,r1
	mov.b	@r1,r0
	tst	r0,r0
	rts
	movt	r0			! (T = off; r0 = off)

! ksy_end: KEY SYNC off -- the shift back to the one before, MASTER TEMPO back off if KEY SYNC
! turned it on (r4 != 0: and it is still on). r7 = the block. Clobbers r0-r3.
ksy_end:
	sts.l	pr,@-r15
	mov	#0,r0
	mov.l	r0,@(48,r7)
	mov.l	L_eng_st,r3
	mov.l	@(52,r7),r0
	mov.l	r0,@(4,r3)
	mov	#0,r0			! CENTPOP: no KEY SYNC cents
	mov.l	r0,@(40,r3)
	mov.l	@(16,r3),r0
	add	#1,r0
	and	#127,r0
	mov.l	r0,@(16,r3)
	tst	r4,r4
	bt	9f
	mov.l	@(56,r7),r0
	tst	r0,r0
	bf	9f
	bsr	mt_now
	nop
	bt	9f			! already off
	bsr	mt_press
	nop
9:	lds.l	@r15+,pr
	rts
	nop

! mt_press: a MASTER TEMPO press for RB_SYN ms (mt_set). r7 = the block. Clobbers r0, r1.
mt_press:
	mov.l	L_tick,r1
	mov.l	@r1,r1
	mov	#RB_SYN,r0
	add	r1,r0
	rts
	mov.l	r0,@(60,r7)

! ksy_shift: r0 = the GUI word -> the engine's shift (its generation bumped). Clobbers r0-r2.
ksy_shift:
	mov.l	L_eng_st,r1
	mov	r0,r2			! CENTPOP: bits 8-15 = the master's cents (signed byte; the GUI's word: 0)
	shlr8	r2
	exts.b	r2,r2
	mov.l	r2,@(40,r1)		!   -> the engine's +40 (ownks adds it while KEY SYNC is on)
	and	#31,r0
	add	#-12,r0
	mov.l	@(4,r1),r2
	cmp/eq	r0,r2
	bt	1f
	mov.l	r0,@(4,r1)
	mov.l	@(16,r1),r0
	add	#1,r0
	and	#127,r0
	mov.l	r0,@(16,r1)
1:	rts
	nop

! ksy_tap: the K.SYNC tile. On: end it (MASTER TEMPO back). Off: KEY SHIFT on and the GUI's word
! valid (both keys known, another deck the master) -> the shift that puts the own key on the
! master's (or its +-1 Camelot neighbour, the nearest), MASTER TEMPO on; else a refusal (the box
! flashes). Saves r4-r7.
ksy_tap:
	sts.l	pr,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	mov.l	L_boot,r0
	mov.l	@r0,r0
	cmp/eq	#1,r0
	bf	kt_out
	mov.l	L_base,r7
	mov.l	@(48,r7),r0
	tst	r0,r0
	bt	1f
	bsr	ksy_end			! on -> off
	mov	#1,r4
	bra	kt_out
	nop
1:	mov.l	L_kill,r1		! V4n36 trace: the KEY SYNC kill switch OFF (modsmenu kill_v +0) -> no new
	mov.l	@r1,r0			!   KEY SYNC (ending one still works)
	tst	r0,r0
	bt	kt_out
	mov.l	L_eng_st,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	kt_ref			! KEY SHIFT off
	bsr	gw_get
	nop
	tst	r0,r0
	bf	2f
	mov.l	@(28,r7),r0		! the last one seen
2:	mov	r0,r4
	shlr16	r0
	mov.w	W_ky,r1
	cmp/eq	r1,r0
	bf	kt_ref
	mov	r4,r0
	tst	#0x80,r0
	bt	kt_ref
	mov.l	L_eng_st,r1
	mov.l	@(4,r1),r0
	mov.l	r0,@(52,r7)		! the shift before
	bsr	own_ld
	nop
	mov.l	r0,@(24,r7)
	mov	#1,r0
	mov.l	r0,@(48,r7)
	bsr	ksy_shift
	mov	r4,r0
	bsr	mt_now
	nop
	mov	#1,r1
	sub	r0,r1			! 1 = it was on
	mov.l	r1,@(56,r7)
	tst	r0,r0
	bt	kt_out
	bsr	mt_press		! MASTER TEMPO on, as the 3000
	nop
	bra	kt_out
	nop
kt_ref:	mov.l	L_tick,r1
	mov.l	@r1,r1
	mov.w	W_ref,r0
	add	r0,r1
	mov	#64,r0
	mov.l	r1,@(r0,r7)
kt_out:	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	lds.l	@r15+,pr
	rts
	nop

! ksy_tick (every 128 ms, modsmenu ks_pub): the GUI's word kept; while KEY SYNC is on it follows the
! master (a new word), ends on an own load (MASTER TEMPO back) or KEY SHIFT off, and is cancelled
! when MASTER TEMPO goes off (the 3000: the shift back, MT stays off). Saves r3-r7.
ksy_tick:
	sts.l	pr,@-r15
	mov.l	r3,@-r15
	mov.l	r4,@-r15
	mov.l	r7,@-r15
	mov.l	L_boot,r0
	mov.l	@r0,r0
	cmp/eq	#1,r0
	bf	tk_out
	mov.l	L_base,r7
	bsr	gw_get
	nop
	mov.l	@(48,r7),r1
	tst	r1,r1
	bt	tk_out
	mov.l	L_eng_st,r1		! KEY SHIFT off: it ended with it (ks_sync)
	mov.l	@r1,r1
	tst	r1,r1
	bf	1f
	mov	#0,r1
	bra	tk_out
	mov.l	r1,@(48,r7)
1:	bsr	own_ld
	nop
	mov.l	@(24,r7),r1
	cmp/eq	r0,r1
	bt	2f
	bsr	ksy_end			! own load: the end, MASTER TEMPO back
	mov	#1,r4
	bra	tk_out
	nop
2:	mov.l	@(60,r7),r0		! MASTER TEMPO off by the user (not within 1 s of our press)
	mov.l	L_tick,r1
	mov.l	@r1,r1
	sub	r1,r0
	mov.w	W_mtset,r1
	add	r1,r0
	cmp/pl	r0
	bt	3f
	bsr	mt_now
	nop
	bf	3f
	bsr	ksy_end			! cancelled: the shift back, MT stays off
	mov	#0,r4
	bra	tk_out
	nop
3:	mov.l	@(28,r7),r0		! follow the master: the newest valid word
	mov	r0,r4
	shlr16	r0
	mov.w	W_ky,r1
	cmp/eq	r1,r0
	bf	tk_out
	mov	r4,r0
	tst	#0x80,r0
	bt	tk_out
	bsr	ksy_shift
	mov	r4,r0
tk_out:	mov.l	@r15+,r7
	mov.l	@r15+,r4
	mov.l	@r15+,r3
	lds.l	@r15+,pr
	rts
	nop

	.p2align 1
W_ky:	.short	0x4B59			! "KY"
W_ref:	.short	600
W_mtset: .short	1000
	.p2align 2
L_mtset: .long	0x084E171C		! stock MASTER TEMPO setter
L_rx:	.long	0xA9072B38 + 0xFF0	! MAIN's RX slot 0 (+ slot << 14), the GUI word's place
L_stat:	.long	0x0B53D828		! the own status packet
L_mt:	.long	0x0B568C9C + 0x20	! heartbeat +0x20 (the GUI's BE byte +0x23): MASTER TEMPO
L_boot:	.long	0x0A35DF3C		! MAIN boot state (1 = normal boot)
L_base:	.long	ks_base
L_kill:	.long	KILLB			! V4n36 trace: modsmenu kill_v (+0 KEY SYNC, 1 ON)
L_eng:	.long	0x08122000		! the engine's DJcont wrapper
L_step:	.long	0x082DBC2E		! stock DSP-output step
L_eng_st: .long	0x08122800		! the engine's state
L_tick:	.long	0x0B0C5258		! ms tick
L_rbset: .long	0x084E10F8		! stock rekordbox-key setter
L_lamp:	.long	0x084DC768		! stock lamp pass
L_keys:	.long	0x0B54C030		! source-key lamp table

! hc_set(r4 deck, r5 idx 1..8, r6 level 0/1): the panel decoder's hot-cue setter (stock 0x084E1974 stores
! the level word 0x0B54CBDC + 0x2CC * deck + 4 * idx; the decoder calls it for the 4 pads every frame,
! idx = 4 * bank + pad). Stock unless boot == 1, KEY SYNC BUTTON ON and deck 0. Then pad 4 (D/H) is
! KEY SYNC: its press (0 -> 1) taps ksy_tap; stock never sees it, and the unreachable G / H levels
! are held at 0. Pads 1-3 are the hot cues A,B,C (bank A-D) / D,E,F (bank E-H); the same pad's slot
! of the other bank is held at 0 (a bank change while pressed leaves nothing stuck).
hc_set:
	mov.l	H_boot,r0
	mov.l	@r0,r0
	cmp/eq	#1,r0
	bf	hs_stock
	mov.l	H_base,r1
	mov	#72,r0
	mov.l	@(r0,r1),r0
	tst	r0,r0
	bt	hs_stock
	mov.l	H_kill,r0		! V4n36 trace: KEY SYNC killed -> the 4 pads stock
	mov.l	@r0,r0
	tst	r0,r0
	bt	hs_stock
	tst	r4,r4
	bf	hs_stock
	mov	r5,r0
	add	#-1,r0			! r0 = idx - 1
	mov	#8,r2
	cmp/hs	r2,r0
	bt	hs_stock		! not 1..8
	mov	r0,r2
	and	#3,r0			! r0 = pad (0..3)
	cmp/eq	#3,r0
	bt	hs_ks
	shlr2	r2			! r2 = bank
	mov	r2,r3
	add	r2,r3
	add	r2,r3
	add	r0,r3
	add	#1,r3			! r3 = the hot cue: 3 * bank + pad + 1
	mov	r3,r0
	tst	r2,r2
	bf	1f
	add	#6,r0
1:	add	#-3,r0			! r0 = the same pad's hot cue in the other bank
	shll2	r0
	mov.l	L_lvl,r1
	mov	#0,r2
	mov.l	r2,@(r0,r1)
	mov	r3,r5
hs_stock:
	mov.l	L_hcset,r0
	jmp	@r0
	nop
hs_ks:	mov.l	L_lvl,r1		! G / H: level 0
	mov	#0,r2
	mov	#28,r0
	mov.l	r2,@(r0,r1)
	mov	#32,r0
	mov.l	r2,@(r0,r1)
	mov.l	H_base,r1
	mov	#88,r0
	mov.l	@(r0,r1),r2		! r2 = the last level
	mov.l	r6,@(r0,r1)
	tst	r6,r6
	bt	9f
	tst	r2,r2
	bf	9f
	sts.l	pr,@-r15		! pressed: KEY SYNC on / off (or the refusal)
	bsr	ksy_tap
	nop
	lds.l	@r15+,pr
9:	rts
	nop

! hc_lamp(r4 pad 0..3, @r15 out): the frame builder's pad-RGB getter (stock 0x084DC684: the RGB of hot
! cue 4 * bank + pad + 1, bank = 0x0B54C0B8). Stock unless boot == 1 and KEY SYNC BUTTON ON. Then pads
! 0-2 show the hot cues they set (hc_set) and pad 3 is the KEY SYNC lamp: WHITE while KEY SYNC is on,
! BLUE when the own key matches the master's (the GUI word valid and its shift == the current one:
! naturally (0) or through a manual KEY SHIFT), off otherwise; a refused tap blinks it WHITE / off.
hc_lamp:
	mov.l	H_boot,r0
	mov.l	@r0,r0
	cmp/eq	#1,r0
	bf	hl_stock
	mov.l	H_base,r7
	mov	#72,r0
	mov.l	@(r0,r7),r0
	tst	r0,r0
	bt	hl_stock
	mov.l	H_kill,r0		! V4n36 trace: KEY SYNC killed -> the pad lamps stock
	mov.l	@r0,r0
	tst	r0,r0
	bt	hl_stock
	mov	#3,r1
	cmp/hi	r1,r4
	bt	hl_stock		! not a pad
	mov.l	@r15,r3			! r3 = out
	mov	r4,r0
	cmp/eq	#3,r0
	bt	hl_ks
	mov.l	L_lbank,r1
	mov.l	@r1,r2
	mov	#1,r0
	and	r0,r2			! r2 = bank
	mov	r2,r1
	add	r2,r1
	add	r2,r1
	add	r4,r1
	add	#1,r1			! r1 = the hot cue
	mov	r1,r0
	shll2	r0
	add	r1,r0
	shll2	r0			! 20 * hot cue
	mov.l	L_hcrgb,r1
	add	r0,r1
	mov.b	@r1,r0
	mov.b	r0,@r3
	mov.b	@(1,r1),r0
	mov.b	r0,@(1,r3)
	mov.b	@(2,r1),r0
	rts
	mov.b	r0,@(2,r3)
hl_ks:	mov	#0,r1			! r1 = 0xRRGGBB
	mov.l	@(48,r7),r0
	tst	r0,r0
	bf	hl_white
	mov.l	@(28,r7),r0		! the GUI's word
	mov	r0,r2
	shlr16	r2
	mov.w	H_ky,r5
	cmp/eq	r5,r2
	bf	hl_out
	tst	#0x80,r0
	bt	hl_out
	and	#31,r0
	add	#-12,r0			! r0 = the shift that matches
	mov.l	H_eng_st,r2
	mov.l	@r2,r5			! KEY SHIFT off: the current shift is 0
	tst	r5,r5
	bt	1f
	mov.l	@(4,r2),r5
1:	cmp/eq	r0,r5
	bf	hl_out
	mov.l	L_blue,r1
	bra	hl_out
	nop
hl_white:
	mov.l	L_white,r1
hl_out:	mov.l	H_tick,r2
	mov.l	@r2,r2
	mov	#64,r0
	mov.l	@(r0,r7),r0
	sub	r2,r0
	cmp/pl	r0
	bf	2f			! no refusal showing
	mov.l	L_white,r1
	mov	r2,r0
	tst	#0x80,r0
	bf	2f
	mov	#0,r1
2:	mov	r1,r0
	mov.b	r0,@(2,r3)
	shlr8	r0
	mov.b	r0,@(1,r3)
	shlr8	r0
	rts
	mov.b	r0,@r3
hl_stock:
	mov.l	L_hcget,r0
	jmp	@r0
	nop

	.p2align 2
L_hcset: .long	0x084E1974		! stock hot-cue setter
L_hcget: .long	0x084DC684		! stock pad-RGB getter
L_lvl:	.long	0x0B54CBDC		! deck 0's hot-cue level words (+4 * idx)
L_lbank: .long	0x0B54C0B8		! the pad lamps' bank
L_hcrgb: .long	0x0B54C180		! hot cue n's RGB at + 20 * n
L_blue:	.long	0x001064FF		! the stock palette's blue
L_white: .long	0x00FFFFFF
H_boot:	.long	0x0A35DF3C
H_base:	.long	ks_base
H_kill:	.long	KILLB			! V4n36 trace: modsmenu kill_v +0 KEY SYNC
H_tick:	.long	0x0B0C5258
H_eng_st: .long	0x08122800
H_ky:	.short	0x4B59			! "KY"
	.p2align 2

! kc_code(r4 = player 1..6): r0 = the key code w8cap's DB cache (KC, 8 entries) holds for the track the
! player has loaded now (LINK table 0x0A371D3C + p * 0x124: +0x28 source | slot << 8 | type << 16, +0x2C
! rbid), 0 = none / not fetched / no key. Clobbers r0-r3, r5.
kc_code:
	mov	r4,r0
	add	#-1,r0
	mov	#6,r1
	cmp/hs	r1,r0
	bt	kc_none
	mov	#0x49,r1
	shll2	r1			! 0x124
	mulu.w	r4,r1
	mov.l	K_tab,r2
	sts	macl,r1
	add	r1,r2
	mov.l	@r2,r3
	shll8	r3
	shlr8	r3			! the tid word (24 bits)
	mov.l	@(4,r2),r5		! the rbid
	mov.l	K_kc,r1
	mov	#8,r2
1:	mov.l	@r1,r0
	cmp/eq	r3,r0
	bf	2f
	mov.l	@(4,r1),r0
	cmp/eq	r5,r0
	bf	2f
	mov.l	@(8,r1),r0
	mov	r0,r2
	shlr16	r2
	mov.w	K_dkc,r3
	cmp/eq	r3,r2
	bf	kc_none
	rts
	and	#31,r0
2:	dt	r2
	bf/s	1b
	add	#16,r1
kc_none: rts
	mov	#0,r0
	.p2align 1
K_dkc:	.short	0x444B			! "DK"

! kx_word: r0 = MAIN's KEY SYNC word (v2.c ks_publish's rule: the own key onto the master's key or its +-1
! Camelot neighbour in the own letter, the nearest, ties master / +1 / -1) when another deck is the master and
! both keys are known (master: ks3k's K3 entry from its status, else the DB cache; own: the DB cache), else 0.
! Clobbers r0-r3; keeps r4-r7.
kx_word:
	sts.l	pr,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	mov.l	r8,@-r15		! CENTPOP: r8 = the master's cents byte (0 = none)
	mov	#0,r8
	mov.l	K_hb,r1
	mov	#0x5C,r0
	mov.l	@(r0,r1),r6		! this deck
	mov	#0x52,r0
	shll	r0
	mov.l	@(r0,r1),r7		! the master
	cmp/eq	r6,r7
	bt	kw_no
	mov	r7,r0
	add	#-1,r0
	mov	#6,r1
	cmp/hs	r1,r0
	bt	kw_no
	mov.l	K_k3,r1			! its status key (ks3k)
	mov	r7,r0
	shll2	r0
	shll	r0
	add	r0,r1
	mov.l	@(4,r1),r0
	mov	r0,r2
	shlr16	r2
	mov.w	K_k3m,r3
	cmp/eq	r3,r2
	bf	1f
	mov	r0,r8			! CENTPOP: ks3k's residual cents, bits 8-15
	shlr8	r8
	extu.b	r8,r8
	and	#31,r0
	tst	r0,r0
	bf	2f
1:	mov	#0,r8			! (dbserver key: no cents)
	bsr	kc_code			! its dbserver key
	mov	r7,r4
2:	tst	r0,r0
	bt	kw_no
	mov	r0,r7			! r7 = m
	bsr	kc_code
	mov	r6,r4
	tst	r0,r0
	bt	kw_no
	mov	r0,r4
	shlr	r4			! r4 = own number 1..12
	mov	r7,r5
	shlr	r5
	add	#-1,r5			! r5 = master number - 1
	mov	#99,r6			! r6 = best
	bsr	kw_c
	mov	#0,r0
	bsr	kw_c
	mov	#1,r0
	bsr	kw_c
	mov	#-1,r0
	mov	r6,r0
	add	#12,r0
	shll8	r8
	or	r8,r0			! CENTPOP: the cents in bits 8-15
	mov.l	K_kyw,r1
	bra	kw_out
	or	r1,r0
kw_no:	mov	#0,r0
kw_out:	mov.l	@r15+,r8
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	lds.l	@r15+,pr
	rts
	nop
! kw_c(r0 = d): x = the shift onto master + d (wrapped to -6..5); r6 = x when |x| < |r6|. Uses r0-r3.
kw_c:	add	r5,r0
	add	#12,r0
	mov	#12,r1
1:	cmp/hs	r1,r0
	bf	2f
	bra	1b
	sub	r1,r0
2:	add	#1,r0			! tn 1..12
	sub	r4,r0
	add	#12,r0			! tn - own + 12, 1..23
	mov	r0,r2
	shll2	r0
	shll	r0
	sub	r2,r0			! * 7
3:	cmp/hs	r1,r0
	bf	4f
	bra	3b
	sub	r1,r0
4:	mov	#5,r2
	cmp/gt	r2,r0
	bf	5f
	add	#-12,r0
5:	mov	r0,r2
	cmp/pz	r2
	bt	6f
	neg	r2,r2
6:	mov	r6,r3
	cmp/pz	r3
	bt	7f
	neg	r3,r3
7:	cmp/hs	r3,r2
	bt	8f
	mov	r0,r6
8:	rts
	nop
	.p2align 1
K_k3m:	.short	0x4B33			! "K3"

! kc_mst: r0 = the LINK master's key code (another deck; 0 = none). Keeps r1-r7.
kc_mst:
	sts.l	pr,@-r15
	mov.l	r1,@-r15
	mov.l	r2,@-r15
	mov.l	r3,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	K_boot,r0
	mov.l	@r0,r0
	cmp/eq	#1,r0
	bf	1f
	mov.l	K_hb,r1
	mov	#0x5C,r0
	mov.l	@(r0,r1),r2		! this deck
	mov	#0x52,r0
	shll	r0
	mov.l	@(r0,r1),r4		! +0xA4 the master
	cmp/eq	r2,r4
	bt	1f
	bsr	kc_code
	nop
	bra	2f
	nop
1:	mov	#0,r0
2:	mov.l	@r15+,r5
	mov.l	@r15+,r4
	mov.l	@r15+,r3
	mov.l	@r15+,r2
	mov.l	@r15+,r1
	lds.l	@r15+,pr
	rts
	nop

! kx_send(r4 the status packet on the sender's stack, r5 its send descriptor: +0 length 0x124, ...):
! the status sender 0x084B8132's UDP send (stock 0x085117CA, once per destination). On a normal boot
! with kx_on, the packet goes out as 0x180 bytes (length field 0x22 = 0x15C, as a CDJ-3000's 0x45C)
! with the CDJ-3000's key fields (re/KEY_SHIFT_PLAN.md K5; the 3000 reads them in link manager
! into its player state, vfunc 16):
!   0x154 the loaded track's key {relative-major tonic 0..11, 1 = B (major), 0, valid} (default 00 01 64 00)
!   0x158 MASTER TEMPO (1 on)
!   0x15C the sounding key: + the tempo fader's semitones (MT off; 12 log2 of pitch 0x8C), NOT KEY SHIFT
!   0x160 CENTPOP: sounding cents (-50..+49 over 0x15C: the fader's rest with MT off + our KEY SYNC cents), 0x164 KEY SHIFT in cents (int64 BE), 0x124 = 1, 0x16C = 1 (V4n36a)
! Stock NXS2s copy only 0x124 bytes (and accept a 3000's 0x480); our ks3k reads 0x15C. The stack
! descriptor's length is restored after the send.
! COMPAT (work/compat/COMPAT_AUDIT.md): per destination (the stock loop's r11 = its device number, 1..68),
! by the class ks3k keeps from that player's own status (KCLS = RAMB + 0x1E848 + player):
!   3 a CDJ-3000 / 3000X ("CDJ-3..."): 0x480 bytes, length 0x45C, version 0x20 = 6 -- a 3000 (fw 3.22)
!     parses the key fields only with version >= 6 AND the full 0x45C payload (live /proc reads of its
!     player state, bisected); 0x124 stays 0 (NXS2 fields not taken as 3000 ones; )
!   2 a Cueline deck ("CDJ-2000NXS2" with a length field >= 0x15C): 0x180 bytes as before (ks3k reads them)
!   0 anything else (stock NXS2, XDJ, DJM, rekordbox, players 7+, unknown): the stock 0x124 packet, untouched
! Both extended forms: 0x150 = the track BPM x 100 (as a 3000), the key fields with the 3000's accidental
! byte. Our name, device type and keepalive stay the stock CDJ-2000NXS2's.
kx_send:
	mov.l	K_boot,r0
	mov.l	@r0,r0
	cmp/eq	#1,r0
	bf	kx_orig
	mov.l	K_base,r1
	mov	#100,r0
	mov.l	@(r0,r1),r0
	tst	r0,r0
	bt	kx_orig
	mov.l	@r5,r0
	mov.w	K_124e,r1
	cmp/eq	r1,r0
	bf	kx_orig
	mov	r11,r0			! COMPAT: the destination (the sender loop's device number)
	add	#-1,r0
	mov	#5,r1
	cmp/hi	r1,r0			! players 1..6 only
	bt	kx_orig
	mov.l	K_cls,r1
	add	r11,r1
	mov.b	@r1,r0			! its class (ks3k; RAMB is 0xFF until ks3k has seen that player)
	extu.b	r0,r0
	cmp/eq	#3,r0
	bt	kx_cl
	cmp/eq	#2,r0
	bf	kx_orig			! not 2 / 3: the stock packet
kx_cl:	mov.l	K_cur,r1
	bra	kx_go
	mov.l	r0,@r1			! this send's class (2 or 3)
kx_orig: mov.l	K_send,r0
	jmp	@r0
	nop
K_124e:	.short	0x124			! (near literals: the pool after kx_send is out of mov.w range here)
kx_go:	sts.l	pr,@-r15
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15		! CENTPOP: r13 = the sounding cents for 0x160
	mov	r4,r8
	mov	r5,r9
	mov.l	K_buf,r10
	mov	r8,r1
	mov	r10,r2
	mov	#73,r3			! 0x124 bytes
1:	mov.l	@r1+,r0
	mov.l	r0,@r2
	dt	r3
	bf/s	1b
	add	#4,r2
	mov	#0,r0
	mov	#-41,r3			! 0x124..0x47F zero: (0x480 - 0x124) / 4 = 215 words
	extu.b	r3,r3
2:	mov.l	r0,@r2
	dt	r3
	bf/s	2b
	add	#4,r2
	mov.l	K_cur,r0		! COMPAT: the length field 0x15C (class 2) or 0x45C + version 6 (class 3)
	mov.l	@r0,r0
	cmp/eq	#3,r0
	bf/s	kx_l2
	mov	#1,r1
	mov	#0x20,r0		! the status version: 6 (a stock NXS2 sends 5, a CDJ-3000 8)
	mov	#6,r1
	mov.b	r1,@(r0,r10)
	mov	#4,r1
kx_l2:	mov	#0x22,r0		! the length field: 0x180 / 0x480 - 0x24
	mov.b	r1,@(r0,r10)
	mov	#0x23,r0
	mov	#0x5C,r1
	mov.b	r1,@(r0,r10)
	mov.w	K_124,r0		! V4n36a (A3): 0x16C = 1 (the KEY SHIFT at 0x164 is valid; )
	mov	#1,r1
	add	#0x48,r0
	mov.b	r1,@(r0,r10)
	! LINK0B (v4.2, work/link0b RE_LINKWAVE.txt): to a CDJ-3000 (class 3) with UTILITY LINK 0x0B ON, status byte
	! 0xCD |= 0x20 = the 3000's "linked waveform" ability (-> AbilityMap node+0x3F, read by
	! ObtainLinkedWaveform on a track load / master change): the 3000 then fetches our track's waveform and draws
	! it in its WAVEFORM phase meter, moved by our 0x0b. Every send from boot, so it is set before load / master.
	! Only this bit (the 3000's other 0xCD bits are other abilities); DJMs / rekordbox / NXS2s never get it.
	mov.l	K_cur,r0
	mov.l	@r0,r0
	cmp/eq	#3,r0
	bf	1f
	mov.l	K_k0b,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	1f
	mov	#0x66,r0
	add	r0,r0
	add	#1,r0			! 0xCD
	mov.b	@(r0,r10),r1
	mov	#0x20,r2
	or	r2,r1
	mov.b	r1,@(r0,r10)
1:
	! COMPAT (work/compat/COMPAT_AUDIT.md): 0x124 stays 0 as in a stock NXS2's packet. On a CDJ-3000,
	! 0x124 bit 0 means "3000 extension valid" (): when it is set, the 3000 stops zeroing the
	! 3000-only fields of an NXS2 packet (0x27, 0x48.., 0x75.., 0xD0..) and trusts them. The key fields
	! 0x154..0x16C are read either way. 0x150 = the track BPM x 100 (from 0x92, BE), as a 3000 sends with
	! a track loaded (ldrh data+0x12C): without it a 3000's KEY SYNC to our master shows
	! UNAVAILABLE. No BPM (0xFFFF, no track) -> 0, as a 3000 with no track.
	mov.w	K_92,r0
	mov.b	@(r0,r10),r1		! BPM high byte
	add	#1,r0
	mov.b	@(r0,r10),r2		! BPM low byte
	mov	r1,r0
	cmp/eq	#-1,r0
	bt	1f
	mov.w	K_150,r0
	mov.b	r1,@(r0,r10)
	add	#1,r0
	mov.b	r2,@(r0,r10)
1:
	mov	#0x24,r0
	mov.b	@(r0,r10),r4		! this deck's player number
	bsr	kc_code
	extu.b	r4,r4
	mov	r0,r11			! r11 = the key code (0 none)
	! r12 = semitones: the fader's (MT off) + KEY SHIFT's
	mov	#0,r12
	mov	#0,r13
	mov.l	K_mt,r1
	mov.b	@r1,r0
	tst	r0,r0
	movt	r5			! r5 = 1: MASTER TEMPO off
	mov	#1,r0
	xor	r5,r0
	mov.w	K_158,r1
	add	r10,r1
	mov.b	r0,@r1			! 0x158 MASTER TEMPO
	tst	r5,r5
	bt	4f
	mov	#0x46,r0		! pitch at 0x8C (BE, 0x100000 = 0 %); CENTPOP: was `mov #0x8C,r0` = -116
	shll	r0			!   (sign-extended: read kx_buf - 116, so the fader semitones were garbage)
	mov.l	@(r0,r10),r1
	swap.b	r1,r1
	swap.w	r1,r1
	swap.b	r1,r1
	mova	K_semi,r0
	mov	#24,r3
	mov	#-12,r12
3:	mov.l	@r0+,r2
	cmp/hs	r2,r1
	bf	kx_fc
	dt	r3
	bf/s	3b
	add	#1,r12
kx_fc:	bsr	kx_fcent		! CENTPOP: r13 = the fader's cents left over the r12 semitones
	nop
4:	mov.l	K_base,r1		! CENTPOP: + our KEY SYNC cents while it is on (the engine's +40)
	mov	#48,r0
	mov.l	@(r0,r1),r0
	tst	r0,r0
	bt	45f
	mov.l	K_eng,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	45f
	mov.l	@(40,r1),r0
	add	r0,r13
	mov	#50,r2			! into -50..+49, the carry into the semitones (0x15C)
41:	cmp/ge	r2,r13
	bf	42f
	add	#-100,r13
	bra	41b
	add	#1,r12
42:	mov	#-50,r2
43:	cmp/ge	r2,r13
	bt	45f
	add	#100,r13
	bra	43b
	add	#-1,r12
45:	mov.w	K_163,r1		! 0x160 sounding cents, int32 BE (the 3000's)
	add	r10,r1
	mov	r13,r0
	mov.b	r0,@r1
	shlr8	r0
	mov.b	r0,@-r1
	shlr8	r0
	mov.b	r0,@-r1
	shlr8	r0
	mov.b	r0,@-r1
	mov.l	K_eng,r1		! KEY SHIFT
	mov.l	@r1,r0
	tst	r0,r0
	bt	5f
	mov.l	@(4,r1),r2		! V4n36a (A3): 0x15C excludes KEY SHIFT, as a CDJ-3000's
	mov	r2,r0			! 0x164 KEY SHIFT cents, int64 BE (low word 0x168)
	mov	#100,r3
	muls.w	r3,r0
	sts	macl,r0
	mov.w	K_16b,r1
	add	r10,r1
	mov.b	r0,@r1
	shlr8	r0
	mov.b	r0,@-r1
	shlr8	r0
	mov.b	r0,@-r1
	shlr8	r0
	mov.b	r0,@-r1
	cmp/pz	r2
	bt	5f
	mov	#-1,r0			! negative: 0x164..0x167 = FF (sign)
	mov.b	r0,@-r1
	mov.b	r0,@-r1
	mov.b	r0,@-r1
	mov.b	r0,@-r1
5:	mov.w	K_154,r1		! the keys (default 00 01 64 00 = none)
	add	r10,r1
	mov	r11,r0
	tst	r0,r0
	bf	6f
	mov	#1,r0
	mov.b	r0,@(1,r1)
	mov	#100,r0
	mov.b	r0,@(2,r1)
	mov	#1,r0
	mov.b	r0,@(9,r1)
	mov	#100,r0
	bra	8f
	mov.b	r0,@(10,r1)
6:	shlr	r0			! n = 1..12
	add	#4,r0
	mov	r0,r2
	shll2	r0
	shll	r0
	sub	r2,r0			! (n + 4) * 7
	mov	#12,r3
7:	cmp/hs	r3,r0
	bf/s	7f
	nop
	bra	7b
	sub	r3,r0
7:	mov	r0,r2			! r2 = b0: the relative major's tonic
	mov.b	r0,@r1
	mov	r11,r0
	and	#1,r0
	mov.b	r0,@(1,r1)		! b1: 1 = B (major)
	mov.b	r0,@(9,r1)
	mov	#1,r0
	mov.b	r0,@(3,r1)		! valid
	mov.b	r0,@(11,r1)
	mov	r2,r4			! COMPAT: b2 = the accidental of the key's name (-1 flat, 0, +1 sharp),
	bsr	kx_acc			! as a CDJ-3000 sends it (Ebm 06 00 FF 01, F#m 09 00 01 01, Gm 0A 00 00 01)
	nop
	mov.b	r0,@(2,r1)
	mov	r2,r0			! the sounding tonic: + r12 semitones, mod 12
	add	r12,r0
	add	#36,r0
	cmp/pz	r0
	bt	9f
	mov	#0,r0
9:	cmp/hs	r3,r0
	bf/s	9f
	nop
	bra	9b
	sub	r3,r0
9:	mov.b	r0,@(8,r1)
	mov	r0,r4			! COMPAT: the sounding key's accidental (0x15E)
	bsr	kx_acc
	mov	r0,r7			! (kx_acc uses r0, r5)
	mov.b	r0,@(10,r1)
	mov	r7,r0
	shll8	r2
	or	r2,r0
8:	mov.l	K_base,r1		! debug: kx_last = code << 16 | b0 << 8 | sounding b0; kx_cnt + 1
	add	#112,r1
	mov	r11,r2
	shll16	r2
	or	r2,r0
	mov.l	r0,@(4,r1)
	mov.l	@r1,r0
	add	#1,r0
	mov.l	r0,@r1
	mov.l	K_cur,r1		! COMPAT: 0x180 or 0x480 bytes
	mov.l	@r1,r1
	mov	#3,r2
	cmp/eq	r2,r1
	bf	kx_s2a
	bra	kx_s2
	mov	#0x12,r0		! 0x480 = 0x12 << 6
kx_s2a:	bra	kx_s2
	mov	#6,r0			! 0x180 = 6 << 6
kx_s2:	shll2	r0
	shll2	r0
	shll2	r0
	mov.l	r0,@r9
	mov	r10,r4
	mov	r9,r5
	mov.l	K_send,r0
	jsr	@r0
	nop
	mov.w	K_124,r1
	mov.l	r1,@r9			! the descriptor as it was
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	lds.l	@r15+,pr
	rts
	nop

! COMPAT kx_acc(r4 = the relative major's tonic 0..11, r11 = the key code: bit 0 = B major) -> r0 = the
! accidental of the key's rekordbox name (minor: Abm Ebm Bbm Fm Cm Gm Dm Am Em Bm F#m Dbm; major: B F# Db Ab
! Eb Bb F C G D A E): -1 flat, 0 natural, +1 sharp. Uses r0, r5 only (r5 = scratch).
kx_acc:
	mov	r11,r0
	and	#1,r0
	mov	r0,r5
	shll2	r5
	mov	r5,r0
	shll	r5
	add	r0,r5			! 0 or 12
	add	r4,r5
	mova	K_acc,r0
	rts
	mov.b	@(r0,r5),r0

	.p2align 2
K_acc:	.byte	0, -1, 0, 0, -1, 0, -1, 0, 0, 1, 0, -1	! minor, by the relative major's tonic C..B
	.byte	0, -1, 0, -1, 0, 0, 1, 0, -1, 0, -1, 0	! major, by its tonic C..B

	.p2align 1
K_124:	.short	0x124
K_180:	.short	0x180
K_92:	.short	0x92
K_150:	.short	0x150
K_154:	.short	0x154
K_158:	.short	0x158
K_16b:	.short	0x16B
K_163:	.short	0x163
K_dk:	.short	0x444B			! "DK"
	.p2align 2
K_boot:	.long	0x0A35DF3C
K_base:	.long	ks_base
K_hb:	.long	0x0B568C9C		! the heartbeat model
K_tab:	.long	0x0A371D3C + 0x28	! the LINK status table, + 0x28
K_kc:	.long	0x081E0000 + 0x1E0C0	! w8cap's key cache (RAMB + 0x1E0C0, mods/w8fetch/w8.inc KC)
K_mt:	.long	0x0B568C9C + 0x20	! heartbeat +0x20 (LE; the GUI's +0x23): MASTER TEMPO
K_eng:	.long	0x08122800		! the KEY SHIFT engine: +0 on, +4 semitones
K_send:	.long	0x085117CA		! stock UDP send (buffer, descriptor)
K_buf:	.long	kx_buf
K_cls:	.long	0x081E0000 + 0x1E848	! COMPAT: ks3k's class table (RAMB + 0x1E848 + player)
K_cur:	.long	kx_cur
K_k3:	.long	0x081E0000 + 0x1E800	! ks3k's table (RAMB + 0x1E800 + player * 8)
K_kyw:	.long	0x4B590080		! "KY", valid
K_k0b:	.long	KILLB + 28		! LINK0B: modsmenu kill_v +28, UTILITY LINK 0x0B (1 ON)
! 0x100000 * 2 ^ ((k + 0.5) / 12), k = -12..11: the pitch word's semitone thresholds
K_semi:	.long	0x83c03, 0x8b95c, 0x93e2a, 0x9cadd, 0xa5fed, 0xafddb, 0xba52d, 0xc5673
	.long	0xd1242, 0xdd93d, 0xeac0c, 0xf8b65, 0x107806, 0x1172b8, 0x127c53, 0x1395b9
	.long	0x14bfdb, 0x15fbb7, 0x174a5b, 0x18ace5, 0x1a2485, 0x1bb27a, 0x1d5819, 0x1f16ca
kx_cur:	.long	0			! COMPAT: this send's class (2 or 3)
kx_buf:	.space	0x480

! kx_fcent(r1 = the pitch word, 0x100000 = 0 %; r12 = its semitones, -12..12): r13 = the cents left,
! -50..+49 = the number of the 99 half-cent thresholds C * 2^((i - 49.5) / 1200) at or below r1, - 50,
! C = 0x100000 * 2^(r12 / 12) (CENTPOP; integer: dmulu.l Q20 x Q30). Clobbers r0, r2-r5, mach/macl.
kx_fcent:
	mov	r12,r0
	add	#12,r0
	shll2	r0
	mov.l	K_fsem,r2
	mov.l	@(r0,r2),r4
	mov.l	K_fthr,r5
	mov	#99,r3
	mov	#-50,r13
1:	mov.l	@r5+,r2
	dmulu.l	r4,r2
	sts	mach,r0
	sts	macl,r2
	shll2	r0
	shlr16	r2
	shlr8	r2
	shlr2	r2
	shlr2	r2
	shlr2	r2
	or	r2,r0
	cmp/hs	r0,r1
	bf	2f
	dt	r3
	bf/s	1b
	add	#1,r13
2:	rts
	nop
	.p2align 2
K_fsem:	.long	kx_fsem
K_fthr:	.long	kx_fthr
kx_fsem:		! 0x100000 * 2^(s / 12), s = -12..12
	.long	0x80000, 0x879c8, 0x8facd, 0x9837f, 0xa1451, 0xaadc1, 0xb504f, 0xbfc88
	.long	0xcb2ff, 0xd7450, 0xe411f, 0xf1a1c, 0x100000, 0x10f390, 0x11f59b, 0x1306fe
	.long	0x1428a3, 0x155b81, 0x16a09e, 0x17f911, 0x1965ff, 0x1ae8a0, 0x1c823e, 0x1e3438
	.long	0x200000
kx_fthr:		! Q30 2^((i - 49.5) / 1200), i = 0..98
	.long	0x3e322d5b, 0x3e3b6078, 0x3e4494f2, 0x3e4dcac8, 0x3e5701fb, 0x3e603a8b, 0x3e697478, 0x3e72afc3
	.long	0x3e7bec6b, 0x3e852a71, 0x3e8e69d5, 0x3e97aa97, 0x3ea0ecb7, 0x3eaa3036, 0x3eb37514, 0x3ebcbb50
	.long	0x3ec602ec, 0x3ecf4be7, 0x3ed89642, 0x3ee1e1fd, 0x3eeb2f17, 0x3ef47d92, 0x3efdcd6e, 0x3f071ea9
	.long	0x3f107146, 0x3f19c544, 0x3f231aa3, 0x3f2c7163, 0x3f35c985, 0x3f3f2309, 0x3f487dee, 0x3f51da36
	.long	0x3f5b37e1, 0x3f6496ee, 0x3f6df75e, 0x3f775931, 0x3f80bc67, 0x3f8a2101, 0x3f9386ff, 0x3f9cee60
	.long	0x3fa65725, 0x3fafc14f, 0x3fb92cdd, 0x3fc299d0, 0x3fcc0828, 0x3fd577e5, 0x3fdee907, 0x3fe85b8f
	.long	0x3ff1cf7d, 0x3ffb44d0, 0x4004bb8a, 0x400e33aa, 0x4017ad30, 0x4021281d, 0x402aa472, 0x4034222d
	.long	0x403da150, 0x404721da, 0x4050a3cd, 0x405a2727, 0x4063abe9, 0x406d3214, 0x4076b9a8, 0x408042a4
	.long	0x4089cd0a, 0x409358d8, 0x409ce611, 0x40a674b3, 0x40b004be, 0x40b99634, 0x40c32914, 0x40ccbd5f
	.long	0x40d65315, 0x40dfea35, 0x40e982c0, 0x40f31cb7, 0x40fcb81a, 0x410654e8, 0x410ff322, 0x411992c9
	.long	0x412333db, 0x412cd65b, 0x41367a47, 0x41401fa0, 0x4149c667, 0x41536e9b, 0x415d183d, 0x4166c34c
	.long	0x41706fca, 0x417a1db6, 0x4183cd11, 0x418d7dda, 0x41973012, 0x41a0e3b9, 0x41aa98d0, 0x41b44f56
	.long	0x41be074c, 0x41c7c0b2, 0x41d17b89


	.global	ks_end
ks_end:
