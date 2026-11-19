#!/usr/bin/env python3
"""pcapsum.py PCAP [SRC_IP|any] : per (src, dport, type, len) count, rate, varying bytes, first payload (Pro DJ Link)."""
import socket, struct, sys
MAGIC = b'Qspt1WmJOL'
def pkts(fn):
    d = open(fn, 'rb').read(); end = '<' if d[:4] == b'\xd4\xc3\xb2\xa1' else '>'
    lt = struct.unpack(end + 'I', d[20:24])[0]; i = 24
    while i + 16 <= len(d):
        ts, tu, incl, _ = struct.unpack(end + 'IIII', d[i:i + 16]); p = d[i + 16:i + 16 + incl]; i += 16 + incl
        if lt == 113: p = p[2:]                     # linux cooked: make it look like ethernet (16 B -> 14)
        if len(p) < 42 or p[12:14] != b'\x08\x00' or p[23] != 17: continue
        ihl = (p[14] & 15) * 4; u = 14 + ihl
        sp, dp, ul = struct.unpack_from('>HHH', p, u)
        yield ts + tu / 1e6, socket.inet_ntoa(p[26:30]), socket.inet_ntoa(p[30:34]), sp, dp, p[u + 8:u + ul], p[6:12]
def main():
    fn = sys.argv[1]; want = sys.argv[2] if len(sys.argv) > 2 else 'any'
    g = {}
    for t, s, dst, sp, dp, pay, mac in pkts(fn):
        if want != 'any' and s != want: continue
        ty = pay[10] if pay[:10] == MAGIC and len(pay) > 10 else -1
        k = (s, dst, dp, ty, len(pay))
        e = g.setdefault(k, dict(n=0, t0=t, t1=t, first=pay, var=set(), mac=mac.hex(':')))
        e['n'] += 1; e['t1'] = t
        e['var'].update(i for i in range(min(len(pay), len(e['first']))) if pay[i] != e['first'][i])
    for k, e in sorted(g.items()):
        dur = e['t1'] - e['t0']; rate = (e['n'] - 1) / dur if dur > 0 else 0
        v = sorted(e['var']); vs = ','.join('%x' % x for x in v[:40]) + ('...' if len(v) > 40 else '')
        print('%s>%s :%d type %s len %d n %d  %.2f/s  mac %s  var[%s]' % (k[0], k[1], k[2], hex(k[3]), k[4], e['n'], rate, e['mac'], vs))
        print('    ' + e['first'][:0x40].hex(' ') + (' | ' + e['first'][0x40:0x80].hex(' ') if len(e['first']) > 0x40 else ''))
main()
