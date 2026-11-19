! SPDX-License-Identifier: Apache-2.0
! gr3direct3k = gr3direct plus marqueefix's recolour (stock selection fill
! 0xDEFC -> 3000 navy 0x19CD), which needs the same DMA-fill literal
! 0x0E508FD4. patch_gui uses it instead of gr3direct when ui3000x is on.
	.set	GR3DIRECT, 1
	.set	MARQUEE, 1
	.include "fpsboost/gui_fpsboost.s"
