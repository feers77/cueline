#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""KEY SHIFT for the MAIN image: the Key Shift engine + our front end.

The engine is our own (mods/ownks, named with the `ownks` mod: a DSP-output pitch shifter, no third-party
code). It sits behind a fixed interface that the front end uses:

  - the SH-4 routine that sends the shift to the DSP from the DJcont loop at 0x08122000 and its
    state block 0x08122800 (+0 on, +4 semitones -12..12, +16 generation);
  - the DSP boot table moved to 0x08130000 (the old table 0x080034E0-0x08091238 becomes free: the
    `ks` layout puts our routines, modsmenu, lang2 and tadec there).

Our front end does the rest (mods/keyshift/main_keyshift.s at KSB, modsmenu's KEYSHIFT items /
touch zones / publish, v2ui's tile and panel). The DJcont call literal 0x082D8970 points at our
boot gate (KSB+32), which calls the engine only when *0x0A35DF3C == 1.
"""
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

MBASE = 0x08000000
KSB = 0x08123000            # our front end
KS_ST = 0x08122800          # the engine's state block
DJ_LIT, DJ_STOCK = 0x082D8970, 0x082DBC2E                   # DJcont: the DSP-output step's literal
RB_LITS, RB_STOCK = (0x0844DA88, 0x0844DF18), 0x084E10F8    # panel decoder -> rekordbox-key setter
LAMP_LIT, LAMP_STOCK = 0x0844F64C, 0x084DC768               # lamp pass call (both callers)
MT_LITS, MT_STOCK = (0x0844DAC8, 0x0844E1EC), 0x084E171C    # V4n: panel decoder -> MASTER TEMPO setter (KEY SYNC)
HC_LITS, HC_STOCK = (0x0844D7AC, 0x0844DEF8), 0x084E1974    # V4n24: panel decoder -> hot-cue setter (KEY SYNC BUTTON)
HCL_LIT, HCL_STOCK = 0x0844FF7C, 0x084DC684                 # V4n24: frame builder -> pad-RGB getter (KEY SYNC BUTTON)
KX_LIT, KX_STOCK = 0x084B8FA0, 0x085117CA                   # V4n33: status sender 0x084B8132 -> UDP send (KEY SYNC fields)
WHAT = ('KEY SHIFT: Key Shift engine (DSP pitch shifter, -12..+12) + our UTILITY / panel / '
        'rekordbox-key front end (ks layout)')


def build_blob():
    """(bytes, symbols) of main_keyshift.s linked at KSB."""
    import patch_main
    src = os.path.join(HERE, 'main_keyshift.s')
    patch_main.check_delay_slots(src)
    with tempfile.TemporaryDirectory() as tmp:
        obj, elf, out = (os.path.join(tmp, n) for n in ('k.o', 'k.elf', 'k.bin'))
        tl = os.environ.get('CDJ_TESTLOG_DEFAULT')     # DEV: the TEST LOG the deck boots with (1 USB, 2 RED = default)
        if tl not in (None, '', '0', '1', '2'):
            raise SystemExit('keyshift: CDJ_TESTLOG_DEFAULT=%s: 0 OFF, 1 USB or 2 RED' % tl)
        if tl and tl != '2' and patch_main.build_profile() == 'release':
            raise SystemExit('keyshift: CDJ_TESTLOG_DEFAULT is a DEV setting (a release build has no TEST LOG item)')
        subprocess.run(['sh4-linux-gnu-as', '--isa=sh4', '-little', '-I', os.path.dirname(HERE)]
                       + (['--defsym', 'TLDEF=%s' % tl] if tl else [])
                       + (['--defsym', 'TONEOFF=1'] if os.environ.get('CDJ_NOTONE') == '1' else [])
                       + ['-o', obj, src], check=True)
        subprocess.run(['sh4-linux-gnu-ld', '-Ttext=%#x' % KSB, '-e', 'ks_base', '-o', elf, obj], check=True)
        subprocess.run(['sh4-linux-gnu-objcopy', '-O', 'binary', '-j', '.text', elf, out], check=True)
        syms = {}
        for line in subprocess.run(['sh4-linux-gnu-nm', elf], check=True, capture_output=True,
                                   text=True).stdout.splitlines():
            f = line.split()
            if len(f) == 3:
                syms[f[2]] = int(f[0], 16)
        return open(out, 'rb').read(), syms


def apply(data, own=False):
    """The engine + our front end into the stock MAIN image `data`. own=True (the `ownks` mod
    named): our own engine (mods/ownks), the only one; keyshift without it is refused."""
    out = bytearray(data)
    o = lambda a: a - MBASE
    u32 = lambda a: struct.unpack_from('<I', out, o(a))[0]
    for lit, want in [(DJ_LIT, DJ_STOCK), (LAMP_LIT, LAMP_STOCK)] + [(a, RB_STOCK) for a in RB_LITS] + [(a, MT_STOCK) for a in MT_LITS] \
            + [(a, HC_STOCK) for a in HC_LITS] + [(HCL_LIT, HCL_STOCK), (KX_LIT, KX_STOCK)]:
        if u32(lit) != want:
            raise SystemExit('keyshift: literal %#x holds %#x, not %#x' % (lit, u32(lit), want))
    n = 0
    if not own:
        raise SystemExit('keyshift: name the ownks mod with keyshift (the KEY SHIFT engine)')
    sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'ownks'))
    import ownks
    ownks.apply_engine(out, bytes(data))
    blob, syms = build_blob()
    if any(b != 0xFF for b in out[o(KSB):o(KSB) + len(blob)]):
        raise SystemExit('keyshift: %#x is not free' % KSB)
    out[o(KSB):o(KSB) + len(blob)] = blob
    struct.pack_into('<I', out, o(DJ_LIT), KSB + 32)
    for a in RB_LITS:
        struct.pack_into('<I', out, o(a), KSB + 36)
    struct.pack_into('<I', out, o(LAMP_LIT), KSB + 40)
    for a in MT_LITS:
        struct.pack_into('<I', out, o(a), KSB + 76)
    for a in HC_LITS:
        struct.pack_into('<I', out, o(a), KSB + 92)
    struct.pack_into('<I', out, o(HCL_LIT), KSB + 96)
    struct.pack_into('<I', out, o(KX_LIT), KSB + 108)
    print('patch_main: keyshift: %s engine (%d bytes: DSP table 0x08130000, loader, DJcont '
          'wrapper 0x08122000) + front end %d bytes at %#x; DJcont %#x / rekordbox key %s / lamp %#x '
          'literals -> our gate / setter / lamp'
          % ('OUR (ownks)', n, len(blob), KSB, DJ_LIT,
             '/'.join('%#x' % a for a in RB_LITS), LAMP_LIT))
    return bytes(out)


def check(img):
    """[(ok, what)] for verify_update: the front end's literals."""
    u32 = lambda a: struct.unpack_from('<I', img, a - MBASE)[0]
    res = [(u32(DJ_LIT) == KSB + 32, 'keyshift: DJcont literal %#x -> the boot gate %#x' % (DJ_LIT, KSB + 32)),
           (all(u32(a) == KSB + 36 for a in RB_LITS), 'keyshift: rekordbox-key setter literals -> %#x' % (KSB + 36)),
           (u32(LAMP_LIT) == KSB + 40, 'keyshift: lamp pass literal -> %#x' % (KSB + 40)),
           (all(u32(a) == KSB + 76 for a in MT_LITS), 'keyshift: MASTER TEMPO setter literals -> %#x' % (KSB + 76)),
           (all(u32(a) == KSB + 92 for a in HC_LITS), 'keyshift: hot-cue setter literals -> %#x' % (KSB + 92)),
           (u32(HCL_LIT) == KSB + 96, 'keyshift: pad-RGB getter literal -> %#x' % (KSB + 96)),
           (u32(KX_LIT) == KSB + 108, 'keyshift: status send literal -> %#x (KEY SYNC fields)' % (KSB + 108)),
           (img[KSB + 44 - MBASE:KSB + 48 - MBASE] == b'TFSK', 'keyshift: front end at %#x' % KSB),
           (u32(0x0832691C) == 0xA8130000, 'keyshift: DSP loader reads the table at 0x08130000')]
    return res
