#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""lang8: the deck's UI trimmed to 8 languages (EN FR DE IT NL ES PT JA).

Selected in patch_update.py as the pseudo-mod `lang8` (= lang8gui on the GUI
image + lang8main on the MAIN image). Analysis: re/STDC_LANG.md; build notes:
re/STDC_BUILD.md. The point is room in the GUI section: the strings of the
10 dropped languages compress away (about -46 KB packed).

GUI (SH-2A, big-endian; file offsets):
  - the UTF-16 strings of tables 6 (RU) and 9..17 (KO ZHS ZHT SV CS HU DA EL
    TR) and their 356-pointer arrays are zeroed;
  - their entries in the master table (0x9F4C4) point at the English array
    (0x0E598FA4), so any old value still shows English;
  - the two copies of the MAIN-value -> language-name switch (0x1C00376C and
    the inline one at 0x1C004554) send the dropped values to the English
    case, so the font class follows too.
MAIN (SH-4, little-endian; addresses):
  - UTILITY > LANGUAGE: options 6/7 = JA/PT, count 18 -> 8 (in whatever item
    table the image uses: stock .data or modsmenu's copy);
  - its setter/getter literals (0x084EF324/0x084F0108/0x084F0664 and
    0x084EF328) go to l_set/l_get (option position <-> MAIN value);
  - the global setter 0x083FC33C jumps to setw (value not kept -> 1), and
    the settings unpacker's language field 0x0846D822 to booth (same clamp
    at boot), both in mods/lang8/main_lang8.s, placed at the layout's
    LAYOUTS[..]['lang8'] address (patch_main.py).
Every byte is checked against its stock value before it is written.
"""
import hashlib
import os
import struct
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- GUI ---
# string blocks (t = GUI table index; rec17 rodata) and pointer arrays (rec18)
GUI_STR = [0x337CC, 0x36C50, 0x3B1D4, 0x40294, 0x451FC, 0x4A100, 0x4F0B2, 0x53F9A, 0x58F6E,
           0x5DE9A, 0x623D0, 0x66156, 0x69EBE, 0x6EC14, 0x73BD2, 0x78ADA, 0x7D830, 0x828CE,
           0x875A0]
GUI_ARR, GUI_ARR_RAM, GUI_ARR_LEN = 0x990A4, 0x0E598FA4, 0x590
GUI_MASTER = 0x9F4C4
GUI_KEEP_T = (0, 1, 2, 3, 4, 5, 7, 8)          # EN JA DE IT NL ES FR PT
GUI_DROP_T = tuple(t for t in range(18) if t not in GUI_KEEP_T)
# the zeroed ranges, merged: strings t6, t9..17; arrays t6, t9..17
GUI_ZERO = [(GUI_STR[6], GUI_STR[7]), (GUI_STR[9], GUI_STR[18]),
            (GUI_ARR + 6 * GUI_ARR_LEN, GUI_ARR + 7 * GUI_ARR_LEN),
            (GUI_ARR + 9 * GUI_ARR_LEN, GUI_ARR + 18 * GUI_ARR_LEN)]
GUI_ZERO_SHA256 = '5d8f1aaed87031d6d953810898200ca79a5c4517c8a8ff00b217291578309d4a'

# Profiles: `lang8` (above, EN FR DE IT NL ES PT JA) and `lang2` (EN ES only,
# V3c: the user's rule "Spanish + English" when the GUI needs room). keep_t =
# GUI tables kept, keep1 = MAIN values kept in option order.
PROFILES = {
    'lang8': dict(keep_t=GUI_KEEP_T, keep1=(1, 2, 3, 4, 5, 6, 11, 12)),
    'lang2': dict(keep_t=(0, 5), keep1=(1, 6)),
    # 2.3 (owner 2026-11-22): the Latin-1 languages back -- EN FR DE IT NL ES PT in the stock option order. Our
    # atlas (v2ui fontgen: ASCII + Latin-1) and font3000's Latin bank cover them; JA / RU / KO / ZH would not.
    'lang7': dict(keep_t=(0, 2, 3, 4, 5, 7, 8), keep1=(1, 2, 3, 4, 5, 6, 12)),
}
# sha256 over the stock bytes of each profile's zeroed ranges (stock 1.81 GUI)
ZERO_SHA = {'lang8': GUI_ZERO_SHA256,
            'lang2': 'a176e90f8e7c359621d575fd8a42f6f36f07e3afec107b8fce6088d075ef7073',
            'lang7': 'aea03e5cdd1c15af0e13c2d7ce85df209e5ffeea04fe87571ccc7e4f94c096ad'}


def _merge(rngs):
    out = []
    for a, b in sorted(rngs):
        if out and out[-1][1] == a:
            out[-1] = (out[-1][0], b)
        else:
            out.append((a, b))
    return out


def drop_t(prof='lang8'):
    return tuple(t for t in range(18) if t not in PROFILES[prof]['keep_t'])


def gui_zero(prof='lang8'):
    if prof == 'lang8':
        return list(GUI_ZERO)
    d = drop_t(prof)
    return _merge([(GUI_STR[t], GUI_STR[t + 1]) for t in d]) + \
        _merge([(GUI_ARR + t * GUI_ARR_LEN, GUI_ARR + (t + 1) * GUI_ARR_LEN) for t in d])


# MAIN value v (1..18) -> GUI table; v - 1 indexes both switch tables
V_TO_T = (0, 7, 2, 3, 4, 5, 6, 9, 10, 11, 1, 8, 12, 13, 14, 15, 16, 17)
# the switch tables (halfword offsets from the braf base), file offsets
GUI_SWITCH = [
    # (file offset, stock entries, English case)
    (0xBAB9C, (0x36, 0x3E, 0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6A, 0x72, 0x78, 0x80, 0x88,
               0x90, 0x98, 0x9E, 0xA6, 0xAE, 0xB6), 0x36),           # 0x1C00376C
    (0xBB984, (0xDE, 0xD8, 0xD0, 0xC8, 0xC0, 0xB8, 0xB2, 0xAA, 0xA4, 0x9C, 0x94, 0x8C,
               0x84, 0x7E, 0x76, 0x6E, 0x66, 0x60), 0xDE),           # 0x1C004554 (inline copy)
]
DROP_V = tuple(v for v in range(1, 19) if V_TO_T[v - 1] in GUI_DROP_T)   # 7 8 9 10 13..18


def drop_v(prof='lang8'):
    d = drop_t(prof)
    return tuple(v for v in range(1, 19) if V_TO_T[v - 1] in d)


def gui_writes(prof='lang8'):
    """Every GUI byte range lang8 writes."""
    out = gui_zero(prof) + [(GUI_MASTER + 4 * t, GUI_MASTER + 4 * t + 4) for t in drop_t(prof)]
    out += [(off + 2 * (v - 1), off + 2 * v) for off, _, _ in GUI_SWITCH for v in drop_v(prof)]
    return out


def gui(data, prof='lang8'):
    img = bytearray(data)
    zero, dropt, dropv = gui_zero(prof), drop_t(prof), drop_v(prof)
    if hashlib.sha256(b''.join(img[a:b] for a, b in zero)).hexdigest() != ZERO_SHA[prof]:
        raise SystemExit('lang8: the GUI language tables are not the stock 1.81 ones')
    u32 = lambda o: struct.unpack_from('>I', img, o)[0]
    for t in range(18):
        if u32(GUI_MASTER + 4 * t) != GUI_ARR_RAM + t * GUI_ARR_LEN:
            raise SystemExit('lang8: GUI master table entry %d is %#x' % (t, u32(GUI_MASTER + 4 * t)))
    for off, stock, _ in GUI_SWITCH:
        got = struct.unpack_from('>18H', img, off)
        if got != stock:
            raise SystemExit('lang8: GUI switch table at %#x is not stock' % off)
    for a, b in zero:
        img[a:b] = bytes(b - a)
    for t in dropt:
        struct.pack_into('>I', img, GUI_MASTER + 4 * t, GUI_ARR_RAM)
    for off, _, en in GUI_SWITCH:
        for v in dropv:
            struct.pack_into('>H', img, off + 2 * (v - 1), en)
    print('patch_update: %s GUI: %d languages dropped (%d bytes zeroed), master and '
          'switch tables -> English' % (prof, len(dropt), sum(b - a for a, b in zero)))
    return bytes(img)


def check_gui(img, prof='lang8'):
    """[(ok, what)] for verify_update."""
    u32 = lambda o: struct.unpack_from('>I', img, o)[0]
    zero, dropt, dropv = gui_zero(prof), drop_t(prof), drop_v(prof)
    return [
        (all(not any(img[a:b]) for a, b in zero),
         '%s GUI: dropped strings and pointer arrays zeroed (%d ranges)' % (prof, len(zero))),
        (all(u32(GUI_MASTER + 4 * t) == (GUI_ARR_RAM if t in dropt
                                          else GUI_ARR_RAM + t * GUI_ARR_LEN) for t in range(18)),
         '%s GUI: master table: dropped -> English array, kept untouched' % prof),
        (all(struct.unpack_from('>18H', img, off) == tuple(en if v in dropv else stock[v - 1]
                                                          for v in range(1, 19))
             for off, stock, en in GUI_SWITCH),
         '%s GUI: both value->language switch tables send dropped values to English' % prof),
    ]


# --------------------------------------------------------------- MAIN ---
MBASE = 0x08000000
KEEP1 = (1, 2, 3, 4, 5, 6, 11, 12)                # MAIN values kept, in option order
L_SET_LITS = (0x084EF324, 0x084F0108, 0x084F0664)
L_GET_LIT = 0x084EF328
SETTER, GETTER = 0x083FC33C, 0x083FC34A
# the stock setter: mov.l @(disp),r2 (0x0A35DF30); mov #24,r0; shll8 r0;
# add #-112,r0; extu.b r4,r4; rts; mov.l r4,@(r0,r2)
SETTER_STOCK = (0xD23F, 0xE018, 0x4018, 0x7090, 0x644C, 0x000B, 0x0246)
SETTER_LIT, SETTER_LIT_VAL = 0x083FC43C, 0x0A35DF30
# the settings unpacker's language field: mov.w @(2,r14),r0; extu.w r0,r0;
# shld r6,r0; and #31,r0; mov.l r0,@(4,r3)
BOOT, BOOT_STOCK = 0x0846D822, (0x85E1, 0x600D, 0x406D, 0xC91F, 0x1301)
# the LANGUAGE item: its label, options array (RAM .data / ROM image) and slots
LANG_LABEL = 0xA80FDB44
LANG_OPTS_RAM, LANG_OPTS_IMG = 0x10DE141C, 0x08570898
LANG_SLOTS = {7: 0x084EF0FC, 11: 0x084EFFDC, 14: 0x084F05A8}   # formatter, commit, cancel
LANG_OPTS_STOCK = (0xA80FDE10, 0xA80FDE20, 0xA80FDE32, 0xA80FDE42, 0xA80FDE54, 0xA80FDE6A,
                   0xA80FDE7A, 0xA80FDE8A, 0xA80FDE92, 0xA80FDEA0, 0xA80FDEAE, 0xA80FDEB6,
                   0xA80FDECA, 0xA80FDEDA, 0xA80FDEEA, 0xA80FDEF8, 0xA80FDF04, 0xA80FDF16)
BLOCK_MAX = 0x100	# V3rc3: 0x0813FF00.. (the modsmenu block + table grew to ~0x0813FE00; lang2 = 172 B, lang8 no longer fits the stock layout)


def tables_src(prof='lang8'):
    """The three byte tables of main_lang8.s for a profile (keep1 padded to 8)."""
    keep1 = PROFILES[prof]['keep1']
    k8 = list(keep1) + [1] * (8 - len(keep1))
    clampt = [v if v in keep1 else 1 for v in range(32)]
    clampt[0] = 1
    posof = [keep1.index(v) + 1 if v in keep1 else 1 for v in range(32)]
    row = lambda xs: '\t.byte\t' + ', '.join(str(x) for x in xs)
    return ('keep1:' + row(k8) + '\n'
            '! clampt[v] = v if v is kept else 1, v = 0..31\n'
            'clampt:' + row(clampt[:16]) + '\n' + row(clampt[16:]) + '\n'
            '! posof[v] = option position + 1 of value v, 1 if v is not kept\n'
            'posof:' + row(posof[:16]) + '\n' + row(posof[16:]) + '\n')


def build_block(base, prof='lang8'):
    """(bytes, {symbol: address}) of mods/lang8/main_lang8.s linked at base."""
    src = os.path.join(HERE, 'lang8', 'main_lang8.s')
    text = open(src).read()
    text = text[:text.index('keep1:')] + tables_src(prof)
    with tempfile.TemporaryDirectory() as tmp:
        obj, elf, out = (os.path.join(tmp, n) for n in ('l.o', 'l.elf', 'l.bin'))
        s2 = os.path.join(tmp, 'l.s')
        with open(s2, 'w') as f:
            f.write(text)
        subprocess.run(['sh4-linux-gnu-as', '--isa=sh4', '-little', '-o', obj, s2], check=True)
        subprocess.run(['sh4-linux-gnu-ld', '-Ttext=%#x' % base, '-e', 'l_set', '-o', elf, obj],
                       check=True)
        subprocess.run(['sh4-linux-gnu-objcopy', '-O', 'binary', '-j', '.text', elf, out], check=True)
        syms = {}
        for line in subprocess.run(['sh4-linux-gnu-nm', elf], check=True, capture_output=True,
                                   text=True).stdout.splitlines():
            f = line.split()
            if len(f) == 3:
                syms[f[2]] = int(f[0], 16)
        with open(out, 'rb') as f:
            return f.read(), syms


def jump_stub(at, target):
    """mov.l @(disp,PC),r0; jmp @r0; nop [; nop]; .long target -- `at` 2 mod 4
    gives 8 bytes (the literal right after), 0 mod 4 gives 10 (one pad nop)."""
    lit = (at & ~3) + 8
    disp = (lit - ((at & ~3) + 4)) // 4
    code = struct.pack('<HHH', 0xD000 | disp, 0x402B, 0x0009)
    code += b'\x09\x00' * ((lit - at - len(code)) // 2)
    return code + struct.pack('<I', target)


def item_table(img):
    """(image address of the UTILITY item table, item count) as the image uses it."""
    import patch_main
    u32 = lambda a: struct.unpack_from('<I', img, a - MBASE)[0]
    table = u32(patch_main.UT_TABLE_LITS[0])
    src = patch_main.UT_STOCK_TABLE_IMG if table == patch_main.UT_STOCK_TABLE_RAM else table
    return src, img[patch_main.UT_COUNT_IMG - MBASE]


def lang_entry(img):
    import patch_main
    src, count = item_table(img)
    hits = [src + k * patch_main.UT_ENTRY for k in range(count)
            if struct.unpack_from('<I', img, src + k * patch_main.UT_ENTRY - MBASE)[0] == LANG_LABEL]
    if len(hits) != 1:
        raise SystemExit('lang8: %d LANGUAGE items in the UTILITY table at %#x' % (len(hits), src))
    return hits[0]


def main(data, layout='stock', prof='lang8'):
    import patch_main
    img = bytearray(data)
    o = lambda a: a - MBASE
    u16 = lambda a: struct.unpack_from('<H', img, o(a))[0]
    u32 = lambda a: struct.unpack_from('<I', img, o(a))[0]
    base = patch_main.LAYOUTS[layout]['lang8']
    blob, syms = build_block(base, prof)
    keep1 = PROFILES[prof]['keep1']
    if len(blob) > BLOCK_MAX:
        raise SystemExit('lang8: block %d bytes > %d' % (len(blob), BLOCK_MAX))
    entry = lang_entry(img)
    # stock checks
    if tuple(u16(SETTER + 2 * k) for k in range(7)) != SETTER_STOCK or u32(SETTER_LIT) != SETTER_LIT_VAL:
        raise SystemExit('lang8: the language setter at %#x is not stock' % SETTER)
    if tuple(u16(BOOT + 2 * k) for k in range(5)) != BOOT_STOCK:
        raise SystemExit('lang8: the settings unpacker at %#x is not stock' % BOOT)
    for a in L_SET_LITS:
        if u32(a) != SETTER:
            raise SystemExit('lang8: literal %#x holds %#x, not the setter' % (a, u32(a)))
    if u32(L_GET_LIT) != GETTER:
        raise SystemExit('lang8: literal %#x holds %#x, not the getter' % (L_GET_LIT, u32(L_GET_LIT)))
    if u32(entry + 4) != LANG_OPTS_RAM or u32(entry + 8) != 18 or \
            any(u32(entry + 4 * k) != v for k, v in LANG_SLOTS.items()):
        raise SystemExit('lang8: the LANGUAGE item at %#x is not the stock one' % entry)
    if tuple(u32(LANG_OPTS_IMG + 4 * k) for k in range(18)) != LANG_OPTS_STOCK:
        raise SystemExit('lang8: the LANGUAGE options at %#x are not stock' % LANG_OPTS_IMG)
    if any(b != 0xFF for b in img[o(base):o(base) + BLOCK_MAX]):
        raise SystemExit('lang8: %#x-%#x is not free' % (base, base + BLOCK_MAX))
    # writes
    img[o(base):o(base) + len(blob)] = blob
    for k, v in enumerate(keep1):
        struct.pack_into('<I', img, o(LANG_OPTS_IMG + 4 * k), LANG_OPTS_STOCK[v - 1])
    struct.pack_into('<I', img, o(entry + 8), len(keep1))
    for a in L_SET_LITS:
        struct.pack_into('<I', img, o(a), syms['l_set'])
    struct.pack_into('<I', img, o(L_GET_LIT), syms['l_get'])
    stub = jump_stub(SETTER, syms['setw'])
    img[o(SETTER):o(SETTER) + 14] = stub + b'\x09\x00' * ((14 - len(stub)) // 2)
    stub = jump_stub(BOOT, syms['booth'])
    assert len(stub) == 10
    img[o(BOOT):o(BOOT) + 10] = stub
    print('patch_update: %s MAIN: LANGUAGE %d options (item %#x), l_set/l_get/setw/booth '
          'at %#x (%d bytes)' % (prof, len(keep1), entry, base, len(blob)))
    return bytes(img)


def check_main(img, layout='stock', prof='lang8'):
    """[(ok, what)] for verify_update."""
    import patch_main
    u32 = lambda a: struct.unpack_from('<I', img, a - MBASE)[0]
    base = patch_main.LAYOUTS[layout]['lang8']
    blob, syms = build_block(base, prof)
    keep1 = PROFILES[prof]['keep1']
    entry = lang_entry(img)
    return [
        (img[base - MBASE:base - MBASE + len(blob)] == blob,
         'lang8 MAIN: block (l_set/l_get/setw/booth) at %#x' % base),
        (u32(entry + 4) == LANG_OPTS_RAM and u32(entry + 8) == len(keep1),
         '%s MAIN: LANGUAGE item (%#x) has %d options' % (prof, entry, len(keep1))),
        (tuple(u32(LANG_OPTS_IMG + 4 * k) for k in range(len(keep1))) ==
         tuple(LANG_OPTS_STOCK[v - 1] for v in keep1),
         '%s MAIN: options = MAIN values %s' % (prof, keep1)),
        (all(u32(a) == syms['l_set'] for a in L_SET_LITS) and u32(L_GET_LIT) == syms['l_get'],
         'lang8 MAIN: setter/getter literals -> l_set/l_get'),
        (img[SETTER - MBASE:SETTER - MBASE + 12] == jump_stub(SETTER, syms['setw']) and
         img[BOOT - MBASE:BOOT - MBASE + 10] == jump_stub(BOOT, syms['booth']),
         'lang8 MAIN: setter %#x and boot unpacker %#x jump to the clamps' % (SETTER, BOOT)),
    ]
