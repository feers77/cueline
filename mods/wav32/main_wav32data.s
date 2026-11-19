! SPDX-License-Identifier: Apache-2.0
!
! 32-bit WAV playback, part 2 of 6: the WAV parser's chunk walk, where it
! compares a chunk id with "data" (0x08348F8A). For a source wav32fmt marked
! as 32-bit, the data chunk's size (stack +36) becomes 3/4 of itself, so the
! duration, sample count and block count all describe the 24-bit stream the
! deck will be fed; the track is recorded (data offset, file size, format)
! for wav32fo. Reproduces the replaced code: r0 = 76, r10, the frame stores,
! r1 = the "data" id pointer, r4 = the chunk id, r2 = "data".
!
! Shared block 0x081FFF00: +0 format of the file being parsed, +4 ring
! index, +8 four records {data offset, file size, format, 0}.

	.include "layout.inc"

	.text
wav32data:
	mov	#64,r0
	mov.l	r11,@(28,r15)
	mov.l	@(r0,r15),r10
	mov	#76,r0
	mov.l	r14,@(r0,r15)
	mov.l	@(20,r15),r4		! chunk id
	mov.l	d_dataid,r1
	mov.l	@r1,r2			! "data"
	cmp/eq	r2,r4
	bf	9f
	mov.l	d_base,r1
	mov.l	@r1,r0			! source format: 1 int32, 3 float32
	cmp/eq	#1,r0
	bt	1f
	cmp/eq	#3,r0
	bf	9f
1:	mov.l	r3,@-r15
	mov.l	r5,@-r15
	mov	r0,r5			! r5 = format
	mov	#0,r0
	mov.l	r0,@r1			! consumed
	mov.l	@(44,r15),r0		! size (+36, past the two pushes)
	shlr2	r0
	mov	r0,r3
	add	r0,r0
	add	r3,r0			! size / 4 * 3
	mov.l	r0,@(44,r15)
	mov.l	@(4,r1),r0		! record {offset, file size, format}
	add	#1,r0
	mov.l	r0,@(4,r1)
	and	#3,r0
	shll2	r0
	shll2	r0
	add	r1,r0
	add	#8,r0			! r0 = the record
	mov.l	@(32,r15),r3		! offset = chunk base + position + 8
	mov.l	@(36,r15),r2		! (+24, +28 past the pushes)
	add	r2,r3
	add	#8,r3
	mov.l	r3,@r0
	mov.l	@(40,r15),r3		! obj (+32); file size at obj + 4
	mov.l	@(4,r3),r3
	mov.l	r3,@(4,r0)
	mov.l	r5,@(8,r0)
	mov.l	@r15+,r5
	mov.l	@r15+,r3
	mov.l	@(20,r15),r4		! restore what the replaced code leaves
	mov.l	d_dataid,r1
	mov.l	@r1,r2
9:	rts
	mov	#76,r0

	.p2align 2
d_dataid:	.long 0xA80B0404	! the parser's "data" id
d_base:		.long RAMB+0x1FF00
