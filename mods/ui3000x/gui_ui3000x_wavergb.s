! SPDX-License-Identifier: Apache-2.0
!
! ui3000x_wavergb -- recolour the centre scrolling waveform of the
! CDJ-2000NXS2 display firmware (SH7269, SH-2A, big-endian) to the exact
! CDJ-3000X / canvas palette.  TEST build; opt-in.  re/UI3000X.md.
!
! The default centre waveform is NOT drawn from the 8-entry 3-band palette
! table (that is the "3-band pure" mode of the base, flag *0x0E5EB6EC).  By
! default each screen column is filled in CODE with one RGB565 colour built
! from the peak sample's own 16-bit word, whose fields the firmware treats as
! additive energy:
!
!     bits 15-13  low  (red)      bits 12-10  mid  (green)
!     bits  9-7   high (blue)     bits  6-2   height
!
! The stock fill expands those three 3-bit fields straight into the top three
! bits of the R, G and B channels of RGB565 -- so a low-heavy sample shows red,
! a high-heavy one blue.  The CDJ-3000X / canvas maps the bands the other way:
! low #005AFF, mid #FFA028, high #EBF5FF.  This routine replaces the stock
! field expansion with a weighted blend of those three colours -- the squared
! band energy as the weight, exactly as pioneer_palette.wave_rgb does, so the
! dominant band wins and the column reads as one clean palette colour.
!
! patch_gui.py places this routine in the free on-chip slot and replaces the
! same span the three_band `wave3` mod hooks (the column's colour build plus
! its fill, 0x1C009CB6..0x1C009D4A).  The playhead stays red and the beat grid
! stays as the firmware draws them -- both are painted after this returns.
!
! In:  r4 = @(44,r15) screen column, r5 = peak sample index, r7 = entry array,
!      r12 = column height in rows (>=1, set by the caller).
!      r0-r7 are clobbered; r12 is read only; nothing else is touched.
!
! The last word is the renderer's canvas address; patch_gui.py (literal=True)
! fills it in from the instruction this call replaces.

        .text
        .global ui3000x_wavergb
ui3000x_wavergb:
        ! --- fetch the peak sample word ---
        shll    r5                      ! r5 = index * 2
        mov     r5,r0
        mov.w   @(r0,r7),r3
        extu.w  r3,r3                   ! r3 = the sample word

        ! --- centre pixel address of this column (consumes r4) ---
        shll    r4                      ! r4 = column * 2
        mov.l   canvas,r2               ! 0x1C200000 (filled in by patch_gui)
        add     r2,r4
        movi20  #0x1a400,r2             ! row 70 = 70 * 768 * 2 bytes
        add     r2,r4                   ! r4 = the column's centre pixel

        ! --- the three 3-bit band energies ---
        mov     r3,r0
        mov     #-13,r1
        shld    r1,r0
        and     #7,r0
        mov     r0,r5                   ! r5 = low  (red field)
        mov     r3,r0
        mov     #-10,r1
        shld    r1,r0
        and     #7,r0
        mov     r0,r6                   ! r6 = mid  (green field)
        mov     r3,r0
        mov     #-7,r1
        shld    r1,r0
        and     #7,r0
        mov     r0,r7                   ! r7 = high (blue field)

        ! --- square each so the dominant band wins (no muddy blend) ---
        mul.l   r5,r5
        sts     macl,r5                 ! r5 = low^2   (0..49)
        mul.l   r6,r6
        sts     macl,r6                 ! r6 = mid^2
        mul.l   r7,r7
        sts     macl,r7                 ! r7 = high^2

        mov     r5,r2
        add     r6,r2
        add     r7,r2                   ! r2 = s = sum of squares
        tst     r2,r2
        bt      black                   ! a silent sample -> black

        ! --- weighted blend of the canvas palette, in 5/6/5 channel space ---
        !   low  #005AFF = R 0   G 22  B 31
        !   mid  #FFA028 = R 31  G 40  B 5
        !   high #EBF5FF = R 29  G 61  B 31
        ! R5 = (mid^2 * 31 + high^2 * 29) / s
        mov     #31,r0
        mul.l   r6,r0
        sts     macl,r3
        mov     #29,r0
        mul.l   r7,r0
        sts     macl,r0
        add     r0,r3
        mov     r2,r0
        divu    r0,r3                   ! r3 = R5 (0..31)
        ! G6 = (low^2 * 22 + mid^2 * 40 + high^2 * 61) / s
        mov     #22,r0
        mul.l   r5,r0
        sts     macl,r1
        mov     #40,r0
        mul.l   r6,r0
        sts     macl,r0
        add     r0,r1
        mov     #61,r0
        mul.l   r7,r0
        sts     macl,r0
        add     r0,r1
        mov     r2,r0
        divu    r0,r1                   ! r1 = G6 (0..63)
        ! B5 = (low^2 * 31 + mid^2 * 5 + high^2 * 31) / s
        mov     #5,r0
        mul.l   r6,r0
        sts     macl,r6                 ! r6 = mid^2 * 5
        mov     #31,r0
        mul.l   r5,r0
        sts     macl,r0
        add     r0,r6
        mov     #31,r0
        mul.l   r7,r0
        sts     macl,r0
        add     r0,r6
        mov     r2,r0
        divu    r0,r6                   ! r6 = B5 (0..31)

        ! --- pack RGB565: (R5 << 11) | (G6 << 5) | B5 ---
        mov     r3,r0
        shll8   r0
        shll2   r0
        shll    r0                      ! R5 << 11
        shll2   r1
        shll2   r1
        shll    r1                      ! G6 << 5
        or      r1,r0
        or      r6,r0
        mov     r0,r1                   ! r1 = the column colour
        bra     fill
        mov     r12,r6                  ! r6 = height (delay slot)

black:
        mov     #0,r1
        mov     r12,r6                  ! r6 = height

fill:
        mov     #-6,r3
        shll8   r3                      ! r3 = -1536 = one row up (768 * 2 bytes)
1:      mov.w   r1,@r4
        dt      r6
        bf/s    1b
        add     r3,r4
        rts
        nop

        .p2align 2
canvas: .long   0
