! SPDX-License-Identifier: Apache-2.0
!
! 32-bit WAV playback, part 6 of 6: right after the play path's fread
! (0x082D633C; r6 = bytes read, also kept at @(8,sp)). For a marked file the
! 4-byte samples in the buffer (r12) are packed in place to 3-byte 24-bit
! little-endian ones: an integer keeps its top 3 bytes, a float is scaled by
! 2^23 and clipped. The byte count read and the one asked for (r14) both
! become 3/4 of themselves, so the function's own "short read" test holds.
! Hook: r4 = saved r0-r7, r5 = the site's sp; r12 = buffer, r13 = file
! object, r14 = bytes asked for (all live).

	.include "layout.inc"

	.text
wav32rdend:
	mov.l	@r13,r1			! FILE *
	mov.l	e_act,r2
	add	#4,r2
	mov	#4,r3
1:	mov.l	@r2,r0
	cmp/eq	r0,r1
	bt	2f
	add	#8,r2
	dt	r3
	bf	1b
	rts
	nop
2:	mov.l	@(4,r2),r7		! format: 1 int32, 3 float32
	mov.l	@(24,r4),r6		! bytes read
	shlr2	r6			! samples
	mov	r6,r0			! new count = samples * 3
	add	r0,r0
	add	r6,r0
	mov.l	r0,@(24,r4)		! saved r6
	mov.l	r0,@(8,r5)		! the function's copy
	mov	r14,r0			! asked for: / 4 * 3
	shlr2	r0
	mov	r0,r1
	add	r0,r0
	add	r1,r0
	mov	r0,r14
	mov	r12,r1			! src
	mov	r12,r2			! dst
	tst	r6,r6
	bt	9f
	mov	r7,r0
	cmp/eq	#3,r0
	bt	5f
3:	mov.b	@(1,r1),r0		! int32 LE: keep bytes 1..3
	mov.b	r0,@r2
	mov.b	@(2,r1),r0
	mov.b	r0,@(1,r2)
	mov.b	@(3,r1),r0
	mov.b	r0,@(2,r2)
	add	#4,r1
	dt	r6
	bf/s	3b
	add	#3,r2
9:	rts
	nop
5:	mov.b	@(3,r1),r0		! float32 LE -> int24
	shll8	r0
	mov	r0,r3
	mov.b	@(2,r1),r0
	extu.b	r0,r0
	or	r0,r3
	shll8	r3
	mov.b	@(1,r1),r0
	extu.b	r0,r0
	or	r0,r3
	shll8	r3
	mov.b	@r1,r0
	extu.b	r0,r0
	or	r0,r3			! r3 = the IEEE bits
	mov	r3,r7
	shll	r7
	shlr16	r7
	shlr8	r7			! exponent
	mov	#127,r0
	sub	r7,r0			! shift = 127 - exponent
	cmp/pl	r0
	bf	6f			! |v| >= 1: clip
	mov	#24,r7
	cmp/ge	r7,r0
	bt	7f			! tiny: 0
	mov	r3,r7			! (1.mantissa) << 8, top bit set
	shll8	r7
	shll	r7
	sett
	rotcr	r7
	add	#8,r0
	neg	r0,r0
	shld	r0,r7			! >> (shift + 8): 0 .. 0x7FFFFF
	bra	8f
	nop
6:	mov.l	e_max,r7
	bra	8f
	nop
7:	mov	#0,r7
8:	cmp/pz	r3
	bt	4f
	neg	r7,r7
4:	mov	r7,r0
	mov.b	r0,@r2
	shlr8	r0
	mov.b	r0,@(1,r2)
	shlr8	r0
	mov.b	r0,@(2,r2)
	add	#4,r1
	dt	r6
	bf/s	5b
	add	#3,r2
	rts
	nop

	.p2align 2
e_act:		.long RAMB+0x1FF48
e_max:		.long 0x007FFFFF
