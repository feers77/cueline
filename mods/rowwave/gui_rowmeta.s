! SPDX-License-Identifier: Apache-2.0
!
! rowmeta (GUI, SH-2A): the browse rows' right-hand text -- file type, BPM,
! key and duration of a TRACK row, written by MAIN (mods/rowwave) as UTF-16
! after the row's title in the slot text (slot text + 0x1A0, carried to the
! GUI's copy R = 0x0E5B82F0 by the stock 0x39 message).
!
! Replaces FUN_0e51e67a, the list redraw's number-column text (called through
! the literal at 0x0E5208D0; the rowmeta poke turns the number column on for
! the artwork layout C7). In: r4 = first index + 1, r5 = row k (0-7).
! Out: r0 = the UTF-16 string the column shows.
!   - meta present: the column (widget 0x62 - 4k) moves to the row's right
!     end, x 520..760 (scene), and shows it;
!   - none but a row with our artwork cell (has_art, a rowwave row whose meta
!     is not in yet): empty, at the stock place;
!   - otherwise: the stock number column, at the stock place.
	.equ	OFF, 0x1A0
	.text
rowmeta:
	sts.l	pr,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	bsr	curbar			! once: a 752-px cursor bar for the artwork lists
	nop
	mov	r5,r2
	add	#1,r2
	mov.w	k220,r0
	mulr	r0,r2			! r2 = (k + 1) * 0x220
	mov.l	base,r0
	add	r2,r0			! r0 = R.slot[k + 1] + 0x2A + OFF
	mov.w	@r0,r1
	tst	r1,r1
	bt	1f
	mov.l	r0,@-r15		! meta: the column at the row's right end
	mov.w	mx0,r6
	mov.w	mx1,r7
	bsr	place
	nop
	mov.l	@r15+,r0
	bra	9f
	nop
1:	mov.w	sx0,r6			! no meta: the stock place
	mov.w	sx1,r7
	bsr	place
	nop
	mov.l	@(4,r15),r5		! (r5, the row, from the stack)
	add	#1,r5
	mov.w	k220,r0
	mulr	r0,r5
	mov.l	slots,r0
	add	r5,r0
	mov.b	@(0x1c,r0),r0		! has_art: a rowwave row, meta not in yet
	cmp/eq	#1,r0
	bf	2f
	mova	empty,r0
	bra	9f
	nop
2:	mov.l	@r15+,r5		! a stock list: the stock number
	mov.l	@r15+,r4
	lds.l	@r15+,pr
	mov.l	stock,r1
	jmp	@r1
	nop
9:	mov.l	@r15+,r5
	mov.l	@r15+,r4
	lds.l	@r15+,pr
	rts
	nop

! curbar: the artwork lists' cursor bar (resource 0x52F, 672x30). rowcell's
! poke of table B starts it at the row's left edge (scene x 12), so the
! whole row -- artwork and waveform cell included -- is highlighted as on the
! CDJ-3000; to reach the scene's right edge (764) it must be 752 px wide.
! Once, copy it stretched to 752 px (nearest column, src = c * 57 / 64 < 672)
! into free on-chip RAM (CB_BUF: after our routines and before the VDC frame
! buffers at 0x1C080000; seen unused) and point the resource there: width at
! +4, pixel offset (from the resource base) at +0x20 -- the GUI derives the
! pointer and the line pitch from those. Clobbers r0-r3, r6, r7.
	.equ	CB_W, 752
curbar:
	mov.l	r4,@-r15
	mov.l	cb_done,r1
	mov.l	@r1,r0
	mov.l	cb_magic,r2
	cmp/eq	r2,r0
	bt	9f
	mov.l	r2,@r1
	mov.l	resptr,r1
	mov.l	@r1,r3			! r3 = resource base
	mov.l	res52f,r0
	add	r3,r0
	mov	r0,r7			! r7 = its record
	mov.l	@(0x20,r7),r1
	add	r3,r1			! r1 = its pixels (672 per line)
	mov.l	cb_buf,r2
	mov	#30,r6
1:	mov	#0,r3			! one line: 752 pixels, column r3
2:	mov	r3,r4
	mov	#57,r0
	mulr	r0,r4			! r4 = c * 57
	mov	r4,r0
	shlr2	r0
	shlr2	r0
	shlr2	r0			! src column = c * 57 / 64
	shll	r0
	mov.w	@(r0,r1),r4
	mov.w	r4,@r2
	add	#2,r2
	add	#1,r3
	mov.w	cb_w,r0
	cmp/hs	r0,r3
	bf	2b
	mov.w	cb_src,r0
	dt	r6
	bf/s	1b
	add	r0,r1
	mov.w	cb_w,r0
	mov.w	r0,@(4,r7)		! width
	mov.l	cb_buf,r0
	mov.l	resptr,r1
	mov.l	@r1,r1
	sub	r1,r0
	mov.l	r0,@(0x20,r7)		! pixels
9:	rts
	mov.l	@r15+,r4
cb_w:	.word	CB_W
cb_src:	.word	672 * 2
	.p2align 2
cb_done: .long	0x1C06FFFC		! "done" marker, just below the copy
cb_magic: .long	0x43555242		! "CURB"
cb_buf:	.long	0x1C070000		! 752 x 30 x 2 = 45120 bytes (< 0x1C080000)

! place: widget 0x62 - 4k (r5 = k) to x r6..r7.
place:
	sts.l	pr,@-r15
	mov.l	r7,@-r15
	shll2	r5
	mov	#0x62,r0
	sub	r5,r0
	mov	r0,r5			! widget id
	mov.l	r5,@-r15
	mov.l	scene,r4
	mov.l	@r4,r4
	mov.l	setleft,r1
	jsr	@r1
	nop
	mov.l	@r15+,r5
	mov.l	@r15+,r6
	mov.l	scene,r4
	mov.l	@r4,r4
	mov.l	setright,r1
	jsr	@r1
	nop
	lds.l	@r15+,pr
	rts
	nop

k220:	.word	0x220
mx0:	.word	520
mx1:	.word	760
sx0:	.word	15
sx1:	.word	95
	.p2align 2
empty:	.word	0, 0
base:	.long	0x0E5B82F0 + 0x2A + OFF	! R: the GUI's copy of the row slots
slots:	.long	0x0E5B82F0
scene:	.long	0x0E59FC48		! -> the browse scene
setleft: .long	0x1C00299E		! SetLeft(scene, id, x)
setright: .long	0x1C0029C2		! SetRight(scene, id, x)
stock:	.long	0x0E51E67A		! the stock number-column text
resptr:	.long	0x0E598F6C		! -> the resource table (RAM)
res52f:	.long	0x52F * 0x2C		! its record there (a mov.w would sign-extend)
