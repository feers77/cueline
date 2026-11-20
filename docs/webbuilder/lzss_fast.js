// SPDX-License-Identifier: GPL-2.0-or-later
// JavaScript port of the hot path of scripts/firmware/lzss_encode.py: pack_optimal() (longest_matches() with
// OPTIMAL_DEPTH + the dynamic-programming parse). It must produce exactly the bytes the Python does -- same
// candidate order (newest first), same window rule, same depth cut-off, same tie-breaks -- and the builder checks
// the final .UPD sha256 against the release anyway, so any divergence fails the build instead of shipping.
// Python's per-key lists (oldest first, with too-old entries dropped from the front) are kept here as one
// linked list per 3-byte key (newest first): walking it until a position falls out of the window visits the
// same candidates in the same order.
'use strict';

const LZSS = (() => {
  const RING = 4096, FILL = 0x20, START = RING - 18, MIN_MATCH = 3, MAX_MATCH = 18, OPTIMAL_DEPTH = 1024;

  function longestMatches(data, depth) {
    const n = data.length, total = START + n;
    const cb = new Uint8Array(total);
    cb.fill(FILL, 0, START);
    cb.set(data, START);
    const head = new Int32Array(1 << 24).fill(-1);   // newest position for each 3-byte key
    const prev = new Int32Array(total);              // next older position with the same key
    const key = (p) => (cb[p] << 16) | (cb[p + 1] << 8) | cb[p + 2];
    for (let pos = 0; pos < START; pos++) {
      if (pos + 3 <= total) { const k = key(pos); prev[pos] = head[k]; head[k] = pos; }
    }
    const lens = new Uint8Array(n), srcs = new Int32Array(n);
    for (let k = 0; k < n; k++) {
      const a = START + k;
      const limit = Math.min(MAX_MATCH, total - a);
      if (limit < MIN_MATCH) continue;
      const kk = key(a);
      const lo = a - RING;
      let bestLen = 0, bestPos = 0, checked = 0;
      for (let p = head[kk]; p >= lo && p >= 0; p = prev[p]) {
        let length = 3;
        while (length < limit && cb[p + length] === cb[a + length]) length++;
        if (length > bestLen) {
          bestLen = length; bestPos = p;
          if (bestLen >= limit) break;
        }
        if (++checked >= depth) break;
      }
      lens[k] = bestLen; srcs[k] = bestPos;
      prev[a] = head[kk]; head[kk] = a;
    }
    return { lens, srcs, cb };
  }

  function packOptimal(data) {
    const { lens, srcs, cb } = longestMatches(data, OPTIMAL_DEPTH);
    const n = data.length;
    const cost = new Float64Array(n + 1);
    const take = new Uint8Array(n);
    for (let i = n - 1; i >= 0; i--) {
      let best = 9 + cost[i + 1], choice = 0;
      const L = lens[i];
      if (L >= MIN_MATCH) {
        for (let k = L; k >= MIN_MATCH; k--) {
          const c = 17 + cost[i + k];
          if (c < best) { best = c; choice = k; }
        }
      }
      cost[i] = best; take[i] = choice;
    }
    const out = new Uint8Array(n + Math.ceil(n / 8) + 16);   // worst case: all literals
    let o = 0, flagAt = 0, mask = 1;
    out[o++] = 0;
    let k = 0;
    while (k < n) {
      let step = take[k];
      if (step) {
        const off = srcs[k] & (RING - 1);
        out[o++] = off & 0xFF;
        out[o++] = ((off >> 4) & 0xF0) | (step - MIN_MATCH);
      } else {
        step = 1;
        out[flagAt] |= mask;
        out[o++] = cb[START + k];
      }
      k += step;
      mask = (mask << 1) & 0xFF;
      if (mask === 0) { flagAt = o; out[o++] = 0; mask = 1; }
    }
    if (o - flagAt === 1) o--;          // drop an empty trailing flag byte, as the Python does
    return out.slice(0, o);
  }

  return { packOptimal };
})();

if (typeof module !== 'undefined') module.exports = LZSS;
