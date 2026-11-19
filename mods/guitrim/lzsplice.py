# SPDX-License-Identifier: Apache-2.0
"""Re-encode only the changed windows of a Pioneer LZSS stream (4096 ring, 0x20 fill at 4078,
3..18-byte matches, 8 items per flag byte), keeping every other byte of the base stream.

The decoder's state at the start of a flag group is (decoded position, the last 4,096 decoded
bytes). For a change in decoded [a, b), the base stream is cut at the last group start at or
before a (s0, p0) and at the first group start whose position p1 >= b + 4096 (the ring then
holds only unchanged bytes again). [p0, p1) is encoded anew with the decoder's real history
(the new decoded bytes before p0, so a match may reach back into it), padded to whole flag
groups, and the base stream continues unchanged from s1. Overlapping windows merge.
Verified by the caller: the new stream must decode to the intended archive.
"""
RING, FILL, START = 4096, 0x20, 4096 - 18
MIN_MATCH, MAX_MATCH = 3, 18


def groups(stream):
    """[(stream offset, decoded position)] of every flag group start, plus the end."""
    out, i, pos, n = [], 0, 0, len(stream)
    while i < n:
        out.append((i, pos))
        flags = stream[i]
        i += 1
        for b in range(8):
            if i >= n:
                break
            if flags >> b & 1:
                i += 1
                pos += 1
            else:
                if i + 1 >= n:
                    i = n
                    break
                pos += (stream[i + 1] & 0x0F) + 3
                i += 2
    out.append((n, pos))
    return out


def _items(cb, lo, a, b, depth):
    """Optimal parse of cb[a:b] (cb = FILL*START + decoded); matches may start in cb[lo:]."""
    chains = {}
    n = b - a
    lens = bytearray(n)
    srcs = [0] * n

    def key(p):
        return (cb[p] << 16) | (cb[p + 1] << 8) | cb[p + 2]

    for p in range(max(lo, a - RING), a):
        if p + 3 <= len(cb):
            chains.setdefault(key(p), []).append(p)
    zrun = 0                    # zero bytes right before x (capped at RING)
    while zrun < RING and a - zrun - 1 >= 0 and cb[a - zrun - 1] == 0:
        zrun += 1
    zero18 = bytes(MAX_MATCH)
    for k in range(n):
        x = a + k
        if k:
            zrun = min(RING, zrun + 1) if cb[x - 1] == 0 else 0
        limit = min(MAX_MATCH, b - x)
        if limit < MIN_MATCH:
            continue
        kk = key(x)
        if zrun >= RING and cb[x:x + limit] == zero18[:limit]:
            # the whole ring is zero: a match at a FIXED ring position (0). Long zero runs then
            # encode as one repeating 17-byte group (flag 0, 8 x '00 0F') that the section's
            # own LZSS packs ~18:1 again, instead of offsets that change with every item.
            lens[k], srcs[k] = limit, 0
            chains.setdefault(kk, []).append(x)
            continue
        if x > lo and cb[x - 1:x + limit] == cb[x:x + 1] * (limit + 1):
            lens[k], srcs[k] = limit, x - 1      # inside a run: the byte before repeats (maximal)
            chains.setdefault(kk, []).append(x)
            continue
        cands = chains.get(kk)
        if cands is None:
            chains[kk] = [x]
            continue
        lw = x - RING
        drop = 0
        while drop < len(cands) and cands[drop] < lw:
            drop += 1
        if drop:
            del cands[:drop]
        bl, bp, chk = 0, 0, 0
        for p in reversed(cands):
            L = 3
            while L < limit and cb[p + L] == cb[x + L]:
                L += 1
            if L > bl:
                bl, bp = L, p
                if bl >= limit:
                    break
            chk += 1
            if chk >= depth:
                break
        lens[k] = bl
        srcs[k] = bp
        cands.append(x)
    cost = [0] * (n + 1)
    take = bytearray(n)
    for i in range(n - 1, -1, -1):
        best, ch = 9 + cost[i + 1], 0
        L = lens[i]
        for m in range(L, MIN_MATCH - 1, -1):
            c = 17 + cost[i + m]
            if c < best:
                best, ch = c, m
        cost[i], take[i] = best, ch
    items, k = [], 0
    while k < n:
        if take[k]:
            items.append(('M', srcs[k] & (RING - 1), take[k]))
            k += take[k]
        else:
            items.append(('L',))
            k += 1
    return items


def _pad(items):
    """Whole flag groups: split a match (p, L>=4) into a literal + (p+1, L-1) (same bytes)."""
    items = list(items)
    i = len(items) - 1
    while len(items) % 8:
        while i >= 0 and not (items[i][0] == 'M' and items[i][2] >= 4):
            i -= 1
        if i < 0:
            raise ValueError('cannot pad a window to whole flag groups')
        _, p, L = items[i]
        items[i:i + 1] = [('L',), ('M', (p + 1) & (RING - 1), L - 1)]
    return items


def _emit(items, cb, a):
    out, code, mask, x = bytearray(), bytearray(1), 1, a
    for it in items:
        if it[0] == 'M':
            p, L = it[1], it[2]
            code += bytes([p & 0xFF, ((p >> 4) & 0xF0) | (L - 3)])
            x += L
        else:
            code[0] |= mask
            code.append(cb[x])
            x += 1
        mask = (mask << 1) & 0xFF
        if not mask:
            out += code
            code, mask = bytearray(1), 1
    if len(code) > 1:
        out += code
    return bytes(out), x


def splice(base_stream, new_decoded, changes, depth=256):
    """base_stream decodes to the old archive; new_decoded differs from it only inside the
    [a, b) spans of `changes`. Returns the new stream."""
    g = groups(base_stream)
    total = g[-1][1]
    wins = []
    for a, b in sorted(changes):
        s0 = max(i for i, (s, p) in enumerate(g) if p <= a)
        e = next((i for i, (s, p) in enumerate(g) if p >= b + RING), len(g) - 1)
        if wins and s0 <= wins[-1][1]:
            wins[-1][1] = max(wins[-1][1], e)
        else:
            wins.append([s0, e])
    cb = bytes([FILL]) * START + bytes(new_decoded)
    out, prev = bytearray(), 0
    for s0, e in wins:
        (so, po), (eo, pe) = g[s0], g[e]
        out += base_stream[prev:so]
        items = _items(cb, 0, START + po, START + pe, depth)
        if e != len(g) - 1:
            items = _pad(items)
        enc, x = _emit(items, cb, START + po)
        assert x == START + pe
        out += enc
        prev = eo
    out += base_stream[prev:]
    return bytes(out)


def encode(data, depth=256):
    """The whole stream for data (the optimal parse above, fixed-position zero runs)."""
    cb = bytes([FILL]) * START + bytes(data)
    enc, x = _emit(_items(cb, 0, START, START + len(data), depth), cb, START)
    assert x == START + len(data)
    return enc
