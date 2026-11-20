#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""ownks: our own KEY SHIFT engine (no third-party code), behind the keyshift front end's interface.

Selected with the `ownks` mod name next to `keyshift` (EXTRA_MODS=ownks); keyshift.apply()
then calls apply_engine(). What it writes:

  - DSP: the stock boot table (16 sections, sha256-checked) with
      * one new section at DSP 0x805C0000 (mods/ownks/dsp/ks3.c, KS3 v4.1: ks_ctl + ks_fill/ks_process,
        about 8.5 KB; its 70 KB state (rings, search buffers) is NOLOAD and set up in chunks over
        the first ~18 blocks, the audio passing through meanwhile). CDJ_KSAB=1 (DEV A/B test
        builds only) adds the previous engine (dsp/ownks.c -DKS_AB_OLD, ~4 KB + 32 KB state) and
        the UTILITY kill switch KS3 ENGINE (modsmenu kill_v+24): OFF = MAIN sends the factor with the
        sign bit set = the old engine. 0x80570000-0x80600000 is DDR the stock program never touches: above the heap
        (0x80100000 + 0x46FFF8, set in the program's init records) and below the buffers at
        0x80600000.
      * the L2 trampoline at 0x0080DD50 (MVK/MVKH B31 + B B31), through which the McBSP0
        transmit ISR (L2 0x00809CE0) calls the deck's audio pipeline 0x800044A4 for every
        64-frame half buffer, retargeted to ks_fill: it calls 0x800044A4 and then pitch-shifts
        the finished block in place.
    The table grows by that section, so it moves to 0x08130000 (the `ks` layout's DSP table
    slot, 598,728 B) and the old place 0x080034E0-0x08091238 is erased (the ks layout puts our
    routines there). The SH-4 loader (0x08326690..) gets the new pointer, length and window
    constants: it streams the table in 16 KB windows (count at 0x08326692 `mov #n,r14`,
    remainder at 0x0832669C/0x083266A4 `mov #hi,r6; shll8 r6; add #lo,r6`), then a checksum
    window it computes itself.
  - MAIN: oks_dj (main_ownks.s) at 0x08122000 and its state block 0x08122800 (+0 on, +4
    semitones, +16 generation: the interface mods/keyshift and modsmenu drive), which sends the
    factor 2^(k/12) to ks_ctl.ratio with the stock "write words" DSP request.
"""
import hashlib
import os
import struct
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MBASE = 0x08000000
TABLE_OLD = (0x080034E0, 0x08091238)        # stock boot table (+ its 4-byte tail) -> erased
TABLE_SHA = '58c30f66cdabb2ca8262a0061aada311e51304a05ff46084bdfcbc210d9789b9'  # 0x080034E0-0x08091234
TABLE_NEW = 0x08130000
TABLE_CAP = 0x081C22C8                      # the ks layout's slot end
WINDOW = 0x4000
LOADER = dict(ptr=0x0832691C, length=0x08326920, nwin=0x08326692, hi=0x0832669C, lo=0x083266A4)
DSP_BASE = 0x805C0000                       # our DSP section
DSP_TRAMP = 0x0080DD50                      # L2: MVK .S2 lo,B31 / MVKH .S2 hi,B31 / B .S2 B31
DSP_STOCK_FILL = 0x800044A4
MAIN_AT, MAIN_ST = 0x08122000, 0x08122800
TOOLS = os.environ.get('CDJ_TIC6X', 'work/ownks/tc/inst/bin')
DSP_BIN = os.path.join(HERE, 'dsp', 'ownks_dsp.bin')        # prebuilt (committed) image: ks3
DSP_BIN_AB = os.path.join(HERE, 'dsp', 'ownks_ab_dsp.bin')  # KS3 A/B: ks3 + the old engine (CDJ_KSAB=1, DEV)
DSP_LIMIT = 0x80600000                      # the stock buffers start here: our image + NOLOAD state stay below
DSP_IMG_CAP = 0x4000                        # the boot-table section (and ks_fill) stay in the first 16 KB
KILL_KSAB = 0x080141E0 + 24                 # modsmenu kill_v+24 (ks layout KILLB + 24): KS3 ENGINE, 1 = ks3
KS_VER = 0x4B533301                         # ks_ctl +44: 'KS3' + 1 (ks3) / 2 (ks3 + old, A/B)


def ab():
    """KS3 A/B test build (DEV only): CDJ_KSAB=1."""
    return os.environ.get('CDJ_KSAB') == '1'
WHAT = 'KEY SHIFT engine: ours (DSP output pitch shifter at 0x805C0000, MAIN sender 0x08122000)'


def build_dsp(force=False, with_ab=None):
    """(image bytes, {symbol: address}) of mods/ownks/dsp (KS3: ks3.c; A/B: + ownks.c -DKS_AB_OLD,
    ks_tab.c), built with tic6x-elf-gcc when the toolchain is there (else the committed
    ownks_dsp.bin / ownks_ab_dsp.bin + .sym)."""
    with_ab = ab() if with_ab is None else with_ab
    gcc = os.path.join(TOOLS, 'tic6x-elf-gcc')
    bin_path = DSP_BIN_AB if with_ab else DSP_BIN
    sym_path = bin_path[:-4] + '.sym'
    if os.path.exists(gcc):
        d = os.path.join(HERE, 'dsp')
        with tempfile.TemporaryDirectory() as tmp:
            cf = ['-O2', '-march=c674x', '-mlittle-endian', '-msdata=none', '-ffreestanding',
                  '-fno-builtin', '-Wall', '-DKS_STOCK_FILL=%#x' % DSP_STOCK_FILL]
            srcs = [('ks3.c', ['-DKS_AB'] if with_ab else [])]
            if with_ab:
                srcs += [('ownks.c', ['-DKS_AB_OLD']), ('ks_tab.c', [])]
            objs = []
            for src, extra in srcs:
                o = os.path.join(tmp, src[:-2] + '.o')
                subprocess.run([gcc] + cf + extra + ['-c', os.path.join(d, src), '-o', o], check=True)
                objs.append(o)
            elf = os.path.join(tmp, 'ownks.elf')
            subprocess.run([os.path.join(TOOLS, 'tic6x-elf-ld'), '--no-warn-rwx-segments', '-T',
                            os.path.join(d, 'ownks.ld'), '-o', elf] + objs, check=True)
            img = os.path.join(tmp, 'ownks.bin')
            subprocess.run([os.path.join(TOOLS, 'tic6x-elf-objcopy'), '-O', 'binary', '-j', '.ksimg',
                            elf, img], check=True)
            syms = {}
            for line in subprocess.run([os.path.join(TOOLS, 'tic6x-elf-nm'), elf], check=True,
                                       capture_output=True, text=True).stdout.splitlines():
                f = line.split()
                if len(f) == 3:
                    syms[f[2]] = int(f[0], 16)
            data = open(img, 'rb').read()
        with open(bin_path, 'wb') as f:
            f.write(data)
        with open(sym_path, 'w') as f:
            for k in sorted(syms):
                f.write('%08x %s\n' % (syms[k], k))
        return data, syms
    syms = {}
    for line in open(sym_path):
        a, n = line.split()
        syms[n] = int(a, 16)
    return open(bin_path, 'rb').read(), syms


def build_main(ratio_addr, with_ab=None):
    """oks_dj linked at MAIN_AT (KS3 A/B: --defsym KSAB, the KS3 ENGINE word -> the factor's sign)."""
    with_ab = ab() if with_ab is None else with_ab
    src = os.path.join(HERE, 'main_ownks.s')
    with tempfile.TemporaryDirectory() as tmp:
        obj, elf, out = (os.path.join(tmp, n) for n in ('o.o', 'o.elf', 'o.bin'))
        extra = ['--defsym', 'KSAB=1', '--defsym', 'OK_KILL_AB=%#x' % KILL_KSAB] if with_ab else []
        subprocess.run(['sh4-linux-gnu-as', '--isa=sh4', '-little', '--defsym',
                        'OK_DSP_RATIO=%#x' % ratio_addr] + extra + ['-o', obj, src], check=True)
        subprocess.run(['sh4-linux-gnu-ld', '-Ttext=%#x' % MAIN_AT, '-e', 'oks_dj', '-o', elf, obj], check=True)
        subprocess.run(['sh4-linux-gnu-objcopy', '-O', 'binary', '-j', '.text', elf, out], check=True)
        return open(out, 'rb').read()


def parse_table(t):
    """[(addr, data)] and entry of a little-endian C6x boot table."""
    entry = struct.unpack_from('<I', t, 0)[0]
    p, secs = 4, []
    while True:
        size = struct.unpack_from('<I', t, p)[0]
        if size == 0:
            break
        addr = struct.unpack_from('<I', t, p + 4)[0]
        secs.append([addr, bytearray(t[p + 8:p + 8 + size])])
        p += 8 + ((size + 3) & ~3)
    return entry, secs


def pack_table(entry, secs):
    out = bytearray(struct.pack('<I', entry))
    for addr, data in secs:
        out += struct.pack('<II', len(data), addr) + data + b'\0' * ((-len(data)) & 3)
    out += struct.pack('<I', 0)
    return bytes(out)


def set_mvk(word, half):
    return (word & ~(0xFFFF << 7)) | ((half & 0xFFFF) << 7)


def dsp_table(stock_main, dsp_img, fill_addr):
    old = stock_main[TABLE_OLD[0] - MBASE:0x08091234 - MBASE]
    if hashlib.sha256(old).hexdigest() != TABLE_SHA:
        raise SystemExit('ownks: the DSP boot table is not stock 1.87')
    entry, secs = parse_table(old)
    if pack_table(entry, secs) != old:
        raise SystemExit('ownks: boot table round trip differs')
    # the trampoline: MVK .S2 0x44A4,B31 ; MVKH .S2 0x8000,B31 -> our ks_fill
    for addr, data in secs:
        if addr <= DSP_TRAMP and DSP_TRAMP + 8 <= addr + len(data):
            o = DSP_TRAMP - addr
            w0, w1 = struct.unpack_from('<II', data, o)
            if (w0 >> 7) & 0xFFFF != DSP_STOCK_FILL & 0xFFFF or (w1 >> 7) & 0xFFFF != DSP_STOCK_FILL >> 16:
                raise SystemExit('ownks: DSP trampoline %#x is not the stock one' % DSP_TRAMP)
            struct.pack_into('<II', data, o, set_mvk(w0, fill_addr & 0xFFFF), set_mvk(w1, fill_addr >> 16))
            break
    else:
        raise SystemExit('ownks: no section holds the trampoline')
    for addr, data in secs:
        if addr < DSP_BASE + len(dsp_img) and DSP_BASE < addr + len(data):
            raise SystemExit('ownks: %#x overlaps stock section %#x' % (DSP_BASE, addr))
    secs.append([DSP_BASE, bytearray(dsp_img)])
    return pack_table(entry, secs)


def loader_patch(out, length):
    o = lambda a: a - MBASE
    u16 = lambda a: struct.unpack_from('<H', out, o(a))[0]
    want = {LOADER['nwin']: 0xEE23, LOADER['hi']: 0xE61D, LOADER['lo']: 0x7654}
    for a, w in want.items():
        if u16(a) != w:
            raise SystemExit('ownks: loader %#x holds %#06x, not stock %#06x' % (a, u16(a), w))
    if struct.unpack_from('<II', out, o(LOADER['ptr'])) != (0xA80034E0, 0x8DD54):
        raise SystemExit('ownks: loader literals are not stock')
    nwin, rem = divmod(length, WINDOW)
    hi, lo = (rem + 0x80) >> 8, rem - (((rem + 0x80) >> 8) << 8)    # add #lo is signed 8-bit
    assert -128 <= lo <= 127 and 0 <= hi <= 127 and (hi << 8) + lo == rem and nwin <= 127
    struct.pack_into('<H', out, o(LOADER['nwin']), 0xEE00 | nwin)      # mov #nwin,r14
    struct.pack_into('<H', out, o(LOADER['hi']), 0xE600 | hi)          # mov #hi,r6
    struct.pack_into('<H', out, o(LOADER['lo']), 0x7600 | (lo & 0xFF)) # add #lo,r6
    struct.pack_into('<II', out, o(LOADER['ptr']), 0xA0000000 | TABLE_NEW, length)
    return nwin, rem


def apply_engine(out, stock_main):
    """Write our engine into `out` (bytearray, a stock MAIN image so far)."""
    o = lambda a: a - MBASE
    if ab() and os.environ.get('CDJ_PROFILE', 'dev') == 'release':
        raise SystemExit('ownks: CDJ_KSAB=1 (the KS3 A/B test switch) is DEV only')
    dsp_img, syms = build_dsp()
    fill, ratio = syms['ks_fill'], syms['ks_ctl'] + 8
    # KS3: the image + its NOLOAD state stay in the free DDR below the stock buffers; ks_fill in the first 16 KB
    end = syms.get('_ks_end')
    if end is None or end > DSP_LIMIT or len(dsp_img) > DSP_IMG_CAP or not DSP_BASE <= fill < DSP_BASE + len(dsp_img):
        raise SystemExit('ownks: DSP image %d B / state end %s / ks_fill %#x out of bounds (limit %#x)'
                         % (len(dsp_img), end and hex(end), fill, DSP_LIMIT))
    if struct.unpack_from('<I', dsp_img, 44)[0] != KS_VER + ab():
        raise SystemExit('ownks: the DSP image is not ks3%s' % (' A/B' if ab() else ''))
    table = dsp_table(bytes(stock_main), dsp_img, fill)
    if TABLE_NEW + len(table) > TABLE_CAP:
        raise SystemExit('ownks: the table (%d B) passes %#x' % (len(table), TABLE_CAP))
    if any(b != 0xFF for b in out[o(TABLE_NEW):o(TABLE_NEW) + len(table)]):
        raise SystemExit('ownks: %#x is not free' % TABLE_NEW)
    out[o(TABLE_NEW):o(TABLE_NEW) + len(table)] = table
    out[o(TABLE_OLD[0]):o(TABLE_OLD[1])] = b'\xff' * (TABLE_OLD[1] - TABLE_OLD[0])
    nwin, rem = loader_patch(out, len(table))
    blob = build_main(ratio)
    for a, n in ((MAIN_AT, len(blob)), (MAIN_ST, 44)):
        if any(b != 0xFF for b in out[o(a):o(a) + n]):
            raise SystemExit('ownks: %#x is not free' % a)
    out[o(MAIN_AT):o(MAIN_AT) + len(blob)] = blob
    out[o(MAIN_ST):o(MAIN_ST) + 44] = b"\0" * 44  # CENTPOP: +40 KEY SYNC cents
    print('patch_main: ownks: our KEY SHIFT engine (ks3%s): DSP section %#x (%d B, ks_fill %#x, ratio %#x, '
          'state to %#x of %#x), trampoline %#x -> ks_fill; boot table %d B at %#x (%d windows + %d, slot to %#x); '
          'oks_dj %d B at %#x'
          % (' + old engine A/B, KS3 ENGINE switch' if ab() else '', DSP_BASE, len(dsp_img), fill, ratio, end,
             DSP_LIMIT, DSP_TRAMP, len(table), TABLE_NEW, nwin, rem, TABLE_CAP, len(blob), MAIN_AT))
    return out


def check(img):
    """[(ok, what)] for verify_update."""
    u32 = lambda a: struct.unpack_from('<I', img, a - MBASE)[0]
    length = u32(LOADER['length'])
    t = img[TABLE_NEW - MBASE:TABLE_NEW - MBASE + length]
    ok_t, fill, img_ks = False, None, b''
    try:
        entry, secs = parse_table(t)
        ok_t = len(secs) == 17 and secs[-1][0] == DSP_BASE and secs[-1][1][:4] == b'OWKS'
        img_ks = bytes(secs[-1][1]) if ok_t else b''
        for addr, data in secs:
            if addr <= DSP_TRAMP < addr + len(data):
                w0, w1 = struct.unpack_from('<II', data, DSP_TRAMP - addr)
                fill = ((w1 >> 7) & 0xFFFF) << 16 | ((w0 >> 7) & 0xFFFF)
    except struct.error:
        pass
    return [(u32(LOADER['ptr']) == 0xA0000000 | TABLE_NEW, 'ownks: DSP loader reads the table at %#x' % TABLE_NEW),
            (ok_t, 'ownks: boot table = 16 stock sections + ours at %#x' % DSP_BASE),
            (fill is not None and DSP_BASE <= fill < DSP_BASE + min(len(img_ks), DSP_IMG_CAP),
             'ownks: L2 trampoline %#x -> ks_fill (inside our section)' % DSP_TRAMP),
            (len(img_ks) >= 48 and struct.unpack_from('<I', img_ks, 44)[0] == KS_VER + ab()
             and len(img_ks) <= DSP_IMG_CAP and struct.unpack_from('<I', img_ks, 4)[0] == 0
             and struct.unpack_from('<I', img_ks, 36)[0] == 0,
             'ownks: DSP engine = ks3%s (ks_ctl +44 version, +4 init / +36 chunked-init counter 0 at load, '
             'section <= %d B)' % (' + old A/B' if ab() else '', DSP_IMG_CAP)),
            (TABLE_NEW + length <= TABLE_CAP, 'ownks: boot table (%d B) inside its slot %#x-%#x' % (length, TABLE_NEW, TABLE_CAP)),
            (img[MAIN_AT - MBASE:MAIN_AT - MBASE + 2] == b'\x86\x2f', 'ownks: oks_dj at %#x' % MAIN_AT)]
