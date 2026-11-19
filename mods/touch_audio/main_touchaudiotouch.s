! SPDX-License-Identifier: Apache-2.0
!
! Touch Preview: keeps the stock needle search off the overview strip while the
! browser's INFO pop-up is open, so a finger there only previews the INFO
! track on the mixer's LINK CUE (main_touchaudio.s) and never moves the track
! on the deck. Replaces the body of the strip's touch handler (zone 0 of the
! touch table at 0xA81010A0, handler 0x084EDC5A), between its own sts.l pr and
! lds.l pr: the same column clamp (x - x0, 1..600; x 15/16 when the zone is
! 640 wide, the V2 overview) and needle-search call
! 0x084E19DC(0, 1, col), skipped while mem32[0x0A35F3CC] == 2 (INFO on a listed track)
! and while Touch Cue owns the strip: UTILITY > LINK CUE includes CUE (LCV bit
! 1, the setting the TchAud task honours too) and the deck plays (0x0A35F7A0 =
! 3 or 4) a rekordbox track (its status packet at 0x0B53D828, +0x2A = 1). With
! LINK CUE at OFF or PREVIEW a touch while playing is the stock one again (the
! NEEDLE LOCK pop-up, no jump). The stock needle search is locked while playing
! anyway, and its handler running on every touch report slows the TchAud
! task's reads down.
!
! In: r4 = touch x (pixels). r0-r7 clobbered.

	.include "layout.inc"

	.text
touchaudiotouch:
	mov.l	tt_zone,r5
	mov.l	@r5,r1			! the strip's x0
	sub	r1,r4
	mov.l	@(8,r5),r1		! its w: 640 under the V2 overview (79..718) -> 600 columns
	mov.w	tt_640,r2
	cmp/eq	r2,r1
	bf	0f
	mov	r4,r1			! col * 15 / 16 (x - x0 >= 0 here; < 0 clamps to 1 below)
	shll2	r1
	shll2	r1
	sub	r4,r1
	shar	r1
	shar	r1
	shar	r1
	shar	r1
	mov	r1,r4
0:
	mov	#1,r7
	cmp/ge	r7,r4
	bt	1f
	mov	#1,r4
1:	mov.w	tt_600,r2
	cmp/gt	r2,r4
	bf	2f
	mov	r2,r4
2:	mov.l	tt_kill,r1		! kill switch (C:/NOMODS): stock behaviour
	mov.l	@r1,r0
	mov.l	tt_nomo,r1
	cmp/eq	r1,r0
	bt	5f
	mov.l	tt_lcv,r2
	mov.l	@r2,r2			! UTILITY > LINK CUE (bit 1 PREVIEW, bit 2 CUE)
	mov.l	tt_info,r1
	mov.l	@r1,r1
	mov	#2,r0
	cmp/eq	r0,r1
	bf	6f
	mov	r2,r0			! INFO on a track, PREVIEW on: Touch Preview's
	tst	#1,r0
	bf	3f
6:	mov.l	tt_owner,r1		! the strip shows our waveform (a row preview)
	mov.l	@r1,r1
	tst	r1,r1
	bf	3f
	mov	r2,r0			! LINK CUE without CUE: needle search stays stock
	tst	#2,r0
	bt	5f
	mov.l	tt_pmode,r1
	mov.l	@r1,r0
	cmp/eq	#3,r0
	bt	4f
	cmp/eq	#4,r0
	bf	5f
4:	mov.l	tt_stat,r1		! playing a rekordbox track: Touch Cue's
	mov	#0x2a,r0
	mov.b	@(r0,r1),r0
	cmp/eq	#1,r0
	bt	3f
5:	mov	r4,r6
	mov	#1,r5
	mov.l	tt_needle,r2
	sts.l	pr,@-r15
	jsr	@r2
	mov	#0,r4
	lds.l	@r15+,pr
3:	rts
	nop

tt_600:		.word 600
tt_640:		.word 640
	.p2align 2
tt_zone:	.long 0xA81010A0	! zone 0 of the touch table: x0, y0, w, h
tt_info:	.long 0x0A35F3CC	! display mode: 2 = INFO pop-up on a listed track
tt_needle:	.long 0x084E19DC	! needle search (r4 = 0, r5 = 1, r6 = column)
tt_pmode:	.long 0x0A35F7A0	! play mode: 3 playing, 4 looping
tt_stat:	.long 0x0B53D828	! the deck's own status packet
tt_kill:	.long RAMB+0x1F7F0
tt_nomo:	.long 0x4F4D4F4E	! "NOMO": mods off
tt_lcv:		.long LCV		! UTILITY > LINK CUE: 0 OFF, 1 PREVIEW, 2 CUE, 3 BOTH
tt_owner:	.long RAMB+0x1F7F8	! 1 while the TchAud task's waveform is in the strip
