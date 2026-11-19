/* SPDX-License-Identifier: Apache-2.0
 * gui78: in-place replacement of 0x084E44E6 (device -> deck-state source code).
 * Stock: 1..4 -> 1..4, 33 -> 5, 17/18 -> 6, else 0. Here also 5 -> 7, 6 -> 8.
 * Uses only r0/r2 like the stock body; 0x3C bytes available. */
	.text
	.org 0
f:	mov	r4,r0
	mov	r4,r2
	cmp/eq	#33,r0
	bt	L5
	cmp/eq	#17,r0
	bt	L6
	cmp/eq	#18,r0
	bt	L6
	tst	r0,r0
	bt	L0
	cmp/eq	#5,r0
	bt	L56
	cmp/eq	#6,r0
	bt	L56
	mov	#4,r2
	cmp/hi	r2,r0
	bt	L0
	bra	Lr
	mov	r4,r2
L56:	bra	Lr
	add	#2,r2
L5:	bra	Lr
	mov	#5,r2
L6:	bra	Lr
	mov	#6,r2
L0:	mov	#0,r2
Lr:	rts
	mov	r2,r0
