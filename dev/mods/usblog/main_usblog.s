! SPDX-License-Identifier: Apache-2.0
!
! usblog, MAIN side (TEST builds only, opt-in: EXTRA_MODS=usblog): the GUI HUD's per-second
! records (mods/v2ui/usblog.inc, -DV2_USBLOG) appended to C:/V3HUD.BIN on the stick.
! Design: re/USB_LOG_DESIGN.md; this mod: re/AUTOTEST_USBLOG.md.
!
! Placed only (empty sig). The TchAud task (mods/touch_audio's TESTHOOK variant
! `touchaudiot`) calls +0 once per loop pass with r4 = touch_audio's data block and
! r5 = the address of mods/autotest's block pointer (0 when autotest is not in the build).
! TchAud exists only on a normal boot (*0x0A35DF3C == 1, checked here again): nothing of
! this runs in update mode.
!
! Opt-in by file: the log is written only when C:/V3HUD.BIN already exists (checked 4 s
! after each mount); only then the 64 KB ring is malloc'd (once). Every 250 ms the GUI's
! block in the received SPI frame (MAIN RX 0x09072B38 +0x800, uncached) is read; new
! checked records go into the ring, stamped with the autotest step / state / reason.
! Flush = ONE open("a") / write / close of everything pending, only with the deck not
! playing for >= 1 s (the heartbeat's elapsed word still), no preview streaming, and
! then once if the last flush predates the pause, else at most every 10 s (or with >= 256
! pending); while playing only a small one (29..31 pending, <= 4 KB, ~every 30 s) -- or
! at once when an autotest script ends (DONE / ABORT). V4g: every flush starts with a 'V3US'
! status record; a failed open retries (8 a mount) instead of switching off. Stops at 4 MB; a short write switches it off until reboot,
! a failed open until the next mount. The ring keeps the newest 512 records (drops counted).
!
! File: 128-byte records (32 LE words). GUI record: w0 seq, w1 GUI ms, w2..w27 HUD txt[0..25],
! w28 cpu %, w29 screen | model << 8, w30 the MAIN stamp (step | state << 16 | why << 24),
! w31 checksum. MAIN records: w0 'V3HB' boot, 'V3MK' step mark, 'V3AE' autotest end
! (tools: work/autotest/decode_usblog.py).

	.include "layout.inc"

	.equ	U_ON, 0			! writing allowed (file present on this mount)
	.equ	U_DEAD, 4		! off until reboot (short write / 4 MB)
	.equ	U_SIZE, 8		! bytes in the file
	.equ	U_WR, 12		! records added (monotonic)
	.equ	U_RD, 16		! records flushed / dropped
	.equ	U_DROP, 20		! records lost (ring full, GUI ring overrun)
	.equ	U_LAST, 24		! last GUI seq taken
	.equ	U_NEXT, 28		! tick of the next poll
	.equ	U_ELW, 32		! elapsed word last seen
	.equ	U_ELT, 36		! tick it last moved
	.equ	U_LASTF, 40		! tick of the last flush
	.equ	U_FORCE, 44		! flush now (autotest ended)
	.equ	U_PSTEP, 48		! autotest step last seen
	.equ	U_PST, 52		! autotest state last seen
	.equ	U_BOOTED, 56		! boot record written
	.equ	U_FLUSH, 60		! flushes
	.equ	U_SCR, 64		! one record of scratch (128 B)
	.equ	U_OFAIL, 192		! V4g: failed opens on this mount (beyond the @(disp) range: r0-indexed)
	.equ	U_DST, 200		! V4n RED: the datagrams' destination (ip host order, port, pad)
	.equ	U_CEP, 208		! V4n26 commander: its UDP endpoint (0 not yet)
	.equ	U_CCEP, 212		!   udp_vcre_cep's 16 B: atr, address, port | pad, callback
	.equ	U_CFROM, 228		!   the last sender (ip, port)
	.equ	U_PACK, 236		!   the last ACK seq reported ('V3CD')
	.equ	U_CTAIL, 240		!   the commander script's END: offset in the autotest block
	.equ	U_CPKT, 244		!   datagrams taken
	.equ	U_RING, 256		! 512 x 128 B
	.equ	U_NREC, 512
	.equ	U_CAP, 4 * 1024 * 1024
	.equ	HUD_MAGIC, 0x48554431	! "HUD1"
	.equ	U_CRX, U_RING + U_NREC * 128	! V4n26: the commander's receive buffer (after the ring)
	.equ	CRX_LEN, 512
	.equ	A_ACK, 156		! mods/autotest block: the last ACK op's seq (exec_op op 9)
	.equ	A_SRC, 160		!   'NETC' while its script is the commander's
	.equ	A_OPS, 208		!   OPS + 16: the first op
	.equ	A_LIM, 4048		!   OPS + OPS_MAX: the op area's end

	.macro	fcall reg
	mov	#0x18,r2
	shll16	r2
	not	r2,r2
	sts	fpscr,r3
	and	r2,r3
	jsr	@\reg
	lds	r3,fpscr
	.endm

	.text
	.global	usblog
usblog:
	bra	ul_tick			! +0  TchAud
	nop
ul_p:	.long	0			! +4  the block (malloc'd), 0 none
ul_nx:	.long	0			! +8  tick of the next mount check
ul_mnt:	.long	0			! +12 mount checks since the stick mounted
	bra	hg_hook			! +16 V4n36 trace (#51): MAIN gui_comm's RX-slot memset literal 0x0838EAEC
	nop				!     points here (patch_main place_hudgrab)

! r4 = touch_audio data, r5 = &autotest block pointer (or 0), r6 = UTILITY TEST LOG (1 USB, 2 RED;
! test_hooks does not call with OFF)
ul_tick:
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15
	mov.l	r14,@-r15
	sts.l	pr,@-r15
	mov.l	ut_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	ut_out
	mov.l	ut_tick,r1
	mov.l	@r1,r9			! r9 = now
	mov	r4,r12			! r12 = touch_audio data
	mov	r5,r13			! r13 = &autotest pointer (0 none)
	mova	ut_base,r0
	mov.l	@r0,r10
	add	r0,r10			! r10 = the blob
	mov.l	@(4,r10),r8		! r8 = the block (0 none)
	mov	r6,r0			! V4n: TEST LOG = RED -> the records over the network, no stick
	cmp/eq	#2,r0
	bf	ut_usbm
	tst	r8,r8
	bf	un_poll
	mov.l	ut_blk,r4		! the block, once (no file needed)
	mov.l	ut_malloc,r1
	fcall	r1
	tst	r0,r0
	bt	ut_out
	mov	r0,r8
	mov.l	r8,@(4,r10)
	mov	r8,r1			! CMDFIX: the WHOLE block cleared (k_malloc does not clear; on the deck the
	mov.l	ut_blkw,r2		!   receive buffer kept a previous boot's datagram across a warm reboot)
	mov	#0,r0
6:	mov.l	r0,@r1
	dt	r2
	bf/s	6b
	add	#4,r1
un_poll:
	mov.l	@(U_BOOTED,r8),r0	! V4n36 trace: the 'V3HB' boot record (build ID) first, once per boot
	tst	r0,r0
	bf	un_bok
	mov	#-1,r14			! no file
	mov	#2,r7			! TEST LOG = RED
	bsr	boot_rec
	nop
un_bok:	mov.l	@(U_NEXT,r8),r1		! every 250 ms: the GUI's records in, the autotest marks
	mov	r9,r0
	sub	r1,r0
	cmp/pz	r0
	bf	ut_out
	mov.w	ut_250,r0
	add	r9,r0
	mov.l	r0,@(U_NEXT,r8)
	bsr	gui_take
	nop
	bsr	hg_take			! V4n36 trace (#51): the record hg_hook caught before MAIN cleared its slot
	nop
	bsr	at_watch
	nop
	bsr	cmd_poll		! V4n26: the network commander (UDP 50098)
	nop
	mov.l	@(U_FORCE,r8),r0	! out once a second (or at once when an autotest ends)
	tst	r0,r0
	bf	1f
	mov.l	@(U_LASTF,r8),r1
	mov	r9,r0
	sub	r1,r0
	mov.w	ut_1000,r1
	cmp/hs	r1,r0
	bf	ut_out
1:	bsr	us_rec			! V4n24: a 'V3US' record (logger + artwork / cue / title state) a second
	nop
	bsr	net_flush
	nop
	bra	ut_out
	nop
ut_usbm:

	mov.l	@(8,r10),r1		! ---- every 2 s: the stick
	mov	r9,r0
	sub	r1,r0
	cmp/pz	r0
	bf	ut_poll
	mov.w	ut_2000,r0
	add	r9,r0
	mov.l	r0,@(8,r10)
	mov.l	ut_usb,r1
	mov.l	@r1,r0
	cmp/eq	#3,r0
	bt	1f
	mov	#0,r0			! not mounted: check again on the next mount
	mov.l	r0,@(12,r10)
	tst	r8,r8
	bt	ut_poll
	bra	ut_poll
	mov.l	r0,@(U_ON,r8)
1:	mov.l	@(12,r10),r0
	cmp/eq	#4,r0
	bt	ut_poll			! checked on this mount
	add	#1,r0
	mov.l	r0,@(12,r10)
	cmp/eq	#3,r0
	bt	2f
	cmp/eq	#4,r0
	bf	ut_poll
2:	tst	r8,r8
	bt	3f
	mov.l	@(U_DEAD,r8),r0
	tst	r0,r0
	bf	ut_poll
3:	mova	ut_path,r0		! C:/V3HUD.BIN there?
	mov	r0,r4
	mov.l	ut_fopen,r1
	fcall	r1
	tst	r0,r0
	bt	ut_poll
	mov	r0,r11			! r11 = handle
	mov	#4,r0
	mov.l	r0,@(12,r10)
	mov	r11,r4			! its size: fseek(fh, 0, END), ftell(fh)
	mov	#0,r5
	mov	#2,r6
	mov.l	ut_fseek,r1
	fcall	r1
	mov	r11,r4
	mov.l	ut_ftell,r1
	fcall	r1
	mov	r0,r14			! r14 = size
	mov	r11,r4
	mov.l	ut_fclose,r1
	fcall	r1
	cmp/pz	r14
	bt	4f
	mov	#0,r14
4:	tst	r8,r8
	bf	5f
	mov.l	ut_blk,r4		! the block, once: control + 64 KB ring
	mov.l	ut_malloc,r1
	fcall	r1
	tst	r0,r0
	bt	ut_poll
	mov	r0,r8
	mov.l	r8,@(4,r10)
	mov	r8,r1			! CMDFIX: the whole block cleared (was: the control words)
	mov.l	ut_blkw,r2
	mov	#0,r0
6:	mov.l	r0,@r1
	dt	r2
	bf/s	6b
	add	#4,r1
5:	mov.l	r14,@(U_SIZE,r8)
	mov	#U_OFAIL / 2,r0		! V4g: open retries again on this mount
	shll	r0
	mov	#0,r1
	mov.l	r1,@(r0,r8)
	mov	#1,r0
	mov.l	r0,@(U_ON,r8)
	mov.l	@(U_BOOTED,r8),r0	! the boot record, once per boot
	tst	r0,r0
	bf	ut_poll
	mov	#1,r7			! V4n36 trace: boot_rec (TEST LOG = USB; r14 = the file size)
	bsr	boot_rec
	nop

ut_poll:
	tst	r8,r8
	bt	ut_out
	mov.l	@(U_NEXT,r8),r1		! ---- every 250 ms
	mov	r9,r0
	sub	r1,r0
	cmp/pz	r0
	bf	ut_out
	mov.w	ut_250,r0
	add	r9,r0
	mov.l	r0,@(U_NEXT,r8)
	bsr	gui_take		! the GUI's new records into the ring
	nop
	bsr	hg_take			! V4n36 trace (#51): + the one hg_hook caught
	nop
	bsr	at_watch		! autotest marks / end
	nop
	mov.l	ut_el,r1		! playing: the heartbeat's elapsed word moves
	mov.l	@r1,r0
	mov.l	@(U_ELW,r8),r1
	cmp/eq	r0,r1
	bt	1f
	mov.l	r0,@(U_ELW,r8)
	mov.l	r9,@(U_ELT,r8)
1:	mov.l	@(U_ON,r8),r0
	tst	r0,r0
	bt	ut_out
	mov.l	@(U_WR,r8),r0
	mov.l	@(U_RD,r8),r1
	sub	r1,r0
	tst	r0,r0
	bt	ut_out			! nothing pending
	mov	r0,r14			! r14 = pending
	mov.l	@(U_FORCE,r8),r0
	tst	r0,r0
	bf	ut_flush
	mov.l	@(U_ELT,r8),r1		! V4g: not playing for 1 s (was 2 s) -> the rules below; playing:
	mov	r9,r0			! only a small write, 29..31 pending (+ the status record: <= 4 KB,
	sub	r1,r0			! ~every 30 s at one GUI record a second)
	mov.w	ut_1000,r1
	cmp/hs	r1,r0
	bt	3f
	mov	#29,r0
	cmp/hs	r0,r14
	bf	ut_out
	mov	#32,r0
	cmp/hs	r0,r14
	bt	ut_out
3:	mov	#104,r0			! no Link Cue preview streaming (D_PREVIEW)
	mov.l	@(r0,r12),r0
	tst	r0,r0
	bf	ut_out
	mov.l	ut_pv,r1		! no row preview (MED+64 "PV" | bit 14)
	mov.l	@r1,r0
	mov	r0,r1
	shlr16	r1
	mov.w	ut_pvm,r2
	cmp/eq	r2,r1
	bf	2f
	mov.w	ut_b14,r1
	tst	r1,r0
	bf	ut_out
2:	mov.w	ut_256,r0		! at most every 10 s, unless the ring fills
	cmp/hs	r0,r14
	bt	ut_flush
	mov.l	@(U_LASTF,r8),r0	! V4g: ... or the last flush was before this pause / play stretch
	mov.l	@(U_ELT,r8),r1		! began (a pause flushes ~1 s in, then every 10 s)
	sub	r1,r0
	cmp/pz	r0
	bf	ut_flush
	mov.l	@(U_LASTF,r8),r1
	mov	r9,r0
	sub	r1,r0
	mov.w	ut_10000,r1
	cmp/hs	r1,r0
	bf	ut_out
ut_flush:
	bsr	flush
	nop
ut_out:
	lds.l	@r15+,pr
	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	rts
	mov.l	@r15+,r8
ut_2000:	.word	2000
ut_1000:	.word	1000
ut_250:		.word	250
ut_256:		.word	256
ut_10000:	.word	10000
ut_pvm:		.word	0x5056
ut_b14:		.word	0x4000
	.p2align 2
ut_base:	.long	usblog - ut_base
ut_boot:	.long	0x0A35DF3C
ut_tick:	.long	0x0B0C5258
ut_usb:		.long	0x0A35F3AC
ut_el:		.long	0x0B568C9C + 0x78	! the heartbeat block's elapsed word
ut_pv:		.long	RAMB+0x1F700+64		! touch_audio MED+64: row preview
ut_blk:		.long	U_RING + U_NREC * 128 + CRX_LEN
ut_blkw:	.long	(U_RING + U_NREC * 128 + CRX_LEN) / 4	! CMDFIX: in words
ut_malloc:	.long	0x08344A9C
ut_fopen:	.long	0x082C0D2A		! thunks (mode "r", tag 0xA80EB5B8)
ut_fseek:	.long	0x082C0D3C
ut_ftell:	.long	0x082C0D34
ut_fclose:	.long	0x082C0D56
ut_path:	.short	'C', ':', '/', 'V', '3', 'H', 'U', 'D', '.', 'B', 'I', 'N', 0
	.p2align 2

! net_flush (V4n, TEST LOG = RED): every pending record (at most 16 a call) as its own 128-byte UDP
! datagram from TchAud's endpoint to the LINK subnet's broadcast (169.254/16 -> x.x.255.255, else
! x.x.x.255), port 50099 -- exactly the file's records, so the Mac's listener only appends them
! (work/autotest/netlog.py) and decode_usblog.py reads the result. No address yet, no endpoint, or a
! failed send: they stay pending. r8 = block, r9 = now, r12 = touch_audio data. Clobbers r0-r7, r11, r14.
net_flush:
	sts.l	pr,@-r15
	mov.l	@(56,r12),r0		! touch_audio D_CEP
	tst	r0,r0
	bt	9f
	add	#-16,r15		! own IP: getter(0, buf16) -> buf+4 (host order)
	mov.l	un_getip,r1
	mov	r15,r5
	jsr	@r1
	mov	#0,r4
	mov.l	@(4,r15),r1
	add	#16,r15
	tst	r0,r0
	bf	9f
	tst	r1,r1
	bt	9f
	mov	r1,r0
	shlr16	r0
	mov.w	un_lla,r2
	extu.w	r2,r2
	cmp/eq	r2,r0
	bf	1f
	mov	#-1,r2
	extu.w	r2,r2
	bra	2f
	or	r2,r1
1:	mov	r1,r0
	or	#0xFF,r0
	mov	r0,r1
2:	mov	#U_DST / 2,r0
	shll	r0
	mov.l	r1,@(r0,r8)
	mov.w	un_port,r2
	add	#4,r0
	mov.w	r2,@(r0,r8)
	mov	#16,r14			! r14 = datagrams left this call
3:	mov.l	@(U_WR,r8),r0
	mov.l	@(U_RD,r8),r11		! r11 = the next record's number
	cmp/eq	r0,r11
	bt	8f
	mov.w	un_mask,r6		! src = ring + (RD & 511) * 128
	and	r11,r6
	shll8	r6
	shlr	r6
	mov.w	un_ring,r0
	add	r0,r6
	add	r8,r6
	mov	#-1,r0			! TMO_FEVR (as touch_audio's sends)
	mov.l	r0,@-r15
	mov.l	@(56,r12),r4
	mov	r8,r5
	mov	#U_DST / 2,r0
	shll	r0
	add	r0,r5
	mov	#64,r7
	shll	r7			! 128
	mov.l	un_snd,r1
	fcall	r1
	add	#4,r15
	cmp/pz	r0
	bf	8f			! failed: stays pending
	add	#1,r11
	mov.l	r11,@(U_RD,r8)
	dt	r14
	bf	3b
8:	mov.l	r9,@(U_LASTF,r8)
	mov	#0,r0
	mov.l	r0,@(U_FORCE,r8)
	mov.l	@(U_FLUSH,r8),r0
	add	#1,r0
	mov.l	r0,@(U_FLUSH,r8)
9:	lds.l	@r15+,pr
	rts
	nop
un_lla:		.word	0xA9FE
un_port:	.word	50099
un_mask:	.word	U_NREC - 1
un_ring:	.word	U_RING
	.p2align 2
un_getip:	.long	0x08221D9E		! own IPv4 getter
un_snd:		.long	0x08233CF6		! udp_snd_dat

! ---------------------------------------------------------------- commander (V4n26) ----
! cmd_poll (TEST LOG = RED only; ul_tick has checked *0x0A35DF3C == 1): the network commander.
! An own UDP endpoint on 50098 (created once, udp_vcre_cep like touch_audio's 50004; retried each
! poll until it exists), polled with TMO_POL from this same TchAud pass (no task, no wait): at most
! 4 datagrams a poll. Datagram: 'ATC1', u32 seq, u16 ops (<= 60), u16 byte sum of the ops, then the
! ops in SCRIPT.BIN's 8-byte encoding (work/autotest/cmd.py). MEM (8: b = len 1..64, c = addr) is
! answered at once with a 'V3MM' record; END / unknown ops are dropped; the rest go to the autotest
! block (cmd_pkt). Then the autotest's ACK word: a new value -> a 'V3CD' record (that datagram's ops
! all ran). Every record goes out by net_flush in this same poll (U_FORCE). r8 = block, r9 = now,
! r13 = &autotest pointer. Clobbers r0-r7, r11.
cmd_poll:
	sts.l	pr,@-r15
	mov.l	r14,@-r15
	mov.w	cm_cep,r0
	mov.l	@(r0,r8),r0
	tst	r0,r0
	bf	2f
	mov.w	cm_ccep,r4		! udp_vcre_cep(&CCEP {atr 0, any address, 50098, no callback})
	add	r8,r4
	mov	#0,r0
	mov.l	r0,@r4
	mov.l	r0,@(4,r4)
	mov.l	r0,@(8,r4)
	mov.l	r0,@(12,r4)
	mov.w	cm_port,r0
	mov.w	r0,@(8,r4)
	mov.l	cm_cre,r1
	fcall	r1
	cmp/pl	r0
	bf	cm_ack
	mov	r0,r1
	mov.w	cm_cep,r0
	mov.l	r1,@(r0,r8)
2:	mov	#4,r14			! r14 = datagrams left this poll
3:	mov	#0,r0
	mov.l	r0,@-r15		! TMO_POL
	mov.w	cm_cep,r0
	mov.l	@(r0,r8),r4
	mov.w	cm_from,r5
	add	r8,r5
	mov.l	cm_rx,r6
	add	r8,r6
	mov.w	cm_rxlen,r7
	mov.l	cm_rcv,r1
	fcall	r1
	add	#4,r15
	cmp/pl	r0
	bf	cm_ack
	bsr	cmd_pkt
	mov	r0,r4			! r4 = its length
	dt	r14
	bf	3b
cm_ack:	tst	r13,r13			! the autotest's ACK word moved: 'V3CD'
	bt	cm_out
	mov.l	@r13,r6
	tst	r6,r6
	bt	cm_out
	mov.w	cm_aack,r0
	mov.l	@(r0,r6),r4
	tst	r4,r4
	bt	cm_out
	mov.w	cm_pack,r0
	mov.l	@(r0,r8),r1
	cmp/eq	r1,r4
	bt	cm_out
	mov.l	r4,@(r0,r8)
	bsr	scr_clear
	nop
	mov.l	cm_mcd,r0
	mov.l	r0,@r1
	mov.l	r9,@(4,r1)
	mov.l	r4,@(8,r1)		! w2 seq
	mov.l	@(48,r6),r0
	mov.l	r0,@(12,r1)		! w3 AT_STEP
	mov.l	@(52,r6),r0
	mov.l	r0,@(16,r1)		! w4 AT_WHY
	mov.l	@(0,r6),r0
	mov.l	r0,@(20,r1)		! w5 AT_STATE
	bsr	cm_fin
	nop
cm_out:	mov.l	@r15+,r14
	lds.l	@r15+,pr
	rts
	nop

! cm_fin: the scratch record stamped, into the ring, flushed in this poll. Clobbers r0-r3.
cm_fin:
	sts.l	pr,@-r15
	bsr	stamp
	nop
	mov	r8,r1
	add	#U_SCR,r1
	add	#64,r1
	mov.l	r0,@(56,r1)
	bsr	add_rec
	nop
	mov	#1,r0
	mov.l	r0,@(U_FORCE,r8)
	lds.l	@r15+,pr
	rts
	nop
cm_cep:		.word	U_CEP
cm_ccep:	.word	U_CCEP
cm_port:	.word	50098
cm_from:	.word	U_CFROM
cm_rxlen:	.word	CRX_LEN
cm_aack:	.word	A_ACK
cm_pack:	.word	U_PACK
	.p2align 2
cm_rx:		.long	U_CRX
cm_cre:		.long	0x08233A22		! udp_vcre_cep
cm_rcv:		.long	0x0823415E		! udp_rcv_dat(cep, &from, buf, len) + tmo on the stack
cm_mcd:		.long	0x44433356		! "V3CD"

! cmd_pkt: one datagram (r4 = its length, at block + U_CRX). Answers with a 'V3CK' record: w2 seq,
! w3 status (0 taken, 1 bad datagram, 2 no autotest block, 3 the op area is full, 4 a USB script
! runs, 5 CMDFIX: the queued script's tail is not an END inside the op area: refused), w4 ops queued, w5 ops in it, w6 AT_STATE after, w7 U_CTAIL, w8 datagrams, w9 sender IP.
! Queueing: the commander's script ends with an END at U_CTAIL. New ops go after that END, then
! an ACK (op 9, c = seq) and a new END; last the old END becomes WAIT 0 (c first, the op byte last:
! exec_op sees either the END or the WAIT). If the executor took the old END meanwhile (DONE, PC just
! past it) it is put back on that slot and RUN. Idle / DONE / ABORT: a fresh script at OPS + 16
! (state words cleared, 'NETC' at A_SRC), ARMED with 0.3 s of noise learning left. No autotest
! block yet (no SCRIPT.BIN ever): it is malloc'd here once, as at_tick would. Keeps r14.
cmd_pkt:
	mov.l	r14,@-r15
	sts.l	pr,@-r15
	mov	#U_CPKT / 4,r0		! CMDFIX: (the pool is out of mov.w range from here)
	shll2	r0
	mov.l	@(r0,r8),r1
	add	#1,r1
	mov.l	r1,@(r0,r8)
	mov.l	ck_rx,r11
	add	r8,r11			! r11 = the datagram
	mov	#1,r14			! r14 = status
	mov	#0,r7			! r7 = ops to queue
	mov	#12,r0
	cmp/ge	r0,r4
	bf	ck_rec
	mov.l	@r11,r1
	mov.l	ck_magic,r2
	cmp/eq	r1,r2
	bf	ck_rec
	mov.w	@(8,r11),r0
	extu.w	r0,r5			! r5 = ops in it
	mov	#60,r0
	cmp/hi	r0,r5
	bt	ck_rec
	mov	r5,r6
	shll2	r6
	add	r6,r6			! r6 = ops x 8
	mov	r6,r0
	add	#12,r0
	cmp/gt	r4,r0
	bt	ck_rec			! shorter than it says
	mov	r11,r1
	add	#12,r1
	mov	#0,r2
	tst	r6,r6
	bt	2f
1:	mov.b	@r1+,r0
	extu.b	r0,r0
	dt	r6
	bf/s	1b
	add	r0,r2
2:	extu.w	r2,r2
	mov.w	@(10,r11),r0
	extu.w	r0,r0
	cmp/eq	r0,r2
	bf	ck_rec
	mov	#0,r14
	mov	r11,r6			! pass 1: MEM answered now, the others counted
	add	#12,r6
	mov	r5,r4
	tst	r4,r4
	bt	ck_q
3:	mov.b	@r6,r0
	extu.b	r0,r0
	cmp/eq	#8,r0
	bf	4f
	bsr	mem_rec			! keeps r4-r7
	nop
	bra	5f
	nop
4:	tst	r0,r0
	bt	5f
	mov	#8,r1
	cmp/hs	r1,r0
	bt	5f
	add	#1,r7
5:	dt	r4
	bf/s	3b
	add	#8,r6
ck_q:	tst	r7,r7
	bt	ck_rec
	mov	#2,r14
	tst	r13,r13
	bt	ck_rec
	mov.l	@r13,r6			! r6 = the autotest block
	tst	r6,r6
	bf	6f
	mov.l	r7,@-r15
	mov.l	r5,@-r15		! CMDFIX: r5 (ops in the datagram) survives the malloc (it was lost: the copy
	mov.w	ck_atblk,r4		!   loop then ran on past the datagram, over stale bytes of the receive buffer)
	mov.l	ck_malloc,r1
	fcall	r1
	mov.l	@r15+,r5
	mov.l	@r15+,r7
	tst	r0,r0
	bt	ck_rec
	mov	r0,r6
	mov.w	ck_atblk,r2
	shlr2	r2
	mov	#0,r1
7:	mov.l	r1,@r0
	dt	r2
	bf/s	7b
	add	#4,r0
	mov.l	r6,@r13
6:	mov.l	@(0,r6),r0		! AT_STATE: ARMED / RUN -> append, else fresh
	cmp/eq	#1,r0
	bt	8f
	cmp/eq	#2,r0
	bt	8f
	mov	#1,r4			! r4 = fresh
	mov	r6,r1			! state words 0..191 cleared (as the loader)
	mov	#48,r2
	mov	#0,r0
9:	mov.l	r0,@r1
	dt	r2
	bf/s	9b
	add	#4,r1
	mov.w	ck_aops,r3		! r3 = tail
	mov	r6,r1			! CMDFIX: the whole op area [A_OPS, A_LIM) cleared too
	add	r3,r1
	mov.w	ck_opw,r2
15:	mov.l	r0,@r1
	dt	r2
	bf/s	15b
	add	#4,r1
	bra	10f
	nop
8:	mov	#0,r4
	mov	#4,r14
	mov.w	ck_asrc,r0
	mov.l	@(r0,r6),r1
	mov.l	ck_netc,r2
	cmp/eq	r1,r2
	bf	ck_rec			! a SCRIPT.BIN runs: not ours to extend
	mov.w	ck_ctail,r0
	mov.l	@(r0,r8),r3
	mov	#5,r14			! CMDFIX: the tail must be an END slot inside the op area, else refused (5)
	mov.w	ck_aops,r1
	cmp/hs	r1,r3
	bf	ck_rec
	mov.w	ck_alim8,r2
	cmp/hi	r2,r3
	bt	ck_rec
	mov	r3,r0
	sub	r1,r0
	tst	#7,r0
	bf	ck_rec
	mov	r6,r1
	add	r3,r1
	mov.l	@r1,r0
	tst	r0,r0
	bf	ck_rec
	mov.l	@(4,r1),r0
	tst	r0,r0
	bf	ck_rec
10:	mov	#3,r14
	mov	r7,r0			! tail + 8 (k + 3) <= the op area's end
	add	#3,r0
	shll2	r0
	add	r0,r0
	add	r3,r0
	mov.w	ck_alim,r1
	cmp/hi	r1,r0
	bt	ck_rec
	mov	r6,r1
	add	r3,r1
	add	#8,r1			! r1 = dst (after the old END)
	mov	r11,r2
	add	#12,r2			! r2 = src
11:	mov.l	@r2,r0			! ops 1..7 copied
	tst	#0xF8,r0
	bf	12f
	tst	#0x07,r0
	bt	12f
	mov.l	r0,@r1
	mov.l	@(4,r2),r0
	mov.l	r0,@(4,r1)
	add	#8,r1
12:	dt	r5
	bf/s	11b
	add	#8,r2
	mov	#9,r0			! ACK seq, END
	mov.l	r0,@r1
	mov.l	@(4,r11),r0
	mov.l	r0,@(4,r1)
	mov	#0,r0
	mov.l	r0,@(8,r1)
	mov.l	r0,@(12,r1)
	add	#8,r1
	sub	r6,r1
	mov.w	ck_ctail,r0
	mov.l	r1,@(r0,r8)		! the new END's offset
	mov	r6,r1
	add	r3,r1			! the old END -> WAIT 0: c, then the op byte
	mov	#0,r0
	mov.l	r0,@(4,r1)
	mov	#4,r0
	mov.l	r0,@r1
	mov	#0,r14
	tst	r4,r4
	bt	13f
	mov.l	r1,@(4,r6)		! fresh: AT_PC = OPS + 16
	mov.w	ck_asrc,r0
	mov.l	ck_netc,r2
	mov.l	r2,@(r0,r6)
	mov	r9,r2			! T_ARMT = now - 2.7 s: RUN in 0.3 s (at_tick)
	mov.w	ck_learn,r0
	sub	r0,r2
	mov	#64,r0
	shll	r0
	mov.l	r2,@(r0,r6)
	mov	#1,r0
	bra	ck_rec
	mov.l	r0,@(0,r6)		! ARMED last
13:	mov.l	ck_cap,r0		! appended: 15 more minutes
	add	r9,r0
	mov.l	r0,@(12,r6)
	mov.l	@(0,r6),r0
	cmp/eq	#3,r0
	bf	ck_rec
	mov.l	@(4,r6),r0		! DONE on the old END just now: on from that slot
	mov	r1,r2
	add	#8,r2
	cmp/eq	r0,r2
	bf	ck_rec
	mov.l	r1,@(4,r6)
	mov.l	r9,@(8,r6)
	mov	#2,r0
	mov.l	r0,@(0,r6)
ck_rec:	bsr	scr_clear
	nop
	mov.l	ck_mck,r0
	mov.l	r0,@r1
	mov.l	r9,@(4,r1)
	mov.l	@(4,r11),r0
	mov.l	r0,@(8,r1)
	mov.l	r14,@(12,r1)
	mov.l	r7,@(16,r1)
	mov.w	@(8,r11),r0
	extu.w	r0,r0
	mov.l	r0,@(20,r1)
	mov	#-1,r0
	tst	r13,r13
	bt	14f
	mov.l	@r13,r2
	tst	r2,r2
	bt	14f
	mov.l	@r2,r0
14:	mov.l	r0,@(24,r1)
	mov.w	ck_ctail,r0
	mov.l	@(r0,r8),r0
	mov.l	r0,@(28,r1)
	mov.w	ck_cpkt,r0
	mov.l	@(r0,r8),r0
	mov.l	r0,@(32,r1)
	mov.w	ck_from,r0
	mov.l	@(r0,r8),r0
	mov.l	r0,@(36,r1)
	bsr	cm_fin
	nop
	lds.l	@r15+,pr
	rts
	mov.l	@r15+,r14
ck_cpkt:	.word	U_CPKT
ck_ctail:	.word	U_CTAIL
ck_from:	.word	U_CFROM
ck_atblk:	.word	4096			! = mods/autotest BLK
ck_aops:	.word	A_OPS
ck_asrc:	.word	A_SRC
ck_alim:	.word	A_LIM
ck_alim8:	.word	A_LIM - 8		! CMDFIX: the last op slot
ck_opw:		.word	(A_LIM - A_OPS) / 4	! CMDFIX: the op area in words
ck_learn:	.word	2700
	.p2align 2
ck_rx:		.long	U_CRX
ck_magic:	.long	0x31435441		! "ATC1"
ck_netc:	.long	0x4354454E		! "NETC"
ck_mck:		.long	0x4B433356		! "V3CK"
ck_malloc:	.long	0x08344A9C
ck_cap:		.long	15 * 60 * 1000

! mem_rec: MEM (r6 = the op: b = len, c = addr) -> a 'V3MM' record: w2 seq, w3 addr, w4 len (0:
! refused), w5.. the bytes. Read-only; 1..64 bytes inside DRAM 0x08000000..0x18000000 (P0, or its
! P1 / P2 mirror 0x8.. / 0xA..). r11 = the datagram. Keeps r4-r7.
mem_rec:
	sts.l	pr,@-r15
	mov.l	r4,@-r15
	bsr	scr_clear
	nop
	mov.l	mr_mag,r0
	mov.l	r0,@r1
	mov.l	r9,@(4,r1)
	mov.l	@(4,r11),r0
	mov.l	r0,@(8,r1)
	mov.l	@(4,r6),r2		! r2 = addr
	mov.l	r2,@(12,r1)
	mov.w	@(2,r6),r0
	extu.w	r0,r3			! r3 = len
	tst	r3,r3
	bt	mr_out
	mov	#64,r0
	cmp/hi	r0,r3
	bt	mr_out
	mov	r2,r0			! the top 3 bits: 0 (P0), 4 (P1), 5 (P2)
	shlr16	r0
	shlr8	r0
	shlr2	r0
	shlr2	r0
	shlr	r0
	tst	r0,r0
	bt	1f
	shlr	r0
	cmp/eq	#2,r0
	bf	mr_out
1:	mov.l	mr_m29,r0
	and	r2,r0
	mov.l	mr_lo,r4
	cmp/hs	r4,r0
	bf	mr_out
	add	r3,r0
	mov.l	mr_hi,r4
	cmp/hi	r4,r0
	bt	mr_out
	mov.l	r3,@(16,r1)
	add	#20,r1
2:	mov.b	@r2+,r0
	mov.b	r0,@r1
	dt	r3
	bf/s	2b
	add	#1,r1
mr_out:	bsr	cm_fin
	nop
	mov.l	@r15+,r4
	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
mr_mag:		.long	0x4D4D3356		! "V3MM"
mr_m29:		.long	0x1FFFFFFF
mr_lo:		.long	0x08000000
mr_hi:		.long	0x18000000

! scr_clear: r1 = the scratch record, zeroed. Clobbers r0, r2.
scr_clear:
	mov	r8,r1
	add	#U_SCR,r1
	mov	#32,r2
	mov	#0,r0
1:	mov.l	r0,@r1
	dt	r2
	bf/s	1b
	add	#4,r1
	mov	r8,r1
	rts
	add	#U_SCR,r1

! add_rec: the scratch record into the ring (the oldest dropped when full).
! r8 = block. Clobbers r0-r3.
add_rec:
	mov.l	@(U_WR,r8),r0
	mov.l	@(U_RD,r8),r1
	mov	r0,r2
	sub	r1,r2
	mov.w	ar_n,r3
	cmp/hs	r3,r2
	bf	1f
	add	#1,r1			! full: the oldest goes
	mov.l	r1,@(U_RD,r8)
	mov.l	@(U_DROP,r8),r1
	add	#1,r1
	mov.l	r1,@(U_DROP,r8)
1:	mov.w	ar_mask,r1		! dst = ring + (WR & 511) * 128
	and	r0,r1
	shll8	r1
	shlr	r1
	mov.w	ar_ring,r2
	add	r2,r1
	add	r8,r1
	add	#1,r0
	mov.l	r0,@(U_WR,r8)
	mov	r8,r2
	add	#U_SCR,r2
	mov	#32,r3
2:	mov.l	@r2+,r0
	mov.l	r0,@r1
	dt	r3
	bf/s	2b
	add	#4,r1
	rts
	nop
ar_n:		.word	U_NREC
ar_mask:	.word	U_NREC - 1
ar_ring:	.word	U_RING
	.p2align 2

! stamp: r0 = the autotest stamp (step | state << 16 | why << 24), 0 without autotest.
! Clobbers r1.
stamp:
	tst	r13,r13
	bt	1f
	mov.l	@r13,r1
	tst	r1,r1
	bt	1f
	mov.l	@(0,r1),r0		! state
	shll16	r0
	mov.l	r0,@-r15
	mov.l	@(52,r1),r0		! why
	shll16	r0
	shll8	r0
	mov.l	@(48,r1),r1		! step
	extu.w	r1,r1
	or	r1,r0
	mov.l	@r15+,r1
	rts
	or	r1,r0
1:	rts
	mov	#0,r0

! gui_take: every new, checked record of the GUI block (TX frame +0x800 as MAIN
! receives it) into the ring. r8 = block, r9 = now. Clobbers r0-r7, r11, r14.
gui_take:
	sts.l	pr,@-r15
	bsr	rx_pick			! r4 = the newest HUD block among MAIN's 3 RX slots (V4m2)
	nop
	mov.l	@r4,r0
	mov.l	gt_magic,r1
	cmp/eq	r0,r1
	bf	gt_out
	mov.l	@(4,r4),r5		! r5 = head seq
	mov.w	gt_tail,r0
	mov.l	@(r0,r4),r0
	cmp/eq	r0,r5			! tail == head: consistent
	bf	gt_out
	mov.l	@(U_LAST,r8),r6
	cmp/hs	r6,r5
	bf	gt_out			! V4m2: an older block = a stale RX slot (was: "the GUI restarted",
					! which re-took 15 records each time a stale slot won the pick)
	cmp/eq	r6,r5
	bt	gt_out
	mov	r5,r0			! first = max(last + 1, head - 14)
	sub	r6,r0
	mov	#15,r1
	cmp/hi	r1,r0
	bf	2f
	add	#-15,r0			! records the GUI ring overwrote: lost
	mov.l	@(U_DROP,r8),r1
	add	r0,r1
	mov.l	r1,@(U_DROP,r8)
	mov	r5,r6
	add	#-15,r6			! last = head - 15
2:	mov	r6,r11
	add	#1,r11			! r11 = seq to take
gt_loop:
	mov	r11,r0			! slot = seq % 15
	mov.l	gt_inv15,r1
	dmulu.l	r0,r1
	sts	mach,r1
	shlr2	r1
	shlr	r1			! q = seq / 15
	mov	r1,r2
	shll2	r2
	shll2	r2
	sub	r1,r2			! q * 15
	sub	r2,r0			! r0 = slot
	shll8	r0
	shlr	r0			! slot * 128
	add	#16,r0
	add	r4,r0			! r0 = the record
	mov	r8,r1
	add	#U_SCR,r1
	mov	#32,r2
	mov	#0,r14			! checksum of w0..w29
	mov	#0,r7
3:	mov.l	@r0+,r3
	mov.l	r3,@r1
	mov	#3,r6
	cmp/hi	r2,r6			! r2 <= 2: w30 / w31 not summed
	bt	4f
	add	r3,r14
4:	dt	r2
	bf/s	3b
	add	#4,r1
	mov	r8,r1
	add	#U_SCR,r1
	mov.l	@r1,r0
	cmp/eq	r0,r11			! its seq
	bf	gt_out
	mov.l	gt_x5a,r0
	xor	r0,r14
	mov.l	gt_m31,r0
	and	r0,r14
	add	#64,r1
	mov.l	@(60,r1),r0		! w31
	cmp/eq	r0,r14
	bf	gt_out			! torn / not written yet: next poll
	bsr	stamp
	nop
	mov	r8,r1
	add	#U_SCR,r1
	add	#64,r1
	mov.l	r0,@(56,r1)		! w30 = the autotest stamp
	bsr	add_rec
	nop
	mov.l	r11,@(U_LAST,r8)
	cmp/eq	r11,r5
	bf/s	gt_loop
	add	#1,r11
gt_out:
	lds.l	@r15+,pr
	rts
	nop
gt_tail:	.word	0x7FC
	.p2align 2
gt_magic:	.long	HUD_MAGIC
gt_inv15:	.long	0x88888889		! ceil(2^35 / 15)
gt_x5a:		.long	0x5A5A5A5A
gt_m31:		.long	0x7FFFFFFF

! at_watch: a 'V3MK' record when the autotest step changes, a 'V3AE' record (and a
! forced flush) when the script ends. r13 = &autotest pointer.
at_watch:
	sts.l	pr,@-r15
	tst	r13,r13
	bt	aw_out
	mov.l	@r13,r11		! r11 = the autotest block
	tst	r11,r11
	bt	aw_out
	mov.l	@(48,r11),r0		! AT_STEP
	mov.l	@(U_PSTEP,r8),r1
	cmp/eq	r0,r1
	bt	1f
	mov.l	r0,@(U_PSTEP,r8)
	bsr	scr_clear
	nop
	mov.l	aw_mk,r0
	mov.l	r0,@r1
	mov.l	r9,@(4,r1)
	mov.l	@(48,r11),r0
	mov.l	r0,@(8,r1)
	mov.l	@(60,r11),r0		! AT_STEPT
	mov.l	r0,@(12,r1)
	mov.l	@(0,r11),r0
	mov.l	r0,@(16,r1)
	bsr	stamp
	nop
	mov	r8,r1
	add	#U_SCR,r1
	add	#64,r1
	mov.l	r0,@(56,r1)
	bsr	add_rec
	nop
1:	mov.l	@(0,r11),r0		! AT_STATE
	mov.l	@(U_PST,r8),r1
	cmp/eq	r0,r1
	bt	aw_out
	mov.l	r0,@(U_PST,r8)
	cmp/eq	#3,r0
	bt	2f
	cmp/eq	#4,r0
	bf	aw_out
2:	bsr	scr_clear
	nop
	mov.l	aw_ae,r0
	mov.l	r0,@r1
	mov.l	r9,@(4,r1)
	mov.l	@(0,r11),r0
	mov.l	r0,@(8,r1)
	mov.l	@(52,r11),r0		! AT_WHY
	mov.l	r0,@(12,r1)
	mov.l	@(48,r11),r0
	mov.l	r0,@(16,r1)
	mov.l	@(4,r11),r0		! op index = (PC - (block + 208)) / 8
	mov	r11,r2
	mov.w	aw_ops,r3
	add	r3,r2
	sub	r2,r0
	shar	r0
	shar	r0
	shar	r0
	mov.l	r0,@(20,r1)
	bsr	stamp
	nop
	mov	r8,r1
	add	#U_SCR,r1
	add	#64,r1
	mov.l	r0,@(56,r1)
	bsr	add_rec
	nop
	mov	#1,r0
	mov.l	r0,@(U_FORCE,r8)
aw_out:
	lds.l	@r15+,pr
	rts
	nop
aw_ops:		.word	208
	.p2align 2
aw_mk:		.long	0x4B4D3356		! "V3MK"
aw_ae:		.long	0x45413356		! "V3AE"

! flush: ONE open("a") / write(s) / close of the pending records. r8 = block,
! r9 = now. Clobbers r0-r7, r11, r14.
flush:
	sts.l	pr,@-r15
	mov.l	fl_path,r4
	add	r10,r4
	mov.l	fl_amode,r5
	mov.l	fl_tag,r6
	mov.l	fl_open,r1
	fcall	r1
	tst	r0,r0
	bf	1f
	mov	#U_OFAIL / 2,r0		! V4g: no open -- try again >= 10 s later (or at the next pause), 8 times
	shll	r0			! a mount, then off until the next mount (was: off at the first failure)
	mov.l	@(r0,r8),r1
	add	#1,r1
	mov.l	r1,@(r0,r8)
	mov.l	r9,@(U_LASTF,r8)
	mov	#8,r0
	cmp/hs	r0,r1
	bf	fl_out
	mov	#0,r0
	bra	fl_out
	mov.l	r0,@(U_ON,r8)
1:	mov	r0,r11			! r11 = handle
	bsr	us_rec			! V4g: a 'V3US' status record first, in this same write
	nop
fl_more:
	mov.l	@(U_WR,r8),r0
	mov.l	@(U_RD,r8),r1
	cmp/eq	r0,r1
	bt	fl_close
	sub	r1,r0			! pending
	mov.w	fl_mask,r2
	and	r1,r2			! idx = RD & 511
	mov.w	fl_n,r3
	sub	r2,r3			! to the ring's end
	cmp/hs	r3,r0
	bf	2f
	mov	r3,r0
2:	mov	r0,r14			! r14 = records in this write
	shll8	r0
	shlr	r0			! bytes
	mov.l	@(U_SIZE,r8),r3		! the 4 MB cap
	add	r0,r3
	mov.l	fl_cap,r1
	cmp/hi	r1,r3
	bt	fl_dead
	mov	r0,r6			! write(ring + idx * 128, 1, bytes, fh), tag on the stack
	shll8	r2
	shlr	r2
	mov.w	fl_ring,r4
	add	r2,r4
	add	r8,r4
	mov	#1,r5
	mov	r11,r7
	mov.l	r6,@-r15
	mov.l	fl_tag,r1
	mov.l	r1,@-r15
	mov.l	fl_write,r1
	fcall	r1
	add	#4,r15
	mov.l	@r15+,r6
	cmp/eq	r0,r6
	bf	fl_dead			! short write: off until reboot
	mov.l	@(U_SIZE,r8),r0
	add	r6,r0
	mov.l	r0,@(U_SIZE,r8)
	mov.l	@(U_RD,r8),r0
	add	r14,r0
	bra	fl_more
	mov.l	r0,@(U_RD,r8)
fl_dead:
	mov	#1,r0
	mov.l	r0,@(U_DEAD,r8)
	mov	#0,r0
	mov.l	r0,@(U_ON,r8)
fl_close:
	mov	r11,r4
	mov.l	fl_tag,r5
	mov.l	fl_close_f,r1
	fcall	r1
	mov.l	r9,@(U_LASTF,r8)
	mov	#0,r0
	mov.l	r0,@(U_FORCE,r8)
	mov.l	@(U_FLUSH,r8),r0
	add	#1,r0
	mov.l	r0,@(U_FLUSH,r8)
fl_out:
	lds.l	@r15+,pr
	rts
	nop
! rx_pick (V4m2): MAIN's gui_comm receives into a RING of 3 slots, 16 KB apart (0xA9072B38 + slot << 14,
! slot bytes 0x10DC151E / 0x10DC151F; the TX buffer 0xA907EB38 is the 4th), and clears a slot once it
! has parsed it. Reading slot 0 only saw the block whenever the link happened to use / keep slot 0: on the
! deck V4g lost it at ~1/3 of the polls and V4k3 at every poll ("RX head 0"). r4 = the slot (+0x800) with
! magic, tail == head and the highest head; slot 0's when none; r6 = its index. Clobbers r0-r3, r6, r7.
rx_pick:
	mov.l	rp_rx,r1
	mova	hg_off,r0		! HUDOFF: + where hg_hook found the block (0x800 by default)
	mov.l	@r0,r0
	add	r0,r1
	mov	r1,r4
	mov	#0,r3			! the best head so far
	mov	#3,r2
1:	mov.l	@r1,r0
	mov.l	rp_mag,r6
	cmp/eq	r0,r6
	bf	2f
	mov.l	@(4,r1),r7		! head
	mov.w	rp_tail,r0
	mov.l	@(r0,r1),r0
	cmp/eq	r0,r7			! tail == head: consistent
	bf	2f
	cmp/hi	r3,r7
	bf	2f
	mov	r7,r3
	mov	r1,r4
2:	mov.l	rp_step,r0
	dt	r2
	bf/s	1b
	add	r0,r1
	mov.l	rp_rx,r1
	mov	r4,r6
	sub	r1,r6
	shlr8	r6
	shlr2	r6
	shlr2	r6
	rts
	shlr2	r6
rp_tail:	.word	0x7FC
	.p2align 2
rp_rx:		.long	0xA9072B38		! HUDOFF: slot 0 (the block offset is hg_off)
rp_mag:		.long	HUD_MAGIC
rp_step:	.long	0x4000

! us_rec (V4g): a 'V3US' record of the logger's own state into the ring (one per flush), so a deck
! log tells why records are missing: w1 tick, w2 flushes, w3 failed opens, w4 drops, w5 file size,
! w6 pending, w7 ms since the elapsed word moved, w8 D_PREVIEW, w9 MED+64 (row preview), w10 USB
! state, w11 RX block magic, w12 RX head seq, w13 last GUI seq taken, w14 (V4m2) RX slot, w15 (V4m3) device settings + detail mode, w16..w27 (V4n24) the
! loaded track's artwork / cue / title chain (see work/autotest/decode_usblog.py). Clobbers r0-r3.
us_rec:
	sts.l	pr,@-r15
	bsr	scr_clear
	nop
	mov.l	us_mag,r0
	mov.l	r0,@r1
	mov.l	r9,@(4,r1)
	mov.l	@(U_FLUSH,r8),r0
	mov.l	r0,@(8,r1)
	mov	#U_OFAIL / 2,r0
	shll	r0
	mov.l	@(r0,r8),r0
	mov.l	r0,@(12,r1)
	mov.l	@(U_DROP,r8),r0
	mov.l	r0,@(16,r1)
	mov.l	@(U_SIZE,r8),r0
	mov.l	r0,@(20,r1)
	mov.l	@(U_WR,r8),r0
	mov.l	@(U_RD,r8),r2
	sub	r2,r0
	mov.l	r0,@(24,r1)
	mov.l	@(U_ELT,r8),r2
	mov	r9,r0
	sub	r2,r0
	mov.l	r0,@(28,r1)
	mov	#104,r0
	mov.l	@(r0,r12),r0
	mov.l	r0,@(32,r1)
	mov.l	us_pv,r2
	mov.l	@r2,r0
	mov.l	r0,@(36,r1)
	mov.l	us_usb,r2
	mov.l	@r2,r0
	mov.l	r0,@(40,r1)
	mov.l	r4,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	mov.l	r1,@-r15
	bsr	rx_pick
	nop
	mov.l	@r15+,r1
	mov	r4,r2
	mov.l	r6,@(56,r1)		! w14 (V4m2): the RX slot the block came from (0..2)
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r4
	mov.l	@r2,r0
	mov.l	r0,@(44,r1)
	mov.l	@(4,r2),r0
	mov.l	r0,@(48,r1)
	mov.l	@(U_LAST,r8),r0
	mov.l	r0,@(52,r1)
	mov	r1,r3			! V4n24: w26 = the GUI's LDART word (HUD block w3, usblog.inc ldart_diag)
	add	#64,r3
	mov.l	@(12,r2),r0
	mov.l	r0,@(40,r3)
	mov.l	us_dev,r2		! w15 (V4m3): the own USB's device-settings bytes (+4 overview,
	mov.l	@r2,r0			! +5, +6 stock WAVEFORM COLOR 1 BLUE / 3 RGB, getter 0x084031C8) in
	shll8	r0			! bits 0-23, the detail requester's mode (1 RGB first, 0 BLUE
	shlr8	r0			! only) in bits 24-31
	mov.l	us_wmode,r2
	mov.l	@r2,r2
	shll16	r2
	shll8	r2
	or	r2,r0
	mov.l	r0,@(60,r1)
	add	#64,r1			! V4n24 (deck: no loaded-track cover): w16.. the artwork / cue chain
	mov.l	us_arc,r2
	mov.l	@r2,r0
	mov.l	r0,@(0,r1)		! w16 AR_SEQ
	mov.l	@(8,r2),r0
	mov.l	r0,@(4,r1)		! w17 AR_TOT
	mov.l	@(4,r2),r0
	mov.l	r0,@(8,r1)		! w18 AR_SENT
	mov.l	@(12,r2),r0
	mov.l	r0,@(12,r1)		! w19 AR_STATE (tries | soft image out << 8)
	mov.l	us_cc,r2
	mov.l	@(20,r2),r0		! w20 CC_STATE | CC_TRY << 8 | CC_OK << 16
	extu.b	r0,r0
	mov.l	@(24,r2),r3
	extu.b	r3,r3
	shll8	r3
	or	r3,r0
	mov.l	@(28,r2),r3
	extu.b	r3,r3
	shll16	r3
	or	r3,r0
	mov.l	r0,@(16,r1)
	mov.l	@r2,r0
	mov.l	r0,@(20,r1)		! w21 CC_SEQ
	mov.l	@(16,r2),r0
	mov.l	r0,@(24,r1)		! w22 CC_RB (the loaded rbid the blocks are for)
	mov.l	us_ja,r2
	mov.l	@r2,r0			! w23 JPU: done & 0xFFFF | seq << 16 (low halves)
	extu.w	r0,r0
	mov.l	@(4,r2),r3
	shll16	r3
	or	r3,r0
	mov.l	r0,@(28,r1)
	mov.l	@(8,r2),r0		! w24 JPU latch (1 = a request out) | rw_art ok << 8 | big image << 16
	extu.b	r0,r0
	mov.l	us_rok,r3		!   (ra_ok RAMB+0x10094, ja_jok RAMB+0x100A8 = +0x10)
	mov.l	@r3,r3
	extu.b	r3,r3
	shll8	r3
	or	r3,r0
	mov.l	@(16,r2),r3
	extu.b	r3,r3
	shll16	r3
	or	r3,r0
	mov.l	r0,@(32,r1)
	mov.l	us_w8,r2
	mov.l	@(0x20,r2),r0		! w25 w8send ST | D_LEFT << 8 (bytes left of the stream under way)
	extu.b	r0,r0
	mov.l	@(0x14,r2),r3
	shll8	r3
	or	r3,r0
	mov.l	r0,@(36,r1)
	mov.l	us_cc,r2
	mov.l	@(12,r2),r0
	mov.l	r0,@(44,r1)		! w27 CC_KEY (source player | slot << 8 | type << 16)
	mova	hg_head,r0		! V4n36 trace (#51): w28 the head hg_hook last caught, w29 its captures
	mov.l	@r0,r2
	mov.l	r2,@(48,r1)
	mov.l	@(4,r0),r2
	mov.l	r2,@(52,r1)
	bsr	add_rec
	nop
	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
us_arc:		.long RAMB+0x15030
us_cc:		.long RAMB+0x15010
us_ja:		.long RAMB+0x10098
us_w8:		.long RAMB+0x1E000
us_rok:		.long RAMB+0x10094
us_mag:		.long	0x53553356		! "V3US"
us_pv:		.long	RAMB+0x1F700+64
us_usb:		.long	0x0A35F3AC
us_dev:		.long	0x0A35F80C + 3 * 0xA8 + 0xA4	! own USB record +0xA4 (getter 0x084031C8 reads +0xA6)
us_wmode:	.long	0x0B531E9C		! detail requester mode (0x0849EB5A: movt = getter == 3)

fl_mask:	.word	U_NREC - 1
fl_n:		.word	U_NREC
fl_ring:	.word	U_RING
	.p2align 2
fl_path:	.long	ut_path - usblog	! r10 = the blob
fl_amode:	.long	0xA80EC2C0		! "a" (a stock mode string next to its file-manager opens)
fl_tag:		.long	0xA80EB5B8		! touch_audio's thunks' owner tag
fl_open:	.long	0x08501CB0		! fm_open(path16, mode, tag)
fl_write:	.long	0x08502862		! fm_write(buf, 1, n, fh) + tag on the stack
fl_close_f:	.long	0x08502224		! fm_close(fh, tag)
fl_cap:		.long	U_CAP

! boot_rec (V4n36 trace): the 'V3HB' boot record, once per boot (U_BOOTED) -- on the stick at the first mount
! with the file (USB) and over the network (RED): w1 tick, w2 drops, w3 file size (r14; RED -1), w4..w5 the MAIN
! version string, w6 autotest in the build, w7 format 2, w8..w19 the build record (BLDID: 'BLD1' + the ASCII
! build ID "TAG YYYYMMDD-HHMM HASH8", mods/usblog/README.md; zeros in a build without one), w20 TEST LOG (r7:
! 1 USB, 2 RED). r8 = block, r9 = now, r13 = &autotest. Clobbers r0-r3, r14.
boot_rec:
	sts.l	pr,@-r15
	mov	#1,r0
	mov.l	r0,@(U_BOOTED,r8)
	bsr	scr_clear
	nop
	mov.l	br_mhb,r0
	mov.l	r0,@r1			! r1 = scratch (scr_clear)
	mov.l	r9,@(4,r1)
	mov.l	@(U_DROP,r8),r0
	mov.l	r0,@(8,r1)
	mov.l	r14,@(12,r1)
	mov.l	br_ver,r2		! MAIN image version string ("1.87+")
	mov.l	@r2,r0
	mov.l	r0,@(16,r1)
	mov.l	@(4,r2),r0
	mov.l	r0,@(20,r1)
	tst	r13,r13
	movt	r0
	xor	#1,r0
	mov.l	r0,@(24,r1)		! autotest in the build
	mov	#2,r0
	mov.l	r0,@(28,r1)		! record format 2 (V4n36 trace)
	mov.l	br_bld,r2		! w8..w19: the build record, when it carries its magic
	mov.l	@r2,r0
	mov.l	br_mag,r3
	cmp/eq	r3,r0
	bf	2f
	mov	r1,r3
	add	#32,r3
	mov	#12,r14
1:	mov.l	@r2+,r0
	mov.l	r0,@r3
	dt	r14
	bf/s	1b
	add	#4,r3
2:	mov	#80,r0
	mov.l	r7,@(r0,r1)		! w20 TEST LOG
	bsr	add_rec
	nop
	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
br_mhb:		.long	0x42483356		! "V3HB"
br_ver:		.long	0x08000740
br_bld:		.long	BLDID			! layout.inc: modsmenu's build record (patch_main fills it)
br_mag:		.long	0x31444C42		! "BLD1"

! hg_take (V4n36 trace, #51): the record hg_hook caught, when newer than the last one taken (gui_take reads the
! RX slots, which MAIN's gui_comm has usually cleared by the time this 250-ms poll looks: on the deck whole boots
! had no HUD record at all). Records skipped between two catches count as drops. r8 = block, r9 = now. Clobbers
! r0-r7, r11, r14.
hg_take:
	sts.l	pr,@-r15
	mova	hg_head,r0
	mov	r0,r7			! r7 = &hg_head
	mov.l	@r7,r5			! r5 = its head
	mov.l	@(U_LAST,r8),r6
	cmp/hi	r6,r5
	bf	ht_out			! nothing newer
	mov	r7,r0
	add	#8,r0			! hg_rec
	mov	r8,r1
	add	#U_SCR,r1
	mov	#32,r2
	mov	#0,r14			! checksum of w0..w29
3:	mov.l	@r0+,r3
	mov.l	r3,@r1
	mov	#3,r4
	cmp/hi	r2,r4			! r2 <= 2: w30 / w31 not summed
	bt	4f
	add	r3,r14
4:	dt	r2
	bf/s	3b
	add	#4,r1
	mov.l	@r7,r0			! the hook caught another one meanwhile: next poll
	cmp/eq	r0,r5
	bf	ht_out
	mov	r8,r1
	add	#U_SCR,r1
	mov.l	@r1,r0
	cmp/eq	r0,r5			! its seq
	bf	ht_out
	mov.l	ht_x5a,r0
	xor	r0,r14
	mov.l	ht_m31,r0
	and	r0,r14
	add	#64,r1
	mov.l	@(60,r1),r0		! w31
	cmp/eq	r0,r14
	bf	ht_out
	tst	r6,r6			! skipped since the last one taken (not before the first)
	bt	5f
	mov	r5,r0
	sub	r6,r0
	add	#-1,r0
	mov.l	@(U_DROP,r8),r1
	add	r0,r1
	mov.l	r1,@(U_DROP,r8)
5:	bsr	stamp
	nop
	mov	r8,r1
	add	#U_SCR,r1
	add	#64,r1
	mov.l	r0,@(56,r1)		! w30 = the autotest stamp
	bsr	add_rec
	nop
	mov.l	r5,@(U_LAST,r8)
ht_out:	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
ht_x5a:		.long	0x5A5A5A5A
ht_m31:		.long	0x7FFFFFFF

! hg_hook (V4n36 trace, #51): memset(r4, r5, r6) of MAIN's gui_comm (the literal 0x0838EAEC, its two calls: the
! RX slot it has just parsed, 0x4000 bytes, and the TX one). On a normal boot only (*0x0A35DF3C == 1), for an RX
! slot (0xA9072B38 + slot << 14, slot 0..2) whose HUD block (+0x800, usblog.inc) is consistent (magic, tail ==
! head) with a head newer than the last caught: its newest record (slot head % 15) is copied into hg_rec, then
! hg_head = head. ~240 calls a second, one record copied a second. Then the memset itself (r4-r7 untouched).
! Uses r0-r3 (saved: mach, macl, r7).
hg_hook:
	mov.l	hk_boot,r0
	mov.l	@r0,r0
	cmp/eq	#1,r0
	bf	hk_go
	mov.l	hk_rx,r0
	mov	r4,r1
	sub	r0,r1
	mov.l	hk_span,r0
	cmp/hs	r0,r1
	bt	hk_go			! not an RX slot
	mova	hg_off,r0		! HUDOFF: the block where it was last found in a slot (0x800 at boot)
	mov.l	@r0,r1
	add	r4,r1			! r1 = the HUD block
	mov.l	@r1,r0
	mov.l	hk_mag,r2
	cmp/eq	r2,r0
	bf	hk_scan
	mov.l	@(8,r1),r0
	mov.l	hk_w2,r2
	cmp/eq	r2,r0
	bf	hk_scan
hk_found:
	mov.l	@(4,r1),r3		! r3 = head
	mov.w	hk_7fc,r0
	mov.l	@(r0,r1),r0
	cmp/eq	r0,r3			! tail == head: consistent
	bf	hk_go
	mova	hg_head,r0
	mov.l	@r0,r2
	cmp/hi	r2,r3
	bf	hk_go			! not newer
	sts.l	mach,@-r15
	sts.l	macl,@-r15
	mov.l	r7,@-r15
	mov	r0,r7			! r7 = &hg_head
	mov	r3,r0			! slot = head % 15
	mov.l	hk_inv,r2
	dmulu.l	r0,r2
	sts	mach,r2
	shlr2	r2
	shlr	r2
	mov	r2,r0
	shll2	r0
	shll2	r0
	sub	r2,r0			! q * 15
	mov	r3,r2
	sub	r0,r2			! r2 = slot
	shll8	r2
	shlr	r2			! slot * 128
	add	#16,r2
	add	r1,r2			! r2 = the record
	mov	r7,r1
	add	#8,r1			! r1 = hg_rec
	mov	#32,r0
	mov.l	r0,@-r15
1:	mov.l	@r2+,r0
	mov.l	r0,@r1
	mov.l	@r15,r0
	dt	r0
	mov.l	r0,@r15
	bf/s	1b
	add	#4,r1
	add	#4,r15
	mov.l	r3,@r7			! hg_head last
	mov.l	@(4,r7),r0
	add	#1,r0
	mov.l	r0,@(4,r7)		! hg_n
	mov.l	@r15+,r7
	lds.l	@r15+,macl
	lds.l	@r15+,mach
hk_go:	mov.l	hk_mset,r0
	jmp	@r0
	nop
! HUDOFF (2026-11-18): on the decks the GUI frame does not always start at an RX slot's start: V4n48g1 boots had
! the HUD block at slot + 0xF4 instead of + 0x800 (per-boot link phase), so nothing was caught (V3US w28/w29 0,
! w11 garbage). Not found at hg_off: 32 more candidate offsets a call (word steps over [0, 0x3800), the whole
! slot in ~0.5 s of memsets): magic + w2 (UL_NREC | UL_W << 16) -> hg_off = that offset. r4-r7 untouched.
hk_scan:
	mov.l	r7,@-r15
	mova	hg_scn,r0
	mov.l	@r0,r7			! r7 = the scan cursor
	mov	#32,r2
1:	mov	r4,r1
	add	r7,r1
	mov.l	@r1,r0
	mov.l	hk_mag,r3
	cmp/eq	r3,r0
	bf	2f
	mov.l	@(8,r1),r0
	mov.l	hk_w2,r3
	cmp/eq	r3,r0
	bf	2f
	mova	hg_off,r0		! found
	mov.l	r7,@r0
	mova	hg_scn,r0
	mov.l	r7,@r0
	mov.l	@r15+,r7
	bra	hk_found
	nop
2:	add	#4,r7
	mov.w	hk_smax,r0
	cmp/hs	r0,r7
	bf	3f
	mov	#0,r7
3:	dt	r2
	bf	1b
	mova	hg_scn,r0
	mov.l	r7,@r0
	mov.l	@r15+,r7
	bra	hk_go
	nop
hk_smax:	.word	0x3800		! HUDOFF: last candidate + 4 (the 2 KB block stays inside the slot)
hk_7fc:		.word	0x7FC
	.p2align 2
hk_boot:	.long	0x0A35DF3C		! MAIN boot state (1 = normal boot)
hk_rx:		.long	0xA9072B38		! RX slot 0
hk_span:	.long	3 * 0x4000		! slots 0..2 (the TX buffer is the 4th)
hk_mag:		.long	HUD_MAGIC
hk_w2:		.long	15 | 32 << 16		! HUDOFF: the block's w2 (usblog.inc UL_NREC | UL_W << 16)
hg_off:		.long	0x800			! HUDOFF: the HUD block's offset in an RX slot (found by hk_scan)
hg_scn:		.long	0			! HUDOFF: hk_scan's cursor
hk_inv:		.long	0x88888889		! ceil(2^35 / 15)
hk_mset:	.long	0x08533D50		! memset (the literal's stock target)
hg_head:	.long	0			! the head caught last (0 none)
hg_n:		.long	0			! records caught (V3US w29)
hg_rec:		.space	128			! the newest record caught
