! SPDX-License-Identifier: Apache-2.0
!
! ks3k (MAIN, SH-4 LE): keeps the KEY of a CDJ-3000's status packet (mods/keyshift, re/KEY_SHIFT_PLAN.md K5).
!
! The status receive 0x083FE8E8 (r14 = the datagram) copies only the first 0x124 bytes into the
! LINK table 0x0A371D3C; a CDJ-3000's packet is 1152 bytes long and carries at 0x15C the SOUNDING key
! {b0 = tonic of the relative major 0-11, b1 = 0 minor / 1 major, b2 = accidental, b3 = valid}.
! This hook (sigpatch hook=True, the span is the table lock's call, entered with r4 = the saved r0-r7,
! r5 = the receive's frame, r14 live) reads it for players 1..6 and stores, per player p, at
! KEYT = RAMB+0x1E800 + p*8:  +0 the four key bytes as sent, +4 "K3" << 16 | Camelot code
! (number * 2 + (major ? 1 : 0), 2..25) | CENTPOP: the residual sounding cents (0x160 + 0x168 after the
! rounding to semitones, -50..+49, signed byte) << 8, or 0 when the packet has no valid 3000 key (a shorter packet
! from a NXS2 clears it). +0x40 debug: the last packet's length field (0x22) and a counter.
! Passive: only when *0x0A35DF3C == 1 (normal boot), nothing else is touched.

	.include "layout.inc"

	.text
	.global ks3k
ks3k:
	sts.l	pr,@-r15
	mov.l	k_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	9f
	mov.l	@r14,r1			! "Qspt"
	mov.l	k_magic,r2
	cmp/eq	r2,r1
	bf	9f
	mov	#0x24,r0
	mov.b	@(r0,r14),r0		! the sender's player number
	extu.b	r0,r3
	tst	r3,r3
	bt	9f
	mov	#7,r0
	cmp/hs	r0,r3
	bt	9f
	mov.l	k_tab,r2
	mov	r3,r0
	shll2	r0
	shll	r0			! * 8
	add	r0,r2			! r2 = the player's entry
	mov	#0,r1
	mov.l	r1,@(4,r2)		! no key until proven
	mov	#0x22,r0
	mov.b	@(r0,r14),r0
	extu.b	r0,r1
	shll8	r1
	mov	#0x23,r0
	mov.b	@(r0,r14),r0
	extu.b	r0,r0
	or	r0,r1			! r1 = the length field
	mov.l	k_dbg,r4
	mov.l	r1,@r4
	mov.l	@(4,r4),r0
	add	#1,r0
	mov.l	r0,@(4,r4)
	! COMPAT: the sender's class for kx_send (KCLS = RAMB+0x1E848 + player): 3 a CDJ-3000 / 3000X
	! (name "CDJ-3..."), 2 a CDJ-2000NXS2 (the 0x180 form, as V4n33..V4n41), 0 anything else. r0, r4, r5 only (r1 = the length field, r2, r3 = player kept).
	mov	#0,r5
	mov	#0x0B,r0
	mov.b	@(r0,r14),r0
	cmp/eq	#0x43,r0		! 'C'
	bf	kc_w
	mov	#0x0E,r0
	mov.b	@(r0,r14),r0
	cmp/eq	#0x2D,r0		! '-'
	bf	kc_w
	mov	#0x0F,r0
	mov.b	@(r0,r14),r0
	cmp/eq	#0x33,r0		! '3': CDJ-3000, CDJ-3000X
	bt/s	kc_w
	mov	#3,r5
	mov	#0,r5
	cmp/eq	#0x32,r0		! '2'
	bf	kc_w
	mov	#0x13,r0
	mov.b	@(r0,r14),r0
	cmp/eq	#0x4E,r0		! 'N': CDJ-2000NXS2
	bf	kc_w
	mov	#2,r5			! a CDJ-2000NXS2 (ours or stock: a stock one copies only 0x124 bytes)
kc_w:	mov.l	k_cls,r4
	add	r3,r4
	mov.b	r5,@r4
	! LINK0B (v4.2): a Cueline deck = "CDJ-2000NXS2" whose status is >= 0x180 B (length field >= 0x15C; a stock
	! NXS2 sends 0x124 = 0x100): link0btx sends it the 0x0b precise position (L0B + 0x80 + player, 1 = Cueline)
	mov	r5,r0
	cmp/eq	#2,r0
	bf/s	kc_c
	mov	#0,r0
	mov.w	k_off,r0		! 0x15C
	cmp/hs	r0,r1
	movt	r0
kc_c:	mov.l	k_cue,r4
	add	r3,r4
	mov.b	r0,@r4
	mov.w	k_min,r0
	cmp/hs	r0,r1			! a 3000's packet carries the extension
	bf	9f
	mov.w	k_off,r4		! 0x15C: the sounding key
	mov	r4,r0
	mov	r2,r3
	mov.b	@(r0,r14),r5		! b0
	mov.b	r5,@r3
	add	#1,r0
	add	#1,r3
	mov.b	@(r0,r14),r6		! b1
	mov.b	r6,@r3
	add	#1,r0
	add	#1,r3
	mov.b	@(r0,r14),r7		! b2
	mov.b	r7,@r3
	add	#1,r0
	add	#1,r3
	mov.b	@(r0,r14),r0		! b3: valid
	mov.b	r0,@r3
	extu.b	r0,r0
	cmp/eq	#1,r0
	bf	9f
	extu.b	r5,r1			! b0
	mov	#12,r0
	cmp/hs	r0,r1
	bt	9f
	extu.b	r6,r6
	! V4n36a (A3): the 3000's own KEY SHIFT is NOT in 0x15C. With 0x16C == 1 its receiver adds 0x164
	! (int64 BE, KEY SHIFT in cents; link manager: else the remote key is invalid) and the
	! 0x160 cents: b0 += round((cents + shift) / 100) semitones (|sum| > 2400: ignored)
	mov	#0,r3			! CENTPOP: r3 = the residual cents (-50..+49), 0 without 0x16C
	mov.w	k_16c,r0
	mov.b	@(r0,r14),r0
	cmp/eq	#1,r0
	bf	8f
	mov.w	k_160,r4
	bsr	ks_be32
	nop
	mov	r3,r7			! 0x160 cents
	mov.w	k_168,r4
	bsr	ks_be32
	nop
	add	r7,r3			! + KEY SHIFT cents (the int64's low word)
	mov.w	k_2400,r4
	cmp/gt	r4,r3
	bt	k3_nc
	neg	r4,r4
	cmp/ge	r4,r3
	bf	k3_nc
	mov	#0,r5
	mov	#50,r4
5:	cmp/ge	r4,r3
	bf	6f
	add	#-100,r3
	bra	5b
	add	#1,r5
6:	mov	#-50,r4
7:	cmp/ge	r4,r3
	bt	7f
	add	#100,r3
	bra	7b
	add	#-1,r5
7:	add	r5,r1
	add	#48,r1
	mov	#12,r4
5:	cmp/hs	r4,r1			! % 12
	bf	8f
	bra	5b
	sub	r4,r1
k3_nc:	mov	#0,r3			! CENTPOP: out of range: no cents
8:	mov	r1,r0
	shll	r0
	add	r1,r0			! 3 x b0
	shll	r0
	add	r1,r0			! 7 x b0
	add	#8,r0
	mov	#12,r4
1:	cmp/hs	r4,r0			! % 12
	bf	2f
	bra	1b
	sub	r4,r0
2:	tst	r0,r0
	bf	3f
	mov	#12,r0			! 0 -> 12
3:	shll	r0			! number * 2
	tst	r6,r6
	bt	4f
	add	#1,r0			! b1 != 0: major (B)
4:	extu.b	r3,r3			! CENTPOP: + the residual cents (signed byte) in bits 8-15 (readers mask
	shll8	r3			!   the code with #31: unchanged for them; kx_word takes the cents)
	or	r3,r0
	mov.w	k_k3,r1
	shll16	r1
	or	r1,r0
	mov.l	r0,@(4,r2)
9:	lds.l	@r15+,pr
	rts
	nop

! ks_be32: r3 = the int32 BE at r14 + r4 (r0, r4, r5 used)
ks_be32:
	mov	#4,r5
	mov	#0,r3
1:	mov	r4,r0
	mov.b	@(r0,r14),r0
	extu.b	r0,r0
	shll8	r3
	or	r0,r3
	add	#1,r4
	dt	r5
	bf	1b
	rts
	nop

	.p2align 1
k_min:	.short	0x0150
k_off:	.short	0x015C
k_k3:	.short	0x4B33
k_16c:	.short	0x016C
k_160:	.short	0x0160
k_168:	.short	0x0168
k_2400:	.short	2400
	.p2align 2
k_boot:	.long	0x0A35DF3C
k_magic: .long	0x74707351	! "Qspt"
k_tab:	.long	RAMB+0x1E800
k_dbg:	.long	RAMB+0x1E840
k_cls:	.long	RAMB+0x1E848	! COMPAT: the senders' classes (kx_send)
k_cue:	.long	RAMB+0x1E600+0x20	! LINK0B: Cueline flags (mods/link0b/link0b.inc L0B_CUE)
