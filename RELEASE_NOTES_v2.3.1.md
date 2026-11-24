# Cueline 2.3.1

**A fix release for 2.3, plus the CDJ-3000 look taken further.** 2.3.1 fixes a loss of treble that 2.3 has after
KEY SHIFT has been used (going back to 0 left a gentle low-pass on the audio until the deck was switched off), and
several display bugs found in a full code review. The LINK phase meter and the player screen now follow the
CDJ-3000's proportions more closely. **If you run 2.3 or anything older, update to 2.3.1.**

2.3.1 was run on two real CDJ-2000NXS2 decks on Pro DJ Link with two unattended test scripts (9 and 33 minutes,
each on both decks) on a developer build of the same sources. The treble fix was verified in a host test of the
resampler, not by ear on the decks.

**Give new life to your CDJ-2000NXS2.** Custom firmware UI for the Pioneer CDJ-2000NXS2, inspired by the CDJ-3000.
Unofficial firmware patcher, **use at your own risk**, provided as-is without warranty. **Not affiliated with or
endorsed by Pioneer DJ / AlphaTheta.**

Cueline follows the deck's own version numbers: 2.3.1 = MAIN 2.30 / GUI 2.24. **Coming from 2.3, 2.2, 2.1 or 2.1.1
you do not need a factory reset** (MAIN 2.30 is newer, so the deck installs it). Coming from a build with
the same or a higher version number (a DEV build, another custom firmware), do **UTILITY → DUPLICATION → DEFAULT**
first, or the update is skipped. Your Cueline settings are carried over.

## Get it
No firmware file is attached. You build Cueline yourself from **your own official CDJ-2000NXS2 update 1.87**
(`C2KNXS2.UPD`, sha256 `f211191a573b7a5c0e694936871f76011a58d5861dd061301cdb0d8b83a8b3e5`):
- **EASY — in your browser:** [Cueline Web Builder](https://feers77.github.io/cueline/webbuilder/). Drop your `C2KNXS2.UPD`, click Download. Nothing to
  install; your file never leaves your computer.
- **Windows:** download `CuelineBuilder.exe` below and drag your `C2KNXS2.UPD` onto it.
- **macOS:** download `CuelineBuilder-macOS.zip` below (Intel and Apple Silicon), unzip, drag your `C2KNXS2.UPD`
  onto `CuelineBuilder.app`. First time: System Settings → Privacy & Security → **Open Anyway** (the app is not
  notarized). See README → *Easy install on macOS*.
- **Linux:** `python3 builder/cueline_patch.py /path/to/C2KNXS2.UPD` (from the source code, Python 3).
- **From source:** `./build.sh /path/to/C2KNXS2.UPD` (see the README).

All of them give the same file:
- `C2KNXS2.UPD` sha256 `65c30bdef959704e86460b996b5c2ec3f1add7b10fb677e5bcbbedbe6f6e0914`
- device version MAIN 2.30 / GUI 2.24; UTILITY → INFO → BUILD shows `Cueline-2.3.1 49e8943c`

## Install (read this)
1. **Coming from the official firmware, Cueline 2.3, 2.2, 2.1 or 2.1.1:** copy the built `C2KNXS2.UPD` **alone** to the root of a small FAT32 USB stick and
   install it like an official update. No factory reset, your settings stay. **Never switch the deck off during the
   update.**
2. **Coming from anything with the same or a higher version number** (a DEV build, another custom firmware), or if
   the deck skips the update: save MY SETTINGS with rekordbox and note your deck settings, **disconnect the Pro DJ
   Link (LAN) cable** (while LINK is active the player does not allow DUPLICATION → DEFAULT), do **UTILITY →
   DUPLICATION → DEFAULT** (factory reset, it erases your settings) and install again.
3. Check UTILITY → INFO → BUILD = `Cueline-2.3.1 49e8943c`.

**Back to stock:** LAN cable out, UTILITY → DUPLICATION → DEFAULT, then install the official 1.87 `C2KNXS2.UPD`
alone on the stick. Check UTILITY → VERSION = 1.87. Details: README → *Going back to stock*.

## New in 2.3.1 (since 2.3)
- **Treble lost after using KEY SHIFT (bug fix, 2.3 has this bug):** once a shift (or KEY SYNC) had been used, going
  back to 0 / RESET left the audio running through the resampler at a fixed in-between position, which acts as a
  gentle low-pass (about −3 dB at 11 kHz in the worst case) until a 48 / 96 kHz track was loaded or the deck was
  switched off. At exactly 0 the samples now pass unchanged.
- **LINK phase meter as on the CDJ-3000:** the PHASE view has a fixed time scale (it no longer changes with the
  waveform zoom), beat marks on one side of each line and a centre line; the WAVEFORM view sits lower, with shorter
  marks. Changing the view by touch, or leaving the player screen, no longer hands the display scaler back in the
  same frame (a cause we suspect for doubled tick rows seen for a moment on real decks).
- **Player screen in CDJ-3000 proportions:** PLAYER, QUANTIZE, BEAT JUMP and BPM boxes, header tiles, track title
  (larger type), minute ruler (taller marks, half minutes), cue marker and loop-length label are resized and
  repositioned. The pad row (BEAT LOOP, BEAT JUMP, KEY SHIFT, GRID ADJUST) has larger pads; while it is open the
  waveform is half height with its top beat marks in place, and ZOOM – GRID moves above the pads. Touch areas moved
  with the drawing.
- **Overview, last 7 % of the track (bug fix):** the top-right corner of the overview was erased on every track,
  hiding hot cue and memory marks near the end.
- **Key names (bug fix, 2.3 has this bug):** showing a browse list with eight rows overwrote part of the internal
  table of key names used for KEY SYNC and the master key. Found by code review and confirmed in the emulator; its
  effect on a deck was not measured.
- **Smaller fixes:** the K.SYNC tile lights when KEY SYNC is on with a shift of 0; small labels (QUANTIZE, KEY) no
  longer run together; the WAVEFORM meter follows a zoom change while both decks are paused; the minute ruler shows
  minutes above 99; SOURCE shows the right total when used and free space come in different units; the waveform is
  read again after a load (a re-read that never ran); the hidden loop window of the original firmware is now
  switched off on every screen, not only on the player.
- **Tested on real decks:** two CDJ-2000NXS2 on Pro DJ Link ran two unattended scripts (9 and 33 minutes) on a
  developer build of the same sources, each script on both decks: four file formats, pop-ups, preview gestures, a
  touch tour of the new pad row, header tiles and ZOOM – GRID with memory read-backs, settings, LINK, KEY SHIFT on
  eight long tracks with loops and searches, and 27 taps on the phase meter under SYNC. No EMERGENCY LOOP. **Not
  checked by eye or ear on the decks:** the treble fix (verified in a host test of the resampler), the doubled tick
  rows.
- **Versioning:** MAIN 2.30 / GUI 2.24 (DEV and RELEASE alike); UTILITY > INFO > BUILD shows `Cueline-2.3.1 <hash>`.
  2.3.1 installs over 2.3, 2.2, 2.1.1 and 2.1 without a factory reset.

Everything else from 2.3 is unchanged (KEY SHIFT inside the MASTER TEMPO engine, KEY SYNC, seven menu languages). Full history: CHANGELOG.md.

## Known limits (short)
- KEY SHIFT has no effect on tracks of 48 / 88.2 / 96 kHz (they play unshifted); 44.1 kHz tracks only for now.
- KEY SYNC with the 2.3 engine and the menu languages were checked in the emulator, not yet measured on real decks.
- The phase meter's doubled tick rows (seen for a moment on real decks with 2.3 test builds) have a suspected cause
  fixed in 2.3.1; not yet confirmed by eye on the decks.
- The first preview over LINK from another deck's USB can take a moment; after that it is immediate.
- Two Cueline decks sharing the mixer's Link Monitor: the hand-over takes a moment, so the monitor starts with a
  short delay, and holding a preview on both decks at once can still interleave the audio for a few seconds. Both
  are being improved in a later release.
- The WAVEFORM meter may sit 1 pixel row off vertically. The PHASE and 4 BARS views are unchanged (drawn by the CPU).
- Everything with a real CDJ-3000 / CDJ-3000X (0x0b packets, the 3000 showing our waveform, KEY SYNC with a 3000)
  is tested against an emulator only. Reports from real 3000 owners are very welcome (docs/COMPATIBILITY.md).
- Some settings are kept only with a HISTORY NAME of 29 characters or fewer (docs/KNOWN_LIMITS.md).
- Link Cue needs a DJM-A9 and plays MP3 / FLAC / WAV only.
- The deck's own menus come in seven languages; Cueline's own screens are in English. Full list: docs/KNOWN_LIMITS.md.

## Assets
| File | sha256 |
|---|---|
| `CuelineBuilder.exe` (Windows, unsigned; SmartScreen may warn) | `ac4d56841abd9c9815832a89c725d72b4f45f7d050f42f1dc357192cb4a58e26` |
| `CuelineBuilder-macOS.zip` (macOS universal app, ad-hoc signed, not notarized) | `0cc6b136d5b67fae16415f242ec142b95c19dfcd802374146f86c7bbb3c9b8bb` |
| `cueline.delta` (patch data, also in `builder/`) | `981750cba8e2681d00bf8eb213a0424c9c68bf92144232a38304912af48801c7` |
| Your built `C2KNXS2.UPD` (expected output) | `65c30bdef959704e86460b996b5c2ec3f1add7b10fb677e5bcbbedbe6f6e0914` |
| Official `C2KNXS2.UPD` 1.87 (required input) | `f211191a573b7a5c0e694936871f76011a58d5861dd061301cdb0d8b83a8b3e5` |
| `SHA256SUMS.txt` | the checksums above |

## Reporting bugs
Open a GitHub issue (Bug report template) with the BUILD id (UTILITY → INFO → BUILD), your setup (decks, mixer,
Pro DJ Link or not), the file format, what you did, what you expected and what happened; a phone video helps.
Community and beta testing: Discord https://discord.gg/UHfG94zeW. Fixes and features are welcome as pull requests
(CONTRIBUTING.md).
