E = lambda p, f, v, k, **kw: dict({'do': 'ensure', 'player': p, 'field': f, 'value': v, 'key': k}, **kw)
steps = [{'do': 'wait_device', 'player': '${A}', 'timeout': 30},
         {'do': 'deck_mem', 'player': '${A}', 'addr': 0x08000740, 'len': 8},
         E('${A}', 'playing', False, 'PLAY'), E('${A}', 'synced', False, 'SYNC')]
for r in (1, 2, 3, 4, 5):
    steps += [{'name': 'load own rbid %d' % r, 'do': 'load', 'target': '${A}', 'src_player': '${A}', 'slot': 'usb', 'rbid': r},
              {'do': 'wait', 's': 3},
              {'do': 'expect', 'player': '${A}', 'timeout': 20, 'loaded': True, 'rbid': r, 'play_mode_name': ['cued', 'paused']},
              E('${A}', 'playing', True, 'PLAY', name='play rbid %d' % r),
              {'name': 'rbid %d plays 10 s' % r, 'do': 'expect', 'player': '${A}', 'timeout': 5, 'playing': True, 'rbid': r, 'hold': 10},
              E('${A}', 'playing', False, 'PLAY')]
steps += [E('${A}', 'master', True, 'MASTER', name='master (alone)', soft=True),
          {'do': 'deck_mem', 'player': '${A}', 'addr': 0x08000740, 'len': 8, 'name': 'commander alive'}]
PLAN = {'name': 'solo3: one V4n34 deck, own USB: 5 formats load + play', 'vars': {'A': 3},
        'virtual': {'number': 5, 'name': 'rig', 'kind': 'cdj'}, 'steps': steps}
