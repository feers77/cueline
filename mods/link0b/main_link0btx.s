! SPDX-License-Identifier: Apache-2.0
!
! link0btx (v4.2 DEV prototype, MAIN, SH-4 LE): the CDJ-3000's precise-position packet (type 0x0b, UDP 50001,
! every ~30 ms) from a CDJ-2000NXS2, and the master's 0x0b position for the GUI's LINK meter.
!
! Hook: the DJcont output task's loop right after it recomputes the play position word 0x09947488 (patch_main
! DJCONT_PASS, as mods/tcnet tcnettime), so the position sent is the freshest the deck has. Each pass:
!  1. PUBLISH (always on a normal boot): staged at L0B + 0x30 / 0x34 / 0x38; modsmenu mm_copy (LINK0B) writes them
!     into heartbeat words +0x104 / +0x108 / +0x10C right before each copy of the block (LE there, the GUI reads
!     them u32be at DECK + 0x104.., zero in every dump; nothing in stock MAIN addresses them) for v2.c:
!       W1 +0x104  the master's position in 1/8 ms, extrapolated here to this pass (the CDJ-3000's getter 
!                  0xe5d2c0: pos + (now - rx) x pitch; held -- no extrapolation -- once the 0x0b is > 64 ms old;
!                  stopped = the same position twice)
!       W2 +0x108  0x0B << 24 | flags << 20 (1 valid, 2 moving = extrapolate on, 4 held, 8 stopped) | master << 16 |
!                  the MAIN ms tick, low 16 bits (the GUI's clock offset is a min filter over it)
!       W3 +0x10C  check << 24 | speed 16.16 (0 when not moving); check = (W1 ^ W2 ^ 0xA5) & 0xFF
!     W1 / W3 are stored before W2 (a copy taken between them fails the check: the GUI keeps its last sample).
!     With UTILITY LINK 0x0B OFF, no master 0x0b or a stale one (no 0x0b for 1 s), W2 carries the tick only.
!  2. EMIT (UTILITY LINK 0x0B ON, a track loaded): every 30 ms one 60-B 0x0b, the CDJ-3000's layout and bytes,
!     name "CDJ-2000NXS2" (we stay an NXS2 everywhere), unicast to every player 1..6 whose class is a CDJ-3000 /
!     3000X (ks3k KCLS 3) or a Cueline deck (ks3k L0B_CUE). Nothing to DJMs, rekordbox, stock NXS2s or unknown
!     devices. The send is the Pro DJ Link beat packet's wrapper 0x085113EC (mode 0 = unicast to the device
!     table's address 0x0A35F80C + p * 0x414), as tcnettime broadcasts.
!  3. DEV (not RELEASE): the GUI's meter debug record (TX frame +0xFC0, 'MTR1') goes out as one broadcast UDP
!     datagram to port 50097 with MAIN's tick, for the emulator's meter-error measurement (work/link0b).
!
! Update safety: only on *0x0A35DF3C == 1; no malloc, no task; r8-r13 saved.

	.include "layout.inc"
	.include "link0b.inc"

	.equ	HB, 0x0B568C9C		! the heartbeat model (copied to the GUI every frame)

	.text
	.global link0btx
link0btx:
	sts.l	pr,@-r15
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15
	mov.l	t_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bt	0f
	bra	out
	nop
0:	mov.l	t_l0b,r8
	mov	#0x18,r0
	mov.l	@(r0,r8),r1
	mov.l	t_l0bm,r2
	cmp/eq	r2,r1
	bt	1f
	mov	r8,r1			! once: clear the block (RAMB is 0xFF there): 128 words
	mov	#64,r3
	shll	r3
	mov	#0,r0
2:	mov.l	r0,@r1
	dt	r3
	bf/s	2b
	add	#4,r1
	mov	#0x18,r0
	mov.l	r2,@(r0,r8)
1:	mov.l	t_dev,r1
	mov.b	@r1,r0
	extu.b	r0,r13			! r13 = our player number
	mov	r13,r0
	add	#-1,r0
	mov	#5,r1
	cmp/hi	r1,r0
	bf	0f
	bra	out
	nop
0:	mov.l	t_kill,r1
	mov.l	@r1,r9			! r9 = UTILITY LINK 0x0B (1 ON)
	bsr	now
	nop
	mov	r0,r10			! r10 = the tick (ms)
	mov	r1,r11			! r11 = microseconds into it

! ---- 1. PUBLISH ----
	mov	#0,r4			! W1
	mov	#0,r5			! flags << 20 | master << 16
	mov	#0,r6			! speed 16.16
	tst	r9,r9
	bt	p_w
	mov.l	t_hb,r1
	mov	#0x54,r0
	shll	r0			! 0xA8
	add	#-4,r0			! 0xA4: the master player
	mov.l	@(r0,r1),r12
	mov	r12,r0
	add	#-1,r0
	mov	#5,r1
	cmp/hi	r1,r0
	bt	p_w
	cmp/eq	r13,r12			! we are the master: nothing to draw
	bt	p_w
	mov	r12,r7
	shll2	r7
	shll2	r7
	shll	r7
	add	#L0B_REC,r7
	add	r8,r7			! r7 = the master's record
	mov.l	@(16,r7),r1		! its last arrival
	mov	r10,r0
	sub	r1,r0
	mov.l	t_1000l,r1
	cmp/hs	r1,r0			! no 0x0b for 1 s (or never): not a 0x0b master
	bt	p_w
	mov.l	@r7,r4
	shll2	r4
	shll	r4			! W1 = the position x 8
	mov	r12,r5
	shll16	r5
	mov.l	@(4,r7),r1		! its arrival, 0 = stopped
	tst	r1,r1
	bf	3f
	mov.l	t_f9,r0			! valid | stopped
	bra	p_w
	or	r0,r5
3:	mov	r10,r0
	sub	r1,r0			! ms since
	mov.l	t_1000l,r2
	mul.l	r2,r0
	sts	macl,r0
	add	r11,r0
	mov.l	@(8,r7),r1
	sub	r1,r0			! r0 = microseconds since its arrival
	mov.l	t_64k,r1
	cmp/hi	r1,r0			! > 64 ms (or negative): held, no extrapolation (the 3000's 64-ms rule)
	bf	4f
	mov.l	t_f5,r0			! valid | held
	bra	p_w
	or	r0,r5
4:	mov.l	@(12,r7),r1		! pitch, percent x 100
	mov.l	t_26844l,r2		! 65536 / 10000 = 26844 / 4096
	mul.l	r1,r2
	sts	macl,r6
	mov	#-12,r2
	shad	r2,r6
	mov.l	t_one,r1
	add	r1,r6			! r6 = speed 16.16
	dmulu.l	r0,r6
	sts	mach,r1
	sts	macl,r2
	shll16	r1
	shlr16	r2
	or	r2,r1			! (us x speed) >> 16 = track microseconds since
	mov.l	t_16777l,r2
	mul.l	r2,r1
	sts	macl,r1
	shlr16	r1
	shlr2	r1
	shlr2	r1
	shlr	r1			! x 16777 >> 21 = / 125 = 1/8 ms
	add	r1,r4
	mov.l	t_f3,r0			! valid | moving
	or	r0,r5
p_w:	extu.w	r10,r0
	or	r0,r5
	mov.l	t_magic,r0
	or	r0,r5			! W2
	mov	r4,r0
	xor	r5,r0
	xor	#0xA5,r0
	shll16	r0
	shll8	r0			! the check, top byte
	or	r0,r6			! W3 (speed < 2^24)
	mov.l	r4,@(0x30,r8)		! W1 (staged: modsmenu mm_copy puts the three words into the heartbeat
	mov.l	r6,@(0x38,r8)		! W3  block right before each copy -- the deck rebuilds the block between
	mov.l	r5,@(0x34,r8)		! W2  frames), W2 last

! ---- 2. EMIT ----
	tst	r9,r9
	bt	e_out
	mov.l	@(8,r8),r1		! the last emission
	mov	r10,r0
	sub	r1,r0
	mov	#30,r1
	cmp/hs	r1,r0
	bf	e_out
	mov.l	t_len,r1
	mov.l	@r1,r12			! the track length (s), 0 = no track
	tst	r12,r12
	bt	e_out
	mov.l	r10,@(8,r8)
	mova	pkt,r0
	mov	r0,r7			! r7 = the packet
	mov	#0x21,r0
	mov.b	r13,@(r0,r7)
	mov	#0x24,r4
	bsr	pbe32
	mov	r12,r1
	mov.l	t_pos,r1
	mov.l	@r1,r1
	bsr	pbe32
	mov	#0x28,r4
	mov.w	t_rec,r1		! our own status record: 0x0A371D3C + p x 0x124
	mul.l	r13,r1
	sts	macl,r12
	mov.l	t_recs,r1
	add	r1,r12
	mov.w	t_8c,r0
	mov.l	@(r0,r12),r2		! pitch, 0x100000 = 100 %
	mov.l	t_one20,r1
	mov	r2,r3
	sub	r1,r3			! - 100 %
	mov.w	t_10000,r1
	dmuls.l	r1,r3
	sts	mach,r1
	sts	macl,r3
	shll8	r1
	shll2	r1
	shll2	r1			! << 12
	shlr16	r3
	shlr2	r3
	shlr2	r3			! >> 20
	or	r3,r1			! percent x 100
	bsr	pbe32
	mov	#0x2C,r4
	mov.w	t_90,r0
	mov.l	@(r0,r12),r1		! BPM: bit 31 set = BPM x 100 in the low half
	cmp/pz	r1
	bt/s	5f
	mov	#0,r3
	extu.w	r1,r1
	dmulu.l	r1,r2			! x pitch
	sts	mach,r1
	sts	macl,r3
	shll8	r1
	shll2	r1
	shll2	r1
	shlr16	r3
	shlr2	r3
	shlr2	r3
	or	r1,r3			! BPM x 100 at the pitch
	mov.l	t_div10,r1
	dmulu.l	r1,r3
	sts	mach,r3
	shlr2	r3
	shlr	r3			! / 10 = BPM x 10
5:	mov	r3,r1
	bsr	pbe32
	mov	#0x38,r4
	mov	#0,r12			! r12 = the destinations sent (bits)
	mov	#1,r11			! r11 = the player
e_lp:	cmp/eq	r13,r11
	bt	e_nx
	mov.l	t_cls,r1
	add	r11,r1
	mov.b	@r1,r0
	cmp/eq	#3,r0			! a CDJ-3000 / 3000X
	bt	6f
	mov	r8,r1
	add	#L0B_CUE,r1
	add	r11,r1
	mov.b	@r1,r0
	cmp/eq	#1,r0			! a Cueline deck
	bf	e_nx
6:	mov.w	t_dsz,r1		! its address: the device table 0x0A35F80C + p x 0x414
	mul.l	r11,r1
	sts	macl,r1
	mov.l	t_devt,r2
	add	r2,r1
	mov.l	@r1,r6
	tst	r6,r6
	bt	e_nx
	mova	desc,r0
	mov	r0,r5
	mov	#60,r1
	mov.l	r1,@r5			! length
	mov	#0,r0
	mov.b	r0,@(4,r5)		! mode 0: unicast
	mov.l	r6,@(8,r5)
	mov.w	t_50001,r1
	extu.w	r1,r1
	mov.l	r1,@(16,r5)
	mova	pkt,r0
	mov	r0,r4
	bsr	send
	nop
	mov.l	@(4,r8),r0
	add	#1,r0
	mov.l	r0,@(4,r8)		! tx count
	mov	#1,r0
	shld	r11,r0
	or	r0,r12
e_nx:	add	#1,r11
	mov	#7,r0
	cmp/hs	r0,r11
	bf	e_lp
	mov.l	r12,@(12,r8)
e_out:

! ---- 3. DEV: the meter debug record ----
	.ifndef	RELEASE
	mov.l	t_rx,r7			! MAIN's RX slots (+ slot << 14): the GUI's TX frame + 0xFC0
	mov	#3,r3
7:	mov.l	@r7,r0
	mov.l	t_mtr,r1
	cmp/eq	r1,r0
	bf	8f
	mov.l	@(4,r7),r1		! seq
	mov.l	@(28,r7),r2		! tail seq
	cmp/eq	r1,r2
	bf	8f
	mov.l	@(16,r8),r2		! the last one sent
	cmp/hi	r2,r1			! newer
	bf	8f
	mov.l	r1,@(16,r8)
	mova	dbg,r0
	mov	r0,r4
	mov.l	@(0,r7),r1
	mov.l	r1,@(0,r4)		! 'MTR1'
	mov.l	@(4,r7),r1
	mov.l	r1,@(4,r4)		! seq
	mov.l	@(8,r7),r1
	mov.l	r1,@(8,r4)		! the drawn position, 1/8 ms
	mov.l	@(12,r7),r1
	mov.l	r1,@(12,r4)		! the GUI ms of that frame
	mov.l	@(16,r7),r1
	mov.l	r1,@(16,r4)		! the GUI's offset (gui - main, 16 bits) | flags << 16
	mov.l	@(20,r7),r1
	mov.l	r1,@(20,r4)		! the beat-path position, 1/8 ms
	mov.l	@(24,r7),r1
	mov.l	r1,@(24,r4)		! the 0x0b position this frame (1/8 ms, 0 none)
	mov.l	t_tick,r1
	mov.l	@r1,r1
	mov.l	r1,@(28,r4)		! MAIN's tick now
	mov.l	@(20,r8),r0
	add	#1,r0
	mov.l	r0,@(20,r8)
	mova	desc,r0
	mov	r0,r5
	mov	#32,r1
	mov.l	r1,@r5
	mov	#1,r0
	mov.b	r0,@(4,r5)		! mode 1: subnet broadcast
	mov	#0,r1
	mov.l	r1,@(8,r5)
	mov.w	t_50097,r1
	extu.w	r1,r1
	mov.l	r1,@(16,r5)
	mova	dbg,r0
	mov	r0,r4
	bsr	send
	nop
	bra	9f
	nop
8:	mov	#64,r0
	shll8	r0			! + 16 KB
	dt	r3
	bf/s	7b
	add	r0,r7
9:
	.endif
out:
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	lds.l	@r15+,pr
	rts
	nop

! pbe32: the BE u32 r1 into the packet r7 at r4. Clobbers r0, r1, r4.
pbe32:
	add	#3,r4
	mov	r4,r0
	mov.b	r1,@(r0,r7)
	shlr8	r1
	add	#-1,r0
	mov.b	r1,@(r0,r7)
	shlr8	r1
	add	#-1,r0
	mov.b	r1,@(r0,r7)
	shlr8	r1
	add	#-1,r0
	rts
	mov.b	r1,@(r0,r7)

! send: r4 the buffer, r5 the descriptor (u32 length, u8 mode, u32 destination, u8 0x60, u32 port) through the
! beat packet's send wrapper, with the fpscr mask the firmware applies before every call. Clobbers r0-r7.
send:
	sts.l	pr,@-r15
	mov.l	t_wrap,r1
	mov.l	t_fpm,r2
	sts	fpscr,r3
	and	r2,r3
	jsr	@r1
	lds	r3,fpscr
	lds.l	@r15+,pr
	rts
	nop

! now: r0 = the RTOS ms tick, r1 = the microseconds into it (mods/tcnet). Clobbers r2, r3, r5-r7, macl.
now:
	mov.l	t_tick,r1
	mov.l	t_tcnt4,r2
1:	mov.l	@r1,r3
	mov.w	@(4,r2),r0
	mov	r0,r6
	mov.l	@r2,r5
	mov.w	@(4,r2),r0
	cmp/eq	r0,r6
	bf	1b
	mov.l	@r1,r7
	cmp/eq	r3,r7
	bf	1b
	mov	r6,r0
	shlr8	r0
	and	#1,r0
	add	r3,r0
	mov.w	t_tcor4,r6
	sub	r5,r6
	mov.w	t_scale,r7
	mul.l	r7,r6
	sts	macl,r1
	rts
	shlr16	r1

t_rec:	.word	0x124
t_8c:	.word	0x8C
t_90:	.word	0x90
t_10000: .word	10000
t_dsz:	.word	0x414
t_50001: .word	50001
t_50097: .word	50097
t_tcor4: .word	10416
t_scale: .word	6291
	.p2align 2
t_boot:	.long	L0B_BOOT
t_1000l: .long	1000
t_16777l: .long	16777
t_26844l: .long	26844
t_kill:	.long	L0B_KILL
t_l0b:	.long	L0B
t_l0bm:	.long	L0B_MAGIC
t_dev:	.long	0x0AB84CFA		! our player number (byte)
t_hb:	.long	HB
t_f9:	.long	9 << 20			! valid | stopped
t_f5:	.long	5 << 20			! valid | held
t_f3:	.long	3 << 20			! valid | moving
t_magic: .long	0x0B000000
t_64k:	.long	64000
t_one:	.long	0x10000
t_one20: .long	0x100000
t_div10: .long	0xCCCCCCCD		! x / 10 = (x * this) >> 35
t_len:	.long	0x0B5125E8		! the track length, s
t_pos:	.long	0x09947488		! the play position, ms (DJcont, recomputed just before this hook)
t_recs:	.long	0x0A371D3C
t_cls:	.long	RAMB + 0x1E848		! ks3k KCLS (3 = CDJ-3000 / 3000X)
t_devt:	.long	0x0A35F80C		! the device table (+0 the address)
t_wrap:	.long	0x085113EC		! the Pro DJ Link beat packet's send wrapper
t_fpm:	.long	0xFFE7FFFF
t_tick:	.long	0x0B0C5258
t_tcnt4: .long	0xFFD90018
t_rx:	.long	0xA9072B38 + 0xFC0	! MAIN's RX slot 0 (+ slot << 14), the GUI's meter record
t_mtr:	.long	0x4D545231		! the GUI word 0x4D545231 ("MTR1" BE; a GUI BE word == a MAIN LE word)
desc:	.long	0, 0, 0, 0x60, 0
dbg:	.space	32
pkt:	.ascii	"Qspt1WmJOL"
	.byte	0x0B
	.ascii	"CDJ-2000NXS2"		! our own name (20 bytes, as in every packet we send)
	.space	8
	.byte	0x02, 0x00, 0x00	! 0x1F 2 (the 3000's subtype), 0x20 0, 0x21 the device (filled in)
	.byte	0x00, 0x18		! 0x22 the length 0x0018
	.space	60 - 0x24		! 0x24 length s, 0x28 position ms, 0x2C pitch, 0x30..0x37 0, 0x38 BPM x 10
	.p2align 2
