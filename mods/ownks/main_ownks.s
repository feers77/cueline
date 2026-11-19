! SPDX-License-Identifier: Apache-2.0
!
! ownks, MAIN side of our own KEY SHIFT engine (replaces the Key Shift engine behind the same
! interface; the front end in mods/keyshift/main_keyshift.s and modsmenu is unchanged):
!   0x08122000  oks_dj(r4 = DJcont context): the DJcont loop's DSP-output step through here
!               (main_keyshift.s ks_dj calls it only when *0x0A35DF3C == 1)
!   0x08122800  state: +0 1 = KEY SHIFT on, +4 semitones -12..+12, +16 generation (front end)
!               +32 the factor last sent (cents + 1200, 0..2400; 1200 = 1.0), +36 resend countdown
!               +40 CENTPOP: KEY SYNC fine tune in cents (-50..+49, mods/keyshift ksy_shift; 0 otherwise)
! After the stock step, the DSP gets the pitch factor 2^((100 k + cents)/1200) (float bits) in our DSP
! control block (mods/ownks/dsp/ks3.c ks_ctl.ratio; KS3 v4.1, the same interface as ownks.c) with the stock "write words" request
! (0x082E43D6: one entry {DSP offset from the parameter block 0x008C8800, &value, 1 word}).
! Sent when the factor changes and every 256 calls (the DSP keeps the last value; a resend
! covers a DSP restart). No malloc, spawn or task: one request on the existing DJcont path.
! LASTFIX: while the jog is touched in VINYL mode (hold / scratch) the factor sent is 1.0 (bypass),
! as the CDJ-3000 turns its key control off while scratching; KS3: the DSP glides to 1.0, splices to a small delay and then to the exact dry signal (correlated, <= 1 s).

	.equ	OK_STEP, 0x082DBC2E	! stock: the DJcont loop's DSP-output step
	.equ	OK_SEND, 0x082E43D6	! stock: queue a DSP request (r4 handle, r5 entries, r6 count)

	.text
	.global	oks_dj
oks_dj:
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	sts.l	pr,@-r15
	sts	fpscr,r11
	mov	r4,r8
	mov.l	O_step,r1
	jsr	@r1
	nop
	mov	r0,r9			! the stock step's result
	mov.l	O_st,r10
	mov.w	O_1200,r1		! CENTPOP: r1 = the factor in cents + 1200, 0..2400 (1200 = 1.0)
	mov.l	@r10,r0
	tst	r0,r0
	bt	1f
	mov.l	@(4,r10),r2
	add	#12,r2
	mov	#24,r3
	cmp/hi	r3,r2			! outside -12..+12: 1.0
	bt	1f
	mov	#100,r3
	mulu.w	r3,r2
	sts	macl,r2			! (semitones + 12) * 100
	mov.l	O_ksy,r3		! CENTPOP: only while KEY SYNC is on (mods/keyshift KSB+48 ksy_on)
	mov.l	@r3,r3
	tst	r3,r3
	bt	6f
	mov.l	@(40,r10),r3		! CENTPOP: + the KEY SYNC cents (+40, -50..+49; outside -99..99: 0)
	mov	#99,r0
	cmp/gt	r0,r3
	bt	6f
	neg	r0,r0
	cmp/ge	r0,r3
	bf	6f
	add	r3,r2
6:	cmp/pz	r2
	bt	7f
	mov	#0,r2
7:	mov.w	O_2400,r3
	cmp/gt	r3,r2
	bf	8f
	mov	r3,r2
8:	mov	r2,r1
1:	mov.l	O_vin,r2		! LASTFIX (the CDJ-3000's KeyControlModeChanger): VINYL mode and a hand
	mov.l	@r2,r0			! on the jog (hold / scratch) -> factor 1.0, the DSP fades to the dry
	cmp/eq	#1,r0			! signal in 23 ms and back once the jog is released
	bf	3f
	mov.l	O_tch,r2
	mov.l	@r2,r0
	tst	r0,r0
	bt	3f
	mov.w	O_1200,r1		! CENTPOP: 1.0 = 1200
3:
	.ifdef	KSAB			! KS3 A/B (DEV test build, CDJ_KSAB=1): UTILITY KS3 ENGINE OFF (modsmenu kill_v+24
	mov.l	O_kab,r2		! = 0) -> bit 16 here (a change resends at once), the factor's sign bit at the send
	mov.l	@r2,r0			! = the DSP's previous engine (mods/ownks/dsp/ks3.c -DKS_AB)
	tst	r0,r0
	bf	4f
	mov.l	O_abf,r0
	or	r0,r1
4:
	.endif
	mov.l	@(32,r10),r0
	cmp/eq	r1,r0
	bf	2f
	mov.l	@(36,r10),r0
	dt	r0
	mov.l	r0,@(36,r10)
	bf	9f
2:	mov.l	@(32,r8),r4		! the DJcont context's DSP channel
	tst	r4,r4
	bt	9f
	add	#96,r4
	mov.l	@r4,r4
	tst	r4,r4
	bt	9f
	mov.l	r1,@(32,r10)		! sent (or about to be)
	mov.w	O_cnt,r0
	mov.l	r0,@(36,r10)
	add	#-16,r15
	mov.l	O_id,r0
	mov.l	r0,@r15			! entry: DSP offset
	mov	r15,r2
	add	#12,r2
	mov.l	r2,@(4,r15)		!        -> the value word
	mov	#1,r0
	mov.l	r0,@(8,r15)		!        1 word
	.ifdef	KSAB
	mov.l	r1,@(12,r15)		! KS3 A/B: keep the engine bit across oks_bits
	extu.w	r1,r1
	.endif
	bsr	oks_bits		! CENTPOP: 2^((r1 - 1200) / 1200) as float bits, integer only
	nop
	.ifdef	KSAB
	mov.l	@(12,r15),r2
	shlr16	r2
	rotr	r2			! bit 16 -> bit 31: the sign = the old engine
	or	r2,r0
	.endif
	mov.l	r0,@(12,r15)		! the factor's float bits
	mov	r15,r5
	mov	#1,r6
	mov.l	O_send,r1
	jsr	@r1
	nop
	add	#16,r15
9:	lds	r11,fpscr
	mov	r9,r0
	lds.l	@r15+,pr
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	rts
	mov.l	@r15+,r8

! oks_bits(r1 = cents + 1200, 0..2400): r0 = float bits of 2^((r1 - 1200) / 1200) (CENTPOP).
! r1 = 1200 * oct + 100 * semi + cent; mantissa = semq[semi] * cq[cent] (Q30 x Q30, dmulu.l), exponent
! 126 + oct. Whole semitones give the old 25-entry table's bits exactly (semq = its mantissas); 1200 = 0x3F800000.
! No FPU. Clobbers r0-r3, r5-r7, mach/macl.
oks_bits:
	mov	r1,r2
	mov	#0,r3			! r3 = oct
	mov.w	O_1200,r0
1:	cmp/hs	r0,r2
	bf	2f
	sub	r0,r2
	bra	1b
	add	#1,r3
2:	mov	#0,r5			! r5 = semi
	mov	#100,r0
3:	cmp/hs	r0,r2
	bf	4f
	sub	r0,r2
	bra	3b
	add	#1,r5
4:	mov.l	O_semq,r0
	shll2	r5
	mov.l	@(r0,r5),r6
	mov.l	O_cq,r0
	shll2	r2
	mov.l	@(r0,r2),r7
	dmulu.l	r6,r7
	sts	mach,r6
	sts	macl,r7
	shll2	r6
	shlr16	r7
	shlr8	r7
	shlr2	r7
	shlr2	r7
	shlr2	r7
	or	r7,r6			! m, Q30, 1.0 <= m < 2.0
	shll2	r6
	shlr8	r6
	shlr	r6			! (m - 1.0) >> 7: the 23 mantissa bits
	mov	#126,r0
	add	r3,r0
	shll16	r0
	shll8	r0
	shlr	r0			! exponent << 23
	rts
	or	r6,r0

O_cnt:	.word	256
O_1200:	.word	1200
O_2400:	.word	2400
	.p2align 2
O_step:	.long	OK_STEP
O_send:	.long	OK_SEND
O_st:	.long	0x08122800
O_vin:	.long	0x0B058C00		! jog mode: 1 = VINYL (setter 0x084E16E0, JogModeVinyl)
O_tch:	.long	0x0B54CB38		! JogTouch, deck 0: (panel report[0x0F] & 0x20) != 0 (decoder 0x0844D4A8,
					! setter 0x084E1780)
O_id:	.long	OK_DSP_RATIO - 0x008C8800	! DSP address of ks_ctl.ratio, as the request's offset
O_semq:	.long	oks_semq
O_ksy:	.long	0x08123000 + 48	! mods/keyshift ksy_on
O_cq:	.long	oks_cq
	.ifdef	KSAB
O_kab:	.long	OK_KILL_AB		! modsmenu kill_v+24: KS3 ENGINE (1 ON = ks3, 0 OFF = the old engine)
O_abf:	.long	0x10000
	.endif
oks_semq:	! Q30 2^(s/12), s = 0..11 (the old table's mantissas: whole semitones bit-exact)
	.long	0x40000000, 0x43ce3e80, 0x47d66b00, 0x4c1bf800, 0x50a28c00, 0x556e0400
	.long	0x5a827980, 0x5fe44380, 0x6597fa80, 0x6ba27e80, 0x7208f800, 0x78d0df80
oks_cq:		! Q30 2^(c/1200), c = 0..99
	.long	0x40000000, 0x4009776d, 0x4012f040, 0x401c6a7a, 0x4025e61b, 0x402f6322, 0x4038e192, 0x40426168
	.long	0x404be2a7, 0x4055654d, 0x405ee95b, 0x40686ed2, 0x4071f5b1, 0x407b7df9, 0x408507aa, 0x408e92c4
	.long	0x40981f47, 0x40a1ad34, 0x40ab3c8b, 0x40b4cd4c, 0x40be5f77, 0x40c7f30c, 0x40d1880c, 0x40db1e77
	.long	0x40e4b64d, 0x40ee4f8e, 0x40f7ea3b, 0x41018653, 0x410b23d8, 0x4114c2c8, 0x411e6324, 0x412804ee
	.long	0x4131a823, 0x413b4cc6, 0x4144f2d6, 0x414e9a53, 0x4158433e, 0x4161ed97, 0x416b995d, 0x41754692
	.long	0x417ef535, 0x4188a547, 0x419256c8, 0x419c09b8, 0x41a5be17, 0x41af73e5, 0x41b92b23, 0x41c2e3d1
	.long	0x41cc9df0, 0x41d6597e, 0x41e0167d, 0x41e9d4ed, 0x41f394ce, 0x41fd561f, 0x420718e3, 0x4210dd18
	.long	0x421aa2be, 0x422469d7, 0x422e3262, 0x4237fc60, 0x4241c7d0, 0x424b94b3, 0x42556309, 0x425f32d2
	.long	0x4269040f, 0x4272d6c0, 0x427caae4, 0x4286807d, 0x4290578a, 0x429a300c, 0x42a40a03, 0x42ade56f
	.long	0x42b7c250, 0x42c1a0a6, 0x42cb8072, 0x42d561b4, 0x42df446c, 0x42e9289a, 0x42f30e3f, 0x42fcf55b
	.long	0x4306ddee, 0x4310c7f8, 0x431ab379, 0x4324a072, 0x432e8ee3, 0x43387ecb, 0x4342702c, 0x434c6306
	.long	0x43565758, 0x43604d24, 0x436a4468, 0x43743d26, 0x437e375d, 0x4388330e, 0x4392303a, 0x439c2edf
	.long	0x43a62eff, 0x43b03099, 0x43ba33af, 0x43c4383f
	.ascii	"OWNKS"
