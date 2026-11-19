! SPDX-License-Identifier: Apache-2.0
! gr3direct = fpsboost plus the player screen's two big windows drawing
! straight into the GR3 back buffer (re/FPS_STOCK.md). One source, one
! more entry (+12) and the GR3DIRECT paths of mods/fpsboost/gui_fpsboost.s.
	.set	GR3DIRECT, 1
	.include "fpsboost/gui_fpsboost.s"
