#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""font3000: the GUI's latin text font replaced, CDJ-3000 style (opt-in).

Selected in patch_update.py / verify_update.py as the pseudo-mod `font3000`
(GUI image only). Format and evidence: re/GUI_FONTS.md; this mod:
re/FONT3000.md.

THE FACE (2026-11-16): by default our own open face, Cueline Sans
(mods/v2ui/fonts/CuelineSans: a modified Outfit, SIL OFL 1.1, built by its
build_font.py), rasterised at cap height 16 px; glyphs it lacks (Greek,
Cyrillic, part of Latin Ext-A) keep the stock bitmap unless a fallback face is
given. Nothing Pioneer-made is needed or read. Optional private overrides:

    CDJ_FONT3000_TTF       e.g. another open TTF (an override: such builds
                           differ from the reference)
    CDJ_FONT3000_FALLBACK  e.g. RobotoCondensed.ttf (OFL) for the glyphs the
                           face lacks

What changes, nothing else:
  1. The ISO8859 blob (the first 79,758 bytes of the font archive, 422 cells
     of 28x27, 2 bpp) gets the new glyphs: gui_fonts.candidate(cap=16,
     baseline=22), same inventory, same cell, same size; ink past a
     glyph's advance is fitted (fit_advances: the deck draws only <advance>
     columns). The archive keeps
     its decoded size (0x57C099) and every blob offset.
  2. The archive's LZSS stream (image 0x440000 = flash 0x470000, BE32 length
     + stream, decoded by the bootloader by that length) is re-encoded only
     where it must be: the base stream is cut at the first 8-item flag group
     that starts at least one ring (4,096 B) past the latin blob, the part
     before is encoded anew (lzss_encode's optimal parse, padded to a whole
     number of flag groups) and the base stream's own bytes follow unchanged
     from there. The decoder's state at the cut (ring contents = the last
     4,096 decoded bytes, ring index = position) is the same either way, so
     the tail decodes as it always did. The rest of the window up to
     0x7C0000 stays zero (stock: zero after the stream).
  3. The advance widths in the five latin code pages (RAM 0x0E592DA0, 5 x 256
     x {BE32 width, BE32 offset}; file 0x92EA0) become the new font's. Byte
     offsets (glyph x 189) do not change.
Before writing, the latin blob, the pages and the decoded archive length are
checked against their stock 1.81 values;
after, the new stream is decoded in full and compared with the intended
archive.

    usage: font3000.py resblob <in.UPD|GUI section|gui_unpacked.bin> <out.bin>
               the decoded font archive of an image (what the emulator loads
               at 0x0DF00000, CDJ_GUI_FONTBLOB / <fw>/resblob.bin)
           font3000.py preview OUT.png [TEXT ...]   the new face, rendered
"""
import hashlib
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
FIRMWARE = os.path.join(HERE, '..', '..', 'scripts', 'firmware')
sys.path.insert(0, FIRMWARE)
import gui_fonts as gf          # noqa: E402
import lzss_decode              # noqa: E402
import lzss_encode              # noqa: E402

ENV_TTF, ENV_FALLBACK = 'CDJ_FONT3000_TTF', 'CDJ_FONT3000_FALLBACK'
CAP, BASELINE = 16, 22          # the approved look (re/fonts mockups, "cap 16")

FONT_OFF = gf.FONT_OFF                          # 0x440000
FONT_LIMIT = 0x7C0000                           # the stream must end by the image end
ARCHIVE_LEN = 0x57C099
LATIN_LEN = 422 * 189                           # 79,758
PAGES_OFF, PAGES_LEN = gf.a2o(gf.LATIN_PAGES), 5 * 256 * 8     # 0x92EA0, 10,240
RING = 4096
CUT_MIN = LATIN_LEN + RING                      # first decoded position the tail may start at

# stock 1.81 (extract/gui_unpacked.bin, resblob.bin)
STOCK_ARCHIVE_SHA = 'cb61896e8d6b3d3fe317e2af14a05c5729593beb084d0e53b98968181272d768'
STOCK_LATIN_SHA = '273269b5925e8b7b3927ee8205365bbd4a26f196468956c6f5a530c2f0d44db1'
STOCK_PAGES_SHA = '146ebc4f16ef18e3be8d3e715debf4b1b9bee4c21f731c4a4adbc61a0a50ae91'
# the font files the approved build was made from (a different file still
# builds, with a warning: the look may differ)
KNOWN_TTF_SHA = {
    # (an earlier private face's entry was removed)
    'dace262afcee68a5276f200d8026c57221735c0118ab5fda8c2c0d3dc409a8d0': 'RobotoCondensed.ttf (OFL)',
}
DEFAULT_TTF = os.path.join(HERE, '..', 'v2ui', 'fonts', 'CuelineSans', 'CuelineSans-Regular.ttf')

WHAT = 'GUI latin font: Cueline Sans (ours, OFL) at cap 16 px, CDJ-3000 style (%s overrides)' % ENV_TTF


def die(msg):
    raise SystemExit('font3000: %s' % msg)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def font_paths():
    """(face, fallback or None): the env overrides, else Cueline Sans and no
    fallback (glyphs the face lacks keep their stock bitmap)."""
    paths = []
    for env, default in ((ENV_TTF, DEFAULT_TTF), (ENV_FALLBACK, None)):
        p = os.environ.get(env) or default
        if not p:
            paths.append(None)
            continue
        if not os.path.isfile(p):
            die('%s: no such file%s' % (p, '' if os.environ.get(env) else
                                       ' (run mods/v2ui/fonts/CuelineSans/build_font.py)'))
        if os.environ.get(env):
            h = sha(open(p, 'rb').read())
            if h not in KNOWN_TTF_SHA:
                print('font3000: WARNING %s is not the file the approved build used (sha256 %s)'
                      % (p, h[:16]))
        paths.append(p)
    return paths


# ------------------------------------------------------------ the archive
def stream_of(img):
    n = struct.unpack_from('>I', img, FONT_OFF)[0]
    if not 0 < n <= FONT_LIMIT - FONT_OFF - 4:
        die('font archive length %#x out of bounds' % n)
    return img[FONT_OFF + 4:FONT_OFF + 4 + n]


def groups(stream):
    """[(stream offset, decoded position)] of every flag group's start."""
    out, i, pos, n = [], 0, 0, len(stream)
    while i < n:
        out.append((i, pos))
        flags = stream[i]
        i += 1
        for b in range(8):
            if i >= n:
                break
            if flags >> b & 1:
                i += 1
                pos += 1
            else:
                if i + 1 >= n:
                    i = n
                    break
                pos += (stream[i + 1] & 0x0F) + 3
                i += 2
    return out


def items_optimal(data):
    """lzss_encode.pack_optimal's parse as a list: ('L',) / ('M', ring
    position, length)."""
    lens, srcs, cb = lzss_encode.longest_matches(data, lzss_encode.OPTIMAL_DEPTH)
    n = len(data)
    cost = [0] * (n + 1)
    take = bytearray(n)
    for i in range(n - 1, -1, -1):
        best, choice = 9 + cost[i + 1], 0
        L = lens[i]
        if L >= 3:
            for k in range(L, 2, -1):
                c = 17 + cost[i + k]
                if c < best:
                    best, choice = c, k
        cost[i], take[i] = best, choice
    items, k = [], 0
    while k < n:
        if take[k]:
            items.append(('M', srcs[k] & (RING - 1), take[k]))
            k += take[k]
        else:
            items.append(('L',))
            k += 1
    return items


def pad_to_groups(items):
    """Split matches until the item count is a multiple of 8, so the encoded
    prefix ends on a whole flag group: a match (p, L>=4) becomes a literal of
    its first byte and the match (p+1, L-1) -- the same bytes, since the
    decoder copies one byte at a time through the ring."""
    items = list(items)
    i = len(items) - 1
    while len(items) % 8:
        while i >= 0 and not (items[i][0] == 'M' and items[i][2] >= 4):
            i -= 1
        if i < 0:
            die('cannot pad the re-encoded prefix to a whole flag group')
        _, p, L = items[i]
        # (encode_items writes the literal from the data: the byte this
        # match copied first)
        items[i:i + 1] = [('L',), ('M', (p + 1) & (RING - 1), L - 1)]
    return items


def encode_items(items, data):
    out, code, mask, pos = bytearray(), bytearray(1), 1, 0
    for it in items:
        if it[0] == 'M':
            _, p, L = it
            code += bytes([p & 0xFF, ((p >> 4) & 0xF0) | (L - 3)])
            pos += L
        else:
            code[0] |= mask
            code.append(data[pos])
            pos += 1
        mask = (mask << 1) & 0xFF
        if not mask:
            out += code
            code, mask = bytearray(1), 1
    if len(code) > 1:
        out += code
    if pos != len(data):
        die('internal: prefix items cover %d of %d bytes' % (pos, len(data)))
    return bytes(out)


def splice(base_stream, new_archive):
    """The base stream with its head re-encoded for new_archive (which may
    differ from the base's decoded archive only before CUT_MIN - RING)."""
    cut = next(((s, p) for s, p in groups(base_stream) if p >= CUT_MIN), None)
    if cut is None:
        die('no flag group past %d in the base font stream' % CUT_MIN)
    s, p = cut
    items = pad_to_groups(items_optimal(new_archive[:p]))
    head = encode_items(items, new_archive[:p])
    return head + base_stream[s:], dict(cut_stream=s, cut_pos=p, head_old=s, head_new=len(head))


# --------------------------------------------------------------- the face
def lite_fonts(img, latin):
    """A gui_fonts.Fonts holding only what candidate() reads: the latin blob
    and the five code pages of this image."""
    f = gf.Fonts.__new__(gf.Fonts)
    f.img = img
    f.blobs = {'iso8859': dict(base=gf.FONT_RAM, size=LATIN_LEN, kind=3, w=28, h=27, bpr=7,
                               gsize=189, count=422, adv=None, data=latin)}
    f.pages = gf.Fonts.read_pages(img)
    return f


def build_face(img, latin):
    """(new latin blob, new page bytes, candidate report) from the env fonts."""
    ttf, fallback = font_paths()
    f = lite_fonts(img, latin)
    levels, widths, rep = gf.candidate(f, ttf, None, fallback=fallback, weight=None,
                                       cap=CAP, baseline=BASELINE)
    rep['trimmed'], rep['widened'] = fit_advances(f, levels, widths)
    blob, pages = gf.encode_latin(levels, widths, f.pages)
    from fontTools.ttLib import TTFont
    own = set(TTFont(ttf).getBestCmap())
    inv = f.latin_inventory()
    rep['fallback'] = sum(1 for g in inv.values() if g['unicode'] not in own
                          and 'U+%04X' % g['unicode'] not in rep['missing'])
    if len(blob) != LATIN_LEN or len(pages) != PAGES_LEN:
        die('internal: face sizes %d/%d' % (len(blob), len(pages)))
    return blob, pages, rep


def fit_advances(f, levels, widths):
    """The blitter draws only the first <advance> columns of a latin cell
    (the glyph call hands it w = the advance; seen in the emulator: the K of
    "TRACK" lost its 13th column). Ink past the advance would be cut: a
    column there holding only level-1 (faintest) pixels is cleared, as the
    deck would anyway; anything stronger widens the advance to cover it
    ('(' and the like, whose outline overhangs its advance).
    Returns (trimmed, widened) glyph lists."""
    trimmed, widened = [], []
    for g, d in sorted(f.latin_inventory().items()):
        refs = [(int(p), int(c, 16)) for p, c in (r.split(':') for r in d['refs'])]
        adv = widths[refs[0]]
        cell = levels[g]
        over = cell[:, adv:]
        if not over.any():
            continue
        if over.max() <= 1:
            cell[:, adv:] = 0
            trimmed.append(chr(d['unicode']))
        else:
            cols = np.nonzero(cell.any(axis=0))[0]
            new = min(28, int(cols[-1]) + 1)
            for r in refs:
                widths[r] = new
            widened.append('%s %d->%d' % (chr(d['unicode']), adv, new))
    return trimmed, widened


def expected(img):
    """(base archive, intended archive, new pages, report) for this image,
    after checking that its font bytes are the stock ones."""
    stream = stream_of(img)
    arc = lzss_decode.unpack(stream, 0)
    if len(arc) != ARCHIVE_LEN:
        die('the base font archive decodes to %#x bytes, not %#x' % (len(arc), ARCHIVE_LEN))
    if sha(arc[:LATIN_LEN]) != STOCK_LATIN_SHA:
        die('the base latin font is not the stock 1.81 one (already patched?)')
    if sha(img[PAGES_OFF:PAGES_OFF + PAGES_LEN]) != STOCK_PAGES_SHA:
        die('the latin code pages at %#x are not the stock 1.81 ones' % PAGES_OFF)
    blob, pages, rep = build_face(img, arc[:LATIN_LEN])
    return stream, arc, blob + arc[LATIN_LEN:], pages, rep


def apply(data):
    """The image with font3000 written (see the module doc)."""
    img = bytearray(data)
    stream, arc, new_arc, pages, rep = expected(data)
    new_stream, cut = splice(stream, new_arc)
    if FONT_OFF + 4 + len(new_stream) > FONT_LIMIT:
        die('the new font stream (%d B) does not fit before %#x' % (len(new_stream), FONT_LIMIT))
    if lzss_decode.unpack(new_stream, 0) != new_arc:
        die('the new font stream does not decode to the intended archive')
    old_end = FONT_OFF + 4 + len(stream)
    if any(img[old_end:FONT_LIMIT]):
        die('bytes after the base font stream (%#x..%#x) are not zero' % (old_end, FONT_LIMIT))
    img[FONT_OFF:FONT_LIMIT] = bytes(FONT_LIMIT - FONT_OFF)
    img[FONT_OFF:FONT_OFF + 4] = struct.pack('>I', len(new_stream))
    img[FONT_OFF + 4:FONT_OFF + 4 + len(new_stream)] = new_stream
    img[PAGES_OFF:PAGES_OFF + PAGES_LEN] = pages
    print('patch_update: font3000: latin font %s at %.2f px (cap %d), %d glyphs from the '
          'fallback, %d kept stock; stream %d -> %d B (head %d -> %d B up to decoded %#x, '
          'the rest of the base stream unchanged)'
          % (rep['ttf'], rep['px'], CAP, rep['fallback'], len(rep['missing']),
             len(stream), len(new_stream), cut['head_old'], cut['head_new'], cut['cut_pos']))
    print('font3000: past-the-advance ink: %d faint columns cleared (%s), %d advances widened (%s)'
          % (len(rep['trimmed']), ''.join(rep['trimmed']), len(rep['widened']),
             ', '.join(rep['widened'])))
    if rep['clipped']:
        print('font3000: note: %d glyphs touch the cell edge: %s'
              % (len(rep['clipped']), ' '.join(rep['clipped'][:12])))
    return bytes(img)


def check_gui(cand, base):
    """[(ok, what)] for verify_update: cand = the candidate GUI image, base =
    the image font3000 was applied to (stock)."""
    stream, arc, new_arc, pages, _ = expected(base)
    c_stream = stream_of(cand)
    c_arc = lzss_decode.unpack(c_stream, 0)
    end = FONT_OFF + 4 + len(c_stream)
    return [
        (len(c_arc) == ARCHIVE_LEN and c_arc == new_arc,
         'font3000: font archive decodes to the intended %#x bytes (sha256 %s)'
         % (ARCHIVE_LEN, sha(c_arc)[:16])),
        (c_arc[LATIN_LEN:] == arc[LATIN_LEN:],
         'font3000: the five other blobs (JIS, KS, GB) unchanged'),
        (cand[PAGES_OFF:PAGES_OFF + PAGES_LEN] == pages,
         'font3000: latin code pages at %#x = the new widths (offsets unchanged)' % PAGES_OFF),
        (all(struct.unpack_from('>I', cand, PAGES_OFF + 8 * k + 4)
             == struct.unpack_from('>I', base, PAGES_OFF + 8 * k + 4) for k in range(5 * 256)),
         'font3000: every glyph offset in the code pages as stock'),
        (end <= FONT_LIMIT and not any(cand[end:FONT_LIMIT]),
         'font3000: stream ends at %#x, zeros after it up to %#x' % (end, FONT_LIMIT)),
    ]


def resblob(path, out):
    img = gf.load_image(path)
    arc = lzss_decode.unpack(stream_of(img), 0)
    with open(out, 'wb') as f:
        f.write(arc)
    print('font3000: %s: font archive %#x bytes (sha256 %s) -> %s'
          % (path, len(arc), sha(arc)[:16], out))


def preview(out, texts):
    from PIL import Image
    import numpy as np
    img = gf.load_image()
    stream = stream_of(img)
    arc = lzss_decode.unpack(stream, 0)
    blob, pages, _ = build_face(img, arc[:LATIN_LEN])
    f = gf.Fonts(img, arc)
    f.blobs['iso8859'] = dict(f.blobs['iso8859'], data=blob)
    f.pages = [[struct.unpack_from('>II', pages, 8 * (256 * p + c)) for c in range(256)]
               for p in range(5)]
    rows = [f.render(t, 0, bg=(16, 16, 16))[0] for t in texts]
    w = max(r.shape[1] for r in rows)
    canvas = np.full((31 * len(rows), w + 8, 3), 16, np.uint8)
    for k, r in enumerate(rows):
        canvas[31 * k + 2:31 * k + 29, 4:4 + r.shape[1]] = r
    Image.fromarray(canvas).resize((canvas.shape[1] * 2, canvas.shape[0] * 2), Image.NEAREST).save(out)


def main(argv):
    if len(argv) == 3 and argv[0] == 'resblob':
        resblob(argv[1], argv[2])
    elif len(argv) >= 2 and argv[0] == 'preview':
        preview(argv[1], argv[2:] or ['【TRACK】 Aaiko (Extended Mix)', 'FLAC 120.0 4A 6:58',
                                      'ÀÉÎÕÜ ñç ß ŁŚŽ ЖЯ ΩΣ 0123456789'])
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
