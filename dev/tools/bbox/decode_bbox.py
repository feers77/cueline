#!/usr/bin/env python3
"""decode_bbox.py FILE... : the BLACK BOX (mods/bbox) as a human-readable timeline.

FILE is any of:
  - C:/BLACKBOX.BIN from the stick: one or more dumps, each a 256-byte 'BBX1' header + n x 16-byte events
  - a TEST LOG = RED network log (tools/commander/netlog.py V3HUD_*.BIN, 128-byte records): the 'V3BB' records
    are taken, every other record is skipped
  - an emu stick image (*.img, FAT at 1 MiB): BLACKBOX.BIN is read out of it with mcopy

Options: --last (only the last dump of each file), --raw (also the raw words).
Event: {u32 tick ms, u32 type | entry << 8 | b << 16, u32 c, u32 d}; see main_bbox.s for the table.
"""
import os
import struct
import subprocess
import sys
import tempfile

ENTRY = {0: 'play mode', 1: 'own track', 2: 'own flags', 3: 'tempo master', 4: 'KEY SYNC', 5: 'KEY SYNC refusal',
         6: 'KEY SHIFT', 7: 'KEY SHIFT semis', 8: 'LC preview', 9: 'LC E', 10: 'LC T',
         11: 'LC zero-filled packets (underrun)', 12: 'LC pacer resyncs', 13: 'LC failed sends',
         14: 'LC election timeouts', 15: 'LC failed opens', 16: 'LC kill edges',
         17: 'NFS lookup tries (W8N)', 18: 'cue/tag lookups (CC_TRY)'}
PMODE = {0: 'no track', 1: '1?', 2: 'LOADING', 3: 'PLAYING', 4: 'LOOPING', 5: 'PAUSED', 6: 'CUED', 7: 'CUE PLAY',
         8: 'CUE SCRATCH', 9: 'SEARCH', 0x0E: 'SPUN DOWN', 0x11: 'END'}
SLOT = {0: '-', 1: 'CD', 2: 'SD', 3: 'USB', 4: 'rekordbox'}
TYPE = {1: 'rekordbox', 2: 'file', 5: 'CD'}
REASON = {1: 'KEY SHIFT off', 2: 'no GUI key word', 3: 'keys not known / no other master', 4: 'other'}
DEVS = (1, 2, 3, 4, 5, 6, 17, 18, 33)
DUMPRES = {0: 'ok', 1: 'SHORT WRITE', 2: 'OPEN FAILED'}
ERRORS = {13, 15}   # error-class entries


def be32(v):
    return struct.unpack('>I', struct.pack('<I', v))[0]


def mask_devs(m):
    return ','.join(('mixer' if d == 33 else 'rb%d' % (d - 16) if d in (17, 18) else 'P%d' % d)
                    for k, d in enumerate(DEVS) if m >> k & 1) or 'none'


def flags(v):
    return '/'.join(n for b, n in ((0x20, 'MASTER'), (0x10, 'SYNC'), (0x08, 'ON AIR')) if v & b) or '-'


def ascii8(a, b):
    return struct.pack('<II', a, b).split(b'\0')[0].decode('latin1')


def event(w1, c, d):
    t, e, b = w1 & 0xFF, (w1 >> 8) & 0xFF, w1 >> 16
    if t == 1:
        return 'BOOT', 'MAIN %s' % ascii8(c, d)
    if t == 2:
        return 'PLAY', '%s -> %s' % (PMODE.get(c, hex(c)), PMODE.get(d, hex(d)))
    if t == 3:
        if not d:
            return 'LOAD', 'own track cleared'
        return 'LOAD', 'player %d slot %s type %s rbid %d' % (c & 0xFF, SLOT.get((c >> 8) & 0xFF, (c >> 8) & 0xFF),
                                                              TYPE.get((c >> 16) & 0xFF, (c >> 16) & 0xFF), be32(d))
    if t == 4:
        bad = d == 0 or c >= 20000
        return ('LOAD END' + (' !!' if bad else ''),
                'took %d ms, now %s, track %d:%02d' % (c, PMODE.get(d, hex(d)), b // 60, b % 60))
    if t == 5:
        on, off = d & ~c, c & ~d
        s = []
        for bit, n in ((0x10, 'SYNC'), (0x20, 'MASTER'), (0x08, 'ON AIR')):
            if on & bit:
                s.append(n + ' on')
            if off & bit:
                s.append(n + ' off')
        return 'FLAGS', ', '.join(s) + '  (%s)' % flags(d)
    if t == 6:
        pn = lambda v: 'none' if v in (0, 255) else v
        return 'MASTER', 'player %s -> %s' % (pn(c), pn(d))
    if t == 7:
        return 'KEY SYNC', 'ON' if d else 'OFF'
    if t == 8:
        return 'KEY SYNC REFUSED', '%s (GUI word %#010x)' % (REASON.get(c, c), d)
    if t == 9:
        return 'KEY SHIFT', 'ON' if d else 'OFF'
    if t == 10:
        sv = lambda v: v - (1 << 32) if v & 0x80000000 else v
        return 'KEY SHIFT', 'semitones %+d -> %+d' % (sv(c), sv(d))
    if t == 11:
        return 'LINK CUE', 'preview streaming %s' % ('START' if d else 'STOP')
    if t == 12:
        return 'LINK CUE', 'mixer LINK CUE %s (E %d)' % ('on' if d else 'off', d)
    if t == 13:
        return 'LINK CUE', ('ELECTED (T %d)' % d) if d == 17 else 'not elected (T %d -> %d)' % (c, d)
    if t == 14:
        return 'LINK CUE' + (' !!' if e in ERRORS else ''), '%s +%d (%d)' % (ENTRY.get(e, e), d - c, d)
    if t == 15:
        return 'NET RETRY', '%s +%d (%d)' % (ENTRY.get(e, e), d - c, d)
    if t == 16:
        on, off = d & ~c, c & ~d
        s = ['%s joined' % mask_devs(on)] if on else []
        s += ['%s left' % mask_devs(off)] if off else []
        return 'LINK', ', '.join(s) + '  (now %s)' % mask_devs(d)
    if t == 17:
        return 'DUMP REQUEST', 'manual (MENU+BACK 3 s)' if b == 0 else 'auto, trigger %s' % TNAME.get(c, c)
    if t == 18:
        return 'DUMP', '#%d %s' % (d, DUMPRES.get(c, c))
    return 'type %d' % t, 'entry %d b %d c %#x d %#x' % (e, b, c, d)


TNAME = {4: 'LOAD END', 14: 'LINK CUE counter', 0: 'manual'}


def fmt_t(ms, t0):
    s = (ms - t0) / 1000.0
    return '%9.3f' % s


def show_events(evs, raw, t0=None):
    if not evs:
        print('  (no events)')
        return
    t0 = evs[0][0] if t0 is None else t0
    for tick, w1, c, d in evs:
        name, text = event(w1, c, d)
        line = '  %s s  [%10d]  %-18s %s' % (fmt_t(tick, t0), tick, name, text)
        if raw:
            line += '   (%08x %08x %08x)' % (w1, c, d)
        print(line)


def dumps(data):
    o = 0
    while o + 256 <= len(data):
        if data[o:o + 4] != b'BBX1':
            j = data.find(b'BBX1', o + 1)
            if j < 0:
                print('  %d trailing bytes without a header' % (len(data) - o))
                return
            print('  skipped %d bytes to the next header' % (j - o))
            o = j
            continue
        h = struct.unpack_from('<64I', data, o)
        n = h[4]
        evs = [struct.unpack_from('<4I', data, o + 256 + 16 * k) for k in range(n)
               if o + 256 + 16 * (k + 1) <= len(data)]
        yield h, data[o:o + 256], evs
        o += 256 + 16 * n


def show_dump(h, hb, evs, raw):
    reason, trig, seq = h[5] & 0xFF, (h[5] >> 8) & 0xFF, h[5] >> 16
    bld = hb[48:96]
    bid = bld[4:].split(b'\0')[0].decode('latin1') if bld[:4] == b'BLD1' else '(no build record)'
    print('=== dump #%d  %s%s  at tick %d (requested %d)' % (
        seq, 'MANUAL' if reason == 1 else 'AUTO', '' if reason == 1 else ' (trigger %s)' % TNAME.get(trig, trig),
        h[2], h[6]))
    print('    build %s   MAIN %s   events %d written, %d in this dump (%d older lost)' % (
        bid, ascii8(h[8], h[9]), h[3], h[4], h[3] - h[4]))
    v = h[24:24 + 32]
    rb = be32(v[1])
    print('    state: play %s, own track %s, flags %s, master %s, LINK %s, KEY SYNC %s, KEY SHIFT %s %+d, LC E%d T%d' % (
        PMODE.get(h[11], h[11]), 'rbid %d' % rb if rb else '-', flags(v[2]), v[3] or 'none', mask_devs(h[10]),
        'on' if v[4] else 'off', 'on' if v[6] else 'off', v[7] - (1 << 32) if v[7] & 0x80000000 else v[7],
        v[9], v[10]))
    print('    counters: ' + ', '.join('%s %d' % (ENTRY[k], v[k]) for k in range(11, 19)))
    show_events(evs, raw)


def netlog(data, raw):
    evs, recs, last = [], 0, None
    for o in range(0, len(data) - 127, 128):
        r = data[o:o + 128]
        if r[:4] != b'V3BB':
            continue
        recs += 1
        w = struct.unpack('<32I', r)
        seq, n = w[2], w[3]
        if last is not None and seq > last:
            evs.append((None, seq - last))
        for k in range(min(n, 7)):
            evs.append(struct.unpack_from('<4I', r, 16 + 16 * k))
        last = seq + n
    print('=== network log: %d V3BB records' % recs)
    out = [e for e in evs if e[0] is not None]
    t0 = out[0][0] if out else 0
    for e in evs:
        if e[0] is None:
            print('  ... %d events lost' % e[1])
        else:
            show_events([e], raw, t0)


def read(path):
    if path.endswith('.img'):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, 'BLACKBOX.BIN')
            r = subprocess.run(['mcopy', '-n', '-i', path + '@@1M', '::BLACKBOX.BIN', out],
                               env=dict(os.environ, MTOOLS_SKIP_CHECK='1'), capture_output=True)
            if r.returncode:
                sys.exit('%s: no BLACKBOX.BIN (%s)' % (path, r.stderr.decode().strip()))
            return open(out, 'rb').read()
    return open(path, 'rb').read()


def main(argv):
    raw = '--raw' in argv
    last = '--last' in argv
    files = [a for a in argv if not a.startswith('--')]
    if not files:
        sys.exit(__doc__)
    for f in files:
        data = read(f)
        print('%s (%d bytes)' % (f, len(data)))
        if data[:4] == b'BBX1':
            ds = list(dumps(data))
            print('  %d dump(s)' % len(ds))
            for h, hb, evs in ds[-1:] if last else ds:
                show_dump(h, hb, evs, raw)
        else:
            netlog(data, raw)


if __name__ == '__main__':
    main(sys.argv[1:])
