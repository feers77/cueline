! SPDX-License-Identifier: GPL-2.0-or-later
!
! 3-band centre waveform for the CDJ-2000NXS2 display firmware (SH7269, SH-2A,
! big-endian). patch_gui.py places this routine in unused on-chip RAM and
! replaces the RGB column fill of the centre-waveform renderer with a call to
! it. The renderer keeps one 16-bit word per waveform entry; the stock word is
! RGB (red 15-13, green 12-10, blue 9-7, height 6-2, bits 1-0 always clear).
! The main board's 3-band mod rewrites the entries in place as
!
!     high5 << 11 | mid5 << 6 | low5 << 1 | 1
!
! so bit 0 tells the two apart. This draws one screen column:
!
!   bit 0 clear   the stock fill, unchanged: the word's own RGB colour, as
!                 many rows up from row 70 as the renderer's height.
!   bit 0 set     the 3-band column. Each band's height is the largest of
!                 its field over the column's entry group, 3 * field / 2 rows
!                 and at least one (the stock height rule, so a full band is
!                 as tall as a full RGB column). Each row takes its colour
!                 from which bands still reach it: low blue, mid amber, high
!                 white, and a blend where two or three overlap.
!
! The renderer's own peak search is meaningless on 3-band words, so r12 (the
! height it hands on to the cue and loop marks drawn above the column) is set
! to the tallest band.
!
! In:  r4 = screen column, r5 = index of the column's peak entry,
!      r6 = height in rows (1..55), r7 = the entry array,
!      @(40,r15) = first entry of the column's group, @(12,r15) = its length
!      (read off the renderer's frame: the call does not move r15).
! r0-r7 and r12 are clobbered; nothing else is touched.
!
! The last word is the renderer's canvas address. It differs between
! firmware builds, so patch_gui.py fills it in from the instruction this
! call replaces.

        .text
        .global wave3
wave3:
        mov.l   canvas,r2
        movi20  #0x1a400,r0             ! centre row 70 of the 768-pixel canvas
        add     r0,r2
        shll    r4
        add     r2,r4                   ! r4 = the column's centre pixel

        mov     r5,r0
        shll    r0
        mov.w   @(r0,r7),r3
        extu.w  r3,r3                   ! r3 = the peak entry
        mov     r3,r0
        tst     #1,r0
        bt      stock

        mov.l   @(40,r15),r0
        shll    r0
        add     r0,r7
        mov     r7,r5                   ! r5 = first entry of the group
        mov.l   @(12,r15),r2            ! r2 = entries left
        mov     #0,r7                   ! r7 = low, r12 = mid, r6 = high
        mov     #0,r12
        mov     #0,r6
1:      mov.w   @r5+,r3
        extu.w  r3,r3
        mov     r3,r1
        shlr    r1
        mov     r1,r0
        and     #31,r0
        cmp/hi  r7,r0
        bf      2f
        mov     r0,r7
2:      mov     r3,r1
        shlr2   r1
        shlr2   r1
        shlr2   r1
        mov     r1,r0
        and     #31,r0
        cmp/hi  r12,r0
        bf      3f
        mov     r0,r12
3:      mov     r3,r1
        shlr8   r1
        shlr2   r1
        shlr    r1
        cmp/hi  r6,r1
        bf      4f
        mov     r1,r6
4:      dt      r2
        bf      1b

        .macro  bandrows field
        mov     \field,r0
        add     \field,r0
        add     \field,r0
        shlr    r0
        tst     r0,r0                   ! a silent band still shows one row
        movt    r1
        or      r1,r0
        mov     r0,\field
        .endm
        bandrows r7
        bandrows r12
        bandrows r6

        mov     r7,r1                   ! r1 = the tallest band
        cmp/hs  r12,r1
        bt      5f
        mov     r12,r1
5:      cmp/hs  r6,r1
        bt      6f
        mov     r6,r1
6:      mov     #-6,r3
        shll8   r3                      ! r3 = one row up
        mov     #0,r5                   ! r5 = row, counted up from the centre
7:      mov     #0,r2                   ! r2 = which bands reach this row
        cmp/gt  r5,r7
        rotcl   r2
        cmp/gt  r5,r12
        rotcl   r2
        cmp/gt  r5,r6
        rotcl   r2
        shll    r2
        mova    bands,r0
        mov.w   @(r0,r2),r2
        mov.w   r2,@r4
        add     #1,r5
        cmp/eq  r5,r1
        bf/s    7b
        add     r3,r4
        rts
        mov     r1,r12

stock:
.ifdef RGB3000
! wave3rgb: a track without 3-band data is drawn in the CDJ-3000 RGB mode
! (ui3000x_wavergb's colour) instead of the stock additive red: the three
! 3-bit fields squared, so the dominant band wins, and the canvas palette
! low #005AFF, mid #FFA028, high #EBF5FF blended by them in 5/6/5 space.
! r12 (the renderer's height for the marks above) is left alone.
        mov.l   r8,@-r15
        mov.l   r9,@-r15
        mov     r3,r0
        mov     #-13,r1
        shld    r1,r0
        and     #7,r0
        mul.l   r0,r0
        sts     macl,r5                 ! r5 = low^2
        mov     r3,r0
        mov     #-10,r1
        shld    r1,r0
        and     #7,r0
        mul.l   r0,r0
        sts     macl,r2                 ! r2 = mid^2
        mov     r3,r0
        mov     #-7,r1
        shld    r1,r0
        and     #7,r0
        mul.l   r0,r0
        sts     macl,r7                 ! r7 = high^2
        mov     r5,r3
        add     r2,r3
        add     r7,r3                   ! r3 = s
        tst     r3,r3
        bt      rgb0                    ! a silent sample: black
        mov     #22,r0                  ! G6 = (low*22 + mid*40 + high*61) / s
        mul.l   r5,r0
        sts     macl,r8
        mov     #40,r0
        mul.l   r2,r0
        sts     macl,r0
        add     r0,r8
        mov     #61,r0
        mul.l   r7,r0
        sts     macl,r0
        add     r0,r8
        mov     r3,r0
        divu    r0,r8
        mov     #31,r0                  ! B5 = (low*31 + mid*5 + high*31) / s
        mul.l   r5,r0
        sts     macl,r9
        mov     #5,r0
        mul.l   r2,r0
        sts     macl,r0
        add     r0,r9
        mov     #31,r0
        mul.l   r7,r0
        sts     macl,r0
        add     r0,r9
        mov     r3,r0
        divu    r0,r9
        mov     #31,r0                  ! R5 = (mid*31 + high*29) / s
        mul.l   r2,r0
        sts     macl,r1
        mov     #29,r0
        mul.l   r7,r0
        sts     macl,r0
        add     r0,r1
        mov     r3,r0
        divu    r0,r1
        shll8   r1
        shll2   r1
        shll    r1                      ! R5 << 11
        shll2   r8
        shll2   r8
        shll    r8                      ! G6 << 5
        or      r8,r1
        bra     rgbfill
        or      r9,r1
rgb0:   mov     #0,r1
rgbfill:
        mov.l   @r15+,r9
        bra     stfill
        mov.l   @r15+,r8
.endif
        mov     r3,r1
        shlr2   r1
        movi20  #0x700,r0
        and     r0,r1
        mov     r3,r2
        shlr2   r2
        shlr2   r2
        shlr    r2
        mov     r2,r0
        and     #28,r0
        add     r0,r1
        movi20  #0xe000,r0
        and     r3,r0
        add     r0,r1                   ! r1 = the word's own colour
stfill:
        mov     #-6,r3
        shll8   r3
8:      mov.w   r1,@r4
        dt      r6
        bf/s    8b
        add     r3,r4
        rts
        nop

! RGB565 colour by which bands reach the row (low, mid, high as bits 2..0),
! layered as the CDJ-3000 draws them (high over mid over low, solid): low
! #0057EA, mid #C06400, high #F7EBD5, measured on real CDJ-3000 fw 3.2x
! frames (re/CDJ3000X_EMU_MINING.md). Entry 0 is unused.
        .p2align 2
bands:  .word   0x0000, 0xf75a, 0xc320, 0xf75a, 0x02bd, 0xf75a, 0xc320, 0xf75a

        .p2align 2
canvas: .long   0
