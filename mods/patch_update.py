#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Patch a real Pioneer CDJ-2000NXS2 firmware update (.UPD) with a mod.

    usage: patch_update.py <in.UPD> <out.UPD> [<mod> ...]
           patch_update.py --list

`lang8` (lang8.py) trims the UI to 8 languages. `font3000` (font3000/font3000.py) replaces the
latin GUI font: Cueline Sans (ours, OFL) unless CDJ_FONT3000_TTF / CDJ_FONT3000_FALLBACK override it.

A mod is named as in mods/mods.conf (three_band, osc, ableton_link, ...) and
brings every patch that row switches on; --list shows them. A single patch
(patch_gui.py --list, patch_main.py --list) can still be named on its own.
With no mod named, every section is copied through untouched -- a repack
that reproduces the input byte for byte, useful for proving the container
handling itself is not what changed.

Every mod here also has a --list entry in patch_gui.py or patch_main.py,
since that is the tool that actually knows how to splice it into its image;
this is the container-level wrapper around them. Only mods that patch real
firmware code are offered -- an emulator-only knob such as high_fps or
live_clock (emulator/mods/mods.conf) has nothing to write into a .UPD and
does not appear here.

    1. Split the update into its sections (the same manifest split_update.py
       reads: CRLF-decimal lengths, then the sections concatenated).
    2. Decode the target section to the raw image patch_gui.py/patch_main.py
       works on: an LZSS stream for the GUI section, Motorola S-records
       wrapping the same LZSS codec for the MAIN section.
    3. Apply every requested mod for that image in one patch() call, so they
       share one placement and cannot collide.
    4. Re-encode (lzss_encode.py) and recompute the section's own length
       field and checksum(s) -- gui_encode.py, main_encode.py.
    5. Rewrite the manifest (only the patched sections' sizes change) and
       concatenate the sections back into a new .UPD.

Every mod declares the firmware version(s) of its target image it was
verified against (MODS[name].fw_versions). patch_update.py reads the
update's own version string for that image and refuses a mismatch -- pass
--force-version to patch anyway, at your own risk.

THIS IS UNTESTED ON REAL HARDWARE. The container repacks correctly and the
patched image has been proven identical to patch_gui.py's/patch_main.py's own
output (see emulator/tests/), but nobody has flashed one of these into a real
deck. Flashing a modified firmware update is entirely at your own risk: keep
the original .UPD to restore from, and expect that a mistake here can require
a service-mode recovery or worse.
"""
import os
import re
import struct
import tempfile
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIRMWARE = os.path.join(HERE, '..', 'scripts', 'firmware')
sys.path.insert(0, HERE)
sys.path.insert(0, FIRMWARE)

import patch_gui
import patch_main
import lang8
from font3000 import font3000     # mods/font3000/font3000.py
from v2ui import v2ui             # mods/v2ui/v2ui.py (V2 UI renderer)
from guitrim import guitrim       # mods/guitrim/guitrim.py (opt-in GUI room, re/GUI_RECLAIM.md)
import gui_decode
import gui_encode
import main_decode
import main_encode

# Which section of the v1.87 container (models/cdj2000nxs2.conf's
# MODEL_GUI_SECTION / MODEL_MAIN_SECTION) each target lives in. The
# CDJ-2000NXS2's .UPD is the only container shape this tool reads; a model
# whose update ships as several files (the CDJ-2000) is out of scope.
SECTION_OF = {'gui': 1, 'main': 3}

# target -> (decode(section) -> (header, declared, avail, image),
#            encode(header_or_section, image) -> section, module owning MODS/patch())
#
# gui's encode() only needs the section's 32-byte header (it is a flat LZSS
# blob with nothing else to preserve); main's needs the whole original
# section, since its own encode() carries the bootloader/emergency-updater
# S-records before the image forward unchanged -- see main() below.
TARGETS = {
    'gui': (gui_decode.decode, gui_encode.encode, patch_gui),
    'main': (main_decode.decode, main_encode.encode, patch_main),
}


# The packed MAIN application ([LE32 len][LZSS][LE16 sum] at section offset
# MAIN_IMG_OFF) must fit what the updater programs. Until re/UPD_SAFETY.md
# settles the real window, the smallest capacity seen (a third-party patched
# update's manifest: 0x3AB000) is the limit, not make_flash's MAIN_END.
MAIN_PACKED_MAX = 0x3AB000


class Entry:
    """One selectable patch: its target image, the module that applies it,
    the image versions it was verified against and its description."""
    def __init__(self, target, module, fw_versions, what):
        self.target, self.module, self.fw_versions, self.what = target, module, fw_versions, what


def registry():
    """{name: Entry} across every target module (TARGETS): its code MODS, and
    where it has them its in-place POKES (the GUI) and FIXED blobs (MAIN's
    tadec), each applied by that module's patch (see apply())."""
    reg = {}
    for target, (_, _, mod) in TARGETS.items():
        for name, m in mod.MODS.items():
            reg[name] = Entry(target, mod, m.fw_versions, m.what)
        for name, p in getattr(mod, 'POKES', {}).items():
            reg[name] = Entry(target, mod, p['fw_versions'], p['what'])
        for name, (_, _, what) in getattr(mod, 'FIXED', {}).items():
            reg[name] = Entry(target, mod, ('1.87',), what)
    for name, (target, what) in LANG8.items():
        reg[name] = Entry(target, lang8, TARGET_VERSIONS[target], what)
    reg['font3000'] = Entry('gui', font3000, TARGET_VERSIONS['gui'], font3000.WHAT)
    reg['v2ui'] = Entry('gui', v2ui, TARGET_VERSIONS['gui'], v2ui.WHAT)
    reg['v2needle'] = Entry('main', v2ui, TARGET_VERSIONS['main'], v2ui.NEEDLE_WHAT)
    for name in guitrim.NAMES:
        reg[name] = Entry('gui', guitrim, TARGET_VERSIONS['gui'], guitrim.WHAT[name])
    return reg


# lang8 (lang8.py): the UI trimmed to 8 languages, one half per image. Not a
# mods.conf row (the emulator's launcher reads that file); the pseudo-row
# `lang8` below names both halves.
TARGET_VERSIONS = {'gui': ('1.81',), 'main': ('1.87',)}
LANG8 = {
    'lang8gui': ('gui', 'UI languages: 10 dropped, their strings zeroed, old values -> English'),
    'lang8main': ('main', 'UTILITY > LANGUAGE: 8 options; other values clamped to English'),
    'lang2gui': ('gui', 'UI languages: only English + Spanish kept, 16 dropped -> English'),
    'lang2main': ('main', 'UTILITY > LANGUAGE: ENGLISH / ESPANOL; other values clamped to English'),
}
EXTRA_ROWS = {'lang8': ['lang8gui', 'lang8main'], 'lang2': ['lang2gui', 'lang2main']}


def mod_rows(reg):
    """{row name: registry names}: mods.conf's rows plus EXTRA_ROWS."""
    out = {key: [n for n in knobs if n in reg] for key, knobs in conf_rows().items()}
    out.update(EXTRA_ROWS)
    return out


def apply(target, image, names):
    """The target module's own full patch: patch_gui.patch_all (code mods,
    redirects, pokes) where it exists, else its patch() (patch_main's handles
    FIXED blobs and code mods); then lang8's half for this image, if named."""
    mod = TARGETS[target][2]
    own = [n for n in names if n not in LANG8 and n not in ('font3000', 'v2ui', 'v2needle')
           and n not in guitrim.NAMES]
    if not own:
        out = image
    else:
        out = mod.patch_all(image, own) if hasattr(mod, 'patch_all') else mod.patch(image, own)
    for prof in ('lang8', 'lang2'):
        if prof + 'gui' in names:
            out = lang8.gui(out, prof)
        if prof + 'main' in names:     # (V4k: keyshift builds in the ks layout -- patch_main.layout_for)
            out = lang8.main(out, patch_main.layout_for(names), prof)
    if 'font3000' in names:     # mods/font3000: the latin font (Cueline Sans; env CDJ_FONT3000_TTF overrides)
        out = font3000.apply(out)
    if 'v2ui' in names:         # mods/v2ui: our renderer, chained into the VDC base write
        out = v2ui.apply(out)
    if 'v2needle' in names:     # mods/v2ui (V3c): MAIN touch zone 0 = the V2 overview
        out = v2ui.needle_main(out)
    if target == 'gui' and guitrim.tiers(names):    # mods/guitrim: last (re-encodes the archives font3000 left)
        out = guitrim.apply(out, names)
    return out


# The GUI section must not outgrow the stock one: the GUI flash's real size
# is not known.
# The MAIN section's length is a 7-digit decimal in the manifest.
# The deck's updater takes a MAIN section of at most 0x902A00 bytes (the
# S-record text, the manifest's third number): 9,447,912 B (S3e) was written,
# 9,448,068 B (S3g) and 9,448,146 B (S3f) were read and silently skipped under
# the same label scheme (2026-10-22, real deck). Not RE'd: the limit may sit
# anywhere in between; keep a margin (the manifest's 7 digits were the old guess).
MAIN_SECTION_MAX = 0x902A00


def conf_rows():
    """{mods.conf key: the registry names of its knobs}. A knob is named
    CDJ_GUI_<NAME> or CDJ_MAIN_<NAME> after its patch_gui/patch_main entry, so
    one row (three_band) stands for every patch it switches on."""
    rows = {}
    with open(os.path.join(HERE, 'mods.conf'), encoding='utf-8') as f:
        for line in f:
            if line.startswith('#') or '|' not in line:
                continue
            key, env = line.split('|')[:2]
            rows[key] = [re.sub(r'^CDJ_(GUI|MAIN)_', '', knob).lower() for knob in env.split('+')]
    return rows


def parse_manifest(data):
    """(section sizes, header length) -- see split_update.py."""
    sizes, pos = [], 0
    while True:
        m = re.match(rb'(\d+)\r\n', data[pos:pos + 32])
        if not m:
            break
        sizes.append(int(m.group(1)))
        pos += m.end()
    return sizes, pos


def section_version(header):
    m = re.search(r'Ver(\d+\.\d+)', header)
    if not m:
        raise SystemExit('patch_update: no version string in section header %r' % header)
    return m.group(1)


# How the deck's updater decides to program a section (MAIN 0x084F30B8,
# called once per section from the update task at 0x084F465E): it reads the
# version from the section label ("CDJ-2000NXS2MAINVer1.87": the digits at
# label offsets 19, 21, 22, 23, a non-digit counting 0) as d*1000+d*100+d*10+d
# and compares it with the INSTALLED version:
#   GUI   the version the running GUI reports, the "1.81" string in the GUI
#         image header (gui image offset 0x8C60C); written only if newer.
#   MAIN  the "1.87" string in the MAIN image header (0x08000740); written if
#         newer -- or, whatever the version, if the installed string carries
#         '+' or '-' right after it ("Ver 1.87+": the copy at 0x0A35F5DC,
#         bytes 8/9), or the label has '+' at offset 23 or 24.
#   DRIV  the drive's version string, written if different.
#   PANL  the panel MCU's BCD version, written only if newer.
# (A flag at 0x0B06C6F8+4 forces every section.) Equal is skipped: a mods
# build labelled 1.87 over 1.87 is accepted, shows 100 % and writes nothing
# -- seen in the emulator.
#
# So a mods build goes up by 0.01 (MAIN 1.88, GUI 1.82) to be written at all,
# and stamps its images so the official stock update can still go back:
#   MAIN header "1.87+": the '+' lets any later MAIN in, the stock 1.87 too.
#                        The number stays 1.87 because the deck announces it
#                        on Pro DJ Link (copied from "Ver 1.87+" bytes 4..7 at
#                        0x08405F10): a "1.88" made a stock 1.87 deck on the
#                        link show "Linked to player with older firmware".
#   GUI header  "1.80":  one below stock, so the stock 1.81 GUI is newer.
# The official C2KNXS2.UPD (1.87/1.81) was meant to be the rollback, and a
# later mods build to install over an earlier one by the '+'.
#
# REAL DECK, 2026-10-21: the '+' does nothing. A build labelled MAIN 1.88 over
# an installed 1.88 ("1.87+" in UTILITY > VERSION) is read and skipped (the
# update screen shows, nothing is written); the same bytes labelled 1.89
# (--main-bump=2) are written. So on hardware only "label newer than the
# installed label" counts: every build for the deck takes --main-bump=N one
# above the installed one, and the official 1.87 is most likely skipped as a
# rollback too (a stock-restore build with a higher label is the way back --
# untested).
# The deck's updater takes a MAIN section of at most 0x902A00 bytes (the
# S-record text, the manifest's third number): 9,447,912 B (S3e) was written,
# 9,448,068 B (S3g) and 9,448,146 B (S3f) were read and silently skipped, same
# labels scheme (2026-10-22, real deck). Not RE'd: the limit may sit anywhere
# in between; keep a margin.

LABEL_VER = 19                 # 'X' of "VerX.YY" in a section label
LABEL_VER_END = LABEL_VER + 4
IMAGE_VER = {'main': 0x740, 'gui': 0x8C60C}   # "X.YY\0" in each image


def ver_str(v):
    return ('%d.%02d' % (v // 100, v % 100)).encode()


def label_ver(label):
    m = re.fullmatch(rb'(\d)\.(\d\d)', label[LABEL_VER:LABEL_VER_END])
    if not m or label[LABEL_VER - 3:LABEL_VER] != b'Ver':
        die('no VerX.YY at label offset %d: %r' % (LABEL_VER, label[:32]))
    return int(m.group(1)) * 100 + int(m.group(2))


MAIN_BUMP = 1                  # --main-bump=N: MAIN label stock + 0.0N (1.89 for
                               # N=2: strictly newer than an installed 1.88)


GUI_BUMP = 1                   # --gui-bump=N: GUI label stock + 0.0N (1.83 for N=2,
                               # over an installed 1.82)


def bumped(target, stock_label_ver):
    return stock_label_ver + (MAIN_BUMP if target == 'main' else GUI_BUMP)


def stamp_image(target, image, version_str):
    """The image-header version stamp described above, checked against the
    stock string first."""
    off = IMAGE_VER[target]
    stock = version_str.encode()
    if image[off:off + len(stock) + 1] != stock + b'\0':
        die('%s image header at %#x holds %r, not %r' % (target, off, image[off:off + 6], stock))
    v = int(stock[0:1]) * 100 + int(stock[2:4])
    new = ver_str(v) + b'+\0' if target == 'main' else ver_str(v - 1) + b'\0'
    out = bytearray(image)
    out[off:off + len(new)] = new
    return bytes(out)


def relabel_section(target, section):
    """The section label goes up by 0.01; the section CRC-16 covers the label
    (GUI trailer big-endian, MAIN little-endian)."""
    sec = bytearray(section)
    v = label_ver(bytes(sec[:32]))
    sec[LABEL_VER:LABEL_VER_END] = ver_str(bumped(target, v))
    crc = gui_encode.crc16_xmodem(bytes(sec[:-2]))
    sec[-2:] = struct.pack('>H' if target == 'gui' else '<H', crc)
    return bytes(sec)


def die(msg):
    raise SystemExit('patch_update: %s' % msg)


def check_committed_bins():
    """The committed MAIN .bins (stock layout) must be what the sources assemble to NOW: touch_audio
    and utiltint carry modsmenu addresses (mm_publish, block_end) as --defsym, so a modsmenu edit
    without `patch_main.py --assemble` leaves them pointing into the old layout (V2j: touch_audio
    called 0x0813E428, the tail of mods_save, every 2 s). Stops the build when they differ."""
    with tempfile.TemporaryDirectory() as tmp:
        patch_main.assemble('stock', tmp, quiet=True)
        stale = []
        for name in sorted(os.listdir(tmp)):
            if not name.endswith('.bin'):
                continue
            committed = patch_main.blob_path(name[:-4])
            with open(os.path.join(tmp, name), 'rb') as f:
                fresh = f.read()
            if not os.path.isfile(committed) or open(committed, 'rb').read() != fresh:
                stale.append(name[:-4])
        if stale:
            die('committed MAIN blobs differ from their sources (%s): run `python3 mods/patch_main.py '
                '--assemble` first' % ', '.join(stale))


def main():
    args = sys.argv[1:]
    force_version = '--force-version' in args
    args = [a for a in args if a != '--force-version']
    # Versions: see bump_versions(). On by default whenever a mod is named,
    # since a mods build the updater skips is no build at all; --no-bump
    # leaves every label and image as the mods made them.
    bump = '--no-bump' not in args
    bump_gui = '--bump-gui' in args
    args = [a for a in args if a != '--bump-gui']
    # --bump-main: the MAIN section goes through the version stamp and label
    # with no MAIN mod (a stock-restore build: stock code, labels above the
    # installed mods build, so the updater writes it without a factory reset).
    bump_main = '--bump-main' in args
    args = [a for a in args if a != '--bump-main']
    # --no-main-size-check: build past MAIN_SECTION_MAX anyway (experiments; the
    # deck is expected to read and skip such a .UPD: 2026-10-22, S3f/S3g).
    size_check = '--no-main-size-check' not in args
    args = [a for a in args if a != '--no-main-size-check']
    global MAIN_BUMP
    for a in [a for a in args if a.startswith('--main-bump=')]:
        MAIN_BUMP = int(a.split('=', 1)[1])
        args = [x for x in args if x != a]
    global GUI_BUMP
    for a in [a for a in args if a.startswith('--gui-bump=')]:
        GUI_BUMP = int(a.split('=', 1)[1])
        args = [x for x in args if x != a]
    args = [a for a in args if a != '--no-bump']
    reg = registry()
    rows = mod_rows(reg)

    if args == ['--list']:
        for key, patches in rows.items():
            if patches:
                versions = sorted({'%s Ver%s' % (reg[n].target, '/'.join(reg[n].fw_versions))
                                   for n in patches})
                print('%-12s [%s] %s' % (key, ', '.join(versions), ' '.join(patches)))
        in_rows = {n for patches in rows.values() for n in patches}
        for name, e in reg.items():
            if name not in in_rows:
                print('%-12s [%s Ver%s] %s' % (name, e.target, '/'.join(e.fw_versions), e.what))
        return

    if len(args) < 2:
        raise SystemExit(__doc__)
    in_path, out_path = args[0], args[1]
    check_committed_bins()

    # A row's name wins over a patch of the same name: `osc` is the whole osc
    # row (osc + oscbeat), not its first patch alone.
    names = []
    for arg in args[2:]:
        if rows.get(arg):
            expanded = rows[arg]
        elif arg in rows:
            die('%s only changes the emulator; it has nothing to write into a .UPD' % arg)
        elif arg in reg:
            expanded = [arg]
        else:
            die('unknown mod %s -- see --list' % arg)
        names += [n for n in expanded if n not in names]

    # With ui3000x, tracks without 3-band data keep the CDJ-3000 RGB look in
    # the overview too (wave3ovrgb; the centre's wave3rgb is patch_gui's).
    if 'ui3000x' in names and 'wave3ovdata' in names:
        names = ['wave3ovrgb' if n == 'wave3ovdata' else n for n in names]
    by_target = {}
    for name in names:
        by_target.setdefault(reg[name].target, []).append(name)
    if bump_gui:
        # --bump-gui: the GUI section goes through the version bump (image
        # stamp 1.80, label 1.82) even with no GUI mod, so it carries the same
        # headers as every mods build (the stock 1.81/1.81 headers are what
        # the deck's installed GUI app choked on, 2026-10-21).
        by_target.setdefault('gui', [])
    if bump_main:
        by_target.setdefault('main', [])

    with open(in_path, 'rb') as f:
        data = f.read()
    sizes, hdrlen = parse_manifest(data)
    off = hdrlen
    sections = []
    for size in sizes:
        sections.append(data[off:off + size])
        off += size

    for target, target_names in sorted(by_target.items()):
        decode, encode, mod = TARGETS[target]
        idx = SECTION_OF[target] - 1
        if idx >= len(sections):
            die('%s targets section %d, but this update only has %d'
                % (target, idx + 1, len(sections)))
        section = sections[idx]
        header, declared, avail, image = decode(section)
        version = section_version(header)
        for name in target_names:
            wanted = reg[name].fw_versions
            if version not in wanted and not force_version:
                die('%s is verified only for %s Ver%s; this update carries Ver%s '
                    '-- pass --force-version to patch anyway (untested)'
                    % (name, target, '/'.join(wanted), version))
        patched = apply(target, image, target_names) if target_names else image
        if bump:
            patched = stamp_image(target, patched, version)
        if target == 'gui' and patched != image:
            patched = patch_gui.fix_trailer(patched)      # the GUI's own CRC over [0:end]
        if target == 'main':
            packed = len(main_encode.encode_image(patched, optimal=True))
            if packed > MAIN_PACKED_MAX:
                die('patched MAIN packs to %d bytes, over the %d the updater is known to '
                    'program (MAIN_PACKED_MAX)' % (packed, MAIN_PACKED_MAX))
            print('patch_update: MAIN packs to %d of %d bytes (%.1f%%)'
                  % (packed, MAIN_PACKED_MAX, 100.0 * packed / MAIN_PACKED_MAX))
        # gui's section has nothing but the header and the LZSS blob; main's
        # carries the bootloader and emergency-updater S-records too, so its
        # encode() needs the whole original section to reproduce them.
        new = (encode(section, patched, optimal=True) if target == 'main'
               else encode(section[:32], patched, optimal=True))
        # never above stock (user rule); tiny synthetic test sections excepted
        if target == 'gui' and len(new) > len(section) and len(section) > 1 << 20:
            die('the GUI section grows to %d bytes, past the stock %d' % (len(new), len(section)))
        if target == 'main' and size_check and len(new) > MAIN_SECTION_MAX:
            die('the MAIN section is %d bytes, past the deck updater\'s %#x (it reads and skips bigger ones)' % (len(new), MAIN_SECTION_MAX))
        sections[idx] = new
        print('patch_update: section %d (%s, Ver%s) %d -> %d bytes'
              % (idx + 1, target, version, len(section), len(sections[idx])))

    if bump:
        for target in by_target:
            idx = SECTION_OF[target] - 1
            sections[idx] = relabel_section(target, sections[idx])
            print('patch_update: section %d (%s) labelled %r' % (idx + 1, target,
                  sections[idx][:LABEL_VER_END].decode('latin1')))

    manifest = b''.join(b'%d\r\n' % len(s) for s in sections)
    with open(out_path, 'wb') as f:
        f.write(manifest + b''.join(sections))
    print('patch_update: wrote %s (%d bytes)' % (out_path, hdrlen + sum(len(s) for s in sections)))
    print('patch_update: UNTESTED ON REAL HARDWARE -- flash at your own risk')


if __name__ == '__main__':
    main()
