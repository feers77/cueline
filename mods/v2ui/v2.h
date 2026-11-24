/* SPDX-License-Identifier: Apache-2.0 */
/* V2 UI: our own renderer for the CDJ-2000NXS2 GUI (SH7269, SH-2A, big-endian). */
#ifndef V2_H
#define V2_H

typedef unsigned char u8;
typedef signed char s8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef signed int s32;

struct glyph {
	u16 code;	/* Unicode code point */
	u8 adv;		/* pen advance */
	s8 xoff;	/* ink box left edge, from the pen */
	u8 w;		/* ink box width */
	u32 off;	/* first byte in the font's pixel array */
};

struct font {
	u8 h;		/* cell height */
	u8 asc;		/* baseline from the cell top */
	u16 n;		/* glyph count */
	const struct glyph *g;
	const u8 *px;	/* 4-bpp rows, two pixels a byte, high nibble first */
};

extern const struct font f_s, f_m, f_l, f_xl, f_md, f_sd, f_bpm, f_t, f_ti;

#endif
