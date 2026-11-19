! SPDX-License-Identifier: Apache-2.0
!
! jogtest (TEST builds, opt-in): JOG ring colour probe (re/JOG_LED_RE.md).
! The panel frame builder 0x0844F678 reads the ring's two channel levels through
! two getters, each via ONE literal (0x0844FA40 -> A 0x084DC640, 0x0844FA44 ->
! B 0x084DC64A); patch_main points them at +0 / +4 here. From 20.0 s to ~52.8 s
! after boot (tick 0x0B0C5258, ms) it walks the 16 combinations, 2.048 s each:
! step i = (t - 20000) >> 11, A = i >> 2, B = i & 3 (A0B0, A0B1 ... A3B3). Any
! other time, and always unless *0x0A35DF3C == 1 (normal boot), the stock getter.
! Leaf: r0-r3 and T only, no store.

	.text
	.global	jogtest
jogtest:
	bra	jt_com
	mov	#0,r1			! +0: channel A
	bra	jt_com
	mov	#1,r1			! +4: channel B
jt_com:
	mov.l	L_boot,r2
	mov.l	@r2,r0
	cmp/eq	#1,r0
	bf	jt_stock
	mov.l	L_tick,r2
	mov.l	@r2,r2
	mov.l	L_t0,r3
	sub	r3,r2			! t - 20000
	cmp/pz	r2
	bf	jt_stock
	shlr8	r2
	shlr2	r2
	shlr	r2			! step = >> 11
	mov	#16,r0
	cmp/hs	r0,r2
	bt	jt_stock
	tst	r1,r1
	bf	jt_b
	mov	r2,r0
	rts
	shlr2	r0			! A = step >> 2
jt_b:	mov	r2,r0
	rts
	and	#3,r0			! B = step & 3
jt_stock:
	tst	r1,r1
	bf	1f
	mov.l	L_sa,r2
	jmp	@r2
	nop
1:	mov.l	L_sb,r2
	jmp	@r2
	nop
	.p2align 2
L_boot:	.long	0x0A35DF3C
L_tick:	.long	0x0B0C5258
L_t0:	.long	20000
L_sa:	.long	0x084DC640
L_sb:	.long	0x084DC64A
