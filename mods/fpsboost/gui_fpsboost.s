! SPDX-License-Identifier: Apache-2.0
!
! fpsboost (GUI, SH-2A): skip a background clear the frame has just done.
!
! Every frame the widget tree clears its backgrounds with the rect fill
! 0x0E508E1E, which hands full-width rectangles of 256 KB or more to the DMA
! fill 0x0E510368 (r4 = 1: channel 6, waits for the end). Two widgets share
! each big surface, and the child's clear follows the parent's at once, with
! the same colour, inside the parent's rows: the top surface (800x294) gets
! 470,400 B and then 441,600 B of the same black, the bottom one (800x186)
! 297,600 B twice. The second fill stores what is already there.
! re/FPS_SAFE.md has the write-watch proof (every one of them, in every
! screen of the scripted session, wrote only bytes that already held its
! value, right after the fill that wrote them) and the bus estimate.
!
! A fill is skipped only when all of these hold:
!   - it comes from the rect fill (r4 = 1) and is >= 0x40000 bytes;
!   - the last DMA fill of the rect fill was >= 0x40000 bytes too, was made
!     during the previous rect-fill call, and nothing else ran the rect
!     fill or the CPU blit 0x0E509244 since (a counter they bump through
!     the redirected literals below);
!   - same 16-bit colour, and its bytes lie inside that fill's;
!   - DMA channel 6 is still as that fill left it: SAR on the pattern
!     buffer, DAR at that fill's end, count 0, DE clear (no other channel-6
!     transfer since).
! Otherwise the stock fill runs, and is remembered if it qualifies.
!
! Entry points (patch_gui REDIRECTS, literal -> blob offset):
!   +0  the DMA fill        (0x0E508FD4, 0x0E50D534 -> 0x0E510368)
!   +4  the rect fill       (six literals -> 0x0E508E1E)
!   +8  the CPU blit        (0x0E50ADB8 -> 0x0E509244)
! All three end in a jump to the stock routine with r4-r7, r15 and pr as
! the caller left them; only r0-r3 change. With --defsym VERIFY=1 (an
! emulator-only build, never shipped) a skip is not taken: the fill is run
! from here instead, so the write-watch can check every would-be skip.
	.text
fpsboost:
	bra	fill_wrap		! +0
	nop
	bra	rect_wrap		! +4
	nop
	bra	blit_wrap		! +8
	nop
.ifdef GR3DIRECT
	bra	copy_wrap		! +12 (gr3direct: the flush's surface -> GR3 copy)
	nop
	bra	flip_sleep		! +16 (gr3direct: the flip's sleep, literal 0x0E509230)
	nop
	bra	draw_wrap		! +20 (gr3direct: the draw-callback dispatcher, RAM slot 0x1C001240)
	nop
	bra	vsync_wrap		! +24 (gr3direct: the vsync callback, literal 0x0E508D08)
	nop
	bra	vdcset_wrap		! +28 (gr3direct: the VDC base write, literals 0x0E50923C / 0x0E508D1C)
	nop
.endif

rect_wrap:
.ifdef GR3DIRECT
	mova	l_stseq_off,r0		! st_seq lies past a pc-relative load's reach
	mov.w	l_stseq_off,r1		! (forward, 1 KB): anchor + offset
	add	r1,r0
.else
	mova	st_seq,r0
.endif
	mov.l	@r0,r1
	add	#1,r1
	mov.l	r1,@r0
.ifdef GR3DIRECT
! gr3direct (re/FPS_STOCK.md): the player screen's two full-width composited
! windows (top 800x294 at (0,0), bottom 800x186 at (0,294); opaque, painted
! first, the only readers of their SDRAM surfaces are the flush's copies to
! GR3) draw straight into the GR3 back buffer. A clear through 0x0E50AAD0
! (its rect-fill call returns to 0x0E50AAE8) or a draw callback (draw_wrap)
! on such a window points its surface base (desc+12) at the back buffer +
! y0 * 1600 for the rest of the frame (gd_win); every primitive takes the
! base from there, so the frame's drawing lands in GR3; the flush's copy of
! a surface that already lives in GR3 is skipped and the SDRAM base put back
! (copy_wrap). Saves the two copies (768,000 B/frame) and moves the fills
! off the SDRAM.
	sts	pr,r0
	mov.l	l_clrret,r1
	cmp/eq	r0,r1
	bf	rect_go			! not a clear through 0x0E50AAD0
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	sts.l	pr,@-r15
	mov.l	l_wpool,r8		! the window owning the surface r4 (pool
	mov.l	l_wend,r9		! 256 x 160 B)
gd_next:
	mov.l	@r8,r0
	mov.l	l_inuse,r1
	tst	r1,r0
	bt	gd_skip			! free entry
	mov.l	@(152,r8),r0		! its surface descriptor
	cmp/eq	r0,r4
	bt	gd_found
gd_skip:
	mov.w	l_160,r0
	add	r0,r8
	cmp/hs	r9,r8
	bf	gd_next
	bra	gd_done
	nop
gd_found:
	bsr	gd_win			! r8 = window, r4 = desc, r5 = the clear's rect
	nop
gd_done:
	lds.l	@r15+,pr
	mov.l	@r15+,r9
	mov.l	@r15+,r8
rect_go:
.endif
.ifdef GR3DIRECT
	mov.l	l_rect2,r0
.else
	mov.l	l_rect,r0
.endif
	jmp	@r0
	nop
.ifdef GR3DIRECT
	.align	2
l_800:		.word	800
l_z133:		.word	133
l_z135:		.word	135
l_1600:		.word	1600
l_160:		.word	160
	.p2align 2
l_clrret:	.long	0x0E50AAE8		! return address of the per-frame clear's rect-fill call
l_wpool:	.long	0x0F6C0690		! window pool (256 x 160 B; +0 bit30 in use)
l_wend:		.long	0x0F6C0690 + 256 * 160
l_inuse:	.long	0x40000000
l_rect2:	.long	0x0E508E1E		! the rect fill (l_rect is out of reach here)
	.p2align 2
l_stseq_off:	.word	st_seq - l_stseq_off
	.p2align 2

! What the panel shows. The VDC5 takes a frame base written through
! 0x0E526626(2, base) at the NEXT vsync. The flip usually waits for a vsync
! before writing (flip_sleep then writes early, so that vsync takes it), but
! it has a path with no wait at all ([0x0F7EB734] == 0, [0xFFF8806C] != 1,
! [0xFFF8806C+44] != 0), after which the buffer the next frame draws into
! stays on the panel for up to a field. These two wrappers keep the model:
! st_pend = base written and not yet taken, st_disp = base on the panel.
! The vsync callback 0x0E508A34 (event 3; registered through the literal
! 0x0E508D08) runs in the VDC interrupt: only r0-r3, no stack.
vsync_wrap:
	mov	r4,r0
	cmp/eq	#3,r0
	bf	vw_go
	mova	st_pend,r0
	mov.l	@r0,r1
	tst	r1,r1
	bt	vw_cnt
	mov.l	r1,@(4,r0)		! st_disp = st_pend
	mov	#0,r1
	mov.l	r1,@r0			! st_pend = 0
vw_cnt:	mov.l	@(8,r0),r1
	add	#1,r1
	mov.l	r1,@(8,r0)		! st_vs: vsyncs seen
vw_go:	mov.l	l_vscb,r0
	jmp	@r0
	nop

! 0x0E526626(r4 = plane, r5 = base): the flip's VDC base write (and the
! display init's). Plane 2 is the GR3 pair.
vdcset_wrap:
	mov	r4,r0
	cmp/eq	#2,r0
	bf	vd_go
	mov.l	l_mask3,r1
	mov	r5,r2
	and	r1,r2
	mova	st_pend,r0
	mov.l	@(24,r0),r1		! st_earlydone: flip_sleep wrote this base
	cmp/eq	r1,r2			! already, before the flip's vsync; the flip's
	bf	vd_new			! own write after it would only set the update
	mov	#0,r1			! bits again (pending for one more field, so
	mov.l	r1,@(24,r0)		! gd_win would take the stock path): skipped
	mov.l	@(28,r0),r1
	add	#1,r1
	mov.l	r1,@(28,r0)		! st_skipped
	rts
	mov	#0,r0
vd_new:	mov.l	r2,@r0			! st_pend = base
	mov.l	@(12,r0),r1
	add	#1,r1
	mov.l	r1,@(12,r0)		! st_vdc: base writes
vd_go:	mov.l	l_vdcset,r0
	jmp	@r0
	nop

! gd_win: r8 = a window, r4 = its surface descriptor, r5 = the rect of the
! clear being made ({x, y, w:16, h:16}) or 0 (a draw callback). When the
! window is one of the player's two (layer 0, composited, z key 133 or 135,
! full width at x 0: a BROWSE list has the geometry but is not redrawn every
! frame) and its surface still sits in SDRAM, the surface is pointed at the
! GR3 back buffer for the rest of the frame. Unless this is a clear of the
! whole window (everything is repainted after it), its rows of the front
! buffer -- the last complete picture; the SDRAM surface is stale since the
! first redirect -- are copied into the back buffer first, under whatever
! the partial clear or the callback paints (the same DMA copy the flush
! makes in stock, so such a frame costs what it costs stock). Keeps r4-r7;
! uses r0-r3, r9; the caller saves pr.
gd_win:
	mov.l	@(28,r8),r0		! layer 0?
	mov.l	l_layer0,r1
	cmp/eq	r0,r1
	bf	gw_ret
	mov.b	@(7,r8),r0		! composited (bit3)?
	tst	#8,r0
	bt	gw_ret
	mov.l	@(12,r8),r0		! the player's top (z 133) or bottom (z 135)
	mov.w	l_z133g,r1		! window (mov #imm is 8-bit signed: 133 would
	cmp/eq	r0,r1			! be -123)
	bt	gw_z
	mov.w	l_z135g,r1
	cmp/eq	r0,r1
	bf	gw_ret
gw_z:
.ifdef TESTALT
	tst	r5,r5			! emulator-only: every other CLEAR is left in
	bt	gw_geo			! SDRAM (its erase is lost), so the draws that
	mova	st_alt,r0		! follow must redirect the window themselves
	mov.l	@r0,r1			! (front-buffer restore + redirect in draw_wrap)
	add	#1,r1
	mov.l	r1,@r0
	mov	r1,r0
	tst	#1,r0
	bf	gw_ret
gw_geo:
.endif
	mov.w	@(8,r8),r0		! full width?
	extu.w	r0,r0
	mov.w	l_800g,r1
	extu.w	r1,r1
	cmp/eq	r0,r1
	bf	gw_ret
	mov.l	@(84,r8),r0		! placed at x = 0?
	tst	r0,r0
	bf	gw_ret
	mov.l	@(12,r4),r0		! already in GR3 (redirected this frame)?
	mov.l	l_mask2,r1
	and	r1,r0
	mov.l	l_gr3lo,r1
	sub	r1,r0
	mov.l	l_gr3len,r1
	cmp/hs	r1,r0
	bf	gw_base
! The frame's first touch of this window. After a flip with no vsync wait
! (the playing deck's case) the back buffer is still on the panel until the
! base the flip wrote is taken (st_pend set, st_disp == back): this window
! then takes the stock path for the frame -- its SDRAM surface, copied by
! the flush -- which never costs more than stock, instead of waiting for the
! vsync. Unless this touch is a clear of the whole window, the surface is
! first made complete again from the front buffer (it is stale since the
! last redirect). Entry.drawn = 2 tells copy_wrap to make the stock copy.
	mov.l	l_gr3desc,r1
	mov.l	@(12,r1),r1
	mov.l	l_mask2,r0
	and	r0,r1			! r1 = back buffer
	mova	st_pend,r0		! st_stuck: the update bits never clear on this
	mov.l	@(32,r0),r0		! VDC (copy_wrap found them set for 20 polls):
	tst	r0,r0			! the vsync-callback model alone decides
	bf	gw_model
	mov.l	l_gr3upd,r0		! GR3_UPDATE: the VDC5 clears IBUS_VEN (bit 0)
	mov.l	@r0,r0			! and P_VEN (bit 4) once the registers written
	tst	#0x11,r0		! are taken at a vsync; set = a base is pending
	bf	gw_fb			! (the panel may still show the back buffer)
gw_model:
	mova	st_pend,r0
	mov.l	@r0,r2
	tst	r2,r2
	bt	gw_shown		! nothing pending: the panel shows the other
	mov.l	@(4,r0),r2
	cmp/eq	r1,r2
	bf	gw_shown		! the panel shows the other buffer
gw_fb:	mova	st_pend,r0
	mov.l	@(16,r0),r1
	add	#1,r1
	mov.l	r1,@(16,r0)		! st_fb: windows that took the stock path
	mov	#2,r3			! SDRAM mode
	tst	r5,r5
	bt	gw_sres			! a draw callback: restore
	mov.l	@r5,r0
	tst	r0,r0
	bf	gw_sres
	mov.l	@(4,r5),r0
	tst	r0,r0
	bf	gw_sres
	mov.w	@(8,r5),r0
	extu.w	r0,r0
	mov.w	@(8,r8),r1
	extu.w	r1,r1
	cmp/eq	r0,r1
	bf	gw_sres
	mov.w	@(10,r5),r0
	extu.w	r0,r0
	mov.w	@(10,r8),r1
	extu.w	r1,r1
	cmp/eq	r0,r1
	bt	gw_entry		! the whole window: nothing to restore
gw_sres:
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	sts.l	pr,@-r15
	mov.l	@(12,r4),r5		! dst = the SDRAM surface
	mov.l	@(88,r8),r0		! y0
	mov.w	l_1600g,r1
	extu.w	r1,r1
	mul.l	r0,r1
	sts	macl,r0
	mov.l	l_gr3desc,r1
	mov.l	@(12,r1),r1		! back
	mov.l	l_mask2,r2
	and	r2,r1
	mov.l	l_gr3ab,r6
	sub	r1,r6			! front
	add	r0,r6			! src = front + y0 * 1600
	mov.w	@(10,r8),r7
	extu.w	r7,r7
	mov.w	l_1600g,r0
	extu.w	r0,r0
	mul.l	r0,r7
	sts	macl,r7			! bytes = h * 1600
	mov	#1,r4
	mov.l	r4,@-r15
	mov.l	l_copy,r0
	jsr	@r0
	nop
	add	#4,r15
	lds.l	@r15+,pr
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	mova	st_pend,r0
	mov.l	@(20,r0),r1
	add	#1,r1
	mov.l	r1,@(20,r0)		! st_fbres: restores made for the stock path
	bra	gw_entry
	mov	#2,r3
gw_shown:
	mov	#1,r3			! GR3 mode
	tst	r5,r5
	bt	gw_front		! a draw callback: nothing erased, restore
	mov.l	@r5,r0
	tst	r0,r0
	bf	gw_front		! x != 0
	mov.l	@(4,r5),r0
	tst	r0,r0
	bf	gw_front		! y != 0
	mov.w	@(8,r5),r0
	extu.w	r0,r0
	mov.w	@(8,r8),r1
	extu.w	r1,r1
	cmp/eq	r0,r1
	bf	gw_front		! w != window's
	mov.w	@(10,r5),r0
	extu.w	r0,r0
	mov.w	@(10,r8),r1
	extu.w	r1,r1
	cmp/eq	r0,r1
	bt	gw_entry		! the whole window: nothing to restore
gw_front:
	mov.l	r4,@-r15		! the caller's arguments
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	sts.l	pr,@-r15
	mov.l	@(88,r8),r0		! y0
	mov.w	l_1600g,r1
	extu.w	r1,r1
	mul.l	r0,r1
	sts	macl,r0
	mov.l	l_gr3desc,r1
	mov.l	@(12,r1),r1		! back
	mov.l	l_mask2,r2
	and	r2,r1
	mov	r1,r5
	add	r0,r5			! dst = back + y0 * 1600
	mov.l	l_gr3ab,r6
	sub	r1,r6			! front
	add	r0,r6			! src = front + y0 * 1600
	mov.w	@(10,r8),r7
	extu.w	r7,r7
	mov.w	l_1600g,r0
	extu.w	r0,r0
	mul.l	r0,r7
	sts	macl,r7			! bytes = h * 1600
	mov	#1,r4
	mov.l	r4,@-r15		! the helper's stack argument (as the flush passes it)
	mov.l	l_copy,r0
	jsr	@r0
	nop
	add	#4,r15
	lds.l	@r15+,pr
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	mova	st_part,r0
	mov.l	@r0,r1
	add	#1,r1
	mov.l	r1,@r0			! counted (emulator checks)
	mov	#1,r3			! GR3 mode (the copy clobbered r3)
gw_entry:
	mova	gd_tab,r0		! this descriptor's entry (desc, SDRAM base,
	mov	r0,r1			! window, drawn), or a free one
	mov	#8,r9
gw_find:
	mov.l	@r1,r0
	cmp/eq	r0,r4
	bt	gw_set
	tst	r0,r0
	bt	gw_set
	add	#16,r1
	dt	r9
	bf	gw_find
	bra	gw_ret			! table full: this window stays in SDRAM
	nop
gw_set:	mov.l	r4,@r1
	mov.l	@(12,r4),r0
	mov.l	r0,@(4,r1)		! desc -> its SDRAM base
	mov.l	r8,@(8,r1)		! its window
	mov.l	r3,@(12,r1)		! drawn this frame: 1 in GR3, 2 in SDRAM
	mov	r3,r0
	cmp/eq	#2,r0
	bt	gw_ret			! the stock path: no redirect
gw_base:
	mov.l	@(88,r8),r0		! y0
	mov.w	l_1600g,r1
	extu.w	r1,r1
	mul.l	r0,r1
	sts	macl,r0
	mov.l	l_gr3desc,r1		! the layer's GR3 descriptor: +12 = back buffer
	mov.l	@(12,r1),r1
	add	r1,r0
	mov.l	l_unc2,r1		! through the uncached alias: the CPU renderers'
	or	r1,r0			! writes reach the RAM the display reads
	mov.l	r0,@(12,r4)		! this frame's drawing goes into GR3
gw_ret:
	rts
	nop
	.align	2
l_800g:		.word	800			! gd_win's words (pc-relative loads reach forward only)
l_z133g:	.word	133
l_z135g:	.word	135
l_1600g:	.word	1600
	.p2align 2
st_pend:	.long	0			! +0 base written, not yet taken by the VDC
		.long	0			! +4 st_disp: base on the panel (0: unknown)
		.long	0			! +8 st_vs: vsyncs
		.long	0			! +12 st_vdc: base writes (plane 2)
		.long	0			! +16 st_fb: window-frames on the stock path (back buffer still shown)
		.long	0			! +20 st_fbres: front -> SDRAM restores for those
		.long	0			! +24 st_earlydone: base written early this flip
		.long	0			! +28 st_skipped: the flip's repeat writes skipped
		.long	0			! +32 st_stuck: GR3_UPDATE bits never seen to clear
l_mask3:	.long	0x1FFFFFFF
l_gr3upd:	.long	0xFFFF7780		! VDC5 GR3_UPDATE
l_vscb:		.long	0x0E508A34		! the vsync callback
l_sleepg:	.long	0x0E52EA70		! sleep(ms)

! The draw-callback dispatcher 0x0E50D16C(r4 = window, r5 = callback, ...),
! RAM API slot 0x1C001240 (its only reference): every widget draw passes
! here. A player window drawn before any clear of the frame would otherwise
! paint its stale SDRAM surface: it is redirected now (front-buffer restore
! first, gd_win with r5 = 0).
draw_wrap:
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	sts.l	pr,@-r15
	mov	r4,r8
	mov.l	@(152,r8),r4
	tst	r4,r4
	bt	dw_go			! no surface of its own
	bsr	gd_win
	mov	#0,r5
dw_go:	lds.l	@r15+,pr
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	mov.l	l_drawcb,r0
	jmp	@r0
	nop
.endif

.ifdef GR3DIRECT
! The flush copies each composited window's surface to GR3 through the DMA
! helper 0x0E50FFDC (r4 = 1, r5 = dst, r6 = src, r7 = bytes; literal
! 0x0E508FCC, its only use; r9 = the source descriptor in the copy routine).
! A source that already lies in GR3 (a window redirected above this frame)
! has nothing to copy: return as the helper would (the caller ignores r0 and
! pops its own stack argument) and give the descriptor its SDRAM base back,
! so the firmware (surface allocator included) sees only real bases between
! flushes. A player window the frame did NOT redraw has its picture in the
! front buffer only (its SDRAM surface is stale since its first redirect):
! the copy then takes the same rows of the front buffer as its source.
copy_wrap:
! A window that took the stock path this frame (its first touch found the
! back buffer still on the panel) is copied here into that buffer. Stock
! flushes at least a field after the previous flip, so the base is taken by
! then; gr3direct's faster frames can flush before it, and the copy (then
! the colourkeyed children composed over it) would land in the buffer being
! scanned: the bottom window seen without its overview and playhead. So any
! copy into GR3 first waits until that buffer is off the panel (the same
! test as gd_win), at most 20 polls of sleep(1) in case the VDC never
! clears its update bits.
	mov.l	l_mask,r1
	mov	r5,r0
	and	r1,r0
	mov.l	l_gr3lo,r1
	sub	r1,r0
	mov.l	l_gr3len,r1
	cmp/hs	r1,r0
	bt	cw_go			! not a copy into GR3
	mov	#20,r3
cw_poll:
	mova	l_pend_off,r0
	mov.w	l_pend_off,r1
	add	r1,r0			! r0 = st_pend
	mov.l	@(32,r0),r1
	tst	r1,r1
	bf	cw_model		! st_stuck: the bits are not usable here
	mov.l	l_gr3upd2,r1
	mov.l	@r1,r1
	mov	#0x11,r2
	tst	r2,r1
	bf	cw_wait			! a base written and not taken yet
cw_model:
	mov.l	@r0,r1
	tst	r1,r1
	bt	cw_go			! nothing pending: the panel shows the other buffer
	mov.l	@(4,r0),r1		! st_disp
	mov.l	l_gr3desc,r2
	mov.l	@(12,r2),r2
	mov.l	l_mask2,r0
	and	r0,r2			! back
	cmp/eq	r1,r2
	bf	cw_go
cw_wait:
	dt	r3
	bf	cw_sleep
	mova	l_pend_off,r0		! 20 polls and the base still not taken: if
	mov.w	l_pend_off,r1		! the update bits were what kept us here,
	add	r1,r0			! stop trusting them (st_stuck) so no later
	mov.l	l_gr3upd2,r1		! copy or window pays this wait again
	mov.l	@r1,r1
	mov	#0x11,r2
	tst	r2,r1
	bt	cw_go
	mov	#1,r1
	bra	cw_go
	mov.l	r1,@(32,r0)
cw_sleep:
	sts.l	pr,@-r15
	mov.l	r3,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	mov.l	l_sleep,r0
	jsr	@r0
	mov	#1,r4
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	mov.l	@r15+,r3
	lds.l	@r15+,pr
	mova	st_cwait,r0
	mov.l	@r0,r1
	add	#1,r1
	mov.l	r1,@r0			! counted (emulator checks)
	bra	cw_poll
	nop
cw_go:
.ifdef TESTALT
	mova	st_c0,r0
	mov.l	@r0,r3
	add	#1,r3
	mov.l	r3,@r0
.endif
	mov.l	l_mask,r1
	mov	r6,r0
	and	r1,r0
	mov.l	l_gr3lo,r1
	sub	r1,r0
	mov.l	l_gr3len,r1
	cmp/hs	r1,r0			! outside GR3: a copy from SDRAM
	bt	cw_sdram
	mova	gd_tab,r0
	mov	r0,r1
	mov	#8,r2
2:	mov.l	@r1,r0
	cmp/eq	r0,r9
	bt	3f
	add	#16,r1
	dt	r2
	bf	2b
	rts
	mov	#0,r0
3:	mov.l	@(4,r1),r0
	mov.l	r0,@(12,r9)		! SDRAM base back
	mov	#0,r0
	mov.l	r0,@(12,r1)		! not drawn (yet) in the next frame
	rts
	mov	#0,r0
cw_sdram:
.ifdef TESTALT
	mova	st_c1,r0
	mov.l	@r0,r3
	add	#1,r3
	mov.l	r3,@r0
.endif
	mova	gd_tab,r0
	mov	r0,r1
	mov	#8,r2
4:	mov.l	@r1,r0
	cmp/eq	r0,r9
	bt	5f
	add	#16,r1
	dt	r2
	bf	4b
	bra	1f			! not a redirected window: the stock copy
	nop
5:
.ifdef TESTALT
	mova	st_c2,r0
	mov.l	@r0,r3
	add	#1,r3
	mov.l	r3,@r0
.endif
	mov.l	@(12,r1),r0
	tst	r0,r0
	bf	1f			! drawn this frame yet in SDRAM: not ours
.ifdef TESTALT
	mova	st_c3,r0
	mov.l	@r0,r3
	add	#1,r3
	mov.l	r3,@r0
.endif
	mov.l	@(8,r1),r2		! the window still owns this descriptor and is
	mov.l	@(152,r2),r0		! still a player window? (the pool slot may
	cmp/eq	r0,r9			! have been reused since)
	bf	1f
.ifdef TESTALT
	mova	st_c4,r0
	mov.l	@r0,r3
	add	#1,r3
	mov.l	r3,@r0
.endif
	mov.l	@(12,r2),r0
	mov.w	l_z133c,r3
	cmp/eq	r0,r3
	bt	6f
	mov.w	l_z135c,r3
	cmp/eq	r0,r3
	bf	1f
6:	mov.l	l_gr3desc,r1		! back = the buffer being flushed,
	mov.l	@(12,r1),r1		! front = the other one (A + B - back)
	mov.l	l_mask,r0
	and	r0,r1
	mov.l	l_gr3ab,r0
	sub	r1,r0			! front
	sub	r1,r0			! front - back
	mov	r5,r6
	add	r0,r6			! src = dst - back + front
	mova	st_sub,r0
	mov.l	@r0,r1
	add	#1,r1
	mov.l	r1,@r0			! counted (emulator checks)
1:	mov.l	l_copy,r0
	jmp	@r0
	nop
.endif

.ifdef GR3DIRECT
! The flip 0x0E50912E waits for a vsync (flag 0x0F6A6960, sleep(1) between
! polls) and only THEN programs the VDC with the buffer it drew (0x0E526626
! (2, base), the GR3 descriptor r12's +12) and toggles +12 to the other one.
! The VDC5 takes a new base at the NEXT vsync, so the buffer just drawn
! stays hidden for one more field and the one still on the panel becomes the
! next frame's drawing target. Stock never notices: a frame only touches GR3
! at its end, in the flush's copies. gr3direct draws into GR3 from the
! frame's first clear on, so that field showed the clear and the half-drawn
! windows (the deck's flicker; the emulator reproduces it with
! CDJ_GUI_VDC_LATCH=1). This wrapper of the flip's sleep (its literal
! 0x0E509230) programs the base at the first poll of the wait, so it is
! taken at the vsync the flip waits for; the stock write after the wait
! repeats the same value. Only the wait loop's sleep(1) acts, once per flip
! (the base last programmed is remembered; +12 toggles between flips).
flip_sleep:
	mov	r4,r0
	cmp/eq	#1,r0
	bf	fs_go			! sleep(33) before the wait: not the poll
	mov.l	@(12,r12),r3		! r12 = the GR3 descriptor in the flip
	mova	st_flip,r0
	mov.l	@r0,r2
	cmp/eq	r3,r2
	bt	fs_go			! this flip's base is programmed already
	mov.l	r3,@r0
	sts.l	pr,@-r15
	mov.l	r4,@-r15
	mov	r3,r5
	bsr	vdcset_wrap		! recorded as pending (st_pend)
	mov	#2,r4
	mov.l	@r15+,r4
	lds.l	@r15+,pr
	mova	st_flip,r0
	mov.l	@r0,r3
	mova	l_pend_off,r0		! st_pend lies behind (pc-relative loads reach
	mov.w	l_pend_off,r1		! forward only): anchor + (negative) offset
	add	r1,r0
	mov.l	r3,@(24,r0)		! st_earlydone = this base
	mova	st_early,r0
	mov.l	@r0,r1
	add	#1,r1
	mov.l	r1,@r0			! st_early: flips written before their vsync
	mov.l	l_vflag,r1		! a vsync between the flip's clear of the flag
	mov	#0,r0			! and this write would end the wait with the
	mov.l	r0,@r1			! old base taken: wait for the next one instead
fs_go:	mov.l	l_sleep,r0
	jmp	@r0
	nop
.endif

.ifdef GR3DIRECT
	.p2align 2
l_layer0:	.long	0x0F6A6964		! layer 0
l_mask2:	.long	0x1FFFFFFF		! (gd_win's copies: the end pool is out of reach)
l_unc2:		.long	0x20000000
l_gr3desc:	.long	0x0F6A4B08		! layer 0's GR3 surface descriptor (+12 = back buffer)
l_gr3lo:	.long	0x1C080000		! GR3 buffers A and B
l_gr3len:	.long	1536000
l_copy:		.long	0x0E50FFDC		! the DMA copy helper
	.p2align 2
l_gr3ab:	.long	0x1C080000 + 0x1C13B800
l_vdcset:	.long	0x0E526626		! program the VDC frame base (r4 = 2, r5 = base)
l_vflag:	.long	0x0F6A6960		! the flip's vsync flag
l_sleep:	.long	0x0E52EA70		! the flip's sleep(ms)
l_drawcb:	.long	0x0E50D16C		! the draw-callback dispatcher
st_flip:	.long	0			! base programmed for the current flip
	.p2align 2
l_pend_off:	.word	st_pend - l_pend_off
	.p2align 2
l_gr3upd2:	.long	0xFFFF7780		! VDC5 GR3_UPDATE (copy_wrap's copy)
st_cwait:	.long	0			! copy_wrap polls waiting for the base
st_early:	.long	0			! early writes made (flip_sleep)
st_sub:		.long	0			! front-buffer copies made (a window not redrawn)
st_part:	.long	0			! front-buffer restores before a partial first clear
st_alt:		.long	0
st_c0:		.long	0
st_c1:		.long	0
st_c2:		.long	0
st_c3:		.long	0
st_c4:		.long	0
gd_tab:		.long	0, 0, 0, 0, 0, 0, 0, 0	! desc, SDRAM base, window, drawn: 8 entries
		.long	0, 0, 0, 0, 0, 0, 0, 0
		.long	0, 0, 0, 0, 0, 0, 0, 0
		.long	0, 0, 0, 0, 0, 0, 0, 0
l_z133c:	.word	133
l_z135c:	.word	135
	.p2align 2
.endif

blit_wrap:
	mova	st_seq,r0
	mov.l	@r0,r1
	add	#1,r1
	mov.l	r1,@r0
	mov.l	l_blit,r0
	jmp	@r0
	nop

! r4 = 1 from the rect fill, r5 = destination, r6 = colour, r7 = bytes
fill_wrap:
.ifdef MARQUEE
	extu.w	r6,r1			! marqueefix folded in (same DMA-fill literal):
	mov.w	l_defc_m,r0		! the stock selection 0xDEFC -> 3000 navy 0x19CD
	extu.w	r0,r0
	cmp/eq	r0,r1
	bf	fw_go
	mov.w	l_navy_m,r6
	extu.w	r6,r6
fw_go:
.endif
	mova	st_seq,r0
	mov	r0,r3			! r3: +0 seq +4 rseq +8 lo +12 hi +16 colour +20 valid
	mov	r4,r0
	cmp/eq	#1,r0
	bf	inval			! not the rect fill's DMA path
	mov.l	l_min,r1
	cmp/hs	r1,r7
	bf	inval			! under 0x40000: the async path
	mov.l	@(20,r3),r0
	tst	r0,r0
	bt	record			! nothing remembered
	mov.l	@r3,r1
	mov.l	@(4,r3),r2
	add	#1,r2
	cmp/eq	r1,r2
	bf	record			! not the very next rect-fill call
	extu.w	r6,r1
	mov.l	@(16,r3),r2
	cmp/eq	r1,r2
	bf	record			! another colour
	mov.l	l_mask,r1
	and	r5,r1			! lo
	mov.l	@(8,r3),r2
	cmp/hs	r2,r1
	bf	record			! starts before it
	add	r7,r1			! hi
	mov.l	@(12,r3),r2
	cmp/hs	r1,r2
	bf	record			! ends after it
	mov.l	l_ch6,r1
	mov.l	@r1,r0			! SAR
	mov.l	l_pat,r2
	cmp/eq	r0,r2
	bf	record
	mov.l	@(4,r1),r0		! DAR
	mov.l	@(12,r3),r2
	mov.l	l_unc,r3
	or	r3,r2
	cmp/eq	r0,r2
	mova	st_seq,r0
	bf/s	record
	mov	r0,r3
	mov.l	@(8,r1),r0		! DMATCR
	tst	r0,r0
	bf	record
	mov.l	@(12,r1),r0		! CHCR
	tst	#1,r0
	bf	record			! DE still set
	mov.l	@r3,r1
	mov.l	r1,@(4,r3)		! a following sibling may skip too
.ifdef VERIFY
	sts.l	pr,@-r15
	mov.l	@(4,r15),r0		! the caller's stack argument, where the fill reads it
	mov.l	r0,@-r15
	mov.l	l_fill,r0
	jsr	@r0
	nop
	add	#4,r15
	lds.l	@r15+,pr
.endif
	rts
	mov	#0,r0

record:
	mov.l	@r3,r1
	mov.l	r1,@(4,r3)		! rseq = this rect-fill call
	mov.l	l_mask,r1
	and	r5,r1
	mov.l	r1,@(8,r3)		! lo
	add	r7,r1
	mov.l	r1,@(12,r3)		! hi
	extu.w	r6,r1
	mov.l	r1,@(16,r3)		! colour
	mov	#1,r1
	bra	go
	mov.l	r1,@(20,r3)		! valid

inval:
	mov	#0,r1
	mov.l	r1,@(20,r3)
go:
	mov.l	l_fill,r0
	jmp	@r0
	nop
.ifdef MARQUEE
l_defc_m:	.word	0xDEFC
l_navy_m:	.word	0x19CD
.endif

	.align	2
st_seq:	.long	0			! bumped by every rect-fill and blit call
	.long	0			! rseq: seq when the remembered fill ran
	.long	0			! lo (physical)
	.long	0			! hi
	.long	0			! colour
	.long	0			! valid
l_fill:	.long	0x0E510368
l_rect:	.long	0x0E508E1E
l_blit:	.long	0x0E509244
l_mask:	.long	0x1FFFFFFF
l_ch6:	.long	0xFFFE1060		! DMAC channel 6: SAR, DAR, DMATCR, CHCR
l_pat:	.long	0x3C27A060		! channel 6's fill pattern (0x3C27A000 + 16 * ch)
l_unc:	.long	0x20000000
l_min:	.long	0x40000			! the rect fill's synchronous channel-6 size
