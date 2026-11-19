/* SPDX-License-Identifier: Apache-2.0
 * player56 cave (MAIN, SH-4 LE), linked at P56_BASE (build.sh). Opt-in, see player56.py.
 * Entered by 3-instruction trampolines (mov.l lit,r0 / jmp @r0 / nop) placed in stock code;
 * jmp keeps r15 and pr, so the stubs see the stock function's frame. */
	.section .text.stub,"ax"
	.global p56_stubA, p56_stubB, p56_vals
	.align 2
/* A3 (sync module, 0x084B2F0E, the own==1/default arm of the own-slot switch):
 * the 3 "other player" status records whose max counter (rec+0x84) 0x084AF2C2 reads.
 * Out: r2 (stored at @(0x31C,r15)), r8, r9; then back to 0x084B2F30. */
p56_stubA:
	mov	#126,r0
	shll2	r0
	mov.l	@(r0,r15),r4		/* own number */
	mov	r9,r5			/* P = status table base (@(0x230,r15), already in r9) */
	mov.l	.LscrA,r6
	mov.l	.Lpick,r1
	jsr	@r1
	nop
	mov.l	.LscrA,r0
	mov.l	@r0,r2
	mov.l	@(4,r0),r8
	mov.l	@(8,r0),r9
	mov	#3,r0
	shll8	r0
	add	#28,r0
	mov.l	r2,@(r0,r15)
	mov.l	.LretA,r0
	jmp	@r0
	nop
/* B4 (master detection, 0x084B6084): fills the 3-entry "others" array at r15+0x354
 * for any own number (stock: own 1..4 only, 5/6 left it uninitialised); back to 0x084B61B4. */
p56_stubB:
	mov	#126,r0
	shll2	r0
	mov.l	@(r0,r15),r4		/* own number */
	mov	#2,r0
	shll8	r0
	add	#48,r0
	mov.l	@(r0,r15),r5		/* P */
	mov	#3,r6
	shll8	r6
	add	#84,r6
	add	r15,r6			/* out = r15+0x354 */
	mov.l	.Lpick,r1
	jsr	@r1
	nop
	mov.l	.LretB,r0
	jmp	@r0
	nop
	.align 2
.LscrA:	.long	p56_scrA
.Lpick:	.long	p56_pick3
.LretA:	.long	0x084B2F30
.LretB:	.long	0x084B61B4
/* a4: UTILITY PLAYER No. values AUTO,1..6 (UTF-16 strings in stock rodata, P2 alias) */
	.align 2
p56_vals:
	.long	0xA80FDF50, 0xA80FDCB4, 0xA80FDCB8, 0xA80FDCBC, 0xA80FDCC0, 0xA80FDCC4, 0xA80FDCC8
	.section .bss.scr,"aw"
	.align 2
	.global p56_scrA
p56_scrA: .space 12

/* ctx (browse/DB context, *0x09437CD0): its init 0x0827990C builds the device records
 * (0x08279D56(rec, dev)) for players 1..4, 17/18, 33, 41..44. Trampoline at 0x08279AD4
 * (right after the player loop; r9 = ctx, r8 = fpscr mask): records for players 5/6 at
 * ctx+0x26A6C / ctx+0x273A4 (index 67/68 of the player block, past the stock 0x26480; end 0x27CDC). */
	.section .text.stub,"ax"
	.global p56_stubInit
	.align 2
p56_stubInit:
	mov.l	.Lr5off,r4
	add	r9,r4
	mov	#5,r5
	mov.l	.Lrecinit,r0
	jsr	@r0
	nop
	sts	fpscr,r2
	and	r8,r2
	lds	r2,fpscr
	mov.l	.Lr6off,r4
	add	r9,r4
	mov	#6,r5
	mov.l	.Lrecinit,r0
	jsr	@r0
	nop
	sts	fpscr,r2
	and	r8,r2
	lds	r2,fpscr
	/* ctxsess (opt-in): session-table entries (2 x 0x90C each) for players 5/6 */
	mov.l	.LsessOn,r0
	mov.l	@r0,r0
	tst	r0,r0
	bt	9f
	mov.l	.Ls5off,r4
	bsr	8f
	nop
	mov.l	.Ls5off2,r4
	bsr	8f
	nop
	mov.l	.Ls6off,r4
	bsr	8f
	nop
	mov.l	.Ls6off2,r4
	bsr	8f
	nop
	bra	9f
	nop
8:	sts.l	pr,@-r15	/* r4 = ctx offset; init the slot block like the stock loop (0x0825BAD0) */
	add	r9,r4
	mov.l	.Lsessinit,r0
	jsr	@r0
	nop
	sts	fpscr,r2
	and	r8,r2
	lds	r2,fpscr
	lds.l	@r15+,pr
	rts
	nop
9:
	/* the 6 instructions the trampoline replaced */
	mov	#38,r2
	mov	r9,r11
	shll8	r2
	mov	#2,r14
	add	#-92,r2
	mov	#17,r12
	mov.l	.LretInit,r0
	jmp	@r0
	nop
	.align 2
.Lr5off:	.long	0x26A6C
.Lr6off:	.long	0x273A4
.Lrecinit:	.long	0x08279D56
.LretInit:	.long	0x08279AE0
.LsessOn:	.long	p56_sessOn
.Lsessinit:	.long	0x0825BAD0
.Ls5off:	.long	0x28EC0
.Ls5off2:	.long	0x297CC
.Ls6off:	.long	0x2A0D8
.Ls6off2:	.long	0x2A9E4
	.section .data.sess,"aw"
	.align 2
	.global p56_sessOn
p56_sessOn:	.long	0
	.section .text.stub,"ax"

/* 0x084B7xxx sync per-player arrays, 5 entries (p = 0..4) in stock, moved here with 7
 * (p = 0..6): A8 (8 B each, was 0x0B53D7EC, memset 0) and A4 (4 B each, was 0x0B53D814,
 * memset -1); stock old A4[1..4] = 0x0B53D818..27 sits right below the own status 0x0B53D828. */
	.section .bss.arr,"aw"
	.align 2
	.global p56_A8, p56_A4
p56_A8:	.space 56
p56_A4:	.space 28
	.global p56_T8
p56_T8:	.space 56		/* 0x0A376BF4 per-player 8-byte table, 5 -> 7 entries (pltab) */

/* own-number "others" switches in 0x084AEBxx/0x084AEDxx/0x084AF0xx (same shape as a3):
 * own 2/3/4 keep the stock arms; the default arm (own 1, 0, 5, 6) is replaced by
 * p56_pick3(own = r0, P = status table) -> three record pointers in the stock registers. */
	.section .text.stub,"ax"
	.global p56_stubC1, p56_stubC2, p56_stubC3
	.align 2
p56_stubC1:			/* 0x084AEBA2: P = r8; out r12 < r11 < r8; back to 0x084AEBBC */
	mov	r0,r4
	mov	r8,r5
	mov.l	.LscrC,r6
	mov.l	.LpickC,r1
	jsr	@r1
	nop
	mov.l	.LscrC,r0
	mov.l	@r0,r12
	mov.l	@(4,r0),r11
	mov.l	@(8,r0),r8
	mov.l	.LretC1,r0
	jmp	@r0
	nop
p56_stubC2:			/* 0x084AEDFA: P = r9; out r13 < r12 < r9; back to 0x084AEE14 */
	mov	r0,r4
	mov	r9,r5
	mov.l	.LscrC,r6
	mov.l	.LpickC,r1
	jsr	@r1
	nop
	mov.l	.LscrC,r0
	mov.l	@r0,r13
	mov.l	@(4,r0),r12
	mov.l	@(8,r0),r9
	mov.l	.LretC2,r0
	jmp	@r0
	nop
p56_stubC3:			/* 0x084AF078: P = r10; out r1 < r7 < r10; back to 0x084AF092 */
	mov	r0,r4
	mov	r10,r5
	mov.l	.LscrC,r6
	mov.l	.LpickC,r1
	jsr	@r1
	nop
	mov.l	.LscrC,r0
	mov.l	@(4,r0),r7
	mov.l	@(8,r0),r10
	mov.l	@r0,r1
	mov.l	.LretC3,r0
	jmp	@r0
	nop
	.align 2
.LscrC:	.long	p56_scrC
.LpickC:	.long	p56_pick3
.LretC1:	.long	0x084AEBBC
.LretC2:	.long	0x084AEE14
.LretC3:	.long	0x084AF092
	.section .bss.scrC,"aw"
	.align 2
	.global p56_scrC
p56_scrC: .space 12

/* srv: the DB server's per-requester table (stock srv+0x527C, index 0..4, followed by the live
 * field srv+0x5290) moved to p56_req with 7 entries (index 0..6); register/unregister/walk accept
 * 1..6. The UI-notify object 0x0AB82D38 (per-requester areas 0..4) serves 5/6 from shadow objects
 * (p56ui.c, p56ui_entries.S). Assumes one server instance (checked in the emu). */
	.section .text.stub,"ax"
	/* DMST parser 0x083DCF20 (UI-notify module only): a requester 5/6 that has a shadow object
	   is index 1 inside it, so the parsed player byte becomes 1; without a shadow the stock
	   check (player < 5) refuses it. The DMST word itself (replies) is not changed. */
	.global p56_uiDmst
	.align 2
p56_uiDmst:			/* 0x083DCF20..0x083DCF2C (r0/r2 dead): r4 = DMST, player in bits 31..24 */
	mov	r4,r0
	shlr16	r0
	shlr8	r0
	add	#-5,r0
	mov	#1,r2
	cmp/hi	r2,r0
	bt	3f
	shll2	r0
	mov.l	.LuiH,r2
	mov.l	@(r0,r2),r2
	tst	r2,r2
	bt	3f
	shlr2	r0		/* p-5 */
	add	#4,r0		/* p-1 */
	shll16	r0
	shll8	r0
	sub	r0,r4		/* player byte -> 1 */
3:	mov.l	r14,@-r15
	mov	r5,r1
	mov	r4,r2
	shlr16	r2
	mov	r6,r14
	shlr8	r2
	mov.l	.LuiDret,r0
	jmp	@r0
	nop
	.align 2
.LuiDret:	.long	0x083DCF2C
.LuiH:	.long	p56_uiH
	.section .bss.req,"aw"
	.align 2
	/* media objects USB 0x092235F4 / SD 0x09223B64 (0x570 = header 0xFC + 5 records 0xE4,
	   requester words at obj+0xE8[p]) relocated with 7 records; the 7 words moved to obj-0x100 */
	.global p56_mUSB, p56_mSD
p56_mUSBw:	.space	0x100
p56_mUSB:	.space	0x6D8
p56_mSDw:	.space	0x100
p56_mSD:	.space	0x6D8
	.global p56_req
p56_req:	.space 28
