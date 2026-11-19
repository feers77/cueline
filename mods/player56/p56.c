/* SPDX-License-Identifier: Apache-2.0
 * player56: choose the 3 "other player" status records the stock sync module works with.
 * Stock (own 1..4): the other three of players 1..4, ascending. With a peer 5 or 6 on the
 * link (or own 5/6): the three best of players 1..6 except own, ranked present > absent,
 * then master flag (rec+0x89 bit 0x20), then the larger counter rec+0x84, then lower number,
 * so the master and the max counter are always among them. */
#include <stdint.h>
#define DEV_PRESENT(d) (*(volatile uint32_t *)(0x0A35F80CUL + (uint32_t)(d) * 0x414u))
#define REC(P, d) ((P) + (uint32_t)(d) * 0x124u)

void p56_pick3(int own, uint8_t *P, uint32_t *out)
{
	int k, d;
	unsigned used = 0;		/* bit d */
	if (own >= 1 && own <= 4 && !DEV_PRESENT(5) && !DEV_PRESENT(6)) {
		for (k = 0, d = 1; d <= 4; d++)
			if (d != own)
				out[k++] = (uint32_t)REC(P, d);
		return;
	}
	if (own >= 1 && own <= 6)
		used |= 1u << own;
	for (k = 0; k < 3; k++) {
		int best = 0;
		uint32_t bkey = 0, bcnt = 0;
		for (d = 1; d <= 6; d++) {
			const uint8_t *r = REC(P, d);
			uint32_t pres, key, cnt;
			if (used & (1u << d))
				continue;
			pres = DEV_PRESENT(d) != 0;
			key = (pres << 2) | ((pres && (r[0x89] & 0x20)) ? 2u : 0u);
			cnt = *(const volatile uint32_t *)(r + 0x84);
			if (!best || key > bkey || (key == bkey && cnt > bcnt)) {
				best = d; bkey = key; bcnt = cnt;
			}
		}
		used |= 1u << best;
		out[k] = (uint32_t)REC(P, best);
	}
}
