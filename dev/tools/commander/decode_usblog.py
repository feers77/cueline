#!/usr/bin/env python3
"""decode_usblog.py -- C:/V3HUD.BIN (USB HUD log, TEST builds) -> CSV + per-step summary.

  decode_usblog.py V3HUD.BIN [--csv out.csv] [--marks SCRIPT.marks] [--json out.json] [--session N|all]

Default: the last session (one boot = one 'V3HB' record and what follows), summary to stdout.
File = 128-byte records of 32 little-endian u32 (mods/usblog/main_usblog.s, mods/v2ui/usblog.inc):
  GUI record   w0 seq, w1 GUI ms, w2..w27 v2.c HUD txt[0..25], w28 cpu %, w29 screen | model << 8
               (V4m2: | wave_type << 16 | det_blue << 18 | wblue << 19 | HW ring look << 20 | det flips << 24),
               w30 MAIN stamp: autotest step | state << 16 | why << 24, w31 (sum w0..w29 ^ 0x5A5A5A5A) & 0x7FFFFFFF
  'V3HB' boot  w1 MAIN tick, w2 drops, w3 file size at mount (RED: 0xFFFFFFFF), w4..w5 MAIN version string,
               w6 autotest built in, w7 format (2: V4n36 trace), w8..w19 the build record ('BLD1' + ASCII build ID,
               mods/usblog/README.md), w20 TEST LOG (1 USB, 2 RED); RED sends it once per boot too
  'V3MK' mark  w1 tick, w2 step, w3 the MARK's tick, w4 autotest state
  'V3US' status (V4g, one per flush) w1 tick, w2 flushes, w3 failed opens, w4 drops, w5 size, w6 pending,
         w7 ms since play, w8 D_PREVIEW, w9 MED+64, w10 usb state, w11/w12 RX magic / head, w13 last taken, w14 RX slot (V4m2),
         w15 (V4m3) own USB device settings bytes 0-2 (+6 = WAVEFORM COLOR 1 BLUE / 3 RGB) | detail mode << 24
         V4n24 (loaded-track cover / cues / title; RED mode now sends one V3US a second too):
         w16 AR_SEQ (artwork block published seq), w17 AR_TOT (bytes: 26228 = image, 16 = none), w18 AR_SENT
         (seq w8send streamed), w19 AR_STATE (tries left | software image out << 8), w20 CC_STATE | CC_TRY << 8 |
         CC_OK << 16 (CC_STATE 1 lookup pending, 2 art retry), w21 CC_SEQ, w22 CC_RB (loaded rbid), w23 JPU done & 0xFFFF |
         seq << 16, w24 JPU latch (1 = request out) | rw_art ok << 8 | JPU big image << 16, w25 w8send ST | D_LEFT << 8,
         w26 GUI LDART word (v2.c ldart_diag: seq & 0xFFF | trailer & 0xFFF << 12 | magic << 24 | len ok << 25 |
         complete << 26 | header drew: 1 MAIN cover / 2 stock slot-0 image << 27), w27 CC_KEY
  'V3AE' end   w1 tick, w2 state (3 DONE / 4 ABORT), w3 why, w4 step, w5 op index
HUD txt[] (v2.c V2_HUD, one record a second): F frames painted, G worst gap ms, D draw ms avg, C copy ms x10,
W band ms x10, X heals since boot, S latch waits timed out, P position stall ms, Q longest frame ms,
WX/KX/MX section maxima ms, B full rebuilds, V refreshes, A 60-fps frames over budget.
"""
import csv
import json
import struct
import sys

COLS = ['F', 'G', 'HB', 'D', 'LAT', 'ROWS', 'C10', 'W10', 'X', 'K10', 'M10', 'Y', 'S', 'P', 'Q', 'WX',
        'KX', 'MX', 'B', 'V', 'RBP', 'RBL', 'RBJ', 'RO', 'RZ', 'A']
HB, MK, AE, US = 0x42483356, 0x4B4D3356, 0x45413356, 0x53553356
STATES = {0: 'idle', 1: 'armed', 2: 'run', 3: 'DONE', 4: 'ABORT'}
WHY = {0: '', 1: 'real key', 2: 'rotary', 3: 'pen down', 4: 'boot state', 5: '15-min cap', 6: 'NOMODS / MODS OFF',
       7: 'bad SCRIPT.BIN'}
SCREENS = {}   # screen_mode() codes are v2.c's M_*; printed raw


def read(path):
    """[(session, kind, dict)], kind 'hud' / 'boot' / 'mark' / 'end' / 'bad'."""
    data = open(path, 'rb').read()
    out, session = [], 0
    for off in range(0, len(data) - 127, 128):
        r = struct.unpack_from('<32I', data, off)
        if r[0] == HB:
            session += 1
            ver = struct.pack('<2I', r[4], r[5]).split(b'\0')[0].decode('latin1')
            bid = ''
            if r[7] >= 2:   # V4n36 trace: w8..w19 = the MAIN build record ('BLD1' + ASCII ID), w20 TEST LOG mode
                raw = struct.pack('<12I', *r[8:20])
                bid = raw[4:].split(b'\0')[0].decode('latin1') if raw[:4] == b'BLD1' else '?'
            out.append((session, 'boot', dict(tick=r[1], drops=r[2], size=r[3], main=ver, at=r[6], bid=bid)))
        elif r[0] == MK:
            out.append((session, 'mark', dict(tick=r[1], step=r[2], mtick=r[3], state=r[4])))
        elif r[0] == US:   # V4g: the logger's own state, one per flush
            out.append((session, 'status', dict(tick=r[1], flushes=r[2], ofail=r[3], drops=r[4], size=r[5],
                                                pending=r[6], still_ms=r[7], preview=r[8], med64=r[9], usb=r[10],
                                                rxmagic=r[11], rxhead=r[12], last=r[13], slot=r[14], dev=r[15],
                                                ar_seq=r[16], ar_tot=r[17], ar_sent=r[18], ar_state=r[19],
                                                cc=r[20], cc_seq=r[21], cc_rb=r[22], jpu=r[23], jlatch=r[24],
                                                w8=r[25], ldart=r[26], cc_key=r[27])))
        elif r[0] == AE:
            out.append((session, 'end', dict(tick=r[1], state=r[2], why=r[3], step=r[4], op=r[5])))
        elif ((sum(r[:30]) ^ 0x5A5A5A5A) & 0x7FFFFFFF) != r[31]:
            out.append((session, 'bad', dict(off=off)))
        else:
            d = dict(seq=r[0], ms=r[1], cpu=r[28], screen=r[29] & 0xFF, model=(r[29] >> 8) & 0xFF,
                     wtype=(r[29] >> 16) & 3, detblue=(r[29] >> 18) & 1, wblue=(r[29] >> 19) & 1,
                     hblook=(r[29] >> 20) & 15, detflips=(r[29] >> 24) & 127,
                     step=r[30] & 0xFFFF, atst=(r[30] >> 16) & 0xFF, why=r[30] >> 24)
            d.update(zip(COLS, r[2:28]))
            out.append((session, 'hud', d))
    return out


def load_marks(path):
    m = {}
    if path:
        for ln in open(path, encoding='utf-8'):
            if '\t' in ln:
                i, t = ln.rstrip('\n').split('\t', 1)
                m[int(i)] = t
    return m


def summarize(recs):
    """Per autotest step (in first-seen order): seconds, F mean / min, G max, D mean, C / W mean (ms),
    Q max, A sum, heals (X growth), cpu max."""
    steps, order = {}, []
    prev_x = None
    for _, kind, d in recs:
        if kind != 'hud':
            continue
        s = d['step']
        if s not in steps:
            steps[s] = []
            order.append(s)
        heal = 0 if prev_x is None else max(0, d['X'] - prev_x)
        prev_x = d['X']
        steps[s].append((d, heal))
    rows = []
    for s in order:
        v = steps[s]
        n = len(v)
        f = [d['F'] for d, _ in v]
        rows.append(dict(step=s, n=n, F=sum(f) / n, Fmin=min(f), G=max(d['G'] for d, _ in v),
                         D=sum(d['D'] for d, _ in v) / n, C=sum(d['C10'] for d, _ in v) / n / 10.0,
                         W=sum(d['W10'] for d, _ in v) / n / 10.0, Q=max(d['Q'] for d, _ in v),
                         A=sum(d['A'] for d, _ in v), heals=sum(h for _, h in v),
                         cpu=max(d['cpu'] for d, _ in v)))
    return rows


def table(rows, marks):
    L = ['%-6s %-26s %4s %6s %4s %4s %5s %5s %5s %4s %5s %5s %4s' % (
        'step', 'label', 'sec', 'F', 'Fmin', 'G', 'D', 'C', 'W', 'Q', 'A', 'heals', 'cpu')]
    for r in rows:
        L.append('%-6d %-26.26s %4d %6.1f %4d %4d %5.1f %5.1f %5.1f %4d %5d %5d %4d' % (
            r['step'], marks.get(r['step'], ''), r['n'], r['F'], r['Fmin'], r['G'], r['D'], r['C'], r['W'],
            r['Q'], r['A'], r['heals'], r['cpu']))
    return '\n'.join(L)


def main(argv):
    if len(argv) < 2 or argv[1] in ('-h', '--help'):
        sys.exit(__doc__)
    opt = {}
    a = argv[2:]
    while a:
        k = a.pop(0)
        opt[k] = a.pop(0)
    recs = read(argv[1])
    sessions = sorted({s for s, _, _ in recs})
    want = opt.get('--session', str(sessions[-1]) if sessions else '0')
    if want != 'all':
        recs = [r for r in recs if r[0] == int(want)]
    marks = load_marks(opt.get('--marks'))
    hud = [d for _, k, d in recs if k == 'hud']
    bad = sum(1 for _, k, _ in recs if k == 'bad')
    print('# %s: %d sessions in the file; session %s: %d HUD records (%d s), %d bad' % (
        argv[1], len(sessions), want, len(hud), len(hud), bad))
    for s, kind, d in recs:
        if kind == 'boot':
            print('# session %d boot: MAIN %s, tick %d, file %d B at mount, drops %d, autotest %s%s' % (
                s, d['main'], d['tick'], d['size'], d['drops'], 'yes' if d['at'] else 'no',
                ', BUILD ' + d['bid'] if d.get('bid') else ''))
        elif kind == 'end':
            print('# autotest %s at step %d (%s), op %d, tick %d%s' % (
                STATES.get(d['state'], d['state']), d['step'], marks.get(d['step'], ''), d['op'], d['tick'],
                (' -- why: ' + WHY.get(d['why'], str(d['why']))) if d['state'] == 4 else ''))
    st = [d for _, k, d in recs if k == 'status']
    if st:
        d = st[-1]
        print('# %d flushes (V3US); last: tick %d, flush #%d, failed opens %d, pending %d, still %d ms, '
              'preview %#x, MED+64 %#x, usb %d, RX head %d (slot %d), last taken %d; RX block seen at %d of %d flushes' % (
                  len(st), d['tick'], d['flushes'], d['ofail'], d['pending'], d['still_ms'], d['preview'],
                  d['med64'], d['usb'], d['rxhead'], d['slot'], d['last'], sum(1 for x in st if x['rxmagic'] == 0x48554431), len(st)))
        dv = sorted(set(x['dev'] for x in st))
        print('# V3US w15 (V4m3): USB WAVEFORM COLOR / detail mode seen: %s' % ', '.join(
            '%s/%s' % ({1: 'BLUE', 3: 'RGB'}.get((v >> 16) & 0xFF, (v >> 16) & 0xFF), {1: 'RGB', 0: 'BLUE'}.get(v >> 24, v >> 24))
            for v in dv))
        prev = None
        for x in st:   # V4n24: the artwork / cue chain, printed whenever it changes
            g = x['ldart']
            cur = ('AR seq %d tot %d sent %d state %#x | CC state %d try %d ok %d seq %d rb %d key %#x | JPU done %#x seq %#x '
                   'latch %d rwok %d big %d | w8 ST %d left %d | GUI LDART seq %d trailer %d magic %d len %d complete %d hdr %s') % (
                x['ar_seq'], x['ar_tot'], x['ar_sent'], x['ar_state'], x['cc'] & 0xFF, (x['cc'] >> 8) & 0xFF,
                (x['cc'] >> 16) & 0xFF, x['cc_seq'], x['cc_rb'], x['cc_key'], x['jpu'] & 0xFFFF, x['jpu'] >> 16,
                x['jlatch'] & 0xFF, (x['jlatch'] >> 8) & 0xFF, (x['jlatch'] >> 16) & 0xFF, x['w8'] & 0xFF, x['w8'] >> 8,
                g & 0xFFF, (g >> 12) & 0xFFF, (g >> 24) & 1, (g >> 25) & 1, (g >> 26) & 1,
                {0: 'none', 1: 'MAIN', 2: 'stock'}.get((g >> 27) & 3, '?'))
            if cur != prev:
                print('# art tick %d: %s' % (x['tick'], cur))
                prev = cur
    nmk = sum(1 for _, k, _ in recs if k == 'mark')
    seqs = [d['seq'] for d in hud]
    gaps = sum(1 for x, y in zip(seqs, seqs[1:]) if y != x + 1)
    print('# %d step marks; GUI seq %s..%s, %d gaps' % (nmk, seqs[0] if seqs else '-', seqs[-1] if seqs else '-', gaps))
    rows = summarize(recs)
    print(table(rows, marks))
    if '--csv' in opt:
        with open(opt['--csv'], 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(['seq', 'gui_ms', 'step', 'label', 'at_state'] + COLS + ['cpu', 'screen', 'model', 'wtype', 'detblue', 'wblue', 'hblook', 'detflips'])
            for d in hud:
                w.writerow([d['seq'], d['ms'], d['step'], marks.get(d['step'], ''), d['atst']] +
                           [d[c] for c in COLS] + [d['cpu'], d['screen'], d['model'], d['wtype'], d['detblue'], d['wblue'],
                                                    d['hblook'], d['detflips']])
    if '--json' in opt:
        json.dump(dict(file=argv[1], session=want, marks={str(k): v for k, v in marks.items()}, steps=rows,
                       ends=[d for _, k, d in recs if k == 'end']), open(opt['--json'], 'w'), indent=1)


if __name__ == '__main__':
    main(sys.argv)
