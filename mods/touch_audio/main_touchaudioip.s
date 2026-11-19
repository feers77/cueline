! SPDX-License-Identifier: Apache-2.0
!
! Learn the DJM-A9's address for the touch_audio mod (M0). The task in
! main_touchaudio.s must send its type-0x29 Touch Audio status to the mixer by
! unicast (the A9 ignores a broadcast one), so it needs the mixer's address
! before the election can start -- but the A9 sends a CDJ nothing on 50002
! until it is announced to. The mixer does broadcast keepalives on 50000, the
! Pro DJ Link announce socket, so this hook on that receive (LINK_RECEIVE,
! shared with main_abletonlinkpong.s) copies the sender's endpoint out of a
! mixer keepalive into the shared block at 0x081FF800 that the task reads.
!
! A mixer is a device whose keepalive (type 0x06) carries a player number of
! 33 or more (0x21; a DJM-A9 is 33). CDJs are 1-6 and rekordbox is 17, so the
! number cleanly tells the mixer apart. We never change the datagram or r0, so
! the firmware's own handling of the keepalive is untouched.
!
! Hook contract (sigpatch.trampoline()): r4 = the saved r0-r7, r5 = the task's
! frame, with the sender's T_IPV4EP at r5+12 and the datagram at r10 (the same
! layout main_abletonlinkpong.s uses on this site). r0-r7 are scratch; we touch
! nothing else and make no call, so no registers need saving.

	.include "layout.inc"

	.text
	.global touchaudioip
touchaudioip:
	mov.l	ti_boot,r1		! V3rc3: nothing in update mode (MAIN boot state != 1)
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	9f
	mov.l	@r10,r1			! "Qspt"? a Pro DJ Link datagram
	mov.l	ti_magic,r2
	cmp/eq	r2,r1
	bf	9f
	mov.b	@(10,r10),r0		! type at 0x0a
	extu.b	r0,r0
	mov	#0x06,r1		! a keepalive?
	cmp/eq	r1,r0
	bf	9f
	mov	r10,r1
	add	#0x24,r1
	mov.b	@r1,r2			! player number at 0x24
	extu.b	r2,r2
	mov	#0x21,r1		! 33 or more -> a mixer
	cmp/hs	r1,r2
	bf	9f
	mov	r5,r1
	add	#12,r1			! &sender (a T_IPV4EP)
	mov.l	ti_shared,r2
	mov.l	@r1,r0			! ip
	mov.l	r0,@(4,r2)
	mov.l	@(4,r1),r0		! port + pad
	mov.l	r0,@(8,r2)
	mov	#1,r0
	mov.l	r0,@r2			! valid = 1
9:	rts
	nop

	.p2align 2
ti_magic:	.long 0x74707351	! "Qspt"
ti_shared:	.long RAMB+0x1F800
ti_boot:	.long 0x0A35DF3C	! MAIN boot state (1 = normal boot)
