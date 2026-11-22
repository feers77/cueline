! SPDX-License-Identifier: Apache-2.0
!
! ownstat.inc -- "what is loaded on THIS deck": the one place that answers it (F1, re/FOUNDATIONS_HANDOFF.md).
!
! MAIN keeps two views of a Pro DJ Link status:
!
!   LINK_TAB + p * LINK_STRIDE   the status record of player NUMBER p (1..6), fields native (little-endian):
!                                +0x28 source player | slot << 8 | type << 16 (bytes +0x28 / +0x29 / +0x2A),
!                                +0x2C rekordbox id, +0x89 flags, ... Record p IS player p's status by
!                                construction. +0x28 is the SOURCE player of the medium, not the sender: it is
!                                legitimately another player when we load from the other deck's USB, so it can
!                                never identify a record.
!   OWN_SLOT                     ONE fixed packet-shaped slot (same offsets, the rekordbox id BIG-endian). It
!                                holds the LAST status seen: our own alone on the wire, THE OTHER DECK'S as soon
!                                as a second deck is on the LINK. It is "ours" only while we have no player
!                                number (OWN_PNO == 0 = nobody else can be talking).
!
! Two shipped bugs came from reading the slot as "ours" (Touch Cue played the other deck's track; the master was
! compared with itself) and one from indexing the table with p - 1. So:
!
!   * the slot and the table base are named ONLY here; mods/check_ownstat.py fails the build on a raw
!     0x0B53D828 / 0x0A371D3C anywhere else, and on a table user it has not been told about;
!   * "our own status" is read ONLY through own_rec / own_loaded below.
!
! The macros are position independent, carry their own literals (jumped over) and use no MACL.

	.equ	OWN_SLOT, 0x0B53D828	! the last status packet seen (see above): never read it directly
	.equ	OWN_PNO, 0x0A35F680	! this deck's player number (1..6), 0 = none assigned yet
	.equ	LINK_TAB, 0x0A371D3C	! the LINK status table, by player NUMBER
	.equ	LINK_STRIDE, 0x124

! own_rec rD, rT: rD = this deck's own status record. rT != 0: the table's record (rekordbox id native);
! rT == 0: no player number yet, the slot (rekordbox id big-endian). The byte fields +0x28 / +0x29 / +0x2A /
! +0x89 read the same in both. Clobbers only rD, rT and T.
	.macro	own_rec rD, rT
	mov.l	.Lown_p\@,\rT
	mov.l	.Lown_s\@,\rD
	mov.l	@\rT,\rT
	tst	\rT,\rT
	bt	.Lown_x\@		! no number: alone on the wire, the slot IS our packet
	mov	\rT,\rD
	shll2	\rD			! p * 4
	shll2	\rT
	shll2	\rT
	shll	\rT			! p * 32
	add	\rT,\rD			! p * 36
	shll2	\rT
	shll	\rT			! p * 256
	add	\rT,\rD			! p * 0x124 (LINK_STRIDE)
	mov.l	.Lown_t\@,\rT
	bra	.Lown_x\@
	add	\rT,\rD
	.p2align 2
.Lown_p\@:	.long	OWN_PNO
.Lown_s\@:	.long	OWN_SLOT
.Lown_t\@:	.long	LINK_TAB
.Lown_x\@:
	.endm

! own_loaded: r4 = our loaded track's +0x28 word (source player | slot << 8 | type << 16), r5 = its rekordbox
! id, NATIVE whichever structure answered. Clobbers r0, r1 and T.
	.macro	own_loaded
	own_rec	r1, r0
	mov.l	@(0x28,r1),r4
	tst	r0,r0
	bf/s	.Lown_n\@
	mov.l	@(0x2C,r1),r5
	swap.b	r5,r5			! the slot's id is in network order
	swap.w	r5,r5
	swap.b	r5,r5
.Lown_n\@:
	.endm
