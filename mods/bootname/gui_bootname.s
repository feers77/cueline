! SPDX-License-Identifier: Apache-2.0
!
! bootname (GUI, SH-2A): a line of text under "Ver" on the boot screen.
!
! The boot screen (0x0E526A50 / 0x0E526A70 build it) is a widget list: a
! table of child descriptors (literal 0x0E526B74 -> 0x0E5B70C0, 8 entries),
! a table of their types (literal 0x0E526B78 -> 0x0E5B70AC, 8 halfwords:
! 1 3 3 3 3 2 1 1) and the count 8 (mov #8,r0 at 0x0E526A56 / 0x0E526A7C).
! Child 2 (0x0E5B6FF4, type 3) is the "Ver" text at (139,363)-(619,385).
! The screen's step handlers sit in a table at 0x0E524C50; entry 4
! (0x0E524C60 -> 0x1C00293E) runs once the children exist.
!
! This mod hands the screen 9 children: the stock eight plus a copy of the "Ver" text widget
! placed one line lower, (139,387)-(619,415), after the fourth child; its
! handler-4 replacement sets that widget's text (0x1C0027FC(0, child 4,
! string)) and then runs the stock handler with the arguments it gets.
!
! Fixed layout (patch_gui points the literals at these offsets, and writes
! the descriptor's own address into the table at +0x50: SELFRELOC):
!   +0x00  handler (entry)      +0x40  child table (9 longs)
!   +0x68  type table (9 u16)   +0x80  descriptor (48 B)
!   +0xB0  the UTF-16 string
	.text
bootname:
	sts.l	pr,@-r15
	mov	#0,r4
	mov	#4,r5			! the inserted child
	mova	str,r0
	mov	r0,r6
	mov.l	l_settext,r0
	jsr	@r0
	nop
	mov	#-1,r4			! the stock handler's arguments
	mov	#0,r5
	mov	#100,r6
	mov.l	l_orig,r0
	lds.l	@r15+,pr
	jmp	@r0
	nop
	.p2align 2
l_settext:	.long	0x1C0027FC	! set a child's text: (screen 0, child, utf16 string)
l_orig:		.long	0x1C00293E	! the stock step-4 handler
	.org	0x40
table:	.long	0x0E5B6FEC, 0x0E5B6FF4, 0x0E5B7020, 0x0E5B7038
	.long	0			! +0x50: our descriptor (SELFRELOC -> +0x80)
	.long	0x0E5B7050, 0x0E5B7070, 0x0E5B709C, 0x0E5B70A4
	.org	0x68
types:	.word	1, 3, 3, 3, 3, 3, 2, 1, 1, 0
	.org	0x80
desc:	.byte	0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x01	! a copy of child 2
	.byte	0x00,0x8b, 0x01,0x83, 0x02,0x6b, 0x01,0x9f	! x0 139, y0 387, x1 619, y1 415
	.byte	0xff,0xff, 0x06,0x00, 0x00,0x00,0x00,0x00
	.byte	0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00
	.byte	0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00
	.byte	0x00,0x00,0x00,0x0c, 0x00,0x00,0x00,0x00
	.org	0xB0
str:	.byte	0,'C',0,'u',0,'e',0,'l',0,'i',0,'n',0,'e',0,0,0,0	! RELAUDIT (user, v4.1): was "Mods by FEERS"
	.p2align 2
