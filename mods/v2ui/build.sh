#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Builds v2ui.bin (the V2 UI renderer, SH-2A big-endian, linked at V2_BASE).
# Needs sh4-linux-gnu-gcc (SH-4 integer subset, -mb; nothing SH-2A lacks is
# emitted: checked by the grep below). Fonts: our own face Cueline Sans (fonts/CuelineSans, SIL OFL 1.1) by
# default, in DEV and RELEASE; a private face can override it (never committed / redistributed):
#   CDJ_V2_TTF=/path/to/font.ttf ./build.sh
set -e
cd "$(dirname "$0")"
V2_BASE=${V2_BASE:-0x1C050000}
V2_RO=${V2_RO:-0x0C700000}
if [ -n "$CDJ_V2_TTF" ]; then
  echo "v2ui: fonts from the private override $CDJ_V2_TTF"
  python3 fontgen.py "$CDJ_V2_TTF" font.c
else
  python3 fontgen.py --cueline font.c
fi
# the icon atlas: our own icon set (../v2ui_assets/icons.py, Apache-2.0), drawn and pixel-fitted here; no firmware
python3 ../v2ui_assets/icons.py ../v2ui_assets
CC=sh4-linux-gnu-gcc
# V3e2 (touch layer drawing, W8, players 5/6 at runtime) is the default; CDJ_V3E2=0 builds the V3f GUI
[ "${CDJ_V3E2:-1}" = 1 ] && V2_CFLAGS="-DV3E2 $V2_CFLAGS"
CFLAGS="-m4-nofpu -mb -Os -ffreestanding -fno-builtin -fno-pic -fno-common -nostdlib \
 -fno-stack-protector -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections -fno-jump-tables -Wall $V2_CFLAGS"
$CC $CFLAGS -c entry.S -o entry.o
$CC $CFLAGS -c v2.c -o v2.o
$CC $CFLAGS -c font.c -o font.o
$CC $CFLAGS -c ../v2ui_assets/v2ui_atlas.c -o atlas.o
sh4-linux-gnu-ld -EB --defsym V2_BASE=$V2_BASE --defsym V2_RO=$V2_RO -T v2.ld --gc-sections -e v2_entry -o v2ui.elf entry.o v2.o font.o atlas.o
sh4-linux-gnu-nm -u v2ui.elf | grep . && { echo "undefined symbols"; exit 1; } || true
sh4-linux-gnu-objcopy -O binary -j .v2 v2ui.elf v2ui.bin
sh4-linux-gnu-objcopy -O binary -j .v2ro v2ui.elf v2ui_ro.bin
# no instruction the SH-2A lacks (FPU, cache ops, prefetch); literal pools are data
python3 check_sh2a.py v2ui.elf
ls -la v2ui.bin v2ui_ro.bin
