#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Builds p56.bin (player56 cave) linked at P56_BASE (default 0x081C4000) + p56.sym.
set -e
cd "$(dirname "$0")"
BASE=${P56_BASE:-0x081C4000}
CC=sh4-linux-gnu-gcc
python3 gen56.py ${STOCK_MAIN:?set STOCK_MAIN to your decoded stock MAIN image} sites.txt p56sites.S sites.json
$CC -m4 -ml -c -o p56stub.o p56stub.S
python3 genui.py ${STOCK_MAIN:?set STOCK_MAIN to your decoded stock MAIN image} p56ui_entries.S ui_entries.json
$CC -m4 -ml -c -o p56uie.o p56ui_entries.S
[ -f p56sites.S ] && $CC -m4 -ml -c -o p56sites.o p56sites.S
python3 gen56.py ${STOCK_MAIN:?set STOCK_MAIN to your decoded stock MAIN image} sites_sess.txt p56sess.S sites_sess.json
$CC -m4 -ml -c -o p56sess.o p56sess.S
$CC -m4 -ml -Os -ffreestanding -fno-pic -fno-stack-protector -fno-builtin -fno-asynchronous-unwind-tables \
    -ffunction-sections -c -o p56.o p56.c
$CC -m4 -ml -Os -ffreestanding -fno-pic -fno-stack-protector -fno-builtin -fno-asynchronous-unwind-tables \
    -ffunction-sections -c -o p56ui.o p56ui.c
sh4-linux-gnu-ld -defsym P56_BASE=$BASE -T p56.ld -o p56.elf p56stub.o $( [ -f p56sites.o ] && echo p56sites.o ) p56sess.o p56.o p56uie.o p56ui.o
sh4-linux-gnu-objcopy -O binary --set-section-flags .bss=alloc,load,contents p56.elf p56.bin
sh4-linux-gnu-nm p56.elf | grep -E ' [TtDdBb] p56_' > p56.sym
sh4-linux-gnu-nm -u p56.elf | grep . && { echo "undefined symbols"; exit 1; } || true
# a7: standalone announce stub (p56ann.bin) at 0x081C7F00, outside p56.bin
$CC -m4 -ml -c -o p56ann.o p56ann.S
sh4-linux-gnu-ld -Ttext=0x081C7F00 -e p56_ann -o p56ann.elf p56ann.o
sh4-linux-gnu-objcopy -O binary -j .text p56ann.elf p56ann.bin
ls -la p56.bin p56ann.bin; cat p56.sym
