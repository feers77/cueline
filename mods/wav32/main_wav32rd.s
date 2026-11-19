! SPDX-License-Identifier: Apache-2.0
!
! 32-bit WAV playback, part 5 of 6: the play path's read (0x082D62AC,
! r4 = file object, r5 = buffer, r6 = bytes). For a marked file it asks the
! real file for 4/3 as many bytes (whole samples: the count is a multiple of
! 3); wav32rdend packs them back to 3 bytes a sample. Hook on the entry:
! r4 = saved r0-r7.

	.include "layout.inc"

	.text
wav32rd:
	mov.l	@(16,r4),r1		! file object
	mov.l	@r1,r1			! FILE *
	mov.l	r_act,r2
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
2:	mov.l	@(24,r4),r0		! bytes / 3 * 4
	mov.l	r_third,r1
	dmulu.l	r1,r0
	sts	mach,r0
	shlr	r0
	shll2	r0
	rts
	mov.l	r0,@(24,r4)

	.p2align 2
r_act:		.long RAMB+0x1FF48
r_third:	.long 0xAAAAAAAB
