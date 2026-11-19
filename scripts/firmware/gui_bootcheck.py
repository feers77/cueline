#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Would the CDJ-2000NXS2 GUI bootloader start this image?  (static check)

    usage: gui_bootcheck.py [--strict] [--quiet] <file> [<file> ...]

<file> is a .UPD, a carved GUI section (starts "CDJ-2000NXS2GUI") or a decoded
GUI image (gui_unpacked.bin, 0x7C0000 bytes). Exit status 0 only when every
file passes; --strict also fails on warnings.

The GUI bootloader (flash 0x0-0x30000 of the SH7269's NOR) is not in any
.UPD and nobody here has its bytes, so this checks what a bootloader that
starts THIS image must rely on -- see re/GUI_BOOTLOADER.md for the evidence
and for what is known versus inferred:

  section (only for .UPD / section input), as the GUI's own update task
  0x0E52607C and its flash task 0x0E50F394 see it:
    S1 header "CDJ-2000NXS2GUI", byte 31 '0' ('1' erases the bootloader)
    S2 CRC-16/XMODEM over [0:len-2] == big-endian trailer
    S3 BE32 stream length fits the section; section <= 8 MB receive buffer
    S4 decoded length even and <= 0x7C0000 (flash 0x30000-0x7F0000)
  image, as a bootloader that scatter-loads it must read it:
    I1 header: [entry][first descriptor], descriptors chained through their
       last word (flash addresses, 0x300D0 -> 0x300A0 -> ... -> 0x30010 -> 0)
    I2 descriptors: three copy triples [dest][flash src][size] and one
       zero-fill pair [dest][size]; sources inside the image, past the
       table, even; destinations inside RAM the SH7269 board has; WARN for
       RAM that no known-good image loads
    I3 no two copies land on the same RAM; a copy over a zero-fill area
       carries zeros there, so copy/zero order is moot
    I4 entry point inside a copied segment
    I5 the image's own trailer: CRC-16/XMODEM BE at 0x14FFFA over [0:end],
       end BE32 at 0x14FFFC, 0 < end <= 0x14FFFA, only 0xFF between end and
       the trailer; WARN when end != the last copied byte (a bootloader that
       takes the range from the table instead would see another CRC)
    I6 artwork archive (flash 0x180000 -> RAM 0x0CD00000) and font archive
       (flash 0x470000 -> RAM 0x0DF00000): length words in bounds, LZSS
       stream decodes, decoded sizes fit their windows (art below the font
       window, fonts below the code at 0x0E500000), artwork directory sane
"""
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lzss_decode                                  # noqa: E402
from gui_encode import crc16_xmodem                 # noqa: E402

IMAGE_LEN = 0x7C0000            # flash 0x30000-0x7F0000
FLASH_BASE = 0x30000            # the image's own flash offset
RX_BUF = 0x800000               # GUI update receive buffer (0x0E6046AC)
STOCK_SECTION = 6931940         # stock GUI section (user rule: never above)
TABLE_END = 0x100               # header + 5 descriptors; code from here
DESC_LEN = 0x30
TRAILER_CRC, TRAILER_END = 0x14FFFA, 0x14FFFC
ART_OFF, FONT_OFF = 0x150000, 0x440000
ART_RAM, FONT_RAM, CODE_RAM = 0x0CD00000, 0x0DF00000, 0x0E500000
ART_RECS, ART_REC = 1435, 44

# RAM the GUI board has (sh7269gui.c / SH7269 manual): CS3 SDRAM and its
# uncached mirror, on-chip large RAM and its mirror, on-chip high-speed RAM.
RAM = [
    (0x0C000000, 0x10000000, 'SDRAM'),
    (0x2C000000, 0x30000000, 'SDRAM (uncached)'),
    (0x1C000000, 0x1C280000, 'on-chip large RAM'),
    (0x3C000000, 0x3C280000, 'on-chip large RAM (uncached)'),
    (0xFFF80000, 0xFFFC0000, 'on-chip high-speed RAM'),
]


# RAM that known-good images load (stock 1.81 and images booted on a real
# deck): the bootloader's own working RAM is unknown, so outside these is
# untested. On-chip segment 2 grown to 0x1C07F5C0 (descriptor 0x30010 copy 2:
# 0x1C040D30 <- flash, 0x3E890 bytes) boots on a deck, still well inside the
# on-chip RAM the board has (0x1C000000-0x1C280000).
PROVEN = [
    (0x0E500000, 0x0FFECE9C),
    (0x1C000000, 0x1C07F5C0),
    (0xFFF84000, 0xFFF84190),
    (0xFFF88000, 0xFFF8EFEC),
]


def proven(a, n):
    return any(lo <= a and a + n <= hi for lo, hi in PROVEN)


def be32(d, o):
    return struct.unpack_from('>I', d, o)[0]


def ram_of(a, n):
    for lo, hi, name in RAM:
        if lo <= a and a + n <= hi:
            return name
    return None


def phys(a):
    """Cached and uncached views of one RAM as one address space."""
    return a & ~0x20000000 if a < 0xF0000000 else a


class Report:
    def __init__(self):
        self.fails, self.warns, self.notes = [], [], []

    def fail(self, msg):
        self.fails.append(msg)

    def warn(self, msg):
        self.warns.append(msg)

    def note(self, msg):
        self.notes.append(msg)


def upd_gui_section(data):
    """Section 1 of a .UPD (manifest of CRLF decimal lengths)."""
    import re
    sizes, pos = [], 0
    while True:
        m = re.match(rb'(\d+)\r\n', data[pos:pos + 32])
        if not m:
            break
        sizes.append(int(m.group(1)))
        pos += m.end()
    if not sizes:
        return None
    return data[pos:pos + sizes[0]]


def check_section(sec, r):
    """S1-S4. Returns the decoded image, or None when it cannot be had."""
    if len(sec) < 0x26:
        r.fail('S1 section is %d bytes, too short for a header' % len(sec))
        return None
    hdr = sec[:32]
    if not hdr.startswith(b'CDJ-2000NXS2GUI'):
        r.fail('S1 section header %r is not CDJ-2000NXS2GUI' % hdr[:16])
    r.note('section header %r' % hdr.rstrip(b'\0 ').decode('latin1'))
    if hdr[31:32] == b'1':
        r.fail("S1 header byte 31 is '1': the GUI erases and reprograms flash from 0, "
               "bootloader included (flash task type 1)")
    elif hdr[31:32] != b'0':
        r.warn("S1 header byte 31 is %r, not '0' (the GUI treats anything but '1' as "
               "type 2, image at 0x30000)" % hdr[31:32])
    want = (sec[-2] << 8) | sec[-1]
    got = crc16_xmodem(sec[:-2])
    if got != want:
        r.fail('S2 section CRC-16/XMODEM %#06x != trailer %#06x: the GUI drops the '
               'update (status 3)' % (got, want))
    declared = be32(sec, 0x20)
    if 0x24 + declared > len(sec) - 2:
        r.fail('S3 BE32 stream length %d runs past the section' % declared)
    if len(sec) > RX_BUF:
        r.fail('S3 section %d bytes > the 8 MB receive buffer (no bounds check there: '
               'GUI RAM corruption)' % len(sec))
    elif len(sec) > STOCK_SECTION:
        r.warn('S3 section %d bytes > stock %d (house rule: never above stock)'
               % (len(sec), STOCK_SECTION))
    r.note('section %d bytes, stream %d' % (len(sec), declared))
    img = lzss_decode.unpack(sec[:0x24 + declared], 0x24)
    if len(img) > IMAGE_LEN:
        r.fail('S4 decoded %#x bytes > %#x: the flash task refuses it (error 3)'
               % (len(img), IMAGE_LEN))
    if len(img) & 1:
        r.fail('S4 decoded length %#x is odd: the flash task programs len/2 halfwords '
               'and drops the last byte' % len(img))
    return img


def descriptors(img, r):
    """I1: walk the descriptor chain; [(flash addr, 12 words)]."""
    out = []
    p = be32(img, 4)
    seen = set()
    while p:
        o = p - FLASH_BASE
        if p in seen:
            r.fail('I1 descriptor chain loops at %#x' % p)
            return out
        if not (0x10 <= o and o + DESC_LEN <= TABLE_END) or (o - 0x10) % DESC_LEN:
            r.fail('I1 descriptor pointer %#x is not one of the five table slots '
                   '(0x30010 + n*0x30)' % p)
            return out
        seen.add(p)
        w = struct.unpack_from('>12I', img, o)
        out.append((p, w))
        p = w[11]
    if len(out) != 5:
        r.warn('I1 chain visits %d descriptors (stock: 5)' % len(out))
    return out


def check_image(img, r, art_ref=None, font_ref=None):
    if len(img) != IMAGE_LEN:
        (r.fail if len(img) > IMAGE_LEN or len(img) < ART_OFF else r.warn)(
            'I0 image is %#x bytes, stock is %#x' % (len(img), IMAGE_LEN))
        if len(img) < TRAILER_END + 4:
            return
    entry, head = be32(img, 0), be32(img, 4)
    if head != 0x300D0:
        r.warn('I1 first descriptor %#x (stock 0x300d0)' % head)
    if any(img[8:16]):
        r.warn('I1 header words 2-3 are not zero: %s' % img[8:16].hex())
    descs = descriptors(img, r)

    copies, zeros = [], []
    for p, w in descs:
        for k in range(3):
            dest, src, size = w[3 * k:3 * k + 3]
            if not size:
                continue
            tag = 'descriptor %#x copy %d (%#010x <- flash %#x, %#x)' % (p, k, dest, src, size)
            off = src - FLASH_BASE
            if src < FLASH_BASE + TABLE_END or off + size > IMAGE_LEN:
                r.fail('I2 %s: source outside the image code area' % tag)
                continue
            if off + size > TRAILER_CRC:
                r.warn('I2 %s: source runs into the trailer/archives' % tag)
            if (src | dest) & 1:
                r.fail('I2 %s: odd source or destination (x16 flash, SH-2A code)' % tag)
            elif (src | dest) & 3:
                r.warn('I2 %s: source or destination not 4-aligned' % tag)
            if not ram_of(dest, size):
                r.fail('I2 %s: destination is not RAM the GUI board has' % tag)
            elif not proven(phys(dest), size):
                r.warn('I2 %s: RAM no known-good image loads (the bootloader\'s own '
                       'working RAM is unknown)' % tag)
            copies.append((phys(dest), size, off, tag))
        zdest, zsize = w[9], w[10]
        if zsize:
            tag = 'descriptor %#x zero-fill (%#010x, %#x)' % (p, zdest, zsize)
            if not ram_of(zdest, zsize):
                r.fail('I2 %s: not RAM the GUI board has' % tag)
            elif not proven(phys(zdest), zsize):
                r.warn('I2 %s: RAM no known-good image loads' % tag)
            zeros.append((phys(zdest), zsize, tag))

    for i, (d1, n1, _, t1) in enumerate(copies):
        for d2, n2, _, t2 in copies[i + 1:]:
            if d1 < d2 + n2 and d2 < d1 + n1:
                r.fail('I3 %s and %s overlap in RAM' % (t1, t2))
        for zd, zn, zt in zeros:
            lo, hi = max(d1, zd), min(d1 + n1, zd + zn)
            if lo < hi:
                o = copies[i][2] + (lo - d1)
                if any(img[o:o + hi - lo]):
                    r.fail('I3 %s overlaps %s with non-zero bytes: the result depends on '
                           'whether the bootloader copies or zero-fills first' % (t1, zt))
                else:
                    r.note('%s covers %#x bytes of %s with zeros (order-proof)'
                           % (t1, hi - lo, zt))
    if not any(d <= phys(entry) < d + n for d, n, _, _ in copies):
        r.fail('I4 entry %#010x is not inside any copied segment' % entry)
    elif entry & 1:
        r.fail('I4 entry %#010x is odd' % entry)

    # I5: the image trailer
    want = struct.unpack_from('>H', img, TRAILER_CRC)[0]
    end = be32(img, TRAILER_END)
    if not 0 < end <= TRAILER_CRC:
        r.fail('I5 trailer end %#x outside (0, %#x]' % (end, TRAILER_CRC))
    else:
        got = crc16_xmodem(img[:end])
        if got != want:
            r.fail('I5 trailer CRC-16 %#06x at %#x, image[0:%#x] gives %#06x (stale trailer)'
                   % (want, TRAILER_CRC, end, got))
        tail = img[end:TRAILER_CRC]
        if tail.count(0xFF) != len(tail):
            first = end + next(i for i, b in enumerate(tail) if b != 0xFF)
            r.fail('I5 non-erased bytes at %#x, past end %#x: outside the CRC' % (first, end))
        last = max((o + n for _, n, o, _ in copies), default=0)
        if copies and last != end:
            r.warn('I5 trailer end %#x != last copied byte %#x (stock keeps them '
                   'equal; a bootloader that CRCs the copied range would get another sum)'
                   % (end, last))
        r.note('trailer CRC %#06x over [0:%#x]' % (want, end))

    check_archives(img, r, art_ref, font_ref)


def check_archives(img, r, art_ref, font_ref):
    """I6."""
    if len(img) < FONT_OFF + 4:
        r.fail('I6 image too short for the font archive')
        return
    for name, off, limit, ram, window, ref in (
            ('artwork', ART_OFF, FONT_OFF, ART_RAM, FONT_RAM - ART_RAM, art_ref),
            ('font', FONT_OFF, IMAGE_LEN, FONT_RAM, CODE_RAM - FONT_RAM, font_ref)):
        clen = be32(img, off)
        if not 0 < clen <= limit - off - 4:
            r.fail('I6 %s archive length %#x at %#x out of bounds (must end by %#x)'
                   % (name, clen, off, limit))
            continue
        stream = img[off + 4:off + 4 + clen]
        h = hashlib.sha256(stream).hexdigest()
        if ref and ref[0] == h:
            out_len, out_head = ref[1], ref[2]
            r.note('%s archive identical to stock' % name)
        else:
            out = lzss_decode.unpack(stream, 0, limit=window + 1)
            out_len, out_head = len(out), out[:ART_RECS * ART_REC]
            r.note('%s archive differs from stock, decodes to %#x bytes' % (name, out_len))
        if out_len > window:
            r.fail('I6 %s archive decodes past its window %#010x+%#x (into %s)'
                   % (name, ram, window, 'the font window' if name == 'artwork'
                      else 'the code at 0x0E500000'))
        if name == 'artwork':
            check_art_dir(out_head, out_len, r)
        if name == 'artwork' and any(img[off + 4 + clen:limit]):
            r.warn('I6 bytes between the artwork stream end %#x and the font archive are '
                   'not zero (stock: zero)' % (off + 4 + clen))


def check_art_dir(d, total, r):
    if len(d) < ART_RECS * ART_REC:
        r.fail('I6 artwork archive too short for its %d-record directory' % ART_RECS)
        return
    for i in range(ART_RECS):
        s = i * ART_REC
        w, h = struct.unpack_from('>HH', d, s + 4)
        if (d[s + 24] != 2 or be32(d, s + 28) != s or be32(d, s + 36) != total
                or be32(d, s + 32) + w * h * 2 > total):
            r.fail('I6 artwork record %d malformed (or decoded size %#x != declared %#x)'
                   % (i, total, be32(d, s + 36)))
            return


def stock_refs():
    """sha256/decoded size/directory of the stock archives, to skip decoding
    them again for every image that kept them."""
    p = os.path.join(HERE, '..', '..', 'extract', 'gui_unpacked.bin')
    if not os.path.exists(p):
        return None, None
    img = open(p, 'rb').read()
    refs = []
    for off, limit in ((ART_OFF, FONT_OFF), (FONT_OFF, IMAGE_LEN)):
        clen = be32(img, off)
        stream = img[off + 4:off + 4 + clen]
        out = lzss_decode.unpack(stream, 0)
        refs.append((hashlib.sha256(stream).hexdigest(), len(out), out[:ART_RECS * ART_REC]))
    return refs[0], refs[1]


def check_bytes(data, refs=(None, None)):
    """(report, kind) for a .UPD, a GUI section or a decoded image."""
    r = Report()
    if data[:1].isdigit():
        kind = 'upd'
        sec = upd_gui_section(data)
        if sec is None:
            r.fail('not a .UPD manifest')
            return r, kind
        img = check_section(sec, r)
    elif data.startswith(b'CDJ-2000NXS2'):
        kind = 'section'
        img = check_section(data, r)
    else:
        kind = 'image'
        img = data
    if img is not None:
        check_image(img, r, *refs)
    return r, kind


def main():
    args = sys.argv[1:]
    strict = '--strict' in args
    quiet = '--quiet' in args
    files = [a for a in args if not a.startswith('--')]
    if not files:
        sys.exit(__doc__)
    refs = stock_refs()
    bad = 0
    for path in files:
        with open(path, 'rb') as f:
            data = f.read()
        r, kind = check_bytes(data, refs)
        ok = not r.fails and not (strict and r.warns)
        bad += not ok
        print('%s  %s (%s)' % ('PASS' if ok else 'FAIL', path, kind))
        for m in r.fails:
            print('   FAIL  ' + m)
        for m in r.warns:
            print('   WARN  ' + m)
        if not quiet:
            for m in r.notes:
                print('   note  ' + m)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
