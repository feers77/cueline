! SPDX-License-Identifier: Apache-2.0
!
! ui3000x (GUI, SH-2A): the "B - 3000X moderno" redesign, GUI side.
! The deck's chrome (title bars, browse/UTILITY row stripes, list cursors,
! and the INFO/preview panel) is bitmap art the boot loader unpacks into
! SDRAM (the resource base, *0x0E598F6C = 0x0CD00000). Instead of shipping
! new art, recolour it in place once, before the first frame: for each group
! of resources in the table below, every pixel equal to a "from" colour
! becomes its "to" colour (RGB565, one pass per resource, no chaining between
! pairs). The browse/INFO backgrounds (0x523-0x529) also recolour the light
! INFO panel (#F7F3F7 -> dark) and its separators; the selected-row / INFO
! text that the firmware paints dark is made light by the ui3000xtext data
! poke (patch_gui, auto with this mod), so it reads on the new dark panel and
! on the cyan cursor.
!
! The browse TRACK list cursor (resource 0x52F, 672 px: the artwork lists'
! bar) is recoloured by column instead: left of the split column (sE_split)
! it stays dark, from there rightward it becomes the cyan selection. With the
! cursor at the stock x0 (screen x 116) a split at the title (screen x 179 =
! column 63) keeps the row's 3-band waveform strip (rowwave/rowcell, screen x
! 33..145) and the track-type icon the same selected or not; with rowmeta's
! full-row curbar the split is 0 (the whole row). See splitE. The other list
! cursors are a flat cyan.
!
! Called instead of the UI loop's draw (0x1C002CE6, through the literal at
! 0x1C001528 that patch_gui's REDIRECTS points here): the first call
! recolours, every call then jumps to the stock draw with r4-r7 untouched.
! Each changed pixel is stored through the cached address and through its
! uncached view (+0x20000000), so neither a write-back D-cache nor a DMA
! reading SDRAM can see the stock colour afterwards.
	.text
ui3000x:
	mova	done,r0
	mov.l	@r0,r1
	tst	r1,r1
	bf	draw			! already recoloured
	mov	#1,r1
	mov.l	r1,@r0
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	r12,@-r15
	mov.l	r13,@-r15
	mov.l	resptr,r1
	mov.l	@r1,r12			! r12 = resource base (records, pixels)
	tst	r12,r12
	bt	out
	mov.l	unc,r11			! r11 = cached -> uncached offset
	mova	table,r0
	mov	r0,r13			! r13 = table cursor
group:	mov.w	@r13+,r8		! first resource (0xFFFF ends the table)
	cmp/pz	r8
	bt	2f
	bra	splitE			! table done -> the cursor's column split
	nop
2:	mov.w	@r13+,r9		! last resource
	mov.w	@r13+,r10		! number of colour pairs; r13 = the pairs
res:	mov	#44,r0
	mov	r8,r1
	mulr	r0,r1
	add	r12,r1			! r1 = the resource's record
	mov	r1,r2
	add	#24,r2
	mov.b	@r2,r0			! format: 1 or 2 = 16 bpp
	cmp/eq	#1,r0
	bt	1f
	cmp/eq	#2,r0
	bf	next
1:	mov.w	@(4,r1),r0
	extu.w	r0,r3			! width
	mov.w	@(6,r1),r0
	extu.w	r0,r0			! height
	mulr	r0,r3			! r3 = pixels
	tst	r3,r3
	bt	next
	mov.l	@(32,r1),r2
	add	r12,r2			! r2 = first pixel
pix:	mov.w	@r2,r0
	mov	r13,r4
	mov	r10,r5
pair:	mov.w	@r4+,r6			! from
	cmp/eq	r6,r0
	bt	hit
	dt	r5
	bf/s	pair
	add	#2,r4
	bra	px_end
	nop
hit:	mov.w	@r4,r6			! to
	mov.w	r6,@r2
	mov	r2,r7
	add	r11,r7
	mov.w	r6,@r7
px_end:	dt	r3
	bf/s	pix
	add	#2,r2
next:	cmp/ge	r9,r8
	bf/s	res
	add	#1,r8
	mov	r10,r0
	shll2	r0
	bra	group
	add	r0,r13			! past this group's pairs

! splitE: recolour the browse artwork-list cursor (0x52F) by column -- dark
! left of the title, cyan from it -- so the waveform strip and icon stay dark
! on the selected row. r11/r12 are still the uncached offset and resource base.
splitE:	mov	#44,r0
	mov.w	sE_id,r8
	mulr	r0,r8
	add	r12,r8			! r8 = the 0x52F record
	mov	r8,r1
	add	#24,r1
	mov.b	@r1,r0			! format
	cmp/eq	#2,r0
	bf	out			! not 16 bpp: leave it stock
	mov.w	@(4,r8),r0
	extu.w	r0,r9			! r9 = width
	mov.w	@(6,r8),r0
	extu.w	r0,r0			! height
	mov	r9,r3
	mulr	r0,r3			! r3 = width * height
	tst	r3,r3
	bt	out
	mov.l	@(32,r8),r2
	add	r12,r2			! r2 = pixels
	mov	#0,r6			! r6 = column
	mov.w	sE_split,r7		! r7 = split column
sE_pix:	mov.w	@r2,r0
	mov.w	sE_from,r1
	cmp/eq	r1,r0
	bf	sE_next			! not the cursor fill: leave it
	cmp/ge	r7,r6			! column >= split -> cyan
	bt	sE_cyan
	mov.w	sE_dark,r1
	bra	sE_wr
	nop
sE_cyan: mov.w	sE_cur,r1
sE_wr:	mov.w	r1,@r2
	mov	r2,r0
	add	r11,r0
	mov.w	r1,@r0
sE_next: add	#1,r6
	cmp/ge	r9,r6			! end of line -> column 0
	bf	sE_nocol
	mov	#0,r6
sE_nocol: dt	r3
	bf/s	sE_pix
	add	#2,r2			! fall into out

out:	mov.l	@r15+,r13
	mov.l	@r15+,r12
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
! INFO open (UI model screen byte, *0x0E5B829C + 7 == 0x06; re/V2_PROTOCOL.md):
! the overview strip shows the browsed track (Link Cue preview), so the
! playing track's progress -- the bar z59 (600x6) and the playhead z57/z54
! (5x49, 3x49), composited children of the bottom window -- is hidden: their
! "composited" bit (+7 bit 3, the flush's child loop 0x0E509A1C tests it) is
! cleared on entering INFO and set again, on the same windows only, on
! leaving it. Uses r0-r3 and saves r4/r5; r4-r7 reach the stock draw intact.
draw:	mov.l	l_model,r1
	mov.b	@(7,r1),r0
	extu.b	r0,r0
	mov	#0,r2
	cmp/eq	#6,r0
	bf	1f
	mov	#1,r2			! r2 = INFO is up
1:	mova	hid,r0
	mov.l	@r0,r3
	cmp/eq	r2,r3
	bt	dr_go			! no change since the last frame
	mov.l	r2,@r0
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	tst	r2,r2
	bt	dr_show
	mova	hid_tab,r0		! hide: walk the window pool
	mov	r0,r4			! r4 = next free slot of the table
	mov.l	l_pool,r1
	mov.w	l_nwin,r5
2:	mov.l	@r1,r0
	mov.l	l_inuse,r3
	tst	r3,r0
	bt	4f			! free slot
	mov.l	@(28,r1),r0
	mov.l	l_layer0,r3
	cmp/eq	r3,r0
	bf	4f
	mov.l	@(12,r1),r0		! z key
	cmp/eq	#54,r0
	bt	3f
	cmp/eq	#57,r0
	bt	3f
	cmp/eq	#59,r0
	bf	4f
3:	mov.b	@(7,r1),r0
	tst	#8,r0
	bt	4f			! not composited now: leave it
	and	#0xF7,r0
	mov.b	r0,@(7,r1)
	mov.l	r1,@r4			! remember it (4 entries)
	add	#4,r4
	mova	hid_end,r0
	cmp/eq	r0,r4
	bt	dr_done			! table full
4:	mov.w	l_wsize,r3
	dt	r5
	bf/s	2b
	add	r3,r1
	bra	dr_done
	nop
dr_show:
	mova	hid_tab,r0		! show: the windows we hid, if still ours
	mov	r0,r4
	mov	#4,r5
5:	mov.l	@r4,r1
	tst	r1,r1
	bt	6f
	mov	#0,r0
	mov.l	r0,@r4
	mov.l	@r1,r0
	mov.l	l_inuse,r3
	tst	r3,r0
	bt	6f			! freed since: leave it
	mov.l	@(12,r1),r0
	cmp/eq	#54,r0
	bt	7f
	cmp/eq	#57,r0
	bt	7f
	cmp/eq	#59,r0
	bf	6f			! the slot was reused
7:	mov.b	@(7,r1),r0
	or	#8,r0
	mov.b	r0,@(7,r1)
6:	dt	r5
	bf/s	5b
	add	#4,r4
dr_done:
	mov.l	@r15+,r5
	mov.l	@r15+,r4
dr_go:	mov.l	stock,r0
	jmp	@r0
	nop
	.p2align 2
l_model:	.long	0x0E5B829C		! UI model (GUI copy)
l_pool:		.long	0x0F6C0690		! window pool, 256 x 160 B
l_inuse:	.long	0x40000000
l_layer0:	.long	0x0F6A6964
hid:		.long	0			! 1 while INFO hides the progress windows
hid_tab:	.long	0, 0, 0, 0
hid_end:
l_nwin:		.word	256
l_wsize:	.word	160
	.p2align 2

	.p2align 2
done:	.long	0			! set by the first call
resptr:	.long	0x0E598F6C		! -> the resource table (RAM)
unc:	.long	0x20000000		! SH7269: 0x2xxxxxxx = uncached view
stock:	.long	0x1C002CE6		! the UI loop's draw

! The 3000X palette (B: re/UI3000X.md). RGB565.
	.equ	HDR,	0x18E4		! #1B1F25 title bar (stock navy #103063)
	.equ	ROWA,	0x10C3		! #15181C light row stripe (stock #303030)
	.equ	ROWB,	0x0862		! #0B0D10 dark row stripe (stock #181C18)
	.equ	CUR,	0x05BF		! #00B4FF list cursor, Pioneer cyan (stock #D8DCE0)
	.equ	SEL,	0x7D9F		! #7FB2FF UTILITY value cell (stock #90A0A8; its text is dark)
	.equ	VALC,	0xC67D		! #C0CFE8 light tint for the UTILITY value cell: the value's ink is dark, so a light cell reads (SEL was too mid -> washed)
	.equ	LINE,	0x2146		! #242930 separators (stock #404040)
	.equ	PSEL,	0x19CD		! #1B3B6E 3000 selection blue (player loop/beat-jump selected chips)

! splitE constants: the browse cursor and its column split.
sE_id:	.word	0x52F			! the 672 px browse artwork-list cursor
sE_split: .word	0			! the bar spans the whole row (rowmeta's curbar),
					! highlighted end to end as on the CDJ-3000
sE_from: .word	0xDEFC			! stock cursor fill #D8DCE0
sE_dark: .word	ROWB			! left of the title: the dark row stripe
sE_cur:	.word	PSEL			! from the title rightward: 3000 navy selection

	.p2align 2
table:
	.word	0x523, 0x529, 5		! browse/INFO backgrounds (768x277)
	.word	0x118C, HDR, 0x3186, ROWA, 0x18E3, ROWB, 0xF79E, ROWA, 0xDEFB, LINE
	! 0xF79E = #F7F3F7 the INFO/preview panel -> dark (#15181C); 0xDEFB =
	! #D8DCDE its separators -> #242930. (0x523 has no panel: no effect.)
	.word	0x52B, 0x52B, 3		! UTILITY background
	.word	0x2966, HDR, 0x18E3, ROWB, 0x4228, LINE
	.word	0x4BC, 0x4BC, 1		! the player's title bar (768x30)
	.word	0x118C, HDR
	.word	0x52E, 0x52E, 1		! the full-width list cursor (plain lists)
	.word	0xDEFC, PSEL
	.word	0x530, 0x532, 1		! the narrow list cursors (0x52F: splitE)
	.word	0xDEFC, PSEL
	.word	0x57F, 0x580, 2		! UTILITY cursor bars (name / value)
	.word	0xDEFC, PSEL, 0x9515, VALC	! name cell -> 3000 navy; value cell -> light tint so its dark text reads (was SEL, too washed)
	! Player QUANTIZE label + value chips (capa 4b): the active red accent -> 3000X
	! cyan; red is text/border on a dark bg, so cyan reads. Inactive grey stays.
	.word	0x442, 0x44C, 1		! QUANTIZE + value chips 1/1-2/1-4/1-8 (1090-1100)
	.word	0xF800, CUR
	! Player loop/beat-jump controls (capa 4a + 4b, re/UI3000X.md): the selected chip
	! face (stock grey) -> the 3000 blue selection, keeping the chips' baked light
	! text legible; the shown face #202429 and its glossy grey bevel #737983 -> the
	! flat 3000X panel #15181C and border #242930, so the chips read dark and flat
	! like a 3000. Off state (#080C08) stays dark. Default player view = flatter/darker.
	.word	0x44D, 0x469, 4		! BEAT JUMP box + beat-jump-size chips (1101-1129)
	.word	0x5AEC, PSEL, 0x2966, PSEL, 0x2125, ROWA, 0x73D0, LINE
	.word	0x477, 0x497, 4		! 1-Beat chevron + LOOP MODE + M.CUE LIST chips (1143-1174)
	.word	0x5AEC, PSEL, 0x2966, PSEL, 0x2125, ROWA, 0x73D0, LINE
	.word	0xFFFF
