! SPDX-License-Identifier: Apache-2.0
!
! jogcue (opt-in): CUE-approach blink of the jog centre red marker (re/JOG_CENTER_RE.md).
! Stock already puts the CUE point on the red marker: tx byte 7 = struct 0x0B06C7B4+0,
! computed from v = word at 0x09947614 + slot*0x88 (slot *0x0B058BF4), which the CUE
! pad writes (emu: v = 0 before CUE, v = cue position 1/150 s after). Extra: while the
! playhead (*0x09947478) is 1..300 units (2 s) BEFORE the cue, the marker blinks at
! ~2 Hz (period 512 ms from tick 0x0B0C5258) = "cue coming" like the 3000's cue cue.
! Entered by literal 0x08450414 (jsr @r6 at 0x0845038E in the tx builder, after bytes
! 7/8/9 are written): r12 = struct, r14 = tx 0x0AB86780, both preserved. Passes to
! stock untouched unless *0x0A35DF3C == 1, *0x0B512568 == 0 (no animation state) and
! tx[9] < 0x80 (no canned code). r1-r3 saved; tail-jumps to 0x0843E344.

	.text
	.global	jogcue
jogcue:
	mov.l	r1,@-r15
	mov.l	r2,@-r15
	mov.l	r3,@-r15
	mov.l	L_boot,r0
	mov.l	@r0,r0
	cmp/eq	#1,r0
	bf	jc_out
	mov.l	L_anim,r0
	mov.l	@r0,r0
	tst	r0,r0
	bf	jc_out
	mov.b	@(9,r14),r0
	cmp/pz	r0			! byte 9 >= 0x80 -> canned animation code
	bf	jc_out
	mov.l	L_slot,r1
	mov.l	@r1,r1
	mov	r1,r2
	shll2	r2
	shll	r2			! slot << 3
	shll2	r1
	shll2	r1
	shll2	r1
	shll	r1			! slot << 7
	add	r2,r1			! slot * 0x88
	mov.l	L_tab,r2
	add	r2,r1
	mov.l	@r1,r1			! v = cue point
	mov.l	L_pos,r2
	mov.l	@r2,r2			! playhead
	sub	r2,r1			! v - pos
	cmp/pl	r1
	bf	jc_out			! cue unset (0) or already passed
	mov.l	L_win,r3
	cmp/hi	r3,r1
	bt	jc_out			! more than 2 s ahead
	mov.l	L_tick,r3
	mov.l	@r3,r3
	shlr8	r3			! 256 ms units
	mov	r3,r0
	tst	#1,r0
	bt	jc_out			! shown phase
	mov	#0,r0
	mov.b	r0,@(7,r14)		! blank phase
jc_out:
	mov.l	@r15+,r3
	mov.l	@r15+,r2
	mov.l	@r15+,r1
	mov.l	L_tgt,r0
	jmp	@r0
	nop
	.p2align 2
L_boot:	.long	0x0A35DF3C
L_anim:	.long	0x0B512568
L_slot:	.long	0x0B058BF4
L_tab:	.long	0x09947614
L_pos:	.long	0x09947478
L_win:	.long	300
L_tick:	.long	0x0B0C5258
L_tgt:	.long	0x0843E344
