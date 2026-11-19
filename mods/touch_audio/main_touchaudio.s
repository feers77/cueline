! SPDX-License-Identifier: Apache-2.0
!
! touch_audio: Link Cue for the CDJ-2000NXS2 MAIN firmware (SH7724, SH-4,
! little-endian, v1.87). The deck joins a DJM-A9's LINK CUE as a CDJ-3000
! Touch Audio source: a track the browser highlights (INFO open, or a browse
! row with the rowwave mod) or the loaded track while it plays (Touch Cue) is
! streamed to the mixer's headphones from the point a finger holds on the
! overview strip. See README.md for the use, the firmware facts and the
! diagnostics; re/LINKCUE_NATIVE.md and re/M0_HANDOFF.md for the history.
!
! The hook (DJCONT_PASS, shared with other mods) creates the task "TchAud"
! (priority 9, 4 KB stack + buffers from the firmware's malloc) once. The task:
!   1. announces a device-17 "CDJ-3000" keepalive to the mixer (unicast, 200 ms)
!      and takes its timing packets (type 0x20, 7 ms) on UDP 50004;
!   2. resolves the track: its rekordbox id -> export.pdb row (an index of the
!      track table, built a few pages a pass) -> file path and ANLZ (PWAV for
!      the strip), on the medium the list browses or the loaded track came
!      from (own USB/SD, or a LINKed player's media over the firmware's NFS
!      mount: medium_letter / set_medium);
!   3. opens the file (WAV here; MP3/FLAC through the tadec blob; AIFF is
!      out for now: the deck's updater caps the MAIN section),
!      converts to 48 kHz s16 stereo, and sends one 0x1e packet (336 frames)
!      per timing packet while the finger is down -- the mixer's clock paces
!      us; the 1 ms tick only when no timing arrives;
!   4. draws the preview into the overview strip (600 records) and keeps it
!      there, giving it back when INFO closes or the mods are switched off.
!
! Register use in the task: r8 = data (the `data` block below, reached by
! ld/st), r9 = the touch-preview state (B_TP) inside touch_preview and what it
! calls. ld / st / fw / adr are multi-instruction macros: they clobber r0 (and
! fw r1-r3) and must never sit in a delay slot (patch_main --assemble checks).
!
	.include "layout.inc"

	.equ	D_ACRE, 4
	.equ	D_STA, 8
	.equ	D_DLY, 12
	.equ	D_UCRE, 16
	.equ	D_URCV, 20
	.equ	D_USND, 24
	.equ	D_FOPEN, 28
	.equ	D_FCLOSE, 32
	.equ	D_FSEEK, 36
	.equ	D_FREAD, 40
	.equ	D_TICK, 44
	.equ	D_STATE, 48
	.equ	D_TID, 52
	.equ	D_CEP, 56
	.equ	D_FH, 60
	.equ	D_DOFF, 64
	.equ	D_DLEN, 68
	.equ	D_POS, 72
	.equ	D_C, 76
	.equ	D_DEADL, 80
	.equ	D_NEXTST, 84
	.equ	D_FIRST, 88
	.equ	D_E, 92
	.equ	D_T, 96
	.equ	D_BUF, 100
	.equ	D_PREVIEW, 104		! a finger previews (the strip, a row): send PCM
	.equ	D_LASTT, 108		! tick of the last timing packet (election timeout)
	.equ	D_EPA, 112
	.equ	D_FROM, 120
	.equ	D_CCEP, 128
	.equ	D_CTSK, 144
	.equ	D_NAME, 172
	.equ	D_HDR, 180
	.equ	D_BCAST, 224
	.equ	D_KA, 232
	.equ	D_DUE, 280		! timing packets not yet answered (the pacer;
					! past the mov #imm range: mov.w offsets)
	.equ	D_GAIN, 284		! Link Cue ramp gain, 0..512 (10.7 ms at 48 kHz)
	.equ	D_LDKEY, 288		! the deck's loaded track (status +0x28 ^ +0x2C)
	.equ	D_LATCH, 292		! a load stopped the preview: no new press
					! until the finger leaves the row

	.equ	STACK, 4096
	.equ	RX_LEN, 0x600
	.equ	TX_LEN, 0x56c
	.equ	B_RX, STACK
	.equ	B_TX, STACK + RX_LEN
	.equ	B_ST, 7024		! converter state (after B_TX + TX_LEN = 7020)
	.equ	B_SRC, B_ST + 48	! decoded s16 stereo frames (<= 337 + slack)
	.equ	B_RAW, B_SRC + 1376	! raw file bytes for one packet (<= 337 * 8)
	.equ	B_TP, B_RAW + 2752	! touch-preview state (TP_*)
	.equ	B_PAGE, B_TP + 128	! one export.pdb page
	.equ	B_BACK, B_PAGE + 4096	! the overview slot's own 600 records
	.equ	B_WAVE, B_BACK + 3600	! the INFO track's PWAV (400 columns)
	.equ	B_APATH, B_WAVE + 400	! its ANLZ path, wide
	.equ	B_RWAVE, B_APATH + 520	! rowwave: a browse row's PWAV (400 columns)
	.equ	B_RW4, B_RWAVE + 400	! rowwave: its PWV4 colour preview (1200 x 6 B)
	.equ	B_PDBP, B_RW4 + 7200	! "X:/PIONEER/rekordbox/export.pdb" wide, X = the
	.equ	B_END, B_PDBP + 80	!   current medium's letter (set_medium)
	.equ	MED, RAMB+0x1F700	! the medium state (words): +0 key of the medium the
					! index / export.pdb belong to (player << 8 | slot;
					! 0 none), +4 its drive letter (wide), +8 / +12 the
					! own C: / B: export.pdb handles (kept open), +16 the
					! medium's media record, +20 the Touch Cue track's
					! medium key, +24 the resolved row's file type, +28 /
					! +32 / +36 a cut-short table walk (page, pages left,
					! id), +40 pages read by this walk call, +44 / +48 / +52
					! browse_key's debounce (raw key, its tick, the settled key),
					! +56 / +60 row_waves' debounce (the wanted rows'
					! signature, the tick it last changed)
	.equ	TP_ID, 0		! rekordbox id shown in INFO (0: none)
	.equ	TP_ACT, 4		! the strip shows our waveform (slot backed up)
	.equ	TP_OK, 8		! track resolved: its audio path is known
	.equ	TP_COL, 12		! column of the last (re)seek
	.equ	TP_OPEN, 16		! the resolved track is the open file
	.equ	TP_MARK, 20		! column painted as the position mark (-1: none)
	.equ	TP_NEXTM, 24		! tick of the next mark update
	.equ	TP_FH, 28		! scratch file handle (pdb / ANLZ)
	.equ	TP_PS, 32		! pdb page size
	.equ	TP_P, 36		! pdb page being read
	.equ	TP_LAST, 40		! pdb track table's last page
	.equ	TP_N, 44		! pages left (loop guard)
	.equ	TP_TOK, 48		! overview slot lock token
	.equ	TP_XRETRY, 52		! index failed: tick to try building it again
	.equ	TP_PEND, 56		! the last lookup waited for the index (no walk)
	.equ	TP_HASH, 60		! Touch Cue: rekordbox id of the loaded track
	.equ	TP_BAD, 64		! INFO id whose lookup failed (not in export.pdb)
	.equ	TP_WAVE, 68		! the resolved track's PWAV was read (B_WAVE)
	.equ	TP_IDX, 76		! rowwave: export.pdb index, u16 page per track id
	.equ	TP_XP, 80		! index build: next page
	.equ	TP_XL, 84		!   the track table's last page
	.equ	TP_XN, 88		!   pages left (loop guard)
	.equ	TP_XS, 92		!   0 not started, 1 building, 2 ready, 3 failed
	.equ	TP_RW, 96		! tp_resolve for a browse row: no INFO/preview state
	.equ	TP_RWOK, 100		!   its PWAV is in B_RWAVE
	.equ	TP_ROWON, 104		! the preview playing is a browse row's
	.equ	TP_RWC, 108		! rowwave: B_RW4 holds the row's PWV4
	.equ	TP_RWN, 112		!   the row (1-8) being looked up
	.equ	TP_KS, 116		!   key names: 0 not read yet, 1 read (or none)
	.equ	CC_SEQ, 0		! V4b1 cue block control (RAMB+0x15010, LE words): published seq (0: none)
	.equ	CC_SENT, 4		!   the seq w8send streamed last
	.equ	CC_TOT, 8		!   bytes to stream (16 + tags, rounded to 4)
	.equ	CC_KEY, 12		!   the loaded track's status +0x28 / +0x2C the block is for
	.equ	CC_RB, 16
	.equ	CC_STATE, 20		!   1 = its tags are not read yet
	.equ	CC_TRY, 24		!   lookups tried
	.equ	AR_SEQ, 0		! G2 artwork block control (RAMB+0x15030, LE words): published seq (0: none)
	.equ	AR_SENT, 4		!   the seq w8send streamed last (kind 4)
	.equ	AR_TOT, 8		!   bytes to stream
	.equ	AR_STATE, 12		!   != 0: the loaded track's artwork is not decoded yet (V4n24: tries | soft << 8)
	.equ	AR_T, 16		!   V4n24: tick of the last artwork try (rv_cue retries 1 s later)
	.equ	TITL_OFF, 0xF80		! V4n24: the cue block's 'TITL' record (magic, rbid, n, <= 64 UTF-16BE chars)
	.equ	CC_OK, 28		!   tr_pco2 walked the .EXT
	.equ	TP_JBUF, 120		!   artwork: file 16 KB, tadec arena 96 KB, 20x20 out
	.equ	T_RETRY, 0x58		! rowwave table: retry[9] (fila gris fix), free +0x58..+0x7B
	.equ	RW_RETRY_MAX, 30	!   latch done[n] after this many colour-fetch misses
	.equ	TP_CACHE, 124		! rowwave: the row cache (malloc'd once; 0 not yet, 1 failed)
	.equ	RC_N, 1024		!   entries, direct-mapped by id & (RC_N - 1)
	.equ	RC_E, 0x11F0		!   entry: id, medium key, 8 B free, cell 0x1180, text 0x60
	.equ	RW_SETTLE, 120		! ms the wanted rows must hold before a file is read
	.equ	TP_PDB, 72		! export.pdb, opened once and kept open: the
					! firmware's own database layer uses that file
					! too, and closing it from here breaks its loads
	.equ	ST_STEP, 0
	.equ	ST_FRAC, 4
	.equ	ST_HAVE, 8
	.equ	ST_ALIGN, 12
	.equ	ST_BITS, 16
	.equ	ST_CH, 20
	.equ	ST_FPC, 24		! source frames per strip column (track / 600)
	.equ	ST_FMT, 28		! sample format flags: 1 big-endian, 2 float
	.equ	ST_CODEC, 32		! 1: MP3/FLAC through the tadec blob (D_FH = sentinel)
	.equ	ST_UNDER, 36		! MP3/FLAC: TchDec's ring had nothing for this packet
					! (the last frame held, apply_gain fades it out)

	.macro	fw fn
	mov.l	@(\fn,r8),r1
	mov.l	@r8,r2
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
	.endm

! ld / st: a data field by offset. BOTH CLOBBER r0 (the offset goes through
! r0): never `st r0,...`, and never keep a value in r0 across them.
	.macro	ld reg, off
	mov	#\off,r0
	mov.l	@(r0,r8),\reg
	.endm
	.macro	st reg, off
	mov	#\off,r0
	mov.l	\reg,@(r0,r8)
	.endm

! Address of data + the offset held in the .word at \offlit, into \reg.
! Clobbers r0; \reg must not be r0.
	.macro	adr reg, offlit
	mov.w	\offlit,r0
	mov	r8,\reg
	add	r0,\reg
	.endm

	.text
	.global touchaudio
! The spawn hook (DJCONT_PASS). r0-r7 free; r8 and pr saved (calls are made).
touchaudio:
	mov.l	h_boot,r1		! V3rc3 update safety: the task only on a normal boot (MAIN boot
	mov.l	@r1,r0			! state 0x0A35DF30 +0xC: 1 normal, 2 a USB / SD update; the stock
	cmp/eq	#1,r0			! updater task UpDtae_TASK waits for it in 0x084F3D14): in update
	bt	0f			! mode (or before it is decided) nothing of ours runs -- no TchAud
	rts				! (no LINK keepalive, file I/O, index, row cache, mm_publish)
	nop
0:	mova	h_pool,r0
	mov.l	@r0,r1
	add	r0,r1			! data
	mov.l	@(D_STATE,r1),r2
	cmp/pz	r2
	bf	9f
	add	#1,r2
	mov.l	r2,@(D_STATE,r1)
	mov.w	h_wait,r3
	cmp/hs	r3,r2
	bf	9f
	sts.l	pr,@-r15
	mov.l	r8,@-r15
	mov	r1,r8
	mov.l	h_shared,r1		! clear the shared block once (A9-valid, sel-valid)
	mov	#0,r2
	mov.l	r2,@r1
	mov.l	r2,@(12,r1)
	mov.l	r2,@(28,r1)
	mov.l	r2,@(32,r1)		! sel-valid (browser-highlighted path)
	mov.w	h_buflen,r4
	mov.l	h_malloc,r1
	mov.l	@r8,r2
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
	mov	#-2,r2
	tst	r0,r0
	bt	1f
	mov	#D_BUF,r1
	add	r8,r1
	mov.l	r0,@r1			! D_BUF = the malloc'd block
	mov.w	h_ctsk,r5
	add	r8,r5			! T_CTSK
	mov.l	h_entry,r1
	add	r8,r1
	mov.l	r1,@(8,r5)		! task
	ld	r1,D_BUF
	mov.l	r1,@(20,r5)		! stk
	mov.w	h_name,r1
	add	r8,r1
	mov.l	r1,@(24,r5)		! name
	mov	#0,r4
	fw	D_ACRE
	mov	#-2,r2
	cmp/pl	r0
	bf	1f
	mov	#D_TID,r1
	add	r8,r1
	mov.l	r0,@r1			! D_TID = the task id
	mov	r0,r4
	mov	#0,r5
	fw	D_STA
	mov	#-1,r2
1:	st	r2,D_STATE
	mov.l	@r15+,r8
	lds.l	@r15+,pr
9:	rts
	nop

h_wait:		.word 1000
h_ctsk:		.word D_CTSK
h_name:		.word D_NAME
h_buflen:	.word B_END
	.p2align 2
h_pool:		.long data - h_pool
h_boot:		.long 0x0A35DF3C	! MAIN boot state (1 = normal boot)
h_entry:	.long task - data
h_malloc:	.long 0x08344A9C
h_shared:	.long RAMB+0x1F800

! The task. r8 = data for good; never returns.
task:
	mova	t_pool,r0
	mov.l	@r0,r8
	add	r0,r8
	mov	#0,r1			! audio endpoint starts zero; A9 ip copied
	st	r1,D_EPA		! in from the shared block each loop
	adr	r2, l_epab
	mov.w	t_p50004b,r0
	mov.w	r0,@(4,r2)		! D_EPA + 4 = port 50004

1:	adr	r4, l_ccepb		! udp_vcre_cep(&CCEP) -> 50004
	mov	#0,r1
	mov.l	r1,@r4
	mov.l	r1,@(4,r4)
	mov.l	r1,@(12,r4)
	mov.w	t_p50004b,r0
	mov.w	r0,@(8,r4)
	fw	D_UCRE
	cmp/pl	r0
	bt	2f
	mov.w	t_1000b,r4
	fw	D_DLY
	bra	1b
	nop
t_p50004b:	.word 50004		! (the loop's pool is out of mov.w range)
t_1000b:	.word 1000
l_epab:		.word D_EPA
l_ccepb:	.word D_CCEP
2:	mov	#D_CEP,r1
	add	r8,r1
	mov.l	r0,@r1			! D_CEP = the 50004 socket

	! copy the 0x1e header template into B_TX
	ld	r1,D_BUF
	mov.w	t_btxb,r0
	add	r0,r1
	adr	r2, l_hdrb
	mov	#0x2c,r3
3:	mov.b	@r2+,r0
	mov.b	r0,@r1
	add	#1,r1
	dt	r3
	bf	3b

	ld	r1,D_BUF		! touch-preview state: nothing shown yet
	mov.w	t_btpb,r0
	add	r0,r1
	mov	#0,r2
	mov.l	r2,@(TP_ID,r1)
	mov.l	r2,@(TP_ACT,r1)
	mov.l	r2,@(TP_OK,r1)
	mov.l	r2,@(TP_OPEN,r1)
	mov.l	r2,@(TP_NEXTM,r1)
	mov	#TP_BAD,r0
	mov.l	r2,@(r0,r1)
	mov	#TP_PDB,r0
	mov.l	r2,@(r0,r1)
	mov	#TP_IDX,r0		! rowwave: no index, not rendering
	mov.l	r2,@(r0,r1)
	mov	#TP_XS,r0
	mov.l	r2,@(r0,r1)
	mov	#TP_RW,r0
	mov.l	r2,@(r0,r1)
	mov	#TP_ROWON,r0
	mov.l	r2,@(r0,r1)
	mov	#TP_KS,r0
	mov.l	r2,@(r0,r1)
	mov	#TP_JBUF,r0
	mov.l	r2,@(r0,r1)
	mov	#TP_CACHE,r0
	mov.l	r2,@(r0,r1)
	mov.l	r2,@(TP_XRETRY,r1)	! (idx_step's batch clock while building)
	mov.l	r2,@(TP_HASH,r1)
	mov	#-1,r2
	mov.l	r2,@(TP_MARK,r1)
	mov.l	t_cnt,r1		! the counters (24 words) and the strip-owner
	mov	#24,r3			! word start at zero
	mov	#0,r2
1:	mov.l	r2,@r1
	add	#4,r1
	dt	r3
	bf	1b
	mov.l	t_owner,r1
	mov.l	r2,@r1
	mov.l	t_cc,r1			! V4b1: the cue block's control words and header start empty
	mov	#16,r3			! (G2: + the artwork block's control words at +0x20)
2:	mov.l	r2,@r1
	add	#4,r1
	dt	r3
	bf	2b
	mov.l	t_cp,r1
	mov.l	r2,@r1
	mov.l	r2,@(4,r1)
	mov.l	r2,@(8,r1)
	mov.l	r2,@(12,r1)
	mov.l	t_med,r1		! no medium yet (idx_step picks the own USB)
	mov.l	r2,@r1
	mov.l	r2,@(4,r1)
	mov.l	r2,@(8,r1)
	mov.l	r2,@(12,r1)
	mov.l	r2,@(44,r1)		! browse_key's debounce: none seen, none settled
	mov.l	r2,@(48,r1)
	mov.l	r2,@(52,r1)
	mov.l	r2,@(56,r1)		! row_waves' debounce
	mov.l	r2,@(60,r1)
	mov	#1,r1
	st	r1,D_FIRST
	mov	#0,r1
	st	r1,D_C
	st	r1,D_POS
	st	r1,D_E
	st	r1,D_T
	st	r1,D_PREVIEW
	st	r1,D_LASTT
	st	r1,D_NEXTST
	mov.l	@(D_TICK,r8),r1
	mov.l	@r1,r1
	st	r1,D_DEADL

loop:
.ifdef TESTHOOK
	mova	t_thb,r0		! TEST builds (touchaudiot): autotest / usblog ticks
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1
	nop
.endif
	mova	t_bbx,r0		! V4n37 bbox: the BLACK BOX tick (mods/bbox; patch_main place_bbox
	mov.l	@r0,r1			! writes its entry here, 0 = not in the build)
	tst	r1,r1
	bt	0f
	mov	r8,r4
	mov.l	@r8,r2			! (as fw, with the callee already in r1)
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
0:	mova	t_ksb,r0		! kill switch: C:/NOMODS on the medium stops
	mov.l	@r0,r1			! everything this task does (and the hooks
	add	r0,r1			! that read 0x081FF7F0) until it is gone
	jsr	@r1
	nop
	tst	r0,r0
	bt	1f
	mov.l	@(D_TICK,r8),r3		! off: only the browse rows' waveforms (the
	mov.l	@r3,r13			! row cell's CDJ-3000 shape is a static GUI
	mova	t_rwb,r0		! poke, so the rows keep it), no preview, no
	mov.l	@r0,r1			! LINK CUE; then idle and look again
	add	r0,r1
	jsr	@r1
	nop
	bra	6f
	nop
t_btxb:		.word B_TX		! (the init's literals: the loop's pool is out
t_btpb:		.word B_TP		! of mov.w range from there)
l_hdrb:		.word D_HDR
1:	mov.l	t_shared,r1		! copy the A9 ip in once it is known
	mov.l	@r1,r2
	tst	r2,r2
	bt	4f
	mov.l	@(4,r1),r2
	st	r2,D_EPA
	mov.w	l_bka,r0		! keepalive dst = A9 ip, port 50000
	mov	r8,r3
	add	r0,r3
	mov.l	r2,@r3
4:
3:	mov.l	@(D_TICK,r8),r3
	mov.l	@r3,r13			! now

	bsr	touch_preview		! INFO + touch on the strip -> D_PREVIEW, seeks
	nop
	ld	r1,D_PREVIEW		! while a preview streams, no index building,
	tst	r1,r1			! row lookups or artwork reads in this task
	bt	lp_rows			! (every read there is a packet late)
	ld	r1,D_FH
	tst	r1,r1
	bf	lp_diag
lp_rows:
	mova	t_rwb,r0		! row_waves: a browse row's waveform, when
	mov.l	@r0,r1			! one is wanted (out of bsr range)
	add	r0,r1
	jsr	@r1
	nop
lp_diag:
	mova	t_dgb,r0		! diag_text: the UTILITY > LINK CUE DIAG line,
	mov.l	@r0,r1			! every 500 ms (out of bsr range)
	add	r0,r1
	jsr	@r1
	nop
	mov.l	@(D_TICK,r8),r3
	mov.l	@r3,r13			! now (touch_preview may have read files)

	ld	r1,D_NEXTST			! every 200 ms: device-17 keepalive
	mov	r13,r2
	sub	r1,r2
	cmp/pz	r2
	bf	5f
	mov.l	t_shared,r1
	mov.l	@r1,r1
	tst	r1,r1
	bt	5f
	bsr	send_keepalive
	nop
	mov	r13,r1
	mov.w	ca_200,r0
	add	r0,r1
	st	r1,D_NEXTST
5:	mov	#8,r9			! drain 50004 (timing / election on our port):
7:	bsr	recv_one		! up to 8 datagrams a pass
	nop
	tst	r0,r0
	bt	2f
	dt	r9
	bf	7b
2:
	mov.l	@(D_TICK,r8),r3		! every 7 ms: one audio packet
	mov.l	@r3,r13
	ld	r1,D_LASTT		! no timing packet for 1 s: not elected any
	mov	r13,r2			! more (E, T cleared: the zero packets ask
	sub	r1,r2			! for the handover again)
	mov.w	t_1000,r0
	cmp/hs	r0,r2
	bf	2f
	ld	r1,D_E
	tst	r1,r1
	bt	2f
	mov	#0,r1
	st	r1,D_E
	st	r1,D_T
	mov.l	t_cnt,r1		! TIMEOUT++
	mov.l	@(0x20,r1),r2
	add	#1,r2
	mov.l	r2,@(0x20,r1)
2:	mov.w	l_due,r0		! paced by the mixer: one audio packet per
	mov.l	@(r0,r8),r9		! timing packet (its 48 kHz clock: no drift
	tst	r9,r9			! against our tick, which drifted into a
	bt	pc_local		! dropout every few seconds on the deck)
	mov	#12,r0
	cmp/hi	r0,r9			! more than 12 due (stalled 84 ms+): drop the
	bf	3f			! backlog, one packet
	mov	#1,r9
	mov.l	t_cnt,r1		! RESYNC++
	mov.l	@(0x10,r1),r2
	add	#1,r2
	mov.l	r2,@(0x10,r1)
3:	ld	r1,D_C			! the packets answer the timings in order:
	add	#1,r1			! the oldest due one carries latest C - (due
	sub	r9,r1			! - 1), so a pass that drained two timings
	st	r1,D_C			! fills both slots (no gap + duplicate)
4:	bsr	send_audio
	nop
	dt	r9
	bf	4b
	mov.w	l_due,r0
	mov	#0,r1
	mov.l	r1,@(r0,r8)
	mov	r13,r1			! the local pacer takes over 100 ms after the
	add	#100,r1			! last timing packet (mixer gone; the engage
	st	r1,D_DEADL		! packets before the election ride the
	bra	6f			! timing too, the mixer sends it to everyone)
	nop				! (st is two instructions: never in a delay slot)
pc_local:
	mov	#12,r2			! catch up: a task delayed by the playing deck
	mov.l	r2,@-r15		! sends up to 12 due packets back to back rather
8:	ld	r1,D_DEADL		! than skip them (a skipped packet is a gap the
	mov	r13,r2			! A9 plays as silence: the choppy Touch Cue)
	sub	r1,r2
	cmp/pz	r2			! now >= deadline ?
	bf	9f
	bsr	send_audio
	nop
	ld	r1,D_DEADL
	add	#7,r1
	st	r1,D_DEADL
	mov.l	@r15,r2
	dt	r2
	bf/s	8b
	mov.l	r2,@r15
	ld	r1,D_DEADL		! still behind after 12 (more than 84 ms): resync
	mov	r13,r2
	cmp/hs	r1,r2
	bf	9f
	st	r13,D_DEADL
	mov.l	t_cnt,r1		! RESYNC++
	mov.l	@(0x10,r1),r2
	add	#1,r2
	mov.l	r2,@(0x10,r1)
9:	add	#4,r15

6:	mov	#1,r4
	fw	D_DLY
	bra	loop
	nop
	.p2align 2
t_rwb:		.long row_waves - t_rwb
t_ksb:		.long kill_check - t_ksb
t_dgb:		.long diag_text - t_dgb
t_bbm:		.long 0x7E57A7B0	! V4n37 bbox marker: place_bbox writes the next word
t_bbx:		.long 0			!   the bbox entry (0 = none)
.ifdef TESTHOOK
t_thb:		.long test_hooks - t_thb
.endif
t_cnt:		.long RAMB+0x1FE80	! counters (README: diag)
t_owner:	.long RAMB+0x1F7F8	! 1 while our waveform is in the strip
t_med:		.long MED
t_cc:		.long RAMB+0x15010	! V4b1: the cue block's control words (CC_*)
t_cp:		.long RAMB+0x14000	! V4b1: the cue block (header 'PCO2' + tags, CUEBUF)

t_1000:		.word 1000
ca_200:		.word 200
l_due:		.word D_DUE
t_p50004:	.word 50004
t_btx:		.word B_TX
t_btp:		.word B_TP
l_epa:		.word D_EPA
l_ccep:		.word D_CCEP
l_hdr:		.word D_HDR
l_bka:		.word D_BCAST
	.p2align 2
t_pool:		.long data - t_pool
t_shared:	.long RAMB+0x1F800

! Sends the device-17 "CDJ-3000" keepalive, unicast to the A9:50000. This is
! what makes the A9 treat us as a Touch Audio peer (the election happens via
! this keepalive plus the 0x1e engage, not via any 0x29/0x30/0x31 handshake).
send_keepalive:
	sts.l	pr,@-r15
	add	#-16,r15		! own IP: getter(0, buf16) -> buf+4 (host order)
	mov.l	ss_getip,r1
	mov	r15,r5
	jsr	@r1
	mov	#0,r4
	tst	r0,r0
	bf	1f			! no address yet: keep the template's
	mov.l	@(4,r15),r1
	adr	r3, ss_kaip		! -> d_ka + 0x2c, big-endian
	mov	r1,r0
	shlr16	r0
	shlr8	r0
	mov.b	r0,@r3
	mov	r1,r0
	shlr16	r0
	mov.b	r0,@(1,r3)
	mov	r1,r0
	shlr8	r0
	mov.b	r0,@(2,r3)
	mov	r1,r0
	mov.b	r0,@(3,r3)
1:	add	#16,r15
	mov.l	ss_mac,r1		! own MAC, 6 bytes in wire order -> d_ka + 0x26
	adr	r3, ss_kamac		! (2-aligned: byte copies)
	mov	#6,r2
2:	mov.b	@r1+,r0
	mov.b	r0,@r3
	add	#1,r3
	dt	r2
	bf	2b
	mov	#-1,r1
	mov.l	r1,@-r15
	ld	r4,D_CEP
	adr	r5, ss_bcast
	adr	r6, ss_ka
	mov	#48,r7
	fw	D_USND
	add	#4,r15
	lds.l	@r15+,pr
	rts
	nop
ss_bcast:	.word D_BCAST
ss_ka:		.word D_KA
ss_kaip:	.word D_KA + 0x2c
ss_kamac:	.word D_KA + 0x26
	.p2align 2
ss_getip:	.long 0x08221D9E	! own IPv4 getter (as mods/ableton_link)
ss_mac:		.long 0x0A35F754	! own MAC

! Receives one datagram (poll) and dispatches it.
recv_one:
	sts.l	pr,@-r15
	mov	#0,r1
	mov.l	r1,@-r15		! TMO_POL
	ld	r4,D_CEP
	adr	r5, ro_from
	ld	r6,D_BUF
	mov.w	ro_rx,r0
	add	r0,r6
	mov.w	ro_rxlen,r7
	fw	D_URCV
	add	#4,r15
	cmp/pl	r0
	bf	9f
	ld	r1,D_BUF
	mov.w	ro_rx,r0
	add	r0,r1			! r1 = the datagram
	mov.l	ro_magic,r2
	mov.l	@r1,r3
	cmp/eq	r2,r3
	bf	ro_got
	mov.b	@(10,r1),r0
	extu.b	r0,r0
	mov	#0x20,r2
	cmp/eq	r2,r0
	bt	rd_timing
ro_got:	lds.l	@r15+,pr
	rts
	mov	#1,r0			! a datagram was taken
9:	lds.l	@r15+,pr
	rts
	mov	#0,r0			! nothing waiting

rd_timing:
	mov.l	ro_shared,r2		! only the A9 we learnt from its keepalive
	mov.l	@r2,r3
	tst	r3,r3
	bt	1f
	mov.l	@(4,r2),r3
	mov	#D_FROM,r0
	mov.l	@(r0,r8),r2
	cmp/eq	r3,r2
	bt	1f
	mov.l	ro_cnt,r2		! IP_REJECT++
	mov.l	@(0x24,r2),r3
	add	#1,r3
	mov.l	r3,@(0x24,r2)
	bra	ro_got
	nop
1:	mov.l	@(D_TICK,r8),r2		! the timing keeps us elected: note the tick
	mov.l	@r2,r2
	st	r2,D_LASTT
	mov.l	ro_cnt,r2		! RX_TIMING++
	mov.l	@(0x1c,r2),r3
	add	#1,r3
	mov.l	r3,@(0x1c,r2)
	mov.w	ro_due,r0		! DUE++: one audio packet per timing (the pacer)
	mov.l	@(r0,r8),r3
	add	#1,r3
	mov.l	r3,@(r0,r8)
	mov.l	@(0x24,r1),r2		! C, big-endian
	swap.b	r2,r2
	swap.w	r2,r2
	swap.b	r2,r2
	st	r2,D_C
	mov	r1,r0
	add	#0x28,r0
	mov.b	@r0,r2			! E
	extu.b	r2,r2
	st	r2,D_E
	mov	r1,r0
	add	#0x29,r0
	mov.b	@r0,r2			! T
	extu.b	r2,r2
	st	r2,D_T
	ld	r2,D_FROM		! lock the A9 ip from the timing sender
	st	r2,D_EPA
	lds.l	@r15+,pr
	rts
	mov	#1,r0

ro_rx:		.word B_RX
ro_rxlen:	.word RX_LEN
ro_from:	.word D_FROM
ro_due:		.word D_DUE
	.p2align 2
ro_magic:	.long 0x74707351	! "Qspt"
ro_shared:	.long RAMB+0x1F800	! +0 A9 known, +4 its ip (main_touchaudioip.s)
ro_cnt:		.long RAMB+0x1FE80	! counters

! Sends one 0x1e audio packet to the A9:50004 every 7 ms. With a finger down
! (D_PREVIEW) it carries PCM once the A9 has elected us (timing E=1, T=17)
! and the file is open; until then zero PCM with I=1, the engage request that
! triggers the handover. With no finger down nothing is sent (the behaviour
! proven on the deck).
send_audio:
	sts.l	pr,@-r15
	bsr	lc_onload		! a track loaded on the deck: preview off
	nop
	ld	r1,D_PREVIEW
	tst	r1,r1
	bf	sa_cont			! touching -> send
	mov.w	sa_gain,r0		! idle: a 10 ms fade-out tail while the gain
	mov.l	@(r0,r8),r1		! is above 0, then nothing (the behaviour
	tst	r1,r1			! proven on the deck)
	bt	sa_idle
	bsr	sa_hdr
	nop
	bsr	sa_engaged
	nop
	bf	sa_gz			! not engaged: drop the tail
	ld	r2,D_FH
	tst	r2,r2
	bt	sa_hold
	bsr	readpcm			! the file still open: its audio, fading
	nop
	bra	sa_tail
	nop
sa_hold:
	bsr	hold_last		! closed (another track / a load): the last
	nop				! frame held, fading to 0
sa_tail:
	bsr	apply_gain
	nop
	bra	sa_send
	nop
sa_gz:	mov	#0,r1
	mov.w	sa_gain,r0
	mov.l	r1,@(r0,r8)
sa_idle:
	lds.l	@r15+,pr
	rts
	nop
sa_cont:
	bsr	sa_hdr			! r1 = B_TX, C written
	nop
	bsr	sa_engaged		! engaged = E==1 && T==0x11 && FH!=0
	nop
	bf	sa_zero
	ld	r2,D_FH
	tst	r2,r2
	bt	sa_zero
	ld	r2,D_FIRST		! I = first
	mov	r1,r0
	add	#0x24,r0
	mov.b	r2,@r0
	mov	#0,r2
	st	r2,D_FIRST
	bsr	readpcm
	nop
	bsr	apply_gain		! fade in (10 ms) from silence
	nop
	mov.l	sa_cnt,r1		! PCM++
	mov.l	@(4,r1),r2
	add	#1,r2
	mov.l	r2,@(4,r1)
	bra	sa_send
	nop
sa_zero:
	mov	#0,r2			! silent: the next PCM fades in from 0
	mov.w	sa_gain,r0
	mov.l	r2,@(r0,r8)
	mov	#1,r2			! I = 1: engage request (triggers handover/election)
	bra	sa_zfill
	nop
sa_zfill:
	mov	r1,r0
	add	#0x24,r0
	mov.b	r2,@r0
	mov	#1,r2
	st	r2,D_FIRST
	ld	r3,D_BUF		! zero the PCM region
	mov.w	sa_btxp,r0
	add	r0,r3
	mov.w	sa_words,r0		! 0x540 / 4
	mov	#0,r2
1:	mov.l	r2,@r3
	add	#4,r3
	dt	r0
	bf	1b
	mov.l	sa_cnt,r1		! ZERO++
	mov.l	@(8,r1),r2
	add	#1,r2
	mov.l	r2,@(8,r1)
sa_send:
	mov	#-1,r1
	mov.l	r1,@-r15
	ld	r4,D_CEP
	adr	r5, sa_epa
	ld	r6,D_BUF
	mov.w	sa_btx,r0
	add	r0,r6
	mov.w	sa_txlen,r7
	fw	D_USND
	add	#4,r15
	mov.l	sa_cnt,r1		! SENT++; SND_ERR++ when the send failed
	mov.l	@r1,r2
	add	#1,r2
	mov.l	r2,@r1
	cmp/pz	r0
	bt	2f
	mov.l	@(0x18,r1),r2
	add	#1,r2
	mov.l	r2,@(0x18,r1)
2:	ld	r2,D_C			! advance C
	add	#1,r2
	st	r2,D_C
	lds.l	@r15+,pr
	rts
	nop
! sa_hdr: r1 = B_TX with C (native) big-endian at 0x28. Clobbers r0, r2.
sa_hdr:
	ld	r1,D_BUF
	mov.w	sa_btx,r0
	add	r0,r1			! r1 = B_TX
	ld	r2,D_C
	swap.b	r2,r2
	swap.w	r2,r2
	swap.b	r2,r2
	rts
	mov.l	r2,@(0x28,r1)

sa_btx:		.word B_TX
sa_btxp:	.word B_TX + 0x2c
sa_words:	.word 0x540 / 4
sa_txlen:	.word TX_LEN
sa_epa:		.word D_EPA
sa_gain:	.word D_GAIN
	.p2align 2
sa_cnt:		.long RAMB+0x1FE80	! counters: +0 SENT, +4 PCM, +8 ZERO, +0x18 SND_ERR

! sa_engaged: T = the A9 elected us (E == 1 && T == 0x11). Clobbers r0, r2.
sa_engaged:
	ld	r2,D_E
	mov	#1,r0
	cmp/eq	r0,r2
	bf	1f
	ld	r2,D_T
	mov	#0x11,r0
	cmp/eq	r0,r2
1:	rts
	nop

! apply_gain: the Link Cue ramps (as the CDJ-3000's 480-sample ones): gain g
! (0..512) steps one per frame toward 512 while a finger previews, toward 0
! after; the packet's 336 frames at B_TX + 0x2c are scaled by g / 512. Full
! and staying full: untouched. Clobbers r0-r7.
apply_gain:
	ld	r1,D_BUF		! TchDec's ring dry (ST_UNDER): fade out as
	mov.w	ag_st,r0		! after a lift, back in once it plays again
	add	r0,r1
	mov.l	@(ST_UNDER,r1),r5
	mov.w	ag_gain,r0
	mov.l	@(r0,r8),r4		! g
	mov.w	ag_512,r6
	mov	#-1,r7
	tst	r5,r5
	bf	2f
	ld	r5,D_PREVIEW
	mov	#1,r7			! step
	tst	r5,r5
	bf	1f
	bra	2f
	mov	#-1,r7
1:	cmp/eq	r6,r4
	bf	2f
	rts
	nop
2:	mov	#-9,r5
	ld	r1,D_BUF
	mov.w	ag_txp,r0
	add	r0,r1
	mov.w	ag_336,r3
3:	add	r7,r4
	cmp/pz	r4
	bt	4f
	mov	#0,r4
4:	cmp/gt	r6,r4
	bf	5f
	mov	r6,r4
5:	mov.w	@r1,r2
	muls.w	r2,r4
	sts	macl,r2
	shad	r5,r2
	mov.w	r2,@r1
	mov.w	@(2,r1),r0
	muls.w	r0,r4
	sts	macl,r0
	shad	r5,r0
	mov.w	r0,@(2,r1)
	add	#4,r1
	dt	r3
	bf	3b
	mov.w	ag_gain,r0
	rts
	mov.l	r4,@(r0,r8)

! hold_last: the packet's 336 frames = its last frame (the file closed under
! a fading tail: no jump, apply_gain then takes it to 0). Clobbers r0-r3.
hold_last:
	ld	r1,D_BUF
	mov.w	ag_txp,r0
	add	r0,r1
	mov.w	ag_last,r0
	mov.l	@(r0,r1),r2
	mov.w	ag_336,r3
1:	mov.l	r2,@r1
	add	#4,r1
	dt	r3
	bf	1b
	rts
	nop

! lc_onload: a track loaded on the deck stops the preview (the CDJ-3000's
! LoadHandler -> LinkMonitor stop): the own status packet's +0x28 (source
! player, slot, type) and +0x2C (rekordbox id) changed. Latched until the
! finger leaves the row, so a held finger does not restart it. Clobbers r0-r3.
lc_onload:
	mov.l	lo_st,r1
	mov.l	@(0x28,r1),r2
	mov.l	@(0x2C,r1),r3
	xor	r3,r2
	mov.w	lo_key,r0
	mov.l	@(r0,r8),r3
	cmp/eq	r2,r3
	bt	1f
	mov.l	r2,@(r0,r8)
	mov	#1,r3
	mov.w	lo_lat,r0
	mov.l	r3,@(r0,r8)
	mov	#0,r3
	st	r3,D_PREVIEW
1:	rts
	nop

ag_gain:	.word D_GAIN
ag_st:		.word B_ST
ag_512:		.word 512
ag_txp:		.word B_TX + 0x2c
ag_336:		.word 336
ag_last:	.word 335 * 4
lo_key:		.word D_LDKEY
lo_lat:		.word D_LATCH
	.p2align 2
lo_st:		.long 0x0B53D828	! the deck's own status packet

! readpcm: fills B_TX + 0x2c with 336 s16 stereo frames at 48 kHz from the
! open WAV (16/24-bit, mono/stereo, 44.1/48 kHz), linearly interpolated: S
! (B_SRC) holds decoded s16 frames, S[0] at the integer part of the read
! phase; each packet reads just the frames it needs, wrapping at the data end.
readpcm:
	sts.l	pr,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15
	mov.l	r14,@-r15
	ld	r14,D_BUF
	mov.w	rp_st2,r0
	add	r0,r14			! r14 = converter state
	mov.l	@(ST_STEP,r14),r9	! step, 16.16 source frames per output frame
	mov.l	@(ST_FRAC,r14),r10	! phase
	mov.w	rp_335b,r0		! need = ((phase + 335*step) >> 16) + 2
	mul.l	r0,r9
	sts	macl,r1
	add	r10,r1
	shlr16	r1
	add	#2,r1
	mov.l	@(ST_HAVE,r14),r2
	sub	r2,r1			! frames still to read
	cmp/pl	r1
	bf	rp_interp
	mov	r1,r11			! r11 = n
	mov.l	@(ST_ALIGN,r14),r0
	mul.l	r0,r11
	sts	macl,r12		! r12 = n * block align bytes
	mov.l	@(ST_CODEC,r14),r0
	tst	r0,r0
	bt	rp_file
	ld	r4,D_BUF		! MP3 / FLAC: q_read(raw, n, live) frames of s16 stereo
	mov.l	rp_raw2,r0		! from TchDec's ring (tadec.c "TchDec")
	add	r0,r4
	ld	r6,D_PREVIEW		! live: a finger previews (TchDec reads on)
	mov	r11,r5
	mov.l	rp_tdread,r1
	jsr	@r1
	nop
	cmp/pz	r0			! -1: nothing now (a seek, an underrun): hold
	bf	rp_under		! the last frame and fade, the phase kept
	mov	#0,r1
	mov.l	r1,@(ST_UNDER,r14)
	cmp/hs	r11,r0			! short (end of stream): pad with silence
	bt	rp_dec
	mov	r0,r3			! got (ld below clobbers r0)
	ld	r2,D_BUF
	mov.l	rp_raw2,r1
	add	r1,r2
	shll2	r3
	add	r3,r2			! r2 = raw + got * 4
	shlr2	r3
	mov	r11,r1
	sub	r1,r3			! -(frames missing)
	neg	r3,r3
	mov	#0,r1
2:	mov.l	r1,@r2
	add	#4,r2
	dt	r3
	bf	2b
	bra	rp_dec
	nop
rp_st2:		.word B_ST
rp_335b:	.word 335
	.p2align 2
rp_tdread:	.long TADEC+0x8	! q_read
rp_under:
	mov	#1,r1
	mov.l	r1,@(ST_UNDER,r14)
	bsr	hold_last
	nop
	bra	rp_ret
	nop
rp_file:
	ld	r1,D_POS		! past the data end: silence, no wrap (a
	add	r12,r1			! preview ends where the track ends)
	ld	r2,D_DLEN
	cmp/hi	r2,r1
	bt	rp_silent
	ld	r4,D_BUF
	mov.l	rp_raw2,r0
	add	r0,r4
	mov	#1,r5
	mov	r12,r6
	ld	r7,D_FH
	fw	D_FREAD
	mov	r0,r3			! bytes read (ld / st below clobber r0)
	ld	r1,D_POS
	add	r12,r1
	st	r1,D_POS
	cmp/pz	r3			! a short (or failed) read: the rest is
	bt	1f			! silence, never the stale bytes
	mov	#0,r3
1:	cmp/hs	r12,r3
	bt	rp_dec
	ld	r1,D_BUF
	mov.l	rp_raw2,r2
	add	r2,r1
	add	r3,r1			! raw + got
	mov	r12,r2
	sub	r3,r2			! bytes missing
	bra	rp_zfill
	nop
rp_silent:
	ld	r1,D_BUF
	mov.l	rp_raw2,r0
	add	r0,r1
	mov	r12,r2
rp_zfill:
	mov	#0,r0
2:	mov.b	r0,@r1
	add	#1,r1
	dt	r2
	bf	2b
	bra	rp_dec
	nop
	.p2align 2
rp_raw2:	.long B_RAW
rp_dec:
	ld	r1,D_BUF		! decode n raw frames -> S[have ..]
	mov.w	rp_raw,r0
	add	r0,r1			! r1 = raw
	ld	r2,D_BUF
	mov.w	rp_src,r0
	add	r0,r2
	mov.l	@(ST_HAVE,r14),r3
	shll2	r3
	add	r3,r2			! r2 = &S[have]
	mov.l	@(ST_BITS,r14),r3
	shlr2	r3
	shlr	r3			! bytes per sample (2, 3, 4)
	mov.l	@(ST_FMT,r14),r12	! big-endian / float
	mov.l	@(ST_CH,r14),r4		! 1 or 2
	mov	r11,r5
2:	bsr	getsamp			! left
	nop
	mov.w	r6,@r2
	mov	#2,r0
	cmp/eq	r0,r4
	bt	4f
	mov	r6,r0			! mono: R = L
	bra	5f
	mov.w	r0,@(2,r2)
4:	bsr	getsamp			! right
	nop
	mov	r6,r0
	mov.w	r0,@(2,r2)
5:	add	#4,r2
	dt	r5
	bf	2b
	mov.l	@(ST_HAVE,r14),r0
	add	r11,r0
	mov.l	r0,@(ST_HAVE,r14)
rp_interp:
	ld	r1,D_BUF
	mov.w	rp_src,r0
	add	r0,r1			! r1 = S
	ld	r2,D_BUF
	mov.w	rp_txp,r0
	add	r0,r2			! r2 = out (B_TX + 0x2c)
	mov.w	rp_336,r5
	mov	r10,r3			! p = phase
	mov	#-15,r12
7:	mov	r3,r0
	shlr16	r0
	shll2	r0
	mov	r1,r6
	add	r0,r6			! &S[p >> 16]
	mov	r3,r7
	extu.w	r7,r7
	shlr	r7			! t (15 bits)
	mov.w	@r6+,r10		! aL
	mov.w	@r6+,r11		! aR
	mov.w	@r6+,r4			! bL
	mov.w	@r6,r13			! bR
	sub	r10,r4
	mul.l	r7,r4
	sts	macl,r4
	shad	r12,r4
	add	r10,r4			! aL + (bL - aL) * t
	mov.w	r4,@r2
	add	#2,r2
	sub	r11,r13
	mul.l	r7,r13
	sts	macl,r13
	shad	r12,r13
	add	r11,r13
	mov.w	r13,@r2
	add	#2,r2
	add	r9,r3
	dt	r5
	bf	7b
	mov	r3,r4			! keep S[p_end >> 16 ..] for the next packet
	shlr16	r4
	extu.w	r3,r3
	mov.l	r3,@(ST_FRAC,r14)
	mov.l	@(ST_HAVE,r14),r5
	sub	r4,r5
	mov.l	r5,@(ST_HAVE,r14)
	shll2	r4
	mov	r1,r6
	add	r4,r6
	tst	r5,r5
	bt	9f
8:	mov.l	@r6+,r0
	mov.l	r0,@r1
	add	#4,r1
	dt	r5
	bf	8b
9:
rp_ret:	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	lds.l	@r15+,pr
	rts
	nop

! getsamp: one sample at r1 (advanced past it) -> r6 = s16. r3 = bytes per
! sample (2..4), r12 = flags (1 big-endian, 2 IEEE float, 32-bit LE only).
! Integer samples keep their top 16 bits. Clobbers r0, r7.
getsamp:
	mov	r12,r0
	tst	#2,r0
	bf	gs_float
	tst	#1,r0
	bf	gs_be
	mov	r3,r0			! little-endian: skip the low bytes
	add	#-2,r0
	add	r0,r1
	mov.b	@r1+,r6
	extu.b	r6,r6
	mov.b	@r1+,r7
	shll8	r7
	rts
	or	r7,r6
gs_be:	mov.b	@r1+,r7			! big-endian: top bytes first
	shll8	r7
	mov.b	@r1+,r6
	extu.b	r6,r6
	or	r7,r6
	mov	r3,r0
	add	#-2,r0
	rts
	add	r0,r1
gs_float:				! 32-bit float: value * 32768, clipped
	mov.b	@r1+,r0
	extu.b	r0,r6
	mov.b	@r1+,r0
	extu.b	r0,r0
	shll8	r0
	or	r0,r6
	mov.b	@r1+,r0
	extu.b	r0,r0
	shll16	r0
	or	r0,r6
	mov.b	@r1+,r0
	shll16	r0
	shll8	r0
	or	r0,r6			! r6 = the IEEE bits
	mov	r6,r7
	shll	r7
	shlr16	r7
	shlr8	r7			! exponent
	mov.w	gs_135,r0
	sub	r7,r0			! shift = 135 - exponent
	cmp/pl	r0
	bf	2f			! |value| >= 1: clip
	mov	#24,r7
	cmp/ge	r7,r0
	bt	3f			! tiny: 0
	mov	r6,r7			! (1.mantissa) << 8: drop sign and exponent,
	shll8	r7			! put the implicit 1 back on top
	shll	r7
	sett
	rotcr	r7
	add	#8,r0
	neg	r0,r0
	shld	r0,r7			! >> (shift + 8)
	mov.w	gs_max,r0
	cmp/hi	r0,r7
	bf	gs_sign
	bra	gs_sign
	mov	r0,r7
2:	mov.w	gs_max,r7		! (a pc-relative load never sits in a delay slot)
	bra	gs_sign
	nop
3:	rts
	mov	#0,r6
gs_sign:
	cmp/pz	r6
	bt	4f
	neg	r7,r7
4:	rts
	mov	r7,r6
gs_135:		.word 135
gs_max:		.word 32767

! reset_conv: restart the resampler (after any seek). Clobbers r0, r1.
reset_conv:
	ld	r1,D_BUF
	mov.w	rp_st,r0
	add	r0,r1
	mov	#0,r0
	mov.l	r0,@(ST_FRAC,r1)
	mov.l	r0,@(ST_UNDER,r1)
	rts
	mov.l	r0,@(ST_HAVE,r1)

rp_st:		.word B_ST
rp_src:		.word B_SRC
rp_raw:		.word B_RAW
rp_txp:		.word B_TX + 0x2c
rp_335:		.word 335
rp_336:		.word 336

! Reads a 32-bit little-endian value at a 2-aligned \ptr into \dst (RIFF
! chunks are only 2-aligned; a mov.l there is an address error on the SH-4).
	.macro	ld32h dst, ptr, tmp
	mov.w	@\ptr,\dst
	extu.w	\dst,\dst
	mov	\ptr,\tmp
	add	#2,\tmp
	mov.w	@\tmp,\tmp
	shll16	\tmp
	or	\tmp,\dst
	.endm

! openwav_at: r4 = wide path ptr. fopen, verify RIFF/WAVE, walk the chunks for
! "fmt " (PCM, 1-2 ch, 16/24-bit, 44.1/48 kHz) and "data" -> D_FH/D_DOFF/D_DLEN
! and the converter state. On an open failure or an unplayable WAV, FH is left 0
! so the caller falls back. Diagnostics at 0x081FFE04: fopen result, status
! (0 ok, 1 not RIFF/WAVE, 2 unsupported fmt), rate, bits << 8 | channels.
openwav_at:
	sts.l	pr,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15
	mov.l	r14,@-r15
	mov	r4,r11			! the path, for the MP3/FLAC fallback
	fw	D_FOPEN
	mov.l	ow_diag2,r10
	mov.l	r0,@(4,r10)
	mov	#0,r1
	mov.l	r1,@(8,r10)
	mov.l	r1,@(12,r10)
	mov.l	r1,@(16,r10)
	tst	r0,r0
	bt	ow_out			! open failed; FH already 0 from caller
	mov	#D_FH,r1
	add	r8,r1
	mov.l	r0,@r1			! D_FH = the open file
	ld	r9,D_BUF
	mov.l	ow_st2,r0
	add	r0,r9			! r9 = converter state; defaults: 48k/16/stereo
	mov.l	ow_s48_2,r0
	mov.l	r0,@(ST_STEP,r9)
	mov	#4,r0
	mov.l	r0,@(ST_ALIGN,r9)
	mov	#16,r0
	mov.l	r0,@(ST_BITS,r9)
	mov	#2,r0
	mov.l	r0,@(ST_CH,r9)
	mov	#0,r0
	mov.l	r0,@(ST_FRAC,r9)
	mov.l	r0,@(ST_HAVE,r9)
	mov.l	r0,@(ST_FMT,r9)
	mov.l	r0,@(ST_CODEC,r9)
	mov	#44,r1			! no data chunk seen: a canonical header
	st	r1,D_DOFF		! (r1, not r0: st clobbers r0)
	mov.l	ow_big3,r1
	st	r1,D_DLEN
	ld	r4,D_BUF
	mov.l	ow_rx3,r0
	add	r0,r4			! B_RX
	mov	#1,r5
	mov.l	ow_hdr2,r6
	ld	r7,D_FH
	fw	D_FREAD
	ld	r1,D_BUF
	mov.l	ow_rx3,r0
	add	r0,r1			! r1 = B_RX
	mov	#1,r0
	mov.l	r0,@(8,r10)		! status 1 until RIFF/WAVE pass
	mov.l	@r1,r3			! "RIFF"?
	mov.l	ow_riff2,r2
	cmp/eq	r2,r3
	bt	1f
	bra	ow_codec		! not RIFF: maybe MP3 / FLAC (AIFF is out of
	nop				! this build: the MAIN section's size cap)
	.p2align 2			! (literals of the prologue above: the pools
ow_diag2:	.long RAMB+0x1FE00	! at the end are out of reach)
ow_st2:		.long B_ST
ow_s48_2:	.long 0x10000
ow_big3:	.long 0x7fffffff
ow_rx3:		.long B_RX
ow_hdr2:	.long RX_LEN - 0x10
ow_riff2:	.long 0x46464952	! "RIFF"
1:	mov.l	@(8,r1),r3		! "WAVE"?
	mov.l	ow_wave2,r2
	cmp/eq	r2,r3
	bf	badwav
	mov	#2,r0
	mov.l	r0,@(8,r10)		! status 2 until the fmt checks pass
	mov	#12,r12			! r12 = chunk offset in the file (the walk
	mov	#64,r13			! seeks: a data chunk may sit behind large
	mov	#0,r14			! metadata chunks); r13 chunks left; r14 fmt seen
ow_walk:
	dt	r13
	bt	ow_wend
	mov.l	ow_maxoff2,r0
	cmp/hi	r0,r12
	bt	ow_wend
	ld	r4,D_FH			! the chunk head: 8 bytes at its offset
	mov	r12,r5
	mov	#0,r6
	fw	D_FSEEK
	ld	r4,D_BUF
	mov.l	ow_rx2,r0
	add	r0,r4
	mov	#1,r5
	mov	#8,r6
	ld	r7,D_FH
	fw	D_FREAD
	mov	#8,r1
	cmp/eq	r1,r0
	bf	ow_wend			! short: the end of the file
	ld	r1,D_BUF
	mov.l	ow_rx2,r0
	add	r0,r1			! r1 = B_RX
	mov	r1,r3			! r3 = chunk (its head, then its body)
	ld32h	r4, r3, r6		! id
	mov	r3,r7
	add	#4,r7
	ld32h	r5, r7, r6		! size
	mov.l	ow_data2,r0
	cmp/eq	r0,r4
	bt	ow_isdata
	mov.l	ow_fmt2,r0
	cmp/eq	r0,r4
	bf	ow_next
	mov	#40,r6			! fmt: its body (40 bytes cover the extensible form)
	cmp/hs	r6,r5
	bt	6f
	mov	r5,r6
6:	mov	r1,r4
	add	#8,r4
	mov.l	r6,@-r15
	mov	#1,r5
	ld	r7,D_FH
	fw	D_FREAD
	mov.l	@r15+,r6
	cmp/eq	r6,r0
	bf	badwav
	mov	#1,r14
	ld	r1,D_BUF
	mov.l	ow_rx2,r0
	add	r0,r1
	mov	r1,r3
	mov	r3,r7
	add	#4,r7
	ld32h	r5, r7, r6		! size again (r5 was the fread count)
	mov	r3,r7			! fmt: tag @8, ch @10, rate @12, align @20, bits @22
	add	#10,r7
	mov.w	@r7,r6
	extu.w	r6,r6			! channels
	mov	r3,r7
	add	#22,r7
	mov.w	@r7,r0
	extu.w	r0,r0			! bits
	mov	r0,r4
	shll8	r4
	or	r6,r4
	mov.l	r4,@(16,r10)		! diag: bits << 8 | ch
	mov.l	r0,@(ST_BITS,r9)
	mov.l	r6,@(ST_CH,r9)
	mov	r3,r7			! format tag: 1 PCM, 3 float, 0xFFFE extensible
	add	#8,r7			! (its sub-format code at +32)
	mov.w	@r7,r4
	extu.w	r4,r4
	mov.w	ow_ext,r7
	extu.w	r7,r7
	cmp/eq	r7,r4
	bf	3f
	mov	r3,r7
	add	#32,r7
	mov.w	@r7,r4
	extu.w	r4,r4
3:	mov	r4,r7
	mov	#3,r4
	cmp/eq	r4,r7
	bf	4f
	cmp/eq	#32,r0			! float: 32-bit only
	bf	badwav
	mov	#2,r4
	bra	2f
	mov.l	r4,@(ST_FMT,r9)
4:	mov	#1,r4
	cmp/eq	r4,r7
	bf	badwav
	bsr	ow_bits			! PCM: 16, 24 or 32 bits, 1-2 channels
	nop
	bf	badwav
2:	mov	r6,r0
	cmp/eq	#1,r0
	bt	5f
	cmp/eq	#2,r0
	bf	badwav
5:	mov	r3,r7
	add	#20,r7
	mov.w	@r7,r0
	extu.w	r0,r0
	mov.l	r0,@(ST_ALIGN,r9)	! block align
	mov	r3,r7
	add	#12,r7
	ld32h	r4, r7, r6		! rate
	mov.l	r4,@(12,r10)		! diag: rate
	mov.l	ow_r48,r0
	cmp/eq	r0,r4
	bt	ow_next			! 48k: step stays 1.0
	mov.l	ow_r441,r0
	cmp/eq	r0,r4
	bf	badwav
	mov.l	ow_s441,r0
	mov.l	r0,@(ST_STEP,r9)
ow_next:
	add	#8,r5			! next = offset + 8 + size, padded even
	add	#1,r5
	mov	#-2,r0
	and	r0,r5
	mov	r12,r7
	add	r5,r12
	cmp/hi	r7,r12			! wrapped (garbage size)? stop
	bf	ow_wend
	bra	ow_walk
	nop
	.p2align 2
ow_rx2:		.long B_RX		! (the walk's own literals: the pools below
ow_maxoff2:	.long 0x40000000	! are out of a pc-relative load's reach)
ow_data2:	.long 0x61746164	! "data"
ow_fmt2:	.long 0x20746d66	! "fmt "
ow_wave2:	.long 0x45564157	! "WAVE"
ow_isdata:
	mov	r12,r2			! (not r0: st clobbers it)
	add	#8,r2
	st	r2,D_DOFF
	tst	r5,r5			! a streaming size (0 or all ones): to the end
	bt	7f
	mov	#-1,r0
	cmp/eq	r0,r5
	bf	8f
7:	mov.l	ow_big,r5
8:	st	r5,D_DLEN
	tst	r14,r14			! fmt seen too: done; else keep walking
	bf	ow_end
	bra	ow_next
	nop
ow_wend:
	tst	r14,r14			! no fmt chunk: not a WAV we can play
	bt	badwav
ow_end:
	mov	#0,r0
	mov.l	r0,@(8,r10)		! status ok
	ld	r4,D_DLEN		! frames per strip column = DLEN / align / 600
	mov.l	@(ST_ALIGN,r9),r5
	bsr	udiv
	nop
	mov	r0,r4
	mov.w	ow_600,r5
	bsr	udiv
	nop
	mov.l	r0,@(ST_FPC,r9)
	ld	r4,D_FH
	ld	r5,D_DOFF
	mov	#0,r6
	fw	D_FSEEK
	bra	ow_out
	nop
! ow_bits: T = (r0 is 16, 24 or 32). Leaves r0.
ow_bits:
	cmp/eq	#16,r0
	bt	1f
	cmp/eq	#24,r0
	bt	1f
	cmp/eq	#32,r0
1:	rts
	nop

ow_st:		.word B_ST
ow_rx:		.word B_RX
ow_hdr:		.word RX_LEN - 0x10	! header bytes read
ow_600:		.word 600
ow_lim:		.word RX_LEN - 0x18	! last chunk offset whose 8-byte head fits
ow_ext:		.word 0xFFFE		! WAVE_FORMAT_EXTENSIBLE
	.p2align 2

! Not RIFF/FORM: hand the path to the tadec blob (MP3 / FLAC, 0x08140000),
! when that blob is present. It then supplies s16 stereo at the file's rate.
ow_codec:
	ld	r4,D_FH
	fw	D_FCLOSE
	mov	#0,r1
	st	r1,D_FH
	mov.l	oc_open,r1		! blob absent (erased cave): no fallback
	mov.w	@r1,r0
	extu.w	r0,r0
	mov.w	oc_erased,r2
	extu.w	r2,r2
	cmp/eq	r2,r0
	bt	ow_out
	mov.l	oc_med,r2		! the export row's file type: 4 = M4A / AAC,
	mov.l	@(24,r2),r0		! which dr_mp3 cannot decode (it would scan
	cmp/eq	#4,r0			! the whole file for a sync): no
	bt	ow_out
	mov	r11,r4			! (r1 = tadec_open still)
	jsr	@r1			! tadec_open(path)
	nop
	tst	r0,r0
	bf	ow_out			! not MP3 / FLAC: FH stays 0
	mov.l	oc_rate,r1
	jsr	@r1
	nop
	mov.l	oc_48k,r1		! above 48 kHz a packet's source frames would
	cmp/hi	r1,r0			! overrun B_RAW (into the preview state): no
	bt	oc_bad
	mov	#16,r1
	mov.l	r1,@(ST_BITS,r9)
	mov	#2,r1
	mov.l	r1,@(ST_CH,r9)
	mov	#4,r1
	mov.l	r1,@(ST_ALIGN,r9)
	mov	#0,r1
	mov.l	r1,@(ST_FMT,r9)
	mov.l	r1,@(ST_FPC,r9)
	mov	#1,r1
	mov.l	r1,@(ST_CODEC,r9)
	mov	r0,r4			! step = rate * 1024 / 750 (= rate / 48000 in 16.16)
	shll8	r4
	shll2	r4
	mov.w	oc_750,r5
	bsr	udiv
	nop
	mov.l	r0,@(ST_STEP,r9)
	mov.l	r0,@(12,r10)		! diag: the step
	mov.l	oc_sent,r1
	st	r1,D_FH			! FH: a sentinel (never fclose'd)
	mov	#0,r1
	st	r1,D_DOFF
	st	r1,D_POS
	mov.l	oc_big,r1
	st	r1,D_DLEN
	mov	#0,r0
	mov.l	r0,@(8,r10)		! status ok
	bra	ow_out
	nop
oc_bad:	mov.l	oc_close,r1		! tadec_close(): the decoder is dropped, FH 0
	jsr	@r1
	nop
	bra	ow_out
	nop
oc_750:		.word 750
oc_erased:	.word 0xFFFF
	.p2align 2
oc_open:	.long TADEC	! tadec_open
oc_rate:	.long TADEC+0xC	! tadec_rate
oc_sent:	.long 0xC0DEC0DE
oc_big:		.long 0x7FFFFFFF
oc_48k:		.long 48000
oc_close:	.long TADEC+0x10	! tadec_close
oc_med:		.long MED

badwav:					! not a playable WAV: close, FH = 0 (caller falls back)
	ld	r4,D_FH
	fw	D_FCLOSE
	mov	#0,r1
	st	r1,D_FH
ow_out:	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	lds.l	@r15+,pr
	rts
	nop

	.p2align 2
os_shared:	.long RAMB+0x1F800
ow_diag:	.long RAMB+0x1FE00
ow_riff:	.long 0x46464952	! "RIFF"
ow_wave:	.long 0x45564157	! "WAVE"
ow_data:	.long 0x61746164	! "data"
ow_fmt:		.long 0x20746d66	! "fmt "
ow_big:		.long 0x7fffffff
ow_maxoff:	.long 0x40000000	! chunk offsets past 1 GB: stop walking
ow_r48:		.long 48000
ow_r441:	.long 44100
ow_s48:		.long 0x10000		! step 1.0
ow_s441:	.long 60211		! 44100 / 48000 in 16.16

! open_selected: open the track touch_preview resolved (wide path at
! shared+36, valid at shared+32). On a failure D_FH stays 0: no audio.
! close_cur: close the preview's open file (fclose, or tadec_close for a
! MP3 / FLAC stream); D_FH = 0. The firmware's file layer holds only a few
! open files, so this runs before the next track is looked up.
close_cur:
	sts.l	pr,@-r15
	ld	r4,D_FH
	tst	r4,r4
	bt	6f
	mov.l	os_sent,r0
	cmp/eq	r0,r4
	bf	4f
	mov.l	os_tdclose,r1		! MP3 / FLAC: tadec_close()
	jsr	@r1
	nop
	bra	5f
	nop
4:	fw	D_FCLOSE
5:	mov	#0,r1
	st	r1,D_FH
6:	lds.l	@r15+,pr
	rts
	nop

open_selected:
	sts.l	pr,@-r15
	bsr	close_cur		! close whatever is open
	nop
1:	mov.l	os_shr,r1		! 0x081FF800
	mov.l	@(32,r1),r2		! path valid?
	tst	r2,r2
	bt	3f
	mov	r1,r4
	add	#36,r4			! wide path at shared+36
	bsr	openwav_at
	nop
	mov.l	os_diag,r1		! keep the selected open's diagnostics at +0x24
	mov.l	@(4,r1),r0
	mov.l	r0,@(0x24,r1)
	mov.l	@(8,r1),r0
	mov.l	r0,@(0x28,r1)
	mov.l	@(12,r1),r0
	mov.l	r0,@(0x2c,r1)
	mov.l	@(16,r1),r0
	mov.l	r0,@(0x30,r1)
3:	mov	#0,r1
	st	r1,D_POS
	bsr	reset_conv
	nop
	lds.l	@r15+,pr
	rts
	nop

	.p2align 2
os_shr:		.long RAMB+0x1F800
os_diag:	.long RAMB+0x1FE00
os_sent:	.long 0xC0DEC0DE
os_tdclose:	.long TADEC+0x10	! tadec_close

! udiv: r0 = r4 / r5 (unsigned; 0 when r5 is 0). Clobbers r1, r2, r4.
udiv:
	mov	#0,r0
	tst	r5,r5
	bt	3f
	mov	#0,r1
	mov	#32,r2
1:	shll	r4
	rotcl	r1
	shll	r0
	cmp/hs	r5,r1
	bf	2f
	sub	r5,r1
	add	#1,r0
2:	dt	r2
	bf	1b
3:	rts
	nop

! ---------------------------------------------------------------------------
! Touch Preview, CDJ-3000 style, on the stock NXS2 screen. While the browser's
! INFO pop-up shows a listed track (mem32[0x0A35F3CC] == 2) the track (rekordbox id
! at 0x09437A6C) is looked up in C:/PIONEER/rekordbox/export.pdb for its audio
! and ANLZ paths, its PWAV preview is drawn into the overview strip (the
! publisher's slot at 0x0B569528, republished under the slot lock), and holding
! a finger on the strip plays it from the touched point on the mixer's LINK
! CUE; dragging seeks, lifting stops. A white column marks the playing point.
! Closing INFO gives the strip back. touchaudiotouch.s keeps the stock needle
! search off the strip meanwhile. r8 = data; r9 = TP state throughout.
! ---------------------------------------------------------------------------
touch_preview:
	sts.l	pr,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15
	mov.l	r14,@-r15
	ld	r9,D_BUF
	mov.w	tp_btp,r0
	add	r0,r9			! r9 = TP state
	mov.l	tp_lcv,r1		! UTILITY > LINK CUE without PREVIEW: no row
	mov.l	@r1,r0			! touch (Touch Cue may still apply)
	tst	#1,r0
	bt	tc_check
	mov.l	tp_info,r1
	mov.l	@r1,r1			! a browse list: a finger on a row's waveform?
	mov	#1,r0
	cmp/eq	r0,r1
	bf	tc_check		! not a list: Touch Cue on the loaded track
	bsr	pre_medium		! the list's medium gets its index before INFO
	nop
	mov.l	tp_kill,r1		! V4n36 trace: LINK ROW PREVIEW killed (modsmenu kill_v +16 = 0) and the list
	mov.l	@(16,r1),r0		!   is a LINKed medium's (MED +0 = player << 8 | slot, player 0 = this deck):
	tst	r0,r0			!   no row touch (as LINK CUE without PREVIEW)
	bf	1f
	mov.l	tp_medk,r1
	mov.l	@r1,r0
	shlr8	r0
	tst	#0xFF,r0
	bf	tp_up
1:	bsr	row_touch
	nop
	tst	r0,r0
	bf	tp_out
tp_up:					! (V3e3: the INFO strip preview is gone; Touch Cue
	mov	#0,r2			! is back in V4n28t: tc_check below)
	st	r2,D_PREVIEW
	mov.w	tp_lat,r0		! not on a row: a load's latch ends
	mov.l	r2,@(r0,r8)

tp_out:
	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	lds.l	@r15+,pr
	rts
	nop

tp_btp:		.word B_TP
tp_lat:		.word D_LATCH
	.p2align 2
tp_info:	.long 0x0A35F3CC	! display mode: 2 = INFO pop-up on a listed track
tp_lcv:		.long LCV		! UTILITY > LINK CUE (bit 1 PREVIEW, bit 2 CUE)
tp_kill:	.long KILLB		! V4n36 trace: modsmenu's kill switches (layout.inc)
tp_medk:	.long MED		! V4n36 trace: the listed medium's key

! Touch Cue, CDJ-3000 style (V4n28t: back after V3e2 removed it with the INFO
! strip preview): while the deck plays (play mode 3, or 4 in a loop) a
! rekordbox track, a finger on the overview strip (touch zone 0 -- x0, y0, w,
! h from the table, so the V2 overview's 79, 405, 640, 75 and the stock 100,
! 377, 600, 103 both work) previews the LOADED track from that point on the
! LINK CUE; the main output is untouched (touchaudiotouch.s skips the needle
! search meanwhile). Not in a browse list (row previews; the list's medium
! stays current) nor INFO. The loaded track comes from rq_get (the own status
! table entry / packet: type 1 = rekordbox, rbid native) and is looked up in
! the medium's export.pdb (TP_ID = -1 marks it selected, TP_HASH its rbid,
! MED+20 its medium key). Paused: nothing here (stock needle search).
tc_check:
	mov.l	tc_lcv,r1		! LINK CUE without CUE: no Touch Cue
	mov.l	@r1,r0
	tst	#2,r0
	bt	tc_none
	mov.l	tc_info,r1		! a browse list (1) / INFO (2): not here
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bt	tc_none
	cmp/eq	#2,r0
	bt	tc_none
	mov.l	tc_pmode,r1
	mov.l	@r1,r0
	cmp/eq	#3,r0
	bt	1f
	cmp/eq	#4,r0
	bf	tc_none
1:	mova	tc_rqg,r0		! rq_get: r4 = player | slot << 8 | type << 16,
	mov.l	@r0,r1			! r5 = rbid (out of bsr range)
	add	r0,r1
	jsr	@r1
	nop
	mov	r4,r0
	shlr16	r0
	extu.b	r0,r0
	cmp/eq	#1,r0			! a rekordbox track?
	bf	tc_none
	mov	r5,r10
	tst	r10,r10
	bt	tc_none
	extu.b	r4,r0			! key = player << 8 | slot
	shll8	r0
	shlr8	r4
	extu.b	r4,r4
	or	r0,r4
	mov.l	@(TP_HASH,r9),r0
	cmp/eq	r0,r10
	bf	2f
	mov.l	tc_med,r1		! the same id: from the same medium too?
	mov.l	@(20,r1),r0		! (ids repeat across exports)
	cmp/eq	r0,r4
	bf	2f
	mov.l	@(TP_ID,r9),r0
	cmp/eq	#-1,r0
	bt	tc_touch		! the loaded track is selected
2:	mov.l	r10,@(TP_HASH,r9)	! (re)select the loaded track
	mov	#-1,r2
	mov.l	r2,@(TP_ID,r9)
	mov	#0,r2
	st	r2,D_PREVIEW
	mov.l	r2,@(TP_OPEN,r9)
	mov.l	tc_med,r1
	mov.l	r4,@(20,r1)		! remembered with the id (the match above)
	mov.l	r4,@-r15
	bsr	close_cur
	nop
	mov.l	@r15+,r4
	bsr	set_medium
	nop
	tst	r0,r0
	bt	tc_none			! not mounted: no Touch Cue
	bsr	tp_resolve		! -> its path at shared+36, TP_OK
	mov	r10,r4
	mov.l	@(TP_PEND,r9),r0	! the index is still building: resolve again
	tst	r0,r0			! next pass (TP_HASH forgotten)
	bt	tc_touch
	mov	#0,r0
	mov.l	r0,@(TP_HASH,r9)
tc_touch:
	mov.l	@(TP_OK,r9),r0
	tst	r0,r0
	bt	tc_none
	mov.l	tc_tx,r1		! calibrated touch (0, 0 when up)
	mov.l	@r1,r10			! x
	mov.l	@(4,r1),r2		! y
	mov.l	tc_zone,r1		! the strip = touch zone 0 {x0, y0, w, h}
	mov.l	@(4,r1),r0
	sub	r0,r2
	cmp/pz	r2
	bf	tc_none
	mov.l	@(12,r1),r0
	cmp/ge	r0,r2
	bt	tc_none
	mov.l	@r1,r0
	sub	r0,r10			! col = x - x0
	cmp/pz	r10
	bf	tc_none
	mov.l	@(8,r1),r0
	cmp/ge	r0,r10
	bt	tc_none
	mov.w	tc_640,r1
	cmp/eq	r1,r0
	bf	1f
	mov	r10,r0			! 640 px -> 600 columns: col * 15 / 16
	shll2	r0
	shll2	r0
	sub	r10,r0
	shlr2	r0
	shlr2	r0
	mov	r0,r10
1:	ld	r0,D_PREVIEW
	tst	r0,r0
	bf	3f
	mov.l	@(TP_OPEN,r9),r0	! press: open (once per track), seek, play
	tst	r0,r0
	bf	5f
	mov.l	r10,@-r15
	bsr	open_selected
	nop
	mov.l	@r15+,r10
	ld	r0,D_FH			! open failed: the next press tries again
	tst	r0,r0
	bt	tc_none
	mov	#1,r0
	mov.l	r0,@(TP_OPEN,r9)
	bra	5f
	nop
3:	mov.l	@(TP_COL,r9),r0		! drag: reseek once moved 2+ columns
	sub	r10,r0
	cmp/pz	r0
	bt	4f
	neg	r0,r0
4:	mov	#2,r1
	cmp/ge	r1,r0
	bf	tq_out
5:	mov.l	r10,@(TP_COL,r9)
	mov	r10,r4
	bsr	tp_seek
	nop
	mov	#1,r2
	st	r2,D_PREVIEW
tq_out:	bra	tp_out
	nop
tc_none:
	bra	tp_up
	nop
tc_640:		.word 640
	.p2align 2
tc_rqg:		.long rq_get - tc_rqg
tc_pmode:	.long 0x0A35F7A0	! play mode: 3 playing, 4 looping, 5 paused
tc_lcv:		.long LCV		! UTILITY > LINK CUE (bit 1 PREVIEW, bit 2 CUE)
tc_info:	.long 0x0A35F3CC	! display mode: 1 browse list, 2 INFO
tc_med:		.long MED
tc_tx:		.long 0x0B06C774	! calibrated touch x, y (pixels; 0 when up)
tc_zone:	.long 0xA81010A0	! touch zone 0 (the strip): x0, y0, w, h

! tp_seek: r4 = strip column -> POS = col * frames-per-column * align.
tp_seek:
	sts.l	pr,@-r15
	ld	r1,D_FH
	tst	r1,r1
	bt	9f
	ld	r1,D_BUF
	mov.w	tk_bst,r0
	add	r0,r1
	mov.l	@(ST_CODEC,r1),r0
	tst	r0,r0
	bt	1f
	mov.l	tk_tdseek,r1		! MP3 / FLAC: tadec_seek(col)
	jsr	@r1
	nop
	mov	#0,r1
	st	r1,D_POS
	bsr	reset_conv
	nop
	bra	9f
	nop
1:
	mov.l	@(ST_FPC,r1),r2
	mul.l	r2,r4
	sts	macl,r4
	mov.l	@(ST_ALIGN,r1),r2
	mul.l	r2,r4
	sts	macl,r4
	st	r4,D_POS
	ld	r5,D_DOFF
	add	r4,r5
	ld	r4,D_FH
	mov	#0,r6
	fw	D_FSEEK
	bsr	reset_conv
	nop
9:	lds.l	@r15+,pr
	rts
	nop
tk_bst:		.word B_ST
	.p2align 2
tk_tdseek:	.long TADEC+0x4	! tadec_seek

! medium_letter: r4 = a medium key (player << 8 | slot; player 0 or the own
! number = this deck, slot 2 SD / 3 USB) -> r0 = its drive letter (wide
! char) or 0 when it is not mounted. The firmware's media records
! (0x0A35F80C + player * 0x414 + slot * 0xA8: +4 the letter, +8 state 2 =
! present) cover the own media (player 0) and the LINKed players' (mounted
! over NFS as D:..Z:, in mount order). Clobbers r1-r3.
medium_letter:
	mov	r4,r1
	shlr8	r1			! player
	mov	r4,r2
	extu.b	r2,r2			! slot
	mov	r2,r0			! (the key is canonical: canon_key did the
	cmp/eq	#2,r0			! own player -> 0, empty slot -> own USB/SD)
	bt	2f
	cmp/eq	#3,r0
	bf	ml_none			! CD / rekordbox: no files to read
2:	mov.w	ml_414,r0
	mul.l	r0,r1
	sts	macl,r3
	mov.w	ml_a8,r0
	mul.l	r0,r2
	sts	macl,r0
	add	r0,r3
	mov.l	ml_media,r0
	add	r0,r3			! r3 = the medium's record
	mov.l	@(8,r3),r0
	cmp/eq	#2,r0			! present?
	bf	ml_none
	mov.l	@(4,r3),r0		! its letter
	extu.b	r0,r0
	tst	r0,r0
	bt	ml_none
	rts
	nop
ml_none:
	rts
	mov	#0,r0
ml_414:		.word 0x414
ml_a8:		.word 0xA8
	.p2align 2
ml_media:	.long 0x0A35F80C	! the media records

! canon_key: r4 = a medium key -> its canonical form, so that one medium has
! one key whichever source named it (the browse descriptor says player 0 for
! the own media, the status packet the own number, the artwork table either;
! before the LINK is up the status packet has no slot at all): the own player
! (or 0, or any player while the deck has no number) becomes 0; slot 0 becomes
! the own USB if present, else the own SD. Two keys for one medium made
! set_medium rebuild the index every pass (INFO pending vs Touch Cue's
! reselect). Clobbers r0-r2.
canon_key:
	mov	r4,r1
	shlr8	r1			! player
	mov	r4,r2
	extu.b	r2,r2			! slot
	mov.l	ck_own,r0
	mov.l	@r0,r0
	tst	r0,r0			! no number yet: everything is own
	bt	1f
	cmp/eq	r0,r1			! the own number: player 0
	bt	1f
	tst	r1,r1
	bf	2f			! another player: as given
1:	mov	#0,r1
	tst	r2,r2			! no slot: the own USB if present, else SD
	bf	2f
	mov	#3,r2
	mov.l	ck_ownusb,r0
	mov.l	@(8,r0),r0
	cmp/eq	#2,r0
	bt	2f
	mov	#2,r2
2:	shll8	r1
	mov	r1,r4
	rts
	or	r2,r4
	.p2align 2
ck_own:		.long 0x0A35F680	! the own player number
ck_ownusb:	.long 0x0A35F80C + 3 * 0xA8	! the own USB's media record

! set_medium: r4 = a medium key -> the index and export.pdb belong to that
! medium: r0 = 1, or 0 when it is not mounted (nothing resolves). A change
! closes a LINKed medium's export.pdb (the own medium's stays open for good:
! the firmware's database layer shares it), points the pdb path at the new
! letter and asks for the index to be rebuilt. r9 = TP state. Keeps r9-r14.
set_medium:
	sts.l	pr,@-r15
	bsr	canon_key		! one key per medium (the own USB is "player
	nop				! 0, slot 3" whoever names it)
	mov.l	r4,@-r15
	bsr	medium_letter
	nop
	mov.l	@r15+,r4
	tst	r0,r0
	bt	sm_fail
	mov	r0,r1			! letter
	mov.l	sm_med,r2
	mov.l	r3,@(16,r2)		! its media record (idx_step watches it)
	mov.l	@r2,r0
	cmp/eq	r4,r0			! the same medium, still on the same letter?
	bf	1f
	mov.l	@(4,r2),r0
	cmp/eq	r1,r0
	bt	sm_ok
1:	mov	#TP_PDB,r0		! a change: a LINKed medium's pdb is closed
	mov.l	@(r0,r9),r3
	tst	r3,r3
	bt	2f
	mov.l	@(8,r2),r0
	cmp/eq	r0,r3			! (never an own medium's kept handle)
	bt	2f
	mov.l	@(12,r2),r0
	cmp/eq	r0,r3
	bt	2f
	mov.l	r1,@-r15
	mov.l	r2,@-r15
	mov.l	r4,@-r15
	mov	r3,r4
	fw	D_FCLOSE
	mov.l	@r15+,r4
	mov.l	@r15+,r2
	mov.l	@r15+,r1
2:	mov.l	r4,@r2			! the current medium and its letter
	mov.l	r1,@(4,r2)
	mov	#0,r3
	mov	r1,r0
	cmp/eq	#'C',r0			! an own medium: its kept handle (0 until opened)
	bf	sm_notc
	mov.l	@(8,r2),r3
sm_notc:
	cmp/eq	#'B',r0
	bf	sm_notb
	mov.l	@(12,r2),r3
sm_notb:
	mov	#TP_PDB,r0
	mov.l	r3,@(r0,r9)
	mov	#0,r3
	mov	#TP_XS,r0		! the index: rebuilt for this medium
	mov.l	r3,@(r0,r9)
	mov	#TP_BAD,r0
	mov.l	r3,@(r0,r9)
	mov	#TP_KS,r0		! the key names: read again from this medium
	mov.l	r3,@(r0,r9)
	mov.l	r3,@(36,r2)		! no walk in progress
	ld	r5,D_BUF		! the pdb path: letter + ":/PIONEER/rekordbox/export.pdb"
	mov.w	sm_bpdbp,r0
	add	r0,r5
	mov.w	r1,@r5
	add	#2,r5
	mova	sm_tail,r0
	mov	r0,r3
4:	mov.w	@r3+,r0
	mov.w	r0,@r5
	add	#2,r5
	tst	r0,r0
	bf	4b
sm_ok:	lds.l	@r15+,pr
	rts
	mov	#1,r0
sm_fail:
	mov.l	sm_med,r2
	mov	#0,r0
	mov.l	r0,@r2			! no medium
	lds.l	@r15+,pr
	rts
	nop
sm_bpdbp:	.word B_PDBP
	.p2align 2
sm_med:		.long MED
sm_tail:	.short ':', '/', 'P', 'I', 'O', 'N', 'E', 'E', 'R', '/'
		.short 'r', 'e', 'k', 'o', 'r', 'd', 'b', 'o', 'x', '/'
		.short 'e', 'x', 'p', 'o', 'r', 't', '.', 'p', 'd', 'b', 0
	.p2align 2

! med_keep: r1 = the export.pdb handle just opened for the current medium:
! an own medium's (C: at +8, B: at +12) is remembered and never closed (the
! firmware's database layer shares it). Clobbers r0, r2.
med_keep:
	mov.l	mk_med,r2
	mov.l	@(4,r2),r0
	cmp/eq	#'C',r0
	bf	1f
	rts
	mov.l	r1,@(8,r2)
1:	cmp/eq	#'B',r0
	bf	2f
	mov.l	r1,@(12,r2)
2:	rts
	nop
	.p2align 2
mk_med:		.long MED

! browse_key: r4 = the key of the medium the browser lists (the one the
! INFO track and the rows belong to): the artwork request entry 0 (INFO /
! cursor row, re/ROWART_RE.md: 0x0B543438 = {state, key[8], ...}) carries the
! list's source player at key+0 and slot at key+1 -- the own number and 3
! for the own USB, a LINKed player's number and its slot for a remote list
! (seen in the emulator: 01 03 own, 02 03 player 2's USB). Clobbers r0, r1.
! pre_medium: a browse list is showing (no INFO, nothing selected, no preview
! streaming): make the list's medium the current one now, so its export.pdb
! index builds while the user scrolls instead of after INFO opens (a LINKed
! player's export over NFS took seconds; the strip only came with a scroll).
pre_medium:
	sts.l	pr,@-r15
	ld	r0,D_PREVIEW
	tst	r0,r0
	bf	pm_out
	bsr	browse_key		! (V4n28t: also after Touch Cue (TP_ID -1): it
					! never runs in a list; an id left behind is
					! forgotten below when the medium changes)
	nop
	tst	r4,r4			! no key yet (or one still settling)
	bt	pm_out
	mov.l	pm_med,r1
	mov.l	@r1,r0
	cmp/eq	r0,r4			! already the current medium
	bt	pm_out
	bsr	set_medium
	nop
	mov	#0,r0			! another medium: the last INFO track's id
	mov.l	r0,@(TP_ID,r9)		! means nothing here (ids repeat per export)
pm_out:	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
pm_med:		.long MED

! browse_key: r4 = the key (player << 8 | slot) of the medium the browser
! shows (the list, and the INFO track is one of its rows), from the DB
! context's descriptor of the current list -- what the firmware builds the
! rows' artwork keys from (re/ARTREQ_MEDIUM.md). The artwork request entry 0
! and the browse medium descriptor 0x0B5125C0 were both wrong on the deck
! (stale across a list change / not {player, slot}). Debounced: a key counts
! once it has held for 300 ms; until a first one settles the key is 0. Keys
! are made canonical by set_medium (one medium, one key). Clobbers r0-r2.
browse_key:
	mov.l	bk_ctxp,r1		! the DB task's context (heap, pointer at
	mov.l	@r1,r1			! 0x09437CD0): +4 the current list's side,
	tst	r1,r1			! +0x6C50 + side * 4 that list's descriptor
	bt	bk_raw0			! {medium*, slot, kind}; medium + 8 = player
	mov.l	@(4,r1),r0		! (the keys of the list rows are made from
	mov	#7,r2			! exactly this: re/ARTREQ_MEDIUM.md)
	cmp/hi	r2,r0
	bt	bk_raw0			! no list
	shll2	r0
	mov.w	bk_6c50,r2
	add	r2,r1
	add	r0,r1
	mov.l	@r1,r1			! the descriptor
	tst	r1,r1
	bt	bk_raw0
	mov.l	@(4,r1),r0		! slot
	extu.b	r0,r4
	mov.l	@r1,r1			! the medium
	tst	r1,r1
	bt	bk_raw0
	mov.l	@(8,r1),r0		! its player
	extu.b	r0,r0
	shll8	r0
	bra	bk_deb
	or	r0,r4			! r4 = the raw key this pass
bk_raw0:
	mov	#0,r4
	mov.l	bk_ui,r0		! V3rc3: the TAG LIST (UI class 3) has no list descriptor: its rows
	mov.l	@r0,r0			! are taken from the own USB, else the own SD (tp_resolve checks
	cmp/eq	#3,r0			! each row's title: a track tagged from another medium gets no cell)
	bf	bk_deb
	mov	#3,r4
	mov.l	bk_usb,r0
	mov.l	@(8,r0),r0
	cmp/eq	#2,r0
	bt	bk_deb
	mov	#2,r4
bk_deb:	mov.l	bk_med,r1
	mov.l	@(44,r1),r0		! the raw key last seen
	cmp/eq	r0,r4
	bt	1f
	mov.l	r4,@(44,r1)		! another: its clock starts now
	mov.l	@(D_TICK,r8),r0
	mov.l	@r0,r0
	bra	2f
	mov.l	r0,@(48,r1)
1:	mov.l	@(D_TICK,r8),r0
	mov.l	@r0,r0
	mov.l	@(48,r1),r2
	sub	r2,r0
	mov.w	bk_300,r2
	cmp/ge	r2,r0			! held for 300 ms: settled
	bf	2f
	mov.l	r4,@(52,r1)
2:	mov.l	@(52,r1),r4		! the settled key -- but none while a new
	mov.l	@(44,r1),r0		! raw key is still settling: a lookup made
	cmp/eq	r0,r4			! then would take the previous medium and
	bt	3f			! stick with it (the id does not change)
	mov	#0,r4
3:	rts
	nop
bk_300:		.word 300
bk_6c50:	.word 0x6C50
	.p2align 2
bk_ctxp:	.long 0x09437CD0	! -> the DB context (DBctx)
bk_med:		.long MED
bk_ui:		.long 0x0B54336C	! the MAIN UI state: +0 screen class
bk_usb:		.long 0x0A35F80C + 3 * 0xA8	! the own USB's media record

! tp_resolve: r4 = rekordbox id. Walks export.pdb's track table for the row
! with that id; its file path (string 20) -> "C:"+path wide at shared+36
! (+32 valid), its ANLZ path (string 14) -> B_APATH; then reads the PWAV.
! TP_OK = 1 when all of it worked. Uses r10-r14 (saved by touch_preview).
tp_resolve:
	sts.l	pr,@-r15
	mov	r4,r10			! id
	mov	#TP_RW,r0		! a browse row's lookup leaves the INFO track be
	mov.l	@(r0,r9),r0
	tst	r0,r0
	bf	1f
	mov	#TP_WAVE,r0
	mov	#0,r1
	mov.l	r1,@(r0,r9)		! no waveform yet
	mov	#0,r0
	mov.l	r0,@(TP_OK,r9)
	mov.l	tr_shr,r1
	mov.l	r0,@(32,r1)		! no audio path until found
1:	mov	#TP_XS,r0		! a real library is only searchable through the
	mov.l	@(r0,r9),r0		! index: while it builds, the lookup waits
	mov	#0,r1			! (pending, no walk); only a failed index walks
	mov.l	r1,@(TP_PEND,r9)
	cmp/eq	#2,r0
	bt	2f
	cmp/eq	#3,r0
	bt	2f
	mov	#1,r1
	mov.l	r1,@(TP_PEND,r9)
	mov.l	tr_cnt,r1		! RESOLVE_PEND++
	mov.l	@(0x30,r1),r0
	add	#1,r0
	mov.l	r0,@(0x30,r1)
	bra	tr_out
	nop
2:	ld	r11,D_BUF
	mov.l	tr_bpagel,r0
	add	r0,r11			! r11 = page buffer
	mov.l	tr_diag,r1		! diag 0x081FFE40: +0 resolves, +4 id, +8 pdb fopen
	mov.l	@(0x00,r1),r0
	add	#1,r0
	mov.l	r0,@(0x00,r1)
	mov.l	r10,@(0x04,r1)
	mov	#TP_PDB,r0
	mov.l	@(r0,r9),r0
	tst	r0,r0
	bf	1f
	ld	r4,D_BUF
	mov.l	tr_bpdbp,r0
	add	r0,r4			! the current medium's export.pdb path
	fw	D_FOPEN
	mov.l	tr_diag,r1
	mov.l	r0,@(0x08,r1)
	tst	r0,r0
	bt	tr_out
	mov	r0,r1
	mov	#TP_PDB,r0
	mov.l	r1,@(r0,r9)
	bsr	med_keep
	nop
	mov	r1,r0
1:	mov.l	r0,@(TP_FH,r9)
	mov	r0,r4			! rewind: the handle is reused
	mov	#0,r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4			! the header (page 0)
	mov	#1,r5
	mov.w	tr_4096b,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov.w	tr_4096b,r1		! a short read (NFS): again next pass
	cmp/eq	r1,r0			! (fread clobbers r4-r7: r6 is gone)
	bf	tr_short
	mov.l	@(4,r11),r12		! page size
	mov.w	tr_4096b,r0
	cmp/hi	r0,r12
	bt	tr_close		! pages larger than the buffer: give up
	mov.l	r12,@(TP_PS,r9)
	mov.l	@(8,r11),r13		! number of tables
	mov	#64,r0
	cmp/hi	r0,r13
	bt	tr_close
	mov	r11,r1
	add	#0x1c,r1
1:	tst	r13,r13
	bt	tr_close		! no track table
	mov.l	@r1,r0
	tst	r0,r0			! type 0 = tracks
	bt	2f
	add	#16,r1
	bra	1b
	dt	r13
2:	mov.l	@(8,r1),r0
	mov.l	r0,@(TP_P,r9)
	mov.l	@(12,r1),r0
	mov.l	r0,@(TP_LAST,r9)
	mov	#32,r0			! (V3rc3: tr_guard = 8192 = 32 << 8, its pool word out of reach)
	shll8	r0
	mov.l	r0,@(TP_N,r9)
	mov.l	tr_medl,r1		! a walk for this id cut short last pass: resume
	mov.l	@(36,r1),r0
	cmp/eq	r0,r10
	bf	tr_fresh
	mov.l	@(28,r1),r0
	mov.l	r0,@(TP_P,r9)
	mov.l	@(32,r1),r0
	mov.l	r0,@(TP_N,r9)
tr_fresh:
	mov	#0,r0
	mov.l	r0,@(40,r1)		! pages read by this call
	mov	#TP_XS,r0		! the index knows the page: read just that one
	mov.l	@(r0,r9),r0
	cmp/eq	#2,r0
	bf	tr_page
	mov.l	tr_idmax16,r0
	cmp/hi	r0,r10
	bt	tr_page
	mov	#TP_IDX,r0
	mov.l	@(r0,r9),r1
	mov	r10,r0
	add	r0,r0
	mov.w	@(r0,r1),r0
	extu.w	r0,r0
	tst	r0,r0
	bt	tr_page			! (not indexed: the full walk)
	mov.l	r0,@(TP_P,r9)
	mov.l	r0,@(TP_LAST,r9)
tr_page:
	mov.l	tr_medl,r1		! a walk is spread over passes: 48 pages a
	mov.l	@(40,r1),r0		! call (192 KB), then pending (resumed above)
	add	#1,r0
	mov.l	r0,@(40,r1)
	mov	#48,r2
	cmp/hi	r2,r0
	bf	tr_budget
	mov.l	@(TP_P,r9),r0
	mov.l	r0,@(28,r1)
	mov.l	@(TP_N,r9),r0
	mov.l	r0,@(32,r1)
	mov.l	r10,@(36,r1)
	mov	#1,r0
	mov.l	r0,@(TP_PEND,r9)
	bra	tr_out
	nop
tr_4096b:	.word 4096		! (the pool below is out of mov.w range)
	.p2align 2
tr_budget:
	mov.l	@(TP_P,r9),r0		! fseek(page * PS); read it
	mov.l	@(TP_PS,r9),r1
	mul.l	r1,r0
	sts	macl,r5
	mov.l	@(TP_FH,r9),r4
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4
	mov	#1,r5
	mov.l	@(TP_PS,r9),r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov.l	@(TP_PS,r9),r1		! a short read (NFS): again next pass
	cmp/eq	r1,r0			! (fread clobbers r4-r7: r6 is gone)
	bf	tr_short
	mov	r11,r1
	add	#0x1b,r1
	mov.b	@r1,r0			! page flags
	tst	#0x40,r0
	bf	tr_next			! not a data page
	mov	r11,r1
	add	#0x18,r1
	mov.b	@r1,r12
	extu.b	r12,r12			! rows (small count)
	mov	r11,r1
	add	#0x22,r1
	mov.w	@r1,r13
	extu.w	r13,r13			! rows (large count)
	cmp/hi	r12,r13
	bf	3f
	mov.w	tr_1fff,r0
	cmp/eq	r0,r13
	bt	3f
	mov	r13,r12
3:	mov	#0,r13			! r13 = row index
tr_row:
	cmp/hs	r12,r13
	bt	tr_next
	mov	r13,r0			! group base = PS - (i / 16) * 0x24
	shlr2	r0
	shlr2	r0
	mov	#0x24,r1
	mul.l	r1,r0
	sts	macl,r0
	mov.l	@(TP_PS,r9),r1
	sub	r0,r1
	add	r11,r1
	mov	r13,r2
	mov	#15,r0
	and	r0,r2			! k = i % 16
	mov	r1,r3
	add	#-4,r3
	mov.w	@r3,r3
	extu.w	r3,r3			! presence bits
	mov	r2,r0
	neg	r0,r0
	shld	r0,r3
	mov	r3,r0
	tst	#1,r0
	bt	tr_rnext
	mov	r2,r0			! offset = u16 at group base - 6 - 2k
	add	r0,r0
	mov	r1,r3
	sub	r0,r3
	add	#-6,r3
	mov.w	@r3,r14
	extu.w	r14,r14
	mov	#0x28,r0
	add	r0,r14			! row offset in the page
	mov	r14,r0			! the row's fixed part must fit the page
	mov.w	tr_rowsz,r1
	add	r1,r0
	mov.l	@(TP_PS,r9),r1
	cmp/hi	r1,r0
	bt	tr_rnext
	add	r11,r14			! r14 = row
	mov	r14,r1
	add	#0x48,r1		! id
	bsr	tr_rd32
	nop
	mov.l	tr_diag,r1		! diag: +0x18 rows seen, +0x1c last id read
	mov.l	r0,@(0x1c,r1)
	mov.l	@(0x18,r1),r2
	add	#1,r2
	mov.l	r2,@(0x18,r1)
	cmp/eq	r10,r0
	bt	tr_found
tr_rnext:
	bra	tr_row
	add	#1,r13
tr_next:
	mov.l	@(TP_N,r9),r0
	dt	r0
	bt	tr_close
	mov.l	r0,@(TP_N,r9)
	mov.l	@(TP_P,r9),r0
	mov.l	@(TP_LAST,r9),r1
	cmp/eq	r0,r1
	bt	tr_close
	mov	r11,r1
	add	#0x0c,r1		! next page
	bsr	tr_rd32
	nop
	mov.l	r0,@(TP_P,r9)
	bra	tr_page
	nop
tr_found:
	mov	#TP_RW,r0		! V3rc1: the LINK master's key lookup (rv_mkey, TP_RW = -1):
	mov.l	@(r0,r9),r0		! the key only, nothing else of the lookup state
	cmp/eq	#-1,r0
	bt	tr_key
	cmp/eq	#-2,r0			! V4b1: the loaded track's cue lookup (rv_cue, TP_RW = -2)
	bf	1f
	bra	tr_cue
	nop
1:	cmp/eq	#-3,r0			! V4n31: the TEMPO MASTER's waveform (w8n_step, TP_RW = -3)
	bf	1f
	mova	tr_w8l,r0
	mov.l	@r0,r1
	add	r0,r1
	jmp	@r1			! tr_w8n (ends as tr_out)
	nop
1:	mov.l	tr_diag,r1		! diag: +0x0c found rows
	mov.l	@(0x0c,r1),r0
	add	#1,r0
	mov.l	r0,@(0x0c,r1)
	mov.l	tr_medl,r1		! (no walk pending) and the row's file type
	mov	#0,r0			! (+0x5A: 1 MP3, 4 M4A, 5 FLAC, 11 WAV, 12 AIFF)
	mov.l	r0,@(36,r1)		! for the codec choice
	mov	r14,r2
	add	#0x5a,r2
	mov.b	@r2,r0
	extu.b	r0,r0
	mov.l	r0,@(24,r1)
	mov	#TP_RW,r0		! a browse row: only its PWAV
	mov.l	@(r0,r9),r0
	tst	r0,r0
	bf	tr_fanlz
	mov	r14,r4			! file path (string 20) -> shared+36
	mov	#20,r5
	mov.l	tr_shr,r6
	add	#36,r6
	bsr	tr_str
	nop
tr_fanlz:
	mov	#TP_RW,r0		! a browse row: its right-hand text first
	mov.l	@(r0,r9),r0
	tst	r0,r0
	bt	1f
	mov.l	tr_ui,r0		! V3rc3: a TAG LIST row (UI class 3; browse_key took the own
	mov.l	@r0,r0			! USB / SD for it): only when the export row's title (string 17)
	cmp/eq	#3,r0			! starts as the list row's -- else the track is another medium's
	bf	2f
	mov	r14,r4
	mov	#17,r5
	ld	r6,D_BUF
	mov.w	tr_bap,r0
	add	r0,r6
	bsr	tr_str
	nop
	ld	r2,D_BUF		! r2 = the title, wide (after "C:")
	mov.w	tr_bap,r0
	add	r0,r2
	add	#4,r2
	mov	#TP_RWN,r0		! r3 = the list row's text (live slot n)
	mov.l	@(r0,r9),r3
	mov	#0x22,r0
	shll2	r0
	shll2	r0			! 0x220
	mulu.w	r0,r3
	sts	macl,r3
	mov.l	tr_side,r0
	add	r0,r3
	mov	#0x28,r0
	mov.w	@(r0,r3),r0		! its length
	extu.w	r0,r1
	add	#0x2A,r3
	mov	#6,r0
	cmp/hi	r0,r1
	bf	3f
	mov	#6,r1
3:	tst	r1,r1
	bt	2f
4:	mov.w	@r2+,r0
	mov.w	@r3+,r5
	cmp/eq	r5,r0
	bf	tr_out			! another track: no cell, no text
	dt	r1
	bf	4b
2:	mova	tr_rmb,r0		! (the row is still whole in the page buffer)
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1			! rw_meta
	nop
1:	mov	r14,r4			! ANLZ path (string 14) -> B_APATH
	mov	#14,r5
	ld	r6,D_BUF
	mov.w	tr_bap,r0
	add	r0,r6
	bsr	tr_str
	nop
	mov	#TP_RW,r0
	mov.l	@(r0,r9),r0
	tst	r0,r0
	bf	1f
	mov.l	tr_shr,r1
	mov	#1,r0
	mov.l	r0,@(32,r1)		! audio path valid: the track can play
	mov.l	r0,@(TP_OK,r9)
1:	bsr	tr_pwav
	nop
	mova	tr_pv4b,r0		! tr_pwv4 for a browse row AND the INFO track:
	mov.l	@r0,r1			! PWV4 colour preview -> B_RW4 (TP_RWC); the
	add	r0,r1			! strip is then coloured by band (tp_d3c)
	jsr	@r1
	nop
	bra	tr_out
	nop
tr_close:				! (export.pdb stays open, see TP_PDB)
	mov.l	tr_medl,r1		! no walk pending
	mov	#0,r0
	mov.l	r0,@(36,r1)
tr_short:
	mov	#1,r0			! pending: the caller asks again next pass
	mov.l	r0,@(TP_PEND,r9)
tr_out:
	lds.l	@r15+,pr
	rts
	nop

tr_bpage:	.word B_PAGE
tr_bap:		.word B_APATH
tr_4096:	.word 4096
tr_guard:	.word 8192		! pages, at most
tr_1fff:	.word 0x1fff
tr_rowsz:	.word 0x88		! fixed part of a track row (+ string offsets)
	.p2align 2
tr_shr:		.long RAMB+0x1F800
tr_idmax16:	.long 0xFFFF
tr_rmb:		.long rw_meta - tr_rmb
tr_bpagel:	.long B_PAGE
tr_bpdbp:	.long B_PDBP
tr_medl:	.long MED
tr_pv4b:	.long tr_pwv4 - tr_pv4b
tr_diag:	.long RAMB+0x1FE40
tr_cnt:		.long RAMB+0x1FE80	! counters: +0x30 RESOLVE_PEND
tr_ui:		.long 0x0B54336C	! the MAIN UI state: +0 screen class (3 = TAG LIST)
tr_side:	.long 0x0B5434EC	! the live row slots (n * 0x220)
tr_w8l:		.long tr_w8n - tr_w8l

! V3rc1: tr_key -- the found row's key (id at +0x20 -> keys_build's name) as the display's key code,
! published by modsmenu (heartbeat +0x14 bits 8-12) through MED+68 = "MK" << 16 | code
tr_key:
	mov	r14,r1
	add	#0x20,r1
	bsr	tr_rd32
	nop
	mov	#127,r1
	cmp/hi	r1,r0
	bt	tr_out
	shll2	r0
	add	r0,r0
	mov.l	tk_keys,r1
	add	r0,r1			! its name
	bsr	key_code
	nop
	tst	r0,r0
	bt	tr_out
	mov.l	tk_mk,r1
	or	r1,r0
	mov.l	tk_med,r1
	bra	tr_out
	mov.l	r0,@r1

! key_code: r1 = a key name (ASCII: rekordbox's "Am", "F#m", "Eb" or Camelot "8A") -> r0 = Camelot
! number * 2 + (B ? 1 : 0), 0 = not a key (the same code as mods/v2ui/v2.c key_code). Uses r0-r3.
key_code:
	mov.b	@r1+,r2
	extu.b	r2,r2
	add	#-48,r2			! r2 = first character - '0'
	mov	#10,r3
	cmp/hs	r3,r2
	bt	kc_cls
	mov.b	@r1+,r0			! Camelot: one or two digits, then A / B
	extu.b	r0,r0
	add	#-48,r0
	cmp/hs	r3,r0
	bt	1f
	mov	r2,r3			! r2 = r2 * 10 + digit
	shll2	r2
	add	r3,r2
	shll	r2
	add	r0,r2
	mov.b	@r1+,r0
	bra	2f
	extu.b	r0,r0
1:	add	#48,r0
2:	cmp/eq	#0x41,r0
	bt	3f
	cmp/eq	#0x42,r0
	bf	kc_no
3:	add	#-0x41,r0
	mov	r0,r3			! r3 = B
	mov	r2,r0
	add	#-1,r0
	mov	#12,r1
	cmp/hs	r1,r0			! 1 .. 12
	bt	kc_no
	mov	r2,r0
	add	r0,r0
	rts
	add	r3,r0
kc_cls:	add	#-17,r2			! classic: r2 = letter - 'A'
	mov	#7,r3
	cmp/hs	r3,r2
	bt	kc_no
	mova	kc_pc,r0
	mov.b	@(r0,r2),r2		! its pitch class
	mov.b	@r1+,r0
	cmp/eq	#0x23,r0		! '#'
	bf	1f
	add	#1,r2
	bra	2f
	mov.b	@r1+,r0
1:	cmp/eq	#0x62,r0		! 'b'
	bf	2f
	add	#11,r2
	mov.b	@r1+,r0
2:	mov	#0,r3
	cmp/eq	#0x6D,r0		! 'm': minor
	bf	3f
	mov	#1,r3
	mov.b	@r1+,r0
3:	tst	r0,r0			! the end of the name (or a space)
	bt	4f
	cmp/eq	#0x20,r0
	bf	kc_no
4:	mov	r3,r0			! number = ((pc + 3 * minor) * 7 + 8) mod 12, 0 -> 12
	add	r0,r0
	add	r3,r0
	add	r2,r0
	mov	r0,r1
	shll2	r0
	shll	r0
	sub	r1,r0
	add	#8,r0
	mov	#12,r1
5:	cmp/hs	r1,r0
	bf	6f
	bra	5b
	sub	r1,r0
6:	tst	r0,r0
	bf	7f
	mov	#12,r0
7:	add	r0,r0
	mov	#1,r1
	sub	r3,r1
	rts
	add	r1,r0			! + 1 for major (B)
kc_no:	rts
	mov	#0,r0
	.p2align 2
kc_pc:	.byte	9, 11, 0, 2, 4, 5, 7	! A .. G
	.p2align 2
tk_keys:	.long RAMB+0x10400	! keys_build's names, 8 bytes per key id
tk_mk:		.long 0x4D4B0000	! "MK"
tk_med:		.long MED+68

! V4b1 (memory-cue colours / hot-cue colours / cue comments): tr_cue -- the cue lookup (TP_RW = -2) found
! the loaded track's row: its ANLZ path (string 14) -> B_APATH, then tr_pco2 copies the .EXT's PCO2 tags
! into the cue block and cue_pub publishes it. Not walked (file not opened): stays pending (rv_cue retries).
tr_cue:
	mov.l	tc_arc,r1		! G2: the loaded track's artwork, once per track (AR_STATE set by rv_cue)
	mov.l	@(AR_STATE,r1),r0
	extu.b	r0,r0			! V4n24: low byte = tries left (bit 8: the software image went out)
	tst	r0,r0
	bt	tc_na
	mov	r14,r1			! the artwork id (+0x1C), for rw_art
	add	#0x1c,r1
	bsr	tr_rd32
	nop
	mov.l	tc_aid,r1
	mov.l	r0,@r1
	mova	tc_alp,r0
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1			! ar_load: preserves r8-r14; r0 = 1: the JPU was busy, try again
	nop
	mov.l	tc_arc,r1
	mov.l	@(AR_STATE,r1),r2
	tst	r0,r0
	bf	1f
	bra	2f
	mov	#0,r2			! done
1:	add	#-1,r2			! one try less (none left: done)
	extu.b	r2,r0
	tst	r0,r0
	bf	2f
	mov	#0,r2
2:	mov.l	r2,@(AR_STATE,r1)
tc_na:	mov.l	tc_ctl,r1		! V4n24: an artwork-only retry (CC_STATE 2): the cues are out already
	mov.l	@(CC_STATE,r1),r0
	cmp/eq	#2,r0
	bt	tc_fin
	mov	r14,r4			! V4n24: the title (string 17) -> the cue block's tail ('TITL', for loads
	mov	#17,r5			! the browse did not start: CONTINUE / track search / LINK -- the
	mov.l	tc_tsrc,r6		! player model's title slot can be empty or stale then)
	bsr	tr_str
	nop
	mov.l	tc_tsrc,r1
	add	#4,r1			! (after "X:")
	mov.l	tc_tdst,r2
	mov	#0,r3
3:	mov.w	@r1+,r0
	extu.w	r0,r0
	tst	r0,r0
	bt	4f
	swap.b	r0,r0			! big-endian as the display's model slots
	mov.w	r0,@r2
	add	#2,r2
	add	#1,r3
	mov	#64,r0
	cmp/hs	r0,r3
	bf	3b
4:	mov.l	tc_tdst,r2
	add	#-12,r2
	mov.l	tc_tmag,r0
	mov.l	r0,@r2
	mov.l	tc_ctl,r1
	mov.l	@(CC_RB,r1),r0
	swap.b	r0,r0
	swap.w	r0,r0
	swap.b	r0,r0
	mov.l	r0,@(4,r2)
	mov	r3,r0
	swap.b	r0,r0
	swap.w	r0,r0
	swap.b	r0,r0
	mov.l	r0,@(8,r2)
	mov	r14,r4
	mov	#14,r5
	ld	r6,D_BUF
	mov.w	tc_bap,r0
	add	r0,r6
	bsr	tr_str
	nop
	mova	tc_pb,r0
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1			! tr_pco2: r10 = bytes copied, CC_OK = 1 when the walk finished
	nop
	mov.l	tc_ctl,r1
	mov.l	@(CC_OK,r1),r0
	tst	r0,r0
	bt	tc_out
	mova	tc_pub,r0
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1			! cue_pub (r10 = used)
	nop
tc_fin:	mov.l	tc_ctl,r1		! done -- or 2 while the artwork waits for the JPU (rv_cue retries ~1/s)
	mov.l	tc_arc,r2
	mov.l	@(AR_STATE,r2),r0
	extu.b	r0,r0
	tst	r0,r0
	bt	5f
	mov.l	@(D_TICK,r8),r3
	mov.l	@r3,r3
	mov.l	r3,@(AR_T,r2)
	mov	#2,r0
5:	mov.l	r0,@(CC_STATE,r1)
tc_out:	bra	tr_out
	nop
tc_bap:		.word B_APATH
	.p2align 2
tc_ctl:		.long RAMB+0x15010
tc_pb:		.long tr_pco2 - tc_pb
tc_pub:		.long cue_pub - tc_pub
tc_arc:		.long RAMB+0x15030
tc_aid:		.long RAMB+0x10090
tc_alp:		.long ar_load - tc_alp
tc_tsrc:	.long RAMB+0x14000 + 0xE0C	! tr_str's scratch (<= 516 B, ends at the block's end; the tags come after)
tc_tdst:	.long RAMB+0x14000 + TITL_OFF + 12
tc_tmag:	.ascii	"TITL"


	.p2align 2
! tr_rd32: r0 = little-endian u32 at r1 (any alignment). Clobbers r2.
tr_rd32:
	mov.b	@(3,r1),r0
	extu.b	r0,r2
	shll8	r2
	mov.b	@(2,r1),r0
	extu.b	r0,r0
	or	r0,r2
	shll8	r2
	mov.b	@(1,r1),r0
	extu.b	r0,r0
	or	r0,r2
	shll8	r2
	mov.b	@r1,r0
	extu.b	r0,r0
	rts
	or	r2,r0

! tr_str: r4 = track row, r5 = string index, r6 = dst. Writes "C:" + the
! DeviceSQL string (short ASCII, long ASCII 0x40 or UTF-16LE 0x90) wide and
! NUL-terminated, at most 255 characters. Clobbers r0-r3, r6.
tr_str:
	mov	r5,r0
	add	r0,r0
	add	#0x5e,r0
	mov	r4,r1
	add	r0,r1
	mov.b	@r1+,r0			! u16 string offset (bytewise)
	extu.b	r0,r2
	mov.b	@r1,r0
	extu.b	r0,r0
	shll8	r0
	or	r2,r0
	mov	r4,r1
	add	r0,r1			! r1 = the string
	mov.l	ts_med,r0		! the medium's letter: "C:", or D:.. for a
	mov.l	@(4,r0),r0		! LINKed player's medium (set_medium)
	mov.w	r0,@r6
	mov	#0x3a,r0
	mov.w	r0,@(2,r6)
	add	#4,r6
	mov.b	@r1,r0
	extu.b	r0,r2			! kind
	tst	#1,r0
	bt	1f
	shlr	r2			! short ASCII: kind/2 - 1 bytes follow
	add	#-1,r2
	bra	ts_8
	add	#1,r1
1:	mov.b	@(1,r1),r0		! long: u16 length, with its 4-byte head
	extu.b	r0,r3
	mov.b	@(2,r1),r0
	extu.b	r0,r0
	shll8	r0
	or	r0,r3
	add	#-4,r3
	add	#4,r1
	mov	r2,r0
	cmp/eq	#0x40,r0
	bf	2f
	bra	ts_8			! long ASCII
	mov	r3,r2
2:	mov	r3,r2			! UTF-16LE: bytes / 2 characters
	shlr	r2
	cmp/pl	r2
	bf	ts_nul
	mov.w	ts_max,r0
	cmp/hi	r0,r2
	bf	3f
	mov	r0,r2
3:	mov.b	@r1+,r0
	extu.b	r0,r3
	mov.b	@r1+,r0
	extu.b	r0,r0
	shll8	r0
	or	r3,r0
	mov.w	r0,@r6
	add	#2,r6
	dt	r2
	bf	3b
	bra	ts_nul
	nop
ts_8:	cmp/pl	r2
	bf	ts_nul
	mov.w	ts_max,r0
	cmp/hi	r0,r2
	bf	4f
	mov	r0,r2
4:	mov.b	@r1+,r0
	extu.b	r0,r0
	mov.w	r0,@r6
	add	#2,r6
	dt	r2
	bf	4b
ts_nul:	mov	#0,r0
	rts
	mov.w	r0,@r6
ts_max:		.word 255
	.p2align 2
ts_med:		.long MED

! tr_pwav: opens the ANLZ file at B_APATH (.DAT), walks its tags for PWAV
! and reads the 400-byte preview into B_WAVE. TP_WAVE = 1 on success (a row:
! TP_RWOK); a track without it still plays, with a flat band for a waveform.
tr_pwav:
	sts.l	pr,@-r15
	ld	r4,D_BUF
	mov.w	tw_bap,r0
	add	r0,r4
	fw	D_FOPEN
	mov.l	tw_diag,r1		! diag: +0x10 ANLZ fopen, +0x14 PWAV read
	mov.l	r0,@(0x10,r1)
	tst	r0,r0
	bt	9f
	mov.l	r0,@(TP_FH,r9)
	mov	#0,r12			! file offset
	mov	#40,r13			! tags, at most
1:	mov.l	@(TP_FH,r9),r4
	mov	r12,r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4			! 12-byte head -> the page buffer
	mov	#1,r5
	mov	#12,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov	#12,r1			! a short read: no tag (fread clobbers r6)
	cmp/eq	r1,r0
	bf	8f
	mov.l	@(4,r11),r1		! big-endian header length
	swap.b	r1,r1
	swap.w	r1,r1
	swap.b	r1,r1
	mov.l	@(8,r11),r2		! big-endian tag length
	swap.b	r2,r2
	swap.w	r2,r2
	swap.b	r2,r2
	tst	r12,r12
	bf	2f
	bra	3f			! the PMAI file header: skip it
	mov	r1,r12
2:	mov.l	@r11,r0
	mov.l	tw_pwav,r3
	cmp/eq	r3,r0
	bt	4f
	tst	r2,r2
	bt	8f
	add	r2,r12			! next tag
3:	dt	r13
	bf	1b
	bra	8f
	nop
4:	mov.l	@(TP_FH,r9),r4		! PWAV: its data follows its header
	mov	r12,r5
	add	r1,r5
	mov	#0,r6
	fw	D_FSEEK
	ld	r4,D_BUF
	mov	#TP_RW,r0
	mov.l	@(r0,r9),r0
	tst	r0,r0
	mov.w	tw_bwave,r0
	bt	5f
	mov.w	tw_brwave,r0		! a browse row's PWAV
5:	add	r0,r4
	mov	#1,r5
	mov.w	tw_400,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov.l	tw_diag,r1
	mov.l	r0,@(0x14,r1)
	mov	#TP_RW,r0
	mov.l	@(r0,r9),r0
	tst	r0,r0
	mov	#1,r0
	bt	5f
	mov	#TP_RWOK,r1
	add	r9,r1
	bra	8f
	mov.l	r0,@r1
5:	mov	#TP_WAVE,r0		! the waveform is in B_WAVE (audio needs only
	mov	#1,r1			! the path: TP_OK, set by tp_resolve)
	mov.l	r1,@(r0,r9)
8:	mov.l	@(TP_FH,r9),r4
	fw	D_FCLOSE
	mov.l	tw_diag,r1		! diag +0x24: ANLZ fclose result
	mov.l	r0,@(0x24,r1)
9:	lds.l	@r15+,pr
	rts
	nop

tw_bap:		.word B_APATH
tw_bwave:	.word B_WAVE
tw_brwave:	.word B_RWAVE
tw_400:		.word 400
	.p2align 2
tw_pwav:	.ascii	"PWAV"
tw_diag:	.long RAMB+0x1FE40

! row_touch (rowwave): in a browse list, a finger on a row (the whole row is
! the target: x 33-779 across it = the whole track, rows of 30 px from y 47,
! 28 px tall; the waveform in the artwork cell is the guide) previews that
! row's track on the LINK CUE from the touched point; dragging seeks,
! lifting stops. The track id is the one the
! rowwave hook published for the row (want[n], 0 for a non-track row).
! r0 = 1 when the touch was ours (the caller skips INFO / Touch Cue).
! r9 = TP state; uses r10-r14 (saved by touch_preview).
row_touch:
	sts.l	pr,@-r15
	mov.l	rt_pvk,r1		! TOUCH (V4n41): the browse header's PREVIEW tile off (modsmenu kill_v +24
	mov.l	@r1,r0			!   = 0): no row preview (one playing ends: rt_off)
	tst	r0,r0
	bt	rt_off
	mov.l	rt_tab,r12
	mov.l	@r12,r0			! the rowwave hook has run?
	mov.l	rt_magic,r1
	cmp/eq	r1,r0
	bf	rt_no
	mov.l	rt_tx,r1
	mov.l	@r1,r13			! x
	mov.l	@(4,r1),r14		! y
	mova	rt_geo,r0		! V3e1: the row geometry from rt_geo (the v2ui
	mov	r0,r3			! (pc-relative: the blob is not linked)
	mov.l	@(4,r3),r1		! MAIN pseudo-mod rewrites it for the V3 layout)
	mov	r13,r0			! inside the cells' column?
	sub	r1,r0
	mov	r0,r13			! r13 = x within the cell
	cmp/pz	r0
	bf	rt_off
	mov.l	@(8,r3),r1
	cmp/hs	r1,r0
	bt	rt_off
	mov.l	rt_kbd,r1		! the SEARCH keyboard is up (MAIN 0x084D0024's
	mov	#0x54,r0		! test): its rows' own geometry, and never below
	mov.l	@(r0,r1),r0
	mov.l	rt_kbd2,r1		! the keys' top
	mov.l	@r1,r1
	or	r1,r0
	tst	r0,r0
	bt	7f
	add	#12,r3			! the keyboard set: +12 (y0, pitch, h, then y max)
	mov.l	@(24,r3),r0
	cmp/hs	r0,r14
	bt	rt_off
7:	mov	r14,r0
	mov.l	@(12,r3),r1
	sub	r1,r0
	cmp/pz	r0
	bf	rt_off
	mov.l	@(16,r3),r1		! n = (y - y0) / pitch + 1
	mov	#1,r2
1:	cmp/hs	r1,r0
	bf	2f
	sub	r1,r0
	bra	1b
	add	#1,r2
2:	mov.l	@(20,r3),r1		! the gap between cells
	cmp/hs	r1,r0
	bt	rt_off
	mov	#9,r1
	cmp/hs	r1,r2
	bt	rt_off
	mov	r2,r0
	shll2	r0
	add	r12,r0
	mov.l	@(0x10,r0),r10		! r10 = the row's track id
	tst	r10,r10
	bt	rt_off
	mov.l	rt_med,r1		! V3e2: the row preview for the display (modsmenu v3e_pub ->
	mov	r2,r0			! heartbeat +0xE8): MED+64 = "PV" << 16 | bit 14 playing |
	shll8	r0			! row << 10 | column
	shll2	r0
	mov.l	rt_pvm,r3
	or	r3,r0
	mov.l	r0,@r1
	mov	r13,r4			! r11 = column: x * 600 / row width (0-599)
	mov.w	rt_600,r0
	mulu.w	r0,r4
	sts	macl,r4
	mova	rt_geo,r0
	mov.l	@(8,r0),r5
	bsr	udiv
	nop
	mov	r0,r11
	mov.l	rt_med,r1
	mov.l	@r1,r0
	or	r11,r0
	mov.l	r0,@r1
	mov.l	@(TP_ID,r9),r0
	cmp/eq	r0,r10
	bt	3f
	mov.l	r10,@(TP_ID,r9)		! another track: stop, resolve
	mov	#0,r2
	st	r2,D_PREVIEW
	mov.l	r2,@(TP_OPEN,r9)
	mov	#TP_ROWON,r0
	mov.l	r2,@(r0,r9)
	bsr	close_cur
	nop
	mov.l	r11,@-r15
	mov.l	r10,@-r15
	bsr	browse_key		! the list's medium
	nop
	bsr	set_medium
	nop
	tst	r0,r0
	bf	rt_sm
	mov	#0,r0			! not mounted: nothing to look up
	mov.l	r0,@(TP_OK,r9)
	mov.l	r0,@(TP_PEND,r9)
	bra	rt_smd
	nop
rt_sm:	bsr	tp_resolve		! -> its path at shared+36, TP_OK
	mov	r10,r4
rt_smd:	mov.l	@r15+,r10
	mov.l	@r15+,r11
	mov.l	@(TP_PEND,r9),r0	! the index is still building: again next pass
	tst	r0,r0
	bt	3f
	mov	#0,r0
	mov.l	r0,@(TP_ID,r9)
3:	mov.l	@(TP_OK,r9),r0
	tst	r0,r0
	bt	rt_yes
	ld	r0,D_PREVIEW
	tst	r0,r0
	bf	4f
	mov.w	rt_lat,r0		! a load stopped it: wait for the finger
	mov.l	@(r0,r8),r0		! to leave the row
	tst	r0,r0
	bf	rt_yes
	mov.l	@(TP_OPEN,r9),r0	! press: open (once per track), seek, play
	tst	r0,r0
	bf	5f
	mov.l	r11,@-r15
	bsr	open_selected
	nop
	mov.l	@r15+,r11
	ld	r0,D_FH			! open failed: the next press tries again
	tst	r0,r0
	bt	rt_yes
	mov	#1,r0
	mov.l	r0,@(TP_OPEN,r9)
	bra	5f
	nop
4:	mov.l	@(TP_COL,r9),r0		! drag: reseek once moved 2+ columns
	sub	r11,r0
	cmp/pz	r0
	bt	6f
	neg	r0,r0
6:	mov	#2,r1
	cmp/ge	r1,r0
	bf	rt_yes
5:	mov.l	r11,@(TP_COL,r9)
	mov	r11,r4
	bsr	tp_seek
	nop
	mov	#1,r2
	st	r2,D_PREVIEW
	mov	#TP_ROWON,r0
	mov.l	r2,@(r0,r9)
rt_yes:	ld	r0,D_PREVIEW
	tst	r0,r0
	bt	1f
	mov.l	rt_med,r1		! playing: bit 14
	mov.l	@r1,r0
	mov	#0x40,r2
	shll8	r2
	or	r2,r0
	mov.l	r0,@r1
1:	mov	#1,r0
	lds.l	@r15+,pr
	rts
	nop
rt_off:	mov.w	rt_lat,r0		! off the row: a load's latch ends
	mov	#0,r1
	mov.l	r1,@(r0,r8)
	mov.l	rt_med,r1		! (no row preview for the display)
	mov.l	rt_pvm,r0
	mov.l	r0,@r1
	mov	#TP_ROWON,r0		! not on a cell: a row preview ends here
	mov.l	@(r0,r9),r1
	tst	r1,r1
	bt	rt_no
	mov	#0,r1
	mov.l	r1,@(r0,r9)
	st	r1,D_PREVIEW
	bra	rt_yes
	nop
rt_no:	mov	#0,r0
	lds.l	@r15+,pr
	rts
	nop
rt_600:		.word 600
rt_lat:		.word D_LATCH
	.p2align 2
rt_tab:		.long RAMB+0x10000	! the rowwave hook's table
rt_med:		.long MED + 64		! V3e2: the row preview word for the display
rt_pvm:		.long 0x50560000	! "PV"
rt_kbd:		.long 0x0B54336C	! UI state (+0x54 keyboard)
rt_kbd2:	.long 0x0B545B64
rt_pvk:		.long KILLB + 24	! TOUCH: modsmenu kill_v +24 PREVIEW (1 ON)
! V3e1: the rows' touch geometry, "RTGO" then x0, w (the column: x * 600 / w),
! y0, pitch, cell height -- and the same with the SEARCH keyboard up, plus the
! keys' top (no row at or below it). Stock layout here; mods/v2ui/v2ui.py
! (v2needle) writes the V3 layout's values behind the marker.
rt_geo:		.long 0x5254474F, 33, 747, 47, 30, 28, 47, 30, 28, 294
rt_magic:	.long 0x52575633	! "RWV3"
rt_tx:		.long 0x0B06C774	! calibrated touch x, y (pixels; 0 when up)

! ---------------------------------------------------------------------------
! row_waves (rowwave, TchAud side). The UI hook (mods/rowwave) publishes the
! track id of each visible browse TRACK row in the table at 0x081F0000
! (magic, want[n] at +0x10, done[n] at +0x34, n = 1-8). One step per loop
! pass: first an index of export.pdb (track id -> page, u16 per id, malloc'd
! once) built a few pages at a time; then one wanted row: its lookup (the
! index makes it one page read) as a browse row (TP_RW: the INFO / Touch Cue
! state is left alone), its PWAV drawn into the row's 80x28 RGB565 buffer
! (0x081E0000 + (n-1)*0x1180) and the row slot flagged for the packer to send
! it again. r8 = data.
! ---------------------------------------------------------------------------
row_waves:
	sts.l	pr,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15
	mov.l	r14,@-r15
	mov.l	rv_quiet,r1		! TchDec out of the file layer before the rows'
	mov.w	@r1,r0			! pdb / ANLZ / artwork reads (q_quiet; not with
	cmp/eq	#-1,r0			! the blob absent: erased cave)
	bt	0f
	jsr	@r1
	nop
0:	ld	r9,D_BUF
	mov.l	rv_btpl,r0
	add	r0,r9			! r9 = TP state
	mov.l	rv_medl,r1		! the medium gone (pulled, swapped) while the
	mov.l	@r1,r0			! index is ready: rebuilt -- idx_step drops
	tst	r0,r0			! the index, the handle and the row cache
	bt	1f
	mov.l	@(16,r1),r1
	mov.l	@(8,r1),r0
	cmp/eq	#2,r0
	bt	1f
	mov	#TP_XS,r0
	mov	#0,r1
	mov.l	r1,@(r0,r9)
1:	mov.l	rv_tab,r12
	mov.l	@r12,r0			! has the UI hook run (its magic)?
	mov.l	rv_magic,r1
	cmp/eq	r1,r0
	bt	1f
	mov	#TP_XS,r0		! no rowwave: the index is still built here,
	mov.l	@(r0,r9),r0		! INFO and Touch Cue lookups need it
	cmp/eq	#2,r0
	bt	rv_out
	bsr	idx_step
	nop
	bra	rv_out
	nop
1:	bsr	rw_mode			! WAVEFORM COLOR changed: rows redrawn
	nop
1:	mov	#TP_XS,r0
	mov.l	@(r0,r9),r0
	cmp/eq	#2,r0
	bt	rv_keys
	cmp/eq	#3,r0
	bf	2f
	bsr	idx_step		! failed: tried again every 10 s; meanwhile
	nop				! the rows take the full walk, slow but right
	bra	rv_rows
	nop
2:	bsr	idx_step
	nop
	bra	rv_out
	nop
rv_keys:
	mov	#TP_KS,r0		! once: the key names (rows' right-hand text)
	mov.l	@(r0,r9),r0
	tst	r0,r0
	bf	rv_rows
	mova	rv_kb,r0
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1			! keys_build
	nop
	bra	rv_out
	nop
rv_rows:
	bsr	browse_key		! hits: cells kept for the medium the list
	nop				! shows (none while its key settles)
	tst	r4,r4
	bt	rv_deb
	bsr	canon_key
	nop
	mov	r4,r11			! r11 = the list's medium key
	mov	#1,r13
rv_hit:	mov	r13,r0			! every wanted row not drawn yet whose cell
	shll2	r0			! is in the cache: copied in at once
	add	r12,r0
	mov.l	@(0x10,r0),r10		! want[n]
	mov.l	@(0x34,r0),r1		! done[n]
	tst	r10,r10
	bt	rv_hnx
	cmp/eq	r10,r1
	bt	rv_hnx
	bsr	rv_sync			! (not before the row's new text is in the
	nop				! model the packer reads)
	bf	rv_hnx
	bsr	rc_slot
	nop
	tst	r0,r0
	bt	rv_deb			! no cache
	mov.l	@r0,r1
	cmp/eq	r10,r1
	bf	rv_hnx
	mov.l	@(4,r0),r1
	cmp/eq	r11,r1
	bf	rv_hnx
	mov	r0,r4
	bsr	rc_rowp			! r5 = row n's cell, r7 = its text
	add	#16,r4
	mov.w	rv_cellw2,r6
	bsr	rc_cpy
	nop
	mov	r7,r5
	bsr	rc_cpy
	mov	#24,r6
	bsr	rv_latch
	nop
rv_hnx:	add	#1,r13
	mov	#9,r0
	cmp/hs	r0,r13
	bf	rv_hit
rv_deb:	mov	r12,r1			! misses: only once the wanted rows have held
	add	#0x14,r1		! RW_SETTLE ms (a scroll reads no file for
	mov	#8,r3			! rows that only fly by)
	mov	#0,r2
1:	rotl	r2
	rotl	r2
	rotl	r2
	mov.l	@r1+,r0
	dt	r3
	bf/s	1b
	xor	r0,r2
	mov.l	rv_medl,r1
	mov.l	@(D_TICK,r8),r3
	mov.l	@r3,r3
	mov.l	@(56,r1),r0
	cmp/eq	r2,r0
	bt	2f
	mov.l	r2,@(56,r1)		! changed: its clock starts now
	bra	rv_out
	mov.l	r3,@(60,r1)
rv_cellw2:	.word 0x1180 / 4
2:	mov.l	@(60,r1),r0
	sub	r0,r3
	mov	#RW_SETTLE,r0
	cmp/hs	r0,r3
	bf	rv_out
	mov	#1,r13			! r13 = the first wanted row not drawn yet
1:	mov	r13,r0
	shll2	r0
	add	r12,r0
	mov.l	@(0x10,r0),r10		! want[n]
	mov.l	@(0x34,r0),r1		! done[n]
	tst	r10,r10
	bt	2f
	cmp/eq	r10,r1
	bf	3f
2:	add	#1,r13
	mov	#9,r0
	cmp/hs	r0,r13
	bf	1b
	bsr	rv_warm			! V3rc2: every row drawn -- warm the cache with the medium's tracks
	nop
	bra	rv_cuej			! V4b1: every row drawn -- the loaded track's cues, then the key
	nop
3:	bsr	rc_alloc		! the cache, once
	nop
	mov	#TP_RWN,r0		! look it up as a browse row
	mov.l	r13,@(r0,r9)
	mov	#TP_RW,r0
	mov	#1,r1
	mov.l	r1,@(r0,r9)
	mov	#TP_RWOK,r0
	mov	#0,r1
	mov.l	r1,@(r0,r9)
	mov	#TP_RWC,r0		! (no colour unless this lookup reads one)
	mov.l	r1,@(r0,r9)
	mov.l	r13,@-r15		! (tp_resolve uses r10-r14)
	mov.l	r10,@-r15
	bsr	browse_key		! the list's medium
	nop
	bsr	set_medium
	nop
	tst	r0,r0
	bf	rv_sm
	mov	#0,r0			! not mounted: nothing to look up
	mov.l	r0,@(TP_PEND,r9)
	bra	rv_smd
	nop
rv_sm:	bsr	tp_resolve
	mov	r10,r4
rv_smd:	mov.l	@r15+,r10
	mov.l	@r15+,r13
	mov	#TP_RW,r0
	mov	#0,r1
	mov.l	r1,@(r0,r9)
	mova	rv_ab,r0		! its artwork, 20x20 (rw_art)
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1
	nop
	bsr	rw_draw
	mov	r13,r4
	mov.l	rv_tab,r12
	! grey-row fix: done[n] is latched only once the colour (TP_RWC) resolved, or
	! after RW_RETRY_MAX tries (a track without PWV4 settles, no loop); not
	! latched, the row is retried on the next passes (an fopen that failed on
	! handle contention recovers to colour). Only latched rows are cached.
	mov	#TP_RWC,r0
	mov.l	@(r0,r9),r1
	tst	r1,r1
	bf	9f			! colour OK: latch
	bsr	rw_isblue		! WAVEFORM COLOR BLUE: no colour to wait for
	nop
	bt	9f
	mov	r13,r0
	shll2	r0
	add	r12,r0
	add	#T_RETRY,r0
	mov.l	@r0,r1
	add	#1,r1			! retry[n]++
	mov.l	r1,@r0
	mov	#RW_RETRY_MAX,r2
	cmp/hs	r2,r1
	bt	9f
	bsr	rv_send			! under the cap: shown, not latched (retried)
	nop
	bra	rv_out
	nop
9:	bsr	rc_put			! kept for the next time the row shows
	nop
	bsr	rv_latch
	nop
! V3rc1 (route A, re_deck): the LINK master's key for the 3000's harmonic KEY colours. The master
! track w8send targets (W8S +0x24 KEY = source player | slot << 8 | type << 16 | master << 24, +0x28
! RBID) is looked up in this medium's export.pdb (the index: one page) when it is on the medium the
! index belongs to (MED+0); its key -> MED+68 ("MK" << 16 | key code, tr_key), MED+72 / +76 = the rbid
! / target tried, MED+80 the index's medium then. Once per target / medium.
rv_mkey:
	mov.l	rk_w8,r1
	mov.l	@r1,r0
	mov.l	rk_w8m,r2
	cmp/eq	r2,r0			! w8send runs ('W8F1')
	bf	rv_out
	mov.l	@(0x24,r1),r4		! r4 = the target
	mov.l	@(0x28,r1),r5		! r5 = its rbid
	mov.l	rv_medl,r3
	mov.l	@r3,r6			! r6 = the index's medium
	add	#64,r3			! r3 = MED + 64
	mov.l	@(12,r3),r0
	cmp/eq	r4,r0
	bf	1f
	mov.l	@(8,r3),r0
	cmp/eq	r5,r0
	bf	1f
	mov.l	@(16,r3),r0
	cmp/eq	r6,r0
	bt	rv_out			! tried already
1:	mov.l	r4,@(12,r3)
	mov.l	r5,@(8,r3)
	mov.l	r6,@(16,r3)
	mov	#0,r0
	mov.l	r0,@(4,r3)		! no key until found
	tst	r4,r4
	bt	rv_out			! no master (or not a rekordbox track)
	mov	r4,r0			! its medium: source player << 8 | slot
	shlr8	r0
	extu.b	r0,r0
	extu.b	r4,r4
	shll8	r4
	bsr	canon_key
	or	r0,r4
	cmp/eq	r4,r6
	bf	rv_out			! another medium: no key (route A)
	mov	#TP_XS,r0
	mov.l	@(r0,r9),r0
	cmp/eq	#2,r0
	bt	2f
	mov	#0,r0			! the index not ready yet: tried again later
	bra	rv_out
	mov.l	r0,@(12,r3)
2:	mov	#TP_RW,r0
	mov	#-1,r1
	mov.l	r1,@(r0,r9)		! a key-only lookup (tr_found -> tr_key)
	bsr	tp_resolve
	mov	r5,r4
	mov	#TP_RW,r0
	mov	#0,r1
	mov.l	r1,@(r0,r9)
rv_out:
	mova	rv_w8b,r0		! V4n31: the master's waveform over NFS (w8n_step)
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1
	nop
	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	lds.l	@r15+,pr
	rts
	nop

! rv_latch: r13 = row n, r10 = its track id, r12 = the table: done[n] = id,
! retry[n] = 0, then rv_send. rv_send: if row n still wants that track, its
! right-hand text into the UI slot and the model (rw_mput) and the flags that
! make the packer send the row's cell again. Clobbers r0-r7.
rv_latch:
	mov	r13,r0
	shll2	r0
	add	r12,r0
	mov.l	r10,@(0x34,r0)		! done[n] = id
	add	#T_RETRY,r0
	mov	#0,r1
	mov.l	r1,@r0			! retry[n] = 0
rv_send:
	mov	r13,r0
	shll2	r0
	add	r12,r0
	mov.l	@(0x10,r0),r1
	cmp/eq	r10,r1			! still that row's track: send it again
	bf	9f
	sts.l	pr,@-r15
	mov	r13,r4			! its right-hand text into the UI slot and
	mova	rv_mp,r0		! the model (rw_mput)
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1
	nop
	mov.w	rv_220,r0
	mulu.w	r0,r13
	sts	macl,r1
	mov.l	rv_side,r2
	add	r2,r1			! S of row n
	add	#0x0c,r1
	mov.b	@r1,r0
	or	#2,r0
	mov.b	r0,@r1			! S+0x0C bit 1: send the artwork
	mov.b	@r2,r0
	or	#0x10,r0
	mov.b	r0,@r2			! side 0: artwork changed
	mov.l	rv_model,r0		! the same in the model the packer reads
	sub	r2,r1			! (FUN_084D11CC copies the UI slots there
	add	r0,r1			! only on a UI change)
	mov.b	@r1,r2
	mov	r0,r3
	mov	r2,r0
	or	#2,r0
	mov.b	r0,@r1
	mov.b	@r3,r0
	or	#0x10,r0
	mov.b	r0,@r3
	lds.l	@r15+,pr
9:	rts
	nop
! rv_sync: T = row n's (r13) new text has reached the model copy the packer
! reads (its title there equals the UI slot's). A cached cell is sent only
! then: flagged sooner (right after the list parse) the packer sent the
! model's previous titles and the list kept showing them. Clobbers r0-r3, r7.
rv_sync:
	mov.w	rv_220,r0
	mulu.w	r0,r13
	sts	macl,r3
	mov.l	rv_side,r1
	add	r3,r1
	mov.l	rv_model,r2
	add	r3,r2
	add	#0x28,r1		! the title: u16 length, then UTF-16
	add	#0x28,r2
	mov.w	@r1,r3
	mov.w	@r2,r0
	cmp/eq	r3,r0
	bf	9f
	extu.w	r3,r3
	mov.w	rv_cf,r0
	cmp/hs	r0,r3			! (too long for rw_mput: not here)
	bt/s	9f
	cmp/eq	r0,r1			! (T = 0)
1:	tst	r3,r3
	bt	9f			! all equal: T = 1
	add	#2,r1
	add	#2,r2
	mov.w	@r1,r0
	mov.w	@r2,r7
	cmp/eq	r0,r7
	bf	9f
	bra	1b
	add	#-1,r3
9:	rts
	nop
rv_cf:		.word 0xCF
rv_220:		.word 0x220
rv_cellw:	.word 0x1180 / 4
	.p2align 2
rv_btpl:	.long B_TP
rv_medl:	.long MED
rv_quiet:	.long TADEC+0x1C	! q_quiet
rv_kb:		.long keys_build - rv_kb
rv_ab:		.long rw_art - rv_ab
rv_mp:		.long rw_mput - rv_mp
rv_tab:		.long RAMB+0x10000	! the UI hook's table (mods/rowwave)
rv_magic:	.long 0x52575633	! "RWV3"
rk_w8:		.long RAMB+0x1E000	! mods/w8fetch's state (w8.inc W8S)
rk_w8m:		.long 0x31463857	! 'W8F1'
rv_w8b:		.long w8n_step - rv_w8b
rv_side:	.long 0x0B5434EC	! row slots: S = this + n * 0x220
rv_model:	.long 0x0B53FBA4	! their copy in the model (0x0B53FB50 + 0x54)

! V4b1: rv_cuej -- far jump to rv_cue (it ends in rv_mkey)
rv_cuej:
	mova	rc_cb,r0
	mov.l	@r0,r1
	add	r0,r1
	jmp	@r1
	nop
	.p2align 2
rc_cb:		.long rv_cue - rc_cb

! rv_warm (V3rc2): with every wanted row drawn, the deck not playing (the heartbeat's elapsed word still
! for 500 ms) and no row preview, one track of the index's medium is built every RW_WARM ms into the
! scratch row 9 (rc_scr: never shown) and kept in the row cache, so a list's first visit finds its cells
! ready. Ids walk up from 1 (present in the index, not cached yet), at most RC_N per medium; a new index
! medium restarts the walk. State at MED+84: +0 the next id, +4 the last build's tick, +8 the medium the
! walk belongs to, +12 cells built, +16 / +20 the elapsed word and the tick it last moved.
	.equ	RW_WARM, 150
rv_warm:
	sts.l	pr,@-r15
	mov.l	rw_ui,r0		! V3rc8w (re/USB_LED_BLINK.md): warm only while a list shows (UI class 2/3) --
	mov.l	@r0,r0			! idle on the player it read ~4 tracks/s for minutes = USB LEDs blinking
	add	#-2,r0
	mov	#1,r1
	cmp/hi	r1,r0			! (class - 2) > 1 unsigned: not 2 / 3
	bt	rw_9
	mov	#TP_CACHE,r0
	mov.l	@(r0,r9),r0
	mov	#1,r1
	cmp/hi	r1,r0
	bf	rw_9			! no cache
	mov	#TP_XS,r0
	mov.l	@(r0,r9),r0
	cmp/eq	#2,r0
	bf	rw_9			! no index (yet)
	mov.l	rw_medp,r7		! r7 = MED, r6 = MED + 84
	mov	r7,r6
	add	#84,r6
	mov.l	@(D_TICK,r8),r3
	mov.l	@r3,r3			! r3 = now (ms)
	mov.l	rw_el,r1		! playing: the heartbeat's elapsed word moves
	mov.l	@r1,r0
	mov.l	@(16,r6),r1
	cmp/eq	r1,r0
	bt	1f
	mov.l	r0,@(16,r6)
	mov.l	r3,@(20,r6)
1:	mov.l	@(20,r6),r1
	mov	r3,r0
	sub	r1,r0
	mov.w	rw_500,r1
	cmp/hs	r1,r0
	bf	rw_9
	mov	r7,r1			! a row preview playing (MED+64 "PV" | bit 14)
	add	#64,r1
	mov.l	@r1,r0
	mov	r0,r1
	shlr16	r1
	mov.w	rw_pv,r2
	cmp/eq	r2,r1
	bf	2f
	mov.w	rw_b14,r1
	tst	r1,r0
	bf	rw_9
2:	mov.l	@(4,r6),r1		! one build every RW_WARM ms
	mov	r3,r0
	sub	r1,r0
	mov.w	rw_wms,r1
	cmp/hs	r1,r0
	bf	rw_9
	mov.l	@r7,r11			! r11 = the index's medium
	tst	r11,r11
	bt	rw_9
	mov.l	@(8,r6),r0
	cmp/eq	r11,r0
	bt	3f
	mov.l	r11,@(8,r6)		! another medium: from the start
	mov	#1,r0
	mov.l	r0,@r6
	mov	#0,r0
	mov.l	r0,@(12,r6)
3:	mov.l	@(12,r6),r0
	mov.w	rw_rcn,r1
	cmp/hs	r1,r0
	bt	rw_9			! a cache's worth built
	mov	#TP_IDX,r0
	mov.l	@(r0,r9),r5		! r5 = the index (u16 page per id)
	mov.l	@r6,r10			! r10 = id
	mov.w	rw_256,r4		! ids looked at per pass
4:	mov.w	rw_top,r1
	extu.w	r1,r1
	cmp/hs	r1,r10
	bt	rw_end			! every id seen
	mov	r10,r0
	add	r0,r0
	mov.w	@(r0,r5),r0
	tst	r0,r0
	bt	5f			! no such track
	bsr	rc_slot			! cached already?
	nop
	mov.l	@r0,r2
	cmp/eq	r10,r2
	bf	6f
	mov.l	@(4,r0),r2
	cmp/eq	r1,r2
	bf	6f
5:	add	#1,r10
	dt	r4
	bf	4b
	bra	rw_8
	nop
6:	mov	r10,r0			! build it
	add	#1,r0
	mov.l	r0,@r6
	mov.l	r3,@(4,r6)
	mov.l	@(12,r6),r0
	add	#1,r0
	mov.l	r0,@(12,r6)
	mov	#TP_RWN,r0
	mov	#9,r1
	mov.l	r1,@(r0,r9)
	mov	#TP_RW,r0
	mov	#1,r1
	mov.l	r1,@(r0,r9)
	mov	#TP_RWOK,r0
	mov	#0,r1
	mov.l	r1,@(r0,r9)
	mov	#TP_RWC,r0
	mov.l	r1,@(r0,r9)
	mov.l	r10,@-r15		! (tp_resolve uses r10-r14)
	bsr	set_medium
	mov	r11,r4
	tst	r0,r0
	bt	7f
	mov.l	@r15,r4
	bsr	tp_resolve
	nop
7:	mov.l	@r15+,r10
	mov	#TP_RW,r0
	mov	#0,r1
	mov.l	r1,@(r0,r9)
	mova	rw_ab,r0		! its artwork, 20x20 (rw_art)
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1
	nop
	bsr	rw_draw
	mov	#9,r4
	mov	#9,r13
	bsr	rc_put
	nop
	bra	rw_9
	nop
rw_end:	mov.w	rw_rcn,r0		! done with this medium
	mov.l	r0,@(12,r6)
rw_8:	mov.l	r10,@r6
rw_9:	lds.l	@r15+,pr
	rts
	nop
rw_500:		.word 500
rw_pv:		.word 0x5056		! "PV"
rw_b14:		.word 0x4000
rw_wms:		.word RW_WARM
rw_rcn:		.word RC_N
rw_256:		.word 256
rw_top:		.word 0xFFFF
	.p2align 2
rw_ui:		.long 0x0B54336C	! V3rc8w: the MAIN UI state, +0 screen class
rw_medp:	.long MED
rw_el:		.long 0x0B568C9C + 0x78	! the heartbeat block's elapsed word (GUI DECK +0x78)
rw_ab:		.long rw_art - rw_ab

! ---------------------------------------------------------------------------
! The row cache (rowwave): the finished cell (0x1180 B) and right-hand text
! (0x60 B) of each drawn row, per (medium key, track id), in RC_N entries of
! RC_E bytes malloc'd once (4.7 MB, firmware heap) on the first row read;
! without it (malloc failed) rows are read every time, as before. Emptied
! whenever the index is (re)built: a medium change, a medium gone or
! re-mounted. Nothing in a cell depends on a setting (LIGHT MODE and BPM
! DECIMALS are the GUI's).
! ---------------------------------------------------------------------------

! rc_slot: r10 = track id -> r0 = its entry (0: no cache), r1 = the current
! medium's key. Clobbers r2.
rc_slot:
	mov	#TP_CACHE,r0
	mov.l	@(r0,r9),r2
	mov	#1,r0
	cmp/hi	r0,r2
	bf/s	9f
	mov	#0,r0
	mov.w	rc_mask,r0
	and	r10,r0
	mov.w	rc_e,r1
	mulu.w	r1,r0
	sts	macl,r0
	add	r2,r0
	mov.l	rc_med,r1
	mov.l	@r1,r1
9:	rts
	nop

! rc_rowp: r13 = row n -> r5 = its cell (0x081E0000 + (n-1)*0x1180), r7 =
! its text (0x081F0100 + n*0x60). Clobbers r0, r1.
rc_rowp:
	mov	r13,r0
	cmp/eq	#9,r0			! V3rc2: row 9 = the warm-up scratch (rv_warm)
	bf	1f
	sts.l	pr,@-r15
	bsr	rc_scr
	nop
	lds.l	@r15+,pr
	mov	r0,r5
	mov.w	rc_cell,r7
	rts
	add	r0,r7
1:	add	#-1,r0
	mov.w	rc_cell,r1
	mulu.w	r1,r0
	sts	macl,r5
	mov.l	rc_ramb,r1
	add	r1,r5
	mov	r13,r0
	mov	#0x60,r1
	mulu.w	r1,r0
	sts	macl,r7
	mov.l	rc_text,r1
	rts
	add	r1,r7

! rc_scr: r0 = the warm-up scratch row (cell 0x1180 + text 0x60), right after the cache's RC_N entries.
! Only called while the cache exists (rv_warm). Clobbers r1.
rc_scr:
	mov	#TP_CACHE,r0
	mov.l	@(r0,r9),r0
	mov.l	rc_size,r1
	rts
	add	r1,r0

! rc_cpy: r6 words from r4 to r5 (both advanced). Clobbers r0.
rc_cpy:
	mov.l	@r4+,r0
	mov.l	r0,@r5
	dt	r6
	bf/s	rc_cpy
	add	#4,r5
	rts
	nop

! rc_put: row n (r13) was just drawn for track r10 and latched: keep its cell
! and text. V3e3: a row latched without its colour preview (TP_RWC 0: the
! fetch failed RW_RETRY_MAX times -- a track without PWV4) is kept too, as
! drawn, so the next visit does not retry it 30 times again (~180 ms); only a
! lookup that was still waiting for the index (TP_PEND) is not kept. An
! artwork that did not decode is kept as drawn (as before).
rc_put:
	mov	#TP_RWC,r0
	mov.l	@(r0,r9),r0
	tst	r0,r0
	bf	1f
	mov.l	@(TP_PEND,r9),r0
	tst	r0,r0
	bf	9f
1:	sts.l	pr,@-r15
	bsr	rc_rowp
	nop
	bsr	rc_slot
	nop
	tst	r0,r0
	bt	8f
	mov.l	r10,@r0			! id, medium
	mov.l	r1,@(4,r0)
	mov	r5,r4
	mov	r0,r5
	add	#16,r5
	mov.w	rc_cellw,r6
	bsr	rc_cpy
	nop
	mov	r7,r4			! the text right after the cell
	bsr	rc_cpy
	mov	#24,r6
8:	lds.l	@r15+,pr
9:	rts
	nop

! rc_alloc: the cache, malloc'd once (TP_CACHE 1 when that failed: rows are
! then read every time). Only reached from a browse row (never in update
! mode, where no list shows). Keeps r8-r14.
rc_alloc:
	mov	#TP_CACHE,r0
	mov.l	@(r0,r9),r0
	tst	r0,r0
	bf	9f
	sts.l	pr,@-r15
	mov.l	rc_size,r4
	mov.w	rc_e,r1			! V3rc2: + the warm-up scratch row (rc_scr)
	add	r1,r4
	mov.l	rc_malloc,r1
	mov.l	@r8,r2
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
	tst	r0,r0
	bf	1f
	mov	#1,r0
1:	mov	r0,r1
	mov	#TP_CACHE,r0
	mov.l	r1,@(r0,r9)
	lds.l	@r15+,pr
! rc_flush: every entry empty. Clobbers r0-r3.
rc_flush:
	mov	#TP_CACHE,r0
	mov.l	@(r0,r9),r1
	mov	#1,r0
	cmp/hi	r0,r1
	bf	9f
	mov.w	rc_n,r2
	mov.w	rc_e,r3
	mov	#0,r0
1:	mov.l	r0,@r1
	dt	r2
	bf/s	1b
	add	r3,r1
9:	rts
	nop
! rw_isblue: T = 1 when modsmenu's WAVEFORM COLOR is BLUE. Clobbers r0, r1.
rw_isblue:
	mov.l	rw_hb,r1
	mov.b	@(3,r1),r0
	cmp/eq	#0x4C,r0
	bf	1f
	mov.b	@r1,r0
	and	#0x18,r0
	cmp/eq	#0x10,r0
1:	rts
	nop

! rw_mode: the WAVEFORM COLOR changed since the rows were drawn: the row cache is flushed and every row
! wanted again (done[] cleared), so the visible rows redraw in the new look. r9 = TP state, r12 = table.
rw_mode:
	sts.l	pr,@-r15
	mov.l	rw_hb,r1
	mov	#0x7F,r2
	mov.b	@(3,r1),r0
	cmp/eq	#0x4C,r0
	bf	1f
	mov.b	@r1,r0
	and	#0x18,r0
	extu.b	r0,r2
1:	add	#1,r2			! (never 0: 0 = not taken yet)
	mov.w	rw_mo,r0
	mov.l	@(r0,r12),r1
	cmp/eq	r2,r1
	bt	9f
	mov.l	r2,@(r0,r12)
	tst	r1,r1			! (first pass after boot: just taken)
	bt	9f
	bsr	rc_flush
	nop
	mov	#8,r2
	mov	r12,r1
	add	#0x38,r1
	mov	#0,r0
2:	mov.l	r0,@r1
	dt	r2
	bf/s	2b
	add	#4,r1
9:	lds.l	@r15+,pr
	rts
	nop

	.p2align 2
rw_mo:		.word	0x88			! table +0x88: the WAVEFORM COLOR the rows were drawn for + 1
	.p2align 2
rw_hb:		.long	0x0B568C9C + 0x54

	.p2align 2
rc_mask:	.word RC_N - 1
rc_n:		.word RC_N
rc_e:		.word RC_E
rc_cell:	.word 0x1180
rc_cellw:	.word 0x1180 / 4
	.p2align 2
rc_med:		.long MED
rc_ramb:	.long RAMB
rc_text:	.long RAMB+0x10100
rc_size:	.long RC_N * RC_E
rc_malloc:	.long 0x08344A9C

! idx_step: TP_XS 0 -> malloc + clear the index, read the pdb header (TP_XS
! 1); 1 -> index two more pages of the track table (TP_XS 2 at its end),
! then rest as long as that took. An
! id above 0xFFFF is left out (its lookup walks). r9 = TP state.
idx_step:
	sts.l	pr,@-r15
	mov.l	ix_med,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	ix_none
	mov.l	@(16,r1),r2		! the medium still there? (a USB pulled or
	mov.l	@(8,r2),r0		! swapped: its handle and index are stale)
	cmp/eq	#2,r0
	bt	0f
	mov	#0,r2
	mov.l	r2,@r1			! no medium
	mov	#TP_PDB,r0
	mov.l	r2,@(r0,r9)
	mov	#TP_XS,r0
	mov.l	r2,@(r0,r9)
	mov.l	@(4,r1),r2
	mov	r2,r0
	cmp/eq	#'C',r0			! an own medium's kept handle is dead with it
	bf	ix_notc
	mov	#0,r0
	mov.l	r0,@(8,r1)
ix_notc:
	cmp/eq	#'B',r0
	bf	ix_none
	mov	#0,r0
	mov.l	r0,@(12,r1)
ix_none:				! no medium chosen (yet / any more): the own USB
	mov.l	@r1,r0
	tst	r0,r0
	bf	0f
	mov	#3,r4
	mova	ix_smb,r0		! V4n24: far (bsr out of range)
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1
	nop
	tst	r0,r0
	bt	ix_ret			! no such medium: nothing to index yet
0:	ld	r11,D_BUF
	mov.w	ix_bpage,r0
	add	r0,r11			! r11 = page buffer
	mov	#TP_XS,r0
	mov.l	@(r0,r9),r0
	cmp/eq	#3,r0			! failed: try again once its tick has come
	bf	1f
	mov.l	@(D_TICK,r8),r1
	mov.l	@r1,r1
	mov.l	@(TP_XRETRY,r9),r2
	sub	r2,r1
	cmp/pz	r1
	bf	ix_ret
	mov	#0,r0			! (start over; the index memory is kept)
1:	tst	r0,r0
	bf	ix_build
	mov	#TP_IDX,r0		! the index: malloc'd once, cleared each build
	mov.l	@(r0,r9),r1
	tst	r1,r1
	bf	2f
	mov.l	ix_size,r4		! 64K ids x u16
	mov.l	ix_malloc,r1
	mov.l	@r8,r2
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
	tst	r0,r0
	bt	ix_fail
	mov	r0,r1
	mov	#TP_IDX,r0
	mov.l	r1,@(r0,r9)
2:	mov.l	ix_size,r3
	shlr2	r3
	mov	#0,r2
1:	mov.l	r2,@r1
	dt	r3
	bf/s	1b
	add	#4,r1
	bsr	rc_flush		! a new index: no row cached from before
	nop
	mov	#TP_PDB,r0		! export.pdb, kept open (see TP_PDB)
	mov.l	@(r0,r9),r0
	tst	r0,r0
	bf	2f
	ld	r4,D_BUF
	mov.w	ix_bpdbp,r0
	add	r0,r4			! the current medium's export.pdb path
	fw	D_FOPEN
	tst	r0,r0
	bt	ix_fail
	mov	r0,r1
	mov	#TP_PDB,r0
	mov.l	r1,@(r0,r9)
	mova	ix_mkb,r0		! med_keep: an own medium's handle is kept for
	mov.l	@r0,r2			! good (out of bsr range from here)
	add	r0,r2
	jsr	@r2
	nop
	mov	r1,r0
2:	mov.l	r0,@(TP_FH,r9)
	mov	r0,r4			! the header (page 0)
	mov	#0,r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4
	mov	#1,r5
	mov.w	ix_4096,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov.w	ix_4096,r1		! a short read: failed, retried in 10 s
	cmp/eq	r1,r0			! (fread clobbers r4-r7: r6 is gone)
	bf	ix_fail
	mov.l	@(4,r11),r12		! page size
	mov.w	ix_4096,r0
	cmp/hi	r0,r12
	bt	ix_fail
	mov.l	r12,@(TP_PS,r9)
	mov.l	@(8,r11),r13		! number of tables
	mov	#64,r0
	cmp/hi	r0,r13
	bt	ix_fail
	mov	r11,r1
	add	#0x1c,r1
3:	tst	r13,r13
	bt	ix_fail			! no track table
	mov.l	@r1,r0
	tst	r0,r0			! type 0 = tracks
	bt	4f
	add	#16,r1
	bra	3b
	dt	r13
4:	mov.l	@(8,r1),r2
	mov	#TP_XP,r0
	mov.l	r2,@(r0,r9)
	mov.l	@(12,r1),r2
	mov	#TP_XL,r0
	mov.l	r2,@(r0,r9)
	mov.w	ix_guard,r2
	mov	#TP_XN,r0
	mov.l	r2,@(r0,r9)
	mov	#1,r2
	bra	ix_set
	nop
ix_fail:
	mov.l	@(D_TICK,r8),r1		! again in 10 s
	mov.l	@r1,r1
	mov.w	ix_10s,r0
	add	r0,r1
	mov.l	r1,@(TP_XRETRY,r9)
	mov	#3,r2
ix_set:	mov	#TP_XS,r0
	mov.l	r2,@(r0,r9)
ix_ret:	lds.l	@r15+,pr
	rts
	nop
ix_bpage:	.word B_PAGE
ix_bpdbp:	.word B_PDBP
ix_4096:	.word 4096
ix_guard:	.word 8192
ix_10s:		.word 10000
	.p2align 2
ix_smb:		.long set_medium - ix_smb
ix_mkb:		.long med_keep - ix_mkb
ix_size:	.long 0x20000
ix_med:		.long MED
ix_malloc:	.long 0x08344A9C
	.p2align 2
ix_build:
	mov.l	@(D_TICK,r8),r1		! yield: a batch no sooner than it took the
	mov.l	@r1,r1			! last one to read after it (TP_XRETRY: the
	mov.l	@(TP_XRETRY,r9),r2	! next batch's tick while building), so the
	mov	r1,r0			! build takes half of MAIN at most
	sub	r2,r0
	cmp/pz	r0
	bf	ix_ret
	mov.l	r1,@(TP_XRETRY,r9)	! (this batch's start)
	mov	#2,r10			! r10 = pages this pass
ix_pg:	mov	#TP_PDB,r0
	mov.l	@(r0,r9),r4
	mov	#TP_XP,r0
	mov.l	@(r0,r9),r0
	mov.l	@(TP_PS,r9),r1
	mul.l	r1,r0
	sts	macl,r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4
	mov	#1,r5
	mov.l	@(TP_PS,r9),r6
	mov	#TP_PDB,r0
	mov.l	@(r0,r9),r7
	fw	D_FREAD
	mov.l	@(TP_PS,r9),r1		! a short read: failed, retried in 10 s
	cmp/eq	r1,r0			! (fread clobbers r4-r7: r6 is gone)
	bf	ix_fail
	mov	r11,r1
	add	#0x1b,r1
	mov.b	@r1,r0			! page flags
	tst	#0x40,r0
	bf	ix_next			! not a data page
	mov	r11,r1
	add	#0x18,r1
	mov.b	@r1,r12
	extu.b	r12,r12			! rows (small count)
	mov	r11,r1
	add	#0x22,r1
	mov.w	@r1,r13
	extu.w	r13,r13			! rows (large count)
	cmp/hi	r12,r13
	bf	1f
	mov.w	ix_1fff,r0
	cmp/eq	r0,r13
	bt	1f
	mov	r13,r12
1:	mov	#0,r13			! r13 = row index
ix_row:	cmp/hs	r12,r13
	bt	ix_next
	mov	r13,r0			! group base = PS - (i / 16) * 0x24
	shlr2	r0
	shlr2	r0
	mov	#0x24,r1
	mul.l	r1,r0
	sts	macl,r0
	mov.l	@(TP_PS,r9),r1
	sub	r0,r1
	add	r11,r1
	mov	r13,r2
	mov	#15,r0
	and	r0,r2			! k = i % 16
	mov	r1,r3
	add	#-4,r3
	mov.w	@r3,r3
	extu.w	r3,r3			! presence bits
	mov	r2,r0
	neg	r0,r0
	shld	r0,r3
	mov	r3,r0
	tst	#1,r0
	bt	ix_rnext
	mov	r2,r0			! offset = u16 at group base - 6 - 2k
	add	r0,r0
	mov	r1,r3
	sub	r0,r3
	add	#-6,r3
	mov.w	@r3,r14
	extu.w	r14,r14
	mov	#0x28,r0
	add	r0,r14
	mov	r14,r0			! the id must fit the page
	add	#0x4c,r0
	mov.l	@(TP_PS,r9),r1
	cmp/hi	r1,r0
	bt	ix_rnext
	mov	r11,r1
	add	r14,r1
	add	#0x48,r1		! id
	bsr	tr_rd32
	nop
	mov.l	ix_ffff,r1
	cmp/hi	r1,r0
	bt	ix_rnext
	add	r0,r0
	mov	r0,r2
	mov	#TP_IDX,r0
	mov.l	@(r0,r9),r1
	add	r2,r1
	mov	#TP_XP,r0
	mov.l	@(r0,r9),r0
	mov.w	r0,@r1			! idx[id] = page
ix_rnext:
	bra	ix_row
	add	#1,r13
ix_next:
	mov	#TP_XP,r0
	mov.l	@(r0,r9),r2
	mov	#TP_XL,r0
	mov.l	@(r0,r9),r1
	cmp/eq	r2,r1
	bt	ix_done			! the last page
	mov	#TP_XN,r0
	mov.l	@(r0,r9),r2
	dt	r2
	bt	ix_done
	mov.l	r2,@(r0,r9)
	mov	r11,r1
	add	#0x0c,r1		! next page
	bsr	tr_rd32
	nop
	mov	r0,r2
	mov	#TP_XP,r0
	mov.l	r2,@(r0,r9)
	dt	r10
	bf	ix_pg
	mov.l	@(D_TICK,r8),r1		! next batch: now + (now - start)
	mov.l	@r1,r1
	mov.l	@(TP_XRETRY,r9),r2
	mov	r1,r0
	add	r0,r0
	sub	r2,r0
	bra	ix_ret
	mov.l	r0,@(TP_XRETRY,r9)
ix_done:
	mov	#2,r2
	bra	ix_set
	nop
ix_1fff:	.word 0x1fff
	.p2align 2
ix_ffff:	.long 0xFFFF

! rw_draw: r4 = row n (1-8). Draws the row's waveform into its 112x20
! RGB565 buffer (stride 224; the GUI's rowcell poke gives the cell that
! shape), centred: with a PWV4 (TP_RWC) in colour, each pixel column the
! loudest of its ~10.7 colour-preview columns, coloured by its three band
! levels; else from the PWAV (400 columns, height + whiteness) in blue; a
! flat grey line when the lookup failed. Keeps r8-r14.
	.equ	RD_W, 112
	.equ	RD_H, 20
rw_draw:
	sts.l	pr,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15
	mov.l	r14,@-r15
	mov	r4,r0			! r11 = buffer
	cmp/eq	#9,r0			! V3rc2: row 9 = the warm-up scratch
	bf	7f
	bsr	rc_scr
	nop
	bra	8f
	mov	r0,r11
7:	add	#-1,r0
	mov.w	rd_1180m,r1
	mulu.w	r1,r0
	sts	macl,r11
	mov.l	rd_buf,r1
	add	r1,r11
8:
	add	#-16,r15		! @0 first wave column, @4 / @8 the colour /
	mov	#0,r0			!   PWAV column steps (10-bit fixed point), @12 the end column
	mov.l	r0,@r15
	mov	#RD_W,r0
	mov.l	r0,@(12,r15)
	mov.w	rd_k12m,r0
	mov.l	r0,@(4,r15)
	mov.w	rd_k4m,r0
	mov.l	r0,@(8,r15)
	mov	#RD_W-26,r0		! V4n19 (user): FIXED layout, art or not -- the wave always 86 columns,
	mov.l	r0,@(12,r15)		!   a 6-px gap, the 20x20 artwork slot at the right (the 3000's thumbnail
	mov.w	rd_k12am,r0		!   after the preview wave); no artwork = the slot left empty
	mov.l	r0,@(4,r15)
	mov.w	rd_k4am,r0
	mov.l	r0,@(8,r15)
	mov	r11,r2			! clear columns 86..111 (gap + slot) of all 20 rows
	add	#127,r2
	add	#45,r2			! +172
	mov	#20,r3
1:	mov	#26,r5
	mov	r2,r6
	mov	#0,r0
3:	mov.w	r0,@r6
	dt	r5
	bf/s	3b
	add	#2,r6
	mov.w	rd_224m,r0
	dt	r3
	bf/s	1b
	add	r0,r2
	mov.l	rd_artok,r0		! an artwork: copy it into the slot
	mov.l	@r0,r0
	tst	r0,r0
	bt	2f
	mov	#TP_JBUF,r0		! copy it: 20 rows of 20 pixels
	mov.l	@(r0,r9),r1
	mov.l	rd_jout,r0
	add	r0,r1			! r1 = the 20x20 out
	mov	r11,r2
	add	#127,r2			! (+184: past the wave's 86 columns + the gap, two steps for the imm range)
	add	#57,r2
	mov	#20,r3
1:	mov	#20,r5
	mov	r2,r6
3:	mov.w	@r1+,r0
	mov.w	r0,@r6
	dt	r5
	bf/s	3b
	add	#2,r6
	mov.w	rd_224m,r0
	dt	r3
	bf/s	1b
	add	r0,r2
2:	mov.l	@r15,r13		! r13 = x
rd_col:	mov	#TP_RWC,r0
	mov.l	@(r0,r9),r0
	tst	r0,r0
	bt	rd_blue
	cmp/eq	#2,r0			! G1: 3BAND (PWV6 from the .2EX)
	bf	rd_c1
	mova	rd_3bp,r0
	mov.l	@r0,r1
	add	r0,r1
	jmp	@r1
	nop
	.p2align 1
rd_1180m:	.word 0x1180
rd_224m:	.word RD_W * 2
rd_brw4m:	.word B_RW4
rd_k12m:	.word 10971
rd_k4m:	.word 3657
rd_k12am:	.word 14288
rd_k4am:	.word 4763
	.p2align 2
rd_3bp:	.long rd_3b - rd_3bp
rd_c1:
	ld	r12,D_BUF		! colour: columns [x*1200/112, (x+1)*1200/112)
	mov.w	rd_brw4,r0
	add	r0,r12
	mov.l	@(4,r15),r1		! 1200 / width in 10-bit fixed point
	mov.l	@r15,r0
	mov	r13,r2
	sub	r0,r2
	mulu.w	r1,r2
	sts	macl,r2
	shlr8	r2
	shlr2	r2			! r2 = first column
	mov	r13,r3
	sub	r0,r3
	add	#1,r3
	mulu.w	r1,r3
	sts	macl,r3
	shlr8	r3
	shlr2	r3			! r3 = end column
	mov	#0,r10			! r10 = peak level
	mov	#0,r14			! r14 = its column's entry
1:	cmp/hs	r3,r2
	bt	2f
	mov	r2,r0			! entry = B_RW4 + 6k
	add	r0,r0
	add	r2,r0
	add	r0,r0
	add	r12,r0
	mov	r0,r5
	mov.b	@(3,r5),r0
	extu.b	r0,r6
	mov.b	@(4,r5),r0
	extu.b	r0,r0
	cmp/hi	r6,r0
	bf	3f
	mov	r0,r6
3:	mov.b	@(5,r5),r0
	extu.b	r0,r0
	cmp/hi	r6,r0
	bf	3f
	mov	r0,r6
3:	cmp/hi	r10,r6			! a louder column
	bf	4f
	mov	r6,r10
	mov	r5,r14
4:	bra	1b
	add	#1,r2
2:	tst	r10,r10
	bt	rd_zero
	mov	r10,r0			! half height = level * 10 / 127 (<= 10)
	mov	#81,r1
	mulu.w	r1,r0
	sts	macl,r0
	shlr8	r0
	shlr2	r0
	mov	#10,r1
	cmp/hi	r1,r0
	bf	5f
	mov	r1,r0
5:	mov.l	r0,@-r15		! (half)
	mov.b	@(3,r14),r0		! colour: each band / peak, to 5-6-5
	extu.b	r0,r4
	mov	#31,r1
	mulu.w	r1,r4
	sts	macl,r4
	mova	rd_udiv,r0
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1
	mov	r10,r5
	mov	r0,r7
	shll8	r7
	shll2	r7
	shll	r7			! r << 11
	mov.b	@(4,r14),r0
	extu.b	r0,r4
	mov	#63,r1
	mulu.w	r1,r4
	sts	macl,r4
	mova	rd_udiv,r0
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1
	mov	r10,r5
	shll2	r0
	shll2	r0
	shll	r0			! g << 5
	or	r0,r7
	mov.b	@(5,r14),r0
	extu.b	r0,r4
	mov	#31,r1
	mulu.w	r1,r4
	sts	macl,r4
	mova	rd_udiv,r0
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1
	mov	r10,r5
	or	r0,r7
	mov	r7,r3			! r3 = colour
	mov.l	@r15+,r2		! r2 = half
	bra	rd_paint
	nop
	.p2align 1
	.p2align 2
rd_udiv:	.long udiv - rd_udiv	! (out of bsr range: pc-relative)
rd_zero:
	mov	#0,r2
	mov	#0,r3
	bra	rd_paint
	nop
rd_blue:
	mov	#TP_RWOK,r0
	mov.l	@(r0,r9),r0
	tst	r0,r0
	bf	1f
	mov	#1,r2			! no PWAV: a flat grey line
	mova	rd_pal,r0
	add	#16,r0
	bra	rd_paint
	mov.w	@r0,r3
1:	ld	r12,D_BUF		! PWAV columns [x*400/112, (x+1)*400/112)
	mov.w	rd_brwave,r0
	add	r0,r12
	mov.l	@(8,r15),r1		! 400 / width in 10-bit fixed point
	mov.l	@r15,r0
	mov	r13,r2
	sub	r0,r2
	mulu.w	r1,r2
	sts	macl,r2
	shlr8	r2
	shlr2	r2
	mov	r13,r3
	sub	r0,r3
	add	#1,r3
	mulu.w	r1,r3
	sts	macl,r3
	shlr8	r3
	shlr2	r3
	mov	#0,r5			! peak height
	mov	#0,r6			! its whiteness
2:	cmp/hs	r3,r2
	bt	3f
	mov	r12,r0
	add	r2,r0
	mov.b	@r0,r0
	extu.b	r0,r0
	mov	r0,r1
	and	#31,r0
	cmp/hi	r5,r0
	bf	4f
	mov	r0,r5
	mov	r1,r6
	shlr2	r6
	shlr2	r6
	shlr	r6
4:	bra	2b
	add	#1,r2
3:	mov	r5,r0			! V4n21: height = h * 20 / 31 (h * 660 >> 10), bottom-anchored
	mov.w	rd_330,r1
	mulu.w	r1,r0
	sts	macl,r2
	shlr8	r2
	shlr2	r2
	bra	rd_paintl
	nop
rd_paint:				! column x: rows [10 - half, 10 + half) in r3
	mov	r11,r1
	mov	r13,r0
	add	r0,r0
	add	r0,r1			! r1 = &pix[0][x]
	mov	#0,r7			! y
6:	mov	#RD_H/2,r0
	sub	r2,r0
	cmp/ge	r0,r7
	bf	7f
	mov	#RD_H/2,r0
	add	r2,r0
	cmp/ge	r0,r7
	bt	7f
	bra	8f
	mov.w	r3,@r1
7:	mov	#0,r0
	mov.w	r0,@r1
8:	mov.w	rd_224,r0
	add	r0,r1
	add	#1,r7
	mov	#RD_H,r0
	cmp/hs	r0,r7
	bf	6b
rd_next:	add	#1,r13
	mov.l	@(12,r15),r0
	cmp/hs	r0,r13
	bt	9f
	bra	rd_col
	nop
9:	add	#16,r15
	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	lds.l	@r15+,pr
	rts
	nop
rd_1180:	.word 0x1180
rd_224:		.word RD_W * 2
rd_brwave:	.word B_RWAVE
rd_brw4:	.word B_RW4
rd_k12:		.word 10971		! 1200 / 112 * 1024
rd_k4:		.word 3657		! 400 / 112 * 1024
rd_k12a:	.word 14288		! 1200 / 86 * 1024
rd_k4a:		.word 4763		! 400 / 86 * 1024
rd_330:		.word 660		! 20 / 31 * 1024
	.p2align 2
rd_pal:		.short 0x1A5F, 0x229F, 0x2AFF, 0x3B5F	! whiteness 0-7: light blue
		.short 0x5BBF, 0x7C1F, 0xA51F, 0xDEFF	!   to near white
		.short 0x4208				! no PWAV: grey
	.p2align 2
rd_buf:		.long RAMB+0x0	! the rows' 112x20 buffers (0x1180 each)
rd_artok:	.long RAMB+0x10094	! rw_art: the row's artwork decoded
rd_jout:	.long 0x1C000		! the 20x20 out in TP_JBUF


! kill_check: every 2 s, whether the medium carries C:/NOMODS (any file of
! that name at its root). Then 0x081FF7F0 = "NOMO": this task stops its
! preview and does nothing else, and the rowwave / touchaudiotouch hooks go
! stock -- a misbehaving mod can be switched off without reflashing. r0 = 1
! while off. r8 = data; keeps r8-r14.
kill_check:
	sts.l	pr,@-r15
	mov.l	ks_word,r1
	mov.l	@(4,r1),r2		! the next check's tick
	mov.l	@(D_TICK,r8),r3
	mov.l	@r3,r3
	mov	r3,r0
	sub	r2,r0
	cmp/pz	r0
	bf	5f
	mov.w	ks_2000,r0
	add	r0,r3
	mov.l	r3,@(4,r1)
	mov.l	ks_pub,r1		! LIGHT MODE / BPM DECIMALS into the heartbeat
	jsr	@r1			! again (modsmenu mm_publish; uses r0-r2)
	nop
	mova	ks_path,r0
	mov	r0,r4
	fw	D_FOPEN
	tst	r0,r0
	bt	2f
	mov	r0,r4			! C:/NOMODS there: all off
	fw	D_FCLOSE
	mov	#1,r0
	bra	3f
	nop
2:	mov.l	ks_moff,r1		! no file: UTILITY > MODS (index 0 = OFF)
	mov.l	@r1,r0
	tst	r0,r0
	movt	r0
3:	mov.l	r0,@-r15		! r0 = all off
	mov.l	ks_w32,r1		! WAV 32-BIT off = all off or its own item OFF
	mov.l	@r1,r1
	tst	r1,r1
	movt	r1
	or	r1,r0
	mov.l	ks_w32k,r1
	tst	r0,r0
	bt/s	4f
	mov	#0,r2
	mov.l	ks_magic,r2
4:	mov.l	r2,@r1			! wav32's kill word
	mov.l	@r15+,r0
	mov.l	ks_lc,r1		! LINK CUE off = all off or its own item OFF
	mov.l	@r1,r1
	tst	r1,r1
	movt	r1
	or	r1,r0
	tst	r0,r0
	bt	6f
	mov.l	ks_word,r1		! off
	mov.l	@r1,r0
	mov.l	ks_magic,r2
	cmp/eq	r2,r0
	bt	5f
	mov.l	r2,@r1			! (newly off: stop the preview)
	mov	#0,r2
	st	r2,D_PREVIEW
	mova	ks_ccb,r0
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1			! close_cur
	nop
	ld	r1,D_BUF		! and forget the track: the next press opens
	mov.w	ks_btp,r0		! it again (TP_OPEN), the loaded track is
	add	r0,r1			! resolved again (TP_HASH)
	mov	#0,r2
	mov.l	r2,@r1			! TP_ID
	mov.l	r2,@(TP_OPEN,r1)
	mov.l	r2,@(TP_HASH,r1)
	mov	#TP_ROWON,r0
	mov.l	r2,@(r0,r1)
	mov.l	ks_cnt,r1		! KILL_EDGE++
	mov.l	@(0x2c,r1),r2
	add	#1,r2
	mov.l	r2,@(0x2c,r1)
	bra	5f
	nop
6:	mov.l	ks_word,r1		! on
	mov	#0,r0
	mov.l	r0,@r1
5:	mov.l	ks_word,r1
	mov.l	@r1,r0
	mov.l	ks_magic,r2
	cmp/eq	r2,r0
	movt	r0
	lds.l	@r15+,pr
	rts
	nop
ks_2000:	.word 2000
ks_btp:		.word B_TP
	.p2align 2
ks_cnt:		.long RAMB+0x1FE80	! counters: +0x2c KILL_EDGE
ks_word:	.long RAMB+0x1F7F0	! "NOMO" when off; +4 the next check's tick
ks_magic:	.long 0x4F4D4F4E	! "NOMO"
ks_moff:	.long MODSV		! UTILITY > MODS: 0 = OFF (mods/modsmenu)
ks_lc:		.long LCV		! UTILITY > LINK CUE: 0 OFF, 1 PREVIEW, 2 CUE, 3 BOTH
ks_w32:		.long W32V		! UTILITY > WAV 32-BIT: 0 = OFF
ks_w32k:	.long RAMB+0x1F7E8	! wav32's kill word ("NOMO" = off)
ks_pub:		.long MMPUB		! modsmenu mm_publish
ks_ccb:		.long close_cur - ks_ccb
ks_path:	.short 'C', ':', '/', 'N', 'O', 'M', 'O', 'D', 'S', 0
	.p2align 2

! ---------------------------------------------------------------------------
! rowwave: each TRACK row's right-hand text, "FLAC 120.0 Em 6:12" (file
! type, BPM, key, duration), as UTF-16 in the table at 0x081F0100 + n*0x60
! (47 characters at most). The UI hook (mods/rowwave) and rw_mput put it
! after the row's title in the slot text (+0x1A0), where the GUI's rowmeta
! routine (mods/rowwave/gui_rowmeta.s) shows it at the row's right end.
! ---------------------------------------------------------------------------

! rw_meta: r14 = the row's export.pdb track row (in the page buffer), the
! row number in TP_RWN. Keeps r8-r14.
rw_meta:
	sts.l	pr,@-r15
	mov	r14,r1			! the artwork id (+0x1C), for rw_art
	add	#0x1c,r1
	bsr	tr_rd32
	nop
	mov.l	rm_artid,r1
	mov.l	r0,@r1
	mov	#TP_RWN,r0
	mov.l	@(r0,r9),r0
	cmp/eq	#9,r0			! V3rc2: row 9 = the warm-up scratch (its text after the cell)
	bf	7f
	bsr	rc_scr
	nop
	mov	#0x11,r6		! + 0x1180
	shll8	r6
	add	#0x40,r6
	add	#0x40,r6
	bra	8f
	add	r0,r6
7:	mov	#0x60,r1
	mulu.w	r1,r0
	sts	macl,r6
	mov.l	rm_tab,r1
	add	r1,r6			! r6 = where the text goes
8:
	mov	r14,r1			! file type, +0x5A: 1 MP3, 4 M4A, 5 FLAC,
	add	#0x5a,r1		!   11 WAV, 12 AIFF
	mov.b	@r1,r0
	extu.b	r0,r0
	cmp/eq	#1,r0
	bf	1f
	mova	rm_mp3,r0
	bra	2f
	nop
1:	cmp/eq	#4,r0
	bf	1f
	mova	rm_m4a,r0
	bra	2f
	nop
1:	cmp/eq	#5,r0
	bf	1f
	mova	rm_flac,r0
	bra	2f
	nop
1:	cmp/eq	#11,r0
	bf	1f
	mova	rm_wav,r0
	bra	2f
	nop
1:	cmp/eq	#12,r0
	bf	3f
	mova	rm_aiff,r0
2:	mov	r0,r1
	bsr	rm_puts
	nop
3:	bsr	rm_gap
	nop
	mov	r14,r1			! BPM: tempo x 100 at +0x38 -> "120.0"
	add	#0x38,r1
	bsr	tr_rd32
	nop
	mov.l	r0,@-r15
	mov	r0,r4
	mov	#100,r5
	bsr	rm_udiv
	nop
	mov	r0,r4
	bsr	rm_dec
	mov	#1,r7
	mov	#'.',r0
	mov.w	r0,@r6
	add	#2,r6
	mov.l	@r15+,r4		! tenths: (tempo / 10) mod 10
	mov	#10,r5
	bsr	rm_udiv
	nop
	mov	r0,r4
	mov	#10,r5
	bsr	rm_udiv
	nop
	mov	r1,r0			! (the remainder)
	add	#'0',r0
	mov.w	r0,@r6
	add	#2,r6
	bsr	rm_gap
	nop
	mov	r14,r1			! key: id at +0x20 -> its name
	add	#0x20,r1
	bsr	kb_rd32			! (tr_rd32's copy: in bsr range)
	nop
	mov	#127,r1
	cmp/hi	r1,r0
	bt	4f
	shll2	r0
	add	r0,r0
	mov.l	rm_keys,r1
	add	r0,r1
	mov.b	@r1,r0
	tst	r0,r0
	bt	4f
	bsr	rm_puts
	nop
	bsr	rm_gap
	nop
4:	mov	r14,r1			! duration: seconds at +0x54 -> "6:12"
	add	#0x54,r1
	mov.b	@(1,r1),r0
	extu.b	r0,r4
	shll8	r4
	mov.b	@r1,r0
	extu.b	r0,r0
	or	r0,r4
	mov	#60,r5
	bsr	rm_udiv
	nop
	mov.l	r1,@-r15		! (seconds)
	mov	r0,r4
	bsr	rm_dec
	mov	#1,r7
	mov	#':',r0
	mov.w	r0,@r6
	add	#2,r6
	mov.l	@r15+,r4
	bsr	rm_dec
	mov	#2,r7
	mov	#0,r0
	mov.w	r0,@r6
	lds.l	@r15+,pr
	rts
	nop

! rm_puts: ASCII at r1 -> UTF-16 at r6 (advanced). Clobbers r0, r1.
rm_puts:
	mov.b	@r1+,r0
	extu.b	r0,r0
	tst	r0,r0
	bt	1f
	mov.w	r0,@r6
	bra	rm_puts
	add	#2,r6
1:	rts
	nop

! rm_gap: a space at r6.
rm_gap:
	mov	#' ',r0
	mov.w	r0,@r6
	rts
	add	#2,r6

! rm_dec: r4 in decimal, at least r7 digits, at r6 (advanced). Clobbers
! r0-r5.
rm_dec:
	sts.l	pr,@-r15
	mov	#0,r3
1:	mov	#10,r5
	bsr	rm_udiv
	nop
	add	#'0',r1			! the remainder: next digit, pushed
	mov.l	r1,@-r15
	add	#1,r3
	mov	r0,r4
	tst	r4,r4
	bf	1b
2:	cmp/ge	r7,r3			! leading zeros up to r7 digits
	bt	3f
	mov	#'0',r1
	mov.l	r1,@-r15
	bra	2b
	add	#1,r3
3:	mov.l	@r15+,r1
	mov.w	r1,@r6
	add	#2,r6
	dt	r3
	bf	3b
	lds.l	@r15+,pr
	rts
	nop

! diag_text: every 500 ms, the UTILITY > LINK CUE DIAG row (mods/modsmenu).
! Its value column (layout.inc DIAGT, about 18 characters visible, so no
! spaces) is the state: "E1T17R143X2S9" = the mixer's E and T, packets sent
! per second, the index state (0-3), the state bits S (1 finger down, 2 track
! resolved, 4 strip ours, 8 INFO on a track). Its label (DIAGL, the wider
! column) is the counters: "M0 I0 Y0 N0 O0 K0 W0" = election timeouts,
! timings dropped for a foreign ip, pacer resyncs, failed sends, open
! failures, kill edges, strip redraws (counters at RAMB+0x1FE80; the index
! waits stay at +0x30). r8 = data; keeps r8-r14.
diag_text:
	sts.l	pr,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	@(D_TICK,r8),r1
	mov.l	@r1,r9			! now
	mov.l	dg_cnt,r10		! the counters
	mov.l	@(0x3c,r10),r1		! +0x3c: the next line's tick
	mov	r9,r2
	sub	r1,r2
	cmp/pz	r2
	bf	dg_out
	mov	r9,r1
	mov.w	dg_500,r0
	add	r0,r1
	mov.l	r1,@(0x3c,r10)
	mov.l	@r10,r1			! rate = (SENT - last SENT) * 2 (per second)
	mov.l	@(0x34,r10),r2
	mov.l	r1,@(0x34,r10)
	sub	r2,r1
	add	r1,r1
	mov.l	r1,@(0x38,r10)
	mov.l	dg_txt,r6		! the line
	mov	#'E',r0
	mov.w	r0,@r6
	add	#2,r6
	ld	r4,D_E
	bsr	dg_num
	nop
	mov	#'T',r0
	mov.w	r0,@r6
	add	#2,r6
	ld	r4,D_T
	bsr	dg_num
	nop
	mov	#'R',r0
	mov.w	r0,@r6
	add	#2,r6
	mov.l	@(0x38,r10),r4
	bsr	dg_num
	nop
	mov	#'X',r0
	mov.w	r0,@r6
	add	#2,r6
	ld	r1,D_BUF
	mov.l	dg_btp,r0
	add	r0,r1
	mov	#TP_XS,r0
	mov.l	@(r0,r1),r4
	bsr	dg_num
	nop
	mov	#'S',r0			! S: 1 finger down, 2 track resolved, 4 the
	mov.w	r0,@r6			! strip is ours, 8 INFO on a track
	add	#2,r6
	mov	#0,r4
	ld	r0,D_PREVIEW
	tst	r0,r0
	bt	1f
	add	#1,r4
1:	ld	r1,D_BUF
	mov.l	dg_btp,r0
	add	r0,r1
	mov.l	@(TP_OK,r1),r0
	tst	r0,r0
	bt	2f
	add	#2,r4
2:	mov.l	@(TP_ACT,r1),r0
	tst	r0,r0
	bt	3f
	add	#4,r4
3:	mov.l	dg_info,r0
	mov.l	@r0,r0
	cmp/eq	#2,r0
	bf	4f
	add	#8,r4
4:	bsr	dg_num
	nop
	mov.l	dg_med,r0		! the medium's letter (C own USB, D.. LINKed)
	mov.l	@(4,r0),r0
	mov.w	r0,@r6
	add	#2,r6
	mov	#0,r0
	mov.w	r0,@r6
	mov.l	dg_lbl,r6		! the label column: the counters
	mov	#'M',r0
	mov.w	r0,@r6
	add	#2,r6
	mov.l	@(0x20,r10),r4
	bsr	dg_num
	nop
	mov	#'Y',r1
	mov.l	@(0x10,r10),r4
	bsr	dg_fld
	nop
	mov	#'W',r1
	mov	r10,r4
	add	#0x40,r4
	mov.l	@r4,r4
	bsr	dg_fld
	nop
	mov	#'A',r1			! strips packed ahead of the model (touchaudiopack)
	mov	r10,r4
	add	#0x44,r4
	mov.l	@r4,r4
	bsr	dg_fld
	nop
	mov	#0,r0
	mov.w	r0,@r6
dg_out:
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	lds.l	@r15+,pr
	rts
	nop
! dg_num: r4 in decimal (1+ digits) at r6. Clobbers r0-r5, r7.
dg_num:
	sts.l	pr,@-r15
	mov.w	dg_999,r0		! capped: the label holds 24 characters
	cmp/hi	r0,r4
	bf	1f
	mov	r0,r4
1:	mov	#1,r7
	bsr	rm_dec
	nop
	lds.l	@r15+,pr
	rts
	nop
! dg_fld: a space, the letter in r1, r4 in decimal, at r6. Clobbers r0-r5, r7.
dg_fld:
	sts.l	pr,@-r15
	mov	#' ',r0
	mov.w	r0,@r6
	add	#2,r6
	mov.w	r1,@r6
	add	#2,r6
	bsr	dg_num
	nop
	lds.l	@r15+,pr
	rts
	nop
dg_500:		.word 500
dg_999:		.word 999
	.p2align 2
dg_cnt:		.long RAMB+0x1FE80
dg_txt:		.long DIAGT
dg_lbl:		.long DIAGL
dg_med:		.long MED
dg_btp:		.long B_TP
dg_info:	.long 0x0A35F3CC	! display mode: 2 = INFO pop-up on a listed track

! rm_udiv: r0 = r4 / r5, r1 = remainder (a local copy of udiv, which is out
! of bsr range). Clobbers r2, r4.
rm_udiv:
	mov	#0,r0
	tst	r5,r5
	bt	3f
	mov	#0,r1
	mov	#32,r2
1:	shll	r4
	rotcl	r1
	shll	r0
	cmp/hs	r5,r1
	bf	2f
	sub	r5,r1
	add	#1,r0
2:	dt	r2
	bf	1b
3:	rts
	nop

	.p2align 2
rm_tab:		.long RAMB+0x10100	! the rows' texts, 0x60 bytes each (n = 1-8)
rm_keys:	.long RAMB+0x10400	! key names, 8 bytes per key id (< 128)
rm_artid:	.long RAMB+0x10090	! the row's artwork id (0: none)
rm_mp3:		.ascii	"MP3\0"
rm_m4a:		.ascii	"M4A\0"
rm_wav:		.ascii	"WAV\0"
	.p2align 2
rm_flac:	.ascii	"FLAC\0"
	.p2align 2
rm_aiff:	.ascii	"AIFF\0"
	.p2align 2

! rw_mput: r4 = row n. Its text (if drawn for the track it shows) into the
! UI slot and the model's copy, after the title (+0x2A + 0x1A0), when the
! title is short enough (< 0xCF characters). Clobbers r0-r7.
rw_mput:
	mov.l	mp_tab,r7
	mov	r4,r0
	shll2	r0
	add	r7,r0
	mov.l	@(0x10,r0),r1		! want[n] == done[n]
	mov.l	@(0x34,r0),r2
	cmp/eq	r1,r2
	bf	9f
	mov	r4,r0			! the text
	mov	#0x60,r1
	mulu.w	r1,r0
	sts	macl,r5
	mov.l	mp_meta,r1
	add	r1,r5
	mov.w	mp_220,r0		! S = UI slot n, M = its model copy
	mulu.w	r0,r4
	sts	macl,r6
	mov.l	mp_ui,r1
	add	r6,r1
	mov.l	mp_model,r2
	add	r6,r2
	mov	r1,r0
	add	#0x28,r0
	mov.w	@r0,r0			! title length
	extu.w	r0,r0
	mov.w	mp_cf,r3
	cmp/hs	r3,r0
	bt	9f
	mov.w	mp_1ca,r0		! +0x2A + 0x1A0
	add	r0,r1
	add	r0,r2
	mov.l	r1,@-r15
	mov.l	r2,@-r15
	mov	#42,r3			! mp3reset: at most 41 characters + the 0 (84 B of
	mov	#-1,r7			! the slot's 86 after +0x1CA), and 0xFFFF ends it:
	extu.w	r7,r7			! a row text rw_meta never wrote (RAMB is 0xFF from
1:	mov.w	@r5+,r0			! the image; a non-rekordbox medium) ran ~64 KB of
	extu.w	r0,r0			! 0xFFFF over the slots and the RTOS -> reset
	cmp/eq	r7,r0
	bf	2f
	mov	#0,r0
2:	dt	r3
	bf	3f
	mov	#0,r0
3:	mov.w	r0,@r1
	mov.w	r0,@r2
	add	#2,r1
	tst	r0,r0
	bf/s	1b
	add	#2,r2
	mov.l	@r15+,r2		! slot +0x0C bit 2 (both copies): the row
	mov.l	@r15+,r1		! text changed, so the packer sends the
	mov.w	mp_1ca,r0		! slots' text (0x39) again
	sub	r0,r1
	sub	r0,r2
	add	#0x0c,r1
	add	#0x0c,r2
	mov.b	@r1,r0
	or	#4,r0
	mov.b	r0,@r1
	mov.b	@r2,r0
	or	#4,r0
	mov.b	r0,@r2
9:	rts
	nop
mp_220:		.word 0x220
mp_cf:		.word 0xCF
mp_1ca:		.word 0x2A + 0x1A0
	.p2align 2
mp_tab:		.long RAMB+0x10000
mp_meta:	.long RAMB+0x10100
mp_ui:		.long 0x0B5434EC	! UI slots
mp_model:	.long 0x0B53FBA4	! the model's copy (0x0B53FB50 + 0x54)

! rw_art: the row's artwork (export.pdb artwork id, kept by rw_meta) ->
! 20x20 RGB565 at TP_JBUF + 0x1C000, through the tadec blob's JPEG entry
! (stb_image); 0x081F0094 = 1 when it worked. The file is
! C:/PIONEER/Artwork/<id / 20 + 1, 5 digits>/a<id>.jpg (rekordbox's export
! layout). Uses r0-r7 and r12; r9 = TP state.
rw_art:
	sts.l	pr,@-r15
	mov.l	r12,@-r15
	mov.l	ra_ok,r1
	mov	#0,r0
	mov.l	r0,@r1
	mov.l	ra_id,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	ra_ret
	mov.l	ra_blob,r1		! the tadec blob present (cave not erased)?
	mov.w	@r1,r0
	extu.w	r0,r0
	mov.w	ra_erased,r1
	extu.w	r1,r1
	cmp/eq	r1,r0
	bt	ra_ret
	mov	#TP_JBUF,r0		! the buffers, once
	mov.l	@(r0,r9),r12
	tst	r12,r12
	bf	1f
	mov.l	ra_size,r4
	mov.l	ra_malloc,r1
	mov.l	@r8,r2
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
	tst	r0,r0
	bt	ra_ret
	mov	r0,r12
	mov	#TP_JBUF,r0
	mov.l	r12,@(r0,r9)
1:	ld	r6,D_BUF		! the path, wide, into B_APATH (free here)
	mov.w	ra_bap,r0
	add	r0,r6
	mov.l	r6,@-r15
	mov.l	ra_med,r0		! the current medium's letter, then the dir
	mov.l	@(4,r0),r0
	mov.w	r0,@r6
	add	#2,r6
	mova	ra_dir,r0
	mov	r0,r1
	bsr	rm_puts
	nop
	mov.l	ra_id,r1
	mov.l	@r1,r4
	mov	#20,r5
	bsr	rm_udiv
	nop
	add	#1,r0
	mov	r0,r4
	bsr	rm_dec
	mov	#5,r7
	mov	#'/',r0
	mov.w	r0,@r6
	add	#2,r6
	mov	#'a',r0
	mov.w	r0,@r6
	add	#2,r6
	mov.l	ra_id,r1
	mov.l	@r1,r4
	bsr	rm_dec
	mov	#1,r7
	mova	ra_ext,r0
	mov	r0,r1
	bsr	rm_puts
	nop
	mov	#0,r0
	mov.w	r0,@r6
	mov.l	@r15+,r4
	fw	D_FOPEN
	tst	r0,r0
	bt	ra_ret
	mov.l	r0,@-r15		! (handle)
	mov	r12,r4			! the file -> TP_JBUF (16 KB at most)
	mov	#1,r5
	mov.w	ra_16k,r6
	mov	r0,r7
	fw	D_FREAD
	mov	r0,r5
	mov.l	@r15+,r4
	mov.l	r5,@-r15		! (length)
	fw	D_FCLOSE
	mov.l	@r15+,r5
	cmp/pl	r5
	bf	ra_ret
	mov.l	ra_len,r1		! D4: the stock hardware JPEG path (JPU + VEU, run inside JpegMgrTask) first
	mov.l	r5,@r1
	bsr	ja_req
	nop
	tst	r0,r0
	bt	ra_hw
	mov.l	ra_len,r1
	mov.l	@r1,r5
	mov	r12,r4			! tadec_jpeg(file, len, out, arena): not decodable by the JPU
	mov.l	ra_jout,r6
	add	r12,r6
	mov.w	ra_16k,r7
	add	r12,r7
	mov.l	ra_entry,r1
	jsr	@r1
	nop
	tst	r0,r0
	bf	ra_ret
ra_hw:	mov.l	ra_ok,r1
	mov	#1,r0
	mov.l	r0,@r1
ra_ret:	mov.l	@r15+,r12
	lds.l	@r15+,pr
	rts
	nop
ra_erased:	.word 0xFFFF
ra_bap:		.word B_APATH
ra_16k:		.word 0x4000
	.p2align 2
ra_id:		.long RAMB+0x10090	! the row's artwork id (rw_meta)
ra_med:		.long MED
ra_ok:		.long RAMB+0x10094
ra_blob:	.long TADEC	! tadec
ra_entry:	.long TADEC+0x14	! tadec_jpeg
ra_malloc:	.long 0x08344A9C
ra_len:		.long RAMB+0x100A4	! D4: the file's length (ja_req)
ra_size:	.long 0x1C000 + 800	! file 16 KB, arena 96 KB, 20x20 out
ra_jout:	.long 0x1C000
ra_dir:		.ascii	":/PIONEER/Artwork/\0"
	.p2align 2
ra_ext:		.ascii	".jpg\0"
	.p2align 2

! ---------------------------------------------------------------------------
! D4: row artwork through the stock HARDWARE JPEG path (re/ARTWORK_DECODER.md §4, prototype work/artwork/artjpu.s).
! JpegMgrTask (prio 9) owns the SH7724 JPU + VEU; Jpeg_DecodeThumbs 0x082C260E drives them and waits on an event flag.
! Calling it from TchAud would race the stock decodes (nothing locks the JPU/VEU/Y-C buffers), so TchAud posts a
! message to JpegMgrTask's mailbox instead, and the task's own free-path literal (0x083D6CF8, swapped by
! patch_main.place_artj) runs jm_shim for it: the mailbox serialises our decodes with the stock ones.

! jm_shim, in JpegMgrTask: r4 = message (+0x18 = 0: the task's `free` path). msg: +8 type, +0x1C jpeg*, +0x20 len,
! +0x24 small*, +0x28 big* (both 16-aligned, 0x1180 / 0x6660 B), +0x2C done*, +0x30 seq. Any other message, or any
! boot that is not a normal one (*0x0A35DF3C != 1), goes straight to the stock free(msg). r8-r14 preserved.
	.macro	jfp
	sts	fpscr,r1		! the firmware's own mask after each call (0xFFE7FFFF)
	mov.l	jm_fpm,r2
	and	r2,r1
	lds	r1,fpscr
	.endm
	.p2align 2
	.long	0x7E57A7D4		! marker: patch_main.place_artj finds jm_shim behind it
jm_shim:
	mov.l	@(8,r4),r0
	mov.l	jm_type,r1
	cmp/eq	r1,r0
	bt	0f
	bra	jm_free
	nop
0:	mov.l	jm_boot,r1		! never in update mode (we are never sent a message then either)
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bt	0f
	bra	jm_free
	nop
0:	sts.l	pr,@-r15
	mov.l	r14,@-r15
	mov.l	r13,@-r15
	mov	r4,r14			! r14 = msg
	add	#-8,r15			! @0 b, @4 a
	mov.l	jm_ctx,r13
	mov.l	jm_stp,r0		! staging <- our JPEG (the stock buffer, idle between messages)
	mov.l	@(r0,r13),r4
	mov.l	@(0x1C,r14),r5
	mov.l	jm_memcpy,r1
	jsr	@r1
	mov.l	@(0x20,r14),r6
	jfp
	mov.l	jm_stl,r0
	mov.l	@(0x20,r14),r4
	mov.l	r4,@(r0,r13)		! the length where On13c5 puts it
	mov	r15,r6			! Jpeg_ParseHdr(len, &a, &b), as On13c5 0x083D741A
	mov	r15,r5
	mov.l	jm_parse,r1
	jsr	@r1
	add	#4,r5
	jfp
	cmp/pz	r0
	bf	jm_fail
	mov.l	jm_stp,r0		! purge the staged bytes for the JPU (as 0x083D7436)
	mov.l	@(r0,r13),r4
	mov	#-32,r2
	and	r2,r4
	mov.l	@(0x20,r14),r5
	add	#31,r5
	and	r2,r5
	add	#32,r5
	mov.l	jm_purge,r1
	jsr	@r1
	nop
	jfp
	mov.l	@(0x24,r14),r4		! purge our outputs: no dirty line of the buffer's earlier use may be
	mov.l	jm_pgn,r5		!   written back over what the VEU writes
	mov.l	jm_purge,r1
	jsr	@r1
	nop
	jfp
	mov.l	@(0x28,r14),r1		! Jpeg_DecodeThumbs(stg, a, b, small, big) 0x082C260E
	mov.l	r1,@-r15
	mov.l	jm_stp,r0
	mov.l	@(r0,r13),r4
	mov.l	@(8,r15),r5
	mov.l	@(4,r15),r6
	mov.l	@(0x24,r14),r7
	mov.l	jm_dec,r1
	jsr	@r1
	nop
	jfp
	add	#4,r15
	cmp/pz	r0
	bf	jm_fail
	mov.l	@(0x30,r14),r0		! done = seq (TchAud matches it: a late reply is ignored)
	bra	jm_done
	nop
jm_fail:
	mov	#-1,r0
jm_done:
	mov.l	@(0x2C,r14),r1
	mov.l	r0,@r1
	mov	r14,r4
	add	#8,r15
	mov.l	@r15+,r13
	mov.l	@r15+,r14
	lds.l	@r15+,pr
jm_free:
	mov.l	jm_freef,r1		! the stock tail: free(msg)
	jmp	@r1
	nop
	.p2align 2
jm_type:	.long	0x0000A27A
jm_boot:	.long	0x0A35DF3C
jm_ctx:		.long	0x157F804C
jm_stp:		.long	0x00F04014
jm_stl:		.long	0x00F04010
jm_memcpy:	.long	0x085336DC
jm_parse:	.long	0x083D722A
jm_purge:	.long	0x08213F14
jm_dec:		.long	0x082C260E
jm_freef:	.long	0x08344B42
jm_fpm:		.long	0xFFE7FFFF
jm_pgn:		.long	0x1180 + 0x6660 + 32

! ja_req: r12 = TP_JBUF buffer (the file, 16 KB, at +0), RAMB+0x100A4 = its length. Posts the decode to JpegMgrTask,
! waits (<= 700 ms: the JPU's own timeout is 500) and box-averages the 109x117 "big" RGB565 into the 20x20 at
! +0x1C000. State RAMB+0x10098: +0 done (seq, or -1 = the JPU refused it), +4 seq, +8 latch (no answer: no JPU
! requests for the rest of the boot). r0 = 0 ok, -1 not decoded (the caller falls back to tadec_jpeg).
! Keeps r8-r14 (r8 = data, r9 = TP state).
ja_req:
	sts.l	pr,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r13,@-r15
	mov.l	r14,@-r15
	mov.l	ja_st,r10
	mov.l	@(8,r10),r0		! (the block starts as erased flash: 0xFFFFFFFF; only 1 = latched)
	cmp/eq	#1,r0
	bf	0f
	mov.l	@r10,r0			! V4n24: latched = the timed-out request is still out; its late answer
	tst	r0,r0			! (done != 0) re-opens the JPU path (was: off for the rest of the boot,
	bt	ja_fail			! so the loaded track's big artwork never came back after one slow decode)
	mov	#0,r0
	mov.l	r0,@(8,r10)
0:	mov.l	ja_ctx,r1
	mov.l	@(4,r1),r14		! JpegMgrTask's mailbox id
	tst	r14,r14
	bt	ja_fail
	mov	#0x40,r4		! msg = malloc(0x40); JpegMgrTask frees it
	mov.l	ja_malloc,r1
	mov.l	@r8,r2
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
	tst	r0,r0
	bt	ja_fail
	mov	r0,r11
	mov	#0,r1
	mov.l	r1,@r11
	mov.l	r1,@(0x18,r11)		! pool 0: freed with free()
	mov.l	ja_type,r1
	mov.l	r1,@(8,r11)
	mov.l	r12,@(0x1C,r11)
	mov.l	ja_lenp,r1
	mov.l	@r1,r1
	mov.l	r1,@(0x20,r11)
	mov.w	ja_so,r0		! small = (buf + 0x4000 + 15) & ~15, big right behind it
	mov	r12,r2
	add	r0,r2
	add	#15,r2
	mov	#-16,r0
	and	r0,r2
	mov.l	r2,@(0x24,r11)
	mov.w	ja_bo,r0
	add	r0,r2
	mov.l	r2,@(0x28,r11)
	mov.l	r10,@(0x2C,r11)
	mov.l	@(4,r10),r1		! seq: odd, 1..0xFFFF (never 0 = pending, never -1 = refused), done = 0
	add	#2,r1
	extu.w	r1,r1
	mov	r1,r0
	or	#1,r0
	mov	r0,r1
	mov.l	r1,@(4,r10)
	mov.l	r1,@(0x30,r11)
	mov	#0,r1
	mov.l	r1,@r10
	mov	r14,r4			! snd_mbx(mailbox, msg)
	mov	r11,r5
	mov.l	ja_snd,r1
	mov.l	@r8,r2
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
	mov.w	ja_tmo,r11
1:	mov	#1,r4
	fw	D_DLY
	mov.l	@r10,r0
	tst	r0,r0
	bf	2f
	dt	r11
	bf	1b
	mov	#1,r0			! no answer in 700 ms: latch (a late done is ignored by the seq check)
	mov.l	r0,@(8,r10)
	bra	ja_fail
	nop
2:	mov.l	@(4,r10),r1		! done == seq? (-1: the JPU refused the image)
	cmp/eq	r1,r0
	bf	ja_fail
	bsr	ja_box
	nop
	mov.l	ja_jok,r1		! G2: the big image is in the buffer (ar_load copies it)
	mov	#1,r0
	mov.l	r0,@r1
	mov	#0,r0
	bra	ja_ret
	nop
ja_fail:
	mov	#-1,r0
ja_ret:
	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	lds.l	@r15+,pr
	rts
	nop
	.p2align 1
ja_so:		.word	0x4000
ja_bo:		.word	0x1180
ja_tmo:		.word	700
	.p2align 2
ja_st:		.long	RAMB+0x10098
ja_lenp:	.long	RAMB+0x100A4
ja_ctx:		.long	0x157F8040
ja_snd:		.long	0x08516E08
ja_malloc:	.long	0x08344A9C
ja_type:	.long	0x0000A27A
ja_jok:		.long	RAMB+0x100A8	! G2: 1 = ja_req left a big image

! ja_box: the 109 x 117 RGB565 big image (stride 0xE0, behind the 16-aligned small one) -> 20x20 box average at
! +0x1C000 of the buffer (r12). Cell (ox, oy) takes columns [ox*109/20, (ox+1)*109/20) and rows [oy*117/20, ..):
! 5 or 6 each, so 25, 30 or 36 pixels. Keeps r8-r14 (r12 in).
ja_box:
	sts.l	pr,@-r15		! (bx_sc is called with bsr)
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r13,@-r15
	mov.l	r14,@-r15
	add	#-4,r15			! @0 pixel count
	mov.w	bx_so,r0		! r11 = big
	mov	r12,r11
	add	r0,r11
	add	#15,r11
	mov	#-16,r0
	and	r0,r11
	mov.w	bx_bo,r0
	add	r0,r11
	mov.w	bx_out,r0		! r13 = out
	shll2	r0
	shll2	r0
	mov	r12,r13
	add	r0,r13
	mov	#0,r14			! oy
bx_y:	mov	#0,r10			! ox
bx_x:	mov	#117,r2			! y0 (r5), rows (r6)
	mov	r14,r1
	bsr	bx_sc
	nop
	mov	r0,r5
	mov	r14,r1
	add	#1,r1
	bsr	bx_sc
	nop
	sub	r5,r0
	mov	r0,r6			! rows
	mov	#109,r2			! x0 (r7), width (r8)
	mov	r10,r1
	bsr	bx_sc
	nop
	mov	r0,r7
	mov	r10,r1
	add	#1,r1
	bsr	bx_sc
	nop
	sub	r7,r0
	mov	r0,r8			! width
	mulu.w	r8,r6
	sts	macl,r0
	mov.l	r0,@r15			! count
	mov.w	bx_224,r0		! r4 = &big[y0][x0]
	mulu.w	r0,r5
	sts	macl,r4
	add	r11,r4
	add	r7,r4
	add	r7,r4
	mov	#0,r1			! sums r1 R, r2 G, r3 B
	mov	#0,r2
	mov	#0,r3
bx_r:	mov	r4,r5
	mov	r8,r9
bx_c:	mov.w	@r5+,r0
	extu.w	r0,r0
	mov	r0,r7
	and	#0x1F,r0
	add	r0,r3
	mov	r7,r0
	shlr2	r0
	shlr2	r0
	shlr	r0
	and	#0x3F,r0
	add	r0,r2
	shlr8	r7
	shlr2	r7
	shlr	r7
	add	r7,r1
	dt	r9
	bf	bx_c
	mov.w	bx_224,r0
	add	r0,r4
	dt	r6
	bf	bx_r
	mov.l	@r15,r0			! reciprocal 65536 / count
	mov.w	bx_k2621,r4
	cmp/eq	#25,r0
	bt	1f
	mov.w	bx_k2184,r4
	cmp/eq	#30,r0
	bt	1f
	mov.w	bx_k1820,r4
1:	mulu.w	r4,r1			! R
	sts	macl,r1
	shlr16	r1
	mulu.w	r4,r2			! G
	sts	macl,r2
	shlr16	r2
	mulu.w	r4,r3			! B
	sts	macl,r3
	shlr16	r3
	shll8	r1
	shll2	r1
	shll	r1			! R << 11
	shll2	r2
	shll2	r2
	shll	r2			! G << 5
	or	r2,r1
	or	r3,r1
	mov.w	r1,@r13
	add	#2,r13
	add	#1,r10
	mov	#20,r0
	cmp/hs	r0,r10
	bf	bx_x
	add	#1,r14
	cmp/hs	r0,r14
	bf	bx_y
	add	#4,r15
	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	lds.l	@r15+,pr
	rts
	nop
! bx_sc: r0 = (r1 * r2) / 20 (r1 <= 20, r2 <= 117: < 2400, 3277 / 65536 is exact there). Clobbers r1, r0.
bx_sc:
	mulu.w	r2,r1
	sts	macl,r1
	mov.w	bx_k3277,r0
	mulu.w	r0,r1
	sts	macl,r0
	rts
	shlr16	r0
	.p2align 1
bx_so:		.word	0x4000
bx_bo:		.word	0x1180
bx_out:		.word	0x1C000 >> 4		! (<< 4)
bx_224:		.word	0xE0
bx_k3277:	.word	3277
bx_k2621:	.word	2621
bx_k2184:	.word	2184
bx_k1820:	.word	1820
	.p2align 2

! keys_build: once, the key names: export.pdb's key table (type 5: +0 id,
! +8 the name, a short or long ASCII DeviceSQL string) -> 0x081F0400 +
! id*8, seven characters at most. TP_KS = 1 whatever happens. r9 = TP state;
! uses r10-r14 (saved by row_waves).
keys_build:
	sts.l	pr,@-r15
	mov	#TP_KS,r0
	mov	#1,r1
	mov.l	r1,@(r0,r9)
	mov.l	kb_keys,r1		! clear the names
	mov.w	kb_256,r3
	mov	#0,r2
1:	mov.l	r2,@r1
	dt	r3
	bf/s	1b
	add	#4,r1
	ld	r11,D_BUF
	mov.w	kb_bpage,r0
	add	r0,r11			! r11 = page buffer
	mov	#TP_PDB,r0
	mov.l	@(r0,r9),r12		! r12 = export.pdb (open since the index)
	tst	r12,r12
	bt	kb_ret
	mov	r12,r4			! the header
	mov	#0,r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4
	mov	#1,r5
	mov.w	kb_4096,r6
	mov	r12,r7
	fw	D_FREAD
	mov.l	@(4,r11),r13		! r13 = page size
	mov.w	kb_4096,r0
	cmp/hi	r0,r13
	bt	kb_ret
	mov.l	@(8,r11),r14		! tables
	mov	#64,r0
	cmp/hi	r0,r14
	bt	kb_ret
	mov	r11,r1
	add	#0x1c,r1
2:	tst	r14,r14
	bt	kb_ret
	mov.l	@r1,r0
	cmp/eq	#5,r0			! type 5 = keys
	bt	3f
	add	#16,r1
	bra	2b
	dt	r14
3:	mov.l	@(8,r1),r10		! r10 = page
	mov.l	@(12,r1),r0
	mov.l	r0,@-r15		! (last page)
	mov	#64,r0
	mov.l	r0,@-r15		! (pages left)
kb_pg:	mov	r10,r0			! fseek(page * size); read it
	mulu.w	r13,r0
	sts	macl,r5
	mov	r12,r4
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4
	mov	#1,r5
	mov	r13,r6
	mov	r12,r7
	fw	D_FREAD
	cmp/eq	r13,r0			! a short read: as no data page (r13 = PS)
	bf	kb_next
	mov	r11,r1
	add	#0x1b,r1
	mov.b	@r1,r0
	tst	#0x40,r0
	bf	kb_next			! not a data page
	mov	r11,r1
	add	#0x18,r1
	mov.b	@r1,r14
	extu.b	r14,r14			! rows (small count; a key table is small)
	mov	#0,r3			! row index
kb_row:	cmp/hs	r14,r3
	bt	kb_next
	mov	r3,r0			! group base = PS - (i / 16) * 0x24
	shlr2	r0
	shlr2	r0
	mov	#0x24,r1
	mulu.w	r1,r0
	sts	macl,r0
	mov	r13,r1
	sub	r0,r1
	add	r11,r1
	mov	r3,r2
	mov	#15,r0
	and	r0,r2			! k = i % 16
	mov	r1,r4
	add	#-4,r4
	mov.w	@r4,r4
	extu.w	r4,r4			! presence bits
	mov	r2,r0
	neg	r0,r0
	shld	r0,r4
	mov	r4,r0
	tst	#1,r0
	bt	kb_rnext
	mov	r2,r0			! offset = u16 at group base - 6 - 2k
	add	r0,r0
	mov	r1,r4
	sub	r0,r4
	add	#-6,r4
	mov.w	@r4,r4
	extu.w	r4,r4
	mov	#0x28,r0
	add	r0,r4
	mov	r4,r0			! the row must fit the page
	add	#24,r0
	cmp/hi	r13,r0
	bt	kb_rnext
	add	r11,r4			! r4 = row
	mov.l	r3,@-r15
	mov	r4,r1
	bsr	kb_rd32			! id
	nop
	mov	r0,r5
	mov.l	@r15+,r3
	mov	#127,r1
	cmp/hi	r1,r5
	bt	kb_rnext
	shll2	r5
	add	r5,r5
	mov.l	kb_keys,r1
	add	r1,r5			! r5 = its name slot
	mov	r4,r1
	add	#8,r1
	mov.b	@r1+,r0			! the string's kind
	extu.b	r0,r0
	tst	#1,r0
	bt	4f
	shlr	r0			! short ASCII: length = kind / 2 - 1
	add	#-1,r0
	bra	5f
	mov	r0,r2
4:	cmp/eq	#0x40,r0		! long ASCII: u16 length (incl. 4), then +4
	bf	kb_rnext
	mov.b	@r1,r0
	extu.b	r0,r2
	add	#-4,r2
	add	#3,r1
5:	mov	#7,r0
	cmp/hi	r0,r2
	bf	6f
	mov	r0,r2
6:	tst	r2,r2
	bt	kb_rnext
7:	mov.b	@r1+,r0
	mov.b	r0,@r5
	dt	r2
	bf/s	7b
	add	#1,r5
kb_rnext:
	bra	kb_row
	add	#1,r3
kb_next:
	mov.l	@(4,r15),r1		! the last page?
	cmp/eq	r10,r1
	bt	kb_done
	mov.l	@r15,r0
	dt	r0
	bt	kb_done
	mov.l	r0,@r15
	mov	r11,r1
	add	#0x0c,r1
	bsr	kb_rd32
	nop
	mov	r0,r10
	bra	kb_pg
	nop
kb_done:
	add	#8,r15
kb_ret:	lds.l	@r15+,pr
	rts
	nop
kb_rd32:				! tr_rd32's copy (out of bsr range from here)
	mov.b	@(3,r1),r0
	extu.b	r0,r2
	shll8	r2
	mov.b	@(2,r1),r0
	extu.b	r0,r0
	or	r0,r2
	shll8	r2
	mov.b	@(1,r1),r0
	extu.b	r0,r0
	or	r0,r2
	shll8	r2
	mov.b	@r1,r0
	extu.b	r0,r0
	rts
	or	r2,r0
kb_256:		.word 256
kb_bpage:	.word B_PAGE
kb_4096:	.word 4096
	.p2align 2
kb_keys:	.long RAMB+0x10400

! tr_pwv4 (rowwave): the same walk on the row's .EXT file (B_APATH with its
! extension changed from DAT) for PWV4, the colour preview: 1200 columns of
! 6 bytes (+3..+5: the low, mid and high band levels, 0-127) -> B_RW4,
! TP_RWC = 1. r9 = TP state, r11 = page buffer; uses r12, r13.
tr_pwv4:
	sts.l	pr,@-r15
	mov	#TP_RW,r0		! G1: a browse row in WAVEFORM COLOR 3BAND (heartbeat word, bits 3-4 = 0, 0x4C
	mov.l	@(r0,r9),r0		!   magic in its top byte = modsmenu running) reads the .2EX PWV6 first
	tst	r0,r0
	bt	t6_no
	mov.l	t6_hb,r1
	mov.b	@(3,r1),r0
	cmp/eq	#0x4C,r0
	bf	t6_no
	mov.b	@r1,r0
	and	#0x18,r0
	tst	r0,r0
	bt	2f			! 3BAND
	cmp/eq	#0x10,r0
	bf	t6_no			! RGB: the PWV4 colour look
	mov	#TP_RWC,r0		! BLUE: the blue PWAV look (TP_RWC 0, rd_blue), no PWV4 read
	mov	#0,r1
	bra	t6_ok
	mov.l	r1,@(r0,r9)
2:	bsr	tr_pwv6
	nop
	mov	#TP_RWC,r0
	mov.l	@(r0,r9),r0
	cmp/eq	#2,r0
	bt	t6_ok			! PWV6 in: done (else the PWV4 look)
t6_no:	mov	#TP_RWC,r0
	mov	#0,r1
	mov.l	r1,@(r0,r9)
	ld	r4,D_BUF
	mov.w	t4_bap,r0
	add	r0,r4
	mov	r4,r1			! "...ANLZ0000.DAT" -> ".EXT"
1:	mov.w	@r1+,r0
	tst	r0,r0
	bf	1b
	add	#-8,r1			! r1 = the 'D'
	mov	#'E',r0
	mov.w	r0,@r1
	mov	#'X',r0
	mov.w	r0,@(2,r1)
	mov	#'T',r0
	mov.w	r0,@(4,r1)
	fw	D_FOPEN
	tst	r0,r0
	bt	9f
	mov.l	r0,@(TP_FH,r9)
	mov	#0,r12			! file offset
	mov	#40,r13			! tags, at most
1:	mov.l	@(TP_FH,r9),r4
	mov	r12,r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4			! 12-byte head -> the page buffer
	mov	#1,r5
	mov	#12,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov	#12,r1			! a short read: no tag (fread clobbers r6)
	cmp/eq	r1,r0
	bf	8f
	mov.l	@(4,r11),r1		! big-endian header length
	swap.b	r1,r1
	swap.w	r1,r1
	swap.b	r1,r1
	mov.l	@(8,r11),r2		! big-endian tag length
	swap.b	r2,r2
	swap.w	r2,r2
	swap.b	r2,r2
	tst	r12,r12
	bf	2f
	bra	3f			! the PMAI file header: skip it
	mov	r1,r12
2:	mov.l	@r11,r0
	mov.l	t4_pwv4,r3
	cmp/eq	r3,r0
	bt	4f
	tst	r2,r2
	bt	8f
	add	r2,r12			! next tag
3:	dt	r13
	bf	1b
	bra	8f
	nop
4:	mov.l	@(TP_FH,r9),r4		! PWV4: its data follows its header
	mov	r12,r5
	add	r1,r5
	mov	#0,r6
	fw	D_FSEEK
	ld	r4,D_BUF
	mov.w	t4_brw4,r0
	add	r0,r4
	mov	#1,r5
	mov.w	t4_7200,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov.w	t4_7200,r1
	cmp/eq	r1,r0
	bf	8f
	mov	#TP_RWC,r0
	mov	#1,r1
	mov.l	r1,@(r0,r9)
8:	mov.l	@(TP_FH,r9),r4
	fw	D_FCLOSE
9:
t6_ok:	lds.l	@r15+,pr
	rts
	nop
t4_bap:		.word B_APATH
t4_brw4:	.word B_RW4
t4_7200:	.word 7200
	.p2align 2
t4_pwv4:	.ascii	"PWV4"
t6_hb:		.long	0x0B568C9C + 0x54	! modsmenu's heartbeat word

! G1 tr_pwv6: the tr_pwv4 walk on the .2EX (DAT -> 2EX) for PWV6, the 3-band preview (1200 x 3 B:
! low, mid, high, 0-128) -> B_RW4 (3600 B), TP_RWC = 2.
tr_pwv6:
	sts.l	pr,@-r15
	mov	#TP_RWC,r0
	mov	#0,r1
	mov.l	r1,@(r0,r9)
	ld	r4,D_BUF
	mov.w	t6_bap,r0
	add	r0,r4
	mov	r4,r1			! "...ANLZ0000.DAT" -> ".EXT"
1:	mov.w	@r1+,r0
	tst	r0,r0
	bf	1b
	add	#-8,r1			! r1 = the 'D'
	mov	#'2',r0
	mov.w	r0,@r1
	mov	#'E',r0
	mov.w	r0,@(2,r1)
	mov	#'X',r0
	mov.w	r0,@(4,r1)
	fw	D_FOPEN
	tst	r0,r0
	bt	9f
	mov.l	r0,@(TP_FH,r9)
	mov	#0,r12			! file offset
	mov	#40,r13			! tags, at most
1:	mov.l	@(TP_FH,r9),r4
	mov	r12,r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4			! 12-byte head -> the page buffer
	mov	#1,r5
	mov	#12,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov	#12,r1			! a short read: no tag (fread clobbers r6)
	cmp/eq	r1,r0
	bf	8f
	mov.l	@(4,r11),r1		! big-endian header length
	swap.b	r1,r1
	swap.w	r1,r1
	swap.b	r1,r1
	mov.l	@(8,r11),r2		! big-endian tag length
	swap.b	r2,r2
	swap.w	r2,r2
	swap.b	r2,r2
	tst	r12,r12
	bf	2f
	bra	3f			! the PMAI file header: skip it
	mov	r1,r12
2:	mov.l	@r11,r0
	mov.l	t6_pwv6,r3
	cmp/eq	r3,r0
	bt	4f
	tst	r2,r2
	bt	8f
	add	r2,r12			! next tag
3:	dt	r13
	bf	1b
	bra	8f
	nop
4:	mov.l	@(TP_FH,r9),r4		! PWV4: its data follows its header
	mov	r12,r5
	add	r1,r5
	mov	#0,r6
	fw	D_FSEEK
	ld	r4,D_BUF
	mov.w	t6_brw4,r0
	add	r0,r4
	mov	#1,r5
	mov.w	t6_3600,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov.w	t6_3600,r1
	cmp/eq	r1,r0
	bf	8f
	mov	#TP_RWC,r0
	mov	#2,r1
	mov.l	r1,@(r0,r9)
8:	mov.l	@(TP_FH,r9),r4
	fw	D_FCLOSE
9:
	lds.l	@r15+,pr
	rts
	nop
! G1 rd_3b: a column in the 3BAND look (v2.c look_3band, scaled to the cell's 10 rows each side): the peaks of
! the low / mid / high bands (PWV6 entries of 3 bytes in B_RW4) over the column's span; rows = low x1.2, mid x0.75,
! high (h/4 - 2); high cream on top, mid dark orange inside the low extent / light orange beyond, low blue.
rd_3b:
	ld	r12,D_BUF
	mov.w	rt_brw4,r0
	add	r0,r12
	mov.l	@(4,r15),r1
	mov.l	@r15,r0
	mov	r13,r2
	sub	r0,r2
	mulu.w	r1,r2
	sts	macl,r2
	shlr8	r2
	shlr2	r2			! first entry
	mov	r13,r3
	sub	r0,r3
	add	#1,r3
	mulu.w	r1,r3
	sts	macl,r3
	shlr8	r3
	shlr2	r3			! end entry
	mov	#0,r4
	mov	#0,r5
	mov	#0,r6
rt_pk:	cmp/hs	r3,r2
	bt	rt_pd
	mov	r2,r0
	add	r0,r0
	add	r2,r0
	add	r12,r0
	mov	r0,r7
	mov.b	@r7,r0
	extu.b	r0,r0
	cmp/hi	r4,r0
	bf	rt_p1
	mov	r0,r4
rt_p1:	mov.b	@(1,r7),r0
	extu.b	r0,r0
	cmp/hi	r5,r0
	bf	rt_p2
	mov	r0,r5
rt_p2:	mov.b	@(2,r7),r0
	extu.b	r0,r0
	cmp/hi	r6,r0
	bf	rt_p3
	mov	r0,r6
rt_p3:	bra	rt_pk
	add	#1,r2
rt_pd:	mov.w	rt_1023,r2		! V4n21: bottom-anchored STACK (the 3000's 3BAND browse): low blue base, mid orange above it,
	mov	#100,r1			!   high white on top; r4 = low rows, r5 = low+mid, r6 = low+mid+high (<= 20)
	mulu.w	r1,r4
	sts	macl,r4
	mov	r2,r3
	shlr	r3
	add	r3,r4
	shlr8	r4
	shlr	r4			! lo * 200 / 1024 (ceil)
	mov	#62,r1
	mulu.w	r1,r5
	sts	macl,r5
	add	r2,r5
	shlr8	r5
	shlr2	r5
	mov	#80,r1
	mulu.w	r1,r6
	sts	macl,r6
	shlr8	r6
	shlr2	r6
	add	r4,r5
	add	r5,r6
	mov	#20,r1
	cmp/hi	r1,r4
	bf	rt_c4
	mov	r1,r4
rt_c4:	cmp/hi	r1,r5
	bf	rt_c5
	mov	r1,r5
rt_c5:	cmp/hi	r1,r6
	bf	rt_c6
	mov	r1,r6
rt_c6:	mov	r11,r1
	mov	r13,r0
	add	r0,r0
	add	r0,r1			! r1 = &pix[0][x]
	mov	#0,r7			! y
rt_y:	mov	#RD_H-1,r2
	sub	r7,r2			! d = rows above the bottom
	cmp/hi	r2,r4			! d < low
	bf	rt_k1
	mov.w	rt_cl,r3
	bra	rt_w
	nop
rt_k1:	cmp/hi	r2,r5			! d < low+mid
	bf	rt_k2
	mov.w	rt_cm,r3
	bra	rt_w
	nop
rt_k2:	cmp/hi	r2,r6			! d < low+mid+high
	bf	rt_k4
	mov.w	rt_ch,r3
	bra	rt_w
	nop
rt_k4:	mov	#0,r3
rt_w:	mov.w	r3,@r1
	mov.w	rt_224,r0
	add	r0,r1
	add	#1,r7
	mov	#RD_H,r0
	cmp/hs	r0,r7
	bf	rt_y
	mova	rt_np,r0
	mov.l	@r0,r1
	add	r0,r1
	jmp	@r1
	nop
	.p2align 2
rt_np:	.long rd_next - rt_np
rt_1023:	.word 1023
rt_brw4:	.word B_RW4
rt_224:	.word RD_W * 2
rt_ch:		.word 0xFFFF		! white (3000 browse 3BAND high)
rt_cm:		.word 0xFD00		! #FFA000 (3000 browse mid)
rt_cm2:		.word 0xFCC5		! #FE9B28 (wc_m2)
rt_cl:		.word 0x02DB		! #0059D8 (3000 browse low)
	.p2align 2
t6_bap:		.word B_APATH
t6_brw4:	.word B_RW4
t6_3600:	.word 3600
	.p2align 2
t6_pwv6:	.ascii	"PWV6"
	.p2align 2
! V4n21: the 3000's browse preview is bottom-anchored (not mirrored), 100 % of the row.
! rd_paintb: r2 = height, r3 = colour: the lower half full, the upper x0.625 (RGB two-tone).
rd_paintb:
	mov	r3,r4
	mov	r3,r5
	shlr	r5
	mov.w	rb_m1,r0
	and	r0,r5
	mov	r3,r6
	shlr2	r6
	shlr	r6
	mov.w	rb_m3,r0
	and	r0,r6
	add	r6,r5			! r5 = outer colour
	mov	r2,r6
	add	#1,r6
	shlr	r6			! r6 = inner rows
	mov	r11,r1
	mov	r13,r0
	add	r0,r0
	add	r0,r1
	mov	#0,r7
1:	mov	#RD_H-1,r0
	sub	r7,r0			! d = rows above the bottom
	cmp/hs	r2,r0
	bt	2f
	cmp/hs	r6,r0
	bt	3f
	bra	4f
	mov.w	r4,@r1
3:	bra	4f
	mov.w	r5,@r1
2:	mov	#0,r0
	mov.w	r0,@r1
4:	mov.w	rb_224,r0
	add	r0,r1
	add	#1,r7
	mov	#RD_H,r0
	cmp/hs	r0,r7
	bf	1b
	bra	rd_next
	nop
! rd_paintl: r2 = height, r6 = whiteness 0-7: BLUE, the vertical ramp table rd_bt (bright base -> dim tip).
rd_paintl:
	mova	rd_bt,r0
	mov	r0,r4
	mov	r6,r0
	mov	#40,r1
	mulu.w	r1,r0
	sts	macl,r0
	add	r0,r4
	mov	r11,r1
	mov	r13,r0
	add	r0,r0
	add	r0,r1
	mov	#0,r7
1:	mov	#RD_H-1,r0
	sub	r7,r0
	cmp/hs	r2,r0
	bt	2f
	shll	r0
	mov.w	@(r0,r4),r0
	bra	4f
	mov.w	r0,@r1
2:	mov	#0,r0
	mov.w	r0,@r1
4:	mov.w	rb_224,r0
	add	r0,r1
	add	#1,r7
	mov	#RD_H,r0
	cmp/hs	r0,r7
	bf	1b
	bra	rd_next
	nop
rb_224:		.word RD_W * 2
rb_m1:		.word 0x7BEF
rb_m3:		.word 0x18E3
	.p2align 2
rd_bt:
		.short 0x13F6, 0x0BD6, 0x0BB5, 0x0B94, 0x0B73, 0x0B53, 0x0B32, 0x0B11, 0x0AF0, 0x0ACF
		.short 0x0AAF, 0x0A6E, 0x0A4D, 0x0A2C, 0x0A0B, 0x09EB, 0x01CA, 0x01A9, 0x0188, 0x0168
		.short 0x2C78, 0x2C57, 0x2436, 0x23F5, 0x23D4, 0x23B3, 0x2393, 0x2352, 0x1B31, 0x1B10
		.short 0x1AEF, 0x1ACF, 0x1A8E, 0x126D, 0x124C, 0x122B, 0x120A, 0x11CA, 0x11A9, 0x0988
		.short 0x44F9, 0x44B8, 0x3C97, 0x3C76, 0x3C35, 0x3C14, 0x33F3, 0x33B3, 0x3392, 0x2B71
		.short 0x2B30, 0x2B0F, 0x2AEE, 0x22AD, 0x228D, 0x226C, 0x1A2B, 0x1A0A, 0x19E9, 0x19A8
		.short 0x5D5A, 0x5D39, 0x5CF8, 0x54D7, 0x5496, 0x4C75, 0x4C34, 0x4413, 0x43D3, 0x43B2
		.short 0x3B91, 0x3B50, 0x332F, 0x32EE, 0x32CD, 0x2A8C, 0x2A6B, 0x222B, 0x220A, 0x21C9
		.short 0x7DDB, 0x759A, 0x7579, 0x6D38, 0x6CF7, 0x64D6, 0x5C95, 0x5C74, 0x5433, 0x5412
		.short 0x4BD1, 0x4B91, 0x4370, 0x432F, 0x3B0E, 0x3ACD, 0x328C, 0x326B, 0x2A2A, 0x2A09
		.short 0x963C, 0x8E1B, 0x8DDA, 0x8599, 0x7D58, 0x7D37, 0x74F6, 0x6CB5, 0x6C94, 0x6453
		.short 0x6412, 0x5BF1, 0x53B0, 0x536F, 0x4B4E, 0x430D, 0x42CC, 0x3A8B, 0x3A6A, 0x3229
		.short 0xAEBD, 0xA67C, 0xA63B, 0x9DFA, 0x95D9, 0x8D98, 0x8D57, 0x8516, 0x7CD5, 0x7494
		.short 0x7473, 0x6C32, 0x63F1, 0x5BB0, 0x5B6F, 0x534E, 0x4B0D, 0x4ACC, 0x428B, 0x3A4A
		.short 0xC71E, 0xBEFD, 0xBEBC, 0xB67B, 0xAE3A, 0xA5F9, 0x9DB8, 0x9577, 0x9536, 0x8CF5
		.short 0x84B4, 0x7C73, 0x7432, 0x6BF1, 0x63AF, 0x636E, 0x5B2D, 0x52EC, 0x4AAB, 0x428A
	.p2align 2

! V4b1: cue_pub -- r10 = tag bytes in the cue block (CUEBUF + 16): its header ('PCO2', seq, rbid, length,
! big-endian words as the display reads them) written, then the control seq published for w8send (kind 3).
! Uses r0-r3.
cue_pub:
	mov.l	cp_ctl,r1
	mov.l	@(CC_SEQ,r1),r2
	add	#1,r2
	mov.l	cp_buf,r3
	mov.l	cp_mag,r0
	mov.l	r0,@r3
	mov	r2,r0
	swap.b	r0,r0
	swap.w	r0,r0
	swap.b	r0,r0
	mov.l	r0,@(4,r3)
	mov.l	@(CC_RB,r1),r0
	swap.b	r0,r0
	swap.w	r0,r0
	swap.b	r0,r0
	mov.l	r0,@(8,r3)
	mov	r10,r0
	swap.b	r0,r0
	swap.w	r0,r0
	swap.b	r0,r0
	mov.l	r0,@(12,r3)
	mov	r10,r0
	add	#19,r0
	shlr2	r0
	shll2	r0
	mov.l	r0,@(CC_TOT,r1)
	mov.w	cp_toff,r0		! V4n24: the 'TITL' record of this rbid there -> the whole block goes
	add	r0,r3
	mov.l	@r3,r0
	mov.l	cp_tmag,r3
	cmp/eq	r3,r0
	bf	1f
	mov.l	cp_buf,r3
	mov.l	@(8,r3),r0		! the header's rbid (swapped as the record's)
	mov.w	cp_toff,r3
	mov.l	cp_buf,r1
	add	r1,r3
	mov.l	@(4,r3),r3
	cmp/eq	r3,r0
	mov.l	cp_ctl,r1
	bf	1f
	mov.w	cp_tend,r0
	mov.l	r0,@(CC_TOT,r1)
1:	mov.l	r2,@(CC_SEQ,r1)
	rts
	nop
	.p2align 1
cp_toff:	.word	TITL_OFF
cp_tend:	.word	0x1010
	.p2align 2
cp_tmag:	.ascii	"TITL"

! G2: ar_pub -- r10 = pixel bytes in the artwork block (0 = none, 26208 = 109 x 117 RGB565, stride 0xE0). Header
! 'PART', seq, rbid, length (words as cue_pub), then the pixels (halfwords already byte-swapped for the display),
! then the seq again as the trailer (the display shows a block only when the trailer matches: chunks arrive in order).
! The control seq is published for w8send (kind 4). Uses r0-r5.
ar_pub:
	mov.l	ap_ctl,r1
	mov.l	@(AR_SEQ,r1),r2
	add	#1,r2
	mov.l	ap_buf,r3
	mov.l	ap_mag,r0
	mov.l	r0,@r3
	mov	r2,r0
	swap.b	r0,r0
	swap.w	r0,r0
	swap.b	r0,r0
	mov	r0,r4			! seq, as the display reads it
	mov.l	r0,@(4,r3)
	mov.l	ap_cc,r5
	mov.l	@(CC_RB,r5),r0
	swap.b	r0,r0
	swap.w	r0,r0
	swap.b	r0,r0
	mov.l	r0,@(8,r3)
	mov	r10,r0
	swap.b	r0,r0
	swap.w	r0,r0
	swap.b	r0,r0
	mov.l	r0,@(12,r3)
	mov	#16,r0
	tst	r10,r10
	bt	1f
	add	r10,r0
	mov	r0,r5
	add	r3,r5
	mov.l	r4,@r5			! the trailer
	add	#4,r0
1:	mov.l	r0,@(AR_TOT,r1)
	mov.l	r2,@(AR_SEQ,r1)
	rts
	nop
	.p2align 2
ap_ctl:		.long RAMB+0x15030
ap_buf:		.long RAMB+0x15100
ap_mag:		.ascii	"PART"
ap_cc:		.long RAMB+0x15010

! G2: ar_load -- the loaded track's artwork (artwork id in RAMB+0x10090, TP state r9): rw_art decodes it through the
! JPU path (JpegMgrTask); the 109 x 117 "big" image is copied into the artwork block and published (kind 4). No image
! (no id, no file) leaves the empty block published by rv_cue. Keeps r8-r14.
! V4n24: when the JPU gave no big image but rw_art's software decode (tadec_jpeg, the 20x20 the browse rows use)
! worked, that 20x20 is scaled up into the block and published once a track (AR_STATE bit 8), so the header /
! INFO always get a cover (the deck showed none: the big image came only from the JPU path). r0 = 1: the JPU path
! was busy (a request still out) -- try again later (tr_cue / rv_cue), else 0.
ar_load:
	sts.l	pr,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	mov.l	ap_idw,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	8f
	mov.l	ja_jokw,r1
	mov	#0,r0
	mov.l	r0,@r1
	bsr	rw_art
	nop
	mov	#TP_JBUF,r0
	mov.l	@(r0,r9),r12
	tst	r12,r12
	bt	8f
	mov.l	ja_jokw,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	ap_soft
	mov.w	ab_so,r0		! big = ((buf + 0x4000 + 15) & ~15) + 0x1180, as ja_box
	mov	r12,r11
	add	r0,r11
	add	#15,r11
	mov	#-16,r0
	and	r0,r11
	mov.w	ab_bo,r0
	add	r0,r11
	mov.l	ap_bufw,r4
	add	#16,r4
	mov.w	ab_n,r3
2:	mov.l	@r11+,r0
	swap.b	r0,r0
	swap.w	r0,r0
	swap.b	r0,r0
	swap.w	r0,r0			! each halfword byte-swapped
	mov.l	r0,@r4
	add	#4,r4
	dt	r3
	bf	2b
	mov.w	ab_len,r10
	bsr	ar_pub
	nop
8:	bra	9f
	mov	#0,r0
ap_soft:
	mov.l	ap_rok,r1		! the software 20x20 there?
	mov.l	@r1,r0
	tst	r0,r0
	bt	7f
	mov.l	ap_ctlw,r1		! once a track
	mov.l	@(AR_STATE,r1),r0
	mov.w	ap_b8,r2
	tst	r2,r0
	bf	7f
	or	r2,r0
	mov.l	r0,@(AR_STATE,r1)
	mov.l	ap_jout,r6		! r6 = source row (20 x 20 RGB565, native halfwords)
	add	r12,r6
	mov.l	ap_bufw,r4
	add	#16,r4			! r4 = the block's pixels (stride 112 halfwords)
	mov	#0,r5			! row accumulator
	mov	#117,r7
3:	mov	#109,r3
	mov	#0,r2
	mov	r6,r1
4:	mov.w	@r1,r0
	swap.b	r0,r0
	mov.w	r0,@r4
	add	#2,r4
	add	#20,r2
	mov	#109,r0
	cmp/hs	r0,r2
	bf	5f
	sub	r0,r2
	add	#2,r1
5:	dt	r3
	bf	4b
	add	#6,r4			! 112 - 109 columns of padding
	add	#20,r5
	mov	#117,r0
	cmp/hs	r0,r5
	bf	6f
	sub	r0,r5
	add	#40,r6
6:	dt	r7
	bf	3b
	mov.w	ab_len,r10
	bsr	ar_pub
	nop
7:	mov.l	ap_jst,r1		! the JPU path busy (latched: a request still out) -> later
	mov.l	@(8,r1),r0
	cmp/eq	#1,r0
	movt	r0
9:	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	lds.l	@r15+,pr
	rts
	nop
	.p2align 1
ab_so:		.word	0x4000
ab_bo:		.word	0x1180
ab_n:		.word	6552
ab_len:		.word	26208
ap_b8:		.word	0x100
	.p2align 2
ap_idw:		.long RAMB+0x10090
ap_bufw:	.long RAMB+0x15100
ja_jokw:	.long RAMB+0x100A8
ap_rok:		.long RAMB+0x10094	! rw_art: 1 = a decode worked (JPU or software)
ap_ctlw:	.long RAMB+0x15030
ap_jout:	.long 0x1C000		! rw_art's 20x20 in TP_JBUF
ap_jst:		.long RAMB+0x10098	! ja_req state (+8 latch)

! tr_pco2: the tr_pwv4 walk on the .EXT (B_APATH) for the PCO2 tags (hot cues and memory cues), their raw
! bytes one after the other into CUEBUF + 16 (4096 bytes at most; a longer one is cut). r10 = bytes copied,
! CC_OK = 1 when the walk ran to its end (the file opened). r9 = TP state, r11 = page buffer.
tr_pco2:
	sts.l	pr,@-r15
	mov.l	cp_ctl,r1
	mov	#0,r0
	mov.l	r0,@(CC_OK,r1)
	mov	#0,r10
	mov	#0,r14
	ld	r4,D_BUF
	mov.w	c4_bap,r0
	add	r0,r4
	mov	r4,r1
1:	mov.w	@r1+,r0
	tst	r0,r0
	bf	1b
	add	#-8,r1
	mov	#'E',r0
	mov.w	r0,@r1
	mov	#'X',r0
	mov.w	r0,@(2,r1)
	mov	#'T',r0
	mov.w	r0,@(4,r1)
	fw	D_FOPEN
	tst	r0,r0
	bf	2f
	bra	c4_ret
	nop
2:	mov.l	r0,@(TP_FH,r9)
	mov	#0,r12
	mov	#40,r13
c4_lp:	mov.l	@(TP_FH,r9),r4
	mov	r12,r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4
	mov	#1,r5
	mov	#12,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov	#12,r1
	cmp/eq	r1,r0
	bf	c4_eof
	mov.l	@(4,r11),r1
	swap.b	r1,r1
	swap.w	r1,r1
	swap.b	r1,r1
	mov.l	@(8,r11),r2
	swap.b	r2,r2
	swap.w	r2,r2
	swap.b	r2,r2
	tst	r12,r12
	bf	2f
	bra	c4_nx
	mov	r1,r12			! the PMAI file header: skip it
2:	mov.l	@r11,r0
	mov.l	c4_tag,r3
	cmp/eq	r3,r0
	bt	c4_hit
	tst	r2,r2
	bt	c4_eof
	add	r2,r12
c4_nx:	dt	r13
	bf	c4_lp
	bra	c4_eof
	nop
c4_hit:	mov.w	c4_cap,r0
	sub	r10,r0			! room left
	mov	r2,r3
	cmp/hi	r0,r3
	bf	1f
	mov	r0,r3			! cut to it
1:	tst	r3,r3
	bt	c4_eof
	mov.l	r3,@-r15
	mov.l	@(TP_FH,r9),r4
	mov	r12,r5
	mov	#0,r6
	fw	D_FSEEK
	mov.l	c4_dst,r4
	add	r10,r4
	mov	#1,r5
	mov.l	@r15,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov.l	@r15+,r1
	cmp/eq	r1,r0
	bf	c4_cls			! a short read: no result (retried)
	add	r1,r10
	add	#1,r14
	mov.l	@(8,r11),r2		! the tag's own length: the next tag
	swap.b	r2,r2
	swap.w	r2,r2
	swap.b	r2,r2
	add	r2,r12
	mov	r14,r0
	cmp/eq	#2,r0			! both found
	bt	c4_eof
	bra	c4_nx
	nop
c4_eof:	mov.l	cp_ctl,r1
	mov	#1,r0
	mov.l	r0,@(CC_OK,r1)
c4_cls:	mov.l	@(TP_FH,r9),r4
	fw	D_FCLOSE
c4_ret:	lds.l	@r15+,pr
	rts
	nop
c4_bap:		.word B_APATH
c4_cap:		.word TITL_OFF - 16	! V4n24: the title record behind (was 4096)
	.p2align 2
c4_tag:		.ascii	"PCO2"
c4_dst:		.long RAMB+0x14010
cp_ctl:		.long RAMB+0x15010
cp_buf:		.long RAMB+0x14000
cp_mag:		.ascii	"PCO2"

! rq_get: r4 / r5 = the own deck's loaded track (+0x28 source player | slot << 8 | type << 16, +0x2C rbid).
! The own status packet is only filled once the LINK is up (empty in the emu / USB-only): then the MAIN
! status table's entry of the own player (0x0A371D3C + (n-1) * 0x124, same +0x28 / +0x2C fields) answers.
! Clobbers r0-r2.
rq_get:
	mov.l	rq_st,r1		! V4n22: the status table entry FIRST (verified path, also with a LINK
	mov.l	@(0x28,r1),r4		!   cable); the packet's words stay the answer when the entry is not ours
	mov.l	@(0x2C,r1),r5
	swap.b	r5,r5			! V4n25 (deck netlog RC1: CC_RB 0x02000000): the packet's rbid is
	swap.w	r5,r5			!   big-endian (network order) -- the table entry's is native
	swap.b	r5,r5
	mov.l	rq_own,r0
	mov.l	@r0,r0
	tst	r0,r0
	bf	2f
	mov	#1,r0			! no number before the LINK: player 1's entry
2:	mov	r0,r2
	add	#-1,r0
	mov	#0x24,r1		! * 0x124 = (n-1) << 8 + (n-1) * 0x24
	mulu.w	r0,r1
	sts	macl,r1
	shll8	r0
	add	r0,r1
	mov.l	rq_tab,r0
	add	r0,r1
	mov.l	@(0x28,r1),r0
	extu.b	r0,r0
	cmp/eq	r2,r0			! the entry belongs to the own player
	bf	1f
	mov.l	@(0x28,r1),r4
	mov.l	@(0x2C,r1),r5
1:	rts
	nop
	.p2align 2
rq_own:		.long 0x0A35F680
rq_tab:		.long 0x0A371D3C

! rv_cue (V4b1, from row_waves' tail, r9 = TP state): the deck's own loaded track changed (status +0x28 /
! +0x2C, as lc_onload): an empty cue block for the new rbid is published at once (the display drops the old
! cues), then its PCO2 tags are fetched -- the track's export.pdb row (tp_resolve, TP_RW = -2: tr_found ->
! tr_cue) when it is on the index's medium, retried while the index is not ready (at most 20 lookups).
! Never during a preview (D_PREVIEW) nor outside a normal boot. Ends in rv_mkey.
rv_cue:
	mov.l	rq_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	rc_x
	ld	r1,D_PREVIEW
	tst	r1,r1
	bf	rc_x
	mov.l	rq_ctl,r3
	bsr	rq_get
	nop
	mov.l	@(CC_KEY,r3),r0
	cmp/eq	r4,r0
	bf	rc_new
	mov.l	@(CC_RB,r3),r0
	cmp/eq	r5,r0
	bf	rc_new
	mov.l	@(CC_STATE,r3),r0
	tst	r0,r0
	bt	rc_x
	cmp/eq	#2,r0			! V4n24: only the artwork left (the JPU was busy): one try a second
	bf	rc_go
	mov.l	rq_arc,r1
	mov.l	@(AR_T,r1),r1
	mov.l	@(D_TICK,r8),r0
	mov.l	@r0,r0
	sub	r1,r0
	mov.w	rq_1s,r1
	cmp/hs	r1,r0
	bt	rc_go
	bra	rc_x
	nop
rc_new:	mov.l	r4,@(CC_KEY,r3)
	mov.l	r5,@(CC_RB,r3)
	mov	#0,r0
	mov.l	r0,@(CC_TRY,r3)
	mov.l	r0,@(CC_OK,r3)
	mov	#1,r0
	mov.l	r0,@(CC_STATE,r3)
	bsr	cue_pub
	mov	#0,r10
	mov.l	rq_arc,r1		! G2: an empty artwork block at once; the decode follows with the row lookup
	mov	#5,r0			! V4n24: 5 tries (JPU busy), the software image not out yet
	mov.l	r0,@(AR_STATE,r1)
	bsr	ar_pub
	mov	#0,r10
rc_go:	bsr	rq_get
	nop
	tst	r5,r5
	bt	rc_done
	mov	r4,r0
	shlr16	r0
	extu.b	r0,r0
	cmp/eq	#1,r0			! a rekordbox track
	bf	rc_done
	mov	r4,r0			! its medium: source player << 8 | slot (rv_mkey's key)
	shlr8	r0
	extu.b	r0,r2			! the slot
	extu.b	r4,r4
	shll8	r4
	mova	rq_ck,r0
	mov.l	@r0,r1
	add	r0,r1			! canon_key
	jsr	@r1
	or	r2,r4
	mov.l	rq_med,r1
	mov.l	@r1,r0
	cmp/eq	r4,r0
	bf	rc_x			! not the index's medium (yet): later
	mov	#TP_XS,r0
	mov.l	@(r0,r9),r0
	cmp/eq	#2,r0
	bf	rc_x			! the index not ready
	mov.l	rq_ctl,r3
	mov.l	@(CC_TRY,r3),r0
	add	#1,r0
	mov.l	r0,@(CC_TRY,r3)
	mov	#20,r1
	cmp/hi	r1,r0
	bt	rc_done
	bsr	rq_get
	nop
	mov	#TP_RW,r0
	mov	#-2,r1
	mov.l	r1,@(r0,r9)
	mov	r5,r4
	mova	rq_tp,r0
	mov.l	@r0,r1
	add	r0,r1			! tp_resolve
	jsr	@r1
	nop
	mov	#TP_RW,r0
	mov	#0,r1
	mov.l	r1,@(r0,r9)
	bra	rc_x
	nop
rc_done: mov.l	rq_ctl,r3
	mov	#0,r0
	mov.l	r0,@(CC_STATE,r3)
rc_x:	mova	rq_mk,r0
	mov.l	@r0,r1
	add	r0,r1
	jmp	@r1			! rv_mkey
	nop
	.p2align 2
rq_1s:		.word 1000
	.p2align 2
rq_boot:	.long 0x0A35DF3C
rq_ctl:		.long RAMB+0x15010
rq_arc:		.long RAMB+0x15030
rq_st:		.long 0x0B53D828
rq_med:		.long MED
rq_tp:		.long tp_resolve - rq_tp
rq_ck:		.long canon_key - rq_ck
rq_mk:		.long rv_mkey - rq_mk


! ---------------------------------------------------------------------------
! V4n31 (#34) w8n: the TEMPO MASTER's waveform read straight from its medium. A CDJ-3000's dbserver
! answers w8fetch's PWV5 / PWV7 tag requests empty; the firmware mounts every LINKed player's media over
! NFS (D:..Z:, the mount Link Cue plays from), so the master's ANLZ file is read like a row's: its
! rekordbox id -> export.pdb row (tp_resolve on the master's medium, TP_RW = -3) -> ANLZ path (string 14)
! -> .EXT: PQT2 (the grid) + PWV5. The blocks are made as w8cap's reply (PWV5 record: +0 n, +4 n * 2,
! entries u16 BE from +20; grid: [u32][the PQT2 tag]) and handed to w8send through W8N (w8.inc: w8send
! asks SEQ / KEY / RB and takes CON; here JOB, then RES / PTR / GPTR and ANS last; one at a time).
! Runs in TchAud's row_waves pass (TchDec already out of the file layer: q_quiet), only on a normal
! boot, never while a preview streams; the DB task never touches NFS (w8send gives up after 60 s).
	.equ	W8N, RAMB+0x1E080
	.equ	N_SEQ, 0
	.equ	N_KEY, 4
	.equ	N_RB, 8
	.equ	N_ANS, 12
	.equ	N_RES, 16
	.equ	N_PTR, 20
	.equ	N_GPTR, 24
	.equ	N_CON, 28
	.equ	N_JOB, 36
	.equ	N_TRY, 40
	.equ	N_DIAG, 44

	.macro	fcall lit
	mova	\lit,r0
	mov.l	@r0,r1
	add	r0,r1
	jsr	@r1
	nop
	.endm

! w8n_step (from row_waves' rv_out; r8 = data, r9 = TP state; r10-r14 free, row_waves restores them):
! an open request (and the last answer taken) -> the master's medium (source player << 8 | slot,
! canonical). Not mounted (CD, rekordbox, gone): answered empty. Not the index's medium: made current
! (set_medium; the index builds in the next passes) -- but never while an index builds, a list / INFO
! shows (pre_medium owns the medium there) or rv_cue still needs the index's medium for the loaded
! track: it waits. The index's medium: the id looked up (tp_resolve, TP_RW = -3 -> tr_w8n), 20 at most.
ws_xe:	lds.l	@r15+,pr		! (w8n_step's exit, in reach of its first branches)
	rts
	nop
w8n_step:
	sts.l	pr,@-r15
	mov.l	wn_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	ws_xe
	ld	r0,D_PREVIEW
	tst	r0,r0
	bf	ws_xe
	mov.l	wn_w8s,r1
	mov.l	@r1,r0
	mov.l	wn_w8m,r2
	cmp/eq	r2,r0			! w8send runs ('W8F1': W8N zeroed)
	bf	ws_xe
	mov.l	wn_nb,r12		! r12 = W8N
	mov.l	@(N_SEQ,r12),r10
	mov.l	@(N_ANS,r12),r0
	cmp/eq	r10,r0
	bt	ws_xe			! nothing asked
	mov.l	@(N_CON,r12),r1
	cmp/eq	r1,r0
	bf	ws_xe			! the last answer not taken yet
	mov.l	@(N_JOB,r12),r0
	cmp/eq	r10,r0
	bt	1f
	mov.l	r10,@(N_JOB,r12)	! a new request
	mov	#0,r0
	mov.l	r0,@(N_TRY,r12)
	mov.l	r0,@(N_DIAG,r12)
1:	mov.l	@(N_KEY,r12),r4
	tst	r4,r4
	bt	ws_fail			! cancelled
	mov	r4,r0			! its medium: source player << 8 | slot
	shlr8	r0
	extu.b	r0,r0
	extu.b	r4,r4
	shll8	r4
	or	r0,r4
	fcall	wn_ckl			! canon_key
	mov	r4,r11			! r11 = the medium
	fcall	wn_mll			! medium_letter
	tst	r0,r0
	bt	ws_fail			! not mounted
	mov.l	wn_med,r1
	mov.l	@r1,r0
	cmp/eq	r11,r0
	bt	ws_same
	mov	#TP_XS,r0		! another medium: not while an index builds
	mov.l	@(r0,r9),r0
	cmp/eq	#2,r0
	bt	2f
	cmp/eq	#3,r0
	bt	2f
	mov.l	wn_med,r1
	mov.l	@r1,r0
	tst	r0,r0
	bf	ws_x
2:	mov.l	wn_info,r1		! nor while a list (1) / INFO (2) shows
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bt	ws_x
	cmp/eq	#2,r0
	bt	ws_x
	mov.l	wn_cc,r1		! nor while rv_cue reads the loaded track's cues from the index's medium
	mov.l	@(CC_STATE,r1),r0
	tst	r0,r0
	bt	3f
	mov.l	@(CC_KEY,r1),r4
	mov	r4,r0
	shlr8	r0
	extu.b	r0,r0
	extu.b	r4,r4
	shll8	r4
	or	r0,r4
	fcall	wn_ckl
	mov.l	wn_med,r1
	mov.l	@r1,r0
	cmp/eq	r4,r0
	bt	ws_x
3:	mov.l	@(N_DIAG,r12),r0
	or	#2,r0
	mov.l	r0,@(N_DIAG,r12)
	mov	r11,r4
	fcall	wn_sml			! set_medium: the index is rebuilt for it
	bra	ws_x
	nop
ws_same:
	mov	#TP_XS,r0
	mov.l	@(r0,r9),r0
	cmp/eq	#2,r0
	bt	3f
	cmp/eq	#3,r0
	bf	ws_x			! the index still building
3:	mov.l	@(N_TRY,r12),r0
	add	#1,r0
	mov.l	r0,@(N_TRY,r12)
	mov	#20,r1
	cmp/hi	r1,r0
	bt	ws_fail			! not found
	mov	#TP_RW,r0
	mov	#-3,r1
	mov.l	r1,@(r0,r9)
	mov.l	@(N_RB,r12),r4
	fcall	wn_tpl			! tp_resolve -> tr_w8n when the row is found
	mov	#TP_RW,r0
	mov	#0,r1
	mov.l	r1,@(r0,r9)
	bra	ws_x
	nop
ws_fail:
	mov.l	wn_nb,r1
	mov.l	@(N_DIAG,r1),r0
	or	#0x80,r0
	mov.l	r0,@(N_DIAG,r1)
	mov	#0,r0
	mov.l	r0,@(N_PTR,r1)
	mov.l	r0,@(N_GPTR,r1)
	mov	#2,r0
	mov.l	r0,@(N_RES,r1)
	mov.l	@(N_JOB,r1),r0
	mov.l	r0,@(N_ANS,r1)
ws_x:	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
wn_boot:	.long 0x0A35DF3C	! MAIN boot state (1 = normal boot)
wn_w8s:		.long RAMB+0x1E000	! W8S
wn_w8m:		.long 0x31463857	! 'W8F1'
wn_nb:		.long W8N
wn_med:		.long MED
wn_info:	.long 0x0A35F3CC	! display mode: 1 browse list, 2 INFO
wn_cc:		.long RAMB+0x15010	! the cue block control (rv_cue)
wn_ckl:		.long canon_key - wn_ckl
wn_mll:		.long medium_letter - wn_mll
wn_sml:		.long set_medium - wn_sml
wn_tpl:		.long tp_resolve - wn_tpl

! tr_w8n (tp_resolve's tr_found for TP_RW = -3; r14 = the row in the page buffer r11, r9 = TP state;
! tp_resolve's pr on the stack): ANLZ path -> B_APATH, made .EXT; its tags walked (wn_walk) -> the PQT2
! tag into a grid block, the PWV5 entries into a record. Answered (W8N): RES 1 with the record (+ grid
! or 0), or RES 2 when the file holds no PWV5. No .EXT open / a short read answers nothing (blocks
! freed): the next pass tries again (N_TRY). N_DIAG bits: 1 entered, 2 medium switched, 4 .EXT open,
! 8 grid read, 0x10 PWV5 read, 0x40 answered with data, 0x80 answered empty, 0x100 a read failed.
tr_w8n:
	mov	#1,r4
	bsr	wn_dg
	nop
	mov	r14,r4			! ANLZ path (string 14) -> B_APATH
	mov	#14,r5
	ld	r6,D_BUF
	mov.l	wn_bap,r0
	add	r0,r6
	fcall	wn_tsl			! tr_str
	mov	r11,r14
	mov.l	wn_100,r0
	add	r0,r14			! r14 = wn_walk's results (the row is done with)
	mov	#0,r10			! r10 = the PWV5 record
	mov	#0,r12			! r12 = the grid block
	ld	r1,D_BUF		! .DAT -> .EXT (B_APATH's last three characters)
	mov.l	wn_bap,r0
	add	r0,r1
1:	mov.w	@r1+,r0
	tst	r0,r0
	bf	1b
	add	#-8,r1
	mov	#'E',r0
	mov.w	r0,@r1
	mov	#'X',r0
	mov.w	r0,@(2,r1)
	mov	#'T',r0
	mov.w	r0,@(4,r1)
	bsr	wn_walk
	nop
	tst	r0,r0
	bf	1f
	bra	wn_out			! no .EXT open (NFS hiccup?): again next pass
	nop
1:
	mov	#4,r4
	bsr	wn_dg
	nop
	mov.l	@(20,r14),r13		! the PQT2 tag's length
	tst	r13,r13
	bt	2f
	mov.l	wn_gmax,r0		! (w8send streams at most 0x7FFC of it)
	cmp/hi	r0,r13
	bf	1f
	mov	r0,r13
1:	mov	r13,r4
	bsr	wn_alloc
	add	#4,r4
	tst	r0,r0
	bt	2f
	mov	r0,r12
	mov	#0,r1
	mov.l	r1,@r12
	mov.l	@(TP_FH,r9),r4
	mov.l	@(16,r14),r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r12,r4
	add	#4,r4
	bsr	wn_read
	mov	r13,r6
	tst	r0,r0
	bt	wn_rerr
	mov	#8,r4
	bsr	wn_dg
	nop
2:	mov.l	@r14,r0			! PWV5?
	tst	r0,r0
	bt	wn_cls
	mov.l	@(TP_FH,r9),r4		! its head: 'PWV5', header len, tag len, entry bytes, n
	mov.l	@r14,r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4
	bsr	wn_read
	mov	#20,r6
	tst	r0,r0
	bt	wn_rerr
	mov.l	@(16,r11),r13		! n (BE)
	swap.b	r13,r13
	swap.w	r13,r13
	swap.b	r13,r13
	mov.l	wn_nmax,r0		! the display keeps 0x30000 entries: the rest is cut
	cmp/hi	r0,r13
	bf	1f
	mov	r0,r13
1:	mov.l	@(8,r14),r1		! never past the tag: n <= (tag len - header len) / 2
	mov.l	@(4,r14),r2
	sub	r2,r1
	shlr	r1
	cmp/hi	r1,r13
	bf	1f
	mov	r1,r13
1:	tst	r13,r13
	bt	wn_cls
	mov	r13,r4
	add	r4,r4
	bsr	wn_alloc
	add	#20,r4
	tst	r0,r0
	bt	wn_cls			! no memory: no waveform
	mov	r0,r10
	mov.l	r13,@r10		! n, n * 2 (what w8send reads), 2, 150, 0
	mov	r13,r0
	add	r0,r0
	mov.l	r0,@(4,r10)
	mov	#2,r0
	mov.l	r0,@(8,r10)
	mov	#150,r0
	extu.b	r0,r0
	mov.l	r0,@(12,r10)
	mov	#0,r0
	mov.l	r0,@(16,r10)
	mov.l	@(TP_FH,r9),r4		! the entries
	mov.l	@r14,r5
	mov.l	@(4,r14),r0
	add	r0,r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r10,r4
	add	#20,r4
	mov	r13,r6
	bsr	wn_read
	add	r6,r6
	tst	r0,r0
	bt	wn_rerr
	mov	#0x10,r4
	bsr	wn_dg
	nop
wn_cls:	mov.l	@(TP_FH,r9),r4
	fw	D_FCLOSE
	mov.l	wn_nb2,r1
	tst	r10,r10
	bf	wn_ok
	mov	r12,r4			! no PWV5: answered empty
	bsr	wn_free
	mov	#0,r12
	mov	#0x80,r4
	bsr	wn_dg
	extu.b	r4,r4
	mov.l	wn_nb2,r1
	bra	wn_ans
	mov	#2,r0
wn_ok:	mov	#0x40,r4
	bsr	wn_dg
	nop
	mov	#1,r0
wn_ans:	mov.l	r10,@(N_PTR,r1)
	mov.l	r12,@(N_GPTR,r1)
	mov.l	r0,@(N_RES,r1)
	mov.l	@(N_JOB,r1),r0		! the answer, last
	bra	wn_out
	mov.l	r0,@(N_ANS,r1)
wn_rerr:
	mov.l	@(TP_FH,r9),r4		! a short read: nothing answered, again next pass
	fw	D_FCLOSE
	bsr	wn_free
	mov	r10,r4
	bsr	wn_free
	mov	r12,r4
	mov.l	wn_d100,r4
	bsr	wn_dg
	nop
wn_out:	lds.l	@r15+,pr		! (tr_out: tp_resolve's pr)
	rts
	nop

! wn_dg: N_DIAG |= r4. Clobbers r0, r1.
wn_dg:	mov.l	wn_nb2,r1
	mov.l	@(N_DIAG,r1),r0
	or	r4,r0
	rts
	mov.l	r0,@(N_DIAG,r1)

! wn_alloc: r0 = malloc(r4) (0: none). wn_free: free(r4) unless 0. Clobber r0-r7.
wn_alloc:
	mov.l	wn_malloc,r1
	bra	1f
	nop
wn_free:
	tst	r4,r4
	bt	2f
	mov.l	wn_freef,r1
1:	mov.l	@r8,r2
	sts	fpscr,r3
	and	r2,r3
	jmp	@r1
	lds	r3,fpscr
2:	rts
	nop

! wn_read: r4 = dst, r6 = bytes from the file TP_FH at its position, in as many freads as it takes
! (one NFS READ of 8 KB a call on the deck). r0 = 1 all read, 0 not (an error / the end). Clobbers r0-r7.
wn_read:
	sts.l	pr,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15
	mov	r4,r12
	mov	r6,r13
1:	tst	r13,r13
	bt	8f
	mov	r12,r4
	mov	#1,r5
	mov	r13,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	cmp/pl	r0
	bf	9f
	cmp/hi	r13,r0
	bt	9f
	add	r0,r12
	bra	1b
	sub	r0,r13
8:	bra	7f
	mov	#1,r0
9:	mov	#0,r0
7:	mov.l	@r15+,r13
	mov.l	@r15+,r12
	lds.l	@r15+,pr
	rts
	nop

! wn_walk: opens B_APATH (TP_FH) and walks its tags (40 at most) for PWV5 (r14: +0 offset, +4 header
! len, +8 tag len) and PQT2 (+16 offset, +20 tag len); 0 = not there. r0 = 1: the file is open (the
! caller closes it), 0: no file. r11 = scratch. Keeps r8-r14.
wn_walk:
	sts.l	pr,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15
	mov	#0,r0
	mov.l	r0,@r14
	mov.l	r0,@(4,r14)
	mov.l	r0,@(8,r14)
	mov.l	r0,@(16,r14)
	mov.l	r0,@(20,r14)
	ld	r4,D_BUF
	mov.l	wn_bap,r0
	add	r0,r4
	fw	D_FOPEN
	tst	r0,r0
	bt	wk_x
	mov.l	r0,@(TP_FH,r9)
	mov	#0,r12			! file offset
	mov	#40,r13			! tags, at most
wk_lp:	mov.l	@(TP_FH,r9),r4
	mov	r12,r5
	mov	#0,r6
	fw	D_FSEEK
	mov	r11,r4
	mov	#1,r5
	mov	#12,r6
	mov.l	@(TP_FH,r9),r7
	fw	D_FREAD
	mov	#12,r1
	cmp/eq	r1,r0
	bf	wk_end
	mov.l	@(4,r11),r1		! header length (BE)
	swap.b	r1,r1
	swap.w	r1,r1
	swap.b	r1,r1
	mov.l	@(8,r11),r2		! tag length (BE)
	swap.b	r2,r2
	swap.w	r2,r2
	swap.b	r2,r2
	tst	r12,r12
	bf	1f
	bra	wk_nx			! the PMAI file header: skip it
	mov	r1,r12
1:	mov.l	@r11,r0
	mov.l	wk_t5,r3
	cmp/eq	r3,r0
	bt	wk_w5
	mov.l	wk_tq,r3
	cmp/eq	r3,r0
	bf	wk_sk
	mov.l	r12,@(16,r14)
	bra	wk_sk
	mov.l	r2,@(20,r14)
wk_w5:	mov.l	r12,@r14
	mov.l	r1,@(4,r14)
	mov.l	r2,@(8,r14)
wk_sk:	tst	r2,r2
	bt	wk_end
	add	r2,r12			! next tag
wk_nx:	dt	r13
	bf	wk_lp
wk_end:	mov	#1,r0
wk_x:	mov.l	@r15+,r13
	mov.l	@r15+,r12
	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
wn_bap:		.long B_APATH
wn_100:		.long 0x100
wn_gmax:	.long 0x7FFC
wn_d100:	.long 0x100
wn_nb2:		.long W8N
wn_tsl:		.long tr_str - wn_tsl
wn_nmax:	.long 0x30000		! PWV5 entries the display keeps
wn_malloc:	.long 0x08344A9C
wn_freef:	.long 0x08344B42
wk_t5:		.ascii	"PWV5"
wk_tq:		.ascii	"PQT2"


.ifdef TESTHOOK
! test_hooks (TEST builds only: the `touchaudiot` variant, main_touchaudiot.s): once a loop pass,
! the autotest loader / life cycle (mods/autotest +8) and the USB HUD log (mods/usblog +0), each
! called with r4 = data, r5 = the autotest block pointer's address. patch_main.place_testhooks()
! puts the placed addresses into the three words below (0 = that mod is not in the build).
! r8 = data; keeps r8-r14.
test_hooks:
	sts.l	pr,@-r15
	mov.l	th_tl,r1		! V4n: UTILITY TEST LOG (mods/keyshift KSB+68: 0 OFF, 1 USB, 2 RED;
	mov	#1,r6			! no word in the build = USB): OFF -> neither hook runs
	tst	r1,r1
	bt	0f
	mov.l	@r1,r6
	tst	r6,r6
	bt	2f
0:	mov.l	r6,@-r15
	mov.l	th_at,r1
	tst	r1,r1
	bt	1f
	mov	r8,r4
	mov.l	th_atp,r5
	mov.l	@r8,r2			! (as fw, with the callee already in r1)
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
1:	mov.l	th_ul,r1
	tst	r1,r1
	bt	3f
	mov	r8,r4
	mov.l	@r15,r6			! the mode
	mov.l	th_atp,r5
	mov.l	@r8,r2			! (as fw, with the callee already in r1)
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
3:	add	#4,r15
2:	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
th_tl:		.long	0x7E57A703		! UTILITY TEST LOG word (0: none in the build)
th_at:		.long	0x7E57A700		! autotest +8 (at_tick)
th_ul:		.long	0x7E57A701		! usblog +0 (ul_tick)
th_atp:		.long	0x7E57A702		! autotest +12 (its block pointer)
.endif


	.p2align 2
data:
	.long	0xFFE7FFFF		! fpscr mask
	.long	0x085142D8		! acre_tsk
	.long	0x08514730		! sta_tsk
	.long	0x08518FD4		! dly_tsk
	.long	0x08233A22		! udp_vcre_cep
	.long	0x0823415E		! udp_rcv_dat
	.long	0x08233CF6		! udp_snd_dat
	.long	0x082C0D2A		! fopen
	.long	0x082C0D56		! fclose (0x082C0D34 is ftell)
	.long	0x082C0D3C		! fseek
	.long	0x082C0D44		! fread
	.long	0x0B0C5258		! 1 ms tick
	.long	0			! D_STATE
	.long	0			! D_TID
	.long	0			! D_CEP
	.long	0			! D_FH
	.long	0			! D_DOFF
	.long	0			! D_DLEN
	.long	0			! D_POS
	.long	0			! D_C
	.long	0			! D_DEADL
	.long	0			! D_NEXTST
	.long	0			! D_FIRST
	.long	0			! D_E
	.long	0			! D_T
	.long	0			! D_BUF
	.space	8			! D_PREVIEW + D_WASON
	.space	8			! D_EPA
	.space	8			! D_FROM
	.long	0, 0, 0, 0		! D_CCEP: atr, addr, port+pad, callback
	.long	0, 0, 0, 9, 4096, 0, 0	! D_CTSK
	.ascii	"TchAud\0\0"		! D_NAME
d_hdr:
	.byte	0x51, 0x73, 0x70, 0x74, 0x31, 0x57, 0x6d, 0x4a, 0x4f, 0x4c, 0x1e, 0x43
	.byte	0x44, 0x4a, 0x2d, 0x33, 0x30, 0x30, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00
	.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x11, 0x05, 0x48
	.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00

	.p2align 2
d_bcast:
	.long	0			! A9 ip (filled in the loop)
	.short	50000, 0
d_ka:
	.byte	0x51, 0x73, 0x70, 0x74, 0x31, 0x57, 0x6d, 0x4a, 0x4f, 0x4c, 0x06, 0x00
	.byte	0x43, 0x44, 0x4a, 0x2d, 0x33, 0x30, 0x30, 0x30, 0x00, 0x00, 0x00, 0x00
	.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x00, 0x00
	.byte	0x11, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0xa9, 0xfe, 0x00, 0x01
	.p2align 2
d_due:	.long	0			! D_DUE
	.long	0			! D_GAIN
	.long	0			! D_LDKEY
	.long	0			! D_LATCH
