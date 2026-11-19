#!/usr/bin/env python3
"""netlog.py [port] [outdir]: the deck's TEST LOG = RED listener (V4n).

The MAIN (mods/usblog net_flush) sends every HUD / status record as its own 128-byte UDP datagram to the
LINK subnet's broadcast, port 50099. Each datagram is exactly one record of the stick file, so they are
appended as they come to <outdir>/V3HUD_<date>.BIN -- decode_usblog.py reads it as it reads the stick's.
Prints one line a record: GUI seq, cpu %, screen, and the first HUD words.
"""
import os
import socket
import struct
import sys
import time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 50099
outdir = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else '~/v3logs/net')
os.makedirs(outdir, exist_ok=True)
path = os.path.join(outdir, time.strftime('V3HUD_%Y%m%d_%H%M%S.BIN'))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
except (AttributeError, OSError):
    pass
s.bind(('', port))
print('netlog: listening on UDP %d -> %s' % (port, path), flush=True)
n = 0
with open(path, 'ab') as f:
    while True:
        d, a = s.recvfrom(2048)
        if len(d) != 128:
            print('netlog: %s: %d bytes (not a record), skipped' % (a[0], len(d)), flush=True)
            continue
        f.write(d)
        f.flush()
        n += 1
        w = struct.unpack('<32I', d)
        tag = d[:4]
        if tag.isalpha():
            print('%5d %s %s' % (n, a[0], tag.decode()), flush=True)
        else:
            print('%5d %s seq %d gui-ms %d cpu %d scr %#x' % (n, a[0], w[0], w[1], w[28], w[29] & 0xFFFF),
                  flush=True)
