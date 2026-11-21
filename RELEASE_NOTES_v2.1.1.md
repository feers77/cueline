# Cueline 2.1.1

**Link Cue fix release.** With **two Cueline decks on the same Pro DJ Link**, Link Cue stuttered and you could
hear the other deck. The mixer keeps a single Link Monitor slot and plays one source at a time, and until now every
Cueline deck claimed that slot permanently — so two linked decks fought over it. In 2.1.1 a deck claims the slot
only while you are actually using Link Cue on it (a preview touch or Touch Cue) plus a few seconds, and an idle
deck announces nothing: the deck you touch last gets the monitor, automatically, with no menu action.
2.1.1 also makes **UTILITY → PRO DJ LINK → LINK CUE** visible in the release build and saves it across a power
cycle, as a manual override. Everything else in 2.1 is unchanged.

The warning in the 2.1 README said the problem was "in 2.1". That was wrong, and we are correcting it here: the
same code is in **every** Cueline version, 1.92 included. It only ever showed when *two* decks ran Cueline with
Link Cue at the same time — until 2.1 only one deck ran Cueline. A single Cueline deck was never affected, and
1.92 is not a workaround for it.

**Give new life to your CDJ-2000NXS2.** Custom firmware UI for the Pioneer CDJ-2000NXS2, inspired by the CDJ-3000.
Unofficial firmware patcher, **use at your own risk**, provided as-is without warranty. **Not affiliated with or
endorsed by Pioneer DJ / AlphaTheta.**

Cueline follows the deck's own version numbers: 2.1.1 = MAIN 2.11 / GUI 2.05. **Coming from 2.1 you do
not need a factory reset** (MAIN 2.11 is newer than 2.10, so the deck installs it). Coming from a build with
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
- `C2KNXS2.UPD` sha256 `765790f583f1365ef42d7bfd5ad09af4736a730e0edbfe888337ec5929755650`
- device version MAIN 2.11 / GUI 2.05; UTILITY → INFO → BUILD shows `Cueline-2.1.1 1c1a45f3`

## Install (read this)
1. **Coming from Cueline 2.1:** copy the built `C2KNXS2.UPD` **alone** to the root of a small FAT32 USB stick and
   install it like an official update. No factory reset, your settings stay. **Never switch the deck off during the
   update.**
2. **Coming from anything with the same or a higher version number** (a DEV build, another custom firmware), or if
   the deck skips the update: save MY SETTINGS with rekordbox and note your deck settings, **disconnect the Pro DJ
   Link (LAN) cable** (while LINK is active the player does not allow DUPLICATION → DEFAULT), do **UTILITY →
   DUPLICATION → DEFAULT** (factory reset, it erases your settings) and install again.
3. Check UTILITY → INFO → BUILD = `Cueline-2.1.1 1c1a45f3`.

**Back to stock:** LAN cable out, UTILITY → DUPLICATION → DEFAULT, then install the official 1.87 `C2KNXS2.UPD`
alone on the stick. Check UTILITY → VERSION = 1.87. Details: README → *Going back to stock*.

## New in 2.1.1 (since 2.1)
- **Link Cue with two Cueline decks (bug fix):** the mixer keeps a *single* Link Monitor slot and plays one source
  at a time. Until now every Cueline deck claimed that slot permanently, so two linked Cueline decks fought over
  it: the preview stuttered and you could hear the other deck. Now a deck claims the slot only while you are
  actually using Link Cue on it (a preview touch or Touch Cue) plus a few seconds, and an idle deck announces
  nothing at all -- so there is no collision, the deck you touch last takes the monitor, and it all happens by
  itself with no menu action.
  This is **not new in 2.1**: the same code is in 1.92 and earlier. It only ever showed when two decks ran Cueline
  with Link Cue at the same time, which is why a single Cueline deck was never affected.
- **UTILITY > PRO DJ LINK > LINK CUE (OFF / PREVIEW / CUE / BOTH) is visible in the release build** -- it used to
  appear only in developer builds -- and it is now saved across a power cycle (default BOTH). Handy as a manual
  override: set one deck to OFF and only the other one ever feeds the mixer. It is saved only when the deck's
  HISTORY name is 23 characters or shorter; with a longer name it comes back as BOTH.
- **Still being improved:** the hand-over from one deck to the other takes a moment, so the monitor starts with a
  short delay; and if you hold a preview on both decks at the same time the audio can still interleave for a few
  seconds. Both are on the list for a later release.
- **Nothing else changed:** same features, same screens and the same source as 2.1 otherwise.
- **Versioning:** MAIN 2.11 / GUI 2.05 (DEV and RELEASE alike); UTILITY > INFO > BUILD shows
  `Cueline-2.1.1 <hash>`. 2.1.1 installs over 2.1 without a factory reset.

Everything 2.1 brought (settings fix, stock pop-ups, green KEY on the selected row, hot-cue badges, preview
gesture, web builder, macOS app) is in 2.1.1 unchanged. Full history: CHANGELOG.md.

## Known limits (short)
- Two Cueline decks sharing the mixer's Link Monitor: the hand-over takes a moment, so the monitor starts with a
  short delay, and holding a preview on both decks at once can still interleave the audio for a few seconds. Both
  are being improved in a later release.
- The WAVEFORM meter may sit 1 pixel row off vertically. The PHASE and 4 BARS views are unchanged (drawn by the CPU).
- Everything with a real CDJ-3000 / CDJ-3000X (0x0b packets, the 3000 showing our waveform, KEY SYNC with a 3000)
  is tested against an emulator only. Reports from real 3000 owners are very welcome (docs/COMPATIBILITY.md).
- Some settings are kept only with a HISTORY NAME of 29 characters or fewer (docs/KNOWN_LIMITS.md).
- Downgrading to 1.92 keeps your settings except WAVEFORM HALF (it reads as FULL).
- Link Cue needs a DJM-A9 and plays MP3 / FLAC / WAV only.
- Menus in English and Spanish only. Full list: docs/KNOWN_LIMITS.md.

## Assets
| File | sha256 |
|---|---|
| `CuelineBuilder.exe` (Windows, unsigned; SmartScreen may warn) | `c38f86e3f3dafc0d9fab7ff5dc980b4e5fda0ea5fb606817c66c8010d04413d7` |
| `CuelineBuilder-macOS.zip` (macOS universal app, ad-hoc signed, not notarized) | `b4b51ea319e7f9324372d617be474d2d7bae99e14276a361494be828f62674f3` |
| `cueline.delta` (patch data, also in `builder/`) | `6809d72584d8e16576a4252f6cb63a67904079ebc239854eb6b081939e59c55d` |
| Your built `C2KNXS2.UPD` (expected output) | `765790f583f1365ef42d7bfd5ad09af4736a730e0edbfe888337ec5929755650` |
| Official `C2KNXS2.UPD` 1.87 (required input) | `f211191a573b7a5c0e694936871f76011a58d5861dd061301cdb0d8b83a8b3e5` |
| `SHA256SUMS.txt` | the checksums above |

## Reporting bugs
Open a GitHub issue (Bug report template) with the BUILD id (UTILITY → INFO → BUILD), your setup (decks, mixer,
Pro DJ Link or not), the file format, what you did, what you expected and what happened; a phone video helps.
Community and beta testing: Discord https://discord.gg/UHfG94zeW. Fixes and features are welcome as pull requests
(CONTRIBUTING.md).
