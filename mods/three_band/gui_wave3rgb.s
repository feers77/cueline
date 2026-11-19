! SPDX-License-Identifier: GPL-2.0-or-later
! wave3rgb = wave3 (true 3-band centre waveform from the .2EX data) with the
! CDJ-3000 RGB colour (ui3000x_wavergb's blend) for tracks that have no
! 3-band data, instead of the stock additive red. Both need the same hook
! span, so the fallback lives inside wave3. patch_gui uses it for wave3 when
! ui3000x is on.
	.set	RGB3000, 1
	.include "three_band/gui_wave3.s"
