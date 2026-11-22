#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Place the V2 UI renderer (v2ui.bin, built by build.sh) into a GUI image.

The blob is linked at a fixed on-chip address (V2_BASE). It gets its own load
record: copied from erased flash right after the last loaded segment (where
sigpatch's segment for the other GUI mods also goes, so this runs after
patch_gui.patch_all). Then its entry (the first word of the blob) is chained in
front of the VDC base write 0x0E526626:
  - stock flip: the literals 0x0E50923C (flip) and 0x0E508D1C (display init),
    when they still hold 0x0E526626, point at the entry;
  - gr3direct / gr3direct3k: those literals already point at its wrapper,
    whose own literal l_vdcset (0x0E526626) is retargeted at the entry.
The entry paints and then jumps on to 0x0E526626, so the chain is unchanged
otherwise. patch_gui.fix_trailer (run by patch_update) covers the new record.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import sigpatch        # noqa: E402
import patch_gui       # noqa: E402

WHAT = 'V2 UI: our own CDJ-3000-style player screen renderer (re/V2_P1P2.md)'
V2_BASE = 0x1C050000
V2_END = 0x1C070000                 # rowmeta's curbar copy starts here (gui_rowmeta.s)
BLOB = os.path.join(HERE, 'v2ui.bin')
BLOB_RO = os.path.join(HERE, 'v2ui_ro.bin')
V2_RO = 0x0C700000                  # SDRAM, read-only image (fonts, icon atlas)
RO_FREE = (0x0C680100, 0x0CD00000)  # untouched by the stock GUI: boot + full tour, write-watch (re/V2_P4.md)
VDCSET = 0x0E526626
VDC_LITS = (0x0E50923C, 0x0E508D1C)
DRAW_SLOT = 0x1C001240              # the draw-callback dispatcher's RAM API slot
CLEAR_LIT = 0x0E50AB50              # the per-frame clear 0x0E50AAD0's rect-fill literal
BLIT_LIT = 0x0E50ADB8               # the CPU image blit 0x0E509244's literal (r4 = surface descriptor)
TEXT_SLOTS = (0x1C0008D0, 0x1C0008E0)
FLIP_SLEEP_LIT = 0x0E509230         # the stock flip's sleep(ms) literal (vsync wait; P9 early present)
SLEEP = 0x0E52EA70   # the text renderers 0x0E50B6E8 / 0x0E50C9BC (r4 = window)
WAVE_LIT = 0x1C00B268               # the frame's direct call of the centre-waveform renderer 0x1C009AB4
# F2 the compose gate: the flush's window loop tests "composited" (+7 bit 3) here and composes the window.
# These 12 bytes (bld.b #3,@(7,r14) ; bf.s ; mov #0,r13 ; mov.l @(28,r14),r10 ; mov r14,r11) become a jump to
# entry +32 (entry.S comp_e), which asks v2_compose_hide() at the moment of composing.
COMP_AT = 0x0E509A1C
COMP_STOCK = bytes.fromhex('3e3930078f42ed005ae76be3')
COMP_ENTRY = 32


def apply(data, blob_path=BLOB):
    blob = open(blob_path, 'rb').read()
    if not blob or V2_BASE + len(blob) > V2_END:
        raise SystemExit('v2ui: blob of %d bytes does not fit %#x..%#x' % (len(blob), V2_BASE, V2_END))
    p = patch_gui.GUI_PROFILE
    img = sigpatch.Image(p, data)
    for _, dest, _, size in img.copies():
        if dest < V2_BASE + len(blob) and V2_BASE < dest + size:
            raise SystemExit('v2ui: %#x..%#x is already loaded (%#x+%#x)'
                             % (V2_BASE, V2_BASE + len(blob), dest, size))
    ram = [c for c in img.copies() if p.ram_base <= c[1] < p.ram_end]
    src = (max(c[2] + c[3] for c in ram) + 15) & ~15
    if any(b != 0xFF for b in img.d[src:src + len(blob)]):
        raise SystemExit('v2ui: no erased flash after the on-chip RAM segments')
    if src + len(blob) > patch_gui.TRAILER_CRC:
        raise SystemExit('v2ui: the blob would run into the image trailer')
    free = [i for i, r in enumerate(img.recs) if i % 4 != 3 and r[2] == 0]
    if not free:
        raise SystemExit('v2ui: no free load-table record')
    rec = free[0]
    ro = open(BLOB_RO, 'rb').read() if os.path.exists(BLOB_RO) else b''
    if ro:
        if not (RO_FREE[0] <= V2_RO and V2_RO + len(ro) <= RO_FREE[1]):
            raise SystemExit('v2ui: read-only image %#x+%#x outside the proven-free SDRAM range' % (V2_RO, len(ro)))
        if ro[-4:] != struct.pack('>I', 0x56325230):
            raise SystemExit('v2ui: read-only image has no V2R0 end marker')
        for _, dest, _, size in img.copies():
            if dest < V2_RO + len(ro) and V2_RO < dest + size:
                raise SystemExit('v2ui: %#x+%#x is already loaded' % (V2_RO, len(ro)))
        rsum = sum(struct.unpack('>%dI' % ((len(ro) - 4) // 4), ro[:len(ro) - 4])) & 0xFFFFFFFF
        mk = blob.find(struct.pack('>I', 0x56325253))           # "V2RS"
        if mk < 0 or mk % 4 or blob.find(struct.pack('>I', 0x56325253), mk + 4) >= 0:
            raise SystemExit('v2ui: no unique V2RS marker in the blob')
        # the read-only image goes FIRST, the blob (the last copied range) after it: the trailer's end
        # then still equals the last copied byte, as in stock (gui_bootcheck I5)
        rsrc = src
        src = (rsrc + len(ro) + 15) & ~15
        if any(b != 0xFF for b in img.d[rsrc:src + len(blob)]) or src + len(blob) > patch_gui.TRAILER_CRC:
            raise SystemExit('v2ui: no erased flash for the read-only image + blob')
        blob = (blob[:mk + 4] + struct.pack('>III', rsum, rsrc + p.flash_base, len(ro))
                + blob[mk + 16:])
    img.d[src:src + len(blob)] = blob
    struct.pack_into(p.byteorder + 'III', img.d, p.loadtab_off + 12 * rec,
                     V2_BASE, src + p.flash_base, len(blob))
    print('v2ui: %d bytes at %#x from flash +%#x (load record %d)' % (len(blob), V2_BASE, src, rec))
    if ro:
        # no load record: the renderer copies it from the memory-mapped flash at its first paint
        img.d[rsrc:rsrc + len(ro)] = ro
        print('v2ui: read-only %d bytes in flash +%#x (CPU %#x), copied to %#x by the renderer (sum %#010x)'
              % (len(ro), rsrc, rsrc + p.flash_base, V2_RO, rsum))
    chained = set()
    for lit in VDC_LITS:
        off = img.off_of(lit)
        v = img.u32(off)
        if v == VDCSET:
            struct.pack_into('>I', img.d, off, V2_BASE)
            print('v2ui: VDC base write literal %#x -> %#x' % (lit, V2_BASE))
            continue
        # a wrapper (gr3direct): its own literal to the stock write
        if v in chained:
            continue
        woff = img.off_of(v & ~3, required=False)
        if woff is None:
            raise SystemExit('v2ui: literal %#x holds %#x, not a known chain' % (lit, v))
        start = woff - 0x40 & ~3
        hits = [o for o in range(start, start + 0x800, 4) if img.u32(o) == VDCSET]
        if len(hits) != 1:
            raise SystemExit('v2ui: %d copies of %#x near the wrapper at %#x' % (len(hits), VDCSET, v))
        struct.pack_into('>I', img.d, hits[0], V2_BASE)
        chained.add(v)
        if True:
            print('v2ui: the wrapper at %#x now continues into %#x (its literal at %#x)'
                  % (v, V2_BASE, img.addr_of(hits[0])))
    # P9 early present: the flip's sleep literal -> entry +28. P10: OFF (half-painted frames on a
    # display that takes the base at once); the stock flip stays byte-identical. V2_EARLY=1 to test.
    off = img.off_of(FLIP_SLEEP_LIT)
    if img.u32(off) != SLEEP:
        raise SystemExit('v2ui: %#x holds %#x, not the stock sleep (gr3direct in the set?)'
                         % (FLIP_SLEEP_LIT, img.u32(off)))
    if os.environ.get('V2_EARLY') == '1':
        struct.pack_into('>I', img.d, off, V2_BASE + 28)
        print('v2ui: flip sleep literal %#x -> %#x' % (FLIP_SLEEP_LIT, V2_BASE + 28))
    # F2 the compose gate: movi20 #(entry >> 16),r3 ; shll16 r3 ; add #(entry & 0xFFFF),r3 ; jmp @r3 ; nop
    ent = V2_BASE + COMP_ENTRY
    if (ent & 0xFFFF) > 0x7F or (ent >> 16) > 0x7FFF:
        raise SystemExit('v2ui: the compose gate cannot reach %#x with movi20 / shll16 / add' % ent)
    off = img.off_of(COMP_AT)
    if bytes(img.d[off:off + 12]) != COMP_STOCK:
        raise SystemExit('v2ui: %#x does not hold the stock window loop (%s)'
                         % (COMP_AT, bytes(img.d[off:off + 12]).hex()))
    img.d[off:off + 12] = struct.pack('>HHHHHH', 0x0300, ent >> 16, 0x4328,    # movi20's top 4 bits (word 0, 7:4) = 0
                                      0x7300 | (ent & 0xFF), 0x432B, 0x0009)
    print('v2ui: compose gate at %#x -> %#x' % (COMP_AT, ent))
    # the two filters: draw-callback slot and the per-frame clear's rect-fill literal
    mark = blob.find(struct.pack('>I', 0x56325052))          # "V2PR"
    if mark < 0 or mark % 4:
        raise SystemExit('v2ui: no V2PR marker in the blob')
    for lit, entry, slot in ((DRAW_SLOT, V2_BASE + 4, mark + 4), (CLEAR_LIT, V2_BASE + 8, mark + 8),
                             (WAVE_LIT, V2_BASE + 12, mark + 12), (BLIT_LIT, V2_BASE + 16, mark + 16),
                             (TEXT_SLOTS[0], V2_BASE + 20, mark + 20), (TEXT_SLOTS[1], V2_BASE + 24, mark + 24)):
        off = img.off_of(lit)
        prev = img.u32(off)
        if prev == 0 or img.off_of(prev & ~3, required=False) is None:
            raise SystemExit('v2ui: %#x holds %#x, not a code address' % (lit, prev))
        struct.pack_into('>I', img.d, src + slot, prev)
        struct.pack_into('>I', img.d, off, entry)
        print('v2ui: %#x -> %#x (then %#x)' % (lit, entry, prev))
    return bytes(img.d)


# V3c: the needle-search / Link Cue touch zone under the V2 overview. MAIN's touch
# table (0xA81010A0, 20-byte zones {x0, y0, w, h, handler}) has zone 0 = the overview
# strip at 100..699 (600 columns, the stock layout); V2 draws its overview 640 wide at
# x 79 (re/V3_PROGRESS.md V3c). Zone 0 becomes (79, 377, 640, 103); the two users of
# the zone (touchaudiotouch's needle search, the TchAud task's tp_touch) read x0 / w
# from it and scale a 640 wide zone to 600 columns (x 15/16), so builds without this
# poke behave exactly as before. A MAIN pseudo-mod (`v2needle`), named with v2ui.
NEEDLE_WHAT = 'V2 UI: needle search / Link Cue touch zone = the V2 overview (79..718, y 405..479); phase meter tap zone'
NEEDLE_ZONE = 0x081010A0
NEEDLE_STOCK = (100, 377, 600, 103, 0x084EDC5A)
# V3d: y from 405 (the hot-cue badge row above the overview): a tap on the time row (y 330..400) no
# longer needle-searches; the CDJ-3000 seeks only on its overview strip
NEEDLE_V2 = (79, 405, 640, 75, 0x084EDC5A)
# V3d: zone 2 = stock's phase meter (292, 55, 216 x 53; its handler 0x084EDBE6 toggles PHASE METER
# TYPE 1 <-> 2, the SHORT CUT setting): spread over the V2 meter (x 204..631, y 60..119) so a tap
# anywhere on it switches WAVEFORM <-> PHASE, as the CDJ-3000 (clear of the stock zones at x 130..199
# and 635..704 in the same rows)
PMETER_ZONE = 0x081010C8
PMETER_STOCK = (292, 55, 216, 53, 0x084EDBE6)
PMETER_V2 = (204, 60, 428, 60, 0x084EDBE6)


# V3e1: the SHORT CUT page in the CDJ-3000 layout (re/V3E_DESIGN.md §6.2, frame 04) -- the stock tiles' zones
# (MAIN class 10) moved to the new tiles, the phase meter's three styles (modsmenu pm_tap / pm_s0..2, found
# behind "PMCY"), the NXS2-only TRACK / PLAYLIST / SEARCH / MATCHING and the stock BLUE / RGB tiles off-screen
# (w = h = 0: never hit). Each entry: zone, its stock rect + handler, the new rect, the new handler (None = keep).
ZONE_TAB = 0x081010A0
SC_ZONES = (
    # zone, stock (x, y, w, h, handler), new (x, y, w, h), handler key
    (53, (29, 41, 70, 53, 0x084EE6F8), (82, 103, 64, 42), 'pm_s0'),     # PHASE (3000 order: WAVEFORM | PHASE)
    (54, (99, 41, 68, 53, 0x084EE708), (19, 103, 62, 42), 'pm_s1'),     # WAVEFORM
    (66, (617, 14, 164, 66, 0x084EE822), (148, 103, 64, 42), 'pm_s2'),  # 4 BARS (the NXS2 classic)
    (55, (29, 128, 69, 53, 0x084EE738), (224, 103, 62, 42), None),      # HOT CUE AUTO LOAD ON
    (56, (99, 128, 70, 53, 0x084EE728), (287, 103, 62, 42), None),      # rekordbox SETTING
    (57, (169, 128, 70, 53, 0x084EE718), (350, 103, 62, 42), None),     # OFF
    (58, (29, 217, 70, 53, 0x084EE748), (17, 251, 62, 42), None),       # QUANTIZE 1/8
    (59, (99, 217, 70, 53, 0x084EE75A), (79, 251, 62, 42), None),       # 1/4
    (60, (169, 217, 69, 53, 0x084EE76C), (141, 251, 62, 42), None),     # 1/2
    (61, (238, 217, 69, 53, 0x084EE7CC), (203, 251, 62, 42), None),     # 1
    (62, (328, 128, 65, 53, 0x084EE7DE), (683, 181, 68, 42), None),     # MY SETTINGS LOAD
    (63, (402, 128, 65, 53, 0x084EE7EE), (683, 234, 68, 42), None),     # SAVE
    (64, (328, 217, 70, 53, 0x084EE7FE), (0, 0, 0, 0), None),           # stock BLUE: off (ours is WAVEFORM COLOR)
    (65, (398, 217, 70, 53, 0x084EE810), (0, 0, 0, 0), None),           # stock RGB
    (67, (617, 80, 164, 66, 0x084EE834), (0, 0, 0, 0), None),           # PLAYLIST (the 3000 has the rail)
    (68, (617, 146, 164, 66, 0x084EE846), (683, 313, 68, 42), 'sm_cycle'),  # V3rc4: SCREEN MODE (SMOOTH/FAST/STEADY)
    (69, (617, 209, 164, 66, 0x084EE858), (0, 0, 0, 0), None),          # MATCHING
)
# the browse rows' touch (touch_audio row_touch: Link Cue = the 3000's touch PREVIEW): the PREVIEW column
# x 56..211 (the mini waveform 64..175 and its margins), rows from mods/v2ui/v2.c (V3_ROW_Y0 / V3_ROW_H),
# and with the SEARCH keyboard up its compact rows (V3_SROW_Y0 / V3_SROW_H) above the keys (y 294)
# V3e2 (video audit K4, the 3000's header tiles): the player's LOOP MODE tile (zone 3) and BEAT JUMP tile (zone
# 15) -- stock at the left / right of the meter row -- move onto V2's BEAT LOOP / BEAT JUMP header tiles (v2.c
# player(): 76 x 60 at x 561 / 721), so a tap on a lit tile opens / closes its pads as on the 3000
HDR_ZONES = (
    (3, (18, 55, 68, 53, 0x084EDBF6), (561, 0, 76, 60)),
    (15, (714, 55, 68, 53, 0x084EDC28), (721, 0, 76, 60)),
)
# V3rc1: TRACK FILTER's KEY edit box (zone 30, class 8) grows onto the CDJ-3000 key grid v2.c filter_page()
# draws (2 x 12 cells, x 255..699, y 100..171); the other filter zones keep stock's geometry (the page is drawn
# on it)
FILTER_ZONES = (
    (30, (255, 117, 126, 36, 0x084EE46C), (255, 100, 444, 72)),
)
# V3rc7 (re/TOUCH_AUDIT.md #1/#3/#6/#10): the player's pad row as v2.c draws it -- 8 pads 72 x 44 at x 58 + 80k,
# y 258. Zone 4 (stock: one 764 x 73 strip at 18,207 cut by 8 u16 thresholds at 0x08101A68, idx = first threshold
# >= x - x0) and the beat-jump zones 7..14 (one per slot) move onto it; the hidden <-/-> jump zones 5 / 6 go off
# (nothing is drawn there); MY TAG item 6 (zone 52) gets the x of its column (stock bug: 572 instead of 527).
# Rect-only checks (handlers of 5 / 6 are re-pointed by modsmenu).
PAD_ZONES = (
    (4, (18, 207, 764, 73), (58, 258, 632, 44)),
) + tuple((7 + k, (18 + 96 * k + (1 if k >= 2 else 0) * 0, 207, 90, 73), (58 + 80 * k, 258, 72, 44)) for k in range(8)) + (
    (5, (130, 55, 70, 53), (0, 0, 0, 0)),
    (6, (635, 55, 70, 53), (0, 0, 0, 0)),
    (52, (572, 230, 244, 36), (527, 230, 244, 36)),
)
PAD_THR = 0x08101A68
PAD_THR_STOCK = (95, 191, 286, 382, 477, 573, 668, 764)
PAD_THR_V3 = (75, 155, 235, 315, 395, 475, 555, 631)
RT_GEO_STOCK = (33, 747, 47, 30, 28, 47, 30, 28, 294)
RT_GEO_V3 = (64, 86, 91, 40, 38, 65, 28, 26, 294)   # V4n28 (audit P1): x0/width = the 86-px wave (was 56..211)


def needle_main(data):
    img = bytearray(data)
    o = lambda a: a - 0x08000000
    mk = bytes(img).find(struct.pack('<I', 0x504D4359))
    if mk < 0 or bytes(img).find(struct.pack('<I', 0x504D4359), mk + 4) >= 0 or mk % 4:
        raise SystemExit('v2needle: no unique PMCY marker (modsmenu V3e1) in MAIN')
    pm = dict(zip(('pm_tap', 'pm_s0', 'pm_s1', 'pm_s2', 'sm_cycle'), struct.unpack_from('<5I', img, mk + 4)))
    for zone, stock, new, h in SC_ZONES:
        zo = o(ZONE_TAB) + 20 * zone
        if struct.unpack_from('<5I', img, zo) != stock:
            raise SystemExit('v2needle: MAIN touch zone %d is not the stock one' % zone)
        struct.pack_into('<5I', img, zo, *(new + (pm[h] if h else stock[4],)))
    print('patch_update: v2needle MAIN: SHORT CUT zones 53..69 -> the CDJ-3000 layout; meter styles %s'
          % ' '.join('%s=%#x' % kv for kv in sorted(pm.items())))
    for zone, stock, new in (HDR_ZONES if os.environ.get('CDJ_V3E2', '1') == '1' else ()):
        zo = o(ZONE_TAB) + 20 * zone
        if struct.unpack_from('<5I', img, zo) != stock:
            raise SystemExit('v2needle: MAIN touch zone %d is not the stock one' % zone)
        struct.pack_into('<5I', img, zo, *(new + (stock[4],)))
    if os.environ.get('CDJ_V3E2', '1') == '1':
        print('patch_update: v2needle MAIN: LOOP MODE / BEAT JUMP tiles (zones 3 / 15) -> the header tiles')
    for zone, stock, new in (FILTER_ZONES if os.environ.get('CDJ_V3E2', '1') == '1' else ()):
        zo = o(ZONE_TAB) + 20 * zone
        if struct.unpack_from('<5I', img, zo) != stock:
            raise SystemExit('v2needle: MAIN touch zone %d is not the stock one' % zone)
        struct.pack_into('<5I', img, zo, *(new + (stock[4],)))
    if os.environ.get('CDJ_V3E2', '1') == '1':
        print('patch_update: v2needle MAIN: TRACK FILTER key edit (zone 30) -> the key grid')
    if os.environ.get('CDJ_V3E2', '1') == '1':
        stock_x = {7 + k: x for k, x in enumerate((18, 115, 211, 307, 403, 499, 595, 691))}
        for zone, stock, new in PAD_ZONES:
            if zone in stock_x:
                stock = (stock_x[zone],) + stock[1:]
            zo = o(ZONE_TAB) + 20 * zone
            if struct.unpack_from('<4I', img, zo) != stock:
                raise SystemExit('v2needle: MAIN touch zone %d is not the stock rect' % zone)
            struct.pack_into('<4I', img, zo, *new)
        if struct.unpack_from('<8H', img, o(PAD_THR)) != PAD_THR_STOCK:
            raise SystemExit('v2needle: loop pad thresholds are not the stock ones')
        struct.pack_into('<8H', img, o(PAD_THR), *PAD_THR_V3)
        print('patch_update: v2needle MAIN: loop / beat-jump pads (zones 4, 7..14 + thresholds) -> the V2 pad row; '
              'zones 5/6 off; zone 52 x 527')
    rg = bytes(img).find(struct.pack('<I', 0x5254474F))
    if rg < 0 and os.environ.get('V3E_NO_RTGO') == '1':     # bisect builds only
        return needle_zones(img, pm)
    if rg < 0 or bytes(img).find(struct.pack('<I', 0x5254474F), rg + 4) >= 0 or rg % 4:
        raise SystemExit('v2needle: no unique RTGO marker (touch_audio V3e1) in MAIN')
    if struct.unpack_from('<9I', img, rg + 4) != RT_GEO_STOCK:
        raise SystemExit('v2needle: touch_audio rt_geo is not the stock geometry')
    struct.pack_into('<9I', img, rg + 4, *RT_GEO_V3)
    print('patch_update: v2needle MAIN: Link Cue row touch -> %s' % (RT_GEO_V3,))
    # V3e1 (user): Link Cue only as the 3000's PREVIEW on the rows -- the INFO screen's strip preview (the
    # TchAud task's tp_touch, y >= tp_y0) is switched off by moving tp_y0 below the screen
    # (V3e3: touch_audio no longer has that code -- no marker, nothing to poke)
    ty = bytes(img).find(struct.pack('<HH', 0x5459, 377))
    if ty >= 0:
        if bytes(img).find(struct.pack('<HH', 0x5459, 377), ty + 2) >= 0:
            raise SystemExit('v2needle: no unique tp_y0 marker (touch_audio V3e1) in MAIN')
        struct.pack_into('<H', img, ty + 2, 0x7FFF)
        print('patch_update: v2needle MAIN: INFO strip Link Cue off (tp_y0 377 -> 32767)')
    return needle_zones(img, pm)


def needle_zones(img, pm=None):
    if pm is None:
        mk = bytes(img).find(struct.pack('<I', 0x504D4359))
        pm = dict(zip(('pm_tap', 'pm_s0', 'pm_s1', 'pm_s2', 'sm_cycle'), struct.unpack_from('<5I', img, mk + 4)))
    for zone, stock, new, what in ((NEEDLE_ZONE, NEEDLE_STOCK, NEEDLE_V2, 'zone 0 (needle search / Link Cue)'),
                                   (PMETER_ZONE, PMETER_STOCK, PMETER_V2, 'zone 2 (phase meter tap)')):
        o = zone - 0x08000000
        if struct.unpack_from('<5I', img, o) != stock:
            raise SystemExit('v2needle: MAIN touch %s at %#x is not the stock one' % (what, zone))
        if zone == PMETER_ZONE:     # V3e1: a tap cycles PHASE -> WAVEFORM -> 4 BARS (modsmenu pm_tap)
            new = new[:4] + (pm['pm_tap'],)
        struct.pack_into('<5I', img, o, *new)
        print('patch_update: v2needle MAIN: touch %s -> %s' % (what, new[:4]))
    return bytes(img)
