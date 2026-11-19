/* SPDX-License-Identifier: Apache-2.0
 * player56 'a7': own number 5/6 -> announce/claim/keepalive bytes of a CDJ-3000 at 5/6
 * (alphatheta-connect src/virtualcdj/index.ts makeStage0a/00/02/04/06; work/realrig/P56_NOTES.md §2).
 * Linked at 0x081C7F00 (last 256 B of the player56 cave reserve), standalone (no p56.bin needed).
 *
 * Entered instead of the stock 50000 sender 0x083E2534(r4 = dest IP or 0 = broadcast, r5 = length),
 * which sends the shared buffer 0x0AB8530C (36-byte header from 0x083E1FF0 + body from 0x083E2134).
 * All 13 literal-pool words that name the sender point here. Rewrites in the buffer, only when
 * *0x0A35DF3C == 1 (normal boot) and own number (0x0AB84CFA) is 5 or 6:
 *   type 0x0a (37 B)  : [0x21] 0x02 -> 0x04, length 0x25 -> 0x26, [0x25] = 0x40, r5 = 38
 *   type 0x00/02/04   : [0x21] 0x02 -> 0x03
 *   type 0x06 (54 B)  : [0x35] -> 0x64
 * Players 1..4 and every other type/length: untouched. Then tail-jumps to the stock sender
 * (r4..r7 and pr preserved; only r0..r3 used). */
	.section .text.ann,"ax"
	.global p56_ann
	.align 2
p56_ann:
	mov.l	.Lboot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	.Lgo
	mov.l	.Lown,r1
	mov.b	@r1,r0
	extu.b	r0,r0
	add	#-5,r0
	mov	#1,r2
	cmp/hi	r2,r0			/* (own-5) > 1 unsigned -> not 5/6 */
	bt	.Lgo
	mov.l	.Lbuf,r1
	mov.b	@(10,r1),r0		/* packet type */
	extu.b	r0,r0
	cmp/eq	#10,r0
	bt	.Lann
	cmp/eq	#6,r0
	bt	.Lka
	tst	#0xF9,r0		/* 0, 2, 4 -> T = 1 */
	bf	.Lgo
	mov	#3,r0
	mov	#33,r2
	add	r1,r2
	bra	.Lgo
	mov.b	r0,@r2			/* [0x21] = 0x03 */
.Lann:
	mov	#37,r0
	cmp/eq	r0,r5
	bf	.Lgo
	mov	#33,r2
	add	r1,r2
	mov	#4,r0
	mov.b	r0,@r2			/* [0x21] = 0x04 */
	mov	#38,r0
	mov.b	r0,@(2,r2)		/* [0x23] = 0x26 (BE length, [0x22] stays 0) */
	mov	#64,r0
	mov.b	r0,@(4,r2)		/* [0x25] = 0x40 */
	bra	.Lgo
	mov	#38,r5
.Lka:
	mov	#54,r0
	cmp/eq	r0,r5
	bf	.Lgo
	mov	#53,r2
	add	r1,r2
	mov	#100,r0
	mov.b	r0,@r2			/* [0x35] = 0x64 */
.Lgo:
	mov.l	.Lsend,r0
	jmp	@r0
	nop
	.align 2
.Lboot:	.long	0x0A35DF3C
.Lown:	.long	0x0AB84CFA
.Lbuf:	.long	0x0AB8530C
.Lsend:	.long	0x083E2534
