#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""guitrim (opt-in, GUI 1.81): room in the GUI section by re-encoding and blanking resource data
that no screen of a v2ui build ever reads. re/GUI_RECLAIM.md.

Proprietary firmware: nothing of it is in this file -- record numbers, offsets and hashes only.

The GUI image (0x7C0000 decoded) carries two LZSS archives that the GUI boot loader unpacks to SDRAM
(re/GUI_FONTS.md, gui_artwork.py), each a BE32 length + a stream in the same codec as the section:
  art   image 0x150000 -> 0x0CD00000, 0xFAF850 B: 1,435 records (44-B directory, RGB565 pixels)
  font  image 0x440000 -> 0x0DF00000, 0x57C099 B: six 2-bpp glyph banks (iso8859, jisx0201, jisx0208,
        ksx1001, gb18030, gb18030jh)
Both are already-compressed data inside the section's own LZSS, so every byte saved in a stream is
~1.1 B of section.

Pseudo-mods (patch_update.py / verify_update.py), applied last (after font3000 and v2ui); each one
implies `guitrim`:
  guitrim      R  the font stream re-encoded whole with the optimal parse. Same decoded bytes
                  (Pioneer's stream is a greedy parse): ~62 KB of section, no content change.
                  Zero runs of 4 KB+ are coded as matches at ONE fixed ring position: the stream then
                  repeats a 17-byte group that the section's own LZSS packs again (a zeroed byte
                  costs ~0.015 B of section instead of ~0.12 B).
  guitrim_cjk  C  + the Chinese and Korean glyph banks (ksx1001, gb18030, gb18030jh) -> zero. Only
                  stock-drawn text with Chinese/Korean characters reaches them. lang2 has no such UI
                  language, and our renderer draws every track and metadata string itself from its
                  own atlas. In the read-watch tours nothing read them. ~3.2 MB of section.
  guitrim_jis  J  + the kanji rows (16..92) of jisx0208 -> zero. Rows 1..15 stay: symbols, kana, Greek,
                  Cyrillic. The stock UI draws its rating stars from row 1 (JIS 0x2179, read in
                  player INFO). ~0.7 MB.
  guitrim_art  A  + 524 art records never read in any tour -> zero pixels. Only whole same-size
                  families with no read member are taken, minus a curated keep list (SEARCH keyboard,
                  rekordbox / PC-link / SOURCE art, the "Wait" spinner, unknown big panels). Other
                  records, sizes and the directory do not change. Spliced into the base stream
                  (lzsplice). ~0.7 MB. RISKIEST tier: a stock screen we never provoked, or the
                  stock fallback UI (v2ui's RO copy failing) would show black holes there.
Checks before writing: the archives decode to their stock lengths, and every byte to be blanked is
the stock 1.81 data (sha256). After writing: each new stream decodes to the intended archive and
ends inside its window, with zeros after it.
"""
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', '..', 'scripts', 'firmware'))
import lzsplice            # noqa: E402
import lzss_decode         # noqa: E402

WHAT = {
    'guitrim': 'GUI room: the font archive re-encoded with the optimal LZSS parse (same bytes), ~62 KB',
    'guitrim_cjk': 'GUI room: + the Chinese/Korean glyph banks blanked (implies guitrim), ~3.2 MB',
    'guitrim_jis': 'GUI room: + the Japanese kanji rows blanked; symbols/kana kept (implies guitrim), ~0.7 MB',
    'guitrim_art': 'GUI room: + 524 never-read art records blanked (implies guitrim; riskiest), ~0.7 MB',
}
NAMES = tuple(WHAT)

ART_OFF, ART_END, ART_LEN = 0x150000, 0x440000, 0xFAF850
FONT_OFF, FONT_END, FONT_LEN = 0x440000, 0x7C0000, 0x57C099
NREC, RECSZ = 1435, 0x2C
# font banks: decoded offsets in the archive (RAM 0x0DF00000 + off)
BANKS = {'iso8859': (0x000000, 0x01378E), 'jisx0201': (0x01378E, 0x0173A9),
         'jisx0208': (0x0173A9, 0x13A979), 'ksx1001': (0x13A979, 0x1B9459),
         'gb18030': (0x1B9459, 0x55910D), 'gb18030jh': (0x55910D, 0x57C099)}
CJK = ('ksx1001', 'gb18030', 'gb18030jh')
JIS_KEEP_ROWS = 15
BANKS['jiskanji'] = (BANKS['jisx0208'][0] + JIS_KEEP_ROWS * 94 * 138, BANKS['jisx0208'][1])

# guitrim_art: inclusive record ranges (re/GUI_RECLAIM.md: never read in tours A/B/U, whole
# same-size families only, curated keep list removed)
ART_RANGES = ((0, 144), (146, 146), (183, 183), (306, 306), (319, 319), (557, 557), (629, 680),
              (683, 683), (686, 686), (688, 692), (695, 730), (755, 756), (758, 758), (866, 867),
              (921, 927), (1010, 1062), (1068, 1086), (1088, 1088), (1101, 1105), (1130, 1211),
              (1213, 1243), (1347, 1376), (1379, 1406), (1409, 1426))
BLANK = tuple(r for lo, hi in ART_RANGES for r in range(lo, hi + 1))
# sha256 of the stock 1.81 bytes each tier blanks (hashes only: no firmware data here)
STOCK = {
    'artdir': '8b5978a44f88ce112620acf061342465f5dbd6bcc4f216d3d389b9612e04c2c5',
    'artblank': 'aad92e3c2ce7e0bfceea91141dabe33405836c53b3d1db74bd3c6b42d5dba32b',
    'ksx1001': '34afc7891989b78cff54fb4956556e6743e379ab5287efe16151c06bc58e5f60',
    'gb18030': 'aaf9d841a66b6c84e1c913b604a608c726f4b0c22c68633ce6941adc8db4030c',
    'gb18030jh': '036fc099c8779faec1fdd4494093902d010b9e44798daaab1fcab9227f60ff9c',
    'jiskanji': 'd628e593ac9efaa8033264cad7d6b1551d0bfd1d18e00b57108248ebefc8f45b',
}


def die(msg):
    raise SystemExit('guitrim: ' + msg)


def sha(b):
    return hashlib.sha256(bytes(b)).hexdigest()


def stream(img, off, end):
    n = struct.unpack_from('>I', img, off)[0]
    if not 0 < n <= end - off - 4:
        die('archive length %#x at %#x out of bounds' % (n, off))
    return bytes(img[off + 4:off + 4 + n])


def records(arc):
    out = []
    for i in range(NREC):
        wh, = struct.unpack_from('>I', arc, i * RECSZ + 4)
        off, = struct.unpack_from('>I', arc, i * RECSZ + 0x20)
        out.append((off, (wh >> 16) * (wh & 0xFFFF) * 2))
    return out


def put(img, off, end, new, old_len):
    if off + 4 + len(new) > end:
        die('the new stream at %#x (%d B) does not fit before %#x' % (off, len(new), end))
    if any(img[off + 4 + old_len:end]):
        die('bytes after the stream at %#x are not zero' % off)
    img[off:off + 4] = struct.pack('>I', len(new))
    img[off + 4:end] = bytes(end - off - 4)
    img[off + 4:off + 4 + len(new)] = new


def art_plan(arc):
    recs = records(arc)
    new = bytearray(arc)
    spans = []
    for r in BLANK:
        o, n = recs[r]
        new[o:o + n] = bytes(n)
        spans.append((o, o + n))
    return bytes(new), spans


def tiers(names):
    return {n for n in names if n in NAMES}


def font_banks(names):
    t = tiers(names)
    return (CJK if 'guitrim_cjk' in t else ()) + (('jiskanji',) if 'guitrim_jis' in t else ())


def apply(data, names=('guitrim',)):
    img = bytearray(data)
    t = tiers(names)
    # A: art records (splice: only the windows around the blanked records are re-encoded)
    if 'guitrim_art' in t:
        st = stream(img, ART_OFF, ART_END)
        arc = lzss_decode.unpack(st, 0)
        if len(arc) != ART_LEN:
            die('art archive decodes to %#x B, not %#x' % (len(arc), ART_LEN))
        recs = records(arc)
        if sha(arc[:NREC * RECSZ]) != STOCK['artdir'] or \
                sha(b''.join(arc[o:o + n] for o, n in (recs[r] for r in BLANK))) != STOCK['artblank']:
            die('art archive is not stock 1.81 (directory or the records to blank)')
        new, spans = art_plan(arc)
        ns = lzsplice.splice(st, new, spans)
        if lzss_decode.unpack(ns, 0) != new:
            die('the new art stream does not decode to the intended archive')
        put(img, ART_OFF, ART_END, ns, len(st))
    # R (+C, J): the font archive re-encoded whole
    st = stream(img, FONT_OFF, FONT_END)
    arc = bytearray(lzss_decode.unpack(st, 0))
    if len(arc) != FONT_LEN:
        die('font archive decodes to %#x B, not %#x' % (len(arc), FONT_LEN))
    for b in font_banks(names):
        lo, hi = BANKS[b]
        if sha(arc[lo:hi]) != STOCK[b]:
            die('glyph bank %s is not stock 1.81' % b)
        arc[lo:hi] = bytes(hi - lo)
    ns = lzsplice.encode(bytes(arc), depth=1024)
    if lzss_decode.unpack(ns, 0) != bytes(arc):
        die('the new font stream does not decode to the intended archive')
    put(img, FONT_OFF, FONT_END, ns, len(st))
    return bytes(img)


def check_gui(cand, base_applied_without, names):
    """verify_update: [(ok, what)] for a candidate image against the same build without guitrim."""
    out = []
    for off, end, ln, what in ((ART_OFF, ART_END, ART_LEN, 'art'), (FONT_OFF, FONT_END, FONT_LEN, 'font')):
        n = struct.unpack_from('>I', cand, off)[0]
        ok = 0 < n <= end - off - 4 and not any(cand[off + 4 + n:end])
        out.append((ok, 'guitrim: %s stream %d B inside %#x..%#x, zeros after it' % (what, n, off, end)))
        if ok:
            a = lzss_decode.unpack(cand[off + 4:off + 4 + n], 0)
            b = lzss_decode.unpack(stream(base_applied_without, off, end), 0)
            out.append((len(a) == ln, 'guitrim: %s archive decodes to %#x B' % (what, len(a))))
            if what == 'art':
                keep = bytearray(b)
                if 'guitrim_art' in tiers(names):
                    keep = bytearray(art_plan(b)[0])
                out.append((a == bytes(keep), 'guitrim: art archive == base with %d records blanked'
                            % (len(BLANK) if 'guitrim_art' in tiers(names) else 0)))
            else:
                keep = bytearray(b)
                for bk in font_banks(names):
                    lo, hi = BANKS[bk]
                    keep[lo:hi] = bytes(hi - lo)
                out.append((a == bytes(keep), 'guitrim: font archive == base with %s blanked'
                            % (', '.join(font_banks(names)) or 'nothing')))
    return out
