#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""CDJ-2000NXS2 GUI fonts: dump, render, compare, re-encode (static only).

The font archive (file 0x440000 of gui_unpacked.bin = flash 0x470000, BE32
length + LZSS) decodes to 0x57C099 bytes at RAM 0x0DF00000. It is six raw
bitmap files glued together, byte-identical to the rekordbox/RX3 files
`pset/fontdata/NS_FONT_ID_*.bin`. There is no header: every metric lives in
the code image. See re/GUI_FONTS.md for the evidence.

    font       base (RAM)  glyphs cell   B/row B/glyph adv  index
    iso8859    0x0DF00000    422  28x27   7    189   table  5 code pages (8 B/entry)
    jisx0201   0x0DF1378E    223  12x23   3     69   11     u16 offset table
    jisx0208   0x0DF173A9   8648  24x23   6    138   22     (hi-0x21)*94+(lo-0x21)
    ksx1001    0x0E03A979   3760  24x23   6    138   22     (hi-0xA1)*94+(lo-0xA1)
    gb18030    0x0E0B9459  27538  24x23   6    138   22     fn 0x0E5031EA (idx>=1038)
    gb18030jh  0x0E45910D   1038  24x23   6    138   22     fn 0x0E5031EA (idx<1038)

Pixels: 2 bpp, MSB first, rows padded to a byte, levels 0..3. The blitter
(0x0E5095CE) does not alpha-blend: level 0 is skipped, levels 1..3 are
replaced by three RGB888 colours of a text style (table 0x0E5958D4, 16 B per
style: 0, c1, c2, c3), written as RGB565.

usage:
    gui_fonts.py dump   [--img gui_unpacked.bin|.UPD] OUTDIR [--all]
    gui_fonts.py render [--img ..] TEXT OUT.png [--style N] [--bg RRGGBB] [--zoom Z]
    gui_fonts.py compare [--img ..] SCREEN.png TEXT X Y [--style N]
    gui_fonts.py find   [--img ..] SCREEN.png TEXT [--style N]
    gui_fonts.py roundtrip [--img ..] [--compress]
    gui_fonts.py candidate TTF OUTDIR [--px N] [--weight W] [--fallback TTF]
"""
import json
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lzss_decode  # noqa: E402

DEFAULT_IMG = os.path.join(HERE, '..', '..', 'extract', 'gui_unpacked.bin')
FONT_OFF = 0x440000          # file offset of the font archive (flash 0x470000)
FONT_RAM = 0x0DF00000

# code-image tables (RAM addresses, segment 0x0E58C6B0 <- file 0x08C7B0)
SEG_RAM, SEG_FILE = 0x0E58C6B0, 0x08C7B0
BLOB_TABLE = 0x0E598DC8      # 6 x {base, size, 3}
PAGE_PTRS = 0x0E5957A0       # 5 latin page pointers + jisx0201 u16 table
LATIN_PAGES = 0x0E592DA0     # 5 pages x 256 x {BE32 width, BE32 byte offset}
JIS0201_TAB = 0x0E5955A0     # 256 x BE16 byte offset into jisx0201
PALETTE = 0x0E5958D4         # text styles, 16 B each: {0, c1, c2, c3}
N_STYLES = 26

PAGE_CODECS = ['latin_1', 'iso8859_2', 'iso8859_5', 'iso8859_7', 'iso8859_9']

FONTS = [  # name, cell w, h, bytes per row, fixed advance (None = table)
    ('iso8859', 28, 27, 7, None),
    ('jisx0201', 12, 23, 3, 11),
    ('jisx0208', 24, 23, 6, 22),
    ('ksx1001', 24, 23, 6, 22),
    ('gb18030', 24, 23, 6, 22),
    ('gb18030jh', 24, 23, 6, 22),
]
RX3_NAMES = ['NS_FONT_ID_ISO8859_w.bin', 'NS_FONT_ID_JISX0201_w.bin',
             'NS_FONT_ID_JISX0208_w.bin', 'NS_FONT_ID_KSX1001_w.bin',
             'NS_FONT_ID_GB18030_w.bin', 'NS_FONT_ID_18030_JH_w.bin']


def a2o(addr):
    return addr - SEG_RAM + SEG_FILE


# --------------------------------------------------------------- loading
def load_image(path=None):
    """gui_unpacked.bin, a raw GUI section or a whole .UPD."""
    data = open(path or DEFAULT_IMG, 'rb').read()
    if len(data) == 0x7C0000:
        return data
    import gui_bootcheck
    sec = data if data[:3] == b'CDJ' else gui_bootcheck.upd_gui_section(data)
    n = struct.unpack_from('>I', sec, 0x20)[0]
    return lzss_decode.unpack(sec[:0x24 + n], 0x24)


def archive(img):
    n = struct.unpack_from('>I', img, FONT_OFF)[0]
    return lzss_decode.unpack(img[FONT_OFF + 4:FONT_OFF + 4 + n], 0)


class Fonts:
    def __init__(self, img=None, arc=None):
        self.img = img if img is not None else load_image()
        self.arc = arc if arc is not None else archive(self.img)
        self.blobs = {}
        for i, (name, w, h, bpr, adv) in enumerate(FONTS):
            base, size, kind = struct.unpack_from('>III', self.img, a2o(BLOB_TABLE) + 12 * i)
            off = base - FONT_RAM
            self.blobs[name] = dict(base=base, size=size, kind=kind, w=w, h=h, bpr=bpr,
                                    gsize=bpr * h, count=size // (bpr * h), adv=adv,
                                    data=self.arc[off:off + size])
        self.pages = self.read_pages(self.img)
        self.jis0201 = list(struct.unpack_from('>256H', self.img, a2o(JIS0201_TAB)))
        self.styles = [struct.unpack_from('>4I', self.img, a2o(PALETTE) + 16 * k)
                       for k in range(N_STYLES)]

    @staticmethod
    def read_pages(img):
        ptrs = struct.unpack_from('>6I', img, a2o(PAGE_PTRS))
        pages = []
        for p in ptrs[:5]:
            e = struct.unpack_from('>512I', img, a2o(p))
            pages.append([(e[2 * c], e[2 * c + 1]) for c in range(256)])
        return pages

    def glyph(self, font, idx):
        b = self.blobs[font]
        return unpack2(b['data'][idx * b['gsize']:(idx + 1) * b['gsize']], b['bpr'], b['h'])[:, :b['w']]

    # ---------------------------------------------------- latin inventory
    def latin_inventory(self):
        """glyph index -> {unicode, width, pages} from the five code pages.
        Only codes 0x20-0x7E of page 0 and 0xA0-0xFF of every page carry a
        real offset; 0x00-0x1F, 0x7F-0x9F and the lower halves of pages 1-4
        point at glyph 0 (a blank) -- see GUI_FONTS.md."""
        inv = {}
        for p, page in enumerate(self.pages):
            for c in range(256):
                w, off = page[c]
                if c < 0x20 or 0x7F <= c < 0xA0 or (p and c < 0x80):
                    continue
                if off == 0 and c != 0x20 and not (c == 0xA0):
                    continue
                g = off // 189
                try:
                    u = bytes([c]).decode(PAGE_CODECS[p])
                except UnicodeDecodeError:
                    continue
                d = inv.setdefault(g, dict(unicode=ord(u), width=w, refs=[]))
                d['refs'].append('%d:%02X' % (p, c))
                if d['width'] != w:
                    d.setdefault('other_widths', []).append(w)
        return inv

    # ------------------------------------------------------- text layout
    def lookup(self, ch):
        """(font, glyph index, advance, cell height) for one character."""
        o = ord(ch)
        if o < 0x100:
            w, off = self.pages[0][o]
            if off or o == 0x20 or o == 0xA0:
                return 'iso8859', off // 189, w, 27
        for p in range(1, 5):
            try:
                c = ch.encode(PAGE_CODECS[p])[0]
            except UnicodeEncodeError:
                continue
            w, off = self.pages[p][c]
            if off:
                return 'iso8859', off // 189, w, 27
        try:
            sj = ch.encode('shift_jis')
            if len(sj) == 1:
                return 'jisx0201', self.jis0201[sj[0]] // 69, 11, 23
            j = ch.encode('iso2022_jp')
            hi, lo = j[3], j[4]
            return 'jisx0208', (hi - 0x21) * 94 + (lo - 0x21), 22, 23
        except (UnicodeEncodeError, IndexError):
            pass
        try:
            k = ch.encode('euc_kr')
            if len(k) == 2 and k[0] <= 0xC8:
                return 'ksx1001', (k[0] - 0xA1) * 94 + (k[1] - 0xA1), 22, 23
        except UnicodeEncodeError:
            pass
        w, off = self.pages[0][0x7E]        # firmware falls back to '~'
        return 'iso8859', off // 189, w, 27

    WIDE = ('jisx0208', 'ksx1001', 'gb18030', 'gb18030jh')

    def layout(self, text):
        """Pen positions as the firmware's text measure (0x0E50AF14) lays
        them out: the sum of advances, plus 1 px where a latin or JIS X 0201
        glyph is followed by a full-width one (JIS X 0208 / KS / GB), and
        where a JIS X 0208 glyph is followed by a JIS X 0201 one (its switch
        on the pair of encodings: 4-8/12 -> 13/14/15 and 13 -> 12 add 1;
        full-width -> latin adds nothing). Hence "【TRACK】": 【 +22, TRACK,
        then 】 one pixel past the sum."""
        x, out, prev = 0, [], None
        for ch in text:
            f, g, adv, h = self.lookup(ch)
            if prev is not None and ((prev not in self.WIDE and f in self.WIDE)
                                     or (prev == 'jisx0208' and f == 'jisx0201')):
                x += 1
            out.append((x, f, g, adv, h))
            x += adv
            prev = f
        return out, x

    def render(self, text, style=0, bg=(0, 0, 0), canvas=None, x0=0, y0=0, cjk_dy=1):
        """Draw like the firmware: glyph top-left at the pen, level 0
        transparent, levels 1..3 replaced by the style's colours (RGB565)."""
        lay, width = self.layout(text)
        if canvas is None:
            canvas = np.zeros((27, max(width, 1), 3), np.uint8)
            canvas[:] = bg
        pal = [rgb565_expand(c) for c in self.styles[style]]
        for x, f, g, adv, h in lay:
            # only the first <advance> columns are drawn (the glyph call
            # returns w = advance to the blitter; a K of an earlier face lost its 13th)
            G = self.glyph(f, g)[:, :max(adv, 1)]
            dy = cjk_dy if f != 'iso8859' else 0
            for lv in (1, 2, 3):
                ys, xs = np.nonzero(G == lv)
                ys = ys + y0 + dy
                xs = xs + x0 + x
                ok = (ys >= 0) & (ys < canvas.shape[0]) & (xs >= 0) & (xs < canvas.shape[1])
                canvas[ys[ok], xs[ok]] = pal[lv]
        return canvas, width


def rgb565_expand(c):
    r, g, b = (c >> 16) & 255, (c >> 8) & 255, c & 255
    r5, g6, b5 = r >> 3, g >> 2, b >> 3
    return ((r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2))


def unpack2(buf, bpr, h):
    d = np.frombuffer(bytes(buf), np.uint8).reshape(h, bpr)
    return np.stack([(d >> 6) & 3, (d >> 4) & 3, (d >> 2) & 3, d & 3], -1).reshape(h, bpr * 4)


def pack2(levels, bpr):
    """levels: h x w array of 0..3 -> bytes (rows padded to bpr bytes)."""
    h, w = levels.shape
    a = np.zeros((h, bpr * 4), np.uint8)
    a[:, :w] = levels
    a = a.reshape(h, bpr, 4)
    return ((a[..., 0] << 6) | (a[..., 1] << 4) | (a[..., 2] << 2) | a[..., 3]).astype(np.uint8).tobytes()


# ------------------------------------------------------------ atlases
ATLAS_COLS = 32


def atlas(fonts, name, first=0, count=None):
    from PIL import Image
    b = fonts.blobs[name]
    count = b['count'] - first if count is None else count
    w, h = b['bpr'] * 4, b['h']
    rows = (count + ATLAS_COLS - 1) // ATLAS_COLS
    img = np.zeros((rows * h, ATLAS_COLS * w), np.uint8)
    d = b['data']
    for k in range(count):
        g = first + k
        G = unpack2(d[g * b['gsize']:(g + 1) * b['gsize']], b['bpr'], h)
        r, c = divmod(k, ATLAS_COLS)
        img[r * h:(r + 1) * h, c * w:(c + 1) * w] = G
    return Image.fromarray(img * 85)      # exact: level = value // 85


def atlas_levels(png, name, count):
    """Inverse of atlas(): PNG -> list of glyph level arrays."""
    from PIL import Image
    spec = dict((f[0], f) for f in FONTS)[name]
    w, h = spec[3] * 4, spec[2]
    a = np.array(Image.open(png).convert('L')).astype(int)
    lv = np.clip((a + 42) // 85, 0, 3).astype(np.uint8)
    out = []
    for k in range(count):
        r, c = divmod(k, ATLAS_COLS)
        out.append(lv[r * h:(r + 1) * h, c * w:(c + 1) * w])
    return out


def preview(fonts, name, count, out, cols=32, zoom=2, labels=None):
    """Human-readable atlas: grid lines, white-on-black, zoomed."""
    from PIL import Image
    b = fonts.blobs[name]
    w, h = b['w'], b['h']
    rows = (count + cols - 1) // cols
    img = np.full((rows * (h + 1) + 1, cols * (w + 1) + 1), 48, np.uint8)
    for k in range(count):
        r, c = divmod(k, cols)
        img[1 + r * (h + 1):1 + r * (h + 1) + h, 1 + c * (w + 1):1 + c * (w + 1) + w] = fonts.glyph(name, k) * 85
    Image.fromarray(img).resize((img.shape[1] * zoom, img.shape[0] * zoom), Image.NEAREST).save(out)


def dump(fonts, outdir, everything=False):
    os.makedirs(outdir, exist_ok=True)
    meta = {'archive_size': len(fonts.arc), 'fonts': {}, 'styles': []}
    for name, b in fonts.blobs.items():
        meta['fonts'][name] = {k: b[k] for k in ('base', 'size', 'w', 'h', 'bpr', 'gsize', 'count', 'adv')}
        meta['fonts'][name]['rx3_file'] = RX3_NAMES[[f[0] for f in FONTS].index(name)]
        big = b['count'] > 1000
        if everything or not big:
            atlas(fonts, name).save(os.path.join(outdir, '%s_atlas.png' % name))
            preview(fonts, name, b['count'], os.path.join(outdir, '%s_preview.png' % name))
        else:
            preview(fonts, name, min(b['count'], 32 * 12), os.path.join(outdir, '%s_preview_first384.png' % name))
    inv = fonts.latin_inventory()
    meta['fonts']['iso8859']['glyphs'] = [
        dict(index=g, unicode='U+%04X' % inv[g]['unicode'], char=chr(inv[g]['unicode']),
             advance=inv[g]['width'], refs=inv[g]['refs'], **({'other_widths': inv[g]['other_widths']}
                                                                 if 'other_widths' in inv[g] else {}))
        if g in inv else dict(index=g, unicode=None)
        for g in range(fonts.blobs['iso8859']['count'])]
    meta['latin_pages'] = {PAGE_CODECS[p]: [list(e) for e in fonts.pages[p]] for p in range(5)}
    meta['jisx0201_offsets'] = fonts.jis0201
    meta['styles'] = ['%06x %06x %06x' % s[1:] for s in fonts.styles]
    json.dump(meta, open(os.path.join(outdir, 'fonts.json'), 'w'), indent=1, ensure_ascii=False)
    return meta


# ----------------------------------------------------- compare / find
def quantize_screen(png):
    from PIL import Image
    return np.array(Image.open(png).convert('RGB')).astype(int)


def compare(fonts, png, text, x, y, style=0):
    """Draw TEXT at (x, y) over the screenshot itself and count changed
    pixels inside the text box; 0 means the firmware drew exactly this."""
    scr = quantize_screen(png) if isinstance(png, str) else png
    canvas = scr.copy().astype(np.uint8)
    canvas, w = fonts.render(text, style, canvas=canvas, x0=x, y0=y)
    box = (slice(y, y + 27), slice(x, x + w))
    diff = np.any(canvas[box].astype(int) != scr[box], axis=2)
    # also check that every ink-coloured pixel in the box is explained
    pal = np.array([rgb565_expand(c) for c in fonts.styles[style][1:]])
    ink = np.zeros(diff.shape, bool)
    for c in pal:
        ink |= np.all(scr[box] == c, axis=2)
    blank = fonts.render(text, style, canvas=np.zeros_like(canvas), x0=x, y0=y)[0][box]
    drawn = np.any(blank != 0, axis=2)
    return dict(width=w, changed=int(diff.sum()), ink_pixels=int(ink.sum()),
                ink_unexplained=int((ink & ~drawn).sum()), drawn=int(drawn.sum()))


def find(fonts, png, text, style=0, step=1):
    scr = quantize_screen(png)
    H, W = scr.shape[:2]
    best = None
    lay, w = fonts.layout(text)
    first = lay[0]
    G = fonts.glyph(first[1], first[2])
    ys, xs = np.nonzero(G == 3)
    c3 = np.array(rgb565_expand(fonts.styles[style][3]))
    hits = np.all(scr == c3, axis=2)
    for y in range(0, H - 27):
        for x in range(0, W - w):
            if not hits[y + ys[0], x + xs[0]]:
                continue
            if not hits[y + ys, x + xs].all():
                continue
            r = compare(fonts, scr, text, x, y, style)
            if best is None or r['changed'] < best[0]['changed']:
                best = (r, x, y)
    return best


# ---------------------------------------------------------- re-encode
def encode_latin(levels, widths_by_page, pages_template):
    """levels: list of 27x28 arrays (glyph order); widths_by_page:
    {(page, code): width} overriding pages_template. Returns (blob, pages_bytes)."""
    blob = b''.join(pack2(g[:27, :28], 7) for g in levels)
    out = bytearray()
    for p, page in enumerate(pages_template):
        for c, (w, off) in enumerate(page):
            out += struct.pack('>II', widths_by_page.get((p, c), w), off)
    return blob, bytes(out)


def okumura_pack(data):
    """Port of Haruhiko Okumura's 1989 lzss.c encoder (public domain): binary
    search trees, N=4096, F=18, THRESHOLD=2, ring filled with 0x20, r=N-F.
    The stock font stream (3,657,695 B) is exactly this program's output on
    the decoded archive, so re-encoding the stock archive with it is
    byte-identical. Pure Python: ~1-2 min for the 5.7 MB archive."""
    N, F, NIL = 4096, 18, 4096
    tb = bytearray(N + F - 1)
    lson = [NIL] * (N + 1)
    rson = [NIL] * (N + 257)
    dad = [NIL] * (N + 1)
    st = {'pos': 0, 'len': 0}

    def insert(r):
        cmp = 1
        p = N + 1 + tb[r]
        rson[r] = lson[r] = NIL
        st['len'] = 0
        while True:
            if cmp >= 0:
                if rson[p] != NIL:
                    p = rson[p]
                else:
                    rson[p] = r
                    dad[r] = p
                    return
            else:
                if lson[p] != NIL:
                    p = lson[p]
                else:
                    lson[p] = r
                    dad[r] = p
                    return
            i = 1
            while i < F:
                cmp = tb[r + i] - tb[p + i]
                if cmp:
                    break
                i += 1
            if i > st['len']:
                st['pos'] = p
                st['len'] = i
                if i >= F:
                    break
        dad[r] = dad[p]
        lson[r] = lson[p]
        rson[r] = rson[p]
        dad[lson[p]] = r
        dad[rson[p]] = r
        if rson[dad[p]] == p:
            rson[dad[p]] = r
        else:
            lson[dad[p]] = r
        dad[p] = NIL

    def delete(p):
        if dad[p] == NIL:
            return
        if rson[p] == NIL:
            q = lson[p]
        elif lson[p] == NIL:
            q = rson[p]
        else:
            q = lson[p]
            if rson[q] != NIL:
                while rson[q] != NIL:
                    q = rson[q]
                rson[dad[q]] = lson[q]
                dad[lson[q]] = dad[q]
                lson[q] = lson[p]
                dad[lson[p]] = q
            rson[q] = rson[p]
            dad[rson[p]] = q
        dad[q] = dad[p]
        if rson[dad[p]] == p:
            rson[dad[p]] = q
        else:
            lson[dad[p]] = q
        dad[p] = NIL

    out = bytearray()
    code = bytearray([0])
    mask = 1
    s, r = 0, N - F
    for i in range(r):
        tb[i] = 0x20
    src, n, ip = data, len(data), 0
    ln = 0
    while ln < F and ip < n:
        tb[r + ln] = src[ip]
        ln += 1
        ip += 1
    if ln == 0:
        return bytes()
    for i in range(1, F + 1):
        insert(r - i)
    insert(r)
    while ln > 0:
        ml = st['len']
        if ml > ln:
            ml = ln
        if ml <= 2:
            ml = 1
            code[0] |= mask
            code.append(tb[r])
        else:
            mp = st['pos']
            code.append(mp & 0xFF)
            code.append(((mp >> 4) & 0xF0) | (ml - 3))
        mask = (mask << 1) & 0xFF
        if mask == 0:
            out += code
            code = bytearray([0])
            mask = 1
        last = ml
        i = 0
        while i < last and ip < n:
            delete(s)
            c = src[ip]
            ip += 1
            tb[s] = c
            if s < F - 1:
                tb[s + N] = c
            s = (s + 1) & (N - 1)
            r = (r + 1) & (N - 1)
            insert(r)
            i += 1
        while i < last:
            i += 1
            delete(s)
            s = (s + 1) & (N - 1)
            r = (r + 1) & (N - 1)
            ln -= 1
            if ln:
                insert(r)
    if len(code) > 1:
        out += code
    return bytes(out)


def encode_archive(blobs, mode='okumura'):
    """blobs in table order -> (decoded archive, BE32 length + LZSS stream).
    mode 'okumura' reproduces the stock encoder bit for bit; 'optimal' is
    lzss_encode's DP parse (~72 KB smaller on the stock archive)."""
    import lzss_encode
    dec = b''.join(blobs)
    st = okumura_pack(dec) if mode == 'okumura' else lzss_encode.pack(dec, True)
    return dec, struct.pack('>I', len(st)) + st


def roundtrip(fonts, tmp, compress=False):
    res = {}
    for name, b in fonts.blobs.items():
        if b['count'] > 10000 and not compress:
            continue
        png = os.path.join(tmp, '%s_atlas.png' % name)
        atlas(fonts, name).save(png)
        lv = atlas_levels(png, name, b['count'])
        enc = b''.join(pack2(g, b['bpr']) for g in lv)
        res[name] = enc == b['data']
    meta = dump(fonts, tmp)
    widths = {}
    for p, rows in enumerate(meta['latin_pages'].values()):
        for c, (w, off) in enumerate(rows):
            widths[(p, c)] = w
    blob, pages = encode_latin(atlas_levels(os.path.join(tmp, 'iso8859_atlas.png'), 'iso8859', 422),
                               widths, fonts.pages)
    res['iso8859_blob_from_atlas'] = blob == fonts.blobs['iso8859']['data']
    res['latin_pages_from_json'] = pages == fonts.img[a2o(LATIN_PAGES):a2o(LATIN_PAGES) + len(pages)]
    res['archive_concat'] = b''.join(b['data'] for b in fonts.blobs.values()) == fonts.arc
    if compress:
        stock = struct.unpack_from('>I', fonts.img, FONT_OFF)[0]
        res['archive_stream_stock'] = stock
        for mode in ('okumura', 'optimal'):
            dec, framed = encode_archive([b['data'] for b in fonts.blobs.values()], mode)
            res[mode + '_decodes_same'] = lzss_decode.unpack(framed[4:], 0) == fonts.arc
            res[mode + '_stream'] = len(framed) - 4
            res[mode + '_bytes_identical'] = framed == fonts.img[FONT_OFF:FONT_OFF + 4 + stock]
    return res


# ------------------------------------------------------- new latin font
def candidate(fonts, ttf, outdir, px=None, weight=None, fallback=None, baseline=22,
              cap=19, track=0, gamma=1.0):
    """Rasterise TTF into the iso8859 slot: same 422-glyph inventory, 28x27
    cell, 2 bpp, baseline at row `baseline`, size chosen so cap height
    (H) == `cap` px like the stock face. Returns (levels, widths, report)."""
    from PIL import Image, ImageDraw, ImageFont
    from fontTools.ttLib import TTFont

    def load(path, size):
        f = ImageFont.truetype(path, size)
        if weight is not None:
            try:
                axes = f.get_variation_axes()
            except Exception:
                axes = []
            if axes:
                vals = [weight if a['name'] in (b'Weight', 'Weight') else a['default'] for a in axes]
                f.set_variation_by_axes(vals)
        return f

    def has(path):
        return set(TTFont(path).getBestCmap())

    def cap_px(path, size):
        f = load(path, int(round(size * 4)))
        bb = f.getbbox('H', anchor='ls')
        return (bb[3] - bb[1]) / 4.0

    cov = has(ttf)
    fcov = has(fallback) if fallback else set()
    if px is None:  # pick the size whose 'H' is `cap` pixels tall
        px = cap * 2
        for s in [x / 4.0 for x in range(40, 160)]:
            if cap_px(ttf, s) >= cap - 0.05:
                px = s
                break
    inv = fonts.latin_inventory()
    OS = 4                              # supersample then box-filter
    levels, widths, missing, clipped = [], {}, [], []
    for g in range(fonts.blobs['iso8859']['count']):
        cell = np.zeros((27, 28), np.uint8)
        u = inv.get(g, {}).get('unicode')
        adv = 0
        if u is not None:
            ch = chr(u)
            path = ttf if u in cov else (fallback if u in fcov else None)
            if path is None:
                missing.append('U+%04X' % u)
                cell = fonts.glyph('iso8859', g)          # keep stock glyph
                adv = inv[g]['width']
            else:
                f = load(path, int(round(px * OS)))
                im = Image.new('L', (28 * OS, 27 * OS), 0)
                ImageDraw.Draw(im).text((0, baseline * OS), ch, font=f, fill=255, anchor='ls')
                a = np.array(im).reshape(27, OS, 28, OS).mean(axis=(1, 3)) / 255.0
                a = a ** gamma
                cell = np.clip(np.round(a * 3), 0, 3).astype(np.uint8)
                adv = int(round(f.getlength(ch) / OS)) + track
                if np.any(np.array(im)[:, -OS:]) or adv > 28:
                    clipped.append('U+%04X' % u)
        levels.append(cell)
        if u is not None:
            for ref in inv[g]['refs']:
                p, c = ref.split(':')
                widths[(int(p), int(c, 16))] = max(1, min(adv, 28))
    rep = dict(ttf=os.path.basename(ttf), px=px, missing=missing, clipped=clipped)
    if outdir:
        os.makedirs(outdir, exist_ok=True)
        blob, pages = encode_latin(levels, widths, fonts.pages)
        open(os.path.join(outdir, 'iso8859.bin'), 'wb').write(blob)
        open(os.path.join(outdir, 'latin_pages.bin'), 'wb').write(pages)
        rep.update(size_report(fonts, blob, pages))
        json.dump(rep, open(os.path.join(outdir, 'report.json'), 'w'), indent=1)
    return levels, widths, rep


def size_report(fonts, blob, pages):
    """Compressed-size impact. Each blob compresses almost independently
    (4 KB LZSS window, blobs are >15 KB), so the delta of the latin blob
    alone is the archive delta to within a few bytes."""
    import lzss_encode
    old = fonts.blobs['iso8859']['data']
    o, n = len(lzss_encode.pack(old, True)), len(lzss_encode.pack(blob, True))
    pg_old = fonts.img[a2o(LATIN_PAGES):a2o(LATIN_PAGES) + len(pages)]
    po, pn = len(lzss_encode.pack(pg_old, True)), len(lzss_encode.pack(pages, True))
    return dict(latin_raw=len(blob), latin_lzss_stock=o, latin_lzss_new=n, latin_delta=n - o,
                pages_lzss_stock=po, pages_lzss_new=pn, pages_delta=pn - po)


def install_candidate(fonts, levels, widths, chain=None):
    """A Fonts view whose latin font/pages are replaced (for previews)."""
    blob, pages = encode_latin(levels, widths, fonts.pages)
    nf = Fonts.__new__(Fonts)
    nf.__dict__.update(fonts.__dict__)
    nf.blobs = dict(fonts.blobs)
    nf.blobs['iso8859'] = dict(fonts.blobs['iso8859'], data=blob)
    nf.pages = [[struct.unpack_from('>II', pages, 8 * (256 * p + c)) for c in range(256)] for p in range(5)]
    return nf


# ---------------------------------------------------------------- CLI
def _opt(args, name, default=None, conv=str):
    if name in args:
        i = args.index(name)
        v = args[i + 1]
        del args[i:i + 2]
        return conv(v)
    return default


def main(argv):
    args = list(argv[1:])
    if not args:
        print(__doc__)
        return 1
    cmd = args.pop(0)
    img = _opt(args, '--img')
    style = _opt(args, '--style', 0, int)
    if cmd == 'candidate':
        px = _opt(args, '--px', None, float)
        fb = _opt(args, '--fallback')
        wt = _opt(args, '--weight', None, float)
        fonts = Fonts(load_image(img))
        lv, w, rep = candidate(fonts, args[0], args[1], px=px, fallback=fb, weight=wt)
        print(json.dumps(rep, indent=1))
        return 0
    fonts = Fonts(load_image(img))
    if cmd == 'dump':
        allf = '--all' in args
        args = [a for a in args if a != '--all']
        meta = dump(fonts, args[0], allf)
        for n, f in meta['fonts'].items():
            print('%-10s base %#010x size %8d glyphs %5d cell %dx%d' % (n, f['base'], f['size'], f['count'], f['w'], f['h']))
    elif cmd == 'render':
        from PIL import Image
        bg = _opt(args, '--bg', '000000')
        zoom = _opt(args, '--zoom', 1, int)
        c, w = fonts.render(args[0], style, bg=tuple(bytes.fromhex(bg)))
        im = Image.fromarray(c)
        im.resize((im.width * zoom, im.height * zoom), Image.NEAREST).save(args[1])
        print('width', w)
    elif cmd == 'compare':
        print(compare(fonts, args[0], args[1], int(args[2]), int(args[3]), style))
    elif cmd == 'find':
        print(find(fonts, args[0], args[1], style))
    elif cmd == 'roundtrip':
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            print(json.dumps(roundtrip(fonts, t, '--compress' in args), indent=1))
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
