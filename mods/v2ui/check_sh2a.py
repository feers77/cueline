#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail if the V2 blob contains an instruction the SH-2A lacks (FPU, cache, prefetch...).

Words that the code loads as PC-relative literals (mov.w/mov.l @(disp,PC) pools) are data, not
instructions, and are skipped -- a coordinate like 403 (0x0193) disassembles as `ocbi`."""
import re
import subprocess
import sys

BAD = re.compile(r'\b(fmov|fldi[01]|flds|fsts|fadd|fmul|pref|movca\.l|ocbi|ocbp|ocbwb|ldtlb|synco|icbi|prefi|movli|movco)\b')
out = subprocess.run(['sh4-linux-gnu-objdump', '-d', sys.argv[1]], capture_output=True, text=True, check=True).stdout
data = set()
for m in re.finditer(r'\tmov\.([wl])\t(?:0x)?([0-9a-f]+)\b', out):
    a = int(m.group(2), 16)
    data.update((a, a + 2) if m.group(1) == 'l' else (a,))
bad = []
for line in out.splitlines():
    m = re.match(r'\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} ){2}\s*(.*)$', line)
    if m and BAD.search(m.group(2)) and int(m.group(1), 16) not in data:
        bad.append(line)
if bad:
    print('\n'.join(bad))
    print('non-SH-2A instruction')
    sys.exit(1)
