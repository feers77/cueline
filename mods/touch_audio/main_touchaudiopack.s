! SPDX-License-Identifier: Apache-2.0
!
! touchaudiopack: the preview strip gets into a frame while the deck plays.
!
! The MAIN -> GUI frame packer (FUN_0838E85E, once a frame) packs the status,
! then -- when the player "model" is dirty, which is nearly every frame while
! a track plays -- the model message, and skips EVERYTHING else that frame
! (bf.s at 0x0838EB90): the overview strip (0x0838FF2E, message 0x35, 0xE50
! bytes) among them. So a strip our task armed (tp_draw) only reaches the
! display once the deck pauses. The frame has room for both (status 0x22C +
! model 0x26DC + 0x7C0 + strip 0xE50 = 0x3F18 of 0x3FFC).
!
! This replaces the eight words at 0x0838EB7A: the lock release that follows
! the dirty computation (`sts fpscr,r1; mov.l @(4,r15),r4; and r14,r1; jsr
! @r12 (0x08404A5E); lds r1,fpscr; sts fpscr,r2; mov.b @(12,r15),r0; mov
! r0,r4`), repeats it, and -- when the frame is dirty, our strip is pending
! (owner word RAMB+0x1F7F8 = 1, arm 0x0A35F3F0 = 1) -- calls the strip
! packer first, before the model message. 0x0838FF2E takes no arguments,
! checks the room itself, consumes the arm and charges the budget; r0-r7,
! pr and macl are its only state. On a clean frame the stock call later in
! the sequence finds the arm consumed and does nothing. Frames in modes 0/2
! never reach this span (no strip there either, as stock).
!
! Contract (sigpatch call_site, hook=False): entered by jsr with r15 = the
! packer's frame (@(4,r15) = the lock token, @(12,r15) = the dirty byte, both
! +4 once pr is pushed), r12 = 0x08404A5E (loaded at 0x0838EB5C, unused
! after), r14 = the fpscr mask. Must leave r2 = fpscr, r0 = r4 = dirty, as
! the replaced words did; r8-r14 kept.

	.include "layout.inc"

	.text
	.global touchaudiopack
touchaudiopack:
	sts.l	pr,@-r15		! frame now: token @(8,r15), dirty @(16,r15)
	sts	fpscr,r1
	mov.l	@(8,r15),r4
	and	r14,r1
	jsr	@r12			! the stock release of the lock
	lds	r1,fpscr
	mov.l	pk_boot,r1		! V3rc3: only on a normal boot (0x0A35DF3C == 1): in update mode
	mov.l	@r1,r0			! exactly the replaced stock words (the update stream, packer mode 2,
	cmp/eq	#1,r0			! never reaches this span anyway)
	bf	9f
	mov	r15,r3
	add	#16,r3
	mov.b	@r3,r0			! dirty? (the model message would eat the frame)
	tst	r0,r0
	bt	9f
	mov.l	pk_owner,r1		! our preview strip in the slot?
	mov.l	@r1,r1
	tst	r1,r1
	bt	9f
	mov.l	pk_arm,r1		! and a send pending?
	mov.l	@r1,r1
	tst	r1,r1
	bt	9f
	sts	fpscr,r1
	and	r14,r1
	mov.l	pk_strip,r2		! the strip packer, before the model
	jsr	@r2
	lds	r1,fpscr
	mov.l	pk_cnt,r1		! FORCED++ (counters +0x44)
	mov.l	@r1,r2
	add	#1,r2
	mov.l	r2,@r1
9:	sts	fpscr,r2
	mov	r15,r3
	add	#16,r3
	mov.b	@r3,r0			! r0 = r4 = dirty, as the replaced words left them
	mov	r0,r4
	lds.l	@r15+,pr
	rts
	nop

	.p2align 2
pk_owner:	.long RAMB+0x1F7F8	! 1 while our waveform is in the strip
pk_arm:		.long 0x0A35F3F0	! the sender armed (tp_unlock)
pk_strip:	.long 0x0838FF2E	! the strip packer (mono 0x34 / colour 0x35)
pk_cnt:		.long RAMB+0x1FE80+0x44	! FORCED: strips packed ahead of the model
pk_boot:	.long 0x0A35DF3C	! MAIN boot state (1 = normal boot)
