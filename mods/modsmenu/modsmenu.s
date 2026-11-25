! SPDX-License-Identifier: Apache-2.0
!
! modsmenu: three UTILITY items for our mods, appended at the end of the
! menu (patch_main.place_modsmenu puts the entries into the item table: a
! copy of the stock table, and bumps the count). How the menu engine and the settings record work: re/UTILITY_ITEMS.md.
!
!   MODS        OFF / ON, saved. OFF = every switchable mod off, ours and
!               any other non-stock UTILITY item set to its option 0 (the
!               saved ones stay so after MODS ON: set them again by hand).
!               The SHORT CUT choices (3BAND, TYPE 3) are left alone.
!   LINK CUE    OFF / PREVIEW / CUE / BOTH, BOTH at every boot. PREVIEW =
!               INFO + strip and the browse rows' touch; CUE = Touch Cue on
!               the playing track; both stream to the mixer's LINK CUE.
!   WAV 32-BIT  OFF / ON, ON at every boot. 32-bit WAV playback (OFF: the
!               deck refuses them as stock does).
!   LINK CUE DIAG  read-only: the TchAud task's diagnostics, for a deck
!               without any other way to read its RAM. Its one "option" is a
!               text buffer in this block the task rewrites with the state
!               (E/T from the mixer's timing, packets per second, index
!               state, state bits), and the task rewrites the LABEL too
!               (its counters: timeouts, rejected timings, resyncs, failed
!               sends, open failures, kill edges, strip redraws).
!
! Each item's word holds its option index (0 = OFF).
!
! The TchAud task's kill check (mods/touch_audio, every 2 s) turns these
! words into the kill words our hooks test (layout.inc: MODSV, LCV, W32V). The browse rows stay CDJ-3000 style either way: the cell's shape
! is a static GUI poke.
!
! Persistence (MODS only): the spare high bit of the QUANTIZE field
! (settings record byte 5 bit 5; QUANTIZE has 4 values in 3 bits), 1 = OFF.
! Two stock literals are redirected: the record unpacker's QUANTIZE setter
! (0x0846D990 -> mods_load) and the packer's getter call that runs after
! byte 5 is packed (0x0846D5D0 -> mods_save, r12 = the record). No other bit
! of the record is kept free, so the other two items are not saved.
!
! Handlers are called with r4 = the entry; r0 out; r8-r14 kept. An entry's
! word is found from its label pointer (+0), since the entries may be
! copied into another table.

	.include "ownstat.inc"
	.text
	.global	entries, mods_off, lc_off, w32_off, diag_off, diag_txt
	.global	it_fmt, it_commit, mods_load, mods_save, entries2, mm_publish, mm_copy, light_v, bpmd_v, wave_v, pos_v
entries:
	.long	L_MODS, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_LC, OPTS4, 4, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_W32, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_DIAG, OPTSD, 1, -1, -1, 0	! read-only: its one "option" is the
	.long	0x084EE886, it_fmt, 0x084EFC34, 0x084EFC38, 0x084EFCD8	! text below
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
mods_off: .long	1			! base + 240: MODS (0 OFF, 1 ON)
lc_off:	.long	3			! base + 244: LINK CUE (0 OFF, 1 PREVIEW, 2 CUE, 3 BOTH)
w32_off: .long	1			! base + 248: WAV 32-BIT (0 OFF, 1 ON)
diag_off: .long	0			! base + 252: LINK CUE DIAG (always 0)
diag_txt: .short '-', '-', 0		! base + 256: the TchAud task's diagnostic
	.space	128 - 6			! line, UTF-16 (layout.inc DIAGT), <= 63 chars
! V4n36 trace: the build record (base + 0x180, layout.inc BLDID; patch_main fill_build_record): "BLD1" + the
! ASCII build ID "TAG YYYYMMDD-HHMM HASH8" (NUL-padded), then the UTILITY BUILD value (UTF-16 "TAG HASH8").
! Read by usblog's boot record and the network commander (work/autotest/cmd.py ver).
	.global	bld_rec, bld_u16, kill_v
bld_rec: .ascii	"BLD1"
	.space	44
bld_u16: .short	'-', 0
	.space	48 - 4
! V4n36 trace: the kill switches (base + 0x1E0, layout.inc KILLB), 1 ON = the feature, 0 OFF = its stock path,
! checked at each feature's entry; UTILITY items after VERSION No. (DEV: shown while TEST LOG is not OFF; RELEASE =
! no TEST LOG item: always shown, kl_reveal), not saved.
	.ifdef	NOTONE			! Cueline 2.2 (patch_main CDJ_NOTONE): no KEY SYNC -- its stock path, and no row
kill_v:	.long	0			! +0  KEY SYNC: OFF for good in this release
	.else
kill_v:	.long	1			! +0  KEY SYNC (mods/keyshift ksy_tap / hc_set / hc_lamp)
	.endif
	.long	1			! +4  MASTER WAVE NFS (mods/w8fetch w8send's NFS lookup)
	.long	1			! +8  MASTER WAVEFORM (display: the phase meter WAVEFORM view's master wave)
	.long	1			! +12 HW BAND LAYER (display: the GR2 hardware band, else the software band)
	.long	1			! +16 LINK ROW PREVIEW (touch_audio row_touch on a LINKed medium's list)
	.long	1			! +20 BLACK BOX (V4n37 mods/bbox; UTILITY item when bbox is in the build: BBOX, V4n37r)
	.long	1			! +24 KS3 ENGINE (KS3 A/B DEV test builds, CDJ_KSAB=1: 1 ON = the ks3 DSP engine,
					!     0 OFF = the previous one; mods/ownks main_ownks.s KSAB), else spare
	.long	1			! +28 LINK 0x0B (v4.2 mods/link0b: send / use the CDJ-3000 0x0b precise position)
OPTS:	.long	L_OFF, L_ON
OPTS4:	.long	L_OFF, L_PV, L_CUE, L_BOTH
OPTSD:	.long	diag_txt
L_MODS:	.short	'M', 'O', 'D', 'S', 0
L_LC:	.short	'L', 'I', 'N', 'K', ' ', 'C', 'U', 'E', 0
L_W32:	.short	'W', 'A', 'V', ' ', '3', '2', '-', 'B', 'I', 'T', 0
	.global	L_DIAG
L_DIAG:	.short	'L', 'I', 'N', 'K', ' ', 'C', 'U', 'E', ' ', 'D', 'I', 'A', 'G', 0
	.space	48 - 28			! the task rewrites this label with its
					! counters (layout.inc DIAGL, <= 23 chars)
L_OFF:	.short	'O', 'F', 'F', 0
L_ON:	.short	'O', 'N', 0
L_PV:	.short	'P', 'R', 'E', 'V', 'I', 'E', 'W', 0
L_CUE:	.short	'C', 'U', 'E', 0
L_BOTH:	.short	'B', 'O', 'T', 'H', 0
	.p2align 2

! r4 = entry -> r1 = its word (by the label pointer at +0). Uses r0, r1.
wordof:
	mov.l	@r4,r0
	mov.l	r2,@-r15		! V4n36 trace: BUILD and the kill switches (kl_map: label, word; 0 ends)
	mov.l	w_klm,r1
wo_l:	mov.l	@r1,r2
	tst	r2,r2
	bt	wo_n
	cmp/eq	r2,r0
	bt	wo_f
	bra	wo_l
	add	#8,r1
wo_f:	mov.l	@(4,r1),r1
	rts
	mov.l	@r15+,r2
wo_n:	mov.l	@r15+,r2
	mov.l	w_lc,r1
	cmp/eq	r1,r0
	bf	1f
	mov.l	w_lcv,r1
	rts
	nop
1:	mov.l	w_w32,r1
	cmp/eq	r1,r0
	bf	2f
	mov.l	w_w32v,r1
	rts
	nop
2:	mov.l	w_diag,r1
	cmp/eq	r1,r0
	bf	3f
	mov.l	w_diagv,r1
	rts
	nop
3:	mov.l	w_light,r1
	cmp/eq	r1,r0
	bf	4f
	mov.l	w_lightv,r1
	rts
	nop
4:	mov.l	w_bpmd,r1
	cmp/eq	r1,r0
	bf	6f
	mov.l	w_bpmdv,r1
	rts
	nop
6:	mov.l	w_wave,r1
	cmp/eq	r1,r0
	bf	7f
	mov.l	w_wavev,r1
	rts
	nop
7:	mov.l	w_pos,r1
	cmp/eq	r1,r0
	bf	5f
	mov.l	w_posv,r1
	rts
	nop
5:
	.ifdef	KEYSHIFT
	mov.l	w_ks,r1
	cmp/eq	r1,r0
	bf	8f
	mov.l	w_ksv,r1
	rts
	nop
8:	mov.l	w_rbb,r1
	cmp/eq	r1,r0
	bf	11f
	mov.l	w_rbbv,r1
	rts
	nop
11:	mov.l	w_ksyb,r1
	cmp/eq	r1,r0
	bf	9f
	mov.l	w_ksybv,r1
	rts
	nop
9:	mov.l	w_bn,r1			! V4n27b: BEAT NUMBERS / GRID ADJUST
	cmp/eq	r1,r0
	bf	12f
	mov.l	w_bnv,r1
	rts
	nop
12:	mov.l	w_ga,r1
	cmp/eq	r1,r0
	bf	14f
	mov.l	w_gav,r1
	rts
	nop
14:	mov.l	w_kf,r1			! V4n36: KEY FORMAT
	cmp/eq	r1,r0
	bf	13f
	mov.l	w_kfv,r1
	rts
	nop
13:
	.ifdef	TESTLOG
	mov.l	w_tl,r1
	cmp/eq	r1,r0
	bf	10f
	mov.l	w_tlv,r1
	rts
	nop
10:
	.endif
	.endif
	mov.l	w_modsv,r1
	rts
	nop
	.p2align 2
	.ifdef	KEYSHIFT
w_ks:	.long	L_KS
w_ksv:	.long	KSB + 20		! mods/keyshift ks_onv
w_rbb:	.long	L_RBB
w_rbbv:	.long	KSB			! mods/keyshift ks_rbm
w_ksyb:	.long	L_KSYB
w_ksybv: .long	KSB + 72		! mods/keyshift ksy_btn (V4n24 KEY SYNC BUTTON)
w_bn:	.long	L_BN			! V4n27b
w_bnv:	.long	bn_v
w_ga:	.long	L_GA
w_gav:	.long	ga_v
w_kf:	.long	L_KF			! V4n36
w_kfv:	.long	kf_v
	.ifdef	TESTLOG
w_tl:	.long	L_TL
w_tlv:	.long	KSB + 68		! mods/keyshift tl_v
	.endif
	.endif
w_light: .long	L_LIGHT
w_lightv: .long	light_v
w_bpmd:	.long	L_BPMD
w_bpmdv: .long	bpmd_v
w_wave:	.long	L_WAVE
w_wavev: .long	wave_v
w_pos:	.long	L_POS
w_posv:	.long	pos_v
w_lc:	.long	L_LC
w_lcv:	.long	lc_off
w_w32:	.long	L_W32
w_w32v:	.long	w32_off
w_diag:	.long	L_DIAG
w_diagv: .long	diag_off
w_modsv: .long	mods_off
w_klm:	.long	kl_map			! V4n36 trace

! slot 1: label + value text. The stock PLAY MODE formatter (0x084EE88A)
! shows opts[+16] while editing and otherwise asks its own getter; show our
! value by presenting it as +16 for the call.
it_fmt:
	mov.l	@(16,r4),r0
	cmp/eq	#-1,r0
	bf	1f			! editing: the stock formatter shows +16
	sts.l	pr,@-r15
	bsr	wordof
	nop
	mov.l	@r1,r0			! the word is the option index
	mov.l	r0,@(12,r4)
	mov.l	r0,@(16,r4)
	mov.l	r4,@-r15
	mov.l	f_fmt,r1
	jsr	@r1
	nop
	mov.l	@r15+,r4
	lds.l	@r15+,pr
	mov	#-1,r1
	rts
	mov.l	r1,@(16,r4)		! not editing again (r0 = the stock's 0)
1:	mov.l	f_fmt,r1
	jmp	@r1
	nop
	.p2align 2
f_fmt:	.long	0x084EE88A

! slot 5: commit the pending value; 1 makes the engine save the settings.
it_commit:
	mov.l	@(16,r4),r5
	mov.w	@(8,r4),r0
	extu.w	r5,r6
	extu.w	r0,r2
	cmp/ge	r2,r6
	bt	0f
	mov.l	@(12,r4),r2
	cmp/eq	r2,r5
	bt	0f
	mov.l	r5,@(12,r4)
	sts.l	pr,@-r15
	bsr	wordof
	nop
	mov.l	r5,@r1			! the word = the option index
	mov	r1,r7
	bsr	mm_publish		! LIGHT MODE / BPM DECIMALS to the display now
	nop
	mov	r7,r1
	.ifdef	KEYSHIFT
	mov.l	c_ksy,r0		! V4k: KEY SHIFT ON / OFF -> the engine
	jsr	@r0
	nop
	mov	r7,r1
	mov.l	c_klc,r0		! V4n36 trace: a kill switch / TEST LOG changed (kl_commit; keeps r5, r7)
	jsr	@r0
	nop
	mov	r7,r1
	.endif
	mov.l	c_mods,r2		! MODS turned OFF: every other mod too
	cmp/eq	r2,r1
	bf	1f
	tst	r5,r5
	bf	1f
	bsr	force_all
	nop
1:	lds.l	@r15+,pr
	rts
	mov	#1,r0			! 1 -> the engine saves (theirs and ours)
0:	rts
	mov	#0,r0
	.p2align 2
c_mods:	.long	mods_off
	.ifdef	KEYSHIFT
c_ksy:	.long	ks_sync
c_klc:	.long	kl_commit
	.endif

! force_all: MODS OFF also sets every item that is neither stock (its label
! in P2 0xA0000000+, the stock tables' own) nor ours to its option 0 (the
! stock-like choice) through the item's own commit (slot 5) and cancel
! (slot 8), as if picked by hand. Keeps r8-r14.
force_all:
	sts.l	pr,@-r15
	sts.l	macl,@-r15
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	fa_tlit,r1
	mov.l	@r1,r8			! the item table the engine uses
	mov.l	fa_cnt,r1
	mov.l	@r1,r9			! its item count
	mov	#0,r10
1:	cmp/hs	r9,r10
	bt	9f
	mov	#60,r0
	mul.l	r0,r10
	sts	macl,r4
	add	r8,r4			! r4 = item i
	mov.l	@r4,r0			! its label: stock (P2) or one of ours?
	mov.l	fa_p2,r1
	cmp/hs	r1,r0
	bt	3f
	mov.l	fa_lo,r1
	cmp/hs	r1,r0
	bf	2f
	mov.l	fa_hi,r1
	cmp/hs	r1,r0
	bf	3f			! ours: leave it
2:	mov.l	fa_skipl,r1		! a label to leave alone (fa_skip,
	mov.l	@r1,r1			! 0 = none)
	cmp/eq	r1,r0
	bt	3f
	mov.l	@(12,r4),r0
	tst	r0,r0
	bt	3f			! already option 0
	mov	#0,r0
	mov.l	r0,@(16,r4)
	mov.l	r4,@-r15
	mov.l	@(44,r4),r1
	jsr	@r1			! commit
	nop
	mov.l	@r15,r4
	mov.l	@(56,r4),r1
	jsr	@r1			! cancel: not editing
	nop
	mov.l	@r15+,r4
3:	bra	1b
	add	#1,r10
9:	mov.l	@r15+,r10
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	lds.l	@r15+,macl
	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
fa_tlit: .long	0x084F08C8		! a literal of the engine's table pointer
fa_cnt:	.long	0x10DE1B98		! the item count (RAM)
fa_p2:	.long	0xA0000000
fa_lo:	.long	entries
fa_hi:	.long	block_end
fa_skipl: .long	fa_skip
	.global	fa_skip
fa_skip: .long	0			! label of an item MODS OFF leaves alone
					! (0 = none)


! ---------------------------------------------------------------------------------------------------------------
! R21 (2.01-b, work/r21/SETTINGS_DONE): VERSIONED SETTINGS. Before, our fields were bits scattered over stock
! "free" bits and the HISTORY tail, decoded blindly from whatever record the unpacker got (a MY SETTINGS import,
! a record of another build). Now every load goes through one decision tree (st_load) into one settings word W,
! every field is clamped against a table on load AND save (st_desc, the lang8 clampt model: an unknown value
! becomes the field's default, never garbage), and the HISTORY tail carries a versioned block.
!
! W (16 bits): 0-1 LIGHT MODE (0..2), 2 BPM DECIMALS, 3-4 WAVEFORM COLOR (0..2), 5 WAVEFORM CURRENT POSITION,
!   6-7 PHASE METER style (0..2) | 8-10 BEAT JUMP index (0..6), 11 KEY SHIFT, 12 KEY FORMAT (1 = ALPHANUMERIC,
!   kf_v), 13 KEY SYNC BUTTON, 14 WAVEFORM HALF (wh_v), 15 reserved 0. Defaults: ST_WDEF (all 0, kf_v 1).
!
! Carriers (N = the 32-byte HISTORY-name record = unpacker record + 8, L = the name's length):
!   main record (type 2, always): byte 6 bit 4 pos, bits 5-6 PHASE style + 1 (1..3: these bits are also the stock
!     loader's record version, >= 2 accepted, 0/1 migrated -- 0x08350EDC/0x08350F18), byte 7 bit 4/6 LIGHT lo/hi,
!     bit 5 BPM DECIMALS, bit 7 WAVEFORM COLOR bit 0. Byte 6 bit 0 is ALWAYS written 0 (the stock loader's
!     "invalid record" flag, 0x08350E88: a full factory reset at the next boot). Byte 5 bit 5 MODS OFF.
!   L <= 30: N[31] = the legacy byte 0x80 | BEAT JUMP | COLOR bit 1 << 3 | KEY SHIFT << 4 | CLASSIC << 5 |
!     KEY SYNC << 6 (what 1.92 / 2.0 read: a downgrade keeps them).
!   L <= 29: N[30] = WAVEFORM HALF << 2, bit 7 CLEAR. Stock's type-3 message builder (0x0835333C) widens the record
!     bytes with mov.b (sign extension): an EVEN byte >= 0x80 turns the next byte into 0xFF in flash. 1.92 / 2.0
!     wrote N[30] = 0x80 | HALF << 2 -> their N[31] reads back 0xFF after every power cycle (KEY SHIFT, KEY SYNC,
!     CLASSIC and COLOR bit 1 all forced on). Rule since R21: every even byte of N we write is < 0x80.
!   L <= 24: the v1 block N[25] = ST_MAGIC, N[26] = ST_VER, N[27] = W & 0xFF, N[28] = W >> 8 (< 0x80, even),
!     N[29] = (0x5A + N[25] + N[26] + N[27] + N[28]) & 0xFF. The stock loader / unpacker / HISTORY export stop at
!     the name's NUL; stock's own save clears the 32 bytes (memset) and drops our block.
! Load (st_load, src word st_src for the benches):
!   1 = v1 block (magic + version 1 + checksum)          -> W from the block
!   0xFF magic present but unknown version / bad checksum -> defaults (a newer or damaged record: never applied)
!   0 = legacy tail (N[31] bit 7, zero padding between the NUL and N[30], N[30] in {0, 4, 0x80, 0x84}): the 1.92 /
!       2.0 layout (v0) and ours for names of 25..30 -> main-record fields + N[31] (0xFF = the sign-extension
!       artefact above: BEAT JUMP / COLOR bit 1 / KEY fields default) + HALF from N[30] bit 2
!   2 = no tail at all (stock-written record, factory reset, a name of 31-32) -> main-record fields, rest default
!   0xFE anything else after the NUL (a foreign record) -> defaults
!   2.1.1: v2 (L <= 23) carries one more byte, N[24] = LINK CUE (0..3), in the checksum; a v1 block (2.0 / 2.1,
!   or a name of exactly 24) has no such byte and loads as BOTH, like every other path.
	.equ	ST_MAGIC, 0xC1
	.equ	ST_VER, 1
	.equ	ST_VER2, 2		! 2.1.1: v1 + N[24] LINK CUE
	.equ	ST_CHKM, (0x5A + ST_MAGIC) & 0xFF	! the checksum's constant part without the version
	.equ	ST_WDEF, 0x1000
	.equ	ST_CHK0, (0x5A + ST_MAGIC + ST_VER) & 0x7F	! 0x1C, the checksum's constant part

! The record unpacker hands the QUANTIZE field (3 bits) to its setter in r4.
mods_load:
	sts.l	pr,@-r15
	mov.l	r4,@-r15
	bsr	st_load			! r0 = W from the record r14 (validated, versioned)
	nop
	.ifdef	NOTONE			! Cueline 2.2: a saved KEY SHIFT ON (W bit 11) / KEY SYNC BUTTON ON (bit 13) is
	mov	#0x28,r1		! dropped -- neither has a UTILITY row here, so nothing could switch it off
	shll8	r1			! again; with the engine's on word 0 the DSP path is its exact bypass
	not	r1,r1
	and	r1,r0
	.endif
	mov	r0,r4
	bsr	st_put			! every field clamped into its word
	nop
	.ifdef	KEYSHIFT
	mov.l	l_ksb,r1
	mov	#0,r0			! V4n23 (user): REKORDBOX BUTTON removed -- the rekordbox key is stock,
	mov.l	r0,@r1			!   a saved ON is ignored (row hidden in UTILITY)
	mov.l	@(20,r1),r0		! KEY SHIFT -> the engine's on word
	mov.l	l_kse,r3
	mov.l	r0,@r3
	.endif
	bsr	mm_publish
	nop
	.ifdef	KEYSHIFT
	mov.l	l_klr,r0		! V4n36 trace: the kill switches shown / hidden (TEST LOG)
	jsr	@r0
	nop
	.endif
	mov.l	@r15+,r4
	lds.l	@r15+,pr
	mov	r4,r0
	shlr2	r0
	and	#1,r0
	xor	#1,r0			! bit 1 = OFF -> MODS index 0
	mov.l	l_var,r1
	mov.l	r0,@r1
	mov	#3,r2
	mov.l	l_qset,r1
	jmp	@r1
	and	r2,r4
	.p2align 2
l_var:	.long	mods_off
l_qset:	.long	0x083FC4DC
	.ifdef	KEYSHIFT
l_ksb:	.long	KSB
l_kse:	.long	0x08122800
l_klr:	.long	kl_reveal
	.endif

! The record packer, after byte 5: our bits into bytes 5-7 (from the clamped W), then the stock getter.
! r4-r7 kept for the getter (the old code used r0-r2 only).
mods_save:
	sts.l	pr,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	bsr	st_get
	nop
	mov	r0,r4			! W, clamped
	mov.l	s_var,r1
	mov.l	@r1,r1
	mov.b	@(5,r12),r0
	and	#0xDF,r0
	tst	r1,r1			! MODS index 0 (OFF) -> bit 1
	bf	1f
	or	#0x20,r0
1:	mov.b	r0,@(5,r12)
	mov	r4,r0			! byte 7: bit 4 LIGHT lo, 5 BPM DECIMALS, 6 LIGHT hi, 7 COLOR bit 0
	and	#1,r0
	shll2	r0
	shll2	r0
	mov	r0,r2
	mov	r4,r0
	and	#4,r0
	shll2	r0
	shll	r0
	or	r0,r2
	mov	r4,r0
	and	#2,r0
	shll2	r0
	shll2	r0
	shll	r0
	or	r0,r2
	mov	r4,r0
	and	#8,r0
	shll2	r0
	shll2	r0
	or	r0,r2
	mov.b	@(7,r12),r0
	and	#0x0F,r0
	or	r2,r0
	mov.b	r0,@(7,r12)
	mov	r4,r0			! byte 6: bit 4 POSITION, bits 5-6 PHASE style + 1 (1..3 = the stock version
	and	#0x20,r0		!   2..7, accepted as is), bit 0 cleared: never the invalid-record flag
	shlr	r0
	mov	r0,r2
	mov	r4,r0
	shlr2	r0
	shlr2	r0
	shlr2	r0
	and	#3,r0			! <= 2 (st_get clamps)
	add	#1,r0
	shll2	r0
	shll2	r0
	shll	r0
	or	r0,r2
	mov.b	@(6,r12),r0
	and	#0x8E,r0		! stock bits 1-3 and 7 kept
	or	r2,r0
	mov.b	r0,@(6,r12)
	mov.l	@r15+,r7
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	lds.l	@r15+,pr
	mov.l	s_get,r1
	jmp	@r1
	nop
	.p2align 2
s_var:	.long	mods_off
s_get:	.long	0x08401B60

! V3rc2 (work/v3rc2/re_settings): the HISTORY-name record (type 3, saved with the settings by the same packer):
! its 32 bytes (record + 8) are cleared by memset (literal 0x0846D5D4 -> hist_save), then the name 0x0A35F698 is
! copied up to its NUL. R21: the legacy byte N[31], HALF in N[30] and the v1 block N[25..29], by the name's length
! (layout above). A pure function of the settings: Backup_TASK appends a record only when the 32 bytes change.
	.global	hist_save
hist_save:				! r4 = record + 8, r5 = 0, r6 = 32 (memset's), r12 = the record
	sts.l	pr,@-r15
	mov.l	r4,@-r15
	mov.l	hs_mset,r0
	jsr	@r0
	nop
	mov.l	@r15,r4			! (memset's r4 is not kept)
	mov.l	hs_name,r1		! L = the name's length (32: no NUL)
	mov	#0,r6
	mov	#32,r3
1:	mov.b	@r1+,r0
	tst	r0,r0
	bt	2f
	add	#1,r6
	cmp/eq	r3,r6
	bf	1b
2:	mov	#30,r0
	cmp/hi	r0,r6
	bt	9f			! 31+: no room (main record only)
	bsr	st_get			! keeps r4, r6
	nop
	mov	r0,r7			! W
	shlr8	r0			! N[31] = 0x80 | BEAT JUMP | COLOR bit 1 << 3 | KS << 4 | CLASSIC << 5 | KSYNC << 6
	and	#7,r0
	mov	r0,r2
	mov	r7,r0
	and	#0x10,r0
	shlr	r0
	or	r0,r2
	mov	r7,r0
	shlr2	r0
	shlr2	r0
	shlr2	r0
	shlr	r0
	and	#0x70,r0
	xor	#0x20,r0		! kf_v 1 = ALPHANUMERIC = CLASSIC bit clear
	or	r2,r0
	or	#0x80,r0
	mov	r4,r1
	add	#31,r1
	mov.b	r0,@r1
	mov	#29,r0
	cmp/hi	r0,r6
	bt	9f
	mov	r7,r0			! N[30] = HALF << 2 -- bit 7 clear (even byte, see above)
	shlr8	r0
	shlr2	r0
	shlr2	r0
	and	#4,r0
	mov	r4,r1
	add	#30,r1
	mov.b	r0,@r1
	mov	#24,r0
	cmp/hi	r0,r6
	bt	9f
	mov	#ST_VER,r5		! 2.1.1: v1, or v2 + N[24] LINK CUE when the name leaves room (L <= 23)
	mov	#23,r0
	cmp/hi	r0,r6
	bt	1f
	mov	#ST_VER2,r5
	mov.l	hs_lc,r1
	mov.l	@r1,r0
	mov	#3,r2
	cmp/hi	r2,r0			! out of range -> BOTH
	bf	2f
	mov	r2,r0
2:	mov	r4,r1
	add	#24,r1
	mov.b	r0,@r1			! N[24] (even byte: 0..3 < 0x80)
1:	mov	r4,r1			! the block N[25..29]
	add	#25,r1
	mov	#ST_MAGIC-256,r0
	mov.b	r0,@r1
	mov	r5,r0
	mov.b	r0,@(1,r1)		! the version written above
	mov	r7,r0
	mov.b	r0,@(2,r1)		! F0 (odd byte: any value)
	extu.b	r0,r3
	shlr8	r0
	and	#0x7F,r0
	mov.b	r0,@(3,r1)		! F1 (even byte: < 0x80)
	add	r0,r3
	add	r5,r3			! + the version
	add	#ST_CHKM,r3
	mov	#ST_VER2,r0
	cmp/eq	r0,r5
	bf	3f
	mov	r4,r0
	add	#24,r0
	mov.b	@r0,r0			! + N[24]
	extu.b	r0,r0
	add	r0,r3
3:	mov	r3,r0
	mov.b	r0,@(4,r1)
9:	mov.l	@r15+,r4
	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
hs_mset: .long	0x08533D50
hs_name: .long	0x0A35F698
hs_lc:	.long	lc_off			! 2.1.1: LINK CUE (0..3), saved in N[24]

! st_get -> r0 = W from the live words, every field clamped (out of range -> its default). Uses r0-r3, r5.
st_get:
	mov.l	g_desc,r5
	mov	#0,r3
1:	mov.l	@r5+,r1			! the word (0 = end)
	tst	r1,r1
	bt	3f
	mov.l	@r1,r1
	mov.b	@r5+,r2			! shift
	add	#1,r5			! (mask: max <= mask)
	mov.b	@r5+,r0			! max
	cmp/hi	r0,r1			! unsigned: a negative word is out of range too
	mov.b	@r5+,r0			! default
	bf	2f
	mov	r0,r1
2:	shld	r2,r1
	bra	1b
	or	r1,r3
3:	rts
	mov	r3,r0

! st_put: r4 = W -> every field into its word, clamped (out of range -> its default). Uses r0-r3, r5.
st_put:
	mov.l	g_desc,r5
1:	mov.l	@r5+,r1
	tst	r1,r1
	bt	3f
	mov.b	@r5+,r2
	neg	r2,r2
	mov	r4,r0
	shld	r2,r0
	mov.b	@r5+,r2
	and	r2,r0			! mask
	mov.b	@r5+,r2
	cmp/hi	r2,r0			! > max
	mov.b	@r5+,r2
	bf	2f
	mov	r2,r0
2:	bra	1b
	mov.l	r0,@r1
3:	rts
	nop

! st_main: r14 = the record -> r0 = W's main-record fields (LIGHT, BPM DECIMALS, COLOR bit 0, POSITION, PHASE
! style; the rest 0). Uses r0-r2.
st_main:
	mov.b	@(7,r14),r0
	extu.b	r0,r1
	shlr2	r1
	shlr2	r1			! b7 >> 4: bit 0 LIGHT lo, 1 BPM DECIMALS, 2 LIGHT hi, 3 COLOR bit 0
	mov	r1,r0
	and	#9,r0			! LIGHT lo -> W 0, COLOR bit 0 -> W 3
	mov	r0,r2
	mov	r1,r0
	and	#4,r0
	shlr	r0			! LIGHT hi -> W 1
	or	r0,r2
	mov	r1,r0
	and	#2,r0
	shll	r0			! BPM DECIMALS -> W 2
	or	r0,r2
	mov.b	@(6,r14),r0
	extu.b	r0,r1
	mov	r1,r0
	and	#0x10,r0
	shll	r0			! POSITION -> W 5
	or	r0,r2
	mov	r1,r0
	shlr2	r0
	shlr2	r0
	shlr	r0
	and	#3,r0			! PHASE style + 1 (0 = a stock version-0 record: PHASE)
	tst	r0,r0
	bt	1f
	add	#-1,r0
1:	shll2	r0
	shll2	r0
	shll2	r0			! -> W 6-7
	rts
	or	r2,r0

! st_load: r14 = the unpacked record -> r0 = W (decision tree above), st_src = the path taken. Uses r0-r7.
st_load:
	sts.l	pr,@-r15
	mov	#3,r0			! 2.1.1: LINK CUE = BOTH on every path but a valid v2 block (old record,
	mov.l	g_lc,r1			!   stock record, foreign record, damaged block: exactly 2.1's behaviour)
	mov.l	r0,@r1
	mov	r14,r5
	add	#8,r5			! N
	mov	r5,r1
	mov	#0,r6			! L
	mov	#32,r3
1:	mov.b	@r1+,r0
	tst	r0,r0
	bt	2f
	add	#1,r6
	cmp/eq	r3,r6
	bf	1b
2:	mov	#24,r0
	cmp/hi	r0,r6
	bt	st_leg			! L > 24: no v1 block
	mov	r5,r1
	add	#25,r1
	mov.b	@r1,r0
	cmp/eq	#ST_MAGIC-256,r0	! (mov.b sign-extends)
	bf	st_leg
	mov.b	@(1,r1),r0
	extu.b	r0,r4			! the version: 1, or 2.1.1's v2 (+ N[24] LINK CUE)
	mov	#ST_VER,r0
	cmp/eq	r0,r4
	bt	1f
	mov	#ST_VER2,r0
	cmp/eq	r0,r4
	bf	st_bad			! a version this build does not know: defaults
1:	mov.b	@(2,r1),r0
	extu.b	r0,r2			! F0
	mov.b	@(3,r1),r0
	extu.b	r0,r3			! F1
	mov	r2,r0
	add	r3,r0
	add	r4,r0			! + the version
	add	#ST_CHKM,r0
	mov	r0,r6			! (L is done: the running checksum)
	mov	#ST_VER2,r0
	cmp/eq	r0,r4
	bf	2f
	mov	r1,r0
	add	#-1,r0
	mov.b	@r0,r0			! + N[24]
	extu.b	r0,r0
	add	r0,r6
2:	mov.b	@(4,r1),r0
	extu.b	r0,r7			! checksum
	mov	r6,r0
	extu.b	r0,r0
	cmp/eq	r7,r0
	bf	st_bad
	mov	#ST_VER2,r0
	cmp/eq	r0,r4
	bf	4f
	mov	r1,r0			! the block is sound: LINK CUE from N[24], clamped (else BOTH)
	add	#-1,r0
	mov.b	@r0,r0
	extu.b	r0,r0
	mov	#3,r4
	cmp/hi	r4,r0
	bf	3f
	mov	r4,r0
3:	mov.l	g_lc,r1
	mov.l	r0,@r1
4:	shll8	r3
	or	r3,r2
	bra	st_out
	mov	#1,r7
st_leg:	mov	#30,r0			! legacy tail?
	cmp/hi	r0,r6
	bt	st_none			! L 31 / 32: no tail
	mov	r5,r1
	add	r6,r1
	add	#1,r1			! N + L + 1
	mov	#29,r3
	sub	r6,r3			! the padding N[L+1..29] must be zero
1:	cmp/pl	r3
	bf	2f
	mov.b	@r1+,r0
	tst	r0,r0
	bf	st_forn
	bra	1b
	add	#-1,r3
2:	mov	#29,r0			! B = N[30] when L <= 29 (r6 from here on; L is done)
	cmp/hi	r0,r6
	mov	#0,r6
	bt	3f
	mov	r5,r1
	add	#30,r1
	mov.b	@r1,r0
	extu.b	r0,r6
3:	mov	r5,r1
	add	#31,r1
	mov.b	@r1,r0
	extu.b	r0,r3			! A = N[31]
	tst	#0x80,r0
	bf	4f
	or	r6,r0			! no legacy marker: all zero = no tail, else foreign
	tst	r0,r0
	bt	st_none
	bra	st_forn
	nop
4:	mov	r6,r0
	tst	#0x7B,r0		! B in {0, 4, 0x80, 0x84}
	bf	st_forn
	bsr	st_main
	nop
	mov	r0,r7			! W so far
	mov	r6,r0			! HALF -> W 14
	and	#4,r0
	shll8	r0
	shll2	r0
	shll2	r0
	or	r0,r7
	mov	#-1,r1
	extu.b	r1,r1
	cmp/eq	r1,r3
	bt	5f			! 0xFF = the 1.92 / 2.0 sign-extension artefact: its fields default
	mov	r3,r0
	and	#7,r0			! BEAT JUMP -> W 8-10
	shll8	r0
	or	r0,r7
	mov	r3,r0
	and	#8,r0
	shll	r0			! COLOR bit 1 -> W 4
	or	r0,r7
	mov	r3,r0
	and	#0x70,r0
	xor	#0x20,r0		! KS, CLASSIC -> ALPHANUMERIC, KSYNC -> W 11-13
	shll8	r0
	shlr	r0
	bra	6f
	or	r0,r7
5:	mov.w	g_wdef,r0
	or	r0,r7
6:	mov	r7,r2
	bra	st_out
	mov	#0,r7
st_none: bsr	st_main			! main-record fields, the rest default
	nop
	mov.w	g_wdef,r2
	or	r0,r2
	bra	st_out
	mov	#2,r7
st_bad:	mov.w	g_wdef,r2
	bra	st_out
	mov	#-1,r7
st_forn: mov.w	g_wdef,r2
	mov	#-2,r7
st_out:	mov.l	g_src,r1
	extu.b	r7,r7
	mov.l	r7,@r1
	mov	r2,r0
	lds.l	@r15+,pr
	rts
	nop
g_wdef:	.short	ST_WDEF
	.p2align 2
g_desc:	.long	st_desc
g_lc:	.long	lc_off			! 2.1.1: LINK CUE (0..3), N[24] of a v2 block
g_src:	.long	st_src
	.global	st_src
st_src:	.long	0x55			! the last load's path (1 v1, 0 legacy, 2 main only, 0xFF bad v1, 0xFE foreign)
! st_desc: the saved fields -- word, W shift, mask, max, default (an out-of-range value -> default, both ways)
st_desc:
	.long	light_v
	.byte	0, 3, 2, 0
	.long	bpmd_v
	.byte	2, 1, 1, 0
	.long	wave_v
	.byte	3, 3, 2, 0
	.long	pos_v
	.byte	5, 1, 1, 0
	.long	pm_c
	.byte	6, 3, 2, 0
	.ifdef	V3E2
	.long	bj_v
	.byte	8, 7, 6, 0
	.endif
	.ifdef	KEYSHIFT
	.long	KSB + 20
	.byte	11, 1, 1, 0
	.long	kf_v
	.byte	12, 1, 1, 1
	.long	KSB + 72
	.byte	13, 1, 1, 0
	.endif
	.long	wh_v
	.byte	14, 1, 1, 0
	.long	0

! mm_publish: the display has no view of MAIN's item words, but the heartbeat
! (type 0x03) is a copy of the 508-byte block at 0x0B568C9C made every frame
! (0x083906F2). Its word +0x54 is unused (always 0 in every capture): it carries
! 0x4C47 ("LG") in the top half and our flags in the low byte -- bit 0 LIGHT
! MODE, bit 1 BPM DECIMALS. The display honours it only with the magic. Called
! at load, on every commit and every 2 s by the TchAud task (the block may be
! re-initialised). Uses r0-r2 (r3-r5 saved).
! V3d: the top byte is the magic 0x4C ('L'); bits 6-23 carry the LINK master's
! status (another deck is master) from MAIN's status table 0x0A371D3C (stride
! 0x124 by player number; fields little-endian), in two slots that alternate
! every 4th publish (bit 6 = slot):
!   slot 0: bits 7-15 the master's cue countdown in beats (0x1FF none), bits
!           16-23 its beat number, low byte;
!   slot 1: bits 7-15 flags (bit 7 valid, bit 8 playing, bit 9 its track is
!           THIS deck's track: same source player, slot and rekordbox id),
!           bits 16-23 (beat number + 128) >> 8 (the display rebuilds the beat
!           number from both slots without a wrap error).
mm_publish:
	mov.l	p_tx,r1			! V3e1: pen up (calibrated touch x = 0) re-arms the meter tap
	mov.l	@r1,r0			! (a zone handler is called on every touch event while the
	tst	r0,r0			! finger stays down; pm_tap counts the first one only)
	bf	0f
	mov.l	p_held,r1
	mov.l	r0,@r1
0:	mov.l	p_light,r1		! bit 0 LIGHT MODE on (LIGHT or FULL), bit 2 FULL
	mov.l	@r1,r0
	mov	#0,r2
	tst	r0,r0
	bt	1f
	mov	#1,r2
	cmp/eq	#2,r0
	bf	1f
	mov	#5,r2
1:
	mov.l	p_bpmd,r1
	mov.l	@r1,r0
	and	#1,r0
	shll	r0
	or	r0,r2
	mov.l	p_wave,r1		! bits 3-4 WAVEFORM COLOR (0 3BAND, 1 RGB, 2 BLUE)
	mov.l	@r1,r0
	and	#3,r0
	shll2	r0
	shll	r0
	or	r0,r2
	mov.l	p_pos,r1		! bit 5 WAVEFORM CURRENT POSITION (0 CENTER, 1 LEFT)
	mov.l	@r1,r0
	and	#1,r0
	shll2	r0
	shll2	r0
	shll	r0
	or	r0,r2
	mov.l	r3,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	p_tog,r1		! the slot: bit 2 of a publish counter
	mov.l	@r1,r0
	add	#1,r0
	mov.l	r0,@r1
	shlr2	r0
	and	#1,r0
	mov	r0,r5			! r5 = slot
	shll2	r0
	shll2	r0
	shll2	r0
	or	r0,r2			! bit 6
	tst	r5,r5			! V3e1: slot 1 bits 10-11 = the PHASE METER style
	bt	9f
	mov.l	p_pmc,r1
	mov.l	@r1,r0
	and	#3,r0
	shll8	r0
	shll2	r0
	or	r0,r2
9:	mov	#0,r4			! payload (bits 7-23): none
	mov.l	p_blk,r1
	mov.w	p_oa4,r0
	mov.l	@(r0,r1),r3		! +0xA4: the master's player number (another deck), else 0
	add	#-1,r3
	mov	#6,r0
	cmp/hs	r0,r3			! (n - 1) >= 6 unsigned: no master record
	bt	8f
	add	#1,r3
	mov.w	p_stride,r0
	mulu.w	r0,r3
	mov.l	p_tab,r3
	sts	macl,r0
	add	r0,r3			! r3 = the master's status record
	tst	r5,r5
	bf	2f
	mov.w	p_oa4,r0		! slot 0: countdown, beat number low byte
	mov.w	@(r0,r3),r4
	extu.w	r4,r4
	mov.w	p_1ff,r0
	cmp/hi	r0,r4
	bf	1f
	mov	r0,r4
1:	shll2	r4
	shll2	r4
	shll2	r4
	shll	r4			! << 7
	mov.w	p_oa0,r0
	mov.l	@(r0,r3),r0
	extu.b	r0,r0
	shll16	r0
	bra	8f
	or	r0,r4
2:	mov.w	p_oa0,r0		! slot 1: flags, (beat number + 128) >> 8
	mov.l	@(r0,r3),r4
	add	#127,r4
	add	#1,r4
	shlr8	r4
	extu.b	r4,r4
	shll16	r4
	mov	r4,r0
	or	#0x80,r0		! bit 7 valid
	mov	r0,r4
	mov.w	p_o88,r0
	mov.l	@(r0,r3),r0		! +0x89 the master's flags (0x40 playing)
	shlr8	r0
	tst	#0x40,r0
	bt	3f
	mov.w	p_b8,r0
	or	r0,r4			! bit 8 playing
3:	own_rec	r1, r5			! F1 (ownstat.inc): OUR record, r5 != 0 = the table's (id native).
	tst	r5,r5			! The fixed slot is the LAST status seen: with a second deck on the
	mov	#0x2C,r0		! LINK it is ITS status, so the master was compared against itself
	mov.l	@(r0,r1),r5		! and bit 9 ("same track") was set for every track; the GUI then
	bt	6f			! drew OUR buffers in the master's strip (v2.c master_mini).
	swap.b	r5,r5			! our id in the form the master's reversed copy below is compared
	swap.w	r5,r5			! in: the slot's is already big-endian, the table's is native
	swap.b	r5,r5
6:	mov	#0x28,r0		! +0x28 player | slot << 8 (the medium)
	mov.w	@(r0,r1),r1
	mov.w	@(r0,r3),r0
	cmp/eq	r0,r1
	bf	8f
	mov	#0x2C,r0
	mov.l	@(r0,r3),r0		! the table's id is little-endian: byte-reverse it
	swap.b	r0,r0
	swap.w	r0,r0
	swap.b	r0,r0
	cmp/eq	r0,r5
	bf	8f
	mov.w	p_b9,r0
	or	r0,r4			! bit 9 same track
8:	or	r4,r2
	mov.l	p_magic,r0
	or	r2,r0
	mov.l	p_word,r1
	mov.l	r0,@r1
	.ifdef	V3E2
	sts.l	pr,@-r15
	mov.l	p_vp1,r0		! V3e2: heartbeat +0xE8 (V4n31a: past bsr's reach)
	jsr	@r0
	nop
	mov.l	p_vp2,r0		! V3e3: heartbeat +0x14 (V4k/V4n: past bsr's reach)
	jsr	@r0
	nop
	mov.l	p_vsl,r0		! V4n32 (#21): heartbeat +0x18 = the slip (shadow) position
	jsr	@r0
	nop
	lds.l	@r15+,pr
	.endif
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	rts
	mov.l	@r15+,r3
	.p2align 1
p_oa4:	.short	0xA4
p_oa0:	.short	0xA0
p_o88:	.short	0x88
p_stride: .short 0x124
p_1ff:	.short	0x1FF
p_b8:	.short	0x100
p_b9:	.short	0x200
	.p2align 2
p_light: .long	light_v
p_bpmd:	.long	bpmd_v
p_wave:	.long	wave_v
p_pos:	.long	pos_v
p_magic: .long	0x4C000000
p_word:	.long	0x0B568C9C + 0x54
p_blk:	.long	0x0B568C9C
p_tab:	.long	LINK_TAB
p_tog:	.long	mm_tog
p_pmc:	.long	pm_c
p_tx:	.long	0x0B06C774
p_held:	.long	pm_held
p_vp2:	.long	v3e_pub2
p_vp1:	.long	v3e_pub
p_vsl:	.long	sl_pub
mm_tog:	.long	0

! mm_copy: the heartbeat's copy call (memcpy 0x085336DC through the literals
! 0x08390944 / 0x08391B60, redirected here). The 508-byte block is rebuilt by
! the deck between frames (word +0x54 back to 0), so the flags go in right
! before each copy of it; any other copy passes through untouched. r4-r7 are
! the copy's own, r0-r2 scratch.
mm_copy:
	mov.l	c_blk,r1
	cmp/eq	r1,r5
	bf	1f
	sts.l	pr,@-r15
	bsr	mm_publish
	nop
	lds.l	@r15+,pr
	.ifdef	LINK0B			! LINK0B (v4.2, mods/link0b link0btx): the master's 0x0b position, staged at
	mov.l	c_l0b,r1		! normal boot only (main-update-safety)
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	1f
	mov.l	c_l0s,r1		! L0B + 0x30 (W1, W2, W3) -> heartbeat +0x104 / +0x108 / +0x10C (the GUI checks
	mov.l	@(0x18,r1),r0		! W3's top byte against W1 ^ W2: a torn set is dropped there), once link0btx
	mov.l	c_l0m,r2		! has cleared its block ('L0B1')
	cmp/eq	r2,r0
	bf	1f
	mov.w	c_104,r2
	add	r5,r2
	mov.l	@(0x30,r1),r0
	mov.l	r0,@r2
	mov.l	@(0x38,r1),r0
	mov.l	r0,@(8,r2)
	mov.l	@(0x34,r1),r0
	mov.l	r0,@(4,r2)
	.endif
1:	mov.l	c_memcpy,r0
	jmp	@r0
	nop
	.ifdef	LINK0B
c_104:	.short	0x104
	.endif
	.p2align 2
c_blk:	.long	0x0B568C9C
c_memcpy: .long	0x085336DC
	.ifdef	LINK0B
c_l0s:	.long	RAMB + 0x1E600
c_l0m:	.long	0x3142304C		! 'L0B1'
c_l0b:	.long	0x0A35DF3C		! MAIN boot words: 1 = normal boot
	.endif

! the second entry block (place_modsmenu appends these two after the first four)
entries2:
	.long	L_LIGHT, OPTS3, 3, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_BPMD, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_WAVE, OPTSW, 3, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_POS, OPTSP, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
light_v: .long	0			! LIGHT MODE (0 OFF, 1 LIGHT, 2 FULL), saved: byte 7 bits 4 (lo) + 6 (hi)
bpmd_v:	.long	0			! BPM DECIMALS (0 OFF, 1 ON), saved: byte 7 bit 5
wave_v:	.long	0			! WAVEFORM COLOR (0 3BAND, 1 RGB, 2 BLUE), saved: W bits 3-4 (byte 7 bit 7 + legacy N[31] bit 3)
pos_v:	.long	0			! WAVEFORM CURRENT POSITION (0 CENTER, 1 LEFT), saved: byte 6 bit 4
OPTSP:	.long	L_CTR, L_LEFT
L_CTR:	.short	'C', 'E', 'N', 'T', 'E', 'R', 0
L_LEFT:	.short	'L', 'E', 'F', 'T', 0
	.p2align 2
OPTSW:	.long	L_3B, L_RGB, L_BLUE
L_3B:	.short	'3', 'B', 'A', 'N', 'D', 0
L_RGB:	.short	'R', 'G', 'B', 0
L_BLUE:	.short	'B', 'L', 'U', 'E', 0
	.p2align 2
OPTS3:	.long	L_OFF, L_LT, L_FULL
L_LT:	.short	'L', 'I', 'G', 'H', 'T', 0
L_FULL:	.short	'F', 'U', 'L', 'L', 0
	.p2align 1
L_LIGHT: .short	'L', 'I', 'G', 'H', 'T', ' ', 'M', 'O', 'D', 'E', 0
L_BPMD:	.short	'B', 'P', 'M', ' ', 'D', 'E', 'C', 'I', 'M', 'A', 'L', 'S', 0
L_WAVE:	.short	'W', 'A', 'V', 'E', 'F', 'O', 'R', 'M', ' ', 'C', 'O', 'L', 'O', 'R', 0
L_POS:	.short	'W', 'A', 'V', 'E', 'F', 'O', 'R', 'M', ' ', 'C', 'U', 'R', 'R', 'E', 'N', 'T', ' '
	.short	'P', 'O', 'S', 'I', 'T', 'I', 'O', 'N', 0
	.p2align 2


! V3e1 (re/V3_PROGRESS.md): the phase meter cycles THREE styles on a tap, as the
! user asked -- PHASE (3000) -> WAVEFORM (3000) -> 4 BARS (the NXS2's classic
! boxes) -> PHASE. The stock PHASE METER TYPE has two values, toggled by the
! meter's touch zone 2 (handler 0x084EDBE6 = request 0x084E1578(0, 1)); the style
! is our own word pm_c (saved in settings byte 6 bits 5-6, published in heartbeat
! +0x54 slot 1 bits 10-11). Every tap also toggles the stock type, so the stock
! settings save runs after it (and saves pm_c with it); the display ignores the
! stock type. pm_tap = zone 2 (cycle); pm_s0/1/2 = the SHORT CUT tiles PHASE /
! WAVEFORM / 4 BARS (zones 53 / 54 / 66 by the v2ui MAIN pseudo-mod, which finds
! them behind the marker "PMCY"). Zone handlers: r0 out = 1, only r0-r2 used.
	.p2align 2
	.global	pm_tap, pm_s0, pm_s1, pm_s2, pm_c, present_v, sm_cycle
pm_mark: .long	0x504D4359		! "PMCY", then the four meter handlers + V3rc4 sm_cycle (5th)
	.long	pm_tap, pm_s0, pm_s1, pm_s2, sm_cycle
pm_c:	.long	0
! V3rc4 (re/V3_PROGRESS.md "V3rc4"): SCREEN MODE -- the display present strategy, cycled by the SHORT CUT
! tile (sm_cycle, v2needle pokes zone 68 here from the 5th PMCY handler). 0 SMOOTH (offscreen compose +
! whole-frame copy, the HW flicker fix, default), 1 FAST (frame-on-change per-region, V3f), 2 STEADY (FAST
! with the periodic forced-repaint spread off). Published in heartbeat +0x14 bits 0-1 (v3e_pub2). Live only:
! it is NOT persisted in the HISTORY tail (room under the fixed tadec blob at 0x08140000 was too tight for
! the persist code). Boots to SMOOTH (0) every time -- the fix the
! user should see first -- which is exactly the wanted default; the tile cycles it for an in-session A/B.
! Not under .ifdef V3E2 so sm_cycle links even in a bare build (where it just cycles an unpublished word).
present_v: .long 0
pm_held: .long	0			! 1 from a counted tap until the pen is up (mm_publish)
pm_tap:	mov.l	t_held,r1
	mov.l	@r1,r0
	tst	r0,r0
	bf	3f			! still the same press: no count
	mov	#1,r0
	mov.l	r0,@r1
	mov.l	t_pmc,r1
	mov.l	@r1,r0
	add	#1,r0
	cmp/eq	#3,r0
	bf	1f
	mov	#0,r0
1:	mov.l	r0,@r1
3:	mov.l	t_tog,r0
	jmp	@r0
	nop
pm_s0:	bra	2f
	mov	#0,r0
pm_s1:	bra	2f
	mov	#1,r0
pm_s2:	mov	#2,r0
2:	mov.l	t_pmc,r1
	mov.l	r0,@r1
	mov.l	t_tog,r0
	jmp	@r0
	nop
! V3rc4: the SCREEN MODE SHORT CUT tile -- cycle present_v 0 -> 1 -> 2 -> 0, then the stock toggle handler
! (0x084EDBE6, as the meter tiles) so the stock settings save runs and hist_save persists present_v.
! V3rc7 (re/TOUCH_AUDIT.md #5): stock calls a zone handler on EVERY panel frame while the pen is down --
! count once per press (pm_held, as pm_tap; mm_publish clears it at pen-up)
sm_cycle:
	mov.l	t_held,r1
	mov.l	@r1,r0
	tst	r0,r0
	bf	2f
	mov	#1,r0
	mov.l	r0,@r1
	mov.l	t_pv,r1
	mov.l	@r1,r0
	add	#1,r0
	cmp/eq	#3,r0
	bf	1f
	mov	#0,r0
1:	mov.l	r0,@r1
2:	mov.l	t_tog,r0
	jmp	@r0
	nop
	.p2align 2
t_pmc:	.long	pm_c
t_held:	.long	pm_held
t_pv:	.long	present_v
t_tog:	.long	0x084EDBE6		! stock zone 2 handler: toggle request, returns 1

	.ifdef	V3E2
! ---------------------------------------------------------------------------
! V3e2 (re/V3E_DESIGN.md §1.3): the CDJ-3000's tap targets on the NXS2's
! touch screen. The panel task calls touch_event(r4 pen, r5 x, r6 y)
! 0x084ECCF8 on every panel frame (pen 0 when up) through the literals
! 0x0844E240 / 0x0844E488; place_modsmenu points both at v3e_touch. A press
! that starts inside one of OUR zones (vt_zones, for the current MAIN screen
! class *0x0B54336C and model screen 0x0B53FB54) runs its action once and is
! not passed on (stock sees only the pen-up); any other press goes to stock
! untouched. Actions reuse stock paths: a panel key held for VT_KT panel
! frames (its decoder setter, as the key would), the rotary (0x084E1214(n):
! the offset the decoder adds to the knob counter, as the MIDI path does),
! the SHORT CUT category requests (0x084E13FA(0, j, 1)), or a call.
! Uses r0-r7 and the stack; r8-r14 kept.
! ---------------------------------------------------------------------------
	.equ	VT_KT, 15		! panel frames (~10 ms each) a tapped key is held down
	.equ	VT_GAP, 40		! panel frames after an action before the next one counts
	.equ	VT_UCLS, 6		! the UTILITY screen's class (emu: 6)
	.equ	VT_RTO, 60		! V3e3: panel frames to wait for the UI to take a detent before re-sending
	.equ	VT_SET, 30		! V3e3: panel frames between two rail-walk steps
	.equ	VT_WMAX, 24		! V3e3: rail-walk steps before giving up
	.p2align 2
	.global	v3e_touch
v3e_touch:
	mov.l	vt_boot0,r0		! V3rc3 update safety: on anything but a normal boot (MAIN boot
	mov.l	@r0,r0			! state 0x0A35DF3C == 1) stock's touch_event as is
	cmp/eq	#1,r0
	bt	0f
	mov.l	vt_ev0,r0
	jmp	@r0
	nop
0:	sts.l	pr,@-r15
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	mov.l	r6,@-r15
	mov.l	vt_kp0,r7		! a tapped key in progress: held VT_KT frames, then released
	mov.l	@r7,r2
	tst	r2,r2
	bt	2f
	mov.l	@(4,r7),r0
	add	#-1,r0
	mov.l	r0,@(4,r7)
	cmp/pl	r0
	movt	r5			! pressed while frames are left
	bt	1f
	mov	#0,r0
	mov.l	r0,@r7			! the release goes out once, then nothing
1:	jsr	@r2
	mov	#0,r4
	mov.l	@r15,r6
	mov.l	@(4,r15),r5
	mov.l	@(8,r15),r4
2:	bsr	vt_kbchk		! V3rc3: SEARCH's hidden keyboard: still on SEARCH?
	nop
	mov.l	vt_hpn,r7		! vt_held: 0 up, 1 stock's press, 2 ours; +4 panel frames counter,
	mov.l	@(4,r7),r0		! +8 the frame of our last action
	add	#1,r0
	mov.l	r0,@(4,r7)
	bsr	vt_seek			! V3e3: a closed-loop knob seek (re_browse: one detent at a time,
	nop				! the next after the live index moved)
	tst	r0,r0
	bf	3f
	mov.l	vt_kpn,r1
	mov.l	@r1,r0
	tst	r0,r0
	bf	3f			! a tapped key still held
	bsr	vt_rail2		! a rail category being reached (live state, one step at a time)
	nop
	bsr	vt_letter		! V3rc1: a letter jump under way
	nop
3:
	mov.l	@r15,r6
	mov.l	@(4,r15),r5
	mov.l	@(8,r15),r4
	mov.l	vt_hpn,r7
	mov.l	@r7,r0			! V3rc2: a remapped press (action 11): every frame of it, up
	cmp/eq	#3,r0			! included, reaches stock at the stock button's place
	bf	4f
	mov.l	vt_rmp,r1
	mov.l	@r1,r0
	add	r0,r5
	mov.l	@(4,r1),r0
	add	r0,r6
	mov.l	r6,@r15
	mov.l	r5,@(4,r15)
	tst	r4,r4
	bf	vt_stock
	bra	vt_up
	nop
4:	mov.l	vt_dgp,r1		! V4n: a list row press pending (tap or drag) / a drag under way
	mov.l	@r1,r0
	tst	r0,r0
	bt	8f
	mov.l	vt_drj,r0
	jsr	@r0
	nop
	mov.l	@r15,r6
	mov.l	@(4,r15),r5
	mov.l	@(8,r15),r4
	mov.l	vt_hpn,r7
	tst	r4,r4
	bt	vt_up
	bra	vt_done
	nop
8:	tst	r4,r4
	bt	vt_up
	mov.l	@r7,r0
	cmp/eq	#1,r0
	bt	vt_stock
	cmp/eq	#2,r0
	bt	vt_done			! ours: stock never sees it
	mov	#1,r0
	mov.l	r0,@r7
	mov.l	@(4,r7),r0		! a press within VT_GAP frames of our last action (a finger that
	mov.l	@(8,r7),r1		! bounces, the model not updated yet): stock's, ours ignore it
	sub	r1,r0
	mov	#VT_GAP,r1
	cmp/hs	r1,r0
	bt	9f
	! REVIEW 1124 1.1: inside the gap the press used to go to STOCK: over an open pad row a fast second tap on
	! KEY SHIFT +1 / -1 set a loop or jumped beats (stock zone 4 lies under our panel). Now it is swallowed.
	mov	#2,r0
	mov.l	r0,@r7
	bra	vt_done
	nop
9:
	mov.l	vt_kbhp2,r1		! V3rc3: SEARCH, keyboard hidden: a tap on the query box (y < 60)
	mov.l	@r1,r0			! shows it again
	tst	r0,r0
	bt	6f
	mov	#60,r0
	cmp/hs	r0,r6
	bt	6f
	mov	#0,r0
	bra	vt_mine
	mov.l	r0,@r1
6:	bsr	vt_hit			! r5 x, r6 y -> r0 = the zone record, or 0
	nop
	tst	r0,r0
	bf	7f
	mov.l	vt_kbhn,r1		! V3rc3: no zone with the keyboard hidden: swallowed (stock would
	mov.l	@r1,r0			! type a key there)
	tst	r0,r0
	bt	vt_stock
vt_mine:	mov	#2,r1			! ours, nothing to do
	mov.l	vt_hpn,r7
	mov.l	r1,@r7
	mov.l	@(4,r7),r1
	bra	vt_done
	mov.l	r1,@(8,r7)
7:
	mov	r0,r3
	mov.b	@(2,r0),r0
	cmp/eq	#11,r0
	bf	5f
	mov.b	@(3,r3),r0		! V3rc2 action 11: the press goes to stock at vt_rmt[arg]
	extu.b	r0,r0
	shll2	r0
	mov	r0,r2
	mova	vt_rmt,r0
	add	r2,r0
	mov.w	@r0,r1
	mov.w	@(2,r0),r0
	sub	r5,r1			! dx
	sub	r6,r0			! dy
	mov.l	vt_rmp,r2
	mov.l	r1,@r2
	mov.l	r0,@(4,r2)
	add	r1,r5
	add	r0,r6
	mov.l	r6,@r15
	mov.l	r5,@(4,r15)
	mov.l	vt_hpn,r2
	mov	#3,r0
	bra	vt_stock
	mov.l	r0,@r2
5:	mov	r3,r0
	mov	#2,r1
	mov.l	vt_hpn,r7
	mov.l	r1,@r7
	mov.l	@(4,r7),r1
	mov.l	r1,@(8,r7)
	bsr	vt_act
	nop
vt_done:
	add	#12,r15
	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
vt_kbhn: .long	vt_kbh			! PLAYERSCALE phase 2: a near copy too (the zone table grew by a row)
vt_hpn:	.long	vt_held			! V4n31a: near copies (va_src / SOURCE grew the code past the
vt_kpn:	.long	vt_key			! reach of the pool below)
vt_up:	mov	#0,r0
	mov.l	r0,@r7
vt_stock:
	mov.l	@r15+,r6
	mov.l	@r15+,r5
	mov.l	@r15+,r4
	lds.l	@r15+,pr
	mov.l	vt_ev,r0
	jmp	@r0
	nop
	.p2align 2
vt_rmt:	.short	52, 76, 52, 140, 52, 261	! action 11 targets: stock's TRACK FILTER BPM/KEY tab (zone 20),
					! MY TAG tab (21), -RESET (23)
vt_rmp:	.long	vt_rm
vt_kbhp2: .long	vt_kbh			! (TOUCH: a near copy)
vt_dgp:	.long	vt_dg			! V4n
vt_boot0: .long	0x0A35DF3C		! (V4n: copies within reach of v3e_touch's head)
vt_ev0:	.long	0x084ECCF8
vt_kp0:	.long	vt_key
vt_drj:	.long	vt_drag
vt_rm:	.long	0, 0			! the remapped press's dx, dy

! r5 = x, r6 = y -> r0 = the first zone record that holds the point for the
! current screen, else 0. Record (8 B): class, model screen (0xFF any), action,
! argument, x0 / 4, y0 / 2, x1 / 4, y1 / 2 (x1 / y1 excluded); class 0 ends.
! vt_kbchk: vt_kbh only while SEARCH (model slot 0 icon 0x25) has its keyboard (UI +0x54 / 0x0B545B64). r0-r2.
vt_kbchk:
	mov.l	vt_kbhp,r2
	mov.l	@r2,r0
	tst	r0,r0
	bt	9f
	mov.l	vt_s0ip,r1
	mov.w	@r1,r0
	extu.w	r0,r0
	cmp/eq	#0x25,r0
	bf	8f
	mov.l	vt_ui,r1
	mov	#0x54,r0
	mov.l	@(r0,r1),r0
	mov.l	vt_kb2,r1
	mov.l	@r1,r1
	or	r1,r0
	tst	r0,r0
	bf	9f
8:	mov	#0,r0
	mov.l	r0,@r2
9:	rts
	nop

vt_hit:
	mov.l	vt_ui,r1
	mov.l	@r1,r2			! r2 = screen class
	mov	r2,r0
	cmp/eq	#1,r0			! TOUCH (V4n41): the player with a pop-up (LOAD PREVIOUS TRACK, stock
	bf	0f			! GRID ADJUST): the pop-up's rows / BACK outside, as on the lists
	mov.l	@(12,r1),r0
	tst	r0,r0
	bf	vt_pop
	mov	r2,r0
0:	cmp/eq	#2,r0			! lists / TAG LIST: none with a pop-up menu or
	bt	1f			! the SEARCH keyboard up (stock's own taps)
	cmp/eq	#3,r0
	bf	2f
1:	mov	#0x54,r0
	mov.l	@(r0,r1),r3
	mov.l	@(12,r1),r0
	or	r3,r0
	mov.l	vt_kb2,r3
	mov.l	@r3,r3
	or	r3,r0
	tst	r0,r0
	bt	2f
	mov.l	vt_kbhp,r0		! V3rc3: SEARCH's keyboard hidden -> the list's zones
	mov.l	@r0,r0
	tst	r0,r0
	bt	vt_pop			! CENTPOP (was 9f: stock's own taps)
2:	mov.l	vt_scrp,r3
	mov.b	@r3,r3
	extu.b	r3,r3			! r3 = model screen
	shlr2	r5			! x / 4, y / 2
	shlr	r6
	mova	vt_zones,r0
	mov	r0,r7
3:	mov.b	@r7,r0
	extu.b	r0,r0
	tst	r0,r0
	bt	9f
	cmp/eq	r2,r0
	bf	4f
	mov.b	@(1,r7),r0
	extu.b	r0,r0
	mov	#-1,r1
	extu.b	r1,r1
	cmp/eq	r1,r0			! 0xFF: any model screen
	bt	5f
	add	#-1,r1
	cmp/eq	r1,r0			! V4n31a (#58): 0xFE = SOURCE -- model screen 0x00 with a medium
	bf	11f			! in slot 1 (v2.c source_screen / is_src_icon)
	tst	r3,r3
	bf	4f
	mov.l	vt_srcip,r1
	mov.l	@r1,r0
	add	#-0x50,r0		! a medium: 0x50..0x55 (0x50.. = the LINK list's rows), 0x58, 0x63
	mov	#6,r1
	cmp/hs	r1,r0
	bf	5f
	cmp/eq	#8,r0
	bt	5f
	cmp/eq	#0x13,r0
	bt	5f
	bra	4f
	nop
11:	cmp/eq	r3,r0
	bf	4f
5:	mov.b	@(4,r7),r0
	extu.b	r0,r0
	cmp/hs	r0,r5			! x >= x0
	bf	4f
	mov.b	@(6,r7),r0
	extu.b	r0,r0
	cmp/hs	r0,r5			! x < x1
	bt	4f
	mov.b	@(5,r7),r0
	extu.b	r0,r0
	cmp/hs	r0,r6
	bf	4f
	mov.b	@(7,r7),r0
	extu.b	r0,r0
	cmp/hs	r0,r6
	bt	4f
	mov.b	@(2,r7),r0		! TOUCH (V4n41): the GRID ADJUST panel's zones (action 15, arg != 5)
	cmp/eq	#15,r0			! only in stock's GRID ADJUST mode
	bf	13f
	mov.b	@(3,r7),r0
	cmp/eq	#5,r0
	bt	14f
	cmp/eq	#7,r0			! PLAYERSCALE phase 2: ZOOM - GRID above the pad row (arg 7)
	bt	14f
	mov.l	vt_gmp,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	4f
	bra	13f
	nop
14:	bra	vt_zg			! PLAYERSCALE phase 2: gated on the pad row (out of line, after the literals)
	nop
13:
vt_z13:
	.ifdef	KEYSHIFT
	mov.b	@(2,r7),r0		! V4k: KEY SHIFT zones (action 12) only in their state
	cmp/eq	#12,r0
	bf	6f
	mov.l	vt_ksb2,r1
	mov.b	@(3,r7),r0
	cmp/eq	#6,r0			! SHORT CUT rekordbox tile: REKORDBOX BUTTON = KEY SHIFT
	bf	7f
	mov.l	@r1,r0
	tst	r0,r0
	bt	4f
	bra	6f
	nop
7:	mov.l	@(20,r1),r0		! KEY SHIFT OFF: none of them
	tst	r0,r0
	bt	4f
	mov.b	@(3,r7),r0
	cmp/eq	#1,r0			! the header tile
	bt	6f
	mov.l	@(4,r1),r0		! the panel's row: while it is open
	tst	r0,r0
	bt	4f
6:
	.endif
	rts
	mov	r7,r0
4:
vt_z4:	bra	3b
	add	#8,r7
9:	rts
	mov	#0,r0
	.p2align 2
vt_srcip: .long	0x0B53FBA4 + 0x220 + 0x14	! V4n31a: the model's side-0 slot 1 icon
vt_gmp:	.long	0x0A35F3E0		! TOUCH: stock GRID ADJUST mode (getter 0x083FBA68)
	.ifdef	KEYSHIFT
vt_ksb2: .long	KSB
	.endif



! r0 = the zone record (the touch's x / 4, y / 2 still in r5 / r6): its action
vt_act:
	sts.l	pr,@-r15
	mov	r0,r7
	mov.b	@(3,r7),r0
	mov	r0,r4			! r4 = argument (signed)
	mov.b	@(2,r7),r0
	cmp/eq	#1,r0
	bt	va_key
	cmp/eq	#2,r0
	bt	va_rot
	cmp/eq	#3,r0
	bt	va_sc
	cmp/eq	#4,r0
	bt	va_rows
	cmp/eq	#5,r0
	bt	va_filter
	cmp/eq	#6,r0
	bt	va_ut
	cmp/eq	#7,r0
	bt	va_own
	cmp/eq	#8,r0
	bt	va_cat
	cmp/eq	#9,r0
	bt	va_ucat
	cmp/eq	#10,r0
	bt	va_bj
	cmp/eq	#13,r0			! V4n31a (#58): a SOURCE row
	bf	12f
	mov.l	vt_srcj,r0
	jmp	@r0
	nop
	.p2align 2
vt_srcj: .long	va_src
12:	mov	#14,r1			! TOUCH (V4n41): 14 pop-up, 15 GRID ADJUST panel, 16 UTILITY row,
	cmp/hs	r1,r0			! 17 UTILITY option, 18 PREVIEW tile (va_touch)
	bf	14f
	mov	#19,r1
	cmp/hs	r1,r0
	bt	14f
	mov.l	vt_tchj,r1
	jmp	@r1
	nop
	.p2align 2
vt_tchj: .long	va_touch
14:
	.ifdef	KEYSHIFT
	cmp/eq	#12,r0
	bf	va_out
	mov.l	vt_ksj,r0
	jmp	@r0
	nop
	.p2align 2
vt_ksj:	.long	va_ks
	.endif
va_out:	lds.l	@r15+,pr
	rts
	nop
va_key:					! a panel key: setter vt_keys[arg], held VT_KT frames
	mova	vt_keys,r0
	shll2	r4
	mov.l	@(r0,r4),r2
va_key2:
	mov.l	vt_kp,r1
	mov	#VT_KT,r0
	mov.l	r0,@(4,r1)
	bra	va_out
	mov.l	r2,@r1
va_rot:	bsr	vt_idx			! the knob, arg detents: a seek to index + arg (V3e3)
	nop
	add	r0,r4
	bsr	vt_seek_to
	nop
	bra	va_out
	nop
va_sc:	mov	r4,r5			! SHORT CUT request j (TRACK 0, SEARCH 1, PLAYLIST 2, MATCHING 3)
	mov	#0,r4
	mov.l	vt_scf,r0
	jsr	@r0
	mov	#1,r6
	bra	va_out
	nop
va_filter:				! V3rc1: TRACK FILTER = KEYCMD 13's event (0x0B5462E4 + 13 * 16:
	mov.l	vt_fev,r1		! +0 key state, +8 stage) forged as a long press being let go: stage
	mov	#2,r0			! 2, then state 1 with the key word up -- the UI task's tracker
	mov.l	r0,@(8,r1)		! (0x084D2060) reports the release, its dispatcher (0x084D2274) calls
	mov	#1,r0			! 0x084D35DA(event) in ITS context: class 2 -> the long path opens the
	bra	va_out			! page (0x084C5DFC(8)), class 8 / 9 -> closes it; the handler's tail
	mov.l	r0,@r1			! clears the stage. (V3e3: called from this task it never opened;
					! the stage alone is not dispatched: no tracker change)
va_ucat:				! UTILITY: a category tile -> a seek to its first item (V3e3: the
	mova	vt_ucat,r0		! engine's index = first row 0x0B5434F4 + cursor row 0x0B5433B8)
	mov.b	@(r0,r4),r4
	extu.b	r4,r4
	bsr	vt_seek_to
	nop
	bra	va_out
	nop
va_cat:					! a rail category: arg = its icon id; vt_rail walks there
	extu.b	r4,r4
	mov.l	vt_rp,r1
	mov.l	r4,@r1			! the target
	mov	#0,r0
	mov.l	r0,@(4,r1)		! steps taken
	mov.l	vt_hp,r2
	mov.l	@(4,r2),r0
	bra	va_out
	mov.l	r0,@(8,r1)		! next step: now
va_ut:					! LCD / JOG BRIGHTNESS -1 / +1 (arg bit 0 item, bit 1 up) through
	mov	r4,r0			! the item's own commit, as UTILITY does, then the settings save
	and	#1,r0
	shll2	r0
	mov	r0,r1
	mova	vt_ute,r0
	mov.l	@(r0,r1),r5		! r5 = the item's table entry
	tst	r5,r5
	bt	va_out
	bsr	vt_utv			! r1 = its live value (its getter's word; +12 is -1 until
	mov	r4,r0			! UTILITY formats it once)
	mov.l	r1,@(12,r5)
	mov	r4,r0
	tst	#2,r0
	bt	2f
	add	#2,r1
2:	add	#-1,r1			! +1 / -1
	cmp/pz	r1
	bf	va_out
	mov.l	@(8,r5),r0		! < the option count
	cmp/hs	r0,r1
	bt	va_out
	mov.l	r1,@(16,r5)		! pending
	mov.l	@(44,r5),r0		! slot 5: commit
	mov.l	r5,@-r15
	jsr	@r0
	mov	r5,r4
	mov.l	@r15+,r5
	mov	#-1,r1
	mov.l	r1,@(16,r5)		! not editing
	cmp/eq	#1,r0
	bf	va_out
va_save:
	mov.l	vt_savel,r0		! the engine's save literal (0x0846D0D2, maybe chained)
	mov.l	@r0,r0
	jsr	@r0
	nop
	bra	va_out
	nop
! r0 = item (bit 0: 0 LCD BRIGHTNESS, 1 JOG BRIGHTNESS) -> r1 = its option index, as the
! UTILITY formatters derive it (LCD: getter 0x083FC474 word - 1; JOG: getter 0x083FC428 word)
vt_utv:	tst	#1,r0
	mov.l	vt_lcdw,r1
	bf	1f
	mov.l	@r1,r1
	rts
	add	#-1,r1
1:	mov.l	vt_jogw,r1
	rts
	mov.l	@r1,r1
	.p2align 2
vt_lcdw: .long	0x0A35F688		! 0x0A35DF30 + 0x1758
vt_jogw: .long	0x0A35F6E0		! 0x0A35DF30 + 0x17B0
va_own:					! our own settings (SHORT CUT WAVEFORM COLOR / POSITION):
	mova	vt_own,r0		! arg = item << 4 | value
	mov	r4,r1
	shlr2	r1
	shlr2	r1
	shll2	r1
	mov.l	@(r0,r1),r1		! the word
	mov	r4,r0
	and	#15,r0
	bra	va_save
	mov.l	r0,@r1
va_rows:				! V4n: the press only starts a gesture (vt_drag): a tap acts on
	mov.l	vt_dgp2,r1		! the release (va_rows0, as the 3000), a move > 8 px drags the list
	mov.l	@r1,r0
	cmp/eq	#3,r0
	bt	va_rows0
	mov	#1,r0
	mov.l	r0,@r1
	mov.l	r5,@(4,r1)		! x / 4
	mov.l	r6,@(8,r1)		! y / 2 at the press
	mov.l	r6,@(16,r1)
	mov.l	r6,@(24,r1)
	mov.l	vt_dtk2,r2
	mov.l	@r2,r2
	mov.l	r2,@(20,r1)
	mov.l	r2,@(28,r1)
	bsr	vt_idx
	nop
	mov.l	vt_dgp2,r1
	mov.l	r0,@(12,r1)		! the cursor index at the press
	bra	va_out
	mov.l	r0,@(32,r1)		! the drag's goal
va_rows0:				! a list row: move the cursor to it; on the cursor row,
	mov	r6,r0			! open it (PUSH) unless it is a track
	add	#-45,r0			! row k = (y / 2 - 45) / 20
	cmp/pz	r0
	bf	va_out
	mov	#0,r4
	mov	#20,r1
1:	cmp/hs	r1,r0
	bf	2f
	sub	r1,r0
	bra	1b
	add	#1,r4
2:	mov	#8,r0
	cmp/hs	r0,r4
	bt	va_out
	mov.l	vt_slots,r1		! the model's side-0 slots (row k = slot k + 1)
	mov.w	vt_220,r2
	mov	r4,r3
	add	#1,r3
	mulu.w	r2,r3
	sts	macl,r3
	add	r1,r3			! r3 = row k's slot
	mov	#0x28,r0		! an empty row: nothing
	mov.w	@(r0,r3),r0
	tst	r0,r0
	bt	va_out
	mov	#53,r0			! the PREVIEW column (x < 212) of a rowwave row is
	cmp/hs	r0,r5			! touch_audio's (Link Cue)
	bt	3f
	mov.l	@(0x1C,r3),r0
	cmp/eq	#1,r0
	bt	8f
3:	mov.l	vt_vcur,r1		! V3e3: the cursor row from the live UI (0x0B5433B8)
	mov.l	@r1,r0
	cmp/eq	r4,r0
	bt	6f
9:	mov.l	vt_vfst,r1
	mov.l	@r1,r0
	add	r0,r4			! a seek to first + k
	bsr	vt_seek_to
	nop
	bra	va_out
	nop
6:	mov.l	@(0x14,r3),r0		! the cursor row: a track stays (the 3000 loads with the
	cmp/eq	#0x2F,r0		! knob or its LOAD button), anything else opens
	bt	5f
	cmp/eq	#0x5A,r0
	bt	5f
	cmp/eq	#0x5B,r0
	bt	5f
	cmp/eq	#0x60,r0
	bt	5f
4:	mov.l	vt_push,r2
	bra	va_key2
	nop
5:	mov	#84,r0			! V4n11: a track's LOAD button (v2.c: over the BPM / KEY columns,
	shll	r0			! V4n30a x >= 672 = x / 4 >= 168): PUSH = load, as the 3000's LOAD
	cmp/hs	r0,r5
	bt	4b
7:	bra	va_out
	nop
! R21 parity (d): the 3000's preview gesture ends with the previewed row SELECTED (blue, LOAD over BPM / KEY;
! re/V3_PROGRESS.md 3000 parity list #9). touch_audio row_touch still owns the press / drag / lift (play from x,
! seek, stop); the release's tap (vt_drag vd_up -> here, a finger that moved < 8 px vertically, any time held)
! now also moves the cursor to that row -- never a PUSH from this column (the cursor row: nothing, as before).
8:	mov.l	vt_vcur,r1
	mov.l	@r1,r0
	cmp/eq	r4,r0
	bf	9b
	bra	va_out
	nop
	.p2align 1
vt_220:	.short	0x220
	.p2align 2
vt_vcur: .long	0x0B5433B8
vt_dgp2: .long	vt_dg			! V4n
vt_dtk2: .long	0x0B0C5258
vt_vfst: .long	0x0B5434F4
	.p2align 2
vt_kp:	.long	vt_key
vt_hp:	.long	vt_held
vt_ev:	.long	0x084ECCF8		! stock touch_event
vt_boot: .long	0x0A35DF3C		! MAIN boot state (1 = normal boot)
vt_kbhp: .long	vt_kbh
vt_s0ip: .long	0x0B53FBA4 + 0x14	! the model's side-0 slot 0 icon (0x25 = SEARCH)
vt_kbh:	.long	0			! V3rc3: 1 = SEARCH's keyboard hidden (the 3000's results view)
vt_ui:	.long	0x0B54336C		! MAIN UI state: +0 class, +0xC pop-up menu, +0x54 keyboard
vt_kb2:	.long	0x0B545B64		! (the keyboard's second flag, MAIN 0x084D0024's test)
vt_scrp: .long	0x0B53FB54		! the model's screen id (GUI model +0x07)
vt_slots: .long	0x0B53FBA4		! the model's side-0 slot 0 (0x0B53FB50 + 0x54)
vt_scf:	.long	0x084E13FA		! SHORT CUT category request (0, j, 1)
vt_fev:	.long	0x0B5463B4		! KEYCMD FILTER's event (13)
vt_push: .long	0x084E121E		! rotary push
vt_back: .long	0x084E1232		! BACK
vt_rp:	.long	vt_rt
vt_curp: .long	0x0B5434F4
vt_key:	.long	0			! the tapped key's setter (0 none)
	.long	0			! panel frames left
	.p2align 2
vt_zg:	! PLAYERSCALE phase 2 (v2.c PADROW_UP): the label sits under the band (arg 5) with no pad row and above
	! it (arg 7) while one is up -- BEAT LOOP pads (heartbeat block +0xF0 == 2), BEAT JUMP pads (+0x118 == 1),
	! stock GRID ADJUST mode, the KEY SHIFT panel -- so each zone is live only in its state
	mov.l	vt_lpm,r1
	mov.l	@r1,r0
	cmp/eq	#2,r0
	bt	15f
	mov.l	vt_bjm,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bt	15f
	mov.l	vt_gmp2,r1
	mov.l	@r1,r0
	tst	r0,r0
	bf	15f
	.ifdef	KEYSHIFT
	mov.l	vt_ksb3,r1
	mov.l	@(20,r1),r0		! KEY SHIFT on ...
	tst	r0,r0
	bt	16f
	mov.l	@(4,r1),r0		! ... and its panel open
	tst	r0,r0
	bf	15f
16:
	.endif
	mov.b	@(3,r7),r0		! no pad row: arg 7 is off
	cmp/eq	#7,r0
	bt	17f
	bra	vt_z13
	nop
17:	bra	vt_z4
	nop
15:	mov.b	@(3,r7),r0		! a pad row: arg 5 is off
	cmp/eq	#5,r0
	bt	17b
	bra	vt_z13
	nop
	.p2align 2
vt_lpm:	.long	0x0B568C9C + 0xF0	! the heartbeat block's loop-pad mode word (GUI DECK + 0xF0)
vt_bjm:	.long	0x0B568C9C + 0x118	! ... and the beat-jump pad mode word (GUI DECK + 0x118)
vt_gmp2: .long	0x0A35F3E0
	.ifdef	KEYSHIFT
vt_ksb3: .long	KSB
	.endif

	.global	vt_held
vt_held: .long	0, 0, -1000		! held, panel frames, frame of the last action
vt_rt:	.long	0, 0, 0			! rail: target icon, steps, frame of the next step
	.global	vt_ucat
vt_ucat: .byte	0, 0, 0, 0, 0, 0, 0, 0	! UTILITY: first item of DJ SETTING .. INFO (place_modsmenu)
	.global	vt_ute
vt_ute:	.long	0, 0, 0			! the LCD / JOG BRIGHTNESS / PLAYER No. table entries (place_modsmenu)
vt_own:	.long	wave_v, pos_v
vt_savel: .long	0x084F1058		! the UTILITY engine's save call literal
vt_keys: .long	0x084E1232, 0x084E11B8, 0x084E11CC, 0x084E121E, 0x084E1120, 0x084E115C
	! 0 BACK, 1 INFO, 2 MENU (the SORT pop-up), 3 PUSH, 4 USB, 5 SEARCH
! the zones (8 B: class, model screen or 0xFF, action 1 key / 2 knob / 3 SHORT CUT request /
! 4 list rows / 5 TRACK FILTER, argument, x0 / 4, y0 / 2, x1 / 4, y1 / 2) -- the V2 browser's
! geometry (mods/v2ui/v2.c: rail 56 px, header y 0..59, column bar 60..87, rows 8 x 40 from y 90)
	.macro	vz cls, scr, act, arg, x0, y0, x1, y1
	.byte	\cls, \scr, \act, \arg, (\x0) / 4, (\y0) / 2, (\x1) / 4, (\y1) / 2
	.endm
	.p2align 2
vt_zones:
	! TOUCH (V4n41): GENERATED -- mods/v2ui/touch_map.py (CURRENT_VT = the rows, re-derived from the drawn rects +
	! 6 px hit-slop by map_vt_rows; `touch_map.py --inc mods/v2ui/touch_vt_zones.inc`; tests/test_touch_map.py).
	! The hand-written table this replaced: work/touch/orig/modsmenu.s (V4n41 base)
	.include "touch_vt_zones.inc"
	.p2align 2

! CENTPOP: SORT / LIST MENU / TAG LIST MENU pop-up up (vt_ui +0xC), no keyboard: stock took no tap anywhere
! (emu: the < box, the column bar, outside the box: nothing) -> a tap on our pop-up is swallowed (knob + PUSH
! select), anywhere else = BACK (closes it, as the 3000's tap outside). The pop-up's box as v2.c popup() draws it: x 230..569 (LOAD PREVIOUS TRACK, model screen 0x02:
! the right pane 457..799), y 88..419; r5 x, r6 y (unscaled) -> r0 = the swallow / BACK zone record
vt_pop:
	mov	#0x54,r0		! the SEARCH keyboard up: stock's (as before)
	mov.l	@(r0,r1),r0
	mov.l	vp_kb2,r3
	mov.l	@r3,r3
	or	r3,r0
	tst	r0,r0
	bt	0f
	rts
	mov	#0,r0
0:	mov.l	vp_scrp,r3
	mov.b	@r3,r0
	mov.w	vp_x0,r2
	mov.w	vp_x1,r3
	cmp/eq	#2,r0
	bf	1f
	mov.w	vp_x2,r2
	mov.w	vp_x3,r3
1:	cmp/hs	r2,r5
	bf	3f
	cmp/hs	r3,r5
	bt	3f
	mov	#88,r0			! below the column bar (60..87: a tap there = BACK too)
	cmp/hs	r0,r6
	bf	3f
	mov.w	vp_y1,r0
	cmp/hs	r0,r6
	bt	3f
	mova	vp_zin,r0
	rts
	nop
3:	mova	vp_zbk,r0
	rts
	nop
	.p2align 1
vp_x0:	.short	230
vp_x1:	.short	570
vp_x2:	.short	457
vp_x3:	.short	800
vp_y1:	.short	420
	.p2align 2
vp_zin:	.byte	2, 0xFF, 14, 0, 0, 0, 0, 0	! TOUCH (V4n41): va_touch's pop-up rows / OK / CANCEL (was: swallowed)
vp_zbk:	.byte	2, 0xFF, 1, 0, 0, 0, 0, 0	! BACK
vp_kb2:	.long	0x0B545B64
vp_scrp: .long	0x0B53FB54


! vt_knob(r4 = n, |n| <= 2): one knob move through the decoder's offset, wrap-safe. Replaces every
! jsr 0x084E1214. Keeps the u16 offset in 0x100..0xFEFF by adding / removing 256 (the poll's
! unwrap takes it back out), so byte + offset never crosses a 16-bit wrap. Uses r0-r2.
	.p2align 1
vt_knob:
	mov.l	vk_off,r1
	mov.w	@r1,r0
	extu.w	r0,r0
	add	r4,r0
	mov.w	vk_100,r2
	cmp/ge	r2,r0			! < 0x100 (incl. negative): + 256
	bt	1f
	add	r2,r0
1:	mov.l	vk_ff00,r2
	cmp/ge	r2,r0			! >= 0xFF00: - 256
	bf	2f
	mov.w	vk_100,r2
	sub	r2,r0
2:	rts
	mov.w	r0,@r1
	.p2align 1
vk_100:	.short	0x100
	.p2align 2
vk_off:	.long	0x10DE15C0
vk_ff00: .long	0xFF00

! vt_idx: r0 = the live absolute cursor index of side 0 (first visible row + cursor row). Uses r1.
vt_idx:
	mov.l	vi_first,r1
	mov.l	@r1,r0
	mov.l	vi_cur,r1
	mov.l	@r1,r1
	rts
	add	r1,r0

! vt_seek_to(r4 = goal index): start a closed-loop knob seek (clamped to 0 .. count - 1). Uses r0-r2.
vt_seek_to:
	mov.l	vi_cnt,r1
	mov.l	@r1,r0
	add	#-1,r0
	cmp/gt	r0,r4
	bf	1f
	mov	r0,r4
1:	cmp/pz	r4
	bt	2f
	mov	#0,r4
2:	mov.l	vs_p,r1
	mov	#0,r0			! TOUCH: a list seek (vt_idx), no PUSH after
	mov.l	r0,@(20,r1)
	mov.l	r0,@(24,r1)
	mov.l	r4,@(4,r1)		! goal
	mov	#-1,r0
	mov.l	r0,@(8,r1)		! index at the last send: none
	mov	#0,r0
	mov.l	r0,@(16,r1)		! sends without movement
	mov	#1,r0
	rts
	mov.l	r0,@r1			! active

! vt_seek: once per panel frame (from v3e_touch, where vt_rail is called now). One detent at a time,
! the next one only after the live index moved (never 2 pending -> never the x5 acceleration, a lost
! detent is re-sent after VT_RTO frames; 4 sends without movement = a list end / dead screen: stop).
! r0 = 1 while seeking. Uses r0-r7.
vt_seek:
	mov.l	vs_p,r7
	mov.l	@r7,r0
	tst	r0,r0
	bt	9f
	sts.l	pr,@-r15
	mov.l	@(20,r7),r0		! TOUCH (V4n41): a pop-up / UTILITY option seek (vt_srdy) waits for its
	tst	r0,r0			! screen, up to VH_WAIT ms
	bt	10f
	bsr	vt_srdy
	nop
	mov	r0,r3
	mov.w	vs_nr,r1
	cmp/eq	r1,r3
	bf	11f
	mov.l	vs_tk,r1
	mov.l	@r1,r0
	mov.l	@(32,r7),r1
	sub	r1,r0
	mov.w	vs_wt,r1
	cmp/hs	r1,r0
	bt	12f
	bra	7f
	nop
10:	bsr	vt_idx
	nop
	mov	r0,r3			! r3 = live index
11:	mov.l	@(4,r7),r2		! r2 = goal
	cmp/eq	r2,r3
	bt	8f
	mov.l	vs_hp,r1
	mov.l	@(4,r1),r6		! r6 = panel frame
	mov.l	@(8,r7),r0
	cmp/eq	r0,r3
	bf	3f			! moved since the last send (or first send): send now
	mov.l	@(12,r7),r0
	mov	r6,r1
	sub	r0,r1
	mov	#VT_RTO,r0
	cmp/hs	r0,r1
	bf	7f			! the UI has not taken it yet
	mov.l	@(16,r7),r0
	add	#1,r0
	mov.l	r0,@(16,r7)
	cmp/eq	#4,r0
	bt	12f			! (TOUCH: given up -- no PUSH)
	bra	4f
	nop
3:	mov	#0,r0
	mov.l	r0,@(16,r7)
4:	mov.l	r3,@(8,r7)
	mov.l	r6,@(12,r7)
	mov	#1,r4
	cmp/gt	r3,r2			! goal > index: +1
	bt	5f
	mov	#-1,r4
5:	bsr	vt_knob
	nop
7:	lds.l	@r15+,pr
	rts
	mov	#1,r0
8:	mov.l	@(24,r7),r0		! TOUCH: reached -- PUSH when asked
	tst	r0,r0
	bt	12f
	mov.l	vs_kp,r1
	mov.l	vs_push,r2
	mov.l	r2,@r1
	mov	#VT_KT,r2
	mov.l	r2,@(4,r1)
	cmp/eq	#2,r0			! 2: then BACK if stock left its pop-up open (an item it ignores: GRID
	bf	12f			! ADJUST's SNAP GRID without a CUE) -- mode 3, vt_srdy
	mov	#3,r0
	mov.l	r0,@(20,r7)
	mov.l	vs_tk,r1
	mov.l	@r1,r0
	mov.l	r0,@(32,r7)
	lds.l	@r15+,pr
	rts
	mov	#1,r0
12:	mov	#0,r0
	mov.l	r0,@r7
	mov.l	r0,@(20,r7)
	mov.l	r0,@(24,r7)
	lds.l	@r15+,pr
9:	rts
	mov	#0,r0
	.p2align 1
vs_nr:	.short	-256			! vt_srdy's TH_NR
vs_wt:	.short	1500			! VH_WAIT
	.p2align 2
vs_tk:	.long	0x0B0C5258
! vt_srdy (r7 = vt_sk, mode != 0): r0 = the live index of a TOUCH seek, or TH_NR while its screen is not
! up (mode 1: a pop-up -> the cursor's row 1..8, 0 none; mode 2: UTILITY's edit -> the entry's pending
! option). Uses r0-r3.
	.equ	TH_NR, -256
vt_srdy:
	mov.l	ts_key,r1		! a key still held (the PUSH / MENU that opens the screen): not yet --
	mov.l	@r1,r0			! the PUSH after the seek must be a new press, not this one's tail
	tst	r0,r0
	bf	8f
	mov.l	ts_tk,r1		! and 120 ms since the tap: the UI has seen the key's release (its poll is
	mov.l	@r1,r0			! slower than the panel frames)
	mov.l	@(32,r7),r1
	sub	r1,r0
	mov	#120,r1
	mov.l	@(20,r7),r2		! (mode 3: 500 ms -- stock closes its pop-up on a PUSH it takes)
	mov	r2,r3
	add	#-3,r3
	tst	r3,r3
	bf	3f
	mov.w	ts_500,r1
3:	cmp/hs	r1,r0
	bf	8f
	mov.l	@(20,r7),r0
	cmp/eq	#3,r0			! mode 3 (the settle above: the PUSH is out): the pop-up still up -> BACK;
	bf	4f			! the seek then ends (its goal is TH_NR's never: vt_seek gives up -- no PUSH)
	mov.l	ts_ui,r1
	mov.l	@(12,r1),r0
	tst	r0,r0
	bt	5f
	mov.l	ts_key,r1
	mov.l	ts_back,r0
	mov.l	r0,@r1
	mov	#VT_KT,r0
	mov.l	r0,@(4,r1)
5:	mov	#0,r0			! done: stop (vt_seek's stop path via the not-ready timeout is slower)
	mov.l	r0,@r7
	mov.l	r0,@(20,r7)
	mov.l	r0,@(24,r7)
	bra	8f
	nop
4:	cmp/eq	#1,r0
	bf	2f
	mov.l	ts_ui,r1
	mov.l	@(12,r1),r0
	tst	r0,r0
	bt	8f
	mov.l	ts_s1,r1
	mov.w	th_2202,r2
	mov	#1,r3
1:	add	r2,r1
	mov.l	@(12,r1),r0
	tst	#8,r0
	bf	3f
	add	#1,r3
	mov	#9,r0
	cmp/eq	r0,r3
	bf	1b
	mov	#0,r3
3:	rts
	mov	r3,r0
2:	mov.l	ts_scr,r1
	mov.b	@r1,r0
	cmp/eq	#9,r0
	bf	8f
	mov.l	@(28,r7),r1
	rts
	mov.l	@(16,r1),r0
8:	mov.w	th_nr,r0
	rts
	nop
	.p2align 1
th_2202:	.short	0x220
ts_500:	.short	500
th_nr:	.short	TH_NR

	.p2align 2
ts_ui:	.long	0x0B54336C
ts_key:	.long	vt_key
ts_back: .long	0x084E1232
ts_tk:	.long	0x0B0C5258
ts_s1:	.long	0x0B53FBA4 + 0x132C
ts_scr:	.long	0x0B53FB54


! Q2: vt_rail2 -- rail category walk on LIVE state, closed loop. Called once per panel frame after
! vt_seek (and only when vt_seek returned 0 and no tapped key is being held). vt_rt: +0 target icon,
! +4 steps, +8 frame of the next step. Each step:
!   count 0                          -> wait (list loading), no step used
!   slot 0 icon == target            -> in the category list: done
!   slot 0 icon is a medium root     -> find the target row on the page:
!       found, cursor on it          -> PUSH
!       found elsewhere              -> seek to first + row
!       not on the page              -> seek to the OTHER end (first == 0 ? count - 1 : 0)
!                                       (V3e2 always paged +8: a target above the page never came)
!   0x63 (the device / SOURCE list)  -> the USB key (V3e2 took it for the root: 0x63 was accepted)
!   anything else                    -> BACK
vt_rail2:
	mov.l	vr_p,r7
	mov.l	@r7,r3			! r3 = target icon
	tst	r3,r3
	bt	9f
	mov.l	vs_p,r1			! V3rc2: a seek under way -- wait for it (its looks used up the
	mov.l	@r1,r0			! VT_WMAX steps: FOLDER, on the root's 2nd page, was reached but
	tst	r0,r0			! never pushed)
	bf	9f
	mov.l	vs_hp,r1
	mov.l	@(4,r1),r6		! frame
	mov.l	@(8,r7),r0
	cmp/hs	r0,r6
	bf	9f
	mov.l	vi_cnt,r1
	mov.l	@r1,r0
	tst	r0,r0
	bf	0f
	mov.l	vr_s0,r1		! V3rc2: count 0 with a title = an EMPTY list (MATCHING without a
	mov	#0x28,r0		! track): go on (BACK out of it), only no title = still loading
	mov.w	@(r0,r1),r0
	tst	r0,r0
	bt	9f			! loading
0:	mov	#VT_SET,r0
	add	r6,r0
	mov.l	r0,@(8,r7)
	mov.l	@(4,r7),r0
	add	#1,r0
	mov.l	r0,@(4,r7)
	cmp/eq	#VT_WMAX,r0
	bt	8f
	sts.l	pr,@-r15
	mov.l	vr_s0,r1		! live side 0
	mov.w	@(0x14,r1),r0
	extu.w	r0,r0			! slot 0 icon
	cmp/eq	r3,r0
	bt	7f			! there
	cmp/eq	#0x63,r0
	bt	6f
	cmp/eq	#0x58,r0		! medium roots: USB / SD / LINK sources -- V4n35: 0x50..0x55, the
	bt	1f			! LINK roots too (a remote USB's root title is 0x52: the walk took
	mov	r0,r2			! it for a sub-list and pressed BACK, real rig deck 2 <- deck 3)
	add	#-0x50,r2
	mov	#6,r4
	cmp/hs	r4,r2
	bf	1f
	mov.l	vs_back,r2		! not the root: up one level
	bra	vr_key
	nop
6:	mov.l	vs_push,r2		! the device list (V3e3 emu: the USB key did nothing there): PUSH the device
	bra	vr_key
	nop
1:	mov.w	vr_220,r2		! scan rows 0..7 (slots 1..8): r4 = row with the icon, -1 none
	mov	#-1,r4
	mov	#0,r5
2:	add	r2,r1
	mov.w	@(0x14,r1),r0
	extu.w	r0,r0
	cmp/eq	r3,r0
	bf	3f
	mov	r5,r4
3:	add	#1,r5
	mov	#8,r0
	cmp/hs	r0,r5
	bf	2b
	mov.l	vi_first,r1
	mov.l	@r1,r5			! r5 = first
	cmp/pz	r4
	bf	4f
	mov.l	vi_cur,r1
	mov.l	@r1,r0
	cmp/eq	r4,r0
	bf	5f
	mov.l	vs_push,r2		! cursor on it: PUSH (next step checks slot 0 == target)
	bra	vr_key
	nop
5:	add	r5,r4			! seek to first + row
	bra	vr_seek
	nop
4:	mov	#0,r4			! not on the page: the other end
	tst	r5,r5
	bf	vr_seek
	mov.l	vi_cnt,r1
	mov.l	@r1,r4
	add	#-1,r4
vr_seek:
	bsr	vt_seek_to
	nop
	bra	vr_out
	nop
vr_key:
	mov.l	vs_kp,r1		! a key, held VT_KT frames (as vt_press)
	mov	#VT_KT,r0
	mov.l	r0,@(4,r1)
	mov.l	r2,@r1
	bra	vr_out
	nop
7:	mov	#0,r0			! done
	mov.l	r0,@r7
vr_out:	lds.l	@r15+,pr
9:	rts
	nop
8:	mov	#0,r0			! give up
	rts
	mov.l	r0,@r7


	.p2align 2
vs_hp:	.long	vt_held
vs_kp:	.long	vt_key
vs_back: .long	0x084E1232
vs_push: .long	0x084E121E
vi_first: .long	0x0B5434F4
vi_cur:	.long	0x0B5433B8
vi_cnt:	.long	0x0B5434F0
vs_p:	.long	vt_sk
vt_sk:	.long	0, 0, 0, 0, 0		! active, goal, index at the last send, frame of it, sends w/o move
	.long	0, 0, 0, 0		! TOUCH: mode (0 list, 1 pop-up, 2 UTILITY option), PUSH after, entry, start ms
	.p2align 1
vr_220:	.short	0x220
	.p2align 2
vr_p:	.long	vt_rt
vr_s0:	.long	0x0B5434EC

! V3rc1: the CDJ-3000 letter jump (re_browse Q5). vt_khook replaces the UI task's knob poll call of
! 0x084D2210(cur, prev) (literal 0x0844F1C8): a turn of VT_LJ or more detents in one poll (a fast turn;
! the stock multiplies these by 5) on a plain list -- class 2, no pop-up / keyboard, model screen 3, or 4
! sorted ALPHABET 0xA2 / DEFAULT 0xA1 -- starts a letter jump in its direction and is swallowed (d = 0);
! anything else goes to stock unchanged. The jump itself runs in the panel task (vt_letter), through the
! closed-loop seek; the display shows its big boxed letter while the cursor moves (v2.c letter overlay).
	.equ	LJ_PH, 4		! 0 start, 1 a probe settling, 2 the landing settling
	.equ	LJ_SIG0, 8		! the page's signature before the move
	.equ	LJ_DIR, 12		! 1 / -1
	.equ	LJ_STG, 16		! backward: 0 this group's start, 1 the group before's start
	.equ	LJ_LO, 20		! the search interval [lo, hi): pred(lo - 1) false, pred(hi) true
	.equ	LJ_PEND, 24		! letters pending (a spin walks the letters)
	.equ	LJ_LET, 28		! the last landing's letter, its tick (published, +0x14 bits 20-24)
	.equ	LJ_HI, 36
	.equ	LJ_K, 40		! the class the predicate tests
	.equ	LJ_MODE, 44		! 0: pred = letter != K, 1: letter == K
	.equ	LJ_HCLS, 48		! the letter of row hi, of row lo - 1
	.equ	LJ_LCLS, 52
	.equ	LJ_T, 56		! the index the move goes to
	.equ	LJ_REQ, 60		! the move (delta) for vt_khook, 0 once taken
	.equ	LJ_SIG, 64		! the signature last seen, its tick, the move's tick, probes made
	.equ	LJ_STK, 68
	.equ	LJ_MTK, 72
	.equ	LJ_NP, 76
	.equ	VL_STAB, 15		! ms a probe's page must stay unchanged
	.equ	VL_MAXNP, 48		! probes a letter at most
	.equ	VT_LJ, 3
	.p2align 1
	.global	vt_khook
vt_khook:
	mov.l	vh_boot,r1		! V3rc3 update safety: not a normal boot -> stock's knob poll as is
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	vh_stock
	mov.l	vh_ghp,r1		! TOUCH (V4n41): a 1/2-beat GRID ADJUST move from the panel (va_touch) ->
	mov.l	@r1,r2			! stock's knob GRID move 0x084E6638(delta), here in the UI task like the knob
	tst	r2,r2			! (still in GRID ADJUST mode only)
	bt	3f
	mov	#0,r0
	mov.l	r0,@r1
	mov.l	vh_gmd,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	3f
	mov.l	r4,@-r15
	mov.l	r5,@-r15
	sts.l	pr,@-r15
	mov.l	vh_gmv,r0
	jsr	@r0
	mov	r2,r4
	lds.l	@r15+,pr
	mov.l	@r15+,r5
	mov.l	@r15+,r4
3:	mov.l	vh_lj,r1		! V3rc3: a move vt_letter asked for -> the pending knob count
	mov.l	@(LJ_REQ,r1),r2		! (written here, in the UI task, as 0x084D2210 does)
	tst	r2,r2
	bt	0f
	mov	#0,r0
	mov.l	r0,@(LJ_REQ,r1)
	mov.l	vh_ui,r1
	mov.l	@r1,r0
	cmp/eq	#2,r0
	bf	0f			! no longer a list: dropped
	mov.l	vh_pend,r1
	mov.l	@r1,r0
	add	r2,r0
	mov.l	r0,@r1
0:	mov	r4,r0
	sub	r5,r0			! d = cur - prev, unwrapped once as 0x084D2210 does
	mov.w	vh_128,r1
	cmp/gt	r1,r0
	bf	1f
	mov.w	vh_256,r1
	bra	2f
	sub	r1,r0
1:	neg	r1,r1
	cmp/ge	r1,r0
	bt	2f
	mov.w	vh_256,r1
	add	r1,r0
2:	mov	r0,r6			! r6 = d
	mov.l	vh_zm,r0		! V4n32 (#zoom6): the player's sixth zoom (zm_knob)
	sts.l	pr,@-r15		! (this hook leaves through a jmp to 0x084D2210: keep the caller's pr)
	jsr	@r0
	nop
	lds.l	@r15+,pr
	tst	r0,r0
	bf	vh_swal
	mov	r4,r5			! ZOOMFIX: zm_knob may rewrite d (r6); stock re-derives d = r4 - r5
	sub	r6,r5
	mov	r6,r0
	tst	r0,r0			! V3rc3: a knob move on SEARCH with the keyboard up -> the 3000's
	bt	8f			! results view (keyboard hidden: vt_kbh, published +0x14 bit 25)
	mov.l	vh_ui,r1
	mov	#0x54,r0
	mov.l	@(r0,r1),r0
	mov.l	vh_kb2,r2
	mov.l	@r2,r2
	or	r0,r2
	tst	r2,r2
	bt	8f
	mov.l	vh_s0i,r1
	mov.w	@r1,r0
	extu.w	r0,r0
	cmp/eq	#0x25,r0
	bf	8f
	mov.l	vh_kbh,r1
	mov	#1,r0
	mov.l	r0,@r1
8:	mov	r6,r0
	cmp/pz	r0
	bt	3f
	neg	r0,r0
3:	mov	#VT_LJ,r1
	cmp/hs	r1,r0
	bf	vh_stock
	mov.l	vh_ui,r1
	mov.l	@r1,r0
	cmp/eq	#2,r0
	bf	vh_stock
	mov.l	@(12,r1),r2		! pop-up menu, keyboard (both flags as vt_hit)
	mov	#0x54,r0
	mov.l	@(r0,r1),r0
	or	r0,r2
	mov.l	vh_kb2,r0
	mov.l	@r0,r0
	or	r0,r2
	tst	r2,r2
	bf	vh_stock
	mov.l	vh_scr,r1
	mov.b	@r1,r0
	cmp/eq	#3,r0
	bt	4f
	cmp/eq	#4,r0
	bf	vh_stock
	mov.l	vh_sort,r1		! live side 1 slot 0's icon = the sort key
	mov.w	@r1,r0
	extu.w	r0,r0
	mov.w	vh_a1,r1
	sub	r1,r0
	mov	#2,r1
	cmp/hs	r1,r0
	bt	vh_stock
4:	mov.l	vh_lj,r1		! (V3rc3: big lists too -- the jump is a search now)
	mov	#1,r0
	cmp/pz	r6
	bt	5f
	mov	#-1,r0
5:	mov.l	@r1,r2			! a jump under way the same way: one letter more (at most 3
	tst	r2,r2			! pending: a fast spin walks the letters, as on the 3000)
	bt	6f
	mov.l	@(12,r1),r2
	cmp/eq	r0,r2
	bf	6f
	mov.l	@(24,r1),r0
	mov	#3,r2
	cmp/hs	r2,r0
	bt	vh_swal
	add	#1,r0
	bra	vh_swal
	mov.l	r0,@(24,r1)
6:	mov.l	r0,@(LJ_DIR,r1)		! direction
	mov	#0,r0
	mov.l	r0,@(LJ_PEND,r1)	! nothing pending
	mov.l	r0,@(LJ_PH,r1)		! start
	mov.l	r0,@(LJ_REQ,r1)
	mov	#1,r0
	mov.l	r0,@r1			! active
vh_swal:
	mov	r4,r5			! swallowed: d = 0
vh_stock:
	mov.l	vh_orig,r0
	jmp	@r0
	nop
	.p2align 1
vh_128:	.short	128
vh_256:	.short	256
vh_a1:	.short	0xA1
	.p2align 2
vh_orig: .long	0x084D2210
vh_ui:	.long	0x0B54336C
vh_kb2:	.long	0x0B545B64
vh_scr:	.long	0x0B53FB54
vh_sort: .long	0x0B5434EC + 0x132C + 0x14
vh_lj:	.long	vt_lj
vh_ghp:	.long	vt_ghp			! TOUCH
vh_gmd:	.long	0x0A35F3E0		! TOUCH: GRID ADJUST mode
vh_gmv:	.long	0x084E6638		! TOUCH: stock knob GRID move(delta)
vh_pend: .long	0x0B546724		! the UI task's pending knob count
vh_boot: .long	0x0A35DF3C		! MAIN boot state (1 = normal boot)
vh_s0i:	.long	0x0B53FBA4 + 0x14	! the model's side-0 slot 0 icon (0x25 = SEARCH)
vh_kbh:	.long	vt_kbh
vh_zm:	.long	zm_knob

! vl_cls: r1 = a live slot -> r0 = its title's first letter A..Z (a..z upper-cased; V3rc3: Latin-1
! accented letters folded onto their base letter), else 0. Uses r0, r2.
vl_cls:
	mov	#0x28,r0
	mov.w	@(r0,r1),r0
	tst	r0,r0
	bt	2f			! empty
	mov	r1,r2
	add	#0x2A,r2
	mov.w	@r2,r0
	extu.w	r0,r0
	mov	#-64,r2
	extu.b	r2,r2			! 0xC0
	cmp/hs	r2,r0
	bf	0f
	mov	#1,r2
	shll8	r2
	cmp/hs	r2,r0
	bt	2f
	and	#0x1F,r0		! 0xC0..0xFF -> 0..31 (lower case folded onto upper case)
	mov	r0,r2
	mova	vl_acc,r0
	mov.b	@(r0,r2),r0
	rts
	extu.b	r0,r0
0:	mov	#0x60,r2
	cmp/hi	r2,r0			! a..z -> A..Z
	bf	1f
	add	#-0x20,r0
1:	mov	#0x41,r2
	cmp/hs	r2,r0
	bf	2f
	mov	#0x5A,r2
	cmp/hi	r2,r0
	bt	2f
	rts
	nop
2:	rts
	mov	#0,r0
	.p2align 2
vl_acc:	.ascii	"AAAAAAACEEEEIIIIDNOOOOO\0OUUUUY\0S"

! vl_sig: r0 = a signature of the 8 live rows' texts (length + first three chars). Uses r0-r3.
vl_sig:
	mov.l	vl_s0,r1
	mov	#8,r3
	mov	#0,r0
1:	mov	#0x22,r2
	shll2	r2
	shll2	r2
	add	r2,r1			! + 0x220
	rotl	r0
	rotl	r0
	rotl	r0
	mov.l	@(0x28,r1),r2
	add	r2,r0
	mov.l	@(0x2C,r1),r2
	dt	r3
	bf.s	1b
	xor	r2,r0
	rts
	nop

! V3rc3: the letter jump as a search on the list itself. The stock list engine takes any knob delta
! in one step (the UI task's pending count 0x0B546724; the 21,851-track list settles a 600-row move
! in ~30-40 ms in the emu), so the jump probes the list by exact moves: vt_letter (panel task) asks
! for a move (LJ_REQ), vt_khook (UI task) adds it to the pending count. Each probe shows 8 rows; a
! binary search on "the row's letter differs from the one we leave" (forward), or "the row's letter
! is the cursor's" then "is the group before's" (backward: the start of the previous letter group)
! lands in ~log2(n / 8) probes (12 on 21,851 rows) instead of a page-by-page scan (40-75 s).
vt_letter:
	mov.l	vl_p,r7
	mov.l	@r7,r0
	tst	r0,r0
	bf	0f
	rts
	nop
0:	sts.l	pr,@-r15
	mov.l	r8,@-r15
	mov.l	r9,@-r15
	mov.l	r10,@-r15
	mov.l	r11,@-r15
	mov.l	vl_ui,r1		! still a plain list?
	mov.l	@r1,r0
	cmp/eq	#2,r0
	bf	vl_stop
	mov.l	@(12,r1),r0
	tst	r0,r0
	bf	vl_stop
	mov.l	vl_tick,r1
	mov.l	@r1,r8			! r8 = the 1 ms tick
	bsr	vl_sig
	nop
	mov	r0,r9			! r9 = the live rows' signature
	mov.l	@(LJ_PH,r7),r0
	tst	r0,r0
	bt	vl_start
	mov.l	@(LJ_REQ,r7),r0		! a move under way: taken by the UI task yet?
	tst	r0,r0
	bf	vl_out
	mov	#LJ_SIG,r0
	mov.l	@(r0,r7),r1
	cmp/eq	r1,r9
	bt	1f
	mov.l	r9,@(r0,r7)		! the rows changed: when
	mov	#LJ_STK,r0
	mov.l	r8,@(r0,r7)
1:	bsr	vt_idx
	nop
	mov.l	@(LJ_T,r7),r1
	cmp/eq	r1,r0
	bf	2f
	mov.l	@(LJ_PH,r7),r0		! there; the landing moves inside the page: done
	cmp/eq	#2,r0
	bt	vl_settled
	mov.l	@(LJ_SIG0,r7),r1	! a probe: its page read in and still for VL_STAB ms
	cmp/eq	r1,r9
	bt	2f
	mov	#LJ_STK,r0
	mov.l	@(r0,r7),r1
	mov	r8,r0
	sub	r1,r0
	mov	#VL_STAB,r1
	cmp/hs	r1,r0
	bt	vl_look
	bra	vl_out
	nop
2:	mov	#LJ_MTK,r0		! 400 ms after the move: go on with what is there
	mov.l	@(r0,r7),r1
	mov	r8,r0
	sub	r1,r0
	mov.w	vl_tmo,r1
	cmp/hs	r1,r0
	bf	vl_out
	mov.l	@(LJ_PH,r7),r0
	cmp/eq	#2,r0
	bf	vl_look
vl_settled:
	mov.l	@(LJ_PEND,r7),r0	! landed: another letter pending?
	tst	r0,r0
	bt	vl_stop
	add	#-1,r0
	mov.l	r0,@(LJ_PEND,r7)
vl_start:
	mov	r7,r1
	add	#LJ_NP,r1
	mov	#0,r0
	mov.l	r0,@r1			! probes made
	mov.l	r0,@(LJ_STG,r7)
	bsr	vt_idx
	nop
	mov	r0,r10			! r10 = the cursor's index
	mov.l	vl_cur,r1
	mov.l	@r1,r1
	add	#1,r1
	mov.w	vl_220,r2
	mulu.w	r2,r1
	sts	macl,r1
	mov.l	vl_s0,r2
	bsr	vl_cls
	add	r2,r1
	mov.l	r0,@(LJ_K,r7)		! the letter we leave
	mov.l	r0,@(LJ_HCLS,r7)
	mov.l	@(LJ_DIR,r7),r0
	cmp/pz	r0
	bf	3f
	mov	#0,r0			! forward: the first row after the cursor whose letter differs
	mov.l	r0,@(LJ_MODE,r7)
	add	#1,r10
	mov.l	r10,@(LJ_LO,r7)
	mov.l	vl_cnt,r1
	mov.l	@r1,r0
	bra	vl_look
	mov.l	r0,@(LJ_HI,r7)
3:	mov	#1,r0			! backward: the first row of the cursor's letter, then of the one before
	mov.l	r0,@(LJ_MODE,r7)
	mov	#0,r0
	mov.l	r0,@(LJ_LO,r7)
	mov.l	r10,@(LJ_HI,r7)
vl_look:				! the live page's rows narrow [lo, hi)
	mov.l	vl_first,r1
	mov.l	@r1,r10			! r10 = first visible index
	mov.l	vl_s0,r11		! r11 = slot (row - 1)
	mov	#0,r6			! r6 = row
4:	mov.w	vl_220,r0
	add	r0,r11
	mov	#0x28,r0
	mov.w	@(r0,r11),r0
	tst	r0,r0
	bt	6f			! past the list end
	mov	r10,r5
	add	r6,r5			! r5 = its index
	mov.l	@(LJ_LO,r7),r1
	cmp/ge	r1,r5
	bf	5f
	mov.l	@(LJ_HI,r7),r1
	cmp/ge	r1,r5
	bt	6f
	bsr	vl_cls
	mov	r11,r1
	mov	r0,r3			! r3 = its letter
	mov.l	@(LJ_K,r7),r1
	cmp/eq	r1,r3
	movt	r2
	mov.l	@(LJ_MODE,r7),r0
	cmp/eq	r0,r2
	bt	7f
	add	#1,r5			! pred false: lo = index + 1
	mov.l	r5,@(LJ_LO,r7)
	bra	5f
	mov.l	r3,@(LJ_LCLS,r7)
7:	mov.l	r5,@(LJ_HI,r7)		! pred true: hi = index (the rows after are true too)
	bra	6f
	mov.l	r3,@(LJ_HCLS,r7)
5:	add	#1,r6
	mov	#8,r0
	cmp/hs	r0,r6
	bf	4b
6:	mov.l	@(LJ_LO,r7),r4
	mov.l	@(LJ_HI,r7),r5
	cmp/ge	r5,r4
	bt	vl_found
	add	r5,r4			! probe the middle
	shar	r4
	bra	vl_mv
	mov	#1,r6
vl_found:				! r5 = the first row where pred holds
	mov.l	@(LJ_DIR,r7),r0
	cmp/pz	r0
	bf	8f
	mov.l	vl_cnt,r1		! forward past the last letter: stay
	mov.l	@r1,r0
	cmp/ge	r0,r5
	bt	vl_stop
	bra	vl_land
	nop
8:	mov.l	@(LJ_STG,r7),r0
	tst	r0,r0
	bf	vl_land
	tst	r5,r5			! the cursor's group starts the list: its top
	bt	vl_land
	mov	#1,r0			! now the group before: its letter = row lo - 1's
	mov.l	r0,@(LJ_STG,r7)
	mov.l	@(LJ_LCLS,r7),r0
	mov.l	r0,@(LJ_K,r7)
	mov.l	r0,@(LJ_HCLS,r7)
	add	#-1,r5
	mov.l	r5,@(LJ_HI,r7)
	mov	#0,r0
	bra	vl_look
	mov.l	r0,@(LJ_LO,r7)
vl_land:
	mov.l	@(LJ_HCLS,r7),r0	! the landing row's letter + its time -> published
	mov.l	r0,@(LJ_LET,r7)
	mov.l	r8,@(32,r7)
	mov	r5,r4
	mov	#2,r6
vl_mv:					! r4 = the index to move to, r6 = the phase
	mov	r7,r1
	add	#LJ_NP,r1
	mov.l	@r1,r0
	add	#1,r0
	mov.l	r0,@r1
	mov	#VL_MAXNP,r1
	cmp/hi	r1,r0
	bt	vl_stop
	mov.l	r6,@(LJ_PH,r7)
	mov.l	r4,@(LJ_T,r7)
	mov.l	r9,@(LJ_SIG0,r7)
	mov	#LJ_SIG,r0
	mov.l	r9,@(r0,r7)
	mov	#LJ_STK,r0
	mov.l	r8,@(r0,r7)
	mov	#LJ_MTK,r0
	mov.l	r8,@(r0,r7)
	bsr	vt_idx
	nop
	sub	r0,r4
	tst	r4,r4
	bf	9f
	mov	r6,r0			! already there (a landing on the cursor)
	cmp/eq	#2,r0
	bt	vl_settled
9:	bra	vl_out
	mov.l	r4,@(LJ_REQ,r7)
vl_stop:
	mov	#0,r0
	mov.l	r0,@(LJ_REQ,r7)
	mov.l	r0,@r7
vl_out:
	mov.l	@r15+,r11
	mov.l	@r15+,r10
	mov.l	@r15+,r9
	mov.l	@r15+,r8
	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
vl_p:	.long	vt_lj
vl_first: .long	0x0B5434F4
vl_cur:	.long	0x0B5433B8
vl_cnt:	.long	0x0B5434F0
vl_tick: .long	0x0B0C5258		! the 1 ms tick (touch_audio's)
vl_ui:	.long	0x0B54336C
vl_s0:	.long	0x0B5434EC
vt_lj:	.long	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0	! (LJ_*)
	.p2align 1
vl_220:	.short	0x220
vl_tmo:	.short	400
	.p2align 2

! V3e2 publish word, heartbeat +0xE8 (always 0 in every capture; the GUI's
! heartbeat copy ends at +0x1A7): 0xE << 28 | bits 16-23 the browse rows
! 1..8 whose track is loaded on ANOTHER deck (the CDJ-3000's green rows,
! re/V3E_DESIGN.md §2.6: a status record 0x0A371D3C + p * 0x124 of another
! player with a rekordbox track (+0x2A = 1) from the medium the list shows
! (touch_audio MED +0: player << 8 | slot, player 0 = this deck) and the row's
! id (the rowwave table's want[n])), bits 0-14 the row preview (touch_audio
! MED +64: bit 31 valid, bit 14 playing, bits 10-13 the row 1..8, bits 0-9 the
! column 0..599). Called from mm_publish (r3-r5 saved there); uses r0-r7.
	.p2align 2
v3e_pub:
	mov.l	r6,@-r15
	mov.l	r7,@-r15
	mov	#0,r2			! r2 = the word's payload
	mov.l	vp_tab,r6
	mov.l	@r6,r0
	mov.l	vp_rwv3,r1
	cmp/eq	r1,r0
	bf	8f			! no rowwave rows
	mov.l	vp_med,r7
	mov.l	@r7,r3			! the listed medium (canonical key)
	tst	r3,r3
	bt	8f
	mov.l	vp_own,r0
	mov.l	@r0,r1			! r1 = own player number
	mov	r3,r0
	shlr8	r0
	tst	r0,r0
	bf	1f
	mov	r1,r0			! player 0 = this deck
1:	shll8	r0
	extu.b	r3,r3
	or	r0,r3			! r3 = player << 8 | slot of the medium
	mov	#1,r4			! r4 = player p
2:	cmp/eq	r1,r4			! not this deck
	bt	6f
	mov.w	vp_124,r0
	mulu.w	r0,r4
	mov.l	vp_stat,r5
	sts	macl,r0
	add	r0,r5			! r5 = p's status record
	mov	#0x2A,r0
	mov.b	@(r0,r5),r0
	cmp/eq	#1,r0			! a rekordbox track
	bf	6f
	mov	#0x28,r0
	mov.b	@(r0,r5),r0
	extu.b	r0,r7
	shll8	r7
	mov	#0x29,r0
	mov.b	@(r0,r5),r0
	extu.b	r0,r0
	or	r0,r7
	cmp/eq	r3,r7			! from the listed medium
	bf	6f
	mov	#0x2C,r0
	mov.l	@(r0,r5),r5		! its id
	mov	#1,r7			! rows 1..8: want[n] at table + 0x10 + 4n
3:	mov	r7,r0
	shll2	r0
	add	#0x10,r0
	mov.l	@(r0,r6),r0
	cmp/eq	r5,r0
	bf	4f
	mov	#1,r0
	shld	r7,r0
	shlr	r0			! 1 << (n - 1)
	shll16	r0
	or	r0,r2
4:	add	#1,r7
	mov	#9,r0
	cmp/hs	r0,r7
	bf	3b
6:	add	#1,r4
	mov	#7,r0
	cmp/hs	r0,r4
	bf	2b
8:	mov.l	vp_med,r7		! the row preview (touch_audio MED+64: "PV" << 16 | payload)
	mov	#64,r0
	mov.l	@(r0,r7),r0
	mov	r0,r1
	shlr16	r1
	mov.w	vp_pv,r3
	extu.w	r3,r3
	cmp/eq	r3,r1
	bf	9f
	mov.w	vp_7fff,r1
	and	r1,r0
	or	r0,r2
9:	sts.l	pr,@-r15		! LCD BRIGHTNESS (bits 24-26) / JOG BRIGHTNESS (bits 27-28)
	mov	#0,r0
	bsr	vt_utv
	nop
	mov	r1,r0
	and	#7,r0
	shll8	r0
	shll16	r0
	or	r0,r2
	mov	#1,r0
	bsr	vt_utv
	nop
	lds.l	@r15+,pr
	mov	r1,r0
	and	#3,r0
	shll8	r0
	shll16	r0
	shll2	r0
	shll	r0
	or	r0,r2
	mov.l	vp_ute,r1		! bit 15: PLAYER No. offers 7 options (players 5/6 builds)
	mov.l	@(8,r1),r1
	tst	r1,r1
	bt	3f
	mov.l	@(8,r1),r0
	cmp/eq	#7,r0
	bf	3f
	mov	#1,r0
	shll16	r0
	shlr	r0			! 0x8000
	or	r0,r2
3:	mov.l	vp_magic,r0
	or	r2,r0
	mov.l	vp_word,r1
	mov.l	r0,@r1
	mov.l	@r15+,r7
	rts
	mov.l	@r15+,r6
	.p2align 1
vp_124:	.short	0x124
vp_7fff: .short	0x7FFF
vp_pv:	.short	0x5056
	.p2align 2
vp_tab:	.long	RAMB + 0x10000		! the rowwave table ("RWV3", want[n] at +0x10 + 4n)
vp_rwv3: .long	0x52575633
vp_med:	.long	RAMB + 0x1F700		! touch_audio MED: +0 the medium key, +64 the row preview
vp_own:	.long	0x0A35F680		! own player number
vp_stat: .long	LINK_TAB		! LINK status records (stride 0x124, by player)
vp_magic: .long	0xE0000000		! (bits 29-31 = 7)
vp_ute:	.long	vt_ute
vp_word: .long	0x0B568C9C + 0xE8

! ---------------------------------------------------------------------------
! V3e3: BEAT JUMP BEAT VALUE (re/V3E_DESIGN.md §6.1, re_deck): bj_v 0..6 = 1, 2, 4 .. 64 beats, set by the
! SHORT CUT tiles (va_bj, per session), used by the player's < / > tiles (stock zones 5 / 6, their
! handlers pointed here by place_modsmenu): the stock beat-jump request 0x084E19C0(0, 2 * bj_v + dir, 1)
! (codes 0..13; the stock caps 9 -> 13 are poked by place_modsmenu). Returns 1 as the stock handlers.
	.p2align 1
	.global	vt_bjl
vt_bjl:	bra	1f
	mov	#0,r5
	.global	vt_bjr
vt_bjr:	mov	#1,r5
1:	sts.l	pr,@-r15
	mov.l	vb_v,r1
	mov.l	@r1,r0
	shll	r0
	add	r0,r5
	mov	#0,r4
	mov.l	vb_req,r0
	jsr	@r0
	mov	#1,r6
	lds.l	@r15+,pr
	rts
	mov	#1,r0
va_bj:	add	#-1,r4			! a SHORT CUT tile 1..7 -> bj_v 0..6
	mov.l	vb_v,r1
	bra	va_out
	mov.l	r4,@r1
	.p2align 2
vb_v:	.long	bj_v
vb_req:	.long	0x084E19C0
	.global	bj_v
bj_v:	.long	0			! 1 beat (stock)

! V3e3 publish word, heartbeat +0x14 (zero in every capture, only the GUI's bulk copy touches it):
! bits 0-1 SCREEN MODE (V3rc4: 0 SMOOTH, 1 FAST, 2 STEADY; in both pages);
! bits 29-31 = 5 (magic), bit 28 = 0 (page 0); bits 2-4 bj_v + 1, bit 5 REV (the DIRECTION lever word
! 0x0B54CB14 != 0: 1 at REV, 0 at FWD -- checked on deck 3 2026-11-17), bit 6 jog mode VINYL (0x0B058C00 = 1),
! bit 7 valid, bits 16-19 the listed medium's rekordbox background colour (0x0A35F894 + p * 0x414 +
! slot * 0xA8; touch_audio MED +0 = player << 8 | slot, 0 = none -> the own USB). Uses r0-r2.
	.ifdef	KEYSHIFT
! ks_pub: heartbeat +0x14 page 1 (bit 28; v3e_pub2 writes it in every other 64-ms slot of the ms
! tick): bit 0 KEY SHIFT ON, bits 1-5 semitones + 12, bit 6 panel open, bit 7 REKORDBOX BUTTON =
! KEY SHIFT, bit 15 valid. Uses r0-r2.
ks_pub:
	sts.l	pr,@-r15		! V4n: KEY SYNC's follow / end checks (mods/keyshift ksy_tick, KSB + 84)
	mov.l	kpy_b,r0
	add	#84,r0
	jsr	@r0
	nop
	mov.l	kpy_klr,r0		! V4n36 trace: the kill switches shown while TEST LOG is not OFF
	jsr	@r0
	nop
	lds.l	@r15+,pr
	mov.l	kpy_b,r1
	mov.l	@(20,r1),r2
	mov.l	@(4,r1),r0
	tst	r0,r0
	bt	1f
	mov	#0x40,r0
	or	r0,r2
1:	mov.l	@r1,r0
	tst	r0,r0
	bt	2f
	mov	#0x40,r0
	shll	r0
	or	r0,r2
2:	mov.l	kpy_e,r1
	mov.l	@(4,r1),r0
	add	#12,r0
	and	#31,r0
	shll	r0
	or	r0,r2
	mov.l	kpy_b,r1		! V4n: bit 8 KEY SYNC on, bit 9 a refusal (the K.SYNC box flashes)
	mov.l	@(48,r1),r0
	tst	r0,r0
	bt	3f
	mov	#1,r0
	shll8	r0
	or	r0,r2
3:	mov	#64,r0
	mov.l	@(r0,r1),r0
	mov.l	kpy_t,r1
	mov.l	@r1,r1
	sub	r1,r0
	cmp/pl	r0
	bf	4f
	mov	#2,r0
	shll8	r0
	or	r0,r2
4:	mov.l	kpy_bn,r1		! V4n27b: bit 12 BEAT NUMBERS OFF,
	mov.l	@r1,r0			! bit 13 GRID ADJUST OFF (set = OFF: an absent item reads ON)
	tst	r0,r0
	bf	5f
	mov	#16,r0
	shll8	r0			! 0x1000
	or	r0,r2
5:	mov.l	@(4,r1),r0		! ga_v = bn_v + 4
	tst	r0,r0
	bf	6f
	mov	#32,r0
	shll8	r0			! 0x2000
	or	r0,r2
6:
	.ifdef	TESTLOG
	mov.l	kpy_b,r1		! V4n: bits 10-11 TEST LOG + 1 (0 = no such item: the GUI writes as before)
	mov	#68,r0
	mov.l	@(r0,r1),r0
	add	#1,r0
	and	#3,r0
	shll8	r0
	shll2	r0
	or	r0,r2
	.endif
	sts.l	pr,@-r15		! V4n32: bit 14 HOT CUE COLOR OFF, bits 16-20 own number / media (v32_pub)
	mov.l	kpy_v32,r0
	jsr	@r0
	nop
	lds.l	@r15+,pr
	mov	#1,r0
	shll16	r0
	shlr	r0			! bit 15
	or	r0,r2
	mov.l	kpy_m,r0
	or	r2,r0
	mov.l	kpy_w,r1
	rts
	mov.l	r0,@r1
	.p2align 2
kpy_b:	.long	KSB
kpy_e:	.long	0x08122800
kpy_m:	.long	0xB0000000
kpy_w:	.long	0x0B568C9C + 0x14
kpy_t:	.long	0x0B0C5258
kpy_bn:	.long	bn_v
kpy_v32: .long	v32_pub
kpy_klr: .long	kl_reveal
	.endif
v3e_pub2:
	.ifdef	KEYSHIFT
	mov.l	vq_tick,r1		! V4k: page 1 (KEY SHIFT) in the odd 64-ms slots
	mov.l	@r1,r0
	tst	#64,r0
	bf	ks_pub
	.endif
	mov.l	vq_bj,r1
	mov.l	@r1,r2
	add	#1,r2
	shll2	r2			! bits 2-4
	mov.l	vq_pv,r1		! V3rc4: SCREEN MODE (0 SMOOTH, 1 FAST, 2 STEADY) in bits 0-1
	mov.l	@r1,r0
	and	#3,r0
	or	r0,r2
	mov.l	vq_rev,r1
	mov.l	@r1,r0
	tst	r0,r0
	bt	1f			! DISPFIX: REV when the lever word is NOT 0 (deck 3 lever test 2026-11-17: FWD = 0, REV = 1)
	mov	#0x20,r0
	or	r0,r2
1:	mov.l	vq_jog,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	2f
	mov	#0x40,r0
	or	r0,r2
2:	mov	#0x40,r0
	shll	r0
	or	r0,r2			! valid
	mov.l	vq_kbh,r1		! V3rc3: bit 25 = SEARCH's keyboard hidden
	mov.l	@r1,r0
	tst	r0,r0
	bt	2f
	mov	#2,r0
	shll16	r0
	shll8	r0
	or	r0,r2
2:
	mov.l	vq_med,r1
	mov.l	@r1,r0
	extu.w	r0,r0
	tst	r0,r0
	bf	3f
	mov	#3,r0			! none: the own USB
3:	mov	r0,r1
	shlr8	r1			! r1 = player (0 = this deck)
	mov	#7,r0
	cmp/hs	r0,r1
	bt	5f
	mov.w	vq_414,r0
	mulu.w	r0,r1
	sts	macl,r1
	mov.l	vq_med,r0
	mov.l	@r0,r0
	extu.b	r0,r0
	tst	r0,r0
	bf	4f
	mov	#3,r0
4:	mov.l	r2,@-r15
	mov	#0x54,r2
	shll	r2			! 0xA8
	mulu.w	r2,r0
	mov.l	@r15+,r2
	sts	macl,r0
	add	r0,r1
	mov.l	vq_col,r0
	add	r1,r0
	mov.b	@r0,r0
	and	#15,r0
	shll16	r0
	or	r0,r2
5:	mov.l	vq_mst,r1		! V4a3: the master is a CDJ-3000 whose status packet carried a valid key
	mov.w	vq_oa4,r0		! (ks3k's table RAMB+0x1E800 + player * 8): priority over the DB routes
	mov.l	@(r0,r1),r1		! the master's player number (another deck), else 0
	mov	#7,r0
	cmp/hs	r0,r1
	bt	vq_oldmk
	tst	r1,r1
	bt	vq_oldmk
	shll2	r1
	shll	r1
	mov.l	vq_k3t,r0
	add	r0,r1
	mov.l	@(4,r1),r0
	mov	r0,r3
	shlr16	r3
	mov.w	vq_k3m,r4
	cmp/eq	r4,r3
	bf	vq_oldmk
	and	#31,r0
	shll8	r0
	or	r0,r2
	bra	6f
	nop
vq_oldmk:	mov.l	vq_mk,r1		! V3rc1: bits 8-12 the LINK master's key (touch_audio MED+68 = "MK" << 16 |
	mov.l	@r1,r0			! key_code, +72 its rbid, +76 its w8send target), while w8send still
	mov	r0,r3			! names that target (r3-r5: saved by mm_publish)
	shlr16	r3
	mov.w	vq_mkm,r4
	cmp/eq	r4,r3
	bf	6f
	mov.l	vq_w8,r4
	mov.l	@(4,r1),r3
	mov.l	@(0x28,r4),r5		! w8send's RBID
	cmp/eq	r3,r5
	bf	6f
	mov.l	@(8,r1),r3
	mov.l	@(0x24,r4),r5		! w8send's KEY
	cmp/eq	r3,r5
	bf	6f
	and	#31,r0
	shll8	r0
	or	r0,r2
6:	mov	r2,r0			! V3rc2 route B: no key from our own index -- the one w8cap fetched over
	shlr8	r0			! the DB client (W8S +0x78 "MK" | code, +0x7C its rbid = w8send's RBID)
	tst	#31,r0
	bf	8f
	mov.l	vq_w8,r1
	mov	#0x78,r0
	mov.l	@(r0,r1),r3
	mov	#0x7C,r0
	mov.l	@(r0,r1),r4
	mov.l	@(0x28,r1),r5
	cmp/eq	r4,r5
	bf	8f
	mov	r3,r0
	shlr16	r0
	mov.w	vq_mkm,r4
	cmp/eq	r4,r0
	bf	8f
	mov	r3,r0
	and	#31,r0
	shll8	r0
	or	r0,r2
8:
	.ifdef	KEYSHIFT
	mov	r2,r0			! V4n33: still no master key -- w8cap's DB key cache (mods/keyshift kc_mst,
	shlr8	r0			! KSB + 104: the master's loaded track by tid + rbid, any NXS2 / dbserver)
	tst	#31,r0
	bf	vq_kcx
	sts.l	pr,@-r15
	mov.l	vq_kcm,r0
	jsr	@r0
	nop
	lds.l	@r15+,pr
	and	#31,r0
	shll8	r0
	or	r0,r2
vq_kcx:
	.endif
	mov.l	vq_lj,r1		! V3rc2: bits 20-24 the letter jump's target (1..26 = A..Z) for 1.5 s
	mov.l	@(28,r1),r0		! after it was found
	tst	r0,r0
	bt	7f
	mov.l	@(32,r1),r3
	mov.l	vq_tick,r4
	mov.l	@r4,r4
	sub	r3,r4
	mov.w	vq_1500,r3
	cmp/hs	r3,r4
	bt	7f
	add	#-0x40,r0
	shll16	r0
	shll2	r0
	shll2	r0
	or	r0,r2
7:	mov.l	vq_dg,r1		! V4n6: a list row press pending (touch vt_dg state 1, a tap not yet
	mov.l	@r1,r0			! released or dragged): bit 26 + its row 0..7 in bits 13-15 (the
	cmp/eq	#1,r0			! 3000's pressed-row feedback)
	bf	9f
	mov.l	@(8,r1),r0		! y / 2 at the press -> row (y / 2 - 45) / 20
	add	#-45,r0
	cmp/pz	r0
	bf	9f
	mov	#0,r3
	mov	#20,r1
5:	cmp/hs	r1,r0
	bf	6f
	sub	r1,r0
	bra	5b
	add	#1,r3
6:	mov	#8,r0
	cmp/hs	r0,r3
	bt	9f
	shll8	r3
	shll2	r3
	shll2	r3
	shll	r3			! << 13
	or	r3,r2
	mov	#1,r0
	shll16	r0
	shll8	r0
	shll2	r0			! bit 26
	or	r0,r2
9:	mov.l	vq_pvk,r1		! TOUCH (V4n41): bit 27 = the PREVIEW tile OFF (kill_v +24 = 0)
	mov.l	@r1,r0
	tst	r0,r0
	bf	10f
	mov	#8,r0
	shll16	r0
	shll8	r0			! 0x08000000
	or	r0,r2
10:	mov.l	vq_magic,r0
	or	r2,r0
	mov.l	vq_word,r1
	rts
	mov.l	r0,@r1
	.p2align 1
vq_414:	.short	0x414
vq_mkm:	.short	0x4D4B
vq_k3m:	.short	0x4B33
vq_oa4:	.short	0xA4
vq_1500: .short	1500
	.p2align 2
vq_lj:	.long	vt_lj
vq_dg:	.long	vt_dg			! V4n6
vq_pvk:	.long	kill_v + 24		! TOUCH
vq_pv:	.long	present_v		! V3rc4: SCREEN MODE
vq_kbh:	.long	vt_kbh
vq_tick: .long	0x0B0C5258
vq_bj:	.long	bj_v
vq_rev:	.long	0x0B54CB14
vq_jog:	.long	0x0B058C00
vq_med:	.long	RAMB + 0x1F700
vq_col:	.long	0x0A35F894
vq_magic: .long	0xA0000000
vq_word: .long	0x0B568C9C + 0x14
vq_mk:	.long	RAMB + 0x1F700 + 68
vq_w8:	.long	RAMB + 0x1E000
vq_mst:	.long	0x0B568C9C
vq_k3t:	.long	RAMB + 0x1E800
	.ifdef	KEYSHIFT
vq_kcm:	.long	KSB + 104		! V4n33 kc_mst
	.endif
	.endif
	.ifdef	KEYSHIFT
! V4k (mods/keyshift): KEY SHIFT OFF / ON (the engine on: the DSP path through the pitch
! shifter; the header tile and the rekordbox key work the panel) and REKORDBOX BUTTON
! REKORDBOX / KEY SHIFT, both saved in the HISTORY tail (bits 4 / 5). Their words live in
! mods/keyshift's block (KSB +20 / +0).
	.global	entries3
entries3:
	.long	L_KS, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_RBB, OPTSRB, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_KSYB, OPTS, 2, -1, -1, 1	! V4n24: KEY SYNC BUTTON (KSB+72, HISTORY tail bit 6)
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	! V4n27b: BEAT NUMBERS / GRID ADJUST, OFF / ON, not saved (ON at boot); v4.1 normal features (RELAUDIT)
	.long	L_BN, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_GA, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	! V4n36: KEY FORMAT CLASSIC / ALPHANUMERIC (the CDJ-3000's key display format setting; kf_v, HISTORY tail bit 5 = CLASSIC,
	! published in +0x14 page 1 bit 27 = CLASSIC: the display draws every key in this notation)
	.long	L_KF, OPTSKF, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.ifdef	TESTLOG
	.long	L_TL, OPTSTL, 3, -1, -1, 1	! V4n: TEST LOG (TEST builds; KSB+68, not saved)
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
OPTSTL:	.long	L_OFF, L_USB, L_RED
L_TL:	.short	'T', 'E', 'S', 'T', ' ', 'L', 'O', 'G', 0
L_USB:	.short	'U', 'S', 'B', 0
L_RED:	.short	'R', 'E', 'D', 0
	.p2align 2
	.endif
OPTSRB:	.long	L_RBX, L_KS
L_KS:	.short	'K', 'E', 'Y', ' ', 'S', 'H', 'I', 'F', 'T', 0
L_RBB:	.short	'R', 'E', 'K', 'O', 'R', 'D', 'B', 'O', 'X', ' ', 'B', 'U', 'T', 'T', 'O', 'N', 0
L_RBX:	.short	'R', 'E', 'K', 'O', 'R', 'D', 'B', 'O', 'X', 0
L_KSYB:	.short	'K', 'E', 'Y', ' ', 'S', 'Y', 'N', 'C', ' ', 'B', 'U', 'T', 'T', 'O', 'N', 0
L_BN:	.short	'B', 'E', 'A', 'T', ' ', 'N', 'U', 'M', 'B', 'E', 'R', 'S', 0	! V4n27b
L_GA:	.short	'G', 'R', 'I', 'D', ' ', 'A', 'D', 'J', 'U', 'S', 'T', 0		! V4n27b
L_KF:	.short	'K', 'E', 'Y', ' ', 'F', 'O', 'R', 'M', 'A', 'T', 0	! V4n36
L_CLS:	.short	'C', 'L', 'A', 'S', 'S', 'I', 'C', 0
L_ALN:	.short	'A', 'L', 'P', 'H', 'A', 'N', 'U', 'M', 'E', 'R', 'I', 'C', 0
	.p2align 2
OPTSKF:	.long	L_CLS, L_ALN
bn_v:	.long	1			! V4n27b: BEAT NUMBERS (0 OFF, 1 ON), not saved
ga_v:	.long	1			! V4n27b: GRID ADJUST (0 OFF = offset ignored, 1 ON), not saved
! ks_sync: the engine's on word = KEY SHIFT; OFF -> shift 0, panel closed; the generation bumped
! (the engine re-sends its parameter). Uses r0, r2, r3.
ks_sync:
	mov.l	ksy_b,r2
	mov.l	@(20,r2),r0
	mov.l	ksy_e,r3
	mov.l	r0,@r3
	tst	r0,r0
	bf	1f
	mov	#0,r0
	mov.l	r0,@(4,r3)
	mov.l	r0,@(4,r2)
	mov.l	r0,@(48,r2)		! V4n: and KEY SYNC
1:	mov.l	@(16,r3),r0
	add	#1,r0
	and	#127,r0
	rts
	mov.l	r0,@(16,r3)
	.p2align 2
ksy_b:	.long	KSB
ksy_e:	.long	0x08122800
	.endif
	.ifdef	KEYSHIFT
! V4k: action 12, arg 1 the header tile (panel open / closed), 2 -1, 3 +1, 4 RESET, 5 the panel row's
! rest (nothing), 6 SHORT CUT rekordbox tile (a stock rekordbox-key press, mods/keyshift rbk_set)
va_ks:	mov.l	vt_ksb,r1
	mov.l	vt_kse,r2
	mov	r4,r0
	cmp/eq	#1,r0
	bf	1f
	mov.l	@(4,r1),r0
	tst	r0,r0
	movt	r0
	bra	9f
	mov.l	r0,@(4,r1)
1:	cmp/eq	#7,r0		! V4n: K.SYNC tile -> mods/keyshift ksy_tap (KSB + 80)
	bf	0f
	mov	r1,r0
	add	#80,r0
	jsr	@r0
	nop
	bra	9f
	nop
0:	cmp/eq	#6,r0
	bf	2f
	mov.l	vt_ktk,r3
	mov.l	@r3,r3
	add	#120,r3
	bra	9f
	mov.l	r3,@(8,r1)
2:	mov.l	@(4,r2),r3
	cmp/eq	#4,r0
	bt	6f
	cmp/eq	#2,r0
	bt	3f
	cmp/eq	#3,r0
	bf	8f
	mov	#11,r0
	cmp/ge	r0,r3			! +1 up to +11 (owner 2026-11-22: at +12 the ks4mt FIFO has no margin; down stays -12)
	bt	8f
	bra	7f
	add	#1,r3
3:	mov	#-12,r0
	cmp/gt	r0,r3			! -1 down to -12
	bf	8f
	bra	7f
	add	#-1,r3
6:	mov	#0,r3
7:	mov.l	r3,@(4,r2)
	mov	#0,r0			! V4n: a manual -1 / +1 / RESET ends KEY SYNC (the shift stays)
	mov.l	r0,@(48,r1)
8:
9:	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
vt_ksb:	.long	KSB
vt_kse:	.long	0x08122800
vt_ktk:	.long	0x0B0C5258
	.endif
! V4n touch drag + fling (the CDJ-3000's lists: juce Viewport DragToScrollListener + AnimatedPosition
! ContinuousWithMomentum). vt_dg: +0 state (0 none, 1 a row press pending, 2 dragging, 3 the tap's replay),
! +4 x / 4, +8 y / 2 at the press, +12 the cursor index then, +16 / +20 the last sample (y / 2, ms tick),
! +24 / +28 the one before, +32 the drag's goal index.
	.p2align 2
vt_dg:	.long	0, 0, 0, 0, 0, 0, 0, 0, 0

! vt_drag (every panel frame while vt_dg is active; r4 pressed, r6 raw y). Pressed: past 8 px the list
! follows the finger (a row a 40 px: a closed-loop seek to the press's index + rows moved); samples
! every >= 20 ms for the speed. Released: no move -> the tap (va_rows0 at the press's place); a drag
! released while still moving (last sample < 80 ms old) -> momentum, rows = speed x ~250 ms (<= 40)
! further. Uses r0-r7.
vt_drag:
	sts.l	pr,@-r15
	mov.l	vd_dgp,r7
	mov	r6,r3
	shlr	r3			! r3 = y / 2
	mov.l	vd_tk,r1
	mov.l	@r1,r2			! r2 = now
	tst	r4,r4
	bt	vd_up
	mov.l	@(20,r7),r0		! a sample every >= 20 ms
	mov	r2,r1
	sub	r0,r1
	mov	#20,r0
	cmp/hs	r0,r1
	bf	1f
	mov.l	@(16,r7),r0
	mov.l	r0,@(24,r7)
	mov.l	@(20,r7),r0
	mov.l	r0,@(28,r7)
	mov.l	r3,@(16,r7)
	mov.l	r2,@(20,r7)
1:	mov.l	@(8,r7),r5
	sub	r3,r5			! r5 = rows' dy (finger up = forward)
	mov.l	@r7,r0
	cmp/eq	#2,r0
	bt	2f
	mov	r5,r0
	cmp/pz	r0
	bt	3f
	neg	r0,r0
3:	mov	#4,r1			! < 8 px: still a tap
	cmp/hs	r1,r0
	bf	vd_out
	mov.l	@(4,r7),r0		! R21 parity (d): a press on a rowwave row's PREVIEW column (x < 212) never
	mov	#53,r1			! scrolls the list -- the 3000's preview waveform keeps the finger: the drag
	cmp/hs	r1,r0			! is touch_audio's seek (row_touch follows the finger's row, so a scroll
	bt	8f			! under it would switch the previewed track); the lift is still the tap
	mov.l	@(8,r7),r0		! row k = (y / 2 at the press - 45) / 20
	add	#-45,r0
	cmp/pz	r0
	bf	8f
	mov	#0,r2
	mov	#20,r1
1:	cmp/hs	r1,r0
	bf	4f
	sub	r1,r0
	bra	1b
	add	#1,r2
4:	mov	#8,r0
	cmp/hs	r0,r2
	bt	8f
	add	#1,r2			! slot k + 1
	mov.w	vd_220,r0
	mulu.w	r0,r2
	sts	macl,r2
	mov.l	vd_slots,r1
	add	r1,r2
	mov.l	@(0x1C,r2),r0		! a rowwave row (its cell) -> stays a tap
	cmp/eq	#1,r0
	bt	vd_out
8:	mov	#2,r0
	mov.l	r0,@r7
2:	mov	#10,r0			! V4n5: to the nearest row (half a row = 10 units), not toward 0
	cmp/pz	r5
	bt	3f
	neg	r0,r0
3:	bsr	div20
	add	r0,r5
	mov.l	@(12,r7),r4
	add	r0,r4			! the goal
	mov.l	@(32,r7),r0
	cmp/eq	r4,r0
	bt	vd_out
	mov.l	r4,@(32,r7)
	mov.l	vd_sk,r0
	jsr	@r0
	nop
	bra	vd_out
	nop
vd_up:	mov.l	@r7,r0
	cmp/eq	#1,r0
	bf	5f
	mov	#3,r0			! a tap: the row action now, at the press's place
	mov.l	r0,@r7
	mov.l	@(4,r7),r5
	bsr	vd_rows
	mov.l	@(8,r7),r6
	mov.l	vd_dgp,r7
	bra	6f
	nop
5:	mov.l	@(20,r7),r0		! momentum only when the finger was still moving
	mov	r2,r1
	sub	r0,r1
	mov	#80,r0
	cmp/hs	r0,r1
	bt	6f
	mov.l	@(24,r7),r5
	mov.l	@(16,r7),r0
	sub	r0,r5			! dy of the last sample interval (y / 2 units)
	mov.l	@(20,r7),r6
	mov.l	@(28,r7),r0
	sub	r0,r6			! its ms
	cmp/pl	r6
	bf	6f
	mov	#12,r0			! rows = dy * 12 / ms (~ speed x 250 ms / 40 px)
	mul.l	r0,r5
	sts	macl,r5
	mov	r5,r1
	cmp/pz	r1
	bt	7f
	neg	r1,r1
7:	mov	#0,r4			! r4 = |dy * 12| / ms, at most 40
8:	cmp/hs	r6,r1
	bf	9f
	sub	r6,r1
	mov	#40,r0
	cmp/hs	r0,r4
	bt	9f
	bra	8b
	add	#1,r4
9:	cmp/pz	r5
	bt	4f
	neg	r4,r4
4:	tst	r4,r4
	bt	6f
	mov.l	@(32,r7),r0
	add	r0,r4
	mov.l	vd_sk,r0
	jsr	@r0
	nop
	mov.l	vd_dgp,r7
6:	mov	#0,r0
	mov.l	r0,@r7
vd_out:	lds.l	@r15+,pr
	rts
	nop
vd_rows:
	sts.l	pr,@-r15		! va_rows0 returns through va_out (lds pr / rts)
	mov.l	vd_r0,r0
	jmp	@r0
	nop
	.p2align 2
vd_dgp:	.long	vt_dg
vd_tk:	.long	0x0B0C5258		! ms tick
vd_sk:	.long	vt_seek_to
vd_r0:	.long	va_rows0
vd_slots: .long	0x0B53FBA4		! R21 parity (d): the model's side-0 slot 0 (= vt_slots)
vd_220:	.short	0x220
	.p2align 2
! div20: r0 = r5 / 20, toward 0 (|r5| < 65536). Uses r0, r1.
div20:
	mov	r5,r0
	cmp/pz	r0
	bt	1f
	neg	r0,r0
1:	mov.w	d20m,r1
	mulu.w	r0,r1
	sts	macl,r0
	shlr16	r0
	shlr2	r0
	shlr2	r0
	cmp/pz	r5
	bt	2f
	neg	r0,r0
2:	rts
	nop
	.p2align 1
d20m:	.short	0xCCCD			! 52429 / 2^20 = 1 / 20


! V4n31a (#58): a SOURCE row k (r4, from vt_act's jump; v2.c source_screen: 64-px rows from y 66): the
! cursor to it, PUSH on the cursor row (opens that medium, as stock's own list). pr is on the stack
! (vt_act): leaves through va_out / va_key2.
va_src:
	! V4n32 (#58b): the rows as v2.c source_screen draws them -- in the LINK list (slot 1 a LINK medium,
	! icon 0x50..0x55) this deck's own SD / USB first (when mounted, v32_pub's media bytes), then the model's
	! rows (slots 1..8 with text); N capped at 8, pitch 64 (N <= 5) else 44 from y 66. An own row presses
	! the SD / USB key; a model row k goes on below (r6 = y / 2).
	mov	r6,r3
	add	r3,r3
	add	#-66,r3			! r3 = y - 66
	cmp/pz	r3
	bf	9f
	mov.l	vsr_slots,r1
	mov	#0,r5			! r5 = the model's rows
	mov.w	vsr_220,r2
1:	add	r2,r1
	mov	#0x28,r0
	mov.w	@(r0,r1),r0
	tst	r0,r0
	bt	2f
	add	#1,r5
	mov	#8,r0
	cmp/eq	r0,r5
	bf	1b
2:	mov	#0,r4			! r4 = 1: an own SD row
	mov	#0,r7			! r7 = own rows
	mov.l	vsr_ic1,r1
	mov.l	@r1,r0
	add	#-0x50,r0
	mov	#6,r1
	cmp/hs	r1,r0
	bt	3f			! not the LINK list
	mov.l	vsr_sdm,r1
	mov.b	@r1,r0
	tst	r0,r0
	bt	4f
	mov	#1,r4
	add	#1,r7
4:	mov.l	vsr_usbm,r1
	mov.b	@r1,r0
	tst	r0,r0
	bt	3f
	add	#1,r7
3:	mov	r5,r0
	add	r7,r0
	mov	#8,r1
	cmp/hi	r1,r0
	bf	5f
	mov	r1,r0
5:	mov	r0,r2			! r2 = N
	mov	#64,r1
	mov	#5,r0
	cmp/hi	r0,r2
	bf	6f
	mov	#44,r1			! r1 = the pitch
6:	mov	#0,r0
7:	cmp/hs	r1,r3
	bf	8f
	sub	r1,r3
	bra	7b
	add	#1,r0			! r0 = the row
8:	cmp/hs	r2,r0
	bt	9f			! below the last row
	cmp/hs	r7,r0
	bt	10f			! a model row
	tst	r0,r0
	bf	11f			! own row 1: USB
	tst	r4,r4
	bt	11f			! own row 0 without an SD row: USB
	mov.l	vsr_sdk,r2
	bra	12f
	nop
11:	mov.l	vsr_usbk,r2
12:	mov.l	vsr_key2,r0
	jmp	@r0
	nop
10:	sub	r7,r0
	mov	r0,r4			! r4 = the model row k
	mov.l	vsr_slots,r1
	mov.w	vsr_220,r2
	mov	r4,r3
	add	#1,r3
	mulu.w	r2,r3
	sts	macl,r3
	add	r1,r3			! r3 = row k's slot
	mov	#0x28,r0		! an empty row: nothing
	mov.w	@(r0,r3),r0
	tst	r0,r0
	bt	9f
	mov.l	vsr_vcur,r1
	mov.l	@r1,r0
	cmp/eq	r4,r0
	bt	8f
	mov.l	vsr_vfst,r1
	mov.l	@r1,r0
	add	r0,r4			! a seek to first + k
	mov.l	vsr_seek,r0
	jsr	@r0
	nop
9:	mov.l	vsr_out,r0
	jmp	@r0
	nop
8:	mov.l	vsr_push,r2
	mov.l	vsr_key2,r0
	jmp	@r0
	nop
	.p2align 1
vsr_220:	.short	0x220
	.p2align 2
vsr_slots: .long	0x0B53FBA4
vsr_vcur: .long	0x0B5433B8
vsr_vfst: .long	0x0B5434F4
vsr_push: .long	0x084E121E
vsr_seek: .long	vt_seek_to
vsr_out:	.long	va_out
vsr_key2: .long	va_key2
vsr_ic1: .long	0x0B53FBA4 + 0x220 + 0x14	! slot 1's icon (vt_srcip)
vsr_sdm: .long	0x0A35F894 + 2 * 0xA8 + 2	! own SD / USB mounted (v32_pub)
vsr_usbm: .long	0x0A35F894 + 3 * 0xA8 + 2
vsr_sdk: .long	0x084E1134			! the SD / USB key setters (vt_keys)
vsr_usbk: .long	0x084E1120

! V4n32 (#21, re/TANDA3_REPORT.md): the SLIP ghost. While SLIP is on (heartbeat +0xDC = 1) the engine pair
! 0x0994754C {pos150, pos150, ms, ms} runs on as the background (slip) position while the heartbeat's own
! +0x70 / +0x78 follow the real (looping / scratched) playhead [V emu V4n32: +8 ran 0x738B..0x9510 while
! +0x78 looped 0x74D3..0x6E97]. Published in heartbeat +0x18 (zero in every capture, not read by the stock
! display path we use): 0x53 << 24 | the slip ms (bits 0-22); left 0 when slip is off. Normal boot only.
! Called from mm_publish (r3-r5 saved there); uses r0-r2.
	.p2align 2
sl_pub:
	mov.l	sl_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	9f
	mov.l	sl_blk,r1
	mov.w	sl_odc,r0
	mov.l	@(r0,r1),r0
	cmp/eq	#1,r0
	bf	8f
	mov.l	sl_eng,r0
	mov.l	@r0,r0
	mov.l	sl_msk,r2
	and	r2,r0
	mov.l	sl_mag,r2
	or	r2,r0
	mov.l	r0,@(24,r1)
9:	rts
	nop
8:	mov.l	sl_kv,r2		! V4n36 trace: no slip -> +0x18 = 0x4B ('K') << 24 | the display's kill switches:
	mov.l	@(8,r2),r0		! bit 0 MASTER WAVEFORM ON, bit 1 HW BAND LAYER ON (the GUI keeps the last
	tst	r0,r0			! one it saw while SLIP uses the word)
	movt	r0
	xor	#1,r0
	mov.l	@(12,r2),r2
	tst	r2,r2
	bt	7f
	or	#2,r0
7:	mov.l	sl_wh,r2		! HALFBLUE: bit 2 WAVEFORM HALF (unset by default: the word stays as before)
	mov.l	@r2,r2
	tst	r2,r2
	bt	6f
	or	#4,r0
6:	mov.l	sl_tsk,r2		! TOUCH (V4n41): bit 3 = a GRID ADJUST tile is driving stock's GRID ADJUST
	mov.l	@r2,r3			! pop-up (vt_sk active, PUSH-then-BACK 2 or its close check, mode 3): the
	tst	r3,r3			! display does not draw that pop-up meanwhile (no menu flash on a tile tap)
	bt	5f
	mov.l	@(20,r2),r3
	mov.l	@(24,r2),r2
	add	#-3,r3
	tst	r3,r3
	bt	4f
	add	#-2,r2
	tst	r2,r2
	bf	5f
4:	or	#8,r0
5:	mov.l	sl_lo,r2		! LINKLAT (v4.2): bits 4-7 = LINK OFFSET option + 1 (lo_v, 0..14)
	mov.l	@r2,r2
	add	#1,r2
	mov	#15,r3
	and	r3,r2
	shll2	r2
	shll2	r2
	or	r2,r0
	mov.l	sl_tick,r2		! LINKLAT #2: bits 17-23 = MAIN's 1-ms tick & 127 at this copy (the display
	mov.l	@r2,r2			! ages each heartbeat sample from it)
	mov	#127,r3
	and	r3,r2
	shll16	r2
	shll	r2
	or	r2,r0
	.ifdef	KEYSHIFT
	mov.l	sl_ksc,r2		! KSAMT (V4n43): bits 8-15 the KEY SYNC cents (ownks +40, signed byte), bit 16 valid
	mov.l	@(40,r2),r2
	extu.b	r2,r2
	shll8	r2
	or	r2,r0
	mov	#1,r2
	shll16	r2
	or	r2,r0
	.endif
	mov.l	sl_kmg,r2
	or	r2,r0
	rts
	mov.l	r0,@(24,r1)
	.p2align 1
sl_odc:	.short	0xDC
	.p2align 2
sl_boot: .long	0x0A35DF3C		! MAIN boot state (1 = normal boot)
sl_blk:	.long	0x0B568C9C
sl_eng:	.long	0x09947554		! the engine's position pair: +8 ms (the slip shadow while SLIP is on)
sl_msk:	.long	0x007FFFFF
sl_mag:	.long	0x53000000
sl_kv:	.long	kill_v			! V4n36 trace
sl_tsk:	.long	vt_sk			! TOUCH
sl_kmg:	.long	0x4B000000
sl_tick: .long	0x0B0C5258		! LINKLAT: MAIN's 1-ms tick
sl_lo:	.long	lo_v			! LINKLAT: LINK OFFSET
	.ifdef	KEYSHIFT
sl_ksc:	.long	0x08122800		! KSAMT: ownks state (+40 KEY SYNC cents)
	.endif
sl_wh:	.long	wh_v			! HALFBLUE

! V4n32: ks_pub's extra bits (heartbeat +0x14 page 1), r2 in / out, uses r0-r3:
!  bit 14   (#50) HOT CUE COLOR OFF -- the stock UTILITY item (setter 0x083FC55A / getter 0x083FC56E, word
!           0x0A35F704: 0 OFF, 1 ON; options at 0x10DE13A8). Set = OFF (an older MAIN reads ON).
!  bits 16-18 (#6) this deck's player number as MAIN keeps it (0x0A35F680, 1..6; players 5/6 builds: the
!           heartbeat's +0x5C may carry 0xFF there), 0 = none
!  bits 19 / 20 (#58b) this deck's own SD / USB mounted: the own (player 0) medium records 0x0A35F894 +
!           slot * 0xA8, byte +2 (1 = mounted [V emu: USB 1, empty SD 0])
	.p2align 2
v32_pub:
	mov.l	v32_hcc,r1
	mov.l	@r1,r0
	tst	r0,r0
	bf	1f
	mov	#0x40,r0
	shll8	r0
	or	r0,r2
1:	mov.l	v32_own,r1
	mov.l	@r1,r3
	mov	r3,r0
	add	#-1,r0
	mov	#6,r1
	cmp/hs	r1,r0
	bt	2f
	mov	r3,r0
	shll16	r0
	or	r0,r2
2:	mov.l	v32_sd,r1
	mov.b	@r1,r0
	tst	r0,r0
	bt	3f
	mov	#8,r0
	shll16	r0
	or	r0,r2
3:	mov.l	v32_usb,r1
	mov.b	@r1,r0
	tst	r0,r0
	bt	4f
	mov	#16,r0
	shll16	r0
	or	r0,r2
4:	mov.l	v32_z6,r1		! bit 21: the sixth zoom (zm_knob)
	mov.l	@r1,r0
	tst	r0,r0
	bt	5f
	mov	#32,r0
	shll16	r0
	or	r0,r2
5:	own_rec	r1, r0			! bits 22-24 / 25-26: the loaded track's source player / slot (OUR status
	mov	#0x28,r0		! record, ownstat.inc, +0x28 / +0x29; the SOURCE screen's "Loaded" tag)
	mov.b	@(r0,r1),r0
	and	#7,r0
	shll16	r0
	shll2	r0
	shll2	r0
	shll2	r0
	or	r0,r2
	mov	#0x29,r0
	mov.b	@(r0,r1),r0
	and	#3,r0
	shll16	r0
	shll8	r0
	shll	r0
	or	r0,r2
	mov.l	v32_kf,r1		! V4n36: bit 27 KEY FORMAT CLASSIC (set = CLASSIC: an older MAIN reads ALPHANUMERIC)
	mov.l	@r1,r0
	tst	r0,r0
	bf	6f
	mov	#8,r0
	shll16	r0
	shll8	r0			! 0x08000000
	or	r0,r2
6:	rts
	nop
	.p2align 2
v32_kf:	.long	kf_v
v32_z6:	.long	zm_v
v32_hcc: .long	0x0A35F704
v32_own: .long	0x0A35F680
v32_sd:	.long	0x0A35F894 + 2 * 0xA8 + 2
v32_usb: .long	0x0A35F894 + 3 * 0xA8 + 2

! V4n32 (#zoom6): the CDJ-3000's sixth (most zoomed-in) detail zoom, 0.5 entries / px (zoom fractions 2/1 ..
! 1/16). Stock's zoom key (live 0x0B569040, getter 0x084E662C / setter 0x084E6632; heartbeat +0xE0 copy) stays
! 0..4 -- the stock GUI renderer 0x1C009AB4 shifts by 4 - key -- and the sixth level is ours (zm_v), on the PLAYER
! screen (UI class 1, not GRID ADJUST mode 0x0A35F3E0). Published in +0x14 page 1 bit 21 (v32_pub); v2.c zkey().
! ZOOMFIX (V4n41z): one level per detent across 4 <-> 6. The key is stock's live word PLUS the knob count still
! pending in 0x0B546724 (the consumer 0x084D23BE runs in another task, so a quick second detent used to see the
! old key) -- not the heartbeat copy; and a poll's d may hold several detents (stock applies the whole d, clamped):
!   in  (d > 0): key + d > 4 (or an accelerated d > 2) -> zm_v = 1; d still goes to stock unless key is 4 already
!   out (d < 0): zm_v set -> cleared and one detent of d spent on it (d + 1 to stock, swallowed if 0; an
!                accelerated d < -2 goes whole); key < 4 with zm_v set (stale) -> cleared, d to stock
! Called from vt_khook (r6 = d, normal boot only): r0 = 1 swallow, else r6 = the d for stock. Uses r0-r3.
	.p2align 2
zm_knob:
	tst	r6,r6
	bt	9f			! no move (the poll runs every UI tick)
	mov.l	zm_ui,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	9f			! not the player
	mov.l	zm_grid,r1
	mov.l	@r1,r0
	tst	r0,r0
	bf	9f			! GRID ADJUST: the knob moves the grid
	mov.l	zm_key,r1
	mov.l	@r1,r3
	mov.l	zm_pend,r1
	mov.l	@r1,r0
	add	r0,r3			! r3 = the key once stock has taken what is pending
	mov.l	zm_vp,r2
	mov	#4,r1
	cmp/pl	r6
	bf	5f
	mov	#2,r0			! in
	cmp/gt	r0,r6
	bt	2f			! accelerated (stock x5): to the end
	mov	r3,r0
	add	r6,r0
	cmp/gt	r1,r0
	bt	2f			! past stock's 4: the sixth level
	mov	#0,r0			! below 4 (any zm_v is stale)
	bra	9f
	mov.l	r0,@r2
2:	mov	#1,r0
	mov.l	r0,@r2
	cmp/ge	r1,r3
	bf	9f			! stock climbs to 4 with this d
	rts				! at 4 already: swallowed
	mov	#1,r0
5:	mov.l	@r2,r0			! out
	tst	r0,r0
	bt	9f			! no sixth level: stock's
	mov	#0,r0
	mov.l	r0,@r2
	cmp/ge	r1,r3
	bf	9f			! stale (key below 4): d to stock
	mov	#-2,r0
	cmp/ge	r0,r6
	bf	9f			! accelerated: whole d to stock
	add	#1,r6			! one detent spent leaving the sixth level
	tst	r6,r6
	bf	9f
	rts
	mov	#1,r0
9:	rts
	mov	#0,r0
	.p2align 2
zm_ui:	.long	0x0B54336C		! MAIN UI state: +0 class (1 player)
zm_grid: .long	0x0A35F3E0		! GRID ADJUST mode (setter 0x083FBA5C / getter 0x083FBA68)
zm_key:	.long	0x0B569040		! stock's live zoom key 0..4 (0x0B569038 +8; the heartbeat +0xE0 copies it)
zm_pend: .long	0x0B546724		! the UI task's pending knob count (0x084D2210 adds, 0x084D23BE takes)
zm_vp:	.long	zm_v
zm_v:	.long	0			! 1 = the sixth zoom
	.global	kf_v
kf_v:	.long	1			! V4n36: KEY FORMAT (0 CLASSIC, 1 ALPHANUMERIC), HISTORY tail bit 5

! V4n36 trace: UTILITY BUILD (read-only: its one "option" is bld_u16, the build tag + source hash) and the kill
! switches (entries5: after VERSION No. with the LINK CUE item, counted out of the menu unless TEST LOG is not
! OFF -- kl_reveal). Each: ON = the feature, OFF = the stock path at its entry, live, not saved (ON every boot).
! Words (kl_map): kill_v +0 KEY SYNC, +4 MASTER WAVE NFS, +8 MASTER WAVEFORM, +12 HW BAND LAYER, +16 LINK ROW
! PREVIEW, +20 BLACK BOX (V4n37 mods/bbox; its row only with BBOX); KSB+100 LINK KEY STATUS (mods/keyshift kx_on: the CDJ-3000 key fields in our status packet).
	.p2align 2
	.global	entries4, entries5, entries5_end, ut_n
entries4:
	.long	L_BLD, OPTSB, 1, -1, -1, 0	! read-only (as LINK CUE DIAG)
	.long	0x084EE886, it_fmt, 0x084EFC34, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	! HALFBLUE (V4n41): WAVEFORM FULL / HALF (wh_v; patch_main UT_ORDER puts it under DISPLAY after WAVEFORM
	! CURRENT POSITION) = the CDJ-3000's two player-overview shapes (: centred mirror / bottom).
	! Only the overview strip + the browse rows' mini waveforms follow it. Saved in the HISTORY record's byte 30
	! (hist_save / hist_get), published in heartbeat +0x18 'K' word bit 2 = HALF (sl_pub, normal boot only)
	.long	L_WH, OPTSWH, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	! LINKLAT (v4.2): LINK OFFSET, the LINK meter's display-time lead (lo_v), a normal row in both profiles
	! (LINKOFF: patch_main UT_ORDER puts it under PRO DJ LINK; live, not saved: OFF at every boot)
	.long	L_LO, OPTSLO, 15, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
entries5:
	.ifdef	KEYSHIFT
	.long	L_KXS, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_KSY, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.endif
	.long	L_KNF, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_KMW, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_KHB, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.long	L_KLP, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.ifdef	BBOX			! V4n37r: BLACK BOX kill switch (mods/bbox in the build; patch_main CDJ_BBOX)
	.long	L_KBB, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.endif
	.ifdef	KSAB			! KS3 (v4.1): A/B of the KEY SHIFT DSP engines (DEV test builds; patch_main CDJ_KSAB)
	.long	L_KAB, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.endif
	.ifdef	LINK0B			! LINK0B (v4.2): the CDJ-3000 0x0b precise position (mods/link0b; patch_main CDJ_LINK0B)
	.long	L_K0B, OPTS, 2, -1, -1, 1
	.long	0x084EE886, it_fmt, 0x084EFAF4, 0x084EFC38, 0x084EFCD8
	.long	it_commit, 0x084F046E, 0x084F04B0, 0x084F056A
	.endif
entries5_end:
ut_n:	.long	0, 0			! the table's items, of them kill switches (patch_main place_modsmenu)
kl_map:	.long	L_BLD, diag_off		! label -> word (wordof); BUILD reads 0 = its one option
	.ifdef	KEYSHIFT
	.long	L_KXS, KSB + 100
	.long	L_KSY, kill_v
	.endif
	.long	L_KNF, kill_v + 4
	.long	L_KMW, kill_v + 8
	.long	L_KHB, kill_v + 12
	.long	L_KLP, kill_v + 16
	.ifdef	BBOX
	.long	L_KBB, kill_v + 20	! V4n37r
	.endif
	.ifdef	KSAB
	.long	L_KAB, kill_v + 24	! KS3 A/B
	.endif
	.ifdef	LINK0B
	.long	L_K0B, kill_v + 28	! LINK0B
	.endif
	.long	L_LO, lo_v		! LINKLAT: LINK OFFSET (not a kill switch)
	.long	L_WH, wh_v		! HALFBLUE (not a kill switch)
	.long	0
OPTSB:	.long	bld_u16
OPTSWH:	.long	L_FULL, L_HALF		! HALFBLUE
	.global	wh_v, lo_v
lo_v:	.long	0			! LINKLAT (v4.2): LINK OFFSET option 0 OFF (default, as the CDJ-3000), 1..14 =
					!   -10..+55 ms (5-ms steps); not saved (OFF every boot); heartbeat +0x18 'K' bits
					!   4-7 = option + 1 (sl_pub); a row in both profiles (LINKOFF)
wh_v:	.long	0			! HALFBLUE: WAVEFORM (0 FULL = the 3000 centred overview, default; 1 HALF =
					!   bottom-anchored), HISTORY record byte 30 bit 2
L_WH:	.short	'W', 'A', 'V', 'E', 'F', 'O', 'R', 'M', 0
L_HALF:	.short	'H', 'A', 'L', 'F', 0
	.p2align 1
L_BLD:	.short	'B', 'U', 'I', 'L', 'D', 0
L_KXS:	.short	'L', 'I', 'N', 'K', ' ', 'K', 'E', 'Y', ' ', 'S', 'T', 'A', 'T', 'U', 'S', 0
L_KSY:	.short	'K', 'E', 'Y', ' ', 'S', 'Y', 'N', 'C', 0
L_KNF:	.short	'M', 'A', 'S', 'T', 'E', 'R', ' ', 'W', 'A', 'V', 'E', ' ', 'N', 'F', 'S', 0
L_KMW:	.short	'M', 'A', 'S', 'T', 'E', 'R', ' ', 'W', 'A', 'V', 'E', 'F', 'O', 'R', 'M', 0
L_KHB:	.short	'H', 'W', ' ', 'B', 'A', 'N', 'D', ' ', 'L', 'A', 'Y', 'E', 'R', 0
L_KLP:	.short	'L', 'I', 'N', 'K', ' ', 'R', 'O', 'W', ' ', 'P', 'R', 'E', 'V', 'I', 'E', 'W', 0
	.ifdef	BBOX
L_KBB:	.short	'B', 'L', 'A', 'C', 'K', ' ', 'B', 'O', 'X', 0
	.endif
	.ifdef	KSAB
L_KAB:	.short	'K', 'S', '3', ' ', 'E', 'N', 'G', 'I', 'N', 'E', 0
	.endif
	.ifdef	LINK0B
L_K0B:	.short	'L', 'I', 'N', 'K', ' ', '0', 'x', '0', 'B', 0
	.endif
					! LINKLAT: LINK OFFSET options (ms)
L_LO:	.short	'L', 'I', 'N', 'K', ' ', 'O', 'F', 'F', 'S', 'E', 'T', 0
L_LO0:	.short	'-', '1', '0', 0
L_LO1:	.short	'-', '5', 0
L_LO2:	.short	'0', 0
L_LO3:	.short	'+', '5', 0
L_LO4:	.short	'+', '1', '0', 0
L_LO5:	.short	'+', '1', '5', 0
L_LO6:	.short	'+', '2', '0', 0
L_LO7:	.short	'+', '2', '5', 0
L_LO8:	.short	'+', '3', '0', 0
L_LO9:	.short	'+', '3', '5', 0
L_LO10:	.short	'+', '4', '0', 0
L_LO11:	.short	'+', '4', '5', 0
L_LO12:	.short	'+', '5', '0', 0
L_LO13:	.short	'+', '5', '5', 0
	.p2align 2
OPTSLO:	.long	L_OFF, L_LO0, L_LO1, L_LO2, L_LO3, L_LO4, L_LO5, L_LO6, L_LO7, L_LO8, L_LO9, L_LO10, L_LO11, L_LO12, L_LO13
	.p2align 2
	.ifdef	KEYSHIFT
! kl_reveal: the UTILITY item count (RAM 0x10DE1B98, a byte) = every item while TEST LOG is not OFF, else without
! the kill switches (the table's last ut_n[1] items). V4n37r RELEASE (a build without TEST LOG): always every item
! -- the kill switches stay reachable for live problems (the image's count still hides them until a normal boot
! runs this, so update mode never shows them). Normal boot only.
! Uses r0-r2.
kl_reveal:
	mov.l	kr_boot,r1
	mov.l	@r1,r0
	cmp/eq	#1,r0
	bf	9f
	mov.l	kr_n,r1
	mov.l	@r1,r2			! every item
	tst	r2,r2
	bt	9f			! not filled (no kill switches)
	.ifdef	TESTLOG
	mov.l	kr_tl,r0
	mov.l	@r0,r0
	tst	r0,r0
	bf	1f			! TEST LOG on: all
	.endif
	mov.l	@(4,r1),r0		! RELAUDIT: RELEASE (no TEST LOG) = never the kill switches
	sub	r0,r2
1:	mov.l	kr_cnt,r1
	mov	r2,r0
	rts
	mov.b	r0,@r1
9:	rts
	nop
! kl_commit (it_commit, r1 = the item's word, r5 = its new option): KEY SYNC switched OFF while on -> ended
! now (mods/keyshift ksy_tap: MASTER TEMPO back); then kl_reveal. Keeps r5, r7; uses r0-r2.
kl_commit:
	sts.l	pr,@-r15
	mov.l	kr_kv,r0
	cmp/eq	r0,r1
	bf	1f
	tst	r5,r5
	bf	1f
	mov.l	kr_ksb,r2
	mov.l	@(48,r2),r0		! ksy_on
	tst	r0,r0
	bt	1f
	mov	r2,r0
	add	#80,r0			! ksy_tap (saves r4-r7)
	jsr	@r0
	nop
1:	bsr	kl_reveal
	nop
	lds.l	@r15+,pr
	rts
	nop
	.p2align 2
kr_boot: .long	0x0A35DF3C		! MAIN boot state (1 = normal boot)
kr_n:	.long	ut_n
	.ifdef	TESTLOG
kr_tl:	.long	KSB + 68		! mods/keyshift tl_v (UTILITY TEST LOG)
	.endif
kr_cnt:	.long	0x10DE1B98		! the UTILITY item count (fa_cnt)
kr_kv:	.long	kill_v
kr_ksb:	.long	KSB
	.endif

	.ifdef	V3E2
! ---------------------------------------------------------------------------
! TOUCH (V4n41, work/touch): the rest of the CDJ-3000 touch -- reached from vt_act (actions 14..18) with
! r7 = the zone record, r4 = its argument, r5 / r6 = x / 4, y / 2 (action 14: x, y as is, from vt_pop),
! pr on the stack (left through va_out). Geometry = v2.c (mods/v2ui/touch_map.py TM_POP_* / TM_UT_* / TM_GA_*).
!  14 pop-up (vt_pop's "inside" record): SORT / LIST MENU -> a row selects it (seek the pop-up cursor, PUSH);
!     TAG LIST MENU -> a row moves the cursor, OK = PUSH, CANCEL = BACK; LOAD PREVIOUS TRACK / stock GRID
!     ADJUST (the right pane) -> a row moves the cursor, a tap on the selected row = PUSH (load / the item)
!  15 GRID ADJUST panel (arg 0 SNAP GRID, 1 SHIFT GRID, 2 1/2 back, 3 1/2 next, 4 RESET, 5 the ZOOM-GRID
!     toggle, 6 the rest of the row): 0 / 1 / 4 = stock's own GRID ADJUST pop-up item (MENU, seek, PUSH),
!     2 / 3 = the stock offset (s16 ms 0x0A35F7AC, setter wrapper 0x083FBAFC) -/+ half a beat
!     (stock's GRID ADJUST tick 0x084E6A0A copies that word into its state 0x0B569014 and saves it after 700 ms
!     idle / on leaving the mode, exactly as a knob move: the same per-track offset stock persists -- user decision)
!  16 UTILITY row: the cursor there (a seek); the cursor's row = PUSH (edit / commit); editing, another
!     row = BACK (leaves the edit, as the key)
!  17 UTILITY option (the radio list right of the rows): PUSH into the edit if needed, seek the item's
!     pending value (its table entry +16) to the option, PUSH -- the stock knob path, dialogs included
!  18 PREVIEW tile: kill_v +24 (1 ON) -- touch_audio row_touch previews only while it is set
! ---------------------------------------------------------------------------
	.p2align 2
va_touch:
	mov.b	@(2,r7),r0
	cmp/eq	#14,r0
	bt	vp_tap
	cmp/eq	#15,r0
	bt	vg_tap
	cmp/eq	#16,r0
	bt	vu_row
	cmp/eq	#17,r0
	bf	1f
	bra	vu_opt
	nop
1:	mov.l	th_scr,r1		! 18: PREVIEW on / off (not on the root / SOURCE: model screen 0x00,
	mov.b	@r1,r0			! no tile there)
	tst	r0,r0
	bt	th_out
	mov.l	th_pv,r1
	mov.l	@r1,r0
	xor	#1,r0
	bra	th_out
	mov.l	r0,@r1

vp_tap:					! r5 x, r6 y
	mov.l	th_s1,r1
	mov	#0x22,r2
	shll2	r2
	shll2	r2			! 0x220
	mov	#0,r3			! r3 = n (the last row with text)
	mov	#1,r4
	mov	#0,r7			! r7 = the cursor's row (0 none)
1:	add	r2,r1
	mov.l	@(0x28,r1),r0
	tst	r0,r0
	bt	2f
	mov	r4,r3
2:	mov.l	@(12,r1),r0
	tst	#8,r0
	bt	3f
	mov	r4,r7
3:	add	#1,r4
	mov	#9,r0
	cmp/eq	r0,r4
	bf	1b
	mov	#0,r1			! r1 = 0: a tap on the selected row pushes
	mov.l	th_scr,r2
	mov.b	@r2,r0
	cmp/eq	#2,r0
	bf	vp_modal
	mov	r6,r0			! the right pane: rows of 40 px from y 90
	add	#-90,r0
	cmp/pz	r0
	bf	th_out
	mov	#0,r4
	mov	#40,r2
4:	cmp/hs	r2,r0
	bf	5f
	sub	r2,r0
	bra	4b
	add	#1,r4
5:	add	#1,r4
	cmp/hi	r3,r4
	bt	th_out
	bra	vp_go
	mov	#0,r5			! no PUSH after the seek (a second tap loads)
vp_modal:
	mov.l	th_s1,r2		! TAG LIST MENU: title "TAGLIST MENU" (12 chars, 'T')
	add	#0x28,r2
	mov.w	@r2+,r0
	cmp/eq	#12,r0
	bf	6f
	mov.w	@r2,r0
	cmp/eq	#0x54,r0
	bf	6f
	mov	#50,r1			! r1 = 50: TAG LIST MENU's OK / CANCEL band
6:	mov	r3,r0			! bh = 52 + 34 max(n, 1) + 8 (+ 50)
	tst	r0,r0
	bf	7f
	mov	#1,r0
7:	mov	#34,r2
	mulu.w	r2,r0
	sts	macl,r0
	add	#60,r0
	add	r1,r0
	mov	r0,r2			! r2 = bh
	shlr	r0
	mov	#118,r4
	add	r4,r4
	sub	r0,r4			! r4 = y0 = 236 - bh / 2, at least 66
	mov	#66,r0
	cmp/gt	r4,r0
	bf	8f
	mov	r0,r4
8:	cmp/hs	r4,r6			! outside the modal's frame (y0 .. y0 + bh) = BACK, as outside vt_pop's box
	bf	14f
	mov	r4,r0
	add	r2,r0
	cmp/hs	r0,r6
	bf	15f
14:	mov.l	th_backk,r2
	bra	th_key
	nop
15:	tst	r1,r1
	bt	9f
	mov	r4,r0			! OK / CANCEL: y0 + bh - 46, 34 tall, +-6 px
	add	r2,r0
	add	#-52,r0
	cmp/hs	r0,r6
	bf	9f
	add	#46,r0
	cmp/hs	r0,r6
	bt	9f
	mov.w	th_400,r0
	cmp/hs	r0,r5
	bt	10f
	mov.l	th_pushk,r2		! OK
	bra	th_key
	nop
10:	mov.l	th_backk,r2		! CANCEL
	bra	th_key
	nop
9:	mov	r6,r0			! rows: y0 + 46 + 34 (k - 1), 34-px pitch
	sub	r4,r0
	add	#-46,r0
	cmp/pz	r0
	bf	th_out
	mov	#0,r4
	mov	#34,r2
11:	cmp/hs	r2,r0
	bf	12f
	sub	r2,r0
	bra	11b
	add	#1,r4
12:	add	#1,r4
	cmp/hi	r3,r4
	bt	th_out
	mov	#1,r5			! SORT / LIST MENU: PUSH after the seek
	tst	r1,r1
	bt	vp_go
	mov	#0,r5
vp_go:					! r4 = the row, r7 = the cursor's, r5 = PUSH after, r1 != 0: no PUSH here
	cmp/eq	r7,r4
	bf	13f
	tst	r1,r1
	bf	th_out
	mov.l	th_pushk,r2
	bra	th_key
	nop
13:	bra	th_seek
	mov	#1,r0			! mode 1: the pop-up cursor

vg_tap:
	mov	r4,r0
	cmp/eq	#7,r0			! PLAYERSCALE phase 2: the label's zone above the pad row = the same toggle
	bf	0f
	mov	#5,r0
0:	cmp/eq	#5,r0
	bf	1f
	mov.l	vg_mode,r1		! the ZOOM - GRID toggle: stock's GRID ADJUST mode on / off
	mov.l	@r1,r0
	tst	r0,r0
	movt	r4
	mov.l	vg_set,r0
	jsr	@r0
	nop
	bra	th_out
	nop
1:	cmp/eq	#6,r0
	bt	th_out
	cmp/eq	#2,r0
	bt	2f
	cmp/eq	#3,r0
	bt	2f
	mova	vg_row,r0		! SNAP GRID / SHIFT GRID / RESET: MENU (the stock GRID ADJUST pop-up),
	mov.b	@(r0,r4),r4		! then its row 2 / 3 / 1 and PUSH
	mov.l	th_kp,r1
	mov.l	th_menuk,r0
	mov.l	r0,@r1
	mov	#VT_KT,r0
	mov.l	r0,@(4,r1)
	mov	#2,r5			! PUSH, then BACK if the pop-up stays (SNAP GRID without a CUE)
	bra	th_seek
	mov	#1,r0
2:	mov.l	vg_bpm,r1		! 1/2 beat: 3,000,000 / (the track's BPM x 100) ms
	mov.l	@r1,r1
	extu.w	r1,r1
	tst	r1,r1
	bt	th_out
	mov	#-1,r2
	extu.w	r2,r2
	cmp/eq	r2,r1
	bt	th_out
	mov.l	vg_3m,r2
	mov	#0,r3
3:	cmp/hs	r1,r2
	bf	4f
	sub	r1,r2
	bra	3b
	add	#1,r3
4:	mov	r4,r0			! the move goes to stock's own knob GRID move 0x084E6638(delta) -- run by
	cmp/eq	#2,r0			! vt_khook in the UI task, as a knob turn: the same clamp, LINK / display
	bf	5f			! mirror and unsaved mark, so stock's 700 ms idle save stores it (as the
	neg	r3,r3			! knob's: the per-track offset)
5:	mov.l	vg_pend,r1
	bra	th_out
	mov.l	r3,@r1

	.p2align 2
vg_row:	.byte	2, 3, 0, 0, 1
	.p2align 1
th_220:	.short	0x220
th_400:	.short	400
	.p2align 1

vu_row:					! r6 = y / 2: row k = (y - 70) / 33
	mov	r6,r0
	add	r0,r0
	add	#-70,r0
	cmp/pz	r0
	bf	th_out
	mov	#0,r4
	mov	#33,r1
1:	cmp/hs	r1,r0
	bf	2f
	sub	r1,r0
	bra	1b
	add	#1,r4
2:	mov	#8,r0
	cmp/hs	r0,r4
	bt	th_out
	mov.l	th_s0,r1		! an empty row: nothing
	mov	#0x22,r2
	shll2	r2
	shll2	r2			! 0x220
	mov	r4,r3
	add	#1,r3
	mulu.w	r2,r3
	sts	macl,r3
	add	r1,r3
	mov.l	@(0x28,r3),r0
	tst	r0,r0
	bt	th_out
	mov.l	th_vcur,r1
	mov.l	@r1,r0
	cmp/eq	r4,r0
	bt	3f
	mov.l	th_scr,r1
	mov.b	@r1,r0
	cmp/eq	#9,r0
	bt	4f
	mov.l	th_vfst,r1
	mov.l	@r1,r0
	add	r0,r4
	mov.l	th_seekto,r0
	jsr	@r0
	nop
	bra	th_out
	nop
3:	mov.l	th_pushk,r2
	bra	th_key
	nop
4:	mov.l	th_backk,r2
	bra	th_key
	nop

th_out:	mov.l	th_outp,r0
	jmp	@r0
	nop
th_key:	mov.l	th_keyp,r0		! r2 = the key's setter
	jmp	@r0
	nop
th_seek:				! r4 goal, r5 PUSH after, r6 the UTILITY entry, r0 mode (1 / 2)
	mov.l	th_sk,r1
	mov.l	r0,@(20,r1)
	mov.l	r4,@(4,r1)
	mov.l	r5,@(24,r1)
	mov.l	r6,@(28,r1)
	mov	#-1,r0
	mov.l	r0,@(8,r1)
	mov	#0,r0
	mov.l	r0,@(16,r1)
	mov.l	th_tk,r2
	mov.l	@r2,r0
	mov.l	r0,@(32,r1)
	mov	#1,r0
	bra	th_out
	mov.l	r0,@r1

vu_opt:					! r6 = y / 2: option row r = (y - 67) / 33
	mov	r6,r0
	add	r0,r0
	add	#-67,r0
	cmp/pz	r0
	bf	th_out
	mov	#0,r3
	mov	#33,r1
1:	cmp/hs	r1,r0
	bf	2f
	sub	r1,r0
	bra	1b
	add	#1,r3
2:	mov	#10,r0
	cmp/hs	r0,r3
	bt	th_out
	mov.l	th_vfst,r1		! the cursor's item: table + 60 x (first + cursor)
	mov.l	@r1,r0
	mov.l	th_vcur,r1
	mov.l	@r1,r1
	add	r1,r0
	mov	#60,r1
	mulu.w	r1,r0
	sts	macl,r6
	mov.l	th_utt,r1
	mov.l	@r1,r1
	tst	r1,r1
	bt	th_out
	add	r1,r6			! r6 = the entry
	mov.l	@(8,r6),r1		! r1 = its option count
	mov	#2,r0
	cmp/hs	r0,r1
	bf	th_out
	mov.l	th_scr,r2
	mov.b	@r2,r0
	mov	r0,r7			! r7 = model screen (0x0A list, 0x09 edit)
	cmp/eq	#9,r0
	bt	3f
	bra	4f
	mov.l	@(12,r6),r2		! r2 = the current option (editing: the pending one)
3:	mov.l	@(16,r6),r2
4:	mov	#0,r4			! v2.c radio_list's window: first = min(c - 4, n - 10) when n > 10, c > 4
	mov	#10,r0
	cmp/gt	r0,r1
	bf	5f
	mov	#4,r0
	cmp/gt	r0,r2
	bf	5f
	mov	r2,r4
	add	#-4,r4
	mov	r1,r0
	add	#-10,r0
	cmp/gt	r0,r4
	bf	5f
	mov	r0,r4
5:	add	r3,r4			! r4 = the option
	cmp/hs	r1,r4
	bt	th_out
	mov	r7,r0
	cmp/eq	#9,r0
	bf	6f
	cmp/eq	r2,r4			! editing: the pending one = PUSH (commit), else seek + PUSH
	bf	7f
	mov.l	th_pushk,r2
	bra	th_key
	nop
7:	mov	#1,r5
	bra	th_seek
	mov	#2,r0
6:	cmp/eq	#0x0A,r0
	bf	th_out
	cmp/eq	r2,r4			! the value it has: nothing
	bt	th_out
	mov.l	th_kp,r1		! PUSH (into the edit); the seek waits for the edit screen
	mov.l	th_pushk,r0
	mov.l	r0,@r1
	mov	#VT_KT,r0
	mov.l	r0,@(4,r1)
	mov	#1,r5
	bra	th_seek
	mov	#2,r0

	.p2align 2
th_pv:	.long	kill_v + 24
th_s0:	.long	0x0B53FBA4		! the model's side-0 slot 0
th_s1:	.long	0x0B53FBA4 + 0x132C	! side 1's
th_scr:	.long	0x0B53FB54		! model screen
th_ui:	.long	0x0B54336C		! UI state (+0xC pop-up)
th_vcur: .long	0x0B5433B8
th_vfst: .long	0x0B5434F4
th_pushk: .long	0x084E121E
th_backk: .long	0x084E1232
th_menuk: .long	0x084E11CC
th_kp:	.long	vt_key
th_sk:	.long	vt_sk
th_tk:	.long	0x0B0C5258		! 1 ms tick
th_outp: .long	va_out
th_keyp: .long	va_key2
th_seekto: .long vt_seek_to
	.global	vt_utt
vt_utt:	.long	0			! UTILITY's item table (place_modsmenu)
th_utt:	.long	vt_utt
vg_mode: .long	0x0A35F3E0		! GRID ADJUST mode
vg_set:	.long	0x083FBA5C		! its setter (a store)
vg_bpm:	.long	0x0A35F3EC		! the track's BPM x 100 (u16, 0xFFFF none)
vg_3m:	.long	3000000
vg_pend: .long	vt_ghp
	.global	vt_ghp
vt_ghp:	.long	0			! TOUCH: a 1/2-beat GRID move (ms) for vt_khook, 0 none
	.endif

block_end:
