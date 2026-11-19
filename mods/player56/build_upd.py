#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build a test .UPD with player56 on top of patch_update.py, without touching it.

usage: build_upd.py <in.UPD> <out.UPD> --p56=<set|patch,...> [patch_update args/mods ...]
Verify with: scripts/firmware/verify_update.py <stock.UPD> <out.UPD> [mods ...] --p56=<same>
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import patch_update   # noqa: E402
import player56       # noqa: E402


def main():
    args = sys.argv[1:]
    sel = [a for a in args if a.startswith('--p56=')]
    args = [a for a in args if not a.startswith('--p56=')]
    names = player56.names_of(sel[-1][6:] if sel else 'proven')
    player56.install(patch_update, names)
    sys.argv = [sys.argv[0]] + args + ['player56']
    patch_update.main()


if __name__ == '__main__':
    main()
