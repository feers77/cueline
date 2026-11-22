# Pro DJ Link compatibility

> **Cueline 2.2:** KEY SHIFT and KEY SYNC are switched off in this release (back in 2.3), and a 2.2 deck sends the
> stock status packet to every device. The KEY SYNC notes below describe 2.1 / 2.1.1 and will apply again in 2.3.
- **How Cueline appears on the network:** exactly like a stock CDJ-2000NXS2 (model name `CDJ-2000NXS2`,
  firmware 1.87, the stock keep-alive packet). The only exception is the optional players 5 / 6 support.
- **Status packets per device.** Cueline sends each device the status format that device understands:

  | Device on the LINK | What Cueline sends |
  |---|---|
  | CDJ-3000 / CDJ-3000X | the CDJ-3000 status format with our key fields, so the 3000's KEY SYNC can follow our master |
  | CDJ-2000NXS2 (stock or Cueline) | the NXS2 status plus our key fields (stock decks read only the stock part) |
  | DJMs, rekordbox, XDJs, other / unknown devices | the exact stock CDJ-2000NXS2 status |
  | UTILITY > INFO > LINK KEY STATUS = OFF | the exact stock status to every device |

- **Tested with:**
  - stock CDJ-2000NXS2 decks next to Cueline: SYNC both ways, tempo follow, master handoff both ways and LINK
    loads both ways (emulator test suite, and the real decks since earlier builds);
  - **CDJ-3000 in an emulator only** (original firmware 3.22). KEY SYNC from the 3000 to a Cueline master engages
    (green key, no UNAVAILABLE). A Cueline deck follows the 3000's key including its KEY SHIFT. SYNC, tempo
    follow, master handoff and loading from our USB over LINK also work. This has not yet been tried with a
    real CDJ-3000 or CDJ-3000X;
  - **Link Cue** with a real DJM-A9 (LINK CUE).
- **Real CDJ-3000 / 3000X checklist.** Please report your results: they have not been confirmed on real hardware yet.
  1. A 3000 and Cueline on one LINK: the 3000 lists our deck as a LINK source, loads a track from our USB and
     shows BPM, master badge and track normally.
  2. Cueline is master and playing: press KEY SYNC on the 3000. It must engage (K.SYNC box, green key), not show
     UNAVAILABLE. Change our KEY SHIFT by +3: the 3000 follows. Toggle KEY SYNC off and on.
  3. The 3000 is master: our KEY SYNC follows the 3000's key; KEY SHIFT +2 / -3 on the 3000 is followed too.
  4. SYNC both ways, master handoff both ways (MASTER buttons), BEAT SYNC tempo follow, phase meter.
  5. CDJ-3000X: repeat 2 and 3 (its status format has not been verified at all).
  6. With a DJM-A9 / V10 / 900NXS2 and rekordbox on the LINK: no errors.
  7. UTILITY > INFO > LINK KEY STATUS = OFF: the 3000 shows UNAVAILABLE again; everything else is unchanged.
- **Known risk:** a non-Pioneer device or app that names itself `CDJ-3…` gets the CDJ-3000 format (the same
  format a real CDJ-3000 sends). Tools that pose as a CDJ-2000NXS2 get the NXS2 or the stock format.
