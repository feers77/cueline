#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""mkdelta.py STOCK.UPD BUILT.UPD OUT.delta --release TAG --build-id "ID" [--report FILE]

Makes cueline.delta: how to turn the stock 1.87 GUI / MAIN images into the built ones, WITHOUT storing stock bytes.
  - per image, the output = the stock image at the same offsets, plus ops on the bytes that differ:
      C dst src n : copy n bytes of the user's STOCK image (any offset) -- every run of >= 24 bytes found in stock
      L dst off n : literal bytes (our compiled mods, generated tables, fills) stored in the delta
  - hard check: no literal run contains a sequence of MINLIT (24) bytes that also occurs in the stock images (other
    than uniform fills), i.e. no stock content is carried in the delta. (At 12 bytes the only overlaps found are
    SH compiler idioms such as register push/pop runs: 0.6 % of the GUI literals, 0.7 % of MAIN, V4r3p.)
  - round-trip check: re-encoding the built images with the stock sections + labels gives BUILT.UPD byte for byte.
Codecs: the repository's scripts/firmware (CUELINE_CODEC dir) -- the same ones the patcher ships.
"""
import hashlib
import json
import lzma
import os
import struct
import sys

_H = os.path.dirname(os.path.abspath(__file__))
CODEC = os.environ.get('CUELINE_CODEC') or next(d for d in (os.path.join(_H, 'codec'), os.path.join(_H, '..', 'scripts', 'firmware'))
                                                 if os.path.isdir(d))
sys.path.insert(0, CODEC)
import gui_decode    # noqa: E402
import gui_encode    # noqa: E402
import main_decode   # noqa: E402
import main_encode   # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cueline_patch as cp   # noqa: E402

K, STEP, MINCOPY, MINLIT = 16, 8, 24, 24   # MINLIT: shorter coincidences are compiler idioms (push/pop runs), not content


def sha(b):
    return hashlib.sha256(b).hexdigest()


def index(stock):
    idx = {}
    for p in range(0, len(stock) - K, STEP):
        k = stock[p:p + K]
        if k.count(k[:1]) == K:      # uniform fill: not indexed (stored as literal, compresses to nothing)
            continue
        idx.setdefault(k, p)
    return idx


def diff_runs(stock, out):
    n = min(len(stock), len(out))
    runs, i = [], 0
    while i < n:
        if stock[i] != out[i]:
            j = i
            while j < n and (stock[j] != out[j] or stock[j:j + 8] != out[j:j + 8]):
                j += 1
            runs.append((i, j))
            i = j
        else:
            i += 1
    if len(out) > n:
        runs.append((n, len(out)))
    return runs


def ops_for(stock, out, idx, blob):
    ops, lit = [], 0
    for a, b in diff_runs(stock, out):
        i, ls = a, None
        while i < b:
            m = None
            if b - i >= MINCOPY:
                for d in range(STEP):                 # a stock copy of >= 24 B holds an indexed 16-B key
                    p = idx.get(out[i + d:i + d + K]) if i + d + K <= b else None
                    if p is not None and p - d >= 0 and stock[p - d:p - d + MINCOPY] == out[i:i + MINCOPY]:
                        m = p - d
                        break
            if m is not None:
                n = MINCOPY
                while i + n < b and m + n < len(stock) and stock[m + n] == out[i + n]:
                    n += 1
                if ls is not None:
                    ops.append(('L', ls, len(blob), i - ls)); blob += out[ls:i]; lit += i - ls; ls = None
                ops.append(('C', i, m, n))
                i += n
            else:
                if ls is None:
                    ls = i
                i += 1
        if ls is not None:
            ops.append(('L', ls, len(blob), b - ls)); blob += out[ls:b]; lit += b - ls
    return ops, blob, lit


def trivial(w):
    """A window that carries no content: <= 3 distinct byte values, one value in >= 2/3 of it, or periodic with a
    period of <= 4 bytes (e.g. 00 01 00 01 ... tables, 0xFF / 0x00 padding with one stray byte)."""
    if len(set(w)) <= 3 or max(w.count(bytes([b])) for b in set(w)) * 3 >= 2 * len(w):
        return True
    return any(w == (w[:p] * (len(w) // p + 1))[:len(w)] for p in (1, 2, 3, 4))


def literal_check(stock_all, ops, blob):
    """No MINLIT-byte window of a literal (non-uniform) occurs in any stock image."""
    # memory-light: index stock at every offset by a 12-byte key only for keys that appear in the literals
    want = {}
    for kind, dst, a, n in ops:
        if kind != 'L':
            continue
        chunk = blob[a:a + n]
        for q in range(0, max(0, n - MINLIT + 1)):
            w = chunk[q:q + MINLIT]
            if trivial(w):                        # fills / padding / short periodic patterns: not content
                continue
            want.setdefault(w, (dst + q))
    hits = []
    for s in stock_all:
        for p in range(0, len(s) - MINLIT + 1):
            w = s[p:p + MINLIT]
            if w in want:
                hits.append((want[w], p))
                if len(hits) > 50:
                    return hits
    return hits


def main():
    a = sys.argv[1:]
    stock_upd, built_upd, out = a[0], a[1], a[2]
    release = a[a.index('--release') + 1]
    build_id = a[a.index('--build-id') + 1]
    report = a[a.index('--report') + 1] if '--report' in a else None
    S, O = open(stock_upd, 'rb').read(), open(built_upd, 'rb').read()
    ss, sh = cp.parse_manifest(S)
    os_, oh = cp.parse_manifest(O)
    def secs(d, sizes, h):
        r, off = [], h
        for s in sizes:
            r.append(d[off:off + s]); off += s
        return r
    Ss, Os = secs(S, ss, sh), secs(O, os_, oh)
    meta = {'format': 1, 'release': release, 'build_id': build_id, 'stock_upd_sha256': sha(S),
            'out_upd_sha256': sha(O), 'targets': {}}
    blob = b''
    rep = []
    stock_imgs = {}
    for target in ('gui', 'main'):
        idx = cp.SECTION_OF[target] - 1
        dec = gui_decode.decode if target == 'gui' else main_decode.decode
        si, oi = dec(Ss[idx])[3], dec(Os[idx])[3]
        stock_imgs[target] = si
        ver = Os[idx][cp.LABEL_VER:cp.LABEL_VER_END].decode()
        # round trip: the patcher's packing of oi must give the built section exactly
        new = (gui_encode.encode(Ss[idx][:32], oi, optimal=True) if target == 'gui'
               else main_encode.encode(Ss[idx], oi, optimal=True))
        if cp.relabel(target, new, ver) != Os[idx]:
            raise SystemExit('mkdelta: %s: re-encoding the built image does not reproduce the built section' % target)
        ops, blob, lit = ops_for(si, oi, index(si), blob)
        copies = sum(n for k, _, _, n in ops if k == 'C')
        meta['targets'][target] = {'stock_image_sha256': sha(si), 'out_image_sha256': sha(oi), 'out_len': len(oi),
                                   'label_ver': ver, 'ops': ops}
        rep.append('%s: %d ops, %d literal bytes (ours), %d bytes copied from the user\'s stock image'
                   % (target, len(ops), lit, copies))
    for i, s in enumerate(Ss):
        if i not in (0, 2) and s != Os[i]:
            raise SystemExit('mkdelta: section %d differs from stock (not supported)' % (i + 1))
    hits = literal_check(list(stock_imgs.values()), [o for t in meta['targets'].values() for o in t['ops']], blob)
    rep.append('literal check (no %d-byte stock sequence inside the literals): %s'
               % (MINLIT, 'PASS' if not hits else 'FAIL %d hit(s), first at out %#x / stock %#x' % (len(hits), *hits[0])))
    j = json.dumps(meta, separators=(',', ':')).encode()
    data = cp.MAGIC + lzma.compress(struct.pack('<I', len(j)) + j + blob, preset=9 | lzma.PRESET_EXTREME)
    open(out, 'wb').write(data)
    rep.append('wrote %s (%d bytes, sha256 %s)' % (out, len(data), sha(data)))
    print('\n'.join(rep))
    if report:
        open(report, 'w').write('\n'.join(rep) + '\n')
    sys.exit(1 if hits else 0)


if __name__ == '__main__':
    main()
