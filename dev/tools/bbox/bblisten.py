#!/usr/bin/env python3
"""bblisten.py GROUP:PORT SECONDS OUT: the deck's RED records (UDP 50099) off the emu's mcast segment;
every 128-byte record appended to OUT (decode_bbox.py reads its 'V3BB' ones)."""
import importlib.util
import os
import sys
import time

spec = importlib.util.spec_from_file_location('atcmd', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'commander', 'cmd.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
link = m.Link('169.254.255.255', sys.argv[1])
n = bb = 0
with open(sys.argv[3], 'ab') as f:
    for src, d in link.records(time.time() + float(sys.argv[2])):
        f.write(d)
        f.flush()
        n += 1
        bb += d[:4] == b'V3BB'
print('records %d, V3BB %d' % (n, bb))
