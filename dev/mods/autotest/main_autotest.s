! SPDX-License-Identifier: Apache-2.0
!
! autotest, MAIN side (TEST builds only, opt-in: EXTRA_MODS=autotest): scripted panel input.
! Design + evidence: re/AUTOTEST_DESIGN.md; this mod: re/AUTOTEST_USBLOG.md.
!
! Placed only (empty sig, like usbkey). patch_main.place_autotest() points
!   H1  the panel decoder's "debug key active?" literal 0x0844D730 (stock 0x08201310)
!       at +0 (at_pre: runs once per panel frame in PnlCom_RcvTASK, before the decode)
!   H2  the touch calibration literal 0x0844E23C (stock 0x084C37E4) at +4 (at_cal)
! and the TchAud task (mods/touch_audio, its TESTHOOK variant `touchaudiot`) calls +8
! (at_tick) once per loop pass. +12 holds the pointer to the run-time block (0 = no
! script ever loaded); mods/usblog reads AT_STEP / AT_STATE / AT_WHY through it.
!
! Update safety (memory main-update-safety): every entry first checks *0x0A35DF3C == 1;
! otherwise H1 returns exactly the stock answer (*0x10DBE75C) and H2 tail-jumps to the
! stock calibration. The block is malloc'd only by at_tick (TchAud exists only on a
! normal boot) and only when the stick carries C:/V3TEST/SCRIPT.BIN. Nothing else is
! allocated, counted or spawned.
!
! Script file (tools: work/autotest/atc.py): 'ATS1', u16 op count (incl. END), u16 byte sum
! of the ops, 8 reserved bytes, then 8-byte ops: u8 op, s8 a, u16 b, u32 c
!   0 END   1 KEY a=value b=level offset (0x0B54C990 + b) c=ms   2 ROT a=detents
!   3 TOUCH b=x c=y | ms << 16   4 WAIT c=ms   5 MARK b=step id   6 LOOP b=count   7 ENDL
!   9 ACK c=seq (V4n26: queued only by the network commander, mods/usblog cmd_poll). The commander also
!     appends to / starts the script in this block (UDP 50098).
!   R21 deck kit (work/r21/deckkit): 8 MEM b=len (1..64) c=addr -> a request mods/usblog logs as 'V3MM'
!     (read-only, DRAM only: usblog mem_rec's range check); TOUCH a=1 = a drag segment: the point is held
!     like any TOUCH but the next ops run meanwhile (a later TOUCH moves the finger without a lift).
! Life cycle: idle -> ARMED (file read; 3 s learning the noisy raw bits) -> RUN -> DONE / ABORT.
! ABORT (AT_WHY): 1 a real key, 2 the rotary, 3 a real touch (calibrated point on screen), 4 boot state, 5 the 40-min cap,
! 6 NOMODS / UTILITY MODS OFF, 7 a bad SCRIPT.BIN, 8 (CMDFIX) a bad op / PC (exec_op's checks). Never re-armed until the stick is re-mounted.

	.include "layout.inc"

	.equ	AT_STATE, 0		! 0 idle 1 armed 2 run 3 done 4 aborted
	.equ	AT_PC, 4		! op pointer
	.equ	AT_WAIT, 8		! tick: next op not before
	.equ	AT_DEADL, 12		! tick: hard stop (RUN + 40 min, R21 kit; was 15)
	.equ	AT_KLVL, 16		! level word being held (0 none)
	.equ	AT_KVAL, 20
	.equ	AT_KEND, 24		! tick: release
	.equ	AT_ROT, 28		! detents left (signed)
	.equ	AT_RNXT, 32		! panel frames to the next detent
	.equ	AT_TX, 36
	.equ	AT_TY, 40
	.equ	AT_TEND, 44		! tick: touch up
	.equ	AT_STEP, 48		! MARK id (stamped into every USB log record)
	.equ	AT_WHY, 52		! abort reason
	.equ	AT_LSP, 56		! loop stack pointer (offset into AT_LS)
	.equ	AT_STEPT, 60		! tick of the MARK
	.equ	AT_RAW, 64		! previous raw frame bytes 0x0C..0x1B (16)
	.equ	AT_NOISE, 80		! bits that toggled on their own while ARMED (16)
	.equ	AT_LS, 96		! 4 x {count, op ptr}
	.equ	AT_ACK, 156		! V4n26: seq of the last ACK op run (network commander, mods/usblog)
	.equ	AT_SRC, 160		! V4n26: 'NETC' = the script is the commander's (the loader clears it)
	.equ	AT_TNB, 164		! R21 kit: the TOUCH holding now is a drag segment (a = 1): ops go on
	.equ	AT_MOP, 168		! R21 kit: MEM request = an op image (+0 op 8 = pending, +2 len, +4 addr) that
	.equ	AT_MSEQ, 180		!   mods/usblog's at_watch turns into a 'V3MM' record; +180 its seq
	.equ	AT_MT, 184		!   tick of the request (a request nobody takes for 2 s is replaced)
	.equ	T_BASE, 128		! at_tick's fields (r11 = block + T_BASE)
	.equ	T_ARMT, 0		!   tick ARMED began
	.equ	T_ENDT, 4		!   tick DONE / ABORT was seen
	.equ	T_NOPS, 8		!   ops in the script
	.equ	T_RUNT, 12		!   tick RUN began
	.equ	T_LOADS, 16		!   scripts loaded since boot
	.equ	OPS, 192		! the file: header (16) + ops
	.equ	OPS_MAX, 3856		! 16 + 480 x 8
	.equ	BLK, 4096		! malloc'd once

	.equ	ST_ARMED, 1
	.equ	ST_RUN, 2
	.equ	ST_DONE, 3
	.equ	ST_ABORT, 4
	.equ	ROT_GAP, 12		! panel frames between detents (~160 ms; faster bursts accelerate)

! fcall reg: a firmware call with the fpscr the firmware expects (SZ/PR clear).
! Clobbers r2, r3 (plus the callee's r0-r7).
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
	.global	autotest
autotest:
	bra	at_pre			! +0  H1
	nop
	bra	at_cal			! +4  H2
	nop
	bra	at_tick			! +8  TchAud, once per loop pass
	nop
	.p2align 2
at_ptr:	.long	0			! +12 the run-time block (malloc'd), 0 none
at_next: .long	0			! +16 tick of the next loader check
at_mnt:	.long	0			! +20 loader checks since the stick mounted

! --------------------------------------------------------------- at_pre ----
! H1. r0 = 1: the decoder skips this frame (our level word stays as written);
! r0 = 0: normal decode. Pioneer's debug-console flag keeps its meaning first.
at_pre:
	mov.l	ap_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	ap_stock
	mova	ap_pp,r0
	mov.l	@r0,r1
	add	r0,r1
	mov.l	@r1,r1			! the block
	tst	r1,r1
	bt	ap_stock
	mov.l	ap_dbg,r2
	mov.l	@r2,r0
	tst	r0,r0
	bf	ap_ret			! console active: its answer, untouched
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	sts.l	pr,@-r15
	mov	r1,r8
	mov.l	@(AT_STATE,r8),r0
	cmp/eq	#ST_RUN,r0
	bt	ap_run
	cmp/eq	#ST_ARMED,r0
	bf	ap_out0
	bsr	raw_learn		! ARMED: learn the noisy bits, nothing else
	nop
	bra	ap_out0
	nop
ap_stock:
	mov.l	ap_dbg,r1		! = stock 0x08201310: return *0x10DBE75C
	rts
	mov.l	@r1,r0
ap_ret:
	rts
	nop

ap_run:
	mov.l	ap_tick,r1
	mov.l	@r1,r9			! r9 = now (ms)
	mov.l	@(AT_DEADL,r8),r1	! the run-time cap (tk_cap)
	mov	r9,r0
	sub	r1,r0
	cmp/pz	r0
	bt	ab_cap
	bsr	raw_check		! a real panel input: r0 = reason
	nop
	tst	r0,r0
	bt	9f
	mov.l	r0,@(AT_WHY,r8)		! V4n17 (user, temporary): a real key / rotary is only LOGGED (the
9:					! record stamp carries AT_WHY), the script goes on -- no abort

	mov.l	@(AT_KLVL,r8),r2	! a held key: keep it written, skip the decode
	tst	r2,r2
	bt	ap_rot
	mov.l	@(AT_KEND,r8),r1
	mov	r9,r0
	sub	r1,r0
	cmp/pz	r0
	bt	ap_krel
	mov.l	@(AT_KVAL,r8),r1
	mov.l	r1,@r2			! level = value
	bra	ap_out1
	nop
ap_krel:
	mov	#0,r1
	mov.l	r1,@r2			! level = 0; the decoder runs again from
	mov.l	r1,@(AT_KLVL,r8)	! this frame on and keeps it (real panel)

ap_rot:	! rotary: one detent every ROT_GAP frames through the bias word
	mov.l	@(AT_ROT,r8),r2
	tst	r2,r2
	bt	ap_touch
	mov.l	@(AT_RNXT,r8),r0
	tst	r0,r0
	bt	1f
	add	#-1,r0
	mov.l	r0,@(AT_RNXT,r8)
	bra	ap_out0
	nop
1:	mov	#ROT_GAP,r0
	mov.l	r0,@(AT_RNXT,r8)
	mov.l	ap_bias,r1		! 0x10DE15C0: u16 added to report[0x0E] by the
	mov.w	@r1,r3			! rotary setter 0x084E11F4
	cmp/pz	r2
	bf	2f
	add	#-1,r2
	bra	3f
	add	#1,r3
2:	add	#1,r2
	add	#-1,r3
3:	mov.w	r3,@r1
	mov.l	r2,@(AT_ROT,r8)
	bra	ap_out0
	nop

ap_touch:	! touch: at_cal puts the point in; here only the release
	mov.l	@(AT_TEND,r8),r1
	tst	r1,r1
	bt	ap_step
	mov	r9,r0
	sub	r1,r0
	cmp/pz	r0
	bt	1f
	mov.w	ap_tnbo,r0		! R21 kit: a drag segment holds while the next ops run
	mov.l	@(r0,r8),r0
	tst	r0,r0
	bt	ap_out0
	bra	ap_step
	nop
ap_tnbo:	.word	AT_TNB
1:	mov	#0,r1
	mov.l	r1,@(AT_TEND,r8)
	mov.l	r1,@(AT_TX,r8)		! (at_cal stops overriding)

ap_step:	! next op once the wait is over
	mov.l	@(AT_WAIT,r8),r1
	mov	r9,r0
	sub	r1,r0
	cmp/pz	r0
	bf	ap_out0
	bsr	exec_op			! one op per frame; a KEY skips this decode
	nop
	tst	r0,r0
	bt	ap_out0
ap_out1:
	mov	#1,r0
	bra	ap_pop
	nop
ab_cap:
	mov	#5,r0
ab_r0:	mov.l	r0,@(AT_WHY,r8)
	mov	#ST_ABORT,r0
	mov.l	r0,@(AT_STATE,r8)
	mov.l	@(AT_KLVL,r8),r2	! drop a held key (the decoder rewrites it anyway)
	tst	r2,r2
	bt	1f
	mov	#0,r1
	mov.l	r1,@r2
	mov.l	r1,@(AT_KLVL,r8)
1:	mov	#0,r1
	mov.l	r1,@(AT_ROT,r8)
	mov.l	r1,@(AT_TEND,r8)
	mov.l	r1,@(AT_TX,r8)
ap_out0:
	mov	#0,r0
ap_pop:
	lds.l	@r15+,pr
	mov.l	@r15+,r9
	rts
	mov.l	@r15+,r8
	.p2align 2
ap_pp:		.long	at_ptr - ap_pp
ap_dbg:		.long	0x10DBE75C
ap_tick:	.long	0x0B0C5258
ap_boot:	.long	0x0A35DF3C
ap_bias:	.long	0x10DE15C0

! --------------------------------------------------------------- exec_op ---
! r8 = block, r9 = now. Returns r0 = 1 if a key press started (skip the decode).
! CMDFIX (hang47): every op is checked before it runs; a bad one ABORTs the script (AT_WHY 8):
! the PC inside the op area [OPS + 16, OPS + OPS_MAX) on an op boundary, op 0 = END (DONE), 1..7 / 9
! known (else abort), KEY level offset a word of the key table (0..0x1FC) held <= 3000 ms (R21 kit), TOUCH
! inside 800 x 480 held <= 2 s, LOOP count 0 -> 1.
exec_op:
	mov.l	@(AT_PC,r8),r4
	mov	r4,r0			! CMDFIX: the PC check
	sub	r8,r0
	mov.w	eo_ops0,r1
	sub	r1,r0			! r0 = PC - (block + OPS + 16)
	mov.w	eo_opsn,r1
	cmp/hs	r1,r0			! >= OPS_MAX - 16 (also < 0, unsigned): outside
	bt	eo_bad
	tst	#7,r0
	bf	eo_bad
	mov.b	@(1,r4),r0		! a (signed)
	mov	r0,r5
	mov.w	@(2,r4),r0		! b
	extu.w	r0,r6
	mov.l	@(4,r4),r7		! c
	mov.b	@r4,r0			! op
	extu.b	r0,r0
	add	#8,r4
	mov.l	r4,@(AT_PC,r8)
	cmp/eq	#1,r0
	bt	op_key
	cmp/eq	#2,r0
	bt	op_rot
	cmp/eq	#3,r0
	bt	op_touch
	cmp/eq	#4,r0
	bt	op_wait
	cmp/eq	#5,r0
	bt	op_mark
	cmp/eq	#6,r0
	bt	op_loop
	cmp/eq	#7,r0
	bt	op_endl
	cmp/eq	#9,r0
	bt	op_ack
	cmp/eq	#8,r0
	bt	op_mem
	tst	r0,r0			! CMDFIX: 0 = END: done; any other op: abort (8)
	bf	eo_bad
	mov	#ST_DONE,r0
	mov.l	r0,@(AT_STATE,r8)
	rts
	mov	#0,r0
eo_bad:	mov	#8,r0			! CMDFIX: a bad op / PC: ABORT (8), nothing of it runs
	mov.l	r0,@(AT_WHY,r8)
	mov	#ST_ABORT,r0
	mov.l	r0,@(AT_STATE,r8)
	rts
	mov	#0,r0
op_key:
	mov	r6,r0			! CMDFIX: b = a word of the key table (0..0x1FC), held <= 3000 ms (R21 kit)
	tst	#3,r0
	bf	eo_bad
	mov.w	eo_kmax,r1
	cmp/hi	r1,r0
	bt	eo_bad
	mov.w	eo_k500,r1
	cmp/hi	r1,r7
	bf	1f
	mov	r1,r7
1:	mov.l	eo_lvl,r1
	add	r6,r1			! level word = 0x0B54C990 + b
	extu.b	r5,r5
	mov.l	r5,@r1
	mov.l	r1,@(AT_KLVL,r8)
	mov.l	r5,@(AT_KVAL,r8)
	mov	r9,r0
	add	r7,r0
	mov.l	r0,@(AT_KEND,r8)
	add	#40,r0			! >= 40 ms gap after the release
	mov.l	r0,@(AT_WAIT,r8)
	rts
	mov	#1,r0
op_rot:
	mov.l	r5,@(AT_ROT,r8)
	mov	#0,r0
	mov.l	r0,@(AT_RNXT,r8)
	rts
	mov	#0,r0
op_touch:
	tst	r6,r6			! CMDFIX: 0 < x < 800, 0 < y < 480, held <= 2 s
	bt	eo_bad
	mov.w	eo_800,r1
	cmp/hs	r1,r6
	bt	eo_bad
	extu.w	r7,r0
	tst	r0,r0
	bt	eo_bad
	mov.w	eo_480,r1
	cmp/hs	r1,r0
	bt	eo_bad
	mov.l	r6,@(AT_TX,r8)
	mov.l	r0,@(AT_TY,r8)
	shlr16	r7
	mov.w	eo_t2000,r1
	cmp/hi	r1,r7
	bf	1f
	mov	r1,r7
1:
	mov	r9,r0
	add	r7,r0
	mov.l	r0,@(AT_TEND,r8)
	mov	#1,r1			! R21 kit: a bit 0 = a drag segment (no wait for the lift)
	and	r5,r1
	mov.w	eo_tnb,r0
	mov.l	r1,@(r0,r8)
	rts
	mov	#0,r0
op_wait:
	mov	r9,r0
	add	r7,r0
	mov.l	r0,@(AT_WAIT,r8)
	rts
	mov	#0,r0
op_mark:
	mov.l	r6,@(AT_STEP,r8)
	mov.l	r9,@(AT_STEPT,r8)
	rts
	mov	#0,r0
op_loop:	! push {count, pc}
	tst	r6,r6			! CMDFIX: count 0 -> 1 (dt would wrap: 2^32 rounds)
	bf	2f
	mov	#1,r6
2:	mov.l	@(AT_LSP,r8),r0
	mov	#24,r1
	cmp/hi	r1,r0			! > 3 levels deep already: ignore (atc.py refuses it)
	bt	1f
	mov	r8,r1
	add	#AT_LS,r1
	add	r0,r1
	mov.l	r6,@r1
	mov.l	r4,@(4,r1)
	add	#8,r0
	mov.l	r0,@(AT_LSP,r8)
1:	rts
	mov	#0,r0
op_endl:
	mov.l	@(AT_LSP,r8),r0
	tst	r0,r0
	bt	2f			! no open LOOP: ignore
	add	#-8,r0
	mov	r8,r1
	add	#AT_LS,r1
	add	r0,r1
	mov.l	@r1,r2
	dt	r2
	bt	1f			! count done: pop
	mov.l	r2,@r1
	mov.l	@(4,r1),r2
	mov.l	r2,@(AT_PC,r8)
	rts
	mov	#0,r0
1:	mov.l	r0,@(AT_LSP,r8)
2:	rts
	mov	#0,r0
op_ack:	! V4n26: ACK (only the network commander queues it, mods/usblog cmd_pkt): c = its datagram's seq
	mov	#AT_ACK / 2,r0
	shll	r0
	mov.l	r7,@(r0,r8)
	rts
	mov	#0,r0
op_mem:	! R21 kit: one pending request; while usblog has not taken the last one (< 2 s) the op is retried
	mov.w	eo_mop,r0
	mov.b	@(r0,r8),r0
	cmp/eq	#8,r0
	bf	1f
	mov.w	eo_mt,r0
	mov.l	@(r0,r8),r1
	mov	r9,r0
	sub	r1,r0
	mov.w	eo_t2000,r1
	cmp/hs	r1,r0
	bt	1f
	add	#-8,r4			! busy: the same op again next frame
	mov.l	r4,@(AT_PC,r8)
	rts
	mov	#0,r0
1:	mov	r8,r1
	mov.w	eo_mop,r0
	add	r0,r1			! r1 = the op image
	mov.l	r7,@(4,r1)		! addr
	mov	r6,r0
	mov.w	r0,@(2,r1)		! len
	mov.l	@(12,r1),r0		! seq++ (AT_MSEQ = AT_MOP + 12)
	add	#1,r0
	mov.l	r0,@(12,r1)
	mov.l	r9,@(16,r1)		! AT_MT = AT_MOP + 16
	mov	#8,r0
	rts
	mov.b	r0,@r1			! pending: the op byte last
eo_ops0:	.word	OPS + 16		! CMDFIX: the first op slot
eo_opsn:	.word	OPS_MAX - 16		! CMDFIX: the op area's length
eo_kmax:	.word	0x1FC			! CMDFIX: the key table's last level word (atc.py KEYS <= 0x1D0)
eo_k500:	.word	3000			! R21 kit: 3 s (a long press: MENU -> UTILITY); was 500
eo_800:		.word	800
eo_480:		.word	480
eo_t2000:	.word	2000
eo_tnb:		.word	AT_TNB
eo_mop:		.word	AT_MOP
eo_mt:		.word	AT_MT
	.p2align 2
eo_lvl:	.long	0x0B54C990

! --------------------------------------------------- raw_learn / raw_check --
! Raw frame copy 0x0B06C700 (PnlCom_RcvTASK copies the checked frame there before
! the decoder runs). Bytes 0x0C..0x1B: keys (0x0C,0x0D,0x10-0x15), rotary counter
! 0x0E, jog 0x0F (only 0x20 = jog touch is a key). (Raw touch X/Y 0x16..0x19 are not
! used: the deck's pen-up raw values are unknown; at_cal tests the calibrated point.)
raw_learn:	! NOISE |= RAW ^ frame; RAW = frame
	mov.l	rc_frame,r1
	add	#0x0C,r1
	mov	r8,r2
	add	#AT_RAW,r2
	mov	r8,r3
	add	#AT_NOISE,r3
	mov	#16,r7
1:	mov.b	@r1+,r4
	mov.b	@r2,r5
	mov.b	r4,@r2
	xor	r4,r5
	mov.b	@r3,r6
	or	r5,r6
	mov.b	r6,@r3
	add	#1,r2
	dt	r7
	bf/s	1b
	add	#1,r3
	rts
	nop

raw_check:	! r0 = 1 key edge, 2 rotary moved, 0 none (a finger: at_cal, from the calibrated point)
	mov.l	rc_frame,r1
	mov	r8,r2
	add	#AT_RAW,r2
	mov	#0x0E,r0		! the rotary counter moved (ours goes through the
	mov.b	@(r0,r1),r4		! bias word, not the raw frame)
	mov.b	@(2,r2),r0
	cmp/eq	r0,r4
	bt	2f
	mov	r4,r0
	mov.b	r0,@(2,r2)
	rts
	mov	#2,r0
2:	add	#0x0C,r1		! rising edges in the key bytes 0x0C..0x15
	mov	r8,r3
	add	#AT_NOISE,r3
	mova	rc_keym,r0
	mov	r0,r6
	mov	#10,r7
	mov	#0,r0
3:	mov.b	@r1+,r4			! now
	mov.b	@r2,r5			! before
	mov.b	r4,@r2
	not	r5,r5
	and	r4,r5			! rising
	mov.b	@r6+,r4
	and	r4,r5			! key bits only
	mov.b	@r3+,r4
	not	r4,r4
	and	r4,r5			! minus the noisy ones
	or	r5,r0
	dt	r7
	bf/s	3b
	add	#1,r2
	extu.b	r0,r0
	tst	r0,r0
	bt	4f
	mov	#1,r0
4:	rts
	nop
	.p2align 2
rc_frame:	.long	0x0B06C700
rc_keym:	.byte	0xFF, 0xFF, 0x00, 0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.p2align 2

! --------------------------------------------------------------- at_cal ----
! H2: r4 = &x, r5 = &y (raw in, calibrated out). The stock calibration, then our
! point while a TOUCH op holds (AT_TX != 0). Off a normal boot / without a block:
! a tail jump to the stock routine (pr untouched).
at_cal:
	mov.l	ac_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	ac_stock
	mova	ac_pp,r0
	mov.l	@r0,r1
	add	r0,r1
	mov.l	@r1,r1
	tst	r1,r1
	bf	ac_ours
ac_stock:
	mov.l	ac_orig,r0
	jmp	@r0
	nop
ac_ours:
	sts.l	pr,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	ac_orig,r0
	jsr	@r0
	nop
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	mova	ac_pp,r0
	mov.l	@r0,r1
	add	r0,r1
	mov.l	@r1,r1			! the block
	mov.l	@(AT_STATE,r1),r0
	cmp/eq	#ST_RUN,r0
	bf	1f
	mov.l	@(AT_TX,r1),r2
	tst	r2,r2
	bt	2f
	mov.l	r2,@r4
	mov.l	@(AT_TY,r1),r2
	mov.l	r2,@r5
1:	lds.l	@r15+,pr
	rts
	nop
2:	mov.l	@r4,r2			! not our touch: a real finger is what the decoder itself
	cmp/pl	r2			! takes as one, 0 < x < 800 and 0 < y < 480 -> ABORT (3)
	bf	1b
	mov.w	ac_800,r0
	cmp/ge	r0,r2
	bt	1b
	mov.l	@r5,r2
	cmp/pl	r2
	bf	1b
	mov.w	ac_480,r0
	cmp/ge	r0,r2
	bt	1b
	mov	#3,r0			! V4n17 (temporary): a real touch is only logged, no abort
	bra	1b
	mov.l	r0,@(AT_WHY,r1)
ac_800:		.word	800
ac_480:		.word	480
	.p2align 2
ac_pp:		.long	at_ptr - ac_pp
ac_boot:	.long	0x0A35DF3C
ac_orig:	.long	0x084C37E4

! -------------------------------------------------------------- at_tick ----
! TchAud, every loop pass (r4 = touch_audio's data, unused). ARMED -> RUN after
! 3 s, NOMODS -> ABORT, and every 2 s the loader: 4 s after the stick mounted (and
! once more 2 s later) C:/V3TEST/SCRIPT.BIN is read into the block (malloc'd the
! first time) and checked; ARMED on success, ABORT (7) on a bad file. One try per
! mount: the stick has to be re-mounted to run a script again.
at_tick:
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	sts.l	pr,@-r15
	mov.l	tk_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	tk_out
	mov.l	tk_tick,r1
	mov.l	@r1,r9			! r9 = now
	mova	tk_base,r0
	mov.l	@r0,r10
	add	r0,r10			! r10 = the blob (+12 the block, +16 next, +20 mnt)
	mov.l	@(12,r10),r8		! r8 = the block (0 none)
	tst	r8,r8
	bt	tk_load
	mov	r8,r11
	add	#64,r11
	add	#64,r11			! r11 = block + T_BASE (128: past mov #imm)
	mov.l	@(AT_STATE,r8),r0
	cmp/eq	#ST_ARMED,r0
	bf	1f
	mov.l	@(T_ARMT,r11),r1	! ARMED for 3 s: RUN
	mov	r9,r0
	sub	r1,r0
	mov.w	tk_3000,r1
	cmp/hs	r1,r0
	bf	tk_load
	mov.l	tk_cap,r1
	add	r9,r1
	mov.l	r1,@(AT_DEADL,r8)
	mov.l	r9,@(AT_WAIT,r8)
	mov.l	r9,@(T_RUNT,r11)
	mov	#ST_RUN,r0
	mov.l	r0,@(AT_STATE,r8)
	bra	tk_load
	nop
1:	cmp/eq	#ST_RUN,r0
	bf	2f
	mov.l	tk_kill,r1		! NOMODS / MODS OFF while running: abort (6)
	mov.l	@r1,r1
	mov.l	tk_nomo,r2
	cmp/eq	r1,r2
	bf	tk_load
	mov	#6,r0
	mov.l	r0,@(AT_WHY,r8)
	mov	#ST_ABORT,r0
	mov.l	r0,@(AT_STATE,r8)
	bra	tk_load
	nop
2:	cmp/eq	#ST_DONE,r0		! DONE / ABORT: the end tick, once
	bt	3f
	cmp/eq	#ST_ABORT,r0
	bf	tk_load
3:	mov.l	@(T_ENDT,r11),r0
	tst	r0,r0
	bf	tk_load
	mov.l	r9,@(T_ENDT,r11)

tk_load:
	mov.l	@(16,r10),r1		! every 2 s
	mov	r9,r0
	sub	r1,r0
	cmp/pz	r0
	bf	tk_out
	mov.w	tk_2000,r0
	add	r9,r0
	mov.l	r0,@(16,r10)
	mov.l	tk_usb,r1		! USB state word: 3 = mounted (re/USB_KEY_STEADY.md)
	mov.l	@r1,r0
	cmp/eq	#3,r0
	bt	1f
	mov	#0,r0
	bra	tk_out
	mov.l	r0,@(20,r10)		! not mounted: the next mount loads again
1:	mov.l	@(20,r10),r0
	cmp/eq	#4,r0
	bt	tk_out			! tried twice on this mount
	add	#1,r0
	mov.l	r0,@(20,r10)
	cmp/eq	#3,r0
	bt	2f
	cmp/eq	#4,r0
	bf	tk_out
2:	mov.l	tk_kill,r1		! not while the mods are off
	mov.l	@r1,r1
	mov.l	tk_nomo,r2
	cmp/eq	r1,r2
	bt	tk_out
	tst	r8,r8			! a script already armed / running: leave it
	bt	3f
	mov.l	@(AT_STATE,r8),r0
	cmp/eq	#ST_ARMED,r0
	bt	tk_out
	cmp/eq	#ST_RUN,r0
	bt	tk_out
3:	mova	tk_path,r0
	mov	r0,r4
	mov.l	tk_fopen,r1
	fcall	r1
	tst	r0,r0
	bt	tk_out			! no script on this stick
	mov	r0,r11			! r11 = the handle
	mov	#4,r0			! found: no second try on this mount
	mov.l	r0,@(20,r10)
	tst	r8,r8
	bf	4f
	mov.w	tk_blk,r4		! the block, once
	mov.l	tk_malloc,r1
	fcall	r1
	tst	r0,r0
	bt	tk_close
	mov	r0,r8
	mov.l	r8,@(12,r10)
	mov	r8,r1			! cleared
	mov.w	tk_blk,r2
	shlr2	r2
	mov	#0,r0
5:	mov.l	r0,@r1
	dt	r2
	bf/s	5b
	add	#4,r1
4:	mov	#0,r0			! a new script: the state words cleared (0..191)
	mov	r8,r1
	mov	#48,r2
6:	mov.l	r0,@r1
	dt	r2
	bf/s	6b
	add	#4,r1
	mov	r8,r4			! fread(block + OPS, 1, OPS_MAX, fh)
	mov.w	tk_ops,r0
	add	r0,r4
	mov	#1,r5
	mov.w	tk_opsmax,r6
	mov	r11,r7
	mov.l	tk_fread,r1
	fcall	r1
	mov.l	r0,@-r15		! bytes read
	mov	r11,r4
	mov.l	tk_fclose,r1
	fcall	r1
	mov.l	@r15+,r6		! r6 = bytes read
	mov	r8,r11
	add	#64,r11
	add	#64,r11			! r11 = block + 128 again
	mov.l	@(T_LOADS,r11),r0
	add	#1,r0
	mov.l	r0,@(T_LOADS,r11)
	mov	r8,r4
	mov.w	tk_ops,r0
	add	r0,r4			! r4 = the file
	mov	#24,r0			! >= header + one op + END
	cmp/ge	r0,r6
	bf	tk_bad
	mov.l	@r4,r1
	mov.l	tk_magic,r2
	cmp/eq	r1,r2
	bf	tk_bad
	mov.w	@(4,r4),r0
	extu.w	r0,r5			! r5 = ops
	mov.l	r5,@(T_NOPS,r11)
	tst	r5,r5
	bt	tk_bad
	mov	r5,r7
	shll2	r7
	add	r7,r7			! r7 = ops x 8
	mov	r7,r0
	add	#16,r0
	cmp/gt	r6,r0			! file shorter than its header says
	bt	tk_bad
	mov.w	tk_opsmaxb,r0
	cmp/hi	r0,r7
	bt	tk_bad
	mov	r4,r1			! byte sum of the ops
	add	#16,r1
	mov	#0,r2
7:	mov.b	@r1+,r0
	extu.b	r0,r0
	dt	r7
	bf/s	7b
	add	r0,r2
	extu.w	r2,r2
	mov.w	@(6,r4),r0
	extu.w	r0,r0
	cmp/eq	r0,r2
	bf	tk_bad
	add	#16,r4
	mov.l	r4,@(AT_PC,r8)		! armed: at_pre learns the noise for 3 s
	mov.l	r9,@(T_ARMT,r11)
	mov	#ST_ARMED,r0
	bra	tk_out
	mov.l	r0,@(AT_STATE,r8)
tk_bad:
	mov	#7,r0
	mov.l	r0,@(AT_WHY,r8)
	mov.l	r9,@(T_ENDT,r11)
	mov	#ST_ABORT,r0
	bra	tk_out
	mov.l	r0,@(AT_STATE,r8)
tk_close:
	mov	r11,r4
	mov.l	tk_fclose,r1
	fcall	r1
tk_out:
	lds.l	@r15+,pr
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	rts
	mov.l	@r15+,r8
tk_3000:	.word	3000
tk_2000:	.word	2000
tk_blk:		.word	BLK
tk_ops:		.word	OPS
tk_opsmax:	.word	OPS_MAX
tk_opsmaxb:	.word	OPS_MAX - 16
	.p2align 2
tk_base:	.long	autotest - tk_base
tk_boot:	.long	0x0A35DF3C
tk_tick:	.long	0x0B0C5258
tk_cap:		.long	40 * 60 * 1000		! R21 kit: 40 min (the deck kit's single run: functions + soak)
tk_kill:	.long	RAMB+0x1F7F0		! touch_audio's kill word ("NOMO" = mods off)
tk_nomo:	.long	0x4F4D4F4E
tk_usb:		.long	0x0A35F3AC
tk_magic:	.long	0x31535441		! "ATS1"
tk_fopen:	.long	0x082C0D2A		! fopen(path16) "r" (file manager thunk)
tk_fread:	.long	0x082C0D44		! fread(buf, 1, n, fh)
tk_fclose:	.long	0x082C0D56		! fclose(fh)
tk_malloc:	.long	0x08344A9C
tk_path:	.short	'C', ':', '/', 'V', '3', 'T', 'E', 'S', 'T', '/'
		.short	'S', 'C', 'R', 'I', 'P', 'T', '.', 'B', 'I', 'N', 0
	.p2align 2
