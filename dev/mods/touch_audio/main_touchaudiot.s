! SPDX-License-Identifier: Apache-2.0
!
! touchaudiot: main_touchaudio.s assembled with TESTHOOK (TEST builds only). patch_main uses it
! in place of `touchaudio` when `autotest` or `usblog` is named (the default touchaudio blob
! stays byte-identical). The only difference: the TchAud loop calls the autotest / usblog ticks
! (test_hooks; addresses put in by patch_main.place_testhooks). re/AUTOTEST_USBLOG.md.
	.equ	TESTHOOK, 1
	.include "main_touchaudio.s"
