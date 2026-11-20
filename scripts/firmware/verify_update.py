#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check a (patched) CDJ-2000NXS2 .UPD before it goes anywhere near a deck.

    usage: verify_update.py <stock.UPD> <candidate.UPD> [<mod> ...]

(the same mod names as patch_update.py, lang8 included: it adds its own checks)

Re-reads the candidate the way the deck's updater would see it and compares
it with the stock update and with what the emulator runs:

  1. Container: the manifest lists four sections whose sizes add up to the
     file, each with its "CDJ-2000NXS2" label and the same kind/version as
     the stock section in that place.
  2. Checksums, first proven on the STOCK update (so the algorithms below are
     Pioneer's, not ours): every section's CRC-16/XMODEM trailer (GUI stored
     big-endian, MAIN little-endian), every S-record's own checksum, and the
     MAIN image's 16-bit byte sum the bootloader verifies before it runs it.
  3. What must not change is identical to the stock update: sections 2 (DRIV)
     and 4 (PANL) byte for byte, and in section 3 every S-record below
     MAIN_IMG_OFF (the bootloader at 0 and the emergency updater at 0x10000)
     and the S7 record.
  4. What changes is exactly what the emulator was tested with: the decoded
     GUI and MAIN images equal patch_gui.patch_all() / patch_main.patch() of
     the stock images with the same mod names (expanded as patch_update.py
     does), and the packed MAIN fits patch_update.MAIN_PACKED_MAX.

Exit status 0 only when every check passes. With no mod named, the candidate
must decode to the stock images (a repack).
"""
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MODS_DIR = os.path.join(HERE, '..', '..', 'mods')
sys.path.insert(0, HERE)
sys.path.insert(0, MODS_DIR)

import gui_decode
import main_decode
from gui_encode import crc16_xmodem
from main_decode import srecords, MAIN_IMG_OFF, LABEL_SIZE

failures = []


def check(ok, what):
    print('  %s %s' % ('ok  ' if ok else 'FAIL', what))
    if not ok:
        failures.append(what)
    return ok


def sections_of(data):
    sizes, pos = [], 0
    while True:
        m = re.match(rb'(\d+)\r\n', data[pos:pos + 32])
        if not m:
            break
        sizes.append(int(m.group(1)))
        pos += m.end()
    out, off = [], pos
    for size in sizes:
        out.append(data[off:off + size])
        off += size
    return sizes, pos, out


def main_parts(section):
    """(prefix S-record lines below MAIN_IMG_OFF, S7 line, packed image bytes,
    every S-record checksum ok)."""
    body = section[LABEL_SIZE:-2]
    prefix, flat, hi = [], {}, 0
    try:
        recs = list(srecords(body))
        recs_ok = True
    except ValueError:
        return None, None, None, False
    for addr, data, line in recs:
        if addr < MAIN_IMG_OFF:
            prefix.append(line)
        else:
            flat[addr] = data
            hi = max(hi, addr + len(data))
    s7 = next((ln for ln in body.split(b'\r\n') if ln[:2] == b'S7'), None)
    buf = bytearray([0xFF]) * (hi - MAIN_IMG_OFF)
    for addr, data in flat.items():
        buf[addr - MAIN_IMG_OFF:addr - MAIN_IMG_OFF + len(data)] = data
    return prefix, s7, bytes(buf), recs_ok


def packed_sum_ok(buf):
    length = struct.unpack_from('<I', buf, 0)[0]
    end = 4 + length
    stored = struct.unpack_from('<H', buf, end)[0]
    return (sum(buf[:end]) & 0xFFFF) == stored, end + 2


def checksums(name, secs):
    print('%s: checksums' % name)
    gui, main = secs[0], secs[2]
    check(struct.unpack('>H', gui[-2:])[0] == crc16_xmodem(gui[:-2]),
          'GUI section CRC-16/XMODEM (big-endian trailer)')
    check(struct.unpack('<H', main[-2:])[0] == crc16_xmodem(main[:-2]),
          'MAIN section CRC-16/XMODEM (little-endian trailer)')
    prefix, s7, buf, recs_ok = main_parts(main)
    check(recs_ok, 'every MAIN S-record checksum')
    ok, packed_len = packed_sum_ok(buf) if buf else (False, 0)
    check(ok, 'MAIN image 16-bit byte sum (checked by the bootloader)')
    return prefix, s7, buf, packed_len


def mod_targets(mods):
    import patch_update
    reg = patch_update.registry()
    rows = patch_update.mod_rows(reg)
    return {reg[n].target for m in mods for n in (rows.get(m) or [m]) if n in reg}


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        raise SystemExit(__doc__)
    bump = '--no-bump' not in args       # as patch_update.py: on whenever a mod is named
    args = [a for a in args if a != '--no-bump']
    bump_gui = '--bump-gui' in args      # as patch_update.py --bump-gui: the GUI bumped without a mod
    args = [a for a in args if a != '--bump-gui']
    bump_main = '--bump-main' in args    # as patch_update.py --bump-main: MAIN bumped without a mod
    args = [a for a in args if a != '--bump-main']
    size_check = '--no-main-size-check' not in args   # as patch_update.py
    args = [a for a in args if a != '--no-main-size-check']
    main_bump = None                     # as patch_update.py --main-bump=N
    for a in [a for a in args if a.startswith('--main-bump=')]:
        main_bump = int(a.split('=', 1)[1])
        args = [x for x in args if x != a]
    gui_bump = None                      # as patch_update.py --gui-bump=N
    for a in [a for a in args if a.startswith('--gui-bump=')]:
        gui_bump = int(a.split('=', 1)[1])
        args = [x for x in args if x != a]
    # --p56=<set|patch,...>: opt-in mods/player56 (as its build_upd.py): the pseudo-mod
    # 'player56' joins the MAIN mods and its patched bytes are checked one by one.
    p56 = next((a.split('=', 1)[1] for a in args if a.startswith('--p56=')), None)
    args = [a for a in args if not a.startswith('--p56=')]
    stock_path, cand_path, mods = args[0], args[1], args[2:]
    sys.path.insert(0, MODS_DIR)
    import patch_update
    if p56 is not None:
        sys.path.insert(0, os.path.join(MODS_DIR, 'player56'))
        import player56
        p56_names = player56.names_of(p56)
        player56.install(patch_update, p56_names)
        mods = mods + ['player56']
    if main_bump is not None:
        patch_update.MAIN_BUMP = main_bump
    if gui_bump is not None:
        patch_update.GUI_BUMP = gui_bump
    stock = open(stock_path, 'rb').read()
    cand = open(cand_path, 'rb').read()

    print('container')
    s_sizes, s_hdr, s_secs = sections_of(stock)
    c_sizes, c_hdr, c_secs = sections_of(cand)
    check(len(c_sizes) == len(s_sizes) == 4, 'four sections (stock %d, candidate %d)'
          % (len(s_sizes), len(c_sizes)))
    check(c_hdr + sum(c_sizes) == len(cand), 'manifest sizes add up to the file')
    targets = mod_targets(mods) if bump else set()
    if bump_gui and bump:
        targets |= {'gui'}
    if bump_main and bump:
        targets |= {'main'}
    for i, (a, b) in enumerate(zip(s_secs, c_secs)):
        want = a[:LABEL_SIZE]
        t = {0: 'gui', 2: 'main'}.get(i)
        if t in targets:                 # bumped by 0.01 so the updater writes it
            want = patch_update.relabel_section(t, a)[:LABEL_SIZE]
        if t == 'main' and size_check:
            check(len(b) <= patch_update.MAIN_SECTION_MAX, 'MAIN section %d bytes <= %#x (the deck skips bigger ones)'
                  % (len(b), patch_update.MAIN_SECTION_MAX))
        check(b[:LABEL_SIZE] == want, 'section %d label %r as expected'
              % (i + 1, b[:LABEL_SIZE].rstrip(b'\x00 ').decode('latin1')))

    _, _, s_buf, _ = checksums('stock', s_secs)
    if failures:
        raise SystemExit('verify_update: the checksum algorithms do not reproduce the STOCK '
                         'update -- stop, nothing else can be trusted')
    c_prefix, c_s7, c_buf, c_packed = checksums('candidate', c_secs)
    s_prefix, s_s7, _, _ = main_parts(s_secs[2])

    print('unchanged parts')
    check(c_secs[1] == s_secs[1], 'section 2 (DRIV) identical to stock')
    check(c_secs[3] == s_secs[3], 'section 4 (PANL) identical to stock')
    check(c_prefix == s_prefix, 'MAIN S-records below 0x%x (bootloader, emergency updater) '
          'identical to stock (%d records)' % (MAIN_IMG_OFF, len(s_prefix or [])))
    check(c_s7 == s_s7, 'MAIN S7 record identical to stock')
    s0 = lambda sec: [ln for ln in sec[32:].split(b'\r\n') if ln[:2] == b'S0']
    check(s0(c_secs[2]) == s0(s_secs[2]) and c_secs[2][32:34] == b'S0',
          'MAIN S0 header record identical to stock and first (as Pioneer\'s)')

    print('images')
    import patch_gui
    import patch_main
    reg = patch_update.registry()
    rows = patch_update.mod_rows(reg)
    names = []
    for m in mods:
        for n in (rows.get(m) or [m]):
            if n not in reg:
                raise SystemExit('verify_update: unknown mod %s' % n)
            if n not in names:
                names.append(n)
    gui_names = [n for n in names if reg[n].target == 'gui']
    main_names = [n for n in names if reg[n].target == 'main']
    if 'ui3000x' in names and 'wave3ovdata' in main_names:     # as patch_update.main()
        main_names = ['wave3ovrgb' if n == 'wave3ovdata' else n for n in main_names]

    _, _, _, s_gui = gui_decode.decode(s_secs[0])
    _, _, _, c_gui = gui_decode.decode(c_secs[0])
    _, _, _, s_main = main_decode.decode(s_secs[2])
    # patch_update.apply(): patch_gui.patch_all / patch_main.patch, then lang8
    want_gui = patch_update.apply('gui', s_gui, gui_names) if gui_names else s_gui
    if 'gui' in targets:
        want_gui = patch_update.stamp_image('gui', want_gui, '1.81')
    if want_gui != s_gui:
        want_gui = patch_gui.fix_trailer(want_gui)
    check(patch_gui.trailer_ok(c_gui), "GUI image trailer: CRC-16 at 0x14FFFA over [0:end] matches "
          "and end covers everything placed before it (the GUI's own integrity check)")
    check(c_gui == want_gui, 'GUI image == patch_gui.patch_all(stock, %s)' % (gui_names or 'none'))

    ext = os.path.join(HERE, '..', '..', 'extract')
    if os.path.exists(os.path.join(ext, 'gui_unpacked.bin')):
        e_gui = open(os.path.join(ext, 'gui_unpacked.bin'), 'rb').read()
        e_main = open(os.path.join(ext, 'main_unpacked.bin'), 'rb').read()
        check(e_gui == s_gui, "the emulator's extract/gui_unpacked.bin is the stock GUI image")
        # extract/main_unpacked.bin was decoded from flash.bin and carries a short
        # tail of decoder run-off past the declared stream; the image proper must match.
        check(e_main[:len(s_main)] == s_main and len(e_main) - len(s_main) < 256,
              "the emulator's extract/main_unpacked.bin is the stock MAIN image "
              "(+%d bytes of decode tail)" % (len(e_main) - len(s_main)))
    _, _, _, c_main = main_decode.decode(c_secs[2])
    want_main = patch_update.apply('main', s_main, main_names) if main_names else s_main
    if 'main' in targets:
        want_main = patch_update.stamp_image('main', want_main, '1.87')
    if targets:
        print('installed-version stamps (rollback path)')
        if 'main' in targets:
            check(c_main[0x740:0x746] == patch_update.ver_str(
                  patch_update.label_ver(s_secs[2])) + b'+\0',
                  'MAIN header "%s": the \'+\' lets the stock 1.87 MAIN back in'
                  % c_main[0x740:0x745].decode('latin1'))
        if 'gui' in targets:
            check(patch_update.label_ver(s_secs[0]) > int(c_gui[0x8C60C:0x8C60D]) * 100
                  + int(c_gui[0x8C60E:0x8C610]),
                  'GUI header "%s" below the stock GUI label: the stock GUI is newer'
                  % c_gui[0x8C60C:0x8C610].decode('latin1'))
    check(c_main == want_main, 'MAIN image == patch_main.patch(stock, %s)' % (main_names or 'none'))
    if p56 is not None:
        for ok, what in player56.verify(c_main, p56_names):
            check(ok, what)
    for prof in ('lang8', 'lang2'):
        if prof + 'gui' not in names and prof + 'main' not in names:
            continue
        import lang8
        print('%s (UI languages)' % prof)
        for ok, what in (lang8.check_gui(c_gui, prof) if prof + 'gui' in names else []) + \
                (lang8.check_main(c_main, patch_main.layout_for(main_names), prof) if prof + 'main' in names
                 else []):
            check(ok, what)
    if 'keyshift' in main_names:     # V4k: the Key Shift engine + our front end (mods/keyshift)
        print('keyshift (KEY SHIFT engine + front end, ks layout)')
        sys.path.insert(0, os.path.join(MODS_DIR, 'keyshift'))
        import keyshift
        for ok, what in keyshift.check(c_main):
            check(ok, what)
        if 'ownks' in main_names:     # our own engine behind the same front end (mods/ownks)
            sys.path.insert(0, os.path.join(MODS_DIR, 'ownks'))
            import ownks
            for ok, what in ownks.check(c_main):
                check(ok, what)
    if 'reclaim' in main_names:      # opt-in: non-Latin codepages erased in place (mods/reclaim)
        print('reclaim (non-Latin codepages -> cp1252)')
        sys.path.insert(0, os.path.join(MODS_DIR, 'reclaim'))
        import reclaim
        for ok, what in reclaim.check(c_main):
            check(ok, what)
    if 'font3000' in names:
        print('font3000 (latin GUI font)')
        for ok, what in patch_update.font3000.check_gui(c_gui, patch_update.apply(
                'gui', s_gui, [n for n in gui_names if n != 'font3000'])):
            check(ok, what)
    if patch_update.guitrim.tiers(gui_names):
        print('guitrim (GUI room: %s)' % ', '.join(sorted(patch_update.guitrim.tiers(gui_names))))
        for ok, what in patch_update.guitrim.check_gui(c_gui, patch_update.apply(
                'gui', s_gui, [n for n in gui_names if n not in patch_update.guitrim.NAMES]), gui_names):
            check(ok, what)
    check(len(c_secs[0]) <= len(s_secs[0]),
          'GUI section %d bytes within the stock %d' % (len(c_secs[0]), len(s_secs[0])))
    check(len(c_secs[2]) <= (9999999 if not size_check else patch_update.MAIN_SECTION_MAX),
          'MAIN section %d bytes within the deck updater\'s limit (%s)'
          % (len(c_secs[2]), '%#x, stock base' % patch_update.MAIN_SECTION_MAX if size_check
             else 'size check OFF: only the manifest\'s 7 digits; ABOVE %#x needs T1'
                  % patch_update.MAIN_SECTION_MAX if len(c_secs[2]) > patch_update.MAIN_SECTION_MAX
             else 'size check OFF; still within %#x' % patch_update.MAIN_SECTION_MAX))
    check(c_packed <= patch_update.MAIN_PACKED_MAX,
          'packed MAIN %d bytes fits MAIN_PACKED_MAX %d' % (c_packed, patch_update.MAIN_PACKED_MAX))

    if failures:
        print('verify_update: %d check(s) FAILED:' % len(failures))
        for f in failures:
            print('   - ' + f)
        sys.exit(1)
    print('verify_update: all checks passed')


if __name__ == '__main__':
    main()
