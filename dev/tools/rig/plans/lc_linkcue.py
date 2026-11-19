# lc_linkcue: Link Cue (Touch Audio row preview) on the REAL rig against the fake DJM-A9.
# ISOLATED segment only (no real mixer): allow_fake_a9_lan. Needs the A9 alias on en4:
#   sudo ifconfig en4 alias 169.254.142.194 netmask 255.255.0.0   (remove after: sudo ifconfig en4 -alias 169.254.142.194)
# run: python3 rig.py plans/lc_linkcue.py --lan 169.254.77.10 --keep-going [--set hold=22000]
# Rows (V3 browse layout, mods/v2ui RT_GEO_V3): wave cell x 64..150 = the whole track, row n at y 91+40(n-1), 38 px.
# Deck 2 USB TRACK list (rowwave ids == rows): 1 MP3, 2 FLAC, 3 WAV, 4 AIFF (not supported), 5 WAV.
# LOCAL = deck A (2) on its own USB; REMOTE = deck B (3) browsing A's USB over LINK (NFS, drive D:).
HOLD = 22000
M = lambda p, a, n, nm, **k: dict({'do': 'deck_mem', 'player': p, 'addr': a, 'len': n, 'name': nm}, **k)


def case(tag, p, ip, nav, row, x=100, fmt='', soft=False, expect_audio=True):
    y = 91 + 40 * (row - 1) + 19
    s = [
        {'do': 'deck', 'player': p, 'ops': nav, 'name': '%s: browse' % tag},
        M(p, 0x0A35F3CC, 4, '%s: display mode (1 = list)' % tag, want=[[0, 0xFF, 1]]),
        M(p, 0x081F0010, 0x18, '%s: row ids (1..5: the TRACK list)' % tag, want=[[4, 0xFF, 1], [20, 0xFF, 5]]),
        M(p, 0x081FF700, 0x20, '%s: medium (MED)' % tag),
        M(p, 0x081FFE80, 0x30, '%s: counters before' % tag),
        {'do': 'a9_reset', 'tag': tag},
        {'do': 'deck', 'player': p, 'ops': ['TOUCH %d %d %d' % (x, y, HOLD), 'WAIT %d' % (HOLD + 300)], 'done': False,
         'timeout': 10, 'name': '%s: hold row %d (%s) %d ms' % (tag, row, fmt, HOLD)},
    ]
    if expect_audio:
        s += [
            {'do': 'expect_a9_audio', 'ip': ip, 'timeout': 10, 'min_pcm': 50, 'peak_gt': 200, 'soft': soft,
             'name': '%s: elected + non-silent PCM' % tag},
            {'do': 'wait', 's': HOLD / 1000.0 - 8},
            {'do': 'expect_a9_audio', 'ip': ip, 'timeout': 2, 'min_pcm': 2000, 'rate': [135, 150], 'soft': True,
             'name': '%s: ~20 s of PCM at ~142.9/s' % tag},
        ]
    else:
        s += [{'do': 'wait', 's': HOLD / 1000.0}]
    s += [
        {'do': 'expect_a9_audio', 'ip': ip, 'timeout': 15, 'quiet_gt': 1.5, 'name': '%s: stops after release' % tag},
        {'do': 'a9_stats', 'name': '%s: final stats' % tag},
        M(p, 0x081FFE80, 0x30, '%s: counters after' % tag),
        M(p, 0x081FFE00, 0x20, '%s: last open diag' % tag),
        {'do': 'wait', 's': 2},
    ]
    return s


LOCAL_NAV = ['KEY USB', 'WAIT 4000', 'TOUCH 28 160 150', 'WAIT 3000', 'ROT -10', 'WAIT 1500']
# REMOTE (V4n32+): KEY LINK opens the SOURCE list (mods/v2ui touch_map src.rows: this deck's own SD / USB rows
# first when mounted, then one row per LINK medium; pitch 64 from y 66 for <= 5 rows). ${src_row} = the row of
# deck A's USB (0 when deck B has no media of its own). A tap there opens that medium's root; the root's TRACK
# row (index 2 in the rekordbox root menu ARTIST, ALBUM, TRACK, ...) is opened with the knob + PUSH, not with
# the rail: the rail walk (modsmenu vt_rail2) did not know the LINK roots' title icons (0x50..0x53) before V4n35
# and pressed BACK instead. The old ['KEY LINK'] only worked when deck B had already browsed that TRACK list.
# KEY LINK does NOT always open the SOURCE list: it resumes deck B's last LINK browse position (2026-11-14
# v35_lc/v35_lc2 FAIL: deck 3 came back in ARTIST > Toto Chiavetta > Ederlezi, a 1-row list; the tap/ROT/PUSH
# then went nowhere -> row ids 0 2 0 0 0, display mode 7). BACK walks up to the SOURCE list ('LINK' title,
# one row per medium) and is a no-op there, so 6 BACKs reach it from any depth (verified live on deck 3).
REMOTE_NAV = ['KEY LINK', 'WAIT 4000'] + ['KEY BACK', 'WAIT 1500'] * 6 + ['TOUCH 200 ${src_y} 200', 'WAIT 5000', 'ROT -10', 'WAIT 800', 'ROT 2',
              'WAIT 800', 'KEY PUSH', 'WAIT 5000', 'ROT -10', 'WAIT 1500']

PLAN = {
 'name': 'lc_linkcue: Link Cue row preview, local (deck 2 USB) and remote (deck 3 <- deck 2 over LINK), fake A9',
 'allow_fake_a9_lan': True,
 'vars': {'A': 2, 'B': 3, 'a9_ip': '169.254.142.194', 'ipA': '169.254.128.46', 'ipB': '169.254.128.18',
          'src_y': 98},  # 66 + 64 * src_row + 32
 'virtual': {'number': 5, 'name': 'rig', 'kind': 'cdj'},
 'steps': [
  {'do': 'wait_device', 'player': '${A}', 'timeout': 30},
  {'do': 'wait_device', 'player': '${B}', 'timeout': 30},
  M('${A}', 0x080140F0, 12, 'A MODS/LINK CUE/WAV32 (ks layout; LINK CUE 3 = BOTH)'),
  M('${B}', 0x080140F0, 12, 'B MODS/LINK CUE/WAV32'),
  {'do': 'fake_a9', 'enable': True, 'ip': '${a9_ip}', 'onair': [1, 1, 1, 1], 'linkcue': 1},
  {'do': 'wait', 's': 4},
 ]
 + case('L_wav', '${A}', '${ipA}', LOCAL_NAV, 3, fmt='WAV')
 + case('L_mp3', '${A}', '${ipA}', ['WAIT 200'], 1, fmt='MP3')
 + case('L_flac', '${A}', '${ipA}', ['WAIT 200'], 2, fmt='FLAC')
 + case('L_aiff', '${A}', '${ipA}', ['WAIT 200'], 4, fmt='AIFF (unsupported)', expect_audio=False)
 + case('R_wav', '${B}', '${ipB}', REMOTE_NAV, 3, fmt='WAV')
 + case('R_mp3', '${B}', '${ipB}', ['WAIT 200'], 1, fmt='MP3')
 + case('R_flac', '${B}', '${ipB}', ['WAIT 200'], 2, fmt='FLAC')
 + [{'do': 'fake_a9', 'enable': False}],
}
