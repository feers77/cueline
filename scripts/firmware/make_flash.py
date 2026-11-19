#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""make_flash (package stub): the one constant the patcher needs from the emulator's flash-image builder.

The full make_flash.py builds a flash image for the emulator and is not part of this package (the emulator is not
shared). mods/patch_main.py only imports MAIN_END: the end of the MAIN flash window the deck's updater programs.
"""
MAIN_END = 0x7E0000          # the updater never programs the MAIN section past this
