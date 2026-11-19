#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Apply code mods to the unpacked display (GUI) firmware image.

    usage: patch_gui.py <gui_unpacked.bin> <patched.bin> <mod> [<mod>...]
           patch_gui.py --assemble     rebuild every mod's .bin from its .s
           patch_gui.py --check        fail if a committed .bin is not its .s assembled
           patch_gui.py --list

Each mod is a routine written in SH-2A assembly (gui_<mod>.s, assembled to
gui_<mod>.bin, which is kept next to it so patching needs no cross tools) and
a stretch of firmware code it replaces with a call to that routine. The patch
is made to the image, the way a firmware update would carry it:

  1. The routines go into the erased flash right after the
     on-chip RAM segments' source, and one new load-table record copies them
     to on-chip RAM past the end of the zero-filled area, where nothing in
     the image points.
  2. Each mod's call site is found by its instructions, not its address, and
     the image is left alone unless every site occurs exactly once.

Naming several mods patches all of them in one pass, sharing one load-table
record between them: pass every mod you want in a single call. Patching them
one at a time and combining the results is not supported.

The load table at 0x10 is twenty 12-byte records in groups of four (that
shape, and everything else about how a call site is found and spliced in, is
generic -- see sigpatch.py). That reading fits every record of v1.80 and
v1.81, but the boot loader that walks the table is not in the image, so it is
inferred, not read.
"""
import glob
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sigpatch
from sigpatch import Mod

GUI_PROFILE = sigpatch.ImageProfile(
    flash_base=0x30000, loadtab_off=0x10, loadtab_n=20,
    ram_base=0x1C000000, ram_end=0x1C280000)

MODS = {
    # The RGB branch of the centre-waveform renderer, from the height clamp to
    # the end of the column fill. r5 = peak sample index, r8 = PWV5 array,
    # r12 = height, @(44,r15) = screen column; the canvas is the literal.
    'wave3': Mod(
        what='3-band centre waveform',
        target='gui',
        fw_versions=('1.81',),
        sig=[
            0x2CC8, 0x8B00, 0xEC01, 0x4500, 0xEB07, 0x6053, 0x058D, 0x0A00,
            0xE000, 0x4B18, 0x605D, 0xE9FB, 0x6103, 0xE400, 0x4121, 0x4121,
            0x21B9, 0x6603, 0x26A9, 0x409C, 0x67C3, 0x77FF, 0x316C, 0xC91C,
            0x3C77, 0x8F22, 0x310C, 0x4715, 0x8B12, 0x56FB, 0xD28A, 0x4600,
            0x0510, 0x9E00, 0x0910, 0xA400, 0x362C, 0x356C, 0x369C, 0x7402,
            0xE2F4, 0x4218, 0x3473, 0x2611, 0x362C, 0x2511, 0x8FF7, 0x352C,
            0x34C3, 0x891A, 0x60E3, 0x0710, 0xA400, 0x4480, 0x50FB, 0xD27E,
            0x4000, 0x3748, 0x307C, 0xA010, 0x0215, 0x4C15, 0x8B0D, 0x52FB,
            0x66C3, 0xD479, 0x4200, 0x0710, 0xA400, 0x324C, 0x327C, 0xE7FA,
            0x4610, 0x4718, 0x2211, 0x8FFA, 0x327C, 0x5BFA, 0xE00C,
        ],
        start=3,            # `shll r5`, after the height clamp
        end=77,             # up to `mov.l @(40,r15),r11`
        # mov.l @(44,r15),r4; mov r12,r6; mov r8,r7 (r5 is already the index)
        args=[0x54FB, 0x66C3, 0x6783],
        literal=True,
    ),
    # The colour-preview strip renderer's per-column record decode (r5 = the
    # record, r8 = the column, r6 = -4): the two heights read from record
    # bytes 4-5, up to the `tst r2,r2` that tests the first. The hook decodes
    # the same way and returns, or paints a 3-band record and returns r2 = 0,
    # which sends the renderer to the end of the column.
    'wave3ov': Mod(
        what='3-band overview strip',
        target='gui',
        fw_versions=('1.81',),
        sig=[
            0xE006, 0x6583, 0x4580, 0xD421, 0xE6FC, 0x354C, 0x3751, 0x8004,
            0x3051, 0x9002, 0x4709, 0x406D, 0x627C, 0xC93F, 0x2228, 0x8F02,
        ],
        start=6,            # `movu.b @(4,r5),r7`
        end=14,             # up to `tst r2,r2`
        args=[],
        literal=False,
    ),
    # The colour-preview overview strip's per-column loop-bottom merge point:
    # every fill style the renderer can take for one column rejoins here,
    # right before the column counter is bumped (r8 = the just-finished
    # column, 0..599). Hooking here instead of the colour lookup means the
    # waveform's own fill is already painted before this call runs, so
    # gui_phrase.s draws its band on top rather than the fill overwriting it,
    # and the waveform's own colours are never touched by this mod at all.
    #
    # sig carries 9 words of context before the replaced pair and 2 after
    # (neither replaced) purely so this site matches uniquely; the two
    # replaced words are sig[9] (the counter load) and sig[10] (the column
    # increment). gui_phrase.s reproduces both, then the branch they lead
    # into, itself -- see that file for why (sigpatch's own auto-resume can
    # only express one target, and this merge point has two).
    # Browse rows' right-hand text (mods/rowwave): placed only; the rowmeta
    # redirect below points the list redraw's number-column call at it.
    'rowmeta': Mod(
        what='Browse rows: file type, BPM, key, duration at the right end (rowwave)',
        target='gui',
        fw_versions=('1.81',),
        sig=(),
        start=0,
        end=0,
        args=[],
        literal=False,
        hook=False,
    ),
    # The "B - 3000X moderno" redesign, first slice (mods/ui3000x,
    # re/UI3000X.md): the title bars, row stripes and list cursors recoloured
    # in the unpacked art, once, before the first frame. Placed only; the
    # ui3000x redirect below points the UI loop's draw call at it.
    'ui3000x': Mod(
        what='3000X look, first slice: dark title bars and rows, cyan list cursor (art recoloured in RAM)',
        target='gui',
        fw_versions=('1.81',),
        sig=(),
        start=0,
        end=0,
        args=[],
        literal=False,
        hook=False,
    ),
    # fpsboost (mods/fpsboost, re/FPS_SAFE.md): the DMA fill of a widget
    # background that the previous rect fill already covered with the same
    # colour is skipped (top surface 441,600 B, bottom 297,600 B a frame).
    # Placed only; the fpsboost redirects below point the fill, the rect fill
    # and the CPU blit at its three entry points.
    'gr3direct': Mod(
        what='gr3direct: fpsboost + the two big player windows drawn straight into the GR3 back buffer (no surface copies)',
        target='gui',
        fw_versions=('1.81',),
        sig=(),
        start=0,
        end=0,
        args=[],
        literal=False,
        hook=False,
    ),
    'gr3direct3k': Mod(
        what='gr3direct + marqueefix in one DMA-fill hook (used for gr3direct when ui3000x is on)',
        target='gui',
        fw_versions=('1.81',),
        sig=(),
        start=0,
        end=0,
        args=[],
        literal=False,
        hook=False,
    ),
    'fpsboost': Mod(
        what='fpsboost: skip the DMA background fills a frame repeats (same colour, same rows)',
        target='gui',
        fw_versions=('1.81',),
        sig=(),
        start=0,
        end=0,
        args=[],
        literal=False,
        hook=False,
    ),
    # ui3000x_wavergb (opt-in, TEST, re/UI3000X.md): the default centre
    # waveform is filled in code, one RGB565 colour per column built from the
    # peak sample word's own R/G/B energy fields (not the 3-band palette
    # table). This hooks the very span the three_band `wave3` mod hooks -- the
    # column's colour build plus its fill -- and rebuilds the colour as a
    # squared-energy blend of the CDJ-3000X / canvas palette (low #005AFF, mid
    # #FFA028, high #EBF5FF) instead of the stock additive-RGB expansion. Same
    # sig/args/literal as wave3; never select both (one span, one hook).
    'ui3000x_wavergb': Mod(
        what='centre waveform: additive RGB -> 3000X/canvas palette (test)',
        target='gui',
        fw_versions=('1.81',),
        sig=[
            0x2CC8, 0x8B00, 0xEC01, 0x4500, 0xEB07, 0x6053, 0x058D, 0x0A00,
            0xE000, 0x4B18, 0x605D, 0xE9FB, 0x6103, 0xE400, 0x4121, 0x4121,
            0x21B9, 0x6603, 0x26A9, 0x409C, 0x67C3, 0x77FF, 0x316C, 0xC91C,
            0x3C77, 0x8F22, 0x310C, 0x4715, 0x8B12, 0x56FB, 0xD28A, 0x4600,
            0x0510, 0x9E00, 0x0910, 0xA400, 0x362C, 0x356C, 0x369C, 0x7402,
            0xE2F4, 0x4218, 0x3473, 0x2611, 0x362C, 0x2511, 0x8FF7, 0x352C,
            0x34C3, 0x891A, 0x60E3, 0x0710, 0xA400, 0x4480, 0x50FB, 0xD27E,
            0x4000, 0x3748, 0x307C, 0xA010, 0x0215, 0x4C15, 0x8B0D, 0x52FB,
            0x66C3, 0xD479, 0x4200, 0x0710, 0xA400, 0x324C, 0x327C, 0xE7FA,
            0x4610, 0x4718, 0x2211, 0x8FFA, 0x327C, 0x5BFA, 0xE00C,
        ],
        start=3,
        end=77,
        args=[0x54FB, 0x66C3, 0x6783],   # mov.l @(44,r15),r4; mov r12,r6; mov r8,r7
        literal=True,
    ),
    'phrase': Mod(
        what='overview strip phrase band',
        target='gui',
        fw_versions=('1.81',),
        sig=[
            0xE627, 0x60F2, 0x3658, 0x59F1, 0x4680, 0x4600, 0x36BC, 0x369C,
            0x2611, 0x52F2, 0x7801, 0x72FF, 0x2228, 0x8D02, 0x1F22, 0xAECE,
            0x0009, 0xDB34, 0x6DB3,
        ],
        start=9,
        end=17,
        args=[],
        literal=False,
    ),
    # marqueefix (mods/marqueefix): placed only; the redirect below points the
    # DMA fill's literal here so a 0xDEFC (stock selection) fill of a scrolling
    # browse title's background becomes the 3000 navy 0x19CD.
    'marqueefix': Mod(
        what='browse marquee: scrolling long-title background 0xDEFC -> 3000 navy',
        target='gui',
        fw_versions=('1.81',),
        sig=(),
        start=0,
        end=0,
        args=[],
        literal=False,
        hook=False,
    ),
    'bootname': Mod(
        what='Boot screen: "Cueline" under "Ver" (a 9th text widget)',
        target='gui',
        fw_versions=('1.81',),
        sig=(),
        start=0,
        end=0,
        args=[],
        literal=False,
        hook=False,
    ),
    # W8 (mods/w8fetch, opt-in): the message dispatcher (0x0E50112C) right
    # after it copies the 8-byte header to 0x0F682190 (the span loads the
    # header's word index, sets up and makes the memcpy call); the hook keeps
    # message 0x31 (the tempo master's PWV5 from MAIN's w8send) in free SDRAM
    # at 0x0CA00000. The span is entered by a branch at its first halfword.
    'w8recv': Mod(
        what='W8: message 0x31 (the tempo master\'s detail waveform) kept at 0x0CA00000',
        target='gui',
        fw_versions=('1.81',),
        sig=[0xAFFE, 0x0009, 0xD20C, 0x6122, 0x65E3, 0xE608, 0x64D3, 0x4108,
             0xE839, 0x490B, 0x351C, 0xD717],
        start=2,
        end=11,
        args=[],
        literal=False,
        hook=True,
    ),
}
MODS['wave3rgb'] = MODS['wave3']._replace(
    what='3-band centre waveform; CDJ-3000 RGB colour for tracks without 3-band data (wave3 + wavergb)')


def source(name):
    """Each routine sits in its own mod's folder, mods/<mod>/."""
    return glob.glob(os.path.join(HERE, '*', 'gui_%s.s' % name))[0]


def blob_path(name):
    return source(name)[:-2] + '.bin'


# Mods kept out of the shared segment's layout unless named: sigpatch sizes
# the segment for every routine of the set it is given, so a routine added
# to MODS would otherwise move or grow every existing build's bytes.
OPT_IN = ('ui3000x', 'fpsboost', 'gr3direct', 'gr3direct3k', 'ui3000x_wavergb',
          'bootname', 'wave3rgb', 'w8recv')


def _layout_set(names):
    return {n: m for n, m in MODS.items() if n not in OPT_IN or n in names}


def patch(data, names, placed=None):
    mods = _layout_set(names)
    return sigpatch.patch(GUI_PROFILE, blob_path, data, mods, names, tag='patch_gui',
                          placed=placed)


def _assemble(name, tmp, out):
    obj = os.path.join(tmp, name + '.o')
    subprocess.run(['sh4-linux-gnu-as', '--isa=sh2a', '-big', '-I', os.path.dirname(os.path.dirname(source(name)))]
                   + ['-o', obj, source(name)], check=True)
    subprocess.run(['sh4-linux-gnu-objcopy', '-O', 'binary', obj, out], check=True)


def assemble():
    with tempfile.TemporaryDirectory() as tmp:
        for name in MODS:
            _assemble(name, tmp, blob_path(name))
            print('patch_gui: wrote %s (%d bytes)'
                  % (blob_path(name), os.path.getsize(blob_path(name))))


def check():
    """Every committed .bin is what its .s assembles to now: a .s edited
    without --assemble would otherwise ship its old routine."""
    stale = []
    with tempfile.TemporaryDirectory() as tmp:
        for name in MODS:
            out = os.path.join(tmp, name + '.bin')
            _assemble(name, tmp, out)
            with open(out, 'rb') as f, open(blob_path(name), 'rb') as g:
                same = f.read() == g.read()
            print('patch_gui: %s %s' % (os.path.basename(blob_path(name)),
                                        'matches its .s' if same else 'is STALE'))
            if not same:
                stale.append(name)
    if stale:
        raise SystemExit('patch_gui: rebuild with patch_gui.py --assemble: %s' % ' '.join(stale))


# In-place pokes: halfwords changed where they are (a code immediate or a
# data table entry), each given by its run-time address and checked against
# its stock value first, so a different image is refused rather than broken.
# Selected like MODS (CDJ_GUI_<NAME>=1); applied after the code mods.
POKES = {
    # The browse rows' artwork cell becomes 112x20 (same 0x1180 bytes as the
    # stock 80x28) for the row waveform of mods/rowwave: the cell descriptors'
    # init code (0x0E51F320..), table C's two artwork layouts (C6/C7: icon
    # x, title x0), which move the icon and the title 32 px right, and table
    # B's cursor x0 for those layouts, so the highlight starts after the cell.
    'rowcell': dict(
        what='Browse rows: 112x20 artwork cell for the row waveform (rowwave)',
        fw_versions=('1.81',),
        pokes=[
            (0x0E51F332, 0xE750, 0xE770),   # mov #80,r7 -> #112: width = stride
            (0x0E51F334, 0xED1C, 0xED14),   # mov #28,r13 -> #20: height
            (0x0E51F32E, 0xE42F, 0xE433),   # mov #47,r4 -> #51: row 1 y (centred)
            (0x0E51F32C, 0xE14D, 0xE151),   # mov #77,r1 -> #81: row 2 y
            (0x0E59FF08, 0x0063, 0x0083),   # C6 icon x 99 -> 131
            (0x0E59FF0A, 0x0081, 0x00A1),   # C6 title x0 129 -> 161
            (0x0E59FF24, 0x0063, 0x0083),   # C7 icon x 99 -> 131
            (0x0E59FF26, 0x0081, 0x00A1),   # C7 title x0 129 -> 161
            (0x0E5A0FA8, 0x0062, 0x000C),   # table B[3] (C7) cursor x0 98 -> 12 (whole row)
            (0x0E5A0FC0, 0x0062, 0x000C),   # table B[4] (C6) cursor x0 98 -> 12 (whole row)
        ],
    ),
}


# Literal redirects: a 32-bit literal (a call target) changed from its stock
# value to a placed routine of MODS. {mod name: [(literal address, stock)]}
# or (literal address, stock, offset of the entry point within the routine).
REDIRECTS = {
    'rowmeta': [(0x0E5208D0, 0x0E51E67A)],   # the list redraw's FUN_0e51e67a
    'ui3000x': [(0x1C001528, 0x1C002CE6)],   # the UI loop's draw (0x1C001494 loads it)
    # (literal, stock, offset into the routine): fpsboost's three entries
    'fpsboost': [(0x0E508FD4, 0x0E510368, 0),     # DMA fill, from the rect fill
                 (0x0E50D534, 0x0E510368, 0),     # DMA fill, 0x0E50D348
                 (0x0E50A838, 0x0E508E1E, 4),     # rect fill, six pools
                 (0x0E50AB50, 0x0E508E1E, 4),
                 (0x0E50D7C0, 0x0E508E1E, 4),
                 (0x0E50DA88, 0x0E508E1E, 4),
                 (0x0E50E6A8, 0x0E508E1E, 4),
                 (0x0E50EC0C, 0x0E508E1E, 4),
                 (0x0E50ADB8, 0x0E509244, 8)],    # CPU blit
    # gr3direct: fpsboost's entries plus the flush's surface->GR3 copy helper
    'gr3direct': [(0x0E508FD4, 0x0E510368, 0), (0x0E50D534, 0x0E510368, 0),
                  (0x0E50A838, 0x0E508E1E, 4), (0x0E50AB50, 0x0E508E1E, 4),
                  (0x0E50D7C0, 0x0E508E1E, 4), (0x0E50DA88, 0x0E508E1E, 4),
                  (0x0E50E6A8, 0x0E508E1E, 4), (0x0E50EC0C, 0x0E508E1E, 4),
                  (0x0E50ADB8, 0x0E509244, 8),
                  (0x0E508FCC, 0x0E50FFDC, 12),   # copy helper (0x0E508DDC's literal)
                  (0x0E509230, 0x0E52EA70, 16),   # the flip's sleep: VDC base before the vsync wait
                  (0x1C001240, 0x0E50D16C, 20),   # the draw-callback dispatcher (RAM API slot)
                  (0x0E508D08, 0x0E508A34, 24),   # the vsync callback (registered at display init)
                  (0x0E50923C, 0x0E526626, 28),   # the flip's VDC base write
                  (0x0E508D1C, 0x0E526626, 28)],  # the display init's VDC base write
    # marqueefix: the DMA fill's literal at the fill helper's DMA path
    # (0x0E508EB0 loads it; the scrolling-title background fill goes through it).
    'marqueefix': [(0x0E508FD4, 0x0E510368)],
    # bootname: the boot screen's child table, type table and step-4 handler
    'bootname': [(0x0E526B74, 0x0E5B70C0, 0x40), (0x0E526B78, 0x0E5B70AC, 0x68),
                 (0x0E524C60, 0x1C00293E, 0)],
}
REDIRECTS['gr3direct3k'] = REDIRECTS['gr3direct']
# Words inside a placed routine that must hold an address inside the same
# routine (data the firmware reads: a table of pointers); written once the
# routine's address is known: (offset of the word, offset it points at).
SELFRELOC = {
    'bootname': [(0x50, 0x80)],   # child table entry 4 -> the descriptor
}
# Pokes that go with a redirect mod.
POKES['bootname'] = dict(
    what='Boot screen: 9 children instead of 8 (bootname)',
    fw_versions=('1.81',),
    pokes=[
        (0x0E526A56, 0xE008, 0xE009),   # mov #8,r0 -> #9 (the build at 0x0E526A50)
        (0x0E526A7C, 0xE008, 0xE009),   # mov #8,r0 -> #9 (the build at 0x0E526A70)
    ],
)
POKES['rowmetac'] = dict(
    what='Browse rows: number column on and title narrowed in layout C7 (rowmeta)',
    fw_versions=('1.81',),
    pokes=[
        (0x0E59FF16, 0x0000, 0x0001),   # C7 +4: number column on
        (0x0E59FF28, 0x02BC, 0x01F4),   # C7 title x1 700 -> 500
    ],
)

# ui3000x's text: the only neutral dark-ink text style is style 1 (the font
# style palette at 0x0E5958D4 + 16*1; GUI_FONTS.md s5), which the firmware
# uses for the highlighted browse row, the selected UTILITY name and the INFO
# panel labels/values -- all of them black ink, meant for a light background.
# ui3000x paints those backgrounds dark (cyan cursor, dark INFO panel), so the
# ink must go light. Each level is 00RRGGBB; this makes it a cool light ramp
# (edge #90A4B0, mid #C8D4DC, ink #FFFFFF) that reads on both the cyan cursor
# and the dark panel. Auto-applied whenever the ui3000x mod is named (like
# rowmetac with rowmeta). Part of the "B" look; see re/UI3000X.md.
POKES['ui3000xtext'] = dict(
    what='Selected-row / INFO text: font style 1 dark ink -> a light ramp (white)',
    fw_versions=('1.81',),
    pokes=[
        (0x0E5958E8, 0x00B5, 0x0090),   # c1 (faint edge) #B5B6BD -> #90A4B0
        (0x0E5958EA, 0xB6BD, 0xA4B0),
        (0x0E5958EC, 0x005A, 0x00C8),   # c2 (mid)        #5A595A -> #C8D4DC
        (0x0E5958EE, 0x595A, 0xD4DC),
        (0x0E5958F0, 0x0000, 0x00FF),   # c3 (solid ink)  #000000 -> #FFFFFF
        (0x0E5958F2, 0x0000, 0xFFFF),
        # style 3 (0x0E595904): the dimmed text style the firmware switches the
        # selected UTILITY row to WHILE A TRACK PLAYS (name #FFFFFF->#9C9A9C,
        # the "dim the menu during playback" state). On the stock light cursor
        # that grey read; on the 3000 navy it looks washed. Same light ramp as
        # style 1 so the selected row stays legible playing or paused.
        (0x0E595908, 0x00C6, 0x0090),   # c1 (edge) #C6C7CE -> #90A4B0
        (0x0E59590A, 0xC7CE, 0xA4B0),
        (0x0E59590C, 0x00AD, 0x00C8),   # c2 (mid)  #ADAEB5 -> #C8D4DC
        (0x0E59590E, 0xAEB5, 0xD4DC),
        (0x0E595910, 0x009C, 0x00FF),   # c3 (ink)  #9C9A9C -> #FFFFFF
        (0x0E595912, 0x9A9C, 0xFFFF),
    ],
)

# framefloor (re: high_fps / sh7269gui.c gui_frame_sigs): the display's UI task
# draws a frame and, if that took less than its 15 ms floor, sleeps out the
# rest -- a `mov #15,r9` at 0x1C00148C (the compare) and a `mov #15,r4` at
# 0x1C0014C8 (the sleep), which must agree. Lower both to 8 ms so a fast frame
# is allowed to repaint sooner: zoomed fully in, the centre waveform then
# scrolls in ~2x as many steps (smoother). It only helps where the draw
# finishes under the floor (a slow frame just runs long); costs some CPU. The
# emulator does this live via CDJ_GUI_FRAME_MS (=6); as a .UPD poke it reaches
# the real deck, whose own pacing decides how much it gains -- verify on HW.
#
# Animations that step once per frame speed up with the lower floor. The browse
# long-title marquee moves 3 px a frame (add #-3,r1 at 0x0E51FF6E), which at
# 8 ms scrolls almost twice as fast; cut its step to 2 px so its on-screen pace
# stays close to the stock 3 px / 15 ms. (The emulator compensates the same
# step via CDJ_TIMED_ADD; this does it in the image, and only with the floor.)
POKES['framefloor'] = dict(
    what='Display frame floor 15 ms -> 8 ms (zoomed waveform redraws ~2x; CPU cost; verify on HW)',
    fw_versions=('1.81',),
    pokes=[
        (0x1C00148C, 0xE90F, 0xE908),   # compare: mov #15,r9 -> mov #8,r9
        (0x1C0014C8, 0xE40F, 0xE408),   # sleep:   mov #15,r4 -> mov #8,r4
        (0x0E51FF6E, 0x71FD, 0x71FE),   # marquee: add #-3,r1 -> add #-2,r1 (keep pace at 8 ms)
    ],
)

# utiltint's tint colours (mods/utiltint): the font-style palette at 0x0E5958D4
# is indexed 2*style, so "ours" (index 2) is entry 4 and "other" (index 11) is
# entry 22. The base's entry-4 green is a neon #00FF00 that reads harsh over the
# 3000 navy selection cursor; the stock deck draws a played-track row the same
# way (coloured text over the selection) but with a calmer medium green that
# reads cleanly on it. Recolour entry 4 to that medium green and entry 22 to a
# matching medium violet (more red, so it is not lost in the blue cursor),
# keeping the green/violet identity on the black row too. Each entry is four
# 00RRGGBB levels (edge, mid, ink); level 0 stays 0. Auto-applied with ui3000x.
POKES['utiltintpal'] = dict(
    what='UTILITY origin tints (styles 2/11): medium green/violet that read on the navy cursor',
    fw_versions=('1.81',),
    pokes=[
        (0x0E595918, 0x0010, 0x0010),   # ours  edge #104910 -> #103A10
        (0x0E59591A, 0x4910, 0x3A10),
        (0x0E59591C, 0x0008, 0x002E),   # ours  mid  #08BA08 -> #2E8E2E
        (0x0E59591E, 0xBA08, 0x8E2E),
        (0x0E595920, 0x0000, 0x0000),   # ours  ink  #00FF00 -> #00A800 (medium green)
        (0x0E595922, 0xFF00, 0xA800),
        (0x0E595A38, 0x004A, 0x0028),   # other edge #4A1873 -> #281042
        (0x0E595A3A, 0x1873, 0x1042),
        (0x0E595A3C, 0x0084, 0x006A),   # other mid  #840CD6 -> #6A3092
        (0x0E595A3E, 0x0CD6, 0x3092),
        (0x0E595A40, 0x009C, 0x00AA),   # other ink  #9C08FF -> #AA50E0 (medium violet)
        (0x0E595A42, 0x08FF, 0x50E0),
        # Each style has a selected-row variant at index+1 with a LIGHT-edge AA
        # ramp, made for the stock light cursor; on the 3000 navy cursor that
        # light edge reads as white fringing on the tinted label. Give the
        # selected variants (entry 5 green, entry 23 violet) the same dark-edge
        # ramp as their normal entry, so a selected tint has no white halo.
        (0x0E595928, 0x00AD, 0x0010),   # ours  sel edge #ADCBAD -> #103A10
        (0x0E59592A, 0xCBAD, 0x3A10),
        (0x0E59592C, 0x0042, 0x002E),   # ours  sel mid  #429E42 -> #2E8E2E
        (0x0E59592E, 0x9E42, 0x8E2E),
        (0x0E595930, 0x0000, 0x0000),   # ours  sel ink  #008200 -> #00A800
        (0x0E595932, 0x8200, 0xA800),
        (0x0E595A48, 0x00DE, 0x0028),   # other sel edge #DEBAF7 -> #281042
        (0x0E595A4A, 0xBAF7, 0x1042),
        (0x0E595A4C, 0x00BD, 0x006A),   # other sel mid  #BD5DFF -> #6A3092
        (0x0E595A4E, 0x5DFF, 0x3092),
        (0x0E595A50, 0x009C, 0x00AA),   # other sel ink  #9C08FF -> #AA50E0
        (0x0E595A52, 0x08FF, 0x50E0),
    ],
)


def apply_selfrelocs(data, names, placed):
    img = sigpatch.Image(GUI_PROFILE, data)
    for name in names:
        for at, target in SELFRELOC[name]:
            off = img.off_of(placed[name] + at)
            if img.u32(off) != 0:
                raise SystemExit('patch_gui: %s: word at +%#x holds %#x, not 0' % (name, at, img.u32(off)))
            img.d[off:off + 4] = (placed[name] + target).to_bytes(4, 'big')
    return bytes(img.d)


def apply_redirects(data, names, placed):
    img = sigpatch.Image(GUI_PROFILE, data)
    for name in names:
        for addr, old, *entry in REDIRECTS[name]:
            target = placed[name] + (entry[0] if entry else 0)
            off = img.off_of(addr)
            if img.u32(off) != old:
                raise SystemExit('patch_gui: %s: literal %#x holds %#x, not %#x'
                                 % (name, addr, img.u32(off), old))
            img.d[off:off + 4] = target.to_bytes(4, 'big')
            print('patch_gui: %s at %#x, called through the literal at %#x'
                  % (MODS[name].what, target, addr))
    return bytes(img.d)


def patch_all(data, names):
    """Everything a name list asks for, in the one order both the emulator's
    launcher (main() below) and patch_update.py use: the code MODS (one
    sigpatch placement), then their literal REDIRECTS, then the POKES -- with
    rowmeta's own pokes (rowmetac) added whenever rowmeta is on."""
    mods = [n for n in names if n in MODS]
    # With ui3000x the true 3-band centre waveform keeps the CDJ-3000 look for
    # tracks without 3-band data too: wave3rgb (wave3 + ui3000x_wavergb's
    # colour in place of the stock additive red).
    if 'ui3000x' in mods and 'wave3' in mods:
        mods = ['wave3rgb' if n == 'wave3' else n for n in mods]
    # ui3000x ships the CDJ-3000 central waveform by default: ui3000x_wavergb
    # recolours the centre scrolling wave from the stock additive red to the
    # 3000X blue/amber/white RGB look. It hooks the same span as the three_band
    # 'wave3' mod (never both) and must never run alongside fpsboost, which
    # blanks the centre -- so add it only when neither is present.
    if ('ui3000x' in mods and 'ui3000x_wavergb' not in mods
            and not {'wave3', 'wave3rgb'} & set(mods) and 'fpsboost' not in mods):
        mods.append('ui3000x_wavergb')
    # marqueefix turns the scrolling-title background navy; it fixes a
    # ui3000x-only artefact (the static cursor is navy but the marquee fill is
    # the stock light 0xDEFC), so it rides with ui3000x. Not with fpsboost,
    # which redirects the same DMA-fill literal.
    # gr3direct also owns that literal: with ui3000x it is built with the
    # marquee recolour inside its own fill hook (gr3direct3k) instead.
    if 'ui3000x' in mods and 'gr3direct' in mods:
        mods = ['gr3direct3k' if n == 'gr3direct' else n for n in mods]
    if ('ui3000x' in mods and 'marqueefix' not in mods
            and not {'fpsboost', 'gr3direct', 'gr3direct3k'} & set(mods)):
        mods.append('marqueefix')
    placed = {}
    out = patch(data, mods, placed) if mods else data
    out = apply_selfrelocs(out, [n for n in mods if n in SELFRELOC], placed)
    out = apply_redirects(out, [n for n in mods if n in REDIRECTS], placed)
    pokes = [n for n in names if n in POKES]
    if 'rowmeta' in mods and 'rowmetac' not in pokes:
        pokes.append('rowmetac')
    if 'ui3000x' in mods and 'ui3000xtext' not in pokes:
        pokes.append('ui3000xtext')
    if 'ui3000x' in mods and 'utiltintpal' not in pokes:
        pokes.append('utiltintpal')
    return apply_pokes(out, pokes)


# The GUI image's own integrity trailer (stock): at file offset 0x14FFFA a
# big-endian CRC-16/XMODEM of image[0:end], then end as a big-endian u32 at
# 0x14FFFC (stock: CRC 0x0F97 over 0x000F9448 bytes). Treat it as checked
# (most likely by the GUI bootloader, which the emulator bypasses): every change of ours must refresh it,
# and end must cover what we place in the erased area after the code.
TRAILER_CRC, TRAILER_END = 0x14FFFA, 0x14FFFC


def _table_end(img):
    """End (image offset) of the last flash->RAM copy in the bootloader's
    load table: a chain of 0x30-byte descriptors from the BE32 at 0x4, each
    with three [RAM dest][flash src][size] copies, one [dest][size] zero
    fill and a next pointer (scripts/firmware/gui_bootcheck.py)."""
    end, p, seen = 0, int.from_bytes(img[4:8], 'big'), set()
    while p and p not in seen and 0x30010 <= p < 0x30100:
        seen.add(p)
        w = [int.from_bytes(img[p - 0x30000 + 4 * i:p - 0x30000 + 4 * i + 4], 'big') for i in range(12)]
        for dest, src, size in (w[0:3], w[3:6], w[6:9]):
            if size and 0x30000 <= src < 0x30000 + TRAILER_CRC:
                end = max(end, src - 0x30000 + size)
        p = w[11]
    return end


def _cover_end(img):
    """The end the trailer must carry: as stock does, it reaches the
    last byte the load table copies and anything non-erased before it."""
    end = int.from_bytes(img[TRAILER_END:TRAILER_END + 4], 'big')
    last = TRAILER_CRC - 1
    while last >= end and img[last] == 0xFF:
        last -= 1
    return max(end, last + 1, _table_end(img))


def fix_trailer(data):
    """The image with its trailer recomputed: end grows to cover the load
    table's last copied byte and the last non-erased byte before the
    trailer, the CRC covers image[0:end]."""
    from gui_encode import crc16_xmodem
    if len(data) < TRAILER_END + 4:      # no trailer (synthetic test images)
        return data
    img = bytearray(data)
    end = _cover_end(img)
    img[TRAILER_END:TRAILER_END + 4] = end.to_bytes(4, 'big')
    img[TRAILER_CRC:TRAILER_CRC + 2] = crc16_xmodem(bytes(img[:end])).to_bytes(2, 'big')
    return bytes(img)


def trailer_ok(data):
    from gui_encode import crc16_xmodem
    if len(data) < TRAILER_END + 4:
        return False
    end = int.from_bytes(data[TRAILER_END:TRAILER_END + 4], 'big')
    return (_cover_end(data) == end and int.from_bytes(data[TRAILER_CRC:TRAILER_CRC + 2], 'big')
            == crc16_xmodem(bytes(data[:end])))


def apply_pokes(data, names):
    img = sigpatch.Image(GUI_PROFILE, data)
    for name in names:
        for addr, old, new in POKES[name]['pokes']:
            off = img.off_of(addr)
            if img.u16(off) != old:
                raise SystemExit('patch_gui: %s: %#x holds %#06x, not %#06x'
                                 % (name, addr, img.u16(off), old))
            img.d[off:off + 2] = new.to_bytes(2, 'big')
        print('patch_gui: %s: %d halfwords' % (POKES[name]['what'], len(POKES[name]['pokes'])))
    return bytes(img.d)


def main():
    args = sys.argv[1:]
    if args == ['--assemble']:
        assemble()
        return
    if args == ['--check']:
        check()
        return
    if args == ['--list']:
        for name, mod in MODS.items():
            print('%-8s %s' % (name, mod.what))
        for name, poke in POKES.items():
            print('%-8s %s' % (name, poke['what']))
        return
    if len(args) < 3 or any(n not in MODS and n not in POKES for n in args[2:]):
        raise SystemExit(__doc__)
    with open(args[0], 'rb') as f:
        data = f.read()
    out = patch_all(data, args[2:])
    with open(args[1], 'wb') as f:
        f.write(out)


if __name__ == '__main__':
    main()
