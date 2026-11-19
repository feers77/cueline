# SPDX-License-Identifier: Apache-2.0
"""The MAIN flash-window constant patch_main needs, kept with the mods so the build does not import the
emulator's scripts/firmware/make_flash.py (the package exporter used to ship a stub of it).

MAIN_END: the end of the MAIN section's flash window -- the updater never programs the section past this
(same value as scripts/firmware/make_flash.py MAIN_END)."""
MAIN_END = 0x7E0000
