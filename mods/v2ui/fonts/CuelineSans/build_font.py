#!/usr/bin/env python3
# SPDX-License-Identifier: OFL-1.1
"""Build Cueline Sans (our UI face) from its OFL source, Outfit (variable).

    usage: build_font.py [OUT_DIR]      -> CuelineSans-Regular.ttf, CuelineSans-Display.ttf

Cueline Sans is a Modified Version of Outfit (SIL OFL 1.1, Copyright 2021 The
Outfit Project Authors, https://github.com/Outfitio/Outfit-Fonts); see OFL.txt
and FONTLOG.txt. It is built only from source-Outfit-wght.ttf with these
changes, all made here, numerically, on Outfit's own outlines:

  * a static instance of the wght axis (Regular = text sizes, Display = the
    big counters: a touch lighter, as large figures read heavier);
  * horizontal condensing by SX (outlines, advances, side bearings, kerning,
    anchors) for a CDJ-style narrow set on 800x480, and the capitals (Unicode
    Lu) a further CAPSX: DIN-like narrow caps for the UI's all-caps labels;
  * tabular figures by default: 0-9 map to Outfit's own .tf glyphs (equal
    advance: BPM / time counters do not jitter);
  * U+00AD (soft hyphen) mapped to the hyphen; U+2212 to the hyphen if absent;
  * renamed (OFL 1.1 section 3 / FONTLOG) to "Cueline Sans".

No other font's outlines, bitmaps or metrics are used.
"""
import os
import sys

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'source-Outfit-wght.ttf')
FAMILY = 'Cueline Sans'
PS = 'CuelineSans'
VERSION = '1.000'
EPOCH = 3846182400        # 2025-11-16 in head-table seconds since 1904 (fixed: reproducible build)
CAPSX = 0.90              # capitals: extra condensing on top of SX
# style -> (wght, SX)
STYLES = {
    'Regular': (460, 0.92),
    'Display': (420, 0.92),
}


def capitals(font):
    """Glyph names of the Unicode Lu code points (and nothing else uses them
    as a simple glyph: lowercase / symbols keep the plain SX)."""
    import unicodedata
    caps, other = set(), set()
    for u, n in font.getBestCmap().items():
        (caps if unicodedata.category(chr(u)) == 'Lu' else other).add(n)
    return caps - other


def scale_x(font, sx):
    glyf = font['glyf']
    hmtx = font['hmtx']
    caps = capitals(font)
    for name in font.getGlyphOrder():
        g = glyf[name]
        k = sx * (CAPSX if name in caps else 1.0)
        if g.isComposite():
            for c in g.components:
                c.x = int(round(c.x * k))
        elif g.numberOfContours > 0:
            coords = g.coordinates
            for i in range(len(coords)):
                x, y = coords[i]
                coords[i] = (int(round(x * k)), y)
        adv, lsb = hmtx[name]
        hmtx[name] = (int(round(adv * k)), lsb)
    for name in font.getGlyphOrder():          # bounds / lsb after composites are resolved
        g = glyf[name]
        g.recalcBounds(glyf)
        adv, _ = hmtx[name]
        hmtx[name] = (adv, g.xMin if g.numberOfContours != 0 else 0)
    if 'GPOS' in font:
        scale_gpos(font['GPOS'].table, sx)
    if 'HVAR' in font:
        del font['HVAR']
    hhea = font['hhea']
    hhea.advanceWidthMax = max(a for a, _ in hmtx.metrics.values())
    os2 = font['OS/2']
    os2.xAvgCharWidth = int(round(os2.xAvgCharWidth * sx))


def scale_gpos(table, sx):
    """Every X value in the GPOS tree (kerning, mark anchors) times sx."""
    seen = set()

    def walk(obj):
        if obj is None or id(obj) in seen:
            return
        if isinstance(obj, (int, float, str, bytes)):
            return
        seen.add(id(obj))
        if isinstance(obj, list):
            for o in obj:
                walk(o)
            return
        d = getattr(obj, '__dict__', None)
        if d is None:
            return
        for k, v in list(d.items()):
            if k in ('XAdvance', 'XPlacement', 'XCoordinate') and isinstance(v, (int, float)):
                setattr(obj, k, int(round(v * sx)))
            else:
                walk(v)
    walk(table)


def tabular_digits(font):
    go = set(font.getGlyphOrder())
    names = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine']
    for t in font['cmap'].tables:
        if not t.isUnicode():
            continue
        for i, n in enumerate(names):
            if n + '.tf' in go:
                t.cmap[0x30 + i] = n + '.tf'
        if 0x2D in t.cmap:
            t.cmap.setdefault(0xAD, t.cmap[0x2D])
            t.cmap.setdefault(0x2212, t.cmap[0x2D])


def rename(font, style):
    name = font['name']
    full = '%s %s' % (FAMILY, style)
    ps = '%s-%s' % (PS, style)
    keep = {0, 13, 14}      # copyright, licence, licence URL stay Outfit's (OFL requires)
    for rec in list(name.names):
        if rec.nameID not in keep:
            name.removeNames(nameID=rec.nameID)
    cr = 'Copyright 2021 The Outfit Project Authors (https://github.com/Outfitio/Outfit-Fonts). ' \
         'Cueline Sans: modified version, 2026, the CDJ-2000NXS2 custom firmware project.'
    for nid, s in ((0, cr), (1, full if style != 'Regular' else FAMILY), (2, 'Regular'),
                   (3, '%s;%s' % (VERSION, ps)), (4, full), (5, 'Version %s' % VERSION), (6, ps),
                   (13, 'This Font Software is licensed under the SIL Open Font License, Version 1.1.'),
                   (14, 'https://openfontlicense.org'), (16, FAMILY), (17, style)):
        name.setName(s, nid, 3, 1, 0x409)
    font['OS/2'].usWeightClass = 400
    font['head'].fontRevision = float(VERSION)
    font['head'].created = font['head'].modified = EPOCH     # reproducible bytes


def build(style, out_dir):
    wght, sx = STYLES[style]
    f = instancer.instantiateVariableFont(TTFont(SRC), {'wght': wght}, updateFontNames=False)
    for t in ('STAT', 'fvar', 'avar', 'gvar', 'HVAR', 'MVAR'):
        if t in f:
            del f[t]
    scale_x(f, sx)
    tabular_digits(f)
    rename(f, style)
    out = os.path.join(out_dir, '%s-%s.ttf' % (PS, style))
    f.recalcTimestamp = False
    f.save(out)
    return out


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else HERE
    for s in STYLES:
        print(build(s, out_dir))


if __name__ == '__main__':
    main()
