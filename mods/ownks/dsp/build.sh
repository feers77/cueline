#!/bin/sh
# Rebuild the committed DSP images with the tic6x toolchain (build_toolchain.sh): ownks_dsp.bin/.sym = ks3 (KS3 v4.1),
# ownks_ab_dsp.bin/.sym = ks3 + the old engine (CDJ_KSAB=1 DEV A/B test builds).
cd "$(dirname "$0")/.." && python3 -c "
import ownks
for ab in (False, True):
    d, s = ownks.build_dsp(with_ab=ab)
    print('ownks_ab_dsp.bin' if ab else 'ownks_dsp.bin', len(d), 'B, ks_fill %#x, state end %#x' % (s['ks_fill'], s['_ks_end']))"
