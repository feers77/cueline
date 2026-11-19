/* SPDX-License-Identifier: Apache-2.0 */
/*
 * player56 server side: the UI-notify object 0x0AB82D38 keeps per-requester areas for
 * requesters 0..4 inside obj+0..0x21E0 (sub-objects of 0x54 bytes, magic 0xAFD837B9):
 *   obj + p*0x2A0 + menu*0xA8 + j*0x54      (4 menus x 2 lists)
 *   obj + 0xD20 / 0xEC4 / 0x1068 + p*0x54
 *   obj + 0x120C + p*4                      (notify object pointer)
 *   obj + 0x1220 / 0x1950 + p*0x150 + menu*0x54
 * A requester 5 or 6 gets its own zeroed copy of that range (a "shadow", allocated when it
 * first registers) and is served as index 1 inside it: the entry stubs swap obj for the
 * shadow (p56ui_entries.S), the DMST parser turns the player byte into 1 (p56_uiDmst),
 * register/unregister and the broadcasts below do the same explicitly. Index 0 of a shadow
 * (the local deck in obj) and indexes 2..4 stay zero, i.e. "not registered", which the stock
 * loops already handle for absent requesters. The default list obj+0x1F40 is the one shared
 * piece; each shadow gets its own (initialised like the local deck's, 50000 entries), and the
 * 'current request' word obj+0x1F94 follows the object of the last 0x083DD826 call (p56_uiCur).
 * Without a shadow nothing changes: the stock parser check refuses players >= 5.
 */
#include <stdint.h>

#define SHADOW_SIZE 0x21E0

typedef int (*fn_t)();
#define K(a) ((fn_t)(a))
#define k_malloc   ((void *(*)(int))0x08344A9C)
#define k_memset   ((void *(*)(void *, int, int))0x08533D50)
#define k_free     ((void (*)(void *))0x08344B42)
#define ui_reg     K(0x083DD108)
#define ui_unreg   K(0x083DD56E)
#define ui_reinit  K(0x083DD36E)
#define ui_release K(0x083DD6D0)
#define ui_maxw    K(0x083DE302)
#define ui_find    K(0x083DF5E4)
#define ui_bc740   K(0x083DF740)
#define ui_bc83e   K(0x083DF83E)
#define ui_bc8a2   K(0x083DF8A2)
#define ui_bcb84   K(0x083DFB84)
#define sub_init   K(0x083DAE78)
#define sub_free   K(0x083DAFA0)
#define w_menu     K(0x083E5BA8)
#define w_drop     K(0x083E5302)
#define m_get      K(0x0820CDDC)
#define m_chk1     K(0x0820D7EA)
#define m_chk2     K(0x0820D836)
#define m_fn3      K(0x0820D8C2)

extern uint32_t p56_req[7];
char *p56_uiH[2];		/* shadows for requesters 5, 6 (never freed) */
int p56_uiCurP;		/* 5/6 while a shadow is being served, else 0 */
char *p56_uiCur;		/* object of the last 0x083DD826 call (owner of obj+0x1F94) */

/* call a stock function on shadow k with p56_uiCurP set (media calls inside see 5/6) */
#define SH(k, f, ...) ({ p56_uiCurP = 5 + (k); int _r = f(__VA_ARGS__); p56_uiCurP = 0; _r; })

static int live(int k)
{
	return p56_uiH[k] && p56_req[5 + k] == 1;
}

char *p56_uiShadow(int p)
{
	char **h = &p56_uiH[p - 5];
	if (!*h) {
		if (*(volatile unsigned int *)0x0A35DF3C != 1)
			return 0;	/* update-safety: allocate only in a normal boot */
		char *m = k_malloc(SHADOW_SIZE);
		if (!m)
			return 0;
		k_memset(m, 0, SHADOW_SIZE);
		/* the default list obj+0x1F40 (DMST -1 and list types 1/20/21) is set up by the
		 * stock register of the local deck (p 0); a shadow needs its own, same size */
		if (sub_init(m + 0x1F40, 50000) != 0) {
			k_free(m);
			return 0;
		}
		*h = m;
	}
	return *h;
}

/* server register / unregister of requester p (0x082BF762 / 0x082BF6D8 and 0x082ADB4C / 0x082BF634) */
int p56_uiset(char *obj, int p)
{
	p &= 0xFF;
	if (p <= 4)
		return ui_reg(obj, p);
	if (p > 6)
		return 0;
	char *h = p56_uiShadow(p);
	if (!h)
		return -1;		/* no memory: the parser keeps refusing 5/6 */
	p56_uiCurP = p;
	int r = ui_reg(h, 1);
	p56_uiCurP = 0;
	return r;
}

int p56_uiclr(char *obj, int p)
{
	p &= 0xFF;
	if (p <= 4)
		return ui_unreg(obj, p);
	if (p > 6 || !p56_uiH[p - 5])
		return 0;
	p56_uiCurP = p;
	int r = ui_unreg(p56_uiH[p - 5], 1);
	p56_uiCurP = 0;
	return r;
}

/* 0x083DD36E(obj, menu+1): re-create the menu's lists of every registered requester.
 * Shadows: index 1 only (index 0 would get the local deck's big lists). */
int p56_uiReinit(char *obj, int m1)
{
	int r = ui_reinit(obj, m1);
	unsigned m = (m1 - 1) & 0xFF;
	for (int k = 0; k < 2; k++) {
		if (!live(k))
			continue;
		char *h = p56_uiH[k];
		char *a = h + 0x2A0 + m * 0xA8;
		sub_init(a, m == 3 ? 32 : m == 0 ? 64 : 50000);
		sub_init(a + 0x54, 0xA5);
		sub_init(h + 0x1220 + 0x150 + m * 0x54, 100);
		sub_init(h + 0x1950 + 0x150 + m * 0x54, 16);
	}
	return r;
}

/* 0x083DD6D0(obj, menu+1): drop the menu's lists (shared default object handled by stock). */
int p56_uiRelease(char *obj, int m1)
{
	int r = ui_release(obj, m1);
	if (r != 0)
		return r;
	unsigned m = (m1 - 1) & 0xFF;
	for (int k = 0; k < 2; k++) {
		char *h = p56_uiH[k];
		if (!h)
			continue;
		uint32_t w = *(uint32_t *)(h + 0x120C + 4);
		if (w && (unsigned)((w_menu(w) & 0xFF) - 1) == m)
			w_drop(w);
		if (p56_req[5 + k] != 1)
			continue;
		char *a = h + 0x2A0 + m * 0xA8;
		sub_free(a);
		sub_free(a + 0x54);
		sub_free(h + 0x1220 + 0x150 + m * 0x54);
		sub_free(h + 0x1950 + 0x150 + m * 0x54);
	}
	return r;
}

/* broadcasts over requesters 0..4: run them on each live shadow too */
int p56_uiMaxw(char *obj, int a)
{
	int r = ui_maxw(obj, a);
	for (int k = 0; k < 2; k++)
		if (live(k)) {
			int s = SH(k, ui_maxw, p56_uiH[k], a);
			if (s > r)
				r = s;
		}
	return r;
}

int p56_uiFind(char *obj, int a, int b, int c, int d, int e, int f, int g)
{
	int r = ui_find(obj, a, b, c, d, e, f, g);
	for (int k = 0; k < 2; k++)
		if (live(k) && SH(k, ui_find, p56_uiH[k], a, b, c, d, e, f, g) == 0)
			r = 0;
	return r;
}

int p56_uiBc740(char *obj, int a, int b, int c, int d, int e, int f, int g)
{
	int r = ui_bc740(obj, a, b, c, d, e, f, g);
	for (int k = 0; k < 2; k++)
		if (live(k))
			SH(k, ui_bc740, p56_uiH[k], a, b, c, d, e, f, g);
	return r;
}

int p56_uiBc83e(char *obj, int a, int b, int c, int d, int e, int f, int g)
{
	int r = ui_bc83e(obj, a, b, c, d, e, f, g);
	for (int k = 0; k < 2; k++)
		if (live(k))
			SH(k, ui_bc83e, p56_uiH[k], a, b, c, d, e, f, g);
	return r;
}

int p56_uiBc8a2(char *obj, int a, int b, int c, int d, int e, int f, int g)
{
	int r = ui_bc8a2(obj, a, b, c, d, e, f, g);
	for (int k = 0; k < 2; k++)
		if (live(k))
			SH(k, ui_bc8a2, p56_uiH[k], a, b, c, d, e, f, g);
	return r;
}

int p56_uiBcb84(char *obj, int a, int b, int c, int d, int e, int f, int g)
{
	int r = ui_bcb84(obj, a, b, c, d, e, f, g);
	if (r == 0)
		for (int k = 0; k < 2; k++)
			if (live(k))
				SH(k, ui_bcb84, p56_uiH[k], a, b, c, d, e, f, g);
	return r;
}

/* media-slot calls made by the UI module with the parsed player (index 1 inside a shadow):
 * give the media module the real requester 5/6 (0x083DDBF6 CHK1, 0x083DF348 GET,
 * 0x083DF370 CHK2, 0x083DCE4E FN3) */
static int unf(int p)
{
	return ((p & 0xFF) == 1 && p56_uiCurP) ? p56_uiCurP : p;
}

int p56_mGETu(int t, int p) { return m_get(t, unf(p)); }
int p56_mCHK1u(int t, int p) { return m_chk1(t, unf(p)); }
int p56_mCHK2u(int t, int p) { return m_chk2(t, unf(p)); }
int p56_mFN3u(int t, int p, int a, int b) { return m_fn3(t, unf(p), a, b); }
