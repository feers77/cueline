#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Pre-render the V2 UI fonts into 4-bit alpha atlases -> font.c.

    usage: fontgen.py --cueline <out font.c>    our face (default build, OFL, in the tree)
           fontgen.py <face.ttf> <out font.c>   any other TTF at the nominal em sizes
                                                (an override TTF)

Default face: Cueline Sans (fonts/CuelineSans, a modified Outfit, SIL OFL 1.1;
fonts/CuelineSans/build_font.py). Each UI font is fitted to the UI's layout
grid (GRID: cell height, baseline, cap height in pixels -- the numbers v2.c's
layout is drawn on): the em size is chosen so the hinted cap height lands on
whole pixels exactly, the baseline sits at the grid's row, so stems and the
cap/x-height edges are crisp and nothing in v2.c moves. Text sizes use the
Regular cut, the big counters the lighter Display cut; figures are tabular
(equal advances: BPM / time do not jitter). The smallest sizes (<= 12 px) get
a slight alpha gamma so 1-px stems keep full contrast on the deck LCD.

Each font: a cell height, a baseline and a charset; each glyph is stored as
its advance, its ink box (x offset, width) and 4-bpp rows (two pixels a byte,
high nibble first) of the full cell height. The renderer blends a glyph over
a known background with a 16-entry colour ramp, so the atlas carries no colour.
Pioneer fonts are never part of the repository: use an open font.
"""
import sys
import os
from PIL import Image, ImageDraw, ImageFont

ASCII = ''.join(chr(c) for c in range(32, 127))
LATIN1 = ''.join(chr(c) for c in range(0xA0, 0x100))
DIGITS = '0123456789:.-+% '

# name, pixel size (TrueType em), charset
FONTS = [
    ('f_s', 12, ASCII + '\u00b1'),             # labels: TRACK, REMAIN, TEMPO, BPM, PLAYER ...
    ('f_m', 20, ASCII + LATIN1),    # list rows, tiles, pop-ups
    ('f_ti', 23, ASCII + LATIN1),   # PLAYERSCALE phase 4: the player header's title and sub-line (the 3000's cap 25-26 -> 16)
    ('f_l', 34, DIGITS),            # TRACK number, tempo %, small boxes
    ('f_xl', 50, DIGITS),           # REMAIN, BPM integer
    ('f_md', 24, DIGITS),           # milliseconds, BPM decimal
    ('f_sd', 18, DIGITS + '/'),     # + '/': the QUANTIZE value (PLAYERSCALE)
    ('f_t', 10, DIGITS + 'ABCDEFGHIJKLMNOPQRSTUVWXYZ/()'),   # V3c: overview ruler, hot-cue letters, beat numbers
    ('f_bpm', 42, DIGITS),          # BPM box integer (fits the box under its label, as the 3000)           # BPM second decimals (BPM DECIMALS ON)
]
# V4k (GUI section <= stock with KEY SHIFT): CDJ_V2_FONTTRIM=1 keeps only the glyphs each big digit font
# is drawn with (v2.c: f_xl "--:--" / mm:ss, f_bpm the BPM integer, f_md ".---" / ms / BPM decimal, f_sd
# the BPM decimals); a missing glyph draws nothing (glyph() returns 0)
if os.environ.get('CDJ_V2_FONTTRIM') == '1':
    TRIM = {'f_l': '0123456789:.-+', 'f_xl': '0123456789:-', 'f_bpm': '0123456789-', 'f_md': '0123456789.-', 'f_sd': '0123456789.-/'}
    # f_m: of U+00A0..U+00BF only the ones a title plausibly carries (NBSP, inverted marks, (c), (R), degree,
    # acute, middle dot); a dropped one shows as '?'
    TRIM['f_m'] = ''.join(ch for ch in ASCII + LATIN1 if not 0xA2 <= ord(ch) <= 0xBE or ch in '\u00a9\u00ae\u00b0\u00b4\u00b7')
    TRIM['f_ti'] = TRIM['f_m']
    FONTS = [(n, z, TRIM.get(n, c)) for n, z, c in FONTS]


HERE = os.path.dirname(os.path.abspath(__file__))
CUELINE = os.path.join(HERE, 'fonts', 'CuelineSans')
# UI layout grid: name -> (cell height, baseline row, cap height) in px
GRID = {'f_s': (15, 12, 9), 'f_m': (25, 20, 14), 'f_ti': (29, 23, 16), 'f_l': (42, 33, 24), 'f_xl': (61, 49, 36),
        'f_md': (30, 24, 17), 'f_sd': (23, 18, 13), 'f_t': (13, 10, 7), 'f_bpm': (51, 41, 30)}
DISPLAY = {'f_l', 'f_xl', 'f_md', 'f_bpm'}      # big counters: the Display cut
SMALL_GAMMA = 0.9                               # <= 12 px nominal
TRACK = {}                                      # px added to every advance, per font (none needed: the face's own spacing)


def fit_size(ttf, cap):
    """The em size (quarter px steps) whose outline cap height is nearest
    `cap` px among those whose hinted 'H' is exactly `cap` px (the hinter
    snaps a wide range of sizes onto one cap; the outline-true one keeps the
    face's proportions)."""
    from fontTools.ttLib import TTFont
    t = TTFont(ttf)
    ratio = t['OS/2'].sCapHeight / float(t['head'].unitsPerEm)
    want = cap / ratio
    ok = [q / 4.0 for q in range(int(cap * 4), int(cap * 16))
          if -ImageFont.truetype(ttf, q / 4.0).getbbox('H', anchor='ls')[1] == cap]
    if not ok:
        raise SystemExit('fontgen: %s has no size with a %d px cap' % (ttf, cap))
    return min(ok, key=lambda s: abs(s - want))


def render_grid(ttf, grid, chars, gamma=1.0, track=0):
    """Glyphs of `ttf` on the layout grid (h, asc, cap): baseline at row asc."""
    h, asc, cap = grid
    size = fit_size(ttf, cap)
    font = ImageFont.truetype(ttf, size)
    glyphs, clipped = [], []
    lut = [min(255, int(round(255 * (v / 255.0) ** gamma))) for v in range(256)]
    for ch in chars:
        adv = int(round(font.getlength(ch))) + track
        if ch == ' ':           # word space: at least 0.36 cap (small sizes: hinting eats it)
            adv = max(adv, int(round(0.36 * cap)))
        box = font.getbbox(ch, anchor='ls')
        if box[1] + asc < 0 or box[3] + asc > h:
            clipped.append(ch)
        pad = 1 - min(0, box[0])
        w = max(1, box[2] + pad + 1)
        img = Image.new('L', (w, h), 0)
        ImageDraw.Draw(img).text((pad, asc), ch, font=font, fill=255, anchor='ls')
        if gamma != 1.0:
            img = img.point(lut)
        bb = img.getbbox()
        if bb is None:
            glyphs.append((ord(ch), adv, 0, 0, b''))
            continue
        x0, x1 = bb[0], bb[2]
        gw = x1 - x0
        rows = bytearray()
        px = img.load()
        for y in range(h):
            for x in range(x0, x0 + gw, 2):
                a = px[x, y] >> 4
                b = (px[x + 1, y] >> 4) if x + 1 < x0 + gw else 0
                rows.append(a << 4 | b)
        xo = x0 - pad
        if cap <= 7 and not ch.isdigit():   # (digits keep equal advances) REVIEW 1124 3.6: at cap 7 (f_t) 'I' (advance 2) and 'Z' / 'Y' / '4' (ink at -1) touched
            xo = max(xo, 0)     # and the later glyph overwrote the stem: ink inside the cell, one free column after it
            adv = max(adv, xo + gw + 1)
        glyphs.append((ord(ch), adv, xo, gw, bytes(rows)))
    return h, asc, glyphs, size, clipped


def render(ttf, size, chars):
    font = ImageFont.truetype(ttf, size)
    asc, desc = font.getmetrics()
    h = asc + desc
    glyphs = []
    for ch in chars:
        adv = int(round(font.getlength(ch)))
        box = font.getbbox(ch)
        w = max(1, box[2] - min(0, box[0]))
        img = Image.new('L', (w + 2, h), 0)
        ImageDraw.Draw(img).text((1 - min(0, box[0]), 0), ch, font=font, fill=255)
        bb = img.getbbox()
        if bb is None:
            glyphs.append((ord(ch), adv, 0, 0, b''))
            continue
        x0, x1 = bb[0], bb[2]
        gw = x1 - x0
        rows = bytearray()
        px = img.load()
        for y in range(h):
            for x in range(x0, x0 + gw, 2):
                a = px[x, y] >> 4
                b = (px[x + 1, y] >> 4) if x + 1 < x0 + gw else 0
                rows.append(a << 4 | b)
        xoff = x0 - 1 + min(0, box[0])
        glyphs.append((ord(ch), adv, xoff, gw, bytes(rows)))
    return h, asc, glyphs


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    ours = sys.argv[1] == '--cueline'
    ttf, out = sys.argv[1], sys.argv[2]
    src = 'Cueline Sans (fonts/CuelineSans, SIL OFL 1.1)' if ours else ttf.split('/')[-1]
    lines = ['/* generated by fontgen.py from %s -- do not edit */' % src,
             '#include "v2.h"']
    for name, size, chars in FONTS:
        chars = ''.join(sorted(set(chars)))      # the renderer binary-searches by code
        if ours:
            cut = 'Display' if name in DISPLAY else 'Regular'
            path = os.path.join(CUELINE, 'CuelineSans-%s.ttf' % cut)
            if not os.path.isfile(path):
                raise SystemExit('fontgen: %s missing (run fonts/CuelineSans/build_font.py)' % path)
            h, asc, glyphs, em, clipped = render_grid(path, GRID[name], chars,
                                                      SMALL_GAMMA if size <= 12 else 1.0,
                                                      TRACK.get(name, 0))
            print('fontgen: %-5s Cueline %-7s em %5.2f px, cell %d, baseline %d, cap %d%s'
                  % (name, cut, em, h, asc, GRID[name][2],
                     (', clipped: ' + ''.join(clipped)) if clipped else ''), file=sys.stderr)
        else:
            h, asc, glyphs = render(ttf, size, chars)
        data = bytearray()
        recs = []
        for code, adv, xoff, gw, rows in glyphs:
            recs.append((code, adv, xoff, gw, len(data)))
            data += rows
        lines.append('static const unsigned char %s_px[%d] = {%s};'
                     % (name, max(1, len(data)), ','.join(str(b) for b in data) or '0'))
        lines.append('static const struct glyph %s_g[%d] = {%s};' % (
            name, len(recs), ','.join('{%d,%d,%d,%d,%d}' % r for r in recs)))
        lines.append('const struct font %s = {%d, %d, %d, %s_g, %s_px};'
                     % (name, h, asc, len(recs), name, name))
    with open(out, 'w') as f:
        f.write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
