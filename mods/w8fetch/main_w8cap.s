! SPDX-License-Identifier: Apache-2.0
!
! w8cap (MAIN, SH-4 LE): the DB task's replies to OUR requests (mods/w8fetch).
!
! Every DB handler answers through 0x0827C2C4(reply, request), which checks the
! DB client (0x08253734(*0x09437CD0, 1)) and mails the reply to the request's
! mailbox (+20). w8send (main_w8send.s) asks the DB task for the TEMPO MASTER's
! PWV5 detail (code 0x433, the stock CUEWAV requester's fetch, handler
! 0x0828A4F0) with W8MBX, a value no mailbox has, as that mailbox. This routine
! replaces 0x0827C2CA..0x0827C2D8 (the literal load, the moves into r13/r14
! and the client check's call). A reply to anyone else continues as stock:
! the client check is tail-called and returns to the call site, which resumes
! at 0x0827C2D8 with its r0.
!
! Ours, still in the DB task: the reply's PWV5 block (+48, the 20-byte record
! 0x08289E98 builds: n, n * 2, 2, 150, ?, -> entries at +20; size +44) is
! kept; with it, the same track's beat grid is fetched the way 0x08289E98
! fetches PWV5 -- open 0x0827A228(ctx, the request's tid at +36), the tag
! primitive 0x082545F8(handle, rbid, "PQT2", "EXT", ...) (a heap block:
! [u32][the tag as in the file]), close 0x0827A34E -- and kept only when it
! is a PQT2 (the stock deck reads its grids from PQT2 too, local or LINKed:
! the grid parser 0x0826AFDE; a PQTZ / .DAT fetch answers with no data).
! Both go to w8send's state (RPTR, RSIZE, RRB = the rbid, GPTR, then
! RDY = 1) when w8send waits for
! them (ST 3, the last reply taken); otherwise they are freed. The reply
! block goes back to its pool and 0x0827C2C4 returns 0 to the handler
! (its own epilogue, run here).
!
! Contract (sigpatch call_site, hook=False): entered by jsr with r4 = reply,
! r5 = request, r15 = 0x0827C2C4's frame (@r15 its caller's pr, @(4) r14,
! @(8) r13). Sets r13 = reply, r14 = request as the replaced code did; r8-r12
! kept.

	.include "layout.inc"
	.include "ownstat.inc"
	.include "w8.inc"

	.text
	.global w8cap
w8cap:
	mov	r4,r13
	mov	r5,r14
	sts.l	pr,@-r15		! V4n33: the DB key cache (this deck's and the master's track) first
	bsr	kc_step
	nop
	lds.l	@r15+,pr
	mov	r13,r4
	mov	r14,r5
	mov.l	@(20,r5),r0		! the reply mailbox
	mov.w	c_mbx,r1
	cmp/eq	r1,r0
	bt	1f
	mov.l	c_ctx,r6		! not ours: the client check, back to the call site
	mov.l	@r6,r4
	mov	#1,r5
	mov.l	c_chk,r1
	jmp	@r1
	nop

1:	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	c_st,r8
	mov.l	@(48,r4),r10		! the PWV5 record
	mov	#0,r9
	mov.l	c_ctx,r0		! the key and the grid: open the track
	mov.l	@r0,r4
	mov	r14,r5
	mov.l	c_open,r0
	jsr	@r0
	add	#36,r5
	tst	r0,r0
	bt	5f
	mov	r0,r9			! the handle
	! V3rc2 (route B, work/v3rc2/re_mkey): the track's key id, as stock's TRACK FILTER MASTER PLAYER asks it
	! (0x0825BFC0 -> dbcl_GetNewKeyID 0x08253934, remote message 0x3D03; own media or LINK): k = 1..24 ->
	! our code k + 1 (Camelot n * 2 + B) at W8S +0x78 ("MK" << 16 | code), its rbid at +0x7C
	mov	r9,r4
	mov.l	@(40,r14),r5
	mov.l	c_gkey,r0
	jsr	@r0
	nop
	add	#-1,r0
	mov	#24,r1
	cmp/hs	r1,r0			! 1..24 only
	bt	2f
	add	#2,r0
	mov.l	c_mk,r1
	or	r1,r0
	mov.l	@(40,r14),r2
	mov	r8,r1
	add	#0x78,r1
	mov.l	r2,@(4,r1)		! the rbid first, then the key word
	mov.l	r0,@r1
2:	bsr	dg_beg			! 2.02 (#34): the DB diagnostic word W8D, a new reply
	nop
	.ifdef	W8NOPWV5		! TEST ONLY (2.02 bench): the PWV5 block dropped, as a CDJ-3000's empty
	bsr	free0			! answer, so w7fb's PWV7 fallback runs (0x2D04, then 0x2C04)
	mov	r10,r4
	mov	#0,r10
	.endif
	.ifdef	W8EMPTY			! TEST ONLY (V4n31 bench): every DB answer treated as empty, as a CDJ-3000's
	bsr	free0
	mov	r10,r4
	bra	nogrid
	mov	#0,r10
	.endif
	tst	r10,r10
	bf	3f
	bsr	w7fb			! no PWV5 (a CDJ-3000 master): its PWV7 (.2EX, 3-band) as a PWV5 record
	nop
	tst	r10,r10
	bf	3f
nogrid:	mov	r9,r4			! no PWV5 / PWV7: close, no grid
	mov.l	c_close,r0
	jsr	@r0
	nop
	bra	5f
	mov	#0,r9
3:	add	#-12,r15		! the fetch's outputs: @(4,r15) = its block
	mov	#0,r1
	mov.l	r1,@(4,r15)
	mov	r15,r1
	mov.l	r1,@-r15
	mov	r15,r1
	add	#8,r1
	mov.l	r1,@-r15
	mov	r15,r1
	add	#16,r1
	mov.l	r1,@-r15
	mova	s_tag,r0
	mov	r0,r6
	add	#8,r0
	mov	r0,r7
	mov	r9,r4
	mov.l	@(40,r14),r5
	mov.l	c_atom,r0
	jsr	@r0
	nop
	add	#12,r15
	mov.l	@(4,r15),r1
	add	#12,r15
	mov	r9,r4
	mov	r1,r9
	mov.l	c_close,r0
	jsr	@r0
	nop
	tst	r9,r9
	bt	5f
	mov.l	@(4,r9),r0		! the tag
	mov.l	s_tag,r1
	cmp/eq	r1,r0
	bt	5f
	mov	r9,r4			! not a PQT2
	mov.l	c_free,r0
	jsr	@r0
	mov	#0,r9

5:	mov.l	@(ST,r8),r0		! r10 = PWV5, r9 = grid (or 0)
	mov.l	@(RDY,r8),r2
	tst	r2,r2
	bf	6f			! the last one still untaken
	cmp/eq	#3,r0
	bf	6f			! nobody waits for it
	mov.l	r10,@(RPTR,r8)
	mov.l	@(44,r13),r2
	mov.l	r2,@(RSIZE,r8)
	mov.l	@(40,r13),r2
	mov.l	r2,@(RRB,r8)
	mov	r8,r1
	add	#0x40,r1
	mov.l	r9,@(GPTR,r1)
	mov	#1,r2
	bra	7f
	mov.l	r2,@(RDY,r8)
6:	bsr	free0
	mov	r10,r4
	bsr	free0
	mov	r9,r4
7:	mov.l	@(24,r13),r4		! the reply block back to its pool
	mov.l	c_rel,r0
	jsr	@r0
	mov	r13,r5
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	mov	#0,r0
	lds.l	@r15+,pr		! 0x0827C2C4's epilogue
	mov.l	@r15+,r14
	rts
	mov.l	@r15+,r13

free0:	tst	r4,r4
	bt	8f
	mov.l	c_free,r0
	jmp	@r0
	nop
8:	rts
	nop

c_mbx:	.word	W8MBX
	.p2align 2
s_tag:	.ascii	"PQT2"
	.long	0
	.ascii	"EXT"
	.byte	0
c_ctx:	.long	0x09437CD0		! -> the DB client context
c_chk:	.long	0x08253734		! client check (ctx, 1)
c_st:	.long	W8S
c_open:	.long	0x0827A228		! open (ctx, tid) -> handle
c_atom:	.long	0x082545F8		! tag (handle, rbid, tag, ext, ...)
c_close:	.long	0x0827A34E
c_free:	.long	0x08344B42		! free
c_rel:	.long	0x08404772		! rel_mpf(pool, block)
c_gkey:	.long	0x08253934		! dbcl_GetNewKeyID(handle, rbid) -> key id
c_mk:	.long	0x4D4B0000		! "MK"

! dg_beg (2.02, #34): W8D (W8N + 52, w8.inc) for a reply of ours: byte 3 = a reply counter + 1, byte 2 =
! bit 0 the 0x433 reply had a PWV5 block (r10); bytes 0 / 1 cleared (byte 1: w7fb's PWV7 status).
dg_beg:	mov.l	k_w8d,r1
	mov.l	@r1,r0
	shlr16	r0
	shlr8	r0
	add	#1,r0
	shll16	r0
	shll8	r0
	tst	r10,r10
	bt	1f
	mov	#1,r2
	shll16	r2
	or	r2,r0
1:	rts
	mov.l	r0,@r1

! w7get (2.02, #34): PWV7/.2EX of the request's track (r14, handle r9) through stock's tag primitive
! 0x082545F8 (dbserver 0x2C04 GET_SPECIFIED_ATOM_INFO). W8D: byte 1 = its status (1 ok, 0xFF error, 0xFE
! unsupported), byte 2 bit 2 = a block came; W8D + 4 = the block's first word. Out: r0 = the heap block
! ([u32][tag], or the bare tag: see w7fb), 0 = none. Keeps r8-r14.
! Not 0x2D04 GET_SPECIFIED_ATOM_INFO2 (what the CDJ-3000's own client sends for PWV6 / PWV7, 
! /): the 3000's server hands 0x2C04 and 0x2D04 to one handler (/
! 0x14D4BC0 -> 0x14D90B0), and stock's client never puts a 0x2D04 on the wire (tried in the emu, R21L2t:
! status -1, nothing sent; an NXS2 server answers 0x2D04 with 0x4003).
w7get:	sts.l	pr,@-r15
	mov.l	@(40,r14),r5
	mova	k_tag7,r0
	mov	r0,r6
	add	#-12,r15
	mov	#0,r1
	mov.l	r1,@r15
	mov.l	r1,@(4,r15)
	mov.l	r1,@(8,r15)
	mov	r15,r1
	mov.l	r1,@-r15
	mov	r15,r1
	add	#8,r1
	mov.l	r1,@-r15
	mov	r15,r1
	add	#16,r1
	mov.l	r1,@-r15
	mov	r6,r7
	add	#8,r7
	mov	r9,r4
	mov.l	g_atom,r0
	jsr	@r0
	nop
	add	#12,r15
	mov.l	k_w8d,r1
	mov	r0,r2			! the status, byte 1
	mov	#1,r0
	mov.b	r2,@(r0,r1)
	mov.l	@(4,r15),r3		! the block
	add	#12,r15
	tst	r3,r3
	bt	1f
	mov.l	@r3,r2
	mov.l	r2,@(4,r1)
	mov.b	@(2,r1),r0
	or	#4,r0
	mov.b	r0,@(2,r1)
1:	mov	r3,r0
	lds.l	@r15+,pr
	rts
	nop

	.p2align 2
g_atom:	.long	0x082545F8
k_w8d:	.long	W8D

! w7fb (DB task, handle r9 open, request r14): the PWV5 fetch answered nothing (a CDJ-3000 keeps its
! 3-band detail as PWV7 in the .2EX). Fetch PWV7/2EX (raw tag: 'PWV7', +8 header 24, +12 tag len,
! +16 entry bytes 3, +20 n, +24 u32, entries low/mid/high from +28) and rewrite it in place into the
! 20-byte PWV5 record w8send streams (+0 n, +4 n*2 bytes, entries from +20): per entry
! u16 BE = R 15-13 | G 12-10 | B 9-7 | height 6-2, height = max band, colours = orange mids, blue
! lows, white highs (r = m + h, g = m/2 + h, b = l + h scaled to the brightest). Out: r10 = the
! record, 0 = none (a bad block is freed).
! 2.02 (#34): through w7get (W8D). The block's tag is read at +4 ([u32][tag], what an NXS2 server sends)
! or, when the block starts with 'PWV7' itself, at +0 (W8D byte 2 bit 3; the 3000's form is not captured yet).
w7fb:	sts.l	pr,@-r15
	mov.l	r8,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	bsr	w7get
	nop
	tst	r0,r0
	bt	w7x			! r10 = 0
1:	mov	r0,r10
	mov	r10,r11			! r11 = the tag (+0 'PWV7', +8 header, +12 len, +16 bytes, +20 n)
	add	#4,r11
	mov.l	@r10,r1
	mov.l	k_tag7,r2
	cmp/eq	r2,r1
	bf	2f
	mov	r10,r11			! the bare tag
	mov.l	k_w8d2,r1
	mov.b	@(2,r1),r0
	or	#8,r0
	mov.b	r0,@(2,r1)
2:	mov.l	@r11,r1
	cmp/eq	r2,r1
	bf	w7bad
	mov.l	@(12,r11),r1		! entry bytes (BE) = 3
	mov	#3,r2
	shll8	r2
	shll16	r2
	cmp/eq	r2,r1
	bf	w7bad
	mov.l	@(16,r11),r6		! n (BE)
	swap.b	r6,r6
	swap.w	r6,r6
	swap.b	r6,r6
	tst	r6,r6
	bt	w7bad
	mov.l	k_nmax,r2
	cmp/hi	r2,r6
	bt	w7bad
	mov.l	@(8,r11),r1		! tag length (BE) >= 24 + 3n
	swap.b	r1,r1
	swap.w	r1,r1
	swap.b	r1,r1
	mov	r6,r2
	add	r6,r2
	add	r6,r2
	add	#24,r2
	cmp/hs	r2,r1
	bf	w7bad
	mov.l	r6,@r10
	mov	r6,r1
	shll	r1
	mov.l	r1,@(4,r10)
	mov	r10,r4
	add	#20,r4			! out
	mov	r11,r5
	add	#24,r5			! in (always ahead of out)
	mov	#64,r8
	shll	r8			! 128
w7lp:	mov.b	@r5+,r0
	extu.b	r0,r1			! low
	mov.b	@r5+,r0
	extu.b	r0,r2			! mid
	mov.b	@r5+,r0
	extu.b	r0,r3			! high
	cmp/hi	r8,r1
	bf	1f
	mov	r8,r1
1:	cmp/hi	r8,r2
	bf	1f
	mov	r8,r2
1:	cmp/hi	r8,r3
	bf	1f
	mov	r8,r3
1:	mov	r1,r11			! height = max band, 0..128 -> 0..31 (v - v>>7) >> 2
	cmp/hi	r11,r2
	bf	1f
	mov	r2,r11
1:	cmp/hi	r11,r3
	bf	1f
	mov	r3,r11
1:	mov	r11,r12
	shlr2	r12
	shlr2	r12
	shlr2	r12
	shlr	r12
	sub	r12,r11
	shlr2	r11
	shll2	r11
	mov	r11,r7			! acc = height << 2
	mov	r2,r0
	shlr	r0
	add	r3,r0			! g
	add	r3,r2			! r
	add	r3,r1			! b
	mov	r2,r3
	cmp/hi	r3,r0
	bf	1f
	mov	r0,r3
1:	cmp/hi	r3,r1
	bf	1f
	mov	r1,r3
1:	tst	r3,r3
	bt	w7st
w7sh:	cmp/hs	r8,r3			! scale so the brightest is 128..256
	bt	1f
	shll	r3
	shll	r2
	shll	r0
	shll	r1
	bra	w7sh
	nop
1:	mov	r0,r3			! G: (g - g>>8) & 0xE0, << 5
	shlr8	r3
	sub	r3,r0
	and	#0xE0,r0
	shll2	r0
	shll2	r0
	shll	r0
	or	r0,r7
	mov	r2,r3			! R, << 8
	shlr8	r3
	sub	r3,r2
	mov	r2,r0
	and	#0xE0,r0
	shll8	r0
	or	r0,r7
	mov	r1,r3			! B, << 2
	shlr8	r3
	sub	r3,r1
	mov	r1,r0
	and	#0xE0,r0
	shll2	r0
	or	r0,r7
w7st:	mov	r7,r0
	shlr8	r0
	mov.b	r0,@r4
	add	#1,r4
	mov	r7,r0
	mov.b	r0,@r4
	add	#1,r4
	dt	r6
	bf	w7lp
	bra	w7x
	nop
w7bad:	mov.l	k_free,r0
	jsr	@r0
	mov	r10,r4
	mov	#0,r10
w7x:	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r8
	lds.l	@r15+,pr
	rts
	nop


	.p2align 2
k_tag7:	.ascii	"PWV7"
	.long	0
	.ascii	"2EX"
	.byte	0
k_nmax:	.long	0x30000		! PWV5 bytes the display keeps: 0x60000
k_w8d2:	.long	W8D
k_atom:	.long	0x082545F8
k_free:	.long	0x08344B42

! kc_step (DB task, every reply; normal boot only): the key of (a) the track a CUEWAV detail request
! (0x432 / 0x433: the deck's own load, or w8send's master fetch) names in its tid (+36, source 0 = this
! deck's media) / rbid (+40), (b) the track this deck (heartbeat +0x5C) and (c) the LINK master (+0xA4)
! have loaded per the LINK table (0x0A371D3C + p * 0x124: +0x28 source | slot << 8 | type << 16, +0x2C
! rbid). A rekordbox track not yet in the cache KC (w8.inc: 8 entries, ring index at KC + 0x80) is asked
! as stock's TRACK FILTER MASTER PLAYER does (open 0x0827A228 with the tid, dbcl_GetNewKeyID 0x08253934
! -- dbserver 0x3D03 for a LINKed deck --, close): entry = tid (source = the player), rbid, "DK" << 16 |
! code (k 1..24 -> k + 1; 0 = no key), tick (a failed open retries after 3 s). r14 = the request.
! Keeps r8-r14; clobbers r0-r7.
kc_step:
	mov.l	k_boot,r0
	mov.l	@r0,r0
	cmp/eq	#1,r0
	bt	1f
	rts
	nop
1:	sts.l	pr,@-r15
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	@(8,r14),r0		! (a) the request's code
	mov.w	k_432,r1
	sub	r1,r0
	mov	#2,r1
	cmp/hs	r1,r0
	bt	2f
	mov.l	@(36,r14),r9
	shll8	r9
	shlr8	r9
	bsr	kc_tr
	mov.l	@(40,r14),r10
2:	mov.l	k_hb,r1			! (b) this deck
	mov	#0x5C,r0
	bsr	kc_pl
	mov.l	@(r0,r1),r4
	mov.l	k_hb,r1			! (c) the master
	mov	#0x52,r0
	shll	r0
	bsr	kc_pl
	mov.l	@(r0,r1),r4
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	lds.l	@r15+,pr
	rts
	nop

! kc_pl(r4 = player): its LINK table track -> kc_tr
kc_pl:	mov	r4,r0
	add	#-1,r0
	mov	#6,r1
	cmp/hs	r1,r0
	bf	1f
	rts
	nop
1:	mov	#0x49,r1
	shll2	r1			! 0x124
	mulu.w	r4,r1
	mov.l	k_tab,r2
	sts	macl,r1
	add	r1,r2
	mov.l	@r2,r9
	shll8	r9
	shlr8	r9
	mov.l	@(4,r2),r10
	! fall through
! kc_tr(r9 = tid word, r10 = rbid): fetch the key into KC unless held. Uses r0-r8, r11.
kc_tr:	mov	r9,r0
	shlr16	r0
	cmp/eq	#1,r0			! a rekordbox track
	bf	9f
	tst	r10,r10
	bt	9f
	mov.l	k_hb,r1
	mov	#0x5C,r0
	mov.l	@(r0,r1),r7		! r7 = this deck's number
	extu.b	r9,r0
	tst	r0,r0
	bf	1f
	or	r7,r9			! source 0 (a request on this deck's media) -> this deck
1:	mov.l	k_tick,r11
	mov.l	@r11,r11		! r11 = now
	mov.l	k_kc,r8
	mov	#8,r3
2:	mov.l	@r8,r0			! held?
	cmp/eq	r9,r0
	bf	3f
	mov.l	@(4,r8),r0
	cmp/eq	r10,r0
	bf	3f
	mov.l	@(8,r8),r0		! fetched (DK), or a failed open less than 3 s ago
	shlr16	r0
	mov.w	k_dk,r1
	cmp/eq	r1,r0
	bt	9f
	mov.l	@(12,r8),r0
	mov	r11,r1
	sub	r0,r1
	mov.w	k_retry,r0
	cmp/hs	r0,r1
	bf	9f
	bra	4f			! retry in the same entry
	nop
3:	dt	r3
	bf/s	2b
	add	#16,r8
	mov.l	k_kc,r8			! a new entry: the ring's next
	mov	#0x80,r0
	extu.b	r0,r0
	mov.l	@(r0,r8),r1
	add	#1,r1
	mov.l	r1,@(r0,r8)
	mov	r1,r0
	and	#7,r0
	shll2	r0
	shll2	r0
	add	r0,r8
4:	mov	#0,r0			! the entry invalid first
	mov.l	r0,@(8,r8)
	mov.l	r9,@r8
	mov.l	r10,@(4,r8)
	mov.l	r11,@(12,r8)
	extu.b	r9,r0			! this deck's own media: a local tid (source 0)
	cmp/eq	r7,r0
	mov	r9,r2
	bf	5f
	xor	r0,r2
5:	add	#-16,r15		! the tid block {tid, rbid, 0, 0}
	mov.l	r2,@r15
	mov.l	r10,@(4,r15)
	mov	#0,r0
	mov.l	r0,@(8,r15)
	mov.l	r0,@(12,r15)
	mov.l	k_ctx,r0
	mov.l	@r0,r4
	mov	r15,r5
	sts.l	pr,@-r15
	mov.l	k_open,r0
	jsr	@r0
	nop
	lds.l	@r15+,pr
	add	#16,r15
	tst	r0,r0
	bt	9f			! no handle: retry after 3 s
	mov	r0,r11			! the handle
	sts.l	pr,@-r15
	mov	r0,r4
	mov	r10,r5
	mov.l	k_gkey,r0
	jsr	@r0
	nop
	mov	r0,r6
	mov.l	r6,@-r15
	mov	r11,r4
	mov.l	k_close,r0
	jsr	@r0
	nop
	mov.l	@r15+,r0
	lds.l	@r15+,pr
	add	#-1,r0
	mov	#24,r1
	cmp/hs	r1,r0			! 1..24 -> code k + 1, else 0 (no key)
	bf	6f
	mov	#-2,r0
6:	add	#2,r0
	mov.w	k_dk,r1
	shll16	r1
	or	r1,r0
	mov.l	r0,@(8,r8)
9:	rts
	nop

	.p2align 1
k_dk:	.short	0x444B			! "DK"
k_retry: .short	3000
k_432:	.short	0x0432
	.p2align 2
k_boot:	.long	0x0A35DF3C
k_hb:	.long	0x0B568C9C		! the heartbeat model
k_tab:	.long	LINK_TAB + 0x28	! the LINK status table, + 0x28
k_kc:	.long	KC
k_tick:	.long	0x0B0C5258		! 1 ms tick
k_ctx:	.long	0x09437CD0		! -> the DB client context
k_open:	.long	0x0827A228
k_gkey:	.long	0x08253934		! dbcl_GetNewKeyID
k_close: .long	0x0827A34E
