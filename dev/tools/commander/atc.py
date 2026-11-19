#!/usr/bin/env python3
"""atc.py -- AUTOTEST script compiler / generator / emulator runner (TEST builds only).

  atc.py build SCRIPT.TXT OUT.BIN     compile to the bytecode mods/autotest runs (+ OUT.marks: id<TAB>label)
  atc.py full N [OUT.TXT]             the default full test for tracks 1..N (tests/v4_full.txt = N 3)
  atc.py emu SCRIPT.TXT [I=inst]      run the same script on the local emulator through bin/emu
                                      key/rot/touch (socket input: no firmware hook, plays in the emu)
  atc.py dump OUT.BIN                 list a compiled script

Script: one command per line, '#' comments.
  KEY name [ms]        named key (table below), default 120 ms (10..500)
  KEY 0xOFF 0xBIT [ms] emulator panel bit (layout A); mapped to the level word
  ROT n                rotary detents (signed); player screen = waveform zoom, lists = cursor
  TOUCH x y [ms]       screen point in pixels (800x480), default 150 ms; WAIT after it
  WAIT ms
  MARK id [text]       step id (1..65535) -> AT_STEP: the USB log stamps every record with it
  LOOP n ... END       nested up to 4
Stick: C:/V3TEST/SCRIPT.BIN (+ an empty C:/V3HUD.BIN for the log). Docs: DEV_TOOLS.md.
"""
import os
import struct
import subprocess
import sys
import time

# name: (level offset from 0x0B54C990, emu offset, emu bit). Level words are the panel
# decoder's per-key outputs (setters 0x084E10BC..0x084E1A36, deck 0); they do not depend on
# the panel layout (A = old panel fw < 0x20, the emulator; B = newer, other bit positions).
KEYS = {
    'PLAY': (0x190, 0x10, 0x01), 'CUE': (0x194, 0x10, 0x02),
    'BROWSE': (0x020, 0x14, 0x01), 'TAGLIST': (0x024, 0x14, 0x02),
    'INFO': (0x028, 0x14, 0x04), 'MENU': (0x02C, 0x14, 0x08),
    'BACK': (0x03C, 0x14, 0x10), 'TAGTRACK': (0x040, 0x14, 0x20),
    'PUSH': (0x038, 0x11, 0x01), 'SHORTCUT': (0x048, 0x11, 0x80),
    'REKORDBOX': (0x00C, 0x13, 0x01), 'LINK': (0x010, 0x13, 0x02),
    'USB': (0x014, 0x13, 0x04), 'SD': (0x018, 0x13, 0x08), 'DISC': (0x01C, 0x13, 0x10),
    'TRACKREV': (0x14C, 0x12, 0x04), 'TRACKFWD': (0x148, 0x12, 0x08),
    'SEARCHREV': (0x19C, 0x12, 0x10), 'SEARCHFWD': (0x198, 0x12, 0x20),
    'LOOPIN': (0x1BC, 0x10, 0x10), 'LOOPOUT': (0x1C0, 0x10, 0x08),
    'RELOOP': (0x1D0, 0x10, 0x04), 'TIMEMODE': (0x120, 0x13, 0x20),
    'MASTER': (0x16C, 0x15, 0x04), 'SYNC': (0x168, 0x15, 0x02),
    'TEMPORANGE': (0x174, 0x15, 0x08), 'MASTERTEMPO': (0x17C, 0x15, 0x10),
}
BY_BIT = {(o, b): n for n, (l, o, b) in KEYS.items()}
OP = dict(END=0, KEY=1, ROT=2, TOUCH=3, WAIT=4, MARK=5, LOOP=6, ENDL=7)
OPN = {v: k for k, v in OP.items()}
MAGIC = b'ATS1'
MAX_OPS = 480              # mods/autotest reads at most 16 + 480 x 8 bytes

# V3 SHORTCUT page, WAVEFORM COLOR tiles (V3rc8y2: x 452 / 516 / 579, y 181, 63 x 42): centres
TILES = {'BLUE': (483, 202), 'RGB': (547, 202), '3BAND': (610, 202)}
RAIL_TRACK = (28, 160)     # the browser's left rail: TRACK (V3e1 3000 browser)


def parse(path):
    out, depth = [], 0
    for ln, raw in enumerate(open(path, encoding='utf-8'), 1):
        t = raw.split('#', 1)[0].split()
        if not t:
            continue
        c, a = t[0].upper(), t[1:]
        try:
            if c == 'KEY':
                if a[0].upper() in KEYS:
                    name, ms = a[0].upper(), int(a[1]) if len(a) > 1 else 120
                else:
                    name = BY_BIT[(int(a[0], 0), int(a[1], 0))]
                    ms = int(a[2]) if len(a) > 2 else 120
                if not 10 <= ms <= 500:
                    raise ValueError('key held %d ms: 10..500 (a held key freezes the panel decode)' % ms)
                out.append(('KEY', name, ms))
            elif c == 'ROT':
                n = int(a[0])
                while n:  # one op per <= 100 detents
                    s = max(-100, min(100, n))
                    out.append(('ROT', s))
                    n -= s
            elif c == 'TOUCH':
                x, y, ms = int(a[0]), int(a[1]), int(a[2]) if len(a) > 2 else 150
                if not (0 < x < 800 and 0 < y < 480) or not 10 <= ms <= 2000:
                    raise ValueError('touch outside 800x480 or ms not 10..2000')
                out.append(('TOUCH', x, y, ms))
            elif c == 'WAIT':
                out.append(('WAIT', int(a[0])))
            elif c == 'MARK':
                i = int(a[0], 0)
                if not 0 < i < 65536:
                    raise ValueError('MARK id 1..65535')
                out.append(('MARK', i, ' '.join(a[1:])))
            elif c == 'LOOP':
                depth += 1
                if depth > 4:
                    raise ValueError('LOOP nested deeper than 4')
                out.append(('LOOP', int(a[0])))
            elif c == 'END':
                depth -= 1
                if depth < 0:
                    raise ValueError('END without LOOP')
                out.append(('ENDL',))
            else:
                raise ValueError('unknown command %s' % c)
        except (IndexError, KeyError, ValueError) as e:
            sys.exit('%s:%d: %s (%s)' % (path, ln, raw.strip(), e))
    if depth:
        sys.exit('%s: LOOP without END' % path)
    return out


def build(cmds):
    ops = []
    for c in cmds:
        k = c[0]
        if k == 'KEY':
            ops.append(struct.pack('<BBHI', OP['KEY'], 1, KEYS[c[1]][0], c[2]))
        elif k == 'ROT':
            ops.append(struct.pack('<BbHI', OP['ROT'], c[1], 0, 0))
        elif k == 'TOUCH':
            ops.append(struct.pack('<BBHI', OP['TOUCH'], 0, c[1], c[2] | c[3] << 16))
        elif k == 'WAIT':
            ops.append(struct.pack('<BBHI', OP['WAIT'], 0, 0, c[1]))
        elif k == 'MARK':
            ops.append(struct.pack('<BBHI', OP['MARK'], 0, c[1], 0))
        elif k == 'LOOP':
            ops.append(struct.pack('<BBHI', OP['LOOP'], 0, c[1], 0))
        elif k == 'ENDL':
            ops.append(struct.pack('<BBHI', OP['ENDL'], 0, 0, 0))
    ops.append(bytes(8))
    if len(ops) > MAX_OPS:
        sys.exit('too many ops: %d > %d' % (len(ops), MAX_OPS))
    body = b''.join(ops)
    return MAGIC + struct.pack('<HH', len(ops), sum(body) & 0xFFFF) + bytes(8) + body


def marks(cmds):
    return {c[1]: c[2] for c in cmds if c[0] == 'MARK'}


def duration_ms(cmds):
    """Rough script length (keys + waits + rotary pacing at 12 panel frames a detent)."""
    def run(seq):
        t, i = 0, 0
        while i < len(seq):
            c = seq[i]
            if c[0] == 'KEY':
                t += c[2] + 40
            elif c[0] == 'ROT':
                t += abs(c[1]) * 160
            elif c[0] == 'WAIT':
                t += c[1]
            elif c[0] == 'LOOP':
                depth, j = 1, i + 1
                while depth:
                    depth += {'LOOP': 1, 'ENDL': -1}.get(seq[j][0], 0)
                    j += 1
                t += c[1] * run(seq[i + 1:j - 1])
                i = j - 1
            i += 1
        return t
    return run(cmds)


def dump(data):
    n, s = struct.unpack_from('<HH', data, 4)
    print('%s ops %d sum %#06x (calc %#06x)' % (data[:4], n, s, sum(data[16:16 + 8 * n]) & 0xFFFF))
    for i in range(n):
        op, a, b, c = struct.unpack_from('<BbHI', data, 16 + 8 * i)
        name = OPN.get(op, '?')
        if name == 'KEY':
            key = [k for k, v in KEYS.items() if v[0] == b]
            print('%3d KEY %s %d ms' % (i, key[0] if key else hex(b), c))
        elif name == 'TOUCH':
            print('%3d TOUCH %d %d %d ms' % (i, b, c & 0xFFFF, c >> 16))
        else:
            print('%3d %s a=%d b=%d c=%d' % (i, name, a, b, c))


def full(n_tracks):
    """The default V4 test: per track browse -> load -> play -> 4 zoom levels -> the three
    waveform colours (SHORTCUT tiles) -> MENU -> INFO -> pause. MARK = track * 100 + step."""
    L = ['# V4 full autotest (atc.py full %d): tracks 1..%d of the TRACK list (rekordbox export).' % (n_tracks, n_tracks),
         '# MARK id = track * 100 + step. Compile: atc.py build v4_full.txt SCRIPT.BIN -> stick C:/V3TEST/.',
         'MARK 1 settle', 'WAIT 3000']
    for t in range(1, n_tracks + 1):
        m = t * 100
        L += ['', '# ---- track %d' % t,
              'MARK %d t%d browse' % (m + 1, t),
              'KEY %s' % ('USB' if t == 1 else 'BROWSE'), 'WAIT 4000',
              'TOUCH %d %d 150    # rail: TRACK (top of the TRACK list)' % RAIL_TRACK, 'WAIT 3000',
              'ROT -10', 'WAIT 1500']
        if t > 1:
            L += ['ROT %d' % (t - 1), 'WAIT 1500']
        L += ['MARK %d t%d load' % (m + 2, t),
              'KEY PUSH', 'WAIT 8000',
              'MARK %d t%d play' % (m + 3, t),
              'KEY PLAY', 'WAIT 6000']
        for z in range(1, 4):
            L += ['MARK %d t%d zoom+%d' % (m + 10 + z, t, z), 'ROT 1', 'WAIT 2500']
        L += ['MARK %d t%d zoom back' % (m + 14, t), 'ROT -3', 'WAIT 2500']
        for k, (col, (x, y)) in enumerate(TILES.items()):
            L += ['MARK %d t%d shortcut %s' % (m + 20 + k * 2, t, col),
                  'KEY SHORTCUT', 'WAIT 2500', 'TOUCH %d %d 200' % (x, y), 'WAIT 1500',
                  'KEY SHORTCUT', 'WAIT 1500',
                  'MARK %d t%d play %s' % (m + 21 + k * 2, t, col), 'WAIT 4000']
        L += ['MARK %d t%d menu' % (m + 30, t), 'KEY MENU', 'WAIT 2500', 'KEY BACK', 'WAIT 2000',
              'MARK %d t%d info' % (m + 31, t), 'KEY INFO', 'WAIT 2500', 'KEY INFO', 'WAIT 2000',
              'MARK %d t%d pause' % (m + 40, t), 'KEY PLAY', 'WAIT 4000']
    L += ['', 'MARK 9999 done', 'WAIT 1000']
    return '\n'.join(L) + '\n'


def emu_run(cmds, inst):
    L = os.environ.get('EMU_LOCAL', 'emu-local')
    env = dict(os.environ, I=inst)

    def emu(*a):
        subprocess.run([L + '/bin/emu'] + [str(x) for x in a], cwd=L, env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def run(seq):
        i = 0
        while i < len(seq):
            c = seq[i]
            k = c[0]
            if k == 'KEY':
                lvl, o, b = KEYS[c[1]]
                emu('key', hex(o), hex(b), c[2])
                time.sleep(0.04)
            elif k == 'ROT':
                step = 1 if c[1] > 0 else -1
                for _ in range(abs(c[1])):
                    emu('rot', step)
                    time.sleep(0.16)
            elif k == 'TOUCH':
                emu('touch', c[1], c[2], c[3])
            elif k == 'WAIT':
                time.sleep(c[1] / 1000.0)
            elif k == 'MARK':
                print('%.1f MARK %d %s' % (time.time(), c[1], c[2]), flush=True)
            elif k == 'LOOP':
                depth, j = 1, i + 1
                while depth:
                    depth += {'LOOP': 1, 'ENDL': -1}.get(seq[j][0], 0)
                    j += 1
                for _ in range(c[1]):
                    run(seq[i + 1:j - 1])
                i = j - 1
            i += 1

    run(cmds)


def main(argv):
    if len(argv) < 3 or argv[1] not in ('build', 'emu', 'full', 'dump'):
        sys.exit(__doc__)
    if argv[1] == 'full':
        txt = full(int(argv[2]))
        if len(argv) > 3:
            open(argv[3], 'w').write(txt)
        else:
            sys.stdout.write(txt)
        return
    if argv[1] == 'dump':
        dump(open(argv[2], 'rb').read())
        return
    cmds = parse(argv[2])
    if argv[1] == 'build':
        data = build(cmds)
        open(argv[3], 'wb').write(data)
        mk = os.path.splitext(argv[3])[0] + '.marks'
        with open(mk, 'w') as f:
            for i, t in sorted(marks(cmds).items()):
                f.write('%d\t%s\n' % (i, t))
        print('%s: %d ops, %d bytes, ~%.0f s; marks -> %s' % (argv[3], len(data) // 8 - 2, len(data),
                                                             duration_ms(cmds) / 1000.0, mk))
    else:
        inst = argv[3][2:] if len(argv) > 3 and argv[3].startswith('I=') else 'e'
        emu_run(cmds, inst)


if __name__ == '__main__':
    main(sys.argv)
