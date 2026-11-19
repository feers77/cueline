! SPDX-License-Identifier: GPL-2.0-or-later
!
! Real 3-band overview for the CDJ-2000NXS2 MAIN firmware (SH7724, SH-4,
! little-endian): the track's own PWV6 bands replace the colour preview in
! the overview payload the deck sends to the display.
!
! Hook: the publisher that copies the 600 six-byte preview records (3600
! bytes) into the link slot at 0x0B569528, run right after that copy, with
! the slot's lock still held. main_wave3data.s leaves the packed PWV6
! (600 x ABC, AB, A extents) behind a pointer at 0x081FFFFC while it is set
! and complete; with no pointer the stock records go out untouched.
!
! The records are three native halfwords each, which the display reads with
! the same values as its big-endian halfwords, so its byte k is byte k^1
! here. Each record becomes, as the display reads it: +0 ABC, +1 AB, +2 A
! (1..40 rows), +3 0x3B, +4 and +5 0xFF. In a stock record the +4 halfword
! starts with a height field, and 0xFFFF there would be 63 rows, past the
! strip renderer's own 40-row clamp, so the display takes it as the mark. The
! low nibble of the last byte is left as it was: the phrase mod keeps its
! colour there, and the display ignores it in the test for the mark.


.ifdef RGB3000
! q = num / s (r1), by subtraction; num is consumed.
	.macro	divq num, q
	mov	#0,\q
dqa_\@:	cmp/hs	r1,\num
	bf	dqb_\@
	sub	r1,\num
	bra	dqa_\@
	add	#1,\q
dqb_\@:
	.endm
! Recolour the native halfword at @r4 (uses r0-r3, r5, r7-r9).
	.macro	recol
	mov.w	@r4,r0
	extu.w	r0,r3
	mov	r3,r0
	shlr8	r0
	shlr2	r0
	shlr	r0			! R5
	shlr2	r0			! low 0..7
	mul.l	r0,r0
	sts	macl,r5			! low^2
	mov	r3,r0
	shlr2	r0
	shlr2	r0
	shlr	r0
	and	#63,r0			! G6
	shlr2	r0
	shlr	r0			! mid 0..7
	mul.l	r0,r0
	sts	macl,r7			! mid^2
	mov	r3,r0
	and	#31,r0			! B5
	shlr2	r0			! high 0..7
	mul.l	r0,r0
	sts	macl,r2			! high^2
	mov	r5,r1
	add	r7,r1
	add	r2,r1			! s
	tst	r1,r1
	bt	rce_\@			! no energy: the colour stays
	mov	#22,r0			! G6 = (low*22 + mid*40 + high*61) / s
	mul.l	r5,r0
	sts	macl,r8
	mov	#40,r0
	mul.l	r7,r0
	sts	macl,r0
	add	r0,r8
	mov	#61,r0
	mul.l	r2,r0
	sts	macl,r0
	add	r0,r8
	divq	r8, r9
	mov	r9,r3
	shll2	r3
	shll2	r3
	shll	r3			! G6 << 5
	mov	#31,r0			! B5 = (low*31 + mid*5 + high*31) / s
	mul.l	r5,r0
	sts	macl,r8
	mov	#5,r0
	mul.l	r7,r0
	sts	macl,r0
	add	r0,r8
	mov	#31,r0
	mul.l	r2,r0
	sts	macl,r0
	add	r0,r8
	divq	r8, r9
	or	r9,r3
	mov	#31,r0			! R5 = (mid*31 + high*29) / s
	mul.l	r7,r0
	sts	macl,r8
	mov	#29,r0
	mul.l	r2,r0
	sts	macl,r0
	add	r0,r8
	divq	r8, r9
	shll8	r9
	shll2	r9
	shll	r9			! R5 << 11
	or	r9,r3
	mov.w	r3,@r4
rce_\@:
	.endm
.endif

	.text
wave3ov:
	mov.l	p_shared,r1
	mov.l	@r1,r5			! packed PWV6, 0 or -1 when there is none
	cmp/pl	r5
	bf	out
	mov.l	p_slot,r4
	mov.l	p_600,r6
column:
	mov.b	@r5+,r0
	mov.b	r0,@(1,r4)		! ABC
	mov.b	@r5+,r0
	mov.b	r0,@r4			! AB
	mov.b	@r5+,r0
	mov.b	r0,@(3,r4)		! A
	mov	#0x3B,r0
	mov.b	r0,@(2,r4)
	mov	#-1,r0
	mov.b	r0,@(5,r4)
	mov.b	@(4,r4),r0		! the low nibble is the phrase mod's
	or	#0xF0,r0
	mov.b	r0,@(4,r4)
	add	#6,r4
	dt	r6
	bf	column
.ifdef RGB3000
	rts				! the 3-band records are done: nothing to recolour
	nop
.endif
out:
.ifdef RGB3000
! wave3ovrgb: no 3-band data -> the stock records' two RGB565 colours are
! recoloured to the CDJ-3000 RGB look (as ui3000x_wavergb / wave3rgb on the
! display): red = low, green = mid, blue = high, each cut to 0..7 and
! squared, blending low #005AFF, mid #FFA028, high #EBF5FF. The copy is
! fresh at every publish, so this never compounds. SH-4 has no divide: the
! quotients (<= 63) come from a subtraction loop. MACL is callee-saved here.
	mov.l	r2,@-r15		! only r0, r1, r4-r6 are the stock routine's to use
	mov.l	r3,@-r15
	mov.l	r7,@-r15
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	sts.l	macl,@-r15
	mov.l	p_slot,r4
	mov.l	p_600,r6
3:	recol				! +0: the record's first colour
	add	#2,r4
	recol				! +2: its second colour
	add	#4,r4			! (+4: the heights, left alone)
	dt	r6
	bt	4f
	bra	3b
	nop
4:
	lds.l	@r15+,macl
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	mov.l	@r15+,r7
	mov.l	@r15+,r3
	rts
	mov.l	@r15+,r2
.else
	rts
	nop
.endif

	.p2align 2
p_shared:	.long 0x081FFFFC
p_slot:		.long 0x0B569528
p_600:		.long 600
