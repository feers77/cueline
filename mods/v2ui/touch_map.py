#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""touch_map -- the single source of every touch target of the V2 UI (task #23, re/TOUCH_MAP.md).

One declarative table: per screen state (MAIN screen class *0x0B54336C, model screen +0x07, pop-up / keyboard /
pad-mode / KEY SHIFT flags) the elements v2.c DRAWS that a finger may hit, with

  * the drawn rectangle (x, y, w, h; each one anchored to the v2.c source text it comes from, so a moved
    button breaks tests/test_touch_map.py instead of silently going dead),
  * the action: MAIN vt zone (modsmenu `vt_zones` action/arg), a stock MAIN zone (0x081010A0 table, as poked
    by v2ui.py v2needle), a stock keyboard key (0x08101630), or a PROPOSED action not implemented yet
    (pop-up rows, UTILITY rows / options, SOURCE rows, PREVIEW),
  * the condition (the states it is drawn in).

Generators (nothing here is wired into a build yet -- a later change can switch modsmenu to them):
  (a) `vt_inc()` / `vt_bytes()`: the CURRENT vt_zones table in exactly modsmenu's format (8-B `vz` rows,
      .ifdef KEYSHIFT), byte-identical to the hand-written one (`parse_modsmenu_vt` +
      the assembler check in the tests); `map_vt_rows()` the same rows re-derived from the drawn geometry
      (+6 px hit-slop) and `vt_diff()` the row-by-row difference; `stock_diff()` the same for the stock
      zone pokes of v2ui.py.
  (b) `v2_touch_h()`: rect constants + press ids for the GUI (v2.c drawing / press feedback).
  (c) `audit()`: dead / misrouted / partial targets and phantom live zones of the CURRENT tables.

CLI:  touch_map.py [--inc F] [--header F] [--diff] [--audit] [--variant ks|plain]
"""
import os
import re
import struct
import sys
from collections import namedtuple

HERE = os.path.dirname(os.path.abspath(__file__))
MODS = os.path.dirname(HERE)
ROOT = os.path.dirname(MODS)
V2C = os.path.join(HERE, 'v2.c')
MODSMENU = os.path.join(MODS, 'modsmenu', 'modsmenu.s')
V2UI = os.path.join(HERE, 'v2ui.py')
STOCK_MAIN = os.path.join(os.path.dirname(ROOT), 'emu-local', 'data', 'firmware_stock', 'main_unpacked.bin')

W, H = 800, 480
SLOP = 6            # hit-slop around a target ...
SLOP_BELOW = 48     # ... on each axis where it is smaller than this (re/TANDA3_REPORT.md #23 design 5)
QTOL = 2            # vz rows store x / 4, y / 2: an edge may move up to this many px when quantised
VT_UCLS = 6         # modsmenu: the UTILITY screen's class
VT_SRC = 0xFE       # modsmenu: the pseudo model screen SOURCE (class 2, screen 0x00, slot 1 a medium)


# ---------------------------------------------------------------------------------------------------------
# geometry
class R(namedtuple('R', 'x y w h')):
    __slots__ = ()

    @property
    def x1(self):
        return self.x + self.w

    @property
    def y1(self):
        return self.y + self.h

    @property
    def cx(self):
        return self.x + self.w // 2

    @property
    def cy(self):
        return self.y + self.h // 2

    def has(self, px, py):
        return self.x <= px < self.x1 and self.y <= py < self.y1

    def inter(self, o):
        x0, y0, x1, y1 = max(self.x, o.x), max(self.y, o.y), min(self.x1, o.x1), min(self.y1, o.y1)
        return R(x0, y0, x1 - x0, y1 - y0) if x1 > x0 and y1 > y0 else None

    def grow(self, dx, dy):
        return R(self.x - dx, self.y - dy, self.w + 2 * dx, self.h + 2 * dy)

    def clip(self):
        x0, y0, x1, y1 = max(0, self.x), max(0, self.y), min(W, self.x1), min(H, self.y1)
        return R(x0, y0, x1 - x0, y1 - y0)

    def edges(self):
        return (self.x, self.y, self.x1, self.y1)

    @staticmethod
    def e(x0, y0, x1, y1):
        return R(x0, y0, x1 - x0, y1 - y0)

    def __str__(self):
        return '%d..%d x %d..%d' % (self.x, self.x1, self.y, self.y1)


# ---------------------------------------------------------------------------------------------------------
# screen states: MAIN class, model screen (GUI MODEL[7] = MAIN 0x0B53FB54), flags
#   pop = MAIN UI +0xC (pop-up menu), kb = the SEARCH keyboard up (+0x54 / 0x0B545B64),
#   modes: pads_loop (heartbeat +0xF3 == 2), pads_bj (+0x11B == 1), ks_on / ks_panel / ks_rbm (KSB words)
State = namedtuple('State', 'name cls sid pop kb modes what')
STATES = {s.name: s for s in (
    State('player', 1, 0x02, 0, 0, (), 'player, no pads'),
    State('player.loop', 1, 0x02, 0, 0, ('pads_loop',), 'player, BEAT LOOP pads up'),
    State('player.bj', 1, 0x02, 0, 0, ('pads_bj',), 'player, BEAT JUMP pads up'),
    State('player.ks', 1, 0x02, 0, 0, ('ks_on',), 'player, UTILITY KEY SHIFT on, panel closed'),
    State('player.ksp', 1, 0x02, 0, 0, ('ks_on', 'ks_panel'), 'player, KEY SHIFT panel open'),
    State('player.lpt', 1, 0x02, 1, 0, (), 'player + LOAD PREVIOUS TRACK pane (MENU)'),
    State('player.grid', 1, 0x02, 0, 0, ('grid',), 'player, stock GRID ADJUST mode (the GRID ADJUST panel)'),
    State('pinfo', 4, 0x08, 0, 0, (), 'player INFO (track sheet)'),
    State('list.trk', 2, 0x04, 0, 0, (), 'browse: a track list'),
    State('list.plain', 2, 0x03, 0, 0, (), 'browse: categories / folders / playlists'),
    State('list.root', 2, 0x00, 0, 0, ('root',), 'browse root (rail = root, rows = preview)'),
    State('list.info', 2, 0x06, 0, 0, (), 'browse INFO (track list + right pane)'),
    State('list.tag', 3, 0x04, 0, 0, (), 'TAG LIST'),
    State('search.kb', 2, 0x04, 0, 1, (), 'SEARCH with its keyboard up'),
    State('pop.sort', 2, 0x04, 1, 0, ('n6',), 'SORT / LIST MENU pop-up (6 items)'),
    State('pop.tagmenu', 3, 0x04, 1, 0, ('n3', 'taglist'), 'TAG LIST MENU pop-up (3 items, OK / CANCEL)'),
    State('source', 2, 0x00, 0, 0, ('source',), 'SOURCE (device rows)'),
    State('filter', 8, 0x18, 0, 0, (), 'TRACK FILTER BPM / KEY page'),
    State('mytag', 9, 0x19, 0, 0, (), 'TRACK FILTER MY TAG page'),
    State('util', VT_UCLS, 0x0A, 0, 0, (), 'UTILITY list'),
    State('util.edit', VT_UCLS, 0x09, 0, 0, (), 'UTILITY value edit'),
    State('shortcut', 10, 0x1E, 0, 0, (), 'SHORT CUT'),
    State('shortcut.rbm', 10, 0x1E, 0, 0, ('ks_on', 'ks_rbm'), 'SHORT CUT, REKORDBOX BUTTON = KEY SHIFT'),
)}
PLAYER = ('player', 'player.loop', 'player.bj', 'player.ks', 'player.ksp', 'player.grid')   # (not under the LPT pane: outside = BACK)
ZOOMG = ('player', 'player.loop', 'player.bj', 'player.ks', 'player.grid')    # the ZOOM - GRID label (under K.SYNC: not ksp)
LISTS = ('list.trk', 'list.plain', 'list.root', 'list.info', 'list.tag')
HDR_LISTS = LISTS                       # header(): back box + INFO box
TRK_LISTS = ('list.trk', 'list.plain', 'list.info', 'list.tag')  # header(pv = tracks): the PREVIEW tile (v2.c: sid 3 / 4 / INFO)

# ---------------------------------------------------------------------------------------------------------
# actions
A = namedtuple('A', 'kind code arg')    # kind: vt (modsmenu act/arg) | stock (zone n, slice) | kbd (stock key)
#                                         | new (PROPOSED, not in MAIN yet) | none
KEY = {'BACK': 0, 'INFO': 1, 'MENU': 2, 'PUSH': 3, 'USB': 4, 'SEARCH': 5}   # modsmenu vt_keys


def vt(act, arg=0):
    return A('vt', act, arg)


def key(name):
    return A('vt', 1, KEY[name])


def stock(z, sl=None):
    return A('stock', z, sl)


def new(name, arg=None):
    return A('new', name, arg)


NONE = A('none', None, None)

# kinds: button (one zone each), area (one zone, the action derives the item from x / y: rows, meter, overview),
#        sub (inside an area, served by its zone: `zone_of`), display (drawn, not a target), swallow (no action:
#        a press there must not reach stock's fallback)
T = namedtuple('T', 'tid states r kind act anchor zone_of note')


def t(tid, states, r, kind, act, anchor=None, zone_of=None, note=''):
    if isinstance(states, str):
        states = (states,)
    return T(tid, tuple(states), R(*r), kind, act, anchor, zone_of, note)


def popup_modal(n, taglist=False):
    """v2.c popup(): the SORT / LIST MENU / TAG LIST MENU modal for n items (rects)."""
    bh = 52 + 34 * (n if n else 1) + 8 + (50 if taglist else 0)
    y0 = max(66, 236 - bh // 2)
    out = {'frame': R(230, y0, 340, bh), 'title': R(232, y0 + 2, 336, 38),
           'rows': [R(236, y0 + 46 + 34 * (k - 1), 328, 32) for k in range(1, n + 1)]}
    if taglist:
        out['ok'] = R(290, y0 + bh - 46, 100, 34)
        out['cancel'] = R(410, y0 + bh - 46, 100, 34)
    return out


def _targets():
    L = []
    a = L.append
    # ---- player (class 1) --------------------------------------------------------------------------------
    a(t('p.loop_tile', PLAYER, (561, 0, 76, 60), 'button', stock(3), 'int tx = 561 + i * 80'))
    a(t('p.ks_tile', ('player.ks', 'player.ksp'), (641, 0, 76, 60), 'button', vt(12, 1), 'int tx = 561 + i * 80'))
    a(t('p.bj_tile', PLAYER, (721, 0, 76, 60), 'button', stock(15), 'int tx = 561 + i * 80'))
    a(t('p.info', PLAYER, (276, 30, 280, 26), 'button', key('INFO'), 'text_u16(&f_m, 276, 32, kft, kfn, 552',
        note='sub-line key + the (i) disc'))
    a(t('p.meter', PLAYER, (204, 60, 428, 60), 'area', stock(2), 'fill(0, 60, W, BAND_Y0 - 60, C_BLACK)',
        note='tap cycles PHASE / WAVEFORM / 4 BARS (pm_tap)'))
    a(t('p.overview', PLAYER, (79, 405, 640, 75), 'area', stock(0), '#define OV_X 79',
        note='needle search (paused) / Touch Cue (playing, LINK CUE with CUE: TchAud tc_check reads zone 0)'))
    for k in range(8):
        a(t('p.loop_pad%d' % k, 'player.loop', (58 + 80 * k, 258, 72, 44), 'button', stock(4, k),
            'int px = 58 + 80 * k, lit = k == active'))
        a(t('p.bj_pad%d' % k, 'player.bj', (58 + 80 * k, 258, 72, 44), 'button', stock(7 + k),
            'int px = 58 + 80 * k, cx = px + 20'))
    for nm, x, arg in (('p.ks_m1', 180, 2), ('p.ks_reset', 353, 4), ('p.ks_p1', 524, 3)):
        a(t(nm, 'player.ksp', (x, 258, 96, 44), 'button', vt(12, arg), 'static const int X[3] = { 180, 353, 524 }'))
    a(t('p.ks_sync', 'player.ksp', (656, 258, 96, 44), 'button', vt(12, 7), 'fill(656, y, 96, 44, bg)'))
    a(t('p.ks_row', 'player.ksp', (16, 250, 768, 60), 'swallow', vt(12, 5), 'fill(WAVE_X0, y - 3, WAVE_N, 48'))
    # TOUCH (V4n41): the GRID ADJUST panel (v2.c grid_bar) and the ZOOM - GRID toggle (zoom_label)
    for k, (nm, x) in enumerate((('snap', 197), ('shift', 282), ('half_back', 367), ('half_next', 446),
                                 ('reset', 531))):
        a(t('g.' + nm, 'player.grid', (x, 258, 72, 44), 'button', vt(15, k),
            'static const short X[5] = { 197, 282, 367, 446, 531 }'))
    a(t('g.row', 'player.grid', (16, 250, 768, 60), 'swallow', vt(15, 6), 'fill(WAVE_X0, y - 3, WAVE_N, 48'))
    a(t('p.zoomgrid', ZOOMG, (708, 296, 86, 18), 'button', vt(15, 5), 'fill(708, 296, 86, 18, C_BLACK)',
        note='stock GRID ADJUST mode on / off'))
    # LOAD PREVIOUS TRACK pane (popup(), MODEL[7] == 0x02)
    a(t('lpt.title', 'player.lpt', (457, 60, 343, 30), 'display', NONE, 'int x0 = 457, w = W - 457, y = 60'))
    # TOUCH (V4n41): modsmenu vt_pop (CENTPOP) -> va_touch action 14 inside the pane, BACK outside
    a(t('lpt.pane', 'player.lpt', (457, 90, 343, 320), 'area', vt(14), 'int x0 = 457, w = W - 457, y = 60',
        note='va_touch: the row from y (40 px from y 90)'))
    for k in range(8):
        a(t('lpt.row%d' % k, 'player.lpt', (457, 90 + 40 * k, 343, 39), 'sub', vt(14),
            'fill(x0, y, w, 39, bg)', zone_of='lpt.pane', note='tap = cursor there; on the cursor = PUSH (load)'))
    a(t('lpt.outside', 'player.lpt', (0, 0, W, H), 'swallow', key('BACK'), note='tap outside the pane = BACK'))
    # ---- player INFO (class 4): nothing tappable is drawn ------------------------------------------------
    a(t('pi.art', 'pinfo', (18, 76, 166, 166), 'display', NONE, 'frame(18, 76, 166, 166, 1, C_ART)'))
    # ---- browse (class 2 / 3) -----------------------------------------------------------------------------
    brs = LISTS + ('search.kb',)
    a(t('b.src', brs, (0, 0, 56, 60), 'button', key('USB'), 'fill(0, 0, RAIL_W, 60, nv)'))
    a(t('b.back', HDR_LISTS, (74, 14, 32, 32), 'button', key('BACK'), 'frame(x, 14, 32, 32, 1, 0x4A69)'))
    a(t('b.info', HDR_LISTS, (712, 12, 80, 36), 'button', key('INFO'), 'fill(712, 12, 80, 36'))
    a(t('b.preview', TRK_LISTS, (562, 6, 72, 48), 'button', vt(18), 'fill(562, 6, 72, 48, C_SEL)',
        note='3000 PREVIEW tile: Link Cue on the rows, a tap = on / off (kill_v +24)'))
    a(t('b.filter', ('list.trk', 'list.plain', 'list.root', 'list.info'), (640, 16, 64, 28), 'button', vt(5),
        'frame(640, 16, 64, 28, 1, 0x4A69)'))
    a(t('b.colhdr', ('list.trk', 'list.plain', 'list.tag'), (184, 60, 616, 28), 'button', key('MENU'),
        'fill(x0, 60, x1 - x0, 28, C_HDR)', note='column header -> stock SORT'))
    a(t('b.colhdr_i', 'list.info', (184, 60, 268, 28), 'button', key('MENU'), 'colhdr(RAIL_W, x1, "TRACK"',
        zone_of='b.colhdr'))
    a(t('b.rows', ('list.trk', 'list.plain', 'list.tag'), (56, 90, 744, 320), 'area', vt(4),
        '#define V3_ROW_Y0 90', note='8 rows x 40: tap = cursor, tap on cursor = open / LOAD'))
    a(t('b.rows_i', 'list.info', (56, 90, 396, 320), 'area', vt(4), '#define PANE2_X 452', zone_of='b.rows'))
    a(t('b.rows_root', 'list.root', (56, 90, 744, 320), 'display', NONE, 'plain_row(f, k, RAIL_W, W, y0 + rh * k',
        note='root: dim preview of the cursor category (3000: the rail is the root)'))
    for k in range(8):
        a(t('b.load%d' % k, ('list.trk', 'list.tag'), (675, 92 + 40 * k, 123, 36), 'sub', key('PUSH'),
            'fill(x1 - 125, y + 2, 123, h - 4, 0xDEDB)', zone_of='b.rows',
            note='cursor track row only (V4n30a: x 675..797, modsmenu x / 4 >= 168)'))
    rail = (('ARTIST', 0x81), ('ALBUM', 0x82), ('TRACK', 0x83), ('KEY', 0x8B), ('PLAYLIST', 0x84),
            ('HISTORY', 0x95), ('SEARCH', None), ('MATCHING', 0xAA), ('FOLDER', 0x90))
    for k, (nm, ic) in enumerate(rail):
        st = brs if k < 5 else LISTS            # the SEARCH keyboard cuts the rail at y 294
        a(t('b.rail%d' % k, st, (0, 60 + 40 * k, 56, 40), 'button', key('SEARCH') if ic is None else vt(8, ic),
            'int y = 60 + 40 * k, a = v2a_for_icon(RAIL_ID[k])', note=nm))
    a(t('b.strip', LISTS, (0, 410, 800, 70), 'swallow', vt(0), 'fill(RAIL_W, y0 + 8 * rh',
        note='deck strip: no zone-0 seek'))
    a(t('b.info_load', 'list.info', (604, 372, 184, 36), 'button', key('PUSH'), 'fill(604, 372, 184, 36, 0xE73C)'))
    a(t('b.info_pane', 'list.info', (452, 60, 348, 360), 'swallow', vt(0), 'fill(PANE2_X, 60, W - PANE2_X, 312'))
    # SEARCH keyboard (stock QWERTY table 0x08101630; v2.c draws its keys inside the stock rects)
    for i in range(10):
        a(t('k.r1_%d' % i, 'search.kb', (40 + 66 * i, 302, 60, 46), 'button', A('kbd', i, None),
            'fill(40 + 66 * i, 302, 60, 46, C_KEYB)'))
    for i in range(9):
        a(t('k.r2_%d' % i, 'search.kb', (73 + 66 * i, 357, 60, 46), 'button', A('kbd', 10 + i, None),
            'fill(73 + 66 * i, 357, 60, 46, C_KEYB)'))
    for i in range(7):
        a(t('k.r3_%d' % i, 'search.kb', (106 + 66 * i, 410, 60, 46), 'button', A('kbd', 19 + i, None),
            'fill(106 + 66 * i, 410, 60, 46, C_KEYB)'))
    a(t('k.bksp', 'search.kb', (717, 302, 65, 46), 'button', A('kbd', 27, None), 'fill(717, 302, 65, 46, C_KEYB2)'))
    a(t('k.clear', 'search.kb', (693, 357, 89, 46), 'button', A('kbd', 29, None), 'fill(693, 357, 89, 46, C_KEYB2)'))
    a(t('k.123', 'search.kb', (18, 410, 65, 46), 'button', A('kbd', 26, None), 'fill(18, 410, 65, 46, C_KEYB2)'))
    a(t('k.space', 'search.kb', (693, 410, 89, 46), 'button', A('kbd', 28, None), 'fill(693, 410, 89, 46, C_KEYB2)'))
    a(t('k.query', 'search.kb', (68, 14, 460, 32), 'display', NONE, 'fill(x, 14, 460, 32, C_BLACK)',
        note='kb hidden: a tap at y < 60 shows it again (v3e_touch code, not a zone)'))
    # pop-ups: SORT / LIST MENU (n = 6) and TAG LIST MENU (n = 3 + OK / CANCEL)
    for st, n, tl in (('pop.sort', 6, False), ('pop.tagmenu', 3, True)):
        g = popup_modal(n, tl)
        a(t(st + '.title', st, g['title'], 'display', NONE, 'fill(232, y0 + 2, 336, 38, 0xB5B6)'))
        a(t(st + '.box', st, g['frame'], 'area', vt(14), 'fill(230, y0, 340, bh, C_POP)',
            note='TOUCH: va_touch finds the row / OK / CANCEL from y (TM_POP_*)'))
        for k, r in enumerate(g['rows']):
            a(t('%s.row%d' % (st, k), st, r, 'sub', vt(14), 'fill(236, y, 328, 32, bg)', zone_of=st + '.box',
                note='TAG LIST MENU: the cursor there; else the cursor there + PUSH'))
        if tl:
            a(t(st + '.ok', st, g['ok'], 'sub', vt(14), 'fill(290, y0 + bh - 46, 100, 34', zone_of=st + '.box',
                note='PUSH'))
            a(t(st + '.cancel', st, g['cancel'], 'sub', vt(14), 'fill(410, y0 + bh - 46, 100, 34',
                zone_of=st + '.box', note='BACK'))
        a(t(st + '.outside', st, (0, 0, W, H), 'swallow', key('BACK'), note='outside the frame = BACK'))
    # ---- SOURCE (class 2, model screen 0x00 listing the media) ---------------------------------------------
    # V4n32 (#58b): one area over the rows -- in the LINK list this deck's own SD / USB (when mounted) first, then
    # the model's rows; up to 8, pitch 64 for <= 5 rows, else 44 (modsmenu va_src derives the row from y)
    a(t('src.rows', 'source', (4, 66, 572, 352), 'area', vt(13), 'int pitch = nr <= 5 ? 64 : 44',
        note='V4n32: modsmenu va_src -- own row: SD / USB key; model row k: seek, PUSH on the cursor row'))
    for k in range(5):
        a(t('src.row%d' % k, 'source', (4, 66 + 64 * k, 572, 60), 'sub', vt(13),
            'y = 66 + pitch * r;', zone_of='src.rows', note='the 64-px layout (<= 5 rows)'))
    a(t('src.rest', 'source', (0, 0, W, H), 'swallow', vt(0), 'layout(0x7102',
        note='V4n31a: nothing else on SOURCE reaches the list zones under it'))
    a(t('src.pane', 'source', (580, 66, 216, 300), 'display', NONE, 'fill(580, 66, 216, 300, 0x2124)'))
    # ---- TRACK FILTER (class 8) / MY TAG (class 9) ---------------------------------------------------------
    for st in ('filter', 'mytag'):
        a(t(st[0] + '.filter', st, (488, 8, 64, 28), 'button', vt(5), 'fill(488, 8, 64, 28'))
        a(t(st[0] + '.reset', st, (568, 4, 76, 36), 'button', vt(11, 2), 'fill(568, 4, 76, 36, 0x2945)',
            note='hold -> stock zone 23'))
        a(t(st[0] + '.bpmkey', st, (648, 4, 76, 36), 'button', vt(11, 0), 'fill(648, 4, 76, 36'))
        a(t(st[0] + '.mytag', st, (728, 4, 68, 36), 'button', vt(11, 1), 'fill(728, 4, 68, 36'))
    for k, nm in enumerate(('bpm', 'key', 'rating', 'color')):
        a(t('f.chk_' + nm, 'filter', (113, (53, 117, 181, 245)[k], 110, 36), 'button', stock(24 + k),
            'fill(113, y, 110, 36, 0x2124)'))
    a(t('f.bpm', 'filter', (255, 53, 126, 36), 'button', stock(28), 'fp_box(255, 53, 126, b, "BPM"'))
    a(t('f.range', 'filter', (519, 53, 126, 36), 'button', stock(29), 'fp_box(519, 53, 126, b, "%"'))
    a(t('f.master', 'filter', (714, 53, 68, 99), 'button', stock(40), 'fill(714, 53, 68, 99, 0x2945)'))
    a(t('f.keygrid', 'filter', (255, 100, 442, 70), 'area', stock(30), 'x = 255 + 37 * (k % 12), y = bb ? 100 : 138'))
    a(t('f.rating', 'filter', (255, 181, 352, 36), 'area', stock(31), 'fill(255, 181, 352, 36, 0x2124)'))
    for k in range(8):
        a(t('f.color%d' % k, 'filter', (255 + 66 * k, 245, 60, 36), 'button', stock(32 + k),
            'int x = 255 + 66 * k, s = (FB[0x0E] >> k) & 1'))
    for k, x in enumerate((102, 274, 447, 620)):
        a(t('m.tab%d' % k, 'mytag', (x, 48, 161, 40), 'button', stock(41 + k),
            'k == 0 ? 102 : k == 1 ? 274 : k == 2 ? 447 : 620'))
    a(t('m.and', 'mytag', (111, 213, 64, 52), 'button', stock(45), 'fill(111, 213, 64, 52'))
    a(t('m.or', 'mytag', (176, 213, 64, 52), 'button', stock(46), 'fill(176, 213, 64, 52'))
    for i in range(6):
        a(t('m.item%d' % i, 'mytag', (527 if i & 1 else 272, 110 + 60 * (i >> 1), 244, 36), 'button', stock(47 + i),
            'int x = i & 1 ? 527 : 272, y = 110 + 60 * (i >> 1)'))
    # ---- UTILITY (class 6) --------------------------------------------------------------------------------
    for k in range(6):
        a(t('u.cat%d' % k, ('util', 'util.edit'), (0, 70 + 48 * k, 64, 46), 'button', vt(9, k),
            'int y = 70 + 48 * k, on = k + 1 == cat'))
    a(t('u.left', 'util', (0, 60, 64, 360), 'swallow', vt(0), 'fill(0, 64, 64, STRIP_Y - 64, C_BLACK)'))
    # TOUCH (V4n41): modsmenu va_touch 16 (rows: the cursor there / PUSH on it) and 17 (options: PUSH, the
    # pending value sought to it, PUSH)
    a(t('u.rows', ('util', 'util.edit'), (68, 70, 458, 263), 'area', vt(16), 'int y = 70 + 33 * k, cur = fl & 8',
        note='va_touch: row k = (y - 70) / 33'))
    for k in range(8):
        a(t('u.row%d' % k, ('util', 'util.edit'), (68, 70 + 33 * k, 458, 31), 'sub', vt(16),
            'fill(68, y, 458, 31, bg)', zone_of='u.rows', note='the cursor there; on it: PUSH; editing: BACK'))
    a(t('u.opts', ('util', 'util.edit'), (530, 67, 266, 329), 'area', vt(17), 'for (i = 0, y = 70; *o; i++)',
        note='va_touch: option first + (y - 67) / 33 (radio_list window)'))
    for i in range(10):
        a(t('u.opt%d' % i, ('util', 'util.edit'), (530, 67 + 33 * i, 266, 32), 'sub', vt(17),
            'fill(530, y - 3, W - 534, 32, rbg)', zone_of='u.opts', note='PUSH, seek the pending value, PUSH'))
    a(t('u.strip', ('util', 'util.edit'), (0, 410, 800, 70), 'swallow', vt(0), 'strip(0);'))
    # ---- SHORT CUT (class 10) -----------------------------------------------------------------------------
    SC = ('shortcut', 'shortcut.rbm')
    for nm, x, w, z in (('wave', 19, 62, 54), ('phase', 82, 64, 53), ('4bars', 148, 64, 66),
                        ('hcal_on', 224, 62, 55), ('hcal_set', 287, 62, 56), ('hcal_off', 350, 62, 57)):
        a(t('s.' + nm, SC, (x, 103, w, 42), 'button', stock(z), 'sc_tile(%d, 103, %d, 42' % (x, w)))
    for nm, x, arg, anc in (('lcd_dn', 17, 0, 'sc_tile(17, 177, 187, 40'), ('lcd_up', 141, 2, 'sc_tile(17, 177, 187, 40'),
                            ('jog_dn', 221, 1, 'sc_tile(221, 177, 187, 40'), ('jog_up', 345, 3, 'sc_tile(221, 177, 187, 40')):
        a(t('s.' + nm, SC, (x, 177, 63, 40), 'button', vt(6, arg), anc, note='< / > half of the tile'))
    for i in range(4):
        a(t('s.q%d' % i, SC, (17 + 62 * i, 251, 61, 42), 'button', stock(58 + i), 'sc_tile(17 + 62 * i, 251, 61, 42'))
    for i in range(8):
        a(t('s.bjv%d' % i, SC, (15 + 62 * (i & 3), 325 + 40 * (i >> 2), 61, 39), 'display' if i == 0 else 'button',
            NONE if i == 0 else vt(10, i), 'sc_tile(15 + 62 * (i & 3), 325 + 40 * (i >> 2), 61, 39',
            note='1/2 disabled (whole beats only)' if i == 0 else ''))
    for nm, x, w, arg in (('wcol_blue', 452, 63, 0x02), ('wcol_rgb', 516, 62, 0x01), ('wcol_3band', 579, 62, 0x00)):
        a(t('s.' + nm, SC, (x, 181, w, 42), 'button', vt(7, arg), 'sc_tile(%d, 181, %d, 42' % (x, w)))
    a(t('s.pos_left', SC, (449, 257, 62, 40), 'button', vt(7, 0x11), 'sc_tile(449, 257, 62, 40, "LEFT"'))
    a(t('s.pos_center', SC, (512, 257, 62, 40), 'button', vt(7, 0x10), 'sc_tile(512, 257, 62, 40, "CENTER"'))
    a(t('s.load', SC, (683, 181, 68, 42), 'button', stock(62), 'sc_tile(683, 181, 68, 42, "LOAD"'))
    a(t('s.save', SC, (683, 234, 68, 42), 'button', stock(63), 'sc_tile(683, 234, 68, 42, "SAVE"'))
    a(t('s.rbk', 'shortcut.rbm', (683, 287, 68, 42), 'button', vt(12, 6), 'sc_tile(683, 287, 68, 42, "rekordbox"'))
    a(t('s.source', SC, (436, 85, 334, 66), 'display', NONE, 'fill(436, 85, 334, 66, C_CK2)'))
    return L


TARGETS = _targets()
BY_ID = {x.tid: x for x in TARGETS}
assert len(BY_ID) == len(TARGETS), 'duplicate target id'
TOUCHABLE = ('button', 'area', 'sub')

# ---------------------------------------------------------------------------------------------------------
# (a) the CURRENT modsmenu vt_zones table, row for row (8 B: class, model screen or 0xFF, action, arg,
#     x0 / 4, y0 / 2, x1 / 4, y1 / 2; first match wins). flag: None or 'KEYSHIFT' (.ifdef)
VZ = namedtuple('VZ', 'cls scr act arg x0 y0 x1 y1 flag tid')


def _current_vt():
    L = []
    a = lambda *v: L.append(VZ(*v))     # noqa: E731
    for k, (nm, x0, x1) in enumerate((('snap', 192, 276), ('shift', 276, 364), ('half_back', 364, 440),
                                      ('half_next', 440, 524), ('reset', 524, 612))):
        a(1, 0xFF, 15, k, x0, 252, x1, 308, None, 'g.' + nm)
    a(1, 0xFF, 12, 1, 640, 0, 720, 60, 'KEYSHIFT', 'p.ks_tile')
    a(1, 0xFF, 12, 2, 176, 254, 280, 306, 'KEYSHIFT', 'p.ks_m1')
    a(1, 0xFF, 12, 4, 348, 254, 452, 306, 'KEYSHIFT', 'p.ks_reset')
    a(1, 0xFF, 12, 3, 520, 254, 624, 306, 'KEYSHIFT', 'p.ks_p1')
    a(1, 0xFF, 12, 7, 652, 254, 756, 306, 'KEYSHIFT', 'p.ks_sync')
    a(1, 0xFF, 12, 5, 16, 250, 784, 310, 'KEYSHIFT', 'p.ks_row')
    a(10, 0xFF, 12, 6, 680, 286, 752, 330, 'KEYSHIFT', 's.rbk')
    a(1, 0xFF, 15, 5, 704, 290, 800, 322, None, 'p.zoomgrid')
    a(1, 0xFF, 15, 6, 16, 250, 784, 310, None, 'g.row')
    for k in range(6):
        a(VT_UCLS, 0x0A, 9, k, 0, 70 + 48 * k, 64, 116 + 48 * k, None, 'u.cat%d' % k)
    a(VT_UCLS, 0x0A, 0, 0, 0, 60, 64, 420, None, 'u.left')
    for sid in (0x0A, 0x09):
        a(VT_UCLS, sid, 16, 0, 68, 70, 528, 334, None, 'u.rows')
        a(VT_UCLS, sid, 17, 0, 528, 64, 800, 398, None, 'u.opts')
    a(VT_UCLS, 0xFF, 0, 0, 0, 410, 800, 480, None, 'u.strip')
    # V4n31a (#58): SOURCE (class 2, model screen 0x00 with media rows) = pseudo screen 0xFE (modsmenu vt_hit:
    # slot 1's icon is a medium); its 64-px rows, then the rest swallowed (the list's zones lie under it)
    a(2, VT_SRC, 13, 0, 4, 66, 576, 418, None, 'src.rows')     # V4n32 (#58b): rows from y (va_src)
    a(2, VT_SRC, 0, 0, 0, 0, 800, 480, None, 'src.rest')
    a(2, 0x06, 1, 3, 600, 368, 792, 412, None, 'b.info_load')
    a(2, 0x06, 0, 0, 452, 60, 800, 420, None, 'b.info_pane')
    for c in (2, 3):
        a(c, 0xFF, 1, 0, 64, 8, 112, 52, None, 'b.back')
        a(c, 0xFF, 1, 1, 708, 8, 796, 52, None, 'b.info')
        a(c, 0xFF, 18, 0, 556, 0, 636, 60, None, 'b.preview')
        a(c, 0xFF, 1, 2, 184, 60, 800, 88, None, 'b.colhdr')
        a(c, 0xFF, 4, 0, 56, 90, 800, 410, None, 'b.rows')
        a(c, 0xFF, 0, 0, 0, 410, 800, 480, None, 'b.strip')
        a(c, 0xFF, 1, 4, 0, 0, 56, 60, None, 'b.src')
        for k, ic in enumerate((0x81, 0x82, 0x83, 0x8B, 0x84, 0x95)):
            a(c, 0xFF, 8, ic, 0, 60 + 40 * k, 56, 100 + 40 * k, None, 'b.rail%d' % k)
        a(c, 0xFF, 1, 5, 0, 300, 56, 340, None, 'b.rail6')
        a(c, 0xFF, 8, 0xAA, 0, 340, 56, 380, None, 'b.rail7')
        a(c, 0xFF, 8, 0x90, 0, 380, 56, 420, None, 'b.rail8')
    a(2, 0xFF, 5, 0, 636, 8, 708, 52, None, 'b.filter')
    for c in (8, 9):
        p = 'f' if c == 8 else 'm'
        a(c, 0xFF, 5, 0, 484, 8, 556, 52, None, p + '.filter')
        a(c, 0xFF, 11, 2, 568, 0, 644, 56, None, p + '.reset')
        a(c, 0xFF, 11, 0, 648, 0, 724, 56, None, p + '.bpmkey')
        a(c, 0xFF, 11, 1, 728, 0, 800, 56, None, p + '.mytag')
    a(1, 0xFF, 1, 1, 268, 26, 556, 58, None, 'p.info')
    a(10, 0xFF, 6, 0, 17, 177, 80, 217, None, 's.lcd_dn')
    a(10, 0xFF, 6, 2, 140, 177, 204, 217, None, 's.lcd_up')
    a(10, 0xFF, 6, 1, 221, 177, 284, 217, None, 's.jog_dn')
    a(10, 0xFF, 6, 3, 344, 177, 408, 217, None, 's.jog_up')
    a(10, 0xFF, 7, 0x02, 452, 181, 516, 223, None, 's.wcol_blue')
    a(10, 0xFF, 7, 0x01, 516, 181, 580, 223, None, 's.wcol_rgb')
    a(10, 0xFF, 7, 0x00, 580, 181, 644, 223, None, 's.wcol_3band')
    a(10, 0xFF, 7, 0x11, 448, 257, 512, 297, None, 's.pos_left')
    a(10, 0xFF, 7, 0x10, 512, 257, 576, 297, None, 's.pos_center')
    for i in range(1, 8):
        a(10, 0xFF, 10, i, 16 + 62 * (i & 3), 325 + 40 * (i >> 2), 76 + 62 * (i & 3), 363 + 40 * (i >> 2), None,
          's.bjv%d' % i)
    return L


CURRENT_VT = _current_vt()
VARIANTS = {'ks': ('KEYSHIFT',), 'plain': ()}


def _on(flag, syms):
    return flag is None or (flag[1:] not in syms if flag.startswith('!') else flag in syms)


def vz_pack(r):
    """One row's 8 bytes, as modsmenu's `vz` macro packs it."""
    return bytes((r.cls, r.scr, r.act, r.arg & 0xFF, r.x0 // 4, r.y0 // 2, r.x1 // 4, r.y1 // 2))


def vz_rect(r):
    """The screen rect a row really covers (the hit test compares x / 4, y / 2)."""
    return R.e(r.x0 // 4 * 4, r.y0 // 2 * 2, r.x1 // 4 * 4, r.y1 // 2 * 2)


def vt_bytes(rows=None, variant='ks'):
    rows = CURRENT_VT if rows is None else rows
    syms = VARIANTS[variant]
    return b''.join(vz_pack(r) for r in rows if _on(r.flag, syms)) + bytes(8)


def vt_inc(rows=None, proposed=()):
    """The table as modsmenu source: the `vz` rows (literal coordinates) under vt_zones's conditionals,
    the 8-zero terminator. Assemble after modsmenu's `vz` macro and VT_UCLS. `proposed`: rows for actions
    MAIN does not have yet, emitted as comments only. TOUCH (V4n41): by default the BUILT table (map_vt_rows:
    the drawn rects + hit-slop) -- modsmenu's vt_zones includes this file."""
    rows = map_vt_rows() if rows is None else rows
    out = ['! generated by mods/v2ui/touch_map.py -- do not edit (re/TOUCH_MAP.md)',
           '! vz class, model screen | 0xFF, action, arg, x0, y0, x1, y1 (the macro stores x / 4, y / 2)']
    cur = None
    for r in rows:
        if r.flag != cur:
            if cur is not None:
                out.append('\t.endif')
            if r.flag is not None:
                out.append('\t.ifndef\t%s' % r.flag[1:] if r.flag.startswith('!') else '\t.ifdef\t%s' % r.flag)
            cur = r.flag
        out.append('\tvz\t%d, %#04x, %d, %#04x, %d, %d, %d, %d\t! %s' % (r.cls, r.scr, r.act, r.arg & 0xFF, r.x0,
                                                                         r.y0, r.x1, r.y1, r.tid))
    if cur is not None:
        out.append('\t.endif')
    out.append('\t.byte\t0, 0, 0, 0, 0, 0, 0, 0')
    for p in proposed:
        out.append('!PROPOSED %s' % p)
    return '\n'.join(out) + '\n'


def modsmenu_vt_block(path=MODSMENU):
    """The hand-written vt_zones source lines (label .. terminator)."""
    with open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')
    s = next(i for i, l in enumerate(lines) if l.startswith('vt_zones:'))
    e = next(i for i in range(s, len(lines)) if re.match(r'\s*\.byte\s+0,\s*0,\s*0,\s*0,\s*0,\s*0,\s*0,\s*0', lines[i])
             or re.match(r'\s*\.include\s+"touch_vt_zones.inc"', lines[i]))
    return lines[s:e + 1]


def _ev(expr, env):
    expr = re.sub(r'\\(\w+)', lambda m: str(env[m.group(1)]), expr)
    expr = expr.replace('VT_UCLS', str(VT_UCLS)).replace('/', '//')
    if not re.fullmatch(r'[\s0-9a-fA-Fx()+\-*/&|<>]+', expr):
        raise ValueError('vt_zones: unsupported expression %r' % expr)
    return eval(expr, {'__builtins__': {}})     # noqa: S307 (repo source, arithmetic only)


def parse_modsmenu_vt(variant='ks', path=MODSMENU):
    """Evaluate the hand-written vt_zones (.ifdef / .ifndef / .irp / vz) for a build variant -> bytes."""
    syms = VARIANTS[variant]
    lines = []
    for l in modsmenu_vt_block(path)[1:]:      # TOUCH (V4n41): vt_zones is `.include "touch_vt_zones.inc"`
        m = re.match(r'\s*\.include\s+"([^"]+)"', l)
        if m:
            with open(os.path.join(HERE, m.group(1)), encoding='utf-8') as f:
                lines += [x.split('!')[0].rstrip() for x in f.read().split('\n')]
        else:
            lines.append(l.split('!')[0].rstrip())

    def run(block, env, out):
        i, live = 0, [True]
        while i < len(block):
            l = block[i].strip()
            i += 1
            if not l:
                continue
            m = re.match(r'\.(ifdef|ifndef)\s+(\w+)', l)
            if m:
                live.append(live[-1] and ((m.group(2) in syms) == (m.group(1) == 'ifdef')))
                continue
            if l == '.endif':
                live.pop()
                continue
            if l.startswith('.irp'):
                var, vals = re.match(r'\.irp\s+(\w+)\s*,\s*(.*)', l).groups()
                depth, body = 1, []
                while depth:
                    b = block[i]
                    i += 1
                    if b.strip().startswith('.irp'):
                        depth += 1
                    elif b.strip() == '.endr':
                        depth -= 1
                        if not depth:
                            break
                    body.append(b)
                if live[-1]:
                    for v in vals.split(','):
                        run(body, dict(env, **{var: _ev(v, env)}), out)
                continue
            if not live[-1]:
                continue
            if l.startswith('vz'):
                v = [_ev(x, env) for x in l[2:].split(',')]
                out.append(bytes((v[0] & 0xFF, v[1] & 0xFF, v[2], v[3] & 0xFF, v[4] // 4, v[5] // 2, v[6] // 4,
                                  v[7] // 2)))
            elif l.startswith('.byte'):
                out.append(bytes(_ev(x, env) for x in l[5:].split(',')))
            else:
                raise ValueError('vt_zones: unexpected line %r' % l)
    out = []
    run(lines, {}, out)
    return b''.join(out)


# ---------------------------------------------------------------------------------------------------------
# stock MAIN zones (0x081010A0, 70 x {x, y, w, h, handler}) and the keyboard table (0x08101630, 6 words)
STOCK_ZONES = (
    (100, 377, 600, 103, 0x084EDC5A), (0, 302, 800, 178, 0x084EDD86), (292, 55, 216, 53, 0x084EDBE6),
    (18, 55, 68, 53, 0x084EDBF6), (18, 207, 764, 73, 0x084EDCC0), (130, 55, 70, 53, 0x084EE318),
    (635, 55, 70, 53, 0x084EE372), (18, 207, 90, 73, 0x084EE32A), (115, 207, 90, 73, 0x084EE384),
    (211, 207, 90, 73, 0x084EE33C), (307, 207, 90, 73, 0x084EE396), (403, 207, 90, 73, 0x084EE34E),
    (499, 207, 90, 73, 0x084EE3A8), (595, 207, 90, 73, 0x084EE360), (691, 207, 90, 73, 0x084EE3BA),
    (714, 55, 68, 53, 0x084EDC28), (18, 45, 68, 59, 0x084EDB16), (18, 106, 68, 59, 0x084EDB4A),
    (19, 167, 68, 58, 0x084EDB7E), (18, 227, 68, 59, 0x084EDBB2), (18, 45, 68, 62, 0x084EE3CC),
    (18, 109, 68, 62, 0x084EE3DC), (19, 180, 68, 49, 0x084EE3EC), (18, 237, 68, 49, 0x084EE3FC),
    (113, 53, 110, 36, 0x084EE40C), (113, 117, 110, 36, 0x084EE41C), (113, 181, 110, 36, 0x084EE42C),
    (113, 245, 110, 36, 0x084EE43C), (255, 53, 126, 36, 0x084EE44C), (519, 53, 126, 36, 0x084EE45C),
    (255, 117, 126, 36, 0x084EE46C), (255, 181, 419, 36, 0x084EE4CC), (255, 245, 60, 36, 0x084EE584),
    (321, 245, 60, 36, 0x084EE596), (387, 245, 60, 36, 0x084EE5A8), (453, 245, 60, 36, 0x084EE5BA),
    (519, 245, 60, 36, 0x084EE5CC), (585, 245, 60, 36, 0x084EE5DE), (651, 245, 60, 36, 0x084EE5F0),
    (717, 245, 60, 36, 0x084EE602), (714, 53, 68, 99, 0x084EE614), (100, 46, 165, 44, 0x084EE624),
    (272, 46, 165, 44, 0x084EE636), (445, 46, 165, 44, 0x084EE648), (618, 46, 165, 44, 0x084EE65A),
    (111, 213, 65, 53, 0x084EE66C), (176, 213, 65, 53, 0x084EE67C), (272, 110, 244, 36, 0x084EE68C),
    (527, 110, 244, 36, 0x084EE69E), (272, 170, 244, 36, 0x084EE6B0), (527, 170, 244, 36, 0x084EE6C2),
    (272, 230, 244, 36, 0x084EE6D4), (572, 230, 244, 36, 0x084EE6E6), (29, 41, 70, 53, 0x084EE6F8),
    (99, 41, 68, 53, 0x084EE708), (29, 128, 69, 53, 0x084EE738), (99, 128, 70, 53, 0x084EE728),
    (169, 128, 70, 53, 0x084EE718), (29, 217, 70, 53, 0x084EE748), (99, 217, 70, 53, 0x084EE75A),
    (169, 217, 69, 53, 0x084EE76C), (238, 217, 69, 53, 0x084EE7CC), (328, 128, 65, 53, 0x084EE7DE),
    (402, 128, 65, 53, 0x084EE7EE), (328, 217, 70, 53, 0x084EE7FE), (398, 217, 70, 53, 0x084EE810),
    (617, 14, 164, 66, 0x084EE822), (617, 80, 164, 66, 0x084EE834), (617, 146, 164, 66, 0x084EE846),
    (617, 209, 164, 66, 0x084EE858),
)
ZONE_TAB, KBD_TAB, THR_TAB = 0x081010A0, 0x08101630, 0x08101A68
STOCK_KBD = tuple((37 + 66 * i, 302, 66, 50) for i in range(10)) + tuple((70 + 66 * i, 352, 66, 54) for i in range(9)) + \
    tuple((103 + 66 * i, 406, 66, 50) for i in range(7)) + \
    ((18, 410, 65, 46), (717, 302, 65, 50), (693, 406, 89, 50), (693, 352, 89, 54))
STOCK_THR = (95, 191, 286, 382, 477, 573, 668, 764)
CLASS_ZONES = {4: tuple(range(16, 20)), 8: (20, 21) + tuple(range(23, 41)), 9: tuple(range(20, 24)) + tuple(range(41, 53)),
               10: tuple(range(53, 70))}


def load_v2needle():
    """v2ui.py's v2needle constants (the stock zone pokes as built today)."""
    import importlib.util
    if MODS not in sys.path:
        sys.path.insert(0, MODS)
    spec = importlib.util.spec_from_file_location('_v2ui_place', V2UI)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def current_stock():
    """{zone: R} and the pad thresholds after v2needle (CDJ_V3E2=1, the default) -- handlers are not modelled
    beyond 'off' (w = h = 0)."""
    m = load_v2needle()
    z = {n: R(*v[:4]) for n, v in enumerate(STOCK_ZONES)}
    for n, _, new, _ in m.SC_ZONES:
        z[n] = R(*new)
    for n, _, new in m.HDR_ZONES + m.FILTER_ZONES + m.PAD_ZONES:
        z[n] = R(*new)
    z[0] = R(*m.NEEDLE_V2[:4])
    z[2] = R(*m.PMETER_V2[:4])
    return z, tuple(m.PAD_THR_V3)


def pad_slices(z4, thr):
    """Zone 4's 8 pads: idx = the first threshold >= x - x0 (handler 0x084EDCC0)."""
    out, lo = [], 0
    for k, th in enumerate(thr):
        x0 = z4.x + (lo if k == 0 else lo + 1)
        out.append(R.e(x0, z4.y, min(z4.x + th + 1, z4.x1), z4.y1))
        lo = th
    return out


# ---------------------------------------------------------------------------------------------------------
# the live zones of a state, in MAIN's order (first hit wins): (zid, rect, swallow?, vz row / None)
Z = namedtuple('Z', 'zid r swallow row')


POP_BOX = R.e(230, 88, 570, 420)         # modsmenu vt_pop (CENTPOP): the pop-up's box; model screen 0x02: the pane
POP_PANE = R.e(457, 88, 800, 420)


def vt_live(rows, st, syms):
    if st.pop and not st.kb and st.cls in (1, 2, 3):
        # vt_hit -> vt_pop: inside the box va_touch 14 (rows / OK / CANCEL), anywhere else BACK
        box = POP_PANE if st.sid == 0x02 else POP_BOX
        if st.sid != 0x02:      # va_touch: a tap in the box but outside the modal's frame = BACK too
            n = int(next(m[1:] for m in st.modes if re.fullmatch(r'n\d', m)))
            box = box.inter(popup_modal(n, 'taglist' in st.modes)['frame'])
        return [Z('vt:pop.in', box, False, VZ(st.cls, 0xFF, 14, 0, box.x, box.y, box.x1, box.y1, None,
                                               'lpt.pane' if st.sid == 0x02 else st.name + '.box')),
                Z('vt:pop.back', R(0, 0, W, H), True, None)]
    if st.cls in (2, 3) and st.kb:
        return []                                   # vt_hit: keyboard -> stock's
    out = []
    for r in rows:
        if not _on(r.flag, syms) or r.cls != st.cls:
            continue
        if r.scr == VT_SRC:                         # vt_hit: SOURCE only (screen 0x00, slot 1 a medium)
            if 'source' not in st.modes:
                continue
        elif r.scr != 0xFF and r.scr != st.sid:
            continue
        if r.act == 18 and st.sid == 0x00:
            continue                                # TOUCH: PREVIEW only off the root / SOURCE (va_touch)
        if r.act == 15 and r.arg != 5 and 'grid' not in st.modes:
            continue                                # TOUCH: GRID ADJUST panel zones in that mode only (vt_hit)
        if r.act == 12:                             # KEYSHIFT gating (vt_hit)
            if r.arg == 6:
                if 'ks_rbm' not in st.modes:
                    continue
            elif 'ks_on' not in st.modes or (r.arg != 1 and 'ks_panel' not in st.modes):
                continue
        out.append(Z('vt:' + r.tid, vz_rect(r), r.act == 0 or (r.act == 12 and r.arg == 5) or
                     (r.act == 15 and r.arg == 6), r))
    return out


def stock_live(st, zones, thr):
    if st.cls == 1:
        ids = [6, 5, 2, 3, 15]
        out = [Z('z%d' % n, zones[n], False, None) for n in ids]
        if 'pads_loop' in st.modes:
            out += [Z('z4.%d' % k, r, False, None) for k, r in enumerate(pad_slices(zones[4], thr))]
        elif 'pads_bj' in st.modes:
            out += [Z('z%d' % n, zones[n], False, None) for n in (8, 7, 10, 9, 12, 11, 14, 13)]
        else:
            out.append(Z('z0', zones[0], False, None))
    elif st.cls in CLASS_ZONES:
        out = [Z('z%d' % n, zones[n], False, None) for n in CLASS_ZONES[st.cls]]
    elif st.kb:
        out = [Z('kbd%d' % i, R(*k), False, None) for i, k in enumerate(STOCK_KBD)] + [Z('z1', zones[1], True, None)]
    else:
        out = [Z('z0', zones[0], False, None)]      # 0x084EDAAA's fallback: the needle zone
    return [z for z in out if z.r.w > 0 and z.r.h > 0]


def live_current(st, variant='ks', stock_state=None):
    zones, thr = stock_state or current_stock()
    return vt_live(map_vt_rows(), st, VARIANTS[variant]) + stock_live(st, zones, thr)


def hit(live, x, y):
    for z in live:
        if z.r.has(x, y):
            return z
    return None


def expected_zid(tg, st, live):
    """The zone ids that implement target tg in state st (several: a vt row per class)."""
    a, owner = tg.act, BY_ID[tg.zone_of] if tg.zone_of else tg
    if owner.act.kind == 'vt':
        return {z.zid for z in live if z.row is not None and z.row.tid == owner.tid}
    if a.kind == 'stock':
        return {'z%d.%d' % (a.code, a.arg)} if a.arg is not None else {'z%d' % a.code}
    if a.kind == 'kbd':
        return {'kbd%d' % a.code}
    return set()


# ---------------------------------------------------------------------------------------------------------
# (c) audit of the CURRENT tables
Issue = namedtuple('Issue', 'sev state what tid rect detail')


def _sample(r, step):
    for y in range(r.y, r.y1, step):
        for x in range(r.x, r.x1, step):
            yield x, y


def audit(variant='ks', tables='current'):
    """Issues: DEAD (nothing / a swallow at the centre), WRONG (another target's zone), PARTIAL (< 90 % of the
    drawn rect reaches its zone), STEAL (>= 2 % of it, >= 3 x 3 px, lands in another live zone), NEW (proposed
    action, nothing live yet), PHANTOM (a live non-swallow zone where nothing touchable is drawn, >= 300 px^2).
    tables: 'current' (modsmenu + v2needle as built) or 'map' (map_vt_rows + map_stock)."""
    ss = current_stock() if tables == 'current' else map_stock()
    rows = map_vt_rows()        # TOUCH (V4n41): modsmenu builds the map's rows (touch_vt_zones.inc) -- both tables
    out = []
    for st in STATES.values():
        if 'KEYSHIFT' not in VARIANTS[variant] and any(m.startswith('ks_') for m in st.modes):
            continue                                # no KEY SHIFT in this build
        live = vt_live(rows, st, VARIANTS[variant]) + stock_live(st, *ss)
        tgs = [x for x in TARGETS if st.name in x.states]
        for tg in tgs:
            if tg.kind not in TOUCHABLE:
                continue
            exp = expected_zid(tg, st, live)
            z = hit(live, tg.r.cx, tg.r.cy)
            got = z.zid if z else None
            if tg.act.kind == 'new':
                if z is None or z.swallow:
                    out.append(Issue('NEW', st.name, 'dead (action %s not in MAIN)' % tg.act.code, tg.tid, tg.r,
                                     'centre -> %s' % (got or 'nothing')))
                else:
                    out.append(Issue('WRONG', st.name, 'hits another zone (action %s not in MAIN)' % tg.act.code,
                                     tg.tid, tg.r, 'centre -> %s %s' % (got, z.r)))
                continue
            if got is None or (z.swallow and got not in exp):
                out.append(Issue('DEAD', st.name, 'no live zone', tg.tid, tg.r, 'centre -> %s' % (got or 'nothing')))
                continue
            if got not in exp:
                out.append(Issue('WRONG', st.name, 'centre hits another zone', tg.tid, tg.r,
                                 'centre -> %s %s, want %s' % (got, z.r, '/'.join(sorted(exp)))))
                continue
            pts = list(_sample(tg.r, 2))
            hz = [hit(live, x, y) for x, y in pts]
            good = sum(1 for h in hz if h is not None and h.zid in exp)
            steal = {}
            for h in hz:
                if h is not None and not h.swallow and h.zid not in exp:
                    steal[h.zid] = steal.get(h.zid, 0) + 1
            for zid, n in sorted(steal.items()):
                zr = next(h.r for h in hz if h is not None and h.zid == zid)
                part = tg.r.inter(zr)
                if n >= 0.02 * len(pts) and part.w >= 3 and part.h >= 3:     # (1-2 px: quantisation)
                    out.append(Issue('STEAL', st.name, '%d %% of it goes to %s' % (100 * n // len(pts), zid), tg.tid,
                                     tg.r, 'stolen part %s' % (part,)))
            if good < 0.9 * len(pts):
                out.append(Issue('PARTIAL', st.name, '%d %% of the drawn rect reaches its zone'
                                 % (100 * good // len(pts)), tg.tid, tg.r, 'zone %s' % (z.r,)))
        # phantoms / shadows
        drawn = [x.r.grow(SLOP + QTOL, SLOP + QTOL) for x in tgs if x.kind in TOUCHABLE]
        for i, z in enumerate(live):
            if z.swallow:
                continue
            mine = [(x, y) for x, y in _sample(z.r, 4) if hit(live, x, y) is z]
            if not mine:                                # fully shadowed: harmless
                continue
            ph = [(x, y) for x, y in mine if not any(d.has(x, y) for d in drawn)]
            if len(ph) * 16 >= 300:
                xs, ys = [p[0] for p in ph], [p[1] for p in ph]
                bb = R.e(min(xs), min(ys), max(xs) + 4, max(ys) + 4)
                out.append(Issue('PHANTOM', st.name, 'live zone where nothing touchable is drawn',
                                 z.zid, z.r, 'phantom part %s (~%d px^2)' % (bb, len(ph) * 16)))
    return out


# issues the map's tables cannot fix by geometry alone: each needs a MAIN change (a new vz condition / action)
STRUCTURAL = (
    ('NEW', r'.*', r'.*', 'proposed action: pop-up rows / OK / CANCEL, UTILITY rows + options, SOURCE rows, PREVIEW'),
    (r'\w+', r'player\.lpt|pop\.\w+', r'.*', 'pop-up open: vz rows have no pop-up condition (vt_hit leaves '
     'classes 2/3 to stock; class 1 keeps the player zones under the LPT pane) -> a pop-up zone table + outside = BACK'),
    (r'\w+', r'source', r'.*', 'SOURCE shares class 2 / model screen 0x00 with the lists: needs a SOURCE condition '
     '(slot 1 icon = a medium, as v2.c is_src_icon) and its own 64-px rows'),
    ('PHANTOM', r'player\.ksp', r'vt:p\.zoomgrid', 'TOUCH: the ZOOM - GRID label lies under the KEY SHIFT panel\'s '
     'K.SYNC tile (both drawn there); its zone stays live beside / below the panel row'),
    ('PHANTOM', r'list\.root', r'vt:b\.(rows|colhdr)', 'root: the rows are a dim preview, a tap moves the hidden '
     'root cursor (3000: the rail is the root) -> decide: rows off in root, or tap = open the category'),
    ('DEAD', r'search\.kb', r'b\.(src|rail\d)', 'keyboard up: vt_hit hands everything to stock'),
    ('DEAD', r'util\.edit', r'u\.cat\d', 'category tiles are model screen 0x0A only'),
    ('DEAD', r'player\.(loop|bj)', r'p\.overview', 'stock class 1 in pad mode tests zone 4 / 7..14 only, no zone 0'),
    ('PHANTOM', r'pinfo', r'z1[6-9]', 'PLAYER 1..4 tabs (class 4 is also stock\'s LINK player list): off only if '
     'that list is never stock-drawn'),
    ('PHANTOM', r'filter|mytag', r'z2[013]', 'vt action 11 remaps the header tabs onto these: move them to the tab '
     'rects instead and drop the remap'),
)


def structural(i):
    """The STRUCTURAL rule (reason) that covers issue i, or None."""
    for sev, st, tid, why in STRUCTURAL:
        if re.fullmatch(sev, i.sev) and re.fullmatch(st, i.state) and re.fullmatch(tid, i.tid):
            return why
    return None


# ---------------------------------------------------------------------------------------------------------
# the map's own hit rects: drawn + slop, split at the gap middle between neighbours, quantised (x 4, y 2)
def _slop(r):
    return r.grow(SLOP if r.w < SLOP_BELOW else 0, SLOP if r.h < SLOP_BELOW else 0).clip()


def _pairs(tg):
    for i, p in enumerate(tg):
        for q in tg[i + 1:]:
            if set(p.states) & set(q.states):
                yield p, q


def _split(hr, p, q, m_of):
    """Two overlapping hit rects: cut both at the boundary m_of(gap_lo, gap_hi) between their drawn rects."""
    P, Q = p.r, q.r
    if P.x1 <= Q.x or Q.x1 <= P.x:                  # side by side: split x
        lo, hi, m = (p.tid, q.tid, m_of(P.x1, Q.x, 4)) if P.x1 <= Q.x else (q.tid, p.tid, m_of(Q.x1, P.x, 4))
        hr[lo] = R.e(hr[lo].x, hr[lo].y, min(hr[lo].x1, m), hr[lo].y1)
        hr[hi] = R.e(max(hr[hi].x, m), hr[hi].y, hr[hi].x1, hr[hi].y1)
    elif P.y1 <= Q.y or Q.y1 <= P.y:                # stacked: split y
        lo, hi, m = (p.tid, q.tid, m_of(P.y1, Q.y, 2)) if P.y1 <= Q.y else (q.tid, p.tid, m_of(Q.y1, P.y, 2))
        hr[lo] = R.e(hr[lo].x, hr[lo].y, hr[lo].x1, min(hr[lo].y1, m))
        hr[hi] = R.e(hr[hi].x, max(hr[hi].y, m), hr[hi].x1, hr[hi].y1)
    # drawn rects that overlap each other are a map error (test_drawn_targets_disjoint)


def hit_rects(quant=True):
    """{tid: R} for every button / area target (subs and swallows are not separate zones): the drawn rect +
    SLOP on each axis under SLOP_BELOW px, cut at the middle of the gap to an overlapping neighbour; with quant,
    widened outwards to MAIN's x / 4, y / 2 grid, a shared edge rounded to the nearest grid line on both sides."""
    tg = [x for x in TARGETS if x.kind in ('button', 'area')]
    hr = {x.tid: _slop(x.r) for x in tg}
    for p, q in _pairs(tg):
        if hr[p.tid].inter(hr[q.tid]):
            _split(hr, p, q, lambda a, b, g: (a + b) // 2)
    if not quant:
        return hr
    for tid, r in hr.items():
        hr[tid] = R.e(r.x // 4 * 4, r.y // 2 * 2, min(W, (r.x1 + 3) // 4 * 4), min(H, (r.y1 + 1) // 2 * 2))
    for p, q in _pairs(tg):
        if hr[p.tid].inter(hr[q.tid]):
            _split(hr, p, q, lambda a, b, g: ((a + b) // 2 + g // 2) // g * g)
    return hr


def map_vt_rows():
    """CURRENT_VT with each row's rect re-derived from its target's hit rect (swallows keep theirs); the
    any-screen swallows (deck strips) move to the end, behind every target of their class (the rail's FOLDER
    tile reaches y 420, the strip swallow starts at 410)."""
    hr = dict(hit_rects(), **MAP_SWALLOW)
    out = []
    for r in CURRENT_VT:
        n = hr.get(r.tid)
        out.append(r if n is None else r._replace(x0=n.x, y0=n.y, x1=n.x1, y1=n.y1))
    late = [r for r in out if r.act == 0 and r.scr == 0xFF]
    return [r for r in out if r not in late] + late


# swallow rows the map widens: UTILITY's strip from y 404 (stock zone 0 starts at 405; nothing is drawn at
# 396..420 there), INFO's right pane from y 54 (the column header's slop band would leak over the pane)
MAP_SWALLOW = {'u.strip': R.e(0, 404, W, H), 'b.info_pane': R.e(452, 54, W, 420)}


# stock zones the map switches off (w = h = 0): drawn nowhere in their class. 68 = SCREEN MODE (tile removed in
# V3rc8q, its handler sm_cycle also toggles PHASE METER TYPE), 22 = the MY TAG page's third left tab (not a
# vt action-11 remap target). 16..19 (player INFO / LINK player list tabs) and 20 / 21 / 23 (vt action 11
# remap targets) stay: see re/TOUCH_MAP.md.
MAP_STOCK_OFF = (22, 68)


def map_stock():
    """(zones, thresholds) as the map would poke them."""
    zones, _ = current_stock()
    zones = dict(zones)
    hr = hit_rects(quant=False)
    for x in TARGETS:
        if x.act.kind == 'stock' and x.act.arg is None and x.tid in hr:
            zones[x.act.code] = hr[x.tid]
    pads = [hr['p.loop_pad%d' % k] for k in range(8)]
    zones[4] = R.e(pads[0].x, pads[0].y, pads[-1].x1, pads[0].y1)
    thr = tuple([(pads[k].x1 + pads[k + 1].x) // 2 - zones[4].x - 1 for k in range(7)] + [zones[4].w - 1])
    for n in MAP_STOCK_OFF:
        zones[n] = R(0, 0, 0, 0)
    return zones, thr


def proposed_rows():
    """Targets whose action MAIN does not have yet (pop-ups, UTILITY rows / options, SOURCE rows, PREVIEW)."""
    hr = hit_rects()
    out = []
    for x in TARGETS:
        if x.act.kind == 'new' and x.tid in hr:
            st = STATES[x.states[0]]
            out.append('%-16s cls %d scr %#04x %-10s arg %-4s %s  (%s)' % (x.tid, st.cls, st.sid, x.act.code,
                                                                       x.act.arg, hr[x.tid], ','.join(x.states)))
    return out


def vt_diff():
    """Rows whose map rect differs from the hand-written one: (index, tid, current R, map R)."""
    return [(i, a.tid, vz_rect(a), vz_rect(b)) for i, (a, b) in enumerate(zip(CURRENT_VT, map_vt_rows()))
            if vz_pack(a) != vz_pack(b)]


def stock_diff():
    """Stock zones (as v2needle pokes them) vs the map: (zone, target, current, map); zone 4 with thresholds."""
    (cz, cthr), (mz, mthr) = current_stock(), map_stock()
    owner = {x.act.code: x.tid for x in TARGETS if x.act.kind == 'stock'}
    out = []
    for n in range(len(STOCK_ZONES)):
        if n != 4 and cz[n] != mz[n]:
            out.append(('z%d' % n, owner.get(n, '(off)'), cz[n], mz[n]))
    if cz[4] != mz[4] or cthr != mthr:
        out.append(('z4', 'p.loop_pad*', '%s thr %s' % (cz[4], cthr), '%s thr %s' % (mz[4], mthr)))
    return out


# ---------------------------------------------------------------------------------------------------------
# (b) v2_touch.h
def v2_touch_h():
    hr = hit_rects()
    o = ['/* generated by mods/v2ui/touch_map.py -- do not edit (re/TOUCH_MAP.md) */',
         '#ifndef V2_TOUCH_H', '#define V2_TOUCH_H', '',
         '/* TM_<ID>_R = x, y, w, h as drawn (fill(TM_X_R, c)); TM_<ID>_HR = the touch rect (+%d px slop under %d px,'
         % (SLOP, SLOP_BELOW), ' * quantised as MAIN stores it); TM_<ID>_PID = the press-feedback id */']
    pid = 1
    fam = {}
    for x in TARGETS:
        m = re.match(r'(.*?)(\d+)$', x.tid)
        if m and x.kind != 'swallow':
            fam.setdefault(m.group(1), []).append(x)
    for x in TARGETS:
        if x.kind == 'swallow':
            continue
        n = 'TM_' + re.sub(r'[^A-Za-z0-9]', '_', x.tid).upper()
        o.append('#define %-28s %d, %d, %d, %d\t/* %s%s */' % (n + '_R', x.r.x, x.r.y, x.r.w, x.r.h, x.kind,
                                                                ': ' + x.note if x.note else ''))
        if x.tid in hr:
            r = hr[x.tid]
            o.append('#define %-28s %d, %d, %d, %d' % (n + '_HR', r.x, r.y, r.w, r.h))
        if x.kind in TOUCHABLE:
            o.append('#define %-28s %d' % (n + '_PID', pid))
            pid += 1
    o += ['', '/* repeated families: member k at X0 + k * DX, Y0 + k * DY */']
    for base, ms in fam.items():
        if len(ms) < 3:
            continue
        a, b = ms[0].r, ms[1].r
        n = 'TM_' + re.sub(r'[^A-Za-z0-9]', '_', base).upper().rstrip('_')
        o.append('#define %-24s %d\n#define %-24s %d\n#define %-24s %d\n#define %-24s %d\n#define %-24s %d\n'
                 '#define %-24s %d\n#define %-24s %d' % (n + '_N', len(ms), n + '_X0', a.x, n + '_Y0', a.y,
                                                         n + '_DX', b.x - a.x, n + '_DY', b.y - a.y, n + '_W', a.w,
                                                         n + '_H', a.h))
    o += ['', '/* the pop-up modal (popup()): n items -> frame y0 = max(66, 236 - bh / 2), bh = 52 + 34 n + 8 (+50 TAG LIST)',
          ' * row k (1..n) = 236, y0 + 46 + 34 (k - 1), 328 x 32; OK / CANCEL at 290 / 410, y0 + bh - 46, 100 x 34 */',
          '#define TM_POP_X 230', '#define TM_POP_W 340', '#define TM_POP_ROW_X 236', '#define TM_POP_ROW_W 328',
          '#define TM_POP_ROW_DY0 46', '#define TM_POP_ROW_DY 34', '#define TM_POP_ROW_H 32',
          '#define TM_LPT_X 457', '#define TM_LPT_ROW_Y0 90', '#define TM_LPT_ROW_DY 40', '#define TM_LPT_ROW_H 39',
          '', '#define TM_SLOP %d' % SLOP, '#define TM_NPID %d' % pid, '', '#endif', '']
    return '\n'.join(o)


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--inc', help='write the current vt_zones table (.inc, modsmenu format)')
    ap.add_argument('--map-inc', help='write the vt_zones table re-derived from the map (+ proposed rows as comments)')
    ap.add_argument('--header', help='write v2_touch.h')
    ap.add_argument('--diff', action='store_true', help='hand-written vs generated vs map')
    ap.add_argument('--audit', action='store_true', help='dead / misaligned / phantom targets of the current tables')
    ap.add_argument('--variant', default='ks', choices=sorted(VARIANTS))
    ap.add_argument('--tables', default='current', choices=('current', 'map'), help='which tables --audit checks')
    a = ap.parse_args(argv)
    if a.inc:
        open(a.inc, 'w').write(vt_inc())
    if a.map_inc:
        open(a.map_inc, 'w').write(vt_inc(map_vt_rows(), proposed_rows()))
    if a.header:
        open(a.header, 'w').write(v2_touch_h())
    if a.diff:
        for v in sorted(VARIANTS):
            hw, gen = parse_modsmenu_vt(v), vt_bytes(variant=v)
            print('vt_zones %-8s hand-written %4d B, generated %4d B: %s' % (v, len(hw), len(gen),
                                                                            'IDENTICAL' if hw == gen else 'DIFFERENT'))
        print('\nvt rows: hand-written -> map (drawn + %d px slop, quantised)' % SLOP)
        for i, tid, c, m in vt_diff():
            print('  #%-3d %-14s %-24s -> %s' % (i, tid, c, m))
        print('\nstock zones (v2needle) -> map')
        for z, tid, c, m in stock_diff():
            print('  %-4s %-14s %-24s -> %s' % (z, tid, c, m))
        print('\nproposed (no MAIN action yet):')
        for p in proposed_rows():
            print('  ' + p)
    if a.audit:
        for i in audit(a.variant, a.tables):
            print('%-7s %-12s %-16s %-22s %s; %s' % (i.sev, i.state, i.tid, i.rect, i.what, i.detail))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
