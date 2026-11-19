! SPDX-License-Identifier: Apache-2.0
!
! marqueefix (GUI, SH-2A): the browse marquee (a long title that scrolls in the
! selected row) fills the title cell's background through the DMA fill
! 0x0E510368 with the STOCK light selection colour 0xDEFC (#D8DCE0), because
! that fill is driven by the scene, not by the list cursor bitmap that ui3000x
! recolours to navy. So while a long title scrolls the title band turns white
! (and its white text becomes unreadable), even though the static selection is
! the 3000 navy. The only fills that use 0xDEFC on this path are those cells
! (every other fill is a clear = 0, or a scene colour), so:
!
! patch_gui REDIRECTS the DMA-fill literal 0x0E508FD4 (stock 0x0E510368) here.
! When the fill colour (r6) is the stock selection 0xDEFC, swap it for the 3000
! navy selection 0x19CD (#1B3B6E); any other colour passes through untouched.
! Contract, exactly like fpsboost's fill_wrap: keep r4-r7, r15 and pr as the
! caller left them, change only r0-r3, and tail-jump to the stock fill.
!
!   In: r4 = 1 (channel 6, sync), r5 = destination, r6 = colour, r7 = bytes.

	.text
marqueefix:
	extu.w	r6,r1			! r1 = fill colour, zero-extended
	mov.l	l_defc,r0
	cmp/eq	r0,r1
	bf	1f
	mov.l	l_navy,r6		! stock selection 0xDEFC -> 3000 navy 0x19CD
1:
	mov.l	l_fill,r0
	jmp	@r0			! the stock DMA fill, r4-r7 as they were
	nop

	.align	2
l_defc:	.long	0x0000DEFC
l_navy:	.long	0x000019CD
l_fill:	.long	0x0E510368
