! SPDX-License-Identifier: Apache-2.0
!
! mods/w8fetch: the state w8send (the frame packer hook) and w8cap (the DB
! reply capture) share, a 128-byte block in RAMB (layout.inc), LE words.
! The block is erased flash (0xFF) at boot: w8send zeroes it once ('W8F1').
!   +0x00 'W8F1'
!   +0x04 DESC   the stream descriptor 0x083913C2 sends from (28 bytes):
!                +0x08 data, +0x10 offset, +0x14 bytes left,
!                +0x18 last index, +0x1C index (kind << 14 | chunk - 1)
!   +0x20 ST     what w8send does next while the descriptor is idle
!   +0x24 KEY    the target: the DB tid word (source player | slot << 8 |
!                type << 16) | the master's player number << 24; 0 = none
!   +0x28 RBID   its rekordbox id
!   +0x2C RDY    1 = w8cap stored a reply (RPTR, RSIZE, RRB), not yet taken
!   +0x30 RPTR   its data (heap; 0x08344B42 frees it), +0x34 RSIZE bytes,
!   +0x38 RRB    the rbid it answers
!   +0x3C TMR    the tick the DB request / NFS lookup started (V4n31)
! second base S2 = W8S + 0x40:
!   +0x00 CKEY / +0x04 CRB / +0x08 CCNT   the candidate target (debounce)
!   +0x0C BUF    the heap block being streamed (freed when done / aborted)
!   +0x10 CTL    the control record, sent as kind 2 (32 bytes, see README)
!   +0x30 GPTR   w8cap: the grid it fetched with the reply (RDY), 0 = none
!   +0x34 GBUF   the grid block waiting to be streamed after the PWV5
! V4n31 (#34) W8N = W8S + 0x80 (64 bytes, zeroed with W8S): the NFS lookup touch_audio's w8n_step
! makes for w8send when the DB answered no PWV5 (a CDJ-3000 master) or not at all (10 s), the master
! playing from a LINKed medium. w8send asks (KEY, RB, then SEQ + 1) and takes (CON = ANS);
! touch_audio works on JOB and answers RES (1 data, 2 none), PTR (the PWV5 record, as w8cap's),
! GPTR (the grid block or 0), then ANS = JOB. An answer w8send no longer waits for is freed.
! w8send waits 60 s at most (then KEY = 0: cancelled); a new target cancels too.
! V4n33 KC = W8S + 0xC0 (erased at boot): w8cap's DB key cache, 8 entries of 16 bytes {tid word (source |
! slot << 8 | type << 16, source = the player), rbid, "DK" << 16 | code (Camelot n * 2 + B, 0 = no key;
! anything else = not fetched), tick of a failed open (retry after 3 s)}, ring index at KC + 0x80. Read by
! mods/keyshift kc_code (the status publish, the master's key for modsmenu v3e_pub2).
	.equ	W8S, RAMB+0x1E000
	.equ	KC, W8S+0xC0
	.equ	W8N, W8S+0x80
	.equ	N_SEQ, 0
	.equ	N_KEY, 4
	.equ	N_RB, 8
	.equ	N_ANS, 12
	.equ	N_RES, 16
	.equ	N_PTR, 20
	.equ	N_GPTR, 24
	.equ	N_CON, 28
	.equ	N_JOB, 36		! touch_audio's (+40 tries, +44 diag bits)
	.equ	N_RCNT, 48		! METERFIX: w8send's retries of a "none" target (zeroed on a new target)
	.equ	W8MBX, 0x5738		! the reply "mailbox" of our requests
	.equ	DESC, 0x04
	.equ	D_PTR, 0x08
	.equ	D_OFF, 0x10
	.equ	D_LEFT, 0x14
	.equ	D_LAST, 0x18
	.equ	D_IDX, 0x1C
	.equ	ST, 0x20
	.equ	KEY, 0x24
	.equ	RBID, 0x28
	.equ	RDY, 0x2C
	.equ	RPTR, 0x30
	.equ	RSIZE, 0x34
	.equ	RRB, 0x38
	.equ	TMR, 0x3C
	.equ	CKEY, 0x00		! from S2
	.equ	CRB, 0x04
	.equ	CCNT, 0x08
	.equ	BUF, 0x0C
	.equ	CTL, 0x10
	.equ	GPTR, 0x30
	.equ	GBUF, 0x34
! 2.02 (#34) W8D = W8N + 52 (zeroed with W8S): w8cap's DB diagnostic for the last reply of ours: byte 3 a
! counter, byte 2 bits: 0 the 0x433 reply had a PWV5 block, 2 w7fb's PWV7 (0x2C04) came, 3 the block was
! a bare tag (no u32 prefix); byte 1 the status of w7fb's PWV7 fetch (1 ok, 0xFF error, 0xFE unsupported,
! 0 not tried); byte 0 = 0. W8D + 4: the first word of the last PWV7 block.
	.equ	W8D, W8N+52
