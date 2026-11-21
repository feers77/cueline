# Cueline known limits

This page lists everything we know Cueline does not do yet, or has not yet tested on a real deck. It covers the
normal RELEASE build.

## Planned improvements

- **KEY SHIFT at large shifts:** better sound quality is planned (today it can sound phasey).

## Not yet tested on a real deck

Not yet confirmed on real hardware:

- **KEY SHIFT sound quality.** Our own engine runs on the real decks; how it sounds, especially at large shifts,
  has not been judged yet.
- **KEY SYNC with a CDJ-3000 master**, tested against a CDJ-3000 emulator, not a real CDJ-3000.
- **Touch Cue** (preview from the overview strip) has no dedicated test on a real deck yet.
- **The KEY SYNC BUTTON pad lamp:** its exact colour on a real deck is not yet confirmed.
- **Artwork of the loaded track:** on the deck it depends on a backup method that is not yet confirmed.

## KEY SHIFT and KEY SYNC

- About **23 ms of extra latency** while a key shift is active.
- Large shifts can sound **"phasey"**.
- The shift **keeps running while you scratch**.
- Very **fast double taps** on -1 / +1 can be missed.
- KEY SYNC needs **Pro DJ Link**, a tempo master with a known key, and **KEY SHIFT ON**.
- KEY SYNC moves the key by at most 2 semitones (the same key, or one Camelot step either way).
- With **KEY SYNC BUTTON** ON, hot cues **D and H** cannot be used from that pad.

## Working with a CDJ-3000

- A CDJ-3000 does **not show the key** of a track loaded from our deck's media.
- A real CDJ-3000 reading our key, or doing KEY SYNC to our deck, is **untested**.
- The phase meter **WAVEFORM view is empty** for a CDJ-3000 master playing from **SD**. Its beat grid still shows.
  With NXS2 masters the waveform works.

## Link Cue

- Needs a **DJM-A9** with LINK CUE, on **Pro DJ Link**.
- Plays **MP3, FLAC and WAV** only. **AIFF and M4A** rows stay silent.
- **One deck at a time.** The mixer keeps a single Link Monitor slot, so with two Cueline decks on the LINK the
  monitor follows the deck you touched last (2.1.1). Two rough edges there, both to be improved: the hand-over
  takes a moment, so the sound starts with a short delay, and holding a preview on both decks at the same time can
  interleave the audio for a few seconds. **UTILITY → PRO DJ LINK → LINK CUE = OFF** on one deck removes any doubt.
- **UTILITY → PRO DJ LINK → LINK CUE** is saved only when the deck's HISTORY name is 23 characters or shorter;
  with a longer name it comes back as BOTH at every power-on.

## Waveforms and grid

- **3BAND** needs rekordbox 3-band data. Without it, the RGB look is used.
- In 3BAND, the **overview is always drawn from the bottom**, even with WAVEFORM set to FULL (as on the CDJ-3000).
- WAVEFORM FULL / HALF changes only the overview and the browse mini waveforms. The detail waveform is always full.
- **GRID ADJUST is display only.** The drawn grid moves, but the deck's own beat grid (used for SYNC and QUANTIZE)
  does not.
- **BEAT NUMBERS** and **GRID ADJUST** are temporary UTILITY rows. They are not saved and are ON at every power-on.
- Tracks **without rekordbox analysis** show no waveform, overview or beat grid (as on the CDJ-3000).

## Saved settings

- WAVEFORM (FULL / HALF), KEY FORMAT, KEY SHIFT, KEY SYNC BUTTON and the BEAT JUMP value are saved with the HISTORY
  NAME. They are kept only with a **HISTORY NAME of 29 characters or fewer**. Otherwise they go back to their
  defaults.
- The **kill switches**, **BEAT NUMBERS** and **GRID ADJUST** are never saved.

## BEAT JUMP

- Whole beats only, from 1 to 64. There is no 1/2-beat jump.

## Players 5 and 6

- Need other gear on Pro DJ Link that supports players 5 and 6.
- A deck with the official NXS2 firmware **will not share its media** with players 5 or 6.

## Languages and font

- Menus in **English and Spanish only**. The other menu languages, and the Chinese and Korean fonts, were removed to
  free space. If you need another language, stay on the official firmware.
- With ESPAÑOL, **UTILITY item names stay in English**.
- The list text from the official firmware is drawn **without kerning** (letter-pair spacing) in Cueline Sans.

## Going back to stock

- The official 1.87 update is **skipped** until you do UTILITY > DUPLICATION > **DEFAULT**. That factory reset also
  erases your deck settings. Disconnect the Pro DJ Link (LAN) cable first: while LINK is active the player does not allow DUPLICATION > DEFAULT. See `FAQ.md`.

## Not in the RELEASE build

- **No BLACK BOX recorder, no logs and no network commander.** They exist only in the DEV build for contributors
  (`dev/README.md`).
