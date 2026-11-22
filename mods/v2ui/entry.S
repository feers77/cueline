! SPDX-License-Identifier: Apache-2.0
! V2 UI entries, a fixed jump table at the blob start (v2ui.py relies on it):
!   +0  paint:  chained in front of the VDC base write 0x0E526626 (r4 = plane,
!               r5 = frame base) -- the stock flip's literals 0x0E50923C /
!               0x0E508D1C, or gr3direct's l_vdcset. Paints our screen into the
!               finished frame, then runs the stock write.
!   +4  draw:   the draw-callback dispatcher's RAM API slot 0x1C001240
!               (r4 = window); a window we own this frame is not drawn by
!               stock (return 0), any other goes on to the previous target.
!   +8  rect:   the per-frame clear's rect-fill literal 0x0E50AB50 (r4 = surface
!               descriptor); same rule.
!   +16 blit:   the CPU image blit's literal 0x0E50ADB8 (r4 = surface descriptor);
!               rule as rect (P9: stock blitted list backgrounds/icons into the
!               surfaces of windows we own -- invisible work)
!   +20 text1 / +24 text2: the text renderers' RAM table slots 0x1C0008D0 /
!               0x1C0008E0 (r4 = window); a window we own is not rendered: its
!               +116/+120 are zeroed as the renderer does first, return 1
!   +28 sleep:  the stock flip's sleep literal 0x0E509230 (r4 = ms, r12 = the flip's GR3
!               descriptor): on a screen we own, its first sleep(1) of the vsync wait paints
!               and programs the base early (taken at the vsync the flip waits for); the
!               flip's own base write afterwards is then skipped (paint returns 1)
!   +12 wave:   the frame's direct call of the stock centre-waveform renderer
!               0x1C009AB4 (literal 0x1C00B268, `jsr/n`, no arguments): while
!               we own the player screen with a track loaded our own waveform
!               replaces it (return at once), else the stock renderer runs.
! l_prevdraw / l_prevrect / l_prevwave: the previous targets, right after the "V2PR"
! marker in the literal pool below, filled by v2ui.py.
! MACH/MACL are callee-saved in this firmware's ABI, not in gcc's: saved here.
	.section .text.entry,"ax"
	.global v2_entry
v2_entry:
	bra	paint_e
	nop
	bra	draw_e
	nop
	bra	rect_e
	nop
	bra	wave_e
	nop
	bra	blit_e
	nop
	bra	text1_e
	nop
	bra	text2_e
	nop
	bra	sleep_e
	nop
	bra	comp_e
	nop

! +32 comp: the flush's window loop (F2, re/V2_OVERLAYS.md "the compose gate"). Stock at 0x0E509A1C:
!		bld.b #3,@(7,r14) ; bf.s next ; mov #0,r13 ; mov.l @(28,r14),r10 ; mov r14,r11
!	(r14 = the window; bit 3 of +7 = "composited"). v2ui.py replaces those 12 bytes by a jump here. A
!	window stock would compose is composed only if v2_compose_hide() says it is not one we keep off the
!	screen we own -- asked at the moment of composing, so a window born this very frame (its surface never
!	drawn: white / garbage on the deck) can no longer reach the panel before manage() has seen it.
!	r0-r7 are dead here in stock (all reloaded after 0x0E509A28 / 0x0E509AA8).
comp_e:					! (stock's own bit test is in v2_compose_hide: every window
	sts.l	pr,@-r15		!  of the loop comes through, so the call is also our tick)
	sts.l	mach,@-r15
	sts.l	macl,@-r15
	mov.l	l_chide,r0
	jsr	@r0
	mov	r14,r4
	lds.l	@r15+,macl
	lds.l	@r15+,mach
	lds.l	@r15+,pr
	tst	r0,r0
	bf	comp_skip
	mov	#0,r13
	mov.l	@(28,r14),r10
	mov.l	l_cgo,r0
	jmp	@r0
	mov	r14,r11
comp_skip:
	mov.l	l_cskip,r0
	jmp	@r0
	mov	#0,r13

paint_e:
	sts.l	pr,@-r15
	sts.l	mach,@-r15
	sts.l	macl,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	mov.l	l_paint,r0
	jsr	@r0
	nop
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	lds.l	@r15+,macl
	lds.l	@r15+,mach
	lds.l	@r15+,pr
	tst	r0,r0
	bf	2f			! programmed early already: the repeat would re-arm the latch
	mov.l	l_vdc,r0
	jmp	@r0
	nop
2:	rts
	mov	#0,r0

sleep_e:
	sts.l	pr,@-r15
	sts.l	mach,@-r15
	sts.l	macl,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	mov	r12,r5			! the flip's GR3 descriptor (+12 = the buffer it shows next)
	mov.l	l_fsleep,r0
	jsr	@r0
	nop
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	lds.l	@r15+,macl
	lds.l	@r15+,mach
	lds.l	@r15+,pr
	mov.l	l_sleep,r0
	jmp	@r0
	nop

blit_e:
	mov.l	l_bskip,r0
	mov.l	l_prevblit,r1
	bra	filt2
	nop
text1_e:
	mov.l	l_tskip,r0
	mov.l	l_prevtxt1,r1
	bra	filt2
	nop
text2_e:
	mov.l	l_tskip,r0
	mov.l	l_prevtxt2,r1
! r0 = C filter (returns 1 = skip), r1 = the previous target; skip returns r0 = 1 (text drawn /
! blit result unused)
filt2:
	sts.l	pr,@-r15
	sts.l	mach,@-r15
	sts.l	macl,@-r15
	mov.l	r1,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	jsr	@r0
	nop
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	mov.l	@r15+,r1
	lds.l	@r15+,macl
	lds.l	@r15+,mach
	lds.l	@r15+,pr
	tst	r0,r0
	bf	1f
	jmp	@r1
	nop
1:	rts
	mov	#1,r0

! r4 = window (draw) or surface descriptor (rect); C returns 1 = skip.
draw_e:
	mov.l	l_dskip,r0
	bra	filt
	nop
rect_e:
	mov.l	l_rskip,r0
filt:
	sts.l	pr,@-r15
	sts.l	mach,@-r15
	sts.l	macl,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	mov.l	r0,@-r15		! which previous target (0 draw, else rect) -- kept below
	jsr	@r0
	nop
	mov.l	@r15+,r1		! the filter we called
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	lds.l	@r15+,macl
	lds.l	@r15+,mach
	lds.l	@r15+,pr
	tst	r0,r0
	bf	skip
	mov.l	l_dskip,r2
	cmp/eq	r1,r2
	bf	1f
	mov.l	l_prevdraw,r0
	jmp	@r0
	nop
1:	mov.l	l_prevrect,r0
	jmp	@r0
	nop
skip:	rts
	mov	#0,r0

wave_e:
	sts.l	pr,@-r15
	sts.l	mach,@-r15
	sts.l	macl,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	mov.l	l_wskip,r0
	jsr	@r0
	nop
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	lds.l	@r15+,macl
	lds.l	@r15+,mach
	lds.l	@r15+,pr
	tst	r0,r0
	bf	1f
	mov.l	l_prevwave,r0
	jmp	@r0
	nop
1:	rts
	nop

	.align	2
l_paint:	.long	v2_paint
l_dskip:	.long	v2_draw_skip
l_rskip:	.long	v2_rect_skip
l_wskip:	.long	v2_wave_skip
l_bskip:	.long	v2_blit_skip
l_tskip:	.long	v2_text_skip
l_vdc:		.long	0x0E526626
l_sleep:	.long	0x0E52EA70
l_fsleep:	.long	v2_flip_sleep
l_chide:	.long	v2_compose_hide
l_cgo:		.long	0x0E509A28		! the loop body, after the five replaced instructions
l_cskip:	.long	0x0E509AA8		! the loop's next window
		.long	0x56325052		! "V2PR"
l_prevdraw:	.long	0
l_prevrect:	.long	0
l_prevwave:	.long	0
l_prevblit:	.long	0
l_prevtxt1:	.long	0
l_prevtxt2:	.long	0
