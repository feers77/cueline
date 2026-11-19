! SPDX-License-Identifier: Apache-2.0
!
! 32-bit WAV playback, part 4 of 6: the play path's seek (0x082D61C4,
! r4 = file object, r5 = offset, r6 = whence). Offsets come in the 24-bit
! stream's bytes (whole 1/75 s blocks, so multiples of 3); for a marked file
! they become the real file's: offset / 3 * 4. Hook on the entry: r4 =
! saved r0-r7.

	.include "layout.inc"

	.text
wav32seek:
	mov.l	@(16,r4),r1		! file object
	mov.l	@r1,r1			! FILE *
	mov.l	s_act,r2
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
2:	mov.l	@(20,r4),r0		! offset (signed)
	cmp/pz	r0
	bt	3f
	neg	r0,r0
3:	mov.l	s_third,r1
	dmulu.l	r1,r0
	sts	mach,r1
	shlr	r1
	shll2	r1			! |offset| / 3 * 4
	mov.l	@(20,r4),r0
	cmp/pz	r0
	bt	4f
	neg	r1,r1
4:	rts
	mov.l	r1,@(20,r4)

	.p2align 2
s_act:		.long RAMB+0x1FF48
s_third:	.long 0xAAAAAAAB
