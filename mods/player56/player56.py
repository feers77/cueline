#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""PLAYER No. 5/6 for the CDJ-2000NXS2 MAIN (v1.87), opt-in, not in mods.conf.
RE notes: re/PLAYER56_RE.md. Every patch checks the stock bytes first.

  option A (the NXS2 itself as player 5/6)
    a1   0x083DFDAC  lnk_syscnfini: own number 1..4 else 1  -> 1..6
    a2   0x084B8156  status (0x0A) builder: own number < 5   -> < 7
    a3   0x084B2F0E  sync module own-slot switch, default arm -> cave p56_stubA
                     (the 3 "other" records for the counter 0x084AF2C2 come from p56_pick3)
    a4   UTILITY PLAYER No. item record (label 0xA80FDB90): values list -> p56_vals
                     (AUTO,1..6, stock strings), count 5 -> 7; patched wherever the
                     record lives (.data 0x08570DBC and modsmenu's copied table)
  option B (peers 5/6)
    b1   0x083FE91E  status (0x0A) receive: device < 5       -> < 7
    b2   0x083FD212  LNKH slot query: device > 4 rejected     -> > 6
    b4a  0x084B59C8  media-tracking loop players 1..4        -> 1..6
    b4b  0x084B5760/0x084B576E  "players with media" count loop 1..4 -> 1..6 [G]
    b4m  0x084B6084  master detection own switch           -> cave p56_stubB (p56_pick3:
                     the 3 "others" checked for the master flag; own 5/6 no longer
                     leaves that array uninitialised)
  gui78 (needs a GUI that knows codes 7/8 -- V2; NOT for the stock GUI)
    a7   own 5/6 announces like a CDJ-3000 at 5/6 (P56_NOTES.md §2): the 13 literal words naming the
         50000 sender 0x083E2534 -> p56ann.bin at 0x081C7F00 (standalone, 112 B): 0x0a [0x21]=4,
         len 38, [0x25]=0x40; 0x00/02/04 [0x21]=3; 0x06 [0x35]=0x64. Own 1..4: stock bytes.
    b3   0x084E3690  deck-state master/source range 1..4 -> 1..6
    b3g  0x084E44E6  device -> source code: + 5 -> 7, 6 -> 8 (in-place rewrite, src78.S)

The cave (p56.bin, build.sh) is placed at P56_BASE = 0x081C4000, 16 KB (KEY SHIFT DSP table
ends 0x081C22C8; RAMB at 0x081E0000 is above); the area must
be erased (0xFF) when applied.

usage: player56.py <main_unpacked.bin> <out.bin> [set|patch,...]
  sets: proven (a1 a2 b1 b2), a, b, ab (a + b), all (ab + gui78)
"""
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = 0x08000000
P56_BASE = 0x081C4000
P56_SIZE = 0x4000         # reserved for the cave (p56.bin + data), up to 0x081C8000; RAMB at 0x081E0000 is above


def _imm(addr, old, new, what, proven):
    return ('imm', addr, bytes.fromhex(old), bytes.fromhex(new), what, proven)


def _tramp(addr, lit_off, sym, what, proven, reg=0):
    return ('tramp', addr, lit_off, sym, what, proven, reg)


GUI78 = bytes.fromhex('43604362218810891188108912880e8908200e89058806890688048904e2'
                      '2630078907a0436205a0027203a005e201a006e200e20b002360') + b'\x09\x00\x09\x00'

PATCHES = {
    'a1': [_imm(0x083DFDAC, '04e5', '06e5', 'lnk_syscnfini own number range 1..6', True)],
    'a2': [_imm(0x084B8156, '05e2', '07e2', 'status builder accepts own number 5/6', True)],
    'a3': [_tramp(0x084B2F0E, 6, 'p56_stubA', 'sync own-slot default arm -> p56_pick3', True)],
    'a4': [('ut', 'UTILITY PLAYER No. AUTO,1..6', True)],
    'b1': [_imm(0x083FE91E, '05e2', '07e2', 'status receive accepts device 5/6', True)],
    'b2': [_imm(0x083FD212, '04e2', '06e2', 'LNKH slot query accepts device 5/6', True)],
    'b4a': [_imm(0x084B59C8, '04ed', '06ed', 'media-tracking loop players 1..6', True)],
    'b4b': [_imm(0x084B5760, '03ee', '05ee', 'media count loop pairs up to 5/6', False),
            _imm(0x084B576E, '04e2', '06e2', 'media count loop tail 1..6', False)],
    'b4m': [_tramp(0x084B6084, 8, 'p56_stubB', 'master detection others -> p56_pick3', True)],
    'b3': [_imm(0x084E3690, '04e2', '06e2', 'deck-state master/source range 1..6', False)],
    'b3g': [('raw', 0x084E44E6,
             bytes.fromhex('43600188018b17a029020288018b13a002e20388018b0fa003e20488018b0ba004e22188018b07a005e2118801891288018b01a006e200e20b002360'), GUI78,
             'device -> source code 5->7, 6->8 (gui78)', False)],
}


def _ctx_sites():
    import json
    out = []
    p = os.path.join(HERE, 'sites.json')
    if not os.path.exists(p):
        return out
    for e in json.load(open(p)):
        site, end = e['site'], e['end']
        lit_off = 8 if site % 4 == 0 else 6
        out.append(('stramp', site, end, bytes.fromhex(e['orig']), lit_off, e['sym'], e['rA'],
                    'record m*0x938 (%s, m=r%d) -> %s' % (e['form'], e['rM'], e['sym'])))
    return out



def _sess_sites():
    import json
    out = []
    p = os.path.join(HERE, 'sites_sess.json')
    if not os.path.exists(p):
        return out
    for e in json.load(open(p)):
        site, end = e['site'], e['end']
        lit_off = 8 if site % 4 == 0 else 6
        out.append(('stramp', site, end, bytes.fromhex(e['orig']), lit_off, e['sym'], e['rA'],
                    'session m*0x1218 (%s, m=r%d) -> %s' % (e['form'], e['rM'], e['sym'])))
    return out


# ctxsess (opt-in, coordinator-approved 2026-11-09): the per-player session table (ctx+0xA638, 4 x 0x1218)
# gets players 5/6 at ctx+0x28EC0 / ctx+0x2A0D8 (end 0x2B2F0); ctx alloc 0x29000 -> 0x2B400 (needs ctxalloc first).
PATCHES['ctxsess'] = ([_imm(0x08279C7C, '00900200', '00b40200', 'browse ctx alloc 0x29000 -> 0x2B400 (session table 5/6)', True)]
                      + _sess_sites() + [('sym32', 'p56_sessOn', 1, 'init session entries 5/6 in p56_stubInit')])


CTX_CHECKS = [   # 1..4 checks in front of player record paths: mov #4,rX -> mov #6,rX
    (0x082567EE, 'e2'), (0x08265194, 'e6'), (0x08266AE0, 'e5'), (0x0827A080, 'e2'), (0x0827A128, 'e2'),
    (0x0827A388, 'e2'), (0x0827A49E, 'e2'), (0x0827DD0E, 'e5'), (0x0827EA0E, 'e2'), (0x0827F7D0, 'e2'),
    (0x0826599A, 'e2'), (0x082659C0, 'e2'), (0x08265F68, 'e2'), (0x08279096, 'e2'),
    # device-classifier chains (1..4 / 17..18 / 33 / 41..44) whose player path is a patched record site
    # or device-generic code (static scan of `mov #4; cmp/gt|hi; ... mov #17`), 2026-11-09 night
    (0x0825A6DC, 'e2'), (0x0825A892, 'e4'), (0x0825DF84, 'e2'), (0x08264568, 'e2'), (0x08266708, 'e2'), (0x0826BB94, 'e2'), (0x0826C062, 'e2'), (0x08273806, 'e6'), (0x0827842A, 'e5'), (0x08280158, 'e2'), (0x08286512, 'e6'), (0x082919DE, 'e6'),
    # per-record / LNKH-query / UI source chains (broader scan: `mov #1; cmp/hs|ge; ...; mov #4; cmp/hi|gt`)
    (0x0825A77E, 'e4'), (0x0825AAF2, 'e5'), (0x0825AC68, 'e5'), (0x0825AE48, 'e5'), (0x0825AFB6, 'e5'),
    (0x0825B1BC, 'e5'), (0x0825B2C4, 'e5'), (0x0825B45C, 'e5'), (0x0825B8CC, 'e5'), (0x0827C4CC, 'e2'),
    (0x0827EBE0, 'e2'), (0x08281720, 'e2'), (0x082817AE, 'e2'), (0x08284E4A, 'e2'), (0x08284F4E, 'e2'),
    (0x08286A6C, 'e6'), (0x082AFF4E, 'e2'), (0x082C1012, 'e6'), (0x084C691E, 'e2'), (0x084C8996, 'e6'),
    # function-entry 1..4 checks in front of the record lookup 0x0827A194 / own-record move 0x08264314
    (0x0825592C, 'e4'), (0x0825776E, 'e2'), (0x0826570C, 'e2'), (0x0826444A, 'e2'),
]
ANN_BASE = 0x081C7F00     # p56ann.bin (build.sh), last 256 B of the cave reserve; p56.bin must end below
ANN_SEND = 0x083E2534     # stock 50000 sender (buffer 0x0AB8530C)
ANN_LITS = (0x083E29EC, 0x083E2C98, 0x083E31E8, 0x083E3494, 0x083E37CC, 0x083E3A50, 0x083E3D4C,
            0x083E4028, 0x083E4310, 0x083E460C, 0x083E4888, 0x083E4B14, 0x083E4DC4)


def _ann():
    blob = open(os.path.join(HERE, 'p56ann.bin'), 'rb').read()
    assert len(blob) <= 0x100 and struct.unpack_from('<I', blob, len(blob) - 4)[0] == ANN_SEND
    return ([_imm(ANN_BASE, 'ff' * len(blob), blob.hex(), 'p56ann stub (CDJ-3000 announce bytes at 5/6)', True)]
            + [_imm(a, struct.pack('<I', ANN_SEND).hex(), struct.pack('<I', ANN_BASE).hex(),
                    '50000 sender literal -> p56ann', True) for a in ANN_LITS])


PATCHES['a7'] = _ann()
PATCHES['a5'] = [('raw', 0x084E3A4E, bytes.fromhex('0188078902880789038807890488078908a0090008a001e206a002e204a003e202a004e2ffe22c62'), bytes.fromhex('03622822028906e556320d8bffe22c620aa009000900090009000900090009000900090009000900'),
                   'deck-state own number: 1..4 else 0xFF -> 1..6 else 0xFF (0x0B568E6C+0x5C)', True)]
PATCHES['a6'] = [   # own "others" switches: default arm -> p56_pick3 (stock arms for own 2/3/4 untouched)
    ('stramp', 0x084AEBA2, 0x084AEBAC, bytes.fromhex('02eb03e1184b05e2487b'), 6, 'p56_stubC1', 1, 'others r12/r11/r8 (P=r8)'),
    ('stramp', 0x084AEDFA, 0x084AEE04, bytes.fromhex('02ec03e1184c05e2487c'), 6, 'p56_stubC2', 1, 'others r13/r12/r9 (P=r9)'),
    ('stramp', 0x084AF078, 0x084AF084, bytes.fromhex('03e405e202ee18441842a367'), 8, 'p56_stubC3', 4, 'others r1/r7/r10 (P=r10)'),
]
PATCHES['ctxalloc'] = [_imm(0x08279C7C, '80640200', '00900200', 'browse ctx alloc 0x26480 -> 0x29000 (records 5/6 end 0x27CDC)', True)]
PATCHES['ctxinit'] = [_tramp(0x08279AD4, 8, 'p56_stubInit', 'ctx init: records for players 5/6', True)]
PATCHES['ctxsites'] = _ctx_sites()
PATCHES['ctxchk'] = [_imm(a, '04' + r, '06' + r, 'browse player check 1..4 -> 1..6', True) for a, r in CTX_CHECKS]
PATCHES['syncarr'] = [
    _imm(0x084B7632, '28e6', '38e6', 'A8 memset 40 -> 56', True),
    _imm(0x084B7640, '14e6', '1ce6', 'A4 memset 20 -> 28', True),
    ('lit', 0x084B7824, 0x0B53D7EC, 'p56_A8', 0, 'A8 base'),
    ('lit', 0x084B7828, 0x0B53D814, 'p56_A4', 0, 'A4 base'),
    ('lit', 0x084B7A74, 0x0B53D818, 'p56_A4', 4, 'A4[1] base (loop 1..)'),
    ('lit', 0x084B7A8C, 0x0B53D7EC, 'p56_A8', 0, 'A8 base (loop)'),
    _imm(0x084B7AEE, '04e2', '06e2', 'sync per-player loop 1..4 -> 1..6', True),
]
# srvreq: DB server per-requester table (srv+0x527C, 0..4) -> p56_req[0..6]; checks 1..4 -> 1..6.
# Needs srvui (the UI notification arrays are 1..4 only). In-place rewrites; T is 0 at 0x082BF770/0x082BF6D8
# (fall-through of `cmp/ge; bt`), the walk at 0x082BF616 uses bra.
PATCHES['srvreq'] = [
    _imm(0x0828F62A, '04e6', '06e6', 'dbserver setup: requester 1..6', True),
    _imm(0x082ACBC4, '04e6', '06e6', 'requester-connect post 0x082ACBB8: 1..6', True),
    _imm(0x082BF76A, '05e5', '07e5', 'register: requester 1..6', True),
    ('rawsym', 0x082BF770, bytes.fromhex('52e208461842e3677c7263602c37'), bytes.fromhex('08466360' '00d7018b' '00000000' '0900'), 8, 'p56_req', 0,
     'register: &p56_req[p]'),
    _imm(0x082BF6D2, '05e6', '07e6', 'unregister: requester 1..6', True),
    ('rawsym', 0x082BF6D8, bytes.fromhex('52e2e3601842d3677c7288dc084000e42c37'), bytes.fromhex('e3600840' '01d789dc' '00e4018b' '00000000' '0900'), 12, 'p56_req', 0,
     'unregister: &p56_req[p]'),
    ('rawsym', 0x082BF616, bytes.fromhex('52e6836e1846feeb7c7604ed6c3e01ec047e'), bytes.fromhex('feeb06ed' '01de02a0' '01ec0000' '00000900' '0900'), 10, 'p56_req', 4,
     'walk: p56_req[1..6]'),
    ('lit', 0x083DD654, 0x0943D024, 'p56_req', 0, 'UI 0x083DD36E reads the requester table directly'),
    ('lit', 0x083DD8A0, 0x0943D024, 'p56_req', 0, 'UI 0x083DD6D0 reads the requester table directly'),
]
PATCHES['srvstor'] = [   # media objects USB/SD: 7 per-requester records, words moved to obj-0x100
] + [('lit', a, 0x092235F4, 'p56_mUSB', 0, 'media object USB -> 7 records') for a in
     (0x0820CD64, 0x0820D01C, 0x0820D2D4, 0x0820D52C, 0x0820D79C, 0x0820DA08)] + [
    ('lit', a, 0x09223B64, 'p56_mSD', 0, 'media object SD -> 7 records') for a in
     (0x0820CD60, 0x0820D020, 0x0820D2D8, 0x0820D520, 0x0820D7A0, 0x0820DA0C)] + [
    _imm(a, old, new, what, True) for a, old, new, what in (
        (0x0820CAF2, '7f76', '8076', 'mount: word base obj+0xE8 -> obj-0x100 (1/2)'),
        (0x0820CAF4, '6976', '8076', 'mount: word base (2/2)'),
        (0x0820CCDA, '7f7d', '807d', 'unmount: word base (1/2)'),
        (0x0820CCEA, '697d', '807d', 'unmount: word base (2/2)'),
        (0x0820D0A8, '7f77', '8077', '0x0820CE0A: word base (1/2)'),
        (0x0820D0AE, '6977', '8077', '0x0820CE0A: word base (2/2)'),
        (0x0820D242, '7f7c', '807c', '0x0820D116: word base (1/2)'),
        (0x0820D24A, '697c', '807c', '0x0820D116: word base (2/2)'),
        (0x0820D402, '7f7c', '807c', '0x0820D290: word base (1/2)'),
        (0x0820D40A, '697c', '807c', '0x0820D290: word base (2/2)'),
        (0x0820CD92, 'e8e66c66', 'ffe61846', 'SET: word base -> obj-0x100'),
        (0x0820CDFA, 'e8e44c64', 'ffe41844', 'GET: word base -> obj-0x100'),
        (0x0820CADC, '05e8', '07e8', 'mount: records 5 -> 7'),
        (0x0820CC64, '05ed', '07ed', 'mount: records 5 -> 7 (sync)'),
        (0x0820CCE8, '05ec', '07ec', 'unmount: records 5 -> 7'),
        (0x0820CD9E, '05ec', '07ec', 'SET: records 5 -> 7'),
        (0x0820D0AC, '05e1', '07e1', '0x0820CE0A: records 5 -> 7'),
        (0x0820D240, '05eb', '07eb', '0x0820D116: records 5 -> 7'),
        (0x0820D400, '05eb', '07eb', '0x0820D290: records 5 -> 7'),
        (0x0820CD54, '04e2', '06e2', 'SET: requester 0..6'),
        (0x0820CDF2, '04e6', '06e6', 'GET: requester 0..6'),
        (0x0820D806, '04e6', '06e6', 'CHK1: requester 0..6'),
        (0x0820D84E, '04e6', '06e6', 'CHK2: requester 0..6'),
        (0x0820D902, '04e6', '06e6', 'FN3: requester 0..6'))]
def _ui_entries():
    out = []
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ui_entries.json')
    if not os.path.exists(p):       # generated from the stock MAIN by genui.py (not shipped)
        return out
    for e in json.load(open(p)):
        out.append(('stramp', e['site'], e['end'], bytes.fromhex(e['orig']), e['lit_off'], e['sym'], e['reg'],
                    'UI entry: requester 5/6 -> its shadow (%s)' % e['mode']))
    return out


PATCHES['srvui'] = [   # UI-notify object 0x0AB82D38: requesters 5/6 served from shadow objects (p56ui.c)
    ('lit', 0x082BF91C, 0x083DD108, 'p56_uiset', 0, 'register UI notify (server register)'),
    ('lit', 0x082ADDC8, 0x083DD108, 'p56_uiset', 0, 'register UI notify (0x082ADB4C)'),
    ('lit', 0x082BF904, 0x083DD56E, 'p56_uiclr', 0, 'unregister UI notify (server unregister)'),
    ('lit', 0x082BF690, 0x083DD56E, 'p56_uiclr', 0, 'unregister UI notify (walk)'),
    ('lit', 0x082B065C, 0x083DD36E, 'p56_uiReinit', 0, 'menu lists re-init, all requesters'),
    ('lit', 0x082B2340, 0x083DD36E, 'p56_uiReinit', 0, 'menu lists re-init, all requesters'),
    ('lit', 0x082B3B48, 0x083DD36E, 'p56_uiReinit', 0, 'menu lists re-init, all requesters'),
    ('lit', 0x082B3FB0, 0x083DD36E, 'p56_uiReinit', 0, 'menu lists re-init, all requesters'),
    ('lit', 0x082BFC48, 0x083DD36E, 'p56_uiReinit', 0, 'menu lists re-init, all requesters'),
    ('lit', 0x082BF404, 0x083DD6D0, 'p56_uiRelease', 0, 'menu lists release, all requesters'),
    ('lit', 0x083424A4, 0x083DE302, 'p56_uiMaxw', 0, 'max over requesters'),
    ('lit', 0x082B6FB4, 0x083DF5E4, 'p56_uiFind', 0, 'find over requesters'),
    ('lit', 0x082B6FC0, 0x083DF740, 'p56_uiBc740', 0, 'broadcast over requesters'),
    ('lit', 0x082B6FC4, 0x083DF83E, 'p56_uiBc83e', 0, 'broadcast over requesters'),
    ('lit', 0x082B6FBC, 0x083DF8A2, 'p56_uiBc8a2', 0, 'broadcast over requesters'),
    ('lit', 0x082BC7B0, 0x083DF8A2, 'p56_uiBc8a2', 0, 'broadcast over requesters'),
    ('lit', 0x082B7300, 0x083DFB84, 'p56_uiBcb84', 0, 'broadcast over requesters'),
    ('lit', 0x082B75B8, 0x083DFB84, 'p56_uiBcb84', 0, 'broadcast over requesters'),
    ('lit', 0x083DDD00, 0x0820D7EA, 'p56_mCHK1u', 0, 'UI -> media CHK1 with the real requester 5/6'),
    ('lit', 0x083DF43C, 0x0820CDDC, 'p56_mGETu', 0, 'UI -> media GET with the real requester 5/6'),
    ('lit', 0x083DF440, 0x0820D836, 'p56_mCHK2u', 0, 'UI -> media CHK2 with the real requester 5/6'),
    ('lit', 0x083DCF14, 0x0820D8C2, 'p56_mFN3u', 0, 'UI -> media FN3 with the real requester 5/6'),
    ('stramp', 0x083DCF20, 0x083DCF2C, bytes.fromhex('e62f536143622942636e1942'), 8, 'p56_uiDmst', 2,
     'DMST parser: player 5/6 with a shadow -> index 1'),
] + _ui_entries()
SETS = {
    'proven': ('a1', 'a2', 'b1', 'b2', 'a7'),
    'a': ('a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7'),
    'b': ('b1', 'b2', 'b4a', 'b4b', 'b4m'),
}
SETS['ab'] = SETS['a'] + SETS['b']
SETS['gui78'] = ('b3', 'b3g')
PATCHES['pltab'] = [   # 0x0A376BF4: 8 bytes per player, memset 40 = index 0..4 only; getter 0x084017B8 and
    # setter 0x08401738 bound the index at 68, so 5/6 read/wrote past it (sync loop 0x084B78C6 saw a
    # 'present' 6 and posted msg 0x586 every 3 s even at 1..4; own 5/6 wrote into the next variable).
    _imm(0x083FB694, '28e6', '38e6', 'table init memset 40 -> 56', True),
    ('lit', 0x083FB784, 0x0A376BF4, 'p56_T8', 0, 'table init base'),
    ('lit', 0x08401824, 0x0A376BF4, 'p56_T8', 0, 'table get/set base (0x0840175A, 0x084017C4)'),
]
SETS['ctx'] = ('ctxalloc', 'ctxinit', 'ctxsites', 'ctxchk', 'syncarr', 'pltab')
SETS['abc'] = SETS['ab'] + SETS['ctx']
SETS['srv'] = ('srvreq', 'srvui', 'srvstor')
SETS['all'] = SETS['abc'] + SETS['gui78']
TEST_ONLY = ()   # nothing test-only left (srvtest was dropped once the real server side passed its proofs)
CAVE_USERS = ('pltab', 'srvreq', 'srvui', 'srvstor', 'a3', 'a4', 'a6', 'b4m', 'ctxsess', 'ctxinit', 'ctxsites', 'syncarr')

UT_LABEL, UT_VALS, UT_COUNT = 0xA80FDB90, 0x10DE146C, 5


def cave():
    """(p56.bin bytes, {symbol: address}) as built by build.sh."""
    with open(os.path.join(HERE, 'p56.bin'), 'rb') as f:
        blob = f.read()
    syms = {}
    with open(os.path.join(HERE, 'p56.sym')) as f:
        for line in f:
            a, _, n = line.split()
            syms[n] = int(a, 16)
    if syms.get('p56_stubA', 0) & ~0xFFF != P56_BASE:
        raise SystemExit('player56: p56.bin is not linked at %#x (rebuild with build.sh)' % P56_BASE)
    return blob, syms


def names_of(arg):
    out = []
    for a in arg.split(','):
        out += list(SETS.get(a, (a,)))
    for n in out:
        if n not in PATCHES:
            raise SystemExit('player56: unknown patch %r' % n)
    return tuple(dict.fromkeys(out))


def apply(image, names=SETS['proven'], log=print):
    out = bytearray(image)
    o = lambda a: a - BASE
    syms = None
    if any(n in CAVE_USERS for n in names):
        blob, syms = cave()
        seg = out[o(P56_BASE):o(P56_BASE + P56_SIZE)]
        if len(seg) < P56_SIZE or any(b != 0xFF for b in seg):
            raise SystemExit('player56: cave %#x-%#x is not free in this image' % (P56_BASE, P56_BASE + P56_SIZE))
        if P56_BASE + len(blob) > ANN_BASE:
            raise SystemExit('player56: p56.bin (%d B) too big for its cave' % len(blob))
        out[o(P56_BASE):o(P56_BASE) + len(blob)] = blob
        log('player56: cave p56.bin %d B at %#x' % (len(blob), P56_BASE))
    for n in names:
        for p in PATCHES[n]:
            kind = p[0]
            if kind in ('imm', 'raw'):
                _, addr, old, new, what, proven = p
                if bytes(out[o(addr):o(addr) + len(old)]) != old:
                    raise SystemExit('player56: %s at %#x holds %s, not stock %s'
                                     % (n, addr, out[o(addr):o(addr) + len(old)].hex(), old.hex()))
                if kind == 'raw':      # the whole stock body must still be there
                    pass
                out[o(addr):o(addr) + len(new)] = new
                log('player56: %s at %#x (%s)%s' % (n, addr, what, '' if proven else ' [G]'))
            elif kind == 'tramp':
                _, addr, lit_off, sym, what, proven, reg = p
                lit = addr + lit_off
                if lit & 3:
                    raise SystemExit('player56: %s literal %#x not aligned' % (n, lit))
                disp = (lit - ((addr & ~3) + 4)) // 4
                code = struct.pack('<HHH', 0xD000 | (reg << 8) | disp, 0x402B | (reg << 8), 0x0009)  # mov.l lit,rN / jmp @rN / nop
                tramp = code + b'\x09\x00' * ((lit - addr - 6) // 2) + struct.pack('<I', syms[sym])
                out[o(addr):o(addr) + len(tramp)] = tramp
                log('player56: %s at %#x -> %s %#x (%s)%s' % (n, addr, sym, syms[sym], what,
                                                              '' if proven else ' [G]'))
            elif kind == 'rawsym':
                _, addr, old, new, loff, sym, add, what = p
                if bytes(out[o(addr):o(addr) + len(old)]) != old:
                    raise SystemExit('player56: %s at %#x is not stock' % (n, addr))
                assert len(new) == len(old)
                nb = bytearray(new)
                struct.pack_into('<I', nb, loff, syms[sym] + add)
                out[o(addr):o(addr) + len(nb)] = nb
                log('player56: %s at %#x (%s)' % (n, addr, what))
            elif kind == 'sym32':
                _, sym, val, what = p
                struct.pack_into('<I', out, o(syms[sym]), val)
                log('player56: %s %s = %d (%s)' % (n, sym, val, what))
            elif kind == 'lit':
                _, addr, old, sym, add, what = p
                if struct.unpack_from('<I', out, o(addr))[0] != old:
                    raise SystemExit('player56: %s literal %#x is not %#x' % (n, addr, old))
                struct.pack_into('<I', out, o(addr), syms[sym] + add)
                log('player56: %s literal %#x %#x -> %#x (%s)' % (n, addr, old, syms[sym] + add, what))
            elif kind == 'stramp':
                _, addr, end, orig, lit_off, sym, reg, what = p
                if bytes(out[o(addr):o(end)]) != orig:
                    raise SystemExit('player56: %s site %#x is not stock' % (n, addr))
                disp = (addr + lit_off - ((addr & ~3) + 4)) // 4
                tr = struct.pack('<HHH', 0xD000 | (reg << 8) | disp, 0x402B | (reg << 8), 0x0009)
                tr += b'\x09\x00' * ((lit_off - 6) // 2) + struct.pack('<I', syms[sym])
                tr += b'\x09\x00' * ((end - addr - len(tr)) // 2)
                out[o(addr):o(end)] = tr
                log('player56: %s at %#x (%s)' % (n, addr, what))
            elif kind == 'ut':
                _, what, proven = p
                pat = struct.pack('<III', UT_LABEL, UT_VALS, UT_COUNT)
                hits = []
                i = out.find(pat)
                while i >= 0:
                    hits.append(i)
                    i = out.find(pat, i + 4)
                if not hits:
                    raise SystemExit('player56: a4: PLAYER No. item record not found')
                for i in hits:
                    out[i + 4:i + 12] = struct.pack('<II', syms['p56_vals'], 7)
                    log('player56: a4 at %#x (%s)' % (BASE + i, what))
    return bytes(out)


def verify(image, names):
    """[(ok, what)] for each named patch: the patched bytes are in image."""
    res = []
    o = lambda a: a - BASE
    syms = cave()[1] if any(n in CAVE_USERS for n in names) else None
    if syms:
        blob = bytearray(cave()[0])
        for n in names:                    # data words set by sym32 patches (ctxsess flag)
            for p in PATCHES[n]:
                if p[0] == 'sym32' and syms[p[1]] - P56_BASE < len(blob):
                    struct.pack_into('<I', blob, syms[p[1]] - P56_BASE, p[2])
        res.append((image[o(P56_BASE):o(P56_BASE) + len(blob)] == bytes(blob), 'player56 cave p56.bin at %#x' % P56_BASE))
    last = {}                         # address -> last (name, patch) writing it (ctxsess rewrites ctxalloc)
    for n in names:
        for p in PATCHES[n]:
            if p[0] in ('imm', 'raw'):
                last[p[1]] = (n, p)
    for n in names:
        for p in PATCHES[n]:
            if p[0] in ('imm', 'raw') and last[p[1]][1] is not p:
                continue
            if p[0] in ('imm', 'raw'):
                _, addr, old, new, what, _ = p
                res.append((image[o(addr):o(addr) + len(new)] == new, 'player56 %s at %#x (%s)' % (n, addr, what)))
            elif p[0] == 'tramp':
                _, addr, lit_off, sym, what, _, reg = p
                ok = struct.unpack_from('<I', image, o(addr + lit_off))[0] == syms[sym] and \
                    struct.unpack_from('<H', image, o(addr + 2))[0] == 0x402B | (reg << 8)
                res.append((ok, 'player56 %s trampoline at %#x -> %s' % (n, addr, sym)))
            elif p[0] == 'rawsym':
                _, addr, old, new, loff, sym, add, what = p
                nb = bytearray(new)
                struct.pack_into('<I', nb, loff, syms[sym] + add)
                res.append((image[o(addr):o(addr) + len(nb)] == bytes(nb), 'player56 %s at %#x (%s)' % (n, addr, what)))
            elif p[0] == 'sym32':
                _, sym, val, what = p
                res.append((struct.unpack_from('<I', image, o(syms[sym]))[0] == val, 'player56 %s %s == %d' % (n, sym, val)))
            elif p[0] == 'lit':
                _, addr, old, sym, add, what = p
                res.append((struct.unpack_from('<I', image, o(addr))[0] == syms[sym] + add,
                            'player56 %s literal %#x -> %s+%d' % (n, addr, sym, add)))
            elif p[0] == 'stramp':
                _, addr, end, orig, lit_off, sym, reg, what = p
                ok = struct.unpack_from('<I', image, o(addr + lit_off))[0] == syms[sym] and \
                    struct.unpack_from('<H', image, o(addr + 2))[0] == 0x402B | (reg << 8)
                res.append((ok, 'player56 %s site %#x -> %s' % (n, addr, sym)))
            elif p[0] == 'ut':
                pat = struct.pack('<III', UT_LABEL, syms['p56_vals'], 7)
                res.append((image.find(pat) >= 0, 'player56 a4 PLAYER No. record -> p56_vals, 7 values'))
    return res


def install(patch_update, names):
    """Make patch_update (or verify_update through it) know the pseudo-mod
    'player56' = these patches on the MAIN section, applied after every other MAIN mod."""
    reg0, apply0 = patch_update.registry, patch_update.apply

    def registry():
        reg = reg0()
        reg['player56'] = patch_update.Entry('main', sys.modules[__name__], ('1.87',),
                                             'PLAYER No. 5/6 (%s)' % ','.join(names))
        return reg

    def apply(target, image, mods):
        own = [m for m in mods if m != 'player56']
        if any(n in TEST_ONLY for n in names):
            raise SystemExit('player56: %s are TEST-ONLY / server WIP, never in a .UPD' % ','.join(n for n in names if n in TEST_ONLY))
        out = apply0(target, image, own) if own else image
        if target == 'main' and 'player56' in mods:
            out = globals()['apply'](out, names, log=lambda *a: None)
        return out

    patch_update.registry = registry
    patch_update.apply = apply


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    img = open(sys.argv[1], 'rb').read()
    out = apply(img, names_of(sys.argv[3] if len(sys.argv) > 3 else 'proven'))
    open(sys.argv[2], 'wb').write(out)
