! SPDX-License-Identifier: Apache-2.0
!
! rowwave, UI side: after the browse list parser FUN_084C958C has filled the
! nine row slots (S = 0x0B5434EC + n*0x220; slot 0 is the title, 1-8 the
! rows), every TRACK row gets our own 80x28 RGB565 "artwork" bitmap, in which
! the TchAud task (main_touchaudio.s, row_waves) draws the track's waveform
! preview. The packer FUN_0838EEE0 then sends our bitmap instead of the JPEG
! thumbnail or the clear message (grey disc), with or without artwork.
!
! Per row n (1-8): the track id comes from the DB task's cache of the visible
! rows (*0x09437CD0 + 0x124E0 + side*0xACC: count, then rows of 0x114 bytes:
! +0 track id, +4 icon, low byte 0x2F for a track; +0x14 the text). It is
! published in the table at 0x081F0000 (want[n] at +0x10); the task draws it
! into buffer n (0x081E0000 + (n-1)*0x1180) and sets done[n] (+0x34). The row
! slot points at the buffer (S+0x20 small, S+0x24 big = a shared black one,
! S+0x1C has_art), its ArtReq entry (0x0B543438 + n*20: state, key[8],
! small, big) goes to state 3 so no JPEG is requested and re-parses keep our
! pointers, and S+0x0C bit 1 / side byte bit 0x10 ask the packer to send it.
!
! Hook on both parser calls (0x084EB2D6, 0x084EBA64): runs after the parser
! returns. May clobber r0-r7; saves pr (it calls rw_bufof).

	.include "layout.inc"

	.equ	T_MAGIC, 0x00
	.equ	T_WANT, 0x10		! want[n], n = 0-8 (0 unused)
	.equ	T_DONE, 0x34		! done[n]
	.equ	T_RETRY, 0x58		! retry[n], fila gris fix (free +0x58..+0x7B, before meta +0x100)

	.equ	T_ROWS, 0x04		! address of the list's cache row 0
	.equ	T_CNT, 0x08		! rows in that cache

	.text
rowwave:
	sts.l	pr,@-r15		! (rw_bufof is called with bsr)
	mov.l	rw_mode,r1		! (the rows stay CDJ-3000 style with the mods
					! off: the cell's shape is a static GUI poke)
	mov.l	@r1,r0
	cmp/eq	#2,r0			! browse screens only
	bt	1f
	cmp/eq	#3,r0
	bf	rw_ret
1:	mov.l	rw_tab,r7		! r7 = table
	mov.l	@(T_MAGIC,r7),r0
	mov.l	rw_magic,r1
	cmp/eq	r1,r0
	bt	2f
	mov	#0,r0			! first time: clear the table, black big
	mov	r7,r2
	mov	#31,r3			! 31 words: incluye retry[9] +0x58..+0x7B (fila gris fix)
3:	mov.l	r0,@r2
	dt	r3
	bf/s	3b
	add	#4,r2
	mov.l	rw_big,r2
	mov.w	rw_bigw,r3
3:	mov.l	r0,@r2
	dt	r3
	bf/s	3b
	add	#4,r2
	mov.l	r1,@(T_MAGIC,r7)
2:	mov.l	rw_db,r1		! the DB task's context
	mov.l	@r1,r1
	tst	r1,r1
	bt	rw_ret
	mov.l	rw_cache,r0
	add	r0,r1			! r1 = side 0 cache: count, then rows
	mov.l	rw_slot1,r2		! slot 1's first character (S+0x2A)
	add	#0x2a,r2
	mov.w	@r2,r3
	extu.w	r3,r3
	mov	#2,r6			! which side holds the visible list?
	mov.l	rw_mode,r4		! V3rc3: on the TAG LIST only its own cache (below)
	mov.l	@r4,r0
	cmp/eq	#3,r0
	bt	7f
4:	mov.l	@r1,r0
	tst	r0,r0
	bt	5f
	mov	#9,r4
	cmp/hi	r4,r0
	bt	5f
	mov	r1,r4
	add	#0x18,r4		! row 0 text (+4 +0x14)
	mov.w	@r4,r0
	extu.w	r0,r0
	cmp/eq	r3,r0
	bt	6f
5:	mov.w	rw_acc,r0
	add	r0,r1
	dt	r6
	bf	4b
7:	mov.l	rw_mode,r1		! V3rc3: the TAG LIST (class 3) has its own row cache, DBctx + 0x17F94
	mov.l	@r1,r0			! (same 0x114-byte rows; the two sides above hold the list left
	cmp/eq	#3,r0			! before it, whose first title can match -> stale cells, F8)
	bf	rw_ret
	mov.l	rw_db,r1
	mov.l	@r1,r1
	mov.l	rw_tagc,r0
	add	r0,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	rw_ret
	mov	#9,r4
	cmp/hi	r4,r0
	bt	rw_ret
	mov	r1,r4
	add	#0x18,r4
	mov.w	@r4,r0
	extu.w	r0,r0
	cmp/eq	r3,r0
	bt	6f
	bra	rw_ret			! neither: not a list we know
	nop
6:	mov.l	@r1,r0
	mov.l	r0,@(T_CNT,r7)
	add	#4,r1
	mov.l	r1,@(T_ROWS,r7)
	mov.l	rw_slot1,r2		! r2 = S
	mov.l	rw_ent1,r3		! r3 = ArtReq entry
	mov	#1,r4			! r4 = n
	mov	#0,r5			! r5 = anything changed
rw_row:
	mov.l	rw_tab,r7
	mov	r4,r6			! r6 = cache row n-1
	add	#-1,r6
	mov.w	rw_114,r0
	mulu.w	r0,r6
	sts	macl,r6
	mov.l	@(T_ROWS,r7),r0
	add	r0,r6
	mov	r2,r0
	add	#0x28,r0
	mov.w	@r0,r0			! no text: an empty row
	tst	r0,r0
	bt	rw_none
	mov.l	@(T_CNT,r7),r0		! beyond the cache
	cmp/gt	r0,r4
	bt	rw_none
	mov.b	@(4,r6),r0		! a track row? accept the track-status icon
	extu.b	r0,r0			! codes: 0x2F plain, 0x5A loaded (green ▶),
	cmp/eq	#0x2f,r0		! 0x5B/0x60 other-player/history. (The green
	bt	rw_icok			! mark is a separate GUI glyph: keeping the
	cmp/eq	#0x5a,r0		! wave coloured on these does not touch it.)
	bt	rw_icok
	cmp/eq	#0x5b,r0
	bt	rw_icok
	cmp/eq	#0x60,r0
	bf	rw_none
rw_icok:
	mov.l	@r6,r6			! r6 = track id
	tst	r6,r6
	bt	rw_none
	mov	r4,r1			! r7 = &want[n]
	shll2	r1
	add	r1,r7
	mov.l	@(T_WANT,r7),r0
	cmp/eq	r6,r0
	bt	7f
	mov.l	r6,@(T_WANT,r7)		! a new track on this row
	mov	r7,r1			! retry[n] = 0 (fila gris fix; disp 0x58 > @(disp,Rn) max)
	add	#T_RETRY,r1
	mov	#0,r0
	mov.l	r0,@r1
	mov.l	@(T_DONE,r7),r0
	cmp/eq	r6,r0
	bt	8f
	bsr	rw_bufof		! not drawn yet: black until it is
	nop
	mov.w	rw_smw,r1
	mov	#0,r7
9:	mov.l	r7,@r0
	dt	r1
	bf/s	9b
	add	#4,r0
8:	mov	#-1,r0			! (re)apply below
	mov.l	r0,@r3
7:	mov.l	@r3,r0			! our state already applied?
	cmp/eq	#3,r0
	bt	rw_next
	mov	#3,r0
	mov.l	r0,@r3
	bsr	rw_bufof
	nop
	mov.l	r0,@(12,r3)		! entry small
	mov	r2,r7
	add	#0x20,r7
	mov.l	r0,@r7			! S+0x20 small
	mov.l	rw_big,r0
	mov.l	r0,@(16,r3)		! entry big
	mov.l	r0,@(4,r7)		! S+0x24 big
	mov	r2,r7
	add	#0x1c,r7
	mov	#1,r0
	mov.b	r0,@r7			! S+0x1C has_art
	mov	r2,r7
	add	#0x0c,r7
	mov.b	@r7,r0
	or	#2,r0
	mov.b	r0,@r7			! S+0x0C bit 1: send the artwork
	mov	#1,r5
	bra	rw_next
	nop
rw_none:
	mov	r4,r1			! not ours: want[n] = 0, stock behaviour
	shll2	r1
	add	r1,r7
	mov	#0,r0
	mov.l	r0,@(T_WANT,r7)
rw_next:
	mov.w	rw_220,r0
	add	r0,r2
	add	#20,r3
	add	#1,r4
	mov	#9,r0
	cmp/hs	r0,r4
	bf	rw_row
	mov.l	rw_slot1,r2		! each drawn row's right-hand text after its
	mov	#1,r4			! title (slot text + 0x1A0; the parse has
6:	mov.l	rw_tab,r7		! just cleared it)
	mov	r4,r0
	shll2	r0
	add	r0,r7
	mov.l	@(T_WANT,r7),r0
	tst	r0,r0
	bt	8f
	mov.l	@(T_DONE,r7),r1
	cmp/eq	r0,r1
	bf	8f
	mov	r2,r0
	add	#0x28,r0
	mov.w	@r0,r0			! title length
	extu.w	r0,r0
	mov.w	rw_cf,r1
	cmp/hs	r1,r0
	bt	8f
	mov	r4,r0			! the text: 0x081F0100 + n * 0x60
	mov	#0x60,r1
	mulu.w	r1,r0
	sts	macl,r6
	mov.l	rw_meta,r1
	add	r1,r6
	mov.w	rw_1ca,r7
	add	r2,r7
	mov	#42,r3			! mp3reset: at most 41 characters + the 0, and
	mov	#-1,r1			! 0xFFFF (a text never written: RAMB is 0xFF from
	extu.w	r1,r1			! the image) ends it -- unbounded it ran ~64 KB
7:	mov.w	@r6+,r0
	extu.w	r0,r0
	cmp/eq	r1,r0
	bf	1f
	mov	#0,r0
1:	dt	r3
	bf	3f
	mov	#0,r0
3:	mov.w	r0,@r7
	tst	r0,r0
	bf/s	7b
	add	#2,r7
8:	mov.w	rw_220,r0
	add	r0,r2
	add	#1,r4
	mov	#9,r0
	cmp/hs	r0,r4
	bf	6b
	tst	r5,r5
	bt	rw_ret
	mov.l	rw_side,r1		! side 0: artwork changed
	mov.b	@r1,r0
	or	#0x10,r0
	mov.b	r0,@r1
rw_ret:
	lds.l	@r15+,pr
	rts
	nop

! rw_bufof: r0 = buffer of row r4 (1-8). Clobbers r1.
rw_bufof:
	mov	r4,r0
	add	#-1,r0
	mov.w	rw_1180,r1
	mulu.w	r1,r0
	sts	macl,r0
	mov.l	rw_buf,r1
	rts
	add	r1,r0

rw_220:		.word 0x220
rw_114:		.word 0x114
rw_acc:		.word 0xACC
rw_1180:	.word 0x1180
rw_smw:		.word 0x1180 / 4
rw_cf:		.word 0xCF
rw_1ca:		.word 0x2A + 0x1A0
rw_bigw:	.word 0x6660 / 4
	.p2align 2
rw_mode:	.long 0x0B54336C	! UI screen mode: 2/3 browse, 4 INFO/preview
rw_slot1:	.long 0x0B5434EC + 0x220
rw_ent1:	.long 0x0B543438 + 20
rw_side:	.long 0x0B5434EC
rw_db:		.long 0x09437CD0	! -> the DB task's context
rw_tagc:	.long 0x17F94		! V3rc3: the TAG LIST's row cache (count, then rows)
rw_cache:	.long 0x124E0		! its cache of the visible list rows (side 0;
					! side 1 at +0xACC)
rw_tab:		.long RAMB+0x10000	! magic, rows, count; want[9] +0x10, done[9] +0x34
rw_buf:		.long RAMB+0x0	! eight 0x1180 small buffers
rw_big:		.long RAMB+0x9000	! one shared black big (0x6660)
rw_magic:	.long 0x52575633	! "RWV3"
rw_kill:	.long RAMB+0x1F7F0
rw_nomo:	.long 0x4F4D4F4E	! "NOMO": mods off
rw_meta:	.long RAMB+0x10100	! the rows' right-hand texts (main_touchaudio.s)
