! SPDX-License-Identifier: Apache-2.0
!
! link0b (v4.2 DEV prototype): CDJ-3000 precise-position packets (type 0x0b, UDP 50001) for the CDJ-2000NXS2.
! Shared by main_link0brx.s (the 50001 receive hook) and main_link0btx.s (the DJcont pass hook).
!
! State block L0B = RAMB + 0x1E600 (512 B; RAMB starts as 0xFF there: link0btx clears it once, magic +0x18):
!   +0x00 rx count (0x0b datagrams taken)     +0x04 tx count (unicast 0x0b sent)
!   +0x08 the tick of the last emission       +0x0C debug: the destinations of the last emission (bit = player)
!   +0x10 the meter debug record's last seq (DEV)   +0x14 debug datagrams sent (DEV)   +0x18 'L0B1' once cleared
!   +0x30 / +0x34 / +0x38 the heartbeat words W1 / W2 / W3 staged for modsmenu mm_copy (+0x104 / +0x108 / +0x10C)
!   +0x20 + p, a byte per player: 1 = a Cueline deck (ks3k: "CDJ-2000NXS2" whose status is >= 0x180 B)
!   +0x40 + p * 32 (players 1..6), the last 0x0b of player p:
!         +0 position ms (as sent, 0x28)      +4 MAIN ms tick at its arrival, 0 = stopped (the same position again)
!         +8 microseconds into that tick       +12 pitch, percent x 100 (s32, 0x2C)
!         +16 the tick of its last arrival (any)
	.equ	L0B, RAMB + 0x1E600
	.equ	L0B_CUE, 0x20
	.equ	L0B_REC, 0x40
	.equ	L0B_MAGIC, 0x3142304C	! "L0B1"
	.equ	L0B_BOOT, 0x0A35DF3C	! MAIN boot words: 1 = normal boot (main-update-safety)
	.equ	L0B_KILL, KILLB + 28	! modsmenu kill_v +28: UTILITY LINK 0x0B (1 ON)
