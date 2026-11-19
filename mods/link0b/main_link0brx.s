! SPDX-License-Identifier: Apache-2.0
!
! link0brx (v4.2 DEV prototype, MAIN, SH-4 LE): takes the CDJ-3000 precise-position packet (type 0x0b) that
! stock MAIN drops, the way a CDJ-3000 does (player state / getter, work/linklat
! REPORT.txt s1): it stamps the arrival and keeps the position; the reader extrapolates pos + dt x pitch and
! holds the raw value once the stamp is > 64 ms old.
!
! Hook: the Pro DJ Link 50001 receive task (0x08511514: socket, bind 50001, recvfrom 0x08217A9E into the fixed
! buffer 0x0BFBB5F8, then a switch on byte 0x0A that has no case for 0x0b), right after the recvfrom and its
! fpscr restore (patch_main BEAT_RECV). Entered with r4 = the span's saved r0-r7 (r0 = the datagram's length).
! The datagram is never swallowed: stock goes on exactly as before (and drops 0x0b itself).
!
! Packet (60 B, as a CDJ-3000 3.22 sends it, work/link3k/cap6.pcap): "Qspt1WmJOL" 0x0b, name (20), 0x1F = 2,
! 0x20 = 0, 0x21 the device, 0x22 length 0x0018 (BE), 0x24 track length s, 0x28 position ms, 0x2C pitch
! (percent x 100, s32), 0x38 BPM x 10 -- all BE.
!
! Update safety: only on *0x0A35DF3C == 1 and UTILITY LINK 0x0B ON; no call, no malloc; r0-r7 only, no mac.

	.include "layout.inc"
	.include "link0b.inc"

	.text
	.global link0brx
link0brx:
	sts.l	pr,@-r15
	mov.l	r_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	9f
	mov.l	r_kill,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	9f
	mov.l	@r4,r6			! the length recvfrom returned
	mov	#0x34,r0
	cmp/ge	r0,r6
	bf	9f
	mov.l	r_buf,r7		! the datagram
	mov.l	@r7,r1
	mov.l	r_magic,r2
	cmp/eq	r2,r1			! "Qspt"
	bf	9f
	mov	#0x0A,r0
	mov.b	@(r0,r7),r0
	cmp/eq	#0x0B,r0
	bf	9f
	mov	#0x1F,r0
	mov.b	@(r0,r7),r0
	cmp/eq	#2,r0			! the 3000's subtype
	bf	9f
	mov	#0x21,r0
	mov.b	@(r0,r7),r0
	extu.b	r0,r3			! the sender's device number
	mov	r3,r0
	add	#-1,r0
	mov	#5,r1
	cmp/hi	r1,r0			! players 1..6 only
	bt	9f
	mov.l	r_dev,r1		! not our own number (a loop-back)
	mov.b	@r1,r0
	extu.b	r0,r0
	cmp/eq	r3,r0
	bt	9f
	mov.l	r_l0b,r5
	mov	#0x18,r0
	mov.l	@(r0,r5),r0
	mov.l	r_l0bm,r1
	cmp/eq	r1,r0			! the block is cleared (link0btx, once)
	bf	9f
	mov.l	@r5,r0			! rx count
	add	#1,r0
	mov.l	r0,@r5
	mov	r3,r0
	shll2	r0
	shll2	r0
	shll	r0			! p * 32
	add	#L0B_REC,r0
	add	r0,r5			! r5 = the player's record
	mov	#0x28,r4
	bsr	be32			! r1 = the position (ms)
	nop
	mov.l	@r5,r2
	mov.l	r1,@r5
	mov	#0x2C,r4
	bsr	be32
	mov	r2,r6			! (delay slot) r6 = the previous position
	mov.l	r1,@(12,r5)		! the pitch, percent x 100
	mov.l	@r5,r1
	cmp/eq	r1,r6
	bf	2f
	mov	#0,r0			! the same position again: stopped (the 3000 stores rx 0)
	mov.l	r0,@(4,r5)
	bsr	now
	nop
	bra	9f
	mov.l	r0,@(16,r5)		! the last arrival
2:	bsr	now
	nop
	mov.l	r0,@(16,r5)		! the last arrival
	tst	r0,r0
	bf	3f
	mov	#1,r0			! tick 0 means stopped: never stamp 0
3:	mov.l	r0,@(4,r5)
	mov.l	r1,@(8,r5)
	bra	9f
	nop
9:	lds.l	@r15+,pr
	rts
	nop

! be32: r1 = the BE u32 at r7 + r4. Clobbers r0, r2, r4.
be32:
	mov	#4,r2
	mov	#0,r1
1:	mov	r4,r0
	mov.b	@(r0,r7),r0
	extu.b	r0,r0
	shll8	r1
	or	r0,r1
	add	#1,r4
	dt	r2
	bf	1b
	rts
	nop

! now: r0 = the RTOS ms tick (0x0B0C5258), r1 = the microseconds into it ((10416 - TCNT4) x 6291 >> 16, as
! mods/tcnet): read until two passes agree. No multiply (no mac: the site's macl is left alone) -- the
! microseconds are (10416 - TCNT4) / 10.4 done as x * 3 / 32 + x / 512 - x / 2048 (0.0937 + 0.0020 - 0.0005).
! Clobbers r0-r4, r6.
now:
	mov.l	r_tick,r2
	mov.l	r_tcnt4,r3
1:	mov.l	@r2,r6
	mov.w	@(4,r3),r0		! TCR4 (bit 8: an underflow not counted yet)
	mov	r0,r4
	mov.l	@r3,r1			! TCNT4
	mov.w	@(4,r3),r0
	cmp/eq	r0,r4
	bf	1b
	mov.l	@r2,r0
	cmp/eq	r0,r6
	bf	1b
	mov	r4,r0
	shlr8	r0
	and	#1,r0
	add	r6,r0			! the tick
	mov.w	r_tcor4,r4
	sub	r1,r4			! elapsed counts in this tick (0..10416)
	mov	r4,r1
	add	r1,r1
	add	r4,r1			! x3
	shlr2	r1
	shlr2	r1
	shlr	r1			! x3/32
	mov	r4,r6
	shlr8	r6
	shlr	r6			! x/512
	add	r6,r1
	shlr2	r6			! x/2048
	sub	r6,r1
	rts
	nop

r_tcor4: .word	10416
	.p2align 2
r_boot:	.long	L0B_BOOT
r_kill:	.long	L0B_KILL
r_buf:	.long	0x0BFBB5F8		! the 50001 receive buffer
r_magic: .long	0x74707351		! "Qspt"
r_dev:	.long	0x0AB84CFA		! our player number (byte)
r_l0b:	.long	L0B
r_l0bm:	.long	L0B_MAGIC
r_tick:	.long	0x0B0C5258
r_tcnt4: .long	0xFFD90018
