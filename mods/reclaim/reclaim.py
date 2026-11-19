"""reclaim (opt-in, MAIN 1.87): drop the non-Latin text codepages of the stock MAIN to free packed flash.

re/MAIN_STOCK_RECLAIM.md #1, traced in work/reclaim/NOTES.md. In-place data only: no code of ours,
no hook, no task, nothing that runs in update mode (main-update-safety).

The ISO-8859 / "native codepage" text path (ID3 encoding 0, ID3v1, rekordbox strings of a remote
deck) is 0x082C0FE2 -> 0x082C0E54, a braf switch on (language - 1), language = this deck's own
(getter 0x083FC34A) or a remote player's (0x083FFE9E). Cases 1..6 (EN FR DE IT NL ES) already go to
the cp1252 converter 0x084F13DA (64-B table 0x08101AC0); 7..18 go to RU / KO / ZHS / ZHT / JA /
PT..DA / EL / TR converters 0x084F151C..0x084F29D0, which use the tables 0x08101B00..0x08118700
(cp1251/1250/1253/1254 8-bit tables, SJIS, GBK, KSC + Hanja, Big5). Nothing else reaches those
converters or tables (static xrefs over the whole image; the only other reader, 0x084F1106, has no
caller of any kind).

What it does:
  1. the 12 braf halfwords 0x082C0F08..0x082C0F1E -> 0x00F8 (every language -> the cp1252 case);
  2. belt and braces: the 8 case literals 0x082C11C4..0x082C11E0 -> 0x084F13DA too;
  3. tables 0x08101B00..0x08118700 -> 0xFF;
  4. converters 0x084F151C..0x084F29D0 -> `rts / mov #0,r0` pairs (any call into them returns 0
     characters, entered at either halfword), except the 4-byte literal slot 0x084F16A0
     (0xA8101AC0), which the KEPT cp1252 converter reads at 0x084F14E4.
Kept: the cp1252 table 0x08101AC0, the FAT short-name SJIS table 0x080B1B5C.., the UTF-16 swap
helper 0x084F1068 (ID3 decoder), the dead 0x084F1106 (untouched), everything from 0x084F29D0 on.

Every byte is checked against stock before it is written (SystemExit otherwise): a base or another
mod that uses these bytes refuses the build instead of being overwritten.
"""
import hashlib
import struct

WHAT = 'reclaim: non-Latin text codepages dropped (every language -> cp1252), ~96 KB packed MAIN freed'

B = 0x08000000
BRAF_LO, BRAF_HI = 0x082C0F08, 0x082C0F20          # switch entries for languages 7..18
BRAF_STOCK_SHA = 'a4d8367c5a30035034285fc8aaa7b326000da8ceee611984b8e0526a745aa51d'   # sha256 of the stock 24-byte braf table
BRAF_CP1252 = 0x00F8                                # entry of languages 1..6: -> 0x082C0FA0
CASE_LITS = 0x082C11C4                              # 8 literals of the case blocks 0x082C0F20..0x082C0F9F
CASE_STOCK = (0x084F1A78, 0x084F17A4, 0x084F1680, 0x084F1C2A, 0x084F2490, 0x084F1EB4, 0x084F2144, 0x084F151C)
CP1252 = 0x084F13DA                                 # cp1252 converter (its own case literal 0x082C11E4)
CP1252_LIT = 0x082C11E4
TABLES = (0x08101B00, 0x08118700,
          '00607f4c8f48b9355b1a14053e0435762273f29e932a9d5bc56d35f3fb2492d2')
CODE = (0x084F151C, 0x084F29D0,
        '8a14ff50ee9efa2926883f04a9e81e6bc4ec0067ed53105fd51a3a3eec39465a')
KEEP_SLOT, KEEP_VAL = 0x084F16A0, 0xA8101AC0        # read by the kept cp1252 converter at 0x084F14E4
RTS, MOV0 = 0x000B, 0xE000                          # rts / mov #0,r0 (SH-4, little endian halfwords)


def _o(a):
    return a - B


def _code_fill(lo, hi):
    out = bytearray()
    for a in range(lo, hi, 2):
        out += struct.pack('<H', RTS if a % 4 == 0 else MOV0)
    k = _o(KEEP_SLOT) - _o(lo)
    out[k:k + 4] = struct.pack('<I', KEEP_VAL)
    return bytes(out)


def _stock_ok(data):
    bad = []
    if hashlib.sha256(bytes(data[_o(BRAF_LO):_o(BRAF_HI)])).hexdigest() != BRAF_STOCK_SHA:
        bad.append('braf table %#x' % BRAF_LO)
    if struct.unpack_from('<8I', data, _o(CASE_LITS)) != CASE_STOCK or \
            struct.unpack_from('<I', data, _o(CP1252_LIT))[0] != CP1252:
        bad.append('case literals %#x' % CASE_LITS)
    for lo, hi, sha in (TABLES, CODE):
        if hashlib.sha256(bytes(data[_o(lo):_o(hi)])).hexdigest() != sha:
            bad.append('%#x-%#x' % (lo, hi))
    return bad


def apply(data):
    out = bytearray(data)
    bad = _stock_ok(out)
    if bad:
        raise SystemExit('reclaim: not stock (another mod or the base uses them): %s' % ', '.join(bad))
    for a in range(BRAF_LO, BRAF_HI, 2):
        struct.pack_into('<H', out, _o(a), BRAF_CP1252)
    struct.pack_into('<8I', out, _o(CASE_LITS), *([CP1252] * 8))
    lo, hi, _ = TABLES
    out[_o(lo):_o(hi)] = b'\xff' * (hi - lo)
    lo, hi, _ = CODE
    out[_o(lo):_o(hi)] = _code_fill(lo, hi)
    print('reclaim: languages 7..18 -> cp1252 (braf %#x, case literals %#x); %d B of tables (0xFF) and '
          '%d B of converters (rts / mov #0,r0) freed at %#x and %#x'
          % (BRAF_LO, CASE_LITS, TABLES[1] - TABLES[0], CODE[1] - CODE[0], TABLES[0], CODE[0]))
    return bytes(out)


def check(data):
    """[(ok, what)] for verify_update."""
    res = []
    braf = struct.unpack_from('<18H', data, _o(0x082C0EFC))
    res.append((all(v == BRAF_CP1252 for v in braf), 'reclaim: all 18 language cases -> cp1252 (0x00F8)'))
    res.append((struct.unpack_from('<9I', data, _o(CASE_LITS)) == (CP1252,) * 9,
                'reclaim: the 9 case literals -> %#x' % CP1252))
    lo, hi, _ = TABLES
    res.append((bytes(data[_o(lo):_o(hi)]) == b'\xff' * (hi - lo), 'reclaim: tables %#x-%#x erased' % (lo, hi)))
    lo, hi, _ = CODE
    res.append((bytes(data[_o(lo):_o(hi)]) == _code_fill(lo, hi),
                'reclaim: converters %#x-%#x = rts pairs, slot %#x kept' % (lo, hi, KEEP_SLOT)))
    res.append((struct.unpack_from('<I', data, _o(0x084F13DA))[0] == 0x2FA62F96,
                'reclaim: cp1252 converter %#x intact' % CP1252))
    return res
