! SPDX-License-Identifier: GPL-2.0-or-later
! wave3ovrgb = wave3ovdata + the CDJ-3000 RGB recolour of the stock overview
! records for tracks without 3-band data. patch_update uses it for
! wave3ovdata when ui3000x is in the build.
	.set	RGB3000, 1
	.include "three_band/main_wave3ovdata.s"
