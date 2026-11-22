# Cueline 2.2

**Stability release.** 2.2 fixes the display problems reported in 2.1.1 — a blank white INFO panel, bands of
corrupted pixels after heavy browsing, and a screen that stopped updating until the next screen change — and the
bugs that showed only with two Cueline decks on Pro DJ Link (Touch Cue previewing the other deck's track, the other
deck's cues and artwork). The cause was fixed, not each case: Cueline no longer lets a window reach the panel
before it is drawn, and never hands a screen it is drawing back to the original firmware half way.

**KEY SHIFT and KEY SYNC are switched off in 2.2.** The 2.1 engine did not sound right on its own, so rather than
ship it again they are hidden and held off; they return in 2.3 with a new engine. **We recommend updating
to 2.2 now:** 2.1.1 has the display bugs listed above. 2.3, with KEY SHIFT and KEY SYNC back, is the next release.

2.2 was confirmed on two real CDJ-2000NXS2 decks on Pro DJ Link with an unattended 33-minute test script and a
power cycle.

**Give new life to your CDJ-2000NXS2.** Custom firmware UI for the Pioneer CDJ-2000NXS2, inspired by the CDJ-3000.
Unofficial firmware patcher, **use at your own risk**, provided as-is without warranty. **Not affiliated with or
endorsed by Pioneer DJ / AlphaTheta.**

Cueline follows the deck's own version numbers: 2.2 = MAIN 2.12 / GUI 2.06. **Coming from 2.1 or 2.1.1
you do not need a factory reset** (MAIN 2.12 is newer, so the deck installs it). Coming from a build with
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
- `C2KNXS2.UPD` sha256 `3a295ac2552b1d83edb55c0bd58db311c5adba496c7d3f4d2505786ff0bad548`
- device version MAIN 2.12 / GUI 2.06; UTILITY → INFO → BUILD shows `Cueline-2.2 7c0049ef`

## Install (read this)
1. **Coming from the official firmware, Cueline 2.1 or 2.1.1:** copy the built `C2KNXS2.UPD` **alone** to the root of a small FAT32 USB stick and
   install it like an official update. No factory reset, your settings stay. **Never switch the deck off during the
   update.**
2. **Coming from anything with the same or a higher version number** (a DEV build, another custom firmware), or if
   the deck skips the update: save MY SETTINGS with rekordbox and note your deck settings, **disconnect the Pro DJ
   Link (LAN) cable** (while LINK is active the player does not allow DUPLICATION → DEFAULT), do **UTILITY →
   DUPLICATION → DEFAULT** (factory reset, it erases your settings) and install again.
3. Check UTILITY → INFO → BUILD = `Cueline-2.2 7c0049ef`.

**Back to stock:** LAN cable out, UTILITY → DUPLICATION → DEFAULT, then install the official 1.87 `C2KNXS2.UPD`
alone on the stick. Check UTILITY → VERSION = 1.87. Details: README → *Going back to stock*.

## New in 2.2 (since 2.1.1)
- **Screen stuck with garbage (bug fix):** after closing SHORT CUT over a browse list the rows sometimes did not
  come back, and a few seconds later the screen showed areas that had never been drawn and stopped reacting until
  the next screen change, while audio and transport kept working. A list Cueline draws now stays Cueline's: at
  worst you see empty rows with the wait spinner, and one turn of the rotary brings the page back.
- **Blank white INFO panel and corrupted bands (bug fix):** a window could reach the panel before it had been
  drawn. Windows are now hidden at the moment the deck composes them.
- **Display that almost stopped updating (hardened):** drawing no longer depends on the original firmware drawing
  something first; one foreign row on the canvas repaints the whole canvas.
- **Two Cueline decks on Pro DJ Link (bug fixes):** every place that needs "this deck's status" reads the deck's
  own record instead of the last status packet that arrived. Touch Cue no longer previews the other deck's loaded
  track, the other deck's cues and artwork are no longer shown, and the mixer's Link Monitor slot is announced only
  while the deck actually holds it.
- **Row colours as on the CDJ-3000:** playing = bright green, already played = dark green (only once the track was
  loaded *and* played), previewed = no mark.
- **Phase meter WAVEFORM view in LIGHT MODE:** the first part of the master's mini waveform has the same
  background as the rest.
- **KEY SHIFT and KEY SYNC are switched off in 2.2.** They are hidden in UTILITY and held off; the grey KEY SHIFT
  tile in the header stays. The 2.1 engine did not sound right on its own; they return in 2.3 with a new engine.
- **Tested on real decks:** two CDJ-2000NXS2 on Pro DJ Link ran a 33-minute unattended script (seven file formats,
  every pop-up, preview gestures, UTILITY and SHORT CUT settings, SYNC / MASTER, a 22-minute load / play / seek
  soak) with the screen painted every second throughout, then a power cycle with every setting kept.
- **Versioning:** MAIN 2.12 / GUI 2.06 (DEV and RELEASE alike); UTILITY > INFO > BUILD shows `Cueline-2.2 <hash>`.
  2.2 installs over 2.1 and 2.1.1 without a factory reset.

Everything else from 2.1 / 2.1.1 is unchanged. Full history: CHANGELOG.md.

## Known limits (short)
- KEY SHIFT, KEY SYNC and the KEY SYNC BUTTON are switched off in 2.2 (back in 2.3).
- The first preview over LINK from another deck's USB can take a moment; after that it is immediate.
- Two Cueline decks sharing the mixer's Link Monitor: the hand-over takes a moment, so the monitor starts with a
  short delay, and holding a preview on both decks at once can still interleave the audio for a few seconds. Both
  are being improved in a later release.
- The WAVEFORM meter may sit 1 pixel row off vertically. The PHASE and 4 BARS views are unchanged (drawn by the CPU).
- Everything with a real CDJ-3000 / CDJ-3000X (0x0b packets, the 3000 showing our waveform, KEY SYNC with a 3000)
  is tested against an emulator only. Reports from real 3000 owners are very welcome (docs/COMPATIBILITY.md).
- Some settings are kept only with a HISTORY NAME of 29 characters or fewer (docs/KNOWN_LIMITS.md).
- Link Cue needs a DJM-A9 and plays MP3 / FLAC / WAV only.
- Menus in English and Spanish only. Full list: docs/KNOWN_LIMITS.md.

## Assets
| File | sha256 |
|---|---|
| `CuelineBuilder.exe` (Windows, unsigned; SmartScreen may warn) | `cc110f45afbf3a4d1c54b5b2786f51473da708f962e5b29601def797c3b7b1c5` |
| `CuelineBuilder-macOS.zip` (macOS universal app, ad-hoc signed, not notarized) | `9e0e813c4a045255a08c9f6b65ac59217522e183ec6084a65bd4eb13a1189a8f` |
| `cueline.delta` (patch data, also in `builder/`) | `b9d05e7aa686b39be7ed033ef968446b98e230ad43cb4b3eee2bc88879f5799b` |
| Your built `C2KNXS2.UPD` (expected output) | `3a295ac2552b1d83edb55c0bd58db311c5adba496c7d3f4d2505786ff0bad548` |
| Official `C2KNXS2.UPD` 1.87 (required input) | `f211191a573b7a5c0e694936871f76011a58d5861dd061301cdb0d8b83a8b3e5` |
| `SHA256SUMS.txt` | the checksums above |

## Reporting bugs
Open a GitHub issue (Bug report template) with the BUILD id (UTILITY → INFO → BUILD), your setup (decks, mixer,
Pro DJ Link or not), the file format, what you did, what you expected and what happened; a phone video helps.
Community and beta testing: Discord https://discord.gg/UHfG94zeW. Fixes and features are welcome as pull requests
(CONTRIBUTING.md).
