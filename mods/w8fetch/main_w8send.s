! SPDX-License-Identifier: Apache-2.0
!
! w8send (MAIN, SH-4 LE): the TEMPO MASTER's detail waveform (PWV5) and beat
! grid (PQT2) for the display (mods/w8fetch, README.md): CDJ-3000 style phase
! meter WAVEFORM.
!
! Replaces the MAIN -> display frame packer's (FUN_0838E85E) last sub-packer
! call (0x0838EC76..0x0838EC86: 0x083904A8 with the fpscr masks around it;
! repeated first), on its normal path only: modes 1/3/4 with a clean model.
! The update stream (mode 2) and the dirty-model frames branch past it.
!
! Every frame: the target = the master the heartbeat model names (0x0B568C9C
! +0xA4, another deck than +0x5C) and what it plays (MAIN's LINK status table
! 0x0A371D3C + player * 0x124: +0x28 source player / slot / type, +0x2C rbid;
! a rekordbox track only, else none). A new target drops whatever was under
! way (its heap blocks freed) and restarts:
!   1  control record, valid 0 (the display drops the old waveform at once);
!      no target: done
!   2  request: the DB task (mailbox *0x09435CC8, helper 0x084A009A, code
!      0x433 = the stock CUEWAV requester's PWV5 fetch) with the tid {source
!      player (0 = this deck's own media), slot, type, rbid} and W8MBX as the
!      reply mailbox; w8cap (main_w8cap.s) keeps the reply and fetches the
!      grid with it
!   3  wait for w8cap; a reply for an older target is freed, no PWV5 = done
!      (the control stays invalid)
!   4  the PWV5 entries streamed (kind 0), their block freed; then the grid
!      (kind 1: the PQT2 tag from the .EXT, header + beats), its block freed
!   7  control record, valid 1
! Streams go out through the stock chunk sender 0x083913C2 (type 0x31, at
! most 0x2000 bytes a frame, only while the frame has room: budget
! *0x09A30330 > 0x2030), charged as the stock detail packer charges its own
! (budget, position *0x09A2FAAC, the frame's message count). The chunk index
! carries the kind: kind << 14 | chunk (1-based); kind 2 = the control record.
!
! Contract (sigpatch call_site, hook=False): entered by jsr with r14 = the
! packer's fpscr mask; r0-r7 free (r6/r7 are dead after the span, r1 is
! reloaded right after it), r8-r14 kept.

	.include "layout.inc"
	.include "w8.inc"

	.text
	.global w8send
w8send:
	sts.l	pr,@-r15
	sts	fpscr,r6		! the replaced code
	and	r14,r6
	lds	r6,fpscr
	mov.l	l_pk,r3
	jsr	@r3
	nop
	sts	fpscr,r7
	and	r14,r7
	lds	r7,fpscr
	mov.l	l_boot,r1		! V3rc3 update safety: only on a normal boot (MAIN boot state
	mov.l	@r1,r0			! 0x0A35DF3C == 1): else nothing but the replaced stock call --
	cmp/eq	#1,r0			! no DB request, no heap block (w8cap then never sees a reply of ours)
	bt	2f
	lds.l	@r15+,pr
	rts
	nop
2:	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	l_s,r8
	mov	r8,r9
	add	#0x40,r9
	mov.l	@r8,r0
	mov.l	l_magic,r1
	cmp/eq	r1,r0
	bt	1f
	mov	#48,r3			! once: the block (erased flash at boot) and W8N zeroed
	mov	r8,r2
	mov	#0,r0
0:	mov.l	r0,@r2
	dt	r3
	bf/s	0b
	add	#4,r2
	mov.l	r1,@r8

	! ---- the target ----
1:	mov.l	l_hb,r1
	mov	#0x5C,r0
	mov.l	@(r0,r1),r2		! this deck's player number
	mov	#0x52,r0
	shll	r0
	mov.l	@(r0,r1),r3		! +0xA4 the master's
	mov	#0,r4
	mov	#0,r5
	cmp/eq	r2,r3
	bt	3f
	mov	r3,r0
	add	#-1,r0
	mov	#6,r1
	cmp/hs	r1,r0
	bt	3f			! none (0) / not 1..6
	mov	#0x49,r1
	shll2	r1			! 0x124 a player
	mulu.w	r3,r1
	mov.l	l_tab,r6
	sts	macl,r1
	add	r1,r6
	mov.l	@r6,r4			! source player | slot << 8 | type << 16
	mov.l	@(4,r6),r5		! rbid
	shll8	r4
	shlr8	r4
	mov	r4,r0
	shlr16	r0
	cmp/eq	#1,r0			! a rekordbox track
	bt	2f
	mov	#0,r4
	bra	3f
	mov	#0,r5
2:	extu.b	r4,r0
	cmp/eq	r2,r0			! on this deck's own media: a local tid (player 0)
	bf	4f
	xor	r0,r4
4:	shll8	r3
	shll16	r3
	or	r3,r4			! | the master << 24
3:	mov.l	@(KEY,r8),r0
	cmp/eq	r4,r0
	bf	6f
	mov.l	@(RBID,r8),r0
	cmp/eq	r5,r0
	bt	run

	! ---- a new target: drop what was under way ----
6:	mov.l	r4,@(KEY,r8)
	mov.l	r5,@(RBID,r8)
	mov.l	r4,@(CTL+8,r9)
	mov.l	r5,@(CTL+12,r9)
	mov	#0,r0
	mov.l	r0,@(CTL+4,r9)		! invalid
	mov.l	r0,@(CTL+16,r9)		! no PWV5 / grid yet
	mov.l	r0,@(0x38,r9)		! V3rc2: no master key yet (W8S +0x78, w8cap route B)
	mov.l	r0,@(CTL+20,r9)
	mov.l	r0,@(D_LEFT,r8)		! the stream stops here
	mov.l	l_pcc,r2		! V4b1: a cue block cut off with the stream is sent again
	mov.l	r0,@(4,r2)
	mov.l	l_par,r2		! V4n24: ... and so is the artwork block (a cut one never came back:
	mov.l	r0,@(4,r2)		!   its trailer stayed unmatched on the display = no cover)
	mov	#1,r1
	mov.l	r1,@(ST,r8)
	mov	r9,r2			! V4n31: an NFS lookup still open (W8N): cancelled
	add	#0x40,r2
	mov.l	r0,@(N_RCNT,r2)		! METERFIX: a new target, no retries yet
	mov.l	@(N_SEQ,r2),r1
	mov.l	@(N_ANS,r2),r3
	cmp/eq	r1,r3
	bt	5f
	mov.l	r0,@(N_KEY,r2)
5:	mov.l	@(BUF,r9),r4
	bsr	free0
	mov.l	r0,@(BUF,r9)
	mov.l	@(GBUF,r9),r4
	mov	#0,r0
	bsr	free0
	mov.l	r0,@(GBUF,r9)
	mov.l	@(RDY,r8),r0
	tst	r0,r0
	bt	run
	mov	#0,r0
	mov.l	r0,@(RDY,r8)
	mov.l	@(GPTR,r9),r4
	bsr	free0
	nop
	bsr	free0
	mov.l	@(RPTR,r8),r4

	! ---- the stream: one chunk a frame while the frame has room ----
run:	mov.l	@(D_LEFT,r8),r0
	tst	r0,r0
	bt	idle
	mov.l	l_budget,r6
	mov.l	@r6,r1
	mov.w	l_ch,r2			! V4b1: the room a chunk needs = its size + 0x30 (0x2030 for a full one;
	cmp/hs	r2,r0			! the small cue block no longer waits for a frame that big)
	bt	1f
	mov	r0,r2
1:	add	#0x30,r2
	cmp/hi	r2,r1
	bf	ret
	mov.w	l_ch,r6
	mov	r6,r10
	cmp/hs	r6,r0
	bt	7f
	mov	r0,r10			! the last, shorter chunk
7:	mov	r8,r4
	add	#DESC,r4
	mov.l	l_send,r0
	jsr	@r0
	mov	#0x31,r5
	mov.l	l_budget,r6		! charged as the stock detail packer does
	mov.l	@r6,r1
	mov	r10,r2
	add	#0x30,r2
	sub	r2,r1
	mov.l	r1,@r6
	mov.l	l_pos,r6
	mov.l	@r6,r1
	shlr2	r10
	add	#12,r10
	add	r10,r1
	mov.l	r1,@r6
	add	#4,r6			! the frames' message counts, right after it
	mov.l	l_bi,r1
	mov.b	@r1,r0
	extu.b	r0,r0
	add	r0,r6
	mov.b	@r6,r1
	add	#1,r1
	bra	ret
	mov.b	r1,@r6

	! ---- the descriptor is idle: the next step ----
idle:	mov	r9,r2			! V4n31: an NFS answer (touch_audio w8n) not taken yet
	add	#0x40,r2
	mov.l	@(N_ANS,r2),r0
	mov.l	@(N_CON,r2),r1
	cmp/eq	r1,r0
	bt	1f
	bra	reap
	nop
1:	mov.l	@(ST,r8),r0
	cmp/eq	#5,r0
	bf	1f
	bra	st5
	nop
1:	cmp/eq	#6,r0			! METERFIX: a "none" target waiting for its retry
	bf	1f
	bra	st6
	nop
1:	cmp/eq	#1,r0
	bt	st1
	cmp/eq	#2,r0
	bt	st2
	cmp/eq	#3,r0
	bt	st3
	cmp/eq	#4,r0
	bt	st4
	cmp/eq	#7,r0
	bt	st7
	tst	r0,r0
	bf	ret
	! V4b1: ST 0 (nothing under way): the cue block (kind 3) when touch_audio published a new one
st0:	mov.l	l_pcc,r1
	mov.l	@r1,r2			! CC_SEQ
	mov.l	@(4,r1),r3		! CC_SENT
	cmp/eq	r2,r3
	bt	a4
	tst	r2,r2
	bt	a4
	mov.l	@(8,r1),r5		! CC_TOT
	mov.w	l_cmax,r0
	cmp/hi	r0,r5
	bt	a4			! (erased flash before touch_audio zeroes it)
	mov.l	r2,@(4,r1)
	mov.l	l_pco,r4
	bra	setup
	mov	#3,r6
a4:	mov.l	l_par,r1		! G2: the loaded track's artwork block (kind 3, chunks 0x21..0x24), same scheme
	mov.l	@r1,r2			! AR_SEQ
	mov.l	@(4,r1),r3		! AR_SENT
	cmp/eq	r2,r3
	bt	ret
	tst	r2,r2
	bt	ret
	mov.l	@(8,r1),r5		! AR_TOT
	mov.w	l_amax,r0
	cmp/hi	r0,r5
	bt	ret
	mov.l	r2,@(4,r1)
	mov.l	l_pab,r4		! (kind 3 chunks 0x21.. : the index field is 16 bits, kind 4 would not fit)
	mov.l	r4,@(D_PTR,r8)
	mov	#0,r0
	mov.l	r0,@(D_OFF,r8)
	mov.l	l_aidx,r6
	mov.l	r6,@(D_IDX,r8)
	mov.w	l_chm1,r0
	add	r5,r0
	shlr8	r0
	shlr2	r0
	shlr2	r0
	shlr	r0			! chunks
	add	r6,r0
	mov.l	r0,@(D_LAST,r8)
	mov.l	r5,@(D_LEFT,r8)
	bra	ret
	nop
st7:	mov	#1,r0			! 7: the control record, valid
	mov.l	r0,@(CTL+4,r9)
	bra	ctl
	mov	#0,r1
st1:	mov.l	@(KEY,r8),r0		! 1: the control record, invalid; then fetch
	mov	#0,r1
	tst	r0,r0
	bt	ctl
	mov	#2,r1
ctl:	mov.l	r1,@(ST,r8)
	mov	r9,r4
	add	#CTL,r4
	mov	#32,r5
	bra	setup
	mov	#2,r6

st3:	mov.l	@(RDY,r8),r0		! 3: wait for w8cap
	tst	r0,r0
	bf	3f
	bra	st3w			! V4n31: no reply in 10 s -> the NFS lookup; V4n24: meanwhile the cue /
	nop				!   artwork blocks (a DB reply that never comes kept them from going out)
3:	mov	#0,r0
	mov.l	r0,@(RDY,r8)
	mov.l	@(RPTR,r8),r4
	mov.l	@(GPTR,r9),r5
	mov.l	@(RRB,r8),r0
	mov.l	@(RBID,r8),r1
	cmp/eq	r1,r0
	bf	drop			! for an older target: keep waiting
	tst	r4,r4
	bf	take
	bsr	free0			! no PWV5 there (a CDJ-3000 master): its grid dropped,
	mov	r5,r4			! V4n31: the master's medium read over NFS instead
	bra	nfs
	nop
drop:	bsr	free0			! drop both
	mov	r5,r10
	bsr	free0
	mov	r10,r4
	bra	ret
	nop
take:	mov.l	r4,@(BUF,r9)
	mov.l	r5,@(GBUF,r9)		! its grid, streamed after it
	mov.l	@(4,r4),r5		! the block: n, n * 2, 2, 150, ?, -> entries (+20)
	mov.l	r5,@(CTL+16,r9)
	add	#20,r4
	add	#3,r5
	mov	#-4,r0
	and	r0,r5
	mov	#4,r0
	mov.l	r0,@(ST,r8)
	bra	setup
	mov	#0,r6

st2:	mov	#3,r0			! 2: ask the DB task
	mov.l	r0,@(ST,r8)
	mov.l	l_tick,r1		! (V4n31: its start, for the 10 s limit)
	mov.l	@r1,r1
	mov.l	r1,@(TMR,r8)
	mov.l	@(RBID,r8),r1
	add	#-40,r15		! the helper's ten stack words (+40.. of the message)
	mov.l	r1,@r15
	mov.l	@(KEY,r8),r7
	shll8	r7
	shlr8	r7			! the tid word
	mov.w	l_mbx,r6
	mov.l	l_dbmbx,r5
	mov.l	@r5,r5
	mov.w	l_code,r4
	mov.l	l_req,r0
	jsr	@r0
	nop
	bra	ret
	add	#40,r15

st4:	mov.l	@(BUF,r9),r4		! 4: a block sent: free it; the grid next, if any
	bsr	free0
	nop
	mov.l	@(GBUF,r9),r4
	mov	#0,r0
	mov.l	r0,@(GBUF,r9)
	tst	r4,r4
	bt/s	st7
	mov.l	r4,@(BUF,r9)
	mov.l	@(12,r4),r5		! the grid: [u32][the PQT2 tag: its length at +8, BE]
	swap.b	r5,r5
	swap.w	r5,r5
	swap.b	r5,r5
	mov.w	l_gmax,r0		! at most 32 KB (the display keeps 64)
	cmp/hs	r0,r5
	bf	1f
	mov	r0,r5
1:	add	#3,r5
	mov	#-4,r0
	and	r0,r5
	mov.l	r5,@(CTL+20,r9)
	add	#4,r4
	mov	#1,r6

	! r4 data, r5 bytes (a multiple of 4), r6 kind: arm the descriptor
setup:	mov.l	r4,@(D_PTR,r8)
	mov	#0,r0
	mov.l	r0,@(D_OFF,r8)
	shll8	r6
	shll2	r6
	shll2	r6
	shll2	r6			! kind << 14
	mov.l	r6,@(D_IDX,r8)
	mov.w	l_chm1,r0
	add	r5,r0
	shlr8	r0
	shlr2	r0
	shlr2	r0
	shlr	r0			! chunks
	add	r6,r0
	mov.l	r0,@(D_LAST,r8)
	mov.l	r5,@(D_LEFT,r8)
ret:	mov.l	@r15+,r10
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	lds.l	@r15+,pr
	rts
	nop

free0:	tst	r4,r4			! free(r4) unless 0
	bt	1f
	mov.l	l_free,r0
	jmp	@r0
	nop
1:	rts
	nop

	.p2align 1
l_room:		.word	0x2030
l_ch:		.word	0x2000
l_chm1:		.word	0x1FFF
l_mbx:		.word	W8MBX
l_code:		.word	0x433
l_gmax:		.word	0x7FFC
l_cmax:		.word	0x1010
l_amax:		.word	0x6700		! artwork block: 16 + 26208 + 4 bytes at most
	.p2align 2
l_pk:		.long	0x083904A8		! the replaced sub-packer
l_pcc:		.long	RAMB+0x15010		! touch_audio's cue block control (+0 seq, +4 sent, +8 bytes)
l_pco:		.long	RAMB+0x14000		! the cue block: header 'PCO2' + PCO2 tags (kind 3)
l_par:		.long	RAMB+0x15030		! touch_audio's artwork block control (+0 seq, +4 sent, +8 bytes)
l_pab:		.long	RAMB+0x15100		! the artwork block: 'PART' header, 109 x 117 RGB565, trailer
l_aidx:		.long	0xC020			! 3 << 14 + 0x20: the first chunk is index 0xC021
l_boot:		.long 0x0A35DF3C	! MAIN boot state (1 = normal boot)
l_s:		.long	W8S
l_magic:	.long	0x31463857		! 'W8F1'
l_hb:		.long	0x0B568C9C		! the heartbeat model (message 0x03)
l_tab:		.long	0x0A371D3C+0x28		! LINK status table, + 0x28
l_budget:	.long	0x09A30330		! the frame's bytes left
l_pos:		.long	0x09A2FAAC		! the frame's write position (words); +4 the counts
l_bi:		.long	0x10DC151E		! which frame buffer
l_send:		.long	0x083913C2		! the stock chunk sender (desc, type, max)
l_dbmbx:	.long	0x09435CC8		! -> the DB task's mailbox
l_req:		.long	0x084A009A		! DB request helper (code, mbx, reply mbx, tid, rbid..)
l_free:		.long	0x08344B42
l_tick:		.long	0x0B0C5258		! 1 ms tick

! ---- V4n31 (#34): the NFS lookup (W8N, w8.inc) for a master whose DB answers no PWV5 ----
st3w:	mov.l	m_tick,r1		! 3, no reply yet: 10 s at most (a late one is freed by w8cap)
	mov.l	@r1,r1
	mov.l	@(TMR,r8),r0
	sub	r0,r1
	mov.w	m_t3,r0
	cmp/hi	r0,r1
	bt	nfs
	bra	st0
	nop
nfs:	mov.l	m_kill,r0		! V4n36 trace: MASTER WAVE NFS killed (modsmenu kill_v +4 = 0) -> no NFS
	mov.l	@(4,r0),r0		!   lookup (the flat line / grid alone, as before V4n31)
	tst	r0,r0
	bt	none
	mov.l	@(KEY,r8),r0		! the master plays from a LINKed medium: ask touch_audio
	extu.b	r0,r0
	tst	r0,r0
	bt	none			! this deck's own media: nothing more to read
	mov	r9,r2
	add	#0x40,r2
	mov.l	@(KEY,r8),r0		! KEY, RB, then SEQ + 1
	mov.l	r0,@(N_KEY,r2)
	mov.l	@(RBID,r8),r0
	mov.l	r0,@(N_RB,r2)
	mov.l	@(N_SEQ,r2),r0
	add	#1,r0
	mov.l	r0,@(N_SEQ,r2)
	mov.l	m_tick,r1
	mov.l	@r1,r1
	mov.l	r1,@(TMR,r8)
	mov	#5,r0
	bra	ret
	mov.l	r0,@(ST,r8)
none:	mov.l	m_tick,r1		! METERFIX (deck V4n45: no wave for a master track that was playing
	mov.l	@r1,r1			! before this deck had a DB session / the medium mounted): not done --
	mov.l	r1,@(TMR,r8)		! retried after 12, 24, 48, then every 60 s while the target stays
	mov	#6,r0			! (the control stays invalid meanwhile)
	bra	ret
	mov.l	r0,@(ST,r8)
	! 6: the retry wait; meanwhile st0's blocks. Then the DB request again (st2 -> st3 -> NFS as before)
st6:	mov	r9,r2
	add	#0x40,r2
	mov.l	@(N_RCNT,r2),r3
	mov.l	m_t6,r0			! 12 s << min(retries, 2), at most 60 s
	mov	#2,r1
	cmp/hi	r1,r3
	bf	1f
	mov	#2,r3
1:	shld	r3,r0
	mov.l	m_t6max,r1
	cmp/hi	r1,r0
	bf	1f
	mov	r1,r0
1:	mov.l	m_tick,r1
	mov.l	@r1,r1
	mov.l	@(TMR,r8),r3
	sub	r3,r1
	cmp/hi	r0,r1
	bt	1f
	bra	st0
	nop
1:	mov.l	@(N_RCNT,r2),r3
	add	#1,r3
	mov.l	r3,@(N_RCNT,r2)
	bra	st2
	nop
	! 5: wait for the NFS lookup, 60 s at most (then cancelled: KEY 0); meanwhile st0's blocks
st5:	mov.l	m_tick,r1
	mov.l	@r1,r1
	mov.l	@(TMR,r8),r0
	sub	r0,r1
	mov.l	m_t5,r0
	cmp/hi	r0,r1
	bt	1f
	bra	st0
	nop
1:	mov	r9,r2
	add	#0x40,r2
	mov	#0,r0
	mov.l	r0,@(N_KEY,r2)
	bra	st0
	mov.l	r0,@(ST,r8)
	! an answer (r0 = ANS, r2 = W8N): ours (ST 5, the open request) is streamed as a DB reply would
	! be; any other has its blocks freed
reap:	mov.l	r0,@(N_CON,r2)		! taken
	mov.l	@(N_PTR,r2),r4
	mov.l	@(N_GPTR,r2),r5
	mov.l	@(N_SEQ,r2),r1
	cmp/eq	r1,r0
	bf	1f
	mov.l	@(ST,r8),r0
	cmp/eq	#5,r0
	bf	1f
	tst	r4,r4
	bt	none
	bra	take
	nop
1:	bra	drop
	nop
	.p2align 1
m_t3:		.word	10000		! ms: the DB reply, at most
	.p2align 2
m_tick:		.long	0x0B0C5258		! 1 ms tick
m_t5:		.long	60000		! ms: the NFS lookup, at most
m_t6:		.long	12000		! METERFIX: the first retry of a "none" target (ms)
m_t6max:	.long	60000		! METERFIX: the longest wait between retries (ms)
m_kill:		.long	KILLB		! V4n36 trace: modsmenu's kill switches (layout.inc)
