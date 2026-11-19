! SPDX-License-Identifier: Apache-2.0
!
! 32-bit WAV playback, part 1 of 6: the WAV parser's fmt chunk. The deck
! accepts only PCM (tag 1) at 16 or 24 bits; this presents a 32-bit integer
! or float file (tag 1, 3, or EXTENSIBLE 0xFFFE with sub-format 1 or 3) as
! 24-bit PCM by rewriting the fmt chunk in the parser's own read buffer, and
! leaves the source format in the shared block (0x081FFF00 = 1 int32, 3
! float32, else 0) for wav32data. EXTENSIBLE 16/24-bit PCM is accepted too.
! The other parts scale the data length (wav32data), fix the file object
! (wav32fo) and convert at read/seek time (wav32seek, wav32rd, wav32rdend).
!
! Replaces the tag fetch at 0x08348D50; out r6 = tag, r0 = 1 when playable.
! In: r12 = the fmt chunk's data. Only r0, r1, r2, r6 change.

	.include "layout.inc"

	.text
wav32fmt:
	mov.l	f_flags,r1
	mov	#0,r0
	mov.l	r0,@r1			! no 32-bit source (yet)
	mov.b	@(9,r12),r0
	extu.b	r0,r6
	mov.b	@(8,r12),r0
	shll8	r6
	extu.b	r0,r2
	add	r2,r6
	extu.w	r6,r6			! format tag
	mov.l	f_kill,r1		! WAV 32-BIT off (its kill word "NOMO", set by
	mov.l	@r1,r1			! the TchAud task from C:/NOMODS or UTILITY >
	mov.l	f_nomo,r2		! MODS / WAV 32-BIT): the stock tag, as stock
	cmp/eq	r2,r1
	bt	9f
	mov.w	f_ext,r2
	extu.w	r2,r2
	cmp/eq	r2,r6
	bf/s	1f
	mov	r6,r1			! r1 = the effective tag
	mov	r12,r2			! EXTENSIBLE: sub-format GUID's first u16 @24
	add	#24,r2
	mov.b	@(1,r2),r0
	extu.b	r0,r1
	shll8	r1
	mov.b	@r2,r0
	extu.b	r0,r0
	or	r0,r1
1:	mov	r12,r2			! bits @22
	add	#22,r2
	mov.b	@r2,r0
	extu.b	r0,r0
	cmp/eq	#32,r0
	bt	3f
	mov.w	f_ext,r0		! not 32-bit: EXTENSIBLE PCM -> plain PCM
	extu.w	r0,r0
	cmp/eq	r0,r6
	bf	9f
	mov	r1,r0
	cmp/eq	#1,r0
	bt	8f
	bra	9f
	nop
3:	mov	r1,r0			! 32-bit integer or float
	cmp/eq	#1,r0
	bt	4f
	cmp/eq	#3,r0
	bf	9f			! anything else: refused as before
	bra	5f
	mov	#3,r0
4:	mov	#1,r0
5:	mov.l	f_flags,r1
	mov.l	r0,@r1
	mov	#24,r0			! present it as 24-bit
	mov.b	r0,@r2
	mov	#0,r0
	mov.b	r0,@(1,r2)
8:	mov	#1,r0			! as PCM
	mov.b	r0,@(8,r12)
	mov	#0,r0
	mov.b	r0,@(9,r12)
	mov	#1,r6
9:	rts
	mov	r6,r0

f_ext:		.word 0xFFFE
	.p2align 2
f_kill:		.long RAMB+0x1F7E8
f_nomo:		.long 0x4F4D4F4E	! "NOMO"
f_flags:	.long RAMB+0x1FF00
