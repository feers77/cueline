#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""F1 build gate: "what is loaded on THIS deck" has one accessor, mods/ownstat.inc.

Fails the build when

  * the fixed status slot (0x0B53D828, OWN_SLOT) is named anywhere but ownstat.inc. It holds the LAST status
    packet seen -- the other deck's as soon as two decks share a LINK. Reading it as "ours" shipped twice
    (Touch Cue played the other deck's track; the master was compared with itself);
  * the LINK status table's base (0x0A371D3C) is written as a number instead of LINK_TAB;
  * a source uses LINK_TAB that is not in TABLE_USERS below with that many uses. The table is indexed by the
    player NUMBER (LINK_TAB + p * LINK_STRIDE); rq_get once used p - 1, one record low. A new or changed user
    must be read by a person, who then records it here.

Run on its own (`python3 mods/check_ownstat.py`) or through patch_update.py, which calls check() on every build.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
INC = 'ownstat.inc'

# source (relative to mods/) -> uses of LINK_TAB, each reviewed to index by the player NUMBER:
TABLE_USERS = {
    'keyshift/main_keyshift.s': 2,      # kc_code, K_tab: LINK_TAB + 0x28 + p * 0x124 (p checked 1..6)
    'link0b/main_link0btx.s': 1,        # t_recs + own p * 0x124
    'modsmenu/modsmenu.s': 2,           # mm_publish (the master, +0xA4, checked 1..6), vp (p = 1..)
    'tcnet/main_tcnetdata.s': 1,        # k_records + p * 0x124 (p checked 1..4)
    'tcnet/main_tcnettime.s': 1,        # p_records + p * 0x124
    'usb_midi/main_usbmiditick.s': 1,   # LINK_TAB + LINK_STRIDE (player 1's record) + (p - 1) * 0x124
    'w8fetch/main_w8cap.s': 1,          # k_tab + p * 0x124
    'w8fetch/main_w8send.s': 1,         # l_tab + p * 0x124 (p checked 1..6)
}

SLOT_NUM = re.compile(r'(?<![0-9A-Za-z_])(?:0x)?0?B53D828(?![0-9A-Za-z_])', re.I)
TAB_NUM = re.compile(r'(?<![0-9A-Za-z_])(?:0x)?0?A371D3C(?![0-9A-Za-z_])', re.I)
SLOT_SYM = re.compile(r'\bOWN_SLOT\b')
TAB_SYM = re.compile(r'\bLINK_TAB\b')
ASM = ('.s', '.S', '.inc')


def code_lines(path):
    """(line number, text without its comments) of an assembly source: '!' to the end of the line, and the
    C comments of a preprocessed .S."""
    with open(path, errors='replace') as f:
        text = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), f.read(), flags=re.S)
    for n, line in enumerate(text.split('\n'), 1):
        yield n, line.split('!', 1)[0]


def problems(root=HERE):
    bad, uses = [], {}
    for d, _, files in os.walk(root):
        for name in sorted(files):
            path = os.path.join(d, name)
            rel = os.path.relpath(path, root).replace(os.sep, '/')
            if rel in (INC, 'check_ownstat.py') or name.endswith('.orig'):
                continue
            if name.endswith(ASM):
                for n, code in code_lines(path):
                    if SLOT_NUM.search(code) or SLOT_SYM.search(code):
                        bad.append('%s:%d: the fixed status slot is read directly -- use own_rec / own_loaded '
                                   '(ownstat.inc)' % (rel, n))
                    if TAB_NUM.search(code):
                        bad.append('%s:%d: the LINK status table as a number -- write LINK_TAB (ownstat.inc)'
                                   % (rel, n))
                    uses[rel] = uses.get(rel, 0) + len(TAB_SYM.findall(code))
            elif name.endswith('.py'):
                with open(path, errors='replace') as f:
                    for n, line in enumerate(f, 1):
                        code = line.split('#', 1)[0]
                        if SLOT_NUM.search(code) or TAB_NUM.search(code):
                            bad.append('%s:%d: a LINK status address patched from Python -- it belongs in '
                                       'ownstat.inc' % (rel, n))
    for rel in sorted(set(uses) | set(TABLE_USERS)):
        have, want = uses.get(rel, 0), TABLE_USERS.get(rel, 0)
        if have != want:
            bad.append('%s: %d use(s) of LINK_TAB, %d reviewed -- check that each indexes by the player NUMBER '
                       '(p * LINK_STRIDE, never p - 1), then update TABLE_USERS in mods/check_ownstat.py'
                       % (rel, have, want))
    return bad


def check(root=HERE):
    bad = problems(root)
    if bad:
        raise SystemExit('check_ownstat (F1, mods/ownstat.inc):\n  ' + '\n  '.join(bad))


if __name__ == '__main__':
    check(sys.argv[1] if len(sys.argv) > 1 else HERE)
    print('check_ownstat: ok')
