! SPDX-License-Identifier: Apache-2.0
!
! lang8 (MAIN half): UTILITY > LANGUAGE offers 8 languages instead of 18
! (EN FR DE IT NL ES JA PT, the ones whose strings the GUI half keeps), and
! no other value can reach the language word. mods/lang8.py places this block
! (linked at its address, see LAYOUTS[..]['lang8'] in patch_main.py) and
! makes the stock code use it; re/STDC_LANG.md and re/STDC_BUILD.md have the
! analysis.
!
! The language word (B+0x44, B = 0x0A35F67C) holds the MAIN language number
! + 1: 1 EN, 2 FR, 3 DE, 4 IT, 5 NL, 6 ES, 7 RU, 8 KO, 9 ZHS, 10 ZHT, 11 JA,
! 12 PT, 13.. SV CS HU DA EL TR. Kept: KEEP1 = 1 2 3 4 5 6 11 12.
!
!   l_set   UTILITY's setter call (formatter preview, commit, cancel: the
!           literals 0x084EF324 / 0x084F0108 / 0x084F0664), r4 = option
!           position + 1 (1..8): r4 = KEEP1[(r4 - 1) & 7], then setw.
!   l_get   UTILITY's getter call (literal 0x084EF328): the option position
!           + 1 of the word's value, 1 (ENGLISH) for a value not kept.
!   setw    the global setter 0x083FC33C (also MY SETTINGS' 0x084C19EC)
!           jumps here: the stock store (extu.b, then B+0x44 through the
!           same r0/r2 the stock code leaves), with a value not kept -> 1.
!           Uses r0, r2, r4 only, as the stock setter.
!   booth   the settings unpacker's language field (0x0846D822-0x0846D82B,
!           jumped to from there): the same field decode, value not kept
!           -> 1, store to @(4,r3), back to 0x0846D82C. r0/r2 only (r2 is
!           rewritten by the subc right after; T is dead there).

	.text
	.global	l_set, l_get, setw, booth

	.equ	GETTER, 0x083FC34A
	.equ	BOOT_RET, 0x0846D82C

	.p2align 2
l_set:
	mov	r4, r2
	add	#-1, r2
	mov	#7, r0
	and	r0, r2
	mova	keep1, r0
	mov.b	@(r0, r2), r4
	! fall through into setw

setw:					! r4 = value
	extu.b	r4, r4
	mov	#31, r2
	cmp/hi	r2, r4
	bf	1f
	mov	#0, r4			! > 31 -> clampt[0] = 1
1:	mova	clampt, r0
	mov.b	@(r0, r4), r4
	mov.l	B_LIT, r2		! as the stock: r2 = 0x0A35DF30, r0 = 0x1790
	mov.w	B_OFF, r0
	rts
	mov.l	r4, @(r0, r2)

l_get:
	sts.l	pr, @-r15
	mov.l	GET_LIT, r0
	jsr	@r0
	nop
	lds.l	@r15+, pr
	mov	r0, r2
	mov	#31, r1
	cmp/hi	r1, r2
	bf	2f
	mov	#0, r2			! > 31 -> posof[0] = 1
2:	mova	posof, r0
	rts
	mov.b	@(r0, r2), r0

booth:					! r14 = packed record, r3 = record, r6 = -5
	mov.w	@(2, r14), r0
	extu.w	r0, r0
	shld	r6, r0
	and	#31, r0
	mov	r0, r2
	mova	clampt, r0
	mov.b	@(r0, r2), r0
	mov.l	r0, @(4, r3)
	mov.l	RET_LIT, r2
	jmp	@r2
	nop

	.p2align 2
B_LIT:	.long	0x0A35DF30
GET_LIT: .long	GETTER
RET_LIT: .long	BOOT_RET
B_OFF:	.short	0x1790
	.p2align 2
! tables after the code (mova reaches forward only; 4-aligned)
keep1:	.byte	1, 2, 3, 4, 5, 6, 11, 12
! clampt[v] = v if v is kept else 1, v = 0..31
clampt:	.byte	1, 1, 2, 3, 4, 5, 6, 1, 1, 1, 1, 11, 12, 1, 1, 1
	.byte	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
! posof[v] = option position + 1 of value v, 1 if v is not kept
posof:	.byte	1, 1, 2, 3, 4, 5, 6, 1, 1, 1, 1, 7, 8, 1, 1, 1
	.byte	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1

