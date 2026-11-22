! SPDX-License-Identifier: Apache-2.0
!
! bbox, MAIN side: the BLACK BOX event recorder (opt-in: EXTRA_MODS=bbox; decoder
! work/bbox/decode_bbox.py). A RAM ring of the last 512 compact events, dumped to the stick
! as C:/BLACKBOX.BIN (appended: one self-contained dump per write) on demand, on an
! error-class event, and streamed live over the network with TEST LOG = RED.
!
! Placed only (empty sig). The TchAud task (mods/touch_audio, both variants) calls +0 once per
! loop pass with r4 = touch_audio's data block (patch_main.place_bbox puts this entry into the
! task's t_bbx word; 0 = no black box in the build: the task skips the call). TchAud exists only
! on a normal boot; *0x0A35DF3C == 1 is checked again on every call: nothing of this runs in
! update mode (main-update-safety). No hook, no task, no spawn: sampling only. The block is
! malloc'd once (8.8 KB), inside that gate.
!
! Off: modsmenu's kill switch KILLB+20 (BLACK BOX, 1 ON, the hidden page), this blob's +4
! (poke 1), or touch_audio's NOMODS ("NOMO" at RAMB+0x1F7F0).
!
! Sampling (no hooks): every 20 ms the watch table's fast entries and the manual-dump keys,
! every 250 ms the stick / play watch, the network stream and the dump, every 1 s the slow
! entries (counters) and the LINK member mask. A watched value that differs from the last one
! seen is an event {w0 tick ms, w1 type | entry << 8 | b << 16, w2 old (c), w3 new (d)}. The
! first sample of each entry only records its value (the dump header carries all of them).
!
! Dump: C:/BLACKBOX.BIN, opened "a" once a dump: a 256-byte header ('BBX1', see dump) then the
! ring's events oldest first. Taken only when writing is safe (usblog's rules plus): the stick
! mounted >= 4 s, the deck not playing (play mode not 2/3/4 and the elapsed word still >= 1 s),
! no load under way nor < 3 s ago, no Link Cue preview, no row preview. A request waits until
! then. Manual: MENU + BACK held together >= 3 s (level words; MENU long = UTILITY, BACK =
! back: no effect on the audio). Auto: an error-class event (Link Cue send / open failures, a
! load that ends with nothing loaded or takes >= 20 s), at most one a 5 min, 8 a boot; 32 dumps
! a boot in all.
!
! Network (TEST builds with usblog and UTILITY TEST LOG = RED): 'V3BB' 128-byte records to the
! LINK subnet's broadcast, UDP 50099, as usblog's (w1 tick, w2 first event's seq, w3 count, w4..
! up to 7 events), from touch_audio's endpoint, <= 4 a 250-ms poll.

	.include "layout.inc"
	.include "ownstat.inc"

	.equ	NEV, 512		! events in the ring (power of 2)
	.equ	NW, 19			! watch entries (wt_tab)
	.equ	B_WR, 0			! events written (monotonic)
	.equ	B_NRD, 4		! the next event the network sends
	.equ	B_NEXT, 8		! tick of the next fast sample
	.equ	B_NEXTS, 12		! tick of the next 250-ms poll
	.equ	B_NEXTC, 16		! tick of the next 1-s poll
	.equ	B_KEYT, 20		! tick both keys went down (0 up)
	.equ	B_KEYF, 24		! this hold fired already
	.equ	B_DREQ, 28		! a dump is pending: 1 manual, 2 auto
	.equ	B_DTRIG, 32		!   the event type that asked (0 manual)
	.equ	B_DLAST, 36		! tick of the last auto request
	.equ	B_DCNT, 40		! dumps this boot
	.equ	B_ELW, 44		! the elapsed word last seen
	.equ	B_ELT, 48		!   tick it last moved
	.equ	B_LDT, 52		! tick the play mode became 2 (loading; 0 none)
	.equ	B_LASTLD, 56		! tick of the last load event
	.equ	B_MNTT, 60		! tick the stick was first seen mounted (0 not)
	.equ	B_INIT, 64		! bit 0 fast / bit 1 slow entries / bit 2 LINK seen once
	.equ	B_DREQT, 68		! tick of the pending request
	.equ	B_DSEQ, 72		! dumps written (all boots of this file: no, this boot)
	.equ	B_AUTO, 80		! auto requests this boot
	.equ	B_LINK, 84		! the LINK member mask
	.equ	B_DST, 88		! the datagrams' destination (ip host order, port, pad)
	.equ	B_LAST, 96		! the watch entries' last values (32 words)
	.equ	B_HDR, 256		! the dump header (256 B)
	.equ	B_NET, 512		! one network record (128 B)
	.equ	B_RING, 640		! NEV x 16 B
	.equ	B_SIZE, B_RING + NEV * 16

	.equ	F_ERR, 1		! a change is an error: auto dump
	.equ	F_SLOW, 2		! sampled every 1 s (counters)
	.equ	F_TA, 4			! the address is an offset into touch_audio's data
	.equ	F_KSB, 8		! only with mods/keyshift in the build (KSB magic)
	.equ	F_BYTE, 16		! a byte (masked by the entry's mask when not 0)
	.equ	F_AUX, 32		! c = the word before the address instead of the old value
	.equ	F_OWN, 64		! the address is an offset into OUR status record (ownstat.inc)

	.equ	T_BOOT, 1		! c, d = the MAIN version string
	.equ	T_PMODE, 2		! play mode 0x0A35F7A0 (2 load, 3 play, 4 loop, 5 pause, 6 cue..)
	.equ	T_LOAD, 3		! own status rbid (BE) changed: c = src | slot << 8 | type << 16
	.equ	T_LOADEND, 4		! mode left 2: b = track length s, c = load ms, d = the mode after
	.equ	T_FLAGS, 5		! own status flags & 0x38 (0x20 MASTER, 0x10 SYNC, 0x08 on air)
	.equ	T_MASTER, 6		! the tempo master's player (0 none)
	.equ	T_KSYNC, 7		! KEY SYNC on / off
	.equ	T_KSREF, 8		! KEY SYNC refused: c = reason, d = the GUI's key word
	.equ	T_KSHIFT, 9		! KEY SHIFT engine on
	.equ	T_KSEMI, 10		! KEY SHIFT semitones
	.equ	T_LCPREV, 11		! Link Cue preview streaming (D_PREVIEW)
	.equ	T_LCE, 12		! the A9's E (LINK CUE on)
	.equ	T_LCT, 13		! the A9's T (17: this deck elected)
	.equ	T_LCCNT, 14		! a Link Cue counter moved (entry: which)
	.equ	T_NET, 15		! an NFS / dbserver retry counter moved (entry: which)
	.equ	T_LINK, 16		! the LINK member mask (players 1-6, 17, 18, mixer 33)
	.equ	T_DUMPREQ, 17		! b 0 manual / 1 auto, c = the trigger type
	.equ	T_DUMPOK, 18		! c = result (0 ok, 1 short write, 2 open failed), d = dump seq

	.equ	KSB, 0x08123000		! mods/keyshift's block (patch_main fills bb_ksb when present)

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
	.global	bbox
bbox:
	bra	bb_tick			! +0  TchAud
	nop
bb_off:	.long	0			! +4  1 = off (poke)
bb_blk:	.long	0			! +8  the block (malloc'd), 0 none
bb_tl:	.long	0			! +12 UTILITY TEST LOG word (usblog builds; patch_main), 0 none
bb_ksb:	.long	0			! +16 KSB when mods/keyshift is in the build (patch_main), 0 none
	.long	0x584F4242		! +20 "BBOX"

! r4 = touch_audio's data. Keeps r8-r14.
bb_tick:
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15
	mov.l	r14,@-r15
	sts.l	pr,@-r15
	mov.l	bt_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	bt_out
	mova	bt_base,r0
	mov.l	@r0,r10
	add	r0,r10			! r10 = the blob
	mov.l	@(4,r10),r0
	tst	r0,r0
	bf	bt_out
	mov.l	bt_kill,r1		! modsmenu kill_v +20: BLACK BOX (1 ON)
	mov.l	@r1,r0
	tst	r0,r0
	bt	bt_out
	mov.l	bt_nomo,r1
	mov.l	@r1,r0
	mov.l	bt_nmag,r1
	cmp/eq	r1,r0
	bt	bt_out
	mov.l	bt_tick,r1
	mov.l	@r1,r9			! r9 = now
	mov	r4,r12			! r12 = touch_audio data
	mov.l	@(8,r10),r8		! r8 = the block
	tst	r8,r8
	bf	1f
	mov.w	bt_size,r4		! once: the block, zeroed
	mov.l	bt_malloc,r1
	fcall	r1
	tst	r0,r0
	bt	bt_out
	mov	r0,r8
	mov.w	bt_size,r2
	shlr2	r2
	mov	#0,r1
2:	mov.l	r1,@r0
	dt	r2
	bf/s	2b
	add	#4,r0
	mov.l	r8,@(8,r10)
	mov	#T_BOOT,r4
	mov.l	bt_ver,r1
	mov.l	@r1,r6
	bsr	ev
	mov.l	@(4,r1),r7
1:	mov.l	@(B_NEXT,r8),r1		! ---- every 20 ms
	mov	r9,r0
	sub	r1,r0
	cmp/pz	r0
	bf	bt_out
	mov	#20,r0
	add	r9,r0
	mov.l	r0,@(B_NEXT,r8)
	bsr	keys
	nop
	bsr	sample
	mov	#0,r5
	mov.l	@(B_NEXTS,r8),r1	! ---- every 250 ms
	mov	r9,r0
	sub	r1,r0
	cmp/pz	r0
	bf	bt_out
	mov.w	bt_250,r0
	add	r9,r0
	mov.l	r0,@(B_NEXTS,r8)
	bsr	slow
	nop
bt_out:
	lds.l	@r15+,pr
	mov.l	@r15+,r14
	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	rts
	mov.l	@r15+,r8
bt_size:	.word	B_SIZE
bt_250:		.word	250
	.p2align 2
bt_base:	.long	bbox - bt_base
bt_boot:	.long	0x0A35DF3C
bt_kill:	.long	KILLB + 20
bt_nomo:	.long	RAMB + 0x1F7F0
bt_nmag:	.long	0x4F4D4F4E		! "NOMO"
bt_tick:	.long	0x0B0C5258
bt_malloc:	.long	0x08344A9C
bt_ver:		.long	0x08000740

! ev: one event into the ring. r4 = type | entry << 8 | b << 16, r6 = c, r7 = d; r8 = block,
! r9 = now. Clobbers r0-r2.
ev:
	mov.l	@(B_WR,r8),r0
	mov	r0,r1
	add	#1,r0
	mov.l	r0,@(B_WR,r8)
	mov.w	ev_mask,r2
	and	r2,r1
	shll2	r1
	shll2	r1
	mov.w	ev_ring,r2
	add	r2,r1
	add	r8,r1
	mov.l	r9,@r1
	mov.l	r4,@(4,r1)
	mov.l	r6,@(8,r1)
	rts
	mov.l	r7,@(12,r1)
ev_mask:	.word	NEV - 1
ev_ring:	.word	B_RING
	.p2align 2

! keys: MENU + BACK both held >= 3 s -> a manual dump request (once a hold).
keys:
	sts.l	pr,@-r15
	mov.l	ky_menu,r1
	mov.l	@r1,r0
	mov.l	ky_back,r1
	mov.l	@r1,r2
	tst	r0,r0
	bt	1f
	tst	r2,r2
	bt	1f
	mov.l	@(B_KEYT,r8),r0
	tst	r0,r0
	bf	2f
	mov	r9,r0
	or	#1,r0
	bra	9f
	mov.l	r0,@(B_KEYT,r8)
2:	mov.l	@(B_KEYF,r8),r1
	tst	r1,r1
	bf	9f
	mov	r9,r1
	sub	r0,r1
	mov.w	ky_3000,r2
	cmp/hs	r2,r1
	bf	9f
	mov	#1,r0
	mov.l	r0,@(B_KEYF,r8)
	mov.l	r0,@(B_DREQ,r8)		! manual (wins over a pending auto one)
	mov	#0,r6
	mov.l	r6,@(B_DTRIG,r8)
	mov	#B_DREQT,r0
	mov.l	r9,@(r0,r8)
	mov	#T_DUMPREQ,r4
	bsr	ev
	mov	#0,r7
	bra	9f
	nop
1:	mov	#0,r0
	mov.l	r0,@(B_KEYT,r8)
	mov.l	r0,@(B_KEYF,r8)
9:	lds.l	@r15+,pr
	rts
	nop
ky_3000:	.word	3000
	.p2align 2
ky_menu:	.long	0x0B54C9BC		! MENU / UTILITY level word (deck 0)
ky_back:	.long	0x0B54C9CC		! BACK level word

! sample: r5 = 0 the fast entries, 1 the slow ones. Clobbers r0-r7, r11, r13, r14.
sample:
	sts.l	pr,@-r15
	mov	r5,r14			! r14 = slow
	mov.l	sm_tab,r11
	add	r10,r11			! r11 = the entry
	mov	#0,r13			! r13 = its index
sm_loop:
	mov.l	@(4,r11),r3		! r3 = type | flags << 8 | mask << 16
	tst	r3,r3
	bt	sm_end
	mov	r3,r0
	shlr8	r0			! r0 = flags | mask << 8
	tst	#F_SLOW,r0
	movt	r1			! 1 = a fast entry
	cmp/eq	r1,r14
	bt	sm_next			! not this pass's
	tst	#F_KSB,r0
	bt	1f
	mov.l	@(16,r10),r1
	tst	r1,r1
	bt	sm_next			! no keyshift in the build
1:	mov.l	@r11,r1			! r1 = the address
	tst	#F_TA,r0
	bt	2f
	add	r12,r1
2:	mov	#0,r5			! r5 != 0: a word of the table's record (native)
	tst	#F_OWN,r0
	bt	sm_abs
	own_rec	r6, r5			! F1: OUR record, not the fixed slot (the other deck's with two decks)
	add	r6,r1
sm_abs:	mov	r0,r2			! r2 = flags | mask << 8
	tst	#F_BYTE,r0
	bt	3f
	mov.b	@r1,r7
	extu.b	r7,r7
	shlr8	r0
	extu.b	r0,r0
	tst	r0,r0
	bt	4f
	bra	4f
	and	r0,r7
3:	mov.l	@r1,r7			! r7 = new
	tst	r5,r5
	bt	4f
	swap.b	r7,r7			! the table's word in the slot's network order: the log's format
	swap.w	r7,r7			! (decode_bbox.py) does not depend on which structure answered
	swap.b	r7,r7
4:	mov	r13,r0
	shll2	r0
	add	#B_LAST,r0
	mov.l	@(r0,r8),r6		! r6 = old
	cmp/eq	r6,r7
	bt	sm_next
	mov.l	r7,@(r0,r8)
	mov	#B_INIT,r0
	mov.l	@(r0,r8),r0
	mov	r14,r5
	add	#1,r5
	tst	r5,r0
	bt	sm_next			! the first sample: only kept
	mov	r2,r0
	tst	#F_AUX,r0
	bt	5f
	add	#-4,r1
	mov.l	@r1,r6			! c = the word before (own status +0x28)
5:	extu.b	r3,r0
	cmp/eq	#T_KSREF,r0
	bf	6f
	bsr	ks_reason
	nop
6:	mov	r13,r4			! w1 = type | entry << 8
	shll8	r4
	extu.b	r3,r0
	or	r0,r4
	mov.l	r2,@-r15
	bsr	ev
	nop
	mov.l	@r15+,r2
	extu.b	r3,r0
	cmp/eq	#T_LOAD,r0
	bf	7f
	mov.l	r9,@(B_LASTLD,r8)
7:	cmp/eq	#T_PMODE,r0
	bf	8f
	bsr	pm_edge
	nop
8:	mov	r2,r0
	tst	#F_ERR,r0
	bt	sm_next
	bsr	auto_req
	extu.b	r3,r4
sm_next:
	add	#8,r11
	bra	sm_loop
	add	#1,r13
sm_end:
	mov	#B_INIT,r0
	mov.l	@(r0,r8),r1
	mov	r14,r2
	add	#1,r2
	or	r2,r1
	mov.l	r1,@(r0,r8)
	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
sm_tab:		.long	wt_tab - bbox

! pm_edge: the play mode moved (r6 old, r7 new). Into 2 (loading): its tick. Out of 2: a
! LOADEND event; nothing loaded after it, or >= 20 s, is an error. Keeps r2, r3, r11, r13, r14.
pm_edge:
	sts.l	pr,@-r15
	mov.l	r2,@-r15
	mov.l	r3,@-r15
	mov	r7,r0
	cmp/eq	#2,r0
	bf	1f
	mov	r9,r0
	or	#1,r0
	bra	9f
	mov.l	r0,@(B_LDT,r8)
1:	mov	r6,r0
	cmp/eq	#2,r0
	bf	9f
	mov.l	@(B_LDT,r8),r1
	tst	r1,r1
	bt	9f
	mov	#0,r0
	mov.l	r0,@(B_LDT,r8)
	mov.l	r9,@(B_LASTLD,r8)
	mov	r9,r6
	sub	r1,r6			! c = the load's ms
	mov.l	pe_len,r1		! b = the track length in s (heartbeat +0x7C ms / 1000)
	mov.l	@r1,r0
	mov.l	pe_inv,r1
	dmulu.l	r0,r1
	sts	mach,r4
	shlr2	r4
	shlr2	r4
	shlr2	r4
	shll16	r4
	mov	#T_LOADEND,r0
	or	r0,r4
	bsr	ev
	nop
	mov	r7,r0
	tst	r0,r0
	bt	2f
	mov.w	pe_20s,r1
	cmp/hs	r1,r6
	bf	9f
2:	bsr	auto_req
	mov	#T_LOADEND,r4
9:	mov.l	@r15+,r3
	mov.l	@r15+,r2
	lds.l	@r15+,pr
	rts
	nop
pe_20s:		.word	20000
	.p2align 2
pe_len:		.long	0x0B568C9C + 0x7C	! heartbeat: the track length, ms
pe_inv:		.long	0x10624DD3		! 2^38 / 1000

! ks_reason: r6 = why KEY SYNC was refused (1 KEY SHIFT off, 2 no GUI key word, 3 the keys not
! known / no other master, 4 other), r7 = the GUI's last KEY SYNC word (KSB+28). Clobbers r0, r1.
ks_reason:
	mov.l	kr_gw,r1
	mov.l	@r1,r7
	mov.l	kr_eng,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt/s	9f
	mov	#1,r6
	mov	r7,r0
	shlr16	r0
	mov.w	kr_ky,r1
	cmp/eq	r1,r0
	bf/s	9f
	mov	#2,r6
	mov	r7,r0
	tst	#0x80,r0
	bt/s	9f
	mov	#3,r6
	mov	#4,r6
9:	rts
	nop
kr_ky:		.word	0x4B59			! "KY"
	.p2align 2
kr_gw:		.long	KSB + 28
kr_eng:		.long	0x08122800		! the KEY SHIFT engine's on word

! auto_req: an error-class event (r4 = its type) asks for a dump: none pending, the last auto
! request >= 5 min ago, < 8 a boot. Clobbers r0-r2, r4, r6, r7.
auto_req:
	sts.l	pr,@-r15
	mov.l	@(B_DREQ,r8),r0
	tst	r0,r0
	bf	9f
	mov	#B_AUTO,r0
	mov.l	@(r0,r8),r1
	mov	#8,r2
	cmp/hs	r2,r1
	bt	9f
	add	#1,r1
	mov.l	@(B_DLAST,r8),r2
	tst	r2,r2
	bt	1f
	mov	r9,r0
	sub	r2,r0
	mov.l	ar_5min,r2
	cmp/hs	r2,r0
	bf	9f
1:	mov	#B_AUTO,r0
	mov.l	r1,@(r0,r8)
	mov	r9,r0
	or	#1,r0
	mov.l	r0,@(B_DLAST,r8)
	mov	#2,r0
	mov.l	r0,@(B_DREQ,r8)
	mov.l	r4,@(B_DTRIG,r8)
	mov	#B_DREQT,r0
	mov.l	r9,@(r0,r8)
	mov	r4,r6			! c = the trigger
	mov.l	ar_req,r4		! T_DUMPREQ, b = 1 (auto)
	bsr	ev
	mov	#0,r7
9:	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
ar_5min:	.long	5 * 60 * 1000
ar_req:		.long	T_DUMPREQ | 1 << 16

! slow (every 250 ms): the play / stick watch; every 1 s the slow entries and the LINK mask;
! the network stream; the dump when one is pending and writing is safe.
slow:
	sts.l	pr,@-r15
	mov.l	sl_el,r1		! playing = the heartbeat's elapsed word moves
	mov.l	@r1,r0
	mov.l	@(B_ELW,r8),r1
	cmp/eq	r0,r1
	bt	1f
	mov.l	r0,@(B_ELW,r8)
	mov.l	r9,@(B_ELT,r8)
1:	mov.l	sl_usb,r1		! the stick mounted since
	mov.l	@r1,r0
	cmp/eq	#3,r0
	bt	2f
	mov	#0,r0
	bra	3f
	mov.l	r0,@(B_MNTT,r8)
2:	mov.l	@(B_MNTT,r8),r0
	tst	r0,r0
	bf	3f
	mov	r9,r0
	or	#1,r0
	mov.l	r0,@(B_MNTT,r8)
3:	mov.l	@(B_NEXTC,r8),r1	! ---- every 1 s
	mov	r9,r0
	sub	r1,r0
	cmp/pz	r0
	bf	4f
	mov.w	sl_1000,r0
	add	r9,r0
	mov.l	r0,@(B_NEXTC,r8)
	bsr	link_mask
	nop
	bsr	sample
	mov	#1,r5
4:
	.ifndef	RELEASE			! V4n37r: a RELEASE build has no network stream (USB dump only)
	bsr	net_send
	nop
	.endif
	bsr	dump_try
	nop
	lds.l	@r15+,pr
	rts
	nop
sl_1000:	.word	1000
	.p2align 2
sl_el:		.long	0x0B568C9C + 0x78	! the heartbeat block's elapsed word
sl_usb:		.long	0x0A35F3AC		! 3 = the stick mounted

! link_mask: bit k = device lm_dev[k] has an address in the LINK device table (0x0A35F80C +
! dev * 0x414, +0 its ip; cleared ~5 s after it leaves). A change -> T_LINK. Clobbers r0-r7.
link_mask:
	sts.l	pr,@-r15
	mova	lm_dev,r0
	mov	r0,r3
	mov	#0,r7
	mov	#1,r5
1:	mov.b	@r3+,r0
	extu.b	r0,r0
	tst	r0,r0
	bt	2f
	mov.w	lm_str,r1
	mulu.w	r0,r1
	sts	macl,r1
	mov.l	lm_tab,r2
	add	r2,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	3f
	or	r5,r7
3:	bra	1b
	shll	r5
2:	mov	#B_LINK,r0
	mov.l	@(r0,r8),r6
	mov.l	r7,@(r0,r8)
	mov	#B_INIT,r0
	mov.l	@(r0,r8),r1
	mov	#4,r2
	tst	r2,r1
	or	r2,r1
	bt/s	9f
	mov.l	r1,@(r0,r8)
	cmp/eq	r6,r7
	bt	9f
	bsr	ev
	mov	#T_LINK,r4
9:	lds.l	@r15+,pr
	rts
	nop
lm_str:		.word	0x414
	.p2align 2
lm_tab:		.long	0x0A35F80C
lm_dev:		.byte	1, 2, 3, 4, 5, 6, 17, 18, 33, 0
	.p2align 2

! dump_try: a pending request, written when it is safe (see the header).
dump_try:
	sts.l	pr,@-r15
	mov.l	@(B_DREQ,r8),r0
	tst	r0,r0
	bt	dt_out
	mov.l	@(B_DCNT,r8),r0		! 32 a boot at most
	mov	#32,r1
	cmp/hs	r1,r0
	bf	1f
	mov	#0,r0
	bra	dt_out
	mov.l	r0,@(B_DREQ,r8)
1:	mov.l	@(B_MNTT,r8),r1		! mounted >= 4 s
	tst	r1,r1
	bt	dt_out
	mov	r9,r0
	sub	r1,r0
	mov.w	dt_4000,r1
	cmp/hs	r1,r0
	bf	dt_out
	mov.l	@(B_ELT,r8),r1		! the elapsed word still >= 1 s
	mov	r9,r0
	sub	r1,r0
	mov.w	dt_1000,r1
	cmp/hs	r1,r0
	bf	dt_out
	mov.l	@(B_LDT,r8),r0		! no load under way
	tst	r0,r0
	bf	dt_out
	mov.l	@(B_LASTLD,r8),r1	! nor one < 3 s ago
	tst	r1,r1
	bt	2f
	mov	r9,r0
	sub	r1,r0
	mov.w	dt_3000,r1
	cmp/hs	r1,r0
	bf	dt_out
2:	mov.l	dt_pm,r1		! play mode not loading / playing / looping
	mov.b	@r1,r0
	extu.b	r0,r0
	cmp/eq	#2,r0
	bt	dt_out
	cmp/eq	#3,r0
	bt	dt_out
	cmp/eq	#4,r0
	bt	dt_out
	mov	#104,r0			! no Link Cue preview streaming (D_PREVIEW)
	mov.l	@(r0,r12),r0
	tst	r0,r0
	bf	dt_out
	mov.l	dt_pv,r1		! no row preview (MED+64 "PV" | bit 14)
	mov.l	@r1,r0
	mov	r0,r1
	shlr16	r1
	mov.w	dt_pvm,r2
	cmp/eq	r2,r1
	bf	3f
	mov.w	dt_b14,r1
	tst	r1,r0
	bf	dt_out
3:	bsr	dump
	nop
dt_out:	lds.l	@r15+,pr
	rts
	nop
dt_4000:	.word	4000
dt_1000:	.word	1000
dt_3000:	.word	3000
dt_pvm:		.word	0x5056
dt_b14:		.word	0x4000
	.p2align 2
dt_pm:		.long	0x0A35F7A0		! play mode
dt_pv:		.long	RAMB + 0x1F700 + 64	! touch_audio MED+64: row preview

! dump: header + the ring (oldest first) appended to C:/BLACKBOX.BIN; then a T_DUMPOK event.
! Header (256 B, LE words): +0 'BBX1', +4 256 | format 1 << 16, +8 tick, +12 events written,
! +16 events in this dump, +20 reason (1 manual, 2 auto) | trigger << 8 | dump seq << 16,
! +24 request tick, +28 watch entries, +32 MAIN version (8 B), +40 LINK mask, +44 play mode,
! +48 the build record (BLDID, 48 B: 'BLD1' + ASCII ID; zeros without), +96 the entries'
! last values (32 words), +252 'BBXE'. Clobbers r0-r7, r11, r13, r14.
dump:
	sts.l	pr,@-r15
	mov.w	dm_hdr,r1
	add	r8,r1			! r1 = the header
	mov	r1,r3
	mov	#64,r2
	mov	#0,r0
1:	mov.l	r0,@r3
	dt	r2
	bf/s	1b
	add	#4,r3
	mov.l	dm_mag,r0
	mov.l	r0,@r1
	mov.l	dm_hv,r0
	mov.l	r0,@(4,r1)
	mov.l	r9,@(8,r1)
	mov.l	@(B_WR,r8),r0
	mov.l	r0,@(12,r1)
	mov	r0,r14			! r14 = events in the dump: min(WR, NEV)
	mov.w	dm_nev,r2
	cmp/hs	r2,r14
	bf	2f
	mov	r2,r14
2:	mov.l	r14,@(16,r1)
	mov	#B_DSEQ,r0
	mov.l	@(r0,r8),r2
	add	#1,r2
	mov.l	r2,@(r0,r8)
	mov	r2,r13			! r13 = this dump's seq
	shll16	r2
	mov.l	@(B_DTRIG,r8),r3
	extu.b	r3,r3
	shll8	r3
	or	r3,r2
	mov.l	@(B_DREQ,r8),r0
	or	r0,r2
	mov.l	r2,@(20,r1)
	mov	#B_DREQT,r0
	mov.l	@(r0,r8),r0
	mov.l	r0,@(24,r1)
	mov	#NW,r0
	mov.l	r0,@(28,r1)
	mov.l	dm_ver,r2
	mov.l	@r2,r0
	mov.l	r0,@(32,r1)
	mov.l	@(4,r2),r0
	mov.l	r0,@(36,r1)
	mov	#B_LINK,r0
	mov.l	@(r0,r8),r0
	mov.l	r0,@(40,r1)
	mov.l	dm_pm,r2
	mov.b	@r2,r0
	extu.b	r0,r0
	mov.l	r0,@(44,r1)
	mov.l	dm_bld,r2		! the build record, when it carries its magic
	mov.l	@r2,r0
	mov.l	dm_bmag,r3
	cmp/eq	r3,r0
	bf	3f
	mov	r1,r3
	add	#48,r3
	mov	#12,r7
4:	mov.l	@r2+,r0
	mov.l	r0,@r3
	dt	r7
	bf/s	4b
	add	#4,r3
3:	mov	r8,r2			! the entries' values
	add	#B_LAST,r2
	mov	r1,r3
	add	#96,r3
	mov	#32,r7
5:	mov.l	@r2+,r0
	mov.l	r0,@r3
	dt	r7
	bf/s	5b
	add	#4,r3
	mov.l	dm_end,r0
	mov.l	r0,@(28,r3)		! +252
	mova	dm_path,r0
	mov	r0,r4
	mov.l	dm_amode,r5
	mov.l	dm_tag,r6
	mov.l	dm_open,r1
	fcall	r1
	mov	#2,r7			! r7 = result (2: no open)
	tst	r0,r0
	bt	dm_done
	mov	r0,r11			! r11 = handle
	mov.w	dm_hdr,r4
	add	r8,r4
	mov.w	dm_256,r6
	bsr	wr
	nop
	tst	r0,r0
	bf	dm_short
	mov.l	@(B_WR,r8),r5		! the oldest event in it: WR - n
	sub	r14,r5
	mov.w	dm_mask,r0
	and	r0,r5			! r5 = its slot
	mov.w	dm_nev,r6
	sub	r5,r6			! slots to the ring's end
	cmp/hs	r6,r14
	bt	6f
	mov	r14,r6
6:	sub	r6,r14			! r14 = the rest (from slot 0)
	mov	r5,r4
	shll2	r4
	shll2	r4
	mov.w	dm_ring,r0
	add	r0,r4
	add	r8,r4
	shll2	r6
	bsr	wr
	shll2	r6
	tst	r0,r0
	bf	dm_short
	tst	r14,r14
	bt	dm_ok
	mov.w	dm_ring,r4
	add	r8,r4
	mov	r14,r6
	shll2	r6
	bsr	wr
	shll2	r6
	tst	r0,r0
	bf	dm_short
dm_ok:	bra	7f
	mov	#0,r14
dm_short:
	mov	#1,r14
7:	mov	r11,r4
	mov.l	dm_tag,r5
	mov.l	dm_close,r1
	fcall	r1
	mov	r14,r7
dm_done:
	mov	#0,r0
	mov.l	r0,@(B_DREQ,r8)
	mov.l	@(B_DCNT,r8),r0
	add	#1,r0
	mov.l	r0,@(B_DCNT,r8)
	mov	r7,r6			! c = result, d = the dump's seq
	mov	r13,r7
	bsr	ev
	mov	#T_DUMPOK,r4
	lds.l	@r15+,pr
	rts
	nop
dm_hdr:		.word	B_HDR
dm_256:		.word	256
dm_nev:		.word	NEV
dm_mask:	.word	NEV - 1
dm_ring:	.word	B_RING
	.p2align 2
dm_mag:		.long	0x31584242		! "BBX1"
dm_hv:		.long	256 | 1 << 16
dm_end:		.long	0x45584242		! "BBXE"
dm_ver:		.long	0x08000740		! MAIN image version string
dm_pm:		.long	0x0A35F7A0		! play mode
dm_bld:		.long	BLDID			! layout.inc: modsmenu's build record
dm_bmag:	.long	0x31444C42		! "BLD1"
dm_amode:	.long	0xA80EC2C0		! "a" (usblog's)
dm_tag:		.long	0xA80EB5B8		! touch_audio's thunks' owner tag
dm_open:	.long	0x08501CB0		! fm_open(path16, mode, tag)
dm_close:	.long	0x08502224		! fm_close(fh, tag)
dm_path:	.short	'C', ':', '/', 'B', 'L', 'A', 'C', 'K', 'B', 'O', 'X', '.', 'B', 'I', 'N', 0
	.p2align 2

! wr: fm_write(r4, 1, r6, r11) -> r0 = 0 when all r6 bytes went. Clobbers r1-r7.
wr:
	sts.l	pr,@-r15
	mov.l	r6,@-r15
	mov	#1,r5
	mov	r11,r7
	mov.l	wr_tag,r1
	mov.l	r1,@-r15
	mov.l	wr_fn,r1
	fcall	r1
	add	#4,r15
	mov.l	@r15+,r6
	sub	r6,r0
	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
wr_fn:		.long	0x08502862		! fm_write(buf, 1, n, fh) + tag on the stack
wr_tag:		.long	0xA80EB5B8

	.ifndef	RELEASE			! V4n37r: net_send is DEV only (patch_main CDJ_PROFILE=release)
! net_send (TEST LOG = RED): the events not sent yet, <= 7 a 'V3BB' record, <= 4 records a poll,
! from touch_audio's endpoint to the LINK subnet's broadcast (169.254/16 -> x.x.255.255, else
! x.x.x.255), port 50099. A failed send: they stay pending. Clobbers r0-r7, r11, r13, r14.
net_send:
	sts.l	pr,@-r15
	mov.l	@(12,r10),r1
	tst	r1,r1
	bt	ns_out
	mov.l	@r1,r0
	cmp/eq	#2,r0
	bf	ns_out
	mov.l	@(56,r12),r0		! touch_audio D_CEP
	tst	r0,r0
	bt	ns_out
	add	#-16,r15		! own IP: getter(0, buf16) -> buf+4 (host order)
	mov.l	ns_getip,r1
	mov	r15,r5
	jsr	@r1
	mov	#0,r4
	mov.l	@(4,r15),r1
	add	#16,r15
	tst	r0,r0
	bf	ns_out
	tst	r1,r1
	bt	ns_out
	mov	r1,r0
	shlr16	r0
	mov.w	ns_lla,r2
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
2:	mov	#B_DST,r0
	mov.l	r1,@(r0,r8)
	mov.w	ns_port,r2
	add	#4,r0
	mov.w	r2,@(r0,r8)
	mov	#4,r14			! r14 = records left this poll
ns_loop:
	mov.l	@(B_WR,r8),r0
	mov.l	@(B_NRD,r8),r13		! r13 = the first event to send
	mov	r0,r11
	sub	r13,r11			! r11 = pending
	tst	r11,r11
	bt	ns_out
	mov.w	ns_nev,r1
	cmp/hi	r1,r11
	bf	3f
	mov	r0,r13			! more than the ring holds: the oldest are gone
	sub	r1,r13
	mov	r1,r11
3:	mov	#7,r1
	cmp/hi	r1,r11
	bf	4f
	mov	r1,r11			! r11 = events in this record
4:	mov.w	ns_net,r6
	add	r8,r6			! r6 = the record
	mov	r6,r3
	mov	#32,r2
	mov	#0,r0
5:	mov.l	r0,@r3
	dt	r2
	bf/s	5b
	add	#4,r3
	mov.l	ns_mag,r0
	mov.l	r0,@r6
	mov.l	r9,@(4,r6)
	mov.l	r13,@(8,r6)
	mov.l	r11,@(12,r6)
	mov	r6,r3
	add	#16,r3
	mov	r11,r7
	mov	r13,r2
6:	mov.w	ns_mask,r0
	and	r2,r0
	shll2	r0
	shll2	r0
	mov.w	ns_ring,r1
	add	r1,r0
	add	r8,r0			! the event
	mov.l	@r0,r1
	mov.l	r1,@r3
	mov.l	@(4,r0),r1
	mov.l	r1,@(4,r3)
	mov.l	@(8,r0),r1
	mov.l	r1,@(8,r3)
	mov.l	@(12,r0),r1
	mov.l	r1,@(12,r3)
	add	#16,r3
	dt	r7
	bf/s	6b
	add	#1,r2
	mov	#-1,r0			! TMO_FEVR (as touch_audio's sends)
	mov.l	r0,@-r15
	mov.l	@(56,r12),r4
	mov	#B_DST,r5
	add	r8,r5
	mov	#64,r7
	shll	r7			! 128
	mov.l	ns_snd,r1
	fcall	r1
	add	#4,r15
	cmp/pz	r0
	bf	ns_out			! failed: stays pending
	add	r11,r13
	mov.l	r13,@(B_NRD,r8)
	dt	r14
	bf	ns_loop
ns_out:	lds.l	@r15+,pr
	rts
	nop
ns_lla:		.word	0xA9FE
ns_port:	.word	50099
ns_nev:		.word	NEV
ns_mask:	.word	NEV - 1
ns_ring:	.word	B_RING
ns_net:		.word	B_NET
	.p2align 2
ns_mag:		.long	0x42423356		! "V3BB"
ns_getip:	.long	0x08221D9E		! own IPv4 getter
ns_snd:		.long	0x08233CF6		! udp_snd_dat
	.endif

! The watch table: {address (or offset, F_TA), type | flags << 8 | mask << 16}; type 0 ends.
! work/bbox/decode_bbox.py names the entries by their index: keep them in step.
	.p2align 2
wt_tab:
	.long	0x0A35F7A0, T_PMODE | F_BYTE << 8			!  0 play mode
	.long	0x2C, T_LOAD | (F_AUX | F_OWN) << 8			!  1 own status rbid (+0x28 in c)
	.long	0x89, T_FLAGS | (F_BYTE | F_OWN) << 8 | 0x38 << 16	!  2 own status flags
	.long	0x0A35F39C, T_MASTER | F_BYTE << 8			!  3 tempo master player
	.long	KSB + 48, T_KSYNC | F_KSB << 8				!  4 KEY SYNC on
	.long	KSB + 64, T_KSREF | F_KSB << 8				!  5 KEY SYNC refusal tick
	.long	0x08122800, T_KSHIFT | F_KSB << 8			!  6 KEY SHIFT on
	.long	0x08122804, T_KSEMI | F_KSB << 8			!  7 KEY SHIFT semitones
	.long	104, T_LCPREV | F_TA << 8				!  8 D_PREVIEW
	.long	92, T_LCE | F_TA << 8					!  9 D_E
	.long	96, T_LCT | F_TA << 8					! 10 D_T
	.long	RAMB + 0x1FE88, T_LCCNT | F_SLOW << 8			! 11 zero-filled packets (underrun)
	.long	RAMB + 0x1FE90, T_LCCNT | F_SLOW << 8			! 12 pacer resyncs
	.long	RAMB + 0x1FE98, T_LCCNT | (F_SLOW | F_ERR) << 8		! 13 failed sends
	.long	RAMB + 0x1FEA0, T_LCCNT | F_SLOW << 8			! 14 election timeouts
	.long	RAMB + 0x1FEA8, T_LCCNT | (F_SLOW | F_ERR) << 8		! 15 failed opens
	.long	RAMB + 0x1FEAC, T_LCCNT | F_SLOW << 8			! 16 kill edges
	.long	RAMB + 0x1E0A8, T_NET | F_SLOW << 8			! 17 W8 NFS lookup tries (W8N +40)
	.long	RAMB + 0x15028, T_NET | F_SLOW << 8			! 18 cue / tag lookups tried (CC_TRY)
	.long	0, 0
