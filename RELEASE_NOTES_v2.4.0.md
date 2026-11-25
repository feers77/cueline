# Cueline 2.4

**A small maintenance release on top of 2.3.1: no new features.** 2.4 closes the next items of the full code review
behind 2.3.1: a fast second tap on a Cueline touch control is no longer passed to the original firmware (it could
set a loop or jump beats under an open KEY SHIFT panel), the phase meter's view change and the scrolling waveform's
clock are hardened, and the preview decoder refuses malformed FLAC / WAV files instead of reading past a buffer.

2.4 was run on two real CDJ-2000NXS2 decks on Pro DJ Link with unattended test scripts on a developer build of the
same sources (one script per deck; the longer one was stopped by hand before its last block). Nothing was checked by
ear.

**Give new life to your CDJ-2000NXS2.** Custom firmware UI for the Pioneer CDJ-2000NXS2, inspired by the CDJ-3000.
Unofficial firmware patcher, **use at your own risk**, provided as-is without warranty. **Not affiliated with or
endorsed by Pioneer DJ / AlphaTheta.**

Cueline follows the deck's own version numbers: 2.4 = MAIN 2.32 / GUI 2.26. **Coming from 2.3.1, 2.3, 2.2, 2.1 or 2.1.1
you do not need a factory reset** (MAIN 2.32 is newer, so the deck installs it). Coming from a build with
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
- `C2KNXS2.UPD` sha256 `85727034d6c8e73578b966bf5473823242fb1821959e886b0c5690565688d40c`
- device version MAIN 2.32 / GUI 2.26; UTILITY → INFO → BUILD shows `Cueline-2.4 40366745`

## Install (read this)
1. **Coming from the official firmware, Cueline 2.3.1, 2.3, 2.2, 2.1 or 2.1.1:** copy the built `C2KNXS2.UPD` **alone** to the root of a small FAT32 USB stick and
   install it like an official update. No factory reset, your settings stay. **Never switch the deck off during the
   update.**
2. **Coming from anything with the same or a higher version number** (a DEV build, another custom firmware), or if
   the deck skips the update: save MY SETTINGS with rekordbox and note your deck settings, **disconnect the Pro DJ
   Link (LAN) cable** (while LINK is active the player does not allow DUPLICATION → DEFAULT), do **UTILITY →
   DUPLICATION → DEFAULT** (factory reset, it erases your settings) and install again.
3. Check UTILITY → INFO → BUILD = `Cueline-2.4 40366745`.

**Back to stock:** LAN cable out, UTILITY → DUPLICATION → DEFAULT, then install the official 1.87 `C2KNXS2.UPD`
alone on the stick. Check UTILITY → VERSION = 1.87. Details: README → *Going back to stock*.

## New in 2.4 (since 2.3.1)
- **Fast second tap on a Cueline touch control (bug fix):** a second tap that arrived within about 0.4 s of the
  first one was handed to the original firmware's touch map instead of being ignored. With the KEY SHIFT panel or the
  ZOOM – GRID row open over the BEAT LOOP / BEAT JUMP pads, a fast double tap on +1 / −1 could therefore set a loop
  or jump beats; on the browse strip it could move a paused deck. Such a tap is now ignored. Found by code review; in
  the unattended deck script two quick taps on +1 over open pads set no loop. Not yet tried by finger on the decks.
- **LINK phase meter, view change (hardening):** the deck's flags and the meter view are now read in one piece, and
  a new view is accepted only when two frames in a row agree, so a half-updated value cannot switch the view for
  one frame.
- **Scrolling waveform and its marks on one clock (hardening):** the position of the hardware-scrolled waveform is
  now computed from the same time stamp as the rest of the frame.
- **Preview decoder bounds (hardening):** a FLAC file with more channels than the preview supports, or a WAV file
  with an invalid block size, is refused instead of being read past the end of a buffer; an end-of-file case in the
  preview pre-roll is handled explicitly.
- **Small display fixes:** the PREVIEW playhead stays inside the strip at the very end of a track; five-digit numbers
  are printed in full; the wait spinner is cleared before EMPTY is shown; a damaged cue list can no longer be read
  past its end.
- **Tested on real decks:** two CDJ-2000NXS2 on Pro DJ Link ran a developer build of the same sources, one unattended
  script per deck. Script 1 (10 minutes, complete): three file formats, pop-ups, preview gestures, the touch tour
  of the pad row, header tiles and ZOOM – GRID with memory read-backs, 45 checks passed. Script 2 was stopped by
  hand after about 27 minutes: settings, LINK / MASTER / SYNC, a long loop with BROWSE and SHORT CUT inside it, and
  KEY SHIFT on eight long tracks with loops and searches had run (screen painted every second, no EMERGENCY LOOP,
  position 983–1014 ms of track per second); its last block, the taps on the phase meter under SYNC, did **not**
  run with this build. Nothing was checked by ear.
- **Versioning:** MAIN 2.32 / GUI 2.26 (DEV and RELEASE alike); UTILITY > INFO > BUILD shows
  `Cueline-2.4 <hash>`. 2.4 installs over 2.3.1, 2.3, 2.2, 2.1.1 and 2.1 without a factory reset.

Everything else from 2.3.1 is unchanged (KEY SHIFT inside the MASTER TEMPO engine, KEY SYNC, the CDJ-3000-style phase meter and player screen, seven menu languages). Full history: CHANGELOG.md.

## Known limits (short)
- KEY SHIFT has no effect on tracks of 48 / 88.2 / 96 kHz (they play unshifted); 44.1 kHz tracks only for now.
- KEY SYNC with the 2.3 engine and the menu languages were checked in the emulator, not yet measured on real decks.
- The phase meter's doubled tick rows (seen for a moment on real decks with 2.3 test builds) have a suspected cause
  fixed since 2.3.1; not yet confirmed by eye on the decks. The treble fix of 2.3.1 is verified in a host test of the
  resampler, not by ear.
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
| `CuelineBuilder.exe` (Windows, unsigned; SmartScreen may warn) | `453bd0bdd82fabb14c78af3748424165c931213003f442422d164793848d825d` |
| `CuelineBuilder-macOS.zip` (macOS universal app, ad-hoc signed, not notarized) | `7a59dc96a80a5357a50b53e315458a67911bfa8bee7f0f5c419e81af78d6e582` |
| `cueline.delta` (patch data, also in `builder/`) | `c9c1b73a65405ade4f70a8b61cb1ad0729f7c04ad90c836f703476e2154c0f4c` |
| Your built `C2KNXS2.UPD` (expected output) | `85727034d6c8e73578b966bf5473823242fb1821959e886b0c5690565688d40c` |
| Official `C2KNXS2.UPD` 1.87 (required input) | `f211191a573b7a5c0e694936871f76011a58d5861dd061301cdb0d8b83a8b3e5` |
| `SHA256SUMS.txt` | the checksums above |

## Reporting bugs
Open a GitHub issue (Bug report template) with the BUILD id (UTILITY → INFO → BUILD), your setup (decks, mixer,
Pro DJ Link or not), the file format, what you did, what you expected and what happened; a phone video helps.
Community and beta testing: Discord https://discord.gg/UHfG94zeW. Fixes and features are welcome as pull requests
(CONTRIBUTING.md).
