#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""V4n41 KEYFIX: table test of v2.c's key notation code (key_code / key_name / key_txt), compiled from the source
with the host gcc. Every rekordbox key (24, plus the sharp spellings rekordbox exports) in both KEY FORMATs
(ALPHANUMERIC = Camelot numbering, CLASSIC = rekordbox spelling), Camelot round trips, KEY SHIFT +-semitones
keep the mode, and every ks_key() call site resets the length after kf_key() (the Bbm -> 6B player bug: kf_key
left the formatted length, 2 for "3A", and ks_key re-parsed "Bbm" as "Bb").
Run: python3 mods/v2ui/test_keys.py  (exit 0 = PASS)"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, 'v2.c')).read()

# rekordbox key -> Camelot (ALPHANUMERIC), and the CLASSIC spelling we show (flats except F# / F#m)
REF = {
    'C': ('8B', 'C'), 'Db': ('3B', 'Db'), 'C#': ('3B', 'Db'), 'D': ('10B', 'D'), 'Eb': ('5B', 'Eb'),
    'D#': ('5B', 'Eb'), 'E': ('12B', 'E'), 'F': ('7B', 'F'), 'F#': ('2B', 'F#'), 'Gb': ('2B', 'F#'),
    'G': ('9B', 'G'), 'Ab': ('4B', 'Ab'), 'G#': ('4B', 'Ab'), 'A': ('11B', 'A'), 'Bb': ('6B', 'Bb'),
    'A#': ('6B', 'Bb'), 'B': ('1B', 'B'),
    'Cm': ('5A', 'Cm'), 'C#m': ('12A', 'Dbm'), 'Dbm': ('12A', 'Dbm'), 'Dm': ('7A', 'Dm'), 'Ebm': ('2A', 'Ebm'),
    'D#m': ('2A', 'Ebm'), 'Em': ('9A', 'Em'), 'Fm': ('4A', 'Fm'), 'F#m': ('11A', 'F#m'), 'Gm': ('6A', 'Gm'),
    'G#m': ('1A', 'Abm'), 'Abm': ('1A', 'Abm'), 'Am': ('8A', 'Am'), 'Bbm': ('3A', 'Bbm'), 'A#m': ('3A', 'Bbm'),
    'Bm': ('10A', 'Bm'),
}


def harness():
    a = SRC.index('static int key_code(const volatile u8 *t, int n)')
    b = SRC.index('/* V4n36: a key text as shown (KEY FORMAT)')
    return r'''#include <stdio.h>
#include <string.h>
typedef unsigned char u8; typedef unsigned short u16; typedef unsigned int u32;
static int KF_CLASSIC;
static u32 u16be(const volatile u8 *p) { return (u32)p[0] << 8 | p[1]; }
''' + SRC[a:b] + r'''
int main(int argc, char **argv)
{
	char line[64];
	while (fgets(line, sizeof line, stdin)) {	/* "<classic 0|1> <semi> <text>" */
		u8 t[32] = {0}, o[32] = {0};
		int cl, semi, n = 0, m, i;
		char txt[16];
		if (sscanf(line, "%d %d %15s", &cl, &semi, txt) != 3)
			continue;
		KF_CLASSIC = cl;
		for (i = 0; txt[i]; i++, n++) { t[2 * n] = 0; t[2 * n + 1] = (u8)txt[i]; }
		m = key_txt(o, t, n, semi);
		for (i = 0; i < m; i++)
			putchar(o[2 * i + 1]);
		putchar('\n');
	}
	return 0;
}
'''


def main():
    with tempfile.TemporaryDirectory() as tmp:
        c, exe = os.path.join(tmp, 'k.c'), os.path.join(tmp, 'k')
        open(c, 'w').write(harness())
        subprocess.run(['gcc', '-O1', '-o', exe, c], check=True)
        cases = []
        for k, (cam, cls) in REF.items():
            cases += [(0, 0, k, cam), (1, 0, k, cls)]
        for n in range(1, 13):
            for l in 'AB':
                s = '%d%s' % (n, l)
                cls = [v[1] for v in REF.values() if v[0] == s][0]
                cases += [(0, 0, s, s), (1, 0, s, cls)]
                for semi in (-12, -7, -1, 1, 2, 7, 12):     # +1 semitone = +7 on the wheel, mode kept
                    num = (n - 1 + 7 * (semi + 24)) % 12 + 1
                    cases.append((0, semi, s, '%d%s' % (num, l)))
        inp = ''.join('%d %d %s\n' % (cl, se, t) for cl, se, t, _ in cases)
        out = subprocess.run([exe], input=inp, capture_output=True, text=True, check=True).stdout.split('\n')
    bad = [(c, o) for c, o in zip(cases, out) if o != c[3]]
    for (cl, se, t, exp), got in bad:
        print('FAIL %s semi %+d %-4s -> %r (expected %s)' % ('CLASSIC' if cl else 'ALNUM', se, t, got, exp))
    # the call sites: ks_key(x, &len, ..) right after kf_key(x, &len) must reset len to the source length first
    sites = 0
    for mt in re.finditer(r'kf_key\((\w+), &(\w+)\);[^\n]*\n((?:[^\n]*\n){0,6}?)[^\n]*ks_key\(\1, &\2,', SRC):
        sites += 1
        if not re.search(r'\b%s = \w+;' % mt.group(2), mt.group(3)):
            print('FAIL call site: ks_key(%s, &%s) after kf_key without resetting %s' % (mt.group(1), mt.group(2),
                                                                                          mt.group(2)))
            bad.append(mt.group(0))
    print('%s: %d notation cases, %d kf_key -> ks_key call sites, %d failures'
          % ('PASS' if not bad else 'FAIL', len(cases), sites, len(bad)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
