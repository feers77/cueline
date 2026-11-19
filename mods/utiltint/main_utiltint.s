! SPDX-License-Identifier: Apache-2.0
!
! utiltint, MAIN side: tint each UTILITY settings-row LABEL by the ORIGIN of
! its item -- stock -> white, our mods -> green, any other -> violet.
!
! The UTILITY list builder (0x084F0740) fills nine slots of the shared list
! model S = 0x0B5434EC + n*0x220 (slot 0 title, 1..8 rows) and MAIN pushes
! them to the GUI snapshot 0x0E5B82F0 every frame. The GUI reads slot+0x10 as
! a text-STYLE index (clamped <24; palette style = 2*index): 0 white, 2 green,
! 11 violet; the selected-row highlight is OR'd in by the GUI's own table.
! In the builder's 8-row loop, namebuf = *(r15) = S+0x0C, so slot+0x10 =
! namebuf+4. The firmware's own grey block (0x084F09A6) stores *(namebuf+4)=1
! for a disabled row -- proof this is the MAIN-written, GUI-transmitted style
! field, and why the hook runs BEFORE that block so a disabled row stays grey.
!
! Hooked after the slot-1 formatter (the row's text is already filled) via the
! UTILITY_ROW span (patch_main.py). Contract: r5 = the builder's frame (r15),
! r4 = the saved span r0-r7 (unused). Clobbers r0-r7 only; does no firmware
! call, so no FPSCR re-mask is needed (the moved formatter call is re-masked by
! the resume code at 0x084F0982). Origin is classified exactly as modsmenu's
! force_all does, on the item entry's label pointer (entry+0); FA_LO/FA_HI
! (modsmenu [entries, block_end)) come in as --defsym.

	.text
	.global	utiltint
utiltint:
	mov.l	@(32,r5),r0		! r0 = item table base (builder local @32)
	mov.l	@(48,r5),r1		! r1 = this row's offset into the table (@48)
	add	r1,r0			! r0 = item entry for this row
	mov.l	@(20,r0),r1		! entry+20: 0 on an informational row
	tst	r1,r1
	bt	ut_stock		! informational -> white
	mov.l	@r0,r2			! r2 = label pointer (entry+0)
	mov.l	ut_p2,r3		! 0xA0000000: stock labels live in P2
	cmp/hs	r3,r2
	bt	ut_stock		! label >= P2 -> stock -> white
	mov.l	ut_lo,r3		! FA_LO = modsmenu entries
	cmp/hs	r3,r2
	bf	ut_other		! label < entries -> not ours -> other
	mov.l	ut_hi,r3		! FA_HI = modsmenu block_end
	cmp/hs	r3,r2
	bt	ut_other		! label >= block_end -> other
	mov	#2,r6			! ours -> green (style index 2)
	bra	ut_write
	nop
ut_other:
	mov	#11,r6			! other -> violet (style index 11)
	bra	ut_write
	nop
ut_stock:
	mov	#0,r6			! stock -> white (style index 0)
ut_write:
	mov.l	@r5,r1			! r1 = namebuf = *(r15) = slot + 0x0C
	rts
	mov.l	r6,@(4,r1)		! namebuf+4 = slot+0x10 = STYLE word (delay slot)
	.p2align 2
ut_p2:	.long	0xA0000000
ut_lo:	.long	FA_LO			! modsmenu entries   (ours: label in [lo,hi))
ut_hi:	.long	FA_HI			! modsmenu block_end
