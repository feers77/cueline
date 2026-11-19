! SPDX-License-Identifier: Apache-2.0
!
! 32-bit WAV playback, part 3 of 6: the play path's file object, built at
! 0x082F1940 from the track descriptor (fo +4 data offset, +8 data length,
! +12 trailing bytes, from desc +20/+24/+28). For a track wav32data recorded
! (same data offset and file size), the object gets the REAL data length
! (4/3 of the presented one) and trailing count, so the deck's own bounds
! and end-of-file checks see the real file, and the file handle is marked
! (+0x48 ring index, +0x4C four {FILE *, format}) for the read/seek hooks.
! Hook: r4 = saved r0-r7 (r2 = the file object, r7 = the descriptor).

	.include "layout.inc"

	.text
wav32fo:
	mov.l	@(8,r4),r2		! file object
	mov.l	@(28,r4),r7		! descriptor
	mov.l	@(20,r7),r5		! data offset
	mov.l	@(24,r7),r6		! presented length
	mov.l	@(28,r7),r3
	add	r5,r3
	add	r6,r3			! file size
	mov.l	o_base,r1
	add	#8,r1
	mov	#4,r4
1:	mov.l	@r1,r0
	cmp/eq	r0,r5
	bf	2f
	mov.l	@(4,r1),r0
	cmp/eq	r0,r3
	bf	2f
	mov.l	@(8,r1),r0
	cmp/eq	#1,r0
	bt	3f
	cmp/eq	#3,r0
	bt	3f
2:	add	#16,r1
	dt	r4
	bf	1b
	mov.l	@r2,r3			! not a 32-bit track: drop any mark left on
	mov.l	o_act,r1		! this FILE * by an earlier one
	add	#4,r1
	mov	#4,r4
	mov	#0,r5
4:	mov.l	@r1,r0
	cmp/eq	r0,r3
	bf	5f
	mov.l	r5,@r1
5:	add	#8,r1
	dt	r4
	bf	4b
	rts
	nop
3:	mov	r0,r4			! r4 = format
	mov	r6,r0			! real length = presented / 3 * 4
	mov.l	o_third,r1
	dmulu.l	r1,r0
	sts	mach,r0
	shlr	r0
	shll2	r0
	mov.l	r0,@(8,r2)
	sub	r5,r3			! real trailing = size - offset - real length
	sub	r0,r3
	mov.l	r3,@(12,r2)
	mov.l	o_act,r1		! mark the FILE *: {idx, 4 x {FILE *, format}}
	mov.l	@r1,r0
	add	#1,r0
	mov.l	r0,@r1
	and	#3,r0
	shll2	r0
	shll	r0
	add	r1,r0
	add	#4,r0
	mov.l	@r2,r3
	mov.l	r3,@r0
	rts
	mov.l	r4,@(4,r0)

	.p2align 2
o_base:		.long RAMB+0x1FF00
o_act:		.long RAMB+0x1FF48
o_third:	.long 0xAAAAAAAB	! x / 3 = (x * this) >> 33
