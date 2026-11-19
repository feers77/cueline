! SPDX-License-Identifier: Apache-2.0
!
! usbkey, MAIN side: the USB SOURCE KEY lamp stays lit while the own USB is
! mounted, instead of copying the USB PORT indicator's blink (re/USB_KEY_STEADY.md).
!
! The lamp pass 0x084DC768 rebuilds the source-key table 0x0B54C030 (3 lit,
! 1 dim) every pass. Twice it sets the USB key [2] from the stock predicate
! 0x084DC522 ("USB indicator word 0x0B54C018 == 3", i.e. the port light is in
! its ON phase): at 0x084DCA62 (browse medium = own USB) and 0x084DCADA
! (0x0B54C380 == 1). Both read it through ONE literal, 0x084DCBE8, which
! patch_main points here; nothing else reads that literal, and every other
! caller of 0x084DC522 is untouched. The indicator itself (0x084DE2FC) is not
! changed, so the port light keeps its stock blink (access flicker, 1 Hz with a
! USB track loaded, mount/eject blinks).
!
! Returns r0 = 1 (key lit) when
!   *0x0A35DF3C == 1       normal boot (update mode: always the stock path)
!   *0x0A35F3AC == 3       USB state: mounted
!   *0x0A35F410 != 2       not in the stock 500 ms (eject/stop) blink
! else the stock predicate, unchanged. A leaf: reads three words, clobbers r0,
! r1 and T only (the stock helper clobbers r0, r6), no call, no store.

	.text
	.global	usbkey
usbkey:
	mov.l	L_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	uk_stock
	mov.l	L_usb,r1
	mov.l	@r1,r0
	cmp/eq	#3,r0
	bf	uk_stock
	mov	#100,r0
	mov.l	@(r0,r1),r0
	cmp/eq	#2,r0
	bt	uk_stock
	rts
	mov	#1,r0
uk_stock:
	mov.l	L_ind,r1		! stock 0x084DC522: *(0x0B54C010+8) == 3
	mov.l	@(8,r1),r0
	cmp/eq	#3,r0
	rts
	movt	r0
	.align	2
L_boot:	.long	0x0A35DF3C
L_usb:	.long	0x0A35F3AC
L_ind:	.long	0x0B54C010
