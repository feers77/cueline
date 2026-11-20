#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Encoder for the LZSS stream lzss_decode.py reads back (see that file for
the confirmed parameters): a 4096-byte ring pre-filled with the space
character, read position starting at N-F=4078, matches of 3-18 bytes stored
as (low 8 bits of the ring position, its high nibble | (length-3)), one flag
bit per item -- least-significant first, eight items per flag byte.

This is the classic Okumura/Yoshizaki LZSS bitstream (public-domain lzss.c,
1989). The decoder doesn't care how a match was chosen, only that offset and
length describe bytes it can actually reproduce, so this encoder is a plain
greedy hash-chain matcher rather than a reimplementation of that reference
tool's own search. pack(data, optimal=True) instead finds the longest match
at every position and picks the cheapest parse (a literal costs 9 bits, a
match 17) by dynamic programming from the end: a few KB smaller on the
firmware images, which matters where a section must not outgrow the stock
one (patch_update.py).

    usage: lzss_encode.py [--optimal] <infile> <outfile>
"""
import sys

RING = 4096
FILL = 0x20
START = RING - 18      # matches GUI_RING_POS / lzss_decode.py's ring_pos
MIN_MATCH = 3
MAX_MATCH = 18
CHAIN_DEPTH = 48
OPTIMAL_DEPTH = 1024    # pack_optimal looks further: ~2 KB less on the GUI image


def pack(data, optimal=False):
    """The decompressed bytes, encoded to the stream unpack() reads back."""
    if optimal:
        return pack_optimal(data)
    cb = bytes([FILL]) * START + data
    chains = {}

    def key(pos):
        return (cb[pos] << 16) | (cb[pos + 1] << 8) | cb[pos + 2]

    def insert(pos):
        if pos + 3 <= len(cb):
            chains.setdefault(key(pos), []).append(pos)

    for pos in range(START):
        insert(pos)

    out = bytearray()
    code_buf = bytearray(1)    # element 0 is this group's flag byte
    mask = 1

    n = len(data)
    k = 0
    while k < n:
        a = START + k
        limit = min(MAX_MATCH, len(cb) - a)
        best_len, best_pos = 0, 0
        if limit >= MIN_MATCH:
            cands = chains.get(key(a))
            if cands is not None:
                lo = a - RING
                while cands and cands[0] < lo:
                    cands.pop(0)
                checked = 0
                for p in reversed(cands):
                    length = 0
                    while length < limit and cb[p + length] == cb[a + length]:
                        length += 1
                    if length > best_len:
                        best_len, best_pos = length, p
                        if best_len >= limit:
                            break
                    checked += 1
                    if checked >= CHAIN_DEPTH:
                        break

        if best_len >= MIN_MATCH:
            step = best_len
            off = best_pos & (RING - 1)
            code_buf.append(off & 0xFF)
            code_buf.append(((off >> 4) & 0xF0) | (step - MIN_MATCH))
        else:
            step = 1
            code_buf[0] |= mask
            code_buf.append(cb[a])

        for t in range(step):
            insert(a + t)
        k += step
        mask = (mask << 1) & 0xFF
        if mask == 0:
            out += code_buf
            code_buf = bytearray(1)
            mask = 1

    if len(code_buf) > 1:
        out += code_buf
    return bytes(out)


def longest_matches(data, depth=CHAIN_DEPTH):
    """(length, ring source position) of the longest match at every
    position of data, by the same hash chains and window rule as pack()."""
    cb = bytes([FILL]) * START + data
    chains = {}
    n = len(data)
    lens = bytearray(n)
    srcs = [0] * n

    def key(pos):
        return (cb[pos] << 16) | (cb[pos + 1] << 8) | cb[pos + 2]

    for pos in range(START):
        if pos + 3 <= len(cb):
            chains.setdefault(key(pos), []).append(pos)
    for k in range(n):
        a = START + k
        limit = min(MAX_MATCH, len(cb) - a)
        if limit >= MIN_MATCH:
            kk = key(a)
            cands = chains.get(kk)
            if cands is not None:
                lo = a - RING
                drop = 0
                while drop < len(cands) and cands[drop] < lo:
                    drop += 1
                if drop:
                    del cands[:drop]
                best_len, best_pos, checked = 0, 0, 0
                for p in reversed(cands):
                    length = 3
                    while length < limit and cb[p + length] == cb[a + length]:
                        length += 1
                    if length > best_len:
                        best_len, best_pos = length, p
                        if best_len >= limit:
                            break
                    checked += 1
                    if checked >= depth:
                        break
                lens[k] = best_len
                srcs[k] = best_pos
                cands.append(a)
            else:
                chains[kk] = [a]
    return lens, srcs, cb


def pack_optimal(data):
    lens, srcs, cb = longest_matches(data, OPTIMAL_DEPTH)
    n = len(data)
    INF = 1 << 60
    cost = [0] * (n + 1)
    take = bytearray(n)          # 0: literal, else the match length used
    for i in range(n - 1, -1, -1):
        best = 9 + cost[i + 1]
        choice = 0
        L = lens[i]
        if L >= MIN_MATCH:
            for k in range(L, MIN_MATCH - 1, -1):
                c = 17 + cost[i + k]
                if c < best:
                    best, choice = c, k
        cost[i] = best
        take[i] = choice
    out = bytearray()
    code_buf = bytearray(1)
    mask = 1
    k = 0
    while k < n:
        step = take[k]
        if step:
            off = srcs[k] & (RING - 1)
            code_buf.append(off & 0xFF)
            code_buf.append(((off >> 4) & 0xF0) | (step - MIN_MATCH))
        else:
            step = 1
            code_buf[0] |= mask
            code_buf.append(cb[START + k])
        k += step
        mask = (mask << 1) & 0xFF
        if mask == 0:
            out += code_buf
            code_buf = bytearray(1)
            mask = 1
    if len(code_buf) > 1:
        out += code_buf
    return bytes(out)


def main():
    args = sys.argv[1:]
    optimal = '--optimal' in args
    args = [a for a in args if a != '--optimal']
    if len(args) != 2:
        raise SystemExit(__doc__)
    sys.argv[1:] = args
    with open(sys.argv[1], 'rb') as f:
        data = f.read()
    out = pack(data, optimal)
    with open(sys.argv[2], 'wb') as f:
        f.write(out)
    print('lzss_encode: %d -> %d bytes' % (len(data), len(out)))


if __name__ == '__main__':
    main()
