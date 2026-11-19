#!/bin/sh
# Builds main_tadec.bin: the MP3/FLAC decoder blob for touch_audio, linked
# at 0x08140000 (MAIN's code cave, above the sigpatch-placed mods). Needs
# sh4-linux-gnu-gcc; patch_main.py copies the .bin in at that address.
#   BASE=0x08018000 ARENA_KB=256 ./build.sh  -> main_tadec_08018000.bin, for
#   patch_main.py's ks layout (a smaller decoder arena; the real use
#   measured in the emulator is 0 for MP3 and ~41 KB for FLAC).
#   OPT=Os ./build.sh -> main_tadec_Os.bin: the MAIN-flash "cap" variant
#   ("selA", re/PERF_V33_ANALYSIS.md): -Os, but dr_mp3 kept at -O2 through
#   -DTADEC_MP3_O2 (all -Os costs MP3 +37 % CPU). patch_main FIXED `tadecos`.
set -e
cd "$(dirname "$0")"
BASE=${BASE:-0x08140000}
ARENA_KB=${ARENA_KB:-440}
OPT=${OPT:-O2}
SUF=$([ "$OPT" = O2 ] || echo _$OPT)
OUT=main_tadec$SUF.bin
[ "$BASE" = 0x08140000 ] || OUT=main_tadec_$(printf %08X $BASE)$SUF.bin
XDEF=$([ "$OPT" = O2 ] || echo -DTADEC_MP3_O2)
CC=sh4-linux-gnu-gcc
$CC -m4 -ml -c -o crt.o crt.S
$CC -m4 -ml -$OPT $XDEF -ffreestanding -fno-pic -fno-stack-protector -D_FORTIFY_SOURCE=0 \
    -fno-strict-aliasing -ffunction-sections -fdata-sections -fno-asynchronous-unwind-tables \
    -DARENA_KB=$ARENA_KB -c -o tadec.o tadec.c
sh4-linux-gnu-ld -defsym TADEC_BASE=$BASE -T tadec.ld --gc-sections -o tadec.elf crt.o tadec.o "$($CC -m4 -print-libgcc-file-name)"
sh4-linux-gnu-readelf -r tadec.elf | grep -q "Relocation section" && { echo "unexpected relocations"; exit 1; } || true
sh4-linux-gnu-nm -u tadec.elf | grep . && { echo "undefined symbols"; exit 1; } || true
# written beside and renamed: a build reading $OUT never sees a half-written blob
sh4-linux-gnu-objcopy -O binary tadec.elf $OUT.tmp.$$ && mv -f $OUT.tmp.$$ $OUT
ls -la $OUT
