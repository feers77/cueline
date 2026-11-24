! SPDX-License-Identifier: Apache-2.0
!
! Where our MAIN mods keep their run-time state and find the tadec blob.
! patch_main.py's LAYOUTS set these with --defsym; the defaults are the
! stock-firmware layout the committed .bin files are assembled with:
!   RAMB   a 128 KB block of free RAM: rowwave buffers +0x0, the black big
!          buffer +0x9000, the row table +0x10000 (texts +0x10100, keys
!          +0x10800 -- REVIEW 1124: was +0x10400 = row 8's text slot), the kill switch word +0x1F7F0, the shared block
!          +0x1F800, diagnostics +0x1FE00, wav32 state +0x1FF00
!   TADEC  the tadec blob's entry table (open +0, seek +4, read +8,
!          rate +0xC, close +0x10, jpeg +0x14)
!   MODSV, LCV, W32V  the UTILITY items MODS, LINK CUE and WAV 32-BIT
!          (mods/modsmenu: option index, 0 = OFF; LINK CUE 1 PREVIEW, 2 CUE,
!          3 BOTH), at its block's base + 240/244/248
!   DIAGT  the LINK CUE DIAG item's text (UTF-16, <= 63 chars), base + 256
!   DIAGL  its label (UTF-16, <= 23 chars; the task writes its counters
!          there): the block's L_DIAG (patch_main passes it)
	.ifndef RAMB
	.equ	RAMB, 0x081E0000
	.endif
	.ifndef TADEC
	.equ	TADEC, 0x08140000
	.endif
	.ifndef MODSV
	.equ	MODSV, 0x0813E0F0
	.endif
	.ifndef LCV
	.equ	LCV, 0x0813E0F4
	.endif
	.ifndef W32V
	.equ	W32V, 0x0813E0F8
	.endif
	.ifndef DIAGT
	.equ	DIAGT, 0x0813E100
	.endif
	.ifndef MMPUB
	.equ	MMPUB, 0x0813E428	! modsmenu's mm_publish (LIGHT MODE / BPM DECIMALS -> heartbeat +0x54)
	.endif
	.ifndef DIAGL
	.equ	DIAGL, 0x0813E1CE
	.endif
!   BLDID  V4n36 trace: modsmenu's build record (block base + 0x180: "BLD1" + the ASCII build ID, then the
!          UTILITY BUILD value in UTF-16; patch_main fills it), for usblog's boot record / cmd.py ver
!   KILLB  V4n36 trace: modsmenu's kill switches (block base + 0x1E0, words: 1 ON = the feature, 0 OFF =
!          its stock path): +0 KEY SYNC, +4 master waveform over NFS, +8 MASTER WAVEFORM (display),
!          +12 HW BAND LAYER (display), +16 LINK ROW PREVIEW. Defaults = the ks layout (menu 0x08014000).
	.ifndef BLDID
	.equ	BLDID, 0x08014180
	.endif
	.ifndef KILLB
	.equ	KILLB, 0x080141E0
	.endif
