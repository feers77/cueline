#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 the cdj-nxs2-qemu authors.
"""Cueline icons: the V2 UI's own icon set, drawn here as vector shapes and rendered at
build time into the renderer's atlas (v2ui_atlas.c / .h). No firmware is read: every
icon is an original geometric drawing in the CDJ-3000 manner (thin white outline
pictograms), sized by the scaling rule (3000 sizes x 0.625) and drawn ON our pixel grid.

Pixel optimisation
  * every shape is authored in target pixels at the exact cell it is drawn in (no runtime
    scaling: one asset per drawn size), straight edges on whole-pixel boundaries, so
    1-px strokes come out as one solid pixel column / row;
  * rendered at SS x SS supersampling and reduced by an exact box (area) filter, i.e.
    alpha = coverage; curves and diagonals keep a 1-px anti-aliased edge;
  * coverage -> 4-bit alpha through a mild gamma (GAMMA), because the renderer blends in
    sRGB (set_ramp): without it thin light strokes on the dark UI read thinner than drawn.
  * the atlas is a 4-bit alpha mask (high nibble = left pixel), tinted fg over bg by the
    renderer, so one drawing serves white, grey, green and the accent backgrounds.

usage: icons.py <outdir> [--png PREVIEW.png] [--sheet SHEET.png]
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.path.join(HERE, '..', 'v2ui', 'fonts', 'CuelineSans', 'CuelineSans-Regular.ttf')
SS = 16          # supersampling per pixel
GAMMA = 0.8      # coverage ** GAMMA -> alpha
AW = 256         # atlas width


class C:
    """A cell w x h in target pixels; draws at SS x."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.im = Image.new('L', (w * SS, h * SS), 0)
        self.d = ImageDraw.Draw(self.im)

    def _p(self, pts):
        return [(x * SS, y * SS) for x, y in pts]

    def rect(self, x0, y0, x1, y1, v=255):          # [x0, x1) x [y0, y1) in pixels
        if x1 > x0 and y1 > y0:
            self.d.rectangle([x0 * SS, y0 * SS, x1 * SS - 1, y1 * SS - 1], fill=v)

    def frame(self, x0, y0, x1, y1, t=1, v=255):
        self.rect(x0, y0, x1, y0 + t, v); self.rect(x0, y1 - t, x1, y1, v)
        self.rect(x0, y0, x0 + t, y1, v); self.rect(x1 - t, y0, x1, y1, v)

    def rrect(self, x0, y0, x1, y1, r, v=255):
        self.d.rounded_rectangle([x0 * SS, y0 * SS, x1 * SS - 1, y1 * SS - 1], radius=r * SS, fill=v)

    def ell(self, cx, cy, rx, ry=None, v=255):
        ry = rx if ry is None else ry
        self.d.ellipse([(cx - rx) * SS, (cy - ry) * SS, (cx + rx) * SS - 1, (cy + ry) * SS - 1], fill=v)

    def ring(self, cx, cy, r, t, v=255, ry=None):
        ry = r if ry is None else ry
        self.ell(cx, cy, r, ry, v)
        self.ell(cx, cy, r - t, ry - t, 0)

    def poly(self, pts, v=255):
        self.d.polygon(self._p(pts), fill=v)

    def line(self, x0, y0, x1, y1, w, v=255, cap=False):
        dx, dy = x1 - x0, y1 - y0
        n = math.hypot(dx, dy) or 1
        ox, oy = -dy / n * w / 2, dx / n * w / 2
        self.poly([(x0 + ox, y0 + oy), (x1 + ox, y1 + oy), (x1 - ox, y1 - oy), (x0 - ox, y0 - oy)], v)
        if cap:
            self.ell(x0, y0, w / 2, v=v); self.ell(x1, y1, w / 2, v=v)

    def pline(self, pts, w, v=255):                   # stroked open polyline, mitred by round joints
        for a, b in zip(pts, pts[1:]):
            self.line(a[0], a[1], b[0], b[1], w, v)
        for p in pts[1:-1]:
            self.ell(p[0], p[1], w / 2, v=v)

    def arc(self, cx, cy, r, t, a0, a1, v=255):       # degrees, 0 = 3 o'clock, clockwise
        self.d.arc([(cx - r) * SS, (cy - r) * SS, (cx + r) * SS - 1, (cy + r) * SS - 1], a0, a1,
                   fill=v, width=max(1, round(t * SS)))

    def text(self, s, cx, cy_cap, cap, v=255):
        """our own font (Cueline Sans, OFL): string centred on cx, its cap height = cap px,
        the cap top at cy_cap - cap / 2"""
        size = cap * SS * 1.42
        for _ in range(4):
            f = ImageFont.truetype(FONT, max(1, round(size)))
            b = f.getbbox('H')
            got = (b[3] - b[1]) / SS
            size *= cap / got
        f = ImageFont.truetype(FONT, round(size))
        bb = self.d.textbbox((0, 0), s, font=f)
        hb = f.getbbox('H')
        x = cx * SS - (bb[2] + bb[0]) / 2
        y = (cy_cap - cap / 2) * SS - hb[1]
        self.d.text((x, y), s, font=f, fill=v)

    def mask(self):
        small = self.im.resize((self.w, self.h), Image.BOX)
        return [[min(15, int(round(15 * ((small.getpixel((x, y)) / 255.0) ** GAMMA))))
                 for x in range(self.w)] for y in range(self.h)]


# ---- the drawings: f(c) with c.w x c.h known; integer coordinates = pixel edges ----

def note(c):
    """eighth note: filled oval head bottom-left, stem, a flag curling down to the right"""
    w, h = c.w, c.h
    s = h / 15.0
    hx, hy = w * 0.36, h - 3.0 * s                 # head centre
    rx, ry = 2.75 * s, 2.05 * s
    pts = []
    for k in range(48):                              # tilted oval
        t = 2 * math.pi * k / 48
        x, y = rx * math.cos(t), ry * math.sin(t)
        a = math.radians(-22)
        pts.append((hx + x * math.cos(a) - y * math.sin(a), hy + x * math.sin(a) + y * math.cos(a)))
    c.poly(pts)
    sx = round(hx + rx * 0.80)                       # stem: a whole pixel column, right edge of the head
    sw = 1 if h < 20 else 2
    c.rect(sx - sw, 0, sx, round(hy))
    # flag: a tapering stroke from the stem top, bowing out to the right and curling down
    fx = sx - 0.5
    pts = []
    for k in range(17):
        t = k / 16.0
        pts.append((fx + (w - 1.0 - fx) * math.sin(t * math.pi * 0.62) ** 0.9, 0.2 + h * 0.60 * t))
    wd = (1.7 if h < 20 else 2.2)
    for (a, b), k in zip(zip(pts, pts[1:]), range(16)):
        c.line(a[0], a[1], b[0], b[1], wd * (1.0 - 0.45 * k / 16.0))
    for k, p in enumerate(pts[1:-1]):
        c.ell(p[0], p[1], wd * (1.0 - 0.45 * (k + 1) / 16.0) / 2)
    c.rect(sx - sw, 0, sx + 1, 2)                     # the flag's root on the stem


def note16(c):                                      # list cell 16: the note glyph 10 x 14 centred
    n = C(10, 14); note(n); _blit(c, n, 3, 1)


def person(c):
    w, h = c.w, c.h
    s = w / 16.0
    t = 1.0 if w < 19 else 1.25
    cx = w / 2
    c.ring(cx, 4.6 * s, 3.6 * s, t)
    # shoulders: the top of a wide ellipse, cut at the cell bottom
    sh = C(w, h)
    sh.ring(cx, h + 3.2 * s, 7.4 * s, t, ry=8.6 * s)
    sh.rect(0, h - 1, w, h, 0)
    _or(c, sh)


def album(c):
    w, h = c.w, c.h
    s = w / 16.0
    o = round(2 * s)                                 # the sleeve behind (an L at bottom-left)
    c.frame(o, 0, w, h - o)
    c.rect(0, o, 1, h); c.rect(0, h - 1, w - o, h)
    cx, cy = o + (w - o) / 2, (h - o) / 2
    c.ring(cx, cy, 4.4 * s, 1.0 if w < 19 else 1.2)
    c.ell(cx, cy, 1.2 * s)


PIX = {   # our own pixel letters for the 16-px pictograms (font text is mush below 7 px)
    'b': ['1000', '1000', '1110', '1001', '1001', '1001', '1110'],
    '#': ['01010', '01010', '11111', '01010', '11111', '01010', '01010'],
    'B': ['110', '101', '110', '101', '110'],
    'P': ['110', '101', '110', '100', '100'],
    'M': ['10001', '11011', '10101', '10001', '10001'],
}


def pixtext(c, s, cx, cy):
    gl = [PIX[ch] for ch in s]
    tw = sum(len(g[0]) for g in gl) + len(gl) - 1
    th = max(len(g) for g in gl)
    x = round(cx - tw / 2); y0 = round(cy - th / 2)
    for g in gl:
        for j, row in enumerate(g):
            for i, b in enumerate(row):
                if b == '1':
                    c.rect(x + i, y0 + j, x + i + 1, y0 + j + 1)
        x += len(g[0]) + 1


def keyicon(c):
    """b# in a frame (the 3000's key pictogram): pixel letters at 16 px, our font above"""
    w, h = c.w, c.h
    fh = round(h * 0.86)
    y0 = (h - fh) // 2
    c.frame(0, y0, w, y0 + fh)
    if w < 19:
        pixtext(c, 'b#', w / 2, y0 + fh / 2)
    else:
        c.text('b#', w / 2, y0 + fh / 2, max(5, round(fh * 0.52)))


def bpmicon(c):
    w, h = c.w, c.h
    fh = round(h * 0.76)
    y0 = (h - fh) // 2
    c.frame(0, y0, w, y0 + fh)
    if w < 19:
        pixtext(c, 'BPM', w / 2, y0 + fh / 2)
    else:
        c.text('BPM', w / 2 + 0.25, y0 + fh / 2, max(4, round(fh * 0.5)))


def lines(c, frame=True, clock=False):
    """a list: bullets + rules, in a frame (PLAYLIST); HISTORY adds a clock badge"""
    w, h = c.w, c.h
    s = w / 16.0
    if frame:
        c.frame(0, 0, w, h)
    n = 3
    x0 = round(3 * s); x1 = w - round(3 * s)
    ys = [round(h * f) for f in (0.28, 0.5, 0.72)]
    for y in ys[:n]:
        c.rect(x0, y - 1, x0 + 2 if w < 19 else x0 + 2, y + (0 if w < 19 else 1))
        c.rect(x0 + round(3.5 * s), y - 1, x1, y + (0 if w < 19 else 1))
    if clock:
        r = 4.4 * s
        cx, cy = w - r + 0.4, h - r + 0.4
        c.ell(cx, cy, r + 1.0, v=0)
        c.ell(cx, cy, r)
        c.rect(round(cx) - 1, round(cy - r * 0.7), round(cx), round(cy) , 0)
        c.rect(round(cx) - 1, round(cy) - 1, round(cx + r * 0.6), round(cy), 0)


def history(c):
    """the list (PLAYLIST) with a solid clock badge bottom-right, hands knocked out"""
    w, h = c.w, c.h
    s = w / 16.0
    c.frame(0, 0, w, h)
    lines(c, frame=False)
    r = 4.4 * s
    cx, cy = w - r, h - r
    c.ell(cx, cy, r + 1.2, v=0)
    c.ell(cx, cy, r)
    cxi, cyi = int(cx), int(cy)
    c.rect(cxi, round(cy - r * 0.7), cxi + 1, cyi + 1, 0)
    c.rect(cxi, cyi, round(cx + r * 0.6), cyi + 1, 0)


def search(c):
    w, h = c.w, c.h
    s = w / 16.0
    r = 5.4 * s
    cx = cy = r + 0.6
    c.ring(cx, cy, r, 1.2 * s if w > 16 else 1.25)
    a = r * 0.72
    c.line(cx + a, cy + a, w - 0.9, h - 0.9, 2.0 * s if w > 16 else 2.0, cap=True)


def matching(c):
    w, h = c.w, c.h
    s = w / 16.0
    t = 1.1 if w < 19 else 1.3
    c.ring(5.6 * s, 9.6 * s, 5.0 * s, t)
    c.ring(10.4 * s, 6.4 * s, 5.0 * s, t)


def folder(c):
    w, h = c.w, c.h
    s = w / 16.0
    top, tab = round(2 * s), round(4 * s)
    y1 = h - round(1.5 * s)
    # outline: tab on the top-left, 1-px edges on the pixel grid (the slant is the only diagonal)
    sx0, sx1 = round(5.5 * s), round(7.5 * s)
    c.rect(0, top, sx0, top + 1)                                 # tab top
    c.line(sx0 - 0.5, top + 0.5, sx1 - 0.5, tab + 0.5, 1.0)      # slant
    c.rect(sx1 - 1, tab, w, tab + 1)                             # body top, right of the slant
    c.rect(0, top, 1, y1); c.rect(w - 1, tab, w, y1); c.rect(0, y1 - 1, w, y1)


def calendar(c):
    w, h = c.w, c.h
    s = w / 16.0
    top = round(1.5 * s)
    c.frame(0, top, w, h - round(0.5 * s))
    c.rect(0, top, w, top + round(3 * s))                      # header band
    for x in (round(4 * s), w - round(4 * s) - 1):              # binder rings
        c.rect(x, 0, x + 1, top + 1, 255)
    gy = top + round(5 * s)
    for j in range(2):
        for i in range(4):
            x = round(2.5 * s + i * 3 * s)
            y = gy + j * round(3 * s)
            c.rect(x, y, x + max(1, round(2 * s)), y + max(1, round(1.4 * s)))


def clock(c):
    w, h = c.w, c.h
    s = w / 16.0
    cx, cy, r = w / 2, h / 2, min(w, h) / 2 - 0.2
    c.ring(cx, cy, r, 1.1 if w < 19 else 1.3)
    xi, yi = int(cx), int(cy)
    c.rect(xi, round(cy - r * 0.62), xi + 1, yi + 1)
    c.rect(xi, yi, round(cx + r * 0.5), yi + 1)


def star(c, filled):
    w, h = c.w, c.h
    cx, cy = w / 2, h / 2 + h * 0.05
    R = min(w, h * 1.05) / 2 - 0.1
    r = R * 0.40
    pts = []
    for k in range(10):
        a = math.radians(-90 + 36 * k)
        rr = R if k % 2 == 0 else r
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    c.poly(pts)
    if not filled:
        t = 1.15 if w < 19 else 1.3
        inner = []
        # inset the star by t along each vertex's bisector (scale about the centre)
        R2, r2 = R - t / math.sin(math.radians(18)) * 0.62, r - t * 0.95
        for k in range(10):
            a = math.radians(-90 + 36 * k)
            rr = R2 if k % 2 == 0 else r2
            inner.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
        c.poly(inner, 0)


def comment(c):
    w, h = c.w, c.h
    s = w / 16.0
    yb = h - round(4 * s)
    c.frame(0, round(1 * s), w, yb)
    tx = round(3 * s)
    c.rect(tx + 1, yb - 1, tx + round(4 * s), yb, 0)            # opening for the tail
    c.line(tx + 0.5, yb - 0.5, tx + 0.5, h - 0.5, 1.0)
    c.line(tx + 0.5, h - 0.8, tx + round(4 * s), yb - 0.5, 1.05)


def play(c):
    w, h = c.w, c.h
    c.poly([(0, 0), (w, h / 2), (0, h)])


def usb(c):
    """a USB stick: connector with two contacts on top, the body below with the trident knocked out"""
    w, h = c.w, c.h
    cw = round(w * 0.58) | 1 if w % 2 else round(w * 0.58) & ~1
    cx0 = (w - cw) // 2
    ch = round(h * 0.28)
    c.frame(cx0, 0, cx0 + cw, ch + 1)
    hh = 2 + max(1, round(ch * 0.4))
    c.rect(cx0 + 2, 2, cx0 + 4, hh)
    c.rect(cx0 + cw - 4, 2, cx0 + cw - 2, hh)
    c.rrect(0, ch, w, h, 1.6)
    # trident (black on the white body)
    mx = w / 2
    y0, y1 = ch + 2.5, h - 2.2
    xi = int(mx)
    c.rect(xi, round(y0 + 1), xi + 1, round(y1), 0)
    c.poly([(mx - 1.6, y0 + 1.6), (mx, y0 - 0.4), (mx + 1.6, y0 + 1.6)], 0)
    c.ell(mx, y1, 1.3, v=0)
    ym = y0 + (y1 - y0) * 0.55
    c.line(mx, ym + 1.6, mx - 3.0, ym - 0.4, 1.0, 0)
    c.ell(mx - 3.0, ym - 1.0, 0.95, v=0)
    c.line(mx, ym + 3.0, mx + 3.0, ym + 1.2, 1.0, 0)
    c.rect(round(mx + 2.2), round(ym - 0.4), round(mx + 4.0), round(ym + 1.4), 0)


def sdcard(c):
    w, h = c.w, c.h
    k = round(w * 0.32)
    c.poly([(0, 0), (w - k, 0), (w, k), (w, h), (0, h)])
    for i in range(3):                                           # contact slots
        x = 3 + 2 * i
        c.rect(x, 1, x + 1, 1 + round(h * 0.22), 0)
    c.rect(0, round(h * 0.42), 1, round(h * 0.58), 0)            # the side notch


def laptop(c):
    """LINK: a monitor (1-px frame) over a separate, wider base bar (the 3000's PC LINK pictogram shape)"""
    w, h = c.w, c.h
    m = round(w * 0.16)
    sb = h - 3                                    # screen bottom; 1-px gap; 2-px base bar
    c.frame(m, 0, w - m, sb)
    c.rect(0, sb + 1, w, h)


def disc(c):
    w, h = c.w, c.h
    cx, cy = w / 2, h / 2
    R = min(w, h) / 2
    c.ell(cx, cy, R)
    c.ring(cx, cy, R * 0.40, 1.0, v=0)
    c.ell(cx, cy, R * 0.14, v=0)


def noart(c):
    """no-artwork placeholder: a flat disc with its centre hole (drawn in grey by the renderer)"""
    w, h = c.w, c.h
    cx, cy = w / 2, h / 2
    R = min(w, h) * 0.40
    c.ell(cx, cy, R, v=150)
    c.ell(cx, cy, R * 0.26, v=0)


def spinner(k):
    def f(c):
        w, h = c.w, c.h
        cx, cy, r = w / 2, h / 2, min(w, h) / 2 - 0.5
        c.ring(cx, cy, r, 3.0, v=70)
        a0 = -90 + 45 * k
        c.arc(cx, cy, r, 3.0, a0, a0 + 100)
    return f


def backspace(c):
    w, h = c.w, c.h
    p = round(h / 2)
    c.pline([(p + 0.5, 0.5), (w - 0.5, 0.5), (w - 0.5, h - 0.5), (p + 0.5, h - 0.5), (0.7, h / 2), (p + 0.5, 0.5)], 1.0)
    mx, my, d = p + (w - p) / 2 - 0.5, h / 2, h * 0.22
    c.line(mx - d, my - d, mx + d, my + d, 1.3)
    c.line(mx - d, my + d, mx + d, my - d, 1.3)


def sliders(c):
    """settings: three rules with knobs (MY SETTINGS tile)"""
    w, h = c.w, c.h
    for i, kx in enumerate((0.7, 0.3, 0.6)):
        y = round(h * (0.2 + 0.3 * i))
        c.rect(0, y, w, y + 1)
        x = round(w * kx)
        c.rect(x - 2, y - 2, x + 2, y + 3)


def _or(dst, src):
    from PIL import ImageChops
    dst.im = ImageChops.lighter(dst.im, src.im)
    dst.d = ImageDraw.Draw(dst.im)


def _blit(dst, src, x, y):
    dst.im.paste(src.im, (x * SS, y * SS))
    dst.d = ImageDraw.Draw(dst.im)


# ---- the asset list: (name, nxs2 model icon id or 0, w, h, drawing). One asset per DRAWN size. ----
# sizes: 3000 skin sizes x 0.625 (list icons 25x34 cell / ~24 px glyph -> 16; category / INFO
# pictograms ~32 px -> 20; source tile pictograms; title note 16x24 -> 12x18 cell; star 29x27 -> 17x16)
L, R_ = 16, 20
ASSETS = [
    # list rows, pane rows, headers (icon_id): 16 px
    ('ARTIST', 0x81, L, L, person), ('ALBUM', 0x82, L, L, album), ('TRACK', 0x83, L, L, note16),
    ('KEY', 0x8B, L, 14, keyicon), ('PLAYLIST', 0x84, L, L, lines), ('HISTORY', 0x95, L, L, history),
    ('SEARCH', 0x91, L, L, search), ('MATCHING', 0xAA, L, L, matching), ('FOLDER', 0x90, L, 15, folder),
    ('DATE_ADDED', 0x8C, L, L, calendar),
    ('ROW_LOADED', 0x5A, 8, 10, play),
    ('INFO_ARTIST', 0x07, L, L, person), ('INFO_ALBUM', 0x06, L, L, album), ('INFO_TIME', 0x0B, L, L, clock),
    ('INFO_BPM', 0x0D, L, 12, bpmicon), ('INFO_KEY', 0x0F, L, 14, keyicon),
    ('INFO_RATING', 0x0A, L, L, lambda c: star(c, False)), ('INFO_DATE', 0x2E, L, L, calendar),
    ('INFO_COMMENT', 0x23, L, L, comment),
    ('DEV_SONGS', 0xB4, L, L, note16), ('DEV_PLAYLISTS', 0xB5, L, L, lines),
    # the note before a title (player header, track rows, browse strip): a 12 x 18 cell (icon_scaled 1:1)
    ('TITLE_TRACK', 0x04, 12, 18, lambda c: _blit(c, _mk(10, 15, note), 1, 1)),
    ('ROW_TRACK', 0x2F, 12, 18, lambda c: _blit(c, _mk(10, 15, note), 1, 1)),
    # source pictograms (source tile, player header, SOURCE rows, SHORT CUT)
    ('SRC_USB', 0x54, 13, 21, usb), ('SRC_DEVICE', 0x63, 14, 18, sdcard), ('SRC_LINK', 0x51, 20, 14, laptop),
    ('SRC_DISC', 0x58, 20, 20, disc), ('SRC_SD', 0x55, 14, 18, sdcard),
    ('SETTINGS', 0, 18, 14, sliders),
    # the rail (categories): 20 px, the 3000's category pictograms x 0.625
    ('RAIL_ARTIST', 0, R_, R_, person), ('RAIL_ALBUM', 0, R_, R_, album), ('RAIL_TRACK', 0, R_, R_,
     lambda c: _blit(c, _mk(13, 18, note), 4, 1)),
    ('RAIL_KEY', 0, R_, 17, keyicon), ('RAIL_PLAYLIST', 0, R_, R_, lines), ('RAIL_HISTORY', 0, R_, R_, history),
    ('RAIL_SEARCH', 0, R_, R_, search), ('RAIL_MATCHING', 0, R_, R_, matching), ('RAIL_FOLDER', 0, R_, 18, folder),
    # the INFO page's field pictograms: 20 px
    ('BIG_ARTIST', 0, R_, R_, person), ('BIG_ALBUM', 0, R_, R_, album), ('BIG_TIME', 0, R_, R_, clock),
    ('BIG_BPM', 0, R_, 15, bpmicon), ('BIG_KEY', 0, R_, 17, keyicon), ('BIG_RATING', 0, R_, R_,
     lambda c: star(c, False)), ('BIG_DATE', 0, R_, R_, calendar), ('BIG_COMMENT', 0, R_, R_, comment),
    ('BIG_GENRE', 0, R_, R_, album),
    # rating stars: in text (17 x 16) and on the INFO page (20 x 20)
    ('RATING_STAR_EMPTY', 0, 17, 16, lambda c: star(c, False)), ('RATING_STAR_FULL', 0, 17, 16, lambda c: star(c, True)),
    ('STAR20_EMPTY', 0, 20, 20, lambda c: star(c, False)), ('STAR20_FULL', 0, 20, 20, lambda c: star(c, True)),
    # SEARCH keyboard delete key, no-artwork placeholders (one per drawn size), the Wait spinner
    ('KEY_BACKSPACE', 0, 24, 16, backspace),
    ('NOART_HDR', 0, 35, 38, noart), ('NOART_PANE', 0, 100, 108, noart), ('NOART_INFO', 0, 164, 164, noart),
] + [('WAIT%d' % k, 0, 32, 32, spinner(k)) for k in range(8)]

# INFO page (big) variants of the model ids, and the rail variants of RAIL_ID
BIG = {0x07: 'BIG_ARTIST', 0x06: 'BIG_ALBUM', 0x0B: 'BIG_TIME', 0x0D: 'BIG_BPM', 0x0F: 'BIG_KEY',
       0x0A: 'BIG_RATING', 0x2E: 'BIG_DATE', 0x23: 'BIG_COMMENT', 0x02: 'BIG_ALBUM'}
RAIL = {0x81: 'RAIL_ARTIST', 0x82: 'RAIL_ALBUM', 0x83: 'RAIL_TRACK', 0x8B: 'RAIL_KEY', 0x84: 'RAIL_PLAYLIST',
        0x95: 'RAIL_HISTORY', 0x91: 'RAIL_SEARCH', 0xAA: 'RAIL_MATCHING', 0x90: 'RAIL_FOLDER'}


def _mk(w, h, f):
    c = C(w, h); f(c); return c


def render():
    out = []
    for name, nid, w, h, f in ASSETS:
        c = C(w, h)
        f(c)
        out.append((name, nid, w, h, c.mask()))
    return out


def pack(assets):
    """shelf packing, tallest first; identical bitmaps share one place"""
    order = sorted(range(len(assets)), key=lambda i: (-assets[i][3], -assets[i][2]))
    pos, seen = {}, {}
    x = y = shelf = 0
    for i in order:
        name, nid, w, h, m = assets[i]
        key = (w, h, tuple(tuple(r) for r in m))
        if key in seen:
            pos[i] = seen[key]
            continue
        if x + w > AW:
            x, y, shelf = 0, y + shelf, 0
        pos[i] = (x, y)
        seen[key] = (x, y)
        x += w + (w & 1)          # even x: a glyph never shares its first byte
        shelf = max(shelf, h)
    return pos, y + shelf


def write(outdir, assets, pos, H):
    rows = [[0] * AW for _ in range(H)]
    for i, (name, nid, w, h, m) in enumerate(assets):
        px, py = pos[i]
        for j in range(h):
            for k in range(w):
                rows[py + j][px + k] = m[j][k]
    data = bytearray()
    for r in rows:
        for k in range(0, AW, 2):
            data.append(r[k] << 4 | r[k + 1])
    hdr = ['/* generated by icons.py (our own drawings, Apache-2.0) -- do not edit */',
           '#ifndef V2UI_ATLAS_H', '#define V2UI_ATLAS_H', '',
           '#define V2A_W %d' % AW, '#define V2A_MASK_H %d' % H, '#define V2A_RGB_H 0',
           '#define V2A_TRANSP 0xF81F', '',
           'enum v2a_kind { V2A_MASK4 = 0, V2A_RGB565 = 1 };', '',
           'struct v2a_rect { unsigned short nxs2_icon, kind, x, y, w, h; };', '', 'enum v2a_id {']
    hdr += ['    V2A_%s,' % a[0] for a in assets] + ['    V2A_COUNT', '};', '',
            'extern const struct v2a_rect v2a_rects[V2A_COUNT];',
            'extern const unsigned char v2a_mask[];   /* 4 bpp, %d x %d */' % (AW, H),
            'extern const unsigned char v2a_rgb[];    /* unused (no colour assets) */',
            '/* NXS2 UI-model icon id -> asset, or -1 */', 'int v2a_for_icon(unsigned id);',
            '/* the INFO page\'s (20 px) and the rail\'s (20 px) variant of an id, else v2a_for_icon(id) */',
            'int v2a_for_big(unsigned id);', 'int v2a_for_rail(unsigned id);', '', '#endif', '']
    src = ['/* generated by icons.py (our own drawings, Apache-2.0) -- do not edit */', '#include "v2ui_atlas.h"', '',
           'const struct v2a_rect v2a_rects[V2A_COUNT] = {']
    for i, (name, nid, w, h, m) in enumerate(assets):
        src.append('    { 0x%02X, V2A_MASK4, %3d, %3d, %3d, %3d },  /* %s */' % (nid, pos[i][0], pos[i][1], w, h, name))
    src += ['};', '', 'const unsigned char v2a_rgb[4] __attribute__((aligned(4))) = { 0 };', '',
            'const unsigned char v2a_mask[%d] __attribute__((aligned(4))) = {' % len(data)]
    for k in range(0, len(data), 24):
        src.append('    ' + ', '.join('0x%02X' % b for b in data[k:k + 24]) + ',')
    src += ['};', '', 'int v2a_for_icon(unsigned id)', '{', '    switch (id) {']
    for name, nid, w, h, m in assets:
        if nid:
            src.append('    case 0x%02X: return V2A_%s;' % (nid, name))
    src += ['    default: return -1;', '    }', '}', '']
    for fn, tab in (('v2a_for_big', BIG), ('v2a_for_rail', RAIL)):
        src += ['int %s(unsigned id)' % fn, '{', '    switch (id) {']
        for nid, name in sorted(tab.items()):
            src.append('    case 0x%02X: return V2A_%s;' % (nid, name))
        src += ['    default: return v2a_for_icon(id);', '    }', '}', '']
    _put(os.path.join(outdir, 'v2ui_atlas.h'), '\n'.join(hdr))
    _put(os.path.join(outdir, 'v2ui_atlas.c'), '\n'.join(src))
    return rows, len(data)


def _put(p, s):
    if os.path.exists(p) and open(p).read() == s:
        return                     # unchanged: keep the timestamp
    open(p, 'w').write(s)


def preview(rows, path, z=3):
    H = len(rows)
    im = Image.new('L', (AW, H))
    im.putdata([v * 17 for r in rows for v in r])
    im.resize((AW * z, H * z), Image.NEAREST).save(path)


def main():
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    outdir = a[0]
    assets = render()
    pos, H = pack(assets)
    rows, n = write(outdir, assets, pos, H)
    if '--png' in a:
        preview(rows, a[a.index('--png') + 1])
    print('icons: %d assets, atlas %d x %d, %d bytes' % (len(assets), AW, H, n))


if __name__ == '__main__':
    main()
