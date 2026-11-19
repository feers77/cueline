#!/usr/bin/env python3
"""lc_pcap.py -- Link Cue on the wire (independent of the fake A9's own recorder): from en4 pcaps, the decks' 0x1e
Touch Audio packets (-> mixer:50004) and the mixer's 0x20 timing packets, per source, split into bursts (> 0.5 s apart).
  lc_pcap.py MIXER_IP T0 T1 PCAP...      (T0/T1 = unix seconds window)
Per burst: packets, PCM / zero / I=1 counts, rate, arrival gaps > 15 ms (count, max), PCM peak; timing rate."""
import struct
import sys


def frames(path):
    f = open(path, 'rb')
    gh = f.read(24)
    if len(gh) < 24:
        return
    end = '<' if gh[:4] in (b'\xd4\xc3\xb2\xa1', b'\x4d\x3c\xb2\xa1') else '>'
    nano = gh[:4] in (b'\x4d\x3c\xb2\xa1', b'\xa1\xb2\x3c\x4d')
    lt = struct.unpack(end + 'I', gh[20:24])[0]
    while True:
        h = f.read(16)
        if len(h) < 16:
            return
        s, us, cl, _ = struct.unpack(end + 'IIII', h)
        d = f.read(cl)
        yield s + us / (1e9 if nano else 1e6), lt, d


def main(a):
    mixer, t0, t1 = a[0], float(a[1]), float(a[2])
    flows = {}
    for p in a[3:]:
        for t, lt, d in frames(p):
            if not t0 <= t <= t1:
                continue
            o = 14 if lt == 1 else (4 if lt == 0 else 16 if lt == 113 else 14)
            if lt == 1 and d[12:14] != b'\x08\x00':
                continue
            ip = d[o:]
            if len(ip) < 28 or ip[9] != 17:
                continue
            ihl = (ip[0] & 15) * 4
            src, dst = '.'.join(map(str, ip[12:16])), '.'.join(map(str, ip[16:20]))
            sp, dp = struct.unpack('>HH', ip[ihl:ihl + 4])
            pay = ip[ihl + 8:]
            if dp != 50004 or pay[:10] != b'Qspt1WmJOL':
                continue
            k = (src, dst, pay[10])
            flows.setdefault(k, []).append((t, pay))
    for (src, dst, ty), pk in sorted(flows.items()):
        bursts, cur = [], [pk[0]]
        for a_, b_ in zip(pk, pk[1:]):
            if b_[0] - a_[0] > 0.5:
                bursts.append(cur)
                cur = []
            cur.append(b_)
        bursts.append(cur)
        for b in bursts:
            ts = [x[0] for x in b]
            span = ts[-1] - ts[0]
            gaps = [round((y - x) * 1000, 1) for x, y in zip(ts, ts[1:]) if y - x > 0.015]
            line = '%s -> %s type 0x%02x  %s..%s  n=%d span=%.2fs rate=%.1f/s gaps>15ms=%d max=%.1fms' % (
                src, dst, ty, '%.3f' % ts[0], '%.3f' % ts[-1], len(b), span, (len(b) - 1) / span if span else 0,
                len(gaps), max(gaps or [0]))
            if ty == 0x1e:
                pcm = zero = i1 = peak = 0
                for _, p in b:
                    body = p[0x2c:0x2c + 0x540]
                    n = len(body) // 2
                    sm = struct.unpack('<%dh' % n, body[:2 * n])
                    pkk = max(max(sm), -min(sm)) if sm else 0
                    peak = max(peak, pkk)
                    pcm += pkk > 0
                    zero += pkk == 0
                    i1 += p[0x24] != 0
                line += ' pcm=%d zero=%d I1=%d peak=%d' % (pcm, zero, i1, peak)
            print(line)


if __name__ == '__main__':
    main(sys.argv[1:])
