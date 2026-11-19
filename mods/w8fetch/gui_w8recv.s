! SPDX-License-Identifier: Apache-2.0
!
! w8recv (GUI, SH-2A BE): message 0x31 from MAIN's w8send (mods/w8fetch) --
! the TEMPO MASTER's detail waveform -- into SDRAM the stock firmware leaves
! free (re/PERF_BROWSE_PLAY.md 7.2), for the V2 phase meter (README.md).
!
! A hook on the message dispatcher (0x0E50112C), right after it copies the
! 8-byte message header to 0x0F682190 ([seq][type][len u16][last u16]
! [index u16]); the payload is at 0xFFF8AFF4 + 4 * *0x0E592D64, as the
! stock handlers read it. The stock dispatcher then treats 0x31 as it always
! did (no handler: logged and ignored), so nothing else changes.
!
! index = kind << 14 | chunk (1-based), at most 0x2000 bytes a chunk:
!   kind 0  PWV5 entries   -> 0x0CA00040 + (chunk - 1) * 0x2000, chunks 1..0x30
!   kind 1  beat grid (PQT2) -> 0x0CA80000 + (chunk - 1) * 0x2000, 1..8
!   kind 3  cue block (PCO2 tags of the loaded track) -> 0x0CA90000 + (chunk - 1) * 0x2000, 1..2
!   kind 3, chunks 0x21..0x24  loaded-track artwork block -> 0x0CA70000 + (chunk - 0x21) * 0x2000 (G2)
!   kind 2  control record  -> 0x0CA00000, 32 bytes, then 'W8M1' over its
!           first word; +0x3C (ours) += 1
! anything else is dropped. Used range: 0x0CA00000-0x0CA90000.
!
! The chunk sender (MAIN 0x083913C2, type > 40) and the link hand over each
! 32-bit word's value: the control record's words arrive as MAIN wrote them
! (read big-endian here), while byte data (PWV5 entries, the PQT2 tag, both
! big-endian in the ANLZ file) arrives with each 4 bytes reversed; this
! copy reverses them back, so the buffers hold the file's bytes.

	.text
w8recv:
	mov.l	l_hdr,r1
	mov.b	@(1,r1),r0
	cmp/eq	#0x31,r0
	bf	9f
	mov.w	@(2,r1),r0
	extu.w	r0,r6			! len
	mov.w	l_ch,r0
	cmp/hi	r0,r6
	bt	9f
	mov.w	@(6,r1),r0
	extu.w	r0,r2			! index
	mov	r2,r5
	shll16	r5
	shll2	r5
	shlr16	r5
	shlr2	r5
	add	#-1,r5			! chunk - 1 (0 -> huge: dropped)
	mov	r2,r0
	shlr8	r0
	shlr2	r0
	shlr2	r0
	shlr2	r0			! kind
	mov.l	l_buf,r4
	cmp/eq	#2,r0
	bf	1f
	mov.l	@(0x3C,r4),r0		! control: our sequence + 1
	add	#1,r0
	mov.l	r0,@(0x3C,r4)
	mov	#32,r6
	bra	5f
	mov	#1,r3			! copied as it is
1:	tst	r0,r0
	bf	2f
	mov	#0x30,r1		! PWV5
	cmp/hs	r1,r5
	bt	9f
	bra	3f
	add	#0x40,r4
2:	cmp/eq	#3,r0
	bf	2f
	mov	#0x20,r1		! G2: chunks 0x21..0x24 = the loaded track's artwork block
	cmp/hs	r1,r5
	bf	4f
	add	#-0x20,r5
	mov	#4,r1
	cmp/hs	r1,r5
	bt	9f
	mov.l	l_art,r4
	bra	3f
	nop
4:	mov	#2,r1			! cue block (PCO2): chunks 1..2
	cmp/hs	r1,r5
	bt	9f
	mov.l	l_pco,r4
	bra	3f
	nop
2:	cmp/eq	#1,r0
	bf	9f
	mov	#8,r1			! grid
	cmp/hs	r1,r5
	bt	9f
	mov.l	l_grid,r4
3:	shll8	r5
	shll2	r5
	shll2	r5
	shll	r5
	add	r5,r4
	mov	#0,r3			! each 4 bytes reversed back
5:	mov.l	l_idx,r5		! the payload
	mov.l	@r5,r5
	shll2	r5
	mov.l	l_pay,r0
	add	r0,r5
	shlr2	r6
	tst	r6,r6
	bt	9f
6:	mov.l	@r5+,r0
	tst	r3,r3
	bf	7f
	swap.b	r0,r0
	swap.w	r0,r0
	swap.b	r0,r0
7:	mov.l	r0,@r4
	dt	r6
	bf/s	6b
	add	#4,r4
	tst	r3,r3			! a control record: our magic over its first word
	bt	9f
	add	#-32,r4
	mov.l	l_magic,r0
	mov.l	r0,@r4
9:	rts
	nop

	.p2align 1
l_ch:	.word	0x2000
	.p2align 2
l_hdr:	.long	0x0F682190		! the message header copy
l_buf:	.long	0x0CA00000		! control record, PWV5 at +0x40
l_grid:	.long	0x0CA80000
l_pco:	.long	0x0CA90000		! kind 3: the cue block (header 'PCO2', seq, rbid, len + PCO2 tags)
l_art:	.long	0x0CA70000		! kind 4: the loaded track's artwork ('PART', seq, rbid, len, 109 x 117 RGB565 stride 224, trailer seq)
l_idx:	.long	0x0E592D64		! the message's word index in the frame
l_pay:	.long	0xFFF8AFF4		! the frame + the header (8 bytes)
l_magic:	.long	0x57384D31		! 'W8M1'
